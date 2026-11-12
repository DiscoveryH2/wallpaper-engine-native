import Foundation
import AVFoundation
import CoreVideo
import CryptoKit

/// TEX video flag and first-body byte range are independently observed in the
/// official Android reader/GLTexture. TEXB0004's extra word is a variant count,
/// not a video discriminator. Only the uncompressed, single-body case is read.
struct SceneVideoContainer {
    let width: Int, height: Int
    let flags: UInt32
    let movie: Data
    static func isVideo(_ data: Data) -> Bool {
        guard data.count >= 26, data.prefix(18) == Data("TEXV0005\0TEXI0001\0".utf8) else { return false }
        return data[data.startIndex + 22] & 32 != 0
    }
    static func decode(_ data: Data) throws -> Self {
        var reader = SceneByteReader(data)
        try reader.expect(Array("TEXV0005\0".utf8), "video TEX version")
        try reader.expect(Array("TEXI0001\0".utf8), "video TEX info")
        _ = try reader.readUInt32("video format")
        let flags = try reader.readUInt32("video flags")
        let w = Int(try reader.readUInt32("video width")), h = Int(try reader.readUInt32("video height"))
        let iw = Int(try reader.readUInt32("video image width")), ih = Int(try reader.readUInt32("video image height"))
        _ = try reader.readUInt32("video reserved")
        guard flags & 32 != 0, flags & (4 | 64) == 0,
              (1...4096).contains(w), (1...4096).contains(h), w == iw, h == ih,
              w * h <= 8_388_608 else { throw SceneError.invalid("Scene 视频尺寸、图集或体积纹理格式尚不支持。") }
        let marker = String(decoding: try reader.readData(9, "video body"), as: UTF8.self)
        guard ["TEXB0002\0", "TEXB0003\0", "TEXB0004\0"].contains(marker),
              try reader.readUInt32("video image count") == 1 else { throw SceneError.invalid("Scene 视频需要单个 TEXB0002/3/4 图像体。") }
        if marker != "TEXB0002\0" {
            guard try reader.readUInt32("video image codec") == UInt32.max else { throw SceneError.invalid("Scene 视频体不能使用静态图片编码。") }
        }
        if marker == "TEXB0004\0" {
            guard try reader.readUInt32("video variant count") == 0 else { throw SceneError.invalid("Scene 视频纹理变体尚未支持。") }
        }
        guard try reader.readUInt32("video mip count") == 1,
              try reader.readUInt32("video body width") == w,
              try reader.readUInt32("video body height") == h,
              try reader.readUInt32("video compression") == 0 else { throw SceneError.invalid("Scene 视频需要单个未压缩字节流。") }
        _ = try reader.readUInt32("video decoded size")
        let length = Int(try reader.readUInt32("video stream size"))
        guard (16...SceneTexture.maximumResourceBytes).contains(length) else { throw SceneError.invalid("Scene 视频字节流尺寸无效。") }
        let movie = try reader.readData(length, "video MP4 stream")
        guard reader.offset == data.count, movie.dropFirst(4).prefix(4) == Data("ftyp".utf8) else { throw SceneError.invalid("Scene 视频需要完整的内嵌 MP4 文件。") }
        return Self(width: w, height: h, flags: flags, movie: movie)
    }
}

