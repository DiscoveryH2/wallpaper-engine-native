import Foundation
import simd

/// Renderer-independent HDR bloom contract. REA offsets, resource provenance,
/// and the explicit SDR presentation boundary are recorded in HDR_BLOOM.md.
struct NativeHDRBloomParameters {
    let strength: Float, threshold: Float, feather: Float, scatter: Float, iterations: Float
    let tint: SIMD3<Float>

    init(general: [String: Any]) {
        strength = SceneValues.number(general["bloomhdrstrength"], 2)
        threshold = SceneValues.number(general["bloomhdrthreshold"], 1)
        feather = SceneValues.number(general["bloomhdrfeather"], 0.1)
        scatter = SceneValues.number(general["bloomhdrscatter"], 1.619)
        iterations = SceneValues.number(general["bloomhdriterations"], 8)
        tint = SceneValues.vector(general["bloomtint"], SIMD3(repeating: 1))
    }

    struct Resolved {
        let levels: Int
        let strength: Float, scatter: Float
        let blend: SIMD4<Float>, tint: SIMD3<Float>
    }

    func resolve(available: Int) -> Resolved? {
        // Keep malformed inputs out of pow, integer conversion and half-float
        // targets. This is a native safety boundary, not an author UI range.
        guard available > 0, iterations.isFinite,
              [strength, threshold, feather, scatter, tint.x, tint.y, tint.z]
                .allSatisfy({ $0.isFinite && (0...65504).contains($0) }) else { return nil }
        let levels = Int(max(1, min(Float(min(8, available)), iterations)))
        let normalized = strength / (pow(scatter, Float(max(0, levels - 2))) + 1)
        let knee = feather * threshold
        let blend = SIMD4(threshold, threshold - knee, 2 * knee, 0.25 / (knee + 0.00001))
        guard normalized.isFinite, (0..<4).allSatisfy({ blend[$0].isFinite }) else { return nil }
        return Resolved(levels: levels, strength: normalized, scatter: scatter, blend: blend, tint: tint)
    }
}

struct NativeHDRBloomPlan {
    let width: Int, height: Int
    let sizes: [SIMD2<Int>]
    var bytes: Int { sizes.reduce(0) { $0 + $1.x * $1.y * 8 } }

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        var sizes: [SIMD2<Int>] = [], minimum = min(width, height)
        for index in 0..<8 {
            guard minimum >= 2 else { break }
            let divisor = 2 << index
            sizes.append(SIMD2(max(2, width / divisor), max(2, height / divisor)))
            minimum >>= 1
        }
        self.sizes = sizes.isEmpty ? [SIMD2(2, 2)] : sizes
    }

    /// sourceIndex=0 samples the full scene; subsequent values sample the
    /// preceding downsample. The same step is used for the reverse pass.
    func step(sourceIndex: Int) -> SIMD2<Float> {
        let factor = Float(1 << sourceIndex)
        return SIMD2(factor / Float(width), factor / Float(height))
    }

    func bicubic(sourceIndex: Int, levels: Int) -> Bool { sourceIndex >= levels - 2 }
}
