import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

/// Only explicit user intent survives application launches. Temporary coverage,
/// power and session pause reasons are recalculated from the current environment.
enum NativeManualPlaybackStore {
    private static let key = "wallpaperManualPlaybackState"
    private struct State: Codable {
        let version: Int
        let projectIdentity: String
        let manuallyPaused: Bool
    }
    static func isPaused(for project: URL) -> Bool {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key), data.count <= 16_384,
              let state = try? JSONDecoder().decode(State.self, from: data), state.version == 1,
              let last = defaults.string(forKey: "lastProject"), last.hasPrefix("/") else { return false }
        let identity = SavedWorkshopStore.settingsIdentity(project)
        guard state.projectIdentity == identity,
              SavedWorkshopStore.settingsIdentity(URL(fileURLWithPath: last)) == identity else { return false }
        return state.manuallyPaused
    }
    static func save(project: URL, paused: Bool) {
        let state = State(version: 1, projectIdentity: SavedWorkshopStore.settingsIdentity(project), manuallyPaused: paused)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(state), data.count <= 16_384 else { return }
        if UserDefaults.standard.data(forKey: key) != data { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum NativeLoadingTimeout: Int, CaseIterable {
    case brief = 15, normal = 60, extended = 180
    var title: String { self == .normal ? "60 秒（默认）" : "\(rawValue) 秒" }
    var seconds: TimeInterval { TimeInterval(rawValue) }
}

struct NativePlaybackPreferences: Equatable {
    var pauseWhenCovered: Bool
    var pauseInLowPowerMode: Bool
    var loadingTimeout: NativeLoadingTimeout = .normal
    var general: NativeGeneralPlayback
    var graphics: NativeGraphicsSettings
    init(pauseWhenCovered: Bool, pauseInLowPowerMode: Bool, loadingTimeout: NativeLoadingTimeout = .normal, general: NativeGeneralPlayback? = nil, graphics: NativeGraphicsSettings = .init()) {
        self.pauseWhenCovered = pauseWhenCovered; self.pauseInLowPowerMode = pauseInLowPowerMode; self.loadingTimeout = loadingTimeout
        self.graphics = graphics
        self.general = (general ?? .init(maximized: pauseWhenCovered ? .pause : .run, fullscreen: pauseWhenCovered ? .pause : .run)).normalized
    }
    static func load() -> Self {
        let coverage = UserDefaults.standard.object(forKey: "pauseWallpaperWhenCovered") as? Bool ?? true
        return Self(pauseWhenCovered: coverage,
             pauseInLowPowerMode: UserDefaults.standard.object(forKey: "pauseWallpaperInLowPowerMode") as? Bool ?? false,
             loadingTimeout: (UserDefaults.standard.object(forKey: "wallpaperLoadingTimeoutSeconds") as? Int).flatMap(NativeLoadingTimeout.init(rawValue:)) ?? .normal,
             general: .load(legacyCoverage: coverage), graphics: .load())
    }
    func save() {
        UserDefaults.standard.set(pauseWhenCovered, forKey: "pauseWallpaperWhenCovered")
        UserDefaults.standard.set(pauseInLowPowerMode, forKey: "pauseWallpaperInLowPowerMode")
        UserDefaults.standard.set(loadingTimeout.rawValue, forKey: "wallpaperLoadingTimeoutSeconds")
        general.save(); graphics.save()
    }
}

/// Persistence belongs at the edge of the monitor.  The default closures keep
/// the existing UserDefaults archive behavior intact; an in-memory store lets
/// policy integration tests prove that configuration alone never starts audio
/// detection without writing a user's preferences.
struct NativePlaybackPolicyStorage {
    let loadPreferences: () -> NativePlaybackPreferences
    let savePreferences: (NativePlaybackPreferences) -> Void
    let loadApplicationRules: () throws -> [NativeApplicationRule]
    let saveApplicationRules: ([NativeApplicationRule]) throws -> Void

    static let standard = Self(loadPreferences: { .load() }, savePreferences: { $0.save() },
                               loadApplicationRules: { try NativeApplicationRulesStore.load() },
                               saveApplicationRules: { try NativeApplicationRulesStore.save($0) })
}

/// The reference runtime aggregates automatic `stop` actions into one
/// process-level boolean, while its `pause` action has a per-display mask.
/// Keep those representations distinct: none of these sources may turn into
/// a single-display renderer release in the native host.
enum NativeDesktopStopSource: Hashable {
    case hotkey
    case applicationRule
    case fullscreen
    case maximized
    case battery

    var summary: String {
        switch self {
        case .hotkey: return "全局热键"
        case .applicationRule: return "应用程序规则"
        case .fullscreen: return "其他应用程序全屏"
        case .maximized: return "其他应用程序最大化"
        case .battery: return "使用电池"
        }
    }
}

struct NativeDesktopStopRequest: Equatable {
    let sources: Set<NativeDesktopStopSource>

    var active: Bool { !sources.isEmpty }

    /// A stable display label is not an ownership rule.  All sources remain
    /// live until individually cleared; this only explains the stop to users.
    var primarySource: NativeDesktopStopSource? {
        [NativeDesktopStopSource.hotkey, .applicationRule, .fullscreen, .maximized, .battery]
            .first(where: { sources.contains($0) })
    }

    var summary: String { (primarySource?.summary ?? "播放策略") + "：已停止壁纸并释放资源" }
}

struct NativePlaybackEnvironment: Equatable {
    var preferences: NativePlaybackPreferences
    var coveredDisplays: Set<CGDirectDisplayID> = []
    var lowPowerMode = false
    var windowGeometryAvailable = true
    var focusedDisplays: Set<CGDirectDisplayID> = []
    var maximizedDisplays: Set<CGDirectDisplayID> = []
    var onBattery = false
    /// Set only after the process-audio bridge accepts an active, fresh meter
    /// snapshot for its current topology/generation lease.
    var externalAudioAudible = false
    var applicationEffects = NativeApplicationRuleEffects()
    /// Global hotkey intent is supplied by the monitor, but defaults to an
    /// inactive value for pure policy/renderer fixtures.  Such fixtures must
    /// not inherit the user's stored desktop state merely by constructing an
    /// environment.
    var hotkeyPlayback = NativeHotkeyPlayback()

    /// REA `FUN_14006cea0` shows a single stop boolean for fullscreen,
    /// maximized and battery conditions.  One matching display therefore
    /// releases the entire desktop presentation; only pause is per-display.
    var desktopStopRequest: NativeDesktopStopRequest {
        var sources = Set<NativeDesktopStopSource>()
        if hotkeyPlayback.stopped { sources.insert(.hotkey) }
        if applicationEffects.stopAll { sources.insert(.applicationRule) }
        if preferences.general.fullscreen == .stop, !coveredDisplays.isEmpty { sources.insert(.fullscreen) }
        if preferences.general.maximized == .stop, !maximizedDisplays.isEmpty { sources.insert(.maximized) }
        if preferences.general.battery == .stop, onBattery { sources.insert(.battery) }
        return .init(sources: sources)
    }

    var stopsDesktop: Bool { desktopStopRequest.active }
}

struct NativeApplicationWindowSample {
    let pid: pid_t
    let executable: String
    let bounds: CGRect
}

enum NativeApplicationWindowConditions {
    static func events(windows: [NativeApplicationWindowSample], displays: [(id: CGDirectDisplayID, bounds: CGRect, visible: CGRect)],
                       focusedPID: pid_t?) -> [NativeApplicationConditionEvent] {
        var events: [NativeApplicationConditionEvent] = [], foundFocus = false
        for window in windows {
            let focused = window.pid == focusedPID && !foundFocus
            if focused { foundFocus = true }
            // A native window has one principal screen. Match the largest
            // intersection; do not suspend both screens for a narrow overlap.
            let screen = displays.filter {
                let i = window.bounds.intersection($0.bounds); return !i.isNull && i.width > 2 && i.height > 2
            }.max {
                let a = window.bounds.intersection($0.bounds), b = window.bounds.intersection($1.bounds)
                return a.width * a.height < b.width * b.height
            }
            guard let screen else { continue }
            let state = NativePlaybackWindowGeometry.classify(window: window.bounds, display: screen.bounds, visible: screen.visible)
            if focused { events.append(.init(executable: window.executable, condition: .focused, display: screen.id)) }
            if state.maximized { events.append(.init(executable: window.executable, condition: .maximized, display: screen.id)) }
            if focused && state.fullscreen { events.append(.init(executable: window.executable, condition: .fullscreen, display: screen.id)) }
        }
        return events
    }
}

/// Uses public window geometry only. Window titles, pixels, and other app data
/// are never read or retained. A failed query does not invent a covered screen.
@MainActor
final class NativePlaybackPolicyMonitor {
    private(set) var environment: NativePlaybackEnvironment
    private(set) var applicationRules: [NativeApplicationRule] = []
    private(set) var applicationRulesNotice: String?
    var onChange: ((NativePlaybackEnvironment) -> Void)?
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var pending: DispatchWorkItem?
    private var activityTask: Task<Void, Never>?
    private var activitySnapshot: NativeApplicationActivitySnapshot?
    private var lastWindowEvents: [NativeApplicationConditionEvent] = []
    private var activityEpoch = 0
    /// Audio callbacks have a separate fence: a process inventory refresh is
    /// not proof that an earlier meter snapshot remains safe to apply.
    private var audioRequestGate = NativeProcessAudioPolicyRequestGate()
    private var audioBridge = NativeProcessAudioPolicyBridge()
    private var audioPlanTracker = NativeProcessAudioPolicyPlanTracker()
    private var acceptedAudioReading = NativeProcessAudioPolicyReading.empty
    private var audioMeterState: NativeProcessAudioMeterState = .off
    /// Preparing a plan reads only the injected process metadata, but it is
    /// asynchronous. Keep that UI lifetime separate from the meter's own
    /// state: there is deliberately no empty-plan "start" call merely to make
    /// the button look busy.
    private enum AudioEnablePhase: Equatable {
        case idle
        case resolvingPlan(UInt64)
        case submittingMeterStart(UInt64)
        /// A submitted start has been cancelled and its serial meter stop is
        /// still draining. New explicit attempts wait for this acknowledgement
        /// so an old stop can never tear down a newer session.
        case drainingCancelledStart(UInt64)
    }
    private var audioEnablePhase: AudioEnablePhase = .idle
    /// These are *only* normalized executable keys from user-saved non-run
    /// audio rules. Never put a process inventory, PID, bundle ID, peak, or
    /// actually audible application into UI status text.
    private var waitingAudioApplicationExecutableKeys: Set<String> = []
    /// Lifecycle authority remains inert until Settings explicitly confirms it.
    /// Tests supply an in-memory controller here; the production initializer
    /// continues to receive the native service created by the factory.
    private let processAudioMeter: (any NativeProcessAudioMeterControlling)?
    private let audioMeterReader: (any NativeProcessAudioMeterReading)?
    private let audioIdentityResolver: (any NativeProcessAudioIdentityResolving)?
    private let storage: NativePlaybackPolicyStorage
    /// The production default reads the bounded public process snapshot.  A
    /// fake closure keeps policy integration checks independent of host apps.
    private let activityCapture: @Sendable () -> NativeApplicationActivitySnapshot
    /// This stays enabled in production.  It lets a fake-only policy test save
    /// rules without falling through to Quartz window/process observation.
    private let allowsWindowObservation: Bool
    private var monitoring = false

    init(audioMeter: NativeProcessAudioMeterService? = nil,
         audioMeterReader: (any NativeProcessAudioMeterReading)? = nil,
         audioMeterController: (any NativeProcessAudioMeterControlling)? = nil,
         audioIdentityResolver: (any NativeProcessAudioIdentityResolving)? = nil,
         activityCapture: @escaping @Sendable () -> NativeApplicationActivitySnapshot = { NativeApplicationActivityReader.capture() },
         allowsWindowObservation: Bool = true,
         audioMeterSupported: Bool? = nil,
         storage: NativePlaybackPolicyStorage = .standard) {
        self.storage = storage
        environment = .init(preferences: storage.loadPreferences())
        let controller = audioMeterController ?? audioMeter
        processAudioMeter = controller
        self.audioMeterReader = audioMeterReader ?? controller
        self.audioIdentityResolver = audioIdentityResolver ?? Self.defaultAudioIdentityResolver()
        self.activityCapture = activityCapture
        self.allowsWindowObservation = allowsWindowObservation
        if controller != nil, !(audioMeterSupported ?? Self.audioMeterSupportedByHost) {
            audioMeterState = .unsupported
        }
        environment.hotkeyPlayback = .load()
        readApplicationRules()
    }

    private static func defaultAudioIdentityResolver() -> (any NativeProcessAudioIdentityResolving)? {
        if #available(macOS 14.2, *) { return NativeSystemProcessAudioIdentityResolver() }
        return nil
    }
    private static var audioMeterSupportedByHost: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    var audioDetectionState: NativeProcessAudioMeterState {
        switch audioEnablePhase {
        case .resolvingPlan, .submittingMeterStart: return .starting
        case .drainingCancelledStart: return .stopping
        case .idle: return audioMeterState
        }
    }
    var audioDetectionConfigurable: Bool {
        guard processAudioMeter != nil else { return false }
        if case .unsupported = audioMeterState { return false }
        return true
    }
    var audioDetectionNeedsObservation: Bool { audioRequirements.needsObservation }
    var audioDetectionStatusText: String {
        switch audioDetectionState {
        case .unsupported: return "当前 macOS 不支持按进程音频检测。"
        case .off: return audioRequirements.needsObservation ? "音频检测尚未启用；已保存的音频设置不会触发检测。" : "没有需要检测的音频动作。"
        case .waitingForApplicationTargets:
            let configured = waitingAudioApplicationExecutableKeys.sorted()
            if configured.isEmpty {
                return "目标应用现已可验证；请点击“重新检测目标应用”，检测不会自动开始。"
            }
            let names = configured.joined(separator: "、")
            return "正在等待已配置的目标应用（\(names)）提供可验证的音频进程身份；发现后仍需点击“重新检测目标应用”，不会自动开始。"
        case .starting: return "正在启用音频检测，正在准备受用户确认的检测请求。"
        case .active: return "音频检测已启用；只使用实时峰值，不保存或上传音频。"
        case .stopping: return "正在停止音频检测。"
        case .unavailable(let issue):
            switch issue {
            case .missingOwnProcessObject:
                return "系统未为本应用提供可验证的 CoreAudio Process Object；为避免将本应用音频混入检测，未启动全局采集。关闭并重新打开应用后可手动重试。"
            case .unsupportedOS:
                return "当前 macOS 不支持按进程音频检测。"
            case .deadlineExceeded:
                return "音频回调已超时，检测已停止；可手动重试。"
            case .unmappedRunExemption, .unmappedApplicationTarget:
                return "无法安全识别音频规则中的应用，因此检测未继续；请在应用运行后重试。"
            case .noCaptureDemand:
                return "没有需要检测的音频动作。"
            case .resourceLimit:
                return "音频规则目标过多，检测未开始。"
            case .lifecycleFailure:
                return "音频检测未能启动或已停止；这不表示权限被拒。请检查系统提示后手动重试。"
            }
        }
    }

    private var audioRequirements: NativeProcessAudioPolicyRequirements {
        .init(globalAction: environment.preferences.general.audio, rules: applicationRules)
    }
    private var audioRuleConfiguration: [NativeApplicationRule] {
        applicationRules.filter { $0.condition == .playingaudio }
    }

    private func readApplicationRules() {
        do { applicationRules = try storage.loadApplicationRules(); applicationRulesNotice = nil }
        catch { applicationRules = []; applicationRulesNotice = error.localizedDescription }
        if applicationRules.isEmpty {
            activityEpoch += 1; activityTask?.cancel(); activityTask = nil; activitySnapshot = nil
        }
    }

    func updateApplicationRules(_ rules: [NativeApplicationRule]) throws {
        let oldAudioRules = audioRuleConfiguration
        try storage.saveApplicationRules(rules)
        readApplicationRules()
        if oldAudioRules != audioRuleConfiguration {
            reconcileAudioPolicy(processes: activitySnapshot?.processes, invalidation: .hard)
        }
        refresh(force: true)
    }

    private func requestActivity() {
        guard monitoring, !applicationRules.isEmpty, activityTask == nil,
              activitySnapshot.map({ ProcessInfo.processInfo.systemUptime - $0.uptime >= 1 }) ?? true else { return }
        let epoch = activityEpoch
        let capture = activityCapture
        activityTask = Task { [weak self, capture] in
            let snapshot = await Task.detached(priority: .utility) { capture() }.value
            guard let self, !Task.isCancelled, epoch == self.activityEpoch else { return }
            self.activityTask = nil
            if snapshot.processStatus != .unavailable {
                let changed = self.activitySnapshot?.processes != snapshot.processes
                self.activitySnapshot = snapshot; self.applicationRulesNotice = nil
                // New processes, exits and PID reuse may alter run exclusions
                // and per-app targets.  This only reconciles an already-active
                // service; it can never begin an off/unavailable one.
                if changed { self.reconcileAudioPolicy(processes: snapshot.processes, invalidation: .safeProcessTopology) }
            } else { self.applicationRulesNotice = "暂时无法读取进程状态，保留上次规则状态。" }
            self.refresh(force: true, collectActivity: false)
        }
    }

    func start() {
        guard timer == nil else { return }
        monitoring = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            observers.append((workspace, token))
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, NSApplication.didChangeScreenParametersNotification] {
            let center = NotificationCenter.default
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            observers.append((center, token))
        }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        refresh(force: true)
    }

    func updatePreferences(_ preferences: NativePlaybackPreferences) {
        let oldAudioAction = environment.preferences.general.audio
        environment.preferences = preferences
        storage.savePreferences(preferences)
        if oldAudioAction != preferences.general.audio {
            reconcileAudioPolicy(processes: activitySnapshot?.processes, invalidation: .hard)
        }
        refresh(force: true)
    }
    func reloadPreferences() {
        let oldAudioAction = environment.preferences.general.audio, oldAudioRules = audioRuleConfiguration
        environment.preferences = storage.loadPreferences()
        environment.hotkeyPlayback = .load()
        readApplicationRules()
        if oldAudioAction != environment.preferences.general.audio || oldAudioRules != audioRuleConfiguration {
            reconcileAudioPolicy(processes: activitySnapshot?.processes, invalidation: .hard)
        }
        refresh(force: true)
    }

    private func audioPlan(processes: [pid_t: String]?) -> Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue> {
        let requirements = audioRequirements
        guard requirements.needsObservation else {
            return .success(.init(monitorsGlobal: false, globalExclusions: [], applicationTargets: []))
        }
        guard #available(macOS 14.2, *), let resolver = audioIdentityResolver else { return .failure(.unsupportedOS) }
        // A generic global action needs only the host identity.  Targeted
        // rules and run exclusions require a usable current process inventory;
        // fail closed instead of silently omitting a target/exclusion.
        let requiresInventory = !requirements.meterRequirements.runExemptionExecutableKeys.isEmpty ||
            !requirements.meterRequirements.applicationMeterExecutableKeys.isEmpty
        guard let processes else {
            return requiresInventory ? .failure(.lifecycleFailure) : NativeProcessAudioMeterPlan.resolve(
                ownPID: ProcessInfo.processInfo.processIdentifier, ownExecutable: ProcessInfo.processInfo.processName,
                namedProcesses: [:], requirements: requirements.meterRequirements, resolver: resolver)
        }
        return NativeProcessAudioMeterPlan.resolve(ownPID: ProcessInfo.processInfo.processIdentifier,
                                                   ownExecutable: ProcessInfo.processInfo.processName,
                                                   namedProcesses: processes,
                                                   requirements: requirements.meterRequirements,
                                                   resolver: resolver)
    }

    private enum AudioPolicyInvalidation { case hard, safeProcessTopology }

    private func unavailableApplicationKeys(
        in requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>
    ) -> Set<String> {
        guard case .success(let plan) = requested else { return [] }
        return plan.unavailableApplicationExecutableKeys
    }

    private func clearAcceptedAudioPolicy() {
        audioBridge.invalidateAllLeases()
        acceptedAudioReading = .empty
        audioPlanTracker.clear()
        environment.externalAudioAudible = false
    }

    private func finishCancelledSubmittedStart(epoch: UInt64, state: NativeProcessAudioMeterState,
                                               completions: [(NativeProcessAudioMeterState) -> Void]) {
        guard case .drainingCancelledStart(let current) = audioEnablePhase,
              current == epoch, audioRequestGate.epoch == epoch else { return }
        audioEnablePhase = .idle
        audioMeterState = state
        refresh(force: true, collectActivity: false, collectAudio: false)
        completions.forEach { $0(state) }
    }

    /// Cancels an enable which was confirmed in Settings but has not yet
    /// become a completed meter session. A cancellation after submission first
    /// drains the meter's serial stop; callers cannot start a replacement
    /// until this acknowledgement arrives, so an old stop cannot end a newer
    /// session. Returns whether it advanced/owns the audio request gate.
    @discardableResult
    private func cancelPendingAudioEnable(
        completion: ((NativeProcessAudioMeterState) -> Void)? = nil
    ) -> Bool {
        switch audioEnablePhase {
        case .idle:
            return false
        case .resolvingPlan:
            audioRequestGate.invalidate()
            audioEnablePhase = .idle
            completion?(audioMeterState)
            return true
        case .submittingMeterStart:
            audioRequestGate.invalidate()
            let epoch = audioRequestGate.epoch
            audioEnablePhase = .drainingCancelledStart(epoch)
            let completions = completion.map { [$0] } ?? []
            guard let processAudioMeter else {
                finishCancelledSubmittedStart(epoch: epoch, state: .off, completions: completions)
                return true
            }
            processAudioMeter.stop { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.finishCancelledSubmittedStart(epoch: epoch, state: state, completions: completions)
                }
            }
            return true
        case .drainingCancelledStart:
            // A second Stop can report the in-progress state, but it must not
            // enqueue another stop behind a user’s eventual retry.
            completion?(.stopping)
            return true
        }
    }

    /// Used by a Settings transaction cancel/close. It intentionally does not
    /// stop an already active, completed explicit session; restoring settings
    /// below reconciles that session only when the restored intent changes.
    func cancelPendingAudioDetectionStart() {
        // Do not invalidate an already accepted active lease simply because a
        // Settings transaction closes. If its restored audio intent changed,
        // reloadPreferences performs the normal hard reconciliation below.
        // A graphics-only cancel must leave the current active generation
        // usable rather than permanently rejecting its fresh snapshots.
        guard cancelPendingAudioEnable() else { return }
        clearAcceptedAudioPolicy()
        refresh(force: true, collectActivity: false, collectAudio: false)
    }

    /// Fences current readings synchronously. Reconciliation is legal only on
    /// an already active service, so preferences/rules/process refreshes never
    /// turn configuration edits into an Audio Capture prompt. Process identity
    /// refresh retains only meter-authenticated, prior app holds; intent edits
    /// and stops revoke every old lease.
    private func reconcileAudioPolicy(processes: [pid_t: String]?, invalidation: AudioPolicyInvalidation) {
        let plan = audioPlan(processes: processes)
        let cancelledPendingEnable = cancelPendingAudioEnable()
        if case .safeProcessTopology = invalidation, !cancelledPendingEnable,
           !audioPlanTracker.needsSafeReconciliation(for: plan) {
            // An unrelated launch/exit left exclusions and targets identical;
            // meter will no-op, so keep the current fresh topology lease.
            return
        }
        if !cancelledPendingEnable { audioRequestGate.invalidate() }
        switch invalidation {
        case .hard: audioBridge.invalidateAllLeases()
        case .safeProcessTopology: audioBridge.beginSafeTopologyReconciliation()
        }
        acceptedAudioReading = .empty
        environment.externalAudioAudible = false
        waitingAudioApplicationExecutableKeys = unavailableApplicationKeys(in: plan)
        guard let audioMeterReader else { return }
        audioMeterReader.reconcileActivePlan(plan)
        audioPlanTracker.record(plan)
    }

    private func requestAudioSnapshot() {
        guard monitoring, let audioMeterReader else { return }
        let token = audioRequestGate.beginSnapshot()
        audioMeterReader.snapshot { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self, self.audioRequestGate.accepts(token) else { return }
                let reading = self.audioBridge.consume(snapshot)
                let stateChanged = self.audioMeterState != snapshot.state
                let readingChanged = self.acceptedAudioReading != reading
                let waitingKeysChanged = self.waitingAudioApplicationExecutableKeys != snapshot.unavailableApplicationExecutableKeys
                self.audioMeterState = snapshot.state
                self.waitingAudioApplicationExecutableKeys = snapshot.unavailableApplicationExecutableKeys
                guard stateChanged || readingChanged || waitingKeysChanged else { return }
                self.acceptedAudioReading = reading
                // Do not recursively request another snapshot from this
                // completion.  Timer/lifecycle refreshes provide bounded poll.
                self.refresh(force: true, collectActivity: false, collectAudio: false)
            }
        }
    }

    /// The only monitor API permitted to reach the service's explicit-start
    /// method.  Settings presents the permission-purpose confirmation first;
    /// saving rules, changing dropdowns and opening the window never call it.
    func enableAudioDetectionFromExplicitUserAction(completion: @escaping (NativeProcessAudioMeterState) -> Void) {
        guard let processAudioMeter else { completion(.unsupported); return }
        guard audioRequirements.needsObservation else { completion(.off); return }
        guard case .idle = audioEnablePhase else { completion(audioDetectionState); return }
        switch audioMeterState {
        case .off, .waitingForApplicationTargets, .unavailable:
            break
        default:
            completion(audioDetectionState)
            return
        }
        audioRequestGate.invalidate()
        clearAcceptedAudioPolicy()
        let epoch = audioRequestGate.epoch
        audioEnablePhase = .resolvingPlan(epoch)
        let capture = activityCapture
        Task { [weak self, capture] in
            let snapshot = await Task.detached(priority: .utility) { capture() }.value
            guard let self, self.audioEnablePhase == .resolvingPlan(epoch),
                  epoch == self.audioRequestGate.epoch else { return }
            let plan: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>
            if snapshot.processStatus == .unavailable {
                // No external inventory is needed for a pure global action:
                // resolve only the host Process Object so it can be excluded.
                // `audioPlan(nil)` remains fail-closed whenever a saved run
                // exemption or attributed per-app target needs that inventory.
                // Do not retain this unusable snapshot for later reconciliation.
                plan = self.audioPlan(processes: nil)
            } else {
                self.activitySnapshot = snapshot
                plan = self.audioPlan(processes: snapshot.processes)
            }
            self.waitingAudioApplicationExecutableKeys = self.unavailableApplicationKeys(in: plan)
            self.audioEnablePhase = .submittingMeterStart(epoch)
            processAudioMeter.startFromExplicitUserAction(plan) { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.audioEnablePhase == .submittingMeterStart(epoch),
                          self.audioRequestGate.epoch == epoch else { return }
                    self.audioEnablePhase = .idle
                    self.audioPlanTracker.record(plan)
                    self.audioMeterState = state
                    if state == .active { self.requestAudioSnapshot() }
                    self.refresh(force: true, collectActivity: false, collectAudio: false)
                    completion(state)
                }
            }
        }
    }

    func stopAudioDetection(completion: @escaping (NativeProcessAudioMeterState) -> Void) {
        clearAcceptedAudioPolicy()
        if cancelPendingAudioEnable(completion: completion) {
            refresh(force: true, collectActivity: false, collectAudio: false)
            return
        }
        audioRequestGate.invalidate()
        waitingAudioApplicationExecutableKeys = []
        let epoch = audioRequestGate.epoch
        guard let processAudioMeter else { audioMeterState = .off; completion(.off); return }
        audioMeterState = .stopping
        processAudioMeter.stop { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.audioRequestGate.epoch == epoch else { return }
                self.audioMeterState = state
                self.refresh(force: true, collectActivity: false, collectAudio: false)
                completion(state)
            }
        }
    }

    /// This is the only monitor API that writes the hotkey override store.
    /// Timers and ordinary policy refreshes retain the already loaded value,
    /// avoiding an implicit preference materialization on every poll.
    func updateHotkeyPlayback(_ value: NativeHotkeyPlayback) {
        value.save()
        environment.hotkeyPlayback = value
        refresh(force: true)
    }

    func toggleHotkeyStopped() {
        var next = environment.hotkeyPlayback
        next.stopped.toggle()
        updateHotkeyPlayback(next)
    }

    func toggleHotkeyMuted() {
        var next = environment.hotkeyPlayback
        next.muted.toggle()
        updateHotkeyPlayback(next)
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
    }

    private func refresh(force: Bool = false, collectActivity: Bool = true, collectAudio: Bool = true) {
        var next = environment
        next.externalAudioAudible = acceptedAudioReading.globalAudible
        next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        next.onBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
            next.onBattery = source as String == kIOPSBatteryPowerValue
        }
        next.coveredDisplays = []; next.focusedDisplays = []; next.maximizedDisplays = []; next.windowGeometryAvailable = true
        var events: [NativeApplicationConditionEvent] = []
        if allowsWindowObservation && (!applicationRules.isEmpty || [next.preferences.general.focus, next.preferences.general.maximized, next.preferences.general.fullscreen].contains(where: { $0 != .run })) {
            if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                let displays = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect, CGRect)? in
                    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                    let id = number.uint32Value, bounds = CGDisplayBounds(id)
                    let frame = screen.frame, visible = screen.visibleFrame
                    guard bounds.width > 4, bounds.height > 4, frame.width > 4, frame.height > 4 else { return nil }
                    let sx = bounds.width / frame.width, sy = bounds.height / frame.height
                    let workArea = CGRect(x: bounds.minX + (visible.minX - frame.minX) * sx, y: bounds.minY + (frame.maxY - visible.maxY) * sy,
                                          width: visible.width * sx, height: visible.height * sy)
                    return (id, bounds, workArea)
                }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                var samples: [NativeApplicationWindowSample] = [], names = activitySnapshot?.processes ?? [:]
                for window in info.prefix(4096) {
                    guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                          (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                          ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 0) >= 0.95,
                          let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                          [bounds.origin.x, bounds.origin.y, bounds.width, bounds.height].allSatisfy(\.isFinite) else { continue }
                    if names[pid] == nil { names[pid] = NSRunningApplication(processIdentifier: pid)?.executableURL?.lastPathComponent }
                    // Unknown identities retain automatic geometry behavior,
                    // but cannot match a user-entered executable basename.
                    samples.append(.init(pid: pid, executable: names[pid] ?? "\0unknown:\(pid)", bounds: bounds))
                }
                events = NativeApplicationWindowConditions.events(windows: samples, displays: displays,
                    focusedPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
                lastWindowEvents = events
            } else { next.windowGeometryAvailable = false; events = lastWindowEvents }
        } else if !allowsWindowObservation {
            // Tests deliberately inject no window/process observer.  Preserve
            // the normal fail-closed representation rather than fabricating
            // geometry events from the current desktop.
            next.windowGeometryAvailable = false; events = lastWindowEvents
        }
        // `audioIOProcesses` remains diagnostics only.  An audio event can
        // arrive solely from the scalar meter bridge, with its authenticated
        // generation/topology evidence and no invented screen attribution.
        events += acceptedAudioReading.applicationEvents
        let input = NativeApplicationRuleInput(runningExecutables: Set(activitySnapshot?.processes.values.map { $0 } ?? []), events: events)
        let effectiveRules = applicationRules.filter {
            $0.condition != .playingaudio || NativeApplicationAction.options(for: .playingaudio, multimonitor: true).contains($0.action)
        }
        next.applicationEffects = (try? NativeApplicationRuleEvaluator(rules: effectiveRules).evaluate(input)) ?? .init(automaticEvents: events)
        for event in next.applicationEffects.automaticEvents {
            switch event.condition {
            case .focused: if let display = event.display { next.focusedDisplays.insert(display) }
            case .maximized: if let display = event.display { next.maximizedDisplays.insert(display) }
            case .fullscreen: if let display = event.display { next.coveredDisplays.insert(display) }
            case .running, .playingaudio: break
            }
        }
        if collectActivity { requestActivity() }
        if collectAudio { requestAudioSnapshot() }
        guard force || next != environment else { return }
        environment = next
        onChange?(next)
    }

    func stop() {
        monitoring = false; activityEpoch += 1; activityTask?.cancel(); activityTask = nil
        clearAcceptedAudioPolicy()
        let cancelledPendingEnable = cancelPendingAudioEnable()
        if !cancelledPendingEnable { audioRequestGate.invalidate() }
        waitingAudioApplicationExecutableKeys = []
        // App shutdown must release an explicitly enabled capture; this is a
        // stop, never a future-session authorization or automatic retry.
        if !cancelledPendingEnable { processAudioMeter?.stop(completion: nil) }
        activitySnapshot = nil; lastWindowEvents = []
        timer?.invalidate(); timer = nil
        pending?.cancel(); pending = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}

