import Foundation
import CryptoKit
import Metal
import simd

/// MDL geometry is decoded by the shared, bounded parser. Metal owns only
/// upload, the supported generic4 material, and draw encoding.
enum NativeMetalModels {
    struct Material {
        let texture: String, blend: String
        let normalTexture: String?, maskTexture: String?, gradientTexture: String?
        let chroma: Bool, noiseTexture: String?
        let projectionTexture: String?
        let chromaFront: SIMD4<Float>, chromaBack: SIMD4<Float>, chromaSpecular: SIMD4<Float>
        let normalFormat: UInt32, mapFlags: UInt32, gradientFormat: UInt32
        let rimLighting: Bool
        let rimAmount: Float, rimExponent: Float
        let tintMask: Bool
        let emissive: SIMD4<Float>
        var textures: [String] { [texture] + [normalTexture, maskTexture, gradientTexture, noiseTexture, projectionTexture].compactMap { $0 } }
        let depth: NativeMetalDepth
        let cull: Bool, visible: Bool, lighting: Bool, fog: Bool, reflection: Bool
        let tint: SIMD4<Float>
        let roughness: Float, metallic: Float, brightness: Float, reflectivity: Float
        let scriptMaterial: SceneScriptMaterial

        func runtimeMaterial(instance: Int, hdr: Bool) -> SceneScriptMaterial {
            var active: Set<String> = ["alpha"]
            if !chroma || tintMask { active.insert("color") }
            if chroma {
                active.formUnion(["tintfront", "tintback"])
                if tintMask { active.insert("tintwexponent") }
                if lighting { active.insert("speculartint") }
                if lighting || mapFlags & 8 != 0 { active.insert("tintpigmentation") }
            }
            if lighting || reflection {
                if mapFlags & 2 == 0 { active.insert("roughness") }
                if mapFlags & 1 == 0 { active.insert("metallic") }
            }
            if reflection { active.insert("reflectivity") }
            if hdr { active.insert("brightness") }
            if lighting && rimLighting { active.formUnion(["rimamount", "rimexponent"]) }
            if mapFlags & 8 != 0 { active.formUnion(["emissivecolor", "emissivebrightness"]) }
            return SceneScriptMaterial(path: scriptMaterial.path, properties: scriptMaterial.properties.filter { active.contains($0.name) })
                .prepending("/objects/\(instance)")
        }
    }
    struct Resource {
        let path: String, signature: String
        let model: SceneModel
        let materials: [[Material]]
        var geometryBytes: Int { model.meshes.reduce(0) { $0 + $1.byteCount } }
        var needsDepth: Bool { materials.flatMap { $0 }.contains { $0.depth.test } }
        var needsReflection: Bool { materials.flatMap { $0 }.contains { $0.reflection } }
    }

