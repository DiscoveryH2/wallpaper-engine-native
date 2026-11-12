import AppKit
import Foundation

struct NativeSeasonalThemePrompt: Equatable {
    let event: NativeSeasonalThemeEvent

    var header: String { event.header }
    var body: String {
        "我们更改了 Wallpaper Engine 的主题以配合当下的场合！该主题会在若干天后自动改回原主题。\n\n" +
        "如果您不喜欢这一操作，您可以随时在设置中禁用季节主题或更改皮肤。\n\n" +
        "此外，发现标签中也有一个特别的配合时令的壁纸列表！"
    }
    var token: Int { event.token }
}

/// Browser-owned persistence. This intentionally stays outside the playback
/// settings transaction: the reference records a seen browser dialog even if
/// the user later cancels an unrelated Settings sheet.
enum NativeSeasonalThemePromptStore {
    static let disabledKey = "nativeSeasonalThemeDialogDisabledV1"
    static let timestampKey = "nativeSeasonalThemeDialogTimestampV1"

    static func dialogDisabled(defaults: UserDefaults = .standard) -> Bool {
        guard let value = defaults.object(forKey: disabledKey) as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
        return value.boolValue
    }

    /// Missing, fractional floating-point, negative and out-of-range values
    /// all mean "not previously acknowledged". The REA float branch accepts
    /// an in-range finite whole number, so `20261102.0` is intentionally just
    /// as valid as its integer representation.
    static func lastAcknowledgedToken(defaults: UserDefaults = .standard) -> Int? {
        guard let value = defaults.object(forKey: timestampKey) as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        if CFNumberIsFloatType(value) {
            let token = value.doubleValue
            guard token.isFinite,
                  token >= 0,
                  token <= Double(UInt32.max),
                  token.rounded(.towardZero) == token else { return nil }
            return Int(token)
        }
        let token = value.int64Value
        // REA `FUN_140046870` bounds this browser field to an unsigned
        // 32-bit value before comparing it. Anything outside that wire range
        // is treated as a missing token, never as a future acknowledgement.
        guard token >= 0, token <= Int64(UInt32.max) else { return nil }
        return Int(token)
    }

    static func recordResolvedPrompt(_ prompt: NativeSeasonalThemePrompt,
                                     neverShowAgain: Bool,
                                     defaults: UserDefaults = .standard) {
        // A malformed fractional NSNumber can remain float-typed when a
        // UserDefaults key is directly overwritten in the same process.
        // Reset that raw representation before recording the official integer
        // token, otherwise a successfully resolved prompt could reappear.
        defaults.removeObject(forKey: timestampKey)
        defaults.set(prompt.token, forKey: timestampKey)
        // The reference only materialises this key when the checkbox is on.
        // Do not write `false`: a normal acknowledgement must preserve an
        // absent raw preference for later, independent browser decisions.
        if neverShowAgain { defaults.set(true, forKey: disabledKey) }
    }
}

enum NativeSeasonalThemePromptDecision {
    static func prompt(settings: NativeInterfaceThemeSettings,
                       at date: Date = Date(),
                       timeZone: TimeZone = .autoupdatingCurrent,
                       defaults: UserDefaults = .standard) -> NativeSeasonalThemePrompt? {
        guard let event = settings.seasonalEvent(at: date, timeZone: timeZone),
              !NativeSeasonalThemePromptStore.dialogDisabled(defaults: defaults) else { return nil }
        let prompt = NativeSeasonalThemePrompt(event: event)
        if let seen = NativeSeasonalThemePromptStore.lastAcknowledgedToken(defaults: defaults), seen >= prompt.token {
            return nil
        }
        return prompt
    }
}

enum NativeSeasonalThemePromptResponse: Equatable {
    /// A resolved default/OK button. It records the token, but changes no
    /// theme or browser route.
    case acknowledge(neverShowAgain: Bool)
    case browseCollection(neverShowAgain: Bool)
    case disableTheming(neverShowAgain: Bool)
    /// An AppKit abort (Escape, system-close, or a failed presentation) is not
    /// a resolved official modal action and must not persist anything.
    case abort
}

/// State machine shared by the native AppKit sheet and isolated tests. The
/// presenter deliberately receives the already-captured event, so a sheet
/// that crosses midnight still writes the original reference token.
@MainActor
final class NativeSeasonalThemePromptCoordinator {
    typealias SettingsProvider = () -> NativeInterfaceThemeSettings
    typealias Eligibility = () -> Bool
    typealias Presenter = (_ prompt: NativeSeasonalThemePrompt,
                           _ completion: @escaping (NativeSeasonalThemePromptResponse) -> Void) -> Bool
    typealias Action = () -> Void

    private let settings: SettingsProvider
    private let eligible: Eligibility
    private let present: Presenter
    private let browseCollection: Action
    private let disableTheming: Action
    private let defaults: UserDefaults
    private let now: () -> Date
    private let timeZone: () -> TimeZone
    private var observers: [NSObjectProtocol] = []
    private var presenting = false
    /// A rejected/aborted AppKit sheet cannot persist the official timestamp.
    /// Suppress that event only for the active library presentation so an Esc
    /// key cannot create an immediate re-presentation loop.
    private var abortedTokensInSession = Set<Int>()

