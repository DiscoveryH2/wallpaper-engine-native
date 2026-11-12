import Foundation

/// Metal consumes the existing bounded SceneScript protocol. Admission remains
/// conservative: unsupported resource/layout scripts retain the other backend.
struct NativeMetalSceneScript {
    private(set) var scene: [String: Any]
    let properties: [String: Any]
    let propertyTypes: [String: String]
    let projectURL: URL
    let camera: NativeCameraPose
    private(set) var textures: [String: [String: Any]]
    private(set) var videos: [String: [String: Any]]
    private(set) var layerWrites: [String: [String]]
    private(set) var signature: Data
    private(set) var paths: Set<String>
    let usesPointer: Bool
    private(set) var activeSlots: Set<Int>?
    private(set) var initialLayerOrder: [String]?
    private(set) var initialConfigurations: [String: [String: Any]]?

    func retiring(to snapshot: NativeSceneLifecycle.Snapshot) throws -> Self {
        var next = self
        next.scene = try snapshot.applyingMembership(to: scene)
        let ids = Set(snapshot.orderedIDs)
        next.textures = textures.filter { ids.contains($0.key) }
        next.videos = videos.filter { ids.contains($0.key) }
        next.layerWrites = layerWrites.filter { ids.contains($0.key) }
        next.paths = paths.filter { snapshot.retains(path: $0) }
        next.activeSlots = snapshot.activeSlots; next.initialLayerOrder = snapshot.orderedIDs
        next.initialConfigurations = try snapshot.initialConfigurations()
        next.signature = try JSONSerialization.data(withJSONObject: next.scene, options: [.sortedKeys])
        return next
    }

    static let callbacks: Set<String> = ["init", "update", "applyUserProperties", "mediaStatusChanged",
        "mediaPropertiesChanged", "mediaThumbnailChanged", "mediaPlaybackChanged", "mediaTimelineChanged",
        "cursorEnter", "cursorLeave", "cursorMove", "cursorDown", "cursorUp", "cursorClick", "animationEvent"]

    static func validate(_ value: Any, path: String, lifecycleAvailable: Bool = false) throws -> Bool {
        guard let script = value as? String, script.utf8.count <= 256 * 1024,
              NativeMetalSceneAnimation.scriptBinding(at: path) != nil else {
            throw SceneError.invalid("\(path)：该脚本输出尚未连接到 Metal，保留兼容渲染器。")
        }
        var pointer = false
        _ = try lowerModule(script) { exports, identifiers in
            guard Set(exports).isSubset(of: lifecycleAvailable ? callbacks.union(["destroy"]) : callbacks),
                  Set(identifiers).isDisjoint(with: ["eval", "Function"]) else {
                throw SceneError.invalid("\(path)：未支持的回调或动态代码仍由兼容渲染器处理。")
            }
            pointer = identifiers.contains("input") || exports.contains { $0.hasPrefix("cursor") }
        }
        return pointer
    }

    static func writes(for object: [String: Any]) -> [String] {
        var keys = ["origin", "angles", "scale", "visible", "parallaxDepth"]
        if object["model"] is String { return keys + ["castshadow", "rootmotion"] }
        if let light = object["light"] as? String {
            return keys + ["color", "intensity", "radius", "exponent"]
                + (light == "lspot" ? ["innercone", "outercone", "castshadow", "usecookie"] : [])
                + (light == "lpoint" ? ["castshadow", "lightsourcesize", "castvolumetrics", "density", "volumetricsexponent"] : [])
        }
        if object["camera"] is String { return keys + ["fov", "zoom", "queuemode"] }
        if object["sound"] != nil { return keys + ["volume", "mintime", "maxtime"] }
        if object["particle"] == nil { keys += ["color", "alpha", "opacity"] }
        if object["text"] != nil { keys += ["backgroundcolor", "backgroundbrightness"] + NativeMetalText.scriptKeys.sorted() }
        return keys
    }

