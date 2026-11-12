import Foundation

/// Prepared metadata for a real renderer's script resources. This value owns
/// canonical JSON and never launches a helper, invokes scripts, or changes a
/// live scene. The same preparation is used by initial load and structural edits.
@MainActor
struct SceneScriptInventory {
    private(set) var sceneLayerOrder: NativeSceneLayerOrder
    private(set) var keys: Set<String>
    private(set) var layerIDs: Set<String>
    private(set) var soundIDs: Set<String>
    private(set) var videoKeys: Set<String>
    private(set) var effectVisibilityPaths: Set<String>
    private(set) var materialDimensions: [String: Int]
    private(set) var timelineLimits: [String: Double]
    private var objectSlots: [String: Int]
    private var data: Data
    private let sceneHeader: Data
    var count: Int { keys.count }

    func retiring(_ ids: Set<String>) throws -> Self {
        guard !ids.isEmpty, ids.count <= NativeSceneLifecycle.maximumMutations, ids.isSubset(of: layerIDs) else {
            throw SceneError.invalid("脚本删除回执包含未知、重复或过多图层。")
        }
        var next = self, payload = try message()
        next.layerIDs.subtract(ids); next.soundIDs.subtract(ids)
        next.objectSlots = objectSlots.filter { !ids.contains($0.key) }
        let slots = Set(next.objectSlots.values)
        func keep(_ path: String) -> Bool { NativeSceneLifecycle.Snapshot.retains(path: path, slots: slots) }
        let layers = (payload["layers"] as! [[String: Any]]).filter { !ids.contains($0["id"] as! String) }.map { layer in
            var value = layer
            if let parent = value["parentID"] as? String, ids.contains(parent) { value.removeValue(forKey: "parentID") }
            return value
        }
        let bindings = (payload["bindings"] as! [[String: Any]]).filter { keep($0["key"] as! String) }
        payload["layers"] = layers; payload["bindings"] = bindings
        payload["timelines"] = (payload["timelines"] as! [[String: Any]]).filter { keep($0["path"] as! String) }
        payload["timelineValues"] = (payload["timelineValues"] as? [String: Any] ?? [:]).filter { keep($0.key) }
        if let writes = payload["layerWriteCapabilities"] as? [String: Any] { payload["layerWriteCapabilities"] = writes.filter { !ids.contains($0.key) } }
        next.keys = Set(bindings.map { $0["key"] as! String })
        next.videoKeys = Set(layers.compactMap { ($0["videoTexture"] as? [String: Any])?["key"] as? String })
        next.effectVisibilityPaths = effectVisibilityPaths.filter(keep)
        next.materialDimensions = materialDimensions.filter { keep($0.key) }
        next.timelineLimits = timelineLimits.filter { keep($0.key) }
        next.sceneLayerOrder = try NativeSceneLayerOrder(objects: sceneLayerOrder.ids.map { ["id": $0] }, activeSlots: slots,
            order: sceneLayerOrder.indices.map { sceneLayerOrder.ids[$0] }.filter { !ids.contains($0) })
        next.data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return next
    }

    /// Decode a fresh tree so callers cannot alias Foundation mutable containers
    /// into a candidate that has already been checked.
    func message() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    var initialValues: [String: Any] {
        let bindings = (try? message()["bindings"] as? [[String: Any]]) ?? []
        return Dictionary(uniqueKeysWithValues: bindings.compactMap { binding in
            let path = binding["key"] as! String
            guard NativeSceneScriptProperties.name(at: path) == nil, timelineLimits[path] == nil,
                  !effectVisibilityPaths.contains(path), materialDimensions[path] == nil else { return nil }
            return (path, binding["value"] ?? NSNull())
        })
    }

