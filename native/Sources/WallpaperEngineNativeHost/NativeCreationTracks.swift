import Foundation

enum NativeCreationProperty: String, Codable, CaseIterable, Hashable, Sendable {
    case x, y, scaleX, scaleY, rotation, opacity

    var title: String {
        switch self {
        case .x: return "X 位置"
        case .y: return "Y 位置"
        case .scaleX: return "横向缩放"
        case .scaleY: return "纵向缩放"
        case .rotation: return "旋转"
        case .opacity: return "透明度"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .x, .y: return -32768...32768
        case .scaleX, .scaleY: return 0.01...8
        case .rotation: return -360...360
        case .opacity: return 0...1
        }
    }
    func value(in pose: NativeCreationPose) -> Double {
        switch self {
        case .x: return pose.x
        case .y: return pose.y
        case .scaleX: return pose.scaleX
        case .scaleY: return pose.scaleY
        case .rotation: return pose.rotation
        case .opacity: return pose.opacity
        }
    }
    func set(_ value: Double, in pose: inout NativeCreationPose) {
        switch self {
        case .x: pose.x = value
        case .y: pose.y = value
        case .scaleX: pose.scaleX = value
        case .scaleY: pose.scaleY = value
        case .rotation: pose.rotation = value
        case .opacity: pose.opacity = value
        }
    }
}

struct NativeCreationScalarKeyframe: Codable, Equatable, Sendable {
    var frame: Int
    var value: Double
    var interpolation: NativeCreationKeyframe.Interpolation = .smooth
    var curve: NativeCreationBezier?
}

struct NativeCreationTrack: Codable, Equatable, Sendable {
    var property: NativeCreationProperty
    var keys: [NativeCreationScalarKeyframe]
    var usesBezier: Bool { keys.contains { $0.interpolation == .bezier || $0.curve != nil } }

    func validated(endFrame: Int) throws {
        guard (1...64).contains(keys.count) else { throw SceneError.invalid("每条属性轨道需要 1–64 个关键帧。") }
        var previous = -1
        for key in keys {
            guard key.interpolation == .bezier ? key.curve?.isValid == true : key.curve == nil else {
                throw SceneError.invalid("贝塞尔过渡需要有效控制点，四个数值均为 0–1；其他过渡不能包含曲线数据。")
            }
            guard key.frame > previous, key.frame <= endFrame, key.value.isFinite, property.range.contains(key.value) else {
                throw SceneError.invalid("\(property.title)关键帧需按时间排序，位于作品时长内，且数值在有效范围内。")
            }
            previous = key.frame
        }
    }

    func value(at frame: Double) -> Double {
        guard let first = keys.first, let last = keys.last else { return 0 }
        if frame <= Double(first.frame) { return first.value }
        if frame >= Double(last.frame) { return last.value }
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
        case .bezier: fraction = a.curve?.value(at: fraction) ?? 0
        }
        return a.value + (b.value - a.value) * fraction
    }

    func interpolation(at frame: Int) -> NativeCreationKeyframe.Interpolation {
        keys.last(where: { $0.frame <= frame })?.interpolation ?? keys.first?.interpolation ?? .smooth
    }
    func curve(at frame: Int) -> NativeCreationBezier? {
        (keys.last(where: { $0.frame <= frame }) ?? keys.first)?.curve
    }
}

extension NativeCreationDocument.Layer {
    /// Legacy pose keys remain untouched until an animation edit is committed.
    /// Splitting each pose into six scalar keys preserves its interpolation.
    var animationTracks: [NativeCreationTrack] {
        if let tracks { return tracks }
        guard let keyframes, !keyframes.isEmpty else { return [] }
        return NativeCreationProperty.allCases.map { property in
            NativeCreationTrack(property: property, keys: keyframes.map {
                NativeCreationScalarKeyframe(frame: $0.frame, value: property.value(in: $0.pose), interpolation: $0.interpolation)
            })
        }
    }
    var scalarKeyframeCount: Int {
        tracks?.reduce(0, { $0 + $1.keys.count }) ?? (keyframes?.count ?? 0) * NativeCreationProperty.allCases.count
    }
    func frames(for properties: [NativeCreationProperty]) -> [Int] {
        Set(animationTracks.filter { properties.contains($0.property) }.flatMap { $0.keys.map(\.frame) }).sorted()
    }
    func hasAnimation(_ property: NativeCreationProperty) -> Bool {
        tracks?.contains(where: { $0.property == property && !$0.keys.isEmpty }) ?? !(keyframes ?? []).isEmpty
    }

