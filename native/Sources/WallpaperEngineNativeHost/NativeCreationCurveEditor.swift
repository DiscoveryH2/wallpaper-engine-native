import AppKit

@MainActor
final class NativeCreationCurveEditor: NSWindowController, NSTextFieldDelegate {
    private let graph = NativeCreationCurveGraph(frame: NSRect(x: 24, y: 206, width: 552, height: 260))
    private var fields: [NSTextField] = []
    private let message = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "应用曲线", target: nil, action: nil)
    private let presets = NSPopUpButton(frame: NSRect(x: 24, y: 104, width: 230, height: 26))
    private let choices: [(String, NativeCreationBezier)] = [
        ("自定义", .standard), ("标准缓动", .standard), ("逐渐加速", .easeIn),
        ("逐渐减速", .easeOut), ("先慢后快再慢", .easeInOut), ("匀速", .linear), ("平滑起止", .smooth)
    ]
    private var result: NativeCreationBezier?

    init(curve: NativeCreationBezier, scope: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 565), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "动画曲线"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        guard let content = panel.contentView else { return }
        let heading = NSTextField(labelWithString: "调整到下一关键帧的速度")
        heading.frame = NSRect(x: 24, y: 522, width: 552, height: 24)
        heading.font = .systemFont(ofSize: 18, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: scope + "\n横轴是经过的时间，纵轴是完成的变化；拖动两个圆点或输入 0–1 的控制点数值。")
        note.frame = NSRect(x: 24, y: 474, width: 552, height: 42)
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        content.addSubview(heading); content.addSubview(note); content.addSubview(graph)
        for (index, title) in ["控制点 1 · 时间", "控制点 1 · 变化", "控制点 2 · 时间", "控制点 2 · 变化"].enumerated() {
            let x = 24 + CGFloat(index) * 140
            let label = NSTextField(labelWithString: title); label.frame = NSRect(x: x, y: 178, width: 128, height: 17)
            label.font = .systemFont(ofSize: 11)
            let field = NSTextField(frame: NSRect(x: x, y: 148, width: 128, height: 24))
            field.setAccessibilityLabel(title); field.delegate = self
            fields.append(field); content.addSubview(label); content.addSubview(field)
        }
        presets.addItems(withTitles: choices.map(\.0)); presets.setAccessibilityLabel("动画曲线预设")
        presets.target = self; presets.action = #selector(selectPreset); content.addSubview(presets)
        message.frame = NSRect(x: 24, y: 65, width: 552, height: 32); message.font = .systemFont(ofSize: 11)
        content.addSubview(message)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEdit))
        cancel.frame = NSRect(x: 364, y: 22, width: 92, height: 30); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        applyButton.frame = NSRect(x: 466, y: 22, width: 110, height: 30); applyButton.bezelStyle = .rounded
        applyButton.target = self; applyButton.action = #selector(applyEdit); applyButton.keyEquivalent = "\r"
        content.addSubview(cancel); content.addSubview(applyButton)
        graph.onChange = { [weak self] curve in self?.show(curve) }
        show(curve)
    }
    required init?(coder: NSCoder) { nil }

    func present(on parent: NSWindow, completion: @escaping (NativeCreationBezier?) -> Void) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in completion(self?.result) }
    }
    private func show(_ curve: NativeCreationBezier) {
        graph.curve = curve
        for (field, value) in zip(fields, [curve.x1, curve.y1, curve.x2, curve.y2]) { field.stringValue = String(value) }
        presets.selectItem(at: choices.dropFirst().firstIndex(where: { $0.1 == curve }) ?? 0)
        message.textColor = .secondaryLabelColor
        message.stringValue = "曲线限制在起止值之间。应用后可在画布中预览；取消不会修改动画。"
        applyButton.isEnabled = true
    }
    private func readCurve() -> NativeCreationBezier? {
        let values = fields.compactMap { Double($0.stringValue) }
        guard values.count == 4 else { return nil }
        let curve = NativeCreationBezier(x1: values[0], y1: values[1], x2: values[2], y2: values[3])
        return curve.isValid ? curve : nil
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let curve = readCurve() else {
            message.textColor = .systemRed; message.stringValue = "四个控制点数值都需要是 0–1 之间的有限小数。"
            applyButton.isEnabled = false; return
        }
        graph.curve = curve; presets.selectItem(at: choices.dropFirst().firstIndex(where: { $0.1 == curve }) ?? 0)
        message.textColor = .secondaryLabelColor; message.stringValue = "曲线已更新；点击“应用曲线”后修改当前动画段。"
        applyButton.isEnabled = true
    }
    @objc private func selectPreset() {
        guard presets.indexOfSelectedItem > 0 else { return }
        show(choices[presets.indexOfSelectedItem].1)
    }
    @objc private func applyEdit() {
        guard let curve = readCurve(), let window, let parent = window.sheetParent else { return }
        result = curve; parent.endSheet(window)
    }
    @objc private func cancelEdit() {
        guard let window, let parent = window.sheetParent else { return }
        result = nil; parent.endSheet(window)
    }
}

