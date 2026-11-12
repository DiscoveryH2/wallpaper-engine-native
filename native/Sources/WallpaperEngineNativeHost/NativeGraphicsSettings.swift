import Foundation

/// Global overrides are separate from author material properties. Existing
/// installations retain their authored reflections until the user changes this.
struct NativeGraphicsSettings: Codable, Equatable {
    static let key = "nativeGraphicsSettingsV1"
    var reflections = true
    var shadows: NativeShadowQuality = .high
    var volumetrics: NativeVolumetricQuality = .high
    var antialiasing: NativeAntialiasing = .none
    var postProcessing: NativePostProcessingQuality = .ultra
    var textureResolution: NativeTextureResolution = .full
    // Like the reference UI, manual adjustments retain the last applied name.
    // It is not treated as proof that all current values still match that preset.
    var preset: NativeQualityPreset?

    init(reflections: Bool = true, shadows: NativeShadowQuality = .high, volumetrics: NativeVolumetricQuality = .high, postProcessing: NativePostProcessingQuality = .ultra, antialiasing: NativeAntialiasing = .none, textureResolution: NativeTextureResolution = .full, preset: NativeQualityPreset? = nil) {
        self.reflections = reflections; self.shadows = shadows; self.volumetrics = volumetrics
        self.postProcessing = postProcessing; self.antialiasing = antialiasing; self.textureResolution = textureResolution
        self.preset = preset
    }
    private enum CodingKeys: String, CodingKey { case reflections, shadows, volumetrics, postProcessing, antialiasing, textureResolution, preset }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reflections = (try? values.decode(Bool.self, forKey: .reflections)) ?? true
        shadows = (try? values.decode(NativeShadowQuality.self, forKey: .shadows)) ?? .high
        volumetrics = (try? values.decode(NativeVolumetricQuality.self, forKey: .volumetrics)) ?? .high
        antialiasing = (try? values.decode(NativeAntialiasing.self, forKey: .antialiasing)) ?? .none
        textureResolution = (try? values.decode(NativeTextureResolution.self, forKey: .textureResolution)) ?? .full
        preset = try? values.decode(NativeQualityPreset.self, forKey: .preset)
        // Retain the pre-setting native HDR/SDR behavior on existing installs.
        postProcessing = (try? values.decode(NativePostProcessingQuality.self, forKey: .postProcessing)) ?? .ultra
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), data.count <= 16_384,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
    func save(defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(self) { defaults.set(data, forKey: Self.key) }
    }
}
