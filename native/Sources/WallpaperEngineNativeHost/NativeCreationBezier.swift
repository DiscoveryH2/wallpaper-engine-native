import Foundation

/// Timing curve with fixed endpoints (0, 0) and (1, 1). Both controls stay in
/// the unit square, so interpolation preserves every property's value bounds.
struct NativeCreationBezier: Codable, Equatable, Sendable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double

    static let standard = Self(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1)
    static let linear = Self(x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
    static let smooth = Self(x1: 1.0 / 3, y1: 0, x2: 2.0 / 3, y2: 1)
    static let easeIn = Self(x1: 0.42, y1: 0, x2: 1, y2: 1)
    static let easeOut = Self(x1: 0, y1: 0, x2: 0.58, y2: 1)
    static let easeInOut = Self(x1: 0.42, y1: 0, x2: 0.58, y2: 1)

    var isValid: Bool { [x1, y1, x2, y2].allSatisfy { $0.isFinite && (0...1).contains($0) } }

    func value(at progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        func coordinate(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let s = 1 - t
            return 3 * s * s * t * a + 3 * s * t * t * b + t * t * t
        }
        // Progress is x, not the curve parameter. Bisection also handles a
        // zero derivative, including crossed handles x1=1, x2=0 at the center.
        var low = 0.0, high = 1.0
        for _ in 0..<44 {
            let t = (low + high) * 0.5
            let x = coordinate(t, x1, x2)
            if x == progress { return coordinate(t, y1, y2) }
            if x < progress { low = t } else { high = t }
        }
        return coordinate((low + high) * 0.5, y1, y2)
    }
}
