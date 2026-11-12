import Foundation
import Metal
import simd

/// Ordinary particle documents feed the existing CPU simulator. Only GPU
/// submission changes; birth journals, world transforms and children stay shared.
struct NativeMetalParticles {
    struct Material {
        let texture: String, blend: String
        let overbright: Float
        let cutout: SIMD4<Float>
        let depth: NativeMetalDepth
    }
    struct Child {
        let system: SceneParticleChildren
        let material: Material
    }
    let system: SceneParticles
    let children: [Child]
    let material: Material
    let instance: [String: Any]
    let signature: Data
    let warnings: [String]
    var reservedParticles: Int { system.maximumParticles + children.reduce(0) { $0 + $1.system.reservedParticles } }
    var reservedInstances: Int { children.reduce(0) { $0 + $1.system.maximumInstances } }

    static func load(object: [String: Any], assets: SceneAssets, values: [String: Any], orthographic: Bool = true,
                     resolve: (Any) throws -> Any,
                     texture: (String) throws -> (String, NativeMetalSceneSource.Texture)) throws -> Self {
        func reject(_ message: String) -> SceneError { .invalid("Metal 粒子：" + message) }
        func keys(_ object: [String: Any], _ allowed: Set<String>, _ label: String) throws {
            let extra = Set(object.keys).subtracting(allowed).sorted()
            guard extra.isEmpty else { throw reject("\(label) 含未迁移字段 \(extra.prefix(4).joined(separator: "、"))。") }
        }
        guard let path = object["particle"] as? String else { throw reject("缺少文档路径。") }
        let document = try assets.json(path)
        let instance = object["instanceoverride"] as? [String: Any] ?? [:]
        try keys(instance, ["count", "size", "alpha", "colorn", "lifetime", "speed", "rate", "controlpoint0", "controlpoint1", "controlpoint2", "controlpoint3"], "实例")
        let system = try SceneParticles(document: document, instance: instance, orthographic: orthographic)
        let flags = (document["flags"] as? NSNumber)?.intValue ?? 0
        guard flags & ~7 == 0 else { throw reject("未知系统 flags 不进入此后端。") }
        var signatures: [String: Any] = ["document": document, "orthographic": orthographic,
            "instance": instance.filter { !SceneParticles.liveInstanceKeys.contains($0.key) }]
        func material(_ path: String) throws -> (Material, NativeMetalSceneSource.Texture) {
            let raw = try assets.json(path)
            try keys(raw, ["passes"], "材质")
            guard let passes = raw["passes"] as? [[String: Any]], passes.count == 1,
                  let pass = try resolve(passes[0]) as? [String: Any] else { throw reject("仅支持单阶段粒子材质。") }
            try keys(pass, ["shader", "textures", "combos", "blending", "cullmode", "depthtest", "depthwrite", "constantshadervalues", "usershadervalues", "visible"], "材质阶段")
            guard pass["shader"] as? String == "genericparticle",
                  !assets.contains("shaders/genericparticle.vert"), !assets.contains("shaders/genericparticle.frag") else { throw reject("作者粒子着色器尚未迁移。") }
            var combos: [String: Int] = [:]
            for (key, value) in pass["combos"] as? [String: Any] ?? [:] {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let integer = Int(exactly: number.doubleValue) else { throw reject("材质组合必须为整数。") }
                let name = key.uppercased()
                guard combos[name] == nil || combos[name] == integer else { throw reject("材质组合大小写冲突。") }
                combos[name] = integer
                let allowed = ["SPRITESHEET", "SPRITESHEETBLEND", "CUTOUT", "FOG"].contains(name) ? [0, 1] : [0]
                guard allowed.contains(integer) else { throw reject("材质组合 \(name) 尚未迁移。") }
            }
            let blend = pass["blending"] as? String ?? "normal"
            guard ["normal", "translucent", "additive"].contains(blend),
                  pass["cullmode"] == nil || pass["cullmode"] as? String == "nocull",
                  pass["visible"] == nil || pass["visible"] as? Bool == true else { throw reject("剔除、可见性或混合状态尚未迁移。") }
            let depth = try NativeMetalDepth(pass)
            let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
            let bindings = pass["usershadervalues"] as? [String: Any] ?? [:]
            let names: Set<String> = ["ui_editor_properties_overbright", "ui_editor_properties_cutout_start", "ui_editor_properties_cutout_end", "ui_editor_properties_cutout_opacity"]
            try keys(constants, names, "常量"); try keys(bindings, names, "用户参数")
            func parameter(_ key: String, _ fallback: Float) throws -> Float {
                var raw = constants[key]
                if let user = bindings[key] as? String { raw = (values[user] as? [String: Any])?["value"] ?? raw }
                let value = SceneValues.number(raw, fallback)
                guard value.isFinite, abs(value) <= 16384 else { throw reject("材质参数超出有限范围。") }
                return value
            }
            let overbright = try parameter("ui_editor_properties_overbright", 1)
            let start = try parameter("ui_editor_properties_cutout_start", 0.1)
            let end = try parameter("ui_editor_properties_cutout_end", 0.2)
            let opacity = try parameter("ui_editor_properties_cutout_opacity", 1)
            let cutout = combos["CUTOUT"] == 1
            guard !cutout || (start < end && (0...1).contains(start) && (0...1).contains(end) && (0...1).contains(opacity)) else { throw reject("Cutout 区间无效。") }
            let namesList = pass["textures"] as? [String] ?? ["util/white"]
            guard namesList.count == 1 else { throw reject("多纹理粒子材质尚未迁移。") }
            let (key, image) = try texture(namesList[0])
            // Texture geometry affects CPU sequence UVs; color and blend do not.
            signatures[path] = ["texture": key, "width": image.width, "height": image.height,
                "imageWidth": image.imageWidth, "imageHeight": image.imageHeight,
                "frames": image.animation?.frames.count ?? 0,
                "frameWidth": image.animation?.width ?? 0, "frameHeight": image.animation?.height ?? 0]
            return (Material(texture: key, blend: blend, overbright: overbright,
                cutout: SIMD4(start, end, opacity, cutout ? 1 : 0), depth: depth), image)
        }
        let (rootMaterial, rootTexture) = try material(system.materialPath)
        try system.configureTexture(rootTexture.animation, width: rootTexture.width, height: rootTexture.height,
            imageWidth: rootTexture.imageWidth, imageHeight: rootTexture.imageHeight)
        var children: [Child] = [], warnings = system.warnings
        if let raw = document["children"], !(raw is NSNull) {
            guard let declarations = raw as? [[String: Any]], declarations.count <= 16 else { throw reject("子系统列表超过 16 项或无效。") }
            var particles = 0, instances = 0
            for (index, declaration) in declarations.enumerated() {
                guard let childPath = declaration["name"] as? String else { throw reject("子系统缺少路径。") }
                let childDocument = try assets.json(childPath)
                signatures["child-\(index)"] = childDocument
                let child = try SceneParticleChildren(parent: system, declaration: declaration, document: childDocument,
                    instance: instance, declarationIndex: index)
                particles += child.reservedParticles; instances += child.maximumInstances
                guard particles <= 4096, instances <= 512 else { throw reject("每个父系统最多预留 4096 个子粒子、512 个实例。") }
                let (pass, image) = try material(child.materialPath)
                try child.configureTexture(image.animation, width: image.width, height: image.height,
                    imageWidth: image.imageWidth, imageHeight: image.imageHeight)
                if child.requiresEmitterHistory { system.enableEmitterTransformHistory() }
                child.activate(); children.append(Child(system: child, material: pass))
                warnings += child.warnings
            }
        }
        if system.usesWorldSpace { system.enableEmitterTransformHistory() }
        return Self(system: system, children: children, material: rootMaterial, instance: instance,
            signature: try JSONSerialization.data(withJSONObject: signatures, options: [.sortedKeys]), warnings: warnings)
    }

