import AppKit
import CoreAudio
import Foundation

struct NativeAudioSpectrum: Sendable {
    struct Channels: Sendable {
        let left: [Float], right: [Float]
        var average: [Float] { zip(left, right).map { ($0 + $1) * 0.5 } }
    }
    let bands: [Int: Channels]
    let frames: UInt64
    let peak: Float
    let sampleRate: Double
    let updatedAt: Double
    static let silence = NativeAudioSpectrum(bands: Dictionary(uniqueKeysWithValues: [16,32,64].map {
        ($0, Channels(left: [Float](repeating: 0, count: $0), right: [Float](repeating: 0, count: $0)))
    }), frames: 0, peak: 0, sampleRate: 0, updatedAt: 0)
    var scriptValue: [String: Any] {
        Dictionary(uniqueKeysWithValues: bands.map { (String($0.key), ["left": $0.value.left, "right": $0.value.right]) })
    }
    var webValue: [Float] { (bands[64]?.left ?? []) + (bands[64]?.right ?? []) }
}

/// PCM remains in a fixed in-memory ring. Only frequency magnitudes leave this
/// object; the app does not save a recording or send audio to a server.
final class NativeSpectrumAnalyzer: @unchecked Sendable {
    private let size = 4096
    private var left = [Float](repeating: 0, count: 4096)
    private var right = [Float](repeating: 0, count: 4096)
    private var position = 0
    private var frames: UInt64 = 0
    private var analyzedFrames: UInt64 = 0
    private var sampleRate: Double = 48000
    private var window: [Float] = []
    private var loggedSignal = false
    private let lock = NSLock()
    private var published = NativeAudioSpectrum.silence
    private let sourceLabel: String
    // ingest/analyze/reset are called only on the capture data queue.
    init(sourceLabel: String = "system capture") {
        self.sourceLabel = sourceLabel
        window = (0..<size).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(size - 1)) }
    }
    func configure(sampleRate: Double) { self.sampleRate = sampleRate }
    func snapshot() -> NativeAudioSpectrum {
        lock.lock(); let value = published; lock.unlock()
        // A stopped/disconnected stream must not leave a frozen loud spectrum.
        return ProcessInfo.processInfo.systemUptime - value.updatedAt <= 0.5 ? value : .silence
    }
    func reset() {
        position = 0; frames = 0; analyzedFrames = 0; loggedSignal = false
        left = [Float](repeating: 0, count: size); right = left
        lock.lock(); published = .silence; lock.unlock()
    }
    func ingest(_ pointer: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: pointer))
        guard let first = buffers.first, let firstData = first.mData, first.mNumberChannels > 0, first.mNumberChannels <= 2 else { return }
        let interleaved = Int(first.mNumberChannels)
        var count = min(32768, Int(first.mDataByteSize) / (4 * interleaved))
        let l = firstData.assumingMemoryBound(to: Float.self)
        var r = l
        var rightStride = interleaved, rightOffset = interleaved == 2 ? 1 : 0
        if interleaved == 1, buffers.count >= 2, let secondData = buffers[1].mData, buffers[1].mNumberChannels == 1 {
            r = secondData.assumingMemoryBound(to: Float.self)
            count = min(count, Int(buffers[1].mDataByteSize) / 4); rightStride = 1; rightOffset = 0
        }
        for index in 0..<count {
            let a = l[index * interleaved], b = r[index * rightStride + rightOffset]
            left[position] = a.isFinite ? max(-8, min(8, a)) : 0
            right[position] = b.isFinite ? max(-8, min(8, b)) : 0
            position = (position + 1) % size
        }
        frames += UInt64(count)
    }
    /// An already mixed stereo window from this wallpaper's own audio files.
    /// Samples overlap between windows; frames counts analysis work, not unique
    /// captured frames. Caller serializes this method with all other operations.
    func analyzeWindow(_ samples: [Float], sampleRate: Double) -> NativeAudioSpectrum {
        guard samples.count == size * 2, sampleRate.isFinite, sampleRate >= 8000 else { return .silence }
        self.sampleRate = sampleRate
        for index in 0..<size {
            let a = samples[index * 2], b = samples[index * 2 + 1]
            left[index] = a.isFinite ? max(-8, min(8, a)) : 0
            right[index] = b.isFinite ? max(-8, min(8, b)) : 0
        }
        position = 0; frames += UInt64(size)
        analyze()
        return snapshot()
    }
    func analyze() {
        guard frames >= UInt64(size), frames != analyzedFrames else { return }
        analyzedFrames = frames
        let orderedLeft = Array(left[position...] + left[..<position])
        let orderedRight = Array(right[position...] + right[..<position])
        let peak = max(orderedLeft.map(abs).max() ?? 0, orderedRight.map(abs).max() ?? 0)
        let l = magnitudes(orderedLeft), r = magnitudes(orderedRight)
        var bands: [Int: NativeAudioSpectrum.Channels] = [:]
        for resolution in [16,32,64] {
            bands[resolution] = .init(left: reduce(l, resolution: resolution), right: reduce(r, resolution: resolution))
        }
        let value = NativeAudioSpectrum(bands: bands, frames: frames, peak: peak, sampleRate: sampleRate, updatedAt: ProcessInfo.processInfo.systemUptime)
        lock.lock(); published = value; lock.unlock()
        if peak > 0.0001, !loggedSignal {
            loggedSignal = true
            fputs("Native audio: first nonzero PCM from \(sourceLabel), sample rate \(sampleRate), analysis frames \(frames); no PCM saved\n", stderr)
        }
    }
    private func magnitudes(_ input: [Float]) -> [Float] {
        let mean = input.reduce(0, +) / Float(size)
        var real = zip(input, window).map { ($0 - mean) * $1 }
        var imaginary = [Float](repeating: 0, count: size)
        // Iterative radix-2 FFT written here; no third-party signal library.
        var j = 0
        for i in 1..<size {
            var bit = size >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { real.swapAt(i, j) }
        }
        var length = 2
        while length <= size {
            let angle = -2 * Float.pi / Float(length), stepR = cos(angle), stepI = sin(angle)
            for block in stride(from: 0, to: size, by: length) {
                var wr: Float = 1, wi: Float = 0
                for offset in 0..<(length / 2) {
                    let a = block + offset, b = a + length / 2
                    let vr = real[b] * wr - imaginary[b] * wi, vi = real[b] * wi + imaginary[b] * wr
                    let ur = real[a], ui = imaginary[a]
                    real[a] = ur + vr; imaginary[a] = ui + vi
                    real[b] = ur - vr; imaginary[b] = ui - vi
                    let nextR = wr * stepR - wi * stepI
                    wi = wr * stepI + wi * stepR; wr = nextR
                }
            }
            length *= 2
        }
        let normalization = 2 / window.reduce(0, +)
        return (0..<(size / 2)).map { sqrt(real[$0] * real[$0] + imaginary[$0] * imaginary[$0]) * normalization }
    }
    private func reduce(_ values: [Float], resolution: Int) -> [Float] {
        let high = min(20000, sampleRate * 0.5), low = 20.0
        return (0..<resolution).map { band in
            let lowerHz = low * pow(high / low, Double(band) / Double(resolution))
            let upperHz = low * pow(high / low, Double(band + 1) / Double(resolution))
            let lower = max(1, min(values.count - 1, Int(lowerHz * Double(size) / sampleRate)))
            let upper = max(lower + 1, min(values.count, Int(ceil(upperHz * Double(size) / sampleRate))))
            // Frequency edges and gain are this engine's current approximation.
            // Wallpaper Engine's exact bin/gain calibration is not public here.
            let energy = values[lower..<upper].reduce(Float(0)) { $0 + $1 * $1 }
            return min(8, sqrt(energy) * 4)
        }
    }
}

