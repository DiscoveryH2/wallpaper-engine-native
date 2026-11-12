import CoreAudio
import Darwin
import Foundation

// This adapter is intentionally independent of NativeAudio.swift.  NativeAudio
// retains PCM for FFT-driven wallpaper effects; this component never retains a
// PCM frame and only publishes bounded scalar peaks after explicit opt-in.

struct NativeProcessAudioIdentity: Hashable, Sendable, Comparable {
    let pid: pid_t
    let processObjectID: AudioObjectID
    let startToken: UInt64
    let executableKey: String

    init(pid: pid_t, processObjectID: AudioObjectID, startToken: UInt64, executable: String) {
        self.pid = pid
        self.processObjectID = processObjectID
        self.startToken = startToken
        self.executableKey = executable.lowercased()
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.pid, lhs.processObjectID, lhs.startToken, lhs.executableKey) <
            (rhs.pid, rhs.processObjectID, rhs.startToken, rhs.executableKey)
    }
}

enum NativeProcessAudioMeterIssue: Error, Equatable, Sendable {
    case unsupportedOS
    case missingOwnProcessObject
    case unmappedRunExemption(pid_t)
    case unmappedApplicationTarget(pid_t)
    case noCaptureDemand
    case resourceLimit
    case lifecycleFailure
    case deadlineExceeded
}

enum NativeProcessAudioMeterState: Equatable, Sendable {
    case unsupported
    case off
    /// The user has explicitly enabled detection, but no configured external
    /// application currently has a trustworthy Process Object. Metadata may
    /// refresh this state, but only another explicit user retry may start IO.
    case waitingForApplicationTargets
    case starting
    case active
    case stopping
    case unavailable(NativeProcessAudioMeterIssue)
}

/// The rule bridge supplies lowercased executable basenames, preserving the
/// existing application's rule-store matching semantics.
struct NativeProcessAudioMeterRequirements: Sendable {
    /// False when the global playback setting is `run`; in that case audio
    /// rules alone must not start a global mix merely to discover exclusions.
    let requiresGlobalMeter: Bool
    let runExemptionExecutableKeys: Set<String>
    let applicationMeterExecutableKeys: Set<String>

    init(requiresGlobalMeter: Bool = false,
         runExemptionExecutableKeys: Set<String> = [], applicationMeterExecutableKeys: Set<String> = []) {
        self.requiresGlobalMeter = requiresGlobalMeter
        self.runExemptionExecutableKeys = Set(runExemptionExecutableKeys.map { $0.lowercased() })
        self.applicationMeterExecutableKeys = Set(applicationMeterExecutableKeys.map { $0.lowercased() })
    }
}

/// A tap plan never represents a permission grant.  Resolving it reads only
/// bounded process metadata; `startFromExplicitUserAction` is the only method
/// allowed to call a backend that can reach AudioDeviceStart.
struct NativeProcessAudioMeterPlan: Equatable, Sendable {
    let monitorsGlobal: Bool
    let globalExclusions: Set<NativeProcessAudioIdentity>
    /// Every saved non-run external application-rule key, including currently
    /// stopped applications that have no Process Object to capture yet.
    let configuredApplicationExecutableKeys: Set<String>
    let applicationTargets: Set<NativeProcessAudioIdentity>
    /// These names have a saved non-run audio rule but no trustworthy current
    /// Process Object.  They are never inferred from I/O metadata; global
    /// monitoring remains safe when its own exclusions are complete.
    let unavailableApplicationExecutableKeys: Set<String>

    init(monitorsGlobal: Bool, globalExclusions: Set<NativeProcessAudioIdentity>,
         configuredApplicationExecutableKeys: Set<String> = [], applicationTargets: Set<NativeProcessAudioIdentity>,
         unavailableApplicationExecutableKeys: Set<String> = []) {
        self.monitorsGlobal = monitorsGlobal
        self.globalExclusions = globalExclusions
        self.configuredApplicationExecutableKeys = Set(configuredApplicationExecutableKeys.map { $0.lowercased() })
        self.applicationTargets = applicationTargets
        self.unavailableApplicationExecutableKeys = Set(unavailableApplicationExecutableKeys.map { $0.lowercased() })
    }
    var requiresCapture: Bool { monitorsGlobal || !applicationTargets.isEmpty }
    var hasWaitingApplicationTargets: Bool { !unavailableApplicationExecutableKeys.isEmpty }

