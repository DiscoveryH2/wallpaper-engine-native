import Foundation
import CryptoKit
import simd

/// Image-local operations. The graph describes routing independently of the
/// Metal implementation, so named buffers and `previous` keep their authored
/// meaning across effects. No author GLSL is silently replaced by its filename.
struct NativeMetalSceneEffects {
    enum Operation: UInt32 {
        case precise, gaussian, downsample, combine, opacity, opacityOptionalMask, opacityMaskOnly
        case motionBlurAccumulation, motionBlurCombine, copy
    }
    /// `graph` is an image-local named FBO.  A Scene layer export is kept as a
    /// distinct input namespace so an authored name cannot accidentally bind a
    /// same-named transient effect target.
    enum Input { case current, graph(String), texture(String), layerComposite(String) }
    struct Parameter {
        let value: [Float]
        let bindingPath: String?

        func sampled(_ values: [String: [Float]]) throws -> [Float] {
            guard let bindingPath else { return value }
            guard let sample = values[bindingPath], sample.count == value.count,
                  sample.allSatisfy({ $0.isFinite && abs($0) <= 16384 }) else {
                throw SceneError.invalid("\(bindingPath)：效果参数采样缺失或越界，停止绘制。")
            }
            return sample
        }
    }
    struct Pass {
        let operation: Operation
        let target: String?
        let inputs: [Int: Input]
        let copySource: String?
        let kernel: Int, vertical: Bool, mask: Bool, blurAlpha: Bool
        let scale: Parameter, color: Parameter, alpha: Parameter, amount: Parameter
        let material: SceneScriptMaterial?
    }
    struct Group {
        let name: String
        let visibilityPath: String
        let enabled: Bool
        let targets: [String: SceneEffectTargetSpec]
        let historyTargets: Set<String>
        let passes: [Pass]
        let materials: [SceneScriptMaterial]
    }
    let groups: [Group]
    var active: [Group] { groups.filter(\.enabled) }
    var passCount: Int { active.reduce(0) { $0 + $1.passes.count } }

