import Foundation

/// Cooperative cancellation around synchronous framework calls. Cancelling the
/// awaiter is immediate; an OS file call already in progress may finish later.
final class NativeResourceCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

private final class NativeResourceCompletion<Value: Sendable>: @unchecked Sendable {
    let cancellation = NativeResourceCancellation()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let waiting = continuation; continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }

    func cancel() { cancellation.cancel(); finish(.failure(CancellationError())) }
}

enum NativeResourceWork {
    static func run<Value: Sendable>(on queue: DispatchQueue,
        _ operation: @escaping @Sendable (NativeResourceCancellation) throws -> Value) async throws -> Value {
        let completion = NativeResourceCompletion<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.install(continuation)
                queue.async {
                    do {
                        try completion.cancellation.check()
                        let value = try operation(completion.cancellation)
                        try completion.cancellation.check()
                        completion.finish(.success(value))
                    } catch { completion.finish(.failure(error)) }
                }
            }
        } onCancel: { completion.cancel() }
    }
}
