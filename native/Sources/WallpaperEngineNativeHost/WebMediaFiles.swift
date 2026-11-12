import CryptoKit
import Darwin
import Foundation

/// All snapshot construction and scans use one bounded I/O lane. Values passed
/// through it are immutable JSON snapshots / file owners, never AppKit objects.
enum WebMediaIO {
    static let queue = DispatchQueue(label: "io.wallpaper-engine-native.web-media", qos: .userInitiated)
    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

/// Private native grants are deliberately separate from the author's property JSON.
/// A page can never turn a path in project.json or a script message into a grant.
enum WallpaperMediaGrants {
    /// Every transition that can make a grant reachable/unreachable shares
    /// this lock: reserved creation pins a grant before releasing it, property
    /// storage commits run under it, and inventory-based pruning holds it from
    /// scan through delete. The required order is transaction -> retention.
    private static let transactionLock = NSLock()
    static func withTransaction<T>(_ operation: () throws -> T) rethrows -> T {
        transactionLock.lock(); defer { transactionLock.unlock() }
        return try operation()
    }

    /// A browser can restore a previous media choice. Keep its authorization
    /// alive until that browser session confirms or successfully rolls back.
    final class Retention: @unchecked Sendable {
        let id = UUID()
        init(project: URL, tokens: Set<String>) {
            retentionLock.lock(); defer { retentionLock.unlock() }
            retentions[id] = (identity(project), tokens)
        }
        deinit {
            retentionLock.lock(); defer { retentionLock.unlock() }
            retentions.removeValue(forKey: id)
        }
    }

    /// Owns newly created grants until their property transaction either
    /// commits or rolls back. Construction happens while `transactionLock` is
    /// held, so a pruner cannot observe the file before its retention pin.
    final class Reservation: @unchecked Sendable {
        private let project: URL
        private let tokens: Set<String>
        private let stateLock = NSLock()
        private var retention: Retention?
        private var finished = false

        fileprivate init(project: URL, tokens: Set<String>) {
            self.project = project; self.tokens = tokens
            retention = tokens.isEmpty ? nil : Retention(project: project, tokens: tokens)
        }
        /// Release the temporary pin after the caller's property record has
        /// committed (and, if desired, has completed the same-transaction
        /// inventory cleanup). Committing never deletes a grant.
        func commit() {
            stateLock.lock(); defer { stateLock.unlock() }
            guard !finished else { return }
            finished = true; retention = nil
        }
        /// Remove uncommitted grants. It is idempotent and holds the global
        /// transaction lock before allowing Retention's lock to be acquired.
        func cancel() {
            stateLock.lock()
            guard !finished else { stateLock.unlock(); return }
            finished = true
            stateLock.unlock()
            WallpaperMediaGrants.withTransaction {
                retention = nil
                tokens.forEach { removeUnlocked($0, project: project) }
            }
        }
        deinit { cancel() }
    }

    /// The only creation surface for UI property transactions. The builder is
    /// scoped to this closure so callers cannot create an unpinned grant and
    /// hand it to a concurrent pruning pass.
    final class ReservationBuilder {
        private let project: URL
        private var tokens = Set<String>()
        fileprivate init(project: URL) { self.project = project }
        func create(source: URL, property: WallpaperProperty, sourceRevision: String) throws -> String {
            let token = try createUnlocked(source: source, project: project, property: property, sourceRevision: sourceRevision)
            tokens.insert(token)
            return token
        }
        fileprivate func cleanup() { tokens.forEach { removeUnlocked($0, project: project) } }
        fileprivate func reservation() -> Reservation { Reservation(project: project, tokens: tokens) }
    }

    static func reserve<T>(project: URL, _ operation: (ReservationBuilder) throws -> T) throws -> (value: T, reservation: Reservation) {
        try withTransaction {
            let builder = ReservationBuilder(project: project)
            do { return (try operation(builder), builder.reservation()) }
            catch { builder.cleanup(); throw error }
        }
    }
    private static let retentionLock = NSLock()
    private static var retentions: [UUID: (String, Set<String>)] = [:]
    struct Grant: Codable, Sendable {
        let version: Int
        let project: String
        let property: String
        let kind: String
        let fileType: String
        let mode: String?
        let sourceRevision: String
        let token: String
        let name: String
        let bookmark: Data
    }

    /// Result for the opt-in, historical-version-only reclaimer.  There is no
    /// implicit caller: a properties transaction must explicitly supply a
    /// complete reference set after a successful user-confirmed clear or
    /// replacement.  In particular, Steam updates and ordinary loads must not
    /// call this API.
    enum HistoricalPruneResult: Sendable, Equatable {
        /// The SavedWorkshop current pointer changed, was busy, or contained
        /// unknown data. No MediaGrants directory was touched.
        case skippedUnvalidatedLineage
        /// A reference token was invalid, or a historical grant directory had
        /// an unknown, malformed, unsafe, or unreadable entry. No historical
        /// project is deleted in this invocation.
        case skippedUnsafeGrantStore
        /// Every candidate directory was completely validated before the first
        /// unlink. `retainedGrants` includes explicit property references and
        /// live Browser-session Retention pins.
        case completed(historicalProjects: Int, removedGrants: Int, retainedGrants: Int)
    }

