import Foundation
import simd

/// Shared ordinary bloom parameters, independent of a graphics API. Defaults
/// and range handling retain the reference-backed 0.59 behavior.
struct NativeBloomParameters {
    let strength: Float
    let threshold: Float
    let tint: SIMD3<Float>

    var isFinite: Bool {
        guard strength.isFinite, threshold.isFinite,
              tint.x.isFinite, tint.y.isFinite, tint.z.isFinite else { return false }
        let tintMagnitude = max(abs(Double(tint.x)), abs(Double(tint.y)), abs(Double(tint.z)))
        let strengthMagnitude = abs(Double(strength))
        return strengthMagnitude * 4 <= Double(Float.greatestFiniteMagnitude)
            && strengthMagnitude * tintMagnitude * 4 <= Double(Float.greatestFiniteMagnitude)
    }
}

struct NativeSceneBloom {
    let enabled: Bool
    let parameters: NativeBloomParameters

    init(general: [String: Any]) {
        enabled = general["bloom"] as? Bool == true
        parameters = NativeBloomParameters(strength: SceneValues.number(general["bloomstrength"], 2),
            threshold: SceneValues.number(general["bloomthreshold"], 0.65),
            tint: SceneValues.vector(general["bloomtint"], SIMD3(repeating: 1)))
    }
}