    static func resolve(ownPID: pid_t,
                        ownExecutable: String,
                        namedProcesses: [pid_t: String],
                        requirements: NativeProcessAudioMeterRequirements,
                        resolver: NativeProcessAudioIdentityResolving) -> Result<Self, NativeProcessAudioMeterIssue> {
        var excluded: Set<NativeProcessAudioIdentity> = []
        if requirements.requiresGlobalMeter {
            guard let own = resolver.resolve(pid: ownPID, executable: ownExecutable) else {
                return .failure(.missingOwnProcessObject)
            }
            excluded.insert(own)
        }
        // The meter is for other applications. An accidentally saved host
        // basename cannot make the host into a target or leave the UI waiting
        // for its own process to become external.
        let configuredTargets = requirements.applicationMeterExecutableKeys.subtracting([ownExecutable.lowercased()])
        var targets: Set<NativeProcessAudioIdentity> = []
        var resolvedTargetKeys: Set<String> = []
        for (pid, executable) in namedProcesses where pid > 0 {
            let key = executable.lowercased()
            if requirements.requiresGlobalMeter, requirements.runExemptionExecutableKeys.contains(key) {
                guard let identity = resolver.resolve(pid: pid, executable: executable),
                      identity.pid == pid, identity.executableKey == key else {
                    // A `run` exception must not accidentally be mixed into
                    // global audio while its identity is uncertain.
                    return .failure(.unmappedRunExemption(pid))
                }
                excluded.insert(identity)
            }
            guard configuredTargets.contains(key), pid != ownPID else { continue }
            guard let identity = resolver.resolve(pid: pid, executable: executable),
                  identity.pid == pid, identity.executableKey == key else {
                continue
            }
            targets.insert(identity)
            resolvedTargetKeys.insert(key)
        }
        return .success(.init(monitorsGlobal: requirements.requiresGlobalMeter,
                              globalExclusions: excluded,
                              configuredApplicationExecutableKeys: configuredTargets,
                              applicationTargets: targets,
                              unavailableApplicationExecutableKeys: configuredTargets.subtracting(resolvedTargetKeys)))
    }
}

protocol NativeProcessAudioIdentityResolving {
    func resolve(pid: pid_t, executable: String) -> NativeProcessAudioIdentity?
}

/// PID-to-Process Object resolution is metadata-only.  It neither creates a
/// tap nor requests Audio Capture access.  The object/PID read-back plus BSD
/// start time makes a cached PID unusable after process replacement.
@available(macOS 14.2, *)
struct NativeSystemProcessAudioIdentityResolver: NativeProcessAudioIdentityResolving {
    func resolve(pid: pid_t, executable: String) -> NativeProcessAudioIdentity? {
        guard pid > 0 else { return nil }
        // `namedProcesses` belongs to an earlier process snapshot.  Read the
        // live basename ourselves instead of treating that snapshot label as
        // identity proof: PIDs can be reused between those operations.
        guard let before = readLiveIdentity(pid), before.executableKey == executable.lowercased() else { return nil }
        var inputPID = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         UInt32(MemoryLayout<pid_t>.size), &inputPID,
                                         &size, &object) == noErr,
              size == MemoryLayout<AudioObjectID>.size,
              object != AudioObjectID(kAudioObjectUnknown),
              readPID(object) == pid,
              let after = readLiveIdentity(pid), after == before,
              // Re-read after metadata verification too: a disappearing or
              // recycled Process Object is never a rule/audio identity.
              readPID(object) == pid else { return nil }
        return .init(pid: pid, processObjectID: object, startToken: after.startToken, executable: after.executable)
    }

    private func readPID(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &raw) == noErr,
              size == MemoryLayout<UInt32>.size, raw > 0, raw <= UInt32(Int32.max) else { return nil }
        return pid_t(raw)
    }

    private struct LiveProcessIdentity: Equatable {
        let executable: String
        let executableKey: String
        let startToken: UInt64
    }

    private func readLiveIdentity(_ pid: pid_t) -> LiveProcessIdentity? {
        var path = [CChar](repeating: 0, count: 4_096)
        let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard count > 0, count < path.count, let end = path.firstIndex(of: 0), end > 0,
              let decoded = String(bytes: path[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8) else { return nil }
        var info = proc_bsdinfo()
        let bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard bytes == MemoryLayout<proc_bsdinfo>.size else { return nil }
        // Seconds/useconds is an OS supplied process instance discriminator,
        // not retained user activity data.  Saturate rather than overflow.
        guard info.pbi_start_tvsec <= UInt64.max / 1_000_000 else { return nil }
        let token = info.pbi_start_tvsec * 1_000_000 + min(info.pbi_start_tvusec, 999_999)
        let executable = (decoded as NSString).lastPathComponent
        guard !executable.isEmpty else { return nil }
        return .init(executable: executable, executableKey: executable.lowercased(), startToken: token)
    }
}

enum NativeProcessAudioCaptureKey: Hashable, Sendable {
    case global
    case application(NativeProcessAudioIdentity)
}

enum NativeProcessAudioCaptureMode: Sendable {
    case global(excluding: Set<NativeProcessAudioIdentity>)
    case application(NativeProcessAudioIdentity)
}

struct NativeProcessAudioCaptureConfiguration: Sendable {
    let key: NativeProcessAudioCaptureKey
    let mode: NativeProcessAudioCaptureMode
    let generation: UInt64
}

