import AppKit

/// The public stable Wallpaper Engine skin choices.  Hidden skins unlocked by
/// the reference application's Konami path are deliberately not accepted by
/// this normal settings model.
enum NativeInterfaceTheme: String, CaseIterable, Equatable {
    case white, dark, halloween, winter

    var title: String {
        switch self {
        case .white: return "白色"
        case .dark: return "暗色"
        case .halloween: return "万圣节"
        case .winter: return "冬天"
        }
    }

    var applicationAppearance: NSAppearance.Name {
        self == .white ? .aqua : .darkAqua
    }
}

/// The two public seasonal events that the current Windows stable build can
/// apply automatically. The token deliberately remains opaque: it mirrors
/// the reference's browser-dialog de-duplication value rather than pretending
/// that every decimal component is a date.
///
/// This belongs beside the date-to-skin mapping, rather than the AppKit prompt,
/// so the runtime skin and its browser prompt cannot disagree about an event.
enum NativeSeasonalThemeEvent: Equatable {
    case halloween(eventYear: Int)
    case winter(eventYear: Int)

    var theme: NativeInterfaceTheme {
        switch self {
        case .halloween: return .halloween
        case .winter: return .winter
        }
    }

    var header: String {
        switch self {
        case .halloween: return "不给糖就捣蛋，万圣节到了"
        case .winter: return "冬天到了"
        }
    }

    /// Windows Build 26168761 uses YYYY1102 for Halloween and YYYY0089 for
    /// Winter. `89` is an implementation token, not a calendar date.
    var token: Int {
        switch self {
        case .halloween(let eventYear): return eventYear * 10_000 + 1_102
        case .winter(let eventYear): return eventYear * 10_000 + 89
        }
    }
}

/// This is intentionally separate from playback preferences.  A skin affects
/// native windows, never wallpaper policy or desktop renderer state.
struct NativeInterfaceThemeSettings: Equatable {
    var theme: NativeInterfaceTheme = .white
    /// The reference has this enabled by default.  It overlays, but never
    /// rewrites, `theme`: after the seasonal interval the chosen base skin
    /// reappears exactly as the user left it.
    var seasonalEnabled = true

    /// Wallpaper Engine's native path uses Windows `GetLocalTime`, whose
    /// month/day fields are Gregorian even when a user selects another
    /// calendar in system preferences.  Keep the local time zone dynamic,
    /// while fixing the calendar identifier to Gregorian.
    func seasonalEvent(at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> NativeSeasonalThemeEvent? {
        guard seasonalEnabled else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let values = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = values.year, let month = values.month, let day = values.day else { return nil }
        switch (month, day) {
        case (10, 24...31), (11, 1...2): return .halloween(eventYear: year)
        // The reference's winter prompt considers December and the following
        // January one event.  Its opaque de-duplication token therefore uses
        // the January year for either side of that boundary.
        case (12, _): return .winter(eventYear: year + 1)
        case (1, _): return .winter(eventYear: year)
        default: return nil
        }
    }

    func effectiveTheme(at date: Date = Date(), timeZone: TimeZone = .autoupdatingCurrent) -> NativeInterfaceTheme {
        seasonalEvent(at: date, timeZone: timeZone)?.theme ?? theme
    }
}

enum NativeInterfaceThemeStore {
    static let key = "nativeInterfaceThemeV1"
    static let seasonalKey = "nativeInterfaceSeasonalThemeV1"
    private static let maximumRawValueUTF8Count = 32

    static func load(defaults: UserDefaults = .standard) -> NativeInterfaceThemeSettings {
        let theme: NativeInterfaceTheme
        guard let raw = defaults.object(forKey: key) as? String,
              raw.utf8.count <= maximumRawValueUTF8Count,
              let parsed = NativeInterfaceTheme(rawValue: raw) else {
            theme = .white
            return .init(theme: theme, seasonalEnabled: seasonalEnabled(defaults: defaults))
        }
        theme = parsed
        return .init(theme: theme, seasonalEnabled: seasonalEnabled(defaults: defaults))
    }

    /// Each setter intentionally owns only its raw key.  Settings may remain
    /// open while a separate path updates the other preference; a control
    /// action must not materialize or overwrite that untouched value.
    static func saveTheme(_ theme: NativeInterfaceTheme, defaults: UserDefaults = .standard) {
        defaults.set(theme.rawValue, forKey: key)
    }

    static func saveSeasonalEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: seasonalKey)
    }

    private static func seasonalEnabled(defaults: UserDefaults) -> Bool {
        guard let value = defaults.object(forKey: seasonalKey) else { return true }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return true }
        return number.boolValue
    }
}