    /// Read-only explanation for a token that is unavailable to the current
    /// saved project.  This is deliberately not an authorization result: it
    /// never makes the historical grant usable by the current project.
    enum HistoricalAuthorizationProvenance: Sendable, Equatable {
        /// Exactly one validated immutable predecessor owns the token with the
        /// same property contract. The UI may tell the user to choose again.
        case priorSavedVersion
    }

    static func identity(_ project: URL) -> String { project.standardizedFileURL.resolvingSymlinksInPath().path }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func isToken(_ value: String) -> Bool {
        guard value.hasPrefix("native-media:"), let uuid = UUID(uuidString: String(value.dropFirst(13))) else { return false }
        return value == "native-media:" + uuid.uuidString.lowercased()
    }
    static func extensions(for property: WallpaperProperty) -> Set<String> {
        if property.mediaFileType == "video" {
            // WebKit decides actual codec support. Audio is useful for authors
            // whose video selector is intentionally wired to an <audio> element.
            return ["webm", "ogg", "ogv", "mp4", "m4v", "mov", "mp3", "wav", "m4a", "aac", "flac"]
        }
        return ["jpeg", "jpg", "png", "pnga", "bmp", "gif", "svg", "webp", "avif", "heic", "heif"]
    }
    private static func directory(_ project: URL) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("WallpaperEngineNative/MediaGrants", isDirectory: true).appendingPathComponent(digest(identity(project)), isDirectory: true)
    }

    /// Does not create Application Support or a grant directory.  The strict
    /// historical reclaimer deliberately treats a missing directory as empty;
    /// a present-but-unreadable one is unsafe and blocks all deletion.
    private static func existingDirectory(_ project: URL) throws -> URL? {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let grants = support.appendingPathComponent("WallpaperEngineNative/MediaGrants", isDirectory: true)
        var grantsIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: grants.path, isDirectory: &grantsIsDirectory) else { return nil }
        guard grantsIsDirectory.boolValue else { throw PropertyError.invalid("素材授权目录格式无效。") }
        let projectDirectory = grants.appendingPathComponent(digest(identity(project)), isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectDirectory.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { throw PropertyError.invalid("素材授权目录格式无效。") }
        return projectDirectory
    }
    private static func file(_ token: String, project: URL) throws -> URL {
        guard isToken(token) else { throw PropertyError.invalid("无效的素材授权。") }
        return try directory(project).appendingPathComponent(String(token.dropFirst(13)) + ".json")
    }
    /// Compatibility creation for non-property callers. It is safe only for
    /// an immediately persisted owner; property editing must use `reserve`.
    static func create(source: URL, project: URL, property: WallpaperProperty, sourceRevision: String) throws -> String {
        try withTransaction { try createUnlocked(source: source, project: project, property: property, sourceRevision: sourceRevision) }
    }
    private static func createUnlocked(source: URL, project: URL, property: WallpaperProperty, sourceRevision: String) throws -> String {
        guard property.isMedia, source.isFileURL else { throw PropertyError.invalid("请选择本机素材。") }
        let canonical = source.standardizedFileURL.resolvingSymlinksInPath()
        let fd = try WebSourceFD.openAbsolute(canonical, directory: property.type == "directory")
        if property.type == "file", !extensions(for: property).contains(canonical.pathExtension.lowercased()) {
            throw PropertyError.invalid("\(property.label)：此选择框需要\(property.mediaFileType == "video" ? "视频或音频" : "图片")文件。")
        }
        _ = try fd.info()
        let token = "native-media:" + UUID().uuidString.lowercased()
        let bookmark = try canonical.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        guard bookmark.count <= 128 * 1024 else { throw PropertyError.invalid("素材位置记录过大。") }
        let grant = Grant(version: 1, project: identity(project), property: property.key, kind: property.type,
                          fileType: property.mediaFileType, mode: property.directoryMode, sourceRevision: sourceRevision, token: token, name: String(canonical.lastPathComponent.prefix(512)), bookmark: bookmark)
        let destination = try file(token, project: project)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(grant).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return token
    }
    static func read(_ token: String, project: URL, property: WallpaperProperty) throws -> Grant {
        guard isToken(token), let parent = try existingDirectory(project) else {
            throw PropertyError.invalid("素材授权与当前项目或属性不匹配，请重新选择。")
        }
        let url = parent.appendingPathComponent(String(token.dropFirst(13)) + ".json")
        let descriptor = try WebSourceFD.openAbsolute(url, directory: false)
        let data = try descriptor.readSmall(maximum: 256 * 1024)
        let grant = try JSONDecoder().decode(Grant.self, from: data)
        guard grant.version == 1, grant.token == token, grant.project == identity(project),
              grant.property == property.key, grant.kind == property.type, grant.fileType == property.mediaFileType, (grant.mode ?? property.directoryMode) == property.directoryMode,
              grant.bookmark.count <= 128 * 1024 else { throw PropertyError.invalid("素材授权与当前项目或属性不匹配，请重新选择。") }
        return grant
    }

