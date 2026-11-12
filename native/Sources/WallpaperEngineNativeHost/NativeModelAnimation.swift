import Foundation
import simd

/// Owned MDLA layer player shared by the two native GPU backends. REA evidence
/// describes Float graph clocks, shortest-hemisphere normalized lerp, ordered
/// pose blending and bind-relative additive rotation. It is not a binary port.
enum NativeModelAnimation {
    struct Controls {
        let rate: Float, blend: Float, blendTime: Float
        let visible: Bool, additive: Bool, blendIn: Bool, blendOut: Bool
    }
    struct Layer {
        let key: String
        let clip: NativeModelSkeleton.Clip
        let raw: [String: Any]
        func controls(samples: [String: Any] = [:], overrides: [String: Any] = [:], resolve: (Any?) -> Any?) throws -> Controls {
            let raw = raw.merging(samples) { _, value in value }.merging(overrides) { _, value in value }
            func number(_ key: String, _ fallback: Float, _ range: ClosedRange<Float>) throws -> Float {
                guard let raw = raw[key] else { return fallback }
                guard let value = NativeAnimationJSON.number(resolve(raw))?.floatValue,
                      value.isFinite, range.contains(value) else {
                    throw SceneError.invalid("模型动画层 \(self.key) 的 \(key) 数值无效。")
                }
                return value
            }
            func flag(_ key: String, _ fallback: Bool) throws -> Bool {
                guard let raw = raw[key] else { return fallback }
                guard let value = NativeAnimationJSON.boolean(resolve(raw)) else {
                    throw SceneError.invalid("模型动画层 \(self.key) 的 \(key) 需要布尔值。")
                }
                return value
            }
            return try Controls(rate: number("rate", 1, -100...100), blend: number("blend", 1, 0...1),
                blendTime: number("blendtime", 0.5, 0...3600), visible: flag("visible", true),
                additive: flag("additive", false), blendIn: flag("blendin", false), blendOut: flag("blendout", false))
        }
    }
    struct Source {
        let skeleton: NativeModelSkeleton
        // Property paths and helper metadata address this original file order.
        let layers: [Layer]
        let initialOrder: [Int]
        let bind: [NativeModelSkeleton.Key]

