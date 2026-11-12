import Foundation
import CoreGraphics

/// Selection uses persistent layer identities; table order is only presentation.
/// Edits are validated on a document copy before any preview or history changes.
enum NativeCreationLayerEditing {
    static func applying(_ poses: [UUID: NativeCreationPose], to document: NativeCreationDocument,
                         frame: Int) throws -> NativeCreationDocument {
        _ = try document.validated()
        try requireEditable(Set(poses.keys), in: document)
        guard (0...Int((document.duration * NativeCreationMotion.fps).rounded())).contains(frame) else {
            throw SceneError.invalid("画布调整的时间超出作品时长。")
        }
        var result = document
        for index in document.layers.indices {
            guard let pose = poses[document.layers[index].id] else { continue }
            var layer = document.layers[index]
            // A displayed swing angle must never become an authored rotation.
            let previous = layer.motion(duration: document.duration, loop: document.loop)
                .pose(at: Double(frame) / NativeCreationMotion.fps, preserveEndpoint: true, includeSwing: false)
            var changed = previous
            changed.x = pose.x; changed.y = pose.y
            changed.scaleX = pose.scaleX; changed.scaleY = pose.scaleY
            guard changed.isValid else { throw SceneError.invalid("整体调整超出位置或缩放范围，所有图层保持原样。") }
            layer.edit(changed, comparedTo: previous, at: frame, properties: [.x, .y, .scaleX, .scaleY])
            result.layers[index] = layer
        }
        result.adoptTrackFormat()
        return try result.validated()
    }

    static func reordered(_ selection: Set<UUID>, in document: NativeCreationDocument,
                          towardFront: Bool) throws -> NativeCreationDocument {
        _ = try document.validated(); try requireEditable(selection, in: document)
        var result = document
        if towardFront {
            for index in document.layers.indices.reversed() where index + 1 < document.layers.count {
                if selection.contains(result.layers[index].id), !selection.contains(result.layers[index + 1].id) {
                    result.layers.swapAt(index, index + 1)
                }
            }
        } else {
            for index in document.layers.indices where index > 0 {
                if selection.contains(result.layers[index].id), !selection.contains(result.layers[index - 1].id) {
                    result.layers.swapAt(index, index - 1)
                }
            }
        }
        return try result.validated()
    }

    static func removing(_ selection: Set<UUID>, from document: NativeCreationDocument) throws -> NativeCreationDocument {
        _ = try document.validated(); try requireEditable(selection, in: document)
        var result = document
        result.layers.removeAll { selection.contains($0.id) }
        guard !result.layers.isEmpty, result.layers.contains(where: \.visible) else {
            throw SceneError.invalid("作品需要保留至少一个可见图层；本次删除未应用。")
        }
        return try result.validated()
    }

    static func settingLocked(_ locked: Bool, selection: Set<UUID>, in document: NativeCreationDocument) throws -> NativeCreationDocument {
        _ = try document.validated(); try checkSelection(selection, in: document)
        var result = document
        for index in result.layers.indices where selection.contains(result.layers[index].id) {
            result.layers[index].editorLocked = locked ? true : nil
        }
        return try result.validated()
    }

    static func requireEditable(_ selection: Set<UUID>, in document: NativeCreationDocument) throws {
        try checkSelection(selection, in: document)
        guard !document.layers.contains(where: { selection.contains($0.id) && $0.isLocked }) else {
            throw SceneError.invalid("所选图层包含已锁定图层，请先解锁；本次操作未应用。")
        }
    }

    private static func checkSelection(_ selection: Set<UUID>, in document: NativeCreationDocument) throws {
        guard !selection.isEmpty, selection.isSubset(of: Set(document.layers.map(\.id))) else {
            throw SceneError.invalid("请选择仍存在的图层。")
        }
    }
}

struct NativeCreationLayerGeometry: Equatable {
    let id: UUID
    let name: String
    let localBounds: CGRect
    var pose: NativeCreationPose
    let visible: Bool
    var locked = false

