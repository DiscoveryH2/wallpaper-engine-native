import Darwin
import Foundation
import Security

enum SteamNativeError: Error, CustomStringConvertible {
    case message(String)
    case unavailable(code: String, message: String)
    var code: String { if case .unavailable(let code, _) = self { return code }; return "api-unavailable" }
    var description: String {
        switch self { case .message(let text), .unavailable(_, let text): return text }
    }
}

/// A user-selected change to a single Steam Workshop subscription.  This is
/// deliberately separate from local installation/download state: Steam can
/// accept a subscription request long before content becomes usable locally.
enum SteamSubscriptionOperation: String {
    case subscribe
    case unsubscribe

    var expectedCallback: Int32 {
        // Steamworks SDK 1.64: k_iSteamRemoteStorageCallbacks (1300) + 13/15.
        switch self { case .subscribe: return 1313; case .unsubscribe: return 1315 }
    }

    var callbackName: String {
        switch self {
        case .subscribe: return "RemoteStorageSubscribePublishedFileResult_t"
        case .unsubscribe: return "RemoteStorageUnsubscribePublishedFileResult_t"
        }
    }
}

/// `confirmed` means that the exact Steam API call received its matching
/// success result.  It does not assert that a refreshed subscription snapshot
/// was obtained or that an item finished downloading.
struct SteamSubscriptionChange {
    let id: UInt64
    let operation: SteamSubscriptionOperation
    let callbackResult: Int32
    /// The original, validated SteamID64 for this helper session. Serialize
    /// this only as decimal text: JSON number consumers may round SteamID64.
    let accountID: UInt64
}

/// Keep an explicit uncertainty channel. Once Steam has been asked to perform
/// a mutation, a timeout, callback transport fault, shutdown, or account
/// change cannot prove that the mutation did not happen.
struct SteamSubscriptionChangeFailure: Error, CustomStringConvertible {
    enum Outcome: String { case failed, unconfirmed }
    /// Evidence that Steam delivered the exact call-result payload. This is
    /// intentionally distinct from `mutationStarted`: a nonzero call handle
    /// followed by a timeout is not a definite rejection. The proof exists
    /// only for an item-matching Subscribe/Unsubscribe callback whose EResult
    /// was read before ManualDispatch released it.
    struct CallbackProof {
        let callbackID: Int32
        let itemID: UInt64
        let result: Int32
        /// Constructed only after `validateSession()` succeeds after the
        /// callback payload has been decoded.
        let sessionValidatedAfterCallback: Bool
    }
    let outcome: Outcome
    let code: String
    let message: String
    /// Present only when this helper established a session identity before the
    /// error. Callers must treat a missing identity as unsafe for account writes.
    let accountID: UInt64?
    /// True only after Steam returned a nonzero async call handle. A false
    /// value is particularly important for an expected-account mismatch: no
    /// account mutation function was invoked.
    let mutationStarted: Bool
    /// Present only for a definite non-OK EResult. All uncertain post-submit
    /// paths deliberately leave this nil so the host cannot turn a timeout or
    /// transport fault into an ordinary retryable failure.
    let callbackProof: CallbackProof?
    init(outcome: Outcome, code: String, message: String, accountID: UInt64? = nil,
         mutationStarted: Bool = false, callbackProof: CallbackProof? = nil) {
        self.outcome = outcome
        self.code = code
        self.message = message
        self.accountID = accountID
        self.mutationStarted = mutationStarted
        self.callbackProof = callbackProof
    }
    var description: String { "steam-\(code): \(message)" }
}

/// A user-selected change to a single Steam Workshop favorite. This is a
/// remote-account mutation only: a successful call result must never be
/// presented as a freshly converged local `favorite_ids` snapshot.
enum SteamFavoriteOperation: String {
    case add
    case remove

    /// Steamworks SDK 1.64 / ISteamUGC v021:
    /// k_iSteamUGCCallbacks (3400) + 7.
    static let expectedCallback: Int32 = 3407

    var wasAddRequest: Bool { self == .add }
    var callbackName: String { "UserFavoriteItemsListChanged_t" }
    var symbolName: String {
        switch self {
        case .add: return "SteamAPI_ISteamUGC_AddItemToFavorites"
        case .remove: return "SteamAPI_ISteamUGC_RemoveItemFromFavorites"
        }
    }
}

/// `confirmed` is confined to an exact successful 3407 API-call receipt. It
/// does not assert that `favoriteIDs(deadline:)` has subsequently observed
/// the requested state.
struct SteamFavoriteChange {
    let id: UInt64
    let operation: SteamFavoriteOperation
    let callbackResult: Int32
    /// Serialize SteamID64 only as decimal text; JSON numbers may round it.
    let accountID: UInt64
}

/// The favorite counterpart of `SteamSubscriptionChangeFailure`. Keep it
/// separate so callers cannot accidentally interpret a favorite proof as a
/// subscription snapshot confirmation.
struct SteamFavoriteChangeFailure: Error, CustomStringConvertible {
    enum Outcome: String { case failed, unconfirmed }
    struct CallbackProof {
        let callbackID: Int32
        let itemID: UInt64
        let result: Int32
        let wasAddRequest: Bool
        /// Set only after a post-callback Steam session validation succeeds.
        let sessionValidatedAfterCallback: Bool
    }
    let outcome: Outcome
    let code: String
    let message: String
    let accountID: UInt64?
    /// Set only after AddItemToFavorites / RemoveItemFromFavorites returned a
    /// nonzero SteamAPICall_t. An uncertain response is never retried here.
    let mutationStarted: Bool
    /// Present only for an exact item/direction/callback receipt with a
    /// non-OK EResult and a still-valid post-callback account session.
    let callbackProof: CallbackProof?
    init(outcome: Outcome, code: String, message: String, accountID: UInt64? = nil,
         mutationStarted: Bool = false, callbackProof: CallbackProof? = nil) {
        self.outcome = outcome
        self.code = code
        self.message = message
        self.accountID = accountID
        self.mutationStarted = mutationStarted
        self.callbackProof = callbackProof
    }
    var description: String { "steam-\(code): \(message)" }
}

/// The two account-scoped directions accepted by Steam's
/// `ISteamUGC::SetUserItemVote`.  This intentionally has no "clear" case:
/// the v021 flat ABI accepts a bool and `false` means a down-vote, not an
/// instruction to cancel or skip a previous vote.
enum SteamUserVoteDirection: String {
    case up
    case down

    /// Steamworks SDK 1.64 / ISteamUGC v021:
    /// k_iSteamUGCCallbacks (3400) + 8.
    static let expectedCallback: Int32 = 3408

    var voteUp: Bool { self == .up }
    var callbackName: String { "SetUserItemVoteResult_t" }
}

/// A valid `GetUserItemVoteResult_t` is deliberately four-state. Steam reports
/// a "skipped" state separately from the two directions, while all three
/// flags false is the distinct no-vote state. Multiply-true flags are
/// malformed evidence and are never reinterpreted as a cancelled vote.
enum SteamUserVoteState: String {
    case none
    case up
    case down
    case skipped

    static let expectedCallback: Int32 = 3409

    var callbackName: String { "GetUserItemVoteResult_t" }

    init?(rawVotedUp: UInt8, rawVotedDown: UInt8, rawVoteSkipped: UInt8) {
        guard rawVotedUp == 0 || rawVotedUp == 1,
              rawVotedDown == 0 || rawVotedDown == 1,
              rawVoteSkipped == 0 || rawVoteSkipped == 1 else { return nil }
        switch (rawVotedUp, rawVotedDown, rawVoteSkipped) {
        case (0, 0, 0): self = .none
        case (1, 0, 0): self = .up
        case (0, 1, 0): self = .down
        case (0, 0, 1): self = .skipped
        default: return nil
        }
    }

    var votedUp: Bool { self == .up }
    var votedDown: Bool { self == .down }
    var voteSkipped: Bool { self == .skipped }
}

/// The exact account-scoped value decoded from `GetUserItemVoteResult_t`.
/// It is not a public aggregate vote count. `none` remains distinct from
/// `skipped`; callers must not infer either from one false direction flag.
struct SteamUserVote {
    let id: UInt64
    let state: SteamUserVoteState
    let callbackResult: Int32
    /// Serialize SteamID64 only as decimal text; JSON number consumers may
    /// otherwise round this identity.
    let accountID: UInt64
}

/// An explicit SetUserItemVote receipt.  `confirmed` proves only this exact
/// request reached Steam; a later `GetUserItemVote` must establish visible
/// account state.
struct SteamUserVoteChange {
    let id: UInt64
    let direction: SteamUserVoteDirection
    let callbackResult: Int32
    let accountID: UInt64
}

/// Query failures retain the same account fence and exact-call contract as
/// writes.  An `unconfirmed` query never returns a vote state for callers to
/// reuse; it only records that a submitted read had no trustworthy result.
struct SteamUserVoteReadFailure: Error, CustomStringConvertible {
    enum Outcome: String { case failed, unconfirmed }
    struct CallbackProof {
        let callbackID: Int32
        let itemID: UInt64
        let result: Int32
        let sessionValidatedAfterCallback: Bool
    }
    let outcome: Outcome
    let code: String
    let message: String
    let accountID: UInt64?
    let requestStarted: Bool
    let callbackProof: CallbackProof?
    init(outcome: Outcome, code: String, message: String, accountID: UInt64? = nil,
         requestStarted: Bool = false, callbackProof: CallbackProof? = nil) {
        self.outcome = outcome
        self.code = code
        self.message = message
        self.accountID = accountID
        self.requestStarted = requestStarted
        self.callbackProof = callbackProof
    }
    var description: String { "steam-\(code): \(message)" }
}

