import Foundation

/// Turns persisted rule intent into an inert meter plan.  It is deliberately
/// policy-only: resolving or storing this value neither creates a tap nor
/// requests permission.  A `run` audio rule is an exclusion only when the
/// global audio action actually needs a global meter; by itself it cannot
/// justify observing unrelated applications.
struct NativeProcessAudioPolicyRequirements: Sendable {
    let needsObservation: Bool
    let meterRequirements: NativeProcessAudioMeterRequirements

    init(globalAction: NativePlaybackAction, rules: [NativeApplicationRule]) {
        // The archive can be user-edited or originate from an older build. Do
        // not let an unsupported audio `pauseall`/`stop` value create a meter
        // demand or acquire a broader policy effect than the official UI.
        let audioRules = rules.filter {
            $0.condition == .playingaudio && NativeApplicationAction.options(for: .playingaudio, multimonitor: true).contains($0.action)
        }
        let requiresGlobal = globalAction != .run
        let exemptions = requiresGlobal
            ? Set(audioRules.filter { $0.action == .run }.map(\.executableKey)) : []
        // Selection rules are deliberately included: a load action still
        // needs a genuinely audible, attributed process event to take effect.
        let attributed = Set(audioRules.filter { $0.action != .run }.map(\.executableKey))
        meterRequirements = .init(requiresGlobalMeter: requiresGlobal,
                                  runExemptionExecutableKeys: exemptions,
                                  applicationMeterExecutableKeys: attributed)
        needsObservation = requiresGlobal || !attributed.isEmpty
    }
}

struct NativeProcessAudioPolicyReading: Equatable, Sendable {
    static let empty = Self(globalAudible: false, applicationEvents: [])
    let globalAudible: Bool
    let applicationEvents: [NativeApplicationConditionEvent]
}

/// Separates a policy/topology invalidation from ordinary snapshot polling.
/// The monitor uses this to reject a late completion after stop, rule/settings
/// edits or a newer poll without coupling audio ordering to activityEpoch.
struct NativeProcessAudioPolicyRequestGate: Equatable, Sendable {
    struct Token: Equatable, Sendable {
        let epoch: UInt64
        let request: UInt64
    }

    private(set) var epoch: UInt64 = 0
    private(set) var request: UInt64 = 0

    mutating func invalidate() { epoch &+= 1; request &+= 1 }
    mutating func beginSnapshot() -> Token { request &+= 1; return .init(epoch: epoch, request: request) }
    func accepts(_ token: Token) -> Bool { token.epoch == epoch && token.request == request }
}

/// Avoids arming a replacement-topology fence when a newly sampled process
/// inventory resolves to exactly the plan already supplied to the meter.  The
/// meter intentionally no-ops in that case and therefore cannot advance its
/// generation; treating it as a rebuild would permanently reject the current
/// fresh lease.
struct NativeProcessAudioPolicyPlanTracker: Sendable {
    private var lastSubmitted: NativeProcessAudioMeterPlan?

    func needsSafeReconciliation(for requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>) -> Bool {
        guard case .success(let plan) = requested else { return true }
        return plan != lastSubmitted
    }

    mutating func record(_ requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>) {
        if case .success(let plan) = requested { lastSubmitted = plan }
        else { lastSubmitted = nil }
    }

    mutating func clear() { lastSubmitted = nil }
}

/// Accepts only a fresh, scalar meter snapshot that belongs to this bridge's
/// current topology lease.  It has no CoreAudio references and cannot start,
/// stop, or retry a meter.  The monitor also applies a separate request gate
/// so a callback issued before a rule edit/stop is discarded.
struct NativeProcessAudioPolicyBridge: Sendable {
    private var minimumGeneration: UInt64 = 0
    private var acceptedEvidence: NativeApplicationAudioEvidence?
    /// A safe process topology rebuild may naturally finish an already
    /// verified per-identity hold.  It is never populated for a rule edit,
    /// explicit stop or audio-action change.
    private var retiredTopologyEvidence: NativeApplicationAudioEvidence?
    private var awaitingReplacementTopology = false

    /// Revoke every lease when user intent changes or detection stops.  A
    /// bounded meter field must not survive a removed rule/permission intent.
    mutating func invalidateAllLeases() {
        if let acceptedEvidence {
            minimumGeneration = max(minimumGeneration,
                                    acceptedEvidence.generation == .max ? .max : acceptedEvidence.generation + 1)
        }
        acceptedEvidence = nil; retiredTopologyEvidence = nil; awaitingReplacementTopology = false
    }

    /// Called only when a new process inventory changes an already active
    /// meter plan.  Fresh old-topology reports are fenced; its separately
    /// emitted, meter-verified bounded app hold remains eligible for at most
    /// the meter's own 3-second lifetime.
    mutating func beginSafeTopologyReconciliation() {
        retiredTopologyEvidence = acceptedEvidence
        awaitingReplacementTopology = acceptedEvidence != nil
    }

