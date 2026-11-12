import AppKit
import Carbon
import Foundation

/// A physical macOS virtual-key chord.  We store Carbon's stable virtual-key
/// code and its four cross-application modifiers, rather than a localized
/// label, so a saved shortcut keeps its meaning when the system language or
/// keyboard-layout display name changes.
struct NativeHotkey: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let modifierMask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    static let modifierOnlyKeyCodes: Set<UInt32> = [54, 55, 56, 58, 59, 60, 61, 62]
    static let assignableKeyCodes: Set<UInt32> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
        26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48,
        49, 50, 51, 53, 64, 65, 67, 69, 71, 75, 76, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 89,
        90, 91, 92, 96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113, 114, 115, 116, 117,
        118, 119, 120, 121, 122, 123, 124, 125, 126
    ]

    init(keyCode: UInt32, modifiers: UInt32) throws {
        guard Self.assignableKeyCodes.contains(keyCode), !Self.modifierOnlyKeyCodes.contains(keyCode),
              modifiers != 0, modifiers & ~Self.modifierMask == 0 else {
            throw NativeProfileHotkeyError.invalidHotkey
        }
        self.keyCode = keyCode; self.modifiers = modifiers
    }

    init(event: NSEvent) throws {
        var value: UInt32 = 0
        if event.modifierFlags.contains(.command) { value |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { value |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { value |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { value |= UInt32(shiftKey) }
        try self.init(keyCode: UInt32(event.keyCode), modifiers: value)
    }

    var label: String {
        let prefix = (modifiers & UInt32(controlKey) != 0 ? "⌃" : "")
            + (modifiers & UInt32(optionKey) != 0 ? "⌥" : "")
            + (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "")
            + (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "")
        return prefix + Self.keyLabel(for: keyCode)
    }

    private static func keyLabel(for code: UInt32) -> String {
        let labels: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
            11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3",
            21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
            31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K",
            41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "空格", 50: "`",
            51: "⌫", 53: "⎋", 64: "F17", 65: "⌨︎.", 67: "⌨︎*", 69: "⌨︎+", 71: "⌫", 75: "⌨︎/", 76: "⌤",
            78: "⌨︎-", 79: "F18", 80: "F19", 81: "⌨︎=", 82: "⌨︎0", 83: "⌨︎1", 84: "⌨︎2", 85: "⌨︎3", 86: "⌨︎4", 87: "⌨︎5",
            88: "⌨︎6", 89: "⌨︎7", 90: "F20", 91: "⌨︎8", 92: "⌨︎9", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
            114: "帮助", 115: "Home", 116: "PgUp", 117: "⌦", 118: "F4", 119: "End", 120: "F2", 121: "PgDn",
            122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return NativeHotkeyLabels.label(for: code) ?? labels[code] ?? "键码 \(code)"
    }
}

struct NativeProfileHotkeyBinding: Codable, Equatable, Hashable, Sendable {
    var profileName: String
    var hotkey: NativeHotkey
}

/// Enabled symbolic system shortcuts are not necessarily exclusive Carbon
/// registrations.  Inspecting this public system list prevents accepting a
/// chord that Carbon could register but macOS would still reserve for itself.
enum NativeSystemProfileHotkeys {
    static func active() -> Set<NativeHotkey> {
        var result: Set<NativeHotkey> = [
            // Cmd-Tab and Cmd-` are session switching shortcuts; keep them
            // reserved even on systems which omit them from symbolic records.
            (try? NativeHotkey(keyCode: 48, modifiers: UInt32(cmdKey))),
            (try? NativeHotkey(keyCode: 50, modifiers: UInt32(cmdKey)))
        ].compactMap { $0 }.reduce(into: Set<NativeHotkey>()) { $0.insert($1) }
        var values: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&values) == noErr,
              let list = values?.takeRetainedValue() as? [[CFString: Any]] else { return result }
        let enabled = kHISymbolicHotKeyEnabled as String as CFString
        let code = kHISymbolicHotKeyCode as String as CFString
        let modifiers = kHISymbolicHotKeyModifiers as String as CFString
        for item in list where (item[enabled] as? Bool) == true {
            guard let keyCode = item[code] as? UInt32, let mask = item[modifiers] as? UInt32,
                  let hotkey = try? NativeHotkey(keyCode: keyCode, modifiers: mask & NativeHotkey.modifierMask) else { continue }
            result.insert(hotkey)
        }
        return result
    }
}

enum NativeProfileHotkeyMutation: Equatable, Sendable {
    case keep
    case clear
    case set(NativeHotkey, removeConflictingBindings: Bool)
}

enum NativeProfileHotkeyError: LocalizedError, Equatable {
    case invalidHotkey
    case unknownProfile(String)
    case duplicateBinding(String)
    case unavailable(NativeHotkey)
    case registrationFailure
    case unreadable

    var errorDescription: String? {
        switch self {
        case .invalidHotkey: return "该热键无效，请按下一个非修饰键或清除热键。"
        case .unknownProfile(let name): return "找不到已保存的配置文件“\(name)”。"
        case .duplicateBinding(let name): return "该热键已分配给“\(name)”。"
        case .unavailable(let hotkey): return "热键 \(hotkey.label) 已被 macOS 或其他应用占用。"
        case .registrationFailure: return "macOS 无法启动全局热键服务。"
        case .unreadable: return "无法读取热键设置，原记录已保留。"
        }
    }
}

/// Keeps raw saved records intact if an older record names a profile deleted in
/// another operation.  The active view filters those dangling entries, so one
/// stale shortcut cannot prevent remaining valid profiles from loading.
@MainActor
enum NativeProfileHotkeyStore {
    static let key = "nativeProfileHotkeysV1"

    struct Saved: Codable, Equatable, Sendable {
        var format = 1
        var bindings: [NativeProfileHotkeyBinding] = []
    }

    private static func rawSaved() throws -> Saved {
        guard let object = UserDefaults.standard.object(forKey: key) else { return Saved() }
        guard let data = object as? Data, data.count <= 1024 * 1024 else { throw NativeProfileHotkeyError.unreadable }
        guard let value = try? JSONDecoder().decode(Saved.self, from: data), value.format == 1, value.bindings.count <= 1000 else {
            throw NativeProfileHotkeyError.unreadable
        }
        return value
    }

    static var hasStoredValue: Bool { UserDefaults.standard.object(forKey: key) != nil }

    private static func encoded(_ value: Saved) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 1024 * 1024 else { throw NativeProfileHotkeyError.unreadable }
        return data
    }

    /// Valid and live bindings only.  Dangling, duplicate and invalid legacy
    /// records stay in the preference payload until an explicit edit touches
    /// them, but cannot claim a system-wide hotkey.
    static func bindings(profiles: [NativeWallpaperProfile]? = nil) throws -> [NativeProfileHotkeyBinding] {
        let source: [NativeWallpaperProfile]
        if let profiles { source = profiles } else { source = try NativeProfileStore.saved().profiles }
        return try validatedBindings(try rawSaved(), profiles: source)
    }

    private static func validatedBindings(_ stored: Saved, profiles: [NativeWallpaperProfile]) throws -> [NativeProfileHotkeyBinding] {
        let known = Set(profiles.map(\.name))
        var names = Set<String>(); var chords = Set<NativeHotkey>(); var result: [NativeProfileHotkeyBinding] = []
        for binding in stored.bindings {
            // A removed profile is harmless and remains preserved as a
            // dangling record until its deletion transaction can clean it.
            guard known.contains(binding.profileName) else { continue }
            guard (try? NativeApplicationProfileTarget.validatedName(binding.profileName)) != nil,
                  (try? NativeHotkey(keyCode: binding.hotkey.keyCode, modifiers: binding.hotkey.modifiers)) != nil,
                  names.insert(binding.profileName).inserted, chords.insert(binding.hotkey).inserted else {
                // Never pick the first of two valid-looking colliding records.
                throw NativeProfileHotkeyError.unreadable
            }
            result.append(binding)
        }
        return result
    }

    /// Snapshot and validate all bindings which would be live for an intended
    /// catalog before the caller claims a system hotkey. In particular, a
    /// dangling legacy record can become live when Save introduces its exact
    /// profile name; retaining this single raw snapshot also prevents a later
    /// read from pairing a reservation with a different preference payload.
    static func validatedRawForMutation(profiles: [NativeWallpaperProfile]) throws -> Saved {
        let stored = try rawSaved()
        _ = try validatedBindings(stored, profiles: profiles)
        return stored
    }

    /// A normal profile Save deliberately leaves unreadable legacy hotkey
    /// bytes alone.  Its one exception is a formerly dangling, *valid* V1
    /// binding for a newly-created profile: that record would become live
    /// merely by committing the catalog.  Return it only when the complete
    /// V1 payload validates against the intended catalog; malformed or
    /// otherwise invalid legacy data retains the historical `.keep` path.
    static func bindingReactivatedByKeepSave(profileName: String,
                                             existingProfiles: [NativeWallpaperProfile],
                                             intendedProfiles: [NativeWallpaperProfile]) -> NativeProfileHotkeyBinding? {
        guard !Set(existingProfiles.map(\.name)).contains(profileName),
              let stored = try? rawSaved(),
              let live = try? validatedBindings(stored, profiles: intendedProfiles) else { return nil }
        return live.first { $0.profileName == profileName }
    }

    static func binding(for profileName: String) throws -> NativeProfileHotkeyBinding? {
        try bindings().first { $0.profileName == profileName }
    }

    static func binding(conflicting hotkey: NativeHotkey, excluding profileName: String? = nil) throws -> NativeProfileHotkeyBinding? {
        try bindings().first { $0.hotkey == hotkey && $0.profileName != profileName }
    }

    private static func write(_ value: Saved) throws { UserDefaults.standard.set(try encoded(value), forKey: key) }

    /// Update one target.  UI code calls the service preflight before this
    /// mutation; when a visible conflict is explicitly accepted, it asks to
    /// remove that binding immediately to mirror the reference behaviour.
    static func replaceBinding(for profileName: String, with hotkey: NativeHotkey?, removeConflictingBindings: Bool = false,
                               hotkeyService: NativeProfileHotkeyService? = nil) throws {
        let service = hotkeyService ?? NativeProfileHotkeyService.shared
        let catalog = try NativeProfileStore.saved()
        _ = try NativeApplicationProfileTarget.resolve(profileName, from: catalog.profiles)
        // This is intentionally before the accepted-overwrite removal.  A
        // damaged payload must not make the confirmation sheet mutate a prior
        // owner and then fail only after a new target has been prepared.
        var value = try validatedRawForMutation(profiles: catalog.profiles)
        if let hotkey, let crossPoolOwner = try NativeHotkeyBindingStore.conflict(for: hotkey, excluding: .profile(name: profileName)) {
            // A V1 owner is handled by the historical immediate overwrite
            // path below.  A V2 owner has no equivalent legacy dialog row;
            // reject before removing any V1 record so profile workflows see
            // the same atomic cross-type collision boundary as Settings.
            if case .profile = crossPoolOwner.target {
                // Existing V1 duplicate logic preserves its profile-specific
                // error and (when accepted) its immediate-removal semantics.
            } else {
                throw NativeProfileHotkeyError.duplicateBinding(crossPoolOwner.target.title)
            }
        }
        if let hotkey, removeConflictingBindings {
            let hasConflict = value.bindings.contains { $0.profileName != profileName && $0.hotkey == hotkey }
            if hasConflict {
                // The official confirmation revokes the prior owner now, even
                // if the user subsequently cancels the new edit.
                value.bindings.removeAll { $0.profileName != profileName && $0.hotkey == hotkey }
                try write(value); try? service.sync()
            }
        }
        let reservation = try hotkey.map { try service.reserveAvailable($0, for: profileName) }
        do {
            value.bindings.removeAll { $0.profileName == profileName }
            if let hotkey {
                if removeConflictingBindings { value.bindings.removeAll { $0.hotkey == hotkey } }
                else if let conflict = try binding(conflicting: hotkey, excluding: profileName) { throw NativeProfileHotkeyError.duplicateBinding(conflict.profileName) }
                value.bindings.append(.init(profileName: profileName, hotkey: hotkey))
            }
            try write(value)
            if let reservation { reservation.commit() } else { try? service.sync() }
        } catch {
            reservation?.cancel(); throw error
        }
    }

    static func removeBindings(forProfiles names: Set<String>, hotkeyService: NativeProfileHotkeyService? = nil) throws {
        guard !names.isEmpty, hasStoredValue else { return }
        let service = hotkeyService ?? NativeProfileHotkeyService.shared
        var value = try rawSaved(); value.bindings.removeAll { names.contains($0.profileName) }; try write(value)
        // Conflict removal is immediately visible in the original dialog; the
        // live registrar must therefore release the previous owner before a
        // deferred Save target reserves the same chord.
        try? service.sync()
    }

    /// The caller has already prepared both payloads.  There are no throwing
    /// operations after the two encodings, so the preferences cannot contain a
    /// half-validated catalog/hotkey transaction.
    static func commit(catalog: NativeProfileStore.Saved, currentName: String?, hotkeys: Saved) throws {
        let catalogEncoder = JSONEncoder(); catalogEncoder.outputFormatting = [.sortedKeys]
        let catalogData = try catalogEncoder.encode(catalog)
        guard catalogData.count <= 16 * 1024 * 1024 else { throw NativePlaylistError.invalid("保存的配置文件数据超过大小上限。") }
        let hotkeyData = try encoded(hotkeys)
        UserDefaults.standard.set(catalogData, forKey: NativeProfileStore.savedKey)
        UserDefaults.standard.set(hotkeyData, forKey: key)
        if let currentName { UserDefaults.standard.set(currentName, forKey: NativeProfileStore.currentNameKey) }
    }

    static func mutate(_ current: Saved, profileName: String, mutation: NativeProfileHotkeyMutation) throws -> Saved {
        var next = current
        switch mutation {
        case .keep: break
        case .clear: next.bindings.removeAll { $0.profileName == profileName }
        case .set(let hotkey, let removeConflicts):
            next.bindings.removeAll { $0.profileName == profileName }
            if removeConflicts { next.bindings.removeAll { $0.hotkey == hotkey } }
            else if let conflict = next.bindings.first(where: { $0.hotkey == hotkey && $0.profileName != profileName }) {
                throw NativeProfileHotkeyError.duplicateBinding(conflict.profileName)
            }
            next.bindings.append(.init(profileName: profileName, hotkey: hotkey))
        }
        return next
    }

    static func savedRawForTransaction() throws -> Saved { try rawSaved() }
}

