import AppKit

/// Client-area geometry and colors measured from public Build 26168761.
/// Native input/accessibility remain NSButton behavior; no official UI code runs.
@MainActor
final class NativeLibraryFooter: NSView {
    let editor: NativeLibraryFooterButton
    let open: NativeLibraryFooterButton
    let confirm: NativeLibraryFooterButton
    let cancel: NativeLibraryFooterButton
    private var compact = false

    init(target: AnyObject, editorAction: Selector, openAction: Selector, confirmAction: Selector, cancelAction: Selector) {
        editor = NativeLibraryFooterButton(title: "壁纸编辑器", primary: true, symbol: "pencil.and.ruler", target: target, action: editorAction)
        open = NativeLibraryFooterButton(title: "打开壁纸", primary: false, symbol: "tray.and.arrow.up", target: target, action: openAction)
        confirm = NativeLibraryFooterButton(title: "确认", primary: true, symbol: nil, target: target, action: confirmAction)
        cancel = NativeLibraryFooterButton(title: "取消", primary: false, symbol: nil, target: target, action: cancelAction)
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("browserFooterActions")
        for (button, id) in [(editor, "browserEditor"), (open, "browserOpenWallpaper"),
                             (confirm, "browserConfirm"), (cancel, "browserCancel")] {
            button.identifier = NSUserInterfaceItemIdentifier(id); addSubview(button)
        }
    }
    required init?(coder: NSCoder) { nil }

    func updateGeometry(viewportWidth: CGFloat) {
        compact = viewportWidth <= 900
        editor.showsText = !compact; open.showsText = !compact
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let leftWidth: CGFloat = compact ? 95 : 250
        // The 5 px CSS margin and an Arial 14 space produce this measured gap.
        let gap: CGFloat = 8.875
        editor.frame = NSRect(x: 0, y: 0, width: leftWidth, height: 26)
        open.frame = NSRect(x: leftWidth + gap, y: 0, width: leftWidth, height: 26)
        cancel.frame = NSRect(x: bounds.width - 95, y: 0, width: 95, height: 26)
        confirm.frame = NSRect(x: cancel.frame.minX - gap - 95, y: 0, width: 95, height: 26)
    }
}

@MainActor
final class NativeLibraryFooterButton: NSButton {
    let primary: Bool
    let symbol: String?
    var showsText = true { didSet { needsDisplay = true } }
    var destructive = false { didSet { needsDisplay = true } }
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    init(title: String, primary: Bool, symbol: String?, target: AnyObject, action: Selector) {
        self.primary = primary; self.symbol = symbol
        super.init(frame: .zero)
        self.title = title; self.target = target; self.action = action
        setButtonType(.momentaryPushIn); isBordered = false; focusRingType = .none
        font = NativeLibraryBrowserStyle.font(14)
        setAccessibilityLabel(title); toolTip = title
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: 95, height: 26) }
    override func updateTrackingAreas() {
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        hoverArea = area; addTrackingArea(area); super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }

    func palette(hovered: Bool, pressed: Bool) -> (background: NSColor, border: NSColor, foreground: NSColor) {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        let nativePalette = NativeLibraryBrowserStyle.palette(effectiveAppearance)
        let dark = nativePalette.theme != .white, active = hovered || pressed
        if destructive { return (active ? rgb(201, 48, 44) : rgb(217, 83, 79), active ? rgb(172, 41, 37) : rgb(212, 63, 58), .white) }
        if primary {
            // These two states reproduce the public seasonal skins' own
            // orange/ice-blue emphasis without importing their bitmap
            // backgrounds into the native, redistributable application.
            switch nativePalette.theme {
            case .halloween:
                return (active ? rgb(204, 49, 0) : nativePalette.accent,
                        active ? rgb(178, 43, 0) : rgb(230, 55, 0), .white)
            case .winter:
                return (active ? rgb(78, 115, 134) : nativePalette.accent,
                        active ? rgb(67, 100, 117) : rgb(97, 144, 166), .white)
            case .white, .dark:
                break
            }
            if dark { return (active ? rgb(17, 99, 242) : rgb(65, 131, 245), active ? rgb(11, 85, 212) : rgb(41, 115, 244), .white) }
            return (active ? rgb(12, 89, 221) : rgb(41, 115, 243), active ? rgb(10, 75, 187) : rgb(17, 99, 242), .white)
        }
        switch nativePalette.theme {
        case .halloween:
            if pressed { return (rgb(22, 22, 27), rgb(28, 28, 35), nativePalette.foreground) }
            if hovered { return (rgb(28, 28, 35), rgb(35, 35, 44), nativePalette.foreground) }
            return (rgb(40, 40, 49), rgb(47, 47, 58), nativePalette.foreground)
        case .winter:
            if pressed { return (rgb(19, 33, 45), rgb(24, 41, 56), nativePalette.foreground) }
            if hovered { return (rgb(24, 41, 56), rgb(28, 49, 67), nativePalette.foreground) }
            return (rgb(31, 54, 74), rgb(36, 62, 85), nativePalette.foreground)
        case .white, .dark:
            break
        }
        if dark {
            return (pressed ? rgb(39, 39, 39) : hovered ? rgb(47, 47, 47) : rgb(60, 60, 60),
                    pressed ? rgb(47, 47, 47) : hovered ? rgb(54, 54, 54) : rgb(67, 67, 67), rgb(238, 238, 238))
        }
        return (active ? rgb(179, 179, 179) : rgb(204, 204, 204), active ? rgb(173, 173, 173) : rgb(204, 204, 204), rgb(51, 51, 51))
    }
    override func draw(_ dirtyRect: NSRect) {
        let colors = palette(hovered: hovered && isEnabled, pressed: isHighlighted && isEnabled)
        colors.background.setFill(); bounds.fill()
        colors.border.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); border.lineWidth = 1; border.stroke()
        let foreground = colors.foreground.withAlphaComponent(isEnabled ? 1 : 0.65)
        let attributes: [NSAttributedString.Key: Any] = [.font: NativeLibraryBrowserStyle.font(14), .foregroundColor: foreground]
        let text = showsText ? title : "", textSize = text.size(withAttributes: attributes)
        let iconWidth: CGFloat = symbol == nil ? 0 : 14
        let gap: CGFloat = symbol == nil || text.isEmpty ? 0 : 4
        let x = (bounds.width - textSize.width - iconWidth - gap) / 2
        if let symbol {
            let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [foreground]))
            if let icon, icon.size.width > 0, icon.size.height > 0 {
                let scale = min(14 / icon.size.width, 14 / icon.size.height)
                let size = NSSize(width: icon.size.width * scale, height: icon.size.height * scale)
                icon.draw(in: NSRect(x: x + (14 - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            }
        }
        text.draw(at: NSPoint(x: x + iconWidth + gap, y: (bounds.height - textSize.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)); focus.lineWidth = 1; focus.stroke()
        }
    }
}
