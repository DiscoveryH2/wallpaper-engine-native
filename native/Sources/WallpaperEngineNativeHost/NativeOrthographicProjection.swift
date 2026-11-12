import Foundation
import CoreFoundation
import simd

/// Author-controlled 2D projection. REA identifies general.zoom separately
/// from the active camera's zoom and a third, still-unmapped scaling factor.
/// This implements general.zoom * legacy camera zoom in centered canvas space.
struct NativeOrthographicProjection {
    let zoom: Float
    let perspectiveFOVDegrees: Float
    let diagnostics: [String]

    init(zoom rawZoom: Any? = nil, perspectiveFOV rawFOV: Any? = nil) {
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
                notes.append("二维相机 \(name) 不是有限标量，采用默认值 \(fallback)。")
                return fallback
            }
            return value
        }
        let candidateZoom = scalar(rawZoom, default: 1, name: "zoom")
        if candidateZoom > 0 { zoom = candidateZoom }
        else {
            zoom = 1
            notes.append("二维相机 zoom 非正值，当前采用 1；零或负缩放尚未适配。")
        }
        let fov = scalar(rawFOV, default: 95, name: "perspectiveoverridefov")
        perspectiveFOVDegrees = max(0.1, min(179.9, fov))
        if fov != perspectiveFOVDegrees {
            notes.append("二维相机 perspectiveoverridefov 按参考库限制到 0.1–179.9 度。")
        }
        diagnostics = notes
    }

    struct Frame {
        let matrix: simd_float4x4
        let appliedZoom: Float
        let usedFallback: Bool
    }

    func frame(visibleWidth: Float, visibleHeight: Float, cameraZoom: Float = 1) -> Frame? {
        func matrix(zoom: Float) -> simd_float4x4? {
            guard zoom.isFinite, zoom > 0, visibleWidth.isFinite, visibleHeight.isFinite,
                  visibleWidth > 0, visibleHeight > 0 else { return nil }
            // View translation already places the authored canvas center at
            // the origin. Scaling these axes therefore preserves that pivot.
            let x = Float(2 * Double(zoom) / Double(visibleWidth))
            let y = Float(2 * Double(zoom) / Double(visibleHeight))
            let result = simd_float4x4(diagonal: SIMD4(x, y, -2 / 10000, 1))
            let determinant = simd_determinant(result)
            guard x.isFinite, y.isFinite, determinant.isFinite, determinant != 0 else { return nil }
            let inverse = simd_inverse(result)
            guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { inverse[c][$0].isFinite } }) else { return nil }
            return result
        }
        let totalZoom = Float(Double(zoom) * Double(cameraZoom))
        if cameraZoom > 0, let result = matrix(zoom: totalZoom) {
            return Frame(matrix: result, appliedZoom: totalZoom, usedFallback: false)
        }
        if let result = matrix(zoom: 1) { return Frame(matrix: result, appliedZoom: 1, usedFallback: true) }
        return nil
    }

    struct ParticleFrame {
        let matrix: simd_float4x4
        let distance: Float
        let near: Float
        let far: Float
    }

    func particles(baseProjection: simd_float4x4, aspect: Float) -> ParticleFrame? {
        // Match the 2D framing at z=0, including both zoom factors. Only this draw
        // gets perspective; the renderer restores the base camera for children.
        let y = 1 / tan(Double(perspectiveFOVDegrees) * .pi / 360)
        let distance = Float(y / Double(baseProjection.columns.1.y))
        let near: Float = 5, far = max(15_000, distance + 1000)
        guard distance.isFinite, distance > 0,
              let matrix = NativePerspectiveProjection.makeMatrix(fovDegrees: perspectiveFOVDegrees,
                aspect: aspect, near: near, far: far) else { return nil }
        return ParticleFrame(matrix: matrix, distance: distance, near: near, far: far)
    }
}
