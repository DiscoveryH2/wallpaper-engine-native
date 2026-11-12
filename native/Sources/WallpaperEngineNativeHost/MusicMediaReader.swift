import CoreServices
import Foundation

/// Read-only Apple events taken from Music's shipped public scripting
/// dictionary. No AppleScript interpreter, MediaRemote privilege workaround,
/// playback command, library enumeration, remote URL or private database.
final class MusicMediaReader: @unchecked Sendable {
    private var cachedIdentity = ""
    private var cachedArtwork: NativeMediaArtwork?
    private var lastArtworkRead = -Double.infinity
    private static func code(_ text: String) -> OSType { text.utf8.reduce(0) { ($0 << 8) | OSType($1) } }

    static func permission(pid: pid_t, ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        guard let descriptor = target.aeDesc else { return -50 }
        return AEDeterminePermissionToAutomateTarget(descriptor, kAECoreSuite, kAEGetData, ask)
    }
    func reset() { cachedIdentity = ""; cachedArtwork = nil; lastArtworkRead = -.infinity }

    private func object(_ wanted: String, form: String, key: NSAppleEventDescriptor, container: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: Self.code(wanted)), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: Self.code(form)), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(key, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        guard let result = record.coerce(toDescriptorType: typeObjectSpecifier) else { throw NativeMediaError.invalid("无法建立当前曲目的读取请求。") }
        return result
    }
    private func property(_ code: String, container: NSAppleEventDescriptor = .null()) throws -> NSAppleEventDescriptor {
        try object("prop", form: "prop", key: NSAppleEventDescriptor(typeCode: Self.code(code)), container: container)
    }
    private func get(_ specifier: NSAppleEventDescriptor, target: NSAppleEventDescriptor, deadline: Double) throws -> NSAppleEventDescriptor {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw NativeMediaError.invalid("读取当前曲目超时。") }
        let request = NSAppleEventDescriptor(eventClass: kAECoreSuite, eventID: kAEGetData, targetDescriptor: target,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        request.setParam(specifier, forKeyword: keyDirectObject)
        let response: NSAppleEventDescriptor
        do { response = try request.sendEvent(options: [.waitForReply,.neverInteract,.dontRecord], timeout: min(0.75,remaining)) }
        catch let error as NSError {
            if error.domain == NSOSStatusErrorDomain, let code = Int32(exactly: error.code) { throw NativeMediaError.appleEvent(code) }
            throw NativeMediaError.invalid("“音乐”读取请求未完成。")
        }
        if let error = response.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
            throw NativeMediaError.appleEvent(error.int32Value)
        }
        guard let result = response.paramDescriptor(forKeyword: keyDirectObject) else { throw NativeMediaError.invalid("“音乐”没有返回当前曲目数据。") }
        return result
    }
    func read(pid: pid_t) throws -> NativeMediaSnapshot {
        let permission = Self.permission(pid: pid, ask: false)
        guard permission == 0 else { reset(); throw NativeMediaError.invalid("需要允许读取“音乐”（权限状态 \(permission)）。") }
        let target = NSAppleEventDescriptor(processIdentifier: pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let state = try get(property("pPlS"), target: target, deadline: deadline).enumCodeValue
        guard ["kPSS","kPSp","kPSP","kPSF","kPSR"].map(Self.code).contains(state) else {
            throw NativeMediaError.invalid("“音乐”返回了未识别的播放状态。")
        }
        let mapped = state == Self.code("kPSp") ? 2 : ["kPSP","kPSF","kPSR"].map(Self.code).contains(state) ? 1 : 0
        guard mapped != 0 else { reset(); return NativeMediaSnapshot(enabled: true, observed: true) }
        let track = try property("pTrk")
        func readText(_ key: String) throws -> String {
            guard let value = try get(property(key, container: track), target: target, deadline: deadline).stringValue else {
                throw NativeMediaError.invalid("“音乐”的当前曲目文字无法读取。")
            }
            // A byte bound also limits long composed Unicode characters.
            return String(decoding: value.utf8.prefix(2048), as: UTF8.self)
        }
        let identity = try readText("pPIS")
        guard !identity.isEmpty else { throw NativeMediaError.invalid("当前曲目没有稳定标识，等待下一次更新。") }
        let title = try readText("pnam"), artist = try readText("pArt")
        let duration = try get(property("pDur", container: track), target: target, deadline: deadline).doubleValue
        let position = try get(property("pPos"), target: target, deadline: deadline).doubleValue
        let now = ProcessInfo.processInfo.systemUptime
        var artwork = identity == cachedIdentity ? cachedArtwork : nil
        if identity != cachedIdentity || now - lastArtworkRead >= 5 {
            let first = try object("cArt", form: "indx", key: NSAppleEventDescriptor(int32: 1), container: track)
            do {
                let raw = try get(property("pRaw", container: first), target: target, deadline: deadline)
                artwork = try NativeMediaArtwork.decode(raw.data)
            } catch NativeMediaError.appleEvent(-1728) {
                // Only "no such object" establishes that artwork 1 is absent.
                // Timeouts/permissions/decoding failures reject the entire
                // observation so old metadata and cover stay paired.
                artwork = nil
            }
            lastArtworkRead = now
        }
        // Music may switch tracks while these separate read events are handled.
        guard try readText("pPIS") == identity,
              try get(property("pPlS"), target: target, deadline: deadline).enumCodeValue == state else {
            throw NativeMediaError.invalid("曲目或播放状态正在变化，等待下一次完整更新。")
        }
        cachedIdentity = identity; cachedArtwork = artwork
        return NativeMediaSnapshot(enabled: true, observed: true, state: mapped, identity: identity, title: title, artist: artist,
            position: position.isFinite && position >= 0 ? position : nil,
            duration: duration.isFinite && duration > 0 && duration <= 7 * 86400 ? duration : nil, artwork: artwork)
    }
}
