import Foundation
import CryptoKit
import CoreGraphics
import simd

/// A graphics-API-independent description of the supported ordinary Scene
/// path. Eligibility applies to the whole scene: unsupported authored behavior
/// keeps the existing backend, rather than dropping individual layers.
struct NativeMetalSceneSource {
    enum FontSelection: Sendable { case active, snapshot(NativeBuiltinFonts.Snapshot?) }
    struct Texture {
        let width: Int, height: Int, imageWidth: Int, imageHeight: Int
        let pixelWidth: Int, pixelHeight: Int, channels: Int
        let rgba: [UInt8]
        let repeating: Bool
        let animation: SceneTextureAnimation?
        var video: SceneVideoAsset? = nil
        var sourceType: UInt32 = 0
        var mipLevel: Int = 0
        var nearest: Bool = false
    }
    struct Layer {
        let objectIndex: Int
        let objectID: String
        let name: String, texture: String, blend: String
        /// A true value is currently rejected at source admission.  Keeping
        /// the fact on the typed layer means a future admission change cannot
        /// accidentally make it exportable before scene ping-pong exists.
        let copyBackground: Bool
        let colorBlendMode: Int
        var depth: NativeMetalDepth = .disabled
        let bounds: CGRect
        let transform: simd_float4x4
        let color: SIMD3<Float>
        let opacity: Float, brightness: Float
        let background: SIMD4<Float>
        let visible: Bool
        let effects: NativeMetalSceneEffects
        let particles: NativeMetalParticles?
        let text: NativeMetalText?
        let pointerID: String?
        var parentIndex: Int?
        var model: NativeMetalModels.Resource? = nil
        var modelAnimation: NativeModelAnimation.Source? = nil
        var modelObjectID: String? = nil
        var castsShadow: Bool = true
        var needsBackdrop: Bool { colorBlendMode != 0 && colorBlendMode != 31 }
        var finalBlend: String { colorBlendMode == 31 ? "additive" : blend }
        /// A published image is independent of its on-screen visibility, but
        /// must not depend on the completed scene or rely on scene-only
        /// geometry/state.  This is intentionally narrower than all current
        /// Metal image layers and mirrors the OpenGL composite-source gate.
        var isLayerCompositeProducer: Bool {
            !copyBackground && colorBlendMode == 0 && !needsBackdrop && !depth.test
                && model == nil && particles == nil
        }
    }
    let title: String
    let width: Float, height: Float, zoom: Float
    let clearColor: SIMD3<Float>
    let clearEnabled: Bool
    let tracksFrameHistory: Bool
    let hdr: Bool
    var postProcessingQuality: NativePostProcessingQuality = .ultra
    var textureResolutionRequest = NativeTextureResolutionRequest()
    var textureResolutionCanvas: NativeTextureCanvas = .unknown
    let hdrBloom: NativeHDRBloomParameters
    let bloom: NativeSceneBloom
    let camera: NativeMetalSceneCamera
    let textures: [String: Texture]
    let layers: [Layer]
    let layerGraph: NativeMetalSceneLayerGraph?
    let animation: NativeMetalSceneAnimation?
    let scripts: NativeMetalSceneScript?
    let sounds: [SceneSoundSource]
    let soundStates: [Int: SceneSoundState]
    let diagnostics: [String]
    let pointVolumeBoundary: Int?
    let layerOrder: NativeSceneLayerOrder?
    let lifecycleSnapshot: NativeSceneLifecycle.Snapshot
    let authoredFileSignature: Data
    let builtinFonts: NativeBuiltinFonts.Snapshot?

