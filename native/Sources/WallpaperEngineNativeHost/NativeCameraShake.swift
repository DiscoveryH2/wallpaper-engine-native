import Foundation
import simd

/// Our implementation of the camera translation observed through REA in the
/// official Android scene library. No native reference code runs in this app.
/// All reads use scene time, so sampling twice cannot advance the camera and
/// pause/resume inherits ScenePlaybackClock's existing semantics.
enum NativeCameraShake {
    static func translation(time: Double, speed: Float, amplitude: Float,
                            roughness: Float, orthogonalHeight: Float?) -> SIMD3<Float>? {
        guard time.isFinite, time >= 0, speed.isFinite, amplitude.isFinite,
              roughness.isFinite else { return nil }
        let phase = speed * speed * Float(time)
        let exponent = pow(roughness, 3)
        guard phase.isFinite, exponent.isFinite else { return nil }
        var wave = SIMD3<Float>(cos(phase), sin(phase * 1.333), sin(phase))
        guard wave.x.isFinite, wave.y.isFinite, wave.z.isFinite else { return nil }
        var scale = amplitude * 0.1
        if let height = orthogonalHeight {
            guard height.isFinite, height > 0 else { return nil }
            scale *= height * 0.1
            wave.z = 0
        }
        if exponent > 0.001, exponent != 1 {
            let length = simd_length(wave)
            // The reference normalizes this vector. Its exact zero has no
            // direction; use a zero displacement instead of sending NaN to GL.
            guard length > 0 else { return .zero }
            wave = (wave / length) * pow(length, exponent)
        }
        let offset = wave * scale
        guard offset.x.isFinite, offset.y.isFinite, offset.z.isFinite,
              simd_reduce_max(simd_abs(offset)) <= 1_000_000 else { return nil }
        return offset
    }
}
