import Foundation

/// A native representation of the desktop selection captured by the official
/// profiles dialog. Global performance settings and per-project author settings
/// remain separate, as they are in the reference wallpaper configuration.
struct NativeWallpaperProfile: Codable, Equatable, Sendable {
    var format = 1
    var name = ""
    var wallpaper: NativePlaylistWallpaper
    var layout: NativeDisplayLayout
    /// The legacy `playlist` remains the default-display schedule. UUID-keyed
    /// schedules are optional on disk so profiles written before 0.215 decode
    /// unchanged; session display targets are intentionally never accepted.
    var playlist: NativePlaylist?
    var displayPlaylists: [String: NativePlaylist] = [:]

    init(format: Int = 1, name: String = "", wallpaper: NativePlaylistWallpaper,
         layout: NativeDisplayLayout, playlist: NativePlaylist? = nil,
         displayPlaylists: [String: NativePlaylist] = [:]) {
        self.format = format; self.name = name; self.wallpaper = wallpaper; self.layout = layout
        self.playlist = playlist; self.displayPlaylists = displayPlaylists
    }

    private enum CodingKeys: String, CodingKey { case format, name, wallpaper, layout, playlist, displayPlaylists }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(Int.self, forKey: .format)
        name = try values.decode(String.self, forKey: .name)
        wallpaper = try values.decode(NativePlaylistWallpaper.self, forKey: .wallpaper)
        layout = try values.decode(NativeDisplayLayout.self, forKey: .layout)
        playlist = try values.decodeIfPresent(NativePlaylist.self, forKey: .playlist)
        displayPlaylists = try values.decodeIfPresent([String: NativePlaylist].self, forKey: .displayPlaylists) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(format, forKey: .format)
        try values.encode(name, forKey: .name)
        try values.encode(wallpaper, forKey: .wallpaper)
        try values.encode(layout, forKey: .layout)
        try values.encodeIfPresent(playlist, forKey: .playlist)
        if !displayPlaylists.isEmpty { try values.encode(displayPlaylists, forKey: .displayPlaylists) }
    }

    var persistentPlaylists: [String: NativePlaylist] {
        var result = displayPlaylists
        if let playlist { result["default"] = playlist }
        return result
    }

    func validated() throws -> Self {
        guard format == 1, name.utf8.count <= 1024, !name.contains("\0") else {
            throw NativePlaylistError.invalid("配置文件格式或名称无效。")
        }
        _ = try wallpaper.validated(); _ = try layout.validated()
        if let playlist {
            _ = try playlist.validated()
            guard playlist.entries.count > 1 else { throw NativePlaylistError.invalid("配置文件中的播放列表至少需要两张壁纸。") }
        }
        guard displayPlaylists.count <= 64 else { throw NativePlaylistError.invalid("配置文件中的独立显示器播放列表过多。") }
        for (target, playlist) in displayPlaylists {
            guard Self.persistentDisplayTarget(target) else {
                throw NativePlaylistError.invalid("配置文件不能保存临时显示器播放列表。")
            }
            _ = try playlist.validated()
            guard playlist.entries.count > 1 else { throw NativePlaylistError.invalid("配置文件中的独立显示器播放列表至少需要两张壁纸。") }
        }
        return self
    }

    private static func persistentDisplayTarget(_ target: String) -> Bool {
        target.hasPrefix("uuid:") && UUID(uuidString: String(target.dropFirst(5))) != nil
    }
}

/// A capture-safe view of the active schedules. Session targets are excluded
/// because their identity is only meaningful until the current display
/// connection ends; the default schedule stays in its legacy profile field.
struct NativeProfilePlaylists: Equatable, Sendable {
    var playlist: NativePlaylist?
    var displayPlaylists: [String: NativePlaylist]
}