@MainActor
protocol NativeProfileHotkeyRegistering: AnyObject {
    func install(activation: @escaping (UInt32, Bool) -> Void) throws
    func register(_ hotkey: NativeHotkey, id: UInt32) throws
    func unregister(id: UInt32)
    func uninstall()
}

@MainActor
private final class NativeCarbonProfileHotkeyRegistrar: NativeProfileHotkeyRegistering {
    private var handler: EventHandlerRef?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var activation: ((UInt32, Bool) -> Void)?

    func install(activation: @escaping (UInt32, Bool) -> Void) throws {
        self.activation = activation
        guard handler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return noErr }
            let owner = Unmanaged<NativeCarbonProfileHotkeyRegistrar>.fromOpaque(data).takeUnretainedValue()
            owner.receive(event)
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw NativeProfileHotkeyError.registrationFailure }
    }

    func register(_ hotkey: NativeHotkey, id: UInt32) throws {
        var ref: EventHotKeyRef?
        let identity = EventHotKeyID(signature: OSType(0x57454E48), id: id) // WENH
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, identity, GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else { throw NativeProfileHotkeyError.unavailable(hotkey) }
        refs[id] = ref
    }

    func unregister(id: UInt32) {
        guard let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
    }

    func uninstall() {
        for id in Array(refs.keys) { unregister(id: id) }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        activation = nil
    }

    private func receive(_ event: EventRef) {
        var identity = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identity) == noErr,
              identity.signature == OSType(0x57454E48) else { return }
        activation?(identity.id, GetEventKind(event) == UInt32(kEventHotKeyPressed))
    }
}

