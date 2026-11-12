import Foundation

/// A reference graph scans authored events before correcting its clock, then
/// at most once more after a loop wrap. Mirror overshoot adds no return scan.
struct SceneTimelineEventWindow {
    let from: Float, to: Float
    let forward: Bool
    func contains(_ time: Float) -> Bool {
        forward ? from <= time && time < to : to < time && time <= from
    }
}

/// Validated intent from the isolated script helper. The native renderer owns
/// time; a response must never replace it with an older helper snapshot.
struct SceneTimelineCommand {
    enum Action: String { case play, pause, stop, setFrame, rate }
    let path: String
    let action: Action
    let value: Float?

    init?(_ raw: [String: Any], ordinal: Int, lengths: [String: Double]) {
        guard NativeAnimationJSON.number(raw["ordinal"])?.doubleValue == Double(ordinal),
              let path = raw["path"] as? String, path.utf8.count <= 4096,
              let length = lengths[path], let name = raw["action"] as? String,
              let action = Action(rawValue: name) else { return nil }
        let value: Float?
        if action == .setFrame || action == .rate {
            guard Set(raw.keys) == ["ordinal", "path", "action", "value"],
                  let number = NativeAnimationJSON.number(raw["value"]),
                  number.doubleValue.isFinite, number.floatValue.isFinite else { return nil }
            if action == .setFrame {
                guard number.doubleValue >= 0, number.doubleValue <= length else { return nil }
            } else { guard abs(number.doubleValue) <= 100 else { return nil } }
            value = number.floatValue
        } else {
            guard Set(raw.keys) == ["ordinal", "path", "action"] else { return nil }
            value = nil
        }
        self.path = path; self.action = action; self.value = value
    }
}

/// PropertySystem's Float graph clock, advanced once per scene frame.
/// Flags and adapter commands are independent: setFrame does not clear a
/// completed graph, pause preserves mirror direction, and stop clears it.
struct SceneTimelinePlayback {
    private(set) var time: Float = 0
    private(set) var rate: Float = 1
    private(set) var paused: Bool
    private(set) var completed = false
    private(set) var reversed = false
    var playing: Bool { !paused && !completed }

    init(paused: Bool, initialTime: Float = 0) { self.paused = paused; time = initialTime }

    /// Native graph owners validate their own authored rate before applying it.
    mutating func setRate(_ value: Float) { rate = value }

    mutating func apply(_ command: SceneTimelineCommand, frameDuration: Float) -> Bool {
        switch command.action {
        case .play:
            if completed { time = 0 }
            paused = false; completed = false
        case .pause: paused = true
        case .stop:
            paused = true; completed = false; reversed = false; time = 0
        case .setFrame:
            guard let frame = command.value else { return false }
            let candidate = frame * frameDuration
            guard candidate.isFinite else { return false }
            time = candidate
        case .rate:
            guard let value = command.value else { return false }
            rate = value
        }
        return true
    }

    mutating func advance(delta: Float, duration: Float, mode: String) -> Bool {
        var ignored: [SceneTimelineEventWindow] = []
        return advance(delta: delta, duration: duration, mode: mode, eventWindows: &ignored)
    }

    mutating func advance(delta: Float, duration: Float, mode: String, eventWindows: inout [SceneTimelineEventWindow]) -> Bool {
        guard delta.isFinite, delta >= 0, duration.isFinite, duration > 0 else { return false }
        if paused || completed || (mode == "single" && time >= duration) { return true }
        let scaled = delta * rate
        let step = reversed ? -scaled : scaled
        var candidate = time + step
        guard candidate.isFinite else { return false }
        var windows = [SceneTimelineEventWindow(from: time, to: candidate, forward: step > 0)]
        var nextReversed = reversed, nextCompleted = completed
        switch mode {
        case "single":
            if candidate >= duration { candidate = duration; nextCompleted = true }
        case "mirror":
            if reversed, candidate <= 0 {
                candidate = -candidate.truncatingRemainder(dividingBy: duration); nextReversed = false
            } else if !reversed, candidate >= duration {
                candidate = duration - candidate.truncatingRemainder(dividingBy: duration); nextReversed = true
            }
        default:
            // Preserve the reference's single correction, including signed
            // remainders after a negative step larger than one duration.
            if candidate < 0 {
                candidate = (candidate + duration).truncatingRemainder(dividingBy: duration)
                if candidate >= 0 { windows.append(SceneTimelineEventWindow(from: duration, to: candidate, forward: false)) }
            }
            if candidate >= duration {
                candidate = candidate.truncatingRemainder(dividingBy: duration)
                if candidate < duration { windows.append(SceneTimelineEventWindow(from: 0, to: candidate, forward: true)) }
            }
        }
        guard candidate.isFinite else { return false }
        time = candidate; reversed = nextReversed; completed = nextCompleted
        eventWindows.append(contentsOf: windows)
        return true
    }

    func sample(length: Int, frameDuration: Float) -> (frame: Int, next: Int, fraction: Float)? {
        guard length > 0, frameDuration.isFinite, frameDuration > 0 else { return nil }
        let quotient = time / frameDuration
        let fraction = time.truncatingRemainder(dividingBy: frameDuration) / frameDuration
        guard quotient.isFinite, fraction.isFinite else { return nil }
        // Clamp before Int conversion. A negative graph time still keeps the
        // signed remainder when its lower frame is clamped to zero.
        let frame = Int(max(0, min(Double(length - 1), Double(quotient))))
        return (frame, min(frame + 1, length), fraction)
    }

    var json: [String: Any] {
        ["time": Double(time), "rate": Double(rate), "paused": paused,
         "completed": completed, "reversed": reversed]
    }
}
