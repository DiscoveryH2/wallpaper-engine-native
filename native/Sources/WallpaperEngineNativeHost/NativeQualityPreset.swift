import Foundation

/// Values from the current public UI's getQualityPreset/applyPreset handlers.
/// Applying a preset leaves playback, loading and power preferences intact.
enum NativeQualityPreset: String, CaseIterable, Codable {
    case low, medium, high, ultra

    var title: String {
        switch self { case .low: return "低"; case .medium: return "中"; case .high: return "高"; case .ultra: return "超高" }
    }
    var framesPerSecond: Int {
        switch self { case .low: return 10; case .medium: return 15; case .high: return 25; case .ultra: return 30 }
    }
    var graphics: NativeGraphicsSettings {
        switch self {
        case .low: return .init(reflections: false, shadows: .low, volumetrics: .low, postProcessing: .disabled, preset: self)
        case .medium: return .init(shadows: .medium, volumetrics: .medium, postProcessing: .enabled, preset: self)
        case .high: return .init(shadows: .high, volumetrics: .high, postProcessing: .enabled, antialiasing: .x2, preset: self)
        case .ultra: return .init(shadows: .ultra, volumetrics: .ultra, postProcessing: .ultra, antialiasing: .x2, preset: self)
        }
    }
    var supportedByDevice: Bool { graphics.antialiasing.supportedByDevice }
    func applying(to preferences: NativePlaybackPreferences) -> NativePlaybackPreferences {
        var result = preferences
        result.general.framesPerSecond = framesPerSecond
        result.graphics = graphics
        return result
    }
}
