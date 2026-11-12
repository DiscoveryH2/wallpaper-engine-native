import Foundation

/// A personal Steam Workshop vote is deliberately not inferred from the
/// public positive-rate counters carried by browse rows.  The SDK reports a
/// three-way state for the *current account*; only up/down are writable.
enum WorkshopUserVote: String, Equatable {
    /// Steam reports all three SDK flags false for a current account that has
    /// not voted.  This is a confirmed read state, distinct from `skipped`.
    case none
    case up
    case down
    case skipped
}

/// Steam's `SetUserItemVote` only accepts a Boolean.  `false` means an
/// explicit down-vote; it is not a cancellation operation.
enum WorkshopUserVoteDirection: String, Equatable {
    case up
    case down

    var vote: WorkshopUserVote { self == .up ? .up : .down }
    var requestedVotedUp: Bool { self == .up }
}

/// Canonicalized current-selection read request.  `selectionGeneration` is
/// opaque to the coordinator: it is echoed to the browser so an old page or
/// selection completion cannot alter the newly selected detail panel.
struct WorkshopUserVoteReadRequest: Equatable {
    let workshopID: String
    let selectionGeneration: UInt64

    init?(workshopID: String, selectionGeneration: UInt64) {
        guard let canonical = WorkshopSubscriptionChangeRequest(workshopID: workshopID, subscribed: true)?.workshopID else {
            return nil
        }
        self.workshopID = canonical
        self.selectionGeneration = selectionGeneration
    }

    func helperArguments(expectedAccount: WorkshopSubscriptionAccount) -> [String] {
        ["vote-get", workshopID, "--expected-account", expectedAccount.id]
    }
}

/// An explicit user click that writes exactly one of Steam's two possible
/// vote directions.  The request has no "clear" case because the official
/// Steam API has no cancellation verb for this action.
struct WorkshopUserVoteChangeRequest: Equatable {
    let workshopID: String
    let direction: WorkshopUserVoteDirection

    init?(workshopID: String, direction: WorkshopUserVoteDirection) {
        guard let canonical = WorkshopSubscriptionChangeRequest(workshopID: workshopID, subscribed: true)?.workshopID else {
            return nil
        }
        self.workshopID = canonical
        self.direction = direction
    }

    func helperArguments(expectedAccount: WorkshopSubscriptionAccount) -> [String] {
        ["vote-set", workshopID, direction.rawValue, "--expected-account", expectedAccount.id]
    }
}

/// A confirmed answer remains bound to the account session that produced it.
/// `account` is intentionally not exposed to presentation code; the receipt
/// instead carries opaque fences the UI can compare with its own selection.
struct WorkshopUserVoteReceipt: Equatable {
    let workshopID: String
    let vote: WorkshopUserVote
    let selectionGeneration: UInt64
    let connectionEpoch: UInt64
    let authorizationGeneration: UInt64
}

enum WorkshopUserVoteReadResult {
    case confirmed(WorkshopUserVoteReceipt)
    case failed(String)
    case unconfirmed(String)
}

enum WorkshopUserVoteChangeResult {
    case confirmed(WorkshopUserVoteReceipt)
    case failed(String)
    case unconfirmed(String)
}

enum WorkshopUserVoteReadResolution: Equatable {
    case confirmed(WorkshopUserVote)
    case failed(String)
    case unconfirmed(String)
}

enum WorkshopUserVoteChangeResolution: Equatable {
    /// The exact SetUserItemVote callback was received.  This is not yet a
    /// visible state confirmation: the coordinator immediately follows with a
    /// fresh same-account `vote-get` and requires the requested vote there.
    case callbackConfirmed
    case failed(String)
    case unconfirmed(String)
}

/// Strict parser for the owned `we-workshop vote-get` protocol.  A read never
/// authorizes a write and it never manufactures a personal vote from missing,
/// numeric, or mutually contradictory boolean fields.
enum WorkshopUserVoteReadProtocol {
    private static let maximumErrorLength = 700