    func world(_ local: CGPoint, pose: NativeCreationPose? = nil) -> CGPoint {
        let pose = pose ?? self.pose, angle = pose.rotation * .pi / 180
        let x = Double(local.x) * pose.scaleX, y = Double(local.y) * pose.scaleY
        return CGPoint(x: pose.x + cos(angle) * x - sin(angle) * y,
                       y: pose.y + sin(angle) * x + cos(angle) * y)
    }
    static func corners(_ bounds: CGRect) -> [CGPoint] {
        [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
         CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
    }
    var localCorners: [CGPoint] { Self.corners(localBounds) }
    var worldCorners: [CGPoint] { localCorners.map { world($0) } }
    func contains(_ point: CGPoint) -> Bool {
        let angle = pose.rotation * .pi / 180, x = Double(point.x) - pose.x, y = Double(point.y) - pose.y
        return localBounds.contains(CGPoint(x: (cos(angle) * x + sin(angle) * y) / pose.scaleX,
                                           y: (-sin(angle) * x + cos(angle) * y) / pose.scaleY))
    }
    /// A rotated layer can overlap a marquee without either rectangle enclosing
    /// a corner of the other. Project both quads onto every separating axis.
    /// Checking the axis-aligned enclosing box alone would select empty corners.
    func intersects(_ rectangle: CGRect) -> Bool {
        let rect = rectangle.standardized
        guard !rect.isNull, !rect.isInfinite, !localBounds.isNull, !localBounds.isInfinite,
              [rect.minX, rect.minY, rect.maxX, rect.maxY,
               localBounds.minX, localBounds.minY, localBounds.maxX, localBounds.maxY].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, localBounds.width > 0, localBounds.height > 0,
              pose.scaleX.isFinite, pose.scaleY.isFinite, pose.scaleX > 0, pose.scaleY > 0 else { return false }
        let quad = worldCorners, box = Self.corners(rect)
        guard quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var axes = [CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)]
        for index in 0..<2 {
            let a = quad[index], b = quad[index + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length.isFinite, length > 0 else { return false }
            axes.append(CGVector(dx: -(b.y - a.y) / length, dy: (b.x - a.x) / length))
        }
        return axes.allSatisfy { axis in
            let a = quad.map { $0.x * axis.dx + $0.y * axis.dy }
            let b = box.map { $0.x * axis.dx + $0.y * axis.dy }
            return a.max()! + 0.0000001 >= b.min()! && b.max()! + 0.0000001 >= a.min()!
        }
    }
    static func intersecting(_ rectangle: CGRect, in items: [Self]) -> Set<UUID> {
        Set(items.filter { !$0.locked && $0.visible && $0.pose.opacity > 0.001 && $0.intersects(rectangle) }.map(\.id))
    }
    static func enclosing(_ items: [Self]) -> CGRect? {
        let points = items.flatMap(\.worldCorners)
        guard let first = points.first, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            CGRect(x: min(rect.minX, point.x), y: min(rect.minY, point.y),
                   width: max(rect.maxX, point.x) - min(rect.minX, point.x),
                   height: max(rect.maxY, point.y) - min(rect.minY, point.y))
        }
    }

    /// Clamp a shared displacement, so hitting a limit never distorts spacing.
    static func translated(_ items: [Self], dx: Double, dy: Double) -> [UUID: NativeCreationPose]? {
        guard valid(items), dx.isFinite, dy.isFinite else { return nil }
        let x = min(items.map { 32768 - $0.pose.x }.min()!, max(items.map { -32768 - $0.pose.x }.max()!, dx))
        let y = min(items.map { 32768 - $0.pose.y }.min()!, max(items.map { -32768 - $0.pose.y }.max()!, dy))
        return Dictionary(uniqueKeysWithValues: items.map { item in
            var pose = item.pose; pose.x += x; pose.y += y
            return (item.id, pose)
        })
    }

    /// Uniform group scaling preserves rotated quads without introducing shear.
    /// The same factor respects every member's position and scale limits.
    static func scaled(_ items: [Self], around anchor: CGPoint, factor: Double) -> [UUID: NativeCreationPose]? {
        guard valid(items), anchor.x.isFinite, anchor.y.isFinite, factor.isFinite else { return nil }
        var lower = items.map { max(0.01 / $0.pose.scaleX, 0.01 / $0.pose.scaleY) }.max()!
        var upper = items.map { min(8 / $0.pose.scaleX, 8 / $0.pose.scaleY) }.min()!
        for item in items {
            for (origin, pivot) in [(item.pose.x, Double(anchor.x)), (item.pose.y, Double(anchor.y))] {
                let delta = origin - pivot
                guard delta.isFinite else { return nil }
                if delta != 0 {
                    let a = (-32768 - pivot) / delta, b = (32768 - pivot) / delta
                    lower = max(lower, min(a, b)); upper = min(upper, max(a, b))
                }
            }
        }
        guard lower.isFinite, upper.isFinite, lower <= upper else { return nil }
        let value = min(upper, max(lower, factor))
        let pairs = items.map { item -> (UUID, NativeCreationPose) in
            var pose = item.pose
            pose.x = min(32768, max(-32768, Double(anchor.x) + (pose.x - Double(anchor.x)) * value))
            pose.y = min(32768, max(-32768, Double(anchor.y) + (pose.y - Double(anchor.y)) * value))
            pose.scaleX = min(8, max(0.01, pose.scaleX * value))
            pose.scaleY = min(8, max(0.01, pose.scaleY * value))
            return (item.id, pose)
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }
    private static func valid(_ items: [Self]) -> Bool {
        !items.isEmpty && Set(items.map(\.id)).count == items.count && items.allSatisfy {
            !$0.locked &&
            [$0.pose.x, $0.pose.y, $0.pose.scaleX, $0.pose.scaleY].allSatisfy(\.isFinite)
                && abs($0.pose.x) <= 32768 && abs($0.pose.y) <= 32768
                && (0.01...8).contains($0.pose.scaleX) && (0.01...8).contains($0.pose.scaleY)
        }
    }
}
