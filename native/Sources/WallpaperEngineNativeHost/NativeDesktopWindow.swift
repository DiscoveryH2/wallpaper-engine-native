import AppKit
import CoreGraphics

enum NativeDesktopRecoveryReason: String, Hashable {
    case displayConfiguration = "显示器变化"
    case activeSpace = "桌面空间切换"
    case systemWake = "系统唤醒"
    case displayWake = "显示器唤醒"
    case activeSession = "用户会话恢复"
}

/// Controls only the windows owned by this application that render the
/// desktop wallpaper.  It intentionally does not write Finder preferences,
/// relaunch Finder, or inspect another process's windows.  The visible effect
/// is the closest native equivalent of the reference "隐藏桌面图标" action:
/// this wallpaper moves above Finder's icon plane until the action is toggled
/// again.  Preview windows never register here.
@MainActor
final class NativeDesktopIconVisibility {
    static let shared = NativeDesktopIconVisibility()

    @MainActor
    private final class WeakDesktopWindow {
        weak var value: DesktopWindow?
        /// The exact values that the wallpaper window had before this helper
        /// moved it above Finder's icon plane.  They are deliberately held as
        /// value types; the coordinator never retains an NSWindow.
        let normalLevel: NSWindow.Level
        let normalIgnoresMouseEvents: Bool

        init(_ value: DesktopWindow) {
            self.value = value
            normalLevel = value.level
            normalIgnoresMouseEvents = value.ignoresMouseEvents
        }
    }

    private var windows: [ObjectIdentifier: WeakDesktopWindow] = [:]
    private(set) var iconsHidden = false

    private init() { }

    func register(_ window: DesktopWindow) {
        purgeReleasedWindows()
        windows[ObjectIdentifier(window)] = WeakDesktopWindow(window)
        apply(to: window)
    }

    func unregister(_ window: DesktopWindow) {
        windows.removeValue(forKey: ObjectIdentifier(window))
    }

    /// Removes only dead weak entries.  It is safe to call during display
    /// reconciliation or termination and never closes or otherwise changes a
    /// live NSWindow.
    func cleanupReleasedWindows() { purgeReleasedWindows() }

    /// Internal observability for the isolated host check. This count has no
    /// ownership semantics: all entries are weak and dead values are purged
    /// before it is returned.
    var registeredWindowCount: Int {
        purgeReleasedWindows()
        return windows.count
    }

    /// Updates the current desktop instances and records the desired state so
    /// newly prepared/recovered DesktopWindow instances use the same level.
    @discardableResult
    func setIconsHidden(_ hidden: Bool) -> Bool {
        iconsHidden = hidden
        purgeReleasedWindows()
        for reference in windows.values {
            if let window = reference.value { apply(to: window, reference: reference) }
        }
        return iconsHidden
    }

    @discardableResult
    func toggleIconsHidden() -> Bool { setIconsHidden(!iconsHidden) }

    /// Restores this app's normal wallpaper level before process termination.
    /// It leaves Finder and all other applications untouched.
    func reset() { _ = setIconsHidden(false) }

    fileprivate func apply(to window: DesktopWindow) {
        guard let reference = windows[ObjectIdentifier(window)] else {
            window.applyNormalDesktopBehavior()
            return
        }
        apply(to: window, reference: reference)
    }

    private func apply(to window: DesktopWindow, reference: WeakDesktopWindow) {
        window.applyDesktopIconVisibility(hidden: iconsHidden,
                                          normalLevel: reference.normalLevel,
                                          normalIgnoresMouseEvents: reference.normalIgnoresMouseEvents)
    }

    private func purgeReleasedWindows() {
        windows = windows.filter { $0.value.value != nil }
    }
}

@MainActor
final class DesktopWindow: NSWindow {
    private(set) var displayID: CGDirectDisplayID
    let displayKey: String
    private(set) var displayName: String
    private(set) var displaySignature: String
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(display: NativeDisplayDescriptor) {
        displayID = display.id; displayKey = display.key
        displayName = display.name; displaySignature = display.signature
        super.init(contentRect: display.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        backgroundColor = .black; isOpaque = true; hasShadow = false
        applyDesktopBehavior()
        NativeDesktopIconVisibility.shared.register(self)
        setFrame(display.screen.frame, display: true)
    }

    /// A changed mode, origin, scale, or display ID does not require replacing
    /// the player. Keep its view, clock, properties, and audio ownership intact.
    @discardableResult
    func reconcile(with display: NativeDisplayDescriptor) -> Bool {
        precondition(display.key == displayKey)
        let changed = displaySignature != display.signature
        displayID = display.id; displayName = display.name; displaySignature = display.signature
        applyDesktopBehavior()
        if frame != display.screen.frame { setFrame(display.screen.frame, display: false) }
        contentView?.needsLayout = true
        contentView?.layoutSubtreeIfNeeded()
        orderFrontRegardless()
        return changed
    }

    override func close() {
        NativeDesktopIconVisibility.shared.unregister(self)
        super.close()
    }

    private func applyDesktopBehavior() {
        hidesOnDeactivate = false; canHide = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        NativeDesktopIconVisibility.shared.apply(to: self)
    }

    /// Called only by NativeDesktopIconVisibility.  In normal mode Finder's
    /// icon plane stays above the wallpaper and keeps mouse input. In hidden
    /// mode this app's wallpaper is above that plane and becomes the input
    /// target; this avoids a visually hidden Finder layer receiving clicks.
    fileprivate func applyNormalDesktopBehavior() {
        ignoresMouseEvents = true
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        level = NSWindow.Level(rawValue: iconLevel - 1)
    }

    fileprivate func applyDesktopIconVisibility(hidden: Bool, normalLevel: NSWindow.Level,
                                                 normalIgnoresMouseEvents: Bool) {
        guard hidden else {
            level = normalLevel
            ignoresMouseEvents = normalIgnoresMouseEvents
            return
        }
        // Let the wallpaper receive the click when it occludes Finder's icon
        // plane, rather than routing input to visually hidden Finder icons.
        ignoresMouseEvents = false
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        level = NSWindow.Level(rawValue: iconLevel + 1)
    }
}
