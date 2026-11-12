import Foundation
import simd

/// An authored Renderable can carry hierarchy and script transforms without
/// owning any drawable resource. Keep this deliberately narrow: unknown or
/// unsupported object kinds must still reach the renderer's error path.
enum NativeSceneTransformNode {
    private static let transformKeys: Set<String> = ["id", "name", "origin", "angles", "scale", "visible", "parent", "locktransforms", "parallaxDepth"]
    private static let nullTypeKeys: Set<String> = ["image", "model", "particle", "camera", "light", "sound", "shape", "sprite"]

    static func matches(_ object: [String: Any]) -> Bool {
        !object.isEmpty && object.allSatisfy { key, value in
            transformKeys.contains(key) || (nullTypeKeys.contains(key) && value is NSNull)
        }
    }
}

/// Serialized layer parents use scene object IDs. Resolve once, then compose
/// local transforms in parent-first order each frame, including parents that
/// have no renderable material. Unknown/cyclic links hide the affected subtree
/// with a diagnostic instead of drawing it at a misleading root position.
struct SceneHierarchy {
    let parents: [Int?]
    let order: [Int]
    let invalid: Set<Int>
    let diagnostics: [String]

    init(objects: [[String: Any]]) {
        func identifier(_ value: Any?) -> String? {
            if let number = value as? NSNumber { return number.stringValue }
            return value as? String
        }
        var indices: [String: [Int]] = [:]
        for (index, object) in objects.enumerated() {
            if let id = identifier(object["id"]) { indices[id, default: []].append(index) }
        }
        var parents = [Int?](repeating: nil, count: objects.count)
        var invalid = Set<Int>(), messages: [String] = []
        for (index, object) in objects.enumerated() {
            guard let raw = object["parent"], !(raw is NSNull) else { continue }
            guard let id = identifier(raw), let candidates = indices[id], candidates.count == 1 else {
                invalid.insert(index)
                messages.append("图层 \(object["name"] as? String ?? String(index)) 的父图层 ID 缺失或不唯一；隐藏该子树。")
                continue
            }
            parents[index] = candidates[0]
        }
        var order: [Int] = [], finished = Set<Int>()
        for start in objects.indices where !finished.contains(start) {
            var chain: [Int] = [], visiting = Set<Int>(), cursor: Int? = start
            while let index = cursor, !finished.contains(index) {
                if !visiting.insert(index).inserted || chain.count >= 512 {
                    invalid.formUnion(chain)
                    messages.append("图层 \(objects[start]["name"] as? String ?? String(start)) 的父链循环或超过 512 层；隐藏该子树。")
                    break
                }
                chain.append(index); cursor = parents[index]
            }
            for index in chain.reversed() {
                if let parent = parents[index], invalid.contains(parent) { invalid.insert(index) }
                finished.insert(index); order.append(index)
            }
        }
        self.parents = parents; self.order = order; self.invalid = invalid; diagnostics = messages
    }

    func resolve(local: [simd_float4x4], visible: [Bool]) -> (transforms: [simd_float4x4], visible: [Bool]) {
        precondition(local.count == parents.count && visible.count == parents.count)
        var transforms = local, visibility = visible
        for index in order {
            if invalid.contains(index) { visibility[index] = false; continue }
            if let parent = parents[index] {
                transforms[index] = transforms[parent] * local[index]
                visibility[index] = visibility[parent] && visible[index]
            }
        }
        return (transforms, visibility)
    }
}
