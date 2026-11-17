import Darwin
import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "check failure" }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.message(message) }
}

private func fakeSymbol<T>(_ library: URL, _ name: String, _ type: T.Type) throws -> T {
    guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL), let raw = dlsym(handle, name) else {
        throw CheckFailure.message("could not inspect fake Steam vote symbol \(name)")
    }
    return unsafeBitCast(raw, to: T.self)
}

private func fakeInt(_ library: URL, _ name: String) throws -> Int32 {
    typealias Read = @convention(c) () -> Int32
    return try fakeSymbol(library, name, Read.self)()
}

private func callbacksBalanced(in library: URL) throws -> Bool {
    try fakeInt(library, "FakeSteamVoteCallbacksBalanced") == 1
}

private func getCount(in library: URL) throws -> Int32 { try fakeInt(library, "FakeSteamVoteGetCount") }
private func setCount(in library: URL) throws -> Int32 { try fakeInt(library, "FakeSteamVoteSetCount") }
private func lastDirectionUp(in library: URL) throws -> Int32 { try fakeInt(library, "FakeSteamVoteLastDirectionUp") }

private struct HelperResult {
    let status: Int32
    let json: [String: Any]
}

private func runHelper(_ helper: URL, library: URL, scenario: String, action: String, direction: String? = nil) throws -> HelperResult {
    let worker = Process(), output = Pipe(), errors = Pipe()
    worker.executableURL = helper
    if action == "vote-get" {
        worker.arguments = [action, "123456789", "--expected-account", "76561198000000001"]
    } else {
        worker.arguments = [action, "123456789", direction ?? "up", "--expected-account", "76561198000000001"]
    }
    var environment = ProcessInfo.processInfo.environment
    environment["WE_TEST_STEAM_API_LIB"] = library.path
    environment["WE_TEST_STEAM_VOTE_TIMEOUT"] = "0.02"
    environment["FAKE_STEAM_VOTE_SCENARIO"] = scenario
    // The fake dylib needs no user data. Keep HOME outside the real account in
    // case a future test-only regression accidentally attempts discovery.
    let temporaryHome = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("steam-user-vote-check-home", isDirectory: true)
    try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
    environment["HOME"] = temporaryHome.path
    worker.environment = environment
    worker.standardOutput = output
    worker.standardError = errors
    try worker.run()
    worker.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw CheckFailure.message("fake vote helper omitted JSON (exit \(worker.terminationStatus)): \(stderr)")
    }
    return HelperResult(status: worker.terminationStatus, json: json)
}

private func directRead(library: URL, scenario: String, expectedState: SteamUserVoteState? = nil, expectedOutcome: SteamUserVoteReadFailure.Outcome? = nil) throws {
    setenv("FAKE_STEAM_VOTE_SCENARIO", scenario, 1)
    do {
        let session = try SteamNativeSession(testLibraryURL: library)
        let result = try session.userVote(123456789, expectedAccount: 76561198000000001, timeout: 0.02)
        guard let expectedState else { throw CheckFailure.message("\(scenario) unexpectedly succeeded") }
        try check(result.id == 123456789 && result.callbackResult == 1 && result.state == expectedState, "\(scenario) successful vote query payload was malformed")
    } catch let failure as SteamUserVoteReadFailure {
        try check(expectedOutcome == failure.outcome, "\(scenario) query outcome \(failure.outcome.rawValue), expected \(expectedOutcome?.rawValue ?? "success")")
        try check(failure.description.hasPrefix("steam-"), "\(scenario) query failure lacks stable steam- prefix")
        if expectedOutcome == .unconfirmed {
            try check(failure.requestStarted, "\(scenario) post-submit query failure must remain unconfirmed")
        }
    } catch let error as SteamNativeError {
        try check(expectedOutcome == .failed, "\(scenario) query session failed before read with \(error.code)")
    }
    let gets = try getCount(in: library)
    let sets = try setCount(in: library)
    if expectedOutcome == .unconfirmed { try check(gets == 1 && sets == 0, "\(scenario) query must submit exactly one read and no mutation") }
    let balanced = try callbacksBalanced(in: library)
    try check(balanced, "\(scenario) query did not free each ManualDispatch callback exactly once")
}

