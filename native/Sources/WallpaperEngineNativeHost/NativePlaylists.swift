import Foundation

enum NativePlaylistMode: String, Codable, CaseIterable, Sendable {
    case logon, timer, daytime, dayofweek, never
    var title: String {
        switch self {
        case .logon: return "登录时"
        case .timer: return "计时器上"
        case .daytime: return "当日时间"
        case .dayofweek: return "星期"
        case .never: return "从不"
        }
    }
}

struct NativePlaylistSettings: Codable, Equatable, Sendable {
    var mode: NativePlaylistMode = .timer
    var random = true
    /// The official UI stores delay in minutes, including fractional minutes.
    var delay: Double = 60
    var transition = "0"
    var transitionMilliseconds: Double = 1500
    var videoSequence = false
    var updateOnPause = false
    var beginFirst = false
    var playIntro = false
    var weekdayOffset = 0

    func validated() throws -> Self {
        guard delay.isFinite, delay >= 0, delay <= 525_600,
              transitionMilliseconds.isFinite, (0...3000).contains(transitionMilliseconds),
              (0...6).contains(weekdayOffset),
              ["none", "-2", "random"].contains(transition) || Int(transition).map({ (0...26).contains($0) }) == true else {
            throw NativePlaylistError.invalid("播放列表设置无效。")
        }
        return self
    }
}

enum NativePlaylistError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
}

struct NativePlaylistWallpaper: Codable, Equatable, Sendable {
    let key: String
    var projectPath: String
    var title: String
    var type: String
    var workshopID: String?
    var creationID: UUID?
    var bundledID: String?

    func validated() throws -> Self {
        guard !key.isEmpty, key.utf8.count <= 8192, !key.contains("\0"),
              projectPath.hasPrefix("/"), projectPath.utf8.count <= 4096, !projectPath.contains("\0"),
              URL(fileURLWithPath: projectPath).standardizedFileURL.path == projectPath,
              URL(fileURLWithPath: projectPath).lastPathComponent == "project.json",
              !title.isEmpty, title.utf8.count <= 4096, !title.contains("\0"),
              ["scene", "web", "video", "image"].contains(type),
              workshopID.map({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && (UInt64($0) ?? 0) > 0 }) ?? true,
              bundledID.map({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") }) ?? true else {
            throw NativePlaylistError.invalid("播放列表中的壁纸记录无效。")
        }
        return self
    }
}

struct NativePlaylistEntry: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var wallpaper: NativePlaylistWallpaper
    var daytimeEnd: Double?
    var preset: String?
}