struct NativeProcessAudioCaptureHandle: Hashable, Sendable { fileprivate let id = UUID() }

/// An opaque proof that a snapshot came from one exact capture topology.  The
/// policy bridge can retain it beside its event and reject a later snapshot if
/// a run-exception/exclusion reconfiguration has replaced the meter.
struct NativeProcessAudioMeterEvidence: Hashable, Sendable {
    let topologyID: UUID
    let generation: UInt64
}

struct NativeProcessAudioPeakReport: Sendable {
    let key: NativeProcessAudioCaptureKey
    let generation: UInt64
    /// Increased by the actual IO callback, never by the timer itself.
    let callbackSequence: UInt64
    let peak: Float
    /// Monotonic timestamp at which the timer observed a new callback sequence.
    let observedAt: TimeInterval
}

protocol NativeProcessAudioMeterBackend: AnyObject {
    func start(configuration: NativeProcessAudioCaptureConfiguration,
               report: @escaping @Sendable (NativeProcessAudioPeakReport) -> Void) throws -> NativeProcessAudioCaptureHandle
    func stop(_ handle: NativeProcessAudioCaptureHandle)
}

struct NativeProcessAudioMeterSnapshot: Equatable, Sendable {
    let state: NativeProcessAudioMeterState
    /// `true` only after every required capture has supplied a real-IO callback
    /// within the deadline. The bridge must not infer freshness from an
    /// idle/starting service or from a timer tick.
    let isFresh: Bool
    /// Nil unless `isFresh` is true.  It changes on every capture rebuild.
    let evidence: NativeProcessAudioMeterEvidence?
    let globalAudible: Bool
    /// Existing application rules compare lowercased executable basenames.
    let audibleExecutables: Set<String>
    let generation: UInt64
    /// A prior *fresh* lease can naturally age its verified peak out after a
    /// teardown/rebuild.  These fields can never seed a new lease or refresh
    /// their deadline; bridge code authenticates `boundedHoldEvidence` against
    /// a previously accepted fresh lease before using them.
    let boundedHoldEvidence: NativeProcessAudioMeterEvidence?
    let boundedExistingGlobalHold: Bool
    let boundedExistingApplicationHolds: Set<String>
    let unavailableApplicationExecutableKeys: Set<String>
}

/// A serial-control service that is deliberately inert until the future UI
/// makes an explicit user request.  It has no singleton and no startup hook;
/// policy/UI ownership remains outside this unconnected adapter.
/// All mutable service state is confined to `queue`; the only cross-queue
/// input is an immutable scalar report, which is re-confined before mutation.
final class NativeProcessAudioMeterService: @unchecked Sendable {
    static let maximumApplicationCaptures = 16
    static let callbackDeadline: TimeInterval = 2
    static let globalHold: TimeInterval = 5
    static let applicationHold: TimeInterval = 3
    static let peakThreshold: Float = 0.001

    private struct ActiveCapture {
        let key: NativeProcessAudioCaptureKey
        let handle: NativeProcessAudioCaptureHandle
        var lastSequence: UInt64 = 0
        var lastCallbackAt: TimeInterval?
        let startedAt: TimeInterval
    }
    private struct VerifiedPeak: Sendable {
        let at: TimeInterval
        let evidence: NativeProcessAudioMeterEvidence
    }

    private let backend: NativeProcessAudioMeterBackend
    private let supported: Bool
    private let now: @Sendable () -> TimeInterval
    private let queue = DispatchQueue(label: "io.wallpaper-engine-native.process-audio.control")
    private var state: NativeProcessAudioMeterState
    private var generation: UInt64 = 0
    private var evidence: NativeProcessAudioMeterEvidence?
    private var plan: NativeProcessAudioMeterPlan?
    private var captures: [ActiveCapture] = []
    /// Runs only on `queue` for an explicitly active capture.  It observes
    /// callback ages but can never mint a callback sequence or restart a tap.
    private var deadlineTimer: DispatchSourceTimer?
    /// Current records belong to the active topology evidence.  Retained
    /// records come only from the immediately previous *fresh* topology and
    /// can only decay; both maps are always keyed by full process identity.
    private var currentGlobalPeak: VerifiedPeak?
    private var currentApplicationPeaks: [NativeProcessAudioIdentity: VerifiedPeak] = [:]
    private var boundedGlobalPeak: VerifiedPeak?
    private var boundedApplicationPeaks: [NativeProcessAudioIdentity: VerifiedPeak] = [:]
    private var currentLeaseWasFresh = false
    private var unavailableApplicationExecutableKeys: Set<String> = []

    init(backend: NativeProcessAudioMeterBackend, supported: Bool, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend; self.supported = supported; self.now = now
        state = supported ? .off : .unsupported
    }

