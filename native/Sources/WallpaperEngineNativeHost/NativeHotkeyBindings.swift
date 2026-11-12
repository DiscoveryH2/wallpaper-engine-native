import Foundation

/// The fixed ordering mirrors Wallpaper Engine's Hotkeys settings page.  A
/// row may be visible before the native host implements its effect; binding it
/// remains a settings operation, while the host dispatch layer reports an
/// unsupported action instead of pretending that it happened.
enum NativeHotkeySystemAction: String, Codable, CaseIterable, Hashable, Sendable {
    case pause, stop, mute, nextWallpaper
    case toggleRecord, toggleIcons, screenshot, screensaver
    case windowBrowser, windowSettings, windowEditor

    enum Group: Int, CaseIterable, Sendable { case playback, general, windows }
    var group: Group {
        switch self {
        case .pause, .stop, .mute, .nextWallpaper: return .playback
        case .toggleRecord, .toggleIcons, .screenshot, .screensaver: return .general
        case .windowBrowser, .windowSettings, .windowEditor: return .windows
        }
    }
    var title: String {
        switch self {
        case .pause: return "暂停壁纸"
        case .stop: return "停止壁纸"
        case .mute: return "使壁纸静音"
        case .nextWallpaper: return "下一张壁纸"
        case .toggleRecord: return "切换录音"
        case .toggleIcons: return "隐藏桌面图标"
        case .screenshot: return "截屏"
        case .screensaver: return "启动屏幕保护程序"
        case .windowBrowser: return "浏览壁纸"
        case .windowSettings: return "设置"
        case .windowEditor: return "编辑器"
        }
    }
    var groupTitle: String {
        switch group {
        case .playback: return "回放"
        case .general: return "常规"
        case .windows: return "Windows"
        }
    }
}

/// A portable, displayable target for a single wallpaper action.  `projectPath`
/// is deliberately the identity (as in the official action's `value=file`),
/// rather than a volatile UI list index. `title` and `location` only enrich
/// display/selection and do not cause an unrelated item to be activated.
struct NativeHotkeyWallpaperTarget: Codable, Hashable, Sendable {
    var projectPath: String
    var title: String
    var location: String?

    /// A wallpaper hotkey follows the official target identity: stable file
    /// value plus optional monitor location.  The title is only presentation
    /// data and commonly changes when a Workshop item is renamed; including
    /// it here would orphan the old assignment or create duplicate owners.
    /// Store entry points call `validated()` before comparing/persisting, so
    /// the path side of this identity is standardized as well.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.projectPath == rhs.projectPath && lhs.location == rhs.location
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(projectPath)
        hasher.combine(location)
    }

    func validated() throws -> Self {
        let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.contains("\0"),
              title.utf8.count <= 1_024, !title.contains("\0"),
              location.map({ !$0.contains("\0") && $0.utf8.count <= 1_024 }) ?? true else {
            throw NativeHotkeyBindingError.invalidTarget
        }
        var copy = self; copy.projectPath = URL(fileURLWithPath: path).standardizedFileURL.path
        copy.title = copy.title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.location = copy.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.location?.isEmpty == true || copy.location == "default" { copy.location = nil }
        return copy
    }
}

/// Profile bindings intentionally remain in `nativeProfileHotkeysV1` for
/// 0.213 compatibility. Other settings live in the V2 pool below; runtime
/// registration sees one combined collision domain.
enum NativeHotkeyTarget: Codable, Hashable, Sendable {
    case system(NativeHotkeySystemAction)
    case profile(name: String)
    case wallpaper(NativeHotkeyWallpaperTarget)
    case playlist(name: String, location: String?)

    var isUserAction: Bool {
        switch self { case .system: return false; case .profile, .wallpaper, .playlist: return true }
    }
    var title: String {
        switch self {
        case .system(let action): return action.title
        case .profile(let name): return "配置文件：\(name)"
        case .wallpaper(let wallpaper): return wallpaper.title.isEmpty ? wallpaper.projectPath : wallpaper.title
        case .playlist(let name, _): return "播放列表：\(name)"
        }
    }

