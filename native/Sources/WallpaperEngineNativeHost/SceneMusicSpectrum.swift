import AudioToolbox
import Foundation

struct SceneMusicInput: Sendable {
    let id: String
    let resourceKey: String
    let generation: UInt64
    let data: Data
    let playbackTime: Double
    let volume: Float
    let wrapHistory: Bool

    init(id: String, data: Data, playbackTime: Double, volume: Float, wrapHistory: Bool,
         resourceKey: String? = nil, generation: UInt64 = 0) {
        self.id = id; self.resourceKey = resourceKey ?? id; self.generation = generation
        self.data = data; self.playbackTime = playbackTime; self.volume = volume; self.wrapHistory = wrapHistory
    }
}

private final class SceneAudioBytes {
    let data: NSData
    init(_ bytes: Data) { data = bytes as NSData }
}

private let sceneAudioRead: AudioFile_ReadProc = { context, position, requested, buffer, actual in
    actual.pointee = 0
    let storage = Unmanaged<SceneAudioBytes>.fromOpaque(context).takeUnretainedValue()
    guard position >= 0, position <= Int64(storage.data.length) else { return -50 }
    let count = min(Int(requested), storage.data.length - Int(position))
    if count > 0 { memcpy(buffer, storage.data.bytes.advanced(by: Int(position)), count) }
    actual.pointee = UInt32(count)
    return noErr
}
private let sceneAudioSize: AudioFile_GetSizeProc = { context in
    Int64(Unmanaged<SceneAudioBytes>.fromOpaque(context).takeUnretainedValue().data.length)
}

/// Read-only AudioToolbox callbacks decode bounded windows directly from the
/// original in-memory resource. No virtual device, process tap or file output.
/// Each instance is owned and used exclusively by the music worker queue.
private final class SceneAudioWindowDecoder {
    static let frameCount = 4096
    static let outputRate = 48000.0
    private let storage: SceneAudioBytes
    private var file: AudioFileID?
    private var extended: ExtAudioFileRef?
    private(set) var sourceRate = 0.0
    private(set) var channels = 0
    private var duration = 0.0

    init(data: Data) throws {
        storage = SceneAudioBytes(data)
        do {
            try check(AudioFileOpenWithCallbacks(Unmanaged.passUnretained(storage).toOpaque(), sceneAudioRead, nil, sceneAudioSize, nil, 0, &file), "打开内存声音资源")
            guard let file else { throw SceneError.invalid("内存声音资源没有返回文件句柄。") }
            try check(ExtAudioFileWrapAudioFileID(file, false, &extended), "创建声音窗口解码器")
            guard let extended else { throw SceneError.invalid("声音窗口解码器不可用。") }
            var format = AudioStreamBasicDescription(), size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileDataFormat, &size, &format), "读取声音格式")
            guard (1...2).contains(format.mChannelsPerFrame), format.mSampleRate.isFinite, (8000...384000).contains(format.mSampleRate) else {
                throw SceneError.invalid("壁纸音乐频谱当前只接受 8–384 kHz 的单/双声道资源；声音播放仍可继续。")
            }
            sourceRate = format.mSampleRate; channels = Int(format.mChannelsPerFrame)
            var length: Int64 = 0; size = UInt32(MemoryLayout<Int64>.size)
            try check(ExtAudioFileGetProperty(extended, kExtAudioFileProperty_FileLengthFrames, &size, &length), "读取声音长度")
            duration = Double(length) / sourceRate
            guard duration.isFinite, duration > 0, duration <= 6 * 3600 else { throw SceneError.invalid("声音窗口时长超出当前范围。") }
            var client = AudioStreamBasicDescription(mSampleRate: Self.outputRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
            try check(ExtAudioFileSetProperty(extended, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client), "配置声音 PCM 解码")
        } catch { close(); throw error }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw SceneError.invalid("\(operation)失败（AudioToolbox \(status)）。") }
    }

    private func read(start: Double, count: Int) throws -> [Float] {
        guard count > 0, count <= Self.frameCount, let extended else { return [] }
        try check(ExtAudioFileSeek(extended, Int64(max(0, min(duration, start)) * sourceRate)), "定位声音窗口")
        var result = [Float](repeating: 0, count: count * channels)
        var frames = UInt32(count)
        let status = result.withUnsafeMutableBytes { bytes -> OSStatus in
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            return ExtAudioFileRead(extended, &frames, &list)
        }
        try check(status, "解码声音窗口")
        // Any short read retains zero padding. Only this bounded window is kept.
        return result
    }

    func window(endingAt time: Double, looping: Bool) throws -> [Float] {
        guard time.isFinite, time >= 0 else { throw SceneError.invalid("声音播放位置无效。") }
        let end = min(time, duration)
        if looping, duration * Self.outputRate < Double(Self.frameCount) {
            let count = max(1, Int(duration * Self.outputRate))
            let clip = try read(start: 0, count: count)
            let endpoint = Int(end * Self.outputRate)
            var repeated = [Float](repeating: 0, count: Self.frameCount * channels)
            for index in 0..<Self.frameCount {
                let source = ((endpoint - Self.frameCount + index) % count + count) % count
                for channel in 0..<channels { repeated[index * channels + channel] = clip[source * channels + channel] }
            }
            return repeated
        }
        let headCount = min(Self.frameCount, max(0, Int(end * Self.outputRate)))
        let tailCount = Self.frameCount - headCount
        var output = [Float](repeating: 0, count: Self.frameCount * channels)
        if looping, tailCount > 0 {
            let tail = try read(start: max(0, duration - Double(tailCount) / Self.outputRate), count: tailCount)
            output.replaceSubrange(0..<tail.count, with: tail)
        }
        if headCount > 0 {
            let head = try read(start: max(0, end - Double(headCount) / Self.outputRate), count: headCount)
            let start = tailCount * channels
            output.replaceSubrange(start..<(start + head.count), with: head)
        }
        return output
    }

    private func close() {
        if let extended { ExtAudioFileDispose(extended); self.extended = nil }
        // WrapAudioFileID does not take ownership of the underlying AudioFileID.
        if let file { AudioFileClose(file); self.file = nil }
    }
    deinit { close() }
}

