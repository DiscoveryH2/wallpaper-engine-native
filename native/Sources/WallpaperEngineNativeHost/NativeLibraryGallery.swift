import AppKit

/// AppKit rendering for the official folder-decoration vocabulary.  Wallpaper
/// Engine uses Font Awesome glyphs on Windows; this native app intentionally
/// maps each persisted choice to a semantic SF Symbol instead.  The raw
/// choices and colors still match the verified official menu, but this helper
/// does not claim Font Awesome/Windows pixel parity.
@MainActor
enum NativeLibraryFolderPresentation {
    static func symbolNames(for icon: NativeLibraryFolders.FolderIcon?) -> [String] {
        switch icon {
        case nil: return ["folder.fill"]
        case .star: return ["star.fill"]
        case .heart: return ["heart.fill"]
        case .gem: return ["diamond.fill", "seal.fill"]
        case .car: return ["car.fill"]
        // `rocket.fill` is not shipped by every macOS SF Symbols catalog
        // supported by this app.  Keep the first candidate available on the
        // oldest observed host rather than silently showing the default folder
        // for the official rocket choice.
        case .rocket: return ["paperplane.fill"]
        case .snowflake: return ["snowflake"]
        case .thumbsUp: return ["hand.thumbsup.fill"]
        case .gamepad: return ["gamecontroller.fill"]
        case .gift: return ["gift.fill"]
        case .music: return ["music.note"]
        case .trash: return ["trash.fill"]
        case .bug: return ["ant.fill", "ladybug.fill"]
        case .magic: return ["wand.and.stars"]
        case .banana: return ["leaf.fill"]
        case .alien: return ["face.smiling.inverse"]
        case .alien8Bit: return ["cpu.fill"]
        case .bat: return ["bird.fill"]
        case .bomb: return ["burst.fill"]
        case .boombox: return ["hifispeaker.2.fill", "speaker.wave.3.fill"]
        case .candle: return ["flame.fill"]
        case .dragon: return ["tornado"]
        case .fire: return ["flame.fill"]
        case .meteor: return ["sparkle"]
        case .palm: return ["tree.fill"]
        case .skull: return ["theatermasks.fill"]
        case .christmasTree: return ["tree.fill"]
        case .retroTV: return ["tv.fill"]
        case .balloons: return ["balloon.2.fill", "circle.fill"]
        case .bone: return ["cross.case.fill", "circle.fill"]
        }
    }
    static func color(for color: NativeLibraryFolders.FolderColor?, fallback: NSColor) -> NSColor {
        guard let color else { return fallback }
        switch color {
        case .brightBlue: return NSColor(srgbRed: 0, green: 245.0 / 255, blue: 1, alpha: 1) // #00F5FF
        case .blue: return NSColor(srgbRed: 41.0 / 255, green: 115.0 / 255, blue: 243.0 / 255, alpha: 1) // #2973F3
        case .purple: return NSColor(srgbRed: 120.0 / 255, green: 12.0 / 255, blue: 1, alpha: 1) // #780CFF
        case .magenta: return NSColor(srgbRed: 204.0 / 255, green: 26.0 / 255, blue: 122.0 / 255, alpha: 1) // #CC1A7A
        case .red: return NSColor(srgbRed: 204.0 / 255, green: 26.0 / 255, blue: 0, alpha: 1) // #CC1A00
        case .yellow: return NSColor(srgbRed: 204.0 / 255, green: 122.0 / 255, blue: 0, alpha: 1) // #CC7A00
        case .brightYellow: return NSColor(srgbRed: 239.0 / 255, green: 218.0 / 255, blue: 0, alpha: 1) // #EFDA00
        case .green: return NSColor(srgbRed: 122.0 / 255, green: 204.0 / 255, blue: 0, alpha: 1) // #7ACC00
        case .darkGreen: return NSColor(srgbRed: 47.0 / 255, green: 103.0 / 255, blue: 68.0 / 255, alpha: 1) // #2F6744
        }
    }
    static func image(icon: NativeLibraryFolders.FolderIcon?, color: NativeLibraryFolders.FolderColor?, fallback: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [self.color(for: color, fallback: fallback)])
        for name in symbolNames(for: icon) {
            if let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
                return base.withSymbolConfiguration(configuration)
            }
        }
        return NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
    }
}

