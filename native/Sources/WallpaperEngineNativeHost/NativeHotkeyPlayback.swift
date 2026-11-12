import Foundation

/// The two global playback overrides controlled by explicit user hotkey
/// actions.  This is deliberately separate from general playback preferences
/// and application-rule effects: it records only a user's most recent global
/// stop/mute choice and is never materialized by polling or by an ordinary
/// settings read.
struct NativeHotkeyPlayback: Codable, Equatable {
    static let key = "nativeHotkeyPlaybackV1"
    private static let currentVersion = 1
    private static let maximumDataSize = 4 * 1024

    private let version: Int
    var stopped: Bool
    var muted: Bool

    init(stopped: Bool = false, muted: Bool = false) {
        version = Self.currentVersion
        self.stopped = stopped
        self.muted = muted
    }

    private enum CodingKeys: String, CodingKey { case version, stopped, muted }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), data.count <= maximumDataSize,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == currentVersion else { return .init() }
        return value
    }

    /// Persist only as the result of an explicit hotkey action.  In
    /// particular, loading the monitor's environment must not create this key
    /// or overwrite a malformed payload.
    func save(defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), data.count <= Self.maximumDataSize else { return }
        guard defaults.data(forKey: Self.key) != data else { return }
        defaults.set(data, forKey: Self.key)
    }
}
