import Foundation
import simd

/// Camera layers are identified by a STRING `camera` member. Their optional
/// `path` resource is unrelated to the legacy scene.camera.paths loader.
final class NativeSceneCameras {
    struct TransformState {
        var origin: SIMD3<Float>
        var angles: SIMD3<Float>
    }
    struct Active {
        let index: Int
        let pose: NativeCameraPose
        let fov: Float
    }
    private struct Path {
        let sourceIndex: Int
        let visibility: Any?
        var graph: NativeCameraAnimationGraph
        let center: [NativeCameraAnimationCurve]
        let eye: [NativeCameraAnimationCurve]
        let up: [NativeCameraAnimationCurve]
        let zoom: NativeCameraAnimationCurve
        let fov: NativeCameraAnimationCurve
        var sampledZoom: Float = 1
        var sampledFOV: Float = 50
    }
    private final class Camera {
        let index: Int
        let name: String
        var paths: [Path]
        var selected: Int?
        var enabled: [Int] = []
        var randomBag: [Int] = []
        var lastRandom: Int?
        var base: TransformState?
        var local: TransformState?
        var lastValidPose: NativeCameraPose
        var lastQueueMode = "random"
        var transitions: UInt64 = 0
        var rejectedSamples: UInt64 = 0
        var sampledFrames: UInt64 = 0
        init(index: Int, name: String, paths: [Path], orthographic: Bool) {
            self.index = index; self.name = name; self.paths = paths
            lastValidPose = orthographic ? .orthographic : .perspective
        }

        func selectPath() -> Int? {
            guard !enabled.isEmpty else { return nil }
            if lastQueueMode == "sequential" {
                for offset in 1...max(1, paths.count) {
                    let candidate = ((selected ?? -1) + offset) % paths.count
                    if enabled.contains(candidate) { return candidate }
                }
                return nil
            }
            if randomBag.isEmpty { randomBag = enabled }
            let start = Int.random(in: randomBag.indices)
            // FairRandomPool removes each draw until refill and avoids an
            // immediate repeat across cycles when another item is available.
            for offset in 0..<randomBag.count {
                let candidate = (start + offset) % randomBag.count
                if randomBag[candidate] != lastRandom {
                    lastRandom = randomBag.remove(at: candidate); return lastRandom
                }
            }
            lastRandom = randomBag.remove(at: start); return lastRandom
        }
    }

    private(set) var indices: [Int]
    let diagnostics: [String]
    private var cameras: [Int: Camera]
    private let orthographic: Bool
    private(set) var active: Active?

    func retire(retainingSlots: Set<Int>) {
        indices.removeAll { !retainingSlots.contains($0) }
        cameras = cameras.filter { retainingSlots.contains($0.key) }
        nonIdentityParents.formIntersection(retainingSlots)
        if let active, !retainingSlots.contains(active.index) { self.active = nil }
    }
    private var previousSceneTime: Double?
    private var clockResets: UInt64 = 0
    private var invalidClockSteps: UInt64 = 0
    private var rejectedPoses: UInt64 = 0
    private var nonIdentityParents = Set<Int>()
    // Even hidden paths need the shared scene-time anchor to keep advancing;
    // otherwise enabling a camera after an idle interval would catch up that
    // entire hidden interval. Static cameras without paths remain demand-driven.
    var needsFrameUpdates: Bool { cameras.values.contains { !$0.paths.isEmpty } }
    var loadedPathCount: Int { cameras.values.reduce(0) { $0 + $1.paths.count } }

    func preserveRuntime(from previous: NativeSceneCameras, retainingSlots slots: Set<Int>, at time: Double) {
        for slot in slots where cameras[slot] != nil {
            if let old = previous.cameras[slot] { cameras[slot] = old }
        }
        previousSceneTime = max(time, previous.previousSceneTime ?? time)
        clockResets = previous.clockResets; invalidClockSteps = previous.invalidClockSteps
        rejectedPoses = previous.rejectedPoses
        nonIdentityParents = previous.nonIdentityParents.intersection(slots)
        if let active = previous.active, slots.contains(active.index) { self.active = active }
    }


