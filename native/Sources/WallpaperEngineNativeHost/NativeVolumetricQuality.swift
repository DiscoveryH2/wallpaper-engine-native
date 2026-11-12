import Foundation

/// Current stable volumetricsfront.frag and the native settings identifiers.
/// Keep quality 3 as the migration default for existing native installations.
enum NativeVolumetricQuality: String, Codable, CaseIterable {
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
    var divisor: Int { self == .low || self == .medium ? 8 : 4 }
    var blurPasses: Int { self == .low || self == .medium ? 2 : 0 }
    var shadowedSamples: Int { [0, 12, 24, 32, 64][index] }
    var unshadowedSamples: Int { [0, 2, 3, 5, 8][index] }
}