    /// This is the only off/waiting/unavailable -> backend-start transition. A UI may
    /// call it after explaining Audio Capture permission; normal monitoring,
    /// app launch, and plan resolution must never call it.
    func startFromExplicitUserAction(_ requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>,
                                     completion: @escaping @Sendable (NativeProcessAudioMeterState) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.supported else { self.state = .unsupported; completion(self.state); return }
            switch self.state {
            case .off, .waitingForApplicationTargets, .unavailable:
                // A new explicit user action is a fresh authorization attempt,
                // not a continuation of an old session. It must never inherit
                // a retired peak/lease from a prior failure or waiting state.
                self.clearAllPeaksLocked()
                self.startLocked(requested)
            default: break
            }
            completion(self.state)
        }
    }

    /// Reconciliation may stage current metadata while inactive, but only an
    /// active, already user-authorized session can rebuild captures. In
    /// particular, a target that appears after a waiting plan never starts a
    /// tap until the user explicitly retries.
    func reconcileActivePlan(_ requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.state == .active else {
                self.stageInactivePlanLocked(requested)
                return
            }
            guard case .success(let next) = requested else {
                self.makeUnavailableLocked(requested.failureIssue, clearGlobal: self.requiresImmediateGlobalClear(requested.failureIssue)); return
            }
            guard next != self.plan else { return }
            let globalChanged = self.plan?.monitorsGlobal != next.monitorsGlobal ||
                self.plan?.globalExclusions != next.globalExclusions
            // A changed global mix must never borrow its old 5-second peak.
            // Per-app records are instead retired by full identity for at most
            // 3 seconds; a PID replacement cannot inherit them.
            self.promoteCurrentPeaksToBoundedLocked(now: self.now(), retainGlobal: !globalChanged)
            self.generation &+= 1
            self.stopCapturesLocked()
            self.startLocked(.success(next), generationAlreadyAdvanced: true,
                             retainRetiredApplicationHoldsWhenWaiting: true)
        }
    }

    func stop(completion: (@Sendable (NativeProcessAudioMeterState) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.state = .stopping
            self.generation &+= 1
            self.clearAllPeaksLocked()
            self.stopCapturesLocked()
            self.plan = nil; self.evidence = nil; self.unavailableApplicationExecutableKeys = []
            self.state = self.supported ? .off : .unsupported
            completion?(self.state)
        }
    }

    func snapshot(completion: @escaping @Sendable (NativeProcessAudioMeterSnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.checkDeadlineLocked(now: self.now())
            let instant = self.snapshotLocked(now: self.now())
            completion(instant)
        }
    }

    private func startLocked(_ requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>,
                             generationAlreadyAdvanced: Bool = false,
                             retainRetiredApplicationHoldsWhenWaiting: Bool = false) {
        guard case .success(let desired) = requested else { makeUnavailableLocked(requested.failureIssue, clearGlobal: requiresImmediateGlobalClear(requested.failureIssue)); return }
        guard desired.requiresCapture else {
            plan = desired; evidence = nil
            if retainRetiredApplicationHoldsWhenWaiting {
                // This is only the active-session transition caused by the
                // last attributed target disappearing. Its already-fresh
                // per-identity holds may finish their bounded 3-second decay,
                // while a global mix is never allowed to cross into waiting.
                clearCurrentPeaksLocked(); boundedGlobalPeak = nil
                prunePeaksLocked(now: now())
            } else {
                clearAllPeaksLocked()
            }
            unavailableApplicationExecutableKeys = desired.unavailableApplicationExecutableKeys
            state = desired.hasWaitingApplicationTargets ? .waitingForApplicationTargets : .off
            return
        }
        guard desired.applicationTargets.count <= Self.maximumApplicationCaptures else { makeUnavailableLocked(.resourceLimit, clearGlobal: false); return }
        state = .starting
        if !generationAlreadyAdvanced { generation &+= 1 }
        let currentGeneration = generation, started = now()
        var created: [ActiveCapture] = []
        var modes: [(NativeProcessAudioCaptureKey, NativeProcessAudioCaptureMode)] = []
        if desired.monitorsGlobal { modes.append((.global, .global(excluding: desired.globalExclusions))) }
        for target in desired.applicationTargets.sorted() {
            modes.append((NativeProcessAudioCaptureKey.application(target), NativeProcessAudioCaptureMode.application(target)))
        }
        do {
            for (key, mode) in modes {
                let config = NativeProcessAudioCaptureConfiguration(key: key, mode: mode, generation: currentGeneration)
                let handle = try backend.start(configuration: config) { [weak self] report in
                    self?.queue.async { [weak self] in self?.acceptLocked(report) }
                }
                created.append(.init(key: key, handle: handle, startedAt: started))
            }
        } catch {
            for capture in created.reversed() { backend.stop(capture.handle) }
            captures = []; plan = nil; evidence = nil; currentLeaseWasFresh = false
            state = .unavailable(.lifecycleFailure)
            return
        }
        captures = created; plan = desired; clearCurrentPeaksLocked()
        unavailableApplicationExecutableKeys = desired.unavailableApplicationExecutableKeys
        evidence = .init(topologyID: UUID(), generation: currentGeneration)
        state = .active; installDeadlineTimerLocked()
    }

    /// Inactive reconciliation is metadata-only. It deliberately cannot call
    /// the backend, so background process changes cannot create a tap, request
    /// Audio Capture, or silently retry after a previous failure.
    private func stageInactivePlanLocked(_ requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>) {
        switch requested {
        case .success(let desired):
            plan = desired
            unavailableApplicationExecutableKeys = desired.unavailableApplicationExecutableKeys
            guard state == .waitingForApplicationTargets else { return }
            // A target may have appeared, but explicit consent to start must
            // be renewed by the user rather than inferred from this update.
            if !desired.requiresCapture, !desired.hasWaitingApplicationTargets {
                state = .off
            }
        case .failure(let issue):
            plan = nil; unavailableApplicationExecutableKeys = []
            switch state {
            case .waitingForApplicationTargets, .unavailable:
                state = .unavailable(issue)
            default:
                break
            }
        }
    }

    private func acceptLocked(_ report: NativeProcessAudioPeakReport) {
        let receivedAt = now()
        guard state == .active, report.generation == generation,
              let index = captures.firstIndex(where: { $0.key == report.key }),
              report.callbackSequence > captures[index].lastSequence,
              report.observedAt.isFinite, receivedAt.isFinite,
              // The service owns the monotonic clock.  A backend report from a
              // future clock domain must not defer a deadline indefinitely.
              report.observedAt <= receivedAt else { return }
        captures[index].lastSequence = report.callbackSequence
        captures[index].lastCallbackAt = report.observedAt
        guard report.peak.isFinite, report.peak > Self.peakThreshold,
              let evidence, evidence.generation == generation else { return }
        switch report.key {
        case .global: currentGlobalPeak = .init(at: report.observedAt, evidence: evidence)
        case .application(let target): currentApplicationPeaks[target] = .init(at: report.observedAt, evidence: evidence)
        }
    }

    private func checkDeadlineLocked(now: TimeInterval) {
        guard state == .active, now.isFinite else { return }
        let expired = captures.contains { capture in
            let heartbeat = capture.lastCallbackAt ?? capture.startedAt
            return now - heartbeat > Self.callbackDeadline
        }
        if expired { makeUnavailableLocked(.deadlineExceeded, clearGlobal: false) }
    }

    private func snapshotLocked(now: TimeInterval) -> NativeProcessAudioMeterSnapshot {
        prunePeaksLocked(now: now)
        let bounded = boundedSnapshotLocked(now: now)
        guard state == .active, let evidence, evidence.generation == generation,
              allCapturesHaveFreshHeartbeatLocked(now: now) else {
            return .init(state: state, isFresh: false, evidence: nil, globalAudible: false, audibleExecutables: [], generation: generation,
                         boundedHoldEvidence: bounded.evidence, boundedExistingGlobalHold: bounded.global,
                         boundedExistingApplicationHolds: bounded.applications,
                         unavailableApplicationExecutableKeys: unavailableApplicationExecutableKeys)
        }
        currentLeaseWasFresh = true
        let global = currentGlobalPeak.map { within($0, hold: Self.globalHold, now: now) } ?? false
        let names = Set(currentApplicationPeaks.compactMap { identity, peak in
            within(peak, hold: Self.applicationHold, now: now) ? identity.executableKey : nil
        })
        return .init(state: state, isFresh: true, evidence: evidence, globalAudible: global, audibleExecutables: names, generation: generation,
                     boundedHoldEvidence: bounded.evidence, boundedExistingGlobalHold: bounded.global,
                     boundedExistingApplicationHolds: bounded.applications,
                     unavailableApplicationExecutableKeys: unavailableApplicationExecutableKeys)
    }

    private func makeUnavailableLocked(_ issue: NativeProcessAudioMeterIssue?, clearGlobal: Bool) {
        promoteCurrentPeaksToBoundedLocked(now: now(), retainGlobal: !clearGlobal)
        generation &+= 1
        stopCapturesLocked(); plan = nil; evidence = nil; currentLeaseWasFresh = false
        state = .unavailable(issue ?? .lifecycleFailure)
    }

    private func stopCapturesLocked() {
        deadlineTimer?.cancel(); deadlineTimer = nil
        for capture in captures.reversed() { backend.stop(capture.handle) }
        captures = []
    }

    private func allCapturesHaveFreshHeartbeatLocked(now: TimeInterval) -> Bool {
        guard now.isFinite, !captures.isEmpty else { return false }
        return captures.allSatisfy { capture in
            guard let heartbeat = capture.lastCallbackAt else { return false }
            return now >= heartbeat && now - heartbeat <= Self.callbackDeadline
        }
    }

    private func installDeadlineTimerLocked() {
        deadlineTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // This timer only consumes the time since an IO-derived heartbeat.
            // It never updates `lastCallbackAt`, produces a peak, or retries.
            self.checkDeadlineLocked(now: self.now())
        }
        timer.resume(); deadlineTimer = timer
    }

    private func clearCurrentPeaksLocked() {
        currentGlobalPeak = nil; currentApplicationPeaks = [:]; currentLeaseWasFresh = false
    }

    private func clearAllPeaksLocked() {
        clearCurrentPeaksLocked(); boundedGlobalPeak = nil; boundedApplicationPeaks = [:]
    }

    private func promoteCurrentPeaksToBoundedLocked(now: TimeInterval, retainGlobal: Bool) {
        prunePeaksLocked(now: now)
        guard currentLeaseWasFresh else { clearCurrentPeaksLocked(); return }
        // Only one previous accepted topology may supply bounded continuation.
        boundedGlobalPeak = retainGlobal ? currentGlobalPeak : nil
        boundedApplicationPeaks = currentApplicationPeaks
        clearCurrentPeaksLocked()
    }

    private func prunePeaksLocked(now: TimeInterval) {
        guard now.isFinite else { clearAllPeaksLocked(); return }
        if let currentGlobalPeak, !within(currentGlobalPeak, hold: Self.globalHold, now: now) { self.currentGlobalPeak = nil }
        currentApplicationPeaks = currentApplicationPeaks.filter { _, peak in within(peak, hold: Self.applicationHold, now: now) }
        if let boundedGlobalPeak, !within(boundedGlobalPeak, hold: Self.globalHold, now: now) { self.boundedGlobalPeak = nil }
        boundedApplicationPeaks = boundedApplicationPeaks.filter { _, peak in within(peak, hold: Self.applicationHold, now: now) }
    }

    private func boundedSnapshotLocked(now: TimeInterval) -> (evidence: NativeProcessAudioMeterEvidence?, global: Bool, applications: Set<String>) {
        let records = ([boundedGlobalPeak].compactMap { $0 } + Array(boundedApplicationPeaks.values))
        guard let evidence = records.first?.evidence,
              records.allSatisfy({ $0.evidence == evidence }) else { return (nil, false, []) }
        let global = boundedGlobalPeak.map { within($0, hold: Self.globalHold, now: now) } ?? false
        let applications = Set(boundedApplicationPeaks.compactMap { identity, peak in
            within(peak, hold: Self.applicationHold, now: now) ? identity.executableKey : nil
        })
        return global || !applications.isEmpty ? (evidence, global, applications) : (nil, false, [])
    }

    private func within(_ peak: VerifiedPeak, hold: TimeInterval, now: TimeInterval) -> Bool {
        now.isFinite && now >= peak.at && now - peak.at <= hold
    }

    private func requiresImmediateGlobalClear(_ issue: NativeProcessAudioMeterIssue?) -> Bool {
        switch issue {
        case .missingOwnProcessObject, .unmappedRunExemption: return true
        default: return false
        }
    }
}

