import Foundation

enum SyncError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "Unknown error" }
}

let steam = SteamLibraryIndex.steamRoot

private let maximumProjectBytes = 4 * 1024 * 1024
private let maximumConsoleTailBytes = 256 * 1024

final class ResponseBox: @unchecked Sendable {
    let lock = NSLock()
    var data: Data?
    var status: Int?
    var error: Error?
}

private func readBoundedFile(_ url: URL, limit: Int, label: String) throws -> Data {
    guard limit > 0 else { throw SyncError.message("Invalid read limit for \(label)") }
    return try SteamLibraryIndex.read(url, limit: limit)
}

private func remoteRevision(_ id: String, native: SteamNativeSession?) throws -> (time: Double, source: String) {
    if let native, let numeric = UInt64(id), numeric > 0,
       let details = try? native.itemDetails(numeric, timeout: 20), !details.cached {
        return (Double(details.updated), "official_steam_api")
    }
    return (try remoteRevisionHTTP(id), "public_steam_web_api")
}

private func remoteRevisionHTTP(_ id: String) throws -> Double {
    let url = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = "itemcount=1&publishedfileids%5B0%5D=\(id)".data(using: .utf8)
    let session = URLSession(configuration: .ephemeral)
    let signal = DispatchSemaphore(value: 0), box = ResponseBox()
    let task = session.dataTask(with: request) { data, response, error in
        box.lock.lock()
        box.data = data; box.status = (response as? HTTPURLResponse)?.statusCode; box.error = error
        box.lock.unlock(); signal.signal()
    }
    task.resume()
    guard signal.wait(timeout: .now() + 15) == .success else {
        task.cancel(); session.invalidateAndCancel()
        throw SyncError.message("Public Steam version metadata timed out")
    }
    session.finishTasksAndInvalidate()
    box.lock.lock(); defer { box.lock.unlock() }
    if let error = box.error { throw error }
    guard box.status == 200, let data = box.data, data.count < 4 * 1024 * 1024,
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let response = json["response"] as? [String: Any],
          let items = response["publishedfiledetails"] as? [[String: Any]],
          let item = items.first,
          item["result"] as? Int == 1,
          item["consumer_app_id"] as? Int == 431960,
          item["publishedfileid"] as? String == id,
          let timestamp = item["time_updated"] as? NSNumber else {
        throw SyncError.message("Public Steam metadata did not confirm an accessible Wallpaper Engine item")
    }
    return timestamp.doubleValue
}

func receipt(_ id: String, since: TimeInterval? = nil, remoteTime: Double? = nil) throws -> [String: Any]? {
    guard validWorkshopID(id) else { throw SyncError.message("Invalid Workshop ID") }
    for library in SteamLibraryIndex.locations().libraries {
        if let value = try? receiptInLibrary(id, library: library, since: since, remoteTime: remoteTime) { return value }
    }
    return nil
}

private func receiptInLibrary(_ id: String, library: SteamLibraryLocation, since: TimeInterval? = nil, remoteTime: Double? = nil) throws -> [String: Any]? {
    let root = try library.manifest()
    let installed = (root["WorkshopItemsInstalled"] as? [String: [String: String]])?[id]
    let detail = (root["WorkshopItemDetails"] as? [String: [String: String]])?[id]
    guard let path = library.projectURL(id) else { return nil }
    guard let installed, let detail, let local = installed["manifest"],
          local == detail["latest_manifest"], FileManager.default.fileExists(atPath: path.path),
          !library.downloadPending(id)
    else { return nil }
    if let since {
        guard let touched = Double(detail["timetouched"] ?? ""), touched >= floor(since) - 1 else { return nil }
    }
    if let remoteTime {
        guard let localTime = Double(installed["timeupdated"] ?? ""), localTime >= remoteTime else { return nil }
    }
    let projectData = try readBoundedFile(path, limit: maximumProjectBytes, label: "Steam project.json")
    let object = try JSONSerialization.jsonObject(with: projectData) as? [String: Any]
    var result: [String: Any] = ["status": "installed", "appid": "431960", "workshop_id": id,
            "project": path.path, "library_root": library.root.path, "title": String((object?["title"] as? String ?? id).prefix(512)),
            "type": object?["type"] as? String ?? "unknown", "manifest": local,
            "latest_known_manifest": detail["latest_manifest"] ?? "", "steam_touched": detail["timetouched"] ?? "",
            "evidence": "Steam ACF installed manifest matches latest known manifest and project.json exists",
            "limitations": ["This verifies local Steam installation state, not rendering compatibility.",
                            "Polling does not guarantee zero-latency updates or access to every Workshop item."]]
    if let remoteTime { result["public_revision_time"] = remoteTime; result["remote_revision_checked"] = true }
    else { result["remote_revision_checked"] = false }
    return result
}

private struct PublicRevision {
    let time: Double?
    let reason: String?
}

private struct LocalWorkshopProject {
    let id: String
    let projectPath: String
    let libraryRoot: String
    let manifest: String?
    let latestKnownManifest: String?
    let localRevisionTime: Double?
    let locallyComplete: Bool
    let localReason: String?
}

private let workshopAppID = 431960
private let maximumUpdateProjects = 1_000
private let maximumMetadataBatch = 50
private let maximumMetadataResponseBytes = 4 * 1024 * 1024

private func stringValue(_ raw: Any?) -> String? {
    if let string = raw as? String, !string.isEmpty { return string }
    if let number = raw as? NSNumber { return number.stringValue }
    return nil
}

private func timestampValue(_ raw: Any?) -> Double? {
    let value: Double?
    if let number = raw as? NSNumber { value = number.doubleValue }
    else if let string = raw as? String { value = Double(string) }
    else { value = nil }
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
}

private func integerValue(_ raw: Any?) -> Int? {
    if let number = raw as? NSNumber {
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value >= Double(Int.min), value < Double(Int.max) else { return nil }
        return Int(value)
    }
    if let string = raw as? String { return Int(string) }
    return nil
}

private func validWorkshopID(_ id: String) -> Bool {
    SteamLibraryIndex.validID(id)
}