    static func parse(_ object: [String: Any]?, processExitedSuccessfully: Bool,
                      request: WorkshopUserVoteReadRequest,
                      account: WorkshopSubscriptionAccount) -> WorkshopUserVoteReadResolution {
        guard let object else {
            return .unconfirmed("steam-vote-get-unconfirmed: Steam 未返回可验证的个人投票结果。")
        }
        guard matchesIdentity(object, request: request, expectedAccount: account) else {
            return .unconfirmed("steam-vote-get-unconfirmed: Steam 返回的个人投票读取身份不匹配。")
        }
        guard WorkshopSubscriptionAccount(object["account_id"] as? String ?? "") == account else {
            return .unconfirmed("steam-account-mismatch: Steam 账号在读取个人投票期间变化；当前投票显示已失效。")
        }
        // `vote-get` is read-only.  A claimed mutation, including a numeric
        // pseudo-Boolean, is protocol-invalid rather than a benign read.
        guard object["mutation_started"] == nil || exactBoolean(object["mutation_started"], equals: false) else {
            return .unconfirmed("steam-vote-get-unconfirmed: 个人投票读取包含不允许的写入标记。")
        }
        guard let outcome = object["outcome"] as? String else {
            return .unconfirmed("steam-vote-get-unconfirmed: Steam 返回缺少 outcome。")
        }
        switch outcome {
        case "confirmed":
            guard processExitedSuccessfully,
                  exactBoolean(object["read_confirmed"], equals: true),
                  exactBoolean(object["request_started"], equals: true),
                  exactBoolean(object["callback_received"], equals: true),
                  exactBoolean(object["session_validated_before_callback"], equals: true),
                  exactBoolean(object["session_validated_after_callback"], equals: true),
                  exactBoolean(object["vote_state_confirmed"], equals: true),
                  exactBoolean(object["state_observed_by_exact_query"], equals: true),
                  object["callback"] as? String == "GetUserItemVoteResult_t",
                  exactInteger(object["callback_id"]) == 3409,
                  canonicalID(object["callback_workshop_id"] as? String) == request.workshopID,
                  exactInteger(object["callback_result"]) == 1,
                  let vote = exactVote(object) else {
                return .unconfirmed("steam-vote-get-unconfirmed: Steam 个人投票回执不完整或不匹配。")
            }
            return .confirmed(vote)
        case "failed":
            // A failed read cannot mutate an account.  Still require a
            // well-formed same-account envelope before showing an ordinary
            // failure; anything callback-shaped is left unconfirmed.
            guard !processExitedSuccessfully,
                  exactBoolean(object["read_confirmed"], equals: false),
                  exactBoolean(object["callback_received"], equals: false),
                  exactBoolean(object["session_validated_after_callback"], equals: false),
                  object["callback"] == nil, object["callback_id"] == nil,
                  object["callback_workshop_id"] == nil, object["callback_result"] == nil,
                  let failureCode = object["failure_code"] as? String,
                  readFailureCodes.contains(failureCode) else {
                return .unconfirmed("steam-vote-get-unconfirmed: Steam 个人投票读取失败回执不完整。")
            }
            return .failed(errorText(object, fallback: "steam-vote-get-failed: Steam 无法读取个人投票状态。"))
        case "unconfirmed":
            guard !processExitedSuccessfully,
                  exactBoolean(object["read_confirmed"], equals: false) else {
                return .unconfirmed("steam-vote-get-unconfirmed: Steam 未确认个人投票读取结果。")
            }
            return .unconfirmed(errorText(object, fallback: "steam-vote-get-unconfirmed: Steam 未确认个人投票读取结果。"))
        default:
            return .unconfirmed("steam-vote-get-unconfirmed: Steam 返回未知个人投票读取状态。")
        }
    }

    private static func matchesIdentity(_ object: [String: Any], request: WorkshopUserVoteReadRequest,
                                        expectedAccount: WorkshopSubscriptionAccount) -> Bool {
        object["status"] as? String == "vote-get"
            && object["source"] as? String == "official_steam_api"
            && exactInteger(object["appid"]) == 431960
            && canonicalID(object["workshop_id"] as? String) == request.workshopID
            && WorkshopSubscriptionAccount(object["expected_account_id"] as? String ?? "") == expectedAccount
    }