private func directChange(library: URL, scenario: String, direction: SteamUserVoteDirection, expectedOutcome: SteamUserVoteChangeFailure.Outcome? = nil) throws {
    setenv("FAKE_STEAM_VOTE_SCENARIO", scenario, 1)
    do {
        let session = try SteamNativeSession(testLibraryURL: library)
        let result = try session.changeUserVote(123456789, direction: direction, expectedAccount: 76561198000000001, timeout: 0.02)
        guard expectedOutcome == nil else { throw CheckFailure.message("\(scenario) unexpectedly succeeded") }
        try check(result.id == 123456789 && result.direction == direction && result.callbackResult == 1, "\(scenario) successful vote write payload was malformed")
    } catch let failure as SteamUserVoteChangeFailure {
        try check(expectedOutcome == failure.outcome, "\(scenario) write outcome \(failure.outcome.rawValue), expected \(expectedOutcome?.rawValue ?? "success")")
        try check(failure.description.hasPrefix("steam-"), "\(scenario) write failure lacks stable steam- prefix")
        if expectedOutcome == .unconfirmed {
            try check(failure.mutationStarted, "\(scenario) must retain unknown post-submit state")
        }
    } catch let error as SteamNativeError {
        try check(expectedOutcome == .failed, "\(scenario) write session failed before mutation with \(error.code)")
    }
    let gets = try getCount(in: library)
    let sets = try setCount(in: library)
    if expectedOutcome == .unconfirmed { try check(gets == 0 && sets == 1, "\(scenario) unknown write must call SetUserItemVote exactly once") }
    let balanced = try callbacksBalanced(in: library)
    try check(balanced, "\(scenario) write did not free each ManualDispatch callback exactly once")
}

