import Foundation
import simd

/// Independent, continuous velocity noise for the particle turbulence operator.
/// This is an explicitly reported compatibility approximation, not the original
/// engine's unpublished noise implementation. No proprietary texture is used.
enum NativeParticleTurbulence {
    private static let side = 32
    private static let lattice: [SIMD3<Float>] = {
        var values: [SIMD3<Float>] = []
        values.reserveCapacity(side * side * side)
        var state: UInt64 = 0x9E3779B97F4A7C15
        func signedUnit() -> Float {
            state &+= 0x9E3779B97F4A7C15
            var bits = state
            bits = (bits ^ (bits >> 30)) &* 0xBF58476D1CE4E5B9
            bits = (bits ^ (bits >> 27)) &* 0x94D049BB133111EB
            bits ^= bits >> 31
            return Float(bits >> 40) / Float(1 << 23) - 1
        }
        for _ in 0..<(side * side * side) {
            values.append(SIMD3(signedUnit(), signedUnit(), signedUnit()))
        }
        return values
    }()

    /// Signed time supports author configurations that move the noise backwards.
    /// Double precision and reduction before Float conversion avoid losing the
    /// fractional cell position during long sessions or for distant particles.
    static func direction(position: SIMD3<Float>, scale: Float, phase: SIMD3<Float>, time: Double) -> SIMD3<Float> {
        let translation = SIMD3<Double>(0.754877666, 0.569840291, 0.438579021)
        var coordinate = SIMD3<Float>.zero
        for axis in 0..<3 {
            let value = Double(position[axis]) * Double(scale) + Double(phase[axis]) + time * translation[axis]
            guard value.isFinite else { return .zero }
            let reduced = value.truncatingRemainder(dividingBy: Double(side))
            coordinate[axis] = Float(reduced < 0 ? reduced + Double(side) : reduced)
        }
        let integer = SIMD3<Int>(Int(floor(coordinate.x)), Int(floor(coordinate.y)), Int(floor(coordinate.z)))
        let fraction = coordinate - SIMD3(Float(integer.x), Float(integer.y), Float(integer.z))
        let cubic: SIMD3<Float> = fraction * fraction * fraction
        let inner: SIMD3<Float> = fraction * 6 - SIMD3<Float>(repeating: 15)
        let polynomial: SIMD3<Float> = fraction * inner + SIMD3<Float>(repeating: 10)
        let blend: SIMD3<Float> = cubic * polynomial
        func corner(_ x: Int, _ y: Int, _ z: Int) -> SIMD3<Float> {
            lattice[((z & 31) * side + (y & 31)) * side + (x & 31)]
        }
        func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ amount: Float) -> SIMD3<Float> { a + (b - a) * amount }
        let x = integer.x, y = integer.y, z = integer.z
        let lower = mix(mix(corner(x, y, z), corner(x + 1, y, z), blend.x),
                        mix(corner(x, y + 1, z), corner(x + 1, y + 1, z), blend.x), blend.y)
        let upper = mix(mix(corner(x, y, z + 1), corner(x + 1, y, z + 1), blend.x),
                        mix(corner(x, y + 1, z + 1), corner(x + 1, y + 1, z + 1), blend.x), blend.y)
        let vector = mix(lower, upper, blend.z)
        // A smooth bounded denominator avoids a direction singularity at zero.
        // Speed min/max select a per-particle scale, not a guaranteed lower bound
        // on resultant speed after noise, mask, gravity and drag are composed.
        return vector / sqrtf(simd_length_squared(vector) + 0.0625)
    }
}
