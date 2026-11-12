import Foundation

/// An explicit, user-initiated Steam Workshop favorite mutation.  It is kept
/// separate from browse metadata: a card's favorite flag is not a safe source
/// of account authority, nor is a successful asynchronous Steam callback a
/// complete favorites snapshot.
struct WorkshopFavoriteChangeRequest: Equatable {
    enum Operation: String, Equatable {
        case add
        case remove

        init(favorited: Bool) { self = favorited ? .add : .remove }

        var favorited: Bool { self == .add }
    }

    let workshopID: String
    let operation: Operation

    init?(workshopID: String, favorited: Bool) {
        guard !workshopID.isEmpty, workshopID.utf8.count <= 20,
              workshopID.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let numeric = UInt64(workshopID), numeric > 0 else { return nil }
        self.workshopID = String(numeric)
        operation = .init(favorited: favorited)
    }

    var desiredFavorited: Bool { operation.favorited }
    func helperArguments(expectedAccount: WorkshopSubscriptionAccount) -> [String] {
        ["favorite-change", workshopID, operation.rawValue, "--expected-account", expectedAccount.id]
    }
}

/// The UI completion type deliberately has no optimistic state.  The
/// coordinator only emits `.confirmed` after an exact 3407 callback and a
/// new, non-cached full favorite list from the same Steam account.
enum WorkshopFavoriteChangeResult {
    case confirmed
    case failed(String)
    case unconfirmed(String)
}

enum WorkshopFavoriteChangeResolution: Equatable {
    case confirmed
    case failed(String)
    case unconfirmed(String)
}

/// Validates the small owned `favorite-change` helper protocol.  Any
/// malformed, stale, mismatched, timeout-shaped, or account-switched result
/// is deliberately unconfirmed: it is never retried automatically.
enum WorkshopFavoriteChangeProtocol {
    private static let maximumErrorLength = 700