private func deterministicReadRejectionHasExactProof(library: URL) throws {
    setenv("FAKE_STEAM_VOTE_SCENARIO", "result-failed", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try session.userVote(123456789, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("result-failed GET unexpectedly succeeded")
    } catch let failure as SteamUserVoteReadFailure {
        try check(failure.outcome == .failed && failure.code == "result-8" && failure.requestStarted, "negative GET EResult must be determinate only after a receipt")
        guard let proof = failure.callbackProof else { throw CheckFailure.message("negative GET EResult omitted exact 3409 proof") }
        try check(proof.callbackID == 3409 && proof.itemID == 123456789 && proof.result == 8 && proof.sessionValidatedAfterCallback, "negative GET proof was not exact")
    }
    let gets = try getCount(in: library), sets = try setCount(in: library), balanced = try callbacksBalanced(in: library)
    try check(gets == 1 && sets == 0 && balanced, "negative GET EResult violated read/callback lifecycle")
}

private func deterministicWriteRejectionHasExactProof(library: URL) throws {
    setenv("FAKE_STEAM_VOTE_SCENARIO", "result-failed", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try session.changeUserVote(123456789, direction: .down, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("result-failed SET unexpectedly succeeded")
    } catch let failure as SteamUserVoteChangeFailure {
        try check(failure.outcome == .failed && failure.code == "result-8" && failure.mutationStarted, "negative SET EResult must be determinate only after a receipt")
        guard let proof = failure.callbackProof else { throw CheckFailure.message("negative SET EResult omitted exact 3408 proof") }
        try check(proof.callbackID == 3408 && proof.itemID == 123456789 && proof.result == 8 && !proof.votedUp && proof.sessionValidatedAfterCallback, "negative SET proof was not exact")
    }
    let gets = try getCount(in: library), sets = try setCount(in: library), balanced = try callbacksBalanced(in: library)
    try check(gets == 0 && sets == 1 && balanced, "negative SET EResult violated one-call/callback lifecycle")
}

private func expectedAccountMismatchDoesNotInvokeVoteFFI(library: URL) throws {
    setenv("FAKE_STEAM_VOTE_SCENARIO", "account-b", 1)
    let read = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try read.userVote(123456789, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("expected A / actual B unexpectedly called GetUserItemVote")
    } catch let failure as SteamUserVoteReadFailure {
        try check(failure.outcome == .failed && failure.code == "account-mismatch" && failure.accountID == 76561198000000002 && !failure.requestStarted, "A/B mismatch must stop before GetUserItemVote FFI")
    }
    var gets = try getCount(in: library), sets = try setCount(in: library), balanced = try callbacksBalanced(in: library)
    try check(gets == 0 && sets == 0 && balanced, "A/B query mismatch reached vote FFI")

    setenv("FAKE_STEAM_VOTE_SCENARIO", "account-b", 1)
    let write = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try write.changeUserVote(123456789, direction: .up, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("expected A / actual B unexpectedly called SetUserItemVote")
    } catch let failure as SteamUserVoteChangeFailure {
        try check(failure.outcome == .failed && failure.code == "account-mismatch" && failure.accountID == 76561198000000002 && !failure.mutationStarted, "A/B mismatch must stop before SetUserItemVote FFI")
    }
    gets = try getCount(in: library); sets = try setCount(in: library); balanced = try callbacksBalanced(in: library)
    try check(gets == 0 && sets == 0 && balanced, "A/B write mismatch reached vote FFI")
}

private func accountChangedBeforeStartDoesNotInvokeVoteFFI(library: URL) throws {
    setenv("FAKE_STEAM_VOTE_SCENARIO", "account-changed-before-start", 1)
    let read = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try read.userVote(123456789, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("post-construction account change unexpectedly called GetUserItemVote")
    } catch let failure as SteamUserVoteReadFailure {
        try check(failure.outcome == .unconfirmed && failure.code == "completion-unconfirmed" && !failure.requestStarted, "post-construction account change must be unconfirmed before GET FFI")
    }
    var gets = try getCount(in: library), sets = try setCount(in: library), balanced = try callbacksBalanced(in: library)
    try check(gets == 0 && sets == 0 && balanced, "post-construction GET account change reached FFI")

    setenv("FAKE_STEAM_VOTE_SCENARIO", "account-changed-before-start", 1)
    let write = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try write.changeUserVote(123456789, direction: .up, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("post-construction account change unexpectedly called SetUserItemVote")
    } catch let failure as SteamUserVoteChangeFailure {
        try check(failure.outcome == .unconfirmed && failure.code == "completion-unconfirmed" && !failure.mutationStarted, "post-construction account change must be unconfirmed before SET FFI")
    }
    gets = try getCount(in: library); sets = try setCount(in: library); balanced = try callbacksBalanced(in: library)
    try check(gets == 0 && sets == 0 && balanced, "post-construction SET account change reached FFI")
}

private func testFakeLibrary(_ library: URL) throws -> Int {
    // Four mutually exclusive SDK-valid GET states. In particular 000 is an
    // observed no-vote value, not a cancellation and not a malformed record.
    try directRead(library: library, scenario: "get-none", expectedState: SteamUserVoteState.none)
    try directRead(library: library, scenario: "get-up", expectedState: .up)
    try directRead(library: library, scenario: "get-down", expectedState: .down)
    try directRead(library: library, scenario: "get-skipped", expectedState: .skipped)
    try deterministicReadRejectionHasExactProof(library: library)
    try directRead(library: library, scenario: "request-rejected", expectedOutcome: .failed)
    try directRead(library: library, scenario: "offline-preflight", expectedOutcome: .failed)
    for scenario in ["no-callback", "wrong-handle", "wrong-callback", "wrong-size", "wrong-item", "get-flags-multiple", "get-flag-malformed", "transport-failed", "offline-after-start", "account-changed-after-start", "shutdown-after-start"] {
        try directRead(library: library, scenario: scenario, expectedOutcome: .unconfirmed)
    }

    try directChange(library: library, scenario: "ok", direction: .up)
    var gets = try getCount(in: library), sets = try setCount(in: library), lastDirection = try lastDirectionUp(in: library)
    try check(gets == 0 && sets == 1 && lastDirection == 1, "up must call v021 SetUserItemVote(true) exactly once")
    try directChange(library: library, scenario: "ok", direction: .down)
    gets = try getCount(in: library); sets = try setCount(in: library); lastDirection = try lastDirectionUp(in: library)
    try check(gets == 0 && sets == 1 && lastDirection == 0, "down must call v021 SetUserItemVote(false), not cancel")
    try deterministicWriteRejectionHasExactProof(library: library)
    try directChange(library: library, scenario: "request-rejected", direction: .up, expectedOutcome: .failed)
    try directChange(library: library, scenario: "offline-preflight", direction: .up, expectedOutcome: .failed)
    for scenario in ["no-callback", "wrong-handle", "wrong-callback", "wrong-size", "wrong-item", "wrong-direction", "direction-malformed", "transport-failed", "offline-after-start", "account-changed-after-start", "shutdown-after-start"] {
        try directChange(library: library, scenario: scenario, direction: .up, expectedOutcome: .unconfirmed)
    }
    try expectedAccountMismatchDoesNotInvokeVoteFFI(library: library)
    try accountChangedBeforeStartDoesNotInvokeVoteFFI(library: library)
    return 48
}

private func testFakeHelper(_ helper: URL, library: URL) throws -> Int {
    let noVote = try runHelper(helper, library: library, scenario: "get-none", action: "vote-get")
    try check(noVote.status == 0 && noVote.json["status"] as? String == "vote-get" && noVote.json["outcome"] as? String == "confirmed", "GET no-vote helper envelope malformed")
    try check(noVote.json["vote_state"] as? String == "none" && noVote.json["voted_up"] as? Bool == false && noVote.json["voted_down"] as? Bool == false && noVote.json["vote_skipped"] as? Bool == false && noVote.json["vote_state_confirmed"] as? Bool == true, "GET 000 must remain confirmed none, never cancellation")
    let skipped = try runHelper(helper, library: library, scenario: "get-skipped", action: "vote-get")
    try check(skipped.status == 0 && skipped.json["vote_state"] as? String == "skipped" && skipped.json["voted_up"] as? Bool == false && skipped.json["voted_down"] as? Bool == false && skipped.json["vote_skipped"] as? Bool == true, "GET skipped state malformed")
    let down = try runHelper(helper, library: library, scenario: "get-down", action: "vote-get")
    try check(down.status == 0 && down.json["vote_state"] as? String == "down" && down.json["callback"] as? String == "GetUserItemVoteResult_t" && down.json["callback_id"] as? Int == 3409 && down.json["callback_workshop_id"] as? String == "123456789" && down.json["callback_result"] as? Int == 1 && down.json["account_id"] as? String == "76561198000000001" && down.json["expected_account_id"] as? String == "76561198000000001" && down.json["state_observed_by_exact_query"] as? Bool == true, "GET down receipt/account freshness envelope malformed")
    let badFlags = try runHelper(helper, library: library, scenario: "get-flags-multiple", action: "vote-get")
    try check(badFlags.status != 0 && badFlags.json["outcome"] as? String == "unconfirmed" && badFlags.json["failure_code"] as? String == "callback-vote-state-malformed" && badFlags.json["vote_state_confirmed"] as? Bool == false && badFlags.json["vote_state"] == nil, "GET non-exclusive flags must not return a state")
    let rejectedRead = try runHelper(helper, library: library, scenario: "result-failed", action: "vote-get")
    try check(rejectedRead.status != 0 && rejectedRead.json["outcome"] as? String == "failed" && rejectedRead.json["callback_received"] as? Bool == true && rejectedRead.json["callback"] as? String == "GetUserItemVoteResult_t" && rejectedRead.json["callback_id"] as? Int == 3409 && rejectedRead.json["callback_result"] as? Int == 8 && rejectedRead.json["session_validated_after_callback"] as? Bool == true, "GET exact non-OK receipt must remain deterministic")

    let setUp = try runHelper(helper, library: library, scenario: "ok", action: "vote-set", direction: "up")
    try check(setUp.status == 0 && setUp.json["status"] as? String == "vote-set" && setUp.json["outcome"] as? String == "confirmed" && setUp.json["direction"] as? String == "up" && setUp.json["requested_voted_up"] as? Bool == true && setUp.json["callback"] as? String == "SetUserItemVoteResult_t" && setUp.json["callback_id"] as? Int == 3408 && setUp.json["callback_voted_up"] as? Bool == true && setUp.json["vote_state_confirmed"] as? Bool == false && setUp.json["requires_fresh_vote_get"] as? Bool == true, "SET up receipt must not overstate visible state")
    let setDown = try runHelper(helper, library: library, scenario: "ok", action: "vote-set", direction: "down")
    try check(setDown.status == 0 && setDown.json["direction"] as? String == "down" && setDown.json["requested_voted_up"] as? Bool == false && setDown.json["callback_voted_up"] as? Bool == false && setDown.json["callback_workshop_id"] as? String == "123456789", "SET down must serialize false as explicit down, not cancellation")
    let rejectedWrite = try runHelper(helper, library: library, scenario: "result-failed", action: "vote-set", direction: "down")
    try check(rejectedWrite.status != 0 && rejectedWrite.json["outcome"] as? String == "failed" && rejectedWrite.json["callback_received"] as? Bool == true && rejectedWrite.json["callback"] as? String == "SetUserItemVoteResult_t" && rejectedWrite.json["callback_id"] as? Int == 3408 && rejectedWrite.json["callback_result"] as? Int == 8 && rejectedWrite.json["callback_voted_up"] as? Bool == false && rejectedWrite.json["failure_code"] as? String == "result-8", "SET exact negative 3408 receipt must stay deterministic")
    let timeout = try runHelper(helper, library: library, scenario: "no-callback", action: "vote-set", direction: "up")
    try check(timeout.status != 0 && timeout.json["outcome"] as? String == "unconfirmed" && timeout.json["failure_code"] as? String == "completion-unconfirmed" && timeout.json["mutation_started"] as? Bool == true && timeout.json["callback_received"] as? Bool == false && timeout.json["automatic_retry_performed"] as? Bool == false, "SET timeout must remain unconfirmed without retry")
    let mismatch = try runHelper(helper, library: library, scenario: "account-b", action: "vote-set", direction: "up")
    try check(mismatch.status != 0 && mismatch.json["outcome"] as? String == "failed" && mismatch.json["failure_code"] as? String == "account-mismatch" && mismatch.json["mutation_started"] as? Bool == false && mismatch.json["account_id"] as? String == "76561198000000002" && mismatch.json["expected_account_id"] as? String == "76561198000000001", "SET helper must reject A/B mismatch before FFI")
    return 31
}

@main
private enum SteamUserVoteNativeChecks {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2 else { throw CheckFailure.message("usage: SteamUserVoteNativeChecks FAKE_LIB TEST_HELPER") }
            let library = URL(fileURLWithPath: arguments[0])
            let helper = URL(fileURLWithPath: arguments[1])
            let direct = try testFakeLibrary(library)
            let helperChecks = try testFakeHelper(helper, library: library)
            let result: [String: Any] = [
                "suite": "steam-user-vote-native-checks",
                "checks": direct + helperChecks,
                "passed": direct + helperChecks,
                "fakeSteamLibrary": true,
                "fakeHelper": true,
                "realSteamAccountUsed": false,
                "realSteamLibraryLoaded": false,
                "userSteamDataWritten": false
            ]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            fputs("Steam user-vote native checks failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
