import Foundation
import simd

/// Current Windows REA: 0x14025d3e0 / 0x14025d420 and common_pbr_2.h.
/// User settings keep the official quality identifiers. The existing native
/// 512-pixel, nine-tap path is the migration default.
enum NativeShadowQuality: String, Codable, CaseIterable {
    case disabled, low, medium, high, ultra
    var title: String {
        switch self {
        case .disabled: return "禁用"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .ultra: return "超高"
        }
    }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var faceSize: Int {
        switch self {
        case .disabled: return 0
        case .low, .medium: return 256
        case .high: return 512
        case .ultra: return 1024
        }
    }
    var filterTaps: Int { self == .disabled ? 0 : self == .low ? 1 : 9 }
    var fieldOfView: Float {
        let degrees: Float = self == .low || self == .medium ? 94 : self == .ultra ? 91.2 : 92
        return degrees * .pi / 180
    }
    var focalScale: Float { 1 / tan(fieldOfView / 2) }
}

/// Six square faces form one 2x3 light slot. Keep the existing one-row layout
/// when it fits; wrap high-resolution slots before exceeding a 16K texture.
/// The normalized grid is derived from the same dimensions by both shaders.
struct NativeShadowAtlasLayout: Equatable {
    let capacity: Int, faceSize: Int, columns: Int, rows: Int, width: Int, height: Int
    init(capacity: Int, quality: NativeShadowQuality) throws {
        guard (0...12).contains(capacity), capacity == 0 || quality != .disabled else {
            throw SceneError.invalid("原生阴影图集的灯光数量或品质无效。")
        }
        self.capacity = capacity; faceSize = quality.faceSize
        if capacity == 0 { columns = 0; rows = 0; width = 1; height = 1; return }
        columns = capacity * faceSize * 2 <= 16_384 ? capacity : (capacity + 1) / 2
        rows = (capacity + columns - 1) / columns
        width = columns * 2 * faceSize; height = rows * 3 * faceSize
        guard width <= 16_384, height <= 16_384, width * height * 4 <= 384 * 1024 * 1024 else {
            throw SceneError.invalid("原生阴影图集超过尺寸或显存预算。")
        }
    }
    func origin(slot: Int, face: Int) -> SIMD2<Int> {
        precondition((0..<capacity).contains(slot) && (0..<6).contains(face))
        let column = (slot % columns) * 2 + face % 2
        let row = (slot / columns) * 3 + face / 2
        return SIMD2(column * faceSize, row * faceSize)
    }
    func scale(quality: NativeShadowQuality) -> SIMD4<Float> {
        SIMD4(1 / Float(width), 1 / Float(height), Float(columns), quality.focalScale)
    }
}