        static func make(_ raw: Any?, skeleton: NativeModelSkeleton?, includeEmpty: Bool = false, resolve: (Any?) -> Any? = { $0 }) throws -> Source? {
            let raw = raw ?? NSNull()
            if raw is NSNull || (raw as? [Any])?.isEmpty == true {
                guard includeEmpty, let skeleton, !skeleton.clips.isEmpty,
                      let bind = try? skeleton.bones.map({ try decompose($0.localBind) }) else { return nil }
                return Source(skeleton: skeleton, layers: [], initialOrder: [], bind: bind)
            }
            guard let array = raw as? [Any], array.count <= 32 else { throw SceneError.invalid("模型动画层需要数组，最多 32 层。") }
            if array.isEmpty { return nil }
            guard let skeleton else { throw SceneError.invalid("模型动画层缺少骨架。") }
            var layers: [Layer] = [], order: [Int] = [], keys = Set<String>()
            for (index, raw) in array.enumerated() {
                guard let object = raw as? [String: Any], Set(object.keys).isSubset(of:
                    ["id", "name", "animation", "rate", "blend", "visible", "additive", "blendin", "blendout", "blendtime", "autosort", "index"]) else {
                    throw SceneError.invalid("模型动画层含未支持字段；动画蒙版尚未接入。")
                }
                guard let number = NativeAnimationJSON.number(object["animation"]),
                      let id = UInt64(number.stringValue), let clip = skeleton.clips.first(where: { $0.id == id }) else {
                    throw SceneError.invalid("模型动画层没有有效的 MDLA 动画编号。")
                }
                let key: String
                if let id = object["id"] {
                    guard let n = NativeAnimationJSON.number(id), let value = UInt64(n.stringValue) else {
                        throw SceneError.invalid("模型动画层 ID 需要非负整数。")
                    }
                    key = "id:\(value)"
                } else { key = "index:\(index)" }
                guard keys.insert(key).inserted else { throw SceneError.invalid("模型动画层 ID 重复。") }
                if let name = object["name"] { guard let name = name as? String, name.utf8.count <= 4096 else { throw SceneError.invalid("模型动画层名称无效。") } }
                for property in ["rate", "blend", "visible", "additive", "blendin", "blendout", "blendtime"] {
                    if let binding = object[property] as? [String: Any] {
                        guard binding["value"] != nil, Set(binding.keys).isSubset(of: ["value", "user", "script", "scriptproperties", "animation"]) else {
                            throw SceneError.invalid("模型动画层 \(property) 的属性绑定无效。")
                        }
                        if let script = binding["script"] {
                            guard let script = script as? String, script.utf8.count <= 256 * 1024 else { throw SceneError.invalid("模型动画层属性脚本无效。") }
                        }
                        if let values = binding["scriptproperties"], !(values is [String: Any]) { throw SceneError.invalid("模型动画层脚本设置无效。") }
                        if let graph = binding["animation"] {
                            guard NativeModelProperties.numbers.contains(property) else { throw SceneError.invalid("模型动画层布尔属性不接受数值时间轴。") }
                            try NativeMetalSceneAnimation.validate(graph, at: "/objects/0/animationlayers/\(index)/\(property)")
                        }
                        if let user = binding["user"] {
                            guard user is String || (user as? [String: Any]).map({ Set($0.keys).isSubset(of: ["name", "condition"]) && $0["name"] is String }) == true else {
                                throw SceneError.invalid("模型动画层用户属性绑定无效。")
                            }
                        }
                    }
                }
                let layer = Layer(key: key, clip: clip, raw: object)
                _ = try layer.controls(resolve: resolve)
                let insertion = try insertionIndex(object, count: order.count) {
                    try layers[order[$0]].controls(resolve: resolve).additive
                }
                order.insert(layers.count, at: insertion)
                layers.append(layer)
            }
            return try Source(skeleton: skeleton, layers: layers, initialOrder: order, bind: skeleton.bones.map { try decompose($0.localBind) })
        }
    }

    /// Shared file/script insertion rule. The reference clamps a numeric index
    /// outside an existing stack to its last slot (before that slot's layer).
    /// Empty/all-additive stacks use a safe front insertion. Ordering options
    /// are scalar construction metadata, not animatable property bindings.
    static func insertionIndex(_ config: [String: Any], count: Int, additiveAt: (Int) throws -> Bool) throws -> Int {
        var insertion = count
        if let raw = config["index"] {
            guard let number = NativeAnimationJSON.number(raw), let index = NativeAnimationJSON.integer(raw),
                  number.doubleValue == Double(index) else {
                throw SceneError.invalid("模型动画层 index 需要 32 位整数。")
            }
            insertion = (0..<count).contains(index) ? index : max(0, count - 1)
        }
        if let raw = config["autosort"] {
            guard let auto = NativeAnimationJSON.boolean(raw) else { throw SceneError.invalid("模型动画层 autosort 需要布尔值。") }
            if auto {
                insertion = 0
                for index in (0..<count).reversed() where try !additiveAt(index) { insertion = index + 1; break }
            }
        }
        return insertion
    }

