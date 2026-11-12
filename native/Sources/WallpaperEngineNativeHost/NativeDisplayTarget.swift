import Foundation

/// One content destination shared by the browser, playlists and hotkeys.
/// Display numbers are presentation labels; only a host display key identifies
/// a screen. An unavailable or malformed display must never select default.
enum NativeDisplayTarget: Equatable, Hashable, Sendable {
    case defaultWallpaper
    case display(String)

    init(location: String?) throws {
        guard let location, location != "default" else {
            self = .defaultWallpaper
            return
        }
        guard NativeDisplayLayout.validKey(location) else {
            throw NativePlaylistError.invalid("显示器目标无效，原桌面保持不变。")
        }
        self = .display(location)
    }

    var key: String {
        switch self {
        case .defaultWallpaper: return "default"
        case .display(let key): return key
        }
    }

    /// Keep the session key here instead of translating it to nil/default.
    /// Shortcut creation must also require `persistent`, because a session
    /// display ID can identify a different screen after the app restarts.
    var hotkeyLocation: String? {
        switch self {
        case .defaultWallpaper: return nil
        case .display(let key): return key
        }
    }

    var persistent: Bool {
        switch self {
        case .defaultWallpaper: return true
        case .display(let key): return key.hasPrefix("uuid:") && NativeDisplayLayout.validKey(key)
        }
    }

    func validated() throws -> Self { try Self(location: key) }
}
