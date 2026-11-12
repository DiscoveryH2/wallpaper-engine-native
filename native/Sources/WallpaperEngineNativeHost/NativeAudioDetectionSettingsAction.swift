import Foundation

/// A small, UI-independent description of what the audio-detection button may
/// do.  Configuration is never consent: `.requestConfirmation` still requires
/// the Settings sheet's affirmative response before its start closure runs.
enum NativeAudioDetectionSettingsAction: Equatable, Sendable {
    case disabled
    case explainNoObservationNeeded
    case requestConfirmation
    case stop

    static func resolve(state: NativeProcessAudioMeterState, configurable: Bool,
                        needsObservation: Bool) -> Self {
        switch state {
        case .active:
            return .stop
        case .starting, .stopping, .unsupported:
            return .disabled
        case .off, .waitingForApplicationTargets, .unavailable:
            guard configurable else { return .disabled }
            return needsObservation ? .requestConfirmation : .explainNoObservationNeeded
        }
    }

    /// The sole path from the confirmation sheet to a requested meter start.
    /// It deliberately owns no meter reference, so a cancelled sheet cannot
    /// cause a later asynchronous start.
    static func startIfConfirmed(_ confirmed: Bool, _ start: () -> Void) {
        guard confirmed else { return }
        start()
    }
}
