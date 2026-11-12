import Foundation

/// Script indices describe display order. Authored object indices remain
/// stable because property paths, parents, effects and model stores use them.
struct NativeSceneLayerOrder {
    let ids: [String]
    private let indexByID: [String: Int]
    private(set) var indices: [Int]
    private(set) var changes = 0

    init(objects: [[String: Any]], activeSlots: Set<Int>? = nil, order: [String]? = nil) throws {
        let ids = objects.enumerated().map { SceneScriptBridge.objectID($0.element, index: $0.offset) }
        let active = activeSlots ?? Set(ids.indices)
        guard ids.count <= 5000, active.isSubset(of: Set(ids.indices)),
              Set(active.map { ids[$0] }).count == active.count else {
            throw SceneError.invalid("SceneScript 图层 ID 必须唯一，且不能超过 5000 个。")
        }
        self.ids = ids
        indexByID = Dictionary(uniqueKeysWithValues: active.map { (ids[$0], $0) })
        indices = active.sorted()
        if let order {
            guard let next = receipt(order) else { throw SceneError.invalid("初始图层顺序与活动场景不一致。") }
            indices = next
        }
    }

    func receipt(_ raw: Any?) -> [Int]? {
        guard let raw = raw as? [String], raw.count == indexByID.count,
              Set(raw).count == indexByID.count else { return nil }
        let result = raw.compactMap { indexByID[$0] }
        return result.count == indexByID.count ? result : nil
    }

    mutating func commit(_ next: [Int]) {
        if next != indices { changes = min(changes + 1, 1_000_000_000); indices = next }
    }

    /// One object may produce several draws (model meshes or particle children).
    /// Keep their internal order and keep unowned renderer passes in their slots.
    func drawIndices(_ owners: [Int?]) -> [Int] {
        let rank = Dictionary(uniqueKeysWithValues: indices.enumerated().map { ($0.element, $0.offset) })
        let slots = owners.indices.filter { owners[$0] != nil }
        let ordered = slots.sorted {
            let lhs = rank[owners[$0]!] ?? Int.max, rhs = rank[owners[$1]!] ?? Int.max
            return lhs == rhs ? $0 < $1 : lhs < rhs
        }
        var result = Array(owners.indices)
        for (slot, draw) in zip(slots, ordered) { result[slot] = draw }
        return result
    }
}
