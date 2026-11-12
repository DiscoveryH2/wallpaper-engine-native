import Foundation

/// Mutable scene membership, independent of the rendering API. Prepare does
/// not change the live scene: resource construction may fail, or another
/// transition may commit while a candidate is being prepared.
final class NativeSceneLifecycle {
    struct Handle: Hashable, Sendable {
        fileprivate let scene: UUID
        let slot: Int
        let generation: UInt64
    }

    struct Insertion {
        let id: String
        let configuration: [String: Any]
    }

    struct Snapshot: Sendable {
        fileprivate let scene: UUID
        let revision: UInt64
        fileprivate let header: Data
        fileprivate let records: [Record?]
        fileprivate let generations: [UInt64]
        let order: [Handle]

        var activeSlots: Set<Int> { Set(order.map(\.slot)) }
        var slotCount: Int { records.count }
        var count: Int { order.count }
        var orderedIDs: [String] { order.map { records[$0.slot]!.id } }

        func handle(id: String) -> Handle? {
            order.first { records[$0.slot]?.id == id }
        }

        func configuration(for handle: Handle) throws -> [String: Any]? {
            guard contains(handle), let record = records[handle.slot] else { return nil }
            return try JSONSerialization.jsonObject(with: record.configuration) as? [String: Any]
        }

        func initialConfigurations() throws -> [String: [String: Any]] {
            try Dictionary(uniqueKeysWithValues: records.compactMap { record in
                try record.map { ($0.id, try JSONSerialization.jsonObject(with: $0.configuration) as! [String: Any]) }
            })
        }

        func contains(_ handle: Handle) -> Bool {
            handle.scene == scene && records.indices.contains(handle.slot) &&
                records[handle.slot] != nil && generations[handle.slot] == handle.generation
        }

        /// Preserve already resolved/expanded survivor values. Membership and
        /// parent detachment come from this snapshot, never from a disk reload.
        func applyingMembership(to scene: [String: Any]) throws -> [String: Any] {
            let old = scene["objects"] as? [[String: Any]] ?? []
            guard old.count == records.count else { throw SceneError.invalid("场景资源槽位与生命周期快照不一致。") }
            var result = scene
            var objects = try materializedScene()["objects"] as! [[String: Any]]
            for slot in activeSlots {
                objects[slot] = old[slot]
                if records[slot]!.parentDetached { objects[slot].removeValue(forKey: "parent") }
            }
            result["objects"] = objects
            return result
        }

        func retains(path: String) -> Bool { Self.retains(path: path, slots: activeSlots) }

        static func retains(path: String, slots: Set<Int>) -> Bool {
            let parts = path.split(separator: "/")
            guard parts.first == "objects" else { return true }
            return parts.count >= 2 && Int(parts[1]).map(slots.contains) == true
        }

        /// Empty slots remain internal. Consumers must use activeSlots when
        /// building resources or exposing script objects. They have no scripts,
        /// parents, textures, models, sounds or other retained resources.
        func materializedScene() throws -> [String: Any] {
            var result = try JSONSerialization.jsonObject(with: header) as! [String: Any]
            let liveIDs = Set(records.compactMap { $0?.id })
            result["objects"] = try records.enumerated().map { slot, record -> [String: Any] in
                guard let record else {
                    var id = "_native_retired_\(scene.uuidString)_\(slot)"
                    while liveIDs.contains(id) { id += "_" }
                    return ["id": id, "visible": false]
                }
                var object = try JSONSerialization.jsonObject(with: record.configuration) as! [String: Any]
                if record.parentDetached { object.removeValue(forKey: "parent") }
                object["id"] = record.id
                return object
            }
            return result
        }
    }

    struct Transition {
        fileprivate let baseRevision: UInt64
        let snapshot: Snapshot
        let inserted: [Handle]
        let retired: [Handle]
        /// Stable slots AND generations, suitable for retaining clocks and
        /// GPU resources. Slot reuse alone never implies object continuity.
        let retainedSlots: Set<Int>
    }

    fileprivate struct Record: Sendable {
        let id: String
        let configuration: Data
        var parentDetached = false
    }

    private(set) var snapshot: Snapshot
    static let maximumLayers = 5000
    static let maximumMutations = 256
    private static let maximumSceneBytes = 4 * 1024 * 1024

    init(snapshot: Snapshot) { self.snapshot = snapshot }

    init(scene: [String: Any]) throws {
        guard let objects = scene["objects"] as? [[String: Any]], objects.count <= Self.maximumLayers else {
            throw SceneError.invalid("场景生命周期需要不超过 5000 个图层的对象列表。")
        }
        let identity = UUID()
        let header = try Self.encode(scene.filter { $0.key != "objects" })
        var bytes = header.count
        var ids = Set<String>(), records: [Record?] = []
        for (index, object) in objects.enumerated() {
            let id = Self.objectID(object, index: index)
            guard Self.validID(id), ids.insert(id).inserted else {
                throw SceneError.invalid("场景生命周期的图层身份为空、过长或重复。")
            }
            let configuration = try Self.encode(object.filter { $0.key != "id" })
            bytes += configuration.count + id.utf8.count + 32
            guard bytes <= Self.maximumSceneBytes else { throw SceneError.invalid("活动场景配置合计超过 4 MiB。") }
            records.append(Record(id: id, configuration: configuration))
        }
        try Self.checkSize(header: header, records: records)
        snapshot = Snapshot(scene: identity, revision: 0, header: header, records: records,
            generations: Array(repeating: 1, count: records.count),
            order: records.indices.map { Handle(scene: identity, slot: $0, generation: 1) })
    }

