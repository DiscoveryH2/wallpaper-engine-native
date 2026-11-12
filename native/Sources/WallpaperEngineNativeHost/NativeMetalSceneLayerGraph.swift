import Foundation

/// The small, explicit subset of Scene inter-layer routing which can be
/// represented without treating an author-provided resource declaration as a
/// rendering dependency.  In particular, object/effect `dependencies` stay
/// outside this type: the only GPU edge is an actually-consumed canonical
/// `_rt_imageLayerComposite_<id>_a` sampler.
///
/// Construction is deliberately whole-scene and fail-closed.  A missing,
/// ambiguous, cyclic, or non-exportable producer prevents Metal admission;
/// callers must leave the Scene on the existing compatibility backend rather
/// than rendering with an old or unrelated texture.
struct NativeMetalSceneLayerGraph: Sendable {
    struct Export: Sendable, Equatable {
        let id: String
        let producerObjectIndex: Int
    }

    let exports: [Export]

    var producerObjectIndices: Set<Int> { Set(exports.map(\.producerObjectIndex)) }
    var isEmpty: Bool { exports.isEmpty }

    /// This is intentionally stricter than parsing an integer.  The matching
    /// OpenGL path does not make `01`, `+1`, a negative id, another suffix, or
    /// a future render-target spelling aliases for layer 1.
    static func compositeID(_ name: String) -> String? {
        let prefix = "_rt_imageLayerComposite_"
        guard name.hasPrefix(prefix), name.hasSuffix("_a") else { return nil }
        let raw = String(name.dropFirst(prefix.count).dropLast(2))
        guard let value = Int(raw), value >= 0, String(value) == raw else { return nil }
        return raw
    }

    static func isRenderTargetAlias(_ name: String) -> Bool { name.hasPrefix("_rt_") }

    /// `layers` are already strictly parsed Metal layers.  That lets this
    /// graph inspect real, active effect-input bindings rather than scanning
    /// arbitrary JSON texture strings (including inactive sampler slots).
    init(layers: [NativeMetalSceneSource.Layer]) throws {
        let requested = Set(layers.flatMap { layer in
            layer.effects.groups.flatMap { group in
                group.passes.flatMap { pass in
                    pass.inputs.values.compactMap { input -> String? in
                        if case let .layerComposite(id) = input { return id }
                        return nil
                    }
                }
            }
        })
        guard requested.count <= 64 else {
            throw SceneError.invalid("Metal 图层纹理引用超过当前 64 个源图层上限。")
        }
        guard !requested.isEmpty else { self.exports = []; return }

        var candidates: [String: [NativeMetalSceneSource.Layer]] = [:]
        for layer in layers {
            // A noncanonical authored object id can never be reached by the
            // canonical sampler grammar.  Keep it out of candidates so the
            // reference reports a missing source instead of becoming an alias.
            guard Self.compositeID("_rt_imageLayerComposite_\(layer.objectID)_a") == layer.objectID else { continue }
            candidates[layer.objectID, default: []].append(layer)
        }
        var visiting = Set<String>(), valid = Set<String>(), invalid = Set<String>()
        var ordered: [Export] = []
        func dependencies(of layer: NativeMetalSceneSource.Layer) -> Set<String> {
            Set(layer.effects.groups.flatMap { group in
                group.passes.flatMap { pass in
                    pass.inputs.values.compactMap { input -> String? in
                        if case let .layerComposite(id) = input { return id }
                        return nil
                    }
                }
            })
        }
        func visit(_ id: String) -> Bool {
            if valid.contains(id) { return true }
            if invalid.contains(id) { return false }
            if visiting.contains(id) {
                invalid.insert(id)
                return false
            }
            guard let matches = candidates[id], matches.count == 1, let layer = matches.first,
                  layer.isLayerCompositeProducer else {
                invalid.insert(id)
                return false
            }
            visiting.insert(id)
            let complete = dependencies(of: layer).sorted().allSatisfy(visit)
            visiting.remove(id)
            guard complete, !invalid.contains(id) else {
                invalid.insert(id)
                return false
            }
            valid.insert(id)
            ordered.append(Export(id: id, producerObjectIndex: layer.objectIndex))
            return true
        }
        guard requested.sorted().allSatisfy(visit) else {
            throw SceneError.invalid("Metal 图层纹理引用缺少唯一的可导出图片/文字源，或存在循环、场景背景读取/颜色合成。")
        }
        self.exports = ordered
    }
}
