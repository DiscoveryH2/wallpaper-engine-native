import Foundation

/// A temporary rule selection owns one original desktop snapshot, even when
/// another matching rule replaces it. The host must prepare a candidate first,
/// then commit this token at the same non-suspending boundary as the desktop.
struct NativeApplicationSelection<Snapshot> {
    typealias Selection = NativeApplicationRuleEffects.Selection
    struct Request {
        let id = UUID()
        let selection: Selection?
        let original: Snapshot
        var restoring: Bool { selection == nil }
    }
    struct Transition {
        var cancelled: UUID?
        var request: Request?
    }
    private enum Attempt: Equatable { case load(Selection), restore }
    private(set) var observed: Selection?
    private(set) var current: Selection?
    private(set) var original: Snapshot?
    private(set) var pending: Request?
    private var suppressed: Selection?
    private var failed: Attempt?

    var ownsTemporarySelection: Bool { original != nil }

    /// When a manual load, modal transaction or termination prevents a commit,
    /// keep the latest observation and invalidate an obsolete in-flight request.
    /// A subsequent call with canBegin=true starts the latest desired change.
    mutating func observe(_ selection: Selection?, snapshot: Snapshot?, canBegin: Bool = true) -> Transition {
        var result = Transition()
        if observed != selection {
            observed = selection; suppressed = nil; failed = nil
            result.cancelled = pending?.id; pending = nil
        }
        if !canBegin {
            result.cancelled = result.cancelled ?? pending?.id; pending = nil
            return result
        }
        if let suppressed, suppressed == observed { return result }
        guard pending == nil else { return result }
        guard current != observed else {
            if current == nil { original = nil }
            return result
        }
        let attempt = observed.map(Attempt.load) ?? .restore
        guard canBegin, failed != attempt else { return result }
        if original == nil { original = snapshot }
        guard let original else { return result }
        let request = Request(selection: observed, original: original)
        pending = request; result.request = request
        return result
    }

    func canCommit(_ request: Request) -> Bool {
        pending?.id == request.id && observed == request.selection &&
            (suppressed == nil || suppressed != observed)
    }
    @discardableResult
    mutating func commit(_ request: Request) -> Bool {
        guard canCommit(request) else { return false }
        current = request.selection; pending = nil; failed = nil
        if current == nil { original = nil }
        return true
    }
    /// The old presentation remains live. A failed target is attempted again
    /// only after an explicit retry or a changed condition, not every poll.
    @discardableResult
    mutating func fail(_ request: Request) -> Bool {
        guard canCommit(request) else { return false }
        pending = nil; failed = request.selection.map(Attempt.load) ?? .restore
        if current == nil { original = nil }
        return true
    }
    mutating func retry() { failed = nil }
    /// An installed version of the same target changed. Preserve ownership and
    /// the original desktop even if preparing that updated version fails.
    mutating func refreshCurrent() -> Request? {
        guard pending == nil, let current, current == observed, let original,
              suppressed != current else { return nil }
        let request = Request(selection: current, original: original)
        pending = request; failed = nil; return request
    }
    @discardableResult
    mutating func updateOriginal(_ change: (inout Snapshot) -> Void) -> UUID? {
        guard var value = original else { return nil }; change(&value); original = value
        let cancelled = pending?.id; pending = nil
        return cancelled
    }
    /// Explicit user selection takes ownership. The same still-matching rule
    /// must not immediately overwrite it; a changed observation rearms rules.
    @discardableResult
    mutating func interruptedByUser() -> UUID? {
        let cancelled = pending?.id
        pending = nil; original = nil; current = nil; failed = nil; suppressed = observed
        return cancelled
    }
    @discardableResult
    mutating func reset() -> UUID? {
        let cancelled = pending?.id; self = Self(); return cancelled
    }
}
