import AppKit

/// Layout values read from the public Build 26168761 browser stylesheet.
/// The macOS title bar is outside these client-area measurements.
struct NativeLibraryBrowserGeometry {
    let viewportWidth: CGFloat
    var detailWidth: CGFloat {
        if viewportWidth >= 1900 { return 400 }
        if viewportWidth >= 400 && viewportWidth <= 950 { return 205 }
        return 320
    }
    var previewHeight: CGFloat { viewportWidth >= 400 && viewportWidth <= 950 ? 165 : 260 }
    var stackedHeader: Bool { viewportWidth <= 1050 }
    var headerHeight: CGFloat { stackedHeader ? 74 : 38 }
    var headerTextVisible: Bool { viewportWidth > 900 }
}

@MainActor
enum NativeLibraryBrowserStyle {
    /// A view's local Aqua/Dark-Aqua override remains useful to the existing
    /// unpresented layout fixtures.  The runtime only overrides that base
    /// palette for the two public seasonal skins, where AppKit still reports
    /// Dark Aqua and therefore cannot express the visual distinction itself.
    static func palette(_ appearance: NSAppearance) -> NativeInterfaceThemePalette {
        NativeInterfaceThemeRuntime.palette(for: appearance)
    }
    static func dark(_ appearance: NSAppearance) -> Bool { palette(appearance).theme != .white }
    static func background(_ appearance: NSAppearance) -> NSColor {
        palette(appearance).background
    }
    static func surface(_ appearance: NSAppearance) -> NSColor {
        palette(appearance).surface
    }
    static func cardBackground(_ appearance: NSAppearance) -> NSColor {
        palette(appearance).cardBackground
    }
    static func border(_ appearance: NSAppearance) -> NSColor {
        palette(appearance).border
    }
    static func accent(_ appearance: NSAppearance) -> NSColor {
        palette(appearance).accent
    }
    static func foreground(_ appearance: NSAppearance) -> NSColor {
        palette(appearance).foreground
    }
    static func mutedForeground(_ appearance: NSAppearance) -> NSColor {
        palette(appearance).mutedForeground
    }
    static func selectionFill(_ appearance: NSAppearance) -> NSColor {
        palette(appearance).selectionFill
    }
    static func font(_ size: CGFloat) -> NSFont { NSFont(name: "Arial", size: size) ?? .systemFont(ofSize: size) }
}

