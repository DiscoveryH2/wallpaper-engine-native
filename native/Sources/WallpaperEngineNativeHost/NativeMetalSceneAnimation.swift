import Foundation
import simd

/// Ordinary Scene curves use the same parser and Float graph clocks as the
/// compatibility renderer. This description contains no GPU or image storage.
struct NativeMetalSceneAnimation {
    enum ValueKind {
        case numeric(Int), boolean, string
    }
    struct Binding {
        let path: String
        let objectIndex: Int?
        let key: String
        let kind: ValueKind
        let effectParameter: Bool
        let effectVisibility: Bool
        var modelProperty: NativeModelProperties.Address? { NativeModelProperties.address(path) }
    }
    struct LayerState {
        let transform: simd_float4x4
        let color: SIMD3<Float>
        let opacity: Float
        let background: SIMD4<Float>
        let camera: NativeMetalSceneCamera.Layer
        let visible: Bool
        let textureTime: Double?
        let textureFrame: Int?
        let textProperties: [String: Any]?
        var castsShadow: Bool = true
    }
    struct Frame {
        let layers: [LayerState]
        let zoom: Float
        let perspective: NativePerspectiveProjection
        let clearColor: SIMD3<Float>
        let clearEnabled: Bool
        let hdrBloom: NativeHDRBloomParameters
        let bloom: NativeSceneBloom
        let camera: NativeMetalSceneCamera.Settings
        let activeCamera: NativeSceneCameras.Active?
        let modelLighting: NativeModelLightFrame
        let effectParameters: [String: [Float]]
        let effectVisibility: [String: Bool]
        let sounds: [Int: SceneSoundState]
        var modelProperties: [Int: [Int: [String: Any]]] = [:]
    }

    private(set) var scene: [String: Any]
    private(set) var objects: [[String: Any]]
    let general: [String: Any]
    private(set) var hierarchy: SceneHierarchy
    private(set) var bindings: [Binding]
    private(set) var scriptBindings: [Binding]
    private(set) var effectBases: [String: [Float]]
    private(set) var effectVisibilityBases: [String: Bool]
    private(set) var materials: [String: [SceneScriptMaterial]]
    private(set) var signature: Data
    private(set) var cameraObjects: NativeMetalCameraObjects?

    private func retiring(to snapshot: NativeSceneLifecycle.Snapshot) throws -> Self {
        var next = self
        next.scene = try snapshot.applyingMembership(to: scene)
        next.objects = try snapshot.applyingMembership(to: ["objects": objects])["objects"] as! [[String: Any]]
        next.hierarchy = SceneHierarchy(objects: next.objects)
        next.bindings = bindings.filter { snapshot.retains(path: $0.path) }
        next.scriptBindings = scriptBindings.filter { snapshot.retains(path: $0.path) }
        next.effectBases = effectBases.filter { snapshot.retains(path: $0.key) }
        next.effectVisibilityBases = effectVisibilityBases.filter { snapshot.retains(path: $0.key) }
        next.materials = materials.filter { snapshot.retains(path: $0.key) }
        let definitions = try JSONSerialization.jsonObject(with: signature) as! [String: Any]
        next.signature = try JSONSerialization.data(withJSONObject: definitions.filter { snapshot.retains(path: $0.key) }, options: [.sortedKeys])
        next.cameraObjects = next.objects.contains { $0["camera"] is String } ? try cameraObjects?.retiring(to: snapshot) : nil
        return next
    }

    static func scriptBinding(at path: String) -> Binding? {
        if let model = NativeModelProperties.address(path), NativeModelProperties.flags.contains(model.property) {
            return Binding(path: path, objectIndex: model.object, key: model.property, kind: .boolean, effectParameter: false, effectVisibility: false)
        }
        let parts = path.split(separator: "/")
        if parts.count == 2, parts[0] == "general", (["fogdistance"].contains(parts[1]) || NativeSceneScriptProperties.flags.contains(String(parts[1]))) {
            return Binding(path: path, objectIndex: nil, key: String(parts[1]), kind: .boolean, effectParameter: false, effectVisibility: false)
        }
        if parts.count == 5, parts[0] == "objects", let index = Int(parts[1]), index >= 0,
           parts[2] == "effects", let effect = Int(parts[3]), effect >= 0, parts[4] == "visible" {
            return Binding(path: path, objectIndex: index, key: "visible", kind: .boolean, effectParameter: false, effectVisibility: true)
        }
        if parts.count == 3, parts[0] == "objects", let index = Int(parts[1]), index >= 0 {
            let key = String(parts[2])
            if key == "visible" || key == "castshadow" || key == "rootmotion" || key == "castvolumetrics" || key == "usecookie" || NativeMetalText.flags.contains(key) {
                return Binding(path: path, objectIndex: index, key: key, kind: .boolean, effectParameter: false, effectVisibility: false)
            }
            if NativeMetalText.strings.contains(key) || key == "queuemode" {
                return Binding(path: path, objectIndex: index, key: key, kind: .string, effectParameter: false, effectVisibility: false)
            }
        }
        return binding(at: path)
    }

