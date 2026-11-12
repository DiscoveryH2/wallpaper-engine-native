import Foundation

enum NativePlaylistLibrary {
    static func key(for project: URL) -> String {
        if let saved = SavedWorkshopStore.recordForProject(project) { return saved.id }
        if SteamLibraryIndex.location(for: project) != nil { return project.deletingLastPathComponent().lastPathComponent }
        if let created = NativeCreationStore.record(for: project) { return "created:" + created.id.uuidString }
        if let bundled = NativeBundledWallpapers.record(for: project) { return "bundled:" + bundled.id }
        return NativeLocalWallpapers.identity(for: project) ?? project.standardizedFileURL.path
    }
    /// Resolve stable identities at selection time, so Workshop updates and
    /// native project saves do not leave a playlist pinned to an old version.
    static func resolve(_ wallpaper: NativePlaylistWallpaper) throws -> URL {
        _ = try wallpaper.validated()
        if let id = wallpaper.workshopID, let current = SavedWorkshopStore.current(id) { return current.project }
        if let id = wallpaper.creationID, let current = NativeCreationStore.records().items.first(where: { $0.id == id }) { return current.project }
        if let id = wallpaper.bundledID, let current = NativeBundledWallpapers.records().items.first(where: { $0.id == id }) { return current.project }
        return URL(fileURLWithPath: wallpaper.projectPath)
    }
}

@MainActor
enum NativePlaylistProgressStore {
    /// Default-display progress remains byte-compatible with the existing V1
    /// record. UUID display targets use `perTargetKey`; session targets never
    /// reach UserDefaults and therefore cannot leak into a later monitor
    /// session with an unrelated identity.
    static let key = "nativePlaylistProgressV1"
    static let perTargetKey = "nativePlaylistProgressByTargetV1"
    struct Record: Codable, Equatable {
        let list: UUID
        let position: NativePlaylistPlayback.Position
    }
    private struct PerTarget: Codable {
        var format = 1
        var records: [String: Record] = [:]
    }
    struct Snapshot {
        fileprivate let defaultRaw: Any?
        fileprivate let perTargetRaw: Any?
        fileprivate let temporary: [String: Record]
    }
    private static var temporary: [String: Record] = [:]

    static func snapshot() -> Snapshot {
        .init(defaultRaw: UserDefaults.standard.object(forKey: key),
              perTargetRaw: UserDefaults.standard.object(forKey: perTargetKey),
              temporary: temporary)
    }

    /// A browser transaction may span a physical disconnect.  Never restore
    /// an old session progress record to a screen whose transient ID has been
    /// recycled; retain any newer runtime record for that ID instead.
    static func restore(_ snapshot: Snapshot, excludingSessionTargets excluded: Set<String> = []) {
        if let value = snapshot.defaultRaw { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        if let value = snapshot.perTargetRaw { UserDefaults.standard.set(value, forKey: perTargetKey) }
        else { UserDefaults.standard.removeObject(forKey: perTargetKey) }
        let currentTemporary = temporary
        temporary = snapshot.temporary.filter { !excluded.contains($0.key) }
        for key in excluded {
            if let current = currentTemporary[key] { temporary[key] = current }
        }
    }

    static func sessionTargetKeys(in snapshot: Snapshot) -> Set<String> {
        Set(snapshot.temporary.keys.filter { $0.hasPrefix("session:") })
    }

    @discardableResult
    static func discardDisconnectedSessionTargets(connectedSessionKeys: Set<String>) -> Set<String> {
        let discarded = Set(temporary.keys.filter {
            $0.hasPrefix("session:") && !connectedSessionKeys.contains($0)
        })
        temporary = temporary.filter { key, _ in
            !key.hasPrefix("session:") || connectedSessionKeys.contains(key)
        }
        return discarded
    }

    /// Compatibility entry point for existing default-playlist callers.
    static func load(for list: NativePlaylist) -> NativePlaylistPlayback.Position {
        load(for: list, target: "default")
    }

    static func load(for list: NativePlaylist, target: String = "default") -> NativePlaylistPlayback.Position {
        guard NativePlaylistStore.validTarget(target) else { return .init() }
        if target == "default" {
            guard let data = UserDefaults.standard.data(forKey: key), data.count <= 1024 * 1024,
                  let record = try? JSONDecoder().decode(Record.self, from: data) else { return .init() }
            return position(record, for: list)
        }
        if target.hasPrefix("session:") { return temporary[target].map { position($0, for: list) } ?? .init() }
        guard let record = validPerTarget()?.records[target] else { return .init() }
        return position(record, for: list)
    }

    /// Compatibility entry point for existing default-playlist callers.
    static func save(_ playback: NativePlaylistPlayback?) {
        save(playback, target: "default")
    }

    static func save(_ playback: NativePlaylistPlayback?, target: String = "default") {
        guard NativePlaylistStore.validTarget(target) else { return }
        let record = playback.flatMap { value -> Record? in
            guard !value.list.entries.isEmpty else { return nil }
            return Record(list: value.list.id, position: value.position)
        }
        if target == "default" {
            guard let record else {
                UserDefaults.standard.removeObject(forKey: key); return
            }
            if let data = try? JSONEncoder().encode(record) { UserDefaults.standard.set(data, forKey: key) }
            return
        }
        if target.hasPrefix("session:") {
            if let record { temporary[target] = record } else { temporary.removeValue(forKey: target) }
            return
        }
        guard var value = validPerTarget() else { return }
        if let record { value.records[target] = record } else { value.records.removeValue(forKey: target) }
        guard !value.records.isEmpty else { UserDefaults.standard.removeObject(forKey: perTargetKey); return }
        guard value.records.count <= 64,
              let data = try? JSONEncoder().encode(value), data.count <= 1024 * 1024 else { return }
        UserDefaults.standard.set(data, forKey: perTargetKey)
    }

    private static func position(_ record: Record, for list: NativePlaylist) -> NativePlaylistPlayback.Position {
        guard record.list == list.id,
              record.position.elapsed.isFinite, (0...31_536_000).contains(record.position.elapsed),
              record.position.remaining.count <= 10_000,
              Set(record.position.remaining).count == record.position.remaining.count else { return .init() }
        return record.position
    }

    /// A single malformed shared record must not let a timer/normal quit on
    /// one screen erase every other screen's saved position. Missing data is
    /// an empty archive; unreadable existing data remains untouched.
    private static func validPerTarget() -> PerTarget? {
        guard let object = UserDefaults.standard.object(forKey: perTargetKey) else { return PerTarget() }
        guard let data = object as? Data, data.count <= 1024 * 1024,
              let value = try? JSONDecoder().decode(PerTarget.self, from: data),
              value.format == 1, value.records.count <= 64,
              value.records.keys.allSatisfy({ isPersistentDisplayTarget($0) }) else { return nil }
        return value
    }

    private static func isPersistentDisplayTarget(_ target: String) -> Bool {
        target.hasPrefix("uuid:") && UUID(uuidString: String(target.dropFirst(5))) != nil
    }
}