/// The mutation helper owns no persistent subscription state. A success here
/// only means Steam confirmed the exact API call; the caller must refresh the
/// normal subscriptions snapshot before changing a visible card's state.
private func subscriptionChangeCommand(id: String, operationText: String, expectedAccountText: String) throws -> [String: Any] {
    guard validWorkshopID(id), let numericID = UInt64(id), numericID != 0 else {
        throw SteamSubscriptionChangeFailure(outcome: .failed, code: "invalid-item", message: "Workshop item ID must contain a positive decimal Steam PublishedFileId")
    }
    guard let operation = SteamSubscriptionOperation(rawValue: operationText) else {
        throw SteamSubscriptionChangeFailure(outcome: .failed, code: "invalid-operation", message: "Subscription operation must be subscribe or unsubscribe")
    }
    guard let expectedAccount = UInt64(expectedAccountText), expectedAccount != 0, String(expectedAccount) == expectedAccountText else {
        throw SteamSubscriptionChangeFailure(outcome: .failed, code: "invalid-account", message: "Expected Steam account ID must be a canonical nonzero decimal SteamID64")
    }
    do {
        #if STEAM_NATIVE_TESTING
        // Test-only fake library injection is compiled out of the distributed
        // helper. It lets the protocol tests exercise this exact CLI without
        // loading, reading, or writing the user's Steam account.
        let session: SteamNativeSession
        if let testLibrary = ProcessInfo.processInfo.environment["WE_TEST_STEAM_API_LIB"], !testLibrary.isEmpty {
            session = try SteamNativeSession(testLibraryURL: URL(fileURLWithPath: testLibrary))
        } else {
            session = try SteamNativeSession()
        }
        #else
        let session = try SteamNativeSession()
        #endif
        #if STEAM_NATIVE_TESTING
        // Bounded test-only timeout so the fake helper can cover the
        // unconfirmed path without waiting for the production 30-second limit.
        let testTimeout = ProcessInfo.processInfo.environment["WE_TEST_STEAM_SUBSCRIPTION_TIMEOUT"].flatMap(TimeInterval.init)
        let change = try session.changeSubscription(numericID, operation: operation, expectedAccount: expectedAccount, timeout: testTimeout ?? 30)
        #else
        let change = try session.changeSubscription(numericID, operation: operation, expectedAccount: expectedAccount)
        #endif
        return [
            "status": "subscription-change",
            "outcome": "confirmed",
            "completion_confirmed": true,
            // Receiving the callback is necessary but not sufficient for a
            // visible membership change. Keep it separate from the historical
            // `completion_confirmed` success field so non-OK EResult receipts
            // can be represented without being mistaken for writes.
            "callback_received": true,
            "session_validated_after_callback": true,
            "request_confirmed": true,
            "mutation_started": true,
            // Deliberately unknown until a later full subscriptions snapshot.
            "subscription_state_confirmed": false,
            "download_ready": false,
            "appid": SteamNativeSession.appID,
            "source": "official_steam_api",
            "account_id": String(change.accountID),
            "expected_account_id": String(expectedAccount),
            "workshop_id": String(change.id),
            "operation": change.operation.rawValue,
            // This is the requested/confirmed call target, not a claim that a
            // current subscription snapshot has converged (see the explicit
            // `subscription_state_confirmed: false` above).
            "subscribed": change.operation == .subscribe,
            "requested_subscribed": change.operation == .subscribe,
            "callback": change.operation.callbackName,
            "callback_id": change.operation.expectedCallback,
            "callback_workshop_id": String(change.id),
            "callback_result": change.callbackResult,
            "limitations": [
                "A confirmed subscription request is not a refreshed subscription snapshot.",
                "A confirmed subscription request is not proof that content is installed or ready to render.",
                "Unsubscribe confirmation does not delete local files or an active wallpaper."
            ]
        ]
    } catch let failure as SteamSubscriptionChangeFailure {
        throw failure
    } catch let error as SteamNativeError {
        // No mutation method was called if session construction failed.
        throw SteamSubscriptionChangeFailure(outcome: .failed, code: error.code, message: error.description)
    } catch {
        throw SteamSubscriptionChangeFailure(outcome: .failed, code: "api-unavailable", message: String(describing: error))
    }
}

private func subscriptionChangeFailurePayload(id: String?, operation: String?, expectedAccountID: String?, error: Error) -> [String: Any] {
    let failure: SteamSubscriptionChangeFailure
    if let value = error as? SteamSubscriptionChangeFailure { failure = value }
    else { failure = SteamSubscriptionChangeFailure(outcome: .failed, code: "api-unavailable", message: String(describing: error)) }
    var result: [String: Any] = [
        "status": "subscription-change",
        "outcome": failure.outcome.rawValue,
        "completion_confirmed": false,
        "callback_received": false,
        "session_validated_after_callback": false,
        "request_confirmed": false,
        "mutation_started": failure.mutationStarted,
        "subscription_state_confirmed": false,
        "download_ready": false,
        "appid": SteamNativeSession.appID,
        "source": "official_steam_api",
        // Structured, bounded error identity. UI may display the separately
        // redacted `error`, but protocol checks never need to parse it.
        "failure_code": failure.code,
        "error": failure.description
    ]
    if let accountID = failure.accountID { result["account_id"] = String(accountID) }
    if let expectedAccountID { result["expected_account_id"] = expectedAccountID }
    if let id { result["workshop_id"] = id }
    if let operation { result["operation"] = operation }
    // A negative EResult is a definite rejection only when the helper read
    // the exact API-call result for this item before releasing it. Do not add
    // these fields for preflight failures, timeouts, transport faults, or
    // session changes: those remain explicitly unconfirmed.
    if let proof = failure.callbackProof,
       let operation, let expectedOperation = SteamSubscriptionOperation(rawValue: operation),
       proof.callbackID == expectedOperation.expectedCallback {
        result["callback_received"] = true
        result["session_validated_after_callback"] = proof.sessionValidatedAfterCallback
        result["callback"] = expectedOperation.callbackName
        result["callback_id"] = proof.callbackID
        result["callback_workshop_id"] = String(proof.itemID)
        result["callback_result"] = proof.result
    }
    return result
}