private struct SceneMusicResult: Sendable {
    let spectrum: NativeAudioSpectrum
    let errors: [String]
    let elapsed: Double
    let activeLayers: Int
}

/// The queue exclusively owns decoder state; immutable Data crosses from UI.
private final class SceneMusicWorker: @unchecked Sendable {
    private var decoders: [String: (key: String, decoder: SceneAudioWindowDecoder)] = [:]
    private var rejected: [String: String] = [:]
    private let analyzer = NativeSpectrumAnalyzer(sourceLabel: "wallpaper music resource")
    func sample(_ inputs: [SceneMusicInput]) -> SceneMusicResult {
        let started = ProcessInfo.processInfo.systemUptime
        var mixed = [Float](repeating: 0, count: SceneAudioWindowDecoder.frameCount * 2), messages: [String] = []
        var activeLayers = 0
        let activeIDs = Set(inputs.prefix(32).map(\.id))
        decoders = decoders.filter { activeIDs.contains($0.key) }
        rejected = rejected.filter { activeIDs.contains($0.key) }
        for input in inputs.prefix(32) where rejected[input.id] != input.resourceKey {
            do {
                let decoder: SceneAudioWindowDecoder
                if let cached = decoders[input.id], cached.key == input.resourceKey { decoder = cached.decoder }
                else {
                    decoder = try SceneAudioWindowDecoder(data: input.data)
                    decoders[input.id] = (input.resourceKey, decoder); rejected[input.id] = nil
                    fputs("Scene music decoder: layer \(input.id), \(decoder.sourceRate) Hz, \(decoder.channels) channels, output 48000 Hz float PCM; in-memory resource only\n", stderr)
                }
                let window = try decoder.window(endingAt: input.playbackTime, looping: input.wrapHistory)
                for index in 0..<SceneAudioWindowDecoder.frameCount {
                    mixed[index * 2] += window[index * decoder.channels] * input.volume
                    mixed[index * 2 + 1] += window[index * decoder.channels + (decoder.channels == 2 ? 1 : 0)] * input.volume
                }
                activeLayers += 1
            } catch {
                rejected[input.id] = input.resourceKey; decoders[input.id] = nil
                messages.append("声音层 \(input.id)：\(error.localizedDescription)")
            }
        }
        let spectrum = activeLayers > 0 ? analyzer.analyzeWindow(mixed, sampleRate: SceneAudioWindowDecoder.outputRate) : .silence
        return SceneMusicResult(spectrum: spectrum, errors: messages, elapsed: ProcessInfo.processInfo.systemUptime - started, activeLayers: activeLayers)
    }
}