private extension Result where Failure == NativeProcessAudioMeterIssue {
    var failureIssue: NativeProcessAudioMeterIssue? {
        if case .failure(let issue) = self { return issue }
        return nil
    }
}

// MARK: - CoreAudio implementation (never constructed automatically)

/// This mailbox is queue-confined: both `record` and `drain` execute only on
/// the dispatch queue supplied to AudioDeviceCreateIOProcIDWithBlock.  There is
/// no lock/atomic race between the IO block and the timer, and no shared PCM.
@available(macOS 14.2, *)
final class NativeProcessAudioRealtimeMailbox {
    private var acceptingGeneration: UInt64?
    private var sequence: UInt64 = 0
    private var lastReportedSequence: UInt64 = 0
    private var largestPeak: Float = 0

    init(generation: UInt64) { acceptingGeneration = generation }
    func accepts(_ generation: UInt64) -> Bool { acceptingGeneration == generation }
    func record(_ peak: Float, generation: UInt64) {
        guard accepts(generation) else { return }
        sequence &+= 1
        if peak.isFinite, peak > largestPeak { largestPeak = peak }
    }
    func drain(generation: UInt64, at now: TimeInterval, key: NativeProcessAudioCaptureKey) -> NativeProcessAudioPeakReport? {
        guard accepts(generation), sequence > lastReportedSequence, now.isFinite else { return nil }
        defer { largestPeak = 0; lastReportedSequence = sequence }
        return .init(key: key, generation: generation, callbackSequence: sequence, peak: largestPeak, observedAt: now)
    }
    func deactivate() { acceptingGeneration = nil; largestPeak = 0 }
}