/// The explicit favorite helper owns no snapshot state. A success only proves
/// the exact Add/RemoveItemToFavorites API call; the coordinator must obtain
/// a later complete favorites snapshot before reflecting the action in UI.
private func favoriteChangeCommand(id: String, operationText: String, expectedAccountText: String) throws -> [String: Any] {
    guard validWorkshopID(id), let numericID = UInt64(id), numericID != 0 else {
        throw SteamFavoriteChangeFailure(outcome: .failed, code: "invalid-item", message: "Workshop item ID must contain a positive decimal Steam PublishedFileId")
    }
    guard let operation = SteamFavoriteOperation(rawValue: operationText) else {
        throw SteamFavoriteChangeFailure(outcome: .failed, code: "invalid-operation", message: "Favorite operation must be add or remove")
    }
    guard let expectedAccount = UInt64(expectedAccountText), expectedAccount != 0, String(expectedAccount) == expectedAccountText else {
        throw SteamFavoriteChangeFailure(outcome: .failed, code: "invalid-account", message: "Expected Steam account ID must be a canonical nonzero decimal SteamID64")
    }
    do {
        #if STEAM_NATIVE_TESTING
        // Only the compiled test helper may select its purpose-built fake
        // dylib. The distributed helper always resolves Valve's local signed
        // library from the normal Steam installation.
        let session: SteamNativeSession
        if let testLibrary = ProcessInfo.processInfo.environment["WE_TEST_STEAM_API_LIB"], !testLibrary.isEmpty {
            session = try SteamNativeSession(testLibraryURL: URL(fileURLWithPath: testLibrary))
        } else {
            session = try SteamNativeSession()
        }
        let testTimeout = ProcessInfo.processInfo.environment["WE_TEST_STEAM_FAVORITE_TIMEOUT"].flatMap(TimeInterval.init)
        let change = try session.changeFavorite(numericID, operation: operation, expectedAccount: expectedAccount, timeout: testTimeout ?? 30)
        #else
        let session = try SteamNativeSession()
        let change = try session.changeFavorite(numericID, operation: operation, expectedAccount: expectedAccount)
        #endif
        return [
            "status": "favorite-change",
            "outcome": "confirmed",
            "completion_confirmed": true,
            "callback_received": true,
            "session_validated_after_callback": true,
            "request_confirmed": true,
            "mutation_started": true,
            // Do not conflate a call receipt with a new UserUGC favorites
            // snapshot. The latter has its own complete-paging contract.
            "favorite_state_confirmed": false,
            "appid": SteamNativeSession.appID,
            "source": "official_steam_api",
            "account_id": String(change.accountID),
            "expected_account_id": String(expectedAccount),
            "workshop_id": String(change.id),
            "operation": change.operation.rawValue,
            "favorited": change.operation == .add,
            "requested_favorited": change.operation == .add,
            "callback": change.operation.callbackName,
            "callback_id": SteamFavoriteOperation.expectedCallback,
            "callback_workshop_id": String(change.id),
            "callback_result": change.callbackResult,
            "callback_was_add_request": change.operation.wasAddRequest,
            "limitations": [
                "A confirmed favorite request is not a refreshed favorites snapshot.",
                "The caller must query a complete account-matching favorite snapshot before changing visible favorite state.",
                "An unconfirmed favorite request is never retried automatically."
            ]
        ]
    } catch let failure as SteamFavoriteChangeFailure {
        throw failure
    } catch let error as SteamNativeError {
        throw SteamFavoriteChangeFailure(outcome: .failed, code: error.code, message: error.description)
    } catch {
        throw SteamFavoriteChangeFailure(outcome: .failed, code: "api-unavailable", message: String(describing: error))
    }
}

private func favoriteChangeFailurePayload(id: String?, operation: String?, expectedAccountID: String?, error: Error) -> [String: Any] {
    let failure: SteamFavoriteChangeFailure
    if let value = error as? SteamFavoriteChangeFailure { failure = value }
    else { failure = SteamFavoriteChangeFailure(outcome: .failed, code: "api-unavailable", message: String(describing: error)) }
    var result: [String: Any] = [
        "status": "favorite-change",
        "outcome": failure.outcome.rawValue,
        "completion_confirmed": false,
        "callback_received": false,
        "session_validated_after_callback": false,
        "request_confirmed": false,
        "mutation_started": failure.mutationStarted,
        // The helper cannot establish this without a subsequent full query.
        "favorite_state_confirmed": false,
        "appid": SteamNativeSession.appID,
        "source": "official_steam_api",
        "failure_code": failure.code,
        "error": failure.description
    ]
    if let accountID = failure.accountID { result["account_id"] = String(accountID) }
    if let expectedAccountID { result["expected_account_id"] = expectedAccountID }
    if let id { result["workshop_id"] = id }
    if let operation { result["operation"] = operation }
    // Only a fully matched 3407 callback with an EResult rejection and a
    // still-valid account becomes `failed`. No proof fields are emitted for
    // timeout, transport, mismatched item/direction, or account drift.
    if let proof = failure.callbackProof,
       let operation, let expectedOperation = SteamFavoriteOperation(rawValue: operation),
       proof.callbackID == SteamFavoriteOperation.expectedCallback,
       proof.wasAddRequest == expectedOperation.wasAddRequest {
        result["callback_received"] = true
        result["session_validated_after_callback"] = proof.sessionValidatedAfterCallback
        result["callback"] = expectedOperation.callbackName
        result["callback_id"] = proof.callbackID
        result["callback_workshop_id"] = String(proof.itemID)
        result["callback_result"] = proof.result
        result["callback_was_add_request"] = proof.wasAddRequest
    }
    return result
}

