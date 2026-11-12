import AppKit

/// Values use the official SettingsCtrl identifiers.  `stop` is deliberately
/// accepted only by the selectors that expose it in the official UI; policy
/// normalization below keeps it out of focus and audio playback.
enum NativePlaybackAction: String, Codable, CaseIterable {
    case run, mute, pause, pauseall, stop
    func title(multimonitor: Bool) -> String {
        switch self {
        case .run: return "保持运行"
        case .mute: return "静音"
        case .pause: return multimonitor ? "按显示器暂停" : "暂停"
        case .pauseall: return "暂停所有"
        case .stop: return "停止（释放内存）"
        }
    }
}

struct NativeGeneralPlayback: Codable, Equatable {
    static let key = "nativeGeneralPlaybackV1"
    var focus: NativePlaybackAction = .run
    var maximized: NativePlaybackAction = .pause
    var fullscreen: NativePlaybackAction = .pause
    var battery: NativePlaybackAction = .run
    /// `playbackaudio` in the reference settings.  Its accepted set is
    /// intentionally narrower than the window conditions: run/mute/pause.
    var audio: NativePlaybackAction = .run
    var framesPerSecond: Int = 60
    private enum CodingKeys: String, CodingKey {
        case focus, maximized, fullscreen, battery, audio, framesPerSecond
    }
    init(focus: NativePlaybackAction = .run, maximized: NativePlaybackAction = .pause,
         fullscreen: NativePlaybackAction = .pause, battery: NativePlaybackAction = .run,
         audio: NativePlaybackAction = .run, framesPerSecond: Int = 60) {
        self.focus = focus; self.maximized = maximized; self.fullscreen = fullscreen
        self.battery = battery; self.audio = audio; self.framesPerSecond = framesPerSecond
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Existing fields retain their previous strict decoding.  Only the
        // new field is optional, so old V1 blobs preserve their exact choices
        // and simply gain the non-observing `run` default.
        focus = try values.decode(NativePlaybackAction.self, forKey: .focus)
        maximized = try values.decode(NativePlaybackAction.self, forKey: .maximized)
        fullscreen = try values.decode(NativePlaybackAction.self, forKey: .fullscreen)
        battery = try values.decode(NativePlaybackAction.self, forKey: .battery)
        audio = try values.decodeIfPresent(NativePlaybackAction.self, forKey: .audio) ?? .run
        framesPerSecond = try values.decode(Int.self, forKey: .framesPerSecond)
        self = normalized
    }
    var normalized: Self {
        var copy = self
        copy.framesPerSecond = min(240, max(10, framesPerSecond))
        // SettingsCtrl never offers stop for the focus selector.  It must not
        // become a hidden all-desktop release action through a malformed blob.
        if copy.focus == .stop { copy.focus = .run }
        if copy.battery == .mute || copy.battery == .pauseall { copy.battery = .pause }
        // Reference `playbackaudio` only exposes run/mute/pause.  Never let a
        // malformed value acquire either multi-display pauseall or desktop
        // stop semantics here.
        if copy.audio == .pauseall { copy.audio = .pause }
        if copy.audio == .stop { copy.audio = .run }
        return copy
    }
    static func load(defaults: UserDefaults = .standard, legacyCoverage: Bool) -> Self {
        let fallback = Self(maximized: legacyCoverage ? .pause : .run, fullscreen: legacyCoverage ? .pause : .run)
        guard let data = defaults.data(forKey: key), data.count <= 16_384,
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return fallback }
        return value.normalized
    }
    func save(defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(normalized) { defaults.set(data, forKey: Self.key) }
    }
}

