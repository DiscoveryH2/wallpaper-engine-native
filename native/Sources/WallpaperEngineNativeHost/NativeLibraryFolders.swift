import Foundation

/// A library folder owns references, never the wallpaper's files. Each item
/// belongs to at most one folder; removing a folder returns its items to root.
struct NativeLibraryFolders: Equatable, Codable {
    /// The icon choices exposed by the public Build 26168761 installed-library
    /// context menu. `nil` on `Folder` means the official default folder icon;
    /// keeping that as an absent value lets pre-decoration V1 data round-trip
    /// without manufacturing a new field.
    enum FolderIcon: String, CaseIterable, Codable {
        case star, heart, gem, car, rocket, snowflake, thumbsUp, gamepad, gift
        case music, trash, bug, magic, banana, alien, alien8Bit, bat, bomb
        case boombox, candle, dragon, fire, meteor, palm, skull, christmasTree
        case retroTV, balloons, bone

        var title: String {
            switch self {
            case .star: return "星标"
            case .heart: return "爱心"
            case .gem: return "宝石"
            case .car: return "汽车"
            case .rocket: return "火箭"
            case .snowflake: return "雪花"
            case .thumbsUp: return "赞"
            case .gamepad: return "游戏手柄"
            case .gift: return "礼物"
            case .music: return "音乐"
            case .trash: return "垃圾桶"
            case .bug: return "虫子"
            case .magic: return "魔法"
            case .banana: return "香蕉"
            case .alien: return "外星人"
            case .alien8Bit: return "像素外星人"
            case .bat: return "蝙蝠"
            case .bomb: return "爆炸"
            case .boombox: return "音响"
            case .candle: return "蜡烛"
            case .dragon: return "龙"
            case .fire: return "火焰"
            case .meteor: return "流星"
            case .palm: return "棕榈树"
            case .skull: return "骷髅"
            case .christmasTree: return "圣诞树"
            case .retroTV: return "复古电视"
            case .balloons: return "气球"
            case .bone: return "骨头"
            }
        }
    }

    /// The nine named color choices from the same official folder menu.
    /// Raw values are stable semantic IDs, rather than platform color-space
    /// payloads, so persistence is deterministic across appearances.
    enum FolderColor: String, CaseIterable, Codable {
        case brightBlue, blue, purple, magenta, red, yellow, brightYellow, green, darkGreen

        var title: String {
            switch self {
            case .brightBlue: return "亮蓝"
            case .blue: return "蓝"
            case .purple: return "紫"
            case .magenta: return "洋红"
            case .red: return "红"
            case .yellow: return "黄"
            case .brightYellow: return "亮黄"
            case .green: return "绿"
            case .darkGreen: return "深绿"
            }
        }
    }

    struct Folder: Equatable, Codable {
        let id: String
        var title: String
        var parent: String?
        var items: Set<String>
        /// Optional fields retain compatibility with existing V1 folder data.
        /// An absent value selects the default icon/color rather than a stored
        /// platform-specific fallback.
        var icon: FolderIcon?
        var color: FolderColor?

        init(id: String, title: String, parent: String?, items: Set<String>,
             icon: FolderIcon? = nil, color: FolderColor? = nil) {
            self.id = id; self.title = title; self.parent = parent; self.items = items
            self.icon = icon; self.color = color
        }