/// Write failures never expose a speculative state.  Once the SetUserItemVote
/// FFI function has returned a nonzero `SteamAPICall_t`, all non-exact paths
/// are unconfirmed and are deliberately not retried by this helper.
struct SteamUserVoteChangeFailure: Error, CustomStringConvertible {
    enum Outcome: String { case failed, unconfirmed }
    struct CallbackProof {
        let callbackID: Int32
        let itemID: UInt64
        let result: Int32
        let votedUp: Bool
        let sessionValidatedAfterCallback: Bool
    }
    let outcome: Outcome
    let code: String
    let message: String
    let accountID: UInt64?
    let mutationStarted: Bool
    let callbackProof: CallbackProof?
    init(outcome: Outcome, code: String, message: String, accountID: UInt64? = nil,
         mutationStarted: Bool = false, callbackProof: CallbackProof? = nil) {
        self.outcome = outcome
        self.code = code
        self.message = message
        self.accountID = accountID
        self.mutationStarted = mutationStarted
        self.callbackProof = callbackProof
    }
    var description: String { "steam-\(code): \(message)" }
}

/// Handle the host's normal SIGTERM away from the signal handler itself, so
/// the watch loop can call Valve's shutdown and release its session cleanly.
private final class SteamWatchLifetime {
    private let lock = NSLock()
    private var stopping = false
    private let source: DispatchSourceSignal
    init() {
        signal(SIGTERM, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.stopping = true; self.lock.unlock()
        }
        source.resume()
    }
    var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }
    deinit { source.cancel(); signal(SIGTERM, SIG_DFL) }
}

/// Runs only inside an owned helper process. Loads the user's signed
/// official Steam API; no Valve binary or SDK implementation is redistributed.
/// Flat API/packed callback ABI: ValveSoftware/Proton, steamworks_sdk_164,
/// SteamUGC v021. macOS uses VALVE_CALLBACK_PACK_SMALL (4-byte packing).
final class SteamNativeSession {
    static let appID: UInt32 = 431960
    private typealias VoidCall = @convention(c) () -> Void
    private typealias Interface = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias ObjectBool = @convention(c) (UnsafeMutableRawPointer) -> Bool
    private typealias ObjectUInt = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    private typealias ObjectUInt64 = @convention(c) (UnsafeMutableRawPointer) -> UInt64
    private typealias ItemState = @convention(c) (UnsafeMutableRawPointer, UInt64) -> UInt32
    private typealias Frame = @convention(c) (Int32) -> Void
    private typealias NextCallback = @convention(c) (Int32, UnsafeMutableRawPointer) -> Bool
    private typealias CallResult = @convention(c) (Int32, UInt64, UnsafeMutableRawPointer, Int32, Int32, UnsafeMutablePointer<Bool>) -> Bool
    private let handle: UnsafeMutableRawPointer
    private var initialized = false
    private var user: UnsafeMutableRawPointer!
    private var ugc: UnsafeMutableRawPointer!
    private var pipe: Int32 = 0
    private var account: UInt64 = 0
    let libraryURL: URL

    convenience init() throws {
        let officialLibrary = SteamLibraryIndex.steamRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/libsteam_api.dylib")
        try self.init(libraryURL: officialLibrary, verifyValveSignature: true)
    }

#if STEAM_NATIVE_TESTING
    /// This entry point only exists in test builds. Production code cannot
    /// redirect Steam loading away from Valve's signed local installation.
    convenience init(testLibraryURL: URL) throws {
        try self.init(libraryURL: testLibraryURL, verifyValveSignature: false)
    }
#endif