    static func load(_ raw: Any?, assets: SceneAssets, values: [String: Any], hdr: Bool,
                     prefix: String, parameterPaths: Set<String>, authored rawAuthored: Any? = nil, dynamic: Bool = false,
                     resolve: (Any) throws -> Any, texture: (String) throws -> String) throws -> Self {
        guard let raw else { return Self(groups: []) }
        guard let effects = raw as? [[String: Any]], effects.count <= 64 else { throw invalid("图片效果列表无效或超过 64 个。") }
        let authoredEffects = rawAuthored as? [[String: Any]] ?? effects
        var groups: [Group] = [], count = 0
        for (index, effect) in effects.enumerated() {
            try keys(effect, ["id", "name", "file", "visible", "passes"], "图片效果")
            guard let path = effect["file"] as? String else { throw invalid("图片效果缺少文件路径。") }
            let document = try assets.json(path)
            try keys(document, ["version", "name", "description", "group", "performance", "preview", "replacementkey", "dependencies", "passes", "fbos"], path)
            let graph = try SceneEffectGraph(document: document, namespace: String(index), hdr: hdr)
            for fbo in document["fbos"] as? [[String: Any]] ?? [] {
                try keys(fbo, ["name", "scale", "format", "unique"], "效果缓冲")
            }
            let authored = document["passes"] as! [[String: Any]]
            guard effect["passes"] == nil || effect["passes"] is [[String: Any]] else { throw invalid("效果 pass 覆盖无效。") }
            let overrides = effect["passes"] as? [[String: Any]] ?? []
            guard overrides.count <= authored.count else { throw invalid("效果覆盖超过声明的 pass 数量。") }
            let originalOverrides = (authoredEffects.indices.contains(index) ? authoredEffects[index]["passes"] : nil) as? [[String: Any]] ?? []
            var passes: [Pass] = []
            for (passIndex, entry) in authored.enumerated() {
                let wiring = graph.passes[passIndex]
                if case let .copy(source) = wiring.command {
                    try keys(entry, ["command", "target", "source"], "效果 copy command")
                    guard let target = wiring.target else { throw invalid("效果 copy 缺少 target。") }
                    let one = Parameter(value: [1], bindingPath: nil)
                    passes.append(Pass(operation: .copy, target: target, inputs: [:], copySource: source,
                                       kernel: 0, vertical: false, mask: false, blurAlpha: true,
                                       scale: Parameter(value: [1, 1], bindingPath: nil), color: Parameter(value: [1, 1, 1], bindingPath: nil),
                                       alpha: one, amount: one, material: nil))
                    continue
                }
                try keys(entry, ["material", "target", "bind"], "效果 pass")
                guard let materialPath = entry["material"] as? String else { throw invalid("效果 pass 缺少材质。") }
                let material = try assets.json(materialPath)
                try keys(material, ["passes"], "效果材质")
                guard let definitions = material["passes"] as? [[String: Any]], !definitions.isEmpty, definitions.count <= 32 else { throw invalid("效果材质 pass 列表无效。") }
                guard definitions.count == 1 || (graph.targets.isEmpty && wiring.bindings.isEmpty) else { throw invalid("带命名缓冲的效果阶段需要单个材质 pass。") }
                for definition in definitions {
                    var original = definition
                    for (key, value) in originalOverrides.indices.contains(passIndex) ? originalOverrides[passIndex] : [:] {
                        if let next = value as? [String: Any], let previous = original[key] as? [String: Any] {
                            original[key] = previous.merging(next) { _, new in new }
                        } else { original[key] = value }
                    }
                    var merged = definition
                    for (key, value) in overrides.indices.contains(passIndex) ? overrides[passIndex] : [:] {
                        if let next = value as? [String: Any], let previous = merged[key] as? [String: Any] {
                            merged[key] = previous.merging(next) { _, new in new }
                        } else { merged[key] = value }
                    }
                    guard let resolved = try resolve(merged) as? [String: Any] else { throw invalid("效果属性无效。") }
                    passes.append(try makePass(resolved, wiring: wiring, assets: assets, values: values,
                        prefix: prefix + "/\(index)/passes/\(passIndex)/constantshadervalues", parameterPaths: parameterPaths, authored: original, dynamic: dynamic, texture: texture))
                }
            }
            count += passes.count
            guard count <= 128 else { throw invalid("单个图层的效果超过 128 个阶段。") }
            groups.append(Group(name: path, visibilityPath: prefix + "/\(index)/visible", enabled: SceneValues.visible(effect["visible"]), targets: graph.targets,
                                historyTargets: graph.historyTargets, passes: passes,
                                materials: try SceneScriptMaterial.merge(passes.compactMap(\.material))))
        }
        return Self(groups: groups)
    }

