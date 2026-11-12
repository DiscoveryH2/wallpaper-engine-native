import Foundation
import Darwin
import CoreFoundation

/// One reader owns stdin, including nested calls during JavaScript execution.
/// Only framed JSON strings cross the callback; no host objects are exposed.
final class NativeScriptLineReader {
    private var buffer = Data()
    func readLine() throws -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                guard newline <= 4 * 1024 * 1024 else { throw ScriptFailure.invalid("Script request exceeds 4 MiB") }
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count <= 4 * 1024 * 1024 else { throw ScriptFailure.invalid("Script request exceeds 4 MiB") }
            var chunk = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count == 0 {
                guard buffer.isEmpty else { throw ScriptFailure.invalid("Truncated script request") }
                return nil
            }
            guard count > 0 else { throw ScriptFailure.invalid("Cannot read script request") }
            buffer.append(contentsOf: chunk.prefix(count))
        }
    }
}

final class NativeScriptHostTransport {
    let input = NativeScriptLineReader()
    var requestID = 0
    var ordinal = 0
    var active = false
    private(set) var failed = false

    private func integer(_ value: Any?, equals expected: Int) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue == Double(expected)
    }

    func call(_ text: String) -> String {
        do {
            guard active, !failed, requestID > 0, ordinal < 256, text.utf8.count <= 1024 * 1024,
                  var message = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw ScriptFailure.invalid("Invalid or excessive native resource request")
            }
            ordinal += 1
            message["nativeCallProtocol"] = 1; message["requestID"] = requestID; message["callID"] = ordinal
            var data = try JSONSerialization.data(withJSONObject: message)
            guard data.count < 1024 * 1024 else { throw ScriptFailure.invalid("Native request exceeds 1 MiB") }
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
            guard let reply = try input.readLine(),
                  let result = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  integer(result["nativeCallProtocol"], equals: 1),
                  integer(result["requestID"], equals: requestID), integer(result["callID"], equals: ordinal),
                  let ok = result["ok"] as? NSNumber, CFGetTypeID(ok) == CFBooleanGetTypeID() else { throw ScriptFailure.invalid("Native resource reply identity mismatch") }
            return String(decoding: reply, as: UTF8.self)
        } catch {
            failed = true
            let data = try! JSONSerialization.data(withJSONObject: ["ok": false, "error": error.localizedDescription])
            return String(decoding: data, as: UTF8.self)
        }
    }
}
