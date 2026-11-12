import Foundation

/// Native authoring data. These curves are evaluated directly by the desktop
/// renderer and by the editor; they do not execute author-supplied code.
struct NativeCreationPose: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var scaleX: Double = 1
    var scaleY: Double = 1
    var rotation: Double
    var opacity: Double

    var isValid: Bool {
        [x, y, scaleX, scaleY, rotation, opacity].allSatisfy(\.isFinite)
            && abs(x) <= 32768 && abs(y) <= 32768
            && (0.01...8).contains(scaleX) && (0.01...8).contains(scaleY)
            && (-360...360).contains(rotation) && (0...1).contains(opacity)
    }
    func blended(to other: Self, fraction: Double) -> Self {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * fraction }
        return Self(x: mix(x, other.x), y: mix(y, other.y),
                    scaleX: mix(scaleX, other.scaleX), scaleY: mix(scaleY, other.scaleY),
                    rotation: mix(rotation, other.rotation), opacity: mix(opacity, other.opacity))
    }
}

struct NativeCreationKeyframe: Codable, Equatable, Sendable {
    enum Interpolation: String, Codable, CaseIterable, Sendable {
        case linear, smooth, hold, bezier
        var title: String {
            switch self { case .linear: return "匀速"; case .smooth: return "平滑起止"; case .hold: return "保持到下一帧"; case .bezier: return "贝塞尔曲线" }
        }
    }
    var frame: Int
    var pose: NativeCreationPose
    var interpolation: Interpolation = .smooth
}

struct NativeCreationMotion: Codable, Equatable, Sendable {
    var format = 1
    var duration: Double
    var loop: Bool
    var base: NativeCreationPose
    var keys: [NativeCreationKeyframe]
    var swing: Double
    var period: Double
    var tracks: [NativeCreationTrack]?
    static let fps = 60.0
    var scalarKeyframeCount: Int { tracks?.reduce(0, { $0 + $1.keys.count }) ?? keys.count * NativeCreationProperty.allCases.count }
    var hasKeyframes: Bool { scalarKeyframeCount > 0 }

    func validated() throws -> Self {
        guard [1, 2, 3].contains(format), duration.isFinite, (0.5...120).contains(duration), base.isValid,
              swing.isFinite, (0...45).contains(swing), period.isFinite, (1...120).contains(period),
              keys.count <= 64 else { throw SceneError.invalid("动画参数无效：时长为 0.5–120 秒，每层最多 64 个关键帧，缩放为 0.01–8。") }
        guard (format == 1 && tracks == nil) || (format >= 2 && tracks != nil && keys.isEmpty) else {
            throw SceneError.invalid("动画格式与轨道数据不一致。")
        }
        var previous = -1
        let end = Int((duration * Self.fps).rounded())
        if let tracks {
            guard format >= 3 || !tracks.contains(where: \.usesBezier) else {
                throw SceneError.invalid("贝塞尔曲线需要原生动画格式 3。")
            }
            guard tracks.count <= NativeCreationProperty.allCases.count, Set(tracks.map(\.property)).count == tracks.count else {
                throw SceneError.invalid("每个属性只能有一条动画轨道。")
            }
            for track in tracks { try track.validated(endFrame: end) }
        }
        for key in keys {
            guard key.frame > previous, key.frame <= end, key.pose.isValid, key.interpolation != .bezier else {
                throw SceneError.invalid("关键帧需按时间排序、位于作品时长以内且参数有效。缩短时长前请先移除超出范围的关键帧。")
            }
            previous = key.frame
        }
        return self
    }

    func localTime(_ time: Double, preserveEndpoint: Bool = false) -> Double {
        let time = time.isFinite ? max(0, time) : 0
        if preserveEndpoint { return min(duration, time) }
        return loop ? time.truncatingRemainder(dividingBy: duration) : min(duration, time)
    }

    func pose(at time: Double, preserveEndpoint: Bool = false, includeSwing: Bool = true) -> NativeCreationPose {
        let time = time.isFinite ? max(0, time) : 0
        if let tracks {
            var result = base
            let frame = localTime(time, preserveEndpoint: preserveEndpoint) * Self.fps
            for track in tracks { track.property.set(track.value(at: frame), in: &result) }
            if includeSwing && !tracks.contains(where: { $0.property == .rotation }) {
                result.rotation += sin(time * 2 * .pi / period) * swing
            }
            return result
        }
        guard let first = keys.first, let last = keys.last else {
            var result = base
            // Legacy simple swing keeps its own period until keyframes are added.
            if includeSwing { result.rotation += sin(time * 2 * .pi / period) * swing }
            return result
        }
        let frame = localTime(time, preserveEndpoint: preserveEndpoint) * Self.fps
        if frame <= Double(first.frame) { return first.pose }
        if frame >= Double(last.frame) { return last.pose }
        var low = 0, high = keys.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if Double(keys[middle].frame) <= frame { low = middle } else { high = middle }
        }
        let a = keys[low], b = keys[high]
        var fraction = (frame - Double(a.frame)) / Double(b.frame - a.frame)
        switch a.interpolation {
        case .linear: break
        case .smooth: fraction = fraction * fraction * (3 - 2 * fraction)
        case .hold: fraction = 0
        case .bezier: fraction = 0 // Rejected for legacy pose keys by validated().
        }
        return a.pose.blended(to: b.pose, fraction: fraction)
    }
}

extension NativeCreationDocument.Layer {
    var basePose: NativeCreationPose {
        get { NativeCreationPose(x: x, y: y, scaleX: scaleX ?? 1, scaleY: scaleY ?? 1, rotation: rotation, opacity: opacity) }
        set { x = newValue.x; y = newValue.y; scaleX = newValue.scaleX; scaleY = newValue.scaleY; rotation = newValue.rotation; opacity = newValue.opacity }
    }
    func motion(duration: Double, loop: Bool) -> NativeCreationMotion {
        NativeCreationMotion(format: tracks == nil ? 1 : (tracks!.contains(where: \.usesBezier) ? 3 : 2), duration: duration, loop: loop, base: basePose,
                             keys: keyframes ?? [], swing: swing, period: period, tracks: tracks)
    }
}