    private static func exactVote(_ object: [String: Any]) -> WorkshopUserVote? {
        guard let up = exactBooleanValue(object["voted_up"]),
              let down = exactBooleanValue(object["voted_down"]),
              let skipped = exactBooleanValue(object["vote_skipped"]),
              [up, down, skipped].filter({ $0 }).count <= 1,
              let text = object["vote_state"] as? String else { return nil }
        switch (text, up, down, skipped) {
        case ("none", false, false, false): return WorkshopUserVote.none
        case ("up", true, false, false): return .up
        case ("down", false, true, false): return .down
        case ("skipped", false, false, true): return .skipped
        default: return nil
        }
    }

    private static func canonicalID(_ text: String?) -> String? {
        guard let text else { return nil }
        return WorkshopUserVoteReadRequest(workshopID: text, selectionGeneration: 0)?.workshopID
    }

    private static let readFailureCodes: Set<String> = [
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

    private static func exactBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        exactBooleanValue(value) == expected
    }

    private static func exactBooleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func errorText(_ object: [String: Any], fallback: String) -> String {
        WorkshopUserVoteProtocolText.errorText(object, fallback: fallback, maximumErrorLength: maximumErrorLength,
                                               prefix: "steam-vote-get-error: ")
    }
}

/// Strict parser for `we-workshop vote-set`.  The result only proves the
/// exact `SetUserItemVoteResult_t` callback.  The coordinator must not expose
/// it to the UI as a changed vote until its subsequent `vote-get` confirms it.
enum WorkshopUserVoteChangeProtocol {
    private static let maximumErrorLength = 700

    static func parse(_ object: [String: Any]?, processExitedSuccessfully: Bool,
                      request: WorkshopUserVoteChangeRequest,
                      account: WorkshopSubscriptionAccount) -> WorkshopUserVoteChangeResolution {
        guard let object else {
            return .unconfirmed("steam-vote-set-unconfirmed: Steam 未返回可验证的个人投票写入结果；不会自动重试。")
        }
        guard matchesIdentity(object, request: request, expectedAccount: account) else {
            return .unconfirmed("steam-vote-set-unconfirmed: Steam 返回的个人投票写入身份不匹配；不会自动重试。")
        }
        guard WorkshopSubscriptionAccount(object["account_id"] as? String ?? "") == account else {
            return .unconfirmed("steam-account-mismatch: Steam 账号在个人投票写入期间变化；当前投票显示已失效。")
        }
        guard let outcome = object["outcome"] as? String else {
            return .unconfirmed("steam-vote-set-unconfirmed: Steam 返回缺少 outcome；不会自动重试。")
        }
        switch outcome {
        case "confirmed":
            guard processExitedSuccessfully,
                  exactBoolean(object["completion_confirmed"], equals: true),
                  exactBoolean(object["request_confirmed"], equals: true),
                  exactBoolean(object["callback_received"], equals: true),
                  exactBoolean(object["session_validated_before_callback"], equals: true),
                  exactBoolean(object["session_validated_after_callback"], equals: true),
                  exactBoolean(object["mutation_started"], equals: true),
                  exactBoolean(object["vote_state_confirmed"], equals: false),
                  exactBoolean(object["requires_fresh_vote_get"], equals: true),
                  exactBoolean(object["automatic_retry_performed"], equals: false),
                  object["callback"] as? String == "SetUserItemVoteResult_t",
                  exactInteger(object["callback_id"]) == 3408,
                  canonicalID(object["callback_workshop_id"] as? String) == request.workshopID,
                  exactInteger(object["callback_result"]) == 1,
                  exactBoolean(object["requested_voted_up"], equals: request.direction.requestedVotedUp),
                  exactBoolean(object["callback_voted_up"], equals: request.direction.requestedVotedUp) else {
                return .unconfirmed("steam-vote-set-unconfirmed: Steam 个人投票写入回执不完整或不匹配；不会自动重试。")
            }
            return .callbackConfirmed
        case "failed":
            guard !processExitedSuccessfully,
                  exactBoolean(object["completion_confirmed"], equals: false),
                  let mutationStarted = exactBooleanValue(object["mutation_started"]),
                  let callbackReceived = exactBooleanValue(object["callback_received"]) else {
                return .unconfirmed("steam-vote-set-unconfirmed: Steam 个人投票写入失败回执不完整；不会自动重试。")
            }
            if !mutationStarted && !callbackReceived,
               exactBoolean(object["session_validated_after_callback"], equals: false),
               object["callback"] == nil, object["callback_id"] == nil,
               object["callback_workshop_id"] == nil, object["callback_result"] == nil,
               object["callback_voted_up"] == nil,
               let failureCode = object["failure_code"] as? String,
               preflightFailureCodes.contains(failureCode) {
                return .failed(errorText(object, fallback: "steam-vote-set-failed: Steam 拒绝了个人投票请求。"))
            }
            guard mutationStarted, callbackReceived,
                  exactBoolean(object["session_validated_before_callback"], equals: true),
                  exactBoolean(object["session_validated_after_callback"], equals: true),
                  object["callback"] as? String == "SetUserItemVoteResult_t",
                  exactInteger(object["callback_id"]) == 3408,
                  canonicalID(object["callback_workshop_id"] as? String) == request.workshopID,
                  let callbackResult = exactInteger(object["callback_result"]), callbackResult > 1,
                  exactBoolean(object["requested_voted_up"], equals: request.direction.requestedVotedUp),
                  exactBoolean(object["callback_voted_up"], equals: request.direction.requestedVotedUp),
                  object["failure_code"] as? String == "result-\(callbackResult)" else {
                return .unconfirmed("steam-vote-set-unconfirmed: Steam 个人投票写入失败回执不完整；不会自动重试。")
            }
            return .failed(errorText(object, fallback: "steam-vote-set-failed: Steam 拒绝了个人投票请求。"))
        case "unconfirmed":
            guard !processExitedSuccessfully,
                  exactBoolean(object["completion_confirmed"], equals: false),
                  exactBooleanValue(object["mutation_started"]) != nil else {
                return .unconfirmed("steam-vote-set-unconfirmed: Steam 未确认个人投票写入结果；不会自动重试。")
            }
            return .unconfirmed(errorText(object, fallback: "steam-vote-set-unconfirmed: Steam 未确认个人投票写入结果；不会自动重试。"))
        default:
            return .unconfirmed("steam-vote-set-unconfirmed: Steam 返回未知个人投票写入状态；不会自动重试。")
        }
    }