    static func parse(_ object: [String: Any]?, processExitedSuccessfully: Bool,
                      request: WorkshopFavoriteChangeRequest,
                      account: WorkshopSubscriptionAccount) -> WorkshopFavoriteChangeResolution {
        guard let object else {
            return .unconfirmed("steam-favorite-helper-unconfirmed: Steam 未返回可验证结果；不会自动重试，请先同步订阅再决定是否重试。")
        }
        guard let outcome = object["outcome"] as? String else {
            return .unconfirmed("steam-favorite-protocol-unconfirmed: Steam 返回缺少 outcome；不会自动重试，请先同步订阅再决定是否重试。")
        }
        guard matchesRequestIdentity(object, request: request, expectedAccount: account) else {
            return .unconfirmed("steam-favorite-protocol-unconfirmed: Steam 返回的收藏请求身份不匹配；不会自动重试，请先同步订阅再决定是否重试。")
        }
        guard WorkshopSubscriptionAccount(object["account_id"] as? String ?? "") == account else {
            return .unconfirmed("steam-account-mismatch: Steam 账号在收藏请求期间变化；当前收藏状态已失效，请先同步订阅再决定是否重试。")
        }
        switch outcome {
        case "confirmed":
            guard processExitedSuccessfully,
                  exactBoolean(object["completion_confirmed"], equals: true),
                  exactBoolean(object["callback_received"], equals: true),
                  exactBoolean(object["session_validated_after_callback"], equals: true),
                  exactBoolean(object["mutation_started"], equals: true),
                  exactBoolean(object["favorite_state_confirmed"], equals: false),
                  object["callback"] as? String == "UserFavoriteItemsListChanged_t",
                  exactInteger(object["callback_id"]) == 3407,
                  canonicalID(object["callback_workshop_id"] as? String) == request.workshopID,
                  exactInteger(object["callback_result"]) == 1,
                  exactBoolean(object["callback_was_add_request"], equals: request.desiredFavorited) else {
                return .unconfirmed("steam-favorite-protocol-unconfirmed: Steam 收藏写入回执不完整或不匹配；不会自动重试，请先同步订阅再决定是否重试。")
            }
            return .confirmed
        case "failed":
            guard !processExitedSuccessfully,
                  exactBoolean(object["completion_confirmed"], equals: false),
                  let mutationStarted = exactBooleanValue(object["mutation_started"]),
                  let callbackReceived = exactBooleanValue(object["callback_received"]) else {
                return .unconfirmed("steam-favorite-protocol-unconfirmed: Steam 收藏失败回执不完整；不会自动重试，请先同步订阅再决定是否重试。")
            }
            if !mutationStarted && !callbackReceived,
               exactBoolean(object["session_validated_after_callback"], equals: false),
               object["callback"] == nil, object["callback_id"] == nil,
               object["callback_workshop_id"] == nil, object["callback_result"] == nil,
               object["callback_was_add_request"] == nil,
               let failureCode = object["failure_code"] as? String,
               preflightFailureCodes.contains(failureCode) {
                return .failed(errorText(object, fallback: "steam-favorite-failed: Steam 拒绝了收藏状态请求。"))
            }
            guard mutationStarted, callbackReceived,
                  exactBoolean(object["session_validated_after_callback"], equals: true),
                  object["callback"] as? String == "UserFavoriteItemsListChanged_t",
                  exactInteger(object["callback_id"]) == 3407,
                  canonicalID(object["callback_workshop_id"] as? String) == request.workshopID,
                  let callbackResult = exactInteger(object["callback_result"]), callbackResult > 1,
                  exactBoolean(object["callback_was_add_request"], equals: request.desiredFavorited),
                  object["failure_code"] as? String == "result-\(callbackResult)" else {
                return .unconfirmed("steam-favorite-protocol-unconfirmed: Steam 收藏失败回执不完整；不会自动重试，请先同步订阅再决定是否重试。")
            }
            return .failed(errorText(object, fallback: "steam-favorite-failed: Steam 拒绝了收藏状态请求。"))
        case "unconfirmed":
            guard !processExitedSuccessfully,
                  exactBoolean(object["completion_confirmed"], equals: false),
                  exactBooleanValue(object["mutation_started"]) != nil else {
                return .unconfirmed("steam-favorite-protocol-unconfirmed: Steam 未确认收藏请求结果；不会自动重试，请先同步订阅再决定是否重试。")
            }
            return .unconfirmed(errorText(object, fallback: "steam-completion-unconfirmed: Steam 未确认收藏请求最终结果；不会自动重试，请先同步订阅再决定是否重试。"))
        default:
            return .unconfirmed("steam-favorite-protocol-unconfirmed: Steam 返回未知 outcome；不会自动重试，请先同步订阅再决定是否重试。")
        }
    }

    /// A favorite has converged only when a fresh, complete list from the
    /// same expected account has the exact desired membership.  Cached lists
    /// are intentionally excluded even if their membership happens to match.
    static func snapshotConverged(favoriteIDs: Set<String>?, accountID: String?,
                                  expectedAccount: WorkshopSubscriptionAccount,
                                  request: WorkshopFavoriteChangeRequest) -> Bool {
        guard WorkshopSubscriptionAccount(accountID ?? "") == expectedAccount,
              let favoriteIDs else { return false }
        return favoriteIDs.contains(request.workshopID) == request.desiredFavorited
    }

    private static func matchesRequestIdentity(_ object: [String: Any], request: WorkshopFavoriteChangeRequest,
                                               expectedAccount: WorkshopSubscriptionAccount) -> Bool {
        object["status"] as? String == "favorite-change"
            && object["source"] as? String == "official_steam_api"
            && exactInteger(object["appid"]) == 431960
            && canonicalID(object["workshop_id"] as? String) == request.workshopID
            && object["operation"] as? String == request.operation.rawValue
            && WorkshopSubscriptionAccount(object["expected_account_id"] as? String ?? "") == expectedAccount
    }

    private static func canonicalID(_ text: String?) -> String? {
        guard let text else { return nil }
        return WorkshopFavoriteChangeRequest(workshopID: text, favorited: true)?.workshopID
    }

