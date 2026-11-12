import AppKit
import Darwin
import Foundation

/// Owns exactly one long-lived observer, independently of serialized requests.
/// Every process/reader/watchdog carries a generation; only the current one may
/// change connection state. Steam itself is never started or terminated here.
@MainActor
final class SteamEventMonitor {
    var onState: ((String, Bool) -> Void)?
    var onSessionInvalidated: (() -> Void)?
    /// A callback is only a reason to recheck; it is never an install receipt.
    /// `nil` represents a newly ready session rather than an item event.
    var onContentInvalidated: ((SteamEvent?) -> Void)?
    private(set) var isConnected = false
    private(set) var description = "Steam：正在检查连接…"
    private(set) var clientPID: pid_t?
    private var enabled = false
    private var stopped = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var process: Process?
    private var generation: UInt64 = 0
    private var ready = false
    private var terminal = false
    private var sequence: UInt64 = 0
    private var lastFrame: TimeInterval = 0
    private var healthyHeartbeats = 0
    private var failures = 0
    private var retryAt: TimeInterval = 0
    private var shuttingDownPID: pid_t?
    private let reader = DispatchQueue(label: "io.wallpaper-engine-native.steam-stream", qos: .utility)

    func configure(automatic: Bool) {
        guard !stopped else { return }
        if timer == nil {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tick() }
                })
            }
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        if enabled != automatic {
            enabled = automatic
            // Turning automatic monitoring on or off is a local scheduling
            // preference, not evidence that the Steam account/session changed.
            // In particular, do not revoke an already-confirmed manual save
            // while it is at the small current-pointer commit boundary.
            stopWorker()
            retryAt = 0
        }
        tick()
    }

    private func setState(_ text: String, connected: Bool = false) {
        guard description != text || isConnected != connected else { return }
        description = text; isConnected = connected
        fputs("Steam connection: \(text)\n", stderr)
        onState?(text, connected)
    }

    private func invalidateSession() {
        isConnected = false
        onSessionInvalidated?()
    }

    private func tick() {
        guard !stopped else { return }
        let clients = NSRunningApplication.runningApplications(withBundleIdentifier: "com.valvesoftware.steam").filter { !$0.isTerminated }
        let nextPID = clients.first(where: { $0.processIdentifier == clientPID })?.processIdentifier
            ?? clients.last?.processIdentifier
        if nextPID != clientPID {
            clientPID = nextPID
            if shuttingDownPID != nextPID { shuttingDownPID = nil }
            invalidateSession(); stopWorker(); retryAt = 0
        }
        guard enabled else { setState("Steam：自动同步已关闭，可手动同步"); return }
        guard let clientPID else { setState("Steam：客户端未运行，打开 Steam 后自动连接"); return }
        guard shuttingDownPID != clientPID else { setState("Steam：正在退出，等待客户端结束"); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let process {
            if !terminal, now - lastFrame > 45 {
                fail("Steam：监听超时，等待重连", worker: process, token: generation)
            }
            return
        }
        guard now >= retryAt else { return }
        launch(client: clientPID)
    }

    private func launch(client: pid_t) {
        guard process == nil, enabled, !stopped,
              let helper = Bundle.main.url(forResource: "we-workshop", withExtension: nil, subdirectory: "Tools") else { return }
        generation += 1
        let token = generation, worker = Process(), pipe = Pipe()
        sequence = 0; ready = false; terminal = false; healthyHeartbeats = 0
        lastFrame = ProcessInfo.processInfo.systemUptime
        // Starting or restarting our own observer does not prove that Steam's
        // account/session changed. Real PID changes, watcher failures,
        // unavailable/shutdown frames and explicit stop paths invalidate in
        // their respective fail-closed branches.
        setState("Steam：正在连接…")
        worker.executableURL = helper; worker.arguments = ["watch"]
        worker.standardOutput = pipe; worker.standardError = FileHandle.nullDevice
        process = worker
        do { try worker.run() }
        catch {
            process = nil; scheduleRetry()
            setState("Steam：无法启动监听，等待重连")
            return
        }
        pipe.fileHandleForWriting.closeFile()
        fputs("Steam watcher started: pid=\(worker.processIdentifier), generation=\(token), client=\(client)\n", stderr)
        reader.async { [weak self] in
            var tail = Data(), bytes = [UInt8](repeating: 0, count: 8192), invalid = false
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            readLoop: while true {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count == 0 { break }
                if count < 0 { if errno == EINTR { continue }; invalid = true; break }
                tail.append(contentsOf: bytes.prefix(count))
                while let newline = tail.firstIndex(of: 10) {
                    let length = tail.distance(from: tail.startIndex, to: newline)
                    guard length > 0, length < SteamEvent.maximumLine else { invalid = true; break readLoop }
                    let line = Data(tail.prefix(length))
                    tail.removeSubrange(tail.startIndex...newline)
                    guard let event = try? JSONDecoder().decode(SteamEvent.self, from: line) else { invalid = true; break readLoop }
                    // Back-pressure the pipe: never accumulate unbounded main
                    // queue callbacks while the UI is busy preparing a scene.
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated { self?.receive(event, worker: worker, token: token, client: client) }
                    }
                }
                if tail.count >= SteamEvent.maximumLine { invalid = true; break }
            }
            if !tail.isEmpty { invalid = true }
            if invalid {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.fail("Steam：监听数据无效，等待重连", worker: worker, token: token) }
                }
            }
            pipe.fileHandleForReading.closeFile()
            worker.waitUntilExit()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finished(worker, token: token) }
            }
        }
    }

    private func receive(_ event: SteamEvent, worker: Process, token: UInt64, client: pid_t) {
        guard !stopped, enabled, process === worker, generation == token, clientPID == client else { return }
        guard !terminal, event.sequence == sequence + 1,
              ready || event.kind == "ready" || event.kind == "unavailable",
              !(ready && event.kind == "ready") else {
            fail("Steam：监听顺序无效，等待重连", worker: worker, token: token); return
        }
        sequence = event.sequence; lastFrame = ProcessInfo.processInfo.systemUptime
        switch event.kind {
        case "ready":
            ready = true
            setState("Steam：已连接，正在监听订阅和安装变化", connected: true)
            onContentInvalidated?(nil)
        case "heartbeat":
            healthyHeartbeats += 1
            if healthyHeartbeats >= 2 { failures = 0 }
            fputs("Steam watcher heartbeat: generation=\(token), sequence=\(sequence)\n", stderr)
        case "invalidated":
            fputs("Steam callback invalidation: ids=\(event.callbacks), items=\(event.item_ids.count), full=\(event.full_reconcile)\n", stderr)
            onContentInvalidated?(event)
        case "shutting-down":
            terminal = true; shuttingDownPID = client
            invalidateSession()
            setState("Steam：正在退出，等待客户端结束")
            // The helper closes its API normally. Only if it fails to exit do
            // we terminate that owned worker; no immediate same-PID reconnect.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak worker] in
                guard let self, let worker, self.process === worker, self.generation == token else { return }
                self.stopWorker()
            }
        case "unavailable":
            if event.code == "shutdown-requested" { shuttingDownPID = client }
            let reason: String
            switch event.code {
            case "client-not-running": reason = "客户端未运行"
            case "offline": reason = "账号连接暂不可用"
            case "account-changed": reason = "账号已变化，重新确认订阅"
            case "license-unconfirmed": reason = "Wallpaper Engine 许可尚未确认"
            case "shutdown-requested": reason = "正在退出"
            default: reason = "接口暂不可用"
            }
            fail("Steam：\(reason)，等待连接恢复", worker: worker, token: token)
        default: fail("Steam：监听数据无效，等待重连", worker: worker, token: token)
        }
    }

    private func scheduleRetry() {
        failures = min(failures + 1, 5)
        let delay: TimeInterval = [5, 15, 30, 60, 60][failures - 1]
        retryAt = ProcessInfo.processInfo.systemUptime + delay
    }

    private func fail(_ text: String, worker: Process, token: UInt64) {
        guard !stopped, process === worker, generation == token, !terminal else { return }
        terminal = true; invalidateSession(); scheduleRetry(); setState(text)
        stopWorker()
    }

    private func stopWorker() {
        generation += 1 // Invalidate all buffered lines and prior watchdogs now.
        guard let worker = process else { return }
        if worker.isRunning { worker.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak worker] in
            guard let self, let worker, self.process === worker, worker.isRunning else { return }
            // Only this Process is owned here. Never kill Steam by name or PID.
            _ = Darwin.kill(worker.processIdentifier, SIGKILL)
        }
        // process remains non-nil until the reader drains and waitUntilExit.
    }

    private func finished(_ worker: Process, token: UInt64) {
        guard process === worker else { return }
        process = nil
        fputs("Steam watcher reaped: pid=\(worker.processIdentifier), generation=\(token), exit=\(worker.terminationStatus)\n", stderr)
        guard !stopped else { return }
        if generation == token, !terminal {
            invalidateSession(); scheduleRetry()
            setState("Steam：监听已结束，等待重连")
        }
        tick()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; enabled = false
        timer?.invalidate(); timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        invalidateSession(); stopWorker()
    }
}