    private static func matchesIdentity(_ object: [String: Any], request: WorkshopUserVoteChangeRequest,
                                        expectedAccount: WorkshopSubscriptionAccount) -> Bool {
        object["status"] as? String == "vote-set"
            && object["source"] as? String == "official_steam_api"
            && exactInteger(object["appid"]) == 431960
            && canonicalID(object["workshop_id"] as? String) == request.workshopID
            && object["direction"] as? String == request.direction.rawValue
            && WorkshopSubscriptionAccount(object["expected_account_id"] as? String ?? "") == expectedAccount
    }

    private static func canonicalID(_ text: String?) -> String? {
        guard let text else { return nil }
        return WorkshopUserVoteChangeRequest(workshopID: text, direction: .up)?.workshopID
    }

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

    private static func exactBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        exactBooleanValue(value) == expected
    }

    private static func exactBooleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func errorText(_ object: [String: Any], fallback: String) -> String {
        WorkshopUserVoteProtocolText.errorText(object, fallback: fallback, maximumErrorLength: maximumErrorLength,
                                               prefix: "steam-vote-set-error: ")
    }
}

private enum WorkshopUserVoteProtocolText {
    static func errorText(_ object: [String: Any], fallback: String, maximumErrorLength: Int, prefix: String) -> String {
        guard let raw = object["error"] as? String else { return fallback }
        let visible = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }).prefix(maximumErrorLength)).replacingOccurrences(of: #"\b7656\d{13}\b"#, with: "<redacted-steam-id>", options: .regularExpression)
        guard !visible.isEmpty else { return fallback }
        return visible.hasPrefix("steam-") ? visible : prefix + visible
    }
}