/// A successfully reserved Carbon registration.  Store code must persist the
/// prepared profile/hotkey payload before asking its service to commit it; this
/// makes the commit non-throwing after the platform has accepted the chord.
@MainActor
final class NativeProfileHotkeyReservation {
    fileprivate weak var service: NativeProfileHotkeyService?
    fileprivate let id: UInt32?
    fileprivate let target: NativeHotkeyTarget
    fileprivate let hotkey: NativeHotkey
    fileprivate var finished = false

    fileprivate init(service: NativeProfileHotkeyService, id: UInt32?, target: NativeHotkeyTarget, hotkey: NativeHotkey) {
        self.service = service; self.id = id; self.target = target; self.hotkey = hotkey
    }

    func cancel() { service?.cancel(self) }
    func commit() { service?.commit(self) }
}

/// The settings model intentionally represents an empty chord as `nil`, but
/// a Carbon registration can never do so.  Keep the service's live registry
/// in this nonoptional form; conversion happens only after the store has
/// produced its active, nonempty snapshot.
@MainActor
private struct NativeRegisteredHotkeyBinding: Equatable {
    let target: NativeHotkeyTarget
    let hotkey: NativeHotkey

    init(_ binding: NativeHotkeyBinding) throws {
        guard let hotkey = binding.hotkey else { throw NativeProfileHotkeyError.unreadable }
        self.target = binding.target
        self.hotkey = hotkey
    }