@available(macOS 14.2, *)
private final class NativeAudioTap: @unchecked Sendable {
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var io: AudioDeviceIOProcID?
    private let dataQueue = DispatchQueue(label: "io.wallpaper-engine-native.audio-data", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let analyzer = NativeSpectrumAnalyzer()
    func snapshot() -> NativeAudioSpectrum { analyzer.snapshot() }
    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SceneError.invalid("\(operation) 失败（Core Audio \(status)）。如权限被拒绝，可在系统设置的隐私与安全性中允许系统音频录制后重试。") }
    }
    // Lifecycle calls run on the service's serial control queue, never on main.
    func start() throws {
        do {
            let analyzer = self.analyzer
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.name = "Wallpaper Engine Native sound response"
            description.uuid = UUID(); description.isPrivate = true; description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "创建系统音频 Tap")
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var format = AudioStreamBasicDescription(), bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &bytes, &format), "读取音频格式")
            guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  (1...2).contains(format.mChannelsPerFrame), format.mSampleRate.isFinite, (8000...384000).contains(format.mSampleRate) else {
                throw SceneError.invalid("当前音频设备格式尚未支持；需要 32 位浮点 PCM、单声道或立体声。")
            }
            dataQueue.sync { analyzer.configure(sampleRate: format.mSampleRate) }
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Wallpaper Engine Native Audio",
                kAudioAggregateDeviceUIDKey: "io.wallpaper-engine-native.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "创建音频输入")
            try check(AudioDeviceCreateIOProcIDWithBlock(&io, device, dataQueue) { _, input, _, _, _ in analyzer.ingest(input) }, "注册音频输入回调")
            try check(AudioDeviceStart(device, io), "开启系统音频输入")
            let timer = DispatchSource.makeTimerSource(queue: dataQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(3))
            timer.setEventHandler { analyzer.analyze() }; timer.resume(); self.timer = timer
            fputs("Native audio: tap started, \(format.mSampleRate) Hz, \(format.mChannelsPerFrame) channels; system playback is unmuted\n", stderr)
        } catch { stop(); throw error }
    }
    func stop() {
        timer?.cancel(); timer = nil
        if device != 0, let io { AudioDeviceStop(device, io); AudioDeviceDestroyIOProcID(device, io) }
        io = nil
        if device != 0 { AudioHardwareDestroyAggregateDevice(device); device = 0 }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap); tap = 0 }
        dataQueue.sync { analyzer.reset() }
    }
}