    struct State {
        var clock = SceneTimelinePlayback(paused: false)
        var wasActive = false
        var fadedIn = false
        var previousBlendIn = false
        var overrides: [String: Any] = [:]
        var single = false
        var removeAtEnd = false
        var suppressEndedOnce = false
        var pendingRemoval = false
        var rootCursor: NativeModelRootMotion.Cursor?
        var rootStoredPose = NativeModelRootMotion.Rigid(position: .zero, rotation: matrix_identity_float3x3)
        init(clip: NativeModelSkeleton.Clip? = nil) {
            if let clip {
                clock = SceneTimelinePlayback(paused: false, initialTime: Float(clip.initialFrame) * (1 / clip.fps))
            }
        }
    }
    final class Runtime {
        let source: Source
        private(set) var layers: [Layer]
        private(set) var states: [State]
        private(set) var removedAuthoredKeys = Set<String>()
        var deliverEvents = false
        private(set) var queuedEvents: [[String: Any]] = []
        private(set) var eventOverflow = false
        private(set) var palette: [Float]
        private(set) var revision: UInt64 = 0
        private(set) var advances = 0
        private(set) var lastTime: Double?
        private(set) var propertySamples: [String: [String: Any]] = [:]
        private(set) var motion: NativeModelRootMotion.ObjectState?
        private var motionWrites: [String: Any] = [:]
        private var rootDescriptions: [UInt64: NativeModelRootMotion.Description] = [:]
        var hasRootMotion: Bool { source.skeleton.clips.contains { $0.rootMotionFlags != 0 } }
        init(_ source: Source) {
            self.source = source
            let ordered = source.initialOrder.map { source.layers[$0] }
            layers = ordered
            states = ordered.map { State(clip: $0.clip) }
            palette = source.skeleton.defaultPalette
        }
        func preserveClock(from previous: Runtime) {
            let authored = Dictionary(uniqueKeysWithValues: source.layers.map { ($0.key, $0) })
            var retained: [Layer] = [], next: [State] = [], seen = Set<String>()
            for (index, old) in previous.layers.enumerated() {
                let layer = old.key.hasPrefix("script:") ? old : authored[old.key]
                guard let layer, layer.clip.id == old.clip.id else { continue }
                retained.append(layer); next.append(previous.states[index]); seen.insert(layer.key)
            }
            for index in source.initialOrder {
                let layer = source.layers[index]
                guard !seen.contains(layer.key) && !previous.removedAuthoredKeys.contains(layer.key) else { continue }
                retained.append(layer); next.append(State(clip: layer.clip))
            }
            layers = retained; states = next; removedAuthoredKeys = previous.removedAuthoredKeys
            queuedEvents = previous.queuedEvents; eventOverflow = previous.eventOverflow
            deliverEvents = previous.deliverEvents
            lastTime = previous.lastTime; advances = previous.advances
            propertySamples = previous.propertySamples
            motion = previous.motion; motionWrites = previous.motionWrites
        }
        struct Draft {
            var layers: [Layer], states: [State], removed: Set<String>
            var motionWrites: [String: Any]
        }
        var draft: Draft { Draft(layers: layers, states: states, removed: removedAuthoredKeys, motionWrites: motionWrites) }
        func commit(_ draft: Draft) {
            layers = draft.layers; states = draft.states; removedAuthoredKeys = draft.removed
            motionWrites = draft.motionWrites
            let live = Set(layers.map(\.key))
            // Destroyed handles have no ended callbacks. Keep already-emitted
            // markers, which belong to the model, across a delayed batch.
            queuedEvents.removeAll { $0["kind"] as? String == "ended" && !live.contains($0["key"] as? String ?? "") }
        }
        func takeEvents(maximum: Int = 128) -> [[String: Any]] {
            let result = Array(queuedEvents.prefix(max(0, maximum)))
            queuedEvents.removeFirst(result.count)
            return result
        }
        func disableEvents() {
            deliverEvents = false
            queuedEvents.removeAll(); eventOverflow = false
            retirePendingLayers()
        }
        private func retirePendingLayers() {
            for index in states.indices.reversed() where states[index].pendingRemoval {
                layers.remove(at: index); states.remove(at: index)
            }
        }
        func scriptState(resolve: (Any?) -> Any? = { ($0 as? [String: Any])?["value"] ?? $0 }) -> [[String: Any]] {
            layers.enumerated().map { index, layer in
                let value = try? layer.controls(samples: propertySamples[layer.key] ?? [:], overrides: states[index].overrides, resolve: resolve)
                return ["key": layer.key, "clip": String(layer.clip.id), "name": layer.raw["name"] as? String ?? "",
                        "clock": states[index].clock.json, "single": states[index].single,
                        "rate": value?.rate ?? 1, "blend": value?.blend ?? 1, "visible": value?.visible ?? true,
                        "additive": value?.additive ?? false, "blendin": value?.blendIn ?? false,
                        "blendout": value?.blendOut ?? false, "blendtime": value?.blendTime ?? 0.5,
                        "overrides": states[index].overrides.keys.sorted()]
            }
        }
        /// Repeated diagnostics/redraws at one scene time never advance time.
        /// Hidden intervals update the anchor but suspend that instance's clocks.
        func update(time: Double, visible: Bool, paused: Bool = false, samples: [String: [String: Any]] = [:],
                    motionInput: NativeModelRootMotion.Input? = nil, resolve: (Any?) -> Any? = { $0 }) throws {
            guard time.isFinite, time >= 0 else { throw SceneError.invalid("模型动画的场景时间无效。") }
            let delta = lastTime.map { max(0, time - $0) } ?? 0
            guard Float(delta).isFinite else { throw SceneError.invalid("模型动画时间步溢出。") }
            var next = states, pose = source.bind
            var nextMotion = motion
            if hasRootMotion {
                guard let motionInput else { throw SceneError.invalid("模型根运动缺少场景变换消费者。") }
                if nextMotion == nil { nextMotion = NativeModelRootMotion.ObjectState(motionInput) }
                try nextMotion?.prepare(motionInput, time: time, paused: paused, writes: motionWrites)
            }
            let controls = try layers.enumerated().map { index, layer in
                try layer.controls(samples: samples[layer.key] ?? [:], overrides: next[index].overrides, resolve: resolve)
            }
            var events: [[String: Any]] = [], ended: [[String: Any]] = []
            var contributed = false, didAdvance = false
            for (index, layer) in layers.enumerated() {
                let control = controls[index]
                let active = visible && control.visible && !next[index].pendingRemoval
                let step = active && next[index].wasActive && !paused ? Float(delta) : 0
                next[index].wasActive = active
                if control.blendIn != next[index].previousBlendIn { next[index].fadedIn = false }
                next[index].previousBlendIn = control.blendIn
                guard active else { continue }
                let duration = Float(layer.clip.frameCount) / layer.clip.fps, frameDuration = 1 / layer.clip.fps
                next[index].clock.setRate(control.rate)
                let before = next[index].clock.time
                let mode = layer.clip.mode
                let wasPlaying = next[index].clock.playing
                let wasReversed = next[index].clock.reversed
                var windows: [SceneTimelineEventWindow] = []
                guard next[index].clock.advance(delta: step, duration: duration, mode: mode, eventWindows: &windows),
                      let sample = next[index].clock.sample(length: layer.clip.frameCount, frameDuration: frameDuration) else {
                    throw SceneError.invalid("模型动画时钟无法安全推进。")
                }
                didAdvance = didAdvance || next[index].clock.time != before
                if deliverEvents {
                    for window in windows {
                        for (eventIndex, event) in layer.clip.events.enumerated() where window.contains(event.time) {
                            guard events.count < 1024 else { throw SceneError.invalid("模型动画单帧事件超过 1024 项；保留上一有效姿态。") }
                            events.append(["kind": "marker", "key": layer.key, "clip": String(layer.clip.id), "eventIndex": eventIndex])
                        }
                    }
                }
                let reachedEnd = mode == "single" ? next[index].clock.completed :
                    mode == "mirror" ? next[index].clock.reversed != wasReversed : next[index].clock.time < before
                if wasPlaying && !next[index].suppressEndedOnce && reachedEnd {
                    if deliverEvents { ended.append(["kind": "ended", "key": layer.key, "clock": next[index].clock.json]) }
                    if next[index].removeAtEnd { next[index].pendingRemoval = true }
                }
                next[index].suppressEndedOnce = false
                let weight = Self.autoBlend(control, clip: layer.clip, state: &next[index])
                guard weight.isFinite else { throw SceneError.invalid("模型动画混合权重溢出。") }
                if weight == 0 { next[index].rootCursor = nil; continue }
                for bone in pose.indices {
                    let keys = layer.clip.tracks[bone]
                    let value = try interpolate(keys[layer.clip.sampleStart + sample.frame], keys[layer.clip.sampleStart + sample.next], sample.fraction)
                    if control.additive {
                        let bind = source.bind[bone], current = pose[bone]
                        let delta = bind.rotation.conjugate * value.rotation
                        let rotation = current.rotation * (try nlerp(simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), delta, weight))
                        pose[bone] = NativeModelSkeleton.Key(position: current.position + (value.position - bind.position) * weight,
                            rotation: rotation, scale: current.scale + (value.scale - bind.scale) * weight)
                    } else { pose[bone] = try interpolate(pose[bone], value, weight) }
                }
                if nextMotion?.enabled == true, layer.clip.rootMotionFlags != 0, let motionInput {
                    if rootDescriptions[layer.clip.id] == nil {
                        rootDescriptions[layer.clip.id] = try NativeModelRootMotion.describe(layer.clip, bones: source.skeleton.bones)
                    }
                    if let description = rootDescriptions[layer.clip.id] {
                        // Later layers still have their previous-frame clocks,
                        // matching the reference's sequential update order.
                        var remaining: Float = 1
                        for later in layers.indices where later > index && controls[later].visible && !controls[later].additive && !next[later].pendingRemoval {
                            remaining *= 1 - Self.autoBlend(controls[later], clip: layers[later].clip, state: &next[later])
                        }
                        if remaining > 0.0001 {
                            let current = try NativeModelRootMotion.sample(layer.clip, bones: source.skeleton.bones, bone: description.bone,
                                frame: layer.clip.sampleStart + sample.frame, next: layer.clip.sampleStart + sample.next, fraction: sample.fraction)
                            let result = try NativeModelRootMotion.extract(description, current: current, time: next[index].clock.time,
                                previous: next[index].rootCursor, weight: weight, remaining: remaining, pose: &pose)
                            try nextMotion?.apply(result, input: motionInput)
                            next[index].rootCursor = result.cursor
                            next[index].rootStoredPose = result.cursor.pose
                        } else {
                            // A covered layer updates its previous clock but
                            // retains the last matrix, initially identity in
                            // AnimationLayer's constructor (0x2682658).
                            next[index].rootCursor = .init(pose: next[index].rootStoredPose, time: next[index].clock.time)
                        }
                    }
                } else { next[index].rootCursor = nil }
                contributed = true
            }
            var packed = source.skeleton.defaultPalette
            if contributed {
                var world: [simd_float4x4] = []; packed.removeAll(keepingCapacity: true)
                for (index, key) in pose.enumerated() {
                    let local = matrix(key), parent = source.skeleton.bones[index].parent
                    let current = parent < 0 ? local : world[parent] * local
                    let bone = current * source.skeleton.inverseBind[index]
                    guard finite(current), finite(bone) else { throw SceneError.invalid("模型动画骨矩阵溢出；保留上一有效姿态。") }
                    world.append(current)
                    for column in 0..<4 { for row in 0..<4 { packed.append(bone[column][row]) } }
                }
            }
            // Commit only after the complete pose passed validation.
            states = next; lastTime = time; propertySamples = samples
            motion = nextMotion; motionWrites.removeAll()
            if deliverEvents {
                // Obj::Update dispatches model markers before ended callbacks.
                events.append(contentsOf: ended)
                if queuedEvents.count + events.count <= 1024 { queuedEvents.append(contentsOf: events) }
                else { eventOverflow = true }
            } else { retirePendingLayers() }
            if didAdvance { advances += 1 }
            if packed != palette { palette = packed; revision &+= 1 }
        }
        var snapshot: [String: Any] {
            ["time": lastTime ?? 0, "advances": advances, "revision": revision,
             "rootMotion": motion?.properties ?? [:],
             "layers": zip(layers, states).map { layer, state in
                ["key": layer.key, "clip": String(layer.clip.id), "active": state.wasActive, "clock": state.clock.json] as [String: Any]
             }]
        }
        private static func autoBlend(_ control: Controls, clip: NativeModelSkeleton.Clip, state: inout State) -> Float {
            let duration = Float(clip.frameCount) / clip.fps, fade = min(control.blendTime, duration * 0.5)
            var weight = control.blend
            if control.blendIn && !state.fadedIn && min(control.blendTime, duration) > Float.ulpOfOne {
                let factor = min(1, state.clock.time / fade)
                weight *= factor
                if factor >= 1 && clip.mode != "single" { state.fadedIn = true }
            }
            if control.blendOut && clip.mode == "single" && min(control.blendTime, duration) > Float.ulpOfOne {
                weight *= min(1, (duration - state.clock.time) / fade)
            }
            return weight
        }
    }

    static func nlerp(_ a: simd_quatf, _ b: simd_quatf, _ weight: Float) throws -> simd_quatf {
        let end = simd_dot(a.vector, b.vector) < 0 ? -b.vector : b.vector
        let vector = a.vector * (1 - weight) + end * weight
        let length = simd_length(vector)
        guard length.isFinite, length > 0 else { throw SceneError.invalid("模型动画四元数无法归一化。") }
        return simd_quatf(vector: vector / length)
    }
    static func interpolate(_ a: NativeModelSkeleton.Key, _ b: NativeModelSkeleton.Key, _ weight: Float) throws -> NativeModelSkeleton.Key {
        try NativeModelSkeleton.Key(position: a.position * (1 - weight) + b.position * weight,
            rotation: nlerp(a.rotation, b.rotation, weight), scale: a.scale * (1 - weight) + b.scale * weight)
    }
    static func matrix(_ key: NativeModelSkeleton.Key) -> simd_float4x4 {
        var result = simd_float4x4(key.rotation)
        for column in 0..<3 { result[column] *= key.scale[column] }
        result[3] = SIMD4(key.position, 1)
        return result
    }
    private static func decompose(_ value: simd_float4x4) throws -> NativeModelSkeleton.Key {
        let columns = (0..<3).map { SIMD3(value[$0].x, value[$0].y, value[$0].z) }
        let scale = SIMD3(simd_length(columns[0]), simd_length(columns[1]), simd_length(columns[2]))
        guard scale.x > 0, scale.y > 0, scale.z > 0, [scale.x, scale.y, scale.z].allSatisfy(\.isFinite) else {
            throw SceneError.invalid("模型动画绑定缩放无法分解。")
        }
        let rotation = simd_float3x3(columns[0] / scale.x, columns[1] / scale.y, columns[2] / scale.z)
        guard abs(simd_determinant(rotation) - 1) < 0.0001,
              abs(simd_dot(rotation[0], rotation[1])) < 0.0001,
              abs(simd_dot(rotation[0], rotation[2])) < 0.0001,
              abs(simd_dot(rotation[1], rotation[2])) < 0.0001 else {
            throw SceneError.invalid("模型动画绑定矩阵含剪切或反射；尚未支持。")
        }
        return NativeModelSkeleton.Key(position: SIMD3(value[3].x, value[3].y, value[3].z), rotation: simd_normalize(simd_quatf(rotation)), scale: scale)
    }
    static func finite(_ value: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { c in (0..<4).allSatisfy { value[c][$0].isFinite } }
    }
}