enum NativeProfileLibrary {
    private static func retain(_ url: URL) throws -> URL {
        if SteamLibraryIndex.location(for: url) != nil {
            return try SavedWorkshopStore.save(project: url, id: url.deletingLastPathComponent().lastPathComponent).project
        }
        return url.standardizedFileURL
    }
    static func capture(project: URL, layout: NativeDisplayLayout, playlist: NativePlaylist?,
                        displayPlaylists: [String: NativePlaylist] = [:]) throws -> NativeWallpaperProfile {
        try validatePersistentLayout(layout)
        guard displayPlaylists.keys.allSatisfy(persistentDisplayTarget) else {
            throw NativePlaylistError.invalid("临时显示器播放列表不能保存为配置文件。")
        }
        let url = try retain(project)
        let metadata = try WallpaperProject.load(from: url)
        let wallpaper = NativePlaylistWallpaper(key: NativePlaylistLibrary.key(for: url), projectPath: url.path,
            title: metadata.title, type: metadata.kind.rawValue,
            workshopID: SavedWorkshopStore.recordForProject(url)?.id,
            creationID: NativeCreationStore.record(for: url)?.id,
            bundledID: NativeBundledWallpapers.record(for: url)?.id)
        var result = NativeWallpaperProfile(wallpaper: wallpaper, layout: layout,
            playlist: (playlist?.entries.count ?? 0) > 1 ? playlist : nil,
            displayPlaylists: displayPlaylists.filter { $0.value.entries.count > 1 })
        result.layout = try retainedLayout(layout)
        return try result.validated()
    }
    /// Resolve identities and retain official Steam files before presentation.
    /// This stage may create a valid owned copy, but never changes preferences.
    static func prepare(_ value: NativeWallpaperProfile) throws -> NativeWallpaperProfile {
        var next = try value.validated()
        try validatePersistentProfile(next)
        let url = try retain(NativePlaylistLibrary.resolve(next.wallpaper))
        let metadata = try WallpaperProject.load(from: url)
        next.wallpaper.projectPath = url.path; next.wallpaper.title = metadata.title
        next.wallpaper.type = metadata.kind.rawValue
        // Preserve the established lazy playlist semantics: only the current
        // wallpaper and display assignments are prepared now. A later broken
        // playlist entry remains eligible for the normal skip-at-playback
        // path rather than making an otherwise valid profile unloadable.
        next.layout = try retainedLayout(next.layout)
        return try next.validated()
    }

    private static func persistentDisplayTarget(_ target: String) -> Bool {
        target.hasPrefix("uuid:") && UUID(uuidString: String(target.dropFirst(5))) != nil
    }
    static func validatePersistentLayout(_ value: NativeDisplayLayout) throws {
        guard value.displays.keys.allSatisfy({ !$0.hasPrefix("session:") }),
              value.preferredAudioDisplay.map({ !$0.hasPrefix("session:") }) ?? true else {
            throw NativePlaylistError.invalid("临时显示器配置不能保存为配置文件。")
        }
    }
    static func validatePersistentProfile(_ value: NativeWallpaperProfile) throws {
        try validatePersistentLayout(value.layout)
        guard value.displayPlaylists.keys.allSatisfy(persistentDisplayTarget) else {
            throw NativePlaylistError.invalid("临时显示器播放列表不能保存为配置文件。")
        }
    }
    private static func retainedLayout(_ value: NativeDisplayLayout) throws -> NativeDisplayLayout {
        var next = try value.validated()
        for (key, assignment) in value.displays {
            guard let resolved = NativeDisplayLayout.resolvedProject(assignment) else { continue }
            let url = assignment.enabled ? try retain(resolved) : resolved
            var item = assignment
            if let record = SavedWorkshopStore.recordForProject(url) {
                item.projectPath = record.project.path; item.projectTitle = record.title; item.workshopID = record.id
            }
            // Disabled assignments are retained, including temporarily missing
            // files. Every enabled selection must at least have valid metadata.
            if item.enabled { _ = try WallpaperProject.load(from: url) }
            next.displays[key] = item
        }
        return try next.validated()
    }
}

@MainActor
enum NativeProfileStore {
    static let savedKey = "nativeSavedProfilesV1"
    static let currentNameKey = "nativeCurrentProfileNameV1"
    struct Saved: Codable, Equatable { var format = 1; var profiles: [NativeWallpaperProfile] = [] }
    static var currentName: String { UserDefaults.standard.string(forKey: currentNameKey) ?? "" }

