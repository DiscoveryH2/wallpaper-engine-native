import AppKit

enum NativeLibraryThumbnailSize: String, CaseIterable {
    case small, medium, large
    static let preferenceKey = "libraryThumbnailSize"
    var title: String {
        switch self { case .small: return "小图标"; case .medium: return "中图标"; case .large: return "大图标" }
    }
    static func stored(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .medium
    }
    func save(in defaults: UserDefaults = .standard) {
        if self == .medium { defaults.removeObject(forKey: Self.preferenceKey) }
        else { defaults.set(rawValue, forKey: Self.preferenceKey) }
    }
}

/// Native equivalent of the verified public Build 26168761 thumbnail flex grid.
/// The viewport selects the CSS breakpoint; containerWidth is the scroll view's
/// actual content width, excluding its scroller. The directive adds 20 invisible
/// cells, so an incomplete final row normally keeps the preceding row's size.
struct NativeLibraryThumbnailGeometry {
    let viewportWidth: CGFloat
    let containerWidth: CGFloat
    let count: Int
    let size: NativeLibraryThumbnailSize
    var minimum: CGFloat {
        switch size {
        case .small: return viewportWidth >= 1450 ? 128 : 96
        case .medium: return viewportWidth >= 2000 ? 200 : viewportWidth >= 1450 ? 160 : viewportWidth >= 1230 ? 140 : 128
        case .large: return viewportWidth >= 2000 ? 230 : viewportWidth >= 1450 ? 200 : 168
        }
    }
    var maximum: CGFloat {
        switch size {
        case .small: return viewportWidth >= 1450 ? 148 : 128
        case .medium: return viewportWidth >= 2000 ? 220 : viewportWidth >= 1450 ? 200 : viewportWidth >= 1230 ? 185 : 168
        case .large: return viewportWidth >= 2000 ? 260 : 250
        }
    }
    var margin: CGFloat { size == .small ? 3 : size == .large || viewportWidth >= 1450 ? 6 : 4 }
    private var available: CGFloat { max(0, containerWidth - 2) }
    var columns: Int { max(1, Int(available / (minimum + margin))) }
    private var total: Int { max(0, count) + 20 }
    private func entries(in row: Int) -> Int { max(1, min(columns, total - row * columns)) }
    private func side(for entries: Int) -> CGFloat {
        // CSS layout uses 1/64 px units. Flex sizes round to the closest unit;
        // distributed space-between gaps truncate to a whole layout unit.
        (min(maximum, max(minimum, available / CGFloat(entries) - margin)) * 64).rounded() / 64
    }
    var rowStride: CGFloat { side(for: columns) + margin }
    func frame(at index: Int) -> NSRect? {
        guard index >= 0, index < count else { return nil }
        let row = index / columns, column = index % columns, entries = entries(in: row)
        let side = side(for: entries)
        let remaining = max(0, available - CGFloat(entries) * (side + margin))
        let extra = viewportWidth >= 720 && entries > 1 ? floor(remaining / CGFloat(entries - 1) * 64) / 64 : 0
        return NSRect(x: 1 + CGFloat(column) * (side + margin + extra), y: 1 + CGFloat(row) * rowStride,
                      width: side, height: side)
    }
    var contentHeight: CGFloat {
        let realRows = (max(0, count) + columns - 1) / columns
        let allRows = (total + columns - 1) / columns
        guard realRows > 0 else { return 2 + CGFloat(allRows) * margin }
        return (2 + CGFloat(realRows - 1) * rowStride + side(for: entries(in: realRows - 1))
                + CGFloat(allRows - realRows + 1) * margin).rounded()
    }
}

enum NativeLibraryThumbnailBadge: String, CaseIterable {
    case approved, portrait, favorite, installed
    var title: String {
        switch self { case .approved: return "精选"; case .portrait: return "纵向壁纸"; case .favorite: return "已收藏"; case .installed: return "已安装" }
    }
    var symbol: String {
        switch self { case .approved: return "trophy.fill"; case .portrait: return "iphone"; case .favorite: return "heart.fill"; case .installed: return "internaldrive.fill" }
    }
    static func known(tags: Set<String>, favorite: Bool = false, installed: Bool = false) -> [Self] {
        var result: [Self] = []
        if tags.contains("Approved") { result.append(.approved) }
        if tags.contains("Portrait") { result.append(.portrait) }
        if favorite { result.append(.favorite) }
        if installed { result.append(.installed) }
        return result
    }
}

@MainActor
enum NativeLibraryThumbnailMenu {
    static func item(selected: NativeLibraryThumbnailSize, choose: @escaping (NativeLibraryThumbnailSize) -> Void) -> NSMenuItem {
        let menu = NSMenu(); menu.autoenablesItems = false
        for size in NativeLibraryThumbnailSize.allCases {
            let item = NativeThumbnailSizeMenuItem(title: size.title) { choose(size) }
            item.identifier = NSUserInterfaceItemIdentifier("libraryThumbnailSize_" + size.rawValue)
            item.state = size == selected ? .on : .off
            menu.addItem(item)
        }
        let item = NSMenuItem(title: "查看", action: nil, keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("libraryThumbnailViewMenu"); item.submenu = menu
        return item
    }
}

@MainActor
private final class NativeThumbnailSizeMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler; super.init(title: title, action: nil, keyEquivalent: "")
        target = self; action = #selector(invoke)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}
