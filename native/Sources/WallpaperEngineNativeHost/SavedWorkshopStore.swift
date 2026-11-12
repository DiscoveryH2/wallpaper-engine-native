import CryptoKit
import Darwin
import Foundation

/// Serializes the tiny irreversible `current.json` publication with a caller's
/// cancellation boundary. A cancelled save may retain an immutable staging
/// version for safe later cleanup, but can never move the current pointer.
final class SavedWorkshopCommitPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var permitted = true

    func cancel() {
        lock.lock(); permitted = false; lock.unlock()
    }

    func isPermitted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return permitted
    }

    func commit<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard permitted else { throw CancellationError() }
        return try operation()
    }
}

/// Immutable copies of explicitly selected Steam items. Only current.json is
/// replaced; an active renderer continues reading its original version directory.
enum SavedWorkshopStore {
    struct Record: Codable, Sendable {
        let format: Int
        let id: String
        let version: String
        let manifest: String
        let sourceProject: String
        let settingsIdentity: String
        let title: String
        let type: String
        let savedAt: Date
        let bytes: Int64
        let files: Int
        let clonedFiles: Int
        let copiedBytes: Int64
        var directory: URL { root.appendingPathComponent(id).appendingPathComponent(version) }
        var project: URL { directory.appendingPathComponent("Content/project.json") }
    }
    /// A fail-closed snapshot of one current saved item and its older immutable
    /// versions.  This is deliberately a lineage of *saved copies*, not a
    /// transferable media-authorization identity: media grants remain bound to
    /// each record's actual `project` path.
    struct HistoricalLineage: Sendable {
        let current: Record
        let historical: [Record]
    }
    private static let queue = DispatchQueue(label: "io.wallpaper-engine-native.saved-workshop", qos: .userInitiated)
    private static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    private static let maximumLibraryBytes: Int64 = 32 * 1024 * 1024 * 1024
    private static let reserveBytes: Int64 = 2 * 1024 * 1024 * 1024
    private static let maximumEntries = 30_000
    /// A normal item has only a few immutable saved revisions.  History cleanup
    /// is intentionally unavailable rather than unbounded if that invariant is
    /// no longer true.
    private static let maximumHistoricalVersions = 512
    /// A descriptive authorization hint is never worth an unbounded directory
    /// scan on a synchronous project-load path.  A larger history remains
    /// intact and simply receives the generic unavailable-authorization UI.
    private static let maximumProvenanceHistoricalVersions = 8
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WallpaperEngineNative/SavedWorkshop", isDirectory: true)
    }
    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
    private static func validID(_ text: String) -> Bool {
        guard let number = UInt64(text), number > 0 else { return false }
        return text == String(number)
    }
    private static func validVersion(_ text: String) -> Bool {
        UUID(uuidString: text)?.uuidString.lowercased() == text
    }
    private static func privateDirectory(_ fd: WebSourceFD) throws {
        let value = try fd.info()
        guard value.st_mode & S_IFMT == S_IFDIR, value.st_uid == geteuid(), value.st_mode & 0o077 == 0 else {
            throw PropertyError.invalid("本机壁纸库必须是当前用户独占的目录。")
        }
    }
    private static func directory(_ parent: WebSourceFD, _ name: String, create: Bool) throws -> WebSourceFD {
        if create, mkdirat(parent.raw, name, 0o700) != 0, errno != EEXIST { throw WebSourceFD.failure("无法创建本机壁纸库") }
        let fd = try parent.child(name, directory: true)
        try privateDirectory(fd)
        return fd
    }
    private static func openRoot(create: Bool) throws -> WebSourceFD {
        let support = root.deletingLastPathComponent().deletingLastPathComponent()
        let base = try WebSourceFD.openAbsolute(support, directory: true)
        if create, mkdirat(base.raw, "WallpaperEngineNative", 0o700) != 0, errno != EEXIST { throw WebSourceFD.failure("无法创建应用目录") }
        let app = try base.child("WallpaperEngineNative", directory: true)
        let info = try app.info()
        guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw PropertyError.invalid("应用目录不能允许其他用户写入。") }
        return try directory(app, "SavedWorkshop", create: create)
    }
    private static func read(_ parent: WebSourceFD, _ name: String) throws -> Record {
        let file = try parent.child(name, directory: false)
        let data = try file.readSmall(maximum: 64 * 1024)
        let value = try JSONDecoder().decode(Record.self, from: data)
        guard value.format == 1, validID(value.id), validVersion(value.version), validID(value.manifest),
              value.bytes >= 0, value.bytes <= maximumBytes, value.files > 0, value.files <= maximumEntries,
              value.title.utf8.count <= 4096, value.type.utf8.count <= 128,
              [value.sourceProject, value.settingsIdentity].allSatisfy({ path in
                  path.hasPrefix("/") && !path.contains("\0") && path.utf8.count <= 4096 &&
                  URL(fileURLWithPath: path).standardizedFileURL.path == path &&
                  path.hasSuffix("/steamapps/workshop/content/431960/" + value.id + "/project.json")
              }) else { throw PropertyError.invalid("本机壁纸版本记录无效。") }
        return value
    }
    static func current(_ id: String) -> Record? {
        guard validID(id), let base = try? openRoot(create: false),
              let item = try? directory(base, id, create: false),
              let record = try? read(item, "current.json"), record.id == id else { return nil }
        return recordForProject(record.project)
    }
    static func recordForProject(_ project: URL) -> Record? {
        let path = project.standardizedFileURL.path
        let prefix = root.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let parts = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard parts.count == 4, validID(parts[0]), validVersion(parts[1]), parts[2] == "Content", parts[3] == "project.json",
              let base = try? openRoot(create: false), let item = try? directory(base, parts[0], create: false),
              let version = try? directory(item, parts[1], create: false),
              let record = try? read(version, "record.json"), record.id == parts[0], record.version == parts[1],
              let content = try? directory(version, "Content", create: false),
              (try? content.child("project.json", directory: false)) != nil else { return nil }
        return record
    }

    /// Read-only convenience inspection.  It acquires the saved-library lock
    /// while it verifies the lineage, but releases it before returning.  The
    /// result must therefore never itself authorize deletion; callers that are
    /// about to mutate another store must use `withValidatedHistoricalLineage`
    /// so the current pointer cannot change between validation and mutation.
    static func inspectHistoricalLineage(anchorProject: URL) -> HistoricalLineage? {
        withValidatedHistoricalLineage(anchorProject: anchorProject) { $0 }
    }

    /// Runs `operation` while the saved-library's existing nonblocking lock is
    /// held and while `anchorProject` is rechecked as this item's current saved
    /// version. `nil` means *do nothing*: the anchor is not current, the store
    /// is busy, a directory/record is unknown or malformed, or a safety limit
    /// was reached. This method never creates a directory or repairs a record.
    ///
    /// The method is intentionally not called by `save` and therefore cannot
    /// turn a Steam update into a permission-revocation path. A caller making
    /// a grant decision must additionally hold WallpaperMediaGrants' transaction
    /// lock before entering this closure.
    static func withValidatedHistoricalLineage<T>(anchorProject: URL, _ operation: (HistoricalLineage) throws -> T) rethrows -> T? {
        guard let anchor = recordForProject(anchorProject),
              let base = try? openRoot(create: false) else { return nil }
        let lock = openat(base.raw, ".lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard lock >= 0 else { return nil }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              flock(lock, LOCK_EX | LOCK_NB) == 0,
              let lineage = validatedHistoricalLineage(anchor: anchor, base: base) else { return nil }
        return try operation(lineage)
    }

    /// Read-only bounded form for explanatory UI.  This deliberately has a
    /// much smaller limit than the historical reclaimer: when an item has more
    /// than eight older copies, it returns `nil` rather than making a project
    /// load wait while every record is decoded under the library lock.  `nil`
    /// also covers a busy lock, malformed entry, or an anchor that stopped
    /// being current.  It never creates, migrates, or removes a saved copy.
    static func withBoundedProvenanceLineage<T>(anchorProject: URL, _ operation: (HistoricalLineage) throws -> T) rethrows -> T? {
        guard let anchor = recordForProject(anchorProject),
              let base = try? openRoot(create: false) else { return nil }
        let lock = openat(base.raw, ".lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard lock >= 0 else { return nil }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              flock(lock, LOCK_EX | LOCK_NB) == 0,
              let lineage = boundedProvenanceLineage(anchor: anchor, base: base) else { return nil }
        return try operation(lineage)
    }

    private static func sameRecord(_ lhs: Record, _ rhs: Record) -> Bool {
        lhs.format == rhs.format && lhs.id == rhs.id && lhs.version == rhs.version && lhs.manifest == rhs.manifest &&
        lhs.sourceProject == rhs.sourceProject && lhs.settingsIdentity == rhs.settingsIdentity && lhs.title == rhs.title &&
        lhs.type == rhs.type && lhs.savedAt == rhs.savedAt && lhs.bytes == rhs.bytes && lhs.files == rhs.files &&
        lhs.clonedFiles == rhs.clonedFiles && lhs.copiedBytes == rhs.copiedBytes
    }

    /// Caller holds the existing root `.lock`.  A historical copy is usable as
    /// a cleanup candidate only after both its path-shaped record and its
    /// on-disk project file have been opened descriptor-relatively.
    private static func checkedRecord(_ item: WebSourceFD, id: String, version: String) throws -> Record {
        let versionDirectory = try directory(item, version, create: false)
        let record = try read(versionDirectory, "record.json")
        guard record.id == id, record.version == version else {
            throw PropertyError.invalid("本机壁纸版本记录与目录不匹配。")
        }
        let content = try directory(versionDirectory, "Content", create: false)
        _ = try content.child("project.json", directory: false)
        return record
    }

    /// This cannot throw to its caller: every unexpected filesystem condition
    /// deliberately collapses to `nil`, which means historical grants must be
    /// retained.  A valid record from another stable settings lineage is known
    /// but never made a candidate for this lineage.
    private static func validatedHistoricalLineage(anchor: Record, base: WebSourceFD) -> HistoricalLineage? {
        // Preserve the reclaimer's established directory-entry limit.
        historicalLineage(anchor: anchor, base: base, maximumDirectoryEntries: maximumHistoricalVersions + 1)
    }

    /// The caller holds the root lock. The bounded provenance caller uses this
    /// helper with eight histories, so `names(maximum:)` fails before it can
    /// enumerate or decode an unexpectedly large revision directory.
    private static func boundedProvenanceLineage(anchor: Record, base: WebSourceFD) -> HistoricalLineage? {
        // Eight predecessor directories plus current.json and the current
        // version directory. A ninth predecessor makes `names` fail closed.
        historicalLineage(anchor: anchor, base: base, maximumDirectoryEntries: maximumProvenanceHistoricalVersions + 2)
    }

    private static func historicalLineage(anchor: Record, base: WebSourceFD, maximumDirectoryEntries: Int) -> HistoricalLineage? {
        do {
            let item = try directory(base, anchor.id, create: false)
            let pointer = try read(item, "current.json")
            guard pointer.id == anchor.id, validVersion(pointer.version) else { return nil }
            let current = try checkedRecord(item, id: anchor.id, version: pointer.version)
            guard sameRecord(pointer, current), sameRecord(anchor, current) else { return nil }
            let names = try item.names(maximum: maximumDirectoryEntries)
            var historical: [Record] = []
            for name in names {
                if name == "current.json" { continue }
                guard validVersion(name) else { return nil }
                let record = try checkedRecord(item, id: current.id, version: name)
                if record.version == current.version { continue }
                // A valid record with another stable identity remains intact,
                // but is not part of the authorization lineage being pruned.
                guard record.settingsIdentity == current.settingsIdentity else { continue }
                historical.append(record)
            }
            return HistoricalLineage(current: current, historical: historical.sorted { $0.version < $1.version })
        } catch { return nil }
    }
    /// Preserve existing ordinary settings and script state across saved versions.
    /// Media grants deliberately continue using each actual version's path.
    static func settingsIdentity(_ project: URL) -> String {
        if let bundled = NativeBundledWallpapers.record(for: project) { return "native-bundled:" + bundled.id }
        return recordForProject(project)?.settingsIdentity ?? project.standardizedFileURL.resolvingSymlinksInPath().path
    }
    static func records() -> (items: [Record], warning: String?) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], nil) }
        do {
            let base = try openRoot(create: false)
            let names = try base.names(maximum: 2000)
            var result: [Record] = [], invalid = 0
            for name in names where validID(name) {
                if let record = current(name) { result.append(record) } else { invalid += 1 }
            }
            return (result, invalid > 0 ? "\(invalid) 项本机保存记录无法读取。" : nil)
        } catch { return ([], "本机壁纸库无法读取：\(error.localizedDescription)") }
    }
    private static func installedManifest(_ project: URL, id: String) throws -> String {
        guard let library = SteamLibraryIndex.location(for: project, id: id), !library.downloadPending(id) else {
            throw PropertyError.invalid("Steam 项目未安装完整，已保留当前壁纸。")
        }
        let acf = try library.manifest()
        guard let item = (acf["WorkshopItemsInstalled"] as? [String: [String: String]])?[id],
              let manifest = item["manifest"], validID(manifest) else {
            throw PropertyError.invalid("Steam 安装版本尚未确认，未保存副本。")
        }
        return manifest
    }
    /// Called only for a user selection or an update to an already saved item.
    /// An existing local Steam item can be saved offline; this checks installation,
    /// not whether it is the latest remotely published revision.
    static func save(project: URL, id: String, expectedManifest: String? = nil,
                     commitPermit: SavedWorkshopCommitPermit? = nil) throws -> Record {
        guard validID(id) else { throw PropertyError.invalid("无效的工坊 ID。") }
        guard commitPermit?.isPermitted() != false else { throw CancellationError() }
        let canonical = project.standardizedFileURL.resolvingSymlinksInPath()
        let manifest = try installedManifest(canonical, id: id)
        guard expectedManifest == nil || expectedManifest == manifest else { throw PropertyError.invalid("Steam 正在切换版本，请稍后重试。") }
        let base = try openRoot(create: true)
        let lock = openat(base.raw, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard lock >= 0 else { throw WebSourceFD.failure("无法锁定本机壁纸库") }
        defer { flock(lock, LOCK_UN); Darwin.close(lock) }
        var lockInfo = stat()
        guard fstat(lock, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_uid == geteuid(),
              flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw PropertyError.invalid("本机壁纸库正在保存，请稍后重试。") }
        let previous = current(id)
        if let previous, previous.manifest == manifest { return previous }
        let source = try WebSourceFD.openAbsolute(canonical.deletingLastPathComponent(), directory: true)
        let metadata = try source.child("project.json", directory: false).readSmall(maximum: 4 * 1024 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
              let type = object["type"] as? String, ["scene", "web", "video"].contains(type.lowercased()),
              let resource = object["file"] as? String, !resource.isEmpty else {
            throw PropertyError.invalid("该项目格式尚不能保存为可用的本机壁纸。")
        }
        // Scan first: limits apply to actual source sizes, never Steam estimates.
        var before = Inventory()
        try walk(source, destination: nil, path: "", depth: 0, inventory: &before)
        let used = try retainedBytes(base)
        guard used <= maximumLibraryBytes - before.bytes else { throw PropertyError.invalid("保存版本累计将超过 32 GiB，未继续复制。旧版本仍保留。") }
        try checkSpace(base, reserving: before.bytes)
        let item = try directory(base, id, create: true)
        let uuid = UUID().uuidString.lowercased(), temporary = ".saving-" + uuid
        let staging = try directory(item, temporary, create: true)
        let content = try directory(staging, "Content", create: true)
        var copied = Inventory()
        // Failed staging directories are retained and counted in the storage cap;
        // never recursively delete a path that another process could replace.
        try walk(source, destination: content, path: "", depth: 0, inventory: &copied)
        var after = Inventory()
        try walk(source, destination: nil, path: "", depth: 0, inventory: &after)
        guard before.fingerprint == copied.fingerprint, before.fingerprint == after.fingerprint,
              manifest == (try installedManifest(canonical, id: id)),
              WebFileSignature(try source.info()) == WebFileSignature(try WebSourceFD.openAbsolute(canonical.deletingLastPathComponent(), directory: true).info()),
              metadata == (try content.child("project.json", directory: false).readSmall(maximum: 4 * 1024 * 1024)) else {
            throw PropertyError.invalid("Steam 素材在保存期间变化，已保留当前壁纸。请稍后重试。")
        }
        let record = Record(format: 1, id: id, version: uuid, manifest: manifest, sourceProject: canonical.path,
                            settingsIdentity: previous?.settingsIdentity ?? canonical.path,
                            title: String((object["title"] as? String ?? id).prefix(512)), type: type.lowercased(), savedAt: Date(),
                            bytes: copied.bytes, files: copied.files, clonedFiles: copied.cloned, copiedBytes: copied.copiedBytes)
        let data = try JSONEncoder().encode(record)
        try write(data, to: staging, name: "record.json")
        guard fsync(staging.raw) == 0, renameat(item.raw, temporary, item.raw, uuid) == 0, fsync(item.raw) == 0 else { throw WebSourceFD.failure("无法提交本机壁纸版本") }
        let publish = {
            // Recheck immediately before the pointer changes.  The copied
            // immutable directory may remain as an unreferenced failed save,
            // but an ACF change can never make it the current version.
            guard manifest == (try installedManifest(canonical, id: id)) else {
                throw PropertyError.invalid("Steam 版本在提交时变化，当前壁纸未替换。")
            }
            let pointer = ".current-" + uuid
            try write(data, to: item, name: pointer)
            guard renameat(item.raw, pointer, item.raw, "current.json") == 0, fsync(item.raw) == 0 else { throw WebSourceFD.failure("无法登记本机壁纸版本") }
        }
        if let commitPermit { try commitPermit.commit(publish) }
        else { try publish() }
        return record
    }
    private struct Inventory {
        var entries = 0, files = 0, cloned = 0
        var bytes: Int64 = 0, copiedBytes: Int64 = 0
        var hash = SHA256()
        var fingerprint: Data { Data(hash.finalize()) }
    }
    private static func checkSpace(_ fd: WebSourceFD, reserving bytes: Int64) throws {
        var space = statvfs()
        guard fstatvfs(fd.raw, &space) == 0 else { throw WebSourceFD.failure("无法读取可用磁盘空间") }
        let available = Double(space.f_bavail) * Double(space.f_frsize)
        guard available >= Double(bytes + reserveBytes) else { throw PropertyError.invalid("可用磁盘空间不足，保存后需至少余下 2 GiB。") }
    }
    private static func retainedBytes(_ base: WebSourceFD) throws -> Int64 {
        var total: Int64 = 0, count = 0
        func countTree(_ fd: WebSourceFD, depth: Int) throws {
            guard depth <= 36 else { throw PropertyError.invalid("本机库目录过深。") }
            for name in try fd.names(maximum: 100_000) {
                count += 1; guard count <= 100_000 else { throw PropertyError.invalid("本机库超过 100,000 个目录项目。") }
                let value = try fd.info(name)
                if value.st_mode & S_IFMT == S_IFDIR { try countTree(fd.child(name, directory: true), depth: depth + 1) }
                else if value.st_mode & S_IFMT == S_IFREG {
                    guard value.st_size >= 0, value.st_size <= maximumLibraryBytes - total else { throw PropertyError.invalid("本机壁纸库已达 32 GiB 上限。") }
                    total += value.st_size
                } else { throw PropertyError.invalid("本机壁纸库含有链接或特殊文件。") }
            }
        }
        try countTree(base, depth: 0)
        return total
    }
    private static func walk(_ source: WebSourceFD, destination: WebSourceFD?, path: String, depth: Int, inventory: inout Inventory) throws {
        guard depth <= 32 else { throw PropertyError.invalid("壁纸目录超过 32 层。") }
        let initial = WebFileSignature(try source.info())
        inventory.hash.update(data: Data((path + "/\0" + initial.revision + "\0").utf8))
        for name in try source.names(maximum: maximumEntries) {
            inventory.entries += 1
            guard inventory.entries <= maximumEntries, !name.contains("\0") else { throw PropertyError.invalid("壁纸超过 30,000 个目录项目。") }
            let info = try source.info(name), kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                let child = try source.child(name, directory: true)
                let target = try destination.map { try directory($0, name, create: true) }
                try walk(child, destination: target, path: path + name + "/", depth: depth + 1, inventory: &inventory)
            } else if kind == S_IFREG {
                let file = try source.child(name, directory: false), signature = WebFileSignature(try file.info())
                guard signature.size >= 0, signature.size <= maximumBytes - inventory.bytes else { throw PropertyError.invalid("单张壁纸素材总量超过 8 GiB。") }
                inventory.bytes += signature.size; inventory.files += 1
                inventory.hash.update(data: Data((path + name + "\0" + signature.revision + "\0").utf8))
                if let destination { try copy(file, to: destination, name: name, signature: signature, inventory: &inventory) }
            } else { throw PropertyError.invalid("壁纸含有链接或特殊文件，未保存副本。") }
        }
        guard initial == WebFileSignature(try source.info()) else { throw PropertyError.invalid("壁纸目录在保存时变化。") }
        if let destination, fsync(destination.raw) != 0 { throw WebSourceFD.failure("无法写入壁纸目录") }
    }
    private static func copy(_ source: WebSourceFD, to parent: WebSourceFD, name: String, signature: WebFileSignature, inventory: inout Inventory) throws {
        try checkSpace(parent, reserving: signature.size)
        let output: Int32
        if fclonefileat(source.raw, parent.raw, name, UInt32(CLONE_NOOWNERCOPY)) == 0 {
            inventory.cloned += 1
            output = openat(parent.raw, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        } else {
            guard [EXDEV, ENOTSUP, EINVAL, ENOSYS].contains(errno) else { throw WebSourceFD.failure("无法克隆壁纸文件") }
            output = openat(parent.raw, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw WebSourceFD.failure("无法创建壁纸文件") }
            do {
                var position: Int64 = 0, buffer = [UInt8](repeating: 0, count: 256 * 1024)
                while position < signature.size {
                    let count = Int(min(Int64(buffer.count), signature.size - position))
                    let n = buffer.withUnsafeMutableBytes { pread(source.raw, $0.baseAddress!, count, position) }
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw PropertyError.invalid("壁纸源文件在复制时变化。") }
                    var offset = 0
                    while offset < n {
                        let written = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress!.advanced(by: offset), n - offset) }
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw WebSourceFD.failure("壁纸文件写入失败") }
                        offset += written
                    }
                    position += Int64(n)
                }
                inventory.copiedBytes += signature.size
            } catch { Darwin.close(output); throw error }
        }
        guard output >= 0 else { throw WebSourceFD.failure("无法打开壁纸副本") }
        defer { Darwin.close(output) }
        var info = stat()
        guard fstat(output, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == signature.size,
              signature == WebFileSignature(try source.info()), fchmod(output, 0o600) == 0, fsync(output) == 0 else {
            throw PropertyError.invalid("壁纸副本未能完整保存。")
        }
    }
    private static func write(_ data: Data, to parent: WebSourceFD, name: String) throws {
        let fd = openat(parent.raw, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WebSourceFD.failure("无法创建版本记录") }
        defer { Darwin.close(fd) }
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw WebSourceFD.failure("无法保存版本记录") }
            offset += n
        }
        guard fsync(fd) == 0 else { throw WebSourceFD.failure("无法提交版本记录") }
    }
}