    static func load(_ project: WallpaperProject, properties: [String: Any]? = nil, videos: SceneVideoLibrary = SceneVideoLibrary(), snapshot: NativeSceneLifecycle.Snapshot? = nil, fontSelection: FontSelection = .active, postProcessing: NativePostProcessingQuality = .ultra, textureResolution: NativeTextureResolutionRequest = .init()) throws -> Self {
        let assets = try SceneAssets(directory: project.directoryURL)
        let relative = project.resourceURL.path.replacingOccurrences(of: project.directoryURL.path + "/", with: "")
        let original = try assets.json(relative)
        let authoredFileSignature = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])))
        let lifecycle = try snapshot ?? NativeSceneLifecycle(scene: original).snapshot
        let authored = try NativeModelMaterials.expand(lifecycle.materializedScene(), assets: assets)
        let activeSlots: Set<Int>? = lifecycle.activeSlots
        let builtinTextures = try NativeBuiltinTextures.activeSnapshot()
        let builtinFonts: NativeBuiltinFonts.Snapshot?
        let builtinFontError: String?
        switch fontSelection {
        case .snapshot(let saved): builtinFonts = saved; builtinFontError = nil
        case .active:
            do { builtinFonts = try NativeBuiltinFonts.activeSnapshot(); builtinFontError = nil }
            catch { builtinFonts = nil; builtinFontError = error.localizedDescription }
        }
        let values = properties ?? project.userProperties
        func unsupported(_ message: String) -> SceneError { .invalid(message) }
        func keys(_ object: [String: Any], _ allowed: Set<String>, _ label: String) throws {
            let extra = Set(object.keys).subtracting(allowed).sorted()
            guard extra.isEmpty else { throw unsupported("\(label) 含尚未迁移的字段：\(extra.prefix(4).joined(separator: "、"))。") }
        }
        var animationPaths = Set<String>(), scriptPaths = Set<String>()
        var scriptBytes = 0
        var usesPointerScripts = false
        // A direct JSON null is an authored default for `clearenabled` in
        // fixed official Scene resources. It is not a property wrapper or an
        // arbitrary nullable switch: retain the raw-key presence so the
        // existing color/depth-history allocation contract is unchanged.
        let authoredClearEnabledIsLiteralNull = (authored["general"] as? [String: Any])?["clearenabled"] is NSNull
        // `camerapreview` is an editor-only flag, not a normal Scene property
        // binding. Validate its authored representation before `resolve` can
        // unwrap a `{ "value": ... }` property object: only a literal JSON
        // Boolean is accepted for this compatibility exception.
        if let authoredGeneral = authored["general"] as? [String: Any],
           let preview = authoredGeneral["camerapreview"] {
            guard let number = preview as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw unsupported("camerapreview 必须为原始布尔值。")
            }
        }
        func resolve(_ raw: Any, path: String = "", depth: Int = 0) throws -> Any {
            guard depth <= 64 else { throw unsupported("Scene 属性嵌套超过 64 层。") }
            if let object = raw as? [String: Any] {
                if object["nativeEditorMotion"] != nil {
                    throw unsupported("原生编辑动画尚未迁移到通用 Metal 路径。")
                }
                if let script = object["script"] {
                    guard object["value"] != nil else { throw unsupported("SceneScript 缺少属性初始值。") }
                    let needsPointer = try NativeMetalSceneScript.validate(script, path: path, lifecycleAvailable: true)
                    usesPointerScripts = usesPointerScripts || needsPointer
                    if let text = script as? String, !text.isEmpty {
                        scriptPaths.insert(path); scriptBytes += text.utf8.count
                        guard scriptPaths.count <= 128, scriptBytes <= 2 * 1024 * 1024 else { throw unsupported("SceneScript 超过 128 段或 2 MiB。") }
                    }
                }
                // An MDLA layer uses a numeric clip identifier named animation,
                // while a property wrapper uses a graph object at that key.
                let pathParts = path.split(separator: "/")
                let modelClip = pathParts.count == 4 && pathParts[0] == "objects" && pathParts[2] == "animationlayers"
                if let animation = object["animation"], !modelClip {
                    guard object["value"] != nil else { throw unsupported("时间轴缺少属性初始值。") }
                    try NativeMetalSceneAnimation.validate(animation, at: path)
                    animationPaths.insert(path)
                }
                if let fallback = object["value"] {
                    try keys(object, ["value", "user", "animation", "script", "scriptproperties"], "属性绑定")
                    // The shared script collector also visits scriptproperties.
                    // Inspect those declarations before unwrapping the value,
                    // so a nested output cannot evade whole-scene admission.
                    if let properties = object["scriptproperties"] {
                        _ = try resolve(properties, path: path + "/scriptproperties", depth: depth + 1)
                    }
                    var value = fallback
                    if let key = object["user"] as? String { value = (values[key] as? [String: Any])?["value"] ?? fallback }
                    else if let reference = object["user"] as? [String: Any], let key = reference["name"] as? String {
                        try keys(reference, ["name", "condition"], "属性条件")
                        if let current = (values[key] as? [String: Any])?["value"] {
                            value = reference["condition"].map { String(describing: current) == String(describing: $0) } ?? current
                        }
                    } else if object["user"] != nil { throw unsupported("无法识别属性绑定。") }
                    return try resolve(value, path: path + "/value", depth: depth + 1)
                }
                return try Dictionary(uniqueKeysWithValues: object.map { key, value in
                    let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    return (key, try resolve(value, path: path + "/" + escaped, depth: depth + 1))
                })
            }
            if let array = raw as? [Any] { return try array.enumerated().map { try resolve($0.element, path: path + "/\($0.offset)", depth: depth + 1) } }
            return raw
        }
        guard let scene = try resolve(authored) as? [String: Any] else { throw unsupported("Scene 不是对象。") }
        try keys(scene, ["camera", "general", "objects", "version"], "Scene")
        let general = scene["general"] as? [String: Any] ?? [:]
        // `camerapreview` occurs as a Boolean in the fixed official editor
        // preview projects, while the fixed player-side Scene string tables do
        // not expose it. It is deliberately accepted as editor metadata only:
        // it must not alter the runtime camera or any Metal frame state. The
        // authored form was already checked before property resolution.
        if let preview = general["camerapreview"] {
            guard let number = preview as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw unsupported("camerapreview 必须为布尔值。")
            }
            _ = number.boolValue
        }
        try keys(general, ["orthogonalprojection", "fov", "nearz", "farz", "clearcolor", "clearenabled", "camerafade", "zoom", "perspectiveoverridefov", "bloom", "bloomstrength", "bloomthreshold", "bloomtint", "bloomhdrstrength", "bloomhdrthreshold", "bloomhdrfeather", "bloomhdrscatter", "bloomhdriterations", "cameraparallax", "cameraparallaxamount", "cameraparallaxdelay", "cameraparallaxmouseinfluence", "camerapreview", "camerashake", "camerashakespeed", "camerashakeamplitude", "camerashakeroughness", "ambientcolor", "skylightcolor", "fogdistance", "fogdistancestart", "fogdistanceend", "fogdistancestartdensity", "fogdistanceenddensity", "fogdistancecolor", "hdr", "hdrtonemap", "lightconfig"], "场景设置")
        if let raw = general["lightconfig"] {
            guard let config = raw as? [String: Any] else { throw unsupported("Metal 灯光设置需要对象。") }
            try keys(config, ["pointshadow", "spotshadow"], "灯光设置")
            for key in ["pointshadow", "spotshadow"] {
                guard let raw = config[key] else { continue }
                let values = SceneValues.floats(raw)
                guard values.count == 1, values[0].isFinite else { throw unsupported("Metal 灯光阴影数量无效。") }
            }
        }
        if let clearEnabled = general["clearenabled"] {
            let literalNull = authoredClearEnabledIsLiteralNull && clearEnabled is NSNull
            let boolean = (clearEnabled as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            guard literalNull || boolean else { throw unsupported("clearenabled 开关不是可识别的布尔值。") }
        }
        for feature in ["hdr", "bloom", "cameraparallax", "camerashake", "fogdistance", "camerafade"] {
            guard general[feature] == nil || general[feature] as? Bool != nil else { throw unsupported("\(feature) 开关不是可识别的布尔值。") }
        }
        for (key, count) in [("ambientcolor", 3), ("skylightcolor", 3), ("fogdistancecolor", 3),
                             ("fogdistancestart", 1), ("fogdistanceend", 1),
                             ("fogdistancestartdensity", 1), ("fogdistanceenddensity", 1)] {
            if let raw = general[key] {
                let values = SceneValues.floats(raw)
                guard values.count == count, values.allSatisfy(\.isFinite) else { throw unsupported("Metal 场景 \(key) 的数值维度或范围无效。") }
            }
        }
        let textureCanvas = NativeTextureCanvas(scene: scene)
        let textureMip = textureResolution.preferredMip(canvas: textureCanvas)
        let hdr = postProcessing.usesHDR(authored: general["hdr"] as? Bool == true)
        let isOrthographic = general["orthogonalprojection"] is [String: Any]
        let width: Float, height: Float
        if let projection = general["orthogonalprojection"] as? [String: Any] {
            try keys(projection, ["width", "height", "auto"], "二维投影")
            guard projection["auto"] == nil || projection["auto"] as? Bool == false else { throw unsupported("自动画布尺寸尚未迁移。") }
            width = SceneValues.number(projection["width"], 0); height = SceneValues.number(projection["height"], 0)
            guard (1...16384).contains(width), (1...16384).contains(height) else { throw unsupported("二维画布尺寸缺失或超过 16384。") }
        } else {
            guard general["orthogonalprojection"] == nil else { throw unsupported("二维投影声明不是对象。") }
            // Perspective framing comes from the current drawable aspect, not
            // a fictitious orthographic canvas or the author's zoom property.
            width = 1; height = 1
        }
        let orthographic = NativeOrthographicProjection(zoom: isOrthographic ? general["zoom"] : nil)
        guard orthographic.diagnostics.isEmpty else { throw unsupported(orthographic.diagnostics.joined(separator: " ")) }
        let camera = scene["camera"] as? [String: Any] ?? [:]
        try keys(camera, ["eye", "center", "up", "zoom", "paths"], "相机")
        if let paths = camera["paths"] {
            guard let paths = paths as? [Any], paths.count <= 1024 else { throw unsupported("旧版相机路径列表无效或超过 1024 项。") }
        }
        guard let objects = scene["objects"] as? [[String: Any]], (!objects.isEmpty || snapshot != nil), objects.count <= 5000,
              let authoredObjects = authored["objects"] as? [[String: Any]], authoredObjects.count == objects.count else { throw unsupported("Scene 对象列表无效。") }
        let hierarchy = SceneHierarchy(objects: objects)
        let layerOrder = try snapshot.map { try NativeSceneLayerOrder(objects: authoredObjects, activeSlots: $0.activeSlots, order: $0.orderedIDs) }
        guard hierarchy.invalid.isEmpty else { throw unsupported(hierarchy.diagnostics.joined(separator: " ")) }
        let cameraSource = try NativeMetalSceneCamera(width: width, height: height, general: general,
            camera: camera, objects: objects, hierarchy: hierarchy, assets: assets, properties: values)
        let cameraObjects = objects.contains { $0["camera"] is String }
            ? try NativeMetalCameraObjects(objects: objects, orthographic: isOrthographic, assets: assets, properties: values) : nil
        let transforms = hierarchy.resolve(local: objects.map(SceneValues.transform), visible: objects.map { SceneValues.visible($0["visible"]) })
        guard transforms.transforms.allSatisfy({ matrix in (0..<4).allSatisfy { c in (0..<4).allSatisfy { matrix[c][$0].isFinite } } }) else { throw unsupported("图层变换包含无效数值。") }
        var textures: [String: Texture] = [:], layers: [Layer] = [], notes: [String] = []
        if let builtinFontError { notes.append("内置字体库未加载：\(builtinFontError)") }
        var modelResources: [String: NativeMetalModels.Resource] = [:], modelBytes = 0, modelAnimationBytes = 0, lightCount = 0
        var sounds: [SceneSoundSource] = [], soundStates: [Int: SceneSoundState] = [:], soundBytes = 0
        var effectParameterBases: [String: [Float]] = [:]
        var effectVisibilityBases: [String: Bool] = [:]
        var decodedBytes = 0, textPixels = 0, textLayers = 0, effectPasses = 0
        var particleRoots = 0, particleCapacity = 0, childCapacity = 0
        func store(_ key: String, _ texture: Texture) throws {
            guard textures.count < 256, texture.rgba.count <= 256 * 1024 * 1024 - decodedBytes else { throw unsupported("Scene 纹理超过 256 张或 256 MiB 解码上限。") }
            decodedBytes += texture.rgba.count; textures[key] = texture
        }
        func texture(_ name: String) throws -> String {
            guard !name.hasPrefix("_rt_"), !name.hasPrefix("$") else { throw unsupported("动态纹理 \(name) 尚未迁移。") }
            let key = name.hasSuffix(".tex") ? name : "materials/\(name).tex"
            if textures[key] != nil { return key }
            if name == "util/white", !assets.contains(key) {
                try store(key, Texture(width: 1, height: 1, imageWidth: 1, imageHeight: 1, pixelWidth: 1, pixelHeight: 1, channels: 4, rgba: [255,255,255,255], repeating: false, animation: nil))
            } else if name == "util/noise", !assets.contains(key), builtinTextures?.contains(key) != true {
                try store(key, Texture(width: 256, height: 256, imageWidth: 256, imageHeight: 256, pixelWidth: 256, pixelHeight: 256, channels: 4, rgba: NativeNoiseTexture.whiteRGBA(), repeating: true, animation: nil))
            } else {
                let data = try assets.contains(key) ? assets.data(key, maximumBytes: SceneTexture.maximumResourceBytes) : (builtinTextures?.contains(key) == true ? builtinTextures!.data(key) : assets.data(key, maximumBytes: SceneTexture.maximumResourceBytes))
                if SceneVideoContainer.isVideo(data) {
                    guard let video = try videos.asset(key), video.matches(data) else { throw unsupported("Scene 视频尚未准备完成或资源已改变。") }
                    try store(key, Texture(width: video.width, height: video.height, imageWidth: video.width, imageHeight: video.height,
                        pixelWidth: video.width, pixelHeight: video.height, channels: 4, rgba: video.firstFrame.rgba,
                        repeating: video.flags & 2 == 0, animation: nil, video: video, nearest: video.flags & 1 != 0))
                    return key
                }
                let decoded = try SceneTexture.decode(data, preferredMip: textureMip)
                try store(key, Texture(width: decoded.width, height: decoded.height, imageWidth: decoded.imageWidth, imageHeight: decoded.imageHeight, pixelWidth: decoded.pixelWidth, pixelHeight: decoded.pixelHeight, channels: decoded.channelCount, rgba: decoded.rgba, repeating: decoded.flags & 2 == 0, animation: decoded.animation, sourceType: decoded.sourceType, mipLevel: decoded.mipLevel, nearest: decoded.flags & 1 != 0))
            }
            return key
        }
        var scriptMaterials: [String: [SceneScriptMaterial]] = [:]
        let originalObjects = authored["objects"] as? [[String: Any]] ?? []
        let objectKeys: Set<String> = Set(["id", "name", "image", "text", "origin", "angles", "scale", "color", "alpha", "opacity", "visible", "parent", "size", "alignment", "effects", "colorBlendMode", "parallaxDepth", "instance", "depthtest", "depthwrite", "locktransforms", "particle", "instanceoverride", "solid", "copybackground", "dependencies"]).union(SceneTextLayout.properties)
        /// Object-level dependencies are an author resource declaration, not a
        /// render edge.  Validate its finite primitive shape without using it
        /// to influence the Metal graph; stale declarations must not invent a
        /// producer or force a frame ordering.
        func validateDependencies(_ raw: Any?, name: String) throws {
            guard let raw else { return }
            guard let entries = raw as? [Any], entries.count <= 1024 else {
                throw unsupported("\(name) 的 dependencies 需要至多 1024 个对象 ID。")
            }
            var seen = Set<Int>()
            for entry in entries {
                guard let number = entry as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let value = Int(exactly: number.doubleValue), value >= 0,
                      seen.insert(value).inserted else {
                    throw unsupported("\(name) 的 dependencies 含无效或重复对象 ID。")
                }
            }
        }
        func copyBackground(_ raw: Any?, name: String) throws -> Bool {
            guard let raw else { return false }
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw unsupported("\(name) 的 copybackground 需要布尔值。")
            }
            guard !number.boolValue else {
                throw unsupported("\(name) 使用 copybackground；Metal 场景帧复制尚未迁移。")
            }
            return false
        }
        for (index, object) in objects.enumerated() where activeSlots?.contains(index) ?? true {
            let name = object["name"] as? String ?? "图层 \(index + 1)"
            if NativeSceneTransformNode.matches(object) { continue }
            if object["camera"] != nil {
                try keys(object, ["id", "name", "camera", "path", "queuemode", "fov", "zoom", "origin", "angles", "scale", "visible", "parent", "locktransforms", "parallaxDepth"], name)
                guard object["camera"] is String else { throw unsupported("Camera 标识必须为字符串。") }
                continue
            }
            if object["light"] != nil {
                try keys(object, ["id", "name", "light", "origin", "angles", "scale", "visible", "parent", "locktransforms", "parallaxDepth", "color", "intensity", "radius", "exponent", "innercone", "outercone", "castshadow", "castvolumetrics", "usecookie", "lightsourcesize", "density", "volumetricsexponent"], name)
                guard let kind = object["light"] as? String, ["lpoint", "lspot", "ldirectional"].contains(kind), lightCount < NativeModelLightFrame.maximumLights else { throw unsupported("Metal 目前支持最多 \(NativeModelLightFrame.maximumLights) 个点光、聚光或方向光对象。") }
                for key in ["castshadow", "castvolumetrics", "usecookie"] {
                    guard object[key] == nil || object[key] as? Bool != nil else { throw unsupported("Metal 灯光 \(key) 需要布尔值。") }
                }
                for (key, count) in [("color", 3), ("intensity", 1), ("radius", 1), ("exponent", 1), ("innercone", 1), ("outercone", 1), ("lightsourcesize", 1), ("density", 1), ("volumetricsexponent", 1)] {
                    if let raw = object[key] {
                        let values = SceneValues.floats(raw)
                        guard values.count == count, values.allSatisfy(\.isFinite) else { throw unsupported("Metal 灯光 \(key) 的数值维度无效。") }
                    }
                }
                if kind == "lspot", !SceneValues.visible(object["usecookie"] ?? false), NativeModelLightFrame.spotCone(object: object, transform: transforms.transforms[index]) == nil {
                    throw unsupported("Metal 聚光灯需要有效方向及 0 ≤ 内锥角 ≤ 外锥角 ≤ 180 度。")
                }
                guard kind == "lpoint" || (!SceneValues.visible(object["castvolumetrics"] ?? false) && !scriptPaths.contains("/objects/\(index)/castvolumetrics")) else { throw unsupported("Metal 目前仅支持点光体积光。") }
                guard kind != "ldirectional" || (!SceneValues.visible(object["castshadow"] ?? false) && !scriptPaths.contains("/objects/\(index)/castshadow")) else { throw unsupported("Metal 方向光阴影尚未实现。") }
                if kind == "lspot", SceneValues.visible(object["castshadow"] ?? false), NativeSpotShadows(object: object,transform: transforms.transforms[index]) == nil {
                    throw unsupported("Metal 聚光阴影需要非退化变换和 0 < 外锥角 < 90 度。")
                }
                if SceneValues.visible(object["usecookie"] ?? false) || scriptPaths.contains("/objects/\(index)/usecookie") {
                    guard kind == "lspot", NativeSpotProjection(outerDegrees:SceneValues.number(object["outercone"],30),
                        radius:SceneValues.number(object["radius"],5),transform:transforms.transforms[index]) != nil else {
                        throw unsupported("投影灯光需要聚光灯、非退化变换和 0 < 外锥角 < 90 度。")
                    }
                }
                lightCount += 1
                continue
            }
            if let path = object["model"] as? String {
                try keys(object, ["id", "name", "model", "origin", "angles", "scale", "visible", "parent", "locktransforms", "parallaxDepth", "animationlayers", "rootmotion", "castshadow", NativeModelMaterials.key], name)
                guard object["castshadow"] == nil || object["castshadow"] as? Bool != nil else { throw unsupported("Metal 模型 castshadow 需要布尔值。") }
                guard object["rootmotion"] == nil || object["rootmotion"] as? Bool != nil else { throw unsupported("Metal 模型 rootmotion 需要布尔值。") }
                let resource: NativeMetalModels.Resource
                if let cached = modelResources[path] { resource = cached }
                else {
                    guard modelResources.count < 512 else { throw unsupported("Metal 模型资源超过 512 份。") }
                    resource = try NativeMetalModels.load(path, assets: assets, properties: values, texture: { name in
                        let key = try texture(name)
                        return (key, textures[key]!.sourceType)
                    })
                    let animationBytes = resource.model.skeleton?.animationBytes ?? 0
                    guard resource.geometryBytes <= 128 * 1024 * 1024 - modelBytes, animationBytes <= 32 * 1024 * 1024 - modelAnimationBytes else { throw unsupported("Metal 模型几何或动画数据超过场景预算。") }
                    for material in resource.materials.flatMap({ $0 }) {
                        let ordinaryTextures = [material.texture] + [material.normalTexture,material.maskTexture,material.gradientTexture,material.noiseTexture].compactMap { $0 }
                        guard ordinaryTextures.allSatisfy({ textures[$0]?.animation == nil }) else {
                            throw unsupported("模型材质的 TEX 图集序列尚未迁移；内嵌视频可通过系统解码器播放。")
                        }
                    }
                    modelResources[path] = resource; modelBytes += resource.geometryBytes; modelAnimationBytes += animationBytes
                }
                let modelAnimation = try NativeModelAnimation.Source.make(object["animationlayers"], skeleton: resource.model.skeleton, includeEmpty: true)
                let entries = try SceneScriptMaterial.merge(resource.materials.flatMap { $0 }.map { $0.runtimeMaterial(instance: index, hdr: hdr) })
                for entry in entries {
                    let owner = entry.path.components(separatedBy: "/passes/")[0]
                    scriptMaterials[owner, default: []].append(entry)
                    for property in entry.properties { effectParameterBases[property.path] = property.value }
                }
                layers.append(Layer(objectIndex: index, objectID: SceneScriptBridge.objectID(object, index: index), name: name, texture: resource.materials[0][0].texture, blend: "normal", copyBackground: false, colorBlendMode: 0,
                    bounds: .zero, transform: transforms.transforms[index], color: SIMD3(repeating: 1), opacity: 1, brightness: 1, background: .zero,
                    visible: transforms.visible[index], effects: NativeMetalSceneEffects(groups: []), particles: nil, text: nil, pointerID: nil, parentIndex: hierarchy.parents[index], model: resource, modelAnimation: modelAnimation, modelObjectID: SceneScriptBridge.objectID(object, index: index), castsShadow: SceneValues.visible(object["castshadow"])))
                continue
            }
            if object["sound"] != nil {
                try keys(object, ["id", "name", "sound", "playbackmode", "startsilent", "muteineditor", "mintime", "maxtime", "volume", "visible", "origin", "angles", "scale", "parent", "parallaxDepth", "locktransforms"], name)
                guard sounds.count < 32 else { throw unsupported("Scene 声音超过 32 层。") }
                let sound = try SceneSoundSource(object: object, index: index, assets: assets, remainingBytes: 128 * 1024 * 1024 - soundBytes)
                guard !sounds.contains(where: { $0.id == sound.id }) else { throw unsupported("声音层 ID 重复。") }
                sounds.append(sound); soundBytes += sound.byteCount
                soundStates[index] = SceneSoundState(volume: object["volume"], visible: transforms.visible[index], minimum: object["mintime"], maximum: object["maxtime"])
                continue
            }
            try keys(object, objectKeys, name)
            try validateDependencies(object["dependencies"], name: name)
            let usesCopyBackground = try copyBackground(object["copybackground"], name: name)
            guard object["solid"] == nil || object["solid"] as? Bool != nil else { throw unsupported("\(name) 的 Solid 开关不是布尔值。") }
            let effects = try NativeMetalSceneEffects.load(object["effects"], assets: assets, values: values, hdr: hdr,
                prefix: "/objects/\(index)/effects", parameterPaths: animationPaths.union(scriptPaths),
                authored: originalObjects.indices.contains(index) ? originalObjects[index]["effects"] : nil, dynamic: !scriptPaths.isEmpty,
                resolve: { try resolve($0) }, texture: texture)
            effectPasses += effects.groups.reduce(0) { $0 + $1.passes.count }
            guard effectPasses <= 2048 else { throw unsupported("Scene 效果阶段超过 2048 个。") }
            for group in effects.groups {
                effectVisibilityBases[group.visibilityPath] = group.enabled
                scriptMaterials[group.visibilityPath] = group.materials
                for pass in group.passes {
                    // `amount` is the checked Motion Blur accumulation rate.
                    // It may be an authored animation or a SceneScript value,
                    // so it must receive a base entry just like the other
                    // dynamically sampled material parameters.
                    for parameter in [pass.scale, pass.color, pass.alpha, pass.amount] {
                        guard let path = parameter.bindingPath else { continue }
                        guard effectParameterBases[path] == nil || effectParameterBases[path] == parameter.value else {
                            throw unsupported("\(path)：多个材质阶段的参数基值不一致，尚未迁移。")
                        }
                        effectParameterBases[path] = parameter.value
                    }
                    for input in pass.inputs.values {
                        if case .texture(let key) = input, textures[key]?.animation != nil { throw unsupported("效果纹理的 TEX 序列采样尚未迁移。") }
                    }
                }
            }
            let colorBlendMode: Int
            if let raw = object["colorBlendMode"], !(raw is NSNull) {
                guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let mode = Int(exactly: number.doubleValue), NativeBlendModes.supports(mode) else {
                    throw unsupported("\(name) 的 colorBlendMode 需要 0–32 的整数。")
                }
                colorBlendMode = mode
            } else { colorBlendMode = 0 }
            // Text owns an object-level depth-test switch. Images and particles
            // take depth state from their materials; do not invent overrides.
            if object["text"] == nil {
                for key in ["depthtest", "depthwrite"] { guard object[key] == nil || object[key] as? String == "disabled" else { throw unsupported("\(name) 的对象深度覆盖尚未迁移，请使用材质状态。") } }
            }

            if object["particle"] != nil {
                try keys(object, ["id", "name", "particle", "instanceoverride", "origin", "angles", "scale", "visible", "parent", "parallaxDepth", "depthtest", "depthwrite", "locktransforms", "effects", "colorBlendMode"], name)
                guard object["image"] == nil, object["text"] == nil, object["instance"] == nil,
                      effects.groups.isEmpty, colorBlendMode == 0 else { throw unsupported("粒子图层的图片效果或颜色混合尚未迁移。") }
                let particles = try NativeMetalParticles.load(object: object, assets: assets, values: values, orthographic: isOrthographic,
                    resolve: { try resolve($0) }, texture: { name in let key = try texture(name); return (key, textures[key]!) })
                particleRoots += 1; particleCapacity += particles.reservedParticles; childCapacity += particles.reservedInstances
                guard particleRoots <= 64, particleCapacity <= 65536, childCapacity <= 2048 else {
                    throw unsupported("Metal 粒子超过 64 个根系统、65536 个总粒子或 2048 个子实例的预留上限。")
                }
                notes += particles.warnings.map { name + "：" + $0 }
                layers.append(Layer(objectIndex: index, objectID: SceneScriptBridge.objectID(object, index: index), name: name, texture: particles.material.texture,
                    blend: particles.material.blend, copyBackground: false, colorBlendMode: 0, bounds: .zero,
                    transform: transforms.transforms[index], color: SIMD3(repeating: 1), opacity: 1,
                    brightness: 1, background: .zero, visible: transforms.visible[index], effects: effects, particles: particles, text: nil, pointerID: nil, parentIndex: hierarchy.parents[index]))
                continue
            }
            let resource: String, bounds: CGRect, blend: String, brightness: Float, background: SIMD4<Float>
            var textSource: NativeMetalText?
            var depth = NativeMetalDepth.disabled
            if object["text"] != nil {
                guard object["depthwrite"] == nil || object["depthwrite"] as? String == "disabled" else { throw unsupported("文字深度写入尚未迁移。") }
                depth = try NativeMetalDepth(["depthtest": object["depthtest"] ?? "disabled"])
                guard object["image"] == nil, object["instance"] == nil, textLayers < 32 else { throw unsupported("文字层结构无效或超过 32 层。") }
                _ = try NativeTextAnchor.parse(object["anchor"])
                try NativeMetalText.validateAlignment(object)
                let layout = try SceneTextLayout(object: authoredObjects[index], assets: assets, builtinFonts: builtinFonts)
                guard let bitmap = try layout.rasterize(object), bitmap.width * bitmap.height <= 8 * 1024 * 1024 - textPixels else { throw unsupported("文字图片超过合计 8M 像素。") }
                notes += layout.diagnostics.map { "\(name)：\($0)" }
                textLayers += 1; textPixels += bitmap.width * bitmap.height
                resource = "text:\(index)"
                try store(resource, Texture(width: bitmap.width, height: bitmap.height, imageWidth: bitmap.width, imageHeight: bitmap.height, pixelWidth: bitmap.width, pixelHeight: bitmap.height, channels: 4, rgba: bitmap.rgba, repeating: false, animation: nil))
                bounds = CGRect(x: Double(bitmap.offset.x) - Double(bitmap.width) / 2, y: Double(bitmap.offset.y) - Double(bitmap.height) / 2, width: Double(bitmap.width), height: Double(bitmap.height))
                textSource = try NativeMetalText(authored: authoredObjects[index], resolved: object, assets: assets, builtinFonts: builtinFonts, directory: project.directoryURL,
                    layoutDiagnostic: layout.runtimeDiagnostic ?? "文字排版快照不可用。")
                blend = "translucent"; brightness = 1
                let color = SceneValues.vector(object["backgroundcolor"], .zero) * SceneValues.number(object["backgroundbrightness"], 1)
                background = SIMD4(color, object["opaquebackground"] as? Bool == true ? 1 : 0)
            } else if let image = object["image"] as? String {
                let model = image == "models/util/solidlayer.json" && !assets.contains(image)
                    ? ["solidlayer": true, "material": "materials/util/solidlayer.json"] : try assets.json(image)
                try keys(model, ["material", "width", "height", "autosize", "solidlayer"], "图片模型")
                guard let path = model["material"] as? String else { throw unsupported("图片模型缺少材质。") }
                let material: [String: Any]
                if model["solidlayer"] as? Bool == true, !assets.contains(path) {
                    material = ["passes": [["shader": "genericimage2", "textures": ["util/white"], "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled"]]]
                } else { material = try assets.json(path) }
                try keys(material, ["passes"], "图片材质")
                guard let passes = material["passes"] as? [[String: Any]], passes.count == 1 else { throw unsupported("多阶段图片材质尚未迁移。") }
                var pass = passes[0]
                if let instance = object["instance"] {
                    guard model["solidlayer"] as? Bool == true, let instance = instance as? [String: Any] else { throw unsupported("图片材质实例覆盖尚未迁移。") }
                    for (key, value) in instance {
                        if let next = value as? [String: Any], let previous = pass[key] as? [String: Any] { pass[key] = previous.merging(next) { _, new in new } }
                        else { pass[key] = value }
                    }
                }
                pass = try resolve(pass) as! [String: Any]
                try keys(pass, ["shader", "textures", "combos", "blending", "cullmode", "depthtest", "depthwrite", "constantshadervalues", "usershadervalues", "visible"], "图片 pass")
                guard let shader = pass["shader"] as? String, ["genericimage2", "genericimage4"].contains(shader),
                      !assets.contains("shaders/\(shader).vert"), !assets.contains("shaders/\(shader).frag") else { throw unsupported("作者着色器尚未迁移到 Metal。") }
                var combos: [String: Int] = [:]
                for (key, raw) in pass["combos"] as? [String: Any] ?? [:] {
                    guard let number = raw as? NSNumber, let value = Int(exactly: number.doubleValue) else { throw unsupported("图片材质组合无效。") }
                    let canonical = key.lowercased()
                    guard combos[canonical] == nil || combos[canonical] == value else { throw unsupported("图片材质组合冲突。") }
                    combos[canonical] = value
                    guard canonical == "spritesheet" ? [0,1].contains(value) : (shader == "genericimage2" && canonical == "version" ? [0,1,2].contains(value) : value == 0) else { throw unsupported("图片材质组合 \(key) 尚未迁移。") }
                }
                blend = pass["blending"] as? String ?? "normal"
                guard ["normal", "translucent", "additive"].contains(blend), (pass["cullmode"] == nil || pass["cullmode"] as? String == "nocull") else { throw unsupported("图片混合或剔除状态尚未迁移。") }
                depth = try NativeMetalDepth(pass)
                guard pass["visible"] == nil || pass["visible"] as? Bool == true else { throw unsupported("材质可见性分支尚未迁移。") }
                let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
                let bindings = pass["usershadervalues"] as? [String: Any] ?? [:]
                try keys(constants, ["Brightness"], "图片常量"); try keys(bindings, ["Brightness"], "图片属性")
                var rawBrightness = constants["Brightness"]
                if let key = bindings["Brightness"] as? String { rawBrightness = (values[key] as? [String: Any])?["value"] ?? rawBrightness }
                brightness = SceneValues.number(rawBrightness, 1)
                let names = pass["textures"] as? [String] ?? ["util/white"]
                guard names.count == 1 else { throw unsupported("多纹理图片材质尚未迁移。") }
                resource = try texture(names[0])
                let bitmap = textures[resource]!
                var size = SceneValues.floats(object["size"])
                if size.count < 2, model["width"] != nil, model["height"] != nil { size = [SceneValues.number(model["width"], 0), SceneValues.number(model["height"], 0)] }
                if size.count < 2, model["autosize"] as? Bool == true { size = [Float(bitmap.animation?.width ?? bitmap.imageWidth), Float(bitmap.animation?.height ?? bitmap.imageHeight)] }
                guard size.count >= 2, size.prefix(2).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 16384 }) else { throw unsupported("图片尺寸无效。") }
                let offset: SIMD2<Float>
                switch object["alignment"] as? String ?? "center" {
                case "center": offset = .zero
                case "left": offset = SIMD2(size[0] / 2, 0)
                case "right": offset = SIMD2(-size[0] / 2, 0)
                case "top": offset = SIMD2(0, -size[1] / 2)
                case "bottom": offset = SIMD2(0, size[1] / 2)
                default: throw unsupported("图片对齐方式尚未迁移。")
                }
                bounds = CGRect(x: Double(offset.x - size[0] / 2), y: Double(offset.y - size[1] / 2), width: Double(size[0]), height: Double(size[1]))
                background = .zero
            } else { throw unsupported("\(name) 的图层类型尚未迁移到通用 Metal 路径。") }
            guard !depth.test || (effects.groups.isEmpty && colorBlendMode == 0) else {
                throw unsupported("\(name) 的深度材质与图片效果/颜色合成组合尚未迁移。")
            }
            layers.append(Layer(objectIndex: index, objectID: SceneScriptBridge.objectID(object, index: index), name: name, texture: resource, blend: blend, copyBackground: usesCopyBackground, colorBlendMode: colorBlendMode, depth: depth, bounds: bounds, transform: transforms.transforms[index], color: SceneValues.vector(object["color"], SIMD3(repeating: 1)), opacity: max(0, min(1, SceneValues.number(object["alpha"] ?? object["opacity"], 1))), brightness: brightness, background: background, visible: transforms.visible[index], effects: effects, particles: nil, text: textSource,
                pointerID: (object["solid"] as? Bool ?? (object["image"] is String)) ? SceneScriptBridge.objectID(object, index: index) : nil,
                parentIndex: hierarchy.parents[index]))
        }
        let graph = try NativeMetalSceneLayerGraph(layers: layers)
        let layerGraph = graph.isEmpty ? nil : graph
        let projectionDeclared = objects.indices.contains { index in
            SceneValues.visible(objects[index]["usecookie"] ?? false) || scriptPaths.contains("/objects/\(index)/usecookie")
        }
        if projectionDeclared {
            guard modelResources.values.flatMap({ $0.materials.flatMap { $0 } }).allSatisfy({ !$0.lighting || $0.projectionTexture != nil }) else {
                throw unsupported("投影灯光资源尚未解析：当前需要受光模型材质在纹理槽 7 显式指定 TEX 或视频；引擎自动资源别名尚未接入。")
            }
        }
        // Keep authored draw ordering. Volume integration can run after one
        // contiguous opaque model block; even initially hidden model/material
        // declarations are checked because visibility may change at runtime.
        let pointLights = objects.indices.filter { objects[$0]["light"] as? String == "lpoint" }
        let models = layers.indices.filter { layers[$0].model != nil }
        let opaque = models.allSatisfy { index in
            layers[index].model!.materials.flatMap { $0 }.allSatisfy { $0.blend == "normal" && $0.depth.key == 3 }
        }
        let contiguous = models.first.map { first in models.last! - first + 1 == models.count } ?? true
        let volumeBoundary: Int? = !pointLights.isEmpty && !isOrthographic && opaque && contiguous ? (models.last.map { $0 + 1 } ?? 0) : nil
        let volumeDeclared = pointLights.contains { index in
            SceneValues.visible(objects[index]["castvolumetrics"] ?? false)
                || scriptPaths.contains("/objects/\(index)/castvolumetrics")
        }
        guard !volumeDeclared || volumeBoundary != nil else {
            throw unsupported("Metal 点光源体积光需要透视相机与连续的不透明深度模型块；二维、透明模型或交错排序保留兼容路径。")
        }
        // Connect curves only after material validation has identified every
        // actual consumer. A plausible JSON path alone cannot enable a track.
        let animation = try NativeMetalSceneAnimation.make(authored: authored, resolved: scene, paths: animationPaths, scriptPaths: scriptPaths,
            hierarchy: hierarchy, effectBases: effectParameterBases, effectVisibilityBases: effectVisibilityBases, materials: scriptMaterials, cameraObjects: cameraObjects, requiresRuntime: snapshot != nil)
        // An unchanged lifecycle snapshot is also passed during ordinary
        // property edits. It must not invent a script source for a scene that
        // never had scripts. A mutated graph retains its script inventory even
        // after the last scripted layer has been removed.
        let needsScriptSource = !scriptPaths.isEmpty || lifecycle.revision > 0
        let scripts = !needsScriptSource ? nil : try NativeMetalSceneScript(authored: authored, properties: values, project: project, paths: scriptPaths, usesPointer: usesPointerScripts,
            camera: cameraSource.legacy.staticPose, layers: layers, textures: textures, pointVolumetrics: volumeBoundary != nil,
            activeSlots: lifecycle.activeSlots, initialLayerOrder: lifecycle.orderedIDs,
            initialConfigurations: try lifecycle.initialConfigurations())
        guard layerGraph == nil || scripts == nil else {
            throw unsupported("含跨图层纹理引用的 Metal Scene 目前不与可变 SceneScript 图层结构并用。")
        }
        notes.append("通用 Scene（\(cameraSource.orthographic ? "二维正交" : "三维透视")）：\(layers.count) 个图层，\(hierarchy.parents.compactMap { $0 }.count) 条父子关系，\(textures.values.filter { $0.animation != nil }.count) 张 TEX 动画纹理。")
        notes.append("genericimage2/4 延用自研采样、亮度、颜色和透明度语义；尚未与 Windows 原版逐像素对齐。")
        notes.append("TEX 采样：\(textures.values.filter(\.nearest).count) 份资源采用作者指定的邻近采样，不使用 mip；其他资源保留线性采样。地址模式独立保留。图片、粒子、模型材质槽和外部效果纹理共用各自资源的设置；生成的文字和中间目标仍按自身规则采样。")
        if particleRoots > 0 { notes.append("Metal 粒子：\(particleRoots) 个根系统，预留 \(particleCapacity) 个粒子 / \(childCapacity) 个子实例；复用自研 CPU 生命周期、运动、序列及直接子系统。暂停重绘复用冻结网格，实例参数在恢复播放后生效。每帧顶点总量限制 64 MiB。材质深度测试、写入和鼠标控制点力场已接入；作者粒子着色器、照明/折射及粒子脚本仍由兼容路径处理。") }
        if !modelResources.isEmpty {
            notes.append("Metal MDL：共享已核对的静态/蒙皮布局、16/32 位索引、多子网格和默认骨矩阵；\(modelResources.count) 份模型，\(modelBytes) 字节几何。generic4 支持材质颜色、GGX 直接照明、距离雾；受支持的 MDLA 动画层按实例运行，支持用户参数与普通/叠加混合。generic4 上一场景帧反射已接入 Metal，粗糙度、金属度和反射强度支持材质脚本/曲线；方向光/聚光灯阴影、聚光灯体积光与作者着色器进入兼容路径；模型动画对象的动态创建、播放控制和结束回调已接入；动画层支持七项控制属性脚本，以及速度、混合权重、淡入淡出时长的数值曲线。蒙版和完整模型属性尚未接入。模型外部材质的颜色、透明度及当前照明/HDR 路径实际消费的数值参数已接入脚本与曲线；模型材质与图层外观分开，三维射线命中尚未实现。")
        }
        let blended = layers.filter { $0.colorBlendMode != 0 }
        if !blended.isEmpty { notes.append("\(blended.count) 个图层使用非默认颜色混合；局部效果完成后合成，共用自研混合公式。1–30 / 32 读取此前场景，31 使用 GPU 加法且不读取背景；最终保留作者材质混合状态。编号与特殊分支已由 REA 静态确认，尚未与 Windows 画面逐像素对齐。") }
        if effectPasses > 0 { notes.append("图片效果已接入 Metal 离屏图：\(effectPasses) 个已解析阶段，保留 previous、命名缓冲、遮罩与参数；\(effectParameterBases.count) 条效果参数绑定接入时间轴或 SceneScript。支持精确/普通模糊的 scale、合成颜色及对应数值材质对象；未知作者 GLSL、非默认合成、动态效果纹理及材质渲染函数仍待迁移。") }
        if let layerGraph { notes.append("Metal 图层纹理引用：\(layerGraph.exports.count) 个图片/文字源按 sampler 依赖拓扑离屏绘制；隐藏源仍输出，object dependencies 仅作已校验声明而不参与 GPU 排序。未知别名、缺源、循环、颜色合成、场景背景读取或可变脚本结构继续保留兼容路径。") }
        if let animation { notes.append("通用 Scene 的 \(animation.bindings.count) 条属性时间轴复用自研 Curve 和 Float 播放时钟；支持 loop / mirror / single、同一属性对象的联合动画与 SceneScript 动画控制，内联属性 animationEvent 已接入同层脚本；MDLA 模型标记已接入所属模型的图层脚本，随机时间轴及木偶事件仍待迁移。") }
        if scripts != nil { notes.append("Metal SceneScript：\(scriptPaths.count) 段脚本使用自研 JavaScriptCore 组件；接入数值、可见性、文字/字号/对齐/换行/锚点/两端对齐、作者设置、时间轴、纹理播放与静态相机。鼠标输入轮询与 Solid 图层的进入/离开/移动/按下/释放/点击已接入；已支持效果的二维 scale、三维 compositecolor 和可见性脚本接入同一离屏图；getEffect(name/index)、getEffectCount、thisObject.visible 与跨图层效果开关已接入；动态写入未支持属性会明确报告。") }
        if !sounds.isEmpty { notes.append("Metal Scene 声音：\(sounds.count) 层、\(soundBytes) 字节；AVAudioPlayer 播放包内资源，音量/可见性复用图层脚本与时间轴；首帧完成后由单个展示实例输出。自身音乐频谱无需系统录音权限。支持单层最多 64 项资源、随机选曲与间隔等待；暂停保留播放及调度位置。空间化与 Windows 精确播放时序仍未对齐。") }
        if textLayers > 0 { notes.append("Metal 动态文字复用 CoreText；只在内容或排版变化时重绘，颜色及背景使用 GPU 参数，锚点独立更新模型前偏移。限制 32 层、单层 2M / 合计 8M 像素；非法更新保留上一有效状态。文字边界与效果缓冲在同一帧提交；锚点仅覆盖二维居中填充裁切，字体 DPI、双向文本两端对齐和 Windows 像素外观仍待核对。") }
        notes.append("普通场景泛光使用 Metal 四分之一亮部提取、八分之一双向模糊和最终相加；支持作者开关、属性绑定及强度/阈值/颜色时间轴。HDR 使用 RGBA16F 多级泛光，支持柔化、散射、级数和独立 HDR 参数；最终输出仍为 SDR。")
        if !modelResources.isEmpty { notes.append("Metal 阴影按 lightconfig.pointshadow / spotshadow 分别选择点光和聚光；点光最多 4 盏、每盏六个视图，聚光使用一个透视视图；两类共用最多 12 盏直接灯光，每视图 512 像素。超出作者预算的灯光仍提供直接照明。模型默认投影，可由 castshadow 关闭；仅受支持的不透明模型阶段投影，非不透明阶段记录跳过数量。") }
        if volumeBoundary != nil { notes.append("Metal 点光源体积光支持透视相机、连续不透明原生模型与距离雾；四分之一分辨率积分，在后续粒子、叠加层和全局泛光前加法合成。阴影灯 32 次、无阴影灯 5 次采样；透明模型交错、二维逐层视差、高度雾与聚光灯仍待迁移。") }
        let mappedMaterials = modelResources.values.flatMap { $0.materials.flatMap { $0 } }
        let chromaCount = mappedMaterials.filter(\.chroma).count
        if chromaCount > 0 {
            notes.append("原生 Chroma 材质：\(chromaCount) 个阶段；已接入观察角度变色、Alpha 遮罩、高光着色和噪声色素，参数可由作者设置、时间轴和脚本驱动。未提供噪声资源时使用已导入素材或自研确定性噪声；Windows 像素一致性仍未验证。")
        }
        let modelVideos = Set(mappedMaterials.flatMap(\.textures).filter { textures[$0]?.video != nil })
        if !modelVideos.isEmpty {
            notes.append("Metal 模型视频贴图：\(modelVideos.count) 份资源；基础颜色、法线、PBR 和明暗渐变使用各自纹理槽。视频按场景时间解码，同一资源共享播放状态；暂停和定位沿用 Scene 时钟。TEX 图集序列仍需单独实现。")
        }
        if !mappedMaterials.isEmpty {
            notes.append("原生模型贴图：法线材质 \(mappedMaterials.filter { $0.normalTexture != nil }.count)，PBR 分量材质 \(mappedMaterials.filter { $0.mapFlags != 0 }.count)，Alpha 着色遮罩 \(mappedMaterials.filter { $0.tintMask }.count)；法线保留 TEX 格式和切线符号，PBR 使用 R 金属度 / G 粗糙度 / B 反射 / A 自发光。")
        }
        if !mappedMaterials.isEmpty { notes.append("原生卡通材质：明暗渐变 \(mappedMaterials.filter { $0.gradientTexture != nil }.count)，边缘光 \(mappedMaterials.filter { $0.lighting && $0.rimLighting }.count)；点光与方向光分别保留漫反射顺序，R8/RG88 渐变取红通道。") }
        if general["clearenabled"] != nil { notes.append("场景 clearenabled 控制每帧颜色与深度清除，默认开启；关闭时保留全局泛光前的历史。首次输出和时间回退初始化为 clearcolor 与远平面深度；暂停重绘保留原输入，恢复后使用最近一次重绘结果。初始内容、缩放策略和 Windows 像素一致性仍未与原版动态对齐。") }
        notes += cameraSource.legacy.diagnostics
        notes += cameraObjects?.diagnostics ?? []
        notes.append("Metal 相机支持二维根图层视差、三维透视与视差旋转、晃动、旧版路径和 fov/nearz/farz 数值时间轴/脚本。相机每帧只采样一次；macOS 鼠标与 delay 仍为自研适配策略，尚未证明 Windows 一致性。Camera 对象选择及路径队列共用原生状态机；完整模型动画脚本 API、方向光阴影/体积光、外部路径脚本和精确遮挡命中仍待迁移。")
        return Self(title: project.title, width: width, height: height, zoom: orthographic.zoom, clearColor: SceneValues.vector(general["clearcolor"], .zero), clearEnabled: general["clearenabled"] as? Bool ?? true, tracksFrameHistory: general["clearenabled"] != nil || !scriptPaths.isEmpty, hdr: hdr, postProcessingQuality: postProcessing, textureResolutionRequest: textureResolution, textureResolutionCanvas: textureCanvas, hdrBloom: NativeHDRBloomParameters(general: general), bloom: NativeSceneBloom(general: general), camera: cameraSource, textures: textures, layers: layers, layerGraph: layerGraph, animation: animation, scripts: scripts, sounds: sounds, soundStates: soundStates, diagnostics: notes, pointVolumeBoundary: volumeBoundary, layerOrder: layerOrder, lifecycleSnapshot: lifecycle, authoredFileSignature: authoredFileSignature, builtinFonts: builtinFonts)
    }
}