    init(objects: [[String: Any]], orthographic: Bool, loadJSON: (String) throws -> [String: Any]) throws {
        let indices = objects.indices.filter { objects[$0]["camera"] is String }
        guard indices.count <= 256 else { throw SceneError.invalid("场景超过原生 256 个 Camera 对象上限。") }
        self.indices = indices; self.orthographic = orthographic
        var cameras: [Int: Camera] = [:], notes: [String] = []
        var inspectedPaths = 0, inspectedKeys = 0
        func note(_ text: String) { if notes.count < 64 { notes.append(text) } }
        for index in indices {
            let object = objects[index], name = object["name"] as? String ?? "Camera \(index + 1)"
            var paths: [Path] = []
            if let file = object["path"] as? String {
                do {
                    let document = try loadJSON(file)
                    guard let entries = document["paths"] as? [Any] else { throw SceneError.invalid("缺少 paths 数组。") }
                    guard entries.count <= 1024 - inspectedPaths else { throw SceneError.invalid("超过每场景 1024 项 Camera 路径读取上限。") }
                    inspectedPaths += entries.count
                    for (pathIndex, raw) in entries.enumerated() {
                        guard let item = raw as? [String: Any], let options = item["options"] as? [String: Any] else { continue }
                        do {
                            let graph = try NativeCameraAnimationGraph(options: options)
                            func vector(_ raw: Any?) throws -> [NativeCameraAnimationCurve] {
                                let object = raw as? [String: Any] ?? [:]
                                return try (0..<3).map { try NativeCameraAnimationCurve(object["c\($0)"], graph: graph, inspectedKeys: &inspectedKeys) }
                            }
                            let center = try vector(item["center"]), eye = try vector(item["eye"]), up = try vector(item["up"])
                            let zoom = try NativeCameraAnimationCurve(item["zoom"], graph: graph, inspectedKeys: &inspectedKeys)
                            let fov = try NativeCameraAnimationCurve(item["fov"], graph: graph, inspectedKeys: &inspectedKeys)
                            paths.append(Path(sourceIndex: pathIndex, visibility: item["visible"], graph: graph,
                                center: center, eye: eye, up: up, zoom: zoom, fov: fov))
                            if let visibility = item["visible"] as? [String: Any], visibility["script"] != nil || visibility["animation"] != nil {
                                note("\(name) 路径 \(pathIndex + 1)：外部路径 visible 的脚本/属性时间轴尚未接入，保留 value/user 值。")
                            }
                        } catch { note("\(name) 路径 \(pathIndex + 1) 未加载：\(error.localizedDescription)") }
                    }
                } catch { note("\(name) 路径文件未加载：\(error.localizedDescription)；该 Camera 仍参与活动相机选择。") }
            }
            cameras[index] = Camera(index: index, name: name, paths: paths, orthographic: orthographic)
            note("Camera \(name)：加载 \(paths.count) 条路径；按对象顺序及完整父链可见性选择，路径曲线不经过通用属性时间轴。")
        }
        if !indices.isEmpty {
            note("Camera 对象为基于 REA 的原生实现；当前活动对象和路径状态见运行快照，随机顺序不承诺与参考同种子一致。Camera 专用 SceneScript 方法及外部路径脚本仍待适配。")
        }
        self.cameras = cameras; diagnostics = notes
    }

    /// Read-only merge: unchanged authored/user properties retain the local
    /// pose written by the previous path update. Timeline and script output
    /// are applied by the renderer AFTER this base, so they retain priority.
    func state(index: Int, base: TransformState) -> TransformState {
        guard let camera = cameras[index], let previous = camera.base, let local = camera.local else { return base }
        return TransformState(origin: base.origin == previous.origin ? local.origin : base.origin,
            angles: base.angles == previous.angles ? local.angles : base.angles)
    }