        private enum CodingKeys: String, CodingKey { case id, title, parent, items, icon, color }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            title = try values.decode(String.self, forKey: .title)
            parent = try values.decodeIfPresent(String.self, forKey: .parent)
            items = try values.decode(Set<String>.self, forKey: .items)
            // Deliberately do not coerce unknown raw values to a default: a
            // malformed/foreign decoration must fail closed with the rest of
            // the existing folder graph and leave the original preference
            // bytes untouched by the controller.
            icon = try values.decodeIfPresent(FolderIcon.self, forKey: .icon)
            color = try values.decodeIfPresent(FolderColor.self, forKey: .color)
        }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(id, forKey: .id)
            try values.encode(title, forKey: .title)
            try values.encodeIfPresent(parent, forKey: .parent)
            try values.encode(items, forKey: .items)
            // Do not add null decoration keys when an existing V1 folder is
            // saved for another reason.
            try values.encodeIfPresent(icon, forKey: .icon)
            try values.encodeIfPresent(color, forKey: .color)
        }
    }
    enum Failure: Error, LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
    }
    static let preferenceKey = "libraryFoldersV1"
    private(set) var version = 1
    private(set) var folders: [Folder] = []
    init() {}
    init(data: Data) throws {
        guard data.count <= 2 * 1024 * 1024 else { throw Failure.invalid("文件夹配置超过读取限额，原数据已保留。") }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }
    func folder(_ id: String?) -> Folder? { id.flatMap { id in folders.first { $0.id == id } } }
    func children(of parent: String?) -> [Folder] { folders.filter { $0.parent == parent } }
    func path(to id: String?) -> [Folder] {
        var result: [Folder] = [], next = id, visited = Set<String>()
        while let current = folder(next), visited.insert(current.id).inserted, result.count <= 32 {
            result.insert(current, at: 0); next = current.parent
        }
        return result
    }
    func contains(_ item: String, in folderID: String?) -> Bool {
        if let folderID { return folder(folderID)?.items.contains(item) == true }
        return !folders.contains { $0.items.contains(item) }
    }
    func owner(of item: String) -> String? { folders.first { $0.items.contains(item) }?.id }
    private static func validTitle(_ title: String) -> Bool {
        !title.isEmpty && title.utf8.count <= 512 && !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func validItem(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= 8192 && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private func validate() throws {
        guard version == 1, folders.count <= 1000, Set(folders.map(\.id)).count == folders.count,
              folders.allSatisfy({ UUID(uuidString: $0.id) != nil && Self.validTitle($0.title) && $0.items.allSatisfy(Self.validItem) }) else {
            throw Failure.invalid("文件夹配置包含无效条目，原数据已保留。")
        }
        var keys = Set<String>()
        for node in folders {
            guard node.parent == nil || folder(node.parent) != nil else { throw Failure.invalid("文件夹的上级目录已缺失，原数据已保留。") }
            let chain = path(to: node.id)
            guard chain.count <= 32, chain.first?.parent == nil else { throw Failure.invalid("文件夹配置存在循环或层级过深，原数据已保留。") }
            for key in node.items where !keys.insert(key).inserted { throw Failure.invalid("壁纸被重复分配到文件夹，原数据已保留。") }
        }
        guard keys.count <= 100_000 else { throw Failure.invalid("文件夹中的壁纸数量超过限额，原数据已保留。") }
    }
    @discardableResult
    mutating func create(title: String, parent: String? = nil) throws -> String {
        let title = title.isEmpty ? "新文件夹" : title
        guard Self.validTitle(title), folders.count < 1000, parent == nil || folder(parent) != nil,
              path(to: parent).count < 32 else { throw Failure.invalid("文件夹名称或位置无效。") }
        let id = UUID().uuidString
        folders.append(.init(id: id, title: title, parent: parent, items: [])); return id
    }
    mutating func rename(_ id: String, to title: String) throws {
        guard Self.validTitle(title), let index = folders.firstIndex(where: { $0.id == id }) else { throw Failure.invalid("文件夹名称或位置无效。") }
        folders[index].title = title
    }
    /// Atomically replace the visual decoration. This never moves wallpaper
    /// references or touches their project files/subscriptions.
    mutating func setDecoration(_ id: String, icon: FolderIcon?, color: FolderColor?) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }) else {
            throw Failure.invalid("文件夹已不存在。")
        }
        var candidate = self
        candidate.folders[index].icon = icon; candidate.folders[index].color = color
        try candidate.validate(); self = candidate
    }
    mutating func move(items keys: Set<String>, to target: String?) throws {
        guard keys.allSatisfy(Self.validItem), keys.count <= 100_000,
              target == nil || folder(target) != nil else { throw Failure.invalid("目标文件夹已不存在。") }
        var candidate = self
        for index in candidate.folders.indices { candidate.folders[index].items.subtract(keys) }
        if let index = candidate.folders.firstIndex(where: { $0.id == target }) { candidate.folders[index].items.formUnion(keys) }
        try candidate.validate(); self = candidate
    }
    mutating func move(folder id: String, to target: String?) throws {
        guard let index = folders.firstIndex(where: { $0.id == id }), target == nil || folder(target) != nil,
              !path(to: target).contains(where: { $0.id == id }) else { throw Failure.invalid("不能将文件夹移入自身或其子文件夹。") }
        var candidate = self; candidate.folders[index].parent = target
        try candidate.validate(); self = candidate
    }
    mutating func remove(_ id: String) throws {
        guard folder(id) != nil else { throw Failure.invalid("文件夹已不存在。") }
        let removed = Set(folders.filter { path(to: $0.id).contains { $0.id == id } }.map(\.id))
        folders.removeAll { removed.contains($0.id) }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 2 * 1024 * 1024 else { throw Failure.invalid("文件夹配置超过保存限额。") }
        return data
    }
    func save(_ defaults: UserDefaults = .standard) throws {
        if folders.isEmpty { defaults.removeObject(forKey: Self.preferenceKey) }
        else { defaults.set(try encoded(), forKey: Self.preferenceKey) }
    }
}