/// Immutable metadata and an owned local file. AVFoundation may not resolve any
/// external movie reference. A file stays alive until all display readers stop.
final class SceneVideoAsset: @unchecked Sendable {
    let directory: URL, url: URL
    let asset: AVURLAsset, track: AVAssetTrack
    let width: Int, height: Int, duration: Double, fps: Double
    /// Audio remains optional. A video with an unavailable or unsupported
    /// audio stream is still a valid texture; AVPlayer simply is not created
    /// for it. This keeps the existing video-only admission contract intact.
    let audioTrackCount: Int
    let signature: String, flags: UInt32
    let firstFrame: SceneVideoFrame
    private init(directory: URL, asset: AVURLAsset, track: AVAssetTrack, container: SceneVideoContainer,
                 duration: Double, fps: Double, audioTrackCount: Int, signature: String, firstFrame: SceneVideoFrame) {
        self.directory = directory; url = directory.appendingPathComponent("video.mp4")
        self.asset = asset; self.track = track; width = container.width; height = container.height
        self.duration = duration; self.fps = fps; self.audioTrackCount = audioTrackCount
        self.signature = signature; flags = container.flags; self.firstFrame = firstFrame
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    static func prepare(_ data: Data) async throws -> SceneVideoAsset {
        let container = try SceneVideoContainer.decode(data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("we-scene-video-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appendingPathComponent("video.mp4")
        try container.movie.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let track = tracks.first else { throw SceneError.invalid("Scene 视频需要单个视频轨道。") }
        let duration = try await asset.load(.duration).seconds
        let (size, transform, fps, formats, range) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions, .timeRange)
        guard duration.isFinite, duration > 0, duration <= 86400, range.start.seconds == 0,
              transform == .identity, Int(size.width) == container.width, Int(size.height) == container.height,
              fps.isFinite, fps > 0, fps <= 120,
              formats.count == 1, let format = formats.first,
              [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC].contains(CMFormatDescriptionGetMediaSubType(format)) else {
            throw SceneError.invalid("Scene 视频目前支持无旋转、从零开始的 H.264/HEVC，最长 24 小时、最高 120 fps。")
        }
        try Task.checkCancellation()
        let stream = SceneVideoStream(asset: asset, track: track, width: container.width, height: container.height, duration: duration)
        let first = try stream.frame(at: 0)
        stream.cancel()
        // Audio selection is deliberately best-effort. Texture rendering has
        // always admitted the video track alone, and a malformed optional
        // stream must not turn a previously visible Scene video into a load
        // failure. AVPlayer will expose a runtime error if it later cannot
        // decode a selected stream.
        let audioTrackCount = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
        let result = SceneVideoAsset(directory: directory, asset: asset, track: track, container: container,
            duration: duration, fps: Double(fps), audioTrackCount: audioTrackCount,
            signature: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), firstFrame: first)
        retained = true; return result
    }
    func metadata(key: String) -> [String: Any] { ["duration": duration, "key": key] }
    func matches(_ data: Data) -> Bool { signature == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

struct SceneVideoFrame: Sendable {
    let pts: Double
    let rgba: [UInt8]
}

/// AVAssetReader is confined to one worker. Only current/next samples are kept;
/// seeks restart the reader near the requested time, never cache the movie.
final class SceneVideoStream {
    private let asset: AVAsset, track: AVAssetTrack
    private let width: Int, height: Int, duration: Double
    private var reader: AVAssetReader?, output: AVAssetReaderTrackOutput?
    private var current: CMSampleBuffer?, next: CMSampleBuffer?
    private var lastRequest = -1.0
    private var cached: SceneVideoFrame?
    init(asset: AVAsset, track: AVAssetTrack, width: Int, height: Int, duration: Double) {
        self.asset = asset; self.track = track; self.width = width; self.height = height; self.duration = duration
    }
    func cancel() { reader?.cancelReading(); reader = nil; output = nil; current = nil; next = nil }
    deinit { cancel() }
    func frame(at requested: Double) throws -> SceneVideoFrame {
        let time = min(max(0, requested), max(0, duration - 0.000001))
        if reader == nil || time < lastRequest || time - lastRequest > 0.5 {
            var preroll = 0.5
            while true {
                cancel()
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                guard reader.canAdd(output) else { throw SceneError.invalid("系统无法解码 Scene 视频轨道。") }
                reader.add(output)
                let start = max(0, time - preroll)
                reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 60000), end: CMTime(seconds: duration, preferredTimescale: 60000))
                guard reader.startReading() else { throw reader.error ?? SceneError.invalid("Scene 视频解码器启动失败。") }
                self.reader = reader; self.output = output; next = output.copyNextSampleBuffer()
                if reader.status == .failed { throw reader.error ?? SceneError.invalid("Scene 视频跳转失败。") }
                // Sparse/VFR movies may have a sample spanning more than the
                // initial preroll. Widen until the preceding sample is found;
                // do not display a future frame or fail on a long final hold.
                if start == 0 || next.map({ CMSampleBufferGetPresentationTimeStamp($0).seconds <= time }) == true { break }
                preroll *= 2
            }
        }
        lastRequest = time
        while let sample = next {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { throw SceneError.invalid("Scene 视频帧时间无效。") }
            if current != nil && pts > time { break }
            current = sample; next = output?.copyNextSampleBuffer()
        }
        if reader?.status == .failed { throw reader?.error ?? SceneError.invalid("Scene 视频解码失败。") }
        guard let current, let pixels = CMSampleBufferGetImageBuffer(current),
              CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height,
              CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { throw SceneError.invalid("Scene 视频解码没有返回有效帧。") }
        let pts = CMSampleBufferGetPresentationTimeStamp(current).seconds
        if let cached, cached.pts == pts { return cached }
        guard CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { throw SceneError.invalid("Scene 视频帧不可读取。") }
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw SceneError.invalid("Scene 视频像素缺失。") }
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let src = x * 4, dst = (y * width + x) * 4
                rgba[dst] = row[src + 2]; rgba[dst + 1] = row[src + 1]; rgba[dst + 2] = row[src]; rgba[dst + 3] = 255
            }
        }
        let frame = SceneVideoFrame(pts: pts, rgba: rgba); cached = frame; return frame
    }
}