/// The only two PCM arrangements accepted by the process meter.  Both use
/// native-endian Float32 samples with no frame padding.  The layout is derived
/// once while creating the tap; the IO callback does not inspect ASBD state or
/// make a format conversion.
@available(macOS 14.2, *)
struct NativeProcessAudioPCMLayout: Equatable {
    let channels: Int
    let isNonInterleaved: Bool

    static func make(format: AudioStreamBasicDescription) -> Self? {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mFormatFlags & kAudioFormatFlagIsAlignedHigh == 0,
              (1...2).contains(format.mChannelsPerFrame),
              format.mFramesPerPacket == 1,
              format.mSampleRate.isFinite,
              (8_000...384_000).contains(format.mSampleRate) else { return nil }

        let channels = Int(format.mChannelsPerFrame)
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let floatBytes = UInt32(MemoryLayout<Float>.size)
        if nonInterleaved {
            // In a planar ASBD each AudioBuffer contains exactly one channel,
            // so its frame/packet carries one Float32 rather than N channels.
            guard format.mBytesPerFrame == floatBytes,
                  format.mBytesPerPacket == floatBytes else { return nil }
        } else {
            guard format.mBytesPerFrame == UInt32(channels) * floatBytes,
                  format.mBytesPerPacket == format.mBytesPerFrame else { return nil }
        }
        return .init(channels: channels, isNonInterleaved: nonInterleaved)
    }
}