/// A complete palette is kept here rather than scattering seasonal colour
/// decisions among views.  The browser style owns how each field is drawn.
@MainActor
struct NativeInterfaceThemePalette: Equatable {
    let theme: NativeInterfaceTheme
    let background: NSColor
    let surface: NSColor
    let border: NSColor
    let accent: NSColor
    let foreground: NSColor
    let mutedForeground: NSColor
    let cardBackground: NSColor
    let selectionFill: NSColor

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    static let white = Self(theme: .white, background: color(0xf3f3f3), surface: color(0xffffff),
                            border: color(0xbbbbbb), accent: color(0x2973f3), foreground: color(0x333333),
                            mutedForeground: color(0x707070), cardBackground: color(0xffffff), selectionFill: color(0xdbe9ff))
    static let dark = Self(theme: .dark, background: color(0x222222), surface: color(0x2b2b2b),
                           border: color(0x3c3c3c), accent: color(0x4183f5), foreground: color(0xeeeeee),
                           mutedForeground: color(0xb9b9b9), cardBackground: color(0x2b2b2b), selectionFill: color(0x324b6f))
    static let halloween = Self(theme: .halloween, background: color(0x111115), surface: color(0x1b171d),
                                border: color(0x663628), accent: color(0xff3d00), foreground: color(0xeeeeee),
                                mutedForeground: color(0xc9b5ae), cardBackground: color(0x201b23), selectionFill: color(0x5b291c))
    static let winter = Self(theme: .winter, background: color(0x101c26), surface: color(0x152735),
                             border: color(0x35536a), accent: color(0x6ea0b9), foreground: color(0xeeeeee),
                             mutedForeground: color(0xc3d2db), cardBackground: color(0x172d3b), selectionFill: color(0x29485a))
}

/// The runtime applies a saved skin before native windows are created and
/// publishes explicit changes for dark -> Halloween/Winter transitions, where
/// AppKit's effective appearance remains dark Aqua and supplies no callback.
@MainActor
enum NativeInterfaceThemeRuntime {
    static let didChange = Notification.Name("NativeInterfaceThemeRuntimeDidChange")

    private(set) static var currentTheme: NativeInterfaceTheme = .white
    private(set) static var seasonalEnabled = true
    private(set) static var currentEffectiveTheme: NativeInterfaceTheme = .white
    private static var seasonalRefreshTimer: Timer?
    private static var refreshObservers: [NSObjectProtocol] = []

    static func palette(for appearance: NSAppearance) -> NativeInterfaceThemePalette {
        switch currentEffectiveTheme {
        case .halloween: return .halloween
        case .winter: return .winter
        case .white, .dark:
            return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .white
        }
    }

    static func applyStoredTheme(defaults: UserDefaults = .standard) {
        apply(NativeInterfaceThemeStore.load(defaults: defaults))
    }

    static func apply(_ settings: NativeInterfaceThemeSettings, now: Date = Date()) {
        currentTheme = settings.theme
        seasonalEnabled = settings.seasonalEnabled
        installRefreshObserversIfNeeded()
        refreshNow(now)
    }

    /// System-clock, time-zone and wake events can cross a seasonal boundary
    /// without the midnight timer firing.  This recomputes only application
    /// appearance; it never writes a UserDefaults key or changes macOS.
    static func refreshNow(_ now: Date = Date(), scheduleRefresh: Bool = true) {
        let effective = NativeInterfaceThemeSettings(theme: currentTheme, seasonalEnabled: seasonalEnabled).effectiveTheme(at: now)
        let changed = currentEffectiveTheme != effective
        currentEffectiveTheme = effective
        NSApp.appearance = NSAppearance(named: effective.applicationAppearance)
        if scheduleRefresh { scheduleSeasonalRefresh(after: now) }
        else { seasonalRefreshTimer?.invalidate(); seasonalRefreshTimer = nil }
        guard changed else { return }
        for window in NSApp.windows {
            guard let root = window.contentView else { continue }
            invalidate(root)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Tests may switch the live palette without persisting a value.  The
    /// previous value is returned so every fixture can restore it explicitly.
    @discardableResult
    static func setForTesting(_ settings: NativeInterfaceThemeSettings, now: Date = Date()) -> NativeInterfaceThemeSettings {
        let previous = NativeInterfaceThemeSettings(theme: currentTheme, seasonalEnabled: seasonalEnabled)
        currentTheme = settings.theme
        seasonalEnabled = settings.seasonalEnabled
        // A fixture can deliberately inject a historical seasonal date. Do
        // not arm a timer for that historical midnight and let it immediately
        // replace the injected effective skin with the host clock's date.
        refreshNow(now, scheduleRefresh: false)
        return previous
    }

    private static func scheduleSeasonalRefresh(after now: Date) {
        seasonalRefreshTimer?.invalidate(); seasonalRefreshTimer = nil
        guard seasonalEnabled else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        guard let followingMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return }
        let timer = Timer(fire: followingMidnight, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                refreshNow()
            }
        }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        seasonalRefreshTimer = timer
    }

    private static func installRefreshObserversIfNeeded() {
        guard refreshObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [Notification.Name.NSSystemClockDidChange,
                     Notification.Name.NSCalendarDayChanged,
                     Notification.Name.NSSystemTimeZoneDidChange] {
            refreshObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { refreshNow() }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        refreshObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { refreshNow() }
        })
    }

    private static func invalidate(_ view: NSView) {
        view.needsLayout = true
        view.needsDisplay = true
        for child in view.subviews { invalidate(child) }
    }
}
