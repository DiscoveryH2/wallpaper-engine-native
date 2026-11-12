import Foundation

/// A deliberately narrow request for an explicit Steam-account write.  This
/// type is used by the host-side coordinator only; it does not talk to Steam,
/// retry work, or infer a changed subscription from a browse result.
///
/// Steam identifiers are canonicalized numerically.  The public browser keeps
/// a legal leading-zero spelling for share URLs, but accepting both `42` and
/// `00042` as separate queued account writes would defeat duplicate fencing.
struct WorkshopSubscriptionChangeRequest: Equatable {
    enum Operation: String, Equatable {
        case subscribe
        case unsubscribe

        init(subscribed: Bool) { self = subscribed ? .subscribe : .unsubscribe }

        var subscribed: Bool { self == .subscribe }
        var expectedCallback: String {
            switch self {
            case .subscribe: return "RemoteStorageSubscribePublishedFileResult_t"
            case .unsubscribe: return "RemoteStorageUnsubscribePublishedFileResult_t"
            }
        }
        var expectedCallbackID: Int {
            switch self {
            case .subscribe: return 1313
            case .unsubscribe: return 1315
            }
        }
    }

    let workshopID: String
    let operation: Operation

    init?(workshopID: String, subscribed: Bool) {
        // Keep this validation self-contained so the coordinator model can be
        // tested without reading a Steam library or launching an AppKit host.
        guard !workshopID.isEmpty, workshopID.utf8.count <= 20,
              workshopID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let rawID = UInt64(workshopID), rawID > 0 else { return nil }
        self.workshopID = String(rawID)
        self.operation = .init(subscribed: subscribed)
    }

    var desiredSubscribed: Bool { operation.subscribed }
    /// Bind the write helper to the account that supplied the user's complete
    /// pre-write snapshot. The helper validates this *before* making either
    /// SubscribeItem/UnsubscribeItem FFI call.
    func helperArguments(expectedAccount: WorkshopSubscriptionAccount) -> [String] {
        ["subscription-change", workshopID, operation.rawValue, "--expected-account", expectedAccount.id]
    }
}

/// The account envelope binds the UI's confirmed snapshot to both helper
/// processes.  SteamID64 is carried as a canonical decimal string so neither
/// a leading-zero alias nor an integer JSON conversion can make account A's
/// write appear to be confirmed by account B's later snapshot.
struct WorkshopSubscriptionAccount: Equatable {
    let id: String

    init?(_ text: String) {
        guard !text.isEmpty, text.utf8.count <= 20,
              text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let numeric = UInt64(text), numeric > 0 else { return nil }
        id = String(numeric)
    }
}

/// This is intentionally separate from the browser's presentation enum.
/// The coordinator maps it to `WorkshopSubscriptionChangeResult` after it
/// has completed the post-write subscription snapshot check.
enum WorkshopSubscriptionChangeResolution: Equatable {
    case confirmed
    case failed(String)
    case unconfirmed(String)
}

/// Strictly validates the small, owned `we-workshop subscription-change` JSON
/// protocol.  A process exit or an API-call handle is never treated as a
/// confirmation: only the expected completion callback can produce
/// `.confirmed`, and that still requires the coordinator's next full account
/// snapshot before the UI may change state.
enum WorkshopSubscriptionChangeProtocol {
    private static let maximumErrorLength = 700