/// Read one account-scoped Workshop vote through the official Steam client.
/// The response is deliberately independent from browse metadata: aggregate
/// vote counts cannot prove this account's direction, and all-false is kept
/// as the distinct `none` state rather than reinterpreted as cancellation.
private func userVoteCommand(id: String, expectedAccountText: String) throws -> [String: Any] {
    guard validWorkshopID(id), let numericID = UInt64(id), numericID != 0 else {
        throw SteamUserVoteReadFailure(outcome: .failed, code: "invalid-item", message: "Workshop item ID must contain a positive decimal Steam PublishedFileId")
    }
    guard let expectedAccount = UInt64(expectedAccountText), expectedAccount != 0, String(expectedAccount) == expectedAccountText else {
        throw SteamUserVoteReadFailure(outcome: .failed, code: "invalid-account", message: "Expected Steam account ID must be a canonical nonzero decimal SteamID64")
    }
    do {
        #if STEAM_NATIVE_TESTING
        // Test-only dependency injection mirrors the favorite helper. The
        // shipping helper never accepts a library path and only opens Valve's
        // signed local Steam API.
        let session: SteamNativeSession
        if let testLibrary = ProcessInfo.processInfo.environment["WE_TEST_STEAM_API_LIB"], !testLibrary.isEmpty {
            session = try SteamNativeSession(testLibraryURL: URL(fileURLWithPath: testLibrary))
        } else {
            session = try SteamNativeSession()
        }
        let testTimeout = ProcessInfo.processInfo.environment["WE_TEST_STEAM_VOTE_TIMEOUT"].flatMap(TimeInterval.init)
        let vote = try session.userVote(numericID, expectedAccount: expectedAccount, timeout: testTimeout ?? 30)
        #else
        let session = try SteamNativeSession()
        let vote = try session.userVote(numericID, expectedAccount: expectedAccount)
        #endif
        return [
            "status": "vote-get",
            "outcome": "confirmed",
            "read_confirmed": true,
            "request_started": true,
            "callback_received": true,
            "session_validated_before_callback": true,
            "session_validated_after_callback": true,
            // This means the state was decoded from the exact 3409 callback
            // during this helper invocation. It is not a timestamp claim or
            // a statement about a subsequent user action.
            "vote_state_confirmed": true,
            "state_observed_by_exact_query": true,
            "appid": SteamNativeSession.appID,
            "source": "official_steam_api",
            "account_id": String(vote.accountID),
            "expected_account_id": String(expectedAccount),
            "workshop_id": String(vote.id),
            "vote_state": vote.state.rawValue,
            "voted_up": vote.state.votedUp,
            "voted_down": vote.state.votedDown,
            "vote_skipped": vote.state.voteSkipped,
            "callback": vote.state.callbackName,
            "callback_id": SteamUserVoteState.expectedCallback,
            "callback_workshop_id": String(vote.id),
            "callback_result": vote.callbackResult
        ]
    } catch let failure as SteamUserVoteReadFailure {
        throw failure
    } catch let error as SteamNativeError {
        throw SteamUserVoteReadFailure(outcome: .failed, code: error.code, message: error.description)
    } catch {
        throw SteamUserVoteReadFailure(outcome: .failed, code: "api-unavailable", message: String(describing: error))
    }
}

private func userVoteFailurePayload(id: String?, expectedAccountID: String?, error: Error) -> [String: Any] {
    let failure: SteamUserVoteReadFailure
    if let value = error as? SteamUserVoteReadFailure { failure = value }
    else { failure = SteamUserVoteReadFailure(outcome: .failed, code: "api-unavailable", message: String(describing: error)) }
    var result: [String: Any] = [
        "status": "vote-get",
        "outcome": failure.outcome.rawValue,
        "read_confirmed": false,
        "request_started": failure.requestStarted,
        "callback_received": false,
        "session_validated_before_callback": false,
        "session_validated_after_callback": false,
        "vote_state_confirmed": false,
        "state_observed_by_exact_query": false,
        "appid": SteamNativeSession.appID,
        "source": "official_steam_api",
        "failure_code": failure.code,
        "error": failure.description
    ]
    if let accountID = failure.accountID { result["account_id"] = String(accountID) }
    if let expectedAccountID { result["expected_account_id"] = expectedAccountID }
    if let id { result["workshop_id"] = id }
    // A non-OK result is a determinate read failure only after an exact item
    // receipt and post-callback session validation. Never emit a direction on
    // this path, including when all raw bools happened to be false.
    if let proof = failure.callbackProof,
       proof.callbackID == SteamUserVoteState.expectedCallback {
        result["callback_received"] = true
        result["session_validated_after_callback"] = proof.sessionValidatedAfterCallback
        result["callback"] = SteamUserVoteState.skipped.callbackName
        result["callback_id"] = proof.callbackID
        result["callback_workshop_id"] = String(proof.itemID)
        result["callback_result"] = proof.result
    }
    return result
}

/// Set an explicit up/down user vote. A successful response intentionally has
/// `vote_state_confirmed=false`: a receipt does not establish that a later
/// account-scoped read still observes the requested state.
private func userVoteChangeCommand(id: String, directionText: String, expectedAccountText: String) throws -> [String: Any] {
    guard validWorkshopID(id), let numericID = UInt64(id), numericID != 0 else {
        throw SteamUserVoteChangeFailure(outcome: .failed, code: "invalid-item", message: "Workshop item ID must contain a positive decimal Steam PublishedFileId")
    }
    guard let direction = SteamUserVoteDirection(rawValue: directionText) else {
        throw SteamUserVoteChangeFailure(outcome: .failed, code: "invalid-direction", message: "Vote direction must be up or down; down is the explicit false direction, not cancel")
    }
    guard let expectedAccount = UInt64(expectedAccountText), expectedAccount != 0, String(expectedAccount) == expectedAccountText else {
        throw SteamUserVoteChangeFailure(outcome: .failed, code: "invalid-account", message: "Expected Steam account ID must be a canonical nonzero decimal SteamID64")
    }
    do {
        #if STEAM_NATIVE_TESTING
        let session: SteamNativeSession
        if let testLibrary = ProcessInfo.processInfo.environment["WE_TEST_STEAM_API_LIB"], !testLibrary.isEmpty {
            session = try SteamNativeSession(testLibraryURL: URL(fileURLWithPath: testLibrary))
        } else {
            session = try SteamNativeSession()
        }
        let testTimeout = ProcessInfo.processInfo.environment["WE_TEST_STEAM_VOTE_TIMEOUT"].flatMap(TimeInterval.init)
        let change = try session.changeUserVote(numericID, direction: direction, expectedAccount: expectedAccount, timeout: testTimeout ?? 30)
        #else
        let session = try SteamNativeSession()
        let change = try session.changeUserVote(numericID, direction: direction, expectedAccount: expectedAccount)
        #endif
        return [
            "status": "vote-set",
            "outcome": "confirmed",
            "completion_confirmed": true,
            "request_confirmed": true,
            "mutation_started": true,
            "callback_received": true,
            "session_validated_before_callback": true,
            "session_validated_after_callback": true,
            // The coordinator must issue its own fresh vote-get before it
            // updates persistent/visible state; this helper never retries.
            "vote_state_confirmed": false,
            "requires_fresh_vote_get": true,
            "automatic_retry_performed": false,
            "appid": SteamNativeSession.appID,
            "source": "official_steam_api",
            "account_id": String(change.accountID),
            "expected_account_id": String(expectedAccount),
            "workshop_id": String(change.id),
            "direction": change.direction.rawValue,
            "requested_voted_up": change.direction.voteUp,
            "callback": change.direction.callbackName,
            "callback_id": SteamUserVoteDirection.expectedCallback,
            "callback_workshop_id": String(change.id),
            "callback_result": change.callbackResult,
            "callback_voted_up": change.direction.voteUp,
            "limitations": [
                "A confirmed vote request is not a fresh user-vote state query.",
                "The caller must use vote-get with the same expected account before changing visible vote state.",
                "An unconfirmed vote request is never retried automatically."
            ]
        ]
    } catch let failure as SteamUserVoteChangeFailure {
        throw failure
    } catch let error as SteamNativeError {
        throw SteamUserVoteChangeFailure(outcome: .failed, code: error.code, message: error.description)
    } catch {
        throw SteamUserVoteChangeFailure(outcome: .failed, code: "api-unavailable", message: String(describing: error))
    }
}

