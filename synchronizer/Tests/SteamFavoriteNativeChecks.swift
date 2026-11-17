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
        throw CheckFailure.message("could not inspect fake Steam symbol \(name)")
    }
    return unsafeBitCast(raw, to: T.self)
}

private func callbacksBalanced(in library: URL) throws -> Bool {
    typealias Read = @convention(c) () -> Int32
    return try fakeSymbol(library, "FakeSteamCallbacksBalanced", Read.self)() == 1
}

private func fakeLastOperation(in library: URL) throws -> Int32 {
    typealias Read = @convention(c) () -> Int32
    return try fakeSymbol(library, "FakeSteamLastOperation", Read.self)()
}

private func fakeMutationCount(in library: URL) throws -> Int32 {
    typealias Read = @convention(c) () -> Int32
    return try fakeSymbol(library, "FakeSteamMutationCount", Read.self)()
}

private func fakeLastAppID(in library: URL) throws -> UInt32 {
    typealias Read = @convention(c) () -> UInt32
    return try fakeSymbol(library, "FakeSteamLastAppID", Read.self)()
}

private struct HelperResult {
    let status: Int32
    let json: [String: Any]
}

private func runHelper(_ helper: URL, library: URL, scenario: String, operation: String) throws -> HelperResult {
    let worker = Process(), output = Pipe(), errors = Pipe()
    worker.executableURL = helper
    worker.arguments = ["favorite-change", "123456789", operation, "--expected-account", "76561198000000001"]
    var environment = ProcessInfo.processInfo.environment
    environment["WE_TEST_STEAM_API_LIB"] = library.path
    environment["WE_TEST_STEAM_FAVORITE_TIMEOUT"] = "0.02"
    environment["FAKE_STEAM_SCENARIO"] = scenario
    // Fake-only init never reads this, but retain an isolated HOME so a later
    // regression cannot silently use the user's Steam location.
    environment["HOME"] = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("steam-favorite-check-home", isDirectory: true).path
    worker.environment = environment
    worker.standardOutput = output
    worker.standardError = errors
    try worker.run()
    worker.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw CheckFailure.message("fake favorite helper omitted JSON (exit \(worker.terminationStatus)): \(stderr)")
    }
    return HelperResult(status: worker.terminationStatus, json: json)
}

private func directChange(library: URL, scenario: String, operation: SteamFavoriteOperation, expected: SteamFavoriteChangeFailure.Outcome?) throws {
    setenv("FAKE_STEAM_SCENARIO", scenario, 1)
    do {
        let session = try SteamNativeSession(testLibraryURL: library)
        let result = try session.changeFavorite(123456789, operation: operation, expectedAccount: 76561198000000001, timeout: 0.02)
        try check(expected == nil, "\(scenario) unexpectedly succeeded")
        try check(result.id == 123456789 && result.operation == operation && result.callbackResult == 1, "\(scenario) success payload was malformed")
    } catch let failure as SteamFavoriteChangeFailure {
        try check(expected == failure.outcome, "\(scenario) outcome \(failure.outcome.rawValue), expected \(expected?.rawValue ?? "success")")
        try check(failure.description.hasPrefix("steam-"), "\(scenario) failure lacks stable steam- prefix")
        if expected == .unconfirmed {
            try check(failure.mutationStarted, "\(scenario) must retain an unknown post-submit state")
        }
    } catch let error as SteamNativeError {
        try check(expected == .failed, "\(scenario) session failed before write with \(error.code)")
    }
    let count = try fakeMutationCount(in: library)
    let callbackOK = try callbacksBalanced(in: library)
    if expected == .unconfirmed {
        try check(count == 1, "\(scenario) must attempt the favorite mutation exactly once; unknown state is never retried")
    }
    try check(callbackOK, "\(scenario) did not free each ManualDispatch callback exactly once after dispatch")
}