    static func parse(_ object: [String: Any]?, processExitedSuccessfully: Bool,
                      request: WorkshopSubscriptionChangeRequest,
                      account: WorkshopSubscriptionAccount) -> WorkshopSubscriptionChangeResolution {
        guard let object else {
            return .unconfirmed("steam-subscription-helper-unconfirmed: Steam 未返回可验证结果；不会自动重试，请先同步订阅再决定是否重试。")
        }
        guard let outcome = object["outcome"] as? String else {
            return .unconfirmed("steam-subscription-protocol-unconfirmed: Steam 返回缺少 outcome；不会自动重试，请先同步订阅再决定是否重试。")
        }
        guard matchesRequestIdentity(object, request: request, expectedAccount: account) else {
            return .unconfirmed("steam-subscription-protocol-unconfirmed: Steam 返回的订阅请求身份不匹配；不会自动重试，请先同步订阅再决定是否重试。")
        }
        // A received B envelope for an A-bound request is never an ordinary
        // negative result: the coordinator must drop its A snapshot and force
        // the user to obtain a new one. In particular, the helper guarantees
        // this branch ran before any account-write FFI call.
        guard WorkshopSubscriptionAccount(object["account_id"] as? String ?? "") == account else {
            return .unconfirmed("steam-account-mismatch: Steam 账号在订阅请求期间变化；当前订阅状态已失效，请先同步订阅再决定是否重试。")
        }
        switch outcome {
        case "confirmed":
            guard processExitedSuccessfully,
                  exactBoolean(object["completion_confirmed"], equals: true),
                  exactBoolean(object["callback_received"], equals: true),
                  exactBoolean(object["session_validated_after_callback"], equals: true),
                  exactBoolean(object["mutation_started"], equals: true),
                  exactBoolean(object["subscribed"], equals: request.desiredSubscribed),
                  object["callback"] as? String == request.operation.expectedCallback,
                  exactInteger(object["callback_id"]) == request.operation.expectedCallbackID,
                  canonicalID(object["callback_workshop_id"] as? String) == request.workshopID,
                  exactInteger(object["callback_result"]) == 1,
                  exactBoolean(object["subscription_state_confirmed"], equals: false),
                  exactBoolean(object["download_ready"], equals: false) else {
                return .unconfirmed("steam-subscription-protocol-unconfirmed: Steam 写入回执不完整或不匹配；不会自动重试，请先同步订阅再决定是否重试。")
            }
            return .confirmed
        case "failed":
            // A helper failure is definite in exactly two cases:
            //   1. preflight failed before Steam returned a call handle; or
            //   2. Steam delivered this exact request's callback with a
            //      non-OK EResult while the same account was still valid.
            // `completion_confirmed` retains its existing semantic of a
            // successful write, so the latter needs the separate
            // `callback_received` proof. Any partial/contradictory envelope
            // stays unconfirmed and is never retried automatically.
            guard !processExitedSuccessfully,
                  exactBoolean(object["completion_confirmed"], equals: false),
                  let mutationStarted = exactBooleanValue(object["mutation_started"]),
                  let callbackReceived = exactBooleanValue(object["callback_received"]) else {
                return .unconfirmed("steam-subscription-protocol-unconfirmed: Steam 失败回执不完整；不会自动重试，请先同步订阅再决定是否重试。")
            }
            if !mutationStarted && !callbackReceived,
               exactBoolean(object["session_validated_after_callback"], equals: false),
               object["callback"] == nil, object["callback_id"] == nil,
               object["callback_workshop_id"] == nil, object["callback_result"] == nil,
               let failureCode = object["failure_code"] as? String,
               preflightFailureCodes.contains(failureCode) {
                return .failed(errorText(object, fallback: "steam-subscription-failed: Steam 拒绝了订阅状态请求。"))
            }
            guard mutationStarted, callbackReceived,
                  exactBoolean(object["session_validated_after_callback"], equals: true),
                  object["callback"] as? String == request.operation.expectedCallback,
                  exactInteger(object["callback_id"]) == request.operation.expectedCallbackID,
                  canonicalID(object["callback_workshop_id"] as? String) == request.workshopID,
                  let callbackResult = exactInteger(object["callback_result"]), callbackResult > 1,
                  object["failure_code"] as? String == "result-\(callbackResult)" else {
                return .unconfirmed("steam-subscription-protocol-unconfirmed: Steam 失败回执不完整；不会自动重试，请先同步订阅再决定是否重试。")
            }
            return .failed(errorText(object, fallback: "steam-subscription-failed: Steam 拒绝了订阅状态请求。"))
        case "unconfirmed":
            guard !processExitedSuccessfully, exactBoolean(object["completion_confirmed"], equals: false),
                  exactBooleanValue(object["mutation_started"]) != nil else {
                return .unconfirmed("steam-subscription-protocol-unconfirmed: Steam 未确认请求结果；不会自动重试，请先同步订阅再决定是否重试。")
            }
            return .unconfirmed(errorText(object, fallback: "steam-completion-unconfirmed: Steam 未确认请求最终结果；不会自动重试，请先同步订阅再决定是否重试。"))
        default:
            return .unconfirmed("steam-subscription-protocol-unconfirmed: Steam 返回未知 outcome；不会自动重试，请先同步订阅再决定是否重试。")
        }
    }

    /// A complete subscriptions snapshot supplies both sets: all subscribed
    /// IDs and the locally enabled subset.  A subscribe only converges when
    /// it appears in *both*; an unsubscribe only converges when absent from
    /// all IDs.  This does not claim download or renderer readiness.
    static func snapshotConverged(allSubscriptionIDs: Set<String>, enabledSubscriptionIDs: Set<String>,
                                  accountID: String?, expectedAccount: WorkshopSubscriptionAccount,
                                  request: WorkshopSubscriptionChangeRequest) -> Bool {
        guard enabledSubscriptionIDs.isSubset(of: allSubscriptionIDs) else { return false }
        guard WorkshopSubscriptionAccount(accountID ?? "") == expectedAccount else { return false }
        if request.desiredSubscribed {
            return allSubscriptionIDs.contains(request.workshopID) && enabledSubscriptionIDs.contains(request.workshopID)
        }
        return !allSubscriptionIDs.contains(request.workshopID)
    }

    private static func matchesRequestIdentity(_ object: [String: Any], request: WorkshopSubscriptionChangeRequest,
                                               expectedAccount: WorkshopSubscriptionAccount) -> Bool {
        object["status"] as? String == "subscription-change"
            && object["source"] as? String == "official_steam_api"
            && exactInteger(object["appid"]) == 431960
            && canonicalID(object["workshop_id"] as? String) == request.workshopID
            && object["operation"] as? String == request.operation.rawValue
            && WorkshopSubscriptionAccount(object["expected_account_id"] as? String ?? "") == expectedAccount
    }

