import AppKit

/// Native adaptation of Wallpaper Engine's `dragdrop.beginAutoScroll` helper.
///
/// The public Build 26168761 UI starts scrolling while a valid internal drag
/// is inside the first/last 50 CSS pixels of a browser container. Its speed is
/// the signed distance beyond that boundary. This native variant intentionally
/// narrows activation to authenticated internal library payloads and uses a
/// 60 Hz timer: the official JavaScript schedules a zero-delay `$timeout` and
/// is also used for non-payload browser selection. The caller remains
/// responsible for validating the drag payload and committing a drop.
@MainActor
final class NativeLibraryDragAutoscroll {
    static let edgeInset: CGFloat = 50
    /// Native resource bound, not an asserted Windows timing match.
    static let tickInterval: TimeInterval = 1.0 / 60.0

    /// Computes the same signed edge speed as the official helper. Positive
    /// means a growing document Y origin; negative means a shrinking one.
    /// AppKit's unflipped coordinate systems invert which visual edge grows
    /// that origin, so retain the UI's visual top/bottom semantics there.
    static func verticalSpeed(locationY: CGFloat, visible: NSRect, documentIsFlipped: Bool) -> CGFloat {
        guard locationY.isFinite, visible.minY.isFinite, visible.maxY.isFinite,
              visible.height.isFinite, visible.height > 0 else { return 0 }
        if documentIsFlipped {
            let offset = locationY - visible.minY
            if offset < edgeInset { return offset - edgeInset }
            if offset > visible.height - edgeInset { return offset - visible.height + edgeInset }
        } else {
            let offsetFromVisualTop = visible.maxY - locationY
            if offsetFromVisualTop < edgeInset { return edgeInset - offsetFromVisualTop }
            let offsetFromVisualBottom = locationY - visible.minY
            if offsetFromVisualBottom < edgeInset { return offsetFromVisualBottom - edgeInset }
        }
        return 0
    }

    private weak var scrollView: NSScrollView?
    private weak var documentView: NSView?
    private var timer: Timer?
    private var speed: CGFloat = 0

    /// Test-only observation seam. It is intentionally not tied to selection,
    /// folders, playback, files, or Steam state.
    var onScrollStep: (() -> Void)?
    var isRunning: Bool { timer != nil }
    var currentSpeed: CGFloat { speed }

    init(scrollView: NSScrollView? = nil) {
        self.scrollView = scrollView
        self.documentView = scrollView?.documentView
    }

    deinit { timer?.invalidate() }

    func configure(scrollView: NSScrollView?) {
        stop()
        self.scrollView = scrollView
        self.documentView = scrollView?.documentView
    }

    /// Updates the active drag location. `permitted` must only be true for a
    /// live, internal payload that the owner has authenticated. This permits
    /// scrolling over an empty portion of the list so an offscreen folder can
    /// become reachable, while still rejecting external/expired drags.
    func update(location: NSPoint, in document: NSView, permitted: Bool) {
        guard permitted, let scrollView, scrollView.documentView === document else {
            stop(); return
        }
        documentView = document
        let point = document.convert(location, to: scrollView.contentView)
        let nextSpeed = Self.verticalSpeed(locationY: point.y, visible: scrollView.contentView.bounds,
                                           documentIsFlipped: document.isFlipped)
        guard nextSpeed.isFinite, nextSpeed != 0 else { stop(); return }
        speed = nextSpeed
        startTimerIfNeeded()
    }

    func stop() {
        timer?.invalidate(); timer = nil; speed = 0; documentView = scrollView?.documentView
    }

    /// Called by the timer and directly by isolated deterministic tests.
    /// Returns whether the viewport actually moved; a clamped edge stops the
    /// timer rather than leaving a hidden repeating callback behind. This is a
    /// deliberate native bounded-lifecycle choice: the official zero-delay
    /// helper keeps scheduling at a clamped edge until a later cancel event.
    @discardableResult
    func step() -> Bool {
        guard let scrollView, let document = documentView, speed.isFinite, speed != 0,
              scrollView.documentView === document else { stop(); return false }
        let clip = scrollView.contentView
        let visible = clip.bounds
        let minimumY = document.bounds.minY
        let maximumY = max(minimumY, document.bounds.maxY - visible.height)
        let candidate = min(maximumY, max(minimumY, visible.origin.y + speed))
        guard candidate.isFinite, candidate != visible.origin.y else { stop(); return false }
        clip.scroll(to: NSPoint(x: visible.origin.x, y: candidate))
        scrollView.reflectScrolledClipView(clip)
        onScrollStep?()
        return true
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            // Timer's closure is imported as nonisolated even though a timer
            // attached below runs on the main run loop. Re-enter the explicit
            // AppKit actor before touching scroll views.
            Task { @MainActor [weak self] in _ = self?.step() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