    /// The reference Renderable destructor detaches surviving children with
    /// SetParent(nil, false, -1). Keep their local state and immutable initial
    /// configuration; only their runtime parent relationship changes.
    func prepare(inserting: [Insertion] = [], retiring: [Handle] = [], order requestedOrder: [String]? = nil) throws -> Transition {
        let base = snapshot
        guard inserting.count + retiring.count <= Self.maximumMutations,
              Set(retiring).count == retiring.count, retiring.allSatisfy(base.contains),
              base.revision < UInt64.max else {
            throw SceneError.invalid("场景增删包含重复、失效或外部对象，或超过单次 256 项上限。")
        }
        var records = base.records, generations = base.generations
        let retired = Set(retiring)
        var order = base.order.filter { !retired.contains($0) }
        let retained = Set(order.map(\.slot))
        let retiredIDs = Set(retiring.compactMap { base.records[$0.slot]?.id })
        for handle in retiring { records[handle.slot] = nil }
        var bytes = base.header.count + records.compactMap { $0 }.reduce(0) { $0 + $1.configuration.count + $1.id.utf8.count + 32 }
        var ids = Set(records.compactMap { $0?.id })
        var inserted: [Handle] = []
        // A batch cannot replace an identity. Otherwise its queued callbacks
        // and cross-layer writes could silently target the replacement object.
        for insertion in inserting {
            guard Self.validID(insertion.id), !retiredIDs.contains(insertion.id), ids.insert(insertion.id).inserted,
                  order.count < Self.maximumLayers else {
                throw SceneError.invalid("新图层身份重复或已在本批次退役，或超过 5000 个活动图层。")
            }
            let configuration = try Self.encode(insertion.configuration.filter { $0.key != "id" })
            bytes += configuration.count + insertion.id.utf8.count + 32
            guard bytes <= Self.maximumSceneBytes else { throw SceneError.invalid("活动场景配置合计超过 4 MiB。") }
            let record = Record(id: insertion.id, configuration: configuration)
            let slot: Int
            if let vacant = records.firstIndex(where: { $0 == nil }) {
                guard generations[vacant] < UInt64.max else { throw SceneError.invalid("图层身份代次已用尽。") }
                slot = vacant; generations[slot] += 1; records[slot] = record
            } else {
                slot = records.count; records.append(record); generations.append(1)
            }
            let handle = Handle(scene: base.scene, slot: slot, generation: generations[slot])
            inserted.append(handle); order.append(handle)
        }
        if let requestedOrder {
            guard requestedOrder.count == order.count, Set(requestedOrder) == ids else {
                throw SceneError.invalid("场景增删后的显示顺序必须完整且唯一。")
            }
            let byID = Dictionary(uniqueKeysWithValues: order.map { (records[$0.slot]!.id, $0) })
            order = requestedOrder.map { byID[$0]! }
        }
        for slot in records.indices {
            guard var record = records[slot] else { continue }
            let object = try JSONSerialization.jsonObject(with: record.configuration) as! [String: Any]
            if let parent = Self.identifier(object["parent"]), retiredIDs.contains(parent), !ids.contains(parent) {
                record.parentDetached = true; records[slot] = record
            }
        }
        try Self.checkSize(header: base.header, records: records)
        let next = Snapshot(scene: base.scene, revision: base.revision + 1, header: base.header,
            records: records, generations: generations, order: order)
        return Transition(baseRevision: base.revision, snapshot: next, inserted: inserted,
            retired: retiring, retainedSlots: retained)
    }

    /// Call only after the complete candidate resources and script inventory
    /// have been prepared. Rejected/stale candidates leave the live scene intact.
    func commit(_ transition: Transition) throws {
        guard transition.snapshot.scene == snapshot.scene, transition.baseRevision == snapshot.revision,
              transition.snapshot.revision == snapshot.revision + 1 else {
            throw SceneError.invalid("场景变更已过期或属于另一个播放实例；保持当前场景。")
        }
        snapshot = transition.snapshot
    }

    private static func objectID(_ object: [String: Any], index: Int) -> String {
        identifier(object["id"]) ?? "object-\(index)"
    }

    private static func identifier(_ value: Any?) -> String? {
        if let value = value as? NSNumber { return value.stringValue }
        return value as? String
    }

    private static func validID(_ id: String) -> Bool { !id.isEmpty && id.utf8.count <= 256 && !id.utf8.contains(0) }

    private static func encode(_ object: [String: Any]) throws -> Data {
        var nodes = 0
        func validate(_ value: Any, depth: Int) throws {
            nodes += 1
            guard depth <= 32, nodes <= 262144 else { throw SceneError.invalid("场景配置超过结构深度或节点上限。") }
            if let object = value as? [String: Any] {
                for (key, value) in object {
                    guard key.utf8.count <= 4096 else { throw SceneError.invalid("场景配置键过长。") }
                    try validate(value, depth: depth + 1)
                }
            } else if let values = value as? [Any] {
                for value in values { try validate(value, depth: depth + 1) }
            } else if let text = value as? String {
                guard text.utf8.count <= maximumSceneBytes else { throw SceneError.invalid("场景配置字符串过长。") }
            } else if let number = value as? NSNumber {
                guard number.doubleValue.isFinite else { throw SceneError.invalid("场景配置含非有限数值。") }
            } else if !(value is NSNull) { throw SceneError.invalid("场景配置只能包含 JSON 值。") }
        }
        try validate(object, depth: 0)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
        guard data.count <= maximumSceneBytes else { throw SceneError.invalid("场景配置超过 4 MiB。") }
        return data
    }

    private static func checkSize(header: Data, records: [Record?]) throws {
        var bytes = header.count
        for record in records.compactMap({ $0 }) {
            bytes += record.configuration.count + record.id.utf8.count + 32
            guard bytes <= maximumSceneBytes else { throw SceneError.invalid("活动场景配置合计超过 4 MiB。") }
        }
    }
}
