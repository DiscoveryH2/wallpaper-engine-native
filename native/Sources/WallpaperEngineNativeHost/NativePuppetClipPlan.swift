import Foundation

/// A deliberately narrow, bounded plan for independent puppet clipping masks.
/// The renderer may only use it after resolving all referenced textures.
struct NativePuppetClipPlan {
    enum Command {
        case normal([Int])
        case masked(mask: Int, sources: [Int], targets: [Int])
    }
    let commands: [Command]
    let sortedRanges: [Int]

    private static func invalid(_ message: String) -> SceneError {
        SceneError.invalid("Puppet clipping plan: \(message)")
    }

    init(shape: NativePuppetModel.Shape, boneOrder: [UInt32]?) throws {
        let ranges = shape.rangeRecords
        guard !ranges.isEmpty, ranges.count <= 4096, !shape.clippingMasks.isEmpty,
              shape.clippingMasks.count <= 16, let boneOrder, !boneOrder.isEmpty else {
            throw Self.invalid("missing ranges, masks or bone order, or plan exceeds its limits")
        }
        // The selected image path supports only the reference's static sort
        // data. The MDLA reader rejects auxiliary animated order tracks.
        var expectedStart: UInt64 = 0
        for range in ranges.sorted(by: { $0.words.z < $1.words.z }) {
            let start = UInt64(range.words.z), count = UInt64(range.words.w)
            guard count > 0, start == expectedStart, count % 3 == 0,
                  start + count <= UInt64(shape.indices.count),
                  Int(range.words.x) < boneOrder.count else {
                throw Self.invalid("ranges must form a complete, valid index partition with a known bone")
            }
            expectedStart += count
        }
        guard expectedStart == UInt64(shape.indices.count) else {
            throw Self.invalid("ranges do not cover the entire index buffer")
        }
        func orderKey(_ index: Int) -> Int64 {
            let row = ranges[index].words
            let initialBoneOrder = Int64(Int32(bitPattern: boneOrder[Int(row.x)]))
            let localOffset = Int64(Int32(bitPattern: row.y))
            // The reference combines the initial and current bone order. With
            // no auxiliary ordering track, current order is the initial value.
            return initialBoneOrder * 2 + localOffset
        }
        let order = ranges.indices.sorted {
            let left = orderKey($0), right = orderKey($1)
            return left == right ? $0 < $1 : left < right
        }
        let position = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
        struct Item {
            let mask: Int
            let sources: [Int]
            let targets: [Int]
            let trigger: Int
            let firstTarget: Int
        }
        var items: [Item] = [], allTargets = Set<Int>(), allSources = Set<Int>()
        var sourceGroups: [Int: [Int]] = [:], plannedRanges = 0
        for (maskIndex, mask) in shape.clippingMasks.enumerated() {
            guard mask.flags == 0, !mask.inputs.isEmpty, !mask.dependencies.isEmpty else {
                throw Self.invalid("non-default mask flags or empty mask lists are not supported")
            }
            let targets = mask.inputs.map(Int.init), sources = mask.dependencies.map(Int.init)
            guard targets.allSatisfy({ ranges.indices.contains($0) }),
                  sources.allSatisfy({ ranges.indices.contains($0) }),
                  Set(targets).count == targets.count, Set(sources).count == sources.count,
                  Set(targets).isDisjoint(with: Set(sources)),
                  allTargets.isDisjoint(with: Set(targets)) else {
                throw Self.invalid("invalid, repeated or overlapping mask range references")
            }
            let sortedSources = sources.sorted { position[$0]! < position[$1]! }
            let sortedTargets = targets.sorted { position[$0]! < position[$1]! }
            plannedRanges += sortedSources.count + sortedTargets.count
            guard plannedRanges <= 8192 else { throw Self.invalid("mask draw count exceeds its per-shape limit") }
            for source in sortedSources {
                if let existing = sourceGroups[source], existing != sortedSources {
                    throw Self.invalid("partially overlapping mask source groups are unsupported")
                }
                sourceGroups[source] = sortedSources
            }
            let sourcePositions = sortedSources.map { position[$0]! }
            guard let first = sourcePositions.first, let last = sourcePositions.last,
                  last - first + 1 == sourcePositions.count,
                  let targetFirst = sortedTargets.first.map({ position[$0]! }), targetFirst > last else {
                throw Self.invalid("interleaved or preceding mask ranges require the general batching path")
            }
            allTargets.formUnion(targets); allSources.formUnion(sources)
            items.append(Item(mask: maskIndex, sources: sortedSources, targets: sortedTargets,
                              trigger: last, firstTarget: targetFirst))
        }
        guard allTargets.isDisjoint(with: allSources) else {
            throw Self.invalid("nested masks require the general batching path")
        }
        let grouped = Dictionary(grouping: items, by: { $0.trigger })
        for (trigger, group) in grouped {
            let targets = group.flatMap(\.targets).map { position[$0]! }.sorted()
            guard let last = targets.last, let first = targets.first,
                  first == trigger + 1, last - first + 1 == targets.count else {
                throw Self.invalid("mask targets interleaved with other ranges require the general batching path")
            }
        }
        var commands: [Command] = [], normal: [Int] = []
        func flush() {
            if !normal.isEmpty { commands.append(.normal(normal)); normal.removeAll(keepingCapacity: true) }
        }
        for (offset, index) in order.enumerated() {
            if !allTargets.contains(index) { normal.append(index) }
            if let triggered = grouped[offset] {
                flush()
                for item in triggered.sorted(by: {
                    $0.firstTarget == $1.firstTarget ? $0.mask < $1.mask : $0.firstTarget < $1.firstTarget
                }) {
                    commands.append(.masked(mask: item.mask, sources: item.sources, targets: item.targets))
                }
            }
        }
        flush()
        self.commands = commands; self.sortedRanges = order
    }
}
