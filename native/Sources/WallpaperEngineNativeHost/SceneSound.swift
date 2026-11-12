import AVFoundation
import Foundation
import CryptoKit

/// Immutable, bounded input shared by both renderers. Preparing a source never
/// creates an audio device or starts playback.
struct SceneSoundSource {
    struct Clip {
        let path: String
        let data: Data
        let signature: String
    }
    static let maximumClips = 64
    let object: [String: Any]
    let index: Int
    let id: String, name: String, mode: String
    let clips: [Clip]
    let byteCount: Int
    let signature: String
    let startSilent: Bool
    let initiallyPlaying: Bool

    init(object: [String: Any], index: Int, assets: SceneAssets, remainingBytes: Int) throws {
        self.object = object; self.index = index
        id = SceneScriptBridge.objectID(object, index: index)
        name = object["name"] as? String ?? "Sound"
        let files = (object["sound"] as? String).map { [$0] } ?? (object["sound"] as? [String]) ?? []
        guard !files.isEmpty, files.count <= Self.maximumClips,
              files.allSatisfy({ !$0.isEmpty }) else {
            throw SceneError.invalid("声音层需要 1–\(Self.maximumClips) 项非空音频资源路径。")
        }
        let mode = object["playbackmode"] ?? "loop"
        guard let mode = mode as? String, ["loop", "random", "single"].contains(mode) else {
            throw SceneError.invalid("声音层的 playbackmode 尚未支持：\(String(describing: object["playbackmode"]))。")
        }
        self.mode = mode
        if let silent = object["startsilent"] {
            guard let number = silent as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw SceneError.invalid("声音层 startsilent 必须为布尔值。")
            }
        }
        startSilent = object["startsilent"] as? Bool == true
        initiallyPlaying = mode == "random" || !startSilent
        guard remainingBytes > 0 else { throw SceneError.invalid("场景声音资源超过总容量上限。") }
        var loaded: [String: Clip] = [:], entries: [Clip] = [], usedBytes = 0
        for resource in files {
            // Repeated entries retain their selection weight without loading
            // or counting the same bytes repeatedly within this sound layer.
            if let clip = loaded[resource] { entries.append(clip); continue }
            guard usedBytes < remainingBytes else { throw SceneError.invalid("场景声音资源超过总容量上限。") }
            let bytes = try assets.data(resource, maximumBytes: min(64 * 1024 * 1024, remainingBytes - usedBytes))
            guard !bytes.isEmpty else { throw SceneError.invalid("声音资源为空：\(resource)") }
            let clip = Clip(path: resource, data: bytes, signature: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
            loaded[resource] = clip; entries.append(clip); usedBytes += bytes.count
        }
        clips = entries; byteCount = usedBytes
        var digest = SHA256()
        // The player retains objectIndex for state lookup. Moving the sound
        // within objects therefore requires a reload, even without scripts.
        digest.update(data: try JSONSerialization.data(withJSONObject: [id, index, mode, startSilent, entries.map { [$0.path, $0.signature] }], options: [.sortedKeys]))
        signature = digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Original sound bytes stay inside this process. Only one selected player is
/// retained per layer. Host suspension and script pause freeze both the selected
/// resource and the schedule; neither resets the other transport's intent.
@MainActor
final class SceneSoundLayer: NSObject, @preconcurrency AVAudioPlayerDelegate {
    let objectIndex: Int
    let objectID: String
    let name: String
    let byteCount: Int
    let mode: String
    private let clips: [SceneSoundSource.Clip]
    private var clipIndex = 0
    private var player: AVAudioPlayer
    private var serial: UInt64 = 0
    private enum Phase: String { case ready, playing, waiting, finished, failed }
    private var phase = Phase.ready
    private var initialWaitPending: Bool
    private var remaining = 0.0
    private var selectedGap = 0.0
    private var minimum = 1.0, maximum = 5.0
    private var lastUpdate: Double?
    private var resumePlayer = false
    private var lastSpectrumTime: Double?
    private var spectrumHasLooped = false
    private(set) var diagnostics: [String] = []
    private var requestedPlaying: Bool
    private var active = false
    private var visible = true
    private var authoredVolume: Float = 1
    private var lastReport = -Double.infinity
    private var reportCount = 0
    var path: String { clips[clipIndex].path }
    private var continuousLoop: Bool { mode == "loop" && clips.count == 1 }
    private var eligible: Bool { requestedPlaying && active && visible && phase != .failed }

    convenience init(object: [String: Any], index: Int, assets: SceneAssets, remainingBytes: Int, initialVolume: Any?,
                     initialMinimum: Any? = nil, initialMaximum: Any? = nil) throws {
        try self.init(source: SceneSoundSource(object: object, index: index, assets: assets, remainingBytes: remainingBytes),
                      initialVolume: initialVolume, initialMinimum: initialMinimum, initialMaximum: initialMaximum)
    }

    init(source: SceneSoundSource, initialVolume: Any?, initialMinimum: Any? = nil, initialMaximum: Any? = nil) throws {
        objectIndex = source.index; objectID = source.id; name = source.name
        mode = source.mode; clips = source.clips; byteCount = source.byteCount
        requestedPlaying = source.initiallyPlaying
        // The desktop developer's random + Start Silent guidance requires an
        // initial interval. The Android reference skips StartPlayback instead;
        // this deliberate desktop policy is documented in SOUND_SCHEDULING.md.
        initialWaitPending = mode == "random" && source.startSilent
        player = try Self.prepare(source.clips[0].data)
        super.init()
        configurePlayer()
        setVolume(initialVolume, report: false)
        setIntervals(minimum: initialMinimum ?? source.object["mintime"], maximum: initialMaximum ?? source.object["maxtime"])
        let known: Set<String> = ["id", "name", "sound", "playbackmode", "startsilent", "muteineditor", "mintime", "maxtime", "volume", "visible", "origin", "angles", "scale", "parent", "parallaxDepth", "locktransforms"]
        let unknown = source.object.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty { note("声音层尚未接入字段：\(unknown.joined(separator: ", "))") }
        report("prepared")
    }

    private static func prepare(_ data: Data) throws -> AVAudioPlayer {
        let player = try AVAudioPlayer(data: data)
        guard player.duration.isFinite, player.duration > 0, player.duration <= 6 * 3600,
              (1...8).contains(player.numberOfChannels), player.format.sampleRate.isFinite, player.format.sampleRate > 0 else {
            throw SceneError.invalid("声音资源时长/声道超出当前原生播放器范围。")
        }
        return player
    }

    private func configurePlayer() {
        player.delegate = self
        player.numberOfLoops = continuousLoop ? -1 : 0
        player.isMeteringEnabled = true
        player.volume = authoredVolume * authoredVolume
    }

    var scriptState: [String: Any] {
        ["available": true, "playing": player.isPlaying, "volume": authoredVolume]
    }
    // Waiting needs CPU scheduling even when a static Metal scene draws once.
    var needsUpdates: Bool { eligible }
    var runtimeState: [String: Any] {
        ["id": objectID, "resource": path, "mode": mode, "requestedPlaying": requestedPlaying,
         "active": active, "visible": visible, "isPlaying": player.isPlaying,
         "time": player.currentTime, "duration": player.duration, "volume": authoredVolume, "outputGain": player.volume,
         "phase": phase.rawValue, "clipIndex": clipIndex, "clipCount": clips.count, "playSerial": serial,
         "scheduleRemaining": remaining, "selectedGap": selectedGap, "minimum": minimum, "maximum": maximum]
    }
    var runtimeDiagnostic: String {
        let state = player.isPlaying ? "播放" : (phase == .waiting ? "间隔等待" : "暂停")
        return String(format: "Scene 声音 %@ · %@ · %.3f / %.3f 秒 · 音量 %.3f · 输出增益 %.3f · 请求 %@ · 输出 %@ · 可见 %@ · 资源 %d/%d %@ · 启动 %llu · 剩余 %.3f 秒（间隔 %.3f，范围 %.3f–%.3f）",
               objectID, state, player.currentTime, player.duration, authoredVolume, player.volume,
               requestedPlaying ? "播放" : "停止", active ? "启用" : "停用", visible ? "是" : "否",
               clipIndex + 1, clips.count, path, serial, remaining, selectedGap, minimum, maximum)
    }

    var musicInput: SceneMusicInput? {
        guard active, visible, player.isPlaying, player.volume > 0 else { return nil }
        let time = player.currentTime
        if continuousLoop, let previous = lastSpectrumTime, time + 0.001 < previous { spectrumHasLooped = true }
        lastSpectrumTime = time
        let clip = clips[clipIndex]
        return SceneMusicInput(id: objectID, data: clip.data, playbackTime: time, volume: player.volume,
                               wrapHistory: spectrumHasLooped, resourceKey: clip.signature, generation: serial)
    }

    func update(volume: Any?, visible: Bool, active: Bool, minimum: Any? = nil, maximum: Any? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        accountElapsed(at: now)
        setVolume(volume)
        setIntervals(minimum: minimum, maximum: maximum)
        let changed = self.visible != visible || self.active != active
        self.visible = visible; self.active = active
        reconcile()
        if changed { report("host-state") }
        else if active, now - lastReport >= (reportCount < 4 ? 5 : 60) { report("playback") }
    }

    private func accountElapsed(at now: Double) {
        if let previous = lastUpdate, eligible, player.volume > 0, remaining > 0 {
            remaining = max(0, remaining - max(0, now - previous))
        }
        lastUpdate = now
    }

    func suspend() {
        accountElapsed(at: ProcessInfo.processInfo.systemUptime)
        guard active || player.isPlaying else { return }
        active = false
        if phase == .playing { player.pause(); resumePlayer = true }
        report("host-suspend")
    }

    func command(_ action: String) {
        accountElapsed(at: ProcessInfo.processInfo.systemUptime)
        switch action {
        case "play":
            // Public ISoundLayer docs specify idempotent play while running.
            // Resuming a wait preserves its countdown, just like a paused clip.
            guard !requestedPlaying || phase == .failed else { return }
            requestedPlaying = true
            if phase == .finished || phase == .failed { phase = .ready; remaining = 0 }
            if phase == .playing { resumePlayer = true }
        case "pause":
            requestedPlaying = false
            if phase == .playing { player.pause(); resumePlayer = true }
        case "stop":
            requestedPlaying = false; resumePlayer = false; initialWaitPending = false
            phase = .ready; remaining = 0; selectedGap = 0
            player.stop(); player.currentTime = 0
            lastSpectrumTime = nil; spectrumHasLooped = false
        default: return
        }
        // Starts occur only in update(), after the newest host gates.
        report("script-" + action)
    }

    private func reconcile() {
        guard eligible else {
            if player.isPlaying { player.pause(); resumePlayer = true }
            return
        }
        if phase == .ready {
            if initialWaitPending {
                initialWaitPending = false; selectedGap = randomGap(); remaining = selectedGap
                phase = .waiting; report("initial-wait")
            } else { startClip(); return }
        }
        if phase == .waiting, remaining <= 0 { startClip(); return }
        if phase == .playing, resumePlayer {
            resumePlayer = false
            if !player.play() { fail("系统音频播放器未能恢复播放；等待脚本重新播放。") }
        }
    }

    private func startClip() {
        // A zero gain freezes scheduling, as in Sound::Update. Existing audio
        // may finish while muted; no repeated selection/decoding occurs then.
        guard player.volume > 0 else { return }
        let next = Int.random(in: clips.indices)
        player.stop()
        do {
            if next != clipIndex { player = try Self.prepare(clips[next].data) }
            clipIndex = next
            player.currentTime = 0; configurePlayer()
            lastSpectrumTime = nil; spectrumHasLooped = false; resumePlayer = false
            selectedGap = mode == "random" ? randomGap() : 0
            remaining = continuousLoop || mode == "single" ? 0 : player.duration + selectedGap
            guard player.play() else { fail("系统音频播放器未能开始播放；等待脚本重新播放。"); return }
            phase = .playing; serial &+= 1
            report("selected")
        } catch {
            fail("声音资源 \(clips[next].path) 解码失败：\(error.localizedDescription)")
        }
    }

    private func randomGap() -> Double { Double.random(in: minimum...maximum) }
    private func setIntervals(minimum rawMinimum: Any?, maximum rawMaximum: Any?) {
        func value(_ raw: Any?, fallback: Double, name: String) -> Double {
            guard let raw else { return fallback }
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                note("声音 \(name) 不是有限数值，采用默认间隔。")
                return fallback
            }
            let value = number.doubleValue
            if !(0...86400).contains(value) { note("声音 \(name) 超出 0–86400 秒范围，当前截断。") }
            return min(86400, max(0, value))
        }
        let low = value(rawMinimum, fallback: 1, name: "mintime")
        let high = value(rawMaximum, fallback: 5, name: "maxtime")
        if low > high { note("声音 mintime 大于 maxtime，当前交换两个端点。") }
        minimum = min(low, high); maximum = max(low, high)
        // An interval change affects the next draw, not a wait already chosen.
    }

    private func setVolume(_ raw: Any?, report shouldReport: Bool = true) {
        let value: Double
        if raw == nil { value = 1 }
        else if let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { value = number.doubleValue }
        else { note("声音音量不是有限数值，当前静音。"); value = 0 }
        if value < 0 || value > 1 { note("声音音量超出系统播放器的 0–1 范围，当前截断；超范围增益尚未实现。") }
        let volume = Float(min(1, max(0, value)))
        let outputGain = volume * volume
        guard authoredVolume != volume || player.volume != outputGain else { return }
        authoredVolume = volume; player.volume = outputGain
        if shouldReport { report("volume") }
    }

    private func fail(_ message: String) {
        player.stop(); requestedPlaying = false; resumePlayer = false; phase = .failed
        remaining = 0; note(message); report("failed")
    }
    private func note(_ message: String) {
        guard !diagnostics.contains(message), diagnostics.count < 32 else { return }
        diagnostics.append(message)
        fputs("Scene sound compatibility: \(name): \(message)\n", stderr)
    }
    private func report(_ event: String) {
        player.updateMeters()
        var value = runtimeState
        value.merge(["event": event, "bytes": byteCount, "loops": player.numberOfLoops,
            "channels": player.numberOfChannels, "sampleRate": player.format.sampleRate,
            "hostUptime": ProcessInfo.processInfo.systemUptime]) { _, new in new }
        if player.isPlaying {
            value["averageDBFS"] = (0..<player.numberOfChannels).map { player.averagePower(forChannel: $0) }
            value["peakDBFS"] = (0..<player.numberOfChannels).map { player.peakPower(forChannel: $0) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            fputs("Scene sound runtime: \(name), \(String(decoding: data, as: UTF8.self))\n", stderr)
        }
        lastReport = ProcessInfo.processInfo.systemUptime; reportCount += 1
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player, phase == .playing else { return }
        accountElapsed(at: ProcessInfo.processInfo.systemUptime)
        guard flag else { fail("声音未正常结束；等待脚本重新播放。"); return }
        resumePlayer = false; player.currentTime = 0
        lastSpectrumTime = nil; spectrumHasLooped = false
        if mode == "single" { requestedPlaying = false; phase = .finished; remaining = 0 }
        else { phase = .waiting }
        report("finished")
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === self.player else { return }
        fail("系统音频解码失败：\(error?.localizedDescription ?? "unknown error")")
    }
    deinit { player.stop() }
}
