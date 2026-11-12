import AppKit

/// A display value purpose-built for the browser's monitor map.  It leaves
/// `NativeDisplayDescriptor` and the persisted layout model untouched while
/// allowing the map to be supplied with deterministic fixtures in GUI checks.
@MainActor
struct NativeMonitorSelectionDisplay: Equatable {
    let key: String
    let name: String
    let frame: CGRect
    let summary: String

    init(key: String, name: String, frame: CGRect, summary: String? = nil) {
        self.key = key
        self.name = name
        self.frame = frame
        self.summary = summary ?? name
    }

    static func connected() -> [Self] {
        NativeDisplayDescriptor.connected().map {
            .init(key: $0.key, name: $0.name, frame: $0.screen.frame, summary: $0.summary)
        }
    }
}

@MainActor
private final class NativeMonitorSelectionSurface: NSView {
    weak var card: NSView?
    var onDismiss: (() -> Void)?
    var onLayout: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func layout() {
        super.layout(); onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(NativeLibraryBrowserStyle.dark(effectiveAppearance) ? 0.48 : 0.34).setFill()
        dirtyRect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if card?.frame.contains(point) != true { onDismiss?() }
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

@MainActor
private final class NativeMonitorSelectionCard: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        NativeLibraryBrowserStyle.surface(effectiveAppearance).withAlphaComponent(0.98).setFill()
        path.fill()
        NativeLibraryBrowserStyle.border(effectiveAppearance).withAlphaComponent(0.72).setStroke()
        path.lineWidth = 1; path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

@MainActor
private final class NativeMonitorMapButton: NSButton {
    let display: NativeMonitorSelectionDisplay
    var selected = false { didSet { refreshAppearance() } }

    init(display: NativeMonitorSelectionDisplay, index: Int, target: AnyObject?, action: Selector) {
        self.display = display
        super.init(frame: .zero)
        identifier = .init("monitorSelectionDisplay\(index)")
        title = "显示器 \(index + 1)\n\(display.name)"
        toolTip = display.summary
        self.target = target; self.action = action
        isBordered = false
        imagePosition = .noImage
        font = NativeLibraryBrowserStyle.font(13)
        alignment = .center
        lineBreakMode = .byTruncatingTail
        setAccessibilityLabel("显示器 \(index + 1)：\(display.name)")
        setAccessibilityHelp(display.summary)
        wantsLayer = true
        layer?.cornerRadius = 4
        refreshAppearance()
    }
    required init?(coder: NSCoder) { nil }

    func refreshAppearance() {
        guard let layer else { return }
        let palette = NativeLibraryBrowserStyle.palette(effectiveAppearance)
        let dark = palette.theme != .white
        let accent = NativeLibraryBrowserStyle.accent(effectiveAppearance)
        layer.borderWidth = selected ? 2 : 1
        layer.borderColor = (selected ? accent : palette.border.withAlphaComponent(dark ? 0.82 : 0.72)).cgColor
        layer.backgroundColor = (selected ? accent.withAlphaComponent(dark ? 0.34 : 0.19) : palette.cardBackground.withAlphaComponent(dark ? 0.9 : 0.96)).cgColor
        contentTintColor = selected ? NativeLibraryBrowserStyle.foreground(effectiveAppearance) : NativeLibraryBrowserStyle.foreground(effectiveAppearance).withAlphaComponent(0.9)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); refreshAppearance()
    }
}

/// True screen-relative monitor geometry.  macOS uses a bottom-left global
/// screen coordinate system; this flipped view inverts Y while retaining every
/// relative offset and aspect ratio.
@MainActor
private final class NativeMonitorSelectionMap: NSView {
    var onSelect: ((String) -> Void)?
    private var displays: [NativeMonitorSelectionDisplay] = []
    private var selectedKey: String?
    private var buttons: [NativeMonitorMapButton] = []

    override var isFlipped: Bool { true }