    /// Determine whether a token that cannot be read by `anchorProject` is
    /// demonstrably owned by exactly one older immutable version of that same
    /// saved Steam item. This only reads app-private grant metadata. In
    /// particular it never resolves a security-scoped bookmark, opens the
    /// user's selected file, creates a grant directory, copies a grant, or
    /// changes any authorization.
    ///
    /// An incomplete lineage, lock conflict, malformed candidate, wrong
    /// property contract, or ambiguous duplicate deliberately returns `nil`.
    /// Callers must then retain the generic unavailable-authorization message.
    static func historicalAuthorizationProvenance(token: String, anchorProject: URL,
                                                  property: WallpaperProperty) -> HistoricalAuthorizationProvenance? {
        guard property.isMedia, isToken(token) else { return nil }
        // Match the grant transaction -> SavedWorkshop lock order used by the
        // opt-in reclaimer. Although this path only reads, the order prevents a
        // concurrent explicit cleanup from racing a descriptor probe, while
        // the saved-library lock keeps `current` fixed until every candidate
        // has been checked.
        return withTransaction {
            // This must be an actual absence, not merely a `read` failure.  A
            // corrupt, mismatched, unreadable, or otherwise unsafe current
            // token must keep the generic warning; an older record cannot
            // truthfully be described as the token's only owner in that case.
            guard currentGrantIsDefinitelyAbsent(token: token, project: anchorProject) else { return nil }
            let hasValidatedPredecessor = SavedWorkshopStore.withBoundedProvenanceLineage(anchorProject: anchorProject) { lineage -> Bool in
                guard identity(lineage.current.project) == identity(anchorProject) else { return false }
                var matches = 0
                for record in lineage.historical {
                    switch historicalGrantProbe(token: token, project: record.project, property: property) {
                    case .absent:
                        continue
                    case .matching:
                        matches += 1
                        // Tokens are UUIDs. A second valid historical owner is
                        // unexpected, so prefer the generic fail-closed UI.
                        guard matches == 1 else { return false }
                    case .unsafe:
                        return false
                    }
                }
                return matches == 1
            }
            return hasValidatedPredecessor == true ? .priorSavedVersion : nil
        }
    }

    /// A read failure is not absence.  This is intentionally descriptor-based
    /// and fail-closed: only a missing exact deterministic filename lets the
    /// provenance path inspect older copies.  It never creates a grant
    /// directory or decodes a bookmark.
    private static func currentGrantIsDefinitelyAbsent(token: String, project: URL) -> Bool {
        do {
            guard let url = try existingDirectory(project) else { return true }
            let directory = try WebSourceFD.openAbsolute(url, directory: true)
            guard privateGrantDirectory(directory) else { return false }
            var info = stat()
            let name = String(token.dropFirst(13)) + ".json"
            if fstatat(directory.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return false }
            return errno == ENOENT
        } catch {
            return false
        }
    }

    private enum HistoricalGrantProbe {
        case absent
        case matching
        case unsafe
    }

    /// Read only the deterministic filename for one token. A missing token is
    /// normal for a historical version; every other filesystem or decoding
    /// failure is unsafe rather than evidence for a version-specific message.
    private static func historicalGrantProbe(token: String, project: URL,
                                             property: WallpaperProperty) -> HistoricalGrantProbe {
        do {
            guard let url = try existingDirectory(project) else { return .absent }
            let directory = try WebSourceFD.openAbsolute(url, directory: true)
            guard privateGrantDirectory(directory) else { return .unsafe }
            let name = String(token.dropFirst(13)) + ".json"
            var info = stat()
            if fstatat(directory.raw, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                return errno == ENOENT ? .absent : .unsafe
            }
            guard info.st_mode & S_IFMT == S_IFREG else { return .unsafe }
            let file = try directory.child(name, directory: false)
            let grant = try JSONDecoder().decode(Grant.self, from: file.readSmall(maximum: 256 * 1024))
            guard validHistoricalGrant(grant, token: token, project: project),
                  grant.property == property.key, grant.kind == property.type,
                  grant.fileType == property.mediaFileType,
                  (grant.mode ?? property.directoryMode) == property.directoryMode else {
                return .unsafe
            }
            return .matching
        } catch {
            return .unsafe
        }
    }

