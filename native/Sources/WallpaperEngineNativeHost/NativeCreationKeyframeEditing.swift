import Foundation

/// A timing edit is prepared on a value copy. No destination key is replaced,
/// and a collision or capacity error leaves every source track untouched.
struct NativeCreationKeyframeEdit: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case move, copy
        var title: String { self == .move ? "移动" : "复制" }
    }
    let sourceFrames: [Int]
    /// The destination places the earliest selected time; all other times keep
    /// their original distance from this anchor.
    var sourceFrame: Int { sourceFrames.first ?? 0 }
    var destinationFrame: Int
    var properties: [NativeCreationProperty]
    var mode: Mode

    init(sourceFrame: Int, destinationFrame: Int, properties: [NativeCreationProperty], mode: Mode) {
        self.init(sourceFrames: [sourceFrame], destinationFrame: destinationFrame, properties: properties, mode: mode)
    }

    init(sourceFrames: [Int], destinationFrame: Int, properties: [NativeCreationProperty], mode: Mode) {
        self.sourceFrames = Set(sourceFrames).sorted()
        self.destinationFrame = destinationFrame; self.properties = properties; self.mode = mode
    }

    static func frame(seconds: Double, duration: Double) throws -> Int {
        guard duration.isFinite, (0.5...120).contains(duration), seconds.isFinite else {
            throw SceneError.invalid("目标时间需要位于 0 和作品时长之间。")
        }
        // The stored duration has always used its nearest 60 Hz frame as the
        // final key position. Accept that displayed endpoint after rounding.
        let end = (duration * NativeCreationMotion.fps).rounded() / NativeCreationMotion.fps
        guard seconds >= 0, seconds <= max(duration, end) else {
            throw SceneError.invalid("目标时间需要位于 0 和作品时长之间（按 1/60 秒对齐）。")
        }
        return Int((seconds * NativeCreationMotion.fps).rounded())
    }

    func applying(to document: NativeCreationDocument, layerID: UUID) throws -> NativeCreationDocument {
        _ = try document.validated()
        try NativeCreationLayerEditing.requireEditable([layerID], in: document)
        let end = Int((document.duration * NativeCreationMotion.fps).rounded())
        guard !sourceFrames.isEmpty, sourceFrames.allSatisfy({ (0...end).contains($0) }),
              (0...end).contains(destinationFrame), sourceFrame != destinationFrame else {
            throw SceneError.invalid("请选择不同的目标时间，且不要超出作品时长。")
        }
        let offset = destinationFrame - sourceFrame
        guard sourceFrames.allSatisfy({ (0...end).contains($0 + offset) }) else {
            throw SceneError.invalid("整组关键帧移动后超出作品时长，请为最后一个时间点留出空间。")
        }
        guard let layerIndex = document.layers.firstIndex(where: { $0.id == layerID }) else {
            throw SceneError.invalid("原图层已不存在，请重新选择关键帧。")
        }
        var tracks = document.layers[layerIndex].animationTracks
        let sources = Set(sourceFrames)
        let affected = tracks.indices.filter { index in
            properties.contains(tracks[index].property) && tracks[index].keys.contains { sources.contains($0.frame) }
        }
        let available = Set(affected.flatMap { tracks[$0].keys.map(\.frame) })
        guard sources.isSubset(of: available) else { throw SceneError.invalid("所选轨道在部分原时间没有关键帧，请重新选择。") }
        let collisions = affected.filter { index in
            let destinations = Set(tracks[index].keys.filter { sources.contains($0.frame) }.map { $0.frame + offset })
            // Moving onto another selected key is valid: it vacates its old
            // position in the same transaction. Copies keep the old keys.
            return tracks[index].keys.contains {
                destinations.contains($0.frame) && (mode == .copy || !sources.contains($0.frame))
            }
        }
        guard collisions.isEmpty else {
            let names = collisions.map { tracks[$0].property.title }.joined(separator: "、")
            throw SceneError.invalid("目标时间已有\(names)关键帧，请选择空位置；已有关键帧不会被覆盖。")
        }
        for index in affected {
            let keys = tracks[index].keys.filter { sources.contains($0.frame) }.map { key in
                var shifted = key; shifted.frame += offset; return shifted
            }
            if mode == .move { tracks[index].keys.removeAll { sources.contains($0.frame) } }
            tracks[index].keys.append(contentsOf: keys)
            tracks[index].keys.sort { $0.frame < $1.frame }
        }
        var result = document
        result.layers[layerIndex].tracks = tracks
        result.layers[layerIndex].keyframes = nil
        result.adoptTrackFormat()
        return try result.validated()
    }
}
