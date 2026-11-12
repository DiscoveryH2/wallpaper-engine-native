import Foundation
import Darwin

/// Private progress messages carry no paths or account information. They never
/// establish installation or permission; only the final verified receipt does.
struct SteamDownloadProgress: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case checking, downloading, confirming }
    let schema: Int
    let appid: UInt32
    let sequence: UInt64
    let workshopID: String
    let phase: Phase
    let downloaded: UInt64?
    let total: UInt64?

    func valid(for id: String) -> Bool {
        guard schema == 1, appid == 431960, sequence > 0, sequence <= 100_000,
              workshopID == id, UInt64(id).map({ $0 > 0 }) == true else { return false }
        if let downloaded, let total {
            return phase == .downloading && total > 0 && downloaded <= total && total <= UInt64(Int64.max)
        }
        return downloaded == nil && total == nil
    }
}

final class SteamDownloadProgressWriter {
    private let id: String
    private var sequence: UInt64 = 0
    init(id: String) { self.id = id }
    func emit(_ phase: SteamDownloadProgress.Phase, downloaded: UInt64? = nil, total: UInt64? = nil) {
        sequence += 1
        let message = SteamDownloadProgress(schema: 1, appid: 431960, sequence: sequence, workshopID: id, phase: phase, downloaded: downloaded, total: total)
        guard message.valid(for: id), var data = try? JSONEncoder().encode(message), data.count <= 8192 else { return }
        data.append(10)
        try? FileHandle.standardError.write(contentsOf: data)
    }
}

enum SteamHelperOutput {
    /// Drain even excessive output so a full pipe cannot deadlock the child.
    static func readResult(_ handle: FileHandle) -> Data? {
        var result = Data(), exceeded = false
        var bytes = [UInt8](repeating: 0, count: 8192)
        defer { try? handle.close() }
        while true {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; return nil }
            if !exceeded, result.count + count <= 8 * 1024 * 1024 { result.append(contentsOf: bytes.prefix(count)) }
            else { result.removeAll(keepingCapacity: false); exceeded = true }
        }
        return exceeded ? nil : result
    }

    static func readProgress(_ handle: FileHandle, id: String, receive: (SteamDownloadProgress) -> Void) {
        var tail = Data(), discardLine = false, consumed = 0, sequence: UInt64 = 0
        var bytes = [UInt8](repeating: 0, count: 8192)
        defer { try? handle.close() }
        while true {
                let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; break }
                consumed = min(4 * 1024 * 1024 + 1, consumed + count)
                guard consumed <= 4 * 1024 * 1024 else { tail.removeAll(); continue }
                for byte in bytes.prefix(count) {
                    if byte == 10 {
                        if !discardLine, let event = try? JSONDecoder().decode(SteamDownloadProgress.self, from: tail),
                           event.valid(for: id), event.sequence > sequence {
                            sequence = event.sequence; receive(event)
                        }
                        tail.removeAll(keepingCapacity: true); discardLine = false
                    } else if !discardLine {
                        if tail.count < 8192 { tail.append(byte) }
                        else { tail.removeAll(keepingCapacity: true); discardLine = true }
                    }
                }
        }
    }
}
