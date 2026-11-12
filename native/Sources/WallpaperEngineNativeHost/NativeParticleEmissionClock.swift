import Foundation

/// Piecewise emission phase. Changing density affects future births without
/// renumbering particles, replaying bursts or changing already sampled lifetimes.
/// This is an implementation-owned scheduler, not a Windows timing replica.
struct NativeParticleEmissionClock {
    let start: Double
    let duration: Double
    let baseRate: Double
    let baseBurst: Int
    private(set) var burst: Int
    private(set) var rate: Double
    private var anchor: Double
    private var phase: Double = 0

    init(start: Double, duration: Double, baseRate: Double, baseBurst: Int, count: Float) {
        self.start = start; self.duration = duration
        self.baseRate = baseRate; self.baseBurst = baseBurst
        burst = Self.integer(Double(baseBurst) * Double(count))
        rate = baseRate * Double(count); anchor = start
    }

    /// Caller must finish the previous schedule through this boundary first.
    mutating func setCount(_ count: Float, at boundary: Double) {
        if boundary < start {
            // The initial delay has not elapsed: the one authored burst can
            // still change. Once emission starts its size/IDs remain fixed.
            burst = Self.integer(Double(baseBurst) * Double(count))
        } else {
            let end = duration > 0 ? start + duration : Double.infinity
            let time = min(boundary, end)
            phase += max(0, time - anchor) * rate
            anchor = max(anchor, time)
        }
        rate = baseRate * Double(count)
    }

    func birthTime(index: Int) -> Double? {
        guard index >= 0 else { return nil }
        if index < burst { return start }
        guard rate > 0 else { return nil }
        let time = anchor + max(0, Double(index - burst) - phase) / rate
        guard time.isFinite, duration == 0 || time < start + duration else { return nil }
        return time
    }

    /// Used only at/after the current anchor, when the live pool is full.
    func emissionIndex(at time: Double, strictlyAfter: Bool) -> Int {
        if time < start || (!strictlyAfter && time == start) { return 0 }
        if rate == 0 { return burst }
        let position = phase + max(0, time - anchor) * rate
        let continuous = strictlyAfter ? floor(position) + 1 : ceil(position)
        return Self.integer(Double(burst) + max(0, continuous))
    }

    private static func integer(_ value: Double) -> Int {
        guard value < Double(Int.max) else { return Int.max }
        return Int(max(0, value))
    }
}