    init(target: NativeHotkeyTarget, hotkey: NativeHotkey) {
        self.target = target
        self.hotkey = hotkey
    }
}

/// Carbon uses exclusive registration and checks enabled symbolic system keys,
/// without Accessibility, Input Monitoring, or an event tap. macOS allows an
/// older non-exclusive registration in another process to coexist, so a zero
/// status is not a universal claim that no other app chose the same shortcut.
/// The service observes only the profile catalog, saved playlists, and the
/// V1/V2 hotkey payloads.  It keeps stable IDs for unchanged entries, so
/// playlist progress writes do not reset held state.
@MainActor
final class NativeProfileHotkeyService {
    static let shared = NativeProfileHotkeyService()

    /// Legacy callback retained for the 0.213 profile activation path.
    var onActivate: ((String, NativeHotkey) -> Void)?
    /// Shared-pool callback for 0.214 fixed and dynamic actions. A profile
    /// press invokes both this and the legacy callback while both are set.
    var onActivateTarget: ((NativeHotkeyTarget, NativeHotkey) -> Void)?
    var onError: ((String) -> Void)?
    private let registrar: NativeProfileHotkeyRegistering
    private var started = false
    private var recordingDepth = 0
    private var needsSyncAfterRecording = false
    private var nextID: UInt32 = 1
    private var registered: [UInt32: NativeRegisteredHotkeyBinding] = [:]
    private var reserved: [UInt32: NativeProfileHotkeyReservation] = [:]
    private var held = Set<UInt32>()
    private var activeFingerprint: Data?
    private var rejectedFingerprint: Data?
    private var defaultsObserver: NSObjectProtocol?
    private let symbolicHotkeys: () -> Set<NativeHotkey>

