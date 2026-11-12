import AppKit

/// A local AppKit recorder, deliberately not an event tap.  While focused it
/// consumes keys that reach this dialog and tells the Carbon registration
/// service to suppress profile activation.  Global shortcut delivery remains
/// the service's responsibility after recording ends.
@MainActor
final class NativeHotkeyRecorder: NSControl {
    var hotkey: NativeHotkey? { didSet { redraw() } }
    var onChange: ((NativeHotkey?) -> Void)?
    var onBeginRecording: (() -> Void)?
    var onEndRecording: (() -> Void)?
    var onInvalidInput: ((String) -> Void)?

    private let label = NSTextField(labelWithString: "")
    /// Installed by the dialog beside the text-field AX element.  NSTextField
    /// roles are AX leaves, so keeping this button inside the recorder would
    /// make it visually present but unreachable to assistive technologies.
    let clearButton = NSButton(title: "×", target: nil, action: nil)
    private var recording = false
    private var invalid = false
    private var lastDelivered: NativeHotkey?

    override var acceptsFirstResponder: Bool { isEnabled }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }
    /// AX focus must describe the actual keyboard first responder.  Merely
    /// setting accessibility metadata lets automation claim focus while hotkey
    /// capture is inactive, which is both misleading and unsafe for ⌘ chords.
    override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        guard accessibilityFocused != isAccessibilityFocused() else { return }
        if accessibilityFocused { _ = window?.makeFirstResponder(self) }
        else if window?.firstResponder === self { window?.makeFirstResponder(nil) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = NativeLibraryBrowserStyle.font(14)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityLabel("热键")
        // The control itself provides the field value, so exposing its
        // decorative label separately would make VoiceOver announce it twice.
        label.setAccessibilityElement(false)
        clearButton.isBordered = false; clearButton.font = NativeLibraryBrowserStyle.font(18)
        clearButton.contentTintColor = .secondaryLabelColor; clearButton.target = self; clearButton.action = #selector(clearHotkey)
        clearButton.identifier = .init("profileHotkeyClear"); clearButton.setAccessibilityLabel("清除热键")
        clearButton.setAccessibilityElement(true); clearButton.setAccessibilityRole(.button); clearButton.toolTip = "清除热键"
        addSubview(label)
        // NSControl with no cell is not inferred as an accessibility element
        // by AppKit, so make the recorder itself explicit. Its clear button is
        // a sibling in NativeProfileCollectionsController (not a fake child
        // of the text-field AX leaf).
        setAccessibilityElement(true)
        setAccessibilityRole(.textField)
        setAccessibilityLabel("热键")
        redraw()
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let labelHeight = min(bounds.height, ceil(label.intrinsicContentSize.height))
        label.frame = NSRect(x: 10, y: (bounds.height - labelHeight) / 2,
                             width: max(0, bounds.width - 42), height: labelHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius: CGFloat = 5
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        let dark = NativeLibraryBrowserStyle.dark(effectiveAppearance)
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill(); path.fill()
        (invalid ? NSColor.systemRed : recording ? NSColor.controlAccentColor : (dark ? NSColor(white: 0.42, alpha: 1) : NSColor(white: 0.68, alpha: 1))).setStroke()
        path.lineWidth = invalid || recording ? 2 : 1; path.stroke()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if !recording { recording = true; invalid = false; lastDelivered = nil; onBeginRecording?() }
        redraw()
        return true
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { endRecording() }
        return result
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        guard isEnabled, recording else { return }
        // Escape stops only recorder capture. It must not dismiss the sheet or
        // clear the old binding while the recorder has keyboard focus.
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        do {
            let next = try NativeHotkey(event: event)
            invalid = false; hotkey = next
            if lastDelivered != next {
                lastDelivered = next; onChange?(next)
                // A completed capture releases Carbon registration before a
                // collision sheet or profile save can reserve the new chord.
                window?.makeFirstResponder(nil)
            }
        } catch {
            invalid = true; onInvalidInput?(error.localizedDescription)
        }
        redraw()
    }
    override func keyUp(with event: NSEvent) { lastDelivered = nil }
    override func flagsChanged(with event: NSEvent) {
        guard isEnabled, recording else { return }
        // Modifier-only capture is not a usable registered chord. Keep the
        // old chord intact and show the reference-style red feedback.
        if !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty { invalid = true; redraw() }
    }
    /// AppKit sends Command chords through menu key-equivalent dispatch before
    /// `keyDown`.  Consume and record them here so recording ⌘Q, ⌘W, etc.
    /// cannot invoke an application menu command.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, window?.firstResponder === self else { return false }
        keyDown(with: event); return true
    }

    @objc private func clearHotkey() {
        guard isEnabled else { return }
        invalid = false; lastDelivered = nil; hotkey = nil; onChange?(nil); redraw()
    }

    private func endRecording() {
        guard recording else { return }
        recording = false; invalid = false; lastDelivered = nil; onEndRecording?(); redraw()
    }

    private func redraw() {
        let empty = hotkey == nil
        label.stringValue = hotkey?.label ?? "按键组合"
        label.textColor = empty ? .tertiaryLabelColor : .labelColor
        label.font = NativeLibraryBrowserStyle.font(14)
        // The reference keeps its trailing × visible for an empty value too;
        // clearing an empty recorder is harmless and avoids a layout jump.
        clearButton.isHidden = false
        clearButton.isEnabled = isEnabled
        setAccessibilityValue(hotkey?.label ?? "按键组合")
        needsDisplay = true
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled, recording { window?.makeFirstResponder(nil) }; redraw() }
    }
}