private func userVoteChangeFailurePayload(id: String?, direction: String?, expectedAccountID: String?, error: Error) -> [String: Any] {
    let failure: SteamUserVoteChangeFailure
    if let value = error as? SteamUserVoteChangeFailure { failure = value }
    else { failure = SteamUserVoteChangeFailure(outcome: .failed, code: "api-unavailable", message: String(describing: error)) }
    var result: [String: Any] = [
        "status": "vote-set",
        "outcome": failure.outcome.rawValue,
        "completion_confirmed": false,
        "request_confirmed": false,
        "mutation_started": failure.mutationStarted,
        "callback_received": false,
        "session_validated_before_callback": false,
        "session_validated_after_callback": false,
        "vote_state_confirmed": false,
        "requires_fresh_vote_get": failure.mutationStarted,
        "automatic_retry_performed": false,
        "appid": SteamNativeSession.appID,
        "source": "official_steam_api",
        "failure_code": failure.code,
        "error": failure.description
    ]
    if let accountID = failure.accountID { result["account_id"] = String(accountID) }
    if let expectedAccountID { result["expected_account_id"] = expectedAccountID }
    if let id { result["workshop_id"] = id }
    if let direction { result["direction"] = direction }
    // Only an exact matching 3408 receipt which was subsequently tied to the
    // same session becomes a deterministic failure. Every post-submit
    // transport/layout/identity issue remains receipt-free and unconfirmed.
    if let proof = failure.callbackProof,
       let direction, let expectedDirection = SteamUserVoteDirection(rawValue: direction),
       proof.callbackID == SteamUserVoteDirection.expectedCallback,
       proof.votedUp == expectedDirection.voteUp {
        result["callback_received"] = true
        result["session_validated_after_callback"] = proof.sessionValidatedAfterCallback
        result["callback"] = expectedDirection.callbackName
        result["callback_id"] = proof.callbackID
        result["callback_workshop_id"] = String(proof.itemID)
        result["callback_result"] = proof.result
        result["callback_voted_up"] = proof.votedUp
    }
    return result
}

private func manifestEntry(_ root: [String: Any], section: String, id: String) -> [String: Any]? {
    guard let entries = root[section] as? [String: Any] else { return nil }
    return entries[id] as? [String: Any]
}