@available(macOS 14.2, *)
enum NativeProcessAudioPeakScanner {
    static let maximumFloatsPerCallback = 32_768

    /// Called only by the IO block.  It has no allocations, locks, bridging,
    /// Dispatch submission, logging, rule work or persistence; it returns one
    /// scalar max-absolute finite sample and discards the input immediately.
    /// A malformed `AudioBufferList` returns nil (no heartbeat and no peak),
    /// rather than interpreting padding or a partial channel as audio.
    static func maximum(in list: UnsafePointer<AudioBufferList>, layout: NativeProcessAudioPCMLayout) -> Float? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let bytesPerFloat = UInt32(MemoryLayout<Float>.size)
        var result: Float = 0

        if layout.isNonInterleaved {
            guard buffers.count == layout.channels else { return nil }
            var expectedFrames: Int?
            // Bound total inspected values, but retain channel symmetry: for a
            // two-channel planar stream, inspect the same leading frame count
            // from each channel.
            let maximumFrames = maximumFloatsPerCallback / layout.channels
            for index in 0..<layout.channels {
                let buffer = buffers[index]
                guard buffer.mNumberChannels == 1,
                      let data = buffer.mData,
                      buffer.mDataByteSize > 0,
                      buffer.mDataByteSize % bytesPerFloat == 0 else { return nil }
                let frames = Int(buffer.mDataByteSize / bytesPerFloat)
                guard frames > 0 else { return nil }
                if let expectedFrames, expectedFrames != frames { return nil }
                expectedFrames = frames
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<min(frames, maximumFrames) {
                    let sample = samples[frame]
                    if sample.isFinite { result = max(result, Swift.abs(sample)) }
                }
            }
            return result
        }

        guard buffers.count == 1 else { return nil }
        let buffer = buffers[0]
        let bytesPerFrame = UInt32(layout.channels) * bytesPerFloat
        guard buffer.mNumberChannels == UInt32(layout.channels),
              let data = buffer.mData,
              buffer.mDataByteSize > 0,
              buffer.mDataByteSize % bytesPerFrame == 0 else { return nil }
        let availableSamples = Int(buffer.mDataByteSize / bytesPerFloat)
        guard availableSamples > 0 else { return nil }
        let samples = data.assumingMemoryBound(to: Float.self)
        for index in 0..<min(availableSamples, maximumFloatsPerCallback) {
            let sample = samples[index]
            if sample.isFinite { result = max(result, Swift.abs(sample)) }
        }
        return result
    }
}

@available(macOS 14.2, *)
private final class NativeCoreAudioProcessTapResource {
    private var tap: AudioObjectID = 0
    private var aggregate: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let dataQueue: DispatchQueue
    private let mailbox: NativeProcessAudioRealtimeMailbox
    private var timer: DispatchSourceTimer?