    static func source(_ grant: Grant) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: grant.bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { throw PropertyError.invalid("素材位置已失效，请重新选择。") }
        return url.standardizedFileURL.resolvingSymlinksInPath()
    }
    static func remove(_ token: String, project: URL) {
        withTransaction { removeUnlocked(token, project: project) }
    }
    private static func removeUnlocked(_ token: String, project: URL) {
        guard isToken(token), let parent = try? existingDirectory(project) else { return }
        try? FileManager.default.removeItem(at: parent.appendingPathComponent(String(token.dropFirst(13)) + ".json"))
    }
    static func prune(project: URL, keeping: Set<String>) {
        withTransaction { pruneWithinTransaction(project: project, keeping: keeping) }
    }
    /// Call only while `transactionLock` is held. This allows property-store
    /// inventory and deletion to be one linearizable operation without relying
    /// on a reentrant NSLock.
    static func pruneWithinTransaction(project: URL, keeping: Set<String>) {
        let keeping = keeping.union(retainedTokens(project: project))
        guard let parent = try? directory(project), let children = try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return }
        for child in children.prefix(4096) where child.pathExtension == "json" {
            let token = "native-media:" + child.deletingPathExtension().lastPathComponent
            if isToken(token), !keeping.contains(token) { try? FileManager.default.removeItem(at: child) }
        }
    }

    /// Opt-in wrapper for callers that do not already own the media-grant
    /// transaction. This function has no call sites in update/load paths.
    static func pruneHistorical(anchorProject: URL, completeReferences: Set<String>) -> HistoricalPruneResult {
        withTransaction {
            pruneHistoricalWithinTransaction(anchorProject: anchorProject, completeReferences: completeReferences)
        }
    }

    /// Strict historical-only reclaimer. The caller must hold
    /// `WallpaperMediaGrants.transactionLock` and must pass the complete set of
    /// media tokens named by every durable and session property record for the
    /// stable settings lineage. A missing/unknown reference inventory must not
    /// be represented by an empty set; callers must skip this API instead.
    ///
    /// SavedWorkshop revalidates its current pointer while holding its own
    /// nonblocking lock. Therefore a Steam update, unfinished save, malformed
    /// saved item, or lock conflict becomes `skippedUnvalidatedLineage` before
    /// any grant directory is opened for deletion. This method never creates,
    /// migrates, copies, or reauthorizes a media grant.
    static func pruneHistoricalWithinTransaction(anchorProject: URL, completeReferences: Set<String>) -> HistoricalPruneResult {
        guard completeReferences.allSatisfy(isToken) else { return .skippedUnsafeGrantStore }
        guard let result = SavedWorkshopStore.withValidatedHistoricalLineage(anchorProject: anchorProject, { lineage in
            strictPruneHistorical(lineage: lineage, completeReferences: completeReferences)
        }) else { return .skippedUnvalidatedLineage }
        return result
    }

    /// The required lock ordering is media transaction -> SavedWorkshop library
    /// `.lock` -> Retention lock. This function is entered only after the first
    /// two have been acquired by its callers.
    private static func retainedTokens(project: URL) -> Set<String> {
        retentionLock.lock(); defer { retentionLock.unlock() }
        return retentions.values.filter { $0.0 == identity(project) }.reduce(into: Set<String>()) { $0.formUnion($1.1) }
    }

    private struct HistoricalGrantDirectory {
        let descriptor: WebSourceFD
        let removals: [String]
        let retained: Int
    }

    private enum HistoricalGrantScan {
        case empty
        case ready(HistoricalGrantDirectory)
        case unsafe
    }

    /// Scan every historical directory completely before unlinking from any of
    /// them. Unknown data must cause retention, not best-effort cleanup.
    private static func strictPruneHistorical(lineage: SavedWorkshopStore.HistoricalLineage, completeReferences: Set<String>) -> HistoricalPruneResult {
        var directories: [HistoricalGrantDirectory] = []
        for record in lineage.historical {
            switch strictHistoricalGrantDirectory(project: record.project, keeping: completeReferences.union(retainedTokens(project: record.project))) {
            case .empty:
                continue
            case .unsafe:
                return .skippedUnsafeGrantStore
            case .ready(let directory):
                directories.append(directory)
            }
        }
        var removed = 0, retained = 0
        for directory in directories {
            retained += directory.retained
            for name in directory.removals {
                var info = stat()
                guard fstatat(directory.descriptor.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      info.st_mode & S_IFMT == S_IFREG,
                      unlinkat(directory.descriptor.raw, name, 0) == 0 else {
                    // Preflight completed before this point; a later filesystem
                    // failure is still fail-closed for all remaining entries.
                    return .skippedUnsafeGrantStore
                }
                removed += 1
            }
        }
        return .completed(historicalProjects: lineage.historical.count, removedGrants: removed, retainedGrants: retained)
    }

    private static func privateGrantDirectory(_ descriptor: WebSourceFD) -> Bool {
        guard let info = try? descriptor.info() else { return false }
        return info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
    }

    private static func boundedNonempty(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
    }

    /// A history scan validates only stable grant-file invariants. It never
    /// resolves a bookmark and deliberately does not reinterpret an old
    /// project's author property definitions as a new-version authorization.
    private static func validHistoricalGrant(_ grant: Grant, token: String, project: URL) -> Bool {
        guard grant.version == 1, grant.token == token, grant.project == identity(project),
              ["file", "directory"].contains(grant.kind), ["image", "video"].contains(grant.fileType),
              boundedNonempty(grant.property, maximum: 4096), boundedNonempty(grant.sourceRevision, maximum: 4096),
              boundedNonempty(grant.name, maximum: 512), !grant.bookmark.isEmpty, grant.bookmark.count <= 128 * 1024 else { return false }
        if let mode = grant.mode, (!boundedNonempty(mode, maximum: 128) || (grant.kind == "directory" && !["ondemand", "fetchall"].contains(mode))) {
            return false
        }
        return grant.kind != "directory" || grant.mode != nil
    }

    private static func strictHistoricalGrantDirectory(project: URL, keeping: Set<String>) -> HistoricalGrantScan {
        do {
            guard let url = try existingDirectory(project) else { return .empty }
            let descriptor = try WebSourceFD.openAbsolute(url, directory: true)
            guard privateGrantDirectory(descriptor) else { return .unsafe }
            let names = try descriptor.names(maximum: 4096)
            var removals: [String] = [], retained = 0
            for name in names {
                guard name.hasSuffix(".json") else { return .unsafe }
                let raw = String(name.dropLast(5)), token = "native-media:" + raw
                guard isToken(token) else { return .unsafe }
                let info = try descriptor.info(name)
                guard info.st_mode & S_IFMT == S_IFREG else { return .unsafe }
                let file = try descriptor.child(name, directory: false)
                let grant = try JSONDecoder().decode(Grant.self, from: file.readSmall(maximum: 256 * 1024))
                guard validHistoricalGrant(grant, token: token, project: project) else { return .unsafe }
                if keeping.contains(token) { retained += 1 }
                else { removals.append(name) }
            }
            return .ready(HistoricalGrantDirectory(descriptor: descriptor, removals: removals, retained: retained))
        } catch { return .unsafe }
    }
}

