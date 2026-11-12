import Foundation

/// Installed browsing has different defaults and all-off behavior from a
/// Workshop query. Keep its local predicate independent of that protocol.
struct NativeInstalledFilterState: Equatable {
    enum Group: String, CaseIterable {
        case type = "typetags", category = "categorytags", source = "sourcetags"
        case age = "ratingtags", resolution = "resolutiontags", genre = "tags"
        var choices: [NativeWorkshopFilterCatalog.Choice] {
            switch self {
            case .type: return NativeWorkshopFilterCatalog.types
            case .category: return NativeWorkshopFilterCatalog.categories
            case .source: return [.init(tag: "Official", title: "官方"), .init(tag: "Workshop", title: "创意工坊"), .init(tag: "Local", title: "我的壁纸")]
            case .age: return NativeWorkshopFilterCatalog.ages
            case .resolution: return NativeWorkshopFilterCatalog.resolutions
            case .genre: return NativeWorkshopFilterCatalog.genres
            }
        }
    }
    struct Entry {
        let title: String
        let tags: String?
        var favorite = false
        var allowMobileUpload = false
        var local = false
        var official = false
    }
    private(set) var allowed: [Group: Set<String>] = Dictionary(uniqueKeysWithValues: Group.allCases.map { ($0, Set($0.choices.map(\.tag))) })
    private(set) var features: [String: Int] = [:]
    var mobileOnly = false
    var favoritesOnly = false
    var isDefault: Bool { self == Self() }
    func isAllowed(_ tag: String, in group: Group) -> Bool { allowed[group]?.contains(tag) == true }
    mutating func setAllowed(_ tag: String, in group: Group, to value: Bool) {
        guard group.choices.contains(where: { $0.tag == tag }) else { return }
        if value { allowed[group, default: []].insert(tag) } else { allowed[group]?.remove(tag) }
    }
    mutating func setAll(in group: Group, to value: Bool, tags: [String]? = nil) {
        for tag in tags ?? group.choices.map(\.tag) { setAllowed(tag, in: group, to: value) }
    }
    mutating func setFeature(_ tag: String, to value: Int) {
        guard NativeWorkshopFilterCatalog.features.contains(where: { $0.tag == tag }), (0...2).contains(value) else { return }
        if value == 0 { features.removeValue(forKey: tag) } else { features[tag] = value }
    }
    func matches(_ entry: Entry, query: String = "") -> Bool {
        if favoritesOnly && !entry.favorite { return false }
        if mobileOnly && !(entry.allowMobileUpload || entry.local || entry.official) { return false }
        if let tags = entry.tags {
            if mobileOnly && (tags.contains("Application") || tags.contains("Web")) { return false }
            for group in Group.allCases {
                for choice in group.choices where !isAllowed(choice.tag, in: group) && tags.contains(choice.tag) { return false }
            }
            for (tag, value) in features {
                if value == 1 && !tags.contains(tag) || value == 2 && tags.contains(tag) { return false }
            }
        }
        return Self.matchesSearch(query, title: entry.title, tags: entry.tags)
    }
    static func matchesSearch(_ query: String, title: String, tags: String?) -> Bool {
        if query.isEmpty { return true }
        guard query.utf16.count <= 4096, title.utf16.count <= 4096 else { return false }
        func normalized(_ value: String) -> String { value.lowercased().replacingOccurrences(of: "[?.!]", with: "", options: .regularExpression) }
        var text = normalized(query)
        for (pattern, tag) in [("hdr", "HDR"), ("3d", "3D"), ("(puppet|puppet warp|puppetwarp)", "Puppet Warp")] {
            // JavaScript's non-Unicode word boundary is ASCII-based.
            let regex = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + pattern + "(?![A-Za-z0-9_])")
            let range = NSRange(text.startIndex..., in: text)
            if regex.firstMatch(in: text, range: range) != nil {
                if let tags, !tags.contains(tag) { return false }
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            }
        }
        guard !text.isEmpty else { return true }
        let title = normalized(title)
        if title.contains(text) { return true }
        // The official title search accepts an optimal-string-alignment
        // distance below three. UTF-16 and adjacent transpositions match JS.
        let a = Array(title.utf16), b = Array(text.utf16)
        guard abs(a.count - b.count) < 3 else { return false }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) < 3 }
        var older = Array(repeating: 0, count: b.count + 1), previous = Array(0...b.count)
        for i in 1...a.count {
            var row = Array(repeating: 3, count: b.count + 1); row[0] = i
            let start = max(1, i - 2), end = min(b.count, i + 2)
            if start <= end {
                for j in start...end {
                    let cost = a[i - 1] == b[j - 1] ? 0 : 1
                    row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost)
                    if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { row[j] = min(row[j], older[j - 2] + cost) }
                }
            }
            older = previous; previous = row
        }
        return previous[b.count] < 3
    }
    var object: [String: Any] {
        var value: [String: Any] = ["version": 1, "features": features, "mobileOnly": mobileOnly, "favoritesOnly": favoritesOnly]
        for group in Group.allCases { value[group.rawValue] = (allowed[group] ?? []).sorted() }
        return value
    }
    init() {}
    init?(object: [String: Any]) {
        guard object["version"] as? Int == 1,
              let features = object["features"] as? [String: Int], features.count <= 3,
              let mobile = object["mobileOnly"] as? Bool, let favorites = object["favoritesOnly"] as? Bool else { return nil }
        for group in Group.allCases {
            guard let values = object[group.rawValue] as? [String], values.count <= group.choices.count,
                  Set(values).isSubset(of: Set(group.choices.map(\.tag))) else { return nil }
            allowed[group] = Set(values)
        }
        for (tag, value) in features {
            guard NativeWorkshopFilterCatalog.features.contains(where: { $0.tag == tag }), (0...2).contains(value) else { return nil }
            setFeature(tag, to: value)
        }
        mobileOnly = mobile; favoritesOnly = favorites
    }
    static func stored(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "libraryInstalledFiltersV1"), data.count <= 16384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = Self(object: object) else { return Self() }
        return value
    }
    func save(_ defaults: UserDefaults = .standard) {
        if isDefault { defaults.removeObject(forKey: "libraryInstalledFiltersV1") }
        else if let data = try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys) { defaults.set(data, forKey: "libraryInstalledFiltersV1") }
    }
}