/// Queries only public Workshop metadata. It neither asks Steam to subscribe to an
/// item nor starts a content download.
private func fetchPublicRevisions(_ ids: [String]) throws -> [String: PublicRevision] {
    guard !ids.isEmpty, ids.count <= maximumMetadataBatch else {
        throw SyncError.message("Public metadata requests must contain 1...\(maximumMetadataBatch) items")
    }

    let url = URL(string: "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/")!
    var body = "itemcount=\(ids.count)"
    for (index, id) in ids.enumerated() {
        body += "&publishedfileids%5B\(index)%5D=\(id)"
    }
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = body.data(using: .utf8)

    let session = URLSession(configuration: .ephemeral)
    let signal = DispatchSemaphore(value: 0)
    let box = ResponseBox()
    let task = session.dataTask(with: request) { data, response, error in
        box.lock.lock()
        box.data = data
        box.status = (response as? HTTPURLResponse)?.statusCode
        box.error = error
        box.lock.unlock()
        signal.signal()
    }
    task.resume()
    guard signal.wait(timeout: .now() + 15) == .success else {
        task.cancel()
        session.invalidateAndCancel()
        throw SyncError.message("Public Steam version metadata timed out after 15 seconds")
    }
    session.finishTasksAndInvalidate()

    box.lock.lock()
    defer { box.lock.unlock() }
    if let error = box.error { throw error }
    guard box.status == 200 else {
        throw SyncError.message("Public Steam metadata returned HTTP \(box.status.map(String.init) ?? "no status")")
    }
    guard let data = box.data, data.count <= maximumMetadataResponseBytes else {
        throw SyncError.message("Public Steam metadata exceeded the 4 MiB response limit or had no body")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let response = json["response"] as? [String: Any],
          let details = response["publishedfiledetails"] as? [[String: Any]] else {
        throw SyncError.message("Public Steam metadata response did not contain published file details")
    }

    let requested = Set(ids)
    var results: [String: PublicRevision] = [:]
    for detail in details {
        guard let id = stringValue(detail["publishedfileid"]), requested.contains(id) else { continue }
        guard integerValue(detail["result"]) == 1 else {
            if results[id] == nil {
                let result = stringValue(detail["result"]) ?? "missing"
                results[id] = PublicRevision(time: nil, reason: "Steam returned result \(result) for this Workshop item.")
            }
            continue
        }
        guard integerValue(detail["consumer_app_id"]) == workshopAppID else {
            results[id] = PublicRevision(time: nil, reason: "Steam metadata did not identify Wallpaper Engine as the consumer app.")
            continue
        }
        guard let time = timestampValue(detail["time_updated"]) else {
            results[id] = PublicRevision(time: nil, reason: "Steam metadata had no valid public update timestamp.")
            continue
        }
        results[id] = PublicRevision(time: time, reason: nil)
    }
    for id in ids where results[id] == nil {
        results[id] = PublicRevision(time: nil, reason: "Steam did not return metadata for this Workshop item.")
    }
    return results
}

private func publicRevisions(for ids: [String]) -> [String: PublicRevision] {
    var results: [String: PublicRevision] = [:]
    var offset = 0
    while offset < ids.count {
        let end = Swift.min(offset + maximumMetadataBatch, ids.count)
        let batch = Array(ids[offset..<end])
        do {
            let response = try fetchPublicRevisions(batch)
            for id in batch {
                results[id] = response[id] ?? PublicRevision(time: nil, reason: "Steam did not return metadata for this Workshop item.")
            }
        } catch {
            let reason = "Public Steam metadata check failed: \(error)"
            for id in batch {
                results[id] = PublicRevision(time: nil, reason: reason)
            }
        }
        offset = end
    }
    return results
}

private func localWorkshopProjects() -> (projects: [LocalWorkshopProject], truncated: Int, warnings: [String], libraries: [SteamLibraryLocation]) {
    let discovered = SteamLibraryIndex.projects(maximum: maximumUpdateProjects)
    var manifests: [String: [String: Any]] = [:]
    var failures: [String: String] = [:]
    for library in discovered.libraries {
        do { manifests[library.root.path] = try library.manifest() }
        catch { failures[library.root.path] = "Local appworkshop_431960.acf could not be read: \(error)" }
    }
    let items = discovered.projects.map { project -> LocalWorkshopProject in
        let root = manifests[project.library.root.path]
        let installed = root.flatMap { manifestEntry($0, section: "WorkshopItemsInstalled", id: project.id) }
        let detail = root.flatMap { manifestEntry($0, section: "WorkshopItemDetails", id: project.id) }
        let installedManifest = stringValue(installed?["manifest"])
        let latestManifest = stringValue(detail?["latest_manifest"])
        let localTime = timestampValue(installed?["timeupdated"])
        let locallyComplete = installedManifest != nil && installedManifest == latestManifest && !project.isInstalling
        let reason: String?
        if let failure = failures[project.library.root.path] { reason = failure }
        else if installed == nil || detail == nil { reason = "No matching installed/detail record in this library's appworkshop_431960.acf." }
        else if project.isInstalling { reason = "Steam still has a pending Workshop download for this item." }
        else if installedManifest == nil || latestManifest == nil { reason = "Steam's manifest fields are incomplete for this item." }
        else { reason = nil }
        return LocalWorkshopProject(id: project.id, projectPath: project.url.path, libraryRoot: project.library.root.path,
            manifest: installedManifest, latestKnownManifest: latestManifest, localRevisionTime: localTime,
            locallyComplete: locallyComplete, localReason: reason)
    }
    return (items, discovered.truncated, discovered.warnings, discovered.libraries)
}

private func checkUpdates() throws {
    let local = localWorkshopProjects()
    let revisions = publicRevisions(for: Array(Set(local.projects.map(\.id))).sorted())
    var items: [[String: Any]] = []
    items.reserveCapacity(local.projects.count)

    for project in local.projects {
        let publicRevision = revisions[project.id] ?? PublicRevision(
            time: nil,
            reason: "Public Steam metadata was not checked for this item."
        )
        let manifestsDiffer = project.manifest != nil && project.latestKnownManifest != nil && project.manifest != project.latestKnownManifest
        let status: String
        let reason: String?
        if manifestsDiffer {
            status = "outdated"
            reason = "Steam's installed manifest differs from its latest known manifest."
        } else if let publicTime = publicRevision.time, let localTime = project.localRevisionTime, localTime < publicTime {
            status = "outdated"
            reason = "The local Steam revision time is older than Steam's public update time."
        } else if publicRevision.time == nil {
            status = "unconfirmed"
            reason = publicRevision.reason
        } else if !project.locallyComplete {
            status = "unconfirmed"
            reason = project.localReason ?? "A complete local Steam installation was not confirmed."
        } else if project.localRevisionTime == nil {
            status = "unconfirmed"
            reason = "The local installed record has no valid revision timestamp."
        } else {
            status = "current"
            reason = nil
        }

        var item: [String: Any] = [
            "workshop_id": project.id,
            "project": project.projectPath,
            "library_root": project.libraryRoot,
            "manifest": project.manifest ?? NSNull(),
            "local_revision_time": project.localRevisionTime ?? NSNull(),
            "public_revision_time": publicRevision.time ?? NSNull(),
            "status": status
        ]
        if let reason { item["reason"] = reason }
        items.append(item)
    }

    let unconfirmed = items.reduce(0) { $0 + (($1["status"] as? String) == "unconfirmed" ? 1 : 0) } + local.truncated
    var result: [String: Any] = [
        "status": "checked",
        "items": items,
        "checked_count": items.count,
        "unconfirmed_count": unconfirmed,
        "discovered_count": items.count + local.truncated,
        "truncated": local.truncated > 0,
        "truncated_count": local.truncated,
        "libraries": local.libraries.map { $0.root.path },
        "discovery_warnings": local.warnings
    ]
    if local.truncated > 0 {
        result["truncation_reason"] = "Only the first \(maximumUpdateProjects) local project.json directories were checked; \(local.truncated) omitted items are unconfirmed."
    }
    try emit(result)
}

func emit(_ object: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
}

/// Reads only the bounded tail of Steam's non-credential diagnostic log. This is
/// invoked after a refresh timeout, never as a reason to stop waiting early.
private func readConsoleLogTail() throws -> Data {
    let url = steam.appendingPathComponent("logs/console_log.txt")
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let end = try handle.seekToEnd()
    let offset = end > UInt64(maximumConsoleTailBytes) ? end - UInt64(maximumConsoleTailBytes) : 0
    try handle.seek(toOffset: offset)
    return try handle.read(upToCount: maximumConsoleTailBytes) ?? Data()
}

private func steamConnectionDiagnostic(requestStarted: Date, timedOut: Date) -> String? {
    // Steam writes a local timestamp in its console log. The short lead-in catches
    // a failure just before the process forwards the request, while excluding older
    // failures from unrelated refreshes.
    let earliestRelevant = requestStarted.addingTimeInterval(-120)
    let latestRelevant = timedOut.addingTimeInterval(5)
    guard let tail = try? readConsoleLogTail() else { return nil }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

    var matches: [String] = []
    for line in String(decoding: tail, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
        guard line.contains("LogonFailure No Connection"), line.first == "[",
              let closing = line.firstIndex(of: "]") else { continue }
        let stampStart = line.index(after: line.startIndex)
        guard let timestamp = formatter.date(from: String(line[stampStart..<closing])),
              timestamp >= earliestRelevant, timestamp <= latestRelevant else { continue }
        if matches.count == 3 { matches.removeFirst() }
        matches.append(formatter.string(from: timestamp))
    }
    guard !matches.isEmpty else { return nil }
    return "Steam's local console log recorded \"LogonFailure No Connection\" at \(matches.joined(separator: ", ")) within 120 seconds before or during this refresh. It may explain the timeout, but does not establish Steam's current connection state."
}

func refresh(_ id: String, timeout: Double, projectPath: String? = nil, requestDownload: Bool = false, progress: SteamDownloadProgressWriter? = nil) throws {
    guard validWorkshopID(id) else {
        throw SyncError.message("Workshop ID must contain only decimal digits")
    }
    let executable = steam.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
        throw SyncError.message("Existing macOS Steam client not found")
    }
    let targetLibrary: SteamLibraryLocation?
    if let projectPath {
        guard projectPath.hasPrefix("/"),
              let library = SteamLibraryIndex.location(for: URL(fileURLWithPath: projectPath), id: id) else {
            throw SyncError.message("Requested project must belong to this Workshop item in a registered Steam library")
        }
        targetLibrary = library
    } else { targetLibrary = nil }
    func confirmedReceipt(since: TimeInterval? = nil, remoteTime: Double) throws -> [String: Any]? {
        if let targetLibrary {
            return try receiptInLibrary(id, library: targetLibrary, since: since, remoteTime: remoteTime)
        }
        return try receipt(id, since: since, remoteTime: remoteTime)
    }
    // Prefer a live, uncached UGC query from the already logged-in Steam client.
    // The public HTTP endpoint remains a fallback, including when Steam is off.
    progress?.emit(.checking)
    let native = try? SteamNativeSession()
    let revision = try remoteRevision(id, native: native)
    let remoteTime = revision.time
    // A fresh public revision check plus a complete matching local manifest is
    // sufficient when no update exists. Do not require Steam to re-download or
    // rewrite timetouched for an unchanged installation.
    let previousCurrentReceipt = try? confirmedReceipt(remoteTime: remoteTime)
    if !requestDownload, var current = previousCurrentReceipt {
        current["already_current"] = true
        current["download_requested"] = false
        current["revision_source"] = revision.source
        current["evidence"] = "Fresh Steam revision metadata confirms the complete local installation is current; no download requested"
        try emit(current)
        return
    }
    let requestStarted = Date()
    let started = requestStarted.timeIntervalSince1970
    let session: SteamNativeSession
    if let native { session = native } else { session = try SteamNativeSession() }
    do {
        guard let numericID = UInt64(id), numericID != 0 else { throw SyncError.message("Workshop ID exceeds Steam's numeric range") }
        progress?.emit(.downloading)
        let completion = try session.download(numericID, timeout: timeout) { bytes, total in progress?.emit(.downloading, downloaded: bytes, total: total) }
        progress?.emit(.confirming)
        // Steam can deliver its callback before the ACF writer flushes. The
        // matching callback is necessary but the selected-copy receipt must
        // still agree before returning a playable project.
        let receiptDeadline = Date().addingTimeInterval(5)
        repeat {
            if var state = try? confirmedReceipt(since: started, remoteTime: remoteTime) {
                let callbackProject = (completion["project"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
                let confirmedProject = (state["project"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
                guard callbackProject == confirmedProject else { throw SyncError.message("Steam callback and requested library receipt refer to different copies") }
                state["already_current"] = previousCurrentReceipt != nil; state["download_requested"] = true
                state["revision_source"] = revision.source
                state["download_completion"] = completion
                state["evidence"] = "Official Steam DownloadItemResult_t succeeded for this app/item; matching fresh ACF installation receipt and Steam revision confirmed"
                try session.validateSession()
                try emit(state); return
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < receiptDeadline
        throw SyncError.message("Steam reported download completion, but this library's fresh installation receipt was not confirmed")
    }

}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let action = args.first else {
        throw SyncError.message("Usage: we-workshop list | libraries | subscriptions | subscription-change ID subscribe|unsubscribe --expected-account SteamID64 | favorite-change ID add|remove --expected-account SteamID64 | vote-get ID --expected-account SteamID64 | vote-set ID up|down --expected-account SteamID64 | browse --query TEXT --sort SORT --cursor CURSOR | details ID | watch | status ID | check-updates | refresh|download ID [--timeout SECONDS] [--project /absolute/project.json] [--progress-json]")
    }
    if action == "watch" {
        guard args.count == 1 else { throw SyncError.message("watch takes no arguments") }
        let parent = getppid(), writer = SteamEventWriter()
        do {
            let session = try SteamNativeSession()
            try session.watch(writer: writer, parent: parent)
        } catch {
            try? writer.emit("unavailable", code: (error as? SteamNativeError)?.code ?? "api-unavailable")
            exit(1)
        }
    } else if action == "list" {
        var results: [[String: Any]] = []
        for project in SteamLibraryIndex.projects().projects {
            if let value = try? receiptInLibrary(project.id, library: project.library) { results.append(value) }
        }
        try emit(results)
    } else if action == "libraries" {
        guard args.count == 1 else { throw SyncError.message("libraries takes no arguments") }
        let result = SteamLibraryIndex.projects()
        try emit(["status": "discovered", "libraries": result.libraries.map { $0.root.path },
            "projects": result.projects.map { ["workshop_id": $0.id, "project": $0.url.path, "library_root": $0.library.root.path,
                "title": $0.title, "type": $0.type, "installing": $0.isInstalling] as [String: Any] },
            "warnings": result.warnings, "truncated_count": result.truncated] as [String: Any])
    } else if action == "subscriptions" {
        guard args.count == 1 else { throw SyncError.message("subscriptions takes no arguments") }
        let session = try SteamNativeSession()
        var result = try session.subscriptions()
        let local = SteamLibraryIndex.projects()
        if let items = result["items"] as? [[String: Any]] {
            result["items"] = items.map { item -> [String: Any] in
                var item = item
                let id = item["workshop_id"] as? String
                item["local_projects"] = local.projects.filter { $0.id == id }.map { $0.url.path }
                return item
            }
        }
        result["discovery_warnings"] = local.warnings
        try session.validateSession()
        try emit(result)
    } else if action == "subscription-change" {
        let id = args.count > 1 ? args[1] : nil
        let operation = args.count > 2 ? args[2] : nil
        let expectedAccount = args.count > 4 && args[3] == "--expected-account" ? args[4] : nil
        guard args.count == 5, let id, let operation, let expectedAccount else {
            let error = SteamSubscriptionChangeFailure(outcome: .failed, code: "invalid-command", message: "subscription-change requires one Workshop ID, subscribe or unsubscribe, and --expected-account SteamID64")
            try emit(subscriptionChangeFailurePayload(id: id, operation: operation, expectedAccountID: expectedAccount, error: error)); exit(1)
        }
        do {
            try emit(subscriptionChangeCommand(id: id, operationText: operation, expectedAccountText: expectedAccount))
        } catch {
            try emit(subscriptionChangeFailurePayload(id: id, operation: operation, expectedAccountID: expectedAccount, error: error)); exit(1)
        }
    } else if action == "favorite-change" {
        let id = args.count > 1 ? args[1] : nil
        let operation = args.count > 2 ? args[2] : nil
        let expectedAccount = args.count > 4 && args[3] == "--expected-account" ? args[4] : nil
        guard args.count == 5, let id, let operation, let expectedAccount else {
            let error = SteamFavoriteChangeFailure(outcome: .failed, code: "invalid-command", message: "favorite-change requires one Workshop ID, add or remove, and --expected-account SteamID64")
            try emit(favoriteChangeFailurePayload(id: id, operation: operation, expectedAccountID: expectedAccount, error: error)); exit(1)
        }
        do {
            try emit(favoriteChangeCommand(id: id, operationText: operation, expectedAccountText: expectedAccount))
        } catch {
            try emit(favoriteChangeFailurePayload(id: id, operation: operation, expectedAccountID: expectedAccount, error: error)); exit(1)
        }
    } else if action == "vote-get" {
        let id = args.count > 1 ? args[1] : nil
        let expectedAccount = args.count > 3 && args[2] == "--expected-account" ? args[3] : nil
        guard args.count == 4, let id, let expectedAccount else {
            let error = SteamUserVoteReadFailure(outcome: .failed, code: "invalid-command", message: "vote-get requires one Workshop ID and --expected-account SteamID64")
            try emit(userVoteFailurePayload(id: id, expectedAccountID: expectedAccount, error: error)); exit(1)
        }
        do {
            try emit(userVoteCommand(id: id, expectedAccountText: expectedAccount))
        } catch {
            try emit(userVoteFailurePayload(id: id, expectedAccountID: expectedAccount, error: error)); exit(1)
        }
    } else if action == "vote-set" {
        let id = args.count > 1 ? args[1] : nil
        let direction = args.count > 2 ? args[2] : nil
        let expectedAccount = args.count > 4 && args[3] == "--expected-account" ? args[4] : nil
        guard args.count == 5, let id, let direction, let expectedAccount else {
            let error = SteamUserVoteChangeFailure(outcome: .failed, code: "invalid-command", message: "vote-set requires one Workshop ID, up or down, and --expected-account SteamID64")
            try emit(userVoteChangeFailurePayload(id: id, direction: direction, expectedAccountID: expectedAccount, error: error)); exit(1)
        }
        do {
            try emit(userVoteChangeCommand(id: id, directionText: direction, expectedAccountText: expectedAccount))
        } catch {
            try emit(userVoteChangeFailurePayload(id: id, direction: direction, expectedAccountID: expectedAccount, error: error)); exit(1)
        }
    } else if action == "browse" {
        guard [7, 9].contains(args.count), args[1] == "--query", args[3] == "--sort", args[5] == "--cursor",
              args.count == 7 || args[7] == "--filters-json" else {
            throw SyncError.message("browse requires --query TEXT --sort SORT --cursor CURSOR [--filters-json JSON]")
        }
        let filters = args.count == 9 ? try WorkshopBrowseFilters(json: args[8]) : .empty
        let request = try WorkshopBrowseRequest(query: args[2], sort: args[4], cursor: args[6], filters: filters)
        let session = try SteamNativeSession()
        try emit(session.browse(request))
    } else if action == "details" {
        guard args.count == 2, validWorkshopID(args[1]), let id = UInt64(args[1]), id > 0 else {
            throw SyncError.message("details requires one valid Workshop item ID")
        }
        let session = try SteamNativeSession()
        let details = try session.itemDetails(id)
        var result: [String: Any] = ["status": "ugc-details", "appid": 431960,
            "workshop_id": String(details.id), "time_updated": details.updated,
            "query_cached": details.cached, "state": details.state, "source": "official_steam_api"]
        if let size = details.size, let source = details.sizeSource { result["size_bytes"] = size; result["size_source"] = source }
        try emit(result)
    } else if action == "check-updates" {
        guard args.count == 1 else {
            throw SyncError.message("check-updates does not accept an item ID or download options")
        }
        try checkUpdates()
    } else {
        guard args.count >= 2 else { throw SyncError.message("Missing Workshop ID") }
        if action == "status" {
            guard validWorkshopID(args[1]) else {
                throw SyncError.message("Workshop ID must contain only decimal digits")
            }
            if let result = try receipt(args[1]) { try emit(result) }
            else { throw SyncError.message("A complete current local installation was not confirmed") }
        } else if action == "refresh" || action == "download" {
            var timeout = 120.0
            var projectPath: String?
            var progress: SteamDownloadProgressWriter?
            var seen = Set<String>(), index = 2
            while index < args.count {
                let option = args[index]
                if option == "--progress-json", seen.insert(option).inserted {
                    progress = SteamDownloadProgressWriter(id: args[1]); index += 1; continue
                }
                guard ["--timeout", "--project"].contains(option), index + 1 < args.count, seen.insert(option).inserted else {
                    throw SyncError.message("Unknown, duplicated, or incomplete refresh option: \(option)")
                }
                if option == "--timeout" {
                    guard let value = Double(args[index + 1]), value.isFinite, value >= 1, value <= 1800 else {
                        throw SyncError.message("Timeout must be between 1 and 1800 seconds")
                    }
                    timeout = value
                } else { projectPath = args[index + 1] }
                index += 2
            }
            try refresh(args[1], timeout: timeout, projectPath: projectPath, requestDownload: action == "download", progress: progress)
        } else { throw SyncError.message("Unknown action: " + action) }
    }
} catch {
    try? emit(["status": "unconfirmed", "error": String(describing: error)])
    exit(1)
}
