import Foundation
import simd

/// TextLayer::PreTransformModel translates by the unzoomed alignment crop
/// before the authored model. It does not turn the layer into a screen-space
/// overlay, and the translation is not inherited by authored child models.
enum NativeTextAnchor: String, CaseIterable {
    case none, center, top, topRight = "topright", right, bottomRight = "bottomright"
    case bottom, bottomLeft = "bottomleft", left, topLeft = "topleft"

    static func parse(_ value: Any?) throws -> Self {
        if value == nil { return .none }
        guard let name = value as? String, let anchor = Self(rawValue: name) else {
            throw SceneError.invalid("文字 anchor 必须是 none/center/top/topright/right/bottomright/bottom/bottomleft/left/topleft，保留上一有效锚点。")
        }
        return anchor
    }

    /// The current native scene framing is centered fill. Projection zoom and
    /// camera shake/parallax are separate operations in the reference engine.
    static func margins(canvas: SIMD2<Float>, aspect: Float) -> SIMD4<Float> {
        guard canvas.x.isFinite, canvas.y.isFinite, aspect.isFinite,
              canvas.x > 0, canvas.y > 0, aspect > 0 else { return .zero }
        let height = min(canvas.y, canvas.x / aspect), width = height * aspect
        let x = max(0, (canvas.x - width) / 2), y = max(0, (canvas.y - height) / 2)
        return SIMD4(x, y, x, y) // left, top, right, bottom
    }

    func offset(_ margins: SIMD4<Float>) -> SIMD2<Float> {
        let center = SIMD2((margins.x - margins.z) / 2, (margins.w - margins.y) / 2)
        switch self {
        case .none: return .zero
        case .center: return center
        case .top: return SIMD2(center.x, -margins.y)
        case .topRight: return SIMD2(-margins.z, -margins.y)
        case .right: return SIMD2(-margins.z, center.y)
        case .bottomRight: return SIMD2(-margins.z, margins.w)
        case .bottom: return SIMD2(center.x, margins.w)
        case .bottomLeft: return SIMD2(margins.x, margins.w)
        case .left: return SIMD2(margins.x, center.y)
        case .topLeft: return SIMD2(margins.x, -margins.y)
        }
    }

    final class State {
        private(set) var value: NativeTextAnchor
        private var requested: NSDictionary
        private var margins = SIMD4<Float>.zero
        private var rejected = 0
        private var notes: [String] = []
        init(_ object: [String: Any]) throws {
            value = try NativeTextAnchor.parse(object["anchor"])
            requested = NSDictionary(dictionary: ["anchor": object["anchor"] ?? "none"])
        }
        func update(_ object: [String: Any]) {
            let next = ["anchor": object["anchor"] ?? "none"]
            guard !requested.isEqual(to: next) else { return }
            requested = NSDictionary(dictionary: next)
            do { value = try NativeTextAnchor.parse(object["anchor"]) }
            catch {
                rejected += 1
                if !notes.contains(error.localizedDescription), notes.count < 8 { notes.append(error.localizedDescription) }
            }
        }
        func model(_ authored: simd_float4x4, margins: SIMD4<Float>) -> simd_float4x4 {
            self.margins = margins
            let offset = value.offset(margins)
            var translation = matrix_identity_float4x4
            translation.columns.3 = SIMD4(offset.x, offset.y, 0, 1)
            return translation * authored
        }
        var diagnostics: [String] {
            ["文字锚点：\(value.rawValue)，裁切边距 L/T/R/B=\(margins)，模型前偏移=\(value.offset(margins))，拒绝 \(rejected) 次；仅补偿二维居中填充裁切。"] + notes
        }
    }
}
