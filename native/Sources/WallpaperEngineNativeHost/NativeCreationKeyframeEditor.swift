import AppKit

@MainActor
final class NativeCreationKeyframeEditor: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let sourceDocument: NativeCreationDocument
    private let layerID: UUID
    private let properties: [NativeCreationProperty]
    private let tracks: [NativeCreationTrack]
    private let availableFrames: [Int]
    private let sourceTimes = NSTableView()
    private let scopeNote = NSTextField(wrappingLabelWithString: "")
    private var rebuildingSelection = true
    private var sourceFrames: [Int] { sourceTimes.selectedRowIndexes.compactMap { availableFrames.indices.contains($0) ? availableFrames[$0] : nil } }
    private let graph: NativeCreationKeyframeGraph
    private let timeField = NSTextField(string: "")
    private let operation = NSPopUpButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let applyButton = NSButton(title: "移动关键帧", target: nil, action: nil)
    private var result: NativeCreationKeyframeEdit?

    init(document: NativeCreationDocument, layerIndex: Int, sourceFrame: Int, properties: [NativeCreationProperty]) {
        self.sourceDocument = document; layerID = document.layers[layerIndex].id
        self.properties = properties
        tracks = document.layers[layerIndex].animationTracks
        availableFrames = Set(tracks.filter { properties.contains($0.property) }.flatMap { $0.keys.map(\.frame) }).sorted()
        graph = NativeCreationKeyframeGraph(tracks: tracks, properties: properties, sourceFrame: sourceFrame,
                                            endFrame: Int((document.duration * NativeCreationMotion.fps).rounded()))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "调整关键帧时间"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        guard let content = panel.contentView else { return }
        let heading = NSTextField(labelWithString: "安排动画的时间")
        heading.frame = NSRect(x: 24, y: 518, width: 952, height: 24); heading.font = .systemFont(ofSize: 18, weight: .semibold)
        scopeNote.frame = NSRect(x: 24, y: 460, width: 952, height: 50); scopeNote.font = .systemFont(ofSize: 12); scopeNote.textColor = .secondaryLabelColor
        content.addSubview(heading); content.addSubview(scopeNote)
        let sourceLabel = NSTextField(labelWithString: "选择原时间点")
        sourceLabel.frame = NSRect(x: 24, y: 430, width: 206, height: 18); sourceLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        content.addSubview(sourceLabel)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time")); column.width = 188
        sourceTimes.addTableColumn(column); sourceTimes.headerView = nil; sourceTimes.rowHeight = 26
        sourceTimes.allowsMultipleSelection = true; sourceTimes.allowsEmptySelection = false
        sourceTimes.setAccessibilityLabel("原关键帧时间点；Shift 连选，Command 多选")
        sourceTimes.dataSource = self; sourceTimes.delegate = self
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 174, width: 206, height: 248))
        scroll.documentView = sourceTimes; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        content.addSubview(scroll)
        let selectionHint = NSTextField(wrappingLabelWithString: "Shift 连选，Command 多选。\n每一行包含该时刻所选轨道的关键帧。")
        selectionHint.frame = NSRect(x: 24, y: 128, width: 206, height: 40); selectionHint.font = .systemFont(ofSize: 11); selectionHint.textColor = .secondaryLabelColor
        content.addSubview(selectionHint)
        graph.frame = NSRect(x: 246, y: 174, width: 730, height: 272); content.addSubview(graph)
        operation.addItems(withTitles: NativeCreationKeyframeEdit.Mode.allCases.map(\.title))
        operation.frame = NSRect(x: 246, y: 126, width: 110, height: 26)
        operation.setAccessibilityLabel("关键帧操作"); operation.target = self; operation.action = #selector(changeOperation)
        let label = NSTextField(labelWithString: "首个目标时间（秒）"); label.frame = NSRect(x: 378, y: 130, width: 140, height: 18)
        timeField.frame = NSRect(x: 524, y: 128, width: 110, height: 24)
        timeField.setAccessibilityLabel("首个关键帧目标时间（秒）"); timeField.delegate = self
        timeField.stringValue = String(Double(sourceFrame) / 60)
        content.addSubview(operation); content.addSubview(label); content.addSubview(timeField)
        let precision = NSTextField(wrappingLabelWithString: "按 1/60 秒对齐，保持整组间隔。\n方向键微调，Shift 为 10 帧。")
        precision.frame = NSRect(x: 650, y: 124, width: 326, height: 32); precision.font = .systemFont(ofSize: 11); precision.textColor = .secondaryLabelColor
        content.addSubview(precision)
        message.frame = NSRect(x: 24, y: 58, width: 952, height: 54); message.font = .systemFont(ofSize: 12)
        content.addSubview(message)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEdit))
        cancel.frame = NSRect(x: 740, y: 22, width: 96, height: 30); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        applyButton.frame = NSRect(x: 848, y: 22, width: 128, height: 30); applyButton.bezelStyle = .rounded
        applyButton.target = self; applyButton.action = #selector(applyEdit); applyButton.keyEquivalent = "\r"
        content.addSubview(cancel); content.addSubview(applyButton)
        graph.onChange = { [weak self] frame in
            guard let self else { return }
            self.timeField.stringValue = String(Double(frame) / 60)
            self.validateEdit()
        }
        // Keep keyboard navigation predictable instead of trapping focus in
        // the custom graph. The numeric field is an equivalent input path.
        sourceTimes.nextKeyView = graph; graph.nextKeyView = operation; operation.nextKeyView = timeField
        timeField.nextKeyView = cancel; cancel.nextKeyView = applyButton; applyButton.nextKeyView = sourceTimes
        sourceTimes.reloadData()
        if let index = availableFrames.firstIndex(of: sourceFrame) { sourceTimes.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        rebuildingSelection = false; refreshSelection()
    }
    required init?(coder: NSCoder) { nil }

    func numberOfRows(in tableView: NSTableView) -> Int { availableFrames.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard availableFrames.indices.contains(row) else { return nil }
        let frame = availableFrames[row]
        let count = tracks.filter { properties.contains($0.property) && $0.keys.contains { $0.frame == frame } }.count
        let text = String(format: "%.3f 秒 · %d 个关键帧", Double(frame) / 60, count)
        let label = NSTextField(labelWithString: text); label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byTruncatingTail; label.toolTip = text; label.setAccessibilityLabel(text)
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !rebuildingSelection { refreshSelection() }
    }
    private func refreshSelection() {
        let offset = graph.targetFrame - (graph.sourceFrames.first ?? 0)
        let frames = sourceFrames
        graph.sourceFrames = frames
        timeField.stringValue = String(Double((frames.first ?? 0) + offset) / 60)
        let count = tracks.filter { properties.contains($0.property) }.reduce(0) { $0 + $1.keys.filter { frames.contains($0.frame) }.count }
        scopeNote.stringValue = String(format: "已选 %d 个时间点 · %d 个关键帧 · 原范围 %.3f–%.3f 秒", frames.count, count, Double(frames.first ?? 0) / 60, Double(frames.last ?? 0) / 60)
            + "\n蓝色为原位置，橙色为目标。点击或拖动时间图设置首个目标时间；整组间隔、数值和到下一帧的曲线一起保留。"
        validateEdit()
    }

    func present(on parent: NSWindow, completion: @escaping (NativeCreationKeyframeEdit?) -> Void) {
        guard let window else { return }
        parent.beginSheet(window) { [weak self] _ in completion(self?.result) }
    }
    private func readEdit() throws -> NativeCreationKeyframeEdit {
        guard let seconds = Double(timeField.stringValue) else { throw SceneError.invalid("请填写有效的目标时间。") }
        let frame = try NativeCreationKeyframeEdit.frame(seconds: seconds, duration: sourceDocument.duration)
        guard !sourceFrames.isEmpty else { throw SceneError.invalid("请至少选择一个原时间点。") }
        return NativeCreationKeyframeEdit(sourceFrames: sourceFrames, destinationFrame: frame, properties: properties,
                                          mode: operation.indexOfSelectedItem == 1 ? .copy : .move)
    }
    private func validateEdit() {
        applyButton.title = operation.indexOfSelectedItem == 1 ? "复制关键帧" : "移动关键帧"
        do {
            let edit = try readEdit()
            graph.targetFrame = edit.destinationFrame
            if edit.destinationFrame == edit.sourceFrame {
                graph.targetValid = false; applyButton.isEnabled = false; message.textColor = .secondaryLabelColor
                message.stringValue = "请选择新的目标时间；已有关键帧与曲线会保留。"
                return
            }
            _ = try edit.applying(to: sourceDocument, layerID: layerID)
            graph.targetValid = true; applyButton.isEnabled = true; message.textColor = .secondaryLabelColor
            let last = edit.destinationFrame + (edit.sourceFrames.last! - edit.sourceFrame)
            message.stringValue = String(format: "目标范围 %.6f–%.6f 秒 · %d 个时间点，间隔不变。%@后在画布预览；取消不修改作品。", Double(edit.destinationFrame) / 60, Double(last) / 60, edit.sourceFrames.count, edit.mode.title)
        } catch {
            graph.targetValid = false; applyButton.isEnabled = false; message.textColor = .systemRed
            message.stringValue = error.localizedDescription
        }
    }
    func controlTextDidChange(_ notification: Notification) { validateEdit() }
    @objc private func changeOperation() { validateEdit() }
    @objc private func applyEdit() {
        do {
            let edit = try readEdit()
            _ = try edit.applying(to: sourceDocument, layerID: layerID)
            guard let window, let parent = window.sheetParent else { return }
            result = edit; parent.endSheet(window)
        } catch { validateEdit() }
    }
    @objc private func cancelEdit() {
        guard let window, let parent = window.sheetParent else { return }
        result = nil; parent.endSheet(window)
    }
}