/// Descriptor-relative traversal prevents a source symlink swap from expanding
/// WebKit's read access. Snapshot destinations contain only host-owned files.
final class WebSourceFD {
    let raw: Int32
    init(_ raw: Int32) { self.raw = raw }
    deinit { Darwin.close(raw) }
    static func failure(_ action: String) -> PropertyError { .invalid("\(action)：\(String(cString: strerror(errno)))") }
    static func openAbsolute(_ url: URL, directory: Bool) throws -> WebSourceFD {
        let components = url.pathComponents.filter { $0 != "/" }
        guard url.isFileURL, url.path.hasPrefix("/"), !components.isEmpty, !components.contains("..") else { throw PropertyError.invalid("无效的本机文件位置。") }
        let initial = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard initial >= 0 else { throw failure("无法打开根目录") }
        var parent = WebSourceFD(initial)
        for (index, component) in components.enumerated() {
            parent = try parent.child(component, directory: index < components.count - 1 || directory)
        }
        return parent
    }
    func child(_ name: String, directory: Bool) throws -> WebSourceFD {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw PropertyError.invalid("无效的素材文件名。") }
        let descriptor = openat(raw, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK | (directory ? O_DIRECTORY : 0))
        guard descriptor >= 0 else { throw Self.failure("无法读取素材 \(name)") }
        let child = WebSourceFD(descriptor), info = try child.info()
        guard directory ? (info.st_mode & S_IFMT == S_IFDIR) : (info.st_mode & S_IFMT == S_IFREG) else { throw PropertyError.invalid("素材必须是普通文件或目录。") }
        return child
    }
    func info() throws -> stat { var value = stat(); guard fstat(raw, &value) == 0 else { throw Self.failure("无法读取文件信息") }; return value }
    func names(maximum: Int) throws -> [String] {
        // A new open file description gives each enumeration its own offset.
        let duplicate = openat(raw, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard duplicate >= 0 else { throw Self.failure("无法打开目录列表") }
        guard let directory = fdopendir(duplicate) else { Darwin.close(duplicate); throw Self.failure("无法读取目录列表") }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw Self.failure("无法读取目录项目") }; break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= maximum else { throw PropertyError.invalid("目录项目超过当前 \(maximum) 项上限。") }
        }
        return result.sorted()
    }
    func info(_ name: String) throws -> stat {
        var value = stat()
        guard fstatat(raw, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw Self.failure("无法读取目录项目 \(name)") }
        return value
    }
    func readSmall(maximum: Int) throws -> Data {
        let size = try info().st_size
        guard size >= 0, size <= maximum else { throw PropertyError.invalid("本机素材记录超过大小上限。") }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeMutableBytes { pread(raw, $0.baseAddress!.advanced(by: offset), $0.count - offset, off_t(offset)) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw Self.failure("素材记录读取失败") }; offset += n
        }
        return Data(bytes)
    }
}

struct WebFileSignature: Equatable {
    let device: dev_t, inode: ino_t, size: off_t
    let modifiedSeconds: Int, modifiedNanoseconds: Int, changedSeconds: Int, changedNanoseconds: Int
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec; changedNanoseconds = value.st_ctimespec.tv_nsec
    }
    var revision: String { "\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanoseconds):\(changedSeconds):\(changedNanoseconds)" }
}