    init(authored: [String: Any], properties: [String: Any], project: WallpaperProject, paths: Set<String>, usesPointer: Bool,
         camera: NativeCameraPose, layers: [NativeMetalSceneSource.Layer], textures: [String: NativeMetalSceneSource.Texture], pointVolumetrics: Bool,
         activeSlots: Set<Int>? = nil, initialLayerOrder: [String]? = nil, initialConfigurations: [String: [String: Any]]? = nil) throws {
        scene = authored; self.properties = properties; projectURL = project.projectURL; self.camera = camera
        self.paths = paths; self.usesPointer = usesPointer
        self.activeSlots = activeSlots; self.initialLayerOrder = initialLayerOrder
        self.initialConfigurations = initialConfigurations
        propertyTypes = Dictionary(uniqueKeysWithValues: project.propertyDefinitions.map { ($0.key, $0.type) })
        let objects = authored["objects"] as? [[String: Any]] ?? []
        var animations: [String: [String: Any]] = [:], writes: [String: [String]] = [:]
        for (index, object) in objects.enumerated() where activeSlots?.contains(index) ?? true {
            let id = SceneScriptBridge.objectID(object, index: index)
            guard writes[id] == nil else { throw SceneError.invalid("Metal SceneScript 图层 ID 重复：\(id)") }
            writes[id] = Self.writes(for: object).filter { pointVolumetrics || !["castvolumetrics", "density", "volumetricsexponent"].contains($0) }
        }
        for layer in layers where layer.particles == nil {
            if let animation = textures[layer.texture]?.animation {
                animations[SceneScriptBridge.objectID(objects[layer.objectIndex], index: layer.objectIndex)] = animation.scriptMetadata
            }
        }
        var videos: [String: [String: Any]] = [:]
        for layer in layers where layer.particles == nil {
            if let video = textures[layer.texture]?.video {
                videos[SceneScriptBridge.objectID(objects[layer.objectIndex], index: layer.objectIndex)] = video.metadata(key: layer.texture)
            }
        }
        self.videos = videos
        self.textures = animations; layerWrites = writes
        signature = try JSONSerialization.data(withJSONObject: authored, options: [.sortedKeys])
    }

    @MainActor
    func makeInventory(animation: NativeMetalSceneAnimation.Runtime, sounds: [String: [String: Any]] = [:], at time: Double) throws -> SceneScriptInventory {
        try SceneScriptInventory(scene: scene, properties: properties,
            textureAnimations: textures, videoTextures: videos, sounds: sounds,
            timelines: animation.timelineStore.scriptMetadata, timelineValues: animation.scriptInput(at: time),
            layerWriteCapabilities: layerWrites, allowedBindingPaths: paths,
            bindingInitialValues: animation.effectScriptInitialValues, effectVisibilityBases: animation.effectVisibilityBases,
            materials: animation.materials, activeLayerSlots: activeSlots,
            initialLayerOrder: initialLayerOrder, initialLayerConfigurations: initialConfigurations)
    }

    @MainActor
    func makeBridge(animation: NativeMetalSceneAnimation.Runtime, sounds: [String: [String: Any]] = [:], models: NativeModelScriptStore? = nil, publication: SceneScriptBridge.Publication = .immediate, retirementHandler: SceneScriptBridge.RetirementHandler? = nil, resourceFonts: NativeBuiltinFonts.Snapshot? = nil, resourceRegistry: SceneScriptAssetRegistry? = nil, creationHandler: SceneScriptBridge.CreationHandler? = nil) throws -> SceneScriptBridge? {
        // Capture the graph store, never an obsolete renderer or property base.
        // Property transactions preserve this exact store at their commit point.
        let timelines = animation.timelineStore
        return try SceneScriptBridge(scene: scene, properties: properties, camera: camera,
            propertyTypes: propertyTypes, textureAnimations: textures, videoTextures: videos, sounds: sounds,
            timelines: timelines.scriptMetadata, timelineValues: animation.scriptInput(at: 0),
            timelineStateProvider: { timelines.scriptStates },
            timelineCommandHandler: { timelines.applyCommands($0) }, projectURL: projectURL,
            layerWriteCapabilities: layerWrites, allowedBindingPaths: paths, pointerInputAvailable: true,
            bindingInitialValues: animation.effectScriptInitialValues, effectVisibilityBases: animation.effectVisibilityBases, materials: animation.materials, timelineEvents: timelines, modelAnimations: models, publication: publication,
            activeLayerSlots: activeSlots, initialLayerOrder: initialLayerOrder, initialLayerConfigurations: initialConfigurations,
            retirementHandler: retirementHandler, resourceFonts: resourceFonts, resourceRegistry: resourceRegistry, creationHandler: creationHandler)
    }
}