@MainActor
final class NativeAudioService {
    static let shared = NativeAudioService()
    private let controlQueue = DispatchQueue(label: "io.wallpaper-engine-native.audio-control")
    private var tap: AnyObject?
    private(set) var active = false
    private(set) var busy = false
    private(set) var status = "系统声音响应未开启"
    var snapshot: NativeAudioSpectrum {
        guard active, #available(macOS 14.2, *), let tap = tap as? NativeAudioTap else { return .silence }
        return tap.snapshot()
    }
    func start() {
        guard !active, !busy else { return }
        guard #available(macOS 14.2, *) else { status = "声音响应需要 macOS 14.2 或更新版本。"; return }
        let capture = NativeAudioTap(); tap = capture
        busy = true; status = "正在申请系统音频权限并开启声音响应…"
        controlQueue.async {
            let result = Result { try capture.start() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    switch result {
                    case .success: self.active = true; self.status = "系统声音响应已开启"
                    case .failure(let error): self.tap = nil; self.status = error.localizedDescription; fputs("Native audio: \(error.localizedDescription)\n", stderr)
                    }
                }
            }
        }
    }
    func stop() {
        guard !busy else { return }
        guard #available(macOS 14.2, *), let capture = tap as? NativeAudioTap else { return }
        active = false; busy = true; status = "正在停止声音响应…"
        controlQueue.async {
            capture.stop()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.tap = nil; self.busy = false; self.status = "系统声音响应已关闭" } }
        }
    }
    func shutdown() {
        active = false
        if #available(macOS 14.2, *), let capture = tap as? NativeAudioTap { controlQueue.sync { capture.stop() } }
        tap = nil
    }
}

@MainActor
final class NativeAudioController: NSWindowController {
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let levelLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "开启声音响应…", target: nil, action: nil)
    private let stopButton = NSButton(title: "关闭声音响应", target: nil, action: nil)
    private var timer: Timer?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 550, height: 440), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.title = "声音响应"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let detail = NSTextField(wrappingLabelWithString: "支持的 Scene 音乐和 Web 本机媒体会自动驱动壁纸频谱。开启系统声音响应后，频谱将来自 Mac 整体声音，包括其他应用。\n\n首次开启系统声音响应时，macOS 会询问是否允许此应用录制系统音频。音频仅在本机转换为频谱，不保存录音，也不上传。不会使用麦克风，原来的声音继续正常播放。\n\n系统声音响应每次启动后需手动开启。当前频段与强度为兼容实现，可能与 Windows 原版不同。")
        let buttons = NSStackView(views: [startButton, stopButton]); buttons.spacing = 12
        let stack = NSStackView(views: [detail,statusLabel,levelLabel,buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 22), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -22), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22)])
        startButton.target = self; startButton.action = #selector(start)
        stopButton.target = self; stopButton.action = #selector(stop)
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        refresh(); window.center()
    }
    required init?(coder: NSCoder) { nil }
    @objc private func start() { NativeAudioService.shared.start(); refresh() }
    @objc private func stop() { NativeAudioService.shared.stop(); refresh() }
    private func refresh() {
        let service = NativeAudioService.shared, value = service.snapshot
        statusLabel.stringValue = service.status
        if service.active {
            levelLabel.stringValue = value.frames > 0 ? String(format: "当前峰值 %.4f · %.0f Hz · 已接收 %llu 帧", value.peak, value.sampleRate, value.frames) : "已开启，等待音频数据；若正在播放却一直为零，请检查系统音频权限。"
        } else {
            let music = SceneMusicSpectrum.shared.snapshot
            if WebMusicSpectrum.shared.isActive { levelLabel.stringValue = WebMusicSpectrum.shared.status }
            else { levelLabel.stringValue = music.frames > 0 ? String(format: "壁纸音乐频谱 · 当前峰值 %.4f · %.0f Hz", music.peak, music.sampleRate) : "当前没有可分析的壁纸音乐。" }
        }
        startButton.isEnabled = !service.active && !service.busy
        stopButton.isEnabled = service.active && !service.busy
    }
    deinit { timer?.invalidate() }
}