fileprivate final class WebSnapshotBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var copied: Int64 = 0
    private(set) var clonedFiles = 0
    func usedClone() { lock.lock(); clonedFiles += 1; lock.unlock() }
    func reserve(_ bytes: Int64, at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        guard bytes >= 0, copied + bytes <= 256 * 1024 * 1024 else { throw PropertyError.invalid("此磁盘无法克隆素材，普通复制超过 256 MiB 上限；请使用支持克隆的 APFS 位置或较小的素材。") }
        let available = (try FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        guard available >= bytes + 512 * 1024 * 1024 else { throw PropertyError.invalid("磁盘空间不足，未复制素材。") }
        copied += bytes
    }
    func release(_ bytes: Int64) { lock.lock(); copied -= bytes; lock.unlock() }
}

fileprivate final class WebOwnedMediaFile {
    let url: URL
    let signature: WebFileSignature
    let fallbackBytes: Int64
    private let budget: WebSnapshotBudget
    init(url: URL, signature: WebFileSignature, fallbackBytes: Int64, budget: WebSnapshotBudget) { self.url = url; self.signature = signature; self.fallbackBytes = fallbackBytes; self.budget = budget }
    deinit {
        let url = url, budget = budget, bytes = fallbackBytes
        WebMediaIO.queue.async { try? FileManager.default.removeItem(at: url); budget.release(bytes) }
    }
}

fileprivate struct WebPropertyMedia {
    let token: String
    let files: [String: WebOwnedMediaFile]
}

final class WebMediaState: @unchecked Sendable {
    let properties: [String: Any]
    let directories: [String: Any]
    let diagnostics: [String]
    fileprivate let media: [String: WebPropertyMedia]
    fileprivate init(properties: [String: Any], directories: [String: Any], diagnostics: [String], media: [String: WebPropertyMedia]) {
        self.properties = properties; self.directories = directories; self.diagnostics = diagnostics; self.media = media
    }
    func sameResourcePaths(as other: WebMediaState) -> Bool {
        guard Set(media.keys) == Set(other.media.keys) else { return false }
        return media.allSatisfy { key, value in
            guard let previous = other.media[key], Set(value.files.keys) == Set(previous.files.keys) else { return false }
            return value.files.allSatisfy { name, file in previous.files[name]?.url == file.url }
        }
    }
}

/// A controller shares one leased session across its WebViews. Its read root
/// includes its original project snapshot and explicitly selected media only.
final class WebMediaWorkspace: @unchecked Sendable {
    let root: URL
    let projectDirectory: URL
    let entry: URL
    let projectFileCount: Int
    let projectByteCount: Int64
    let sourceRevision: String
    private let project: WallpaperProject
    private let lease: Int32
    private let budget = WebSnapshotBudget()
    private static let maximumFileBytes: Int64 = 1024 * 1024 * 1024
    private static let maximumTreeBytes: Int64 = 4 * 1024 * 1024 * 1024
    private static let maximumMediaFiles = 2000

