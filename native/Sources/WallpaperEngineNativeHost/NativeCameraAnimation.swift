import Foundation

// Preserve Camera call sites while sharing the recovered curve implementation.
typealias NativeCameraJSON = NativeAnimationJSON
typealias NativeCameraAnimationCurve = NativeAnimationCurve

extension NativeAnimationCurve {
    init(_ raw: Any?, graph: NativeCameraAnimationGraph, inspectedKeys: inout Int) throws {
        try self.init(raw, wrapAt: graph.wrapLoop ? graph.length : nil, inspectedKeys: &inspectedKeys)
    }
}

struct NativeCameraAnimationGraph {
    enum Mode: String { case loop, mirror, single }
    let length: Int
    let frameDuration: Float
    let duration: Float
    let mode: Mode
    let startPaused: Bool
    let wrapLoop: Bool
    let randomFlag: Bool
    private(set) var time: Float = 0
    private(set) var reversed = false
    private(set) var completed = false

    init(options: [String: Any]) throws {
        guard let length = NativeCameraJSON.integer(options["length"]), length > 0, length <= 1_000_000,
              let number = NativeCameraJSON.number(options["fps"]), number.floatValue.isFinite,
              number.floatValue > 0 else {
            throw SceneError.invalid("Camera 路径 length/fps 无效，或超过原生 1000000 帧上限。")
        }
        let fps = number.floatValue, step = 1 / fps, duration = Float(length) / fps
        guard step.isFinite, step > 0, duration.isFinite, duration > 0 else {
            throw SceneError.invalid("Camera 路径时长不能用有限正数表示。")
        }
        self.length = length; frameDuration = step; self.duration = duration
        mode = Mode(rawValue: (options["mode"] as? String ?? "").lowercased()) ?? .loop
        startPaused = NativeCameraJSON.boolean(options["startpaused"]) == true
        wrapLoop = NativeCameraJSON.boolean(options["wraploop"]) == true
        // The reference parser stores this flag, but Camera::Update does not
        // consume it. Path queue randomness is a separate FairRandomPool.
        randomFlag = NativeCameraJSON.boolean(options["random"]) == true
    }

    mutating func reset() { time = 0; completed = false }

    /// Camera passes no event output to UpdateAnimationGraph. A completed
    /// Single path is switched by Camera on the NEXT scene update.
    mutating func advance(delta: Float) -> Bool {
        guard delta.isFinite, delta >= 0 else { return false }
        if startPaused || completed || (mode == .single && time >= duration) { return true }
        var candidate = time + (reversed ? -delta : delta)
        guard candidate.isFinite else { return false }
        var nextReversed = reversed, nextCompleted = completed
        switch mode {
        case .single:
            if candidate >= duration { candidate = duration; nextCompleted = true }
        case .mirror:
            if reversed, candidate <= 0 {
                candidate = -candidate.truncatingRemainder(dividingBy: duration); nextReversed = false
            } else if !reversed, candidate >= duration {
                candidate = duration - candidate.truncatingRemainder(dividingBy: duration); nextReversed = true
            }
        case .loop:
            if candidate < 0 { candidate = (candidate + duration).truncatingRemainder(dividingBy: duration) }
            if candidate >= duration { candidate = candidate.truncatingRemainder(dividingBy: duration) }
        }
        guard candidate.isFinite, candidate >= 0 else { return false }
        time = candidate; reversed = nextReversed; completed = nextCompleted
        return true
    }

    var sample: (frame: Int, next: Int, fraction: Float)? {
        let quotient = time / frameDuration
        guard quotient.isFinite, quotient >= 0 else { return nil }
        // Clamp before converting so a large finite Float never traps Int().
        let frame = Int(min(Float(length - 1), quotient))
        let fraction = time.truncatingRemainder(dividingBy: frameDuration) / frameDuration
        guard fraction.isFinite else { return nil }
        return (frame, min(frame + 1, length), fraction)
    }
}