/// Preparation never mutates project files. Failures belong to the individual
/// resource so an unused incompatible clip cannot hide an otherwise valid scene.
final class SceneVideoLibrary: @unchecked Sendable {
    private let entries: [String: Result<SceneVideoAsset, Error>]
    init(entries: [String: Result<SceneVideoAsset, Error>] = [:]) { self.entries = entries }
    func asset(_ path: String) throws -> SceneVideoAsset? { try entries[path.lowercased()]?.get() }
    static func prepare(project: WallpaperProject, snapshot: NativeSceneLifecycle.Snapshot? = nil,
                        preparedAssets: SceneAssets? = nil, expandedSceneJSON: Data? = nil) async throws -> SceneVideoLibrary {
        guard project.kind == .scene else { return SceneVideoLibrary() }
        let assets = try preparedAssets ?? SceneAssets(directory: project.directoryURL)
        // Follow the same project-relative JSON references used by Scene,
        // models and materials. Sibling projects/previews are not video inputs.
        let relative = project.resourceURL.path.replacingOccurrences(of: project.directoryURL.path + "/", with: "")
        var pending = [relative], visited = Set<String>(), referenced = Set<String>(), jsonBytes = 0
        func visit(_ value: Any, depth: Int = 0) throws {
            guard depth <= 64 else { throw SceneError.invalid("Scene 视频资源引用嵌套过深。") }
            if let string = value as? String {
                if string.lowercased().hasSuffix(".json"), assets.contains(string), !visited.contains(string.lowercased()) { pending.append(string) }
                let texture = string.hasSuffix(".tex") ? string : "materials/\(string).tex"
                if assets.contains(texture) { referenced.insert(texture.lowercased()) }
            } else if let array = value as? [Any] { for item in array { try visit(item, depth: depth + 1) } }
            else if let object = value as? [String: Any] { for item in object.values { try visit(item, depth: depth + 1) } }
        }
        while let path = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(path.lowercased()).inserted else { continue }
            guard visited.count <= 5000 else { throw SceneError.invalid("Scene 视频引用图超过 5000 个资源。") }
            let data = try assets.data(path, maximumBytes: 4 * 1024 * 1024)
            jsonBytes += data.count
            guard jsonBytes <= 64 * 1024 * 1024 else { throw SceneError.invalid("Scene 视频引用图超过 64 MiB。") }
            let document: Any
            if path.lowercased() == relative.lowercased(), let expandedSceneJSON {
                document = try JSONSerialization.jsonObject(with: expandedSceneJSON)
            } else {
                document = path.lowercased() == relative.lowercased() && snapshot != nil
                    ? try snapshot!.materializedScene() : try JSONSerialization.jsonObject(with: data)
            }
            if path.lowercased() == relative.lowercased(), let scene = document as? [String: Any] {
                // MDL material paths are binary references, so the JSON walk
                // alone cannot reach their videos. Reuse the same bounded
                // material expansion as both renderers, including packed MDL
                // resources, instead of scanning unrelated project files.
                try visit(expandedSceneJSON == nil ? NativeModelMaterials.expand(scene, assets: assets) : scene)
            } else {
                try visit(document)
            }
        }
        var entries: [String: Result<SceneVideoAsset, Error>] = [:], bytes = 0, pixels = 0
        for path in referenced.sorted() {
            try Task.checkCancellation()
            guard SceneVideoContainer.isVideo(try assets.prefix(path, count: 26)) else { continue }
            do {
                guard entries.count < 8 else { throw SceneError.invalid("Scene 视频资源超过当前 8 个上限。") }
                let data = try assets.data(path, maximumBytes: SceneTexture.maximumResourceBytes)
                let header = try SceneVideoContainer.decode(data)
                guard bytes + data.count <= 256 * 1024 * 1024, pixels + header.width * header.height <= 16_777_216 else {
                    throw SceneError.invalid("Scene 视频合计超过 256 MiB 文件或 1600 万像素。")
                }
                let prepared = try await SceneVideoAsset.prepare(data)
                entries[path] = .success(prepared); bytes += data.count; pixels += header.width * header.height
            } catch is CancellationError { throw CancellationError() }
            catch { entries[path] = .failure(error) }
        }
        return SceneVideoLibrary(entries: entries)
    }
}