@MainActor
final class NativeLibraryGalleryLayout: NSCollectionViewLayout {
    private(set) var thumbnailSize: NativeLibraryThumbnailSize = .medium
    private var viewportWidth: CGFloat = 1100
    private var width: CGFloat = 0
    private var geometry = NativeLibraryThumbnailGeometry(viewportWidth: 1100, containerWidth: 0, count: 0, size: .medium)
    var columnCount: Int { geometry.columns }
    func configure(size: NativeLibraryThumbnailSize, viewportWidth: CGFloat) {
        guard thumbnailSize != size || self.viewportWidth != viewportWidth else { return }
        thumbnailSize = size; self.viewportWidth = viewportWidth; invalidateLayout()
    }
    func updateViewport(width: CGFloat) {
        if width > 0, self.width != width { self.width = width; invalidateLayout() }
    }
    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        geometry = NativeLibraryThumbnailGeometry(viewportWidth: viewportWidth, containerWidth: collectionView.bounds.width,
            count: collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0, size: thumbnailSize)
    }
    override var collectionViewContentSize: NSSize {
        NSSize(width: geometry.containerWidth, height: max(geometry.contentHeight, collectionView?.enclosingScrollView?.contentSize.height ?? 0))
    }
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { collectionView?.bounds.size != newBounds.size }
    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section == 0, let frame = geometry.frame(at: indexPath.item) else { return nil }
        let attributes = NSCollectionViewLayoutAttributes(forItemWith: indexPath); attributes.frame = frame; return attributes
    }
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        let start = max(0, Int(floor((rect.minY - 1) / geometry.rowStride))) * geometry.columns
        let end = min(geometry.count, max(0, Int(ceil((rect.maxY - 1) / geometry.rowStride)) + 1) * geometry.columns)
        guard start < end else { return [] }
        return (start..<end).compactMap { index in
            guard let attributes = layoutAttributesForItem(at: IndexPath(item: index, section: 0)), attributes.frame.intersects(rect) else { return nil }
            return attributes
        }
    }
}

/// The library's native, virtualized thumbnail browser. The owner decides
/// whether choosing an item applies it or stages a display assignment.
@MainActor
final class NativeLibraryGallery: NSCollectionView {
    var onChoose: ((Int?) -> Void)?
    var onModifiedChoose: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onActivate: (() -> Void)?
    var canActivate: ((Int) -> Bool)?
    var onSelectAll: (() -> Void)?
    var onNavigate: ((UInt16) -> Void)?
    var onRectangle: (([Int], NSEvent.ModifierFlags) -> Void)?
    var onBeginDrag: ((Int, NSEvent) -> Bool)?
    var onDragUpdate: ((NSDraggingInfo) -> NSDragOperation)?
    /// Separates payload authentication from a particular folder hit target.
    /// A valid internal drag may scroll across blank space to reveal a folder;
    /// the existing `onDragUpdate` continues to decide whether it may drop.
    var onDragAutoscrollValid: ((NSDraggingInfo) -> Bool)?
    var onDrop: ((NSDraggingInfo) -> Bool)?
    var onDragLeave: (() -> Void)?
    var onContextMenu: ((Int?) -> NSMenu?)?
    private var pointerDown: NSEvent?
    private var pointerIndex: Int?
    private var pointerMoved = false
    private var rectangleOrigin: NSPoint?
    private var selectionRectangle: NSRect?
    private let rectangleOverlay = NativeLibrarySelectionOverlay()
    private let dragAutoscroll = NativeLibraryDragAutoscroll()