    func reload(_ displays: [NativeMonitorSelectionDisplay], selectedKey: String?) {
        self.displays = displays
        self.selectedKey = selectedKey
        buttons.forEach { $0.removeFromSuperview() }
        buttons = displays.enumerated().map { index, display in
            NativeMonitorMapButton(display: display, index: index, target: self, action: #selector(selectDisplay(_:)))
        }
        buttons.forEach(addSubview)
        needsLayout = true
    }

    func select(_ key: String?) {
        selectedKey = key
        for button in buttons { button.selected = button.display.key == key }
    }

    func refreshTheme() {
        for button in buttons { button.refreshAppearance() }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard !displays.isEmpty else { return }
        let union = displays.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        guard !union.isNull, union.width > 0, union.height > 0 else { return }
        let inset: CGFloat = 18
        let available = NSSize(width: max(1, bounds.width - inset * 2), height: max(1, bounds.height - inset * 2))
        let scale = min(available.width / union.width, available.height / union.height)
        for button in buttons {
            let frame = button.display.frame
            let x = inset + (frame.minX - union.minX) * scale
            let y = inset + (union.maxY - frame.maxY) * scale
            button.frame = NSRect(x: x, y: y, width: max(38, frame.width * scale), height: max(28, frame.height * scale)).integral
            button.selected = button.display.key == selectedKey
        }
    }

    @objc private func selectDisplay(_ sender: NativeMonitorMapButton) { onSelect?(sender.display.key) }
}

/// Native counterpart of the browser's `browseMonitorSelectionContainer`.
/// It is intentionally an overlay inside the Library window's content view,
/// not an NSPanel/sheet.  Applying a picked project remains the Library and
/// runtime's responsibility; this component only selects the concrete screen
/// context and forwards formal actions through explicit callbacks.
@MainActor
final class NativeMonitorSelectionController: NSObject {
    var onSelectTarget: ((String) -> Void)?
    var onRemoveTarget: ((String) async throws -> Void)?
    var onShowProfiles: ((Bool) -> Void)?

    private let displaysProvider: () -> [NativeMonitorSelectionDisplay]
    private let layoutProvider: () -> NativeDisplayLayout
    private let surface = NativeMonitorSelectionSurface()
    private let card = NativeMonitorSelectionCard()
    private let dismiss = NSButton()
    private let heading = NSTextField(labelWithString: "选择显示器")
    private let profileLoad = NSButton(title: "加载配置文件", target: nil, action: nil)
    private let profileSave = NSButton(title: "保存配置文件", target: nil, action: nil)
    private let map = NativeMonitorSelectionMap()
    private let current = NSTextField(wrappingLabelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private lazy var change = NativeLibraryFooterButton(title: "更换壁纸", primary: true, symbol: nil, target: self, action: #selector(changeWallpaper))
    private lazy var remove = NativeLibraryFooterButton(title: "移除壁纸", primary: false, symbol: nil, target: self, action: #selector(removeWallpaper))
    private weak var parentWindow: NSWindow?
    private var displays: [NativeMonitorSelectionDisplay] = []
    private var layout = NativeDisplayLayout()
    private var selectedKey: String?
    private var busy = false
    private var request = UUID()
    private var task: Task<Void, Never>?
    private var themeObserver: NSObjectProtocol?

    var isVisible: Bool { surface.superview != nil && !surface.isHidden }

    /// Default closures are selected inside this MainActor initializer rather
    /// than as parameter defaults: Swift evaluates default arguments from a
    /// nonisolated caller context even when the initializer itself is actor
    /// isolated.
    init(displays: (() -> [NativeMonitorSelectionDisplay])? = nil,
         layout: (() -> NativeDisplayLayout)? = nil) {
        displaysProvider = displays ?? { NativeMonitorSelectionDisplay.connected() }
        layoutProvider = layout ?? { NativeDisplayStore.load() }
        super.init()
        surface.identifier = .init("nativeMonitorSelectionOverlay")
        surface.card = card
        surface.onDismiss = { [weak self] in self?.close() }
        surface.onLayout = { [weak self] in self?.layoutViews() }
        card.identifier = .init("monitorSelectionContainer")
        surface.addSubview(card)

        dismiss.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "关闭选择显示器")
        dismiss.imagePosition = .imageOnly; dismiss.bezelStyle = .texturedRounded
        dismiss.identifier = .init("monitorSelectionClose")
        dismiss.setAccessibilityLabel("关闭选择显示器")
        dismiss.target = self; dismiss.action = #selector(closeSelection)
        heading.font = NativeLibraryBrowserStyle.font(25)
        heading.identifier = .init("monitorSelectionTitle")

        profileLoad.identifier = .init("monitorSelectionLoadProfile")
        profileSave.identifier = .init("monitorSelectionSaveProfile")
        profileLoad.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        profileSave.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        profileLoad.imagePosition = .imageLeading; profileSave.imagePosition = .imageLeading
        profileLoad.target = self; profileLoad.action = #selector(loadProfile)
        profileSave.target = self; profileSave.action = #selector(saveProfile)

        map.identifier = .init("monitorSelectionMap")
        map.wantsLayer = true; map.layer?.cornerRadius = 5
        map.layer?.borderWidth = 1
        map.onSelect = { [weak self] key in self?.select(key) }

        current.identifier = .init("monitorSelectionCurrent")
        current.font = NativeLibraryBrowserStyle.font(14)
        current.alignment = .center; current.maximumNumberOfLines = 2
        status.identifier = .init("monitorSelectionStatus")
        status.font = NativeLibraryBrowserStyle.font(12)
        status.alignment = .center; status.maximumNumberOfLines = 2
        status.textColor = .secondaryLabelColor

        change.identifier = .init("monitorSelectionChangeWallpaper")
        remove.identifier = .init("monitorSelectionRemoveWallpaper")

        [dismiss, heading, profileLoad, profileSave, map, current, status, change, remove].forEach(card.addSubview)
        themeObserver = NotificationCenter.default.addObserver(forName: NativeInterfaceThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTheme() }
        }
    }

    convenience init(descriptors: @escaping () -> [NativeDisplayDescriptor], layout: (() -> NativeDisplayLayout)? = nil) {
        self.init(displays: {
            descriptors().map { .init(key: $0.key, name: $0.name, frame: $0.screen.frame, summary: $0.summary) }
        }, layout: layout)
    }

    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }

    func present(on window: NSWindow, selectedKey: String? = nil) {
        close()
        guard let content = window.contentView else { return }
        parentWindow = window
        surface.frame = content.bounds
        surface.autoresizingMask = [.width, .height]
        content.addSubview(surface)
        self.selectedKey = selectedKey
        refresh(preservingStatus: false)
        window.makeFirstResponder(surface)
    }

    func close() {
        request = UUID()
        task?.cancel(); task = nil
        busy = false
        if parentWindow?.firstResponder === surface { parentWindow?.makeFirstResponder(nil) }
        surface.removeFromSuperview()
        parentWindow = nil
    }

    private func refresh(preservingStatus: Bool) {
        displays = displaysProvider().filter { !$0.key.isEmpty && !$0.frame.isNull && $0.frame.width > 0 && $0.frame.height > 0 }
        layout = layoutProvider()
        if selectedKey.flatMap({ key in displays.contains(where: { $0.key == key }) ? key : nil }) == nil {
            selectedKey = displays.first?.key
        }
        map.reload(displays, selectedKey: selectedKey)
        refreshTheme()
        profileLoad.isEnabled = !busy && onShowProfiles != nil
        profileSave.isEnabled = !busy && onShowProfiles != nil
        change.isEnabled = !busy && selectedKey != nil && onSelectTarget != nil
        remove.isEnabled = !busy && selectedKey.flatMap { layout.displays[$0] } != nil && onRemoveTarget != nil
        if !preservingStatus { status.stringValue = "" }
        updateCurrentLabel()
        layoutViews()
    }

    /// Calendar-driven Halloween/Winter changes retain Dark Aqua, so AppKit
    /// does not call `viewDidChangeEffectiveAppearance`.  Refresh the few
    /// layer-backed controls explicitly when the theme runtime announces a
    /// palette transition.
    private func refreshTheme() {
        let palette = NativeLibraryBrowserStyle.palette(card.effectiveAppearance)
        let dark = palette.theme != .white
        map.layer?.backgroundColor = palette.cardBackground.withAlphaComponent(dark ? 0.74 : 0.96).cgColor
        map.layer?.borderColor = palette.border.withAlphaComponent(dark ? 0.72 : 0.62).cgColor
        map.refreshTheme()
        surface.needsDisplay = true; card.needsDisplay = true
        heading.textColor = palette.foreground
        current.textColor = palette.foreground
        status.textColor = palette.mutedForeground
    }