    private static func canonicalID(_ text: String?) -> String? {
        guard let text else { return nil }
        return WorkshopSubscriptionChangeRequest(workshopID: text, subscribed: true)?.workshopID
    }

    /// These are the helper paths that are explicitly known to have no
    /// successful asynchronous account-write result. `completion-unconfirmed`
    /// and `account-changed` are intentionally absent: either can leave the
    /// caller's account state unsafe even where no FFI write was attempted.
    private static let preflightFailureCodes: Set<String> = [
        "invalid-item", "invalid-account", "request-rejected", "offline",
        "license-unconfirmed", "client-not-running", "api-unavailable"
    ]

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded(.towardZero) == raw,
              let integer = Int(exactly: raw) else { return nil }
        return integer
    }

    /// `NSNumber(1)` bridges to `Bool` in a conditional cast on Apple
    /// platforms.  Protocol booleans must be CFBoolean specifically: treating
    /// JSON 0/1 as completion proof would allow malformed helper output to
    /// cross an account-write confirmation boundary.
    private static func exactBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        exactBooleanValue(value) == expected
    }

    private static func exactBooleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func errorText(_ object: [String: Any], fallback: String) -> String {
        guard let raw = object["error"] as? String else { return fallback }
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).prefix(maximumErrorLength)).replacingOccurrences(of: #"\b7656\d{13}\b"#, with: "<redacted-steam-id>", options: .regularExpression)
        guard !visible.isEmpty else { return fallback }
        return visible.hasPrefix("steam-") ? visible : "steam-subscription-error: " + visible
    }
}

/// Serializes explicit account mutations separately from downloads.  It is
/// MainActor-confined to match `WorkshopCoordinator`; clearing the completion
/// slot before invoking it makes a second helper callback, session-loss path,
/// or shutdown path inert.  The queue deliberately contains no retry logic.
@MainActor
final class WorkshopSubscriptionChangeQueue {
    struct Work: Equatable {
        let token: UUID
        let request: WorkshopSubscriptionChangeRequest
        let account: WorkshopSubscriptionAccount
        let connectionEpoch: UInt64
        /// The complete pre-write snapshot's authorization generation. A
        /// 3418 frame invalidates this before any old snapshot may be reused
        /// to start or confirm the explicit mutation.
        let authorizationGeneration: UInt64
    }

    enum EnqueueResult: Equatable {
        case enqueued(UUID)
        case duplicate(workshopID: String)
    }

    typealias Completion = (WorkshopSubscriptionChangeResolution) -> Void

    private var pending: [Work] = []
    private(set) var active: Work?
    private var reservedIDs = Set<String>()
    private var completions: [UUID: Completion] = [:]

    var isEmpty: Bool { active == nil && pending.isEmpty }
    var pendingCount: Int { pending.count }
    func contains(workshopID: String) -> Bool {
        WorkshopSubscriptionChangeRequest(workshopID: workshopID, subscribed: true).map { reservedIDs.contains($0.workshopID) } ?? false
    }

    @discardableResult
    func enqueue(_ request: WorkshopSubscriptionChangeRequest, account: WorkshopSubscriptionAccount,
                 connectionEpoch: UInt64, authorizationGeneration: UInt64,
                 completion: @escaping Completion) -> EnqueueResult {
        guard reservedIDs.insert(request.workshopID).inserted else { return .duplicate(workshopID: request.workshopID) }
        let work = Work(token: UUID(), request: request, account: account, connectionEpoch: connectionEpoch,
                        authorizationGeneration: authorizationGeneration)
        pending.append(work)
        completions[work.token] = completion
        return .enqueued(work.token)
    }

    /// The coordinator calls this only when its single helper slot is idle.
    func beginNext() -> Work? {
        guard active == nil, !pending.isEmpty else { return nil }
        let work = pending.removeFirst()
        active = work
        return work
    }

    /// Resolving a non-active or already-resolved token is deliberately a
    /// no-op.  That is how stale helper process results and duplicate callback
    /// delivery are made harmless without scheduling a retry.
    func finish(_ token: UUID, with resolution: WorkshopSubscriptionChangeResolution) {
        guard active?.token == token, let completion = completions.removeValue(forKey: token) else { return }
        let work = active!
        active = nil
        reservedIDs.remove(work.request.workshopID)
        completion(resolution)
    }

    /// Session loss and application shutdown must settle every visible UI
    /// request exactly once.  The active helper may later finish, but its
    /// token no longer has a completion slot and is ignored by `finish`.
    func cancelAll(with resolution: WorkshopSubscriptionChangeResolution) {
        var callbacks: [Completion] = []
        if let active, let completion = completions.removeValue(forKey: active.token) { callbacks.append(completion) }
        for work in pending {
            if let completion = completions.removeValue(forKey: work.token) { callbacks.append(completion) }
        }
        active = nil
        pending.removeAll()
        reservedIDs.removeAll()
        callbacks.forEach { $0(resolution) }
    }
}