    init(configuration: NativeProcessAudioCaptureConfiguration,
         report: @escaping @Sendable (NativeProcessAudioPeakReport) -> Void) throws {
        dataQueue = DispatchQueue(label: "io.wallpaper-engine-native.process-audio.data.\(UUID().uuidString)", qos: .userInitiated)
        mailbox = .init(generation: configuration.generation)
        do {
            let description: CATapDescription
            switch configuration.mode {
            case .global(let excluded):
                description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded.sorted().map(\.processObjectID))
            case .application(let target):
                description = CATapDescription(stereoMixdownOfProcesses: [target.processObjectID])
            }
            description.name = "Wallpaper Engine Native process audio meter"
            description.uuid = UUID()
            description.isPrivate = true
            // Sampling must never alter a user's audible output.
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap))
            let tapUID = try readTapUID(tap)
            let format = try readFormat(tap)
            guard let layout = NativeProcessAudioPCMLayout.make(format: format) else {
                throw NativeProcessAudioBackendError.invalidFormat
            }
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Wallpaper Engine Native Process Audio",
                kAudioAggregateDeviceUIDKey: "io.wallpaper-engine-native.process-audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    // Apple documents that the aggregate references the UID
                    // returned by the created Tap, not merely a requested
                    // description UUID.
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate))
            let mailbox = self.mailbox, generation = configuration.generation, key = configuration.key
            try check(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregate, dataQueue) { _, input, _, _, _ in
                // The two generation checks fence callbacks racing teardown;
                // deactivation occurs synchronously on this same data queue.
                guard mailbox.accepts(generation) else { return }
                guard let peak = NativeProcessAudioPeakScanner.maximum(in: input, layout: layout) else { return }
                guard mailbox.accepts(generation) else { return }
                mailbox.record(peak, generation: generation)
            })
            try check(AudioDeviceStart(aggregate, ioProc))
            let timer = DispatchSource.makeTimerSource(queue: dataQueue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(5))
            timer.setEventHandler {
                // A timer reports only when IO has advanced `sequence`; it
                // cannot synthesize a heartbeat during an IO callback outage.
                if let next = mailbox.drain(generation: generation, at: ProcessInfo.processInfo.systemUptime, key: key) { report(next) }
            }
            timer.resume(); self.timer = timer
        } catch {
            teardown(); throw error
        }
    }

    func teardown() {
        // Fence first on the callback queue; an in-flight callback finishes
        // before this returns and all subsequent callbacks observe inactive.
        dataQueue.sync { mailbox.deactivate() }
        timer?.cancel(); timer = nil
        if aggregate != 0, let ioProc { _ = AudioDeviceStop(aggregate, ioProc); _ = AudioDeviceDestroyIOProcID(aggregate, ioProc) }
        ioProc = nil
        if aggregate != 0 { _ = AudioHardwareDestroyAggregateDevice(aggregate); aggregate = 0 }
        if tap != 0 { _ = AudioHardwareDestroyProcessTap(tap); tap = 0 }
        // Drain queued block/timer work after destroying the IOProc.  This is
        // not executed from the data queue and cannot block the RT callback.
        dataQueue.sync { mailbox.deactivate() }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw NativeProcessAudioBackendError.status(status) }
    }

    private func readFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format))
        guard size == MemoryLayout<AudioStreamBasicDescription>.size else { throw NativeProcessAudioBackendError.invalidFormat }
        return format
    }

    private func readTapUID(_ tap: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, $0)
        }
        try check(status)
        guard size == MemoryLayout<CFString>.size, !String(uid).isEmpty else {
            throw NativeProcessAudioBackendError.invalidFormat
        }
        return String(uid)
    }

}

private enum NativeProcessAudioBackendError: Error { case status(OSStatus), invalidFormat, unsupported }

/// The only class that calls CoreAudio creation/destruction APIs.  Construction
/// itself is inert; no tap exists until the owning service receives explicit
/// user intent and invokes `start`.
@available(macOS 14.2, *)
final class NativeCoreAudioProcessMeterBackend: NativeProcessAudioMeterBackend {
    private var resources: [NativeProcessAudioCaptureHandle: NativeCoreAudioProcessTapResource] = [:]

    func start(configuration: NativeProcessAudioCaptureConfiguration,
               report: @escaping @Sendable (NativeProcessAudioPeakReport) -> Void) throws -> NativeProcessAudioCaptureHandle {
        let resource = try NativeCoreAudioProcessTapResource(configuration: configuration, report: report)
        let handle = NativeProcessAudioCaptureHandle(); resources[handle] = resource
        return handle
    }

    func stop(_ handle: NativeProcessAudioCaptureHandle) {
        let resource = resources.removeValue(forKey: handle)
        resource?.teardown()
    }

    deinit { for resource in resources.values { resource.teardown() } }
}

/// Creates a backend without creating a tap.  macOS 14.0/14.1 get an explicit
/// unsupported service and cannot reach the 14.2 Process Tap symbols.
enum NativeProcessAudioMeterFactory {
    static func makeService(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) -> NativeProcessAudioMeterService {
        if #available(macOS 14.2, *) {
            return .init(backend: NativeCoreAudioProcessMeterBackend(), supported: true, now: now)
        }
        return .init(backend: NativeUnsupportedProcessAudioMeterBackend(), supported: false, now: now)
    }
}

private final class NativeUnsupportedProcessAudioMeterBackend: NativeProcessAudioMeterBackend {
    func start(configuration: NativeProcessAudioCaptureConfiguration,
               report: @escaping @Sendable (NativeProcessAudioPeakReport) -> Void) throws -> NativeProcessAudioCaptureHandle {
        throw NativeProcessAudioBackendError.unsupported
    }
    func stop(_ handle: NativeProcessAudioCaptureHandle) {}
}


