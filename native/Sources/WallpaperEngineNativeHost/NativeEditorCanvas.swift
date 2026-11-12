import AppKit

/// Selection outlines are editor-only. Geometry comes from the actual renderer.
@MainActor
final class NativeEditorCanvas: NSView, NSMenuItemValidation {
    typealias Item = NativeCreationLayerGeometry
    var prepareInteraction: (() -> Bool)?
    var onSelect: ((Set<UUID>, UUID?) -> Void)?
    var onBegin: ((Set<UUID>) -> Bool)?
    var onChange: (([UUID: NativeCreationPose]) -> Bool)?
    var onFinish: ((Bool) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onDelete: (() -> Void)?
    var interactionEnabled = false { didSet { if !interactionEnabled { cancelInteraction() }; needsDisplay = true } }
    var marqueeMode = false { didSet { if oldValue != marqueeMode { cancelInteraction() } } }
    private var items: [Item] = []
    private var selectedIDs: Set<UUID> = []
    private var primaryID: UUID?
    private var canvasSize = CGSize(width: 1920, height: 1080)
    private struct Gesture {
        let items: [Item]
        let start: CGPoint
        let handle: Int?
        let groupBounds: CGRect?
        var began = false
    }
    private var gesture: Gesture?
    private struct Marquee {
        enum Mode { case replace, add, toggle }
        let start: CGPoint
        let originalSelection: Set<UUID>
        let primary: UUID?
        let mode: Mode
        var end: CGPoint
        var began = false
        var rectangle: CGRect {
            CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
    }
    private var marquee: Marquee?
    private var interacting: Bool { gesture != nil || marquee != nil }
    private var selectedItems: [Item] { items.filter { selectedIDs.contains($0.id) } }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("作品画布")
        toolTip = "Command 点击增减选择，Command-A 全选。拖动移动；单层角点自由缩放，Shift 保持比例，多层角点整体等比缩放。Option 点击切换重叠图层。方向键微调，Shift 为 10 像素；Delete 删除所选图层，Esc 取消拖动。"
        toolTip = (toolTip ?? "") + " 锁定图层不会被画布点击或全选选中，请在图层列表中选择并解锁。"
        toolTip = (toolTip ?? "") + " 空白处拖动框选；开启“框选”后可从任意位置拖动。Shift 框选追加，Command 框选切换；未选中任何图层时保留原选择。"
        setAccessibilityHelp(toolTip)
    }
    required init?(coder: NSCoder) { nil }

    func update(size: CGSize, items: [Item], selected: Set<UUID>, primary: UUID?) {
        if marquee != nil && (size != canvasSize || items != self.items || selected != selectedIDs || primary != primaryID) {
            cancelInteraction()
        }
        canvasSize = size; self.items = items; selectedIDs = selected; primaryID = primary
        updateAccessibility(); needsDisplay = true
    }
    private func updateAccessibility() {
        var description = "画布 \(Int(canvasSize.width)) × \(Int(canvasSize.height))"
        let chosen = selectedItems
        if chosen.count > 1 {
            description += "，已选 \(chosen.count) 个图层：" + chosen.map(\.name).joined(separator: "、")
            if let bounds = Item.enclosing(chosen) {
                description += String(format: "，范围 X %.2f 至 %.2f，Y %.2f 至 %.2f", bounds.minX, bounds.maxX, bounds.minY, bounds.maxY)
            }
        } else if let item = chosen.first {
            description += String(format: "，已选 %@，X %.2f，Y %.2f，缩放 %.3f / %.3f", item.name, item.pose.x, item.pose.y, item.pose.scaleX, item.pose.scaleY)
        }
        let lockedCount = chosen.filter(\.locked).count
        if lockedCount > 0 { description += "，含 \(lockedCount) 个锁定图层，请在列表解锁后修改" }
        if let marquee, marquee.began { description += "，框选预览 \(marqueeSelection(marquee).count) 个图层，松开鼠标确认，Esc 取消" }
        setAccessibilityValue(description)
    }
    private func scenePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * canvasSize.width / max(1, bounds.width), y: point.y * canvasSize.height / max(1, bounds.height))
    }
    private func viewPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * bounds.width / canvasSize.width, y: point.y * bounds.height / canvasSize.height)
    }
    private func outline(_ corners: [CGPoint], handles: Bool) {
        guard corners.count == 4 else { return }
        let points = corners.map { viewPoint($0) }
        let path = NSBezierPath(); path.move(to: points[0])
        points.dropFirst().forEach { path.line(to: $0) }; path.close()
        NSColor.black.withAlphaComponent(0.7).setStroke(); path.lineWidth = 3; path.stroke()
        NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke()
        if handles {
            for point in points {
                let handle = NSBezierPath(rect: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                NSColor.white.setFill(); handle.fill(); NSColor.controlAccentColor.setStroke(); handle.lineWidth = 1.5; handle.stroke()
            }
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        guard interactionEnabled else { return }
        let preview = marquee.flatMap { $0.began ? marqueeSelection($0) : nil }
        let chosen = items.filter { (preview ?? selectedIDs).contains($0.id) }
        let editable = !chosen.contains(where: \.locked)
        for item in chosen where item.visible { outline(item.worldCorners, handles: marquee == nil && chosen.count == 1 && editable) }
        if chosen.count > 1, chosen.contains(where: \.visible), let bounds = Item.enclosing(chosen) {
            outline(Item.corners(bounds), handles: marquee == nil && editable)
        }
        if let marquee, marquee.began {
            let a = viewPoint(CGPoint(x: marquee.rectangle.minX, y: marquee.rectangle.minY))
            let b = viewPoint(CGPoint(x: marquee.rectangle.maxX, y: marquee.rectangle.maxY))
            let path = NSBezierPath(rect: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
            NSColor.controlAccentColor.withAlphaComponent(0.13).setFill(); path.fill()
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5
            path.setLineDash([5, 3], count: 2, phase: 0); path.stroke()
        }
    }
    private func select(_ ids: Set<UUID>, primary: UUID?) {
        selectedIDs = ids; primaryID = primary; onSelect?(ids, primary)
        updateAccessibility(); needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        guard interactionEnabled, !interacting, prepareInteraction?() == true else { return }
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil), scene = scenePoint(point)
        guard bounds.contains(point) else { return }
        if marqueeMode { beginMarquee(at: scene, flags: event.modifierFlags); return }
        let toggle = event.modifierFlags.contains(.command), cycle = event.modifierFlags.contains(.option)
        var handle: Int?
        let chosen = selectedItems
        let groupBounds = chosen.count > 1 ? Item.enclosing(chosen) : nil
        if !toggle, !cycle, !chosen.contains(where: \.locked), chosen.contains(where: \.visible) {
            let corners = groupBounds.map(Item.corners) ?? chosen.first?.worldCorners ?? []
            handle = corners.firstIndex { corner in
                let p = viewPoint(corner); return hypot(p.x - point.x, p.y - point.y) <= 9
            }
        }
        if handle == nil {
            let hits = items.reversed().filter { !$0.locked && $0.visible && $0.pose.opacity > 0.001 && $0.contains(scene) }
            let hit: Item?
            if cycle, let index = hits.firstIndex(where: { $0.id == primaryID }) { hit = hits[(index + 1) % hits.count] }
            else { hit = hits.first }
            guard let hit else { beginMarquee(at: scene, flags: event.modifierFlags); return }
            if toggle {
                var ids = selectedIDs
                if ids.contains(hit.id), ids.count > 1 { ids.remove(hit.id) } else { ids.insert(hit.id) }
                select(ids, primary: ids.contains(hit.id) ? hit.id : items.last(where: { ids.contains($0.id) })?.id)
                return
            }
            if !selectedIDs.contains(hit.id) || cycle || chosen.contains(where: \.locked) { select([hit.id], primary: hit.id) }
            else { select(selectedIDs, primary: hit.id) }
        }
        let current = selectedItems
        guard !current.isEmpty, current.count == selectedIDs.count, !current.contains(where: \.locked) else { return }
        gesture = Gesture(items: current, start: scene, handle: handle,
                          groupBounds: current.count > 1 ? Item.enclosing(current) : nil)
    }
    override func mouseDragged(with event: NSEvent) {
        if marquee != nil { updateMarquee(with: event); return }
        guard interactionEnabled, var gesture else { return }
        let point = scenePoint(convert(event.locationInWindow, from: nil))
        if !gesture.began {
            let start = viewPoint(gesture.start), current = viewPoint(point)
            guard hypot(current.x - start.x, current.y - start.y) >= 3 else { return }
            guard onBegin?(Set(gesture.items.map(\.id))) == true else { self.gesture = nil; return }
            gesture.began = true; self.gesture = gesture
        }
        let shift = event.modifierFlags.contains(.shift)
        let poses: [UUID: NativeCreationPose]?
        if let handle = gesture.handle, let group = gesture.groupBounds {
            let corners = Item.corners(group), anchor = corners[(handle + 2) % 4], corner = corners[handle]
            let dx = corner.x - anchor.x, dy = corner.y - anchor.y
            let length = dx * dx + dy * dy
            guard length > 0 else { return }
            let factor = ((dx + point.x - gesture.start.x) * dx + (dy + point.y - gesture.start.y) * dy) / length
            poses = Item.scaled(gesture.items, around: anchor, factor: Double(factor))
        } else if let handle = gesture.handle, let item = gesture.items.first {
            var pose = item.pose
            let corners = item.localCorners, anchor = corners[(handle + 2) % 4]
            let fixed = item.world(anchor), angle = pose.rotation * .pi / 180
            let originalCorner = item.world(corners[handle])
            let dx = Double(point.x - gesture.start.x + originalCorner.x - fixed.x)
            let dy = Double(point.y - gesture.start.y + originalCorner.y - fixed.y)
            let localX = cos(angle) * dx + sin(angle) * dy, localY = -sin(angle) * dx + cos(angle) * dy
            let width = Double(corners[handle].x - anchor.x), height = Double(corners[handle].y - anchor.y)
            if shift {
                let startX = width * pose.scaleX, startY = height * pose.scaleY
                let factor = (localX * startX + localY * startY) / max(0.000001, startX * startX + startY * startY)
                let bounded = min(min(8 / pose.scaleX, 8 / pose.scaleY), max(max(0.01 / pose.scaleX, 0.01 / pose.scaleY), factor))
                pose.scaleX *= bounded; pose.scaleY *= bounded
            } else {
                pose.scaleX = min(8, max(0.01, localX / width)); pose.scaleY = min(8, max(0.01, localY / height))
            }
            let x = Double(anchor.x) * pose.scaleX, y = Double(anchor.y) * pose.scaleY
            pose.x = Double(fixed.x) - cos(angle) * x + sin(angle) * y
            pose.y = Double(fixed.y) - sin(angle) * x - cos(angle) * y
            poses = [item.id: pose]
        } else {
            var dx = Double(point.x - gesture.start.x), dy = Double(point.y - gesture.start.y)
            if shift { if abs(dx) >= abs(dy) { dy = 0 } else { dx = 0 } }
            poses = Item.translated(gesture.items, dx: dx, dy: dy)
        }
        if let poses { _ = apply(poses) }
    }
    private func apply(_ poses: [UUID: NativeCreationPose]) -> Bool {
        guard onChange?(poses) == true else { return false }
        for index in items.indices { if let pose = poses[items[index].id] { items[index].pose = pose } }
        needsDisplay = true; updateAccessibility(); return true
    }
    override func mouseUp(with event: NSEvent) {
        if marquee != nil {
            updateMarquee(with: event)
            guard let marquee else { return }
            let ids = marqueeSelection(marquee)
            self.marquee = nil
            if marquee.began {
                let primary = marquee.primary.flatMap { ids.contains($0) ? $0 : nil } ?? items.last(where: { ids.contains($0.id) })?.id
                select(ids, primary: primary)
            }
            updateAccessibility(); needsDisplay = true
            return
        }
        guard let gesture else { return }
        if gesture.began { mouseDragged(with: event) }
        self.gesture = nil
        if gesture.began { onFinish?(true) }
    }
    func cancelInteraction() {
        if marquee != nil { marquee = nil; updateAccessibility(); needsDisplay = true }
        guard let gesture else { return }
        self.gesture = nil
        if gesture.began { onFinish?(false) }
    }
    override func cancelOperation(_ sender: Any?) { cancelInteraction() }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { cancelInteraction() }
        super.setFrameSize(newSize)
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelInteraction() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func selectAll(_ sender: Any?) {
        guard interactionEnabled, !interacting, prepareInteraction?() == true else { return }
        let editable = items.filter { !$0.locked }
        guard let last = editable.last else { return }
        let ids = Set(editable.map(\.id))
        select(ids, primary: primaryID.flatMap { ids.contains($0) ? $0 : nil } ?? last.id)
    }
    @objc func undo(_ sender: Any?) {
        guard interactionEnabled, !interacting else { return }
        onUndo?()
    }
    @objc func redo(_ sender: Any?) {
        guard interactionEnabled, !interacting else { return }
        onRedo?()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        interactionEnabled && !interacting
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelInteraction(); return }
        guard interactionEnabled else { super.keyDown(with: event); return }
        guard !interacting else { return }
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "z": if event.modifierFlags.contains(.shift) { redo(nil) } else { undo(nil) }; return
            case "a": selectAll(nil); return
            default: break
            }
        }
        if [51,117].contains(event.keyCode) { onDelete?(); return }
        guard [123,124,125,126].contains(event.keyCode), prepareInteraction?() == true else { super.keyDown(with: event); return }
        let chosen = selectedItems
        guard !chosen.isEmpty, chosen.count == selectedIDs.count else { return }
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let dx = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
        let dy = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
        guard let poses = Item.translated(chosen, dx: dx, dy: dy), onBegin?(selectedIDs) == true else { return }
        onFinish?(apply(poses))
    }
    private func beginMarquee(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        let mode: Marquee.Mode = flags.contains(.command) ? .toggle : flags.contains(.shift) ? .add : .replace
        marquee = Marquee(start: point, originalSelection: selectedIDs, primary: primaryID, mode: mode, end: point)
    }
    private func updateMarquee(with event: NSEvent) {
        guard interactionEnabled, var marquee else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Dragging outside the preview selects only within the actual canvas.
        let clamped = CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)), y: min(bounds.maxY, max(bounds.minY, point.y)))
        let start = viewPoint(marquee.start)
        if !marquee.began && hypot(point.x - start.x, point.y - start.y) < 3 { return }
        marquee.began = true; marquee.end = scenePoint(clamped); self.marquee = marquee
        updateAccessibility(); needsDisplay = true
    }
    private func marqueeSelection(_ marquee: Marquee) -> Set<UUID> {
        let hits = Item.intersecting(marquee.rectangle, in: items)
        let result: Set<UUID>
        switch marquee.mode {
        case .replace: result = hits
        case .add: result = marquee.originalSelection.union(hits)
        case .toggle: result = marquee.originalSelection.symmetricDifference(hits)
        }
        // The inspector requires a primary layer; an empty gesture preserves it.
        return result.isEmpty ? marquee.originalSelection : result
    }
}