struct NativePlaylist: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var settings = NativePlaylistSettings()
    var entries: [NativePlaylistEntry] = []

    func validated() throws -> Self {
        _ = try settings.validated()
        guard name.utf8.count <= 1024, !name.contains("\0"), entries.count <= 10_000,
              Set(entries.map(\.id)).count == entries.count,
              settings.mode != .dayofweek || entries.count <= 7 else {
            throw NativePlaylistError.invalid("播放列表超过支持范围；星期模式最多接受 7 张壁纸。")
        }
        for entry in entries {
            _ = try entry.wallpaper.validated()
            guard entry.daytimeEnd.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                  entry.preset.map({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") }) ?? true else {
                throw NativePlaylistError.invalid("播放列表时间点或预设无效。")
            }
        }
        return self
    }

    /// Match the browser's normalization before selectPlaylist: the final item
    /// ends at midnight; out-of-order bounds and bounds in other modes vanish.
    mutating func normalize() {
        guard !entries.isEmpty else { return }
        entries[entries.count - 1].daytimeEnd = nil
        var last: Double = 0
        for index in entries.indices {
            guard let end = entries[index].daytimeEnd else { continue }
            if settings.mode != .daytime || !end.isFinite || !(0...1).contains(end) || end < last {
                entries[index].daytimeEnd = nil
            } else { last = end }
        }
    }

    @discardableResult
    mutating func toggle(_ wallpapers: [NativePlaylistWallpaper], forceAdd: Bool = false) throws -> Bool {
        guard let clicked = wallpapers.first else { return false }
        let adding = forceAdd || !entries.contains { $0.wallpaper.key == clicked.key }
        var candidate = self
        var limited = false
        if adding {
            for wallpaper in wallpapers where forceAdd || !candidate.entries.contains(where: { $0.wallpaper.key == wallpaper.key }) {
                guard candidate.entries.count < 10_000,
                      candidate.settings.mode != .dayofweek || candidate.entries.count < 7 else {
                    limited = true; continue
                }
                candidate.entries.append(NativePlaylistEntry(wallpaper: wallpaper))
            }
        } else {
            let keys = Set(wallpapers.map(\.key))
            candidate.entries.removeAll { keys.contains($0.wallpaper.key) }
        }
        candidate.normalize(); self = try candidate.validated(); return limited
    }

    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id }; normalize() }
    mutating func move(_ id: UUID, before destination: UUID?) {
        guard let source = entries.firstIndex(where: { $0.id == id }), id != destination else { return }
        if let destination, !entries.contains(where: { $0.id == destination }) { return }
        let value = entries.remove(at: source)
        let index = destination.flatMap { next in entries.firstIndex { $0.id == next } } ?? entries.count
        entries.insert(value, at: index); normalize()
    }

    /// Every explicit boundary partitions the items since the previous boundary
    /// equally. The last partition ends at 1 even without an explicit marker.
    var daytimeRanges: [Range<Double>] {
        var normalized = self; normalized.normalize()
        let entries = normalized.entries
        var result = Array(repeating: 0.0..<0.0, count: entries.count)
        var first = 0, start: Double = 0
        for index in entries.indices {
            guard let end = entries[index].daytimeEnd ?? (index == entries.count - 1 ? 1 : nil) else { continue }
            let width = (end - start) / Double(index - first + 1)
            for item in first...index {
                let lower = start + Double(item - first) * width
                result[item] = lower..<(item == index ? end : lower + width)
            }
            first = index + 1; start = end
        }
        return result
    }

    var weekdayRanges: [Range<Int>] {
        let count = min(7, entries.count)
        guard count > 0 else { return [] }
        var remaining = 7, first = 0
        return (0..<count).map { index in
            let days = remaining / (count - index)
            defer { first += days; remaining -= days }
            return first..<(first + days)
        }
    }

    func weekdayLabel(_ index: Int, names: [String] = ["星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日"]) -> String {
        let ranges = weekdayRanges
        guard names.count == 7, ranges.indices.contains(index) else { return "" }
        let range = ranges[index]
        let first = names[(range.lowerBound + settings.weekdayOffset) % 7]
        return range.count == 1 ? first : first + " - " + names[(range.upperBound - 1 + settings.weekdayOffset) % 7]
    }

    func scheduledIndex(at date: Date, calendar: Calendar = .current) -> Int? {
        guard !entries.isEmpty else { return nil }
        switch settings.mode {
        case .daytime:
            // wallpaper64's scheduler samples hour/minute, not seconds.
            let components = calendar.dateComponents([.hour, .minute], from: date)
            let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            let fraction = Double(minutes) / 1440
            return daytimeRanges.firstIndex { $0.contains(fraction) } ?? entries.indices.last
        case .dayofweek:
            let mondayDay = (calendar.component(.weekday, from: date) + 5) % 7
            let relativeDay = (mondayDay - settings.weekdayOffset + 7) % 7
            return weekdayRanges.firstIndex { $0.contains(relativeDay) }
        default: return nil
        }
    }
}