@MainActor
final class NativeLibraryBrowserSurface: NSView {
    var onWidthChanged: ((CGFloat) -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        let changed = frame.size.width != newSize.width
        super.setFrameSize(newSize)
        if changed { onWidthChanged?(newSize.width) }
    }
    override func draw(_ dirtyRect: NSRect) {
        NativeLibraryBrowserStyle.background(effectiveAppearance).setFill(); dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

@MainActor
final class NativeLibraryBrowserHeader: NSView {
    private let navigation: NativeLibraryNavigation
    private let controls = NSStackView()
    private let displayContext = NSView()
    private let displayContextTitle = NSTextField(labelWithString: "")
    private let chooseDisplay: NSButton
    private let mobile: NSButton
    private let displays: NSButton
    private let settings: NSButton
    private var geometry = NativeLibraryBrowserGeometry(viewportWidth: 1100)
    override var isFlipped: Bool { true }

    init(navigation: NativeLibraryNavigation, target: AnyObject, displaysAction: Selector, settingsAction: Selector) {
        self.navigation = navigation
        chooseDisplay = NSButton(title: "选择显示器", target: target, action: displaysAction)
        mobile = NSButton(title: "移动设备", target: nil, action: nil)
        displays = NSButton(title: "显示", target: target, action: displaysAction)
        settings = NSButton(title: "设置", target: target, action: settingsAction)
        super.init(frame: .zero)
        mobile.isEnabled = false
        mobile.toolTip = "移动设备连接尚未提供。"
        mobile.identifier = NSUserInterfaceItemIdentifier("browserMobileDevices")
        displays.identifier = NSUserInterfaceItemIdentifier("browserDisplays")
        settings.identifier = NSUserInterfaceItemIdentifier("browserSettings")
        settings.toolTip = "打开播放与节能设置。"
        for (button, symbol) in [(mobile, "iphone"), (displays, "display"), (settings, "gearshape")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel(button.title)
            button.bezelStyle = .rounded
            controls.addArrangedSubview(button)
        }
        controls.orientation = .horizontal; controls.spacing = 4
        displayContext.isHidden = true
        displayContext.identifier = NSUserInterfaceItemIdentifier("browserDisplayContext")
        displayContextTitle.font = NativeLibraryBrowserStyle.font(17)
        displayContextTitle.lineBreakMode = .byTruncatingTail
        displayContextTitle.identifier = NSUserInterfaceItemIdentifier("browserDisplayContextTitle")
        chooseDisplay.identifier = NSUserInterfaceItemIdentifier("browserChooseDisplay")
        chooseDisplay.setAccessibilityLabel("选择显示器")
        chooseDisplay.bezelStyle = .rounded
        displayContext.addSubview(displayContextTitle); displayContext.addSubview(chooseDisplay)
        addSubview(navigation); addSubview(displayContext); addSubview(controls)
    }
    required init?(coder: NSCoder) { nil }
    func updateGeometry(_ geometry: NativeLibraryBrowserGeometry) {
        self.geometry = geometry
        navigation.equalWidthTabs = geometry.stackedHeader
        for (button, title) in [(mobile, "移动设备"), (displays, "显示"), (settings, "设置")] {
            button.title = geometry.headerTextVisible ? title : ""
            button.imagePosition = geometry.headerTextVisible ? .imageLeading : .imageOnly
        }
        controls.distribution = geometry.stackedHeader ? .fillEqually : .fill
        needsLayout = true; needsDisplay = true
    }
    /// The official browser switches from the generic display control to a
    /// monitor heading with a “选择显示器” affordance while a concrete target
    /// is active.  `nil` restores the ordinary native default-wallpaper view.
    func setDisplayContext(title: String?) {
        let text = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        displayContext.isHidden = text.isEmpty
        displayContextTitle.stringValue = text.isEmpty ? "" : "显示器 " + text
        displayContextTitle.setAccessibilityLabel(displayContextTitle.stringValue)
        needsLayout = true; needsDisplay = true
    }
    override func layout() {
        super.layout()
        if geometry.stackedHeader {
            let controlsWidth = min(250, bounds.width)
            controls.frame = NSRect(x: 0, y: 0, width: controlsWidth, height: 26)
            displayContext.frame = NSRect(x: controls.frame.maxX + (displayContext.isHidden ? 0 : 8), y: 0,
                                          width: max(0, bounds.width - controls.frame.maxX - (displayContext.isHidden ? 0 : 8)), height: 26)
            navigation.frame = NSRect(x: 0, y: 29, width: bounds.width, height: 36)
        } else {
            navigation.frame = NSRect(x: 0, y: 1, width: navigation.intrinsicContentSize.width, height: 28)
            let controlsX = max(navigation.frame.maxX + 8, bounds.width - 250)
            controls.frame = NSRect(x: controlsX, y: 2,
                                    width: min(250, max(0, bounds.width - navigation.frame.maxX - 8)), height: 26)
            displayContext.frame = NSRect(x: navigation.frame.maxX + (displayContext.isHidden ? 0 : 8), y: 1,
                                          width: max(0, controls.frame.minX - navigation.frame.maxX - (displayContext.isHidden ? 0 : 16)), height: 28)
        }
        let buttonWidth = min(108, max(0, displayContext.bounds.width * 0.42))
        chooseDisplay.frame = NSRect(x: max(0, displayContext.bounds.width - buttonWidth), y: 0, width: buttonWidth, height: 26)
        displayContextTitle.frame = NSRect(x: 0, y: 3, width: max(0, chooseDisplay.frame.minX - 8), height: 22)
    }
    override func draw(_ dirtyRect: NSRect) {
        NativeLibraryBrowserStyle.accent(effectiveAppearance).setFill()
        NSRect(x: 0, y: bounds.height - 9, width: bounds.width, height: 3).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}