    static func binding(at path: String) -> Binding? {
        if let material = NativeModelMaterials.parameter(path) {
            return Binding(path: path, objectIndex: material.object, key: material.name, kind: .numeric(material.count), effectParameter: true, effectVisibility: false)
        }
        if let model = NativeModelProperties.address(path), NativeModelProperties.numbers.contains(model.property) {
            return Binding(path: path, objectIndex: model.object, key: model.property, kind: .numeric(1), effectParameter: false, effectVisibility: false)
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 2, parts[0] == "general", let count = ["zoom": 1, "clearcolor": 3, "fov": 1, "nearz": 1, "farz": 1,
            "ambientcolor": 3, "skylightcolor": 3, "fogdistancestart": 1, "fogdistanceend": 1, "fogdistancestartdensity": 1, "fogdistanceenddensity": 1, "fogdistancecolor": 3,
            "bloomstrength": 1, "bloomthreshold": 1, "bloomtint": 3,
            "bloomhdrstrength": 1, "bloomhdrthreshold": 1, "bloomhdrfeather": 1, "bloomhdrscatter": 1, "bloomhdriterations": 1,
            "cameraparallaxamount": 1, "cameraparallaxdelay": 1, "cameraparallaxmouseinfluence": 1,
            "camerashakespeed": 1, "camerashakeamplitude": 1, "camerashakeroughness": 1][parts[1]] {
            return Binding(path: path, objectIndex: nil, key: parts[1], kind: .numeric(count), effectParameter: false, effectVisibility: false)
        }
        if parts.count == 8, parts[0] == "objects", let index = Int(parts[1]), index >= 0,
           parts[2] == "effects", let effect = Int(parts[3]), effect >= 0,
           parts[4] == "passes", let pass = Int(parts[5]), pass >= 0, parts[6] == "constantshadervalues",
           let count = ["scale": 2, "compositecolor": 3, "alpha": 1,
                        // These are the three inspected Motion Blur g_Amount
                        // labels.  Keep this list aligned with
                        // NativeMetalSceneEffects.makePass: no arbitrary
                        // author constant becomes script- or curve-addressable.
                        "Accumulation rate": 1, "rate": 1, "g_Amount": 1][parts[7]] {
            return Binding(path: path, objectIndex: index, key: parts[7], kind: .numeric(count), effectParameter: true, effectVisibility: false)
        }
        let counts = ["origin": 3, "angles": 3, "scale": 3, "color": 3, "alpha": 1, "opacity": 1,
                      "backgroundcolor": 3, "backgroundbrightness": 1, "parallaxDepth": 2,
                      "fov": 1, "zoom": 1, "intensity": 1, "radius": 1, "exponent": 1, "innercone": 1, "outercone": 1, "lightsourcesize": 1, "density": 1, "volumetricsexponent": 1, "pointsize": 1, "padding": 1, "maxwidth": 1, "maxrows": 1, "volume": 1, "mintime": 1, "maxtime": 1]
        guard parts.count == 3, parts[0] == "objects", let index = Int(parts[1]), index >= 0,
              let count = counts[parts[2]] else { return nil }
        return Binding(path: path, objectIndex: index, key: parts[2], kind: .numeric(count), effectParameter: false, effectVisibility: false)
    }

    static func validate(_ raw: Any, at path: String) throws {
        guard binding(at: path) != nil, let animation = raw as? [String: Any],
              Set(animation.keys).isSubset(of: ["options", "relative", "c0", "c1", "c2", "c3"]),
              let options = animation["options"] as? [String: Any],
              Set(options.keys).isSubset(of: ["fps", "length", "mode", "name", "startpaused", "wraploop", "parent", "events", "random"]) else {
            throw SceneError.invalid("\(path)：该属性或时间轴结构尚未迁移到 Metal。")
        }
        // Unsupported graph coordination is also rejected by the
        // shared parser diagnostics below. Never quietly omit an author track.
        for channel in 0..<4 {
            guard let keys = animation["c\(channel)"] as? [Any] else { continue }
            guard keys.count <= 2048 else { throw SceneError.invalid("\(path)：时间轴超过单通道 2048 项上限。") }
            for rawKey in keys {
                guard let key = rawKey as? [String: Any],
                      Set(key.keys).isSubset(of: ["frame", "value", "step", "back", "front"]) else {
                    throw SceneError.invalid("\(path)：时间轴关键帧含尚未迁移的字段。")
                }
                for direction in ["back", "front"] {
                    if let handle = key[direction] as? [String: Any],
                       !Set(handle.keys).isSubset(of: ["enabled", "x", "y"]) {
                        throw SceneError.invalid("\(path)：曲线手柄含尚未迁移的字段。")
                    }
                }
            }
        }
    }

    static func make(authored: [String: Any], resolved: [String: Any], paths: Set<String>, scriptPaths: Set<String>, hierarchy: SceneHierarchy,
                     effectBases: [String: [Float]], effectVisibilityBases: [String: Bool] = [:], materials: [String: [SceneScriptMaterial]] = [:], cameraObjects: NativeMetalCameraObjects? = nil, requiresRuntime: Bool = false) throws -> Self? {
        let needsModelState = (resolved["objects"] as? [[String: Any]] ?? []).contains { $0["model"] is String || $0["light"] is String }
        guard !paths.isEmpty || !scriptPaths.isEmpty || cameraObjects != nil || needsModelState || requiresRuntime else { return nil }
        let timelines = SceneTimelines(scene: authored)
        guard timelines.unsupportedDiagnostics.isEmpty, Set(timelines.paths) == paths else {
            throw SceneError.invalid("Metal 时间轴未完整加载：\(timelines.unsupportedDiagnostics.joined(separator: " "))")
        }
        guard let objects = resolved["objects"] as? [[String: Any]],
              let authoredObjects = authored["objects"] as? [[String: Any]], objects.count == authoredObjects.count else {
            throw SceneError.invalid("时间轴图层列表无效。")
        }
        let general = resolved["general"] as? [String: Any] ?? [:]
        let authoredGeneral = authored["general"] as? [String: Any] ?? [:]
        var definitions: [String: Any] = [:], bindings: [Binding] = []
        func validateModel(_ binding: Binding) throws {
            guard let address = binding.modelProperty else { return }
            guard objects.indices.contains(address.object), objects[address.object]["model"] is String,
                  let layers = objects[address.object]["animationlayers"] as? [[String: Any]], layers.indices.contains(address.layer) else {
                throw SceneError.invalid("\(binding.path)：属性没有对应的模型动画层。")
            }
        }
        for path in paths.sorted() {
            guard let binding = binding(at: path) else { throw SceneError.invalid("未接入的 Metal 属性时间轴：\(path)") }
            let base: Any?
            if binding.modelProperty != nil {
                try validateModel(binding)
                base = property(at: path, in: resolved); definitions[path] = property(at: path, in: authored)
            } else if binding.effectParameter {
                guard let value = effectBases[path], let definition = property(at: path, in: authored) else {
                    throw SceneError.invalid("\(path)：效果时间轴未连接到已支持的材质参数。")
                }
                base = value; definitions[path] = definition
            } else if let index = binding.objectIndex {
                guard objects.indices.contains(index),
                      (!(binding.key.hasPrefix("background") || NativeMetalText.numbers.contains(binding.key)) || objects[index]["text"] != nil),
                      (!["volume", "mintime", "maxtime"].contains(binding.key) || objects[index]["sound"] != nil),
                      (!["fov", "zoom"].contains(binding.key) || objects[index]["camera"] is String),
                      (!["intensity", "radius", "exponent", "lightsourcesize", "density", "volumetricsexponent"].contains(binding.key) || objects[index]["light"] is String),
                      (!["innercone", "outercone"].contains(binding.key) || objects[index]["light"] as? String == "lspot"),
                      (!["density", "volumetricsexponent"].contains(binding.key) || objects[index]["light"] as? String == "lpoint") else {
                    throw SceneError.invalid("\(path)：属性与图层类型不匹配。")
                }
                base = objects[index][binding.key]
                definitions[path] = authoredObjects[index][binding.key]
            } else {
                base = general[binding.key]
                definitions[path] = authoredGeneral[binding.key]
            }
            guard let sample = timelines.value(at: path, time: 0, base: base),
                  components(sample, binding: binding) != nil else {
                throw SceneError.invalid("\(path)：时间轴数值维数不匹配或初始采样无效。")
            }
            bindings.append(binding)
        }
        let scriptBindings = try scriptPaths.sorted().map { path -> Binding in
            guard let binding = scriptBinding(at: path) else {
                throw SceneError.invalid("\(path)：Metal 脚本属性尚未迁移。")
            }
            try validateModel(binding)
            // A syntactically valid path is insufficient: a supported material
            // must consume this exact parameter, including disabled effects.
            let initial: Any?
            if binding.effectParameter {
                guard let base = effectBases[path] else {
                    throw SceneError.invalid("\(path)：效果脚本未连接到已支持的材质参数。")
                }
                initial = base
            } else if binding.effectVisibility {
                guard let base = effectVisibilityBases[path] else {
                    throw SceneError.invalid("\(path)：效果开关脚本未连接到已支持的处理组。")
                }
                initial = base
            } else { initial = property(at: path, in: resolved) }
            guard let initial, valid(initial, binding: binding) else {
                throw SceneError.invalid("\(path)：Metal 脚本初始值类型无效。")
            }
            if binding.modelProperty == nil, !binding.effectParameter, !binding.effectVisibility, let index = binding.objectIndex {
                guard objects.indices.contains(index), NativeMetalSceneScript.writes(for: objects[index]).contains(binding.key) else {
                    throw SceneError.invalid("\(path)：该图层的脚本属性尚未迁移。")
                }
            }
            return binding
        }
        return Self(scene: authored, objects: objects, general: general, hierarchy: hierarchy, bindings: bindings, scriptBindings: scriptBindings, effectBases: effectBases, effectVisibilityBases: effectVisibilityBases, materials: materials,
                    signature: try JSONSerialization.data(withJSONObject: definitions, options: [.sortedKeys]), cameraObjects: cameraObjects)
    }

    private static func property(at path: String, in scene: [String: Any]) -> Any? {
        var current: Any = scene
        for component in path.split(separator: "/") {
            let key = String(component).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let object = current as? [String: Any], let value = object[key] { current = value }
            else if let array = current as? [Any], let index = Int(key), array.indices.contains(index) { current = array[index] }
            else { return nil }
        }
        return current
    }

    private static func components(_ value: Any, binding: Binding) -> [Float]? {
        guard case .numeric(let dimensions) = binding.kind else { return nil }
        let values = SceneValues.floats(value)
        return values.count == dimensions && values.allSatisfy({ $0.isFinite && (!binding.effectParameter || abs($0) <= 16384) }) ? values : nil
    }

    private static func valid(_ value: Any, binding: Binding) -> Bool {
        switch binding.kind {
        case .boolean: return value as? Bool != nil
        case .string: return value as? String != nil
        case .numeric: return components(value, binding: binding) != nil
        }
    }

    @MainActor
    final class Runtime {
        private var source: NativeMetalSceneAnimation
        private var timelines: SceneTimelines
        private var cameraObjects: NativeSceneCameras?
        var timelineStore: SceneTimelines { timelines }
        private var lastFrameNotes: [String] = []
        var needsFrameUpdates: Bool { timelines.needsFrameUpdates || cameraObjects?.needsFrameUpdates == true }
        var diagnostics: [String] { timelines.diagnostics + [timelines.runtimeDiagnostic].compactMap { $0 } + lastFrameNotes + [cameraObjects?.runtimeDiagnostic].compactMap { $0 } }
        var effectScriptInitialValues: [String: Any] {
            Dictionary(uniqueKeysWithValues: source.scriptBindings.filter { $0.effectParameter || $0.modelProperty != nil || ["rootmotion", "castshadow", "lightsourcesize", "castvolumetrics", "usecookie", "density", "volumetricsexponent"].contains($0.key) }.map {
                ($0.path, $0.effectParameter ? source.effectBases[$0.path]! as Any : base($0)!)
            })
        }
        private func base(_ binding: Binding) -> Any? {
            if binding.modelProperty != nil { return NativeMetalSceneAnimation.property(at: binding.path, in: ["objects": source.objects]) }
            return binding.effectParameter ? source.effectBases[binding.path] :
                (binding.objectIndex.map { source.objects[$0][binding.key] } ?? source.general[binding.key])
        }
        var effectVisibilityBases: [String: Bool] { source.effectVisibilityBases }
        var materials: [String: [SceneScriptMaterial]] { source.materials }

        init(_ source: NativeMetalSceneAnimation) throws {
            self.source = source
            timelines = SceneTimelines(scene: source.scene)
            cameraObjects = try source.cameraObjects?.makeRuntime()
        }

        func prepareRetirement(to snapshot: NativeSceneLifecycle.Snapshot) throws -> () -> Void {
            let next = try source.retiring(to: snapshot)
            return { [self] in
                source = next
                timelines.retire(retainingSlots: snapshot.activeSlots)
                cameraObjects?.retire(retainingSlots: snapshot.activeSlots)
                lastFrameNotes.removeAll()
            }
        }

        /// Called at the property transaction's commit boundary, not when
        /// preparation begins. Other frames may run while resources prepare.
        func preserveClock(from previous: Runtime) {
            if source.signature == previous.source.signature { timelines = previous.timelines }
            if source.cameraObjects?.signature == previous.source.cameraObjects?.signature { cameraObjects = previous.cameraObjects }
        }

        func preserveInsertionRuntime(from previous: Runtime, slots: Set<Int>, at time: Double) throws {
            try timelines.preserveRuntime(from: previous.timelines, retainingSlots: slots, at: time)
            if let current = cameraObjects, let old = previous.cameraObjects,
               let definition = source.cameraObjects, let before = previous.source.cameraObjects {
                let retained = try definition.retainedCameraSlots(from: before, slots: slots)
                current.preserveRuntime(from: old, retainingSlots: retained, at: time)
            }
        }

        func scriptInput(at time: Double) -> [String: Any] {
            timelines.advance(to: time)
            var values: [String: Any] = [:]
            for binding in source.bindings {
                if let value = timelines.value(at: binding.path, time: time, base: base(binding)) {
                    values[binding.path] = binding.objectIndex != nil && !binding.effectParameter && binding.key == "angles"
                        ? SceneValues.floats(value).map { Double($0) * 180 / .pi } : value
                }
            }
            return values
        }

        func frame(at time: Double, scripts: SceneScriptBridge? = nil, models: NativeMetalModels.Runtime? = nil, paused: Bool = false, displayOrder: [Int]? = nil) throws -> Frame {
            timelines.advance(to: time)
            var objects = source.objects, general = source.general
            var cameraBases: [Int: NativeSceneCameras.TransformState] = [:]
            if let cameraObjects {
                for index in cameraObjects.indices {
                    let base = NativeSceneCameras.TransformState(origin: SceneValues.vector(objects[index]["origin"], .zero), angles: SceneValues.vector(objects[index]["angles"], .zero))
                    cameraBases[index] = base
                    let state = cameraObjects.state(index: index, base: base)
                    objects[index]["origin"] = [state.origin.x, state.origin.y, state.origin.z]
                    objects[index]["angles"] = [state.angles.x, state.angles.y, state.angles.z]
                }
            }
            // Resolved material/user values cover the first frame and script
            // startup. Curves then sample these bases; explicit script results
            // have the final say, without changing the owning layer's scale.
            var effectParameters = source.effectBases
            var effectVisibility = source.effectVisibilityBases
            var modelProperties: [Int: [Int: [String: Any]]] = [:]
            for binding in source.bindings {
                guard let value = timelines.value(at: binding.path, time: time, base: base(binding)),
                      let components = NativeMetalSceneAnimation.components(value, binding: binding) else {
                    throw SceneError.invalid("\(binding.path)：Metal 时间轴采样无效，停止绘制。")
                }
                if let model = binding.modelProperty { modelProperties[model.object, default: [:]][model.layer, default: [:]][model.property] = value }
                else if binding.effectParameter { effectParameters[binding.path] = components }
                else if let index = binding.objectIndex { objects[index][binding.key] = value }
                else { general[binding.key] = value }
            }
            func checked(_ value: Any, binding: Binding) throws -> Any {
                switch binding.kind {
                case .boolean:
                    guard let flag = value as? Bool else { throw SceneError.invalid("\(binding.path)：脚本属性不是布尔值。") }; return flag
                case .string:
                    guard let text = value as? String else { throw SceneError.invalid("\(binding.path)：脚本属性不是字符串。") }; return text
                case .numeric: break
                }
                guard let components = NativeMetalSceneAnimation.components(value, binding: binding) else {
                    throw SceneError.invalid("\(binding.path)：脚本返回值的维数或有限范围无效。")
                }
                // Public SceneScript angles use degrees; file/curve values use radians.
                if binding.key == "angles", binding.objectIndex != nil { return components.map { $0 * .pi / 180 } }
                return components.count == 1 ? components[0] : value
            }
            if let scripts {
                for (path, value) in scripts.materialValues {
                    guard let base = effectParameters[path], base.count == value.count,
                          value.allSatisfy({ $0.isFinite && abs($0) <= 16384 }) else {
                        throw SceneError.invalid("\(path)：材质参数没有当前帧消费者或数值无效。")
                    }
                    effectParameters[path] = value
                }
                for (path, value) in scripts.effectVisibilityValues {
                    guard effectVisibility[path] != nil else { throw SceneError.invalid("\(path)：效果可见性没有当前帧消费者。") }
                    effectVisibility[path] = value
                }
                for index in objects.indices {
                    let id = SceneScriptBridge.objectID(objects[index], index: index)
                    if let updates = scripts.layerValues[id] {
                        for key in NativeMetalSceneScript.writes(for: objects[index]) {
                            if models?.usesRootMotion(index) == true && ["origin", "angles", "rootmotion"].contains(key) { continue }
                            if let value = updates[key], let binding = NativeMetalSceneAnimation.scriptBinding(at: "/objects/\(index)/\(key)") {
                                objects[index][key] = try checked(value, binding: binding)
                            }
                        }
                    }
                }
                for binding in source.scriptBindings {
                    // Model property returns and thisObject writes share the
                    // same ordered model command transaction, avoiding a stale
                    // path value overriding a later explicit handle command.
                    if binding.modelProperty != nil { continue }
                    if let index = binding.objectIndex, models?.usesRootMotion(index) == true && ["origin", "angles", "rootmotion"].contains(binding.key) { continue }
                    if let value = scripts.value(at: binding.path, fallback: nil) {
                        let value = try checked(value, binding: binding)
                        if binding.effectParameter { effectParameters[binding.path] = NativeMetalSceneAnimation.components(value, binding: binding)! }
                        else if binding.effectVisibility { effectVisibility[binding.path] = value as? Bool }
                        else if let index = binding.objectIndex { objects[index][binding.key] = value }
                        else { general[binding.key] = value }
                    }
                }
            }
            // IScene setters can target settings that have no bound script.
            // The complete, checked snapshot publishes with all other effects.
            if let scripts { general.merge(scripts.sceneValues) { _, next in next } }
            let visibility = objects.map { SceneValues.visible($0["visible"]) }
            let curveOverrides = Dictionary(grouping: source.bindings.filter { $0.objectIndex != nil && ["origin", "angles"].contains($0.key) }, by: { $0.objectIndex! }).mapValues { Set($0.map(\.key)) }
            func advanceModel(_ index: Int, _ parent: simd_float4x4, _ visible: Bool, _ state: inout [String: Any]) throws {
                try models?.updateObject(instance: index, time: time, visible: visible, paused: paused,
                    properties: modelProperties[index] ?? [:], state: &state, parent: parent, curveOverrides: curveOverrides[index] ?? [])
            }
            let hierarchy: (transforms: [simd_float4x4], visible: [Bool])
            if let cameraObjects, let definition = source.cameraObjects {
                hierarchy = try cameraObjects.advance(to: time, states: &objects, bases: cameraBases,
                    hierarchy: source.hierarchy, localVisibility: visibility, transform: SceneValues.transform,
                    resolve: definition.resolveVisibility, displayOrder: scripts?.sceneLayerOrder.indices ?? displayOrder, beforeObject: advanceModel)
            } else {
                var resolved = source.hierarchy.resolve(local: objects.map(SceneValues.transform), visible: visibility)
                for index in source.hierarchy.order {
                    let parent = source.hierarchy.parents[index].map { resolved.transforms[$0] } ?? matrix_identity_float4x4
                    try advanceModel(index, parent, resolved.visible[index], &objects[index])
                    resolved.transforms[index] = parent * SceneValues.transform(objects[index])
                }
                hierarchy = resolved
            }
            guard hierarchy.transforms.allSatisfy({ matrix in (0..<4).allSatisfy { c in (0..<4).allSatisfy { matrix[c][$0].isFinite } } }) else {
                throw SceneError.invalid("Metal 动画父子变换超出有限数值范围，停止绘制。")
            }
            let layers = objects.enumerated().map { index, object in
                let background = SceneValues.vector(object["backgroundcolor"], .zero) * SceneValues.number(object["backgroundbrightness"], 1)
                return LayerState(transform: hierarchy.transforms[index], color: SceneValues.vector(object["color"], SIMD3(repeating: 1)),
                    opacity: max(0, min(1, SceneValues.number(object["alpha"] ?? object["opacity"], 1))),
                    background: SIMD4(background, object["opaquebackground"] as? Bool == true ? 1 : 0),
                    camera: NativeMetalSceneCamera.Layer(object: object), visible: hierarchy.visible[index],
                    textureTime: scripts?.texturePlayback[SceneScriptBridge.objectID(object, index: index)]?.time(at: time),
                    textureFrame: scripts?.texturePlayback[SceneScriptBridge.objectID(object, index: index)]?.staticFrame,
                    textProperties: object["text"] == nil ? nil : NativeMetalText.layoutProperties(object),
                    castsShadow: SceneValues.visible(object["castshadow"]))
            }
            let projection = NativeOrthographicProjection(zoom: general["zoom"])
            let clear = SceneValues.vector(general["clearcolor"], .zero)
            guard layers.allSatisfy({ layer in (0..<4).allSatisfy { layer.background[$0].isFinite } }) else {
                throw SceneError.invalid("Metal 动画背景颜色超出有限数值范围，停止绘制。")
            }
            lastFrameNotes = [String(format: "Metal 属性动画最近编码：场景时间 %.6f 秒；活动时间轴 %@；zoom %.4f。此快照不代替 GPU 完成状态。", time, needsFrameUpdates ? "有" : "无", projection.zoom)]
            lastFrameNotes += projection.diagnostics
            var animated = Set((source.bindings + source.scriptBindings).filter { !$0.effectParameter && !$0.effectVisibility && $0.modelProperty == nil }.compactMap(\.objectIndex))
            if let scripts {
                animated.formUnion(objects.indices.filter { scripts.layerValues[SceneScriptBridge.objectID(objects[$0], index: $0)]?.isEmpty == false })
            }
            for index in objects.indices.filter({ animated.contains($0) || source.hierarchy.parents[$0].map(animated.contains) == true }).prefix(8) {
                let layer = layers[index], position = layer.transform.columns.3
                let name = objects[index]["name"] as? String ?? "图层 \(index + 1)"
                lastFrameNotes.append(String(format: "%@：世界位置 (%.3f, %.3f, %.3f)，颜色 (%.3f, %.3f, %.3f)，透明度 %.4f，可见=%@。", name,
                    position.x, position.y, position.z, layer.color.x, layer.color.y, layer.color.z, layer.opacity, layer.visible ? "是" : "否"))
            }
            let sounds = Dictionary(uniqueKeysWithValues: objects.enumerated().compactMap { index, object -> (Int, SceneSoundState)? in
                guard object["sound"] != nil else { return nil }
                return (index, SceneSoundState(volume: object["volume"], visible: hierarchy.visible[index], minimum: object["mintime"], maximum: object["maxtime"]))
            })
            return Frame(layers: layers, zoom: projection.zoom, perspective: NativePerspectiveProjection(fov: cameraObjects?.active?.fov ?? general["fov"], near: general["nearz"], far: general["farz"]), clearColor: clear, clearEnabled: general["clearenabled"] as? Bool ?? true, hdrBloom: NativeHDRBloomParameters(general: general), bloom: NativeSceneBloom(general: general),
                         camera: NativeMetalSceneCamera.Settings(general: general), activeCamera: cameraObjects?.active, modelLighting: NativeMetalModelLighting.frame(objects: objects, general: general, transforms: hierarchy.transforms, visible: hierarchy.visible), effectParameters: effectParameters, effectVisibility: effectVisibility, sounds: sounds, modelProperties: modelProperties)
        }
    }
}