/// The primary presentation publishes a single wallpaper-music spectrum for
/// all displays. It is used only while the separately controlled system tap is
/// off, so enabling that tap cannot double-count this app's own audio.
@MainActor
final class SceneMusicSpectrum {
    static let shared = SceneMusicSpectrum()
    private let queue = DispatchQueue(label: "io.wallpaper-engine-native.music-spectrum", qos: .userInitiated)
    private var worker: SceneMusicWorker?
    private var owner: UUID?
    private var generation = 0
    private var pendingRequest: Int?
    private var requestSerial = 0
    private var signature = ""
    private var lastRequest = -Double.infinity
    private var published = NativeAudioSpectrum.silence
    private var windows = 0
    private var elapsedTotal = 0.0
    private var elapsedMaximum = 0.0
    private var lastReport = -Double.infinity
    private(set) var diagnostics: [String] = []
    var snapshot: NativeAudioSpectrum {
        ProcessInfo.processInfo.systemUptime - published.updatedAt <= 0.5 ? published : .silence
    }

    func activate(owner: UUID) {
        guard self.owner != owner else { return }
        self.owner = owner; generation += 1; pendingRequest = nil; signature = ""
        published = .silence; worker = SceneMusicWorker(); diagnostics = []
        windows = 0; elapsedTotal = 0; elapsedMaximum = 0; lastRequest = -.infinity; lastReport = -.infinity
    }
    func deactivate(owner: UUID) {
        guard self.owner == owner else { return }
        clear(owner: owner); self.owner = nil; worker = nil
    }
    func clear(owner: UUID) {
        guard self.owner == owner else { return }
        if !signature.isEmpty || published.frames > 0 {
            signature = ""; generation += 1; published = .silence
            fputs("Scene music spectrum: cleared; no audible wallpaper source\n", stderr)
        }
    }

    func update(owner: UUID, inputs: [SceneMusicInput]) {
        guard self.owner == owner, let worker else { return }
        guard !inputs.isEmpty else { clear(owner: owner); return }
        let nextSignature = inputs.map { "\($0.id):\($0.resourceKey):\($0.generation):\($0.volume)" }.joined(separator: ",")
        if signature != nextSignature {
            signature = nextSignature; generation += 1; published = .silence
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard pendingRequest == nil, now - lastRequest >= 1.0 / 30 else { return }
        requestSerial += 1; let request = requestSerial
        pendingRequest = request; lastRequest = now
        let currentGeneration = generation
        queue.async { [weak self] in
            let result = worker.sample(inputs)
            DispatchQueue.main.async {
                guard let self, self.owner == owner, self.pendingRequest == request else { return }
                self.pendingRequest = nil
                guard self.generation == currentGeneration else { return }
                self.published = result.spectrum
                self.windows += 1; self.elapsedTotal += result.elapsed; self.elapsedMaximum = max(self.elapsedMaximum, result.elapsed)
                for message in result.errors where !self.diagnostics.contains(message) && self.diagnostics.count < 32 {
                    self.diagnostics.append(message); fputs("Scene music spectrum compatibility: \(message)\n", stderr)
                }
                let at = ProcessInfo.processInfo.systemUptime
                if at - self.lastReport >= (self.windows <= 90 ? 1 : 30) {
                    self.lastReport = at
                    let left = result.spectrum.bands[64]?.left ?? [], right = result.spectrum.bands[64]?.right ?? []
                    let value: [String: Any] = ["source": "wallpaper resources", "windows": self.windows, "activeLayers": result.activeLayers,
                        "peak": result.spectrum.peak, "sampleRate": result.spectrum.sampleRate,
                        "left64": left, "right64": right, "gainSignature": self.signature,
                        "meanMilliseconds": self.elapsedTotal / Double(self.windows) * 1000, "maximumMilliseconds": self.elapsedMaximum * 1000,
                        "hostUptime": at, "playbackTimes": inputs.map { ["id": $0.id, "time": $0.playbackTime] as [String: Any] }]
                    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                        fputs("Scene music spectrum: \(String(decoding: data, as: UTF8.self))\n", stderr)
                    }
                }
            }
        }
    }
}