    mutating func record(_ pose: NativeCreationPose, at frame: Int,
                         interpolation: NativeCreationKeyframe.Interpolation,
                         properties: [NativeCreationProperty] = NativeCreationProperty.allCases,
                         curve: NativeCreationBezier? = nil) {
        guard !properties.isEmpty else { return }
        var values = animationTracks
        for property in NativeCreationProperty.allCases where properties.contains(property) {
            var keys = values.first(where: { $0.property == property })?.keys ?? []
            let controls = interpolation == .bezier ? (curve ?? values.first(where: { $0.property == property })?.curve(at: frame) ?? .standard) : nil
            if keys.isEmpty && frame > 0 {
                keys.append(.init(frame: 0, value: property.value(in: basePose), interpolation: interpolation, curve: controls))
            }
            let key = NativeCreationScalarKeyframe(frame: frame, value: property.value(in: pose), interpolation: interpolation, curve: controls)
            if let index = keys.firstIndex(where: { $0.frame == frame }) { keys[index] = key }
            else { keys.append(key) }
            values.removeAll { $0.property == property }
            values.append(.init(property: property, keys: keys.sorted { $0.frame < $1.frame }))
        }
        tracks = NativeCreationProperty.allCases.compactMap { property in values.first { $0.property == property } }
        keyframes = nil
    }

    /// Inspector/canvas edits key only properties that already have a track.
    /// Untouched sampled fields never become keys, even when displayed rounded.
    mutating func edit(_ pose: NativeCreationPose, comparedTo previous: NativeCreationPose, at frame: Int,
                       properties: [NativeCreationProperty] = NativeCreationProperty.allCases) {
        for property in properties where property.value(in: pose) != property.value(in: previous) {
            if let track = animationTracks.first(where: { $0.property == property }) {
                record(pose, at: frame, interpolation: track.interpolation(at: frame), properties: [property], curve: track.curve(at: frame))
            } else {
                var base = basePose
                property.set(property.value(in: pose), in: &base)
                basePose = base
            }
        }
    }

    mutating func deleteKeys(at frame: Int, properties: [NativeCreationProperty]) {
        guard frames(for: properties).contains(frame) else { return }
        var values = animationTracks
        for index in values.indices where properties.contains(values[index].property) {
            values[index].keys.removeAll { $0.frame == frame }
        }
        tracks = values.filter { !$0.keys.isEmpty }; keyframes = nil
    }

    mutating func setInterpolation(_ value: NativeCreationKeyframe.Interpolation, at frame: Int,
                                   properties: [NativeCreationProperty], curve: NativeCreationBezier? = nil) {
        guard frames(for: properties).contains(frame) else { return }
        var values = animationTracks
        for index in values.indices where properties.contains(values[index].property) {
            if let key = values[index].keys.firstIndex(where: { $0.frame == frame }) {
                values[index].keys[key].interpolation = value
                values[index].keys[key].curve = value == .bezier ? (curve ?? values[index].keys[key].curve ?? .standard) : nil
            }
        }
        tracks = values; keyframes = nil
    }
}

extension NativeCreationDocument {
    mutating func adoptTrackFormat() {
        if layers.contains(where: { $0.tracks?.contains(where: \.usesBezier) == true }) { format = 4 }
        else if layers.contains(where: { $0.tracks != nil }) { format = max(format, 3) }
    }
}