    /// Structural edits may add or retire objects, but cannot silently replace
    /// a surviving object's scripts or move its property address to another slot.
    /// Parent detachment is runtime state; initialConfig remains unchanged.
    func retainedBindings(from previous: SceneScriptInventory, retaining ids: Set<String>) throws -> Set<String> {
        guard sceneHeader == previous.sceneHeader, ids == layerIDs.intersection(previous.layerIDs),
              ids.allSatisfy({ objectSlots[$0] == previous.objectSlots[$0] }) else {
            throw SceneError.invalid("结构变更的保留身份或属性槽位与现有脚本不一致。")
        }
        let current = try message(), old = try previous.message()
        let currentLayers = current["layers"] as! [[String: Any]], oldLayers = old["layers"] as! [[String: Any]]
        let before = Dictionary(uniqueKeysWithValues: oldLayers.map { ($0["id"] as! String, $0) })
        func encoded(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) }
        for layer in currentLayers where ids.contains(layer["id"] as! String) {
            let initial = layer["initialConfig"] ?? NSNull()
            guard try encoded(initial) == encoded(before[layer["id"] as! String]!["initialConfig"] ?? NSNull()) else {
                throw SceneError.invalid("结构变更不能替换存活图层的初始配置。")
            }
            func stableMetadata(_ layer: [String: Any]) -> [String: Any] {
                var result = layer; result.removeValue(forKey: "parentID")
                if var sound = result["sound"] as? [String: Any] {
                    sound.removeValue(forKey: "playing"); result["sound"] = sound
                }
                return result
            }
            guard try encoded(stableMetadata(layer)) == encoded(stableMetadata(before[layer["id"] as! String]!)) else {
                throw SceneError.invalid("结构变更不能更改存活图层的脚本资源接口。")
            }
        }
        let oldBindings = old["bindings"] as! [[String: Any]], newBindings = current["bindings"] as! [[String: Any]]
        let surviving: ([String: Any]) -> Bool = { ($0["objectID"] as? String) == "" || ids.contains($0["objectID"] as? String ?? "") }
        let previousBindings = Dictionary(uniqueKeysWithValues: oldBindings.filter(surviving).map { ($0["key"] as! String, $0) })
        let nextBindings = Dictionary(uniqueKeysWithValues: newBindings.filter(surviving).map { ($0["key"] as! String, $0) })
        guard Set(previousBindings.keys) == Set(nextBindings.keys) else { throw SceneError.invalid("结构变更不能增删存活对象上的脚本绑定。") }
        for (key, value) in nextBindings {
            guard try encoded(value) == encoded(previousBindings[key]!) else { throw SceneError.invalid("结构变更不能替换存活对象上的脚本定义。") }
        }
        return Set(nextBindings.keys)
    }

    init(scene: [String: Any], properties: [String: Any],
         textureAnimations: [String: [String: Any]] = [:], videoTextures: [String: [String: Any]] = [:],
         sounds: [String: [String: Any]] = [:], timelines: [[String: Any]] = [], timelineValues: [String: Any] = [:],
         layerWriteCapabilities: [String: [String]]? = nil, allowedBindingPaths: Set<String>? = nil,
         bindingInitialValues: [String: Any] = [:], effectVisibilityBases: [String: Bool] = [:],
         materials: [String: [SceneScriptMaterial]] = [:], activeLayerSlots: Set<Int>? = nil,
         initialLayerOrder: [String]? = nil, initialLayerConfigurations: [String: [String: Any]]? = nil) throws {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        let sceneLayerOrder = try NativeSceneLayerOrder(objects: objects, activeSlots: activeLayerSlots, order: initialLayerOrder)
        var dimensions: [String: Int] = [:], materialInitialValues: [String: Any] = [:]
        var materialCount = 0
        for (effect, entries) in materials {
            let modelMaterial = NativeModelMaterials.isOwner(effect)
            guard modelMaterial || effect.hasSuffix("/visible"), entries.count <= 128 else {
                throw SceneError.invalid("SceneScript 材质对象路径或数量无效。")
            }
            let prefix = modelMaterial ? effect : String(effect.dropLast("/visible".count))
            materialCount += entries.count
            // Effects can have non-material authored stages.  In particular,
            // Wallpaper Engine's Motion Blur effect inserts a `command: copy`
            // stage between materials 0 and 2.  The entries array contains
            // only real materials, so its compact enumeration is not the
            // authored pass index.  Preserve model-material validation below:
            // model material paths are a separate native interface whose
            // sequential indices are part of its contract.
            var previousEffectPassIndex: Int?
            for (index, entry) in entries.enumerated() {
                let indexedPath: Bool
                if modelMaterial {
                    indexedPath = entry.path == prefix + "/passes/\(index)"
                } else {
                    let base = prefix + "/passes/"
                    let suffix = entry.path.hasPrefix(base) ? String(entry.path.dropFirst(base.count)) : ""
                    let authoredIndex = Int(suffix)
                    // SceneRenderer and SceneEffectGraph both cap an authored
                    // effect document at 32 passes.  Keep that existing bound
                    // when validating this prepared renderer metadata.
                    indexedPath = authoredIndex != nil && (0..<32).contains(authoredIndex!) && String(authoredIndex!) == suffix &&
                        (previousEffectPassIndex == nil || authoredIndex! > previousEffectPassIndex!)
                    if indexedPath { previousEffectPassIndex = authoredIndex! }
                }
                guard indexedPath, entry.properties.count <= 128 else {
                    throw SceneError.invalid("SceneScript 材质索引与效果阶段不一致。")
                }
                var names = Set<String>()
                for property in entry.properties {
                    guard !property.name.isEmpty, property.name.utf8.count <= 256, names.insert(property.name).inserted,
                          property.path == entry.path + "/constantshadervalues/" + SceneScriptBridge.path(property.name),
                          dimensions[property.path] == nil, (1...4).contains(property.value.count),
                          property.value.allSatisfy({ $0.isFinite && abs($0) <= 16384 }) else {
                        throw SceneError.invalid("SceneScript 材质参数路径、类型或基值无效。")
                    }
                    dimensions[property.path] = property.value.count
                    materialInitialValues[property.path] = property.value
                }
            }
        }
        guard materialCount <= 8192, dimensions.count <= 16384 else {
            throw SceneError.invalid("SceneScript 材质对象或参数超过上限。")
        }
        for entry in timelines {
            if let path = entry["path"] as? String, path.contains("/\(NativeModelMaterials.key)/"), dimensions[path] == nil {
                throw SceneError.invalid("\(path)：模型材质曲线没有实际渲染参数。")
            }
        }
        var bindings: [[String: Any]] = []
        var sourceBytes = 0
        func collect(_ value: Any, path: String, objectID: String, property: String, depth: Int) throws {
            guard depth <= 32 else { throw SceneError.invalid("SceneScript 属性嵌套超过 32 层。") }
            if let dictionary = value as? [String: Any] {
                if let source = dictionary["script"] as? String, !source.isEmpty {
                    guard !path.contains("/\(NativeModelMaterials.key)/") || dimensions[path] != nil else {
                        throw SceneError.invalid("\(path)：模型材质脚本没有实际渲染参数。")
                    }
                    sourceBytes += source.utf8.count
                    guard bindings.count < 128, source.utf8.count <= 256 * 1024, sourceBytes <= 2 * 1024 * 1024 else {
                        throw SceneError.invalid("SceneScript 超过当前 128 段、单段 256 KiB 或总共 2 MiB 上限。")
                    }
                    let rawInitial = materialInitialValues[path] ?? bindingInitialValues[path] ?? effectVisibilityBases[path] as Any? ?? dictionary["value"]
                    let initial = path.hasSuffix("/angles") && path.split(separator: "/").count == 3 ? Self.angleDegrees(rawInitial) : rawInitial ?? NSNull()
                    bindings.append(["key": path, "source": source, "value": initial, "objectID": objectID, "property": property,
                                     "scriptProperties": dictionary["scriptproperties"] as? [String: Any] ?? [:]])
                }
                for key in dictionary.keys.sorted() where key != "script" {
                    try collect(dictionary[key]!, path: path + "/" + SceneScriptBridge.path(key), objectID: objectID, property: key, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                for (index, item) in array.enumerated() {
                    try collect(item, path: path + "/\(index)", objectID: objectID, property: property, depth: depth + 1)
                }
            }
        }
        func resolvedLightProperty(_ raw: Any?, fallback: Any) -> Any {
            guard let definition = raw as? [String: Any], let value = definition["value"] else { return raw ?? fallback }
            if let key = definition["user"] as? String { return (properties[key] as? [String: Any])?["value"] ?? value }
            if let reference = definition["user"] as? [String: Any], let key = reference["name"] as? String,
               let current = (properties[key] as? [String: Any])?["value"] {
                return reference["condition"].map { String(describing: current) == String(describing: $0) } ?? current
            }
            return value
        }
        var layers: [[String: Any]] = []
        var declaredEffects = Set<String>()
        var declaredModelMaterials = Set<String>()
        for (index, object) in objects.enumerated() where activeLayerSlots?.contains(index) ?? true {
            let id = SceneScriptBridge.objectID(object, index: index)
            var layer: [String: Any] = ["id": id, "name": object["name"] ?? "Object", "propertyPath": "/objects/\(index)",
                "initialConfig": (initialLayerConfigurations?[id] ?? object).filter { $0.key != "id" && $0.key != NativeModelMaterials.key }]
            let effects = object["effects"] as? [[String: Any]] ?? []
            guard effects.count <= 64, declaredEffects.count + effects.count <= 4096 else {
                throw SceneError.invalid("SceneScript 效果对象超过单层 64 或全场景 4096 个上限。")
            }
            layer["effects"] = effects.enumerated().map { effectIndex, effect -> [String: Any] in
                let path = "/objects/\(index)/effects/\(effectIndex)/visible"
                declaredEffects.insert(path)
                return ["path": path, "name": effect["name"] as? String ?? "",
                        "available": effectVisibilityBases[path] != nil,
                        "materials": materials[path].map { $0.map(\.metadata) } as Any? ?? NSNull(),
                        "visible": effectVisibilityBases[path] ?? SceneValues.visible(effect["visible"]),
                        "property": (effect["visible"] as? [String: Any]).map { $0.filter { ["value", "user"].contains($0.key) } } as Any? ?? effect["visible"] ?? true]
            }
            layer["textureAnimation"] = textureAnimations[id]
            layer["videoTexture"] = videoTextures[id]
            if object["model"] is String {
                layer["model"] = true
                layer["rootmotion"] = resolvedLightProperty(object["rootmotion"], fallback: true)
                let documents = object[NativeModelMaterials.key] as? [[String: Any]] ?? []
                layer["modelMaterials"] = documents.indices.flatMap { material -> [[String: Any]] in
                    let path = NativeModelMaterials.owner(object: index, material: material)
                    declaredModelMaterials.insert(path)
                    return (materials[path] ?? []).map(\.metadata)
                }
            }
            if object["sound"] != nil {
                layer["sound"] = sounds[id] ?? ["available": false]
                layer["volume"] = sounds[id]?["volume"] ?? 1
            }
            if object["model"] is String || object["light"] is String {
                let raw = object["castshadow"]
                layer["castshadow"] = resolvedLightProperty(raw, fallback: object["model"] is String)
            }
            if object["light"] is String {
                layer["castvolumetrics"] = resolvedLightProperty(object["castvolumetrics"], fallback: false)
                layer["usecookie"] = resolvedLightProperty(object["usecookie"], fallback: false)
                for (key, fallback) in [("intensity", Float(1)), ("radius", 5), ("exponent", 2), ("lightsourcesize", 0.05), ("density", 2), ("volumetricsexponent", 1)] {
                    let raw = object[key]
                    layer[key] = resolvedLightProperty(raw, fallback: fallback)
                }
                if object["light"] as? String == "lspot" {
                    for (key, fallback) in [("innercone", Float(20)), ("outercone", 30)] {
                        layer[key] = resolvedLightProperty(object[key], fallback: fallback)
                    }
                }
            }
            if object["camera"] is String {
                for (key, fallback) in [("fov", 50), ("zoom", 1)] {
                    let raw = object[key]
                    layer[key] = (raw as? [String: Any])?["value"] ?? raw ?? fallback
                }
                let queue = object["queuemode"]
                layer["queuemode"] = (queue as? [String: Any])?["value"] ?? queue ?? "random"
            }
            if let parent = object["parent"] as? NSNumber { layer["parentID"] = parent.stringValue }
            else if let parent = object["parent"] as? String { layer["parentID"] = parent }
            for key in ["origin", "angles", "scale", "size", "color", "alpha", "opacity", "visible", "parallaxDepth"] + SceneTextLayout.properties {
                if let value = object[key] {
                    let initial = (value as? [String: Any])?["value"] ?? value
                    layer[key] = key == "angles" ? Self.angleDegrees(initial) : initial
                }
            }
            if object["text"] != nil {
                // Missing text properties have the same defaults as the native
                // CoreText renderer, so cross-layer writes can address them.
                let defaults: [String: Any] = ["font": "", "pointsize": 16, "padding": 0,
                    "horizontalalign": "center", "verticalalign": "center", "anchor": "none", "blockalign": false,
                    "limitwidth": false, "maxwidth": 500, "limitrows": false, "maxrows": 1, "limituseellipsis": false,
                    "opaquebackground": false, "backgroundcolor": "0 0 0", "backgroundbrightness": 1]
                layer.merge(defaults) { current, _ in current }
            }
            layers.append(layer)
            try collect(object, path: "/objects/\(index)", objectID: id, property: "", depth: 0)
        }
        if let general = scene["general"] { try collect(general, path: "/general", objectID: "", property: "", depth: 0) }
        if let allowedBindingPaths, Set(bindings.compactMap { $0["key"] as? String }) != allowedBindingPaths {
            throw SceneError.invalid("SceneScript 清单与当前渲染器接收的绑定不一致，未启动脚本组件。")
        }
        guard Set(effectVisibilityBases.keys).isSubset(of: declaredEffects), Set(materials.keys).isSubset(of: declaredEffects.union(declaredModelMaterials)) else {
            throw SceneError.invalid("SceneScript 效果对象与当前渲染器的可见性路径不一致。")
        }
        let keys = Set(bindings.compactMap { $0["key"] as? String })
        let layerIDs = Set(layers.compactMap { $0["id"] as? String })
        let soundIDs = Set(sounds.keys)
        let effectVisibilityPaths = Set(effectVisibilityBases.keys)
        let timelineLimits: [String: Double] = Dictionary(uniqueKeysWithValues: timelines.compactMap { metadata in
            guard let path = metadata["path"] as? String, let length = metadata["length"] as? Double else { return nil }
            return (path, length)
        })
        let order = Dictionary(uniqueKeysWithValues: sceneLayerOrder.indices.enumerated().map { (sceneLayerOrder.ids[$0.element], $0.offset) })
        layers.sort { order[$0["id"] as! String]! < order[$1["id"] as! String]! }
        let payload: [String: Any] = ["bindings": bindings, "layers": layers,
            "timelines": timelines, "timelineValues": timelineValues,
            "layerWriteCapabilities": layerWriteCapabilities as Any? ?? NSNull()]
        data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        sceneHeader = try JSONSerialization.data(withJSONObject: scene.filter { $0.key != "objects" }, options: [.sortedKeys])
        guard data.count <= 4 * 1024 * 1024 else { throw SceneError.invalid("SceneScript 资源清单超过 4 MiB。") }
        self.sceneLayerOrder = sceneLayerOrder
        self.keys = keys; self.layerIDs = layerIDs; self.soundIDs = soundIDs
        self.videoKeys = Set(videoTextures.values.compactMap { $0["key"] as? String })
        self.effectVisibilityPaths = effectVisibilityPaths; self.materialDimensions = dimensions
        self.timelineLimits = timelineLimits
        self.objectSlots = Dictionary(uniqueKeysWithValues: sceneLayerOrder.indices.map { (sceneLayerOrder.ids[$0], $0) })
    }

    /// Scene file rotations are radians; the public layer scripting API uses degrees.
    private static func angleDegrees(_ value: Any?) -> Any {
        let parts = SceneValues.floats(value)
        guard parts.count == 3 else { return value ?? NSNull() }
        return parts.map { String(Double($0) * 180 / .pi) }.joined(separator: " ")
    }

}
