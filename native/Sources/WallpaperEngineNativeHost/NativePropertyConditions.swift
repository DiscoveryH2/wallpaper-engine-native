import Foundation
import Darwin

enum NativePropertyConditions {
    struct Result: Sendable {
        let visible: [String: Bool]
        let errors: [String: String]
        let processID: Int
    }
    private static let queue = DispatchQueue(label: "io.wallpaper-engine-native.property-conditions", qos: .userInitiated)

    @MainActor static func evaluate(conditions: [String: String], properties: [String: Any], executable: URL) async throws -> Result {
        let request = try JSONSerialization.data(withJSONObject: ["protocol": 1, "conditions": conditions, "properties": properties])
        guard conditions.count <= 256, request.count <= 4 * 1024 * 1024 else {
            throw PropertyError.invalid("显示条件或参数内容过大。")
        }
        let invocation = Invocation(executable: executable, request: request)
        // Resume only after the worker has reaped the child. Cancellation must
        // not let application termination finish while this helper still runs.
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do { continuation.resume(returning: try invocation.run()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { invocation.cancel() }
        try Task.checkCancellation()
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              reply["protocol"] as? Int == 1, reply["ok"] as? Bool == true,
              let values = reply["visible"] as? [String: Bool], Set(values.keys) == Set(conditions.keys),
              let errors = reply["errors"] as? [String: String], Set(errors.keys).isSubset(of: Set(conditions.keys)),
              let pid = reply["pid"] as? Int, pid > 0 else {
            throw PropertyError.invalid("无法读取显示条件的结果。")
        }
        return Result(visible: values, errors: errors, processID: pid)
    }

    private final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private let executable: URL
        private let request: Data
        private var process: Process?
        private var cancelled = false
        init(executable: URL, request: Data) { self.executable = executable; self.request = request }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        private func checkCancellation() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
        func run() throws -> Data {
            let child = Process(), input = Pipe(), output = Pipe()
            child.executableURL = executable; child.arguments = ["--evaluate-property-conditions"]
            child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
            lock.lock()
            if cancelled { lock.unlock(); throw CancellationError() }
            do { try child.run(); process = child; lock.unlock() }
            catch { lock.unlock(); throw error }
            defer {
                if child.isRunning { _ = kill(child.processIdentifier, SIGKILL) }
                child.waitUntilExit()
                lock.lock(); process = nil; lock.unlock()
                try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
            }
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            let fd = output.fileHandleForReading.fileDescriptor
            let flags = fcntl(fd, F_GETFL, 0)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw PropertyError.invalid("无法读取显示条件组件。")
            }
            var message = request; message.append(10)
            try input.fileHandleForWriting.write(contentsOf: message)
            try input.fileHandleForWriting.close()
            let deadline = ProcessInfo.processInfo.systemUptime + 1.5
            var data = Data(), chunk = [UInt8](repeating: 0, count: 8192), eof = false
            while !eof {
                try checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw PropertyError.invalid("显示条件求值超时。")
                }
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count > 0 {
                    data.append(contentsOf: chunk.prefix(count))
                    guard data.count <= 1024 * 1024 else { throw PropertyError.invalid("显示条件返回内容过大。") }
                } else if count == 0 {
                    eof = true
                } else if errno == EINTR {
                    continue
                } else if errno == EAGAIN || errno == EWOULDBLOCK {
                    Thread.sleep(forTimeInterval: 0.005)
                } else { throw PropertyError.invalid("读取显示条件失败。") }
            }
            child.waitUntilExit()
            try checkCancellation()
            guard child.terminationStatus == 0, !data.isEmpty else { throw PropertyError.invalid("显示条件组件未正常结束。") }
            return data
        }
    }
}