    /// All visible camera layers update, even those not currently selected.
    /// Only this method advances clocks. It returns the SAME final hierarchy
    /// snapshot that rendering uses for camera children and other layers.
    func advance(to time: Double, states: inout [[String: Any]], bases: [Int: TransformState],
                 hierarchy: SceneHierarchy, localVisibility: [Bool], transform: ([String: Any]) -> simd_float4x4,
                 resolve: (Any?) -> Any?,
                 displayOrder: [Int]? = nil,
                 beforeObject: (Int, simd_float4x4, Bool, inout [String: Any]) throws -> Void = { _, _, _, _ in }) rethrows -> (transforms: [simd_float4x4], visible: [Bool]) {
        var local = states.map(transform)
        // Preserve the renderer's existing property coercion for ALL layers;
        // strict JSON booleans below apply only to external Camera paths.
        let visibility = hierarchy.resolve(local: local, visible: localVisibility).visible
        var delta: Float = 0, advances = false
        if time.isFinite, time >= 0 {
            advances = time != previousSceneTime
            if let previous = previousSceneTime, time < previous {
                for camera in cameras.values {
                    for i in camera.paths.indices { camera.paths[i].graph.reset() }
                    camera.selected = nil; camera.randomBag = []; camera.lastRandom = nil
                }
                Self.increment(&clockResets)
            } else if let previous = previousSceneTime { delta = Float(time - previous) }
            previousSceneTime = time
            if !delta.isFinite { delta = 0; advances = false; Self.increment(&invalidClockSteps) }
        } else { Self.increment(&invalidClockSteps) }

        func world(_ index: Int) -> simd_float4x4 {
            var chain = [index], cursor = hierarchy.parents[index]
            while let parent = cursor { chain.append(parent); cursor = hierarchy.parents[parent] }
            return chain.reversed().reduce(matrix_identity_float4x4) { $0 * local[$1] }
        }
        // Models and cameras share one parent-first pass. A camera path must
        // see this frame's moved model parent; a model parented to a camera
        // must likewise see the camera path's current transform.
        for index in hierarchy.order {
            let parent = hierarchy.invalid.contains(index) ? matrix_identity_float4x4 : hierarchy.parents[index].map(world) ?? matrix_identity_float4x4
            try beforeObject(index, parent, visibility[index], &states[index])
            local[index] = transform(states[index])
            guard let camera = cameras[index] else { continue }
            let enabled = camera.paths.indices.filter { Self.visible(resolve(camera.paths[$0].visibility)) }
            if enabled != camera.enabled {
                let added = enabled.filter { !camera.enabled.contains($0) }
                camera.randomBag.removeAll { !enabled.contains($0) }
                camera.randomBag.append(contentsOf: added)
                camera.enabled = enabled
            }
            // Unknown/non-string queue names use the first enum value, random.
            camera.lastQueueMode = states[index]["queuemode"] as? String == "sequential" ? "sequential" : "random"
            if advances, visibility[index], !enabled.isEmpty {
                if let selected = camera.selected, camera.paths[selected].graph.completed {
                    camera.paths[selected].graph.reset()
                    camera.selected = camera.selectPath(); Self.increment(&camera.transitions)
                } else if camera.selected == nil {
                    camera.selected = camera.selectPath(); Self.increment(&camera.transitions)
                }
                if let selected = camera.selected {
                    let updated = camera.paths[selected].graph.advance(delta: delta)
                    let matrix = world(index)
                    if let parent = hierarchy.parents[index], !Self.isIdentity(world(parent)) { nonIdentityParents.insert(index) }
                    if updated, let sample = camera.paths[selected].graph.sample,
                       let result = Self.sample(camera.paths[selected], at: sample, world: matrix, orthographic: orthographic) {
                        var candidateState = states[index]
                        candidateState["origin"] = [result.state.origin.x, result.state.origin.y, result.state.origin.z]
                        candidateState["angles"] = [result.state.angles.x, result.state.angles.y, result.state.angles.z]
                        let candidate = transform(candidateState)
                        if Self.finite(candidate) {
                            states[index] = candidateState
                            local[index] = candidate
                            camera.paths[selected].sampledZoom = result.zoom
                            camera.paths[selected].sampledFOV = result.fov
                            Self.increment(&camera.sampledFrames)
                        } else {
                            // Other layers retain the entire input local pose.
                            Self.increment(&camera.rejectedSamples)
                        }
                    } else { Self.increment(&camera.rejectedSamples) }
                }
            }
            camera.base = bases[index]
            camera.local = TransformState(origin: Self.vector(states[index]["origin"], fallback: .zero),
                angles: Self.vector(states[index]["angles"], fallback: .zero))
        }
        let resolved = hierarchy.resolve(local: local, visible: visibility)
        active = nil
        if let index = (displayOrder ?? indices).reversed().first(where: { cameras[$0] != nil && resolved.visible[$0] }), let camera = cameras[index] {
            let matrix = resolved.transforms[index]
            let eye = Self.xyz(matrix.columns.3)
            let zoom = camera.selected.map { camera.paths[$0].sampledZoom } ?? Self.scalar(states[index]["zoom"], fallback: 1)
            let fov = camera.selected.map { camera.paths[$0].sampledFOV } ?? Self.scalar(states[index]["fov"], fallback: 50)
            // Getters use raw columns, without Update's normalize or *5.
            let pose = NativeCameraPose(eye: eye, center: eye - Self.xyz(matrix.columns.2), up: Self.xyz(matrix.columns.1), zoom: zoom)
            if pose.frame() != nil { camera.lastValidPose = pose } else { Self.increment(&rejectedPoses) }
            active = Active(index: index, pose: camera.lastValidPose, fov: fov.isFinite ? fov : 50)
        }
        return resolved
    }