    private init(libraryURL: URL, verifyValveSignature: Bool) throws {
        self.libraryURL = libraryURL
        if verifyValveSignature {
            var code: SecStaticCode?, requirement: SecRequirement?
            let rule = "anchor apple generic and certificate leaf[subject.OU] = \"MXGJJ98X76\""
            guard SecStaticCodeCreateWithPath(libraryURL as CFURL, [], &code) == errSecSuccess,
                  SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
                  let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
                throw SteamNativeError.message("The installed Steam API could not be verified as signed by Valve")
            }
        }
        // Applies only to this short-lived helper, never to the user's settings.
        setenv("SteamAppId", String(Self.appID), 1)
        setenv("SteamGameId", String(Self.appID), 1)
        guard let library = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            throw SteamNativeError.message("The installed official Steam API could not be loaded")
        }
        handle = library
        typealias Running = @convention(c) () -> Bool
        guard try symbol("SteamAPI_IsSteamRunning", Running.self)() else {
            throw SteamNativeError.unavailable(code: "client-not-running", message: "Open the official Steam client before using its API")
        }
        typealias Init = @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32
        var error = [CChar](repeating: 0, count: 1024)
        let result = try symbol("SteamAPI_InitFlat", Init.self)(&error)
        guard result == 0 else { throw SteamNativeError.message("Steam API initialization failed (\(result)): \(String(cString: error))") }
        initialized = true
        do {
            user = try symbol("SteamAPI_SteamUser_v023", Interface.self)()
            ugc = try symbol("SteamAPI_SteamUGC_v021", Interface.self)()
            guard user != nil, ugc != nil,
                  let utils = try symbol("SteamAPI_SteamUtils_v011", Interface.self)(),
                  let apps = try symbol("SteamAPI_SteamApps_v009", Interface.self)() else {
                throw SteamNativeError.message("Installed Steam API does not expose the required versioned interfaces")
            }
            account = try symbol("SteamAPI_ISteamUser_GetSteamID", ObjectUInt64.self)(user)
            typealias Owns = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Bool
            guard try symbol("SteamAPI_ISteamUtils_GetAppID", ObjectUInt.self)(utils) == Self.appID,
                  try symbol("SteamAPI_ISteamApps_BIsSubscribedApp", Owns.self)(apps, Self.appID) else {
                throw SteamNativeError.unavailable(code: "license-unconfirmed", message: "Steam did not confirm a licensed Wallpaper Engine session")
            }
            try requireOnline()
            try symbol("SteamAPI_ManualDispatch_Init", VoidCall.self)()
            typealias Pipe = @convention(c) () -> Int32
            pipe = try symbol("SteamAPI_GetHSteamPipe", Pipe.self)()
            guard pipe != 0 else { throw SteamNativeError.message("Steam returned no callback pipe") }
        } catch { close(); throw error }
    }

    deinit { close() }
    private func close() {
        if initialized {
            initialized = false
            if let shutdown = try? symbol("SteamAPI_Shutdown", VoidCall.self) { shutdown() }
        }
        // Deliberately no dlclose: Valve's own worker threads may still unwind.
    }
    private func symbol<T>(_ name: String, _ type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw SteamNativeError.message("Installed Steam API lacks " + name) }
        return unsafeBitCast(pointer, to: type)
    }
    private func requireOnline() throws {
        guard user != nil, try symbol("SteamAPI_ISteamUser_BLoggedOn", ObjectBool.self)(user) else {
            throw SteamNativeError.unavailable(code: "offline", message: "Steam is not currently connected to its account servers")
        }
        guard account != 0, try symbol("SteamAPI_ISteamUser_GetSteamID", ObjectUInt64.self)(user) == account else {
            throw SteamNativeError.unavailable(code: "account-changed", message: "Steam account changed during this request")
        }
    }
    func validateSession() throws {
        try requireOnline()
        typealias Owns = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Bool
        guard let apps = try symbol("SteamAPI_SteamApps_v009", Interface.self)(),
              try symbol("SteamAPI_ISteamApps_BIsSubscribedApp", Owns.self)(apps, Self.appID) else {
            throw SteamNativeError.unavailable(code: "license-unconfirmed", message: "Steam license is no longer confirmed")
        }
    }
    func itemState(_ id: UInt64) throws -> UInt32 {
        try symbol("SteamAPI_ISteamUGC_GetItemState", ItemState.self)(ugc, id)
    }
    private func clientSubscriptions(includeDisabled: Bool) throws -> [UInt64] {
        typealias Count = @convention(c) (UnsafeMutableRawPointer, Bool) -> UInt32
        typealias Items = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>?, UInt32, Bool) -> UInt32
        let count = try symbol("SteamAPI_ISteamUGC_GetNumSubscribedItems", Count.self)(ugc, includeDisabled)
        guard count <= 100_000 else { throw SteamNativeError.message("Steam subscriptions exceed the 100,000-item discovery limit") }
        var ids = [UInt64](repeating: 0, count: max(1, Int(count)))
        let returned = try symbol("SteamAPI_ISteamUGC_GetSubscribedItems", Items.self)(ugc, &ids, UInt32(ids.count), includeDisabled)
        guard returned <= ids.count, returned == count else { throw SteamNativeError.message("Steam subscriptions changed while reading; retry discovery") }
        return Array(ids.prefix(Int(returned)))
    }

    private struct Callback { let id: Int32; let payload: Data }
    private func callbacks() throws -> [Callback] {
        try symbol("SteamAPI_ManualDispatch_RunFrame", Frame.self)(pipe)
        let next = try symbol("SteamAPI_ManualDispatch_GetNextCallback", NextCallback.self)
        let free = try symbol("SteamAPI_ManualDispatch_FreeLastCallback", Frame.self)
        let message = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { message.deallocate() }
        var result: [Callback] = []
        for _ in 0..<512 {
            guard next(pipe, message) else { break }
            // ManualDispatch owns only the most recently returned callback.
            // Copy it before retrieving another one and release it in this
            // iteration, rather than deferring all releases to function exit.
            do {
                defer { free(pipe) }
                let id = message.load(fromByteOffset: 4, as: Int32.self)
                let parameter = message.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)
                let size = message.load(fromByteOffset: 16, as: Int32.self)
                guard size >= 0, size <= 65_536 else { continue }
                if size == 0 { result.append(Callback(id: id, payload: Data())) }
                else if let parameter { result.append(Callback(id: id, payload: Data(bytes: parameter, count: Int(size)))) }
            }
        }
        return result
    }
    private func value<T>(_ data: Data, _ offset: Int, _ type: T.Type) throws -> T {
        guard offset >= 0, offset + MemoryLayout<T>.size <= data.count else { throw SteamNativeError.message("Steam callback has an unexpected layout") }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: type) }
    }
    /// Wait for a specific async Steam API call. Notifications such as
    /// UserSubscribedItemsListChanged are deliberately not accepted as a call
    /// result: only SteamAPICallCompleted_t (703) for the exact handle is.
    private func awaitAPICall(_ call: UInt64, expectedCallback: Int32, permittedPayloadBytes: ClosedRange<Int>, deadline: Date, label: String) throws -> Data {
        let run = try symbol("SteamAPI_ManualDispatch_RunFrame", Frame.self)
        let next = try symbol("SteamAPI_ManualDispatch_GetNextCallback", NextCallback.self)
        let free = try symbol("SteamAPI_ManualDispatch_FreeLastCallback", Frame.self)
        let read = try symbol("SteamAPI_ManualDispatch_GetAPICallResult", CallResult.self)
        let message = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { message.deallocate() }
        while Date() < deadline {
            try requireOnline()
            run(pipe)
            for _ in 0..<512 {
                guard next(pipe, message) else { break }
                // The SDK template requires GetAPICallResult to run while the
                // 703 callback is still dispatched, then requires exactly one
                // FreeLastCallback before the next GetNextCallback call.
                do {
                    defer { free(pipe) }
                    let callbackID = message.load(fromByteOffset: 4, as: Int32.self)
                    let parameter = message.load(fromByteOffset: 8, as: UnsafeRawPointer?.self)
                    let callbackBytes = message.load(fromByteOffset: 16, as: Int32.self)
                    if callbackID == 704 { throw SteamNativeError.unavailable(code: "shutdown-requested", message: "Steam is shutting down") }
                    if callbackID == 102 || callbackID == 103 {
                        throw SteamNativeError.unavailable(code: "offline", message: "Steam connection callback reported unavailability")
                    }
                    guard callbackID == 703 else { continue }
                    // SteamAPICallCompleted_t is the fixed 16-byte pack(4)
                    // structure { uint64 call; int32 callback; uint32 bytes }.
                    guard callbackBytes == 16, let parameter else {
                        throw SteamNativeError.message("Steam returned a malformed async call completion")
                    }
                    let completion = Data(bytes: parameter, count: Int(callbackBytes))
                    guard try value(completion, 0, UInt64.self) == call else { continue }
                    let kind = try value(completion, 8, Int32.self)
                    let size = try value(completion, 12, UInt32.self)
                    guard kind == expectedCallback, let count = Int(exactly: size), permittedPayloadBytes.contains(count) else {
                        throw SteamNativeError.message("Steam returned an unexpected \(label) result")
                    }
                    var failed = false, data = Data(count: count)
                    let accepted = data.withUnsafeMutableBytes { read(pipe, call, $0.baseAddress!, Int32(count), kind, &failed) }
                    guard accepted, !failed else { throw SteamNativeError.message("Steam \(label) failed at the callback transport layer") }
                    return data
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw SteamNativeError.message("Steam \(label) timed out without a result callback")
    }
    private func awaitQuery(_ call: UInt64, deadline: Date) throws -> Data {
        try awaitAPICall(call, expectedCallback: 3401, permittedPayloadBytes: 21...65_536, deadline: deadline, label: "UGC query")
    }

    /// Request a single user-initiated subscription mutation. It neither
    /// refreshes the subscription snapshot nor deletes/downloads local files.
    /// A later `subscriptions` request remains the authority for visible state.
    func changeSubscription(_ id: UInt64, operation: SteamSubscriptionOperation, expectedAccount: UInt64, timeout: TimeInterval = 30) throws -> SteamSubscriptionChange {
        guard id != 0 else {
            throw SteamSubscriptionChangeFailure(outcome: .failed, code: "invalid-item", message: "Workshop item ID must be a positive Steam PublishedFileId", accountID: account)
        }
        guard expectedAccount != 0 else {
            throw SteamSubscriptionChangeFailure(outcome: .failed, code: "invalid-account", message: "Expected Steam account ID must be nonzero", accountID: account)
        }
        var submitted = false
        do {
            // The client session must be usable before the write function is
            // entered. This is a definite preflight failure, not uncertainty.
            try validateSession()
            // The browser snapshot is account-specific. Reject before calling
            // either mutation FFI if Steam switched from the enqueue account.
            guard account == expectedAccount else {
                throw SteamSubscriptionChangeFailure(outcome: .failed, code: "account-mismatch", message: "Steam account differs from the account that authorized this request", accountID: account)
            }
            typealias Change = @convention(c) (UnsafeMutableRawPointer, UInt64) -> UInt64
            let symbolName = operation == .subscribe ? "SteamAPI_ISteamUGC_SubscribeItem" : "SteamAPI_ISteamUGC_UnsubscribeItem"
            let request = try symbol(symbolName, Change.self)
            let call = request(ugc, id)
            guard call != 0 else {
                throw SteamSubscriptionChangeFailure(outcome: .failed, code: "request-rejected", message: "Steam rejected the \(operation.rawValue) request before returning an async call", accountID: account)
            }
            submitted = true
            let payload = try awaitAPICall(call, expectedCallback: operation.expectedCallback, permittedPayloadBytes: 12...12,
                                           deadline: Date().addingTimeInterval(timeout), label: "\(operation.rawValue) request")
            // SDK 1.64, VALVE_CALLBACK_PACK_SMALL: EResult at byte 0, then the
            // unaligned PublishedFileId_t at byte 4. This is not SteamUGCDetails.
            let result = try value(payload, 0, Int32.self)
            let callbackID = try value(payload, 4, UInt64.self)
            guard callbackID == id else {
                throw SteamSubscriptionChangeFailure(outcome: .unconfirmed, code: "callback-item-mismatch", message: "Steam completed a different Workshop item", accountID: account, mutationStarted: true)
            }
            guard result == 1 else {
                // A non-OK EResult is a definite rejection only while the
                // same Steam account/session still validates after we read the
                // exact callback. Otherwise it joins every other submitted
                // request on the unconfirmed path below.
                try validateSession()
                let proof = SteamSubscriptionChangeFailure.CallbackProof(callbackID: operation.expectedCallback,
                                                                           itemID: callbackID, result: result,
                                                                           sessionValidatedAfterCallback: true)
                throw SteamSubscriptionChangeFailure(outcome: .failed, code: "result-\(result)", message: "Steam rejected the \(operation.rawValue) request (EResult \(result))", accountID: account, mutationStarted: true, callbackProof: proof)
            }
            // Do not report a confirmed account mutation if Steam changed
            // account/session between its callback and our return to the app.
            try validateSession()
            return SteamSubscriptionChange(id: id, operation: operation, callbackResult: result, accountID: account)
        } catch let failure as SteamSubscriptionChangeFailure {
            throw failure
        } catch let error as SteamNativeError {
            let code = error.code
            // Before the FFI call, an offline or license preflight failure is
            // a definite no-write. An account switch is different: `account`
            // is the identity captured during session construction, so it
            // must never be returned as an ordinary A failure after a later
            // validation observed a different current account.
            let uncertain = submitted || code == "account-changed"
            throw SteamSubscriptionChangeFailure(outcome: uncertain ? .unconfirmed : .failed,
                                                 code: uncertain ? "completion-unconfirmed" : code,
                                                 message: uncertain ? "Steam 未确认请求最终结果；不会自动重试，请先同步订阅再决定是否重试。（\(code)）" : error.description,
                                                 accountID: account, mutationStarted: submitted)
        } catch {
            throw SteamSubscriptionChangeFailure(outcome: submitted ? .unconfirmed : .failed,
                                                 code: submitted ? "completion-unconfirmed" : "api-unavailable",
                                                 message: submitted ? "Steam 未确认请求最终结果；不会自动重试，请先同步订阅再决定是否重试。" : String(describing: error),
                                                 accountID: account, mutationStarted: submitted)
        }
    }

    /// Request one explicit, account-scoped Steam favorite mutation. This
    /// helper has no retry loop: after a nonzero SteamAPICall_t, anything
    /// other than the exact 3407 receipt below is an unknown remote state.
    /// It intentionally neither queries nor changes the cached favorites
    /// snapshot; callers must obtain a new complete snapshot before updating
    /// visible favorite state.
    func changeFavorite(_ id: UInt64, operation: SteamFavoriteOperation, expectedAccount: UInt64, timeout: TimeInterval = 30) throws -> SteamFavoriteChange {
        guard id != 0 else {
            throw SteamFavoriteChangeFailure(outcome: .failed, code: "invalid-item", message: "Workshop item ID must be a positive Steam PublishedFileId", accountID: account)
        }
        guard expectedAccount != 0 else {
            throw SteamFavoriteChangeFailure(outcome: .failed, code: "invalid-account", message: "Expected Steam account ID must be nonzero", accountID: account)
        }
        var submitted = false
        do {
            // This validation and the expected-account fence are deliberately
            // before resolving or invoking either Add/Remove FFI symbol.
            try validateSession()
            guard account == expectedAccount else {
                throw SteamFavoriteChangeFailure(outcome: .failed, code: "account-mismatch", message: "Steam account differs from the account that authorized this request", accountID: account)
            }
            // ISteamUGC::Add/RemoveItemToFavorites(AppId_t, PublishedFileId_t)
            // in the SDK 1.64 v021 flat ABI.
            typealias Change = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt64) -> UInt64
            let request = try symbol(operation.symbolName, Change.self)
            let call = request(ugc, Self.appID, id)
            guard call != 0 else {
                throw SteamFavoriteChangeFailure(outcome: .failed, code: "request-rejected", message: "Steam rejected the favorite \(operation.rawValue) request before returning an async call", accountID: account)
            }
            submitted = true
            // `awaitAPICall` accepts only a 703 record whose async handle is
            // exactly `call`, asks GetAPICallResult while that callback is
            // outstanding, then frees that callback exactly once. For 3407,
            // macOS VALVE_CALLBACK_PACK_SMALL layout is exactly 16 bytes:
            // PublishedFileId_t @0, EResult @8, bool m_bWasAddRequest @12.
            let payload = try awaitAPICall(call, expectedCallback: SteamFavoriteOperation.expectedCallback,
                                           permittedPayloadBytes: 16...16,
                                           deadline: Date().addingTimeInterval(timeout),
                                           label: "favorite \(operation.rawValue) request")
            let callbackID = try value(payload, 0, UInt64.self)
            let result = try value(payload, 8, Int32.self)
            let rawWasAddRequest = try value(payload, 12, UInt8.self)
            guard rawWasAddRequest == 0 || rawWasAddRequest == 1 else {
                throw SteamFavoriteChangeFailure(outcome: .unconfirmed, code: "callback-direction-malformed", message: "Steam completed the favorite request with an invalid direction flag", accountID: account, mutationStarted: true)
            }
            let callbackWasAddRequest = rawWasAddRequest == 1
            guard callbackID == id else {
                throw SteamFavoriteChangeFailure(outcome: .unconfirmed, code: "callback-item-mismatch", message: "Steam completed a different Workshop item", accountID: account, mutationStarted: true)
            }
            guard callbackWasAddRequest == operation.wasAddRequest else {
                throw SteamFavoriteChangeFailure(outcome: .unconfirmed, code: "callback-direction-mismatch", message: "Steam completed a different favorite operation", accountID: account, mutationStarted: true)
            }
            guard result == 1 else {
                // A negative EResult is determinate only when all callback
                // fields above matched and the post-callback account still
                // validates. An account switch reduces this to unconfirmed.
                try validateSession()
                let proof = SteamFavoriteChangeFailure.CallbackProof(callbackID: SteamFavoriteOperation.expectedCallback,
                                                                        itemID: callbackID, result: result,
                                                                        wasAddRequest: callbackWasAddRequest,
                                                                        sessionValidatedAfterCallback: true)
                throw SteamFavoriteChangeFailure(outcome: .failed, code: "result-\(result)", message: "Steam rejected the favorite \(operation.rawValue) request (EResult \(result))", accountID: account, mutationStarted: true, callbackProof: proof)
            }
            // Success must use the same account session which received the
            // callback. A change here is unknown, never an implicit retry.
            try validateSession()
            return SteamFavoriteChange(id: id, operation: operation, callbackResult: result, accountID: account)
        } catch let failure as SteamFavoriteChangeFailure {
            throw failure
        } catch let error as SteamNativeError {
            let code = error.code
            // A stale constructor identity is not evidence that the remote
            // request did not happen; retain the same fail-closed rule as
            // subscription mutations even if the FFI call was never reached.
            let uncertain = submitted || code == "account-changed"
            throw SteamFavoriteChangeFailure(outcome: uncertain ? .unconfirmed : .failed,
                                             code: uncertain ? "completion-unconfirmed" : code,
                                             message: uncertain ? "Steam 未确认收藏请求最终结果；不会自动重试，请先同步收藏再决定是否重试。（\(code)）" : error.description,
                                             accountID: account, mutationStarted: submitted)
        } catch {
            throw SteamFavoriteChangeFailure(outcome: submitted ? .unconfirmed : .failed,
                                             code: submitted ? "completion-unconfirmed" : "api-unavailable",
                                             message: submitted ? "Steam 未确认收藏请求最终结果；不会自动重试，请先同步收藏再决定是否重试。" : String(describing: error),
                                             accountID: account, mutationStarted: submitted)
        }
    }

    /// Read the current signed-in account's vote for one Workshop item through
    /// the official ISteamUGC v021 API. This is intentionally a point read:
    /// it does not write, infer state from aggregate counts, or treat the
    /// valid all-false state as a cancellation.
    func userVote(_ id: UInt64, expectedAccount: UInt64, timeout: TimeInterval = 30) throws -> SteamUserVote {
        guard id != 0 else {
            throw SteamUserVoteReadFailure(outcome: .failed, code: "invalid-item", message: "Workshop item ID must be a positive Steam PublishedFileId", accountID: account)
        }
        guard expectedAccount != 0 else {
            throw SteamUserVoteReadFailure(outcome: .failed, code: "invalid-account", message: "Expected Steam account ID must be nonzero", accountID: account)
        }
        var submitted = false
        do {
            // Do not resolve or call GetUserItemVote until the account which
            // authorized this read is still the session account.
            try validateSession()
            guard account == expectedAccount else {
                throw SteamUserVoteReadFailure(outcome: .failed, code: "account-mismatch", message: "Steam account differs from the account that authorized this vote query", accountID: account)
            }
            // ISteamUGC::GetUserItemVote(PublishedFileId_t), SDK 1.64 v021
            // flat ABI. No app ID is accepted by this account-scoped method.
            typealias Request = @convention(c) (UnsafeMutableRawPointer, UInt64) -> UInt64
            let request = try symbol("SteamAPI_ISteamUGC_GetUserItemVote", Request.self)
            let call = request(ugc, id)
            guard call != 0 else {
                throw SteamUserVoteReadFailure(outcome: .failed, code: "request-rejected", message: "Steam rejected the user vote query before returning an async call", accountID: account)
            }
            submitted = true
            // SDK 1.64 `GetUserItemVoteResult_t`, macOS pack(4):
            // PublishedFileId_t @0, EResult @8, bools @12/@13/@14, trailing
            // pack padding @15. The exact 3409/handle is enforced before we
            // receive this byte buffer.
            let payload = try awaitAPICall(call, expectedCallback: SteamUserVoteState.expectedCallback,
                                           permittedPayloadBytes: 16...16,
                                           deadline: Date().addingTimeInterval(timeout),
                                           label: "user vote query")
            let callbackID = try value(payload, 0, UInt64.self)
            let result = try value(payload, 8, Int32.self)
            guard callbackID == id else {
                throw SteamUserVoteReadFailure(outcome: .unconfirmed, code: "callback-item-mismatch", message: "Steam completed a different Workshop item vote query", accountID: account, requestStarted: true)
            }
            guard result == 1 else {
                // A non-OK reply is determinate only after both the exact
                // item receipt and a post-callback same-account validation.
                try validateSession()
                let proof = SteamUserVoteReadFailure.CallbackProof(callbackID: SteamUserVoteState.expectedCallback,
                                                                     itemID: callbackID, result: result,
                                                                     sessionValidatedAfterCallback: true)
                throw SteamUserVoteReadFailure(outcome: .failed, code: "result-\(result)", message: "Steam rejected the user vote query (EResult \(result))", accountID: account, requestStarted: true, callbackProof: proof)
            }
            let rawVotedUp = try value(payload, 12, UInt8.self)
            let rawVotedDown = try value(payload, 13, UInt8.self)
            let rawVoteSkipped = try value(payload, 14, UInt8.self)
            guard let state = SteamUserVoteState(rawVotedUp: rawVotedUp, rawVotedDown: rawVotedDown, rawVoteSkipped: rawVoteSkipped) else {
                throw SteamUserVoteReadFailure(outcome: .unconfirmed, code: "callback-vote-state-malformed", message: "Steam completed the vote query with non-exclusive vote flags", accountID: account, requestStarted: true)
            }
            // Do not return a vote belonging to an account which changed
            // while the callback was in flight.
            try validateSession()
            return SteamUserVote(id: id, state: state, callbackResult: result, accountID: account)
        } catch let failure as SteamUserVoteReadFailure {
            throw failure
        } catch let error as SteamNativeError {
            let code = error.code
            let uncertain = submitted || code == "account-changed"
            throw SteamUserVoteReadFailure(outcome: uncertain ? .unconfirmed : .failed,
                                           code: uncertain ? "completion-unconfirmed" : code,
                                           message: uncertain ? "Steam 未确认投票查询结果；不会返回或推断投票状态。（\(code)）" : error.description,
                                           accountID: account, requestStarted: submitted)
        } catch {
            throw SteamUserVoteReadFailure(outcome: submitted ? .unconfirmed : .failed,
                                           code: submitted ? "completion-unconfirmed" : "api-unavailable",
                                           message: submitted ? "Steam 未确认投票查询结果；不会返回或推断投票状态。" : String(describing: error),
                                           accountID: account, requestStarted: submitted)
        }
    }

    /// Request one explicit account-scoped vote mutation. The call has no
    /// retry path and performs no follow-up read: after a nonzero async handle,
    /// only the exact 3408 receipt below is a completion; any other outcome is
    /// unknown to callers until they explicitly issue a fresh `userVote` read.
    func changeUserVote(_ id: UInt64, direction: SteamUserVoteDirection, expectedAccount: UInt64, timeout: TimeInterval = 30) throws -> SteamUserVoteChange {
        guard id != 0 else {
            throw SteamUserVoteChangeFailure(outcome: .failed, code: "invalid-item", message: "Workshop item ID must be a positive Steam PublishedFileId", accountID: account)
        }
        guard expectedAccount != 0 else {
            throw SteamUserVoteChangeFailure(outcome: .failed, code: "invalid-account", message: "Expected Steam account ID must be nonzero", accountID: account)
        }
        var submitted = false
        do {
            // The expected-account fence is deliberately complete before
            // resolving or invoking SetUserItemVote. `false` passed below is
            // the SDK's explicit down-vote, never a cancel signal.
            try validateSession()
            guard account == expectedAccount else {
                throw SteamUserVoteChangeFailure(outcome: .failed, code: "account-mismatch", message: "Steam account differs from the account that authorized this vote request", accountID: account)
            }
            // ISteamUGC::SetUserItemVote(PublishedFileId_t, bool), SDK 1.64
            // v021 flat ABI. Preserve Bool here; do not substitute an Int32.
            typealias Request = @convention(c) (UnsafeMutableRawPointer, UInt64, Bool) -> UInt64
            let request = try symbol("SteamAPI_ISteamUGC_SetUserItemVote", Request.self)
            let call = request(ugc, id, direction.voteUp)
            guard call != 0 else {
                throw SteamUserVoteChangeFailure(outcome: .failed, code: "request-rejected", message: "Steam rejected the user vote request before returning an async call", accountID: account)
            }
            submitted = true
            // SDK 1.64 `SetUserItemVoteResult_t`, macOS pack(4):
            // PublishedFileId_t @0, EResult @8, bool m_bVoteUp @12; size 16.
            let payload = try awaitAPICall(call, expectedCallback: SteamUserVoteDirection.expectedCallback,
                                           permittedPayloadBytes: 16...16,
                                           deadline: Date().addingTimeInterval(timeout),
                                           label: "user vote \(direction.rawValue) request")
            let callbackID = try value(payload, 0, UInt64.self)
            let result = try value(payload, 8, Int32.self)
            let rawVotedUp = try value(payload, 12, UInt8.self)
            guard rawVotedUp == 0 || rawVotedUp == 1 else {
                throw SteamUserVoteChangeFailure(outcome: .unconfirmed, code: "callback-direction-malformed", message: "Steam completed the vote request with an invalid direction flag", accountID: account, mutationStarted: true)
            }
            let callbackVotedUp = rawVotedUp == 1
            guard callbackID == id else {
                throw SteamUserVoteChangeFailure(outcome: .unconfirmed, code: "callback-item-mismatch", message: "Steam completed a different Workshop item vote request", accountID: account, mutationStarted: true)
            }
            guard callbackVotedUp == direction.voteUp else {
                throw SteamUserVoteChangeFailure(outcome: .unconfirmed, code: "callback-direction-mismatch", message: "Steam completed a different vote direction", accountID: account, mutationStarted: true)
            }
            guard result == 1 else {
                try validateSession()
                let proof = SteamUserVoteChangeFailure.CallbackProof(callbackID: SteamUserVoteDirection.expectedCallback,
                                                                       itemID: callbackID, result: result,
                                                                       votedUp: callbackVotedUp,
                                                                       sessionValidatedAfterCallback: true)
                throw SteamUserVoteChangeFailure(outcome: .failed, code: "result-\(result)", message: "Steam rejected the user vote \(direction.rawValue) request (EResult \(result))", accountID: account, mutationStarted: true, callbackProof: proof)
            }
            try validateSession()
            return SteamUserVoteChange(id: id, direction: direction, callbackResult: result, accountID: account)
        } catch let failure as SteamUserVoteChangeFailure {
            throw failure
        } catch let error as SteamNativeError {
            let code = error.code
            let uncertain = submitted || code == "account-changed"
            throw SteamUserVoteChangeFailure(outcome: uncertain ? .unconfirmed : .failed,
                                             code: uncertain ? "completion-unconfirmed" : code,
                                             message: uncertain ? "Steam 未确认投票请求最终结果；不会自动重试，请先重新查询投票状态再决定下一步。（\(code)）" : error.description,
                                             accountID: account, mutationStarted: submitted)
        } catch {
            throw SteamUserVoteChangeFailure(outcome: submitted ? .unconfirmed : .failed,
                                             code: submitted ? "completion-unconfirmed" : "api-unavailable",
                                             message: submitted ? "Steam 未确认投票请求最终结果；不会自动重试，请先重新查询投票状态再决定下一步。" : String(describing: error),
                                             accountID: account, mutationStarted: submitted)
        }
    }

    /// Steamworks SDK 1.64, UGC v021, macOS pack(4); the layout is recorded
    /// from the development headers, not inferred from a particular item.
    private static func ugcMetadata(_ buffer: UnsafeRawPointer) -> (updated: UInt32, size: UInt64?, sizeSource: String?, score: Double?, votesUp: UInt32, votesDown: UInt32) {
        let updated = buffer.loadUnaligned(fromByteOffset: 8168, as: UInt32.self)
        let total = buffer.loadUnaligned(fromByteOffset: 9764, as: UInt64.self)
        let legacy = buffer.loadUnaligned(fromByteOffset: 9484, as: Int32.self)
        // m_flScore is part of the same recorded SDK 1.64 v021 layout used by
        // the subscription snapshot below. Keep zero: it is a confirmed zero
        // rating, unlike an omitted or malformed score.
        let rawScore = buffer.loadUnaligned(fromByteOffset: 9756, as: Float.self)
        let score = rawScore.isFinite && (0...1).contains(rawScore) ? Double(rawScore) : nil
        // These are SteamUGCDetails_t's aggregate counts, not the current
        // account's vote. The public header records them immediately before
        // m_flScore, in this same v021 / macOS pack(4) layout.
        let votesUp = buffer.loadUnaligned(fromByteOffset: 9748, as: UInt32.self)
        let votesDown = buffer.loadUnaligned(fromByteOffset: 9752, as: UInt32.self)
        // Keep unknown or implausible values out of size-dependent UI paths.
        let maximum: UInt64 = 16 * 1024 * 1024 * 1024 * 1024
        if total > 0 && total <= maximum { return (updated, total, "total_files", score, votesUp, votesDown) }
        if legacy > 0 { return (updated, UInt64(legacy), "legacy_file", score, votesUp, votesDown) }
        return (updated, nil, nil, score, votesUp, votesDown)
    }

    struct ItemDetails {
        let id: UInt64
        let updated: UInt32
        let size: UInt64?
        let sizeSource: String?
        let cached: Bool
        let state: UInt32
    }

    /// Read an individual public item through the existing signed Steam client.
    /// A cached response remains explicit and is not used as a fresh revision.
    func itemDetails(_ id: UInt64, timeout: TimeInterval = 20) throws -> ItemDetails {
        typealias Create = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>, UInt32) -> UInt64
        typealias Option = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32) -> Bool
        typealias Send = @convention(c) (UnsafeMutableRawPointer, UInt64) -> UInt64
        typealias Release = @convention(c) (UnsafeMutableRawPointer, UInt64) -> Bool
        typealias Detail = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UnsafeMutableRawPointer) -> Bool
        guard id != 0 else { throw SteamNativeError.message("Invalid Workshop item ID") }
        try validateSession()
        let create = try symbol("SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest", Create.self)
        let release = try symbol("SteamAPI_ISteamUGC_ReleaseQueryUGCRequest", Release.self)
        var requested = id
        let handle = create(ugc, &requested, 1)
        guard handle != UInt64.max else { throw SteamNativeError.message("Steam rejected the item detail query") }
        defer { _ = release(ugc, handle) }
        guard try symbol("SteamAPI_ISteamUGC_SetAllowCachedResponse", Option.self)(ugc, handle, 0) else {
            throw SteamNativeError.message("Steam could not set the item detail cache policy")
        }
        let call = try symbol("SteamAPI_ISteamUGC_SendQueryUGCRequest", Send.self)(ugc, handle)
        guard call != 0 else { throw SteamNativeError.message("Steam did not start the item detail query") }
        let result = try awaitQuery(call, deadline: Date().addingTimeInterval(timeout))
        guard result.count >= 21, try value(result, 0, UInt64.self) == handle,
              try value(result, 8, Int32.self) == 1, try value(result, 12, UInt32.self) == 1,
              try value(result, 16, UInt32.self) >= 1 else {
            throw SteamNativeError.message("Steam did not confirm the requested Workshop item")
        }
        let cached = try value(result, 20, UInt8.self) != 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16_384, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 16_384)
        guard try symbol("SteamAPI_ISteamUGC_GetQueryUGCResult", Detail.self)(ugc, handle, 0, buffer),
              buffer.loadUnaligned(as: UInt64.self) == id,
              buffer.loadUnaligned(fromByteOffset: 8, as: Int32.self) == 1,
              buffer.loadUnaligned(fromByteOffset: 20, as: UInt32.self) == Self.appID else {
            throw SteamNativeError.message("Steam item details were missing, unavailable, or for a different app")
        }
        let metadata = Self.ugcMetadata(UnsafeRawPointer(buffer))
        guard metadata.updated > 0 else { throw SteamNativeError.message("Steam item revision time was unavailable") }
        let state = try itemState(id)
        try validateSession()
        return ItemDetails(id: id, updated: metadata.updated, size: metadata.size,
                           sizeSource: metadata.sizeSource, cached: cached, state: state)
    }

    /// A single public Workshop page. Query handles are always released; no
    /// subscription, installation, voting, or account settings are changed.
    func browse(_ request: WorkshopBrowseRequest, timeout: TimeInterval = 30) throws -> [String: Any] {
        typealias Create = @convention(c) (UnsafeMutableRawPointer, Int32, Int32, UInt32, UInt32, UnsafePointer<CChar>) -> UInt64
        typealias Search = @convention(c) (UnsafeMutableRawPointer, UInt64, UnsafePointer<CChar>) -> Bool
        typealias Cache = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32) -> Bool
        typealias Send = @convention(c) (UnsafeMutableRawPointer, UInt64) -> UInt64
        typealias Release = @convention(c) (UnsafeMutableRawPointer, UInt64) -> Bool
        typealias Detail = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UnsafeMutableRawPointer) -> Bool
        typealias Preview = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UnsafeMutablePointer<CChar>, UInt32) -> Bool
        typealias TagGroup = @convention(c) (UnsafeMutableRawPointer, UInt64, UnsafeRawPointer) -> Bool
        typealias TagCount = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32) -> UInt32
        typealias Tag = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UInt32, UnsafeMutablePointer<CChar>, UInt32) -> Bool
        typealias RequiredValue = @convention(c) (UnsafeMutableRawPointer, UInt64, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Bool
        typealias ReturnValues = @convention(c) (UnsafeMutableRawPointer, UInt64, Bool) -> Bool
        typealias FirstValue = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, UInt32) -> Bool
        try validateSession()
        let create = try symbol("SteamAPI_ISteamUGC_CreateQueryAllUGCRequestCursor", Create.self)
        let release = try symbol("SteamAPI_ISteamUGC_ReleaseQueryUGCRequest", Release.self)
        // EUGCMatchingUGCType_Items=0. The consumer app is Wallpaper Engine.
        let handle = request.cursor.withCString { create(ugc, request.queryType, 0, 0, Self.appID, $0) }
        guard handle != UInt64.max else { throw SteamNativeError.message("Steam rejected the Workshop query") }
        defer { _ = release(ugc, handle) }
        if !request.query.isEmpty {
            let search = try symbol("SteamAPI_ISteamUGC_SetSearchText", Search.self)
            guard request.query.withCString({ search(ugc, handle, $0) }) else {
                throw SteamNativeError.message("Steam rejected the Workshop search text")
            }
        }
        if !request.filters.required.isEmpty {
            let add = try symbol("SteamAPI_ISteamUGC_AddRequiredTagGroup", TagGroup.self)
            for group in request.filters.required {
                let allocated = group.map { strdup($0) }
                defer { allocated.forEach { free($0) } }
                guard allocated.allSatisfy({ $0 != nil }) else { throw SteamNativeError.message("Could not allocate Workshop tags") }
                let pointers = allocated.map { $0.map { UnsafePointer<CChar>($0) } }
                let accepted = pointers.withUnsafeBufferPointer { buffer in
                    // SteamParamStringArray_t, SDK 1.64: pointer at 0, int32
                    // count at 8 on macOS arm64. Packed size is 12 bytes.
                    let encoded = UnsafeMutableRawPointer.allocate(byteCount: 12, alignment: 8)
                    defer { encoded.deallocate() }
                    encoded.storeBytes(of: buffer.baseAddress, as: UnsafePointer<UnsafePointer<CChar>?>?.self)
                    encoded.storeBytes(of: Int32(group.count), toByteOffset: 8, as: Int32.self)
                    return add(ugc, handle, UnsafeRawPointer(encoded))
                }
                guard accepted else { throw SteamNativeError.message("Steam rejected a Workshop tag group") }
            }
        }
        if !request.filters.excluded.isEmpty {
            let exclude = try symbol("SteamAPI_ISteamUGC_AddExcludedTag", Search.self)
            for tag in request.filters.excluded {
                guard tag.withCString({ exclude(ugc, handle, $0) }) else { throw SteamNativeError.message("Steam rejected an excluded Workshop tag") }
            }
        }
        if !request.filters.keyValues.isEmpty {
            let add = try symbol("SteamAPI_ISteamUGC_AddRequiredKeyValueTag", RequiredValue.self)
            let returnValues = try symbol("SteamAPI_ISteamUGC_SetReturnKeyValueTags", ReturnValues.self)
            for (key, value) in request.filters.keyValues.sorted(by: { $0.key < $1.key }) {
                let accepted = key.withCString { k in value.withCString { v in add(ugc, handle, k, v) } }
                guard accepted else { throw SteamNativeError.message("Steam rejected a required Workshop key/value tag") }
            }
            guard returnValues(ugc, handle, true) else { throw SteamNativeError.message("Steam could not return Workshop key/value tags") }
        }
        let cache = try symbol("SteamAPI_ISteamUGC_SetAllowCachedResponse", Cache.self)
        guard cache(ugc, handle, 0) else { throw SteamNativeError.message("Steam could not set the Workshop cache policy") }
        let send = try symbol("SteamAPI_ISteamUGC_SendQueryUGCRequest", Send.self)
        let call = send(ugc, handle)
        guard call != 0 else { throw SteamNativeError.message("Steam did not start the Workshop query") }
        let result = try awaitQuery(call, deadline: Date().addingTimeInterval(timeout))
        guard result.count >= 277, try value(result, 0, UInt64.self) == handle,
              try value(result, 8, Int32.self) == 1 else {
            throw SteamNativeError.message("Steam did not confirm the Workshop query")
        }
        let count = try value(result, 12, UInt32.self), total = try value(result, 16, UInt32.self)
        let cached = try value(result, 20, UInt8.self) != 0
        guard count <= 50, count <= total else { throw SteamNativeError.message("Steam returned an invalid Workshop page size") }
        let cursorBytes = result[21..<277].prefix(while: { $0 != 0 })
        guard let next = String(bytes: cursorBytes, encoding: .utf8), next.utf8.count <= 255,
              next.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw SteamNativeError.message("Steam returned an invalid Workshop cursor")
        }
        let detail = try symbol("SteamAPI_ISteamUGC_GetQueryUGCResult", Detail.self)
        let preview = try? symbol("SteamAPI_ISteamUGC_GetQueryUGCPreviewURL", Preview.self)
        let tagCount = try? symbol("SteamAPI_ISteamUGC_GetQueryUGCNumTags", TagCount.self)
        let getTag = try? symbol("SteamAPI_ISteamUGC_GetQueryUGCTag", Tag.self)
        let firstValue = request.filters.keyValues.isEmpty ? nil : try symbol("SteamAPI_ISteamUGC_GetQueryFirstUGCKeyValueTag", FirstValue.self)
        var items: [[String: Any]] = [], seen = Set<UInt64>(), unavailable = 0
        for index in 0..<count {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16_384, alignment: 8)
            defer { buffer.deallocate() }
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 16_384)
            guard detail(ugc, handle, index, buffer) else { throw SteamNativeError.message("Steam omitted a Workshop result") }
            let id = buffer.loadUnaligned(as: UInt64.self)
            let code = buffer.loadUnaligned(fromByteOffset: 8, as: Int32.self)
            let consumer = buffer.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
            guard id != 0, seen.insert(id).inserted else { throw SteamNativeError.message("Steam returned duplicate or invalid Workshop IDs") }
            guard code == 1, consumer == Self.appID else { unavailable += 1; continue }
            let bytes = UnsafeRawBufferPointer(start: buffer.advanced(by: 24), count: 129)
            let title = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            var previewBuffer = [CChar](repeating: 0, count: 2048)
            let hasPreview = previewBuffer.withUnsafeMutableBufferPointer { target in
                guard let preview, let base = target.baseAddress else { return false }
                return preview(ugc, handle, index, base, UInt32(target.count))
            }
            var previewURL = ""
            if hasPreview, let end = previewBuffer.firstIndex(of: 0), end > 0 {
                let raw = previewBuffer[..<end].map { UInt8(bitPattern: $0) }
                previewURL = String(bytes: raw, encoding: .utf8) ?? ""
            }
            let metadata = Self.ugcMetadata(UnsafeRawPointer(buffer))
            var tags: [String] = []
            if let tagCount, let getTag {
                for tagIndex in 0..<min(tagCount(ugc, handle, index), 64) {
                    var bytes = [CChar](repeating: 0, count: 256)
                    guard getTag(ugc, handle, index, tagIndex, &bytes, UInt32(bytes.count)),
                          let end = bytes.firstIndex(of: 0), end > 0,
                          let tag = String(bytes: bytes[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8),
                          tag.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { continue }
                    tags.append(tag)
                }
            }
            var item: [String: Any] = ["workshop_id": String(id), "title": title.isEmpty ? String(id) : title,
                                       "state": try itemState(id), "preview_url": previewURL, "tags": tags]
            if let firstValue {
                var values: [String: String] = [:]
                for (key, expected) in request.filters.keyValues {
                    var bytes = [CChar](repeating: 0, count: 256)
                    let found = key.withCString { firstValue(ugc, handle, index, $0, &bytes, UInt32(bytes.count)) }
                    guard found, let end = bytes.firstIndex(of: 0),
                          let value = String(bytes: bytes[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8),
                          value == expected else { throw SteamNativeError.message("Steam result did not confirm a required Workshop key/value tag") }
                    values[key] = value
                }
                item["key_values"] = values
            }
            if let size = metadata.size, let source = metadata.sizeSource { item["size_bytes"] = size; item["size_source"] = source }
            if let score = metadata.score { item["score"] = score }
            item["votes_up"] = metadata.votesUp; item["votes_down"] = metadata.votesDown
            if metadata.updated > 0 { item["time_updated"] = metadata.updated }
            items.append(item)
        }
        try validateSession()
        let hasNext = count > 0 && !next.isEmpty && next != request.cursor
        return ["status": "workshop-page", "appid": Self.appID, "source": "official_steam_api",
                "query": request.query, "sort": request.sort.rawValue, "cursor": request.cursor, "filters": request.filters.object,
                "next_cursor": hasNext ? next : "", "has_next": hasNext,
                "returned": count, "total": total, "unavailable": unavailable,
                "query_cached": cached, "items": items,
                "queried_at": ISO8601DateFormatter().string(from: Date())]
    }

    /// Read-only membership of the account's Wallpaper Engine favorites. This
    /// is separate from subscriptions; an unavailable snapshot stays unknown.
    private func favoriteIDs(deadline: Date) throws -> (ids: Set<UInt64>, cached: Bool) {
        typealias Query = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32, Int32, Int32, UInt32, UInt32, UInt32) -> UInt64
        typealias Cache = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32) -> Bool
        typealias Send = @convention(c) (UnsafeMutableRawPointer, UInt64) -> UInt64
        typealias Release = @convention(c) (UnsafeMutableRawPointer, UInt64) -> Bool
        typealias Detail = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UnsafeMutableRawPointer) -> Bool
        let query = try symbol("SteamAPI_ISteamUGC_CreateQueryUserUGCRequest", Query.self)
        let cache = try symbol("SteamAPI_ISteamUGC_SetAllowCachedResponse", Cache.self)
        let send = try symbol("SteamAPI_ISteamUGC_SendQueryUGCRequest", Send.self)
        let release = try symbol("SteamAPI_ISteamUGC_ReleaseQueryUGCRequest", Release.self)
        let detail = try symbol("SteamAPI_ISteamUGC_GetQueryUGCResult", Detail.self)
        var ids = Set<UInt64>(), expected: UInt32?, cached = false
        for page in 1...2000 {
            guard Date() < deadline else { throw SteamNativeError.message("Steam favorites query timed out") }
            // SDK 1.64: EUserUGCList_Favorited=5, TitleAsc=2, MatchingAll=-1.
            let handle = query(ugc, UInt32(truncatingIfNeeded: account), 5, -1, 2, 0, Self.appID, UInt32(page))
            guard handle != UInt64.max else { throw SteamNativeError.message("Steam rejected favorites query") }
            defer { _ = release(ugc, handle) }
            guard cache(ugc, handle, 0) else { throw SteamNativeError.message("Steam rejected favorites cache policy") }
            let call = send(ugc, handle)
            guard call != 0 else { throw SteamNativeError.message("Steam did not start favorites query") }
            let result = try awaitQuery(call, deadline: deadline)
            guard try value(result, 0, UInt64.self) == handle, try value(result, 8, Int32.self) == 1 else { throw SteamNativeError.message("Steam did not confirm favorites query") }
            let count = try value(result, 12, UInt32.self), total = try value(result, 16, UInt32.self)
            guard count <= 50, total <= 100_000, expected == nil || expected == total else { throw SteamNativeError.message("Favorites count changed during query") }
            expected = total
            let pageCached = try value(result, 20, UInt8.self) != 0
            cached = cached || pageCached
            for index in 0..<count {
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16_384, alignment: 8)
                defer { buffer.deallocate() }
                buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 16_384)
                guard detail(ugc, handle, index, buffer) else { throw SteamNativeError.message("Steam omitted a favorite") }
                let id = buffer.loadUnaligned(as: UInt64.self)
                guard id != 0, ids.insert(id).inserted else { throw SteamNativeError.message("Steam returned duplicate favorite IDs") }
            }
            if ids.count == Int(total) { return (ids, cached) }
            guard count > 0, ids.count < Int(total) else { throw SteamNativeError.message("Favorites pagination ended prematurely") }
        }
        throw SteamNativeError.message("Favorites exceeded the page limit")
    }

    /// A paged account query, cross-checked against both client snapshots.
    /// No SubscribeItem/UnsubscribeItem or other account mutation is called.
    func subscriptions(timeout: TimeInterval = 30) throws -> [String: Any] {
        typealias Query = @convention(c) (UnsafeMutableRawPointer, UInt32, Int32, Int32, Int32, UInt32, UInt32, UInt32) -> UInt64
        typealias QueryOption = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32) -> Bool
        typealias Send = @convention(c) (UnsafeMutableRawPointer, UInt64) -> UInt64
        typealias Release = @convention(c) (UnsafeMutableRawPointer, UInt64) -> Bool
        typealias Detail = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UnsafeMutableRawPointer) -> Bool
        typealias TagCount = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32) -> UInt32
        typealias Tag = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UInt32, UnsafeMutablePointer<CChar>, UInt32) -> Bool
        typealias ReturnValues = @convention(c) (UnsafeMutableRawPointer, UInt64, Bool) -> Bool
        typealias FirstValue = @convention(c) (UnsafeMutableRawPointer, UInt64, UInt32, UnsafePointer<CChar>, UnsafeMutablePointer<CChar>, UInt32) -> Bool
        // Bind both the beginning and end of a complete snapshot to the same
        // SteamID64. A caller must never receive an envelope for a session
        // whose account had already changed before querying began.
        try validateSession()
        let account = UInt32(truncatingIfNeeded: self.account)
        let makeQuery = try symbol("SteamAPI_ISteamUGC_CreateQueryUserUGCRequest", Query.self)
        let cache = try symbol("SteamAPI_ISteamUGC_SetAllowCachedResponse", QueryOption.self)
        let send = try symbol("SteamAPI_ISteamUGC_SendQueryUGCRequest", Send.self)
        let release = try symbol("SteamAPI_ISteamUGC_ReleaseQueryUGCRequest", Release.self)
        let get = try symbol("SteamAPI_ISteamUGC_GetQueryUGCResult", Detail.self)
        let tagCount = try? symbol("SteamAPI_ISteamUGC_GetQueryUGCNumTags", TagCount.self)
        let getTag = try? symbol("SteamAPI_ISteamUGC_GetQueryUGCTag", Tag.self)
        let returnValues = try? symbol("SteamAPI_ISteamUGC_SetReturnKeyValueTags", ReturnValues.self)
        let firstValue = try? symbol("SteamAPI_ISteamUGC_GetQueryFirstUGCKeyValueTag", FirstValue.self)
        let before = Set(try clientSubscriptions(includeDisabled: true))
        let enabled = Set(try clientSubscriptions(includeDisabled: false))
        let deadline = Date().addingTimeInterval(timeout)
        var items: [[String: Any]] = [], ids = Set<UInt64>(), expectedTotal: UInt32?, pages = 0, cachedPages = 0
        for page in 1...2000 {
            // EUserUGCList_Subscribed=6, MatchingAll=-1, SubscriptionDateDesc=4.
            let query = makeQuery(ugc, account, 6, -1, 4, 0, Self.appID, UInt32(page))
            guard query != UInt64.max else { throw SteamNativeError.message("Steam rejected the subscription query") }
            defer { _ = release(ugc, query) }
            guard cache(ugc, query, 0) else { throw SteamNativeError.message("Steam could not disable cached query results") }
            let hasValues = firstValue != nil && returnValues?(ugc, query, true) == true
            let call = send(ugc, query)
            guard call != 0 else { throw SteamNativeError.message("Steam did not start the subscription query") }
            let result = try awaitQuery(call, deadline: deadline)
            let matchesQuery = try value(result, 0, UInt64.self) == query
            let resultCode = try value(result, 8, Int32.self)
            let cached = try value(result, 20, UInt8.self) != 0
            guard matchesQuery, resultCode == 1 else {
                throw SteamNativeError.message("Steam subscription query was not confirmed (matching handle: \(matchesQuery), result: \(resultCode), cached: \(cached))")
            }
            // Steam may still mark a result cached after SetAllowCachedResponse(0).
            // Keep that provenance explicit; matching client snapshots establish
            // consistency, not a fresh server response or zero-latency delivery.
            if cached { cachedPages += 1 }
            let count = try value(result, 12, UInt32.self), total = try value(result, 16, UInt32.self)
            guard count <= 50, total <= 100_000, expectedTotal == nil || expectedTotal == total else {
                throw SteamNativeError.message("Steam subscription count changed or exceeded limits during pagination")
            }
            expectedTotal = total; pages += 1
            for index in 0..<count {
                // v021 SteamUGCDetails_t is < 16 KiB; use a bounded oversized
                // buffer and read only documented fields, never account IDs.
                let buffer = UnsafeMutableRawPointer.allocate(byteCount: 16_384, alignment: 8)
                defer { buffer.deallocate() }
                buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 16_384)
                guard get(ugc, query, index, buffer) else { throw SteamNativeError.message("Steam omitted an item from the subscription query") }
                let id = buffer.loadUnaligned(as: UInt64.self)
                let itemResult = buffer.loadUnaligned(fromByteOffset: 8, as: Int32.self)
                let consumer = buffer.loadUnaligned(fromByteOffset: 20, as: UInt32.self)
                guard id != 0, ids.insert(id).inserted else { throw SteamNativeError.message("Steam returned duplicate or invalid subscription IDs") }
                let titleBytes = UnsafeRawBufferPointer(start: buffer.advanced(by: 24), count: 129)
                let title = String(decoding: titleBytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                let state = try itemState(id)
                var item: [String: Any] = ["workshop_id": String(id), "title": title.isEmpty ? String(id) : title,
                    "consumer_app_id": consumer, "result": itemResult, "state": state,
                    "enabled": enabled.contains(id), "subscribed": true,
                    "needs_download": enabled.contains(id) && (state & 4 == 0 || state & 8 != 0)]
                if itemResult == 1, consumer == Self.appID {
                    let metadata = Self.ugcMetadata(UnsafeRawPointer(buffer))
                    let subscribed = buffer.loadUnaligned(fromByteOffset: 8172, as: UInt32.self)
                    item["time_updated"] = metadata.updated; item["time_subscribed"] = subscribed
                    if let score = metadata.score { item["score"] = score }
                    if let size = metadata.size { item["size_bytes"] = size; item["size_source"] = metadata.sizeSource }
                }
                // Optional metadata must never invalidate an otherwise complete
                // subscription snapshot. Omit incomplete tags for local fallback.
                if itemResult == 1, consumer == Self.appID, let tagCount, let getTag {
                    let count = tagCount(ugc, query, index)
                    if count <= 64 {
                        var tags: [String] = []
                        for tagIndex in 0..<count {
                            var bytes = [CChar](repeating: 0, count: 256)
                            guard getTag(ugc, query, index, tagIndex, &bytes, UInt32(bytes.count)),
                                  let end = bytes.firstIndex(of: 0), end > 0,
                                  let tag = String(bytes: bytes[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8),
                                  tag.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { break }
                            tags.append(tag)
                        }
                        if tags.count == Int(count) { item["tags"] = tags }
                    }
                    if hasValues, let firstValue {
                        var bytes = [CChar](repeating: 0, count: 256)
                        let found = "app_workshop_eula_version".withCString { firstValue(ugc, query, index, $0, &bytes, UInt32(bytes.count)) }
                        let value = bytes.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                        item["allow_mobile_upload"] = found && String(bytes: value, encoding: .utf8) == "3"
                    }
                }
                items.append(item)
            }
            if items.count == Int(total) { break }
            guard count > 0, items.count < Int(total) else { throw SteamNativeError.message("Steam subscription pagination ended prematurely") }
        }
        let favorites = try? favoriteIDs(deadline: min(deadline, Date().addingTimeInterval(10)))
        if let favorites {
            for index in items.indices {
                if let id = (items[index]["workshop_id"] as? String).flatMap(UInt64.init) { items[index]["favorite"] = favorites.ids.contains(id) }
            }
        }
        try validateSession()
        let after = Set(try clientSubscriptions(includeDisabled: true))
        guard before == after, ids == after, items.count == Int(expectedTotal ?? UInt32.max) else {
            throw SteamNativeError.message("Account subscriptions changed during query; result is not a complete consistent snapshot")
        }
        return ["status": "subscriptions", "appid": Self.appID, "source": "official_steam_api",
            // SteamID64 must remain a decimal string: JSON numbers commonly
            // lose precision above IEEE-754's exact integer range.
            "account_id": String(self.account),
            "snapshot_consistent": true, "server_query_confirmed": cachedPages == 0,
            "query_cached": cachedPages > 0, "cached_pages": cachedPages, "requested_cache_age_seconds": 0,
            "subscription_count": items.count, "items": items, "pages": pages,
            "queried_at": ISO8601DateFormatter().string(from: Date()), "account_changed": false,
            "favorites_confirmed": favorites != nil, "favorites_query_cached": favorites.map { $0.cached as Any } ?? NSNull(),
            "favorite_ids": favorites.map { $0.ids.sorted().map(String.init) as Any } ?? NSNull(),
            "limitations": ["This is a point-in-time account query, not proof of rendering support or zero-latency update delivery."]]
    }

    /// Waits for this exact app/item's DownloadItemResult_t before touching files.
    func download(_ id: UInt64, timeout: TimeInterval, progress: ((UInt64?, UInt64?) -> Void)? = nil) throws -> [String: Any] {
        typealias Download = @convention(c) (UnsafeMutableRawPointer, UInt64, Bool) -> Bool
        typealias Install = @convention(c) (UnsafeMutableRawPointer, UInt64, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<CChar>, UInt32, UnsafeMutablePointer<UInt32>) -> Bool
        typealias DownloadInfo = @convention(c) (UnsafeMutableRawPointer, UInt64, UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>) -> Bool
        try requireOnline()
        // Consume events already queued before this request.
        if try callbacks().contains(where: { $0.id == 704 }) {
            throw SteamNativeError.unavailable(code: "shutdown-requested", message: "Steam is shutting down")
        }
        let requestDownload = try symbol("SteamAPI_ISteamUGC_DownloadItem", Download.self)
        guard requestDownload(ugc, id, false) else {
            throw SteamNativeError.message("Official Steam rejected the download request for \(id)")
        }
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + timeout
        let getProgress = try? symbol("SteamAPI_ISteamUGC_GetItemDownloadInfo", DownloadInfo.self)
        var nextProgress = started
        var nextStateCheck = started + 3.0, requests = 1, attemptedRetry = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try requireOnline()
            for event in try callbacks() {
                if event.id == 704 { throw SteamNativeError.unavailable(code: "shutdown-requested", message: "Steam is shutting down") }
                guard event.id == 3406 else { continue }
                // macOS pack(4): app at 0, uint64 item at 4, result at 12.
                guard event.payload.count == 16,
                      try value(event.payload, 0, UInt32.self) == Self.appID,
                      try value(event.payload, 4, UInt64.self) == id else { continue }
                let code = try value(event.payload, 12, Int32.self)
                guard code == 1 else { throw SteamNativeError.message("Steam download completed with result \(code) for \(id)") }
                var size: UInt64 = 0, timestamp: UInt32 = 0
                var folder = [CChar](repeating: 0, count: 4096)
                guard try symbol("SteamAPI_ISteamUGC_GetItemInstallInfo", Install.self)(ugc, id, &size, &folder, UInt32(folder.count), &timestamp),
                      folder.contains(0), try itemState(id) & (4 | 8 | 16 | 32) == 4 else {
                    throw SteamNativeError.message("Steam callback succeeded but installed content is not yet confirmed")
                }
                let project = URL(fileURLWithPath: String(cString: folder)).appendingPathComponent("project.json")
                guard SteamLibraryIndex.location(for: project, id: String(id)) != nil else {
                    throw SteamNativeError.message("Steam download points outside registered Workshop libraries")
                }
                try validateSession()
                return ["transport": "official_steam_api", "callback": "DownloadItemResult_t", "callback_result": code,
                        "callback_appid": Self.appID, "callback_workshop_id": String(id), "project": project.path,
                        "size_on_disk": size, "steam_install_timestamp": timestamp,
                        "request_count": requests, "retry_attempted": attemptedRetry]
            }
            let now = ProcessInfo.processInfo.systemUptime
            if progress != nil, now >= nextProgress {
                nextProgress = now + 1
                var downloaded: UInt64 = 0, total: UInt64 = 0
                if let getProgress, getProgress(ugc, id, &downloaded, &total), total > 0, downloaded <= total, total <= UInt64(Int64.max) {
                    progress?(downloaded, total)
                } else { progress?(nil, nil) }
            }
            if !attemptedRetry && now >= nextStateCheck {
                nextStateCheck = now + 2.0
                let state = try itemState(id)
                if state & (4 | 8 | 16 | 32) == 4 {
                    // Some clients install the item without delivering a 3406
                    // callback for the first request. Reissue once only after
                    // Steam reports no pending download, then still wait for a
                    // matching callback before reading the install location.
                    attemptedRetry = true
                    if requestDownload(ugc, id, false) { requests += 1 }
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw SteamNativeError.message("Steam download callback timed out for \(id); Steam may still be downloading. Completion is unconfirmed.")
    }

    /// Only observes callbacks and connection health. Never mutates an account,
    /// starts a download, or treats a notification as proof of installation.
    func watch(writer: SteamEventWriter, parent: pid_t) throws {
        let lifetime = SteamWatchLifetime()
        defer { close() }
        try writer.emit("ready")
        var health = ProcessInfo.processInfo.systemUptime
        var license = health, heartbeat = health
        while getppid() == parent, parent > 1, !lifetime.shouldStop {
            var changed = Set<Int32>(), items = Set<String>(), full = false
            let events = try callbacks()
            if events.contains(where: { $0.id == 704 }) {
                try writer.emit("shutting-down", code: "shutdown-requested", callbacks: [704], full: true)
                return
            }
            if events.contains(where: { $0.id == 102 || $0.id == 103 }) {
                throw SteamNativeError.unavailable(code: "offline", message: "Steam connection callback reported unavailability")
            }
            for event in events {
                switch event.id {
                case 101:
                    changed.insert(101); full = true
                case 3418, 3405, 3406:
                    // Even an unknown payload length can only invalidate. If
                    // AppID is available it must match before any scheduling.
                    guard event.payload.count >= 4 else { changed.insert(event.id); full = true; continue }
                    guard try value(event.payload, 0, UInt32.self) == Self.appID else { continue }
                    let expected = event.id == 3418 ? 4 : event.id == 3405 ? 28 : 16
                    guard event.payload.count == expected else { changed.insert(event.id); full = true; continue }
                    if event.id == 3406, try value(event.payload, 12, Int32.self) != 1 { continue }
                    changed.insert(event.id)
                    if event.id == 3418 { full = true }
                    else {
                        let id = try value(event.payload, 4, UInt64.self)
                        if id > 0, items.count < 128 { items.insert(String(id)) } else { full = true }
                    }
                default: break
                }
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - health >= 1 || !changed.isEmpty { try requireOnline(); health = now }
            if now - license >= 30 { try validateSession(); license = now }
            if !changed.isEmpty {
                try writer.emit("invalidated", callbacks: changed.sorted(), items: items.sorted(), full: full)
            }
            if now - heartbeat >= 15 { try writer.emit("heartbeat"); heartbeat = now }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }
}
