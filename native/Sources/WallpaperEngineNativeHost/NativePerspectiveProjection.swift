import Foundation
import CoreFoundation
import simd

/// Native OpenGL perspective for the scene's general.fov / nearz / farz.
/// Defaults and the FOV clamp come from the REA Scene constructor, property
/// registration and Update exports. Matrix construction is our implementation.
/// The matrix builder is also used by the separate 2D particle parameters.
struct NativePerspectiveProjection {
    let fovDegrees: Float
    let near: Float
    let far: Float
    let diagnostics: [String]

    init(fov rawFOV: Any? = nil, near rawNear: Any? = nil, far rawFar: Any? = nil) {
        var notes: [String] = []
        func scalar(_ raw: Any?, default fallback: Float, name: String) -> Float {
            guard let raw, !(raw is NSNull) else { return fallback }
            let value: Float?
            if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                value = number.floatValue
            } else if let text = raw as? String {
                value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else { value = nil }
            guard let value, value.isFinite else {
                notes.append("三维相机 \(name) 不是有限标量，采用默认值 \(fallback)。")
                return fallback
            }
            return value
        }
        let fov = scalar(rawFOV, default: 50, name: "fov")
        fovDegrees = max(0.1, min(179.9, fov))
        if fovDegrees != fov { notes.append("三维相机 fov 按参考库限制到 0.1–179.9 度。") }
        let near = scalar(rawNear, default: 0.1, name: "nearz")
        let far = scalar(rawFar, default: 10_000, name: "farz")
        if Self.makeMatrix(fovDegrees: fovDegrees, aspect: 1, near: near, far: far) != nil {
            self.near = near; self.far = far
        } else {
            // Keep the authored scene visible, but never send a singular or
            // non-finite matrix into rendering, effects or pointer inversion.
            self.near = 0.1; self.far = 10_000
            notes.append("三维相机裁剪距离无效或矩阵无法安全求逆，nearz/farz 回退为 0.1/10000。")
        }
        diagnostics = notes
    }

    func matrix(aspect: Float) -> simd_float4x4? {
        Self.makeMatrix(fovDegrees: fovDegrees, aspect: aspect, near: near, far: far)
    }

    static func makeMatrix(fovDegrees: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4? {
        guard fovDegrees.isFinite, fovDegrees > 0, fovDegrees < 180,
              aspect.isFinite, aspect > 0, near.isFinite, far.isFinite,
              near > 0, far > near else { return nil }
        // Double intermediates avoid overflowing 2*near*far before division.
        let n = Double(near), f = Double(far)
        let y = 1 / tan(Double(fovDegrees) * .pi / 360)
        let values = [y / Double(aspect), y, -(f + n) / (f - n), -2 * n * f / (f - n)].map(Float.init)
        guard values.allSatisfy(\.isFinite) else { return nil }
        let result = simd_float4x4(columns: (SIMD4(values[0], 0, 0, 0), SIMD4(0, values[1], 0, 0),
            SIMD4(0, 0, values[2], -1), SIMD4(0, 0, values[3], 0)))
        let determinant = simd_determinant(result)
        guard determinant.isFinite, determinant != 0 else { return nil }
        let inverse = simd_inverse(result)
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { inverse[c][$0].isFinite } }) else { return nil }
        return result
    }
}