    init(settings: @escaping SettingsProvider = { NativeInterfaceThemeStore.load() },
         eligible: @escaping Eligibility,
         present: @escaping Presenter,
         browseCollection: @escaping Action,
         disableTheming: @escaping Action,
         defaults: UserDefaults = .standard,
         now: @escaping () -> Date = Date.init,
         timeZone: @escaping () -> TimeZone = { .autoupdatingCurrent },
         observesThemeChanges: Bool = true) {
        self.settings = settings
        self.eligible = eligible
        self.present = present
        self.browseCollection = browseCollection
        self.disableTheming = disableTheming
        self.defaults = defaults
        self.now = now
        self.timeZone = timeZone
        guard observesThemeChanges else { return }
        observers.append(NotificationCenter.default.addObserver(forName: NativeInterfaceThemeRuntime.didChange,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestPresentationIfEligible() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.requestPresentationIfEligible() }
            }
        })
        // Playback Settings is an independent window rather than a sheet.
        // Once it closes, the Library becomes key again; that is the safe
        // point to retry an event that was deferred without writing state.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.requestPresentationIfEligible() }
            }
        })
    }

    deinit {
        // `deinit` is nonisolated under strict concurrency. Copying and
        // removing the observer tokens directly avoids scheduling work after
        // the coordinator has gone away.
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func close() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    /// Call only after a regular wallpaper Library controller was presented.
    /// It makes an abort retryable on a later library presentation but does
    /// not touch any persisted browser state.
    func beginLibraryPresentationSession() {
        abortedTokensInSession.removeAll()
        requestPresentationIfEligible()
    }

    func requestPresentationIfEligible() {
        guard !presenting, eligible(),
              let prompt = NativeSeasonalThemePromptDecision.prompt(settings: settings(), at: now(),
                                                                       timeZone: timeZone(), defaults: defaults),
              !abortedTokensInSession.contains(prompt.token) else { return }
        presenting = true
        var completed = false
        let started = present(prompt) { [weak self] response in
            guard !completed else { return }
            completed = true
            self?.complete(prompt: prompt, response: response)
        }
        if !started { presenting = false }
    }

    private func complete(prompt: NativeSeasonalThemePrompt, response: NativeSeasonalThemePromptResponse) {
        presenting = false
        switch response {
        case .abort:
            abortedTokensInSession.insert(prompt.token)
        case .acknowledge(let neverShowAgain):
            NativeSeasonalThemePromptStore.recordResolvedPrompt(prompt, neverShowAgain: neverShowAgain, defaults: defaults)
        case .browseCollection(let neverShowAgain):
            NativeSeasonalThemePromptStore.recordResolvedPrompt(prompt, neverShowAgain: neverShowAgain, defaults: defaults)
            browseCollection()
        case .disableTheming(let neverShowAgain):
            NativeSeasonalThemePromptStore.recordResolvedPrompt(prompt, neverShowAgain: neverShowAgain, defaults: defaults)
            disableTheming()
        }
    }
}

/// Native rendering of the official three resolved actions. It has no cancel
/// button; any unexpected AppKit dismissal is explicitly treated as abort.
@MainActor
enum NativeSeasonalThemePromptSheet {
    static func present(_ prompt: NativeSeasonalThemePrompt, on window: NSWindow,
                        completion: @escaping (NativeSeasonalThemePromptResponse) -> Void) -> Bool {
        guard window.isVisible, window.attachedSheet == nil else { return false }
        let alert = makeAlert(prompt)
        alert.beginSheetModal(for: window) { response in
            completion(responseForModalResponse(response, neverShowAgain: alert.suppressionButton?.state == .on))
        }
        return true
    }

    static func makeAlert(_ prompt: NativeSeasonalThemePrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.header
        alert.informativeText = prompt.body
        // The reference leaves its generic modal's OK text at `ui_ok`, whose
        // current Simplified Chinese stable translation is "确认".
        alert.addButton(withTitle: "确认")
        alert.addButton(withTitle: "浏览收藏")
        alert.addButton(withTitle: "禁用主题")
        // An AppKit secondary alert button can otherwise receive Escape as a
        // key equivalent. The reference has no cancel control: Escape is a
        // dismissed/rejected modal, not an implicit Browse or Disable action.
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = ""
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "不再显示此对话框"
        alert.suppressionButton?.state = .off
        return alert
    }

    static func responseForModalResponse(_ response: NSApplication.ModalResponse,
                                         neverShowAgain: Bool) -> NativeSeasonalThemePromptResponse {
        switch response {
        case .alertFirstButtonReturn: return .acknowledge(neverShowAgain: neverShowAgain)
        case .alertSecondButtonReturn: return .browseCollection(neverShowAgain: neverShowAgain)
        case .alertThirdButtonReturn: return .disableTheming(neverShowAgain: neverShowAgain)
        default: return .abort
        }
    }
}
