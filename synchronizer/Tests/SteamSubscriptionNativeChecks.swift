import Darwin
import Foundation

private enum CheckFailure: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let value) = self { return value }; return "check failure" }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.message(message) }
}

private func callbacksBalanced(in library: URL) throws -> Bool {
    guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL),
          let raw = dlsym(handle, "FakeSteamCallbacksBalanced") else {
        throw CheckFailure.message("could not inspect fake Steam callback lifecycle")
    }
    typealias Balance = @convention(c) () -> Int32
    return unsafeBitCast(raw, to: Balance.self)() == 1
}

private func fakeLastOperation(in library: URL) throws -> Int32 {
    guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL),
          let raw = dlsym(handle, "FakeSteamLastOperation") else {
        throw CheckFailure.message("could not inspect fake Steam operation count")
    }
    typealias LastOperation = @convention(c) () -> Int32
    return unsafeBitCast(raw, to: LastOperation.self)()
}

private struct HelperResult {
    let status: Int32
    let json: [String: Any]
}

private func runHelper(_ helper: URL, library: URL, scenario: String, operation: String) throws -> HelperResult {
    let worker = Process(), output = Pipe(), errors = Pipe()
    worker.executableURL = helper
    worker.arguments = ["subscription-change", "123456789", operation, "--expected-account", "76561198000000001"]
    var environment = ProcessInfo.processInfo.environment
    environment["WE_TEST_STEAM_API_LIB"] = library.path
    environment["WE_TEST_STEAM_SUBSCRIPTION_TIMEOUT"] = "0.02"
    environment["FAKE_STEAM_SCENARIO"] = scenario
    // Do not inherit the user's Steam data location even though the test-only
    // init route never reads it.
    environment["HOME"] = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("steam-subscription-check-home", isDirectory: true).path
    worker.environment = environment
    worker.standardOutput = output
    worker.standardError = errors
    try worker.run()
    worker.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw CheckFailure.message("fake helper omitted JSON (exit \(worker.terminationStatus)): \(stderr)")
    }
    return HelperResult(status: worker.terminationStatus, json: json)
}

private func directChange(library: URL, scenario: String, operation: SteamSubscriptionOperation, expected: SteamSubscriptionChangeFailure.Outcome?) throws {
    setenv("FAKE_STEAM_SCENARIO", scenario, 1)
    do {
        let session = try SteamNativeSession(testLibraryURL: library)
        let result = try session.changeSubscription(123456789, operation: operation, expectedAccount: 76561198000000001, timeout: 0.02)
        try check(expected == nil, "\(scenario) unexpectedly succeeded")
        try check(result.id == 123456789 && result.operation == operation && result.callbackResult == 1, "\(scenario) success payload was malformed")
    } catch let failure as SteamSubscriptionChangeFailure {
        try check(expected == failure.outcome, "\(scenario) outcome \(failure.outcome.rawValue), expected \(expected?.rawValue ?? "success")")
        try check(failure.description.hasPrefix("steam-"), "\(scenario) failure lacks stable steam- prefix")
    } catch let error as SteamNativeError {
        try check(expected == .failed, "\(scenario) session failed before write with \(error.code)")
    }
    let balanced = try callbacksBalanced(in: library)
    try check(balanced, "\(scenario) did not free each ManualDispatch callback exactly once after dispatch")
}

