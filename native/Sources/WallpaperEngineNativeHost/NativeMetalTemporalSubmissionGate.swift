import Foundation

/// Admits at most one frame that may read and then overwrite retained effect
/// history. Ordinary frames deliberately bypass this gate and continue to use
/// the view's three-command-buffer admission semaphore.
///
/// A scene revision is part of the token only to make a late completion
/// unambiguous. It is never a reason to release the active token: retirement
/// and resize can retain the same private history texture across revisions.
@MainActor
final class NativeMetalTemporalSubmissionGate {
    struct Token: Hashable {
        let renderer: ObjectIdentifier
        let revision: UInt64?
        let generation: UInt64
    }

    private var active: Token?
    private var nextGeneration: UInt64 = 0

    var hasActiveTemporalSubmission: Bool { active != nil }

    /// This preflight is deliberately nonmutating. The view calls it before
    /// acquiring a drawable or encoding; a missing drawable or thrown encoder
    /// must never leave an uncommitted token behind.
    func blocks(requiresSequentialSubmission: Bool) -> Bool {
        requiresSequentialSubmission && active != nil
    }

    /// Call only after `renderer.command(...)` succeeded and immediately
    /// before the nonthrowing `present`/`commit` pair. Main-actor execution
    /// makes the preflight-to-begin interval race-free.
    func begin(requiresSequentialSubmission: Bool, renderer: ObjectIdentifier, revision: UInt64?) -> Token? {
        guard requiresSequentialSubmission else { return nil }
        guard active == nil else { return nil }
        nextGeneration &+= 1
        let token = Token(renderer: renderer, revision: revision, generation: nextGeneration)
        active = token
        return token
    }

    /// Completion must call this only after the submission renderer has
    /// terminally finalized its retained-history tickets. Matching the full
    /// token makes duplicate or stale callbacks harmless and gives the view a
    /// one-shot signal for scheduling its coalesced redraw.
    @discardableResult
    func finish(_ token: Token) -> Bool {
        guard active == token else { return false }
        active = nil
        return true
    }
}
