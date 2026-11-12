import Foundation

struct SceneEffectTargetSpec {
    let scale: Double
    let hdr: Bool
    let authoredFormat: String
    /// `unique` targets are allocated per image layer and retained while that
    /// layer remains alive. The only current consumer is a deliberately
    /// constrained `copy` history target (for the official Motion Blur graph).
    let unique: Bool
    func dimensions(width: Int, height: Int) -> (Int, Int) {
        (max(1, Int(ceil(Double(width) / scale))), max(1, Int(ceil(Double(height) / scale))))
    }
}

/// Asset-driven pass wiring. "previous" is the effect input, not the last
/// intermediate. Names are scoped to one effect and never become file paths.
struct SceneEffectGraph {
    struct Pass {
        enum Command {
            /// Copy a previously written named target into `target`. This is
            /// intentionally not a general command language: unknown commands
            /// remain rejected by the graph parser.
            case copy(source: String)
        }
        let target: String?
        let bindings: [Int: String]
        let command: Command?
    }
    let targets: [String: SceneEffectTargetSpec]
    let passes: [Pass]
    /// Targets that are read before their first write in a frame, then filled
    /// by a later constrained copy. Renderers initialize these on allocation
    /// and preserve them across frames; all other targets remain current-frame
    /// only.
    let historyTargets: Set<String>
    static let previous = "$effect-input"

    init(document: [String: Any], namespace: String, hdr: Bool) throws {
        let fbos = document["fbos"] as? [[String: Any]] ?? []
        guard document["fbos"] == nil || document["fbos"] is [[String: Any]], fbos.count <= 16 else { throw SceneError.invalid("效果 fbos 无效或超过 16 个。") }
        var specs: [String: SceneEffectTargetSpec] = [:]
        func scoped(_ name: String) -> String { namespace + ":" + name }
        for fbo in fbos {
            guard let name = fbo["name"] as? String, !name.isEmpty, name.utf8.count <= 256, name != "previous",
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains), specs[scoped(name)] == nil else { throw SceneError.invalid("效果缓冲名称缺失、重复或无效。") }
            guard let format = fbo["format"] as? String, ["rgba_backbuffer", "rgba8888"].contains(format),
                  fbo["persistent"] == nil, fbo["history"] == nil else {
                throw SceneError.invalid("当前仅支持当前帧的 rgba_backbuffer / rgba8888 效果缓冲。")
            }
            let scale = (fbo["scale"] as? NSNumber)?.doubleValue ?? 1
            guard scale.isFinite, (1...64).contains(scale) else { throw SceneError.invalid("效果缓冲 scale 必须在 1…64 之间。") }
            guard fbo["unique"] == nil || fbo["unique"] is Bool else { throw SceneError.invalid("效果缓冲 unique 必须为布尔值。") }
            // Legacy effects explicitly request four normalized 8-bit channels.
            // They must retain that precision even when the scene enables HDR.
            specs[scoped(name)] = SceneEffectTargetSpec(scale: scale, hdr: format == "rgba_backbuffer" && hdr,
                                                        authoredFormat: format, unique: fbo["unique"] as? Bool ?? false)
        }
        guard let authored = document["passes"] as? [[String: Any]], !authored.isEmpty, authored.count <= 32 else { throw SceneError.invalid("效果 passes 缺失或超过 32 个。") }
        // A unique target used as the destination of a later copy is the only
        // legal pre-frame history input. The reference Motion Blur effect uses
        // this exact ordering: read Buffer1, write Buffer2, copy Buffer2 into
        // Buffer1, then combine Buffer2. Do not generalize this to arbitrary
        // forward references or commands.
        var futureCopyTargetAt: [String: Int] = [:]
        for (index, pass) in authored.enumerated() where pass["command"] != nil {
            guard let command = pass["command"] as? String, command == "copy" else {
                throw SceneError.invalid("效果 command 仅支持 copy。")
            }
            guard Set(pass.keys).isSubset(of: Set(["command", "source", "target"])),
                  let rawTarget = pass["target"] as? String, let target = specs[scoped(rawTarget)], target.unique else {
                throw SceneError.invalid("效果 copy 需要 unique=true 的已声明 target，且不能带额外字段。")
            }
            guard futureCopyTargetAt[scoped(rawTarget)] == nil else { throw SceneError.invalid("效果 copy history target 不能重复。") }
            futureCopyTargetAt[scoped(rawTarget)] = index
        }
        var parsed: [Pass] = [], written = Set<String>(), history = Set<String>()
        for (passIndex, pass) in authored.enumerated() {
            if pass["command"] != nil {
                guard let command = pass["command"] as? String, command == "copy",
                      Set(pass.keys).isSubset(of: Set(["command", "source", "target"])),
                      let rawSource = pass["source"] as? String, let rawTarget = pass["target"] as? String,
                      let sourceSpec = specs[scoped(rawSource)], let targetSpec = specs[scoped(rawTarget)],
                      rawSource != rawTarget, written.contains(scoped(rawSource)), targetSpec.unique,
                      sourceSpec.scale == targetSpec.scale, sourceSpec.hdr == targetSpec.hdr,
                      sourceSpec.authoredFormat == targetSpec.authoredFormat else {
                    throw SceneError.invalid("效果 copy 需要同规格的已写 source 和 unique target。")
                }
                parsed.append(Pass(target: scoped(rawTarget), bindings: [:], command: .copy(source: scoped(rawSource))))
                written.insert(scoped(rawTarget))
                continue
            }
            let target: String?
            if let name = pass["target"] as? String {
                guard specs[scoped(name)] != nil else { throw SceneError.invalid("效果输出引用未声明的缓冲：\(name)") }
                target = scoped(name)
            } else {
                guard pass["target"] == nil else { throw SceneError.invalid("效果 target 类型无效。") }
                target = nil
            }
            let bindings = pass["bind"] as? [[String: Any]] ?? []
            guard pass["bind"] == nil || pass["bind"] is [[String: Any]], bindings.count <= 8 else { throw SceneError.invalid("效果 bind 无效或超过 8 个。") }
            var slots: [Int: String] = [:]
            for binding in bindings {
                guard let number = binding["index"] as? NSNumber, number.doubleValue.isFinite,
                      number.doubleValue == Double(number.intValue), (0..<8).contains(number.intValue),
                      let name = binding["name"] as? String, slots[number.intValue] == nil else { throw SceneError.invalid("效果纹理绑定无效或槽位重复。") }
                let key = name == "previous" ? Self.previous : scoped(name)
                let permittedHistory = key != Self.previous && futureCopyTargetAt[key].map { $0 > passIndex } == true
                    && specs[key]?.unique == true
                guard key == Self.previous || written.contains(key) || permittedHistory else { throw SceneError.invalid("效果读取尚未写入的缓冲：\(name)") }
                guard key != target else { throw SceneError.invalid("效果不能同时读写同一缓冲：\(name)") }
                if permittedHistory { history.insert(key) }
                slots[number.intValue] = key
            }
            parsed.append(Pass(target: target, bindings: slots, command: nil))
            if let target { written.insert(target) }
        }
        guard parsed.last?.target == nil else { throw SceneError.invalid("效果最后一遍必须输出到图层，不能只写中间缓冲。") }
        targets = specs; passes = parsed; historyTargets = history
    }
}