    init(registrar: NativeProfileHotkeyRegistering? = nil,
         symbolicHotkeys: @escaping () -> Set<NativeHotkey> = NativeSystemProfileHotkeys.active) {
        self.registrar = registrar ?? NativeCarbonProfileHotkeyRegistrar(); self.symbolicHotkeys = symbolicHotkeys
    }

    deinit { if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) } }

    func start() {
        guard !started else { return }
        do {
            try registrar.install { [weak self] id, pressed in self?.receive(id: id, pressed: pressed) }
            started = true
            defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.synchronizeIfChanged() }
            }
            try sync()
        } catch { onError?(error.localizedDescription) }
    }

    func stop() {
        for id in Array(registered.keys) { registrar.unregister(id: id) }
        for id in Array(reserved.keys) { registrar.unregister(id: id) }
        registered.removeAll(); reserved.removeAll(); held.removeAll(); activeFingerprint = nil; rejectedFingerprint = nil; recordingDepth = 0; needsSyncAfterRecording = false
        registrar.uninstall(); started = false
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver); self.defaultsObserver = nil }
    }

    /// A recorder must release registered chords while focused; otherwise the
    /// Carbon handler can consume the very chord the AppKit field is recording.
    func beginRecording() {
        recordingDepth += 1
        guard recordingDepth == 1 else { return }
        held.removeAll()
        for id in Array(registered.keys) { registrar.unregister(id: id) }
        registered.removeAll(); activeFingerprint = nil
    }

    func endRecording() {
        guard recordingDepth > 0 else { return }
        recordingDepth -= 1
        guard recordingDepth == 0 else { return }
        held.removeAll()
        needsSyncAfterRecording = false
        do { try sync(force: true) } catch { onError?(error.localizedDescription) }
    }

    /// A temporary registration remains reserved until `commit(_:)`, avoiding
    /// a system-conflict race between UI validation and the preference write.
    /// Callers normally end field recording immediately after a valid capture.
    /// Reserves a chord for the complete V1+V2 target domain.  The profile
    /// overload below preserves every 0.213 caller while ensuring those
    /// callers also see a fixed/wallpaper/playlist collision before they
    /// persist anything.
    func reserveAvailable(_ hotkey: NativeHotkey, for rawTarget: NativeHotkeyTarget) throws -> NativeProfileHotkeyReservation {
        let target = try rawTarget.validatedSyntax()
        func ownerName(_ owner: NativeHotkeyTarget) -> String {
            // Preserve the legacy profile API's exact-name error payload.
            if case .profile(let name) = owner { return name }
            return owner.title
        }
        guard !symbolicHotkeys().contains(hotkey) else { throw NativeProfileHotkeyError.unavailable(hotkey) }
        if let conflict = try NativeHotkeyBindingStore.conflict(for: hotkey, excluding: target) {
            throw NativeProfileHotkeyError.duplicateBinding(ownerName(conflict.target))
        }
        if let existing = registered.first(where: { $0.value.hotkey == hotkey }) {
            guard existing.value.target == target else { throw NativeProfileHotkeyError.duplicateBinding(ownerName(existing.value.target)) }
            return .init(service: self, id: nil, target: target, hotkey: hotkey)
        }
        if let existing = reserved.first(where: { $0.value.hotkey == hotkey }) {
            guard existing.value.target == target else { throw NativeProfileHotkeyError.duplicateBinding(ownerName(existing.value.target)) }
            return existing.value
        }
        guard started else { return .init(service: self, id: nil, target: target, hotkey: hotkey) }
        let id = nextRegistrationID()
        do { try registrar.register(hotkey, id: id) }
        catch { throw NativeProfileHotkeyError.unavailable(hotkey) }
        let reservation = NativeProfileHotkeyReservation(service: self, id: id, target: target, hotkey: hotkey)
        reserved[id] = reservation
        return reservation
    }

    func reserveAvailable(_ hotkey: NativeHotkey, for profileName: String) throws -> NativeProfileHotkeyReservation {
        try reserveAvailable(hotkey, for: .profile(name: profileName))
    }

    /// Compatibility preflight for callers that do not need a reservation.
    func validateAvailable(_ hotkey: NativeHotkey, for target: NativeHotkeyTarget) throws {
        let reservation = try reserveAvailable(hotkey, for: target); reservation.cancel()
    }

    func validateAvailable(_ hotkey: NativeHotkey, for profileName: String) throws {
        try validateAvailable(hotkey, for: .profile(name: profileName))
    }

    /// Must be called only after a no-throw persistence commit that contains
    /// this exact profile name and chord.  It cannot fail because Carbon has
    /// already registered the reservation.
    func commit(_ reservation: NativeProfileHotkeyReservation) {
        guard reservation.service === self, !reservation.finished else { return }
        reservation.finished = true
        if let id = reservation.id {
            reserved.removeValue(forKey: id)
            let replacedIDs = registered.compactMap { oldID, value in
                value.target == reservation.target || value.hotkey == reservation.hotkey ? oldID : nil
            }
            for oldID in replacedIDs {
                registrar.unregister(id: oldID); registered.removeValue(forKey: oldID); held.remove(oldID)
            }
            if recordingDepth == 0 { registered[id] = .init(target: reservation.target, hotkey: reservation.hotkey) }
            else { registrar.unregister(id: id); needsSyncAfterRecording = true }
        }
        synchronizeIfChanged()
    }

    fileprivate func cancel(_ reservation: NativeProfileHotkeyReservation) {
        guard reservation.service === self, !reservation.finished else { return }
        reservation.finished = true
        if let id = reservation.id { reserved.removeValue(forKey: id); registrar.unregister(id: id) }
    }

    /// Registers the exact current catalog.  New chords are added before old
    /// unrelated bindings are removed; if a platform rejection occurs, stable
    /// existing registrations survive unchanged.  A same-chord ownership move
    /// is briefly released and restored on failure because Carbon allows only
    /// one owner for that chord.
    func sync(force: Bool = false) throws {
        guard started else { return }
        let snapshot = try desiredSnapshot()
        if recordingDepth > 0 { needsSyncAfterRecording = true; return }
        guard force || (snapshot.fingerprint != activeFingerprint && snapshot.fingerprint != rejectedFingerprint) else { return }
        let desired = snapshot.bindings
        let unchanged = Set(registered.compactMap { desired.contains($0.value) ? $0.key : nil })
        let additions = desired.filter { binding in !registered.values.contains(binding) }
        let releasing = registered.filter { id, binding in
            !unchanged.contains(id) && additions.contains { $0.hotkey == binding.hotkey }
        }
        var added: [UInt32: NativeRegisteredHotkeyBinding] = [:], failures: [Error] = []
        for binding in additions {
            let displaced = releasing.filter { $0.value.hotkey == binding.hotkey }
            for (id, _) in displaced { registrar.unregister(id: id) }
            do {
                guard !symbolicHotkeys().contains(binding.hotkey) else { throw NativeProfileHotkeyError.unavailable(binding.hotkey) }
                let id = nextRegistrationID(); try registrar.register(binding.hotkey, id: id); added[id] = binding
            } catch {
                failures.append(error)
                for (id, old) in displaced { try? registrar.register(old.hotkey, id: id) }
            }
        }
        let retainedIDs = Set(unchanged).union(releasing.compactMap { id, old in
            additions.contains(where: { $0.hotkey == old.hotkey }) && !added.values.contains(where: { $0.hotkey == old.hotkey }) ? id : nil
        })
        let removedIDs = registered.keys.filter { !retainedIDs.contains($0) }
        for id in removedIDs { registrar.unregister(id: id) }
        for id in removedIDs { registered.removeValue(forKey: id); held.remove(id) }
        for (id, binding) in added { registered[id] = binding }
        activeFingerprint = snapshot.fingerprint; rejectedFingerprint = nil
        if let failure = failures.first { throw failure }
    }

    private func synchronizeIfChanged() {
        guard started else { return }
        do { try sync() } catch { onError?(error.localizedDescription) }
    }

    private func desiredSnapshot() throws -> (bindings: [NativeRegisteredHotkeyBinding], fingerprint: Data) {
        let profiles = try NativeProfileStore.saved().profiles
        let playlists = try NativePlaylistStore.saved().lists
        let bindings = try NativeHotkeyBindingStore.activeBindings(profiles: profiles, playlists: playlists).map {
            try NativeRegisteredHotkeyBinding($0)
        }
        let profileData = UserDefaults.standard.data(forKey: NativeProfileStore.savedKey) ?? Data()
        let profileHotkeyData = UserDefaults.standard.data(forKey: NativeProfileHotkeyStore.key) ?? Data()
        let generalHotkeyData = UserDefaults.standard.data(forKey: NativeHotkeyBindingStore.key) ?? Data()
        let playlistData = UserDefaults.standard.data(forKey: NativePlaylistStore.savedKey) ?? Data()
        var fingerprint = Data([profileData.isEmpty ? 0 : 1]); fingerprint.append(profileData)
        fingerprint.append(profileHotkeyData.isEmpty ? 0 : 1); fingerprint.append(profileHotkeyData)
        fingerprint.append(generalHotkeyData.isEmpty ? 0 : 1); fingerprint.append(generalHotkeyData)
        fingerprint.append(playlistData.isEmpty ? 0 : 1); fingerprint.append(playlistData)
        return (bindings, fingerprint)
    }

    private func nextRegistrationID() -> UInt32 {
        defer { nextID &+= 1; if nextID == 0 { nextID = 1 } }
        return nextID
    }

    private func receive(id: UInt32, pressed: Bool) {
        guard let binding = registered[id] else { return }
        if pressed {
            guard held.insert(id).inserted, recordingDepth == 0 else { return }
            onActivateTarget?(binding.target, binding.hotkey)
            if case .profile(let profileName) = binding.target { onActivate?(profileName, binding.hotkey) }
        } else { held.remove(id) }
    }
}