    /// Compatibility accessor for default-only callers. UUID display lists no
    /// longer make profile capture/apply fail; use `capturableActivePlaylists`
    /// when the full profile context is required.
    static func supportedPlaylist() throws -> NativePlaylist? {
        try capturableActivePlaylists().playlist
    }

    static func capturableActivePlaylists() throws -> NativeProfilePlaylists {
        let active = try NativePlaylistStore.active()
        let defaultPlaylist = active.lists["default"].flatMap { $0.entries.count > 1 ? $0 : nil }
        let displayPlaylists = active.lists.filter {
            $0.key.hasPrefix("uuid:") && UUID(uuidString: String($0.key.dropFirst(5))) != nil && $0.value.entries.count > 1
        }
        return .init(playlist: defaultPlaylist, displayPlaylists: displayPlaylists)
    }

    static func saved() throws -> Saved {
        guard let object = UserDefaults.standard.object(forKey: savedKey) else { return Saved() }
        guard let data = object as? Data, data.count <= 16 * 1024 * 1024 else {
            throw NativePlaylistError.invalid("保存的配置文件数据超过大小上限。")
        }
        let value: Saved
        do { value = try JSONDecoder().decode(Saved.self, from: data) }
        catch { throw NativePlaylistError.invalid("无法读取配置文件，原记录已保留。") }
        guard value.format == 1, value.profiles.count <= 1000,
              Set(value.profiles.map(\.name)).count == value.profiles.count,
              value.profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw NativePlaylistError.invalid("保存的配置文件目录无效，原记录已保留。")
        }
        for profile in value.profiles { _ = try profile.validated() }
        return value
    }
    @discardableResult
    static func saveNamed(_ profile: NativeWallpaperProfile, name: String) throws -> NativeWallpaperProfile {
        try saveNamed(profile, name: name, hotkey: .keep)
    }

    /// Saving a profile can also commit its visible shortcut.  The normal save
    /// path deliberately keeps a malformed legacy hotkey payload untouched;
    /// an explicit hotkey edit validates both records before writing either.
    @discardableResult
    static func saveNamed(_ profile: NativeWallpaperProfile, name: String,
                          hotkey: NativeProfileHotkeyMutation,
                          hotkeyService: NativeProfileHotkeyService? = nil) throws -> NativeWallpaperProfile {
        let service = hotkeyService ?? NativeProfileHotkeyService.shared
        var profile = profile; profile.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty else { throw NativePlaylistError.invalid("请输入配置文件名称。") }
        _ = try profile.validated()
        try NativeProfileLibrary.validatePersistentProfile(profile)
        var catalog = try saved()
        let existingProfiles = catalog.profiles
        if let index = catalog.profiles.firstIndex(where: { $0.name == profile.name }) { catalog.profiles[index] = profile }
        else {
            guard catalog.profiles.count < 1000 else { throw NativePlaylistError.invalid("保存的配置文件已达到数量上限。") }
            catalog.profiles.append(profile)
        }
        switch hotkey {
        case .keep:
            // A normal save must keep an unreadable legacy hotkey payload
            // untouched.  A valid dangling V1 binding with this exact newly
            // created profile name is different: committing the catalog makes
            // it live, so check a valid V2 owner and reserve its old chord
            // before writing the profile bytes.
            guard let reactivated = NativeProfileHotkeyStore.bindingReactivatedByKeepSave(
                profileName: profile.name, existingProfiles: existingProfiles, intendedProfiles: catalog.profiles
            ) else {
                try save(catalog); UserDefaults.standard.set(profile.name, forKey: currentNameKey)
                break
            }
            var v2Owner: NativeHotkeyBinding?
            do {
                v2Owner = try NativeHotkeyBindingStore.activeV2Conflict(for: reactivated.hotkey)
            } catch {
                // This is intentionally the historical `.keep` behavior for
                // malformed/unreadable non-V1 state: preserve it verbatim and
                // do not turn an ordinary profile save into a repair action.
                try save(catalog); UserDefaults.standard.set(profile.name, forKey: currentNameKey)
                break
            }
            if let v2Owner { throw NativeProfileHotkeyError.duplicateBinding(v2Owner.target.title) }
            let reservation = try service.reserveAvailable(reactivated.hotkey, for: profile.name)
            do {
                // `save` performs all fallible encoding before writing. The
                // current-name write and reservation commit are nonthrowing,
                // so an OS rejection cannot leave a newly-live unusable V1
                // binding in the catalog.
                try save(catalog)
                UserDefaults.standard.set(profile.name, forKey: currentNameKey)
                reservation.commit()
            } catch {
                reservation.cancel(); throw error
            }
        case .clear:
            let stored = try NativeProfileHotkeyStore.savedRawForTransaction()
            let updated = try NativeProfileHotkeyStore.mutate(stored, profileName: profile.name, mutation: hotkey)
            try NativeProfileHotkeyStore.commit(catalog: catalog, currentName: profile.name, hotkeys: updated)
            try? service.sync()
        case .set(let value, _):
            // The service holds an accepted Carbon registration while both
            // preference payloads are encoded and committed.  No fallible
            // operation follows that commit, so a failed OS reservation never
            // leaves a saved shortcut that cannot be activated.
            // Validate the raw record against the intended catalog before
            // claiming Carbon. A formerly dangling legacy record can become
            // live when this save introduces its profile name, and must not
            // poison a newly persisted binding after the next app launch.
            let stored = try NativeProfileHotkeyStore.validatedRawForMutation(profiles: catalog.profiles)
            let reservation = try service.reserveAvailable(value, for: profile.name)
            do {
                let updated = try NativeProfileHotkeyStore.mutate(stored, profileName: profile.name, mutation: hotkey)
                try NativeProfileHotkeyStore.commit(catalog: catalog, currentName: profile.name, hotkeys: updated)
                reservation.commit()
            } catch {
                reservation.cancel(); throw error
            }
        }
        return profile
    }
    static func removeNamed(_ name: String, hotkeyService: NativeProfileHotkeyService? = nil) throws {
        let service = hotkeyService ?? NativeProfileHotkeyService.shared
        var catalog = try saved(); catalog.profiles.removeAll { $0.name == name }
        // A damaged old hotkey payload must not strand a user profile.  It is
        // ignored operationally and preserved for repair; a valid payload is
        // removed in the same preference transaction as the catalog entry.
        if NativeProfileHotkeyStore.hasStoredValue, let stored = try? NativeProfileHotkeyStore.savedRawForTransaction() {
            var next = stored; next.bindings.removeAll { $0.profileName == name }
            try NativeProfileHotkeyStore.commit(catalog: catalog, currentName: nil, hotkeys: next)
            try? service.sync()
        } else {
            try save(catalog)
        }
    }
    private static func save(_ value: Saved) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 16 * 1024 * 1024 else { throw NativePlaylistError.invalid("保存的配置文件数据超过大小上限。") }
        UserDefaults.standard.set(data, forKey: savedKey)
    }

    /// Runs without suspension at the presentation commit boundary. A failure
    /// in either validated store restores the exact previous preferences.
    static func applySelection(_ profile: NativeWallpaperProfile) throws {
        _ = try profile.validated()
        try NativeProfileLibrary.validatePersistentProfile(profile)
        let displays = NativeDisplayStore.snapshot()
        let playlists = NativePlaylistStore.snapshot()
        let runtimeLayout = NativeDisplayStore.load()
        var layout = profile.layout
        layout.displays.merge(runtimeLayout.displays.filter { $0.key.hasPrefix("session:") }) { _, session in session }
        if runtimeLayout.preferredAudioDisplay?.hasPrefix("session:") == true {
            layout.preferredAudioDisplay = runtimeLayout.preferredAudioDisplay
        }
        do {
            try NativeDisplayStore.save(layout)
            try NativePlaylistStore.replacePersistent(.init(lists: profile.persistentPlaylists))
        } catch {
            NativeDisplayStore.restore(displays)
            NativePlaylistStore.restore(playlists)
            throw error
        }
        UserDefaults.standard.set(profile.name, forKey: currentNameKey)
    }
}
