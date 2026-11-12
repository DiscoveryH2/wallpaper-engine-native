import Foundation

/// Construction, script initialization, and the first draw have no animation
/// duration. The scene starts advancing only after its first frame is submitted.
struct ScenePlaybackClock {
    private(set) var hasSubmittedFrame = false
    private(set) var isPaused = false
    private(set) var isAttached = false
    private var elapsed = 0.0
    private var anchor: Double?
    private(set) var lastSubmittedTime: Double?

    func time(at uptime: Double) -> Double {
        elapsed + (anchor.map { max(0, uptime - $0) } ?? 0)
    }

    /// Used only by the native editor's deterministic, script-free preview.
    mutating func seek(to time: Double, at uptime: Double) {
        guard time.isFinite, time >= 0, time <= 120 else { return }
        elapsed = time
        lastSubmittedTime = nil
        restartIfRunning(at: uptime)
    }

    /// Remember the frame enqueued for presentation, including paused edits.
    /// GPU completion can arrive later and must not rewind this record.
    mutating func recordSubmittedFrame(time: Double) {
        guard time.isFinite, time >= 0 else { return }
        lastSubmittedTime = time
    }

    mutating func setPaused(_ paused: Bool, at uptime: Double, holdingLastFrame: Bool = false) {
        guard isPaused != paused else { return }
        settle(at: uptime)
        if paused, holdingLastFrame, let lastSubmittedTime { elapsed = lastSubmittedTime }
        isPaused = paused
        restartIfRunning(at: uptime)
    }

    mutating func setAttached(_ attached: Bool, at uptime: Double) {
        guard isAttached != attached else { return }
        settle(at: uptime)
        isAttached = attached
        restartIfRunning(at: uptime)
    }

    @discardableResult
    mutating func submitFirstFrame(at uptime: Double) -> Bool {
        guard !hasSubmittedFrame else { return false }
        hasSubmittedFrame = true
        restartIfRunning(at: uptime)
        return true
    }

    private mutating func settle(at uptime: Double) {
        elapsed = time(at: uptime)
        anchor = nil
    }

    private mutating func restartIfRunning(at uptime: Double) {
        anchor = hasSubmittedFrame && isAttached && !isPaused ? uptime : nil
    }
}
