import Darwin
import Foundation

// Development-only reader for the official Steam installation's flat API.
// Does not bundle Valve's library, write subscriptions, or request downloads.
enum ConnectionError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { return text }; return "Steam connection unavailable" }
}

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

let steamRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
let library = steamRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/Frameworks/Steam Helper.app/Contents/MacOS/libsteam_api.dylib")

do {
    setenv("SteamAppId", "431960", 1)
    setenv("SteamGameId", "431960", 1)
    guard let handle = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
        throw ConnectionError.message("Official Steam API library could not be loaded: " + String(cString: dlerror()))
    }
    // Keep the library mapped until process exit. Steam owns internal threads.
    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else { throw ConnectionError.message("Official Steam API lacks " + name) }
        return unsafeBitCast(pointer, to: type)
    }
    /// Newest exported accessor wins: Valve removes the previous version when
    /// it bumps an interface, and the flat wrappers in this same library were
    /// compiled against the newest one it ships.
    func interface(_ prefix: String) throws -> Interface {
        for version in stride(from: 64, through: 0, by: -1) {
            if let pointer = dlsym(handle, String(format: "%@%03d", prefix, version)) {
                return unsafeBitCast(pointer, to: Interface.self)
            }
        }
        throw ConnectionError.message("Official Steam API exposes no " + prefix + "NNN accessor")
    }
    typealias Init = @convention(c) (UnsafeMutablePointer<CChar>?) -> Int32
    typealias VoidCall = @convention(c) () -> Void
    typealias Interface = @convention(c) () -> UnsafeMutableRawPointer?
    typealias BoolCall = @convention(c) (UnsafeMutableRawPointer) -> Bool
    typealias UIntCall = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    typealias OwnsApp = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Bool
    typealias Count = @convention(c) (UnsafeMutableRawPointer, Bool) -> UInt32
    typealias Items = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt64>?, UInt32, Bool) -> UInt32
    typealias ItemState = @convention(c) (UnsafeMutableRawPointer, UInt64) -> UInt32
    let initialize = try symbol("SteamAPI_InitFlat", as: Init.self)
    let shutdown = try symbol("SteamAPI_Shutdown", as: VoidCall.self)
    let callbacks = try symbol("SteamAPI_RunCallbacks", as: VoidCall.self)
    var error = [CChar](repeating: 0, count: 1024)
    let initialized = initialize(&error)
    guard initialized == 0 else {
        emit(["status": "unconfirmed", "library": library.path, "initialization_result": initialized, "reason": String(cString: error)])
        exit(1)
    }
    defer { shutdown() }
    guard let user = try interface("SteamAPI_SteamUser_v")(),
          let utils = try interface("SteamAPI_SteamUtils_v")(),
          let apps = try interface("SteamAPI_SteamApps_v")(),
          let ugc = try interface("SteamAPI_SteamUGC_v")() else {
        throw ConnectionError.message("Official Steam API interface is unavailable")
    }
    let appID = try symbol("SteamAPI_ISteamUtils_GetAppID", as: UIntCall.self)(utils)
    let loggedOn = try symbol("SteamAPI_ISteamUser_BLoggedOn", as: BoolCall.self)
    let owns = try symbol("SteamAPI_ISteamApps_BIsSubscribedApp", as: OwnsApp.self)(apps, 431960)
    guard appID == 431960, owns, loggedOn(user) else {
        emit(["status": "unconfirmed", "appid": appID, "owns_app": owns, "logged_on": loggedOn(user), "reason": "Steam did not confirm an online licensed Wallpaper Engine session"])
        exit(1)
    }
    let countItems = try symbol("SteamAPI_ISteamUGC_GetNumSubscribedItems", as: Count.self)
    let getItems = try symbol("SteamAPI_ISteamUGC_GetSubscribedItems", as: Items.self)
    let state = try symbol("SteamAPI_ISteamUGC_GetItemState", as: ItemState.self)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline { callbacks(); Thread.sleep(forTimeInterval: 0.05) }
    let count = countItems(ugc, true)
    guard count <= 100_000 else { throw ConnectionError.message("Subscription list exceeds the reader's 100,000-item limit") }
    var ids = [UInt64](repeating: 0, count: max(1, Int(count)))
    let returned = getItems(ugc, &ids, UInt32(ids.count), true)
    guard returned <= ids.count, loggedOn(user), countItems(ugc, true) == returned else {
        throw ConnectionError.message("Subscription list changed or Steam disconnected while reading")
    }
    let known: [UInt64] = [1548688862, 900945540, 1909832184, 3172483791, 959093204, 2134765860]
    emit(["status": "client_snapshot", "appid": appID, "owns_app": owns, "logged_on": true,
          "library": library.path, "ugc_interface": "v021", "include_locally_disabled": true,
          "subscription_count": returned, "subscriptions": ids.prefix(Int(returned)).map { String($0) },
          "known_item_states": known.map { ["workshop_id": String($0), "state": state(ugc, $0)] as [String: Any] },
          "server_query_confirmed": false, "download_requested": false,
          "limitations": ["This is the official client's current subscription snapshot; a server query and change callbacks are not implemented by this reader."]])
} catch {
    emit(["status": "unconfirmed", "reason": String(describing: error)])
    exit(1)
}