    func validatedSyntax() throws -> Self {
        switch self {
        case .system: return self
        case .profile(let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 1_024, !name.contains("\0") else {
                throw NativeHotkeyBindingError.invalidTarget
            }
            return self
        case .wallpaper(let wallpaper): return .wallpaper(try wallpaper.validated())
        case .playlist(let rawName, let rawLocation):
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let location = rawLocation?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.utf8.count <= 1_024, !name.contains("\0"),
                  location.map({ !$0.utf8.isEmpty && $0.utf8.count <= 1_024 && !$0.contains("\0") }) ?? true else {
                throw NativeHotkeyBindingError.invalidTarget
            }
            return .playlist(name: name, location: location?.isEmpty == true || location == "default" ? nil : location)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, action, name, wallpaper, location }
    private enum Kind: String, Codable { case system, profile, wallpaper, playlist }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .system: self = .system(try values.decode(NativeHotkeySystemAction.self, forKey: .action))
        case .profile: self = .profile(name: try values.decode(String.self, forKey: .name))
        case .wallpaper: self = .wallpaper(try values.decode(NativeHotkeyWallpaperTarget.self, forKey: .wallpaper))
        case .playlist: self = .playlist(name: try values.decode(String.self, forKey: .name), location: try values.decodeIfPresent(String.self, forKey: .location))
        }
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .system(let action): try values.encode(Kind.system, forKey: .kind); try values.encode(action, forKey: .action)
        case .profile(let name): try values.encode(Kind.profile, forKey: .kind); try values.encode(name, forKey: .name)
        case .wallpaper(let wallpaper): try values.encode(Kind.wallpaper, forKey: .kind); try values.encode(wallpaper, forKey: .wallpaper)
        case .playlist(let name, let location):
            try values.encode(Kind.playlist, forKey: .kind); try values.encode(name, forKey: .name); try values.encodeIfPresent(location, forKey: .location)
        }
    }
}

struct NativeHotkeyBinding: Codable, Equatable, Hashable, Sendable {
    var target: NativeHotkeyTarget
    /// Nil is meaningful for fixed rows and for a user row while the settings
    /// sheet remains open. `pruneEmptyUserActions()` removes the latter only
    /// on close, matching the observed shared-array behaviour.
    var hotkey: NativeHotkey?
}

enum NativeHotkeyBindingError: LocalizedError, Equatable {
    case invalidTarget
    case unreadable
    case conflict(NativeHotkeyTarget)

    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "热键目标无效，原记录已保留。"
        case .unreadable: return "无法读取热键设置，原记录已保留。"
        case .conflict(let target): return "该热键已分配给“\(target.title)”。"
        }
    }
}

/// V2 owns fixed actions plus wallpaper/playlist actions. Profiles continue
/// to be persisted in their 0.213 V1 store and are merged at read time.
@MainActor
enum NativeHotkeyBindingStore {
    static let key = "nativeHotkeyBindingsV2"
    struct Saved: Codable, Equatable, Sendable {
        var format = 1
        var bindings: [NativeHotkeyBinding] = []
    }
    struct PreferenceSnapshot {
        fileprivate let rawV1: Any?
        fileprivate let rawV2: Any?
        fileprivate let profileCatalog: Any?
        fileprivate let playlistCatalog: Any?
    }

