import AppKit
import CoreGraphics

/// Desktop presentation is an identity of a `DesktopWindow`, not a transient
/// hit-testing setting.  In particular, the Hide Desktop Icons command turns
/// `ignoresMouseEvents` off while the same non-key desktop window remains the
/// wallpaper presentation.  Keep that distinction in one small, testable
/// place so renderers cannot accidentally reinterpret that mode as a preview.
enum NativeDesktopPointerRouting {
    enum Mode: Equatable {
        case desktop
        case preview
    }

    static func isDesktopPresentation(_ window: NSWindow?) -> Bool {
        window is DesktopWindow
    }

    static func mode(for window: NSWindow?) -> Mode {
        isDesktopPresentation(window) ? .desktop : .preview
    }

    /// Desktop windows intentionally cannot become key.  Their input is
    /// admitted only after the caller establishes that the pointer is in a
    /// visible desktop region.  Preview windows retain the ordinary AppKit
    /// key-window, active-app, and tracking-area requirements.
    static func admitsInput(mode: Mode, desktopExposed: Bool,
                            isKeyWindow: Bool, applicationActive: Bool,
                            hasPreviewPoint: Bool) -> Bool {
        switch mode {
        case .desktop:
            return desktopExposed
        case .preview:
            return isKeyWindow && applicationActive && hasPreviewPoint
        }
    }

    /// A click-through desktop needs the observing global monitor.  Keep that
    /// monitor while icons are hidden too: AppKit specifies that global
    /// monitors receive only events sent to other applications, whereas the
    /// hidden desktop receives its own direct events.  This makes a live
    /// normal → hidden → normal toggle neither duplicate nor lose a button
    /// transition, including when a renderer first attaches while icons are
    /// already hidden.
    static func needsGlobalButtonMonitor(mode: Mode, hasScripts: Bool,
                                         monitorInstalled: Bool) -> Bool {
        mode == .desktop && hasScripts && !monitorInstalled
    }

    /// A click-through desktop preserves the existing Finder-only privacy
    /// boundary.  When the Hide Desktop Icons command makes that same desktop
    /// window receive clicks, macOS may make this application frontmost even
    /// though the pointer is still on the desktop.  Admit only that one extra
    /// state; an unrelated frontmost application is never used as a proxy for
    /// desktop exposure.
    static func desktopFrontmostMayObserve(ignoresMouseEvents: Bool,
                                           frontmostBundleIdentifier: String?,
                                           ownBundleIdentifier: String?) -> Bool {
        guard let frontmostBundleIdentifier else { return false }
        if frontmostBundleIdentifier == "com.apple.finder" { return true }
        return !ignoresMouseEvents && ownBundleIdentifier != nil &&
            frontmostBundleIdentifier == ownBundleIdentifier
    }

    /// The WindowServer documents `OnScreenAboveWindow` as the on-screen
    /// windows above a particular window.  Query from the actual desktop
    /// window rather than assuming that desktop-element filtering also omits
    /// every app-created wallpaper surface.  `windowNumber` is a signed
    /// 32-bit WindowServer identity, so an absent, zero, negative, or
    /// out-of-range AppKit value must fail closed instead of falling back to a
    /// broad all-windows query.
    static func desktopCoverageRelativeWindowNumber(_ windowNumber: Int) -> CGWindowID? {
        guard windowNumber > 0, windowNumber <= Int(Int32.max) else { return nil }
        return CGWindowID(windowNumber)
    }

    /// Defensive second identity check for a WindowServer record.  The
    /// relative list should already exclude the reference window, but exact
    /// equality is the only safe exception if a platform returns it anyway.
    /// A missing listed number stays a cover (fail closed); ownership/PID is
    /// intentionally never used, so another window from this process and a
    /// wallpaper on a different display retain their independent behavior.
    static func listedWindowMayCoverDesktop(listedWindowNumber: Int?,
                                            desktopWindowNumber: Int) -> Bool {
        guard let listedWindowNumber else { return true }
        return listedWindowNumber != desktopWindowNumber
    }
}