@MainActor
final class NativeCreationKeyframeGraph: NSView {
    private let tracks: [NativeCreationTrack]
    private let properties: [NativeCreationProperty]
    var sourceFrames: [Int] { didSet { refreshAccessibility(); needsDisplay = true } }
    private var sourceFrame: Int { sourceFrames.first ?? 0 }
    private var lastTargetFrame: Int { max(0, endFrame - ((sourceFrames.last ?? 0) - sourceFrame)) }
    private let endFrame: Int
    var targetFrame: Int { didSet { refreshAccessibility(); needsDisplay = true } }
    var targetValid = false { didSet { needsDisplay = true } }
    var onChange: ((Int) -> Void)?
    private var dragStart: Int?
    private var plot: NSRect { NSRect(x: 110, y: 30, width: max(1, bounds.width - 136), height: max(1, bounds.height - 46)) }
    override var acceptsFirstResponder: Bool { true }

    init(tracks: [NativeCreationTrack], properties: [NativeCreationProperty], sourceFrame: Int, endFrame: Int) {
        self.tracks = tracks; self.properties = properties; self.sourceFrames = [sourceFrame]
        self.endFrame = endFrame; targetFrame = sourceFrame
        super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("关键帧时间图；点击或左右拖动设置整组首个目标时间，方向键微调，Tab 离开")
        refreshAccessibility()
    }
    required init?(coder: NSCoder) { nil }
    private func refreshAccessibility() {
        setAccessibilityValue(String(format: "已选 %d 个时间点，原首帧 %.6f 秒，目标首帧 %.6f 秒，第 %d 帧", sourceFrames.count, Double(sourceFrame) / 60, Double(targetFrame) / 60, targetFrame))
    }
    private func x(_ frame: Int) -> CGFloat { plot.minX + CGFloat(frame) / CGFloat(max(1, endFrame)) * plot.width }
    private func y(_ row: Int) -> CGFloat { plot.maxY - (CGFloat(row) + 0.5) * plot.height / CGFloat(NativeCreationProperty.allCases.count) }
    private func diamond(_ center: NSPoint, radius: CGFloat = 5) -> NSBezierPath {
        let path = NSBezierPath(); path.move(to: NSPoint(x: center.x, y: center.y + radius))
        path.line(to: NSPoint(x: center.x + radius, y: center.y)); path.line(to: NSPoint(x: center.x, y: center.y - radius))
        path.line(to: NSPoint(x: center.x - radius, y: center.y)); path.close(); return path
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.secondaryLabelColor]
        for index in 0...4 {
            let position = plot.minX + CGFloat(index) * plot.width / 4
            let line = NSBezierPath(); line.move(to: NSPoint(x: position, y: plot.minY)); line.line(to: NSPoint(x: position, y: plot.maxY))
            NSColor.separatorColor.setStroke(); line.stroke()
            let label = String(format: "%.2f", Double(endFrame) / 60 * Double(index) / 4) as NSString
            let width = label.size(withAttributes: attributes).width
            label.draw(at: NSPoint(x: position - width / 2, y: 10), withAttributes: attributes)
        }
        for (row, property) in NativeCreationProperty.allCases.enumerated() {
            let selected = properties.contains(property)
            let labelAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular), .foregroundColor: selected ? NSColor.labelColor : .secondaryLabelColor]
            (property.title as NSString).draw(at: NSPoint(x: 12, y: y(row) - 7), withAttributes: labelAttributes)
            let line = NSBezierPath(); line.move(to: NSPoint(x: plot.minX, y: y(row))); line.line(to: NSPoint(x: plot.maxX, y: y(row)))
            NSColor.separatorColor.setStroke(); line.stroke()
            for key in tracks.first(where: { $0.property == property })?.keys ?? [] {
                let source = selected && sourceFrames.contains(key.frame)
                (source ? NSColor.controlAccentColor : NSColor.secondaryLabelColor.withAlphaComponent(0.6)).setFill()
                let shape = diamond(NSPoint(x: x(key.frame), y: y(row)), radius: source ? 6 : 4); shape.fill()
            }
            if selected && targetFrame != sourceFrame {
                for key in tracks.first(where: { $0.property == property })?.keys ?? [] where sourceFrames.contains(key.frame) {
                    let destination = key.frame + targetFrame - sourceFrame
                    if (0...endFrame).contains(destination) {
                        let shape = diamond(NSPoint(x: x(destination), y: y(row)), radius: 7)
                        (targetValid ? NSColor.systemOrange : NSColor.systemRed).setStroke(); shape.lineWidth = 2; shape.stroke()
                    }
                }
            }
        }
        if targetFrame != sourceFrame {
            let cursor = NSBezierPath(); cursor.move(to: NSPoint(x: x(targetFrame), y: plot.minY)); cursor.line(to: NSPoint(x: x(targetFrame), y: plot.maxY))
            cursor.setLineDash([3, 3], count: 2, phase: 0)
            (targetValid ? NSColor.systemOrange : NSColor.systemRed).withAlphaComponent(0.7).setStroke(); cursor.stroke()
        }
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7); border.lineWidth = 2; border.stroke()
        }
    }
    private func change(_ frame: Int) {
        targetFrame = min(lastTargetFrame, max(0, frame)); onChange?(targetFrame)
    }
    private func position(_ event: NSEvent) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        let fraction = min(1, max(0, (point.x - plot.minX) / plot.width))
        return Int((fraction * CGFloat(endFrame)).rounded())
    }
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard plot.insetBy(dx: -10, dy: -5).contains(point) else { return }
        dragStart = targetFrame; window?.makeFirstResponder(self); change(position(event))
    }
    override func mouseDragged(with event: NSEvent) { if dragStart != nil { change(position(event)) } }
    override func mouseUp(with event: NSEvent) { dragStart = nil }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let original = dragStart { dragStart = nil; change(original); return }
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            needsDisplay = true; return
        }
        let step = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123: change(targetFrame - step)
        case 124: change(targetFrame + step)
        case 115: change(0)
        case 119: change(endFrame)
        default: super.keyDown(with: event)
        }
    }
}