private func directQuery(library: URL) throws {
    setenv("FAKE_STEAM_SCENARIO", "ok", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    let details = try session.itemDetails(123456789, timeout: 0.02)
    try check(details.id == 123456789 && details.updated == 1 && details.state == 4, "fake UGC query result was not decoded")
    let balanced = try callbacksBalanced(in: library)
    try check(balanced, "UGC query did not call GetAPICallResult before exactly-once FreeLastCallback")
}

private func expectedAccountMismatchDoesNotMutate(library: URL) throws {
    setenv("FAKE_STEAM_SCENARIO", "account-b", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try session.changeSubscription(123456789, operation: .subscribe, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("expected A / actual B unexpectedly called SubscribeItem")
    } catch let failure as SteamSubscriptionChangeFailure {
        try check(failure.outcome == .failed && failure.code == "account-mismatch" && failure.accountID == 76561198000000002 && !failure.mutationStarted, "A/B account mismatch must fail before a mutation begins")
    }
    let operation = try fakeLastOperation(in: library)
    try check(operation == 0, "A/B account mismatch reached SubscribeItem or UnsubscribeItem")
    let balanced = try callbacksBalanced(in: library)
    try check(balanced, "A/B mismatch should not allocate or leak a ManualDispatch callback")
}

private func accountChangedBeforeStartDoesNotMutate(library: URL) throws {
    setenv("FAKE_STEAM_SCENARIO", "account-changed-before-start", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try session.changeSubscription(123456789, operation: .subscribe, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("post-construction account switch unexpectedly reached SubscribeItem")
    } catch let failure as SteamSubscriptionChangeFailure {
        try check(failure.outcome == .unconfirmed && failure.code == "completion-unconfirmed" && failure.accountID == 76561198000000001 && !failure.mutationStarted, "post-construction account switch must not preserve the stale A identity as a definite failure")
    }
    let operation = try fakeLastOperation(in: library)
    let balanced = try callbacksBalanced(in: library)
    try check(operation == 0, "post-construction account switch reached SubscribeItem or UnsubscribeItem")
    try check(balanced, "post-construction account switch should not allocate or leak a ManualDispatch callback")
}

private func directSubscriptionsSnapshot(library: URL) throws {
    setenv("FAKE_STEAM_SCENARIO", "ok", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    let snapshot = try session.subscriptions(timeout: 0.2)
    try check(snapshot["status"] as? String == "subscriptions" && snapshot["snapshot_consistent"] as? Bool == true, "fake subscriptions snapshot was not complete")
    try check(snapshot["account_id"] as? String == "76561198000000001", "snapshot account_id must be an exact decimal SteamID64 string")
    try check(snapshot["subscription_count"] as? Int == 1, "fake snapshot subscription count malformed")
    let balanced = try callbacksBalanced(in: library)
    try check(balanced, "subscriptions query did not call GetAPICallResult before exactly-once FreeLastCallback")
}

private func testFakeLibrary(_ library: URL) throws -> Int {
    try directChange(library: library, scenario: "ok", operation: .subscribe, expected: nil)
    try directChange(library: library, scenario: "ok", operation: .unsubscribe, expected: nil)
    try directChange(library: library, scenario: "result-failed", operation: .subscribe, expected: .failed)
    try directChange(library: library, scenario: "request-rejected", operation: .subscribe, expected: .failed)
    try directChange(library: library, scenario: "offline-preflight", operation: .subscribe, expected: .failed)
    for scenario in ["no-callback", "wrong-callback", "wrong-item", "transport-failed", "offline-after-start", "account-changed-after-start", "shutdown-after-start"] {
        try directChange(library: library, scenario: scenario, operation: .subscribe, expected: .unconfirmed)
    }
    try directQuery(library: library)
    try directSubscriptionsSnapshot(library: library)
    try expectedAccountMismatchDoesNotMutate(library: library)
    try accountChangedBeforeStartDoesNotMutate(library: library)
    return 16
}

private func testFakeHelper(_ helper: URL, library: URL) throws -> Int {
    let subscribe = try runHelper(helper, library: library, scenario: "ok", operation: "subscribe")
    try check(subscribe.status == 0, "fake helper subscribe should exit 0")
    try check(subscribe.json["status"] as? String == "subscription-change" && subscribe.json["outcome"] as? String == "confirmed", "confirmed helper envelope malformed")
    try check(subscribe.json["callback"] as? String == "RemoteStorageSubscribePublishedFileResult_t" && subscribe.json["callback_id"] as? Int == 1313, "subscribe callback identity malformed")
    try check(subscribe.json["completion_confirmed"] as? Bool == true && subscribe.json["callback_received"] as? Bool == true && subscribe.json["session_validated_after_callback"] as? Bool == true && subscribe.json["mutation_started"] as? Bool == true && subscribe.json["callback_workshop_id"] as? String == "123456789" && subscribe.json["subscription_state_confirmed"] as? Bool == false && subscribe.json["download_ready"] as? Bool == false, "confirmed result overstates state/readiness")
    try check(subscribe.json["account_id"] as? String == "76561198000000001", "action account_id must be an exact decimal SteamID64 string")
    let unsubscribe = try runHelper(helper, library: library, scenario: "ok", operation: "unsubscribe")
    try check(unsubscribe.status == 0 && unsubscribe.json["callback_id"] as? Int == 1315 && unsubscribe.json["requested_subscribed"] as? Bool == false, "unsubscribe callback identity malformed")
    let rejected = try runHelper(helper, library: library, scenario: "result-failed", operation: "subscribe")
    try check(rejected.status != 0 && rejected.json["outcome"] as? String == "failed" && rejected.json["completion_confirmed"] as? Bool == false && rejected.json["callback_received"] as? Bool == true && rejected.json["session_validated_after_callback"] as? Bool == true && rejected.json["mutation_started"] as? Bool == true && rejected.json["callback"] as? String == "RemoteStorageSubscribePublishedFileResult_t" && rejected.json["callback_id"] as? Int == 1313 && rejected.json["callback_workshop_id"] as? String == "123456789" && rejected.json["callback_result"] as? Int == 8 && rejected.json["failure_code"] as? String == "result-8" && (rejected.json["error"] as? String)?.hasPrefix("steam-result-8:") == true, "Steam EResult failure must carry an exact callback proof while preserving completion_confirmed=false")
    let offline = try runHelper(helper, library: library, scenario: "offline-preflight", operation: "subscribe")
    try check(offline.status != 0 && offline.json["outcome"] as? String == "failed" && (offline.json["error"] as? String)?.hasPrefix("steam-offline:") == true, "preflight offline must be a definite failure")
    let unconfirmed = try runHelper(helper, library: library, scenario: "no-callback", operation: "subscribe")
    try check(unconfirmed.status != 0 && unconfirmed.json["outcome"] as? String == "unconfirmed" && (unconfirmed.json["error"] as? String)?.hasPrefix("steam-completion-unconfirmed:") == true && unconfirmed.json["account_id"] as? String == "76561198000000001", "callback timeout must remain explicitly unconfirmed with its session identity")
    let mismatch = try runHelper(helper, library: library, scenario: "account-b", operation: "subscribe")
    try check(mismatch.status != 0 && mismatch.json["outcome"] as? String == "failed" && (mismatch.json["error"] as? String)?.hasPrefix("steam-account-mismatch:") == true && mismatch.json["mutation_started"] as? Bool == false && mismatch.json["account_id"] as? String == "76561198000000002" && mismatch.json["expected_account_id"] as? String == "76561198000000001", "helper must report A/B mismatch before the mutation starts")
    let changedBeforeStart = try runHelper(helper, library: library, scenario: "account-changed-before-start", operation: "subscribe")
    try check(changedBeforeStart.status != 0 && changedBeforeStart.json["outcome"] as? String == "unconfirmed" && changedBeforeStart.json["failure_code"] as? String == "completion-unconfirmed" && changedBeforeStart.json["mutation_started"] as? Bool == false && changedBeforeStart.json["account_id"] as? String == "76561198000000001", "post-construction account switch must be unconfirmed even before an account-write FFI call")
    return 7
}

@main
private enum SteamSubscriptionNativeChecks {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2 else { throw CheckFailure.message("usage: SteamSubscriptionNativeChecks FAKE_LIB TEST_HELPER") }
            let library = URL(fileURLWithPath: arguments[0])
            let helper = URL(fileURLWithPath: arguments[1])
            let direct = try testFakeLibrary(library)
            let helperChecks = try testFakeHelper(helper, library: library)
            let result: [String: Any] = [
                "suite": "steam-subscription-native-checks",
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
            fputs("Steam subscription native checks failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