    private static let preflightFailureCodes: Set<String> = [
        "invalid-item", "invalid-account", "request-rejected", "offline",
        "license-unconfirmed", "client-not-running", "api-unavailable"
    ]

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded(.towardZero) == raw,
              let value = Int(exactly: raw) else { return nil }
        return value
    }

    private static func exactBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        exactBooleanValue(value) == expected
    }

    private static func exactBooleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func errorText(_ object: [String: Any], fallback: String) -> String {
        guard let raw = object["error"] as? String else { return fallback }
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).prefix(maximumErrorLength)).replacingOccurrences(of: #"\b7656\d{13}\b"#, with: "<redacted-steam-id>", options: .regularExpression)
        guard !visible.isEmpty else { return fallback }
        return visible.hasPrefix("steam-") ? visible : "steam-favorite-error: " + visible
    }
}

/// One serial fence for every explicit Steam-account mutation. Subscription,
/// favorite, and personal-vote writes cannot interleave callbacks and their
/// respective post-write confirmation reads. The per-item reservation is
/// shared across mutation kinds, so an alias or cross-kind request cannot
/// race the same Workshop ID.
@MainActor
final class WorkshopAccountMutationQueue {
    enum Request: Equatable {
        case subscription(WorkshopSubscriptionChangeRequest)
        case favorite(WorkshopFavoriteChangeRequest)
        case userVote(WorkshopUserVoteChangeRequest)

        var workshopID: String {
            switch self {
            case .subscription(let request): return request.workshopID
            case .favorite(let request): return request.workshopID
            case .userVote(let request): return request.workshopID
            }
        }
    }

    enum Resolution: Equatable {
        case confirmed
        /// Only emitted by a personal-vote work item after both its exact
        /// SetUserItemVote receipt and fresh same-account GetUserItemVote
        /// confirmation have completed under this queue's active fence.
        case confirmedUserVote(WorkshopUserVoteReceipt)
        case failed(String)
        case unconfirmed(String)
    }

    struct Work: Equatable {
        let token: UUID
        let request: Request
        let account: WorkshopSubscriptionAccount
        let connectionEpoch: UInt64
        let authorizationGeneration: UInt64
        /// Opaque browser selection/page generation for personal-vote work.
        /// It is never used to authorize a Steam request; it is merely echoed
        /// in the final receipt so a detail view can reject an old callback.
        let selectionGeneration: UInt64?
    }

    enum EnqueueResult: Equatable {
        case enqueued(UUID)
        case duplicate(workshopID: String)
    }

    typealias Completion = (Resolution) -> Void

    private var pending: [Work] = []
    private(set) var active: Work?
    private var reservedIDs = Set<String>()
    private var completions: [UUID: Completion] = [:]

    var isEmpty: Bool { active == nil && pending.isEmpty }
    var pendingCount: Int { pending.count }
    func contains(workshopID: String) -> Bool {
        guard let normalized = WorkshopFavoriteChangeRequest(workshopID: workshopID, favorited: true)?.workshopID else { return false }
        return reservedIDs.contains(normalized)
    }

    @discardableResult
    func enqueue(_ request: Request, account: WorkshopSubscriptionAccount,
                 connectionEpoch: UInt64, authorizationGeneration: UInt64,
                 selectionGeneration: UInt64? = nil,
                 completion: @escaping Completion) -> EnqueueResult {
        guard reservedIDs.insert(request.workshopID).inserted else { return .duplicate(workshopID: request.workshopID) }
        let work = Work(token: UUID(), request: request, account: account,
                        connectionEpoch: connectionEpoch, authorizationGeneration: authorizationGeneration,
                        selectionGeneration: selectionGeneration)
        pending.append(work)
        completions[work.token] = completion
        return .enqueued(work.token)
    }

    func beginNext() -> Work? {
        guard active == nil, !pending.isEmpty else { return nil }
        let work = pending.removeFirst()
        active = work
        return work
    }

    func finish(_ token: UUID, with resolution: Resolution) {
        guard active?.token == token, let completion = completions.removeValue(forKey: token) else { return }
        let work = active!
        active = nil
        reservedIDs.remove(work.request.workshopID)
        completion(resolution)
    }

    func cancelAll(with resolution: Resolution) {
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
