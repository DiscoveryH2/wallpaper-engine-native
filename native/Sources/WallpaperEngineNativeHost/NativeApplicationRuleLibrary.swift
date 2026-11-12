import Foundation

/// Stable native library reference, not an executable path or a network URL.
/// Keep identities so Workshop updates and editor saves resolve at load time.
enum NativeApplicationWallpaperTarget {
    private static let prefix = "wenative-wallpaper-v1:"
    static func capture(project: URL, title: String, type: String) throws -> String {
        let key = NativePlaylistLibrary.key(for: project)
        var value = NativePlaylistWallpaper(key: key, projectPath: project.standardizedFileURL.path, title: title, type: type)
        if key.hasPrefix("created:") { value.creationID = UUID(uuidString: String(key.dropFirst(8))) }
        else if key.hasPrefix("bundled:") { value.bundledID = String(key.dropFirst(8)) }
        else if UInt64(key).map({ $0 > 0 }) == true { value.workshopID = key }
        return try encode(value)
    }
    static func encode(_ wallpaper: NativePlaylistWallpaper) throws -> String {
        _ = try wallpaper.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let value = prefix + (try encoder.encode(wallpaper)).base64EncodedString()
        guard value.utf8.count <= 8_192 else { throw NativeApplicationRuleError.invalidTarget }
        _ = try decode(value)
        return value
    }
    static func decode(_ value: String) throws -> NativePlaylistWallpaper {
        guard value.utf8.count <= 8_192, value.hasPrefix(prefix),
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let wallpaper = try? JSONDecoder().decode(NativePlaylistWallpaper.self, from: data) else {
            throw NativeApplicationRuleError.invalidTarget
        }
        _ = try wallpaper.validated()
        let identities = [wallpaper.workshopID != nil, wallpaper.creationID != nil, wallpaper.bundledID != nil].filter { $0 }.count
        guard identities <= 1,
              wallpaper.workshopID.map({ wallpaper.key == $0 }) ?? true,
              wallpaper.creationID.map({ wallpaper.key == "created:" + $0.uuidString }) ?? true,
              wallpaper.bundledID.map({ wallpaper.key == "bundled:" + $0 }) ?? true,
              !wallpaper.key.hasPrefix("local:") || NativeLocalWallpapers.identity(for: URL(fileURLWithPath: wallpaper.projectPath)) == wallpaper.key else {
            throw NativeApplicationRuleError.invalidTarget
        }
        return wallpaper
    }
    static func resolve(_ value: String) throws -> URL {
        let wallpaper = try decode(value)
        if wallpaper.key.hasPrefix("local:"), let current = NativeLocalWallpapers.records().items.first(where: { "local:" + $0.record.id == wallpaper.key }) { return current.project }
        return try NativePlaylistLibrary.resolve(wallpaper)
    }
}

struct NativeApplicationRuleLibraryItem: Equatable, Sendable {
    let wallpaper: NativePlaylistWallpaper
    let file: String
    var item: NativeApplicationRuleEditor.Item { .init(label: wallpaper.title, file: file) }
    var project: URL { URL(fileURLWithPath: wallpaper.projectPath) }
    var workshopURL: URL? { wallpaper.workshopID.flatMap { URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=" + $0) } }
    init(_ wallpaper: NativePlaylistWallpaper) throws {
        file = try NativeApplicationWallpaperTarget.encode(wallpaper)
        self.wallpaper = try NativeApplicationWallpaperTarget.decode(file)
    }
}

enum NativeApplicationRuleLibrary {
    struct Catalog: Sendable {
        var items: [NativeApplicationRuleLibraryItem]
        var warnings: [String] = []

        /// Versions can change both path and title. Restore the same library
        /// identity, never a same-named but unrelated wallpaper.
        func restoredFile(from archived: String?) -> String? {
            guard let archived, let saved = try? NativeApplicationWallpaperTarget.decode(archived) else { return nil }
            return items.first { $0.wallpaper.key == saved.key }?.file
        }
    }
    /// Read the same installed sources as the main library. Bundled wallpaper
    /// installation retains its existing app-owned, versioned store behavior.
    static func wallpapers() -> Catalog {
        let steam = SteamLibraryIndex.projects(), saved = SavedWorkshopStore.records()
        let created = NativeCreationStore.records(), bundled = NativeBundledWallpapers.records(), local = NativeLocalWallpapers.records()
        var values: [NativePlaylistWallpaper] = saved.items.map {
            .init(key: $0.id, projectPath: $0.project.path, title: $0.title, type: $0.type.lowercased(), workshopID: $0.id)
        }
        let savedIDs = Set(saved.items.map(\.id))
        values += steam.projects.filter { !$0.isInstalling && !savedIDs.contains($0.id) }.map {
            .init(key: $0.id, projectPath: $0.url.path, title: $0.title, type: $0.type.lowercased(), workshopID: $0.id)
        }
        values += created.items.map { .init(key: "created:" + $0.id.uuidString, projectPath: $0.project.path, title: $0.title, type: "scene", creationID: $0.id) }
        values += bundled.items.map { .init(key: "bundled:" + $0.id, projectPath: $0.project.path, title: $0.title, type: $0.type, bundledID: $0.id) }
        values += local.items.map { .init(key: NativeLocalWallpapers.identity(for: $0.project) ?? $0.project.path, projectPath: $0.project.path, title: $0.record.title, type: $0.record.type) }
        var seen = Set<String>()
        let items = values.prefix(10_000).compactMap { value -> NativeApplicationRuleLibraryItem? in
            guard ["scene", "web", "video", "image"].contains(value.type), seen.insert(value.key).inserted else { return nil }
            return try? NativeApplicationRuleLibraryItem(value)
        }.sorted { $0.wallpaper.title.localizedStandardCompare($1.wallpaper.title) == .orderedAscending }
        return Catalog(items: items, warnings: steam.warnings + [saved.warning, created.warning, local.warning].compactMap { $0 } + bundled.warnings)
    }
}

extension NativeDisplayLayout {
    /// REA 14006cea0 builds the selected wallpaper for every display. Retain
    /// disabled displays and audio ownership, but replace independent projects
    /// only in this value; the persistent display store must remain unchanged.
    func replacingProjectsForApplicationRule() -> Self {
        var result = self
        for key in result.displays.keys where result.displays[key]?.enabled == true {
            result.displays[key]?.projectPath = nil
            result.displays[key]?.projectTitle = nil
            result.displays[key]?.workshopID = nil
        }
        return result
    }
}