    func configureDragAutoscroll(in scrollView: NSScrollView?) {
        dragAutoscroll.configure(scrollView: scrollView)
    }
    func cancelDragAutoscroll() { dragAutoscroll.stop() }
    var isDragAutoscrolling: Bool { dragAutoscroll.isRunning }
    @discardableResult func advanceDragAutoscrollForTesting() -> Bool { dragAutoscroll.step() }

    /// Reflow only: retain selection, loaded images and the first visible item.
    /// This must not invoke the owner's choose/download/preview callbacks.
    func updateThumbnailPresentation(size: NativeLibraryThumbnailSize, viewportWidth: CGFloat) {
        guard let layout = collectionViewLayout as? NativeLibraryGalleryLayout else { return }
        let anchor = layout.layoutAttributesForElements(in: visibleRect).min { $0.indexPath!.item < $1.indexPath!.item }
        let relativeOffset = anchor.map { visibleRect.minY - $0.frame.minY }
        let clippedFraction = anchor.map { max(0, visibleRect.minY - $0.frame.minY) / max(1, $0.frame.height) }
        layout.configure(size: size, viewportWidth: viewportWidth)
        layoutSubtreeIfNeeded()
        for case let cell as NativeLibraryGalleryItem in visibleItems() { cell.setThumbnailSize(size) }
        if let path = anchor?.indexPath, let offset = relativeOffset, let fraction = clippedFraction,
           let frame = layout.layoutAttributesForItem(at: path)?.frame,
           let scroll = enclosingScrollView {
            // A partially clipped large card may have an offset greater than
            // the entire new small card. Preserve its visible fraction instead
            // of carrying over the old number of points and skipping the card.
            let y = min(max(0, frame.minY + fraction * frame.height + min(0, offset)), max(0, layout.collectionViewContentSize.height - scroll.contentSize.height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        (collectionViewLayout as? NativeLibraryGalleryLayout)?.updateViewport(width: newSize.width)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), onContextMenu != nil { rightMouseDown(with: event); return }
        window?.makeFirstResponder(self)
        cancelPointer()
        pointerDown = event
        let point = convert(event.locationInWindow, from: nil)
        pointerIndex = indexPathForItem(at: point)?.item
        rectangleOrigin = point
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down = pointerDown, let origin = rectangleOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard pointerMoved || hypot(point.x-origin.x,point.y-origin.y) >= 4 else { return }
        if let index = pointerIndex {
            guard !pointerMoved else { return }; pointerMoved = true
            _ = onBeginDrag?(index,event)
        } else if onRectangle != nil {
            pointerMoved = true; autoscroll(with:event)
            let rect = NSRect(x:min(origin.x,point.x),y:min(origin.y,point.y),width:abs(point.x-origin.x),height:abs(point.y-origin.y)).intersection(bounds)
            selectionRectangle = rect
            if rectangleOverlay.superview == nil { addSubview(rectangleOverlay,positioned:.above,relativeTo:nil) }
            rectangleOverlay.frame = rect; rectangleOverlay.needsDisplay = true
        }
        _ = down
    }
    override func mouseUp(with event: NSEvent) {
        guard let down = pointerDown else { return }
        let index = pointerIndex, moved = pointerMoved, rect = selectionRectangle
        cancelPointer()
        if let rect, moved {
            let indexes = (collectionViewLayout?.layoutAttributesForElements(in:rect) ?? []).filter {
                $0.representedElementCategory == .item && $0.frame.intersects(rect)
            }.compactMap { $0.indexPath?.item }.sorted()
            onRectangle?(indexes,down.modifierFlags); return
        }
        guard !moved, let index, indexPathForItem(at:convert(event.locationInWindow,from:nil))?.item == index else { return }
        let activate = canActivate?(index) ?? true
        if let onModifiedChoose { onModifiedChoose(index,down.modifierFlags) } else { onChoose?(index) }
        if event.clickCount == 2, activate, down.modifierFlags.intersection([.command,.shift]).isEmpty { onActivate?() }
    }
    private func cancelPointer() {
        pointerDown = nil; pointerIndex = nil; pointerMoved = false; rectangleOrigin = nil; selectionRectangle = nil
        rectangleOverlay.removeFromSuperview()
    }
    override func rightMouseDown(with event: NSEvent) {
        let index = indexPathForItem(at: convert(event.locationInWindow, from: nil))?.item
        if let menu = onContextMenu?(index) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        else { super.rightMouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "a", let onSelectAll { onSelectAll(); return }
        if event.keyCode == 53 { cancelPointer(); cancelDragAutoscroll(); return }
        if [123,124,125,126].contains(event.keyCode), let onNavigate { onNavigate(event.keyCode); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if !selectionIndexPaths.isEmpty { onActivate?() }
        } else { super.keyDown(with: event) }
    }
    override func selectAll(_ sender: Any?) {
        if let onSelectAll { onSelectAll() } else { super.selectAll(sender) }
    }
    private func updateDragging(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = onDragUpdate?(sender) ?? []
        let location = convert(sender.draggingLocation, from: nil)
        dragAutoscroll.update(location: location, in: self, permitted: onDragAutoscrollValid?(sender) ?? false)
        return operation
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDragging(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDragging(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { cancelDragAutoscroll(); onDragLeave?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { updateDragging(sender).isEmpty == false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { cancelDragAutoscroll(); onDragLeave?() }
        return onDrop?(sender) ?? false
    }
    /// The viewport can advance under a stationary drag pointer. Ask AppKit to
    /// resend `draggingUpdated` so a newly revealed folder becomes a valid
    /// drop target without requiring the user to jiggle the mouse.
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelDragAutoscroll() }
    }
}

@MainActor
private final class NativeLibrarySelectionOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NativeLibraryBrowserStyle.selectionFill(effectiveAppearance).withAlphaComponent(0.54).setFill(); bounds.fill()
        NativeLibraryBrowserStyle.accent(effectiveAppearance).setStroke(); NSBezierPath(rect:bounds.insetBy(dx:0.5,dy:0.5)).stroke()
    }
}

@MainActor
final class NativeLibraryDragSource: NSObject, NSDraggingSource {
    var onEnded: (() -> Void)?
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { onEnded?() }
}

@MainActor
final class NativeLibraryGalleryItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("nativeWallpaperThumbnail")
    private var card: NativeLibraryCard { view as! NativeLibraryCard }
    var representedIdentity: String? { card.identity }

    override func loadView() { view = NativeLibraryCard() }
    override var isSelected: Bool {
        didSet {
            card.selected = isSelected
            card.setAccessibilitySelected(isSelected)
        }
    }
    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { card.highlighted = highlightState == .forSelection }
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        card.identity = nil; card.thumbnail = nil; card.onChoose = nil; card.badges = []; card.hovered = false
    }
    func configure(identity: String, title: String, type: String, state: String,
                   current: Bool, available: Bool, folder: Bool = false, badges: [NativeLibraryThumbnailBadge] = [],
                   folderIcon: NativeLibraryFolders.FolderIcon? = nil, folderColor: NativeLibraryFolders.FolderColor? = nil,
                   size: NativeLibraryThumbnailSize = .medium, onChoose: @escaping () -> Void) {
        card.identity = identity; card.title = title; card.type = type
        card.state = state; card.current = current; card.available = available; card.folder = folder
        card.dropTarget = false
        card.folderIcon = folderIcon; card.folderColor = folderColor
        card.badges = badges; card.thumbnailSize = size; card.hovered = false
        card.thumbnail = nil; card.onChoose = onChoose
        let status = ([state] + badges.map(\.title)).joined(separator: " · ")
        card.setAccessibilityLabel(title + "，" + type + "，" + status)
        card.toolTip = title + "\n" + type + " · " + status
        card.needsDisplay = true
    }
    func setThumbnail(_ image: NSImage?) { card.thumbnail = image }
    func setDropTarget(_ value: Bool) { card.dropTarget = value }
    func setThumbnailSize(_ value: NativeLibraryThumbnailSize) { card.thumbnailSize = value; card.needsDisplay = true }
}

@MainActor
private final class NativeLibraryCard: NSView {
    var identity: String?
    var title = ""
    var type = ""
    var state = ""
    var current = false
    var folder = false
    var folderIcon: NativeLibraryFolders.FolderIcon?
    var folderColor: NativeLibraryFolders.FolderColor?
    var available = true
    var thumbnailSize: NativeLibraryThumbnailSize = .medium
    var badges: [NativeLibraryThumbnailBadge] = []
    var hovered = false { didSet { needsDisplay = true } }
    private var hoverTracking: NSTrackingArea?
    var onChoose: (() -> Void)?
    var selected = false { didSet { needsDisplay = true } }
    var highlighted = false { didSet { needsDisplay = true } }
    var dropTarget = false { didSet { needsDisplay = true } }
    var thumbnail: NSImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.cell)
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); hoverTracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func accessibilityPerformPress() -> Bool {
        guard let onChoose else { return false }
        onChoose(); return true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds
        NativeLibraryBrowserStyle.cardBackground(effectiveAppearance).setFill(); frame.fill()
        if folder {
            let icon = NativeLibraryFolderPresentation.image(icon: folderIcon, color: folderColor,
                fallback: NativeLibraryBrowserStyle.accent(effectiveAppearance))
            let side: CGFloat = thumbnailSize == .small ? 70 : thumbnailSize == .large ? 154 : 112
            icon?.draw(in: NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else if let image = thumbnail, image.size.width > 0, image.size.height > 0 {
            let width = frame.width * (hovered ? 1.2 : 1.01), height = width * image.size.height / image.size.width
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: frame).addClip()
            image.draw(in: NSRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height),
                       from: .zero, operation: .sourceOver, fraction: available ? 1 : 0.6,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            symbol?.draw(in: NSRect(x: frame.midX - 18, y: frame.midY - 27, width: 36, height: 30),
                         from: .zero, operation: .sourceOver, fraction: 0.35, respectFlipped: true, hints: nil)
        }
        if dropTarget {
            NSColor.systemGreen.setStroke()
            let border = NSBezierPath(rect:frame.insetBy(dx:2,dy:2)); border.lineWidth = 4; border.stroke()
        }
        let caption = NSRect(x: frame.minX, y: frame.maxY - 40, width: frame.width, height: 40)
        NSColor.black.withAlphaComponent(hovered ? 0.2 : 0.5).setFill(); caption.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping; paragraph.alignment = .center
        let text = NSAttributedString(string: title, attributes: [
            .font: NativeLibraryBrowserStyle.font(11.2), .foregroundColor: hovered ? NSColor.white : NSColor(white: 187.0 / 255, alpha: 1),
            .paragraphStyle: paragraph
        ])
        let textHeight = min(28, ceil(text.boundingRect(with: NSSize(width: max(1, caption.width - 4), height: 28),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]).height))
        text.draw(with: NSRect(x: caption.minX + 2, y: caption.midY - textHeight / 2 + 1.5, width: max(1, caption.width - 4), height: textHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if !badges.isEmpty {
            let badge = NSRect(x: frame.minX, y: frame.minY + 6, width: CGFloat(badges.count) * 15 + 11, height: 18)
            NSColor.black.withAlphaComponent(hovered ? 0.2 : 0.5).setFill(); NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
            for (index, value) in badges.enumerated() {
                let color: NSColor = value == .approved ? .systemYellow : value == .favorite ? .systemRed : .white
                let icon = NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
                icon?.draw(in: NSRect(x: badge.minX + 6 + CGFloat(index) * 15, y: badge.minY + 2, width: 13, height: 13),
                    from: .zero, operation: .sourceOver, fraction: hovered ? 0.4 : 1, respectFlipped: true, hints: nil)
            }
        }
        if selected || highlighted {
            NativeLibraryBrowserStyle.accent(effectiveAppearance).setStroke()
            let outline = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            outline.lineWidth = 3; outline.stroke()
        }
    }
}

@MainActor
final class NativeLibraryTable: NSTableView {
    var onContextMenu: ((Int?) -> NSMenu?)?
    var onChoose: ((Int,NSEvent.ModifierFlags) -> Void)?
    var onActivate: (() -> Void)?
    var canActivate: ((Int) -> Bool)?
    var onSelectAll: (() -> Void)?
    var onNavigate: ((UInt16) -> Void)?
    var onBeginDrag: ((Int,NSEvent) -> Bool)?
    var onDragUpdate: ((NSDraggingInfo) -> NSDragOperation)?
    var onDragAutoscrollValid: ((NSDraggingInfo) -> Bool)?
    var onDrop: ((NSDraggingInfo) -> Bool)?
    var onDragLeave: (() -> Void)?
    private let dragAutoscroll = NativeLibraryDragAutoscroll()
    private var down: NSEvent?
    private var downRow = -1
    private var moved = false
    func configureDragAutoscroll(in scrollView: NSScrollView?) {
        dragAutoscroll.configure(scrollView: scrollView)
    }
    func cancelDragAutoscroll() { dragAutoscroll.stop() }
    var isDragAutoscrolling: Bool { dragAutoscroll.isRunning }
    @discardableResult func advanceDragAutoscrollForTesting() -> Bool { dragAutoscroll.step() }
    override func rightMouseDown(with event: NSEvent) {
        let index = row(at: convert(event.locationInWindow, from: nil))
        if let menu = onContextMenu?(index < 0 ? nil : index) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        else { super.rightMouseDown(with: event) }
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), onContextMenu != nil { rightMouseDown(with: event) }
        else {
            window?.makeFirstResponder(self); down = event; moved = false
            downRow = row(at:convert(event.locationInWindow,from:nil))
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, downRow >= 0, !moved, hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y) >= 4 else { return }
        moved = true; _ = onBeginDrag?(downRow,event)
    }
    override func mouseUp(with event: NSEvent) {
        defer { down = nil; moved = false; downRow = -1 }
        guard let down, !moved, downRow >= 0, row(at:convert(event.locationInWindow,from:nil)) == downRow else { return }
        let activate = canActivate?(downRow) ?? true
        onChoose?(downRow,down.modifierFlags)
        if event.clickCount == 2,activate,down.modifierFlags.intersection([.command,.shift]).isEmpty { onActivate?() }
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),event.charactersIgnoringModifiers?.lowercased() == "a",let onSelectAll { onSelectAll(); return }
        if [123,124,125,126].contains(event.keyCode),let onNavigate { onNavigate(event.keyCode); return }
        if event.keyCode == 36 || event.keyCode == 76 { onActivate?(); return }
        super.keyDown(with:event)
    }
    override func selectAll(_ sender: Any?) {
        if let onSelectAll { onSelectAll() } else { super.selectAll(sender) }
    }
    private func updateDragging(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = onDragUpdate?(sender) ?? []
        let location = convert(sender.draggingLocation, from: nil)
        dragAutoscroll.update(location: location, in: self, permitted: onDragAutoscrollValid?(sender) ?? false)
        return operation
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDragging(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDragging(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { cancelDragAutoscroll(); onDragLeave?() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { updateDragging(sender).isEmpty == false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { cancelDragAutoscroll(); onDragLeave?() }
        return onDrop?(sender) ?? false
    }
    /// See NativeLibraryGallery: timer-driven viewport movement must refresh
    /// the table row beneath a stationary system drag pointer.
    override func wantsPeriodicDraggingUpdates() -> Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelDragAutoscroll() }
    }
}