    mutating func consume(_ snapshot: NativeProcessAudioMeterSnapshot) -> NativeProcessAudioPolicyReading {
        guard snapshot.state == .active, snapshot.isFresh,
              let meterEvidence = snapshot.evidence,
              meterEvidence.generation == snapshot.generation,
              meterEvidence.generation >= minimumGeneration else {
            return boundedReading(snapshot)
        }
        let evidence = NativeApplicationAudioEvidence(topologyID: meterEvidence.topologyID,
                                                       generation: meterEvidence.generation, isFresh: true)
        if awaitingReplacementTopology, let acceptedEvidence {
            // A late report from the stopped mix cannot reassert global audio;
            // the replacement service generation must advance before fresh
            // data becomes policy-visible.
            guard evidence.generation > acceptedEvidence.generation else { return boundedReading(snapshot) }
            retiredTopologyEvidence = acceptedEvidence; awaitingReplacementTopology = false
        } else if let acceptedEvidence, acceptedEvidence != evidence {
            // A topology change without monitor coordination is fail-closed.
            return .empty
        }
        acceptedEvidence = evidence
        return merging(reading(global: snapshot.globalAudible, executables: snapshot.audibleExecutables, evidence: evidence),
                       boundedReading(snapshot))
    }

    /// A failure/rebuild is not fresh audio.  It may only naturally finish a
    /// peak that this bridge had already accepted from the same lease.  Thus a
    /// bounded field cannot bootstrap a pause, cross a rule/topology change,
    /// or rearm an expired meter; the meter itself owns 3/5-second expiry.
    private func boundedReading(_ snapshot: NativeProcessAudioMeterSnapshot) -> NativeProcessAudioPolicyReading {
        guard let bounded = snapshot.boundedHoldEvidence,
              bounded.generation >= minimumGeneration,
              matchesAcceptedLease(bounded) else { return .empty }
        let evidence = NativeApplicationAudioEvidence(topologyID: bounded.topologyID,
                                                       generation: bounded.generation, isFresh: false)
        return reading(global: snapshot.boundedExistingGlobalHold,
                       executables: snapshot.boundedExistingApplicationHolds, evidence: evidence)
    }

    private func reading(global: Bool, executables: Set<String>, evidence: NativeApplicationAudioEvidence) -> NativeProcessAudioPolicyReading {
        let events: [NativeApplicationConditionEvent] = executables.map { $0.lowercased() }.filter { !$0.isEmpty }.sorted()
            .map { .init(executable: $0, condition: .playingaudio, display: nil, audioEvidence: evidence) }
        return .init(globalAudible: global, applicationEvents: events)
    }

    private func matchesAcceptedLease(_ evidence: NativeProcessAudioMeterEvidence) -> Bool {
        [acceptedEvidence, retiredTopologyEvidence].compactMap { $0 }.contains {
            $0.topologyID == evidence.topologyID && $0.generation == evidence.generation
        }
    }

    private func merging(_ fresh: NativeProcessAudioPolicyReading, _ bounded: NativeProcessAudioPolicyReading) -> NativeProcessAudioPolicyReading {
        guard bounded != .empty else { return fresh }
        let current = Set(fresh.applicationEvents.map(\.executable))
        return .init(globalAudible: fresh.globalAudible || bounded.globalAudible,
                     applicationEvents: fresh.applicationEvents + bounded.applicationEvents.filter { !current.contains($0.executable) })
    }
}

/// Read-only, active-session operations shared by the policy monitor and a
/// fake scalar source.  Neither operation can move an off/unavailable meter
/// into capture.
protocol NativeProcessAudioMeterReading: AnyObject {
    func reconcileActivePlan(_ requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>)
    func snapshot(completion: @escaping @Sendable (NativeProcessAudioMeterSnapshot) -> Void)
}

extension NativeProcessAudioMeterService: NativeProcessAudioMeterReading {}

/// The monitor needs this separate capability only for two user-visible
/// lifecycle edges: an explicitly confirmed start and an explicit/shutdown
/// stop.  Keeping it narrower than the meter backend lets integration tests
/// inject a controller that records intent without constructing a Process Tap,
/// requesting permission, or reading PCM.
protocol NativeProcessAudioMeterControlling: NativeProcessAudioMeterReading {
    func startFromExplicitUserAction(_ requested: Result<NativeProcessAudioMeterPlan, NativeProcessAudioMeterIssue>,
                                     completion: @escaping @Sendable (NativeProcessAudioMeterState) -> Void)
    func stop(completion: (@Sendable (NativeProcessAudioMeterState) -> Void)?)
}

extension NativeProcessAudioMeterService: NativeProcessAudioMeterControlling {}