    private static func makePass(_ pass: [String: Any], wiring: SceneEffectGraph.Pass,
                                 assets: SceneAssets, values: [String: Any], prefix: String,
                                 parameterPaths: Set<String>, authored: [String: Any], dynamic: Bool, texture: (String) throws -> String) throws -> Pass {
        try keys(pass, ["id", "shader", "textures", "combos", "blending", "cullmode", "depthtest", "depthwrite", "constantshadervalues", "usershadervalues", "visible"], "效果材质 pass")
        guard let shader = pass["shader"] as? String else { throw invalid("效果缺少着色器。") }
        let operation = try operation(shader: shader, assets: assets)
        guard pass["visible"] == nil || pass["visible"] as? Bool == true else { throw invalid("效果内部的材质可见性分支尚未迁移。") }
        guard pass["blending"] == nil || pass["blending"] as? String == "normal",
              pass["cullmode"] == nil || pass["cullmode"] as? String == "nocull",
              pass["depthtest"] == nil || pass["depthtest"] as? String == "disabled",
              pass["depthwrite"] == nil || pass["depthwrite"] as? String == "disabled" else { throw invalid("效果材质需要普通、不剔除、无深度的离屏状态。") }
        guard pass["combos"] == nil || pass["combos"] is [String: Any],
              pass["textures"] == nil || pass["textures"] is [Any] else { throw invalid("效果组合或纹理列表无效。") }
        let allowed: Set<String>
        switch operation {
        case .precise: allowed = ["KERNEL", "VERTICAL", "ENABLEMASK", "MASK", "BLURALPHA"]
        case .gaussian: allowed = ["KERNEL", "VERTICAL"]
        case .motionBlurAccumulation: allowed = ["MASK"]
        case .downsample, .opacity, .opacityMaskOnly, .motionBlurCombine, .copy: allowed = []
        case .opacityOptionalMask: allowed = ["MASK"]
        case .combine: allowed = ["MASK", "BLURALPHA", "COMPOSITE", "COMPOSITEMONO", "BLENDMODE"]
        }
        var combos: [String: Int] = [:]
        for (key, raw) in pass["combos"] as? [String: Any] ?? [:] {
            guard allowed.contains(key), let number = raw as? NSNumber, let value = Int(exactly: number.doubleValue),
                  key == "KERNEL" ? (0...2).contains(value) : (["COMPOSITE", "COMPOSITEMONO", "BLENDMODE"].contains(key) ? value == 0 : (0...1).contains(value)) else { throw invalid("效果组合 \(key) 尚未迁移。") }
            combos[key] = value
        }
        let declared = pass["textures"] as? [Any] ?? []
        guard declared.count <= 8, declared.allSatisfy({ $0 is String || $0 is NSNull }) else { throw invalid("效果纹理槽位无效。") }
        let maskSlot = (operation == .precise || operation == .motionBlurAccumulation) ? 2 : 1
        let hasMask = declared.indices.contains(maskSlot) && (declared[maskSlot] as? String).map { !$0.isEmpty } == true
        let masked = operation == .opacity || operation == .opacityMaskOnly
            || ((operation == .precise || operation == .combine || operation == .opacityOptionalMask || operation == .motionBlurAccumulation) && (combos["MASK"] ?? (hasMask ? 1 : 0)) == 1)
        let blurAlpha = (combos["BLURALPHA"] ?? 1) != 0
        var used: Set<Int> = [0]
        if operation == .precise && (masked || !blurAlpha) { used.insert(1) }
        if operation == .motionBlurAccumulation { used.insert(1) }
        if operation == .combine { used.insert(2) }
        if masked { used.insert(maskSlot) }
        guard Set(wiring.bindings.keys).isSubset(of: [0, 1, 2]) else { throw invalid("此效果的缓冲绑定槽位尚未迁移。") }
        var inputs: [Int: Input] = [:]
        for slot in used {
            if let name = wiring.bindings[slot] { inputs[slot] = .graph(name); continue }
            if declared.indices.contains(slot), let name = declared[slot] as? String, !name.isEmpty {
                if name == "_rt_FullFrameBuffer" { inputs[slot] = .current }
                else if let id = NativeMetalSceneLayerGraph.compositeID(name) { inputs[slot] = .layerComposite(id) }
                else if NativeMetalSceneLayerGraph.isRenderTargetAlias(name) {
                    throw invalid("效果渲染目标 \(name) 尚未迁移。")
                }
                else { inputs[slot] = .texture(try texture(name)) }
            } else if slot == 0 { inputs[slot] = .current }
            else { inputs[slot] = .texture(try texture("util/white")) }
        }
        guard pass["constantshadervalues"] == nil || pass["constantshadervalues"] is [String: Any],
              pass["usershadervalues"] == nil || pass["usershadervalues"] is [String: Any] else { throw invalid("效果常量或属性绑定无效。") }
        let constants = pass["constantshadervalues"] as? [String: Any] ?? [:]
        let users = pass["usershadervalues"] as? [String: Any] ?? [:]
        let parameters: Set<String>
        switch operation {
        case .combine: parameters = ["compositecolor"]
        case .opacity, .opacityOptionalMask: parameters = ["alpha"]
        // All three labels occur in shipped Motion Blur variants. They map to
        // the same g_Amount uniform; accept at most one below.
        case .motionBlurAccumulation: parameters = ["Accumulation rate", "rate", "g_Amount"]
        case .downsample, .opacityMaskOnly, .motionBlurCombine, .copy: parameters = []
        case .precise, .gaussian: parameters = ["scale"]
        }
        try keys(constants, parameters, "效果常量"); try keys(users, parameters, "效果属性")
        func parameter(_ key: String, fallback: [Float]) throws -> Parameter {
            var raw = constants[key]
            if let user = users[key] {
                guard let name = user as? String else { throw invalid("效果属性绑定需要属性名称。") }
                raw = (values[name] as? [String: Any])?["value"] ?? raw
            }
            let components = raw.map { SceneValues.floats($0) } ?? fallback
            guard components.count == fallback.count, components.allSatisfy({ $0.isFinite && abs($0) <= 16384 }) else { throw invalid("效果参数 \(key) 的维数或范围无效。") }
            let path = prefix + "/" + key
            return Parameter(value: components, bindingPath: parameters.contains(key) && (dynamic || parameterPaths.contains(path)) ? path : nil)
        }
        let scale = try parameter("scale", fallback: [1, 1]), color = try parameter("compositecolor", fallback: [1, 1, 1])
        let alpha = try parameter("alpha", fallback: [1])
        let amountNames = ["Accumulation rate", "rate", "g_Amount"].filter { constants[$0] != nil || users[$0] != nil }
        guard amountNames.count <= 1 else { throw invalid("Motion Blur 的 g_Amount 不能同时使用多个别名。") }
        let amount = try parameter(amountNames.first ?? "Accumulation rate", fallback: [0.8])
        if operation == .motionBlurAccumulation {
            guard amount.value.count == 1, (0.01...1).contains(amount.value[0]) else {
                throw invalid("Motion Blur Accumulation rate 必须在 0.01…1。")
            }
        }
        let originalConstants = authored["constantshadervalues"] as? [String: Any] ?? [:]
        let originalUsers = authored["usershadervalues"] as? [String: Any] ?? [:]
        let propertyNames = operation == .motionBlurAccumulation ? [amountNames.first ?? "Accumulation rate"] : parameters.sorted()
        let properties = propertyNames.map { key in
            SceneScriptMaterial.Property(name: key, path: prefix + "/" + key,
                value: key == "scale" ? scale.value : (key == "alpha" ? alpha.value : (key == "compositecolor" ? color.value : amount.value)),
                authored: originalConstants[key], user: originalUsers[key])
        }
        let material = SceneScriptMaterial(path: String(prefix.dropLast("/constantshadervalues".count)), properties: properties)
        return Pass(operation: operation, target: wiring.target, inputs: inputs, copySource: nil, kernel: combos["KERNEL"] ?? 0,
                    vertical: combos["VERTICAL"] == 1, mask: masked, blurAlpha: blurAlpha,
                    scale: scale, color: color, alpha: alpha, amount: amount, material: material)
    }