    private static func sample(_ path: Path, at sample: (frame: Int, next: Int, fraction: Float),
                               world: simd_float4x4, orthographic: Bool) -> (state: TransformState, zoom: Float, fov: Float)? {
        guard finite(world), let z = normalized(xyz(world.columns.2)), let up = normalized(xyz(world.columns.1)) else { return nil }
        let eye = xyz(world.columns.3), center = eye - z * 5
        func vector(_ curves: [NativeCameraAnimationCurve], fallback: SIMD3<Float>) -> SIMD3<Float>? {
            var result = fallback
            for i in 0..<3 {
                guard let value = curves[i].value(sample: sample, fallback: fallback[i]) else { return nil }
                result[i] = value
            }
            return result
        }
        guard let sampledEye = vector(path.eye, fallback: eye), let sampledCenter = vector(path.center, fallback: center),
              let sampledUp = vector(path.up, fallback: up),
              let forward = normalized(sampledCenter - sampledEye), let right = normalized(simd_cross(forward, sampledUp)) else { return nil }
        // Camera::Update's Euler extraction. The resulting pose is written to
        // LOCAL origin/rotation, even though defaults above came from WORLD.
        let az = atan2(right.y, right.x)
        let ay = atan2(-right.z, sqrt(forward.z * forward.z + pow(forward.y * right.x - forward.x * right.y, 2)))
        let cz = cos(az), sz = sin(az)
        let ax = atan2(forward.y * cz - forward.x * sz,
            cz * (forward.x * right.z - forward.z * right.x) - sz * (forward.z * right.y - forward.y * right.z))
        guard [ax, ay, az].allSatisfy(\.isFinite) else { return nil }
        let zoom = orthographic ? path.zoom.value(sample: sample, fallback: 1) : path.sampledZoom
        let fov = orthographic ? path.sampledFOV : path.fov.value(sample: sample, fallback: 50)
        guard let zoom, let fov else { return nil }
        return (TransformState(origin: sampledEye, angles: SIMD3(ax, ay, az)), zoom, fov)
    }

    private static func xyz(_ vector: SIMD4<Float>) -> SIMD3<Float> { SIMD3(vector.x, vector.y, vector.z) }
    private static func finite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }
    }
    private static func isIdentity(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { c in (0..<4).allSatisfy { abs(matrix[c][$0] - (c == $0 ? 1 : 0)) < 0.000001 } }
    }
    private static func normalized(_ vector: SIMD3<Float>) -> SIMD3<Float>? {
        let wide = SIMD3<Double>(vector), length = simd_length(wide)
        guard length.isFinite, length > 0 else { return nil }
        return SIMD3<Float>(wide / length)
    }
    private static func scalar(_ raw: Any?, fallback: Float) -> Float {
        let value = NativeCameraJSON.number(raw)?.floatValue ?? (raw as? String).flatMap(Float.init)
        return value?.isFinite == true ? value! : fallback
    }
    private static func vector(_ raw: Any?, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let values: [Float]
        if let text = raw as? String { values = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Float($0) } }
        else if let array = raw as? [NSNumber] { values = array.map(\.floatValue) }
        else if let dictionary = raw as? [String: Any] { values = ["x", "y", "z"].compactMap { NativeCameraJSON.number(dictionary[$0])?.floatValue } }
        else { values = [] }
        return values.count >= 3 && values.prefix(3).allSatisfy(\.isFinite) ? SIMD3(values[0], values[1], values[2]) : fallback
    }
    private static func visible(_ raw: Any?) -> Bool {
        NativeCameraJSON.boolean(raw) ?? NativeCameraJSON.boolean((raw as? [String: Any])?["value"]) ?? true
    }
    private static func increment(_ count: inout UInt64) { if count != .max { count += 1 } }

    var runtimeDiagnostic: String {
        let selection: String
        if let active, let camera = cameras[active.index] {
            var pathState = "无活动路径，使用对象属性"
            if let selected = camera.selected {
                let path = camera.paths[selected]
                pathState = "路径=\(path.sourceIndex + 1)，\(path.graph.mode.rawValue)，时间=\(path.graph.time)/\(path.graph.duration)，反向=\(path.graph.reversed)，完成=\(path.graph.completed)，startpaused=\(path.graph.startPaused)"
            }
            selection = "活动=\(camera.name)（图层 \(active.index + 1)）；\(pathState)；队列=\(camera.lastQueueMode)，可见路径=\(camera.enabled.count)/\(camera.paths.count)，选择次数=\(camera.transitions)，有效路径帧=\(camera.sampledFrames)，拒绝采样=\(camera.rejectedSamples)；eye=\(active.pose.eye)，center=\(active.pose.center)，up=\(active.pose.up)，zoom=\(active.pose.zoom)，fov=\(active.fov)"
        } else { selection = "无活动 Camera 对象，使用旧版路径或基础相机" }
        let parentNote = nonIdentityParents.isEmpty ? "" : "；非恒等父级 Camera 图层=\(nonIdentityParents.sorted().map { $0 + 1 })，保留参考的世界默认值到局部写回顺序，待真实素材核对"
        return "Camera 对象运行快照：共 \(indices.count) 个；\(selection)；时钟重置=\(clockResets)，无效计时步=\(invalidClockSteps)，无效最终姿态保留上一值=\(rejectedPoses)\(parentNote)。"
    }
}
