import CoreAudio
import Darwin
import Foundation

enum NativeApplicationObservationStatus: String, Sendable { case available, partial, unavailable }

struct NativeApplicationActivitySnapshot: Sendable {
    let processes: [pid_t: String]
    let processStatus: NativeApplicationObservationStatus
    let audioIOProcesses: Set<pid_t>
    let audioIOStatus: NativeApplicationObservationStatus
    let uptime: TimeInterval

    func ruleInput(events: [NativeApplicationConditionEvent] = []) -> NativeApplicationRuleInput {
        // CoreAudio's is-running flags include silent output. They may be used
        // for diagnostics, but must not be promoted to audible-session events.
        .init(runningExecutables: Set(processes.values), events: events)
    }
}

/// Read-only adapter for bounded CoreAudio property reads. No tap, microphone,
/// stream data, process path, or window contents are retained by this module.
protocol NativeAudioPropertySource {
    func byteCount(object: AudioObjectID, selector: AudioObjectPropertySelector) -> Int?
    func read(object: AudioObjectID, selector: AudioObjectPropertySelector, into buffer: UnsafeMutableRawBufferPointer) -> Int?
}

private struct NativeSystemAudioPropertySource: NativeAudioPropertySource {
    func byteCount(object: AudioObjectID, selector: AudioObjectPropertySelector) -> Int? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        return Int(size)
    }
    func read(object: AudioObjectID, selector: AudioObjectPropertySelector, into buffer: UnsafeMutableRawBufferPointer) -> Int? {
        guard let addressOfBytes = buffer.baseAddress, buffer.count > 0, buffer.count <= 65_536 else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(buffer.count)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, addressOfBytes) == noErr,
              size <= buffer.count else { return nil }
        return Int(size)
    }
}

enum NativeApplicationActivityReader {
    /// Call on a worker queue. Process identities exist only in the returned
    /// in-memory snapshot; collection does not write diagnostics or preferences.
    static func capture(includeAudioIO: Bool = false) -> NativeApplicationActivitySnapshot {
        let (processes, status) = processNames()
        var audio: (Set<pid_t>, NativeApplicationObservationStatus) = ([], .unavailable)
        if includeAudioIO, #available(macOS 14.2, *) {
            audio = audioIO(source: NativeSystemAudioPropertySource())
        }
        return .init(processes: processes, processStatus: status, audioIOProcesses: audio.0,
                     audioIOStatus: audio.1, uptime: ProcessInfo.processInfo.systemUptime)
    }

    private static func processNames() -> ([pid_t: String], NativeApplicationObservationStatus) {
        let estimate = proc_listallpids(nil, 0)
        guard estimate >= 0 else { return ([:], .unavailable) }
        var capacity = min(16_384, max(256, Int(estimate) + 256))
        var processes: [pid_t] = [], status: NativeApplicationObservationStatus = .available
        // A process may start between the size query and data read. Retry full
        // buffers, bound all allocations, and label truncation as partial.
        for attempt in 0..<3 {
            var ids = [pid_t](repeating: 0, count: capacity)
            let count = ids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
            guard count >= 0, count <= capacity else { return ([:], .unavailable) }
            processes = Array(ids.prefix(Int(count)))
            if count < capacity { break }
            if attempt == 2 || capacity == 16_384 { status = .partial; break }
            capacity = min(16_384, capacity * 2)
        }
        var names: [pid_t: String] = [:]
        for pid in processes where pid > 0 {
            var path = [CChar](repeating: 0, count: 4_096)
            let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            // A terminated process or inaccessible executable is skipped; it
            // must never borrow a display title or another process's name.
            guard count > 0, count < path.count, let end = path.firstIndex(of: 0), end > 0,
                  let decoded = String(bytes: path[..<end].map { UInt8(bitPattern: $0) }, encoding: .utf8) else {
                status = .partial; continue
            }
            let name = (decoded as NSString).lastPathComponent
            if !name.isEmpty { names[pid] = name }
        }
        return (names, status)
    }

    /// Also exercised with a fake property source for empty lists, size races,
    /// malformed byte counts, and disappearing CoreAudio process objects.
    static func uint32List(source: any NativeAudioPropertySource, object: AudioObjectID,
                           selector: AudioObjectPropertySelector) -> [UInt32]? {
        for _ in 0..<3 {
            guard let size = source.byteCount(object: object, selector: selector),
                  size >= 0, size <= 65_536, size.isMultiple(of: 4) else { return nil }
            if size == 0 { return [] } // Never dereference an empty buffer.
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes { source.read(object: object, selector: selector, into: $0) }
            guard let count else { continue }
            guard count >= 0, count <= size, count.isMultiple(of: 4) else { return nil }
            return data.withUnsafeBytes { bytes in
                stride(from: 0, to: count, by: 4).map { bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self) }
            }
        }
        return nil
    }

    private static func uint32(source: any NativeAudioPropertySource, object: AudioObjectID,
                               selector: AudioObjectPropertySelector) -> UInt32? {
        guard let values = uint32List(source: source, object: object, selector: selector), values.count == 1 else { return nil }
        return values[0]
    }

    @available(macOS 14.2, *)
    static func audioIO(source: any NativeAudioPropertySource) -> (Set<pid_t>, NativeApplicationObservationStatus) {
        guard let objects = uint32List(source: source, object: AudioObjectID(kAudioObjectSystemObject),
                                      selector: kAudioHardwarePropertyProcessObjectList) else { return ([], .unavailable) }
        var pids: Set<pid_t> = [], status: NativeApplicationObservationStatus = .available
        for object in objects {
            let input = uint32(source: source, object: object, selector: kAudioProcessPropertyIsRunningInput)
            let output = uint32(source: source, object: object, selector: kAudioProcessPropertyIsRunningOutput)
            if input == nil || output == nil { status = .partial }
            guard input == 1 || output == 1 else { continue }
            guard let pid = uint32(source: source, object: object, selector: kAudioProcessPropertyPID),
                  pid > 0, pid <= Int32.max else { status = .partial; continue }
            pids.insert(pid_t(pid))
        }
        return (pids, status)
    }
}
