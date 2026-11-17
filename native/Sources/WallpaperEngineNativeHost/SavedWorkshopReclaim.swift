import Foundation

/// One saved copy of a Workshop item under `SavedWorkshop/<id>/<version>`.
///
/// This is a filesystem-only description: it never carries media
/// authorization, and it must never be used to open the project.  It exists so
/// that an unused copy can be measured and, on explicit user request, removed.
struct SavedWorkshopCopy: Equatable, Sendable {
    let id: String
    let version: String
    /// Allocated bytes of this single version directory.
    let bytes: Int64
    let itemDirectory: URL
    let project: URL
}

/// Decides which locally saved Workshop copies are safe to delete.
///
/// Rules, in order of authority:
///
/// 1. An unknown subscription list means *no* candidates.  A failed or
///    offline Steam lookup must never be read as "you unsubscribed from
///    everything".
/// 2. Any copy referenced by persisted playback state is kept.  The check is
///    deliberately textual: the state blobs are searched for
///    `SavedWorkshop/<id>`, so schema changes in a profile, playlist or
///    display layout can only cost extra retention, never an accidental
///    deletion.
/// 3. Only canonical `SavedWorkshop/<decimal id>/<lowercase uuid>` entries are
///    ever considered, and only ones owned by the current user.
///
/// Deletion is always opt-in: `plan` is pure, and `remove` is the only call
/// that touches the filesystem destructively.
enum SavedWorkshopReclaim {
    enum Failure: Error, CustomStringConvertible {
        case unreadableRoot(String)
        case subscriptionsUnavailable(String)
        case notRemovable(String)

        var description: String {
            switch self {
            case .unreadableRoot(let detail): return "壁纸库目录不可读：" + detail
            case .subscriptionsUnavailable(let detail): return "无法确认订阅状态，未做任何改动：" + detail
            case .notRemovable(let detail): return "拒绝删除：" + detail
            }
        }
    }

    struct Plan: Sendable {
        /// Whole items that are unsubscribed and unreferenced, one entry per id.
        let candidates: [SavedWorkshopCopy]
        /// Kept because Steam still reports an active subscription.
        let keptSubscribed: Int
        /// Kept because persisted state still points at them.
        let keptReferenced: Int

        var bytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
        var isEmpty: Bool { candidates.isEmpty }
    }

    /// Preference keys that can hold a project path.  Callers pass their actual
    /// values to `references(inState:)`; the list is documentation as much as
    /// code, so a new persisted layout only needs adding one key here.
    static let stateKeys = [
        "lastProject",
        "nativeDisplayLayoutV1",
        "nativeSavedProfilesV1",
        "nativeActivePlaylistsV1",
        "nativeSavedPlaylistsV1",
        "nativeApplicationRulesV1",
        "nativeProfileHotkeysV1",
        "nativePlaylistProgressV1",
        "nativePlaylistProgressByTargetV1",
        "libraryFoldersV1",
    ]

    static let root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/WallpaperEngineNative/SavedWorkshop", isDirectory: true)

    // MARK: - Scanning

