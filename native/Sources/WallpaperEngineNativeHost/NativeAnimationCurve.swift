import Foundation
import CoreFoundation

/// Shared numeric parsing and curve math recovered through development-only
/// REA static analysis of Animation::Curve and PropertySystem::Update.
enum NativeAnimationJSON {
    static func number(_ raw: Any?) -> NSNumber? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }
    static func boolean(_ raw: Any?) -> Bool? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    static func integer(_ raw: Any?) -> Int? {
        guard let n = number(raw), n.doubleValue.isFinite else { return nil }
        let value = n.doubleValue.rounded(.towardZero)
        guard value >= Double(Int32.min), value <= Double(Int32.max) else { return nil }
        return Int(value)
    }
}


struct NativeAnimationCurve {
    private struct Handle { var x: Float = 0; var y: Float = 0; var enabled = false }
    private struct Key {
        var frame: Int; var value: Float
        var step = false
        var back = Handle(); var front = Handle()
    }
    private var keys: [Key] = []
    var isEmpty: Bool { keys.isEmpty }
    var keyCount: Int { keys.count }

    init(_ raw: Any?, wrapAt length: Int?, inspectedKeys: inout Int,
         keyLimit: Int = 65_536, valueOffset: Float? = nil) throws {
        guard let entries = raw as? [Any] else { return }
        guard inspectedKeys >= 0, inspectedKeys <= keyLimit,
              entries.count <= keyLimit - inspectedKeys else {
            throw SceneError.invalid("动画曲线超过每场景 \(keyLimit) 项关键帧读取上限。")
        }
        inspectedKeys += entries.count
        func handle(_ raw: Any?) throws -> Handle {
            guard let object = raw as? [String: Any], NativeAnimationJSON.boolean(object["enabled"]) != false else { return Handle() }
            let x = NativeAnimationJSON.number(object["x"])?.floatValue ?? 0
            let y = NativeAnimationJSON.number(object["y"])?.floatValue ?? 0
            guard x.isFinite, y.isFinite else { throw SceneError.invalid("动画曲线手柄不是有限数值。") }
            return Handle(x: x, y: y, enabled: true)
        }
        var previous = -1
        for raw in entries {
            guard let entry = raw as? [String: Any],
                  let value = NativeAnimationJSON.number(entry["value"]),
                  let frame = NativeAnimationJSON.integer(entry["frame"]), frame > previous else { continue }
            let absoluteValue = valueOffset.map { $0 + value.floatValue } ?? value.floatValue
            guard absoluteValue.isFinite else { throw SceneError.invalid("动画曲线值不是有限数值。") }
            var key = Key(frame: frame, value: absoluteValue)
            key.step = NativeAnimationJSON.boolean(entry["step"]) == true
            if !key.step { key.back = try handle(entry["back"]); key.front = try handle(entry["front"]) }
            keys.append(key); previous = frame
        }
        if let length { wrap(at: length) }
    }

    private mutating func wrap(at length: Int) {
        guard keys.count >= 2 else { return }
        let first = keys[0]
        while keys.count >= 2, keys.last!.frame > length { keys.removeLast() }
        guard keys.count >= 2 else { return }
        if keys.last!.frame != length { keys.append(Key(frame: length, value: 0)) }
        let index = keys.count - 1
        keys[index].value = first.value
        // Existing step/front flags survive. When first.front is disabled the
        // reference clears only the back-enable flag, retaining its raw xy.
        keys[index].back.enabled = first.front.enabled
        if first.front.enabled {
            keys[index].back.x = -first.front.x; keys[index].back.y = -first.front.y
        }
    }

    /// Evaluate integer frames first; callers linearly blend adjacent
    /// frames. Handle x is normalized by HALF the keyframe interval.
    func value(frame: Int) -> Float? {
        guard let first = keys.first, let last = keys.last else { return nil }
        if frame <= first.frame { return first.value }
        if frame >= last.frame { return last.value }
        var low = 0, high = keys.count - 1
        while high - low > 1 {
            let mid = (high + low) / 2
            if keys[mid].frame <= frame { low = mid } else { high = mid }
        }
        let a = keys[low], b = keys[high]
        if frame == a.frame || b.step { return a.value }
        let span = Float(b.frame - a.frame)
        let x0 = Float(a.frame), x3 = Float(b.frame)
        let x1 = x0 + (span / 2) * a.front.x, x2 = x3 + (span / 2) * b.back.x
        let y1 = a.value + a.front.y, y2 = b.value + b.back.y
        guard [x1, x2, y1, y2].allSatisfy(\.isFinite) else { return nil }
        func cubic(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
            let s = 1 - t
            return t*t*t*d + t*t*s*3*c + s*s*s*a + t*s*s*3*b
        }
        // Assembly confirms signed INTEGER division for the initial t.
        var t = Float((frame - a.frame) / (b.frame - a.frame)), step: Float = 0.999
        for _ in 0..<1000 {
            let x = cubic(x0, x1, x2, x3, t)
            guard x.isFinite else { return nil }
            if abs(x - Float(frame)) < 0.01 { break }
            step *= 0.5
            let next = t + (x > Float(frame) ? -step : step)
            if next == t { break } // Remaining Float iterations cannot change t.
            t = next
        }
        let result = cubic(a.value, y1, y2, b.value, max(0, min(1, t)))
        return result.isFinite ? result : nil
    }

    func value(sample: (frame: Int, next: Int, fraction: Float), fallback: Float) -> Float? {
        if isEmpty { return fallback }
        guard let a = value(frame: sample.frame), let b = value(frame: sample.next) else { return nil }
        let result = (1 - sample.fraction) * a + sample.fraction * b
        return result.isFinite ? result : nil
    }
}