    /// Fingerprints identify inspected shader interfaces across Workshop paths.
    /// Changed author code remains on the existing shader backend. Original
    /// reference code is development data and is not linked or bundled here.
    private static func operation(shader: String, assets: SceneAssets) throws -> Operation {
        let vertex = "shaders/\(shader).vert", fragment = "shaders/\(shader).frag"
        let builtins: [String: Operation] = ["effects/blur_precise_gaussian": .precise, "effects/blur_gaussian": .gaussian,
                                           "effects/blur_downsample4": .downsample, "effects/blur_combine": .combine,
                                           "effects/opacity": .opacityOptionalMask]
        if !assets.contains(vertex), !assets.contains(fragment), let operation = builtins[shader] { return operation }
        guard assets.contains(vertex), assets.contains(fragment) else { throw invalid("效果着色器未完整提供：\(shader)。") }
        func digest(_ path: String) throws -> String {
            SHA256.hash(data: try assets.data(path, maximumBytes: 1_048_576)).map { String(format: "%02x", $0) }.joined()
        }
        let v = try digest(vertex), f = try digest(fragment)
        let references: [(Operation, Set<String>, String)] = [
            (.precise, ["4900e7a84bc5c1dc6e9d3b95a1c1862638a3ced4408a9bd17962be55149a10ec", "177057a90b5de94011ad967b36d25a2a51072b06638498a7ce99a9758e45ba0a"], "7d613ded8d61b1ca68b109d84a8f7f68d2901c65268af7e0ea7628adeb07b16f"),
            (.gaussian, ["514f192a941cfb2aa0fa1e2e7f8b7a04405f5169e557d10293ed4e3d4f326144"], "bb847f608de8c34b6c400c8e54da9db33e5438a47ad837ba762390e9eae9f9b6"),
            (.downsample, ["522620fd19ca833762e965696c0c55e3136bae5442cec70227d5b32b32955747"], "247c303a1925db1babae53f721710537338fe53810e94c38d1457444878f54f9"),
            (.combine, ["208d5f52d8ad1d5bac439ad1c653e75fc9dc062ac6bb7f8ff87c1d18827c5dad"], "f0ba8bf7a60aad077fa4f6538c66ea1e258d1470819cc7bd57c4416bf5c13298"),
            (.opacity, ["45803f340c80659ca4726cdea107eb017e7638a64a1b9ff7d30093d1938a738e"], "819d8eff141d95eeafeaa47b70004a2b5e1ac6c470a7f9bf35bfa17cb22c62e3"),
            (.opacityOptionalMask, ["45803f340c80659ca4726cdea107eb017e7638a64a1b9ff7d30093d1938a738e"], "418d565af5509983802c17d1ed901b24b02a6aa8183396cc511ff5f5eefbeb47"),
            (.opacityMaskOnly, ["45803f340c80659ca4726cdea107eb017e7638a64a1b9ff7d30093d1938a738e"], "0f64c837715d5565bbd19df1481289d69d48fa7a49ee719516a62160a53c0d45"),
            // The Windows 26168761 resources ship three annotation-only
            // variants of Motion Blur. The executable bodies share the same
            // accumulation and identity-combine semantics; retain each exact
            // fingerprint rather than trusting a filename.
            (.motionBlurAccumulation, ["a771827a46d18c786f542b0622a52c271857c708d6811803cca74693a3d203ec"], "31b3ad35e38d2d7119c5a02d1ba73e9b6f9f0c6a941489c8b01a2de1a319e679"),
            (.motionBlurAccumulation, ["a771827a46d18c786f542b0622a52c271857c708d6811803cca74693a3d203ec"], "0e43b054b8adf39e7d36dbb6cb6d6ab8f5e85c9a35d20ea5fc24451547eaa011"),
            (.motionBlurAccumulation, ["a771827a46d18c786f542b0622a52c271857c708d6811803cca74693a3d203ec"], "80d9426ec0bce8664b6913ea5651c8dc4a2bb19fbfb428f4837eb97b2e655d09"),
            (.motionBlurCombine, ["0db922d6a0c5880e1cdfdeeabd13855fe3d959dd6492d0f3c79737ed5ed0bcdb"], "15d8db2eeef4d92b203d4d890deffe2a004147c158eb6e71f499b033649e902f"),
            (.motionBlurCombine, ["0db922d6a0c5880e1cdfdeeabd13855fe3d959dd6492d0f3c79737ed5ed0bcdb"], "22bb1420d0267844a68f36119a8f2c0bcede2d41f3f7768ef56829d884e484ab"),
            (.motionBlurCombine, ["0db922d6a0c5880e1cdfdeeabd13855fe3d959dd6492d0f3c79737ed5ed0bcdb"], "da0340830f7aaded326a60aa4b24729add5d2361212775e4048d158b350abf70")
        ]
        guard let reference = references.first(where: { $0.1.contains(v) && $0.2 == f }) else { throw invalid("作者效果着色器 \(shader) 尚未迁移到 Metal。") }
        return reference.0
    }

    private static func invalid(_ message: String) -> SceneError { .invalid(message) }
    private static func keys(_ object: [String: Any], _ allowed: Set<String>, _ name: String) throws {
        let extra = Set(object.keys).subtracting(allowed).sorted()
        guard extra.isEmpty else { throw invalid("\(name) 含尚未迁移的字段：\(extra.prefix(4).joined(separator: "、"))。") }
    }
}