    private static func rawSaved() throws -> Saved {
        guard let object = UserDefaults.standard.object(forKey: key) else { return Saved() }
        guard let data = object as? Data, data.count <= 1_048_576,
              let value = try? JSONDecoder().decode(Saved.self, from: data),
              value.format == 1, value.bindings.count <= 1_000 else {
            throw NativeHotkeyBindingError.unreadable
        }
        return value
    }
    private static func encode(_ value: Saved) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 1_048_576 else { throw NativeHotkeyBindingError.unreadable }
        return data
    }
    private static func write(_ value: Saved) throws { UserDefaults.standard.set(try encode(value), forKey: key) }

    static func preferenceSnapshot() -> PreferenceSnapshot {
        .init(rawV1: UserDefaults.standard.object(forKey: NativeProfileHotkeyStore.key), rawV2: UserDefaults.standard.object(forKey: key),
              profileCatalog: UserDefaults.standard.object(forKey: NativeProfileStore.savedKey), playlistCatalog: UserDefaults.standard.object(forKey: NativePlaylistStore.savedKey))
    }
    /// Test-fixture-only raw preference restoration. The reference Hotkeys
    /// panel writes live and its enclosing Settings cancellation does not roll
    /// edits back, so production Settings must never call this method. Any
    /// isolated test that does use it must pair it with `service.sync(force:)`.
    static func restore(_ snapshot: PreferenceSnapshot) {
        let values: [(String, Any?)] = [(NativeProfileHotkeyStore.key, snapshot.rawV1), (key, snapshot.rawV2),
                                        (NativeProfileStore.savedKey, snapshot.profileCatalog), (NativePlaylistStore.savedKey, snapshot.playlistCatalog)]
        for (name, value) in values { if let value { UserDefaults.standard.set(value, forKey: name) } else { UserDefaults.standard.removeObject(forKey: name) } }
    }

    /// Fixed rows retain an empty record; legacy profile rows are projected
    /// from V1. Dynamic V2 rows include a nil hotkey until panel-close pruning.
    static func snapshot() throws -> [NativeHotkeyBinding] {
        let saved = try validatedV2(rawSaved())
        var indexed = Dictionary(uniqueKeysWithValues: saved.bindings.map { ($0.target, $0) })
        var result = NativeHotkeySystemAction.allCases.map { action in
            indexed.removeValue(forKey: .system(action)) ?? .init(target: .system(action), hotkey: nil)
        }
        result.append(contentsOf: try NativeProfileHotkeyStore.bindings().map { .init(target: .profile(name: $0.profileName), hotkey: $0.hotkey) })
        // The official user-action section is the persisted shared-array
        // order, not an alphabetized browser view. `validatedV2` guarantees
        // target uniqueness, so preserving `Saved.bindings` is unambiguous.
        result.append(contentsOf: saved.bindings.filter { $0.target.isUserAction })
        // Individual V1/V2 payloads may each be well-formed while claiming
        // the same active chord across stores. Settings must fail closed in
        // that state too: treating a visible row as safely unbound would let
        // an edit overwrite one arbitrary owner. `activeBindings()` excludes
        // intentionally inert missing-playlist rows, which remain visible in
        // this snapshot and may legally reuse a live chord until restored.
        _ = try activeBindings()
        return result
    }

    /// Reads the projected row without hiding malformed preferences as an
    /// unbound target.  UI callers should surface `unreadable`, not silently
    /// offer a destructive replacement based on an invented empty state.
    static func binding(for target: NativeHotkeyTarget) throws -> NativeHotkeyBinding? {
        let target = try target.validatedSyntax()
        return try snapshot().first { $0.target == target }
    }

    /// Only currently valid, nonempty V2 entries join the Carbon pool. Missing
    /// named playlists stay preserved but inert, just like dangling V1 profile
    /// records. A profile target in V2 is corrupt because V1 owns profiles.
    static func activeBindings(profiles: [NativeWallpaperProfile]? = nil, playlists: [NativePlaylist]? = nil) throws -> [NativeHotkeyBinding] {
        let profileSource: [NativeWallpaperProfile]
        if let profiles { profileSource = profiles } else { profileSource = try NativeProfileStore.saved().profiles }
        let playlistSource: [NativePlaylist]
        if let playlists { playlistSource = playlists } else { playlistSource = try NativePlaylistStore.saved().lists }
        let legacy = try NativeProfileHotkeyStore.bindings(profiles: profileSource).map { NativeHotkeyBinding(target: .profile(name: $0.profileName), hotkey: $0.hotkey) }
        var active = legacy
        active.append(contentsOf: try activeV2Bindings(playlists: playlistSource))
        try validatePool(active)
        return active
    }

    /// Used by a legacy `.keep` profile save before it makes a formerly
    /// dangling V1 record live. V2 is inspected by itself so malformed V2
    /// bytes can retain the old ordinary-save compatibility path, while a
    /// valid V2 owner is still reported before the catalog mutation.
    static func activeV2Conflict(for hotkey: NativeHotkey,
                                 playlists: [NativePlaylist]? = nil) throws -> NativeHotkeyBinding? {
        let source: [NativePlaylist]
        if let playlists { source = playlists } else { source = try NativePlaylistStore.saved().lists }
        return try activeV2Bindings(playlists: source).first { $0.hotkey == hotkey }
    }

    static func conflict(for hotkey: NativeHotkey, excluding target: NativeHotkeyTarget? = nil) throws -> NativeHotkeyBinding? {
        try activeBindings().first { $0.hotkey == hotkey && $0.target != target }
    }

    /// Assigns an existing target live. UI must resolve conflicts first, then
    /// pass `overwrite: true` only after the overwrite sheet is accepted.
    static func replace(_ target: NativeHotkeyTarget, hotkey: NativeHotkey?, overwrite: Bool = false,
                        hotkeyService: NativeProfileHotkeyService? = nil) throws {
        let target = try target.validatedSyntax()
        let service = hotkeyService ?? NativeProfileHotkeyService.shared
        if case .profile(let name) = target {
            if let hotkey, let conflict = try conflict(for: hotkey, excluding: target), !overwrite {
                throw NativeHotkeyBindingError.conflict(conflict.target)
            }
            if overwrite, let hotkey, let conflict = try conflict(for: hotkey, excluding: target) {
                try removeBinding(conflict.target, hotkeyService: service)
            }
            try NativeProfileHotkeyStore.replaceBinding(for: name, with: hotkey, removeConflictingBindings: false, hotkeyService: service)
            return
        }
        var saved = try validatedV2(rawSaved())
        if let hotkey, let conflict = try conflict(for: hotkey, excluding: target) {
            guard overwrite else { throw NativeHotkeyBindingError.conflict(conflict.target) }
            try removeBinding(conflict.target, hotkeyService: service)
            saved = try validatedV2(rawSaved())
        }
        let reservation = try hotkey.map { try service.reserveAvailable($0, for: target) }
        do {
            saved.bindings.removeAll { $0.target == target }
            saved.bindings.append(.init(target: target, hotkey: hotkey))
            _ = try validatedV2(saved)
            try write(saved)
            if let reservation { reservation.commit() } else { try? service.sync() }
        } catch {
            reservation?.cancel(); throw error
        }
    }

    static func clear(_ target: NativeHotkeyTarget, hotkeyService: NativeProfileHotkeyService? = nil) throws {
        try replace(target, hotkey: nil, hotkeyService: hotkeyService)
    }

    /// An alias for a normal live settings edit.  A nil chord is a visible
    /// cleared state: fixed actions keep their empty row and user actions are
    /// pruned only when Settings closes.
    static func assign(_ target: NativeHotkeyTarget, hotkey: NativeHotkey?,
                       hotkeyService: NativeProfileHotkeyService? = nil) throws {
        try replace(target, hotkey: hotkey, hotkeyService: hotkeyService)
    }

    /// Removes an existing owner immediately.  This is deliberately distinct
    /// from `clear`: a deferred Profile Save which accepts an overwrite must
    /// revoke the old V1/V2 dynamic owner even if the new Save is later
    /// cancelled.  Fixed system actions have a durable empty row instead.
    static func removeBinding(_ target: NativeHotkeyTarget,
                              hotkeyService: NativeProfileHotkeyService? = nil) throws {
        let target = try target.validatedSyntax()
        let service = hotkeyService ?? NativeProfileHotkeyService.shared
        switch target {
        case .profile(let name):
            try NativeProfileHotkeyStore.replaceBinding(for: name, with: nil, hotkeyService: service)
        case .system:
            try replace(target, hotkey: nil, hotkeyService: service)
        case .wallpaper, .playlist:
            var saved = try validatedV2(rawSaved())
            saved.bindings.removeAll { $0.target == target }
            try write(saved)
            try? service.sync()
        }
    }

    static func pruneEmptyUserActions(hotkeyService: NativeProfileHotkeyService? = nil) throws {
        let service = hotkeyService ?? NativeProfileHotkeyService.shared
        var saved = try validatedV2(rawSaved())
        saved.bindings.removeAll { $0.target.isUserAction && $0.hotkey == nil }
        try write(saved); try? service.sync()
    }

    private static func validatedV2(_ saved: Saved) throws -> Saved {
        guard saved.format == 1, saved.bindings.count <= 1_000 else { throw NativeHotkeyBindingError.unreadable }
        var targets = Set<NativeHotkeyTarget>(), chords = Set<NativeHotkey>()
        var result = saved
        for index in result.bindings.indices {
            let target = try result.bindings[index].target.validatedSyntax()
            guard !matchesLegacyProfile(target), targets.insert(target).inserted else { throw NativeHotkeyBindingError.unreadable }
            result.bindings[index].target = target
            if let hotkey = result.bindings[index].hotkey {
                guard (try? NativeHotkey(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)) != nil,
                      chords.insert(hotkey).inserted else { throw NativeHotkeyBindingError.unreadable }
            }
        }
        return result
    }

    private static func matchesLegacyProfile(_ target: NativeHotkeyTarget) -> Bool {
        if case .profile = target { return true }; return false
    }
    private static func activeV2Bindings(playlists: [NativePlaylist]) throws -> [NativeHotkeyBinding] {
        let saved = try validatedV2(rawSaved())
        let names = Set(playlists.map(\.name))
        var active: [NativeHotkeyBinding] = []
        for binding in saved.bindings {
            guard let hotkey = binding.hotkey else { continue }
            switch binding.target {
            case .profile: throw NativeHotkeyBindingError.unreadable
            case .playlist(let name, _): guard names.contains(name) else { continue }
            case .system, .wallpaper: break
            }
            active.append(.init(target: binding.target, hotkey: hotkey))
        }
        return active
    }
    private static func validatePool(_ bindings: [NativeHotkeyBinding]) throws {
        var targets = Set<NativeHotkeyTarget>(), chords = Set<NativeHotkey>()
        for binding in bindings {
            guard let hotkey = binding.hotkey, targets.insert(binding.target).inserted, chords.insert(hotkey).inserted else {
                throw NativeHotkeyBindingError.unreadable
            }
        }
    }
}