private func deterministicRejectionHasExactProof(library: URL) throws {
    setenv("FAKE_STEAM_SCENARIO", "result-failed", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try session.changeFavorite(123456789, operation: .add, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("result-failed unexpectedly succeeded")
    } catch let failure as SteamFavoriteChangeFailure {
        try check(failure.outcome == .failed && failure.code == "result-8" && failure.mutationStarted, "negative EResult must be a definite failure only after submission")
        guard let proof = failure.callbackProof else { throw CheckFailure.message("negative EResult omitted exact 3407 proof") }
        try check(proof.callbackID == 3407 && proof.itemID == 123456789 && proof.result == 8 && proof.wasAddRequest && proof.sessionValidatedAfterCallback, "negative EResult proof was not exact")
    }
    let mutations = try fakeMutationCount(in: library)
    let balanced = try callbacksBalanced(in: library)
    try check(mutations == 1 && balanced, "negative EResult violated one-call/callback lifecycle")
}

private func expectedAccountMismatchDoesNotMutate(library: URL) throws {
    setenv("FAKE_STEAM_SCENARIO", "account-b", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try session.changeFavorite(123456789, operation: .add, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("expected A / actual B unexpectedly called AddItemToFavorites")
    } catch let failure as SteamFavoriteChangeFailure {
        try check(failure.outcome == .failed && failure.code == "account-mismatch" && failure.accountID == 76561198000000002 && !failure.mutationStarted, "A/B account mismatch must stop before Favorite FFI")
    }
    let mutations = try fakeMutationCount(in: library)
    let operation = try fakeLastOperation(in: library)
    let appID = try fakeLastAppID(in: library)
    let balanced = try callbacksBalanced(in: library)
    try check(mutations == 0 && operation == 0 && appID == 0, "A/B mismatch reached AddItemToFavorites or RemoveItemFromFavorites")
    try check(balanced, "A/B mismatch should not allocate or leak a ManualDispatch callback")
}

private func accountChangedBeforeStartDoesNotMutate(library: URL) throws {
    setenv("FAKE_STEAM_SCENARIO", "account-changed-before-start", 1)
    let session = try SteamNativeSession(testLibraryURL: library)
    do {
        _ = try session.changeFavorite(123456789, operation: .add, expectedAccount: 76561198000000001, timeout: 0.02)
        throw CheckFailure.message("post-construction account switch unexpectedly reached favorite FFI")
    } catch let failure as SteamFavoriteChangeFailure {
        try check(failure.outcome == .unconfirmed && failure.code == "completion-unconfirmed" && failure.accountID == 76561198000000001 && !failure.mutationStarted, "post-construction account switch must remain unconfirmed and pre-FFI")
    }
    let mutations = try fakeMutationCount(in: library)
    let operation = try fakeLastOperation(in: library)
    let balanced = try callbacksBalanced(in: library)
    try check(mutations == 0 && operation == 0, "post-construction account switch reached favorite FFI")
    try check(balanced, "post-construction account switch should not allocate or leak a ManualDispatch callback")
}

private func testFakeLibrary(_ library: URL) throws -> Int {
    try directChange(library: library, scenario: "ok", operation: .add, expected: nil)
    let addOperation = try fakeLastOperation(in: library)
    let addAppID = try fakeLastAppID(in: library)
    try check(addOperation == 1 && addAppID == 431960, "add must call the v021 favorite FFI with Wallpaper Engine appid")
    try directChange(library: library, scenario: "ok", operation: .remove, expected: nil)
    let removeOperation = try fakeLastOperation(in: library)
    let removeAppID = try fakeLastAppID(in: library)
    try check(removeOperation == 2 && removeAppID == 431960, "remove must call the v021 favorite FFI with Wallpaper Engine appid")
    try deterministicRejectionHasExactProof(library: library)
    try directChange(library: library, scenario: "request-rejected", operation: .add, expected: .failed)
    try directChange(library: library, scenario: "offline-preflight", operation: .add, expected: .failed)
    for scenario in ["no-callback", "wrong-handle", "wrong-callback", "wrong-size", "wrong-item", "wrong-direction", "direction-malformed", "transport-failed", "offline-after-start", "account-changed-after-start", "shutdown-after-start"] {
        try directChange(library: library, scenario: scenario, operation: .add, expected: .unconfirmed)
    }
    try expectedAccountMismatchDoesNotMutate(library: library)
    try accountChangedBeforeStartDoesNotMutate(library: library)
    return 19
}

private func testFakeHelper(_ helper: URL, library: URL) throws -> Int {
    let add = try runHelper(helper, library: library, scenario: "ok", operation: "add")
    try check(add.status == 0 && add.json["status"] as? String == "favorite-change" && add.json["outcome"] as? String == "confirmed", "confirmed add helper envelope malformed")
    try check(add.json["callback"] as? String == "UserFavoriteItemsListChanged_t" && add.json["callback_id"] as? Int == 3407 && add.json["callback_workshop_id"] as? String == "123456789" && add.json["callback_result"] as? Int == 1 && add.json["callback_was_add_request"] as? Bool == true, "confirmed add callback proof malformed")
    try check(add.json["account_id"] as? String == "76561198000000001" && add.json["expected_account_id"] as? String == "76561198000000001" && add.json["completion_confirmed"] as? Bool == true && add.json["callback_received"] as? Bool == true && add.json["session_validated_after_callback"] as? Bool == true && add.json["mutation_started"] as? Bool == true && add.json["favorite_state_confirmed"] as? Bool == false, "confirmed add overstates account or snapshot state")
    let remove = try runHelper(helper, library: library, scenario: "ok", operation: "remove")
    try check(remove.status == 0 && remove.json["outcome"] as? String == "confirmed" && remove.json["operation"] as? String == "remove" && remove.json["requested_favorited"] as? Bool == false && remove.json["callback_was_add_request"] as? Bool == false, "confirmed remove callback direction malformed")
    let rejected = try runHelper(helper, library: library, scenario: "result-failed", operation: "add")
    try check(rejected.status != 0 && rejected.json["outcome"] as? String == "failed" && rejected.json["completion_confirmed"] as? Bool == false && rejected.json["callback_received"] as? Bool == true && rejected.json["session_validated_after_callback"] as? Bool == true && rejected.json["mutation_started"] as? Bool == true && rejected.json["callback"] as? String == "UserFavoriteItemsListChanged_t" && rejected.json["callback_id"] as? Int == 3407 && rejected.json["callback_workshop_id"] as? String == "123456789" && rejected.json["callback_result"] as? Int == 8 && rejected.json["callback_was_add_request"] as? Bool == true && rejected.json["failure_code"] as? String == "result-8", "exact negative 3407 receipt must stay deterministically failed")
    let timeout = try runHelper(helper, library: library, scenario: "no-callback", operation: "add")
    try check(timeout.status != 0 && timeout.json["outcome"] as? String == "unconfirmed" && timeout.json["failure_code"] as? String == "completion-unconfirmed" && timeout.json["mutation_started"] as? Bool == true && timeout.json["callback_received"] as? Bool == false && timeout.json["favorite_state_confirmed"] as? Bool == false, "timeout must remain unconfirmed without a snapshot claim")
    let mismatch = try runHelper(helper, library: library, scenario: "account-b", operation: "add")
    try check(mismatch.status != 0 && mismatch.json["outcome"] as? String == "failed" && mismatch.json["failure_code"] as? String == "account-mismatch" && mismatch.json["mutation_started"] as? Bool == false && mismatch.json["account_id"] as? String == "76561198000000002" && mismatch.json["expected_account_id"] as? String == "76561198000000001", "helper must reject A/B mismatch before favorite FFI")
    let changedBeforeStart = try runHelper(helper, library: library, scenario: "account-changed-before-start", operation: "add")
    try check(changedBeforeStart.status != 0 && changedBeforeStart.json["outcome"] as? String == "unconfirmed" && changedBeforeStart.json["failure_code"] as? String == "completion-unconfirmed" && changedBeforeStart.json["mutation_started"] as? Bool == false && changedBeforeStart.json["favorite_state_confirmed"] as? Bool == false, "post-construction account change must not become a favorite retryable failure")
    return 15
}

@main
private enum SteamFavoriteNativeChecks {
    static func main() {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 2 else { throw CheckFailure.message("usage: SteamFavoriteNativeChecks FAKE_LIB TEST_HELPER") }
            let library = URL(fileURLWithPath: arguments[0])
            let helper = URL(fileURLWithPath: arguments[1])
            let direct = try testFakeLibrary(library)
            let helperChecks = try testFakeHelper(helper, library: library)
            let result: [String: Any] = [
                "suite": "steam-favorite-native-checks",
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
            fputs("Steam favorite native checks failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