@MainActor
final class NativeCreationCurveGraph: NSView {
    var curve = NativeCreationBezier.standard { didSet { needsDisplay = true } }
    var onChange: ((NativeCreationBezier) -> Void)?
    private var active = 0
    private var original: NativeCreationBezier?
    private var plot: NSRect { bounds.insetBy(dx: 32, dy: 24) }
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("动画速度曲线；拖动控制点，Tab 切换圆点，方向键微调")
    }
    required init?(coder: NSCoder) { nil }
    private func point(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: plot.minX + x * plot.width, y: plot.minY + y * plot.height) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        for i in 0...4 {
            let f = Double(i) / 4, grid = NSBezierPath()
            grid.move(to: point(f, 0)); grid.line(to: point(f, 1)); grid.move(to: point(0, f)); grid.line(to: point(1, f)); grid.stroke()
        }
        let start = point(0, 0), end = point(1, 1), a = point(curve.x1, curve.y1), b = point(curve.x2, curve.y2)
        let guides = NSBezierPath(); guides.move(to: start); guides.line(to: a); guides.move(to: end); guides.line(to: b)
        NSColor.secondaryLabelColor.setStroke(); guides.stroke()
        let path = NSBezierPath(); path.move(to: start); path.curve(to: end, controlPoint1: a, controlPoint2: b)
        path.lineWidth = 3; NSColor.controlAccentColor.setStroke(); path.stroke()
        for (index, p) in [a, b].enumerated() {
            let shape = NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            (index == 0 ? NSColor.controlAccentColor : NSColor.systemOrange).setFill(); shape.fill()
            if window?.firstResponder === self && active == index { NSColor.labelColor.setStroke(); shape.lineWidth = 2; shape.stroke() }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        ("0" as NSString).draw(at: NSPoint(x: plot.minX - 12, y: plot.minY - 16), withAttributes: attributes)
        ("1" as NSString).draw(at: NSPoint(x: plot.maxX - 3, y: plot.minY - 16), withAttributes: attributes)
        ("变化 1" as NSString).draw(at: NSPoint(x: 3, y: plot.maxY + 4), withAttributes: attributes)
        ("时间 →" as NSString).draw(at: NSPoint(x: plot.midX - 18, y: 3), withAttributes: attributes)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let controls = [point(curve.x1, curve.y1), point(curve.x2, curve.y2)]
        guard let nearest = controls.indices.min(by: { hypot(p.x - controls[$0].x, p.y - controls[$0].y) < hypot(p.x - controls[$1].x, p.y - controls[$1].y) }),
              hypot(p.x - controls[nearest].x, p.y - controls[nearest].y) <= 16 else { return }
        active = nearest; original = curve; window?.makeFirstResponder(self); needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard original != nil else { return }
        let p = convert(event.locationInWindow, from: nil)
        change(x: Double((p.x - plot.minX) / plot.width), y: Double((p.y - plot.minY) / plot.height))
    }
    override func mouseUp(with event: NSEvent) { original = nil }
    private func change(x: Double, y: Double) {
        let x = min(1, max(0, x)), y = min(1, max(0, y))
        if active == 0 { curve.x1 = x; curve.y1 = y } else { curve.x2 = x; curve.y2 = y }
        onChange?(curve)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let original { self.original = nil; curve = original; onChange?(curve); return }
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                if active == 1 { active = 0 } else { window?.selectPreviousKeyView(self) }
            } else {
                if active == 0 { active = 1 } else { window?.selectNextKeyView(self) }
            }
            needsDisplay = true; return
        }
        guard [123, 124, 125, 126].contains(event.keyCode) else { super.keyDown(with: event); return }
        var x = active == 0 ? curve.x1 : curve.x2, y = active == 0 ? curve.y1 : curve.y2
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        if event.keyCode == 123 { x -= step }; if event.keyCode == 124 { x += step }
        if event.keyCode == 125 { y -= step }; if event.keyCode == 126 { y += step }
        change(x: x, y: y)
    }
}
