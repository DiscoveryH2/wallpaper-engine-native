import AppKit

@MainActor
final class NativePlaylistPanel: NSView {
    var onToggle: (() -> Void)?
    var onClear: (() -> Void)?
    var onLoad: (() -> Void)?
    var onSave: (() -> Void)?
    var onConfigure: (() -> Void)?
    var onSelect: ((NativePlaylistEntry) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onMove: ((UUID, UUID?) -> Void)?
    var onTime: ((UUID, Double?) -> Void)?
    private(set) var list = NativePlaylist()
    private let heading = NSTextField(labelWithString: "播放列表")
    private var buttons: [NativeLibraryFooterButton] = []
    private let scroll = NSScrollView()
    private let row = NativePlaylistRow()
    private var viewportWidth: CGFloat = 1100
    private let images = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 2; q.qualityOfService = .utility; return q }()
    private var generation = UUID()
    override var isFlipped: Bool { true }
    var requiredHeight: CGFloat { list.entries.isEmpty ? 38 : list.settings.mode == .daytime || list.settings.mode == .dayofweek ? 144 : 120 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = .init("libraryPlaylist"); setAccessibilityLabel("播放列表")
        heading.font = NativeLibraryBrowserStyle.font(24); heading.lineBreakMode = .byTruncatingTail; addSubview(heading)
        for (title, symbol, selector, id, primary) in [
            ("读取", "folder", #selector(loadList), "playlistLoad", false),
            ("保存", "square.and.arrow.down", #selector(saveList), "playlistSave", false),
            ("配置", "gearshape.2", #selector(configure), "playlistConfigure", false),
            ("添加壁纸", "plus", #selector(toggle), "playlistAdd", true),
            ("移除壁纸", "minus", #selector(toggle), "playlistRemove", true),
            ("清理", "trash", #selector(clear), "playlistClear", false)
        ] {
            let button = NativeLibraryFooterButton(title: title, primary: primary, symbol: symbol, target: self, action: selector)
            button.identifier = .init(id); buttons.append(button); addSubview(button)
        }
        buttons[5].destructive = true
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder; scroll.documentView = row; addSubview(scroll)
        row.onSelect = { [weak self] entry in self?.onSelect?(entry) }
        row.onRemove = { [weak self] id in self?.onRemove?(id) }
        row.onMove = { [weak self] id, next in self?.onMove?(id, next) }
        row.onTime = { [weak self] id, end in self?.onTime?(id, end) }
        images.totalCostLimit = 24 * 1024 * 1024; images.countLimit = 100
        update(list: list, selectedKey: nil, canToggle: false)
    }
    required init?(coder: NSCoder) { nil }
    func updateGeometry(viewportWidth: CGFloat) { self.viewportWidth = viewportWidth; needsLayout = true }
    func update(list: NativePlaylist, selectedKey: String?, canToggle: Bool, error: String? = nil) {
        let changed = self.list != list
        self.list = list
        heading.stringValue = list.entries.isEmpty ? "播放列表" : "播放列表 (\(list.entries.count))"
        heading.toolTip = error ?? (list.name.isEmpty ? nil : list.name)
        let member = list.entries.contains { $0.wallpaper.key == selectedKey }
        buttons[0].isEnabled = error == nil; buttons[1].isEnabled = error == nil && list.entries.count >= 2
        buttons[2].isEnabled = error == nil && !list.entries.isEmpty
        buttons[3].isHidden = member; buttons[4].isHidden = !member
        buttons[3].isEnabled = error == nil && canToggle; buttons[4].isEnabled = error == nil && canToggle
        buttons[5].isHidden = list.entries.isEmpty; buttons[5].isEnabled = error == nil
        scroll.isHidden = list.entries.isEmpty
        row.update(list: list, selectedKey: selectedKey)
        if changed {
            queue.cancelAllOperations(); generation = UUID(); let ticket = generation
            for entry in list.entries.prefix(1000) {
                let path = entry.wallpaper.projectPath
                if let image = images.object(forKey: path as NSString) { row.setImage(image, path: path); continue }
                let operation = BlockOperation()
                operation.addExecutionBlock { [weak self, weak operation] in
                    guard operation?.isCancelled == false else { return }
                    let result = NativeLibraryPreview.load(project: URL(fileURLWithPath: path))
                    guard operation?.isCancelled == false, let cg = result.image else { return }
                    DispatchQueue.main.async { [weak self, operation] in
                        guard let self, operation?.isCancelled == false, generation == ticket else { return }
                        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
                        images.setObject(image, forKey: path as NSString, cost: cg.bytesPerRow * cg.height); row.setImage(image, path: path)
                    }
                }
                queue.addOperation(operation)
            }
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        heading.textColor = NativeLibraryBrowserStyle.foreground(effectiveAppearance)
        // NSTextField adds a 2 pt inset on each side even for a label. Account
        // for it so a four-character Chinese heading is not ellipsized.
        let textWidth = heading.stringValue.size(withAttributes: [.font: NativeLibraryBrowserStyle.font(24)]).width
        let titleWidth = min(bounds.width * 0.5, textWidth + 14)
        heading.frame = NSRect(x: 0, y: 10, width: titleWidth - 10, height: 28)
        var x = titleWidth
        for (index, button) in buttons.enumerated() where !button.isHidden {
            button.showsText = viewportWidth >= 1200
            let textWidth = button.showsText ? button.title.size(withAttributes: [.font: NativeLibraryBrowserStyle.font(14)]).width + 4 : 0
            let width = 14 + textWidth + 14
            let left = index == 5 ? max(x + 3, bounds.width - width) : x + 3
            button.frame = NSRect(x: left, y: 11, width: width, height: 26); x = button.frame.maxX
        }
        scroll.frame = NSRect(x: 0, y: 48, width: bounds.width, height: max(0, requiredHeight - 58))
        let width = list.entries.count > 1000 ? bounds.width : max(bounds.width, CGFloat(list.entries.count) * 53 + 2)
        row.frame = NSRect(x: 0, y: 0, width: width, height: requiredHeight == 144 ? 79 : 55)
        row.needsLayout = true
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsLayout = true }
    @objc private func loadList() { onLoad?() }
    @objc private func saveList() { onSave?() }
    @objc private func configure() { onConfigure?() }
    @objc private func toggle() { onToggle?() }
    @objc private func clear() { onClear?() }
}

@MainActor
private final class NativePlaylistRow: NSView {
    static let dragType = NSPasteboard.PasteboardType("io.wallpaper-engine-native.playlist-entry")
    let owner = UUID()
    var onSelect: ((NativePlaylistEntry) -> Void)?
    var onRemove: ((UUID) -> Void)?
    var onMove: ((UUID, UUID?) -> Void)?
    var onTime: ((UUID, Double?) -> Void)?
    private var list = NativePlaylist()
    private var cards: [NativePlaylistCard] = []
    override var isFlipped: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([Self.dragType]) }
    required init?(coder: NSCoder) { nil }
    func update(list: NativePlaylist, selectedKey: String?) {
        let rebuild = self.list.entries != list.entries || self.list.settings.mode != list.settings.mode
        self.list = list
        if rebuild {
            cards.forEach { $0.removeFromSuperview() }; cards = []
            if list.entries.count <= 1000 {
                for entry in list.entries {
                    let card = NativePlaylistCard(entry: entry, owner: owner)
                    card.onSelect = { [weak self] in self?.onSelect?(entry) }
                    card.onRemove = { [weak self] in self?.onRemove?(entry.id) }
                    card.onTime = { [weak self] location in
                        guard let self else { return }
                        let fraction = min(1, max(0, location / max(1, bounds.width - 2)))
                        let quantized = list.entries.count <= 50 ? (fraction * 288).rounded() / 288 : fraction
                        onTime?(entry.id, quantized)
                    }
                    card.onMove = { [weak self] forward in
                        guard let self, let index = list.entries.firstIndex(where: { $0.id == entry.id }) else { return }
                        let destination = forward ? index - 1 : index + 2
                        guard destination >= 0 else { return }
                        onMove?(entry.id, list.entries.indices.contains(destination) ? list.entries[destination].id : nil)
                    }
                    cards.append(card); addSubview(card)
                }
            }
        }
        for card in cards { card.selected = card.entry.wallpaper.key == selectedKey; card.needsDisplay = true }
        needsLayout = true; needsDisplay = true
    }
    func setImage(_ image: NSImage, path: String) { for card in cards where card.entry.wallpaper.projectPath == path { card.preview = image; card.needsDisplay = true } }
    override func layout() {
        super.layout()
        let timed = list.settings.mode == .daytime || list.settings.mode == .dayofweek
        let ranges = list.daytimeRanges
        for (index, card) in cards.enumerated() {
            var x = CGFloat(index) * 53 + 1, width: CGFloat = 48
            if timed {
                let range = list.settings.mode == .daytime ? ranges[index] : Double(index) / Double(cards.count)..<Double(index + 1) / Double(cards.count)
                x = 3 + CGFloat(range.lowerBound) * (bounds.width - 2)
                width = max(1, CGFloat(range.upperBound - range.lowerBound) * (bounds.width - 2) - 4)
            }
            card.timeEditable = list.settings.mode == .daytime && index < cards.count - 1
            card.frame = NSRect(x: x, y: timed ? 29 : 5, width: width, height: 48)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        if list.entries.count > 1000 {
            "在播放清单中显示太多的壁纸。".draw(at: NSPoint(x: 1, y: 5), withAttributes: [.font: NativeLibraryBrowserStyle.font(14), .foregroundColor: NativeLibraryBrowserStyle.foreground(effectiveAppearance)]); return
        }
        let timed = list.settings.mode == .daytime || list.settings.mode == .dayofweek
        guard timed else { return }
        NativeLibraryBrowserStyle.accent(effectiveAppearance).setFill(); NSRect(x: 1, y: 22, width: bounds.width - 2, height: 1).fill()
        let labels = list.settings.mode == .daytime ? ["00:00", "06:00", "12:00", "18:00", "23:59"] : list.entries.indices.map { list.weekdayLabel($0) }
        for (index, text) in labels.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [.font: NativeLibraryBrowserStyle.font(12), .foregroundColor: NativeLibraryBrowserStyle.foreground(effectiveAppearance)]
            let width = text.size(withAttributes: attributes).width
            let x: CGFloat = list.settings.mode == .daytime ? max(1, min(bounds.width - width - 1, CGFloat(index) / 4 * bounds.width - width / 2)) : (CGFloat(index) + 0.5) / CGFloat(labels.count) * bounds.width - width / 2
            text.draw(at: NSPoint(x: x, y: 4), withAttributes: attributes)
        }
    }
    private func draggedID(_ sender: NSDraggingInfo) -> UUID? {
        guard let value = sender.draggingPasteboard.string(forType: Self.dragType) else { return nil }
        let parts = value.split(separator: "/")
        guard parts.count == 2, parts[0] == owner.uuidString, let id = UUID(uuidString: String(parts[1])), list.entries.contains(where: { $0.id == id }) else { return nil }
        return id
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggedID(sender) == nil ? [] : .move }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggedID(sender) == nil ? [] : .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = draggedID(sender) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let next = cards.first { $0.frame.midX > point.x }?.entry.id
        onMove?(id, next); return true
    }
}

@MainActor
private final class NativePlaylistCard: NSView, NSDraggingSource {
    let entry: NativePlaylistEntry
    let owner: UUID
    var preview: NSImage?
    var selected = false
    var timeEditable = false
    var onSelect: (() -> Void)?
    var onRemove: (() -> Void)?
    var onTime: ((CGFloat) -> Void)?
    var onMove: ((Bool) -> Void)?
    private let remove = NSButton(title: "×", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    init(entry: NativePlaylistEntry, owner: UUID) {
        self.entry = entry; self.owner = owner; super.init(frame: .zero)
        identifier = .init("playlistEntry_" + entry.id.uuidString)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel(entry.wallpaper.title)
        toolTip = entry.wallpaper.title
        remove.isBordered = false; remove.font = .boldSystemFont(ofSize: 16); remove.contentTintColor = .systemRed
        remove.target = self; remove.action = #selector(removeEntry); remove.isHidden = true
        remove.setAccessibilityLabel("移除 " + entry.wallpaper.title); remove.identifier = .init("playlistDelete_" + entry.id.uuidString); addSubview(remove)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); remove.frame = NSRect(x: max(0, bounds.width - 18), y: 0, width: 18, height: 18) }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        tracking = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { remove.isHidden = false }
    override func mouseExited(with event: NSEvent) { remove.isHidden = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 0.1).setFill(); bounds.fill()
        if let preview {
            let side = min(bounds.width, bounds.height)
            preview.draw(in: NSRect(x: 0, y: 0, width: side, height: bounds.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        if selected {
            NativeLibraryBrowserStyle.accent(effectiveAppearance).setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5)); border.lineWidth = 3; border.stroke()
        }
        if timeEditable, entry.daytimeEnd != nil { NSColor.systemOrange.setFill(); NSRect(x: bounds.width - 4, y: 0, width: 4, height: 48).fill() }
    }
    @objc private func removeEntry() { onRemove?() }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    override func mouseDown(with event: NSEvent) {
        let origin = convert(event.locationInWindow, from: nil)
        guard let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { return }
        if next.type == .leftMouseUp { onSelect?(); return }
        if timeEditable, origin.x >= bounds.width - 8 {
            var point = next.locationInWindow
            while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
                point = next.locationInWindow
                if next.type == .leftMouseUp { break }
            }
            if let superview { onTime?(superview.convert(point, from: nil).x) }
            return
        }
        let pasteboard = NSPasteboardItem(); pasteboard.setString(owner.uuidString + "/" + entry.id.uuidString, forType: NativePlaylistRow.dragType)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let image = preview ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!
        item.setDraggingFrame(bounds, contents: image); beginDraggingSession(with: [item], event: next, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(LibraryActionMenuItem(title: "向前移动") { [weak self] in self?.onMove?(true) })
        menu.addItem(LibraryActionMenuItem(title: "向后移动") { [weak self] in self?.onMove?(false) })
        if timeEditable { menu.addItem(LibraryActionMenuItem(title: "平均分配时间") { [weak self] in guard let self else { return }; (superview as? NativePlaylistRow)?.onTime?(entry.id, nil) }) }
        menu.addItem(LibraryActionMenuItem(title: "移除壁纸") { [weak self] in self?.onRemove?() }); return menu
    }
}