struct SceneVideoPlayback: Equatable {
    let playing: Bool, loop: Bool
    let position: Double, anchor: Double, rate: Double
    init?(_ value: [String: Any]) {
        guard let playing = value["playing"] as? Bool, let loop = value["loop"] as? Bool,
              let position = value["position"] as? Double, let anchor = value["anchor"] as? Double,
              let rate = value["rate"] as? Double, position.isFinite, position >= 0, position <= 86400,
              anchor.isFinite, anchor >= 0, rate.isFinite, (0...16).contains(rate) else { return nil }
        self.playing = playing; self.loop = loop; self.position = position; self.anchor = anchor; self.rate = rate
    }
    func time(at runtime: Double, duration: Double) -> Double {
        let t = position + (playing ? max(0, runtime - anchor) * rate : 0)
        return loop && t >= duration ? t.truncatingRemainder(dividingBy: duration) : min(duration, t)
    }
}

/// AVPlayer is intentionally separate from `SceneVideoStream`: the reader
/// supplies deterministic CPU frames on its worker queue, while this object is
/// touched only by the main-actor renderers to drive the optional embedded
/// audio track. In particular, constructing/preparing a video never creates a
/// player or starts audio output.
@MainActor
private final class SceneVideoAudioTransport {
    private let asset: AVURLAsset
    private let duration: Double
    private let trackCount: Int
    private var player: AVPlayer?
    private var outputEnabled = false
    private var presentationActive = false
    private var requestedPlaying = false
    private var transportRunning = false
    private var requestedRate = 0.0
    private var requestedLoop = true
    private var expectedTime = 0.0
    private var lastSceneTime: Double?
    private var lastExpectedTime: Double?
    private var lastRate = 0.0
    private var lastLoop = true
    private var lastDriftCheckSceneTime = -Double.infinity
    private var synchronizationCount = 0
    private var seekCount = 0
    private var seekPending = false
    private var pendingSeekTime: Double?
    private var pendingSeekStartedAt: Double?
    /// A single asynchronous AVPlayer seek can finish after the scene clock
    /// has advanced. Permit one retarget using the just-observed seek latency;
    /// do not form an unbounded seek-completion loop when AVFoundation is slow.
    private var completionAlignmentBudget = 0
    private var completionAlignmentCorrections = 0
    private var seekGeneration = 0

    init(asset: AVURLAsset, duration: Double, trackCount: Int) {
        self.asset = asset; self.duration = duration; self.trackCount = trackCount
    }