@MainActor
enum NativePlaylistStore {
    static let activeKey = "nativeActivePlaylistsV1"
    static let savedKey = "nativeSavedPlaylistsV1"
    /// Ephemeral displays do not have a stable cross-launch identity. Keep
    /// their active schedules in memory, then merge them into runtime reads
    /// without ever serialising a `session:` target to the V1 active store.
    private static var temporary: [String: NativePlaylist] = [:]
    struct Active: Codable, Equatable {
        var format = 1
        var lists: [String: NativePlaylist] = [:]
    }
    struct Snapshot {
        fileprivate let persistent: Any?
        fileprivate let temporary: [String: NativePlaylist]
    }
    struct Saved: Codable, Equatable {
        var format = 1
        var lists: [NativePlaylist] = []
    }
    static func validTarget(_ key: String) -> Bool {
        key == "default" ||
            (key.hasPrefix("uuid:") && UUID(uuidString: String(key.dropFirst(5))) != nil) ||
            (key.hasPrefix("session:") && (UInt32(key.dropFirst(8)) ?? 0) > 0)
    }
    static func persistentTarget(_ key: String) -> Bool {
        key == "default" || (key.hasPrefix("uuid:") && UUID(uuidString: String(key.dropFirst(5))) != nil)
    }
    static func snapshot() -> Snapshot {
        .init(persistent: UserDefaults.standard.object(forKey: activeKey), temporary: temporary)
    }
    /// Restore persistent schedules and only those session overlays that have
    /// not crossed a disconnect boundary.  An excluded overlay belongs to a
    /// former display-ID generation, so retain any live replacement instead.
    static func restore(_ snapshot: Snapshot, excludingSessionTargets excluded: Set<String> = []) {
        if let value = snapshot.persistent { UserDefaults.standard.set(value, forKey: activeKey) }
        else { UserDefaults.standard.removeObject(forKey: activeKey) }
        let currentTemporary = temporary
        temporary = snapshot.temporary.filter { !excluded.contains($0.key) }
        for key in excluded {
            if let current = currentTemporary[key] { temporary[key] = current }
        }
    }
    static func sessionTargetKeys(in snapshot: Snapshot) -> Set<String> {
        Set(snapshot.temporary.keys.filter { $0.hasPrefix("session:") })
    }
    /// Clears only volatile schedules for disappeared session displays.  The
    /// return set is shared with the display/progress cleanup path so callers
    /// can invalidate related controller contexts in one transaction.
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
    static func active() throws -> Active {
        let stored: Active = try load(activeKey) ?? Active()
        // Pre-0.215 payloads may contain a now-invalid persisted session key.
        // Ignore it on read rather than routing a schedule to a fresh session;
        // a later explicit write canonicalises the persistent subset.
        var persistent = stored
        persistent.lists = stored.lists.filter { persistentTarget($0.key) }
        var value = try validateActive(persistent)
        value.lists.merge(temporary) { _, current in current }
        return try validateActive(value)
    }
    private static func validateActive(_ value: Active) throws -> Active {
        guard value.format == 1, value.lists.count <= 64, value.lists.keys.allSatisfy(validTarget) else { throw NativePlaylistError.invalid("当前播放列表记录无效。") }
        for list in value.lists.values { _ = try list.validated() }
        return value
    }
    static func replaceActive(_ value: Active) throws {
        let valid = try validateActive(value)
        var persistent = valid
        persistent.lists = valid.lists.filter { persistentTarget($0.key) }
        let nextTemporary = valid.lists.filter { $0.key.hasPrefix("session:") }
        try save(persistent, key: activeKey)
        temporary = nextTemporary
    }
    /// Replaces only persistent default/UUID schedules, retaining the current
    /// runtime session overlays which a portable profile is not allowed to
    /// name or serialise.
    static func replacePersistent(_ value: Active) throws {
        guard value.lists.keys.allSatisfy(persistentTarget) else {
            throw NativePlaylistError.invalid("配置文件不能保存临时显示器播放列表。")
        }
        try save(validateActive(value), key: activeKey)
    }
    static func saved() throws -> Saved {
        let value: Saved = try load(savedKey) ?? Saved()
        guard value.format == 1, value.lists.count <= 1000,
              Set(value.lists.map(\.name)).count == value.lists.count,
              value.lists.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NativePlaylistError.invalid("保存的播放列表记录无效。")
        }
        for list in value.lists { _ = try list.validated() }
        return value
    }
    static func setActive(_ list: NativePlaylist, target: String) throws {
        guard validTarget(target) else { throw NativePlaylistError.invalid("播放列表显示器无效。") }
        var value = try active()
        if list.entries.isEmpty { value.lists.removeValue(forKey: target) }
        else { value.lists[target] = try list.validated() }
        // Keep session targets in the in-memory overlay.  Writing `value`
        // directly would serialise a session key and could later route its
        // schedule to an unrelated reconnected display.
        try replaceActive(value)
    }
    static func saveNamed(_ list: NativePlaylist, name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NativePlaylistError.invalid("请输入播放列表名称。") }
        var list = list; list.name = name; _ = try list.validated()
        guard list.entries.count >= 2 else { throw NativePlaylistError.invalid("至少添加两张壁纸后才能保存播放列表。") }
        var value = try saved()
        if let index = value.lists.firstIndex(where: { $0.name == name }) { value.lists[index] = list }
        else {
            guard value.lists.count < 1000 else { throw NativePlaylistError.invalid("保存的播放列表已达到大小上限。") }
            value.lists.append(list)
        }
        try save(value, key: savedKey)
    }
    static func removeNamed(_ name: String) throws {
        var value = try saved(); value.lists.removeAll { $0.name == name }; try save(value, key: savedKey)
    }
    private static func load<T: Decodable>(_ key: String) throws -> T? {
        guard let object = UserDefaults.standard.object(forKey: key) else { return nil }
        guard let data = object as? Data, data.count <= 4 * 1024 * 1024 else { throw NativePlaylistError.invalid("播放列表数据超出大小上限。") }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw NativePlaylistError.invalid("无法读取播放列表，原记录已保留。") }
    }
    private static func save<T: Encodable>(_ value: T, key: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 4 * 1024 * 1024 else { throw NativePlaylistError.invalid("播放列表数据超出大小上限。") }
        UserDefaults.standard.set(data, forKey: key)
    }
}