/// Only these engine preferences participate in the settings dialog transaction.
/// Absence is retained as absence; cancel does not materialize defaults or alter
/// library content, permissions, display assignments or wallpaper properties.
struct NativePlaybackPreferenceSnapshot {
    static let keys = ["pauseWallpaperWhenCovered", "pauseWallpaperInLowPowerMode", "wallpaperLoadingTimeoutSeconds", NativeGeneralPlayback.key, NativeGraphicsSettings.key, NativeApplicationRulesStore.key, NativeInterfaceThemeStore.key, NativeInterfaceThemeStore.seasonalKey]
    private let values: [String: Any]
    init(defaults: UserDefaults = .standard) {
        values = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
    }
    func restore(defaults: UserDefaults = .standard) {
        for key in Self.keys {
            if let value = values[key] { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
    }
}

struct NativePlaybackDecision: Equatable {
    var pauseReason: String?
    var muted = false
    static func evaluate(_ environment: NativePlaybackEnvironment, display: CGDirectDisplayID?, desktop: Bool) -> Self {
        let preferences = environment.preferences
        // Both are global, explicit mute sources. They must survive an early
        // power-policy pause just as they do the normal desktop-rule path.
        let globalMuted = desktop && display != nil &&
            (environment.hotkeyPlayback.muted || environment.applicationEffects.muted)
        if preferences.pauseInLowPowerMode && environment.lowPowerMode {
            return .init(pauseReason: "低电量模式，已暂停", muted: globalMuted)
        }
        let settings = preferences.general
        // `stop` is handled by the controller-wide release request.  Do not
        // silently downgrade it to a per-renderer pause decision here.
        if environment.onBattery && settings.battery == .pause {
            return .init(pauseReason: "使用电池，已暂停", muted: globalMuted)
        }
        guard desktop, let display else { return Self() }
        // Explicit hotkey stop is a desktop-only, reversible renderer-release
        // request.  It takes precedence in the displayed reason even if an
        // application rule also currently requests a stop.
        if environment.hotkeyPlayback.stopped {
            return .init(pauseReason: "全局热键：已停止壁纸并释放资源", muted: true)
        }
        // REA 14006cea0: automatic conditions accumulate independently; run
        // adds no effect. Global mute is not limited to the event's display.
        let conditions: [(Set<CGDirectDisplayID>, NativePlaybackAction, String)] = [
            (environment.coveredDisplays, settings.fullscreen, "其他应用程序全屏"),
            (environment.maximizedDisplays, settings.maximized, "其他应用程序最大化"),
            (environment.focusedDisplays, settings.focus, "其他应用程序成为焦点")]
        let rules = environment.applicationEffects
        let audioMuted = environment.externalAudioAudible && settings.audio == .mute
        let audioPaused = environment.externalAudioAudible && settings.audio == .pause
        let muted = globalMuted || audioMuted ||
            conditions.contains { !$0.0.isEmpty && $0.1 == .mute }
        if rules.stopAll { return .init(pauseReason: "应用程序规则：停止壁纸并释放资源", muted: true) }
        if rules.pauseAll { return .init(pauseReason: "应用程序规则：暂停所有显示器", muted: muted) }
        if let all = conditions.first(where: { !$0.0.isEmpty && $0.1 == .pauseall }) {
            return .init(pauseReason: all.2 + "，已暂停所有显示器", muted: muted)
        }
        if rules.pausedDisplays.contains(display) { return .init(pauseReason: "应用程序规则：已暂停", muted: muted) }
        if audioPaused { return .init(pauseReason: "其他应用程序播放音频，已暂停", muted: muted) }
        if let local = conditions.first(where: { $0.0.contains(display) && $0.1 == .pause }) {
            return .init(pauseReason: local.2 + "，已暂停", muted: muted)
        }
        return .init(muted: muted)
    }
}

/// Geometry inference, not an Accessibility permission or window-title query.
/// Quartz frames are supplied in one coordinate space by the monitor.
enum NativePlaybackWindowGeometry {
    static func classify(window: CGRect, display: CGRect, visible: CGRect) -> (focused: Bool, maximized: Bool, fullscreen: Bool) {
        guard [window.minX, window.minY, window.width, window.height, display.minX, display.minY, display.width, display.height,
               visible.minX, visible.minY, visible.width, visible.height].allSatisfy(\.isFinite),
              window.width > 4, window.height > 4, display.width > 4, display.height > 4, visible.width > 4, visible.height > 4 else { return (false, false, false) }
        let intersection = window.intersection(display)
        let focused = !intersection.isNull && intersection.width > 2 && intersection.height > 2
        let fullscreen = window.contains(display.insetBy(dx: 2, dy: 2))
        return (focused, !fullscreen && window.contains(visible.insetBy(dx: 2, dy: 2)), fullscreen)
    }
}