    deinit { player?.pause() }

    private func currentPlayerTime() -> Double? {
        guard let value = player?.currentTime().seconds, value.isFinite else { return nil }
        return value
    }

    private func playbackDistance(_ lhs: Double, _ rhs: Double, loop: Bool) -> Double {
        let linear = abs(lhs - rhs)
        return loop ? min(linear, max(0, duration - linear)) : linear
    }

    private func advanceExpected(_ time: Double, by elapsed: Double) -> Double {
        let advanced = time + max(0, elapsed) * requestedRate
        if requestedLoop, duration > 0 { return advanced.truncatingRemainder(dividingBy: duration) }
        return min(duration, max(0, advanced))
    }

    private func makePlayer() -> AVPlayer? {
        // AVPlayer chooses a media-selection group by default. For a Scene
        // texture we only have a deterministic contract for one embedded
        // audio track, so do not accidentally select an author-defined
        // alternate/multi-track group.
        guard trackCount == 1 else { return nil }
        if let player { return player }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        self.player = player
        return player
    }

    private func continuous(sceneTime: Double, expected: Double, rate: Double, loop: Bool) -> Bool {
        guard let lastSceneTime, let lastExpectedTime,
              sceneTime >= lastSceneTime, rate == lastRate, loop == lastLoop else { return false }
        // `actionAtItemEnd = .pause` means an AVPlayer cannot smoothly wrap
        // itself. A clock wrap must be a prompt, exact seek/play; treating
        // it as mathematical continuity leaves the player paused until the
        // slower periodic drift correction gets a chance to notice.
        if loop, expected + 0.025 < lastExpectedTime { return false }
        let advanced = lastExpectedTime + (sceneTime - lastSceneTime) * rate
        let expectedContinuation: Double
        if loop, duration > 0 { expectedContinuation = advanced.truncatingRemainder(dividingBy: duration) }
        else { expectedContinuation = min(duration, advanced) }
        return abs(expectedContinuation - expected) < 0.025
    }

    private func cancelPendingSeek() {
        seekGeneration &+= 1
        seekPending = false
        pendingSeekTime = nil
        pendingSeekStartedAt = nil
        completionAlignmentBudget = 0
    }

    private func pauseTransport(cancelPending: Bool = true) {
        if cancelPending { cancelPendingSeek() }
        player?.pause()
        transportRunning = false
    }

    private var transportPermitted: Bool {
        trackCount == 1 && outputEnabled && presentationActive && requestedPlaying && requestedRate > 0
            && (requestedLoop || expectedTime < duration - 0.000_001)
    }

    private func completeSeek(_ generation: Int, completed: Bool) {
        guard generation == seekGeneration else { return }
        let seekTarget = pendingSeekTime ?? expectedTime
        let seekElapsed = max(0, ProcessInfo.processInfo.systemUptime - (pendingSeekStartedAt ?? ProcessInfo.processInfo.systemUptime))
        seekPending = false; pendingSeekTime = nil; pendingSeekStartedAt = nil
        guard completed, transportPermitted else {
            pauseTransport(cancelPending: false)
            return
        }
        // Do not start audible playback at a known stale cursor. Scene time is
        // monotonic while a live presentation is active, so the observed
        // latency gives one bounded prediction for the retarget's completion.
        // The budget deliberately prevents AVFoundation latency from causing
        // a self-sustaining seek chain; the ordinary 0.75 s drift policy then
        // remains the fallback if that one prediction is still imperfect.
        if playbackDistance(seekTarget, expectedTime, loop: requestedLoop) > 0.025,
           completionAlignmentBudget > 0, let player {
            completionAlignmentBudget -= 1
            completionAlignmentCorrections += 1
            beginSeek(player, expected: advanceExpected(expectedTime, by: seekElapsed), resetCompletionAlignmentBudget: false)
            return
        }
        player?.playImmediately(atRate: Float(requestedRate))
        transportRunning = true
    }

