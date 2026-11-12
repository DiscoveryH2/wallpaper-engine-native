import AppKit

/// The shared browser chrome. Each page keeps its own selection and query.
@MainActor
final class NativeLibraryNavigation: NSView {
    enum Page: Int, CaseIterable { case installed, discover, workshop }
    var onSelect: ((Page) -> Void)?
    private(set) var selected: Page = .installed
    private(set) var buttons: [NSButton] = []
    var equalWidthTabs = false { didSet { needsLayout = true } }
    override var intrinsicContentSize: NSSize {
        NSSize(width: buttons.reduce(0) { $0 + $1.intrinsicContentSize.width } + 8, height: 34)
    }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        let titles = ["已安装", "发现", "创意工坊"]
        for page in Page.allCases {
            let button = NativeLibraryTab(title: titles[page.rawValue], target: self, action: #selector(selectTab(_:)))
            button.tag = page.rawValue
            button.setAccessibilityLabel(titles[page.rawValue])
            button.identifier = NSUserInterfaceItemIdentifier("wallpaperTab" + String(page.rawValue))
            addSubview(button); buttons.append(button)
        }
        setSelected(.installed)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for button in buttons {
            let width = equalWidthTabs ? floor((bounds.width - 8) / 3) : button.intrinsicContentSize.width
            button.frame = NSRect(x: x, y: button.state == .on ? 0 : 2, width: width, height: button.state == .on ? bounds.height : bounds.height - 2)
            x += width + 4
        }
    }
    func setSelected(_ page: Page) {
        selected = page
        for button in buttons {
            button.state = button.tag == page.rawValue ? .on : .off
            button.setAccessibilityValue(button.state == .on ? 1 : 0)
            button.needsDisplay = true
        }
        needsLayout = true
    }
    @objc private func selectTab(_ sender: NSButton) {
        guard let page = Page(rawValue: sender.tag) else { return }
        onSelect?(page)
    }
}

private final class NativeLibraryTab: NSButton {
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(title.size(withAttributes: [.font: NativeLibraryBrowserStyle.font(16.8)]).width) + 34, height: 34)
    }
    override func draw(_ dirtyRect: NSRect) {
        let selected = state == .on
        let blue = NativeLibraryBrowserStyle.accent(effectiveAppearance)
        (selected ? blue : NativeLibraryBrowserStyle.background(effectiveAppearance)).setFill()
        bounds.fill()
        blue.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1; border.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NativeLibraryBrowserStyle.font(16.8),
            .foregroundColor: selected ? NSColor.white : NativeLibraryBrowserStyle.foreground(effectiveAppearance)
        ]
        let size = title.size(withAttributes: attributes)
        let start = (bounds.width - size.width - 20) / 2
        let symbol = ["internaldrive", "safari", "square.grid.2x2"][max(0, min(2, tag))]
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(paletteColors: [selected ? .white : NativeLibraryBrowserStyle.foreground(effectiveAppearance)]))
        icon?.draw(in: NSRect(x: start, y: (bounds.height - 15) / 2, width: 15, height: 15))
        title.draw(at: NSPoint(x: start + 20, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)); focus.lineWidth = 2; focus.stroke()
        }
    }
}