    static func load(_ path: String, assets: SceneAssets, properties: [String: Any],
                     texture: (String) throws -> (String, UInt32)) throws -> Resource {
        let data = try assets.data(path), model = try SceneModel.decode(data)
        func keys(_ raw: [String: Any], _ allowed: Set<String>) throws {
            guard Set(raw.keys).isSubset(of: allowed) else {
                throw SceneError.invalid("Metal 模型材质尚未迁移字段：\(Set(raw.keys).subtracting(allowed).sorted())。")
            }
        }
        // Declarations also live in the expanded Scene and are validated by
        // the animation/script collectors. Keep their owning material below.
        func value(_ raw: Any) throws -> Any {
            guard let object = raw as? [String: Any] else { return raw }
            try keys(object, ["value", "user", "script", "scriptproperties", "animation"])
            guard let fallback = object["value"] else { throw SceneError.invalid("模型材质属性缺少 value。") }
            if let user = object["user"] as? String { return (properties[user] as? [String: Any])?["value"] ?? fallback }
            guard object["user"] == nil else { throw SceneError.invalid("模型材质用户属性条件尚未迁移。") }
            return fallback
        }
        var cache: [String: [Material]] = [:]
        let materialPaths = NativeModelMaterials.paths(model)
        let materials = try model.meshes.map { mesh -> [Material] in
            if let cached = cache[mesh.materialPath] { return cached }
            let document = try assets.json(mesh.materialPath)
            try keys(document, ["passes"])
            guard let passes = document["passes"] as? [[String: Any]], !passes.isEmpty, passes.count <= 32 else {
                throw SceneError.invalid("Metal 模型材质需要 1...32 个阶段。")
            }
            let materialIndex = materialPaths.firstIndex { $0.lowercased() == mesh.materialPath.lowercased() }!
            let prepared = try passes.enumerated().map { passIndex, pass -> Material in
                try keys(pass, ["shader", "textures", "combos", "blending", "cullmode", "depthtest", "depthwrite", "constantshadervalues", "usershadervalues", "visible"])
                guard let shader = pass["shader"] as? String, ["generic4", "chroma4"].contains(shader),
                      !assets.contains("shaders/\(shader).vert"), !assets.contains("shaders/\(shader).frag") else {
                    throw SceneError.invalid("模型自定义着色器尚未迁移到 Metal。")
                }
                let chroma = shader == "chroma4"
                for key in ["combos", "constantshadervalues", "usershadervalues"] {
                    guard pass[key] == nil || pass[key] is [String: Any] else { throw SceneError.invalid("模型材质 \(key) 必须为对象。") }
                }
                for key in ["blending", "cullmode"] {
                    guard pass[key] == nil || pass[key] is String else { throw SceneError.invalid("模型材质 \(key) 必须为字符串。") }
                }
                guard pass["textures"] == nil || pass["textures"] is [Any] else { throw SceneError.invalid("模型纹理列表必须为数组。") }
                let combos = try NativeModelMaterial.combinations(pass)
                let blend = pass["blending"] as? String ?? "normal", cull = pass["cullmode"] as? String ?? "nocull"
                guard ["normal", "translucent", "additive"].contains(blend), ["normal", "nocull"].contains(cull) else {
                    throw SceneError.invalid("模型混合或剔除模式尚未迁移。")
                }
                let visible = try pass["visible"].map(value) ?? true
                guard let visible = visible as? Bool else { throw SceneError.invalid("模型材质可见性需要布尔值。") }
                let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
                let users = pass["usershadervalues"] as? [String: Any] ?? [:]
                let allowed = Set(NativeModelMaterials.dimensions.keys).subtracting(chroma ? [] : Set(NativeModelMaterials.chromaDimensions.keys))
                try keys(constants, allowed); try keys(users, allowed)
                func parameter(_ name: String, _ fallback: [Float]) throws -> [Float] {
                    var raw: Any = constants[name] ?? fallback
                    if let key = users[name] as? String { raw = (properties[key] as? [String: Any])?["value"] ?? raw }
                    else if users[name] != nil { throw SceneError.invalid("模型材质 \(name) 的用户属性绑定无效。") }
                    let numbers = SceneValues.floats(try value(raw))
                    guard numbers.count == fallback.count, numbers.allSatisfy({ $0.isFinite && abs($0) <= 16384 }) else {
                        throw SceneError.invalid("模型材质 \(name) 数值维度或范围无效。")
                    }
                    return numbers
                }
                let color = try parameter("color", [1,1,1]), alpha = try parameter("alpha", [1])[0]
                let roughness = try parameter("roughness", [0.7])[0], metallic = try parameter("metallic", [0])[0]
                let brightness = try parameter("brightness", [1])[0]
                let reflectivity = try parameter("reflectivity", [1])[0]
                let emissiveColor = try parameter("emissivecolor", [1,1,1])
                let emissiveBrightness = try parameter("emissivebrightness", [1])[0]
                let rimAmount = try parameter("rimamount", [2])[0], rimExponent = try parameter("rimexponent", [4])[0]
                let address = "/\(NativeModelMaterials.key)/\(materialIndex)/passes/\(passIndex)"
                var initial: [String: [Float]] = ["color": color, "alpha": [alpha], "roughness": [roughness], "metallic": [metallic], "brightness": [brightness], "reflectivity": [reflectivity], "emissivecolor": emissiveColor, "emissivebrightness": [emissiveBrightness], "rimamount": [rimAmount], "rimexponent": [rimExponent]]
                if chroma {
                    for (name, fallback) in ["tintfront": [Float](repeating: 1, count: 3), "tintback": [1,1,1], "speculartint": [1,1,1], "tintpigmentation": [0.5], "tintwexponent": [1.5]] {
                        initial[name] = try parameter(name, fallback)
                    }
                }
                let scriptMaterial = SceneScriptMaterial(path: address, properties: initial.keys.sorted().map { key in
                    SceneScriptMaterial.Property(name: key, path: address + "/constantshadervalues/" + key,
                        value: initial[key]!, authored: constants[key] ?? initial[key]!, user: users[key])
                })
                let textures = pass["textures"] as? [Any] ?? []
                guard textures.isEmpty || textures[0] is String || textures[0] is NSNull else { throw SceneError.invalid("模型主纹理名称无效。") }
                let (resource, _) = try texture(textures.first as? String ?? "util/white")
                let normal = combos["NATIVE_NORMALMAP"] == 1 && (chroma || combos["NATIVE_LIGHTING"] == 1 || combos["NATIVE_REFLECTION"] == 1)
                    ? try texture(textures[1] as! String) : nil
                let mapFlags = ["METALLIC_MAP", "ROUGHNESS_MAP", "REFLECTION_MAP", "EMISSIVE_MAP"].enumerated().reduce(UInt32(0)) {
                    $0 | (combos["NATIVE_" + $1.element] == 1 ? UInt32(1) << $1.offset : 0)
                }
                let mask = mapFlags != 0 ? try texture(textures[2] as! String).0 : nil
                let gradientName = textures.indices.contains(4) ? textures[4] as? String : nil
                let gradient = combos["NATIVE_LIGHTING"] == 1 && combos["NATIVE_SHADINGGRADIENT"] == 1
                    ? try texture(gradientName ?? "gradient/gradient_toon_smooth") : nil
                let noiseName = textures.indices.contains(8) ? textures[8] as? String : nil
                let noise = chroma && (combos["NATIVE_LIGHTING"] == 1 || mapFlags & 8 != 0)
                    ? try texture(noiseName ?? "util/noise").0 : nil
                // An unlit material never samples projection; stale paths or
                // engine aliases in its inactive slot are not dependencies.
                let projectionName = combos["NATIVE_LIGHTING"] == 1 && textures.indices.contains(7) ? textures[7] as? String : nil
                let projectionTexture = try projectionName.map { name -> String in
                    guard name != "_alias_lightCookie" else { throw SceneError.invalid("投影灯光资源别名尚未解析；当前需要材质纹理槽 7 显式指定资源。") }
                    return try texture(name).0
                }
                let front = initial["tintfront"] ?? [1,1,1], back = initial["tintback"] ?? [1,1,1]
                let specular = initial["speculartint"] ?? [1,1,1]
                return Material(texture: resource, blend: blend, normalTexture: normal?.0, maskTexture: mask, gradientTexture: gradient?.0,
                    chroma: chroma, noiseTexture: noise, projectionTexture: projectionTexture,
                    chromaFront: SIMD4(front[0],front[1],front[2],initial["tintwexponent"]?.first ?? 1.5),
                    chromaBack: SIMD4(back[0],back[1],back[2],initial["tintpigmentation"]?.first ?? 0.5),
                    chromaSpecular: SIMD4(specular[0],specular[1],specular[2],chroma ? 1 : 0),
                    normalFormat: normal?.1 ?? 0, mapFlags: mapFlags, gradientFormat: gradient?.1 ?? 0, rimLighting: combos["NATIVE_RIMLIGHTING"] == 1,
                    rimAmount: rimAmount, rimExponent: rimExponent,
                    tintMask: combos["NATIVE_TINTMASKALPHA"] == 1,
                    emissive: SIMD4(emissiveColor[0], emissiveColor[1], emissiveColor[2], emissiveBrightness), depth: try NativeMetalDepth(pass), cull: cull == "normal", visible: visible,
                    lighting: combos["NATIVE_LIGHTING"] == 1, fog: combos["NATIVE_FOG"] == 1, reflection: combos["NATIVE_REFLECTION"] == 1,
                    tint: SIMD4(color[0],color[1],color[2],alpha), roughness: roughness, metallic: metallic, brightness: brightness, reflectivity: reflectivity, scriptMaterial: scriptMaterial)
            }
            cache[mesh.materialPath] = prepared
            return prepared
        }
        return Resource(path: path, signature: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), model: model, materials: materials)
    }

    struct Uniforms {
        var model: simd_float4x4, viewProjection: simd_float4x4, normal: simd_float4x4
        var tint: SIMD4<Float>, parameters: SIMD4<Float>, eye: SIMD4<Float>
        var ambient: SIMD4<Float>, skylight: SIMD4<Float>, fogColor: SIMD4<Float>, fogParameters: SIMD4<Float>
        var reflection: SIMD4<Float>, shadowScale: SIMD4<Float>, emissive: SIMD4<Float>, stylization: SIMD4<Float>
        var chromaFront: SIMD4<Float>, chromaBack: SIMD4<Float>, chromaSpecular: SIMD4<Float>, chromaScreen: SIMD4<Float>
        var projectionRegion: SIMD4<Float>, projectionParameters: SIMD4<Float>
        var maps: SIMD4<UInt32>
        var flags: SIMD4<UInt32>, layout: SIMD4<UInt32>
    }
    @MainActor final class Runtime {
        struct Mesh { let vertices: MTLBuffer, indices: MTLBuffer; let count: Int, components: Int; let bounds: NativePointShadows.Bounds? }
        struct Geometry { let signature: String; let meshes: [Mesh]; let bones: MTLBuffer; let boneCount: Int }
        struct Instance {
            let path: String, signature: String
            let animation: NativeModelAnimation.Runtime
            var buffer: MTLBuffer?
            var revision: UInt64?
        }
        private let device: MTLDevice
        private var resources: [String: Geometry] = [:]
        private var instances: [Int: Instance] = [:]
        private(set) var scriptStore = NativeModelScriptStore()
        private(set) var scriptSignatures: [String: String] = [:]
        var animationSnapshots: [Int: [String: Any]] { instances.mapValues { $0.animation.snapshot } }
        var hasAnimations: Bool { instances.values.contains { !$0.animation.layers.isEmpty } }
        func usesRootMotion(_ index: Int) -> Bool { instances[index]?.animation.hasRootMotion == true }
        func retire(ids: Set<String>, retaining layers: [NativeMetalSceneSource.Layer]) {
            let slots = Set(layers.map(\.objectIndex)), paths = Set(layers.compactMap { $0.model?.path })
            instances = instances.filter { slots.contains($0.key) }
            resources = resources.filter { paths.contains($0.key) }
            scriptSignatures = scriptSignatures.filter { !ids.contains($0.key) }
            scriptStore.retire(ids)
            geometryBytes = resources.values.reduce(0) { $0 + $1.meshes.reduce(0) { $0 + $1.vertices.length + $1.indices.length } }
            meshCount = resources.values.reduce(0) { $0 + $1.meshes.count }
            boneCount = resources.values.reduce(0) { $0 + $1.boneCount }
        }
        private(set) var geometryBytes = 0, meshCount = 0, boneCount = 0
        private(set) var diagnostic = "Metal 模型：尚未编码。"
        init(device: MTLDevice, sources: [Resource], layers: [NativeMetalSceneSource.Layer] = []) throws {
            self.device = device
            for source in sources where resources[source.path] == nil {
                guard source.geometryBytes <= 128 * 1024 * 1024 - geometryBytes else { throw SceneError.invalid("Metal 模型几何超过 128 MiB。") }
                let meshes = try source.model.meshes.map { mesh -> Mesh in
                    let vertices = mesh.vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
                    let indices = mesh.indices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
                    guard let vertices, let indices else { throw SceneError.invalid("无法分配 Metal 模型网格。") }
                    return Mesh(vertices: vertices, indices: indices, count: mesh.indices.count, components: mesh.componentsPerVertex, bounds: NativePointShadows.Bounds(vertices: mesh.vertices, skeleton: source.model.skeleton))
                }
                let palette = source.model.skeleton?.defaultPalette ?? [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
                guard let bones = palette.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }) else {
                    throw SceneError.invalid("无法分配 Metal 默认骨矩阵。")
                }
                let count = source.model.skeleton?.bones.count ?? 0
                resources[source.path] = Geometry(signature: source.signature, meshes: meshes, bones: bones, boneCount: count)
                geometryBytes += source.geometryBytes; meshCount += meshes.count; boneCount += count
            }
            var totalLayers = 0
            for layer in layers {
                guard let source = layer.model else { continue }
                let id = layer.modelObjectID ?? String(layer.objectIndex)
                guard scriptSignatures[id] == nil else { throw SceneError.invalid("模型图层 ID 重复。") }
                scriptSignatures[id] = source.signature
                guard let animation = layer.modelAnimation else { scriptStore.staticModelIDs.insert(id); continue }
                guard instances.count < 256, totalLayers + animation.layers.count <= 2048 else {
                    throw SceneError.invalid("模型动画超过每场景 256 实例 / 2048 层预算。")
                }
                instances[layer.objectIndex] = Instance(path: source.path, signature: source.signature,
                    animation: NativeModelAnimation.Runtime(animation))
                scriptStore.players[id] = instances[layer.objectIndex]!.animation
                totalLayers += animation.layers.count
            }
        }
        func updateObject(instance: Int, time: Double, visible: Bool, paused: Bool, properties: [Int: [String: Any]],
                          state: inout [String: Any], parent: simd_float4x4, curveOverrides: Set<String>) throws {
            guard let value = instances[instance] else { return }
            let input = try value.animation.hasRootMotion ? NativeModelRootMotion.Input(object: state, parent: parent, curveOverrides: curveOverrides) : nil
            try update(instance: instance, time: time, visible: visible, paused: paused, properties: properties, motionInput: input)
            if let motion = value.animation.motion { state.merge(motion.properties) { _, next in next } }
        }
        func update(instance: Int, time: Double, visible: Bool, paused: Bool, properties: [Int: [String: Any]] = [:], motionInput: NativeModelRootMotion.Input? = nil) throws {
            guard var value = instances[instance] else { return }
            var samples: [String: [String: Any]] = [:]
            for (index, properties) in properties {
                guard value.animation.source.layers.indices.contains(index) else { throw SceneError.invalid("模型属性时间轴引用了未知动画层。") }
                let key = value.animation.source.layers[index].key
                if value.animation.layers.contains(where: { $0.key == key }) { samples[key] = properties }
            }
            try value.animation.update(time: time, visible: visible, paused: paused, samples: samples, motionInput: motionInput)
            if visible && (value.buffer == nil || value.revision != value.animation.revision) {
                // Immutable uploads: an earlier command can still be reading
                // its palette when the next scene frame is submitted.
                guard let buffer = value.animation.palette.withUnsafeBytes({
                    device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                }) else { throw SceneError.invalid("无法分配 Metal 动画骨矩阵。") }
                value.buffer = buffer; value.revision = value.animation.revision
            }
            instances[instance] = value
        }
        func bones(instance: Int, fallback: MTLBuffer) -> MTLBuffer { instances[instance]?.buffer ?? fallback }
        func geometry(for source: Resource) throws -> Geometry {
            guard let value = resources[source.path], value.signature == source.signature else { throw SceneError.invalid("Metal 模型几何与资源不匹配。") }
            return value
        }
        func preserveGeometry(from previous: Runtime) {
            for (name, current) in resources {
                if let old = previous.resources[name], old.signature == current.signature { resources[name] = old }
            }
            for (index, value) in instances {
                if let old = previous.instances[index], old.path == value.path, old.signature == value.signature {
                    value.animation.preserveClock(from: old.animation)
                }
            }
            let rebound = scriptStore.players
            let staticIDs = scriptStore.staticModelIDs
            scriptStore = previous.scriptStore
            scriptStore.players = rebound
            scriptStore.staticModelIDs = staticIDs
        }

        /// A candidate keeps a separate protocol store until publication, while
        /// surviving players and geometry retain their actual runtime identity.
        func preserveForInsertion(from previous: Runtime, slots: Set<Int>) {
            for (name, current) in resources {
                if let old = previous.resources[name], old.signature == current.signature { resources[name] = old }
            }
            for (index, value) in instances where slots.contains(index) {
                if let old = previous.instances[index], old.path == value.path, old.signature == value.signature {
                    instances[index] = old
                }
            }
            for id in scriptStore.players.keys {
                if let old = previous.scriptStore.players[id], scriptSignatures[id] == previous.scriptSignatures[id] {
                    scriptStore.players[id] = old
                }
            }
            scriptStore.inheritProtocol(from: previous.scriptStore)
        }
        func record(time: Double, instances: Int, draws: Int, lighting: NativeModelLightFrame, invalidNormals: Int) {
            let animated = self.instances.keys.sorted().map { key in
                let value = self.instances[key]!.animation
                return "对象 \(key)：\(value.layers.count) 层，时钟 \(value.states.map { String(format: "%.6f", $0.clock.time) }.joined(separator: ","))，推进 \(value.advances)，姿态 \(value.revision)"
            }.joined(separator: "; ")
            diagnostic = "Metal 模型运行快照：场景时间 \(String(format: "%.6f", time)) 秒；\(instances) 个可见实例，共享 \(resources.count) 份模型 / \(meshCount) 个网格，几何缓冲 \(geometryBytes) 字节；资源骨矩阵 \(boneCount) 个；\(draws) 次索引绘制，法线回退 \(invalidNormals)；直接灯光 \(lighting.lights.count)，拒绝 \(lighting.rejected)，距离雾=\(lighting.fogEnabled)，参数=\(lighting.fogParams)。独立骨骼动画实例 \(self.instances.count)：\(animated)。点光源阴影与体积光见独立快照。"
        }
    }

    static let shader = """
    struct ModelUniforms {
        float4x4 model, viewProjection, normal;
        float4 tint, parameters, eye, ambient, skylight, fogColor, fogParameters, reflection, shadowScale, emissive, stylization;
        float4 chromaFront, chromaBack, chromaSpecular, chromaScreen;
        float4 projectionRegion, projectionParameters;
        uint4 maps, flags, layout;
    };
    struct ModelVertex { float4 position [[position]]; float3 world, normal, tangent, bitangent; float2 uv; float3 clipPosition; };
    struct ModelLight { float4 positionRadius, colorExponent, shadow, spotDirection, spotParameters, shadowRight, shadowUp, shadowForward, projectionRight, projectionUp, projectionForward; };
    \(NativeProjectionSampling.metal)
    vertex ModelVertex modelVertex(uint id [[vertex_id]], constant ModelUniforms &u [[buffer(0)]],
        const device float *vertices [[buffer(1)]], const device float4x4 *bones [[buffer(2)]]) {
        uint offset = id * u.layout.x;
        float4 local = float4(vertices[offset],vertices[offset+1],vertices[offset+2],1);
        float3 normal = float3(vertices[offset+3],vertices[offset+4],vertices[offset+5]);
        float3 tangent = float3(vertices[offset+6],vertices[offset+7],vertices[offset+8]);
        if (u.layout.y > 0) {
            float4x4 skin = bones[uint(vertices[offset+10])] * vertices[offset+14]
                         + bones[uint(vertices[offset+11])] * vertices[offset+15]
                         + bones[uint(vertices[offset+12])] * vertices[offset+16]
                         + bones[uint(vertices[offset+13])] * vertices[offset+17];
            local = float4((skin * local).xyz,1);
            normal = float3x3(skin[0].xyz,skin[1].xyz,skin[2].xyz) * normal;
            tangent = float3x3(skin[0].xyz,skin[1].xyz,skin[2].xyz) * tangent;
        }
        float4 world = u.model * local, clip = u.viewProjection * world;
        clip.z = (clip.z + clip.w) * .5;
        uint uv = offset + u.layout.x - 2;
        float3 worldNormal=(u.normal*float4(normal,0)).xyz;
        if (u.maps.x != 0) worldNormal=length(worldNormal)>0.0000001 ? normalize(worldNormal) : float3(0,0,1);
        float3 worldTangent=(u.normal*float4(tangent,0)).xyz;
        float3 worldBitangent=(u.normal*float4(cross(normal,tangent)*vertices[offset+9],0)).xyz;
        return {clip,world.xyz,worldNormal,worldTangent,worldBitangent,float2(vertices[uv],vertices[uv+1]),clip.xyw};
    }
    float3 modelUnitMetal(float3 v, float3 fallback) { float n=length(v); return n>0.0000001 ? v/n : fallback; }
    float3 modelDirectMetal(float3 n,float3 v,float3 l,float3 radiance,float3 albedo,float metal,float rough,float shadow,
        bool pointLight,float lightEnergy,float3 specularTint,constant ModelUniforms &u,texture2d<float> gradientImage,sampler gradientSampler) {
        float3 h=modelUnitMetal(l+v,n);
        float nv=max(dot(n,v),0.0),dnl=dot(n,l),nh=max(dot(n,h),0.0),hv=clamp(dot(h,v),0.0,1.0);
        float a2=rough*rough*rough*rough,denominator=nh*nh*(a2-1.0)+1.0;
        float distribution=shadow*a2/max(M_PI_F*denominator*denominator,0.00000001);
        float k=(rough+1.0)*(rough+1.0)*.125;
        float2 cosines=max(float2(nv,dnl),float2(.001)),visibility=cosines/(cosines*(1.0-k)+k);
        float3 reflectance=mix(float3(.04),albedo,metal);
        float3 fresnel=reflectance+(1.0-reflectance)*pow(max(1.0-hv,.001),5.0);
        float3 nl=float3(max(dnl*shadow,0.0));
        if (u.maps.w != 0) {
            float coordinate=max(min(shadow,dnl)*.5+.5,0.0);
            float4 gradient=gradientImage.sample(gradientSampler,float2(coordinate,0));
            uint format=u.maps.w-1;
            nl=(format==8 || format==9) ? gradient.rrr : gradient.rgb;
        }
        float diffuseMetal=metal;
        if (u.stylization.z != 0) {
            // Guard the pow domain for non-unit tangent bases and invalid
            // nonpositive exponents, identically to the owned GL path.
            float rim=shadow*pow(max(1.0-nv,0.0),max(u.stylization.y,.000001))*u.stylization.x*nl.x*step(.001,lightEnergy);
            nl=max(nl,float3(rim));
            if (!pointLight) diffuseMetal-=clamp(rim,0.0,1.0);
        }
        float3 specular=distribution*visibility.x*visibility.y*fresnel/max(4.0*nv*nl,float3(.001));
        float3 diffuse=albedo*(1.0-diffuseMetal)*(1.0-fresnel)/M_PI_F;
        return radiance*(diffuse+specular*specularTint)*nl;
    }
    fragment float4 modelFragment(ModelVertex in [[stage_in]], constant ModelUniforms &u [[buffer(0)]],
        const device ModelLight *lights [[buffer(1)]], texture2d<float> image [[texture(0)]],
        texture2d<float> history [[texture(1)]], depth2d<float> shadowAtlas [[texture(2)]],
        texture2d<float> normalImage [[texture(3)]], texture2d<float> maskImage [[texture(4)]], texture2d<float> gradientImage [[texture(5)]], texture2d<float> noiseImage [[texture(6)]], texture2d<float> projectionImage [[texture(7)]],
        sampler sampleState [[sampler(0)]], sampler normalSampler [[sampler(1)]], sampler maskSampler [[sampler(2)]], sampler gradientSampler [[sampler(3)]], sampler noiseSampler [[sampler(4)]]) {
        // Evaluate the actual triangle plane before any nonuniform branches.
        float3 receiverNormal=cross(dfdx(in.world),dfdy(in.world));
        float4 texel=image.sample(sampleState,in.uv);
        float alpha=clamp((u.maps.z != 0 ? 1.0 : texel.a)*u.tint.a,0.0,1.0);
        if (u.layout.w != 0 && alpha<=0.0) discard_fragment();
        float3 base=u.maps.z != 0 ? mix(texel.rgb,max(texel.r,max(texel.g,texel.b))*u.tint.rgb,texel.a) : texel.rgb*u.tint.rgb;
        float3 geometricNormal=modelUnitMetal(in.normal,float3(0,0,1)),normal=geometricNormal;
        if (u.maps.x != 0) {
            float4 encoded=normalImage.sample(normalSampler,in.uv);
            uint format=u.maps.x-1;
            float2 xy=(format==8 ? encoded.rg : encoded.ag)*2.0-1.0;
            if ((format>=3 && format<=7) || format==12) xy.y+=.035;
            float3 localNormal=float3(xy,sqrt(clamp(1.0-dot(xy,xy),0.0,1.0)));
            normal=in.tangent*localNormal.x+in.bitangent*localNormal.y+in.normal*localNormal.z;
        }
        float4 masks=u.maps.y != 0 ? maskImage.sample(maskSampler,in.uv) : float4(1);
        float3 deltaEye=u.eye.xyz-in.world,view=modelUnitMetal(deltaEye,normal);
        float3 specularTint=float3(1);
        float pigment=0;
        if (u.chromaSpecular.w != 0) {
            float facing=dot(view,normal);
            if (u.maps.z != 0) {
                // Non-unit bases or back-facing normals can make pow undefined.
                // Keep this branch finite, like the existing native rim light.
                float blend=pow(max(facing,0.0),max(u.chromaFront.w,.000001));
                base*=mix(float3(1),mix(u.chromaBack.rgb,u.chromaFront.rgb,blend),texel.a);
                specularTint=mix(float3(1),u.chromaSpecular.rgb,texel.a);
            } else {
                base=texel.rgb*mix(u.chromaBack.rgb,u.chromaFront.rgb,facing);
                specularTint=u.chromaSpecular.rgb;
            }
            float2 noiseUV=(in.clipPosition.xy/in.clipPosition.z*.5+.5)*u.chromaScreen.xy;
            float3 noise=noiseImage.sample(noiseSampler,noiseUV).rgb*2.0-1.0;
            float reflected=dot(noise-2.0*dot(view,noise)*view,normal);
            float wave=abs(sin(9.0*length(deltaEye)*reflected));
            pigment=wave*wave*wave-.25;
        }
        float3 ambient=base,direct=float3(0);
        float roughness=clamp((u.maps.y & 2) != 0 ? masks.g : u.parameters.x,0.0,1.0);
        float rough=max(roughness,.02),metal=clamp((u.maps.y & 1) != 0 ? masks.r : u.parameters.y,0.0,1.0);
        if (u.flags.x != 0) {
            ambient=base*mix(u.skylight.rgb,u.ambient.rgb,clamp(geometricNormal.y*.5+.5,0.0,1.0));
            for (uint i=0;i<u.layout.z;i++) {
                float4 spatial=lights[i].positionRadius,energy=lights[i].colorExponent;
                float3 delta=spatial.w>0.0 ? spatial.xyz-in.world : spatial.xyz;
                float attenuation=1.0;
                if (spatial.w>0.0) {
                    float falloff=max(0.0,1.0-length(delta)/spatial.w);
                    attenuation=falloff>=.00006103515625 ? pow(falloff+.00006103515625,energy.w) : 0.0;
                }
                float cone=1.0;
                if (lights[i].spotParameters.y>0.0 && lights[i].spotParameters.z==0.0) {
                    float4 spot=lights[i].spotDirection;
                    float cosine=-dot(modelUnitMetal(delta,normal),spot.xyz);
                    float width=lights[i].spotParameters.x-spot.w;
                    float progress=width>0.0 ? clamp((cosine-spot.w)/width,0.0,1.0) : step(spot.w,cosine);
                    cone=progress*progress*(3.0-2.0*progress);
                }
                float shadow=lights[i].shadow.w>.5
                    ? spotVisibilityMetal(-delta,receiverNormal,lights[i].shadow,u.shadowScale,lights[i].shadowRight,lights[i].shadowUp,lights[i].shadowForward,shadowAtlas,u.stylization.w == 1.0)
                    : pointVisibilityMetal(-delta,lights[i].shadow,u.shadowScale,shadowAtlas,receiverNormal,u.stylization.w == 1.0);
                float3 projectedColor=float3(cone);
                if (lights[i].spotParameters.z>0.0) projectedColor=nativeProjectionColor(projectionImage,-delta,
                    lights[i].projectionRight,lights[i].projectionUp,lights[i].projectionForward,u.projectionRegion,u.projectionParameters.x>0.5);
                float3 lightColor=energy.rgb*projectedColor;
                direct+=modelDirectMetal(normal,view,modelUnitMetal(delta,normal),lightColor*attenuation,base,metal,rough,shadow,
                    spatial.w>0.0,lightColor.r+lightColor.g+lightColor.b,specularTint,u,gradientImage,gradientSampler);
            }
        }
        if ((u.maps.y & 8) != 0) direct=max(direct,u.emissive.rgb*base*(masks.a*u.emissive.a));
        if (u.chromaSpecular.w != 0) direct+=float3(pigment*u.chromaBack.w*dot(direct,float3(.299,.587,.114)));
        float3 color=ambient+direct;
        if (u.flags.z != 0) {
            float size=length(direct);
            color=clamp(color,0.0,1.0)+direct*(clamp(size-2.0,0.0,1.0)*.5/max(.01,size));
        }
        // Keep the authored flag for normal/emissive material semantics.
        // parameters.w suppresses only global reflection sampling.
        if (u.reflection.x != 0 && u.parameters.w == 0) {
            float facing=clamp(abs(dot(normal,view)),0.0,1.0);
            float3 projectedNormal=modelUnitMetal(float3x3(u.viewProjection[0].xyz,u.viewProjection[1].xyz,u.viewProjection[2].xyz)*normal,float3(0,0,1));
            float2 reflectedUV=in.clipPosition.xy/in.clipPosition.z*.5+.5;
            reflectedUV+=projectedNormal.xy*float2(.15,.15*u.reflection.w)*pow(facing,4.0)*10.0;
            float2 edgeFade=(1.0-smoothstep(float2(1.0),float2(1.3),reflectedUV))*smoothstep(float2(-.3),float2(0.0),reflectedUV);
            // The authored projection uses bottom-up Y; Metal histories are top-down.
            reflectedUV.y=1.0-reflectedUV.y;
            constexpr sampler historySampler(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
            float3 reflected=history.sample(historySampler,reflectedUV,level(roughness*u.reflection.z)).rgb;
            reflected*=edgeFade.x*edgeFade.y*(1.0-facing)*clamp(u.reflection.y,0.0,1.0)*((u.maps.y & 4) != 0 ? masks.b : 1.0);
            color+=clamp(pow(max(float3(.001),reflected),float3(2.0-metal)),0.0,1.0);
        }
        if (u.flags.z != 0) {
            color*=u.parameters.z;
            if ((u.flags.x != 0 || u.reflection.x != 0) && (u.maps.y & 8) != 0)
                color+=u.emissive.rgb*color*max(0.0,masks.a*(u.emissive.a-1.0));
        }
        if (u.flags.y != 0 && u.flags.w != 0) {
            float fraction=clamp((length(deltaEye)-u.fogParameters.x)/u.fogParameters.y,0.0,1.0);
            float fog=clamp(u.fogParameters.z+u.fogParameters.w*fraction*fraction,0.0,1.0);
            color=mix(color,u.fogColor.rgb,fog);
        }
        return float4(color,alpha);
    }
    """
}