    private func updateCurrentLabel() {
        guard let key = selectedKey, let index = displays.firstIndex(where: { $0.key == key }) else {
            current.stringValue = "尚未发现可选择的显示器"
            change.isEnabled = false; remove.isEnabled = false
            if status.stringValue.isEmpty { status.stringValue = "连接显示器后可在此选择目标屏幕。" }
            return
        }
        let display = displays[index]
        let assignment = layout.displays[key]
        let detail: String
        if assignment?.enabled == false { detail = "未配置动态壁纸" }
        else if let title = assignment?.projectTitle, !title.isEmpty { detail = "当前壁纸：\(title)" }
        else if assignment?.projectPath != nil { detail = "当前壁纸：独立壁纸" }
        else { detail = "当前壁纸：默认壁纸" }
        current.stringValue = "显示器 \(index + 1) · \(display.name)\n\(detail)"
        current.toolTip = display.summary
    }

    private func layoutViews() {
        guard surface.superview != nil else { return }
        let outer = surface.bounds
        let width = min(max(420, outer.width - 48), 700)
        let height = min(max(360, outer.height - 42), 570)
        card.frame = NSRect(x: max(12, (outer.width - width) / 2), y: max(12, (outer.height - height) / 2), width: width, height: height).integral
        dismiss.frame = NSRect(x: 16, y: 13, width: 30, height: 28)
        heading.frame = NSRect(x: 55, y: 15, width: max(80, width - 70), height: 30)
        profileLoad.frame = NSRect(x: 20, y: 60, width: 132, height: 28)
        profileSave.frame = NSRect(x: 160, y: 60, width: 132, height: 28)
        let mapTop: CGFloat = 104
        let footerHeight: CGFloat = 116
        map.frame = NSRect(x: 20, y: mapTop, width: max(1, width - 40), height: max(92, height - mapTop - footerHeight))
        current.frame = NSRect(x: 20, y: map.frame.maxY + 4, width: max(1, width - 40), height: 32)
        status.frame = NSRect(x: 20, y: current.frame.maxY + 2, width: max(1, width - 40), height: 16)
        let actionWidth: CGFloat = 112
        remove.frame = NSRect(x: width - 20 - actionWidth, y: height - 36, width: actionWidth, height: 26)
        change.frame = NSRect(x: remove.frame.minX - actionWidth - 8, y: height - 36, width: actionWidth, height: 26)
        map.needsLayout = true
    }

    private func select(_ key: String) {
        guard !busy, displays.contains(where: { $0.key == key }) else { return }
        selectedKey = key
        map.select(key)
        status.stringValue = ""
        updateCurrentLabel()
    }

    @objc private func closeSelection() { close() }
    @objc private func loadProfile() { onShowProfiles?(false) }
    @objc private func saveProfile() { onShowProfiles?(true) }

    @objc private func changeWallpaper() {
        guard !busy, let key = selectedKey, let action = onSelectTarget else {
            if !busy { status.stringValue = "此版本尚未连接显示器目标选择。" }
            return
        }
        action(key)
        // The target is persistent in LibraryController; closing only removes
        // this visual overlay, never clears the selected display context.
        close()
    }

    @objc private func removeWallpaper() {
        guard !busy, let key = selectedKey, let action = onRemoveTarget else {
            if !busy { status.stringValue = "此版本尚未连接移除显示器壁纸的操作。" }
            return
        }
        let currentRequest = UUID()
        request = currentRequest; busy = true
        status.stringValue = "正在移除这块屏幕的壁纸…"
        refresh(preservingStatus: true)
        task = Task { [weak self] in
            do {
                try await action(key)
                try Task.checkCancellation()
                guard let self, self.request == currentRequest, self.isVisible else { return }
                self.busy = false; self.task = nil
                self.status.stringValue = "已移除这块屏幕的独立壁纸。"
                self.refresh(preservingStatus: true)
            } catch is CancellationError {
                guard let self, self.request == currentRequest, self.isVisible else { return }
                self.busy = false; self.task = nil
                self.status.stringValue = "本次移除已取消。"
                self.refresh(preservingStatus: true)
            } catch {
                guard let self, self.request == currentRequest, self.isVisible else { return }
                self.busy = false; self.task = nil
                self.status.stringValue = "未移除，保留原壁纸：" + error.localizedDescription
                self.refresh(preservingStatus: true)
            }
        }
    }
}