    @MainActor
    final class Runtime {
        struct Mesh { let buffer: MTLBuffer?; let count: Int; var bytes: Int { count * 12 * MemoryLayout<Float>.size } }
        let source: NativeMetalParticles
        private(set) var system: SceneParticles
        private(set) var children: [SceneParticleChildren]
        private(set) var meshes: [Mesh] = []
        private var revision = 0
        private var sampledTime = -1.0
        private var inherited = false
        init(_ source: NativeMetalParticles) {
            self.source = source; system = source.system; children = source.children.map(\.system)
        }
        func preserve(from previous: Runtime) {
            guard source.signature == previous.source.signature else { return }
            system = previous.system; children = previous.children; meshes = previous.meshes
            revision = previous.revision; sampledTime = previous.sampledTime; inherited = true
        }
        var needsFrameUpdates: Bool {
            sampledTime < 0 || system.eventPoolIsActive || children.contains { $0.needsFrameUpdates }
        }
        var pointerSnapshot: [String: Any] {
            system.pointerSnapshot.merging(["geometryRevision": revision, "sampledTime": sampledTime,
                "inherited": inherited]) { _, next in next }
        }
        var diagnostics: [String] {
            ["Metal 粒子几何：代次 \(revision)，采样时间 \(String(format: "%.6f", sampledTime)) 秒，\(meshes.reduce(0) { $0 + $1.count / 6 }) 个四边形，\(meshes.reduce(0) { $0 + $1.bytes }) 字节；属性提交继承=\(inherited)。", system.runtimeDiagnostic,
             "Metal 粒子空间：\(system.usesWorldSpace ? "世界" : "局部")；世界出生 \(system.worldBirths)，空间失败=\(system.spaceFailure ?? "无")；透视=\(system.usesPerspectiveProjection)，待模拟=\(needsFrameUpdates)。"] + (system.hasPointerForces ? [system.pointerDiagnostic] : []) + children.compactMap(\.runtimeDiagnostic)
        }
        func update(device: MTLDevice, time: Double, paused: Bool, model: simd_float4x4,
                    right: SIMD3<Float>, up: SIMD3<Float>, remainingBytes: inout Int,
                    pointer: SceneParticlePointerInput = .init(position: nil, reason: "input-not-provided")) throws {
            // Resize/expose and paused property commits must not consume queued
            // births or physics backlog. Parameters take effect on resume.
            if paused && sampledTime >= 0 {
                let bytes = meshes.reduce(0) { $0 + $1.bytes }
                guard bytes <= remainingBytes else { throw SceneError.invalid("Metal 粒子几何超过每帧 64 MiB。") }
                remainingBytes -= bytes; return
            }
            let overrides = try SceneParticles.LiveOverrides(source.instance)
            try system.applyLiveOverrides(overrides)
            for child in children { try child.applyLiveOverrides(overrides) }
            func upload(_ vertices: [Float]) throws -> Mesh {
                let bytes = vertices.count * MemoryLayout<Float>.size
                guard vertices.count % 72 == 0, bytes <= remainingBytes, vertices.allSatisfy(\.isFinite) else {
                    throw SceneError.invalid("Metal 粒子网格无效或超过每帧 64 MiB。")
                }
                remainingBytes -= bytes
                guard bytes > 0 else { return Mesh(buffer: nil, count: 0) }
                let buffer = vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared) }
                guard let buffer else { throw SceneError.invalid("无法分配 Metal 粒子顶点。") }
                buffer.label = "Immutable native particle frame"
                return Mesh(buffer: buffer, count: vertices.count / 12)
            }
            var next = [try upload(system.vertices(at: time, cameraRight: right, cameraUp: up,
                pointer: pointer, capturePointer: !paused, authoredModel: model))]
            for child in children {
                next.append(try upload(child.vertices(at: time, cameraRight: right, cameraUp: up,
                    drawModel: model * child.drawLocalTransform)))
            }
            meshes = next; revision += 1; sampledTime = time
            if let report = system.observation(at: time) { fputs("Metal particle runtime: \(report)\n", stderr) }
            for child in children {
                if let report = child.observation(at: time) { fputs("Metal child particle runtime: \(report)\n", stderr) }
            }
        }
    }

    struct Uniforms { var transform: simd_float4x4; var appearance: SIMD4<Float>; var cutout: SIMD4<Float> }
    static let shader = """
    struct ParticleUniforms { float4x4 transform; float4 appearance; float4 cutout; };
    struct ParticleOut { float4 position [[position]]; float2 uv; float4 color; float2 nextUV; float blend; };
    vertex ParticleOut particleVertex(uint id [[vertex_id]], constant ParticleUniforms &u [[buffer(0)]], device const float *vertices [[buffer(1)]]) {
        device const float *v = vertices + id * 12;
        float4 clip = u.transform * float4(v[0], v[1], v[2], 1);
        clip.z = (clip.z + clip.w) * .5;
        return {clip, float2(v[3], v[4]), float4(v[5], v[6], v[7], v[8]), float2(v[9], v[10]), v[11]};
    }
    float4 particleSample(texture2d<float> image, sampler s, float2 uv, float channels) {
        float4 value = image.sample(s, uv);
        if (channels < 1.5) return float4(1, 1, 1, value.r);
        if (channels < 2.5) return float4(value.rrr, value.g);
        return value;
    }
    fragment float4 particleFragment(ParticleOut in [[stage_in]], constant ParticleUniforms &u [[buffer(0)]], texture2d<float> image [[texture(0)]], sampler s [[sampler(0)]]) {
        float4 value = particleSample(image, s, in.uv, u.appearance.x);
        if (in.blend > 0) {
            float4 other = particleSample(image, s, in.nextUV, u.appearance.x);
            value = mix(value, other, in.blend);
        }
        value *= in.color;
        value.rgb *= u.appearance.y;
        if (u.cutout.w > .5) value.a = smoothstep(u.cutout.x, u.cutout.y, value.a) * u.cutout.z;
        value.a = clamp(value.a, 0.0, 1.0);
        if (u.appearance.z > .5 && value.a <= 0) discard_fragment();
        return value;
    }
    """
}