    /// Enumerates canonical saved copies. Anything that does not match the
    /// exact directory shape is skipped rather than repaired.
    static func scan(root: URL = SavedWorkshopReclaim.root) throws -> [SavedWorkshopCopy] {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw Failure.unreadableRoot(root.path)
        }
        var copies: [SavedWorkshopCopy] = []
        for item in items {
            guard let itemValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  itemValues.isDirectory == true, itemValues.isSymbolicLink != true,
                  isCanonicalID(item.lastPathComponent) else { continue }
            let versions = (try? manager.contentsOfDirectory(at: item, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
            for version in versions {
                guard let versionValues = try? version.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      versionValues.isDirectory == true, versionValues.isSymbolicLink != true,
                      isCanonicalVersion(version.lastPathComponent) else { continue }
                let project = version.appendingPathComponent("Content/project.json")
                guard manager.fileExists(atPath: project.path) else { continue }
                copies.append(SavedWorkshopCopy(id: item.lastPathComponent,
                                                version: version.lastPathComponent,
                                                bytes: allocatedBytes(of: version),
                                                itemDirectory: item,
                                                project: project))
            }
        }
        return copies.sorted { ($0.id, $0.version) < ($1.id, $1.version) }
    }

    private static func isCanonicalID(_ text: String) -> Bool {
        guard let number = UInt64(text), number > 0 else { return false }
        return text == String(number)
    }

    private static func isCanonicalVersion(_ text: String) -> Bool {
        UUID(uuidString: text)?.uuidString.lowercased() == text
    }

    /// Allocated size, not logical size: this is what the disk actually gives
    /// back. Symlinks are counted as their own entry and never followed.
    static func allocatedBytes(of directory: URL) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: directory,
                                                  includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey],
                                                  options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { continue }
            if let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize { total += Int64(size) }
        }
        return total
    }

    // MARK: - Policy

    /// Collects the ids that persisted playback state still points at.
    ///
    /// `state` is the caller's list of raw preference values (strings, data, or
    /// anything JSON-serializable). Substring matching on `SavedWorkshop/<id>`
    /// is intentional: a false positive costs disk space, a false negative
    /// deletes a wallpaper the user still has assigned.
    static func references(inState state: [Any], copies: [SavedWorkshopCopy]) -> Set<String> {
        var blob = Data()
        for value in state {
            if let text = value as? String { blob.append(Data(text.utf8)) }
            else if let data = value as? Data { blob.append(data) }
            else if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) { blob.append(data) }
            blob.append(0x0A)
        }
        guard let text = String(data: blob, encoding: .utf8) else { return [] }
        var referenced: Set<String> = []
        for id in Set(copies.map(\.id)) where text.contains("SavedWorkshop/" + id) {
            referenced.insert(id)
        }
        return referenced
    }

    /// `subscribed` is `nil` when Steam's answer is unknown; that yields no
    /// plan at all, by design.
    static func plan(copies: [SavedWorkshopCopy], subscribed: Set<String>?, references: Set<String>) -> Plan? {
        guard let subscribed else { return nil }
        var latest: [String: SavedWorkshopCopy] = [:]
        var keptSubscribed = 0, keptReferenced = 0
        for copy in copies {
            if subscribed.contains(copy.id) { keptSubscribed += 1; continue }
            if references.contains(copy.id) { keptReferenced += 1; continue }
            // One entry per id: the item directory is removed as a whole, so
            // report its largest version and let `bytes(of:)` sum the rest.
            if let current = latest[copy.id] { if copy.bytes > current.bytes { latest[copy.id] = copy } }
            else { latest[copy.id] = copy }
        }
        let candidates = latest.values.map { copy in
            SavedWorkshopCopy(id: copy.id, version: copy.version,
                              bytes: copies.filter { $0.id == copy.id }.reduce(0) { $0 + $1.bytes },
                              itemDirectory: copy.itemDirectory, project: copy.project)
        }.sorted { $0.id < $1.id }
        return Plan(candidates: candidates, keptSubscribed: keptSubscribed, keptReferenced: keptReferenced)
    }

    // MARK: - Deletion

    /// Removes one whole `SavedWorkshop/<id>` directory after re-checking that
    /// it is still exactly what `scan` described. Returns the bytes freed.
    static func remove(_ copy: SavedWorkshopCopy, root: URL = SavedWorkshopReclaim.root) throws -> Int64 {
        let manager = FileManager.default
        let target = copy.itemDirectory.standardizedFileURL
        let expectedParent = root.standardizedFileURL
        guard target.deletingLastPathComponent() == expectedParent, isCanonicalID(target.lastPathComponent) else {
            throw Failure.notRemovable("目录不在壁纸库根目录下：" + target.path)
        }
        let values: URLResourceValues
        do { values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) }
        catch { throw Failure.notRemovable("无法读取 " + target.path) }
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw Failure.notRemovable("不是普通目录：" + target.path)
        }
        let attributes = try manager.attributesOfItem(atPath: target.path)
        guard let owner = attributes[.ownerAccountID] as? NSNumber, owner.int32Value == geteuid() else {
            throw Failure.notRemovable("目录不属于当前用户：" + target.path)
        }
        // Re-measure right before deleting so the reported number is what this
        // call actually frees, not what a previous scan saw.
        let freed = allocatedBytes(of: target)
        try manager.removeItem(at: target)
        return freed
    }

    // MARK: - Inputs shared by the CLI and the app

    /// Asks the bundled `we-workshop` helper, which talks to the installed
    /// Steam client. Every failure is fatal on purpose: an empty answer must
    /// never be read as "nothing is subscribed any more".
    static func subscribedIDs(helper: URL, timeout: TimeInterval = 120) throws -> Set<String> {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw Failure.subscriptionsUnavailable("找不到 " + helper.path)
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ["subscriptions"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw Failure.subscriptionsUnavailable(error.localizedDescription) }

        // Read on a worker so a silent helper cannot hang the caller forever.
        var data = Data()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw Failure.subscriptionsUnavailable("we-workshop subscriptions 超时")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure.subscriptionsUnavailable("we-workshop 退出码 \(process.terminationStatus)")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else {
            throw Failure.subscriptionsUnavailable("订阅结果缺少 items")
        }
        if let changed = root["account_changed"] as? Bool, changed {
            throw Failure.subscriptionsUnavailable("Steam 账号在查询过程中发生了变化")
        }
        if let account = root["account_id"] as? String, account.isEmpty {
            throw Failure.subscriptionsUnavailable("Steam 未返回账号")
        }
        var subscribed: Set<String> = []
        for item in items {
            guard let id = item["workshop_id"] as? String, item["subscribed"] as? Bool == true else { continue }
            subscribed.insert(id)
        }
        return subscribed
    }

    /// Raw preference values that may point at a saved copy. The app passes
    /// `.standard`; the CLI passes the app's own domain so a dry run there sees
    /// the same state.
    static func preferenceState(defaults: UserDefaults) -> [Any] {
        stateKeys.compactMap { defaults.object(forKey: $0) }
    }
}