struct NativeInstalledFilterMetadata: Equatable {
    var tags: Set<String> = []
    var allowMobileUpload = false
    var modifiedAt: TimeInterval = 0
    var remoteWeb = false
    init(object: [String: Any]) {
        let scheme = (object["file"] as? String).flatMap { URLComponents(string: $0)?.scheme?.lowercased() }
        remoteWeb = (object["type"] as? String)?.lowercased() == "web" && ["http", "https"].contains(scheme ?? "")
        if let values = object["tags"] as? [String] {
            tags = Set(values.prefix(64).filter { !$0.isEmpty && $0.utf8.count <= 128 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) })
        }
        if let rating = object["contentrating"] as? String, NativeWorkshopFilterCatalog.ages.contains(where: { $0.tag == rating }) { tags.insert(rating) }
        if object["approved"] as? Bool == true { tags.insert("Approved") }
        if let properties = (object["general"] as? [String: Any])?["properties"] as? [String: Any], properties.keys.contains(where: { $0 != "schemecolor" }) { tags.insert("Customizable") }
        allowMobileUpload = object["allowmobileupload"] as? Bool == true
    }
    static func read(_ project: URL) -> Self {
        guard let data = try? SteamLibraryIndex.read(project, limit: 4 * 1024 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Self(object: [:]) }
        var result = Self(object: object)
        result.modifiedAt = (try? project.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return result
    }
    func entry(title: String, type: String, workshop: Bool, publishedTags: [String]? = nil, publishedMobilePermission: Bool? = nil) -> NativeInstalledFilterState.Entry {
        var tags = publishedTags.map(Set.init) ?? self.tags
        for source in ["Official", "Workshop", "Local"] { tags.remove(source) }
        tags.insert(workshop ? "Workshop" : "Local")
        let filterType = type.lowercased() == "image" ? "scene" : type.lowercased()
        if let kind = NativeWorkshopFilterCatalog.types.first(where: { $0.tag.lowercased() == filterType }) { tags.insert(kind.tag) }
        if !tags.contains("Preset") { tags.insert("Wallpaper") }
        return .init(title: title, tags: tags.sorted().joined(separator: ","), allowMobileUpload: publishedMobilePermission ?? allowMobileUpload, local: !workshop)
    }
}
