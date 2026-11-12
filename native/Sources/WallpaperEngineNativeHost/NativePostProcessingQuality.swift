import Foundation

/// The SDR display choices in the stable Steam UI. Display-HDR is intentionally
/// not advertised until the native presentation path supports EDR output.
enum NativePostProcessingQuality: String, CaseIterable, Codable, Sendable {
    case disabled, enabled, ultra
    var title: String {
        switch self { case .disabled: "禁用"; case .enabled: "启用"; case .ultra: "超高" }
    }
    var allowsBloom: Bool { self != .disabled }
    func usesHDR(authored: Bool) -> Bool { self == .ultra && authored }
}