    private func beginSeek(_ player: AVPlayer, expected: Double, resetCompletionAlignmentBudget: Bool = true) {
        seekGeneration &+= 1
        let generation = seekGeneration
        if resetCompletionAlignmentBudget { completionAlignmentBudget = 1 }
        seekPending = true; pendingSeekTime = expected; pendingSeekStartedAt = ProcessInfo.processInfo.systemUptime
        player.pause(); transportRunning = false
        player.seek(to: CMTime(seconds: expected, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
            // AVFoundation does not promise this callback arrives on the main
            // thread. The generation check below makes a late completion from
            // an obsolete seek unable to restart a paused/secondary player.
            Task { @MainActor [weak self] in self?.completeSeek(generation, completed: completed) }
        }
        seekCount += 1
    }

    func setOutputEnabled(_ enabled: Bool) {
        outputEnabled = enabled
        if !enabled {
            presentationActive = false
            pauseTransport()
        }
    }

    func suspend() {
        presentationActive = false
        pauseTransport()
    }

    func synchronize(playback: SceneVideoPlayback?, sceneTime: Double, active: Bool, outputEnabled: Bool) {
        synchronizationCount += 1
        self.outputEnabled = outputEnabled
        presentationActive = active
        let playing = playback?.playing ?? true
        let loop = playback?.loop ?? true
        let rate = playback?.rate ?? 1
        let expected = playback?.time(at: sceneTime, duration: duration)
            ?? sceneTime.truncatingRemainder(dividingBy: duration)
        requestedPlaying = playing; requestedRate = rate; requestedLoop = loop; expectedTime = expected
        defer {
            lastSceneTime = sceneTime; lastExpectedTime = expected; lastRate = rate; lastLoop = loop
        }
        // A zero rate is visually a frozen video frame. Do not ask AVPlayer
        // to play at zero, and never emit audio past a non-looping endpoint.
        let mayRun = trackCount == 1 && outputEnabled && active && playing && rate > 0
            && (loop || expected < duration - 0.000_001)
        guard mayRun, let player = makePlayer() else {
            pauseTransport()
            return
        }
        let isContinuous = continuous(sceneTime: sceneTime, expected: expected, rate: rate, loop: loop)
        let shouldCheckDrift = sceneTime - lastDriftCheckSceneTime >= 0.75
        let drifted: Bool
        if shouldCheckDrift {
            lastDriftCheckSceneTime = sceneTime
            if let playerTime = currentPlayerTime() {
                // Across a loop boundary either representation is valid until
                // the explicit seek, so compare the shorter circular distance.
                drifted = playbackDistance(playerTime, expected, loop: loop) > 0.20
            } else { drifted = true }
        } else { drifted = false }
        if seekPending {
            // A normal 60 fps clock update can advance while an exact seek is
            // completing. Do not queue a seek per frame: a >50 ms seek is
            // still valid while the scene clock naturally advances. Only an
            // actual script seek/rate/loop change or clock jump supersedes it.
            if !isContinuous { beginSeek(player, expected: expected) }
            return
        }
        if !transportRunning || !isContinuous || drifted { beginSeek(player, expected: expected) }
        else { player.playImmediately(atRate: Float(rate)) }
    }

    var state: [String: Any] {
        ["audioTrackCount": trackCount, "audioOutputEnabled": outputEnabled,
         "presentationActive": presentationActive, "requestedPlaying": requestedPlaying,
         "transportRunning": transportRunning, "expectedTime": expectedTime,
         "requestedRate": requestedRate, "actualRate": Double(player?.rate ?? 0),
         // Scene-video audio has no authored per-layer volume input. It is
         // deliberately AVPlayer unity gain, unlike SceneSoundLayer volume.
         "unityGain": Double(player?.volume ?? 1), "playerTime": currentPlayerTime() ?? -1,
         "synchronizations": synchronizationCount, "seeks": seekCount,
         "completionAlignmentCorrections": completionAlignmentCorrections]
    }

    var diagnostic: String {
        guard trackCount > 0 else { return " · 内嵌音轨：无" }
        guard trackCount == 1 else { return " · 内嵌音轨：检测到 \(trackCount) 条，当前仅启用单轨 MP4" }
        return String(format: " · 内嵌音轨 %d 轨 · unity gain · 主输出=%@ · 活跃=%@ · 传输=%@ · 目标 %.3f · seek %d",
            trackCount, outputEnabled ? "是" : "否", presentationActive ? "是" : "否",
            transportRunning ? "运行" : "暂停", expectedTime, seekCount)
    }
}

/// A coalescing mailbox keeps at most one pending request per movie, regardless
/// of render rate. The main thread never waits for decoding or file access.
final class SceneVideoRuntime: @unchecked Sendable {
    let asset: SceneVideoAsset
    private let queue = DispatchQueue(label: "io.wallpaper-engine-native.scene-video", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: Double?, busy = false
    private var latest: SceneVideoFrame
    private var failure: Error?
    private var lastRequested = -1.0
    private var decoded = 0
    private var completedTime = 0.0
    private var didDecode: (@Sendable () -> Void)?
    private let stream: SceneVideoStream
    /// All methods touching this transport are called by a main-actor
    /// renderer. The decode worker never accesses it.
    private let audio: SceneVideoAudioTransport
    @MainActor init(_ asset: SceneVideoAsset) {
        self.asset = asset; latest = asset.firstFrame
        stream = SceneVideoStream(asset: asset.asset, track: asset.track, width: asset.width, height: asset.height, duration: asset.duration)
        audio = SceneVideoAudioTransport(asset: asset.asset, duration: asset.duration, trackCount: asset.audioTrackCount)
    }
    func frame(at time: Double) throws -> SceneVideoFrame {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        let time = min(max(0, time), asset.duration)
        if time != lastRequested {
            lastRequested = time; pending = time
            if !busy { busy = true; queue.async { [weak self] in self?.drain() } }
        }
        return latest
    }
    func ready(at time: Double) throws -> Bool {
        _ = try frame(at: time)
        lock.lock(); defer { lock.unlock() }
        return completedTime == min(max(0, time), asset.duration)
    }
    func setDidDecode(_ callback: @escaping @Sendable () -> Void) {
        lock.lock(); didDecode = callback; lock.unlock()
    }
    /// Synchronize once per live presentation frame. `active` is supplied by
    /// the renderer only after its first frame is submitted, preventing sound
    /// from image preparation, hidden candidates, or secondary displays.
    @MainActor func syncAudio(playback: SceneVideoPlayback?, sceneTime: Double, active: Bool, outputEnabled: Bool) {
        audio.synchronize(playback: playback, sceneTime: sceneTime, active: active, outputEnabled: outputEnabled)
    }
    /// Owner changes must stop a non-owner immediately; waiting for another
    /// GPU frame would leave a short but user-visible duplicated audio tail.
    @MainActor func setAudioOutputEnabled(_ enabled: Bool) { audio.setOutputEnabled(enabled) }
    @MainActor func suspendAudio() { audio.suspend() }
    /// Transport telemetry, not an acoustic measurement. Automated tests use
    /// a digital-silence AAC fixture, so `transportRunning` deliberately does
    /// not claim that a listener heard output from a physical device.
    @MainActor var audioRuntimeState: [String: Any] { audio.state }
    private func drain() {
        while true {
            lock.lock()
            guard let time = pending else { busy = false; lock.unlock(); return }
            pending = nil; lock.unlock()
            let result = Result { try autoreleasepool { try stream.frame(at: time) } }
            lock.lock()
            switch result { case .success(let frame): latest = frame; completedTime = time; decoded += 1
            case .failure(let error): failure = error; pending = nil; busy = false }
            let failed = failure != nil, callback = didDecode; lock.unlock()
            callback?()
            if failed { return }
        }
    }
    @MainActor var diagnostic: String {
        lock.lock(); defer { lock.unlock() }
        return String(format: "Scene 视频 %d×%d · %.3f 秒 · 目标 %.3f · 已解码 PTS %.3f · 请求完成 %d%@%@", asset.width, asset.height, asset.duration, lastRequested, latest.pts, decoded, failure.map { " · 错误 \($0.localizedDescription)" } ?? "", audio.diagnostic)
    }
}