    init(project: WallpaperProject) throws {
        self.project = project
        let cache = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("WallpaperEngineNative/WebSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Self.pruneAbandonedSessions(cache)
        root = cache.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        projectDirectory = root.appendingPathComponent("Project", isDirectory: true)
        let relative = String(project.resourceURL.path.dropFirst(project.directoryURL.path.count + 1))
        guard !relative.isEmpty, !relative.split(separator: "/").contains("..") else { throw PropertyError.invalid("网页入口不在当前项目内。") }
        entry = projectDirectory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        lease = Darwin.open(root.appendingPathComponent(".lease").path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lease >= 0 else { try? FileManager.default.removeItem(at: root); throw WebSourceFD.failure("无法建立网页运行目录") }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(lease); try? FileManager.default.removeItem(at: root); throw WebSourceFD.failure("无法锁定网页运行目录") }
        do {
            try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Media", isDirectory: true), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let descriptor = try WebSourceFD.openAbsolute(project.directoryURL, directory: true)
            var count = 0, bytes: Int64 = 0, revision = SHA256()
            try Self.copyProject(descriptor, to: projectDirectory, relative: "", depth: 0, count: &count, bytes: &bytes, revision: &revision, budget: budget)
            let snapshotRevision = revision.finalize().map { String(format: "%02x", $0) }.joined()
            // Catch updates that occur between parsing project.json and taking
            // the snapshot, or while copying an earlier member of the tree.
            let metadata = try WebSourceFD.openAbsolute(projectDirectory.appendingPathComponent(project.projectURL.lastPathComponent), directory: false).readSmall(maximum: 4 * 1024 * 1024)
            var checkedCount = 0, checkedBytes: Int64 = 0, checkedRevision = SHA256()
            let currentSource = try WebSourceFD.openAbsolute(project.directoryURL, directory: true)
            try Self.copyProject(currentSource, to: nil, relative: "", depth: 0, count: &checkedCount, bytes: &checkedBytes, revision: &checkedRevision, budget: budget)
            guard metadata == project.metadataData, snapshotRevision == checkedRevision.finalize().map({ String(format: "%02x", $0) }).joined() else {
                throw PropertyError.invalid("壁纸在准备过程中发生更新，保留当前画面；请稍后重新打开。")
            }
            projectFileCount = count; projectByteCount = bytes; sourceRevision = snapshotRevision
        } catch {
            flock(lease, LOCK_UN); Darwin.close(lease); try? FileManager.default.removeItem(at: root); throw error
        }
    }
    deinit {
        let root = root, descriptor = lease
        WebMediaIO.queue.async { try? FileManager.default.removeItem(at: root); flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
    }

    private static func pruneAbandonedSessions(_ cache: URL) {
        guard let roots = try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]) else { return }
        for root in roots.prefix(256) where UUID(uuidString: root.lastPathComponent) != nil {
            guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .creationDateKey]), values.isDirectory == true, values.isSymbolicLink != true,
                  let created = values.creationDate, created.timeIntervalSinceNow < -600 else { continue }
            let fd = Darwin.open(root.appendingPathComponent(".lease").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { try? FileManager.default.removeItem(at: root); flock(fd, LOCK_UN) }
            Darwin.close(fd)
        }
    }

    private static func copyProject(_ source: WebSourceFD, to destination: URL?, relative: String, depth: Int, count: inout Int, bytes: inout Int64, revision: inout SHA256, budget: WebSnapshotBudget) throws {
        guard depth <= 32 else { throw PropertyError.invalid("网页项目目录超过 32 层。") }
        for name in try source.names(maximum: 12000) {
            count += 1; guard count <= 12000 else { throw PropertyError.invalid("网页项目超过 12,000 个目录项目。") }
            let info = try source.info(name), kind = info.st_mode & S_IFMT
            let target = destination?.appendingPathComponent(name)
            let path = relative + name
            if kind == S_IFDIR {
                let child = try source.child(name, directory: true)
                if let target { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
                revision.update(data: Data((path + "/\0" + WebFileSignature(try child.info()).revision + "\0").utf8))
                try copyProject(child, to: target, relative: path + "/", depth: depth + 1, count: &count, bytes: &bytes, revision: &revision, budget: budget)
            } else if kind == S_IFREG {
                let child = try source.child(name, directory: false), actual = try child.info()
                guard actual.st_size >= 0, actual.st_size <= maximumFileBytes, bytes + actual.st_size <= maximumTreeBytes else { throw PropertyError.invalid("网页项目超过单文件 1 GiB 或总量 4 GiB 上限。") }
                bytes += actual.st_size
                if let target { _ = try copy(child, to: target, expected: WebFileSignature(actual), budget: budget) }
                revision.update(data: Data((path + "\0" + WebFileSignature(actual).revision + "\0").utf8))
            } else { throw PropertyError.invalid("网页项目包含符号链接或非普通文件，未授予网页读取权限：\(name)") }
        }
    }

    private static func copy(_ source: WebSourceFD, to target: URL, expected: WebFileSignature, budget: WebSnapshotBudget) throws -> Int64 {
        var fallbackBytes: Int64 = 0, succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: target); budget.release(fallbackBytes) } }
        if fclonefileat(source.raw, AT_FDCWD, target.path, UInt32(CLONE_NOOWNERCOPY)) == 0 { budget.usedClone() }
        else {
            let cloneError = errno
            guard [EXDEV, ENOTSUP, EINVAL, ENOSYS].contains(cloneError) else { throw WebSourceFD.failure("无法克隆网页素材") }
            try budget.reserve(expected.size, at: target); fallbackBytes = expected.size
            let output = Darwin.open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw WebSourceFD.failure("无法创建素材副本") }
            defer { Darwin.close(output) }
            var offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65536)
            while offset < expected.size {
                let capacity = Int(min(Int64(buffer.count), expected.size - offset))
                let read = buffer.withUnsafeMutableBytes { pread(source.raw, $0.baseAddress!, capacity, offset) }
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw PropertyError.invalid("素材在复制期间发生变化。") }
                var written = 0
                while written < read {
                    let n = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: written), read - written) }
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw WebSourceFD.failure("素材副本写入失败") }; written += n
                }
                offset += Int64(read)
            }
        }
        var copiedInfo = stat()
        guard lstat(target.path, &copiedInfo) == 0, copiedInfo.st_mode & S_IFMT == S_IFREG, copiedInfo.st_size == expected.size,
              WebFileSignature(try source.info()) == expected else { throw PropertyError.invalid("素材在复制期间发生变化，请稍后重试。") }
        guard chmod(target.path, 0o600) == 0 else { throw WebSourceFD.failure("无法设置素材权限") }
        succeeded = true
        return fallbackBytes
    }

    /// All filesystem work may run on a worker queue. The supplied prior state
    /// is immutable; unchanged files retain their existing snapshot paths.
    func prepare(properties: [String: Any], previous: WebMediaState?, tolerateUnavailable: Bool, requiredProperties: Set<String> = []) throws -> WebMediaState {
        var runtime = properties, media: [String: WebPropertyMedia] = [:], diagnostics: [String] = []
        var directories: [String: Any] = [:], totalCount = 0, totalBytes: Int64 = 0
        for property in project.propertyDefinitions where property.isMedia {
            let token = (properties[property.key] as? [String: Any])?["value"] as? String ?? ""
            let prior = previous?.media[property.key]
            var selected = WebPropertyMedia(token: "", files: [:])
            if !token.isEmpty {
                do {
                    let grant = try WallpaperMediaGrants.read(token, project: project.projectURL, property: property)
                    guard grant.sourceRevision == sourceRevision else { throw PropertyError.invalid("壁纸文件已更新，请重新选择素材以授权当前版本。") }
                    let url = try WallpaperMediaGrants.source(grant)
                    let source = try WebSourceFD.openAbsolute(url, directory: property.type == "directory")
                    let parent = root.appendingPathComponent("Media", isDirectory: true).appendingPathComponent(WallpaperMediaGrants.digest(property.key), isDirectory: true)
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    var files: [String: WebOwnedMediaFile] = [:], skipped = 0
                    let names = property.type == "directory" ? try source.names(maximum: 12000) : [url.lastPathComponent]
                    var selectionBytes: Int64 = 0
                    for name in names {
                        let ext = (name as NSString).pathExtension.lowercased()
                        if property.type == "directory" {
                            let info = try source.info(name)
                            if name.hasPrefix(".") || info.st_mode & S_IFMT != S_IFREG || !WallpaperMediaGrants.extensions(for: property).contains(ext) { skipped += 1; continue }
                        } else if !WallpaperMediaGrants.extensions(for: property).contains(ext) { throw PropertyError.invalid("所选素材类型与作者定义不匹配。") }
                        let file = property.type == "directory" ? try source.child(name, directory: false) : source
                        let signature = WebFileSignature(try file.info())
                        guard signature.size >= 0, signature.size <= Self.maximumFileBytes else { throw PropertyError.invalid("单个素材超过 1 GiB 上限。") }
                        selectionBytes += signature.size
                        guard files.count < Self.maximumMediaFiles, selectionBytes <= Self.maximumTreeBytes else { throw PropertyError.invalid("所选素材超过 2,000 个文件或 4 GiB 上限。") }
                        if prior?.token == token, let existing = prior?.files[name], existing.signature == signature { files[name] = existing }
                        else {
                            let target = parent.appendingPathComponent(UUID().uuidString.lowercased() + "." + ext)
                            let copied = try Self.copy(file, to: target, expected: signature, budget: budget)
                            files[name] = WebOwnedMediaFile(url: target, signature: signature, fallbackBytes: copied, budget: budget)
                        }
                    }
                    selected = WebPropertyMedia(token: token, files: files)
                    if skipped > 0 { diagnostics.append("\(property.label)：未导入 \(skipped) 个子目录、隐藏项、链接或不匹配格式；当前读取所选目录第一层。") }
                } catch {
                    guard tolerateUnavailable, !requiredProperties.contains(property.key) else { throw error }
                    if let prior, prior.token == token { selected = prior }
                    diagnostics.append("\(property.label)：素材暂不可用，\(selected.files.isEmpty ? "使用空选择" : "保留上次副本")。\(error.localizedDescription)")
                }
            }
            totalCount += selected.files.count; totalBytes += selected.files.values.reduce(0) { $0 + $1.signature.size }
            guard totalCount <= Self.maximumMediaFiles, totalBytes <= Self.maximumTreeBytes else { throw PropertyError.invalid("当前壁纸选中的素材总量超过 2,000 个文件或 4 GiB 上限。") }
            media[property.key] = selected
            let paths = selected.files.keys.sorted().compactMap { selected.files[$0].map { Self.runtimePath($0.url) } }
            if property.type == "directory" {
                directories[property.key] = ["mode": property.directoryMode, "files": paths]
                if property.directoryMode == "fetchall" { runtime.removeValue(forKey: property.key) }
                else { runtime[property.key] = property.payload(selected.token.isEmpty ? "" : Self.runtimePath(root.appendingPathComponent("Media/" + WallpaperMediaGrants.digest(property.key), isDirectory: true))) }
            } else { runtime[property.key] = property.payload(paths.first ?? "") }
        }
        diagnostics.insert("Web 素材：\(totalCount) 个文件；按明确选择导入，每 5 秒检查变化。", at: 0)
        return WebMediaState(properties: runtime, directories: directories, diagnostics: diagnostics, media: media)
    }

    static func runtimePath(_ url: URL) -> String {
        // Authors prepend file:///. Encoding includes quotes and parentheses,
        // since these paths are also used inside CSS url('…') by real projects.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/-._~")
        return String(url.path.drop(while: { $0 == "/" })).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
