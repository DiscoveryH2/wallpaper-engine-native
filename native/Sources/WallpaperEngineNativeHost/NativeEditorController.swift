import AppKit
import UniformTypeIdentifiers

@MainActor
final class NativeEditorController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var onSaved: (() -> Void)?
    var onApply: ((URL) -> Void)?
    private var composition = NativeCreationDocument.starter()
    private var images: [UUID: NativeCreationImage] = [:]
    private var record: NativeCreationStore.Record?
    private var restoreOnPresent: NativeCreationStore.Record?
    private var records: [NativeCreationStore.Record] = []
    private let historyButton = NSButton(title: "历史版本…", target: nil, action: nil)
    private var historyEditor: NativeCreationHistoryEditor?
    private struct History {
        let document: NativeCreationDocument
        let selection: Set<UUID>
        let primary: UUID
    }
    private var undoHistory: [History] = []
    private var redoHistory: [History] = []
    private var dirty = false { didSet { window?.isDocumentEdited = dirty } }
    private var busy = false
    private var importing = false
    private var importGeneration = 0
    private var rebuilding = false
    private var selected = 2
    private var selectionIDs: Set<UUID> = []
    private let selectionSummary = NSTextField(wrappingLabelWithString: "")
    private var snapshot: NativeCreationStore.Snapshot?
    private var renderer: NativeSceneRendering?
    private var renderedDocument: NativeCreationDocument?
    private let canvas = NativeEditorCanvas(frame: .zero)
    private var canvasOriginal: NativeCreationDocument?
    private var canvasDraft: NativeCreationDocument?
    private var canvasLayerIDs: Set<UUID> = []
    private var aspect: NSLayoutConstraint?
    private let titleField = NSTextField(string: "")
    private let canvasWidth = NSTextField(string: "1920")
    private let canvasHeight = NSTextField(string: "1080")
    private let chooser = NSPopUpButton()
    private let table = NSTableView()
    private let previewHost = NSView()
    private let previewFrame = NSView()
    private let status = NSTextField(wrappingLabelWithString: "编辑图层后点击“更新预览”。预览使用实际 Scene 引擎。")
    private let visibility = NSButton(checkboxWithTitle: "显示图层", target: nil, action: nil)
    private let lockSelectionButton = NSButton(title: "锁定所选", target: nil, action: nil)
    private let unlockSelectionButton = NSButton(title: "解锁所选", target: nil, action: nil)
    private var fields: [String: NSTextField] = [:]
    private var controls: [NSControl] = []
    private let undoButton = NSButton(title: "撤销", target: nil, action: nil)
    private let redoButton = NSButton(title: "重做", target: nil, action: nil)
    private let pauseButton = NSButton(title: "暂停预览", target: nil, action: nil)
    private let marqueeButton = NSButton(checkboxWithTitle: "框选", target: nil, action: nil)
    private let thumbnailButton = NSButton(title: "更新作品预览图", target: nil, action: nil)
    private var previewPaused = true
    private var timer: Timer?
    private let clock = NSTextField(labelWithString: "")
    private let durationField = NSTextField(string: "8")
    private let loopButton = NSButton(checkboxWithTitle: "循环播放", target: nil, action: nil)
    private let timeField = NSTextField(string: "0.00")
    private let timeSlider = NSSlider(value: 0, minValue: 0, maxValue: 480, target: nil, action: nil)
    private let keyTable = NSTableView()
    private let trackPicker = NSPopUpButton()
    private var activeTrackIndex = 0
    private let interpolation = NSPopUpButton()
    private let curveButton = NSButton(title: "编辑曲线…", target: nil, action: nil)
    private var curveEditor: NativeCreationCurveEditor?
    private let timingButton = NSButton(title: "调整时间…", target: nil, action: nil)
    private var timingEditor: NativeCreationKeyframeEditor?
    private var mixedInterpolationIndex: Int { NativeCreationKeyframe.Interpolation.allCases.count }
    private let recordKeyButton = NSButton(title: "记录关键帧", target: nil, action: nil)
    private let deleteKeyButton = NSButton(title: "删除关键帧", target: nil, action: nil)
    private let timelineNote = NSTextField(wrappingLabelWithString: "")
    private var playheadFrame = 0
    private var displayedPose: NativeCreationPose?
    private var endFrame: Int { Int((composition.duration * NativeCreationMotion.fps).rounded()) }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1340, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wallpaper Engine Native · 壁纸编辑器"
        window.minSize = NSSize(width: 1180, height: 830)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        refreshFields()
        window.center()
    }
    required init?(coder: NSCoder) { nil }

    private func button(_ title: String, _ selector: Selector) -> NSButton {
        let value = NSButton(title: title, target: self, action: selector)
        value.bezelStyle = .rounded; controls.append(value); return value
    }
    private func field(_ key: String, label: String) -> [NSView] {
        let value = NSTextField(string: "")
        value.setAccessibilityLabel(label); value.delegate = self
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fields[key] = value; controls.append(value)
        return [NSTextField(labelWithString: label), value]
    }
    private func stack(_ views: [NSView], vertical: Bool = false) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = vertical ? .vertical : .horizontal
        result.alignment = vertical ? .leading : .centerY
        result.spacing = 8; result.translatesAutoresizingMaskIntoConstraints = false
        return result
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        titleField.setAccessibilityLabel("作品名称"); titleField.delegate = self
        canvasWidth.setAccessibilityLabel("画布宽度"); canvasWidth.delegate = self
        canvasHeight.setAccessibilityLabel("画布高度"); canvasHeight.delegate = self
        controls += [titleField, canvasWidth, canvasHeight, chooser, visibility, undoButton, redoButton, pauseButton]
        chooser.target = self; chooser.action = #selector(openChosen)
        chooser.setAccessibilityLabel("打开已保存作品")
        let top = stack([button("新建作品", #selector(newDocument)), button("导入作品…", #selector(chooseArchive)), chooser, NSTextField(labelWithString: "名称"), titleField,
                         NSTextField(labelWithString: "画布"), canvasWidth, NSTextField(labelWithString: "×"), canvasHeight])
        chooser.widthAnchor.constraint(equalToConstant: 210).isActive = true
        titleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        canvasWidth.widthAnchor.constraint(equalToConstant: 68).isActive = true
        canvasHeight.widthAnchor.constraint(equalToConstant: 68).isActive = true
        let column = NSTableColumn(identifier: .init("layer")); column.title = "图层（前景在上）"; column.width = 180
        table.addTableColumn(column); table.dataSource = self; table.delegate = self; table.rowHeight = 30
        table.allowsEmptySelection = false; table.allowsMultipleSelection = true; table.setAccessibilityLabel("作品图层")
        table.toolTip = "Command 点击增减选择，Shift 点击选择连续图层。上移、下移和删除作用于全部所选图层。"
        let layerScroll = NSScrollView(); layerScroll.documentView = table; layerScroll.hasVerticalScroller = true
        let adds = stack([button("图片…", #selector(addImage)), button("文字", #selector(addText)), button("色块", #selector(addSolid))])
        let order = stack([button("上移", #selector(raiseLayer)), button("下移", #selector(lowerLayer)), button("删除", #selector(removeLayer))])
        lockSelectionButton.target = self; lockSelectionButton.action = #selector(lockSelection)
        unlockSelectionButton.target = self; unlockSelectionButton.action = #selector(unlockSelection)
        for control in [lockSelectionButton, unlockSelectionButton] {
            control.bezelStyle = .rounded; controls.append(control)
        }
        lockSelectionButton.toolTip = "保护所选图层的属性、关键帧和图层操作；画布点击会跳过它们。"
        unlockSelectionButton.toolTip = "锁定图层仍可在列表中选择，解锁后可继续编辑。"
        let locks = stack([lockSelectionButton, unlockSelectionButton])
        let left = stack([NSTextField(labelWithString: "图层"), layerScroll, adds, order, locks], vertical: true)
        left.widthAnchor.constraint(equalToConstant: 220).isActive = true
        layerScroll.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true
        layerScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        previewFrame.wantsLayer = true; previewFrame.layer?.backgroundColor = NSColor.black.cgColor
        previewFrame.translatesAutoresizingMaskIntoConstraints = false
        previewHost.addSubview(previewFrame)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        previewFrame.addSubview(canvas)
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: previewFrame.leadingAnchor), canvas.trailingAnchor.constraint(equalTo: previewFrame.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: previewFrame.topAnchor), canvas.bottomAnchor.constraint(equalTo: previewFrame.bottomAnchor),
            previewFrame.centerXAnchor.constraint(equalTo: previewHost.centerXAnchor),
            previewFrame.centerYAnchor.constraint(equalTo: previewHost.centerYAnchor),
            previewFrame.widthAnchor.constraint(lessThanOrEqualTo: previewHost.widthAnchor),
            previewFrame.heightAnchor.constraint(lessThanOrEqualTo: previewHost.heightAnchor)
        ])
        // Fitting the preview must yield to the user's window size. A high
        // priority makes AppKit grow the content past the visible window.
        let preferredWidth = previewFrame.widthAnchor.constraint(equalTo: previewHost.widthAnchor); preferredWidth.priority = .defaultLow; preferredWidth.isActive = true
        clock.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); clock.textColor = .secondaryLabelColor
        pauseButton.target = self; pauseButton.action = #selector(togglePreviewPause); pauseButton.bezelStyle = .rounded
        marqueeButton.target = self; marqueeButton.action = #selector(toggleMarqueeMode)
        marqueeButton.toolTip = "从任意位置拖出选框；触及图层即选中。Shift 追加、Command 切换选择，Esc 取消；跳过锁定、隐藏和透明图层。关闭后可继续拖动图层。"
        canvas.prepareInteraction = { [weak self] in self?.prepareCanvasInteraction() ?? false }
        canvas.onSelect = { [weak self] ids, primary in self?.selectCanvasLayers(ids, primary: primary) }
        canvas.onBegin = { [weak self] ids in self?.beginCanvasChange(ids) ?? false }
        canvas.onChange = { [weak self] poses in self?.changeCanvasLayers(poses) ?? false }
        canvas.onFinish = { [weak self] commit in self?.finishCanvasChange(commit: commit) }
        canvas.onUndo = { [weak self] in self?.undoChange() }
        canvas.onRedo = { [weak self] in self?.redoChange() }
        canvas.onDelete = { [weak self] in self?.removeLayer() }
        let canvasHint = NSTextField(wrappingLabelWithString: "空白处拖动框选；开启“框选”可从任意位置开始。Shift 追加、Command 切换，空框保留原选择。关闭框选后拖动移动，角点缩放；Esc 取消。")
        canvasHint.font = .systemFont(ofSize: 11); canvasHint.textColor = .secondaryLabelColor
        let timeline = buildTimeline()
        let center = stack([NSTextField(labelWithString: "画布预览"), previewHost, canvasHint, stack([marqueeButton, pauseButton, clock]), timeline], vertical: true)
        canvasHint.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        timeline.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        previewHost.widthAnchor.constraint(equalTo: center.widthAnchor).isActive = true
        previewHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        center.widthAnchor.constraint(greaterThanOrEqualToConstant: 350).isActive = true
        let grid = NSGridView(views: [
            field("name", label: "图层名称"), field("x", label: "X 位置"), field("y", label: "Y 位置"),
            field("width", label: "宽度"), field("height", label: "高度"), field("rotation", label: "旋转（度）"),
            field("scaleX", label: "横向缩放"), field("scaleY", label: "纵向缩放"),
            field("opacity", label: "透明度 0–1"), field("color", label: "颜色 HEX"),
            field("text", label: "文字内容"), field("fontSize", label: "字号"),
            field("swing", label: "摆动幅度（度）"), field("period", label: "摆动周期（秒）")
        ])
        grid.rowSpacing = 8; grid.columnSpacing = 8
        for index in 0..<grid.numberOfRows { grid.row(at: index).height = 24 }
        visibility.target = self; visibility.action = #selector(visibilityChanged)
        let note = NSTextField(wrappingLabelWithString: "暂停后编辑。原点在左下角；文字高度自动。已有动画的属性修改后会记录当前时刻；其他属性仍修改基础值。选择时间轴轨道可单独记录、删除或设置过渡。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        selectionSummary.font = .systemFont(ofSize: 11); selectionSummary.textColor = .secondaryLabelColor
        let inspector = stack([NSTextField(labelWithString: "图层属性"), selectionSummary, visibility, grid, note, button("更新预览", #selector(updatePreview))], vertical: true)
        inspector.widthAnchor.constraint(equalToConstant: 285).isActive = true
        grid.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        note.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        selectionSummary.widthAnchor.constraint(equalTo: inspector.widthAnchor).isActive = true
        let body = stack([left, center, inspector]); body.alignment = NSLayoutConstraint.Attribute.top; body.spacing = 18; body.distribution = .fill
        left.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        center.heightAnchor.constraint(equalTo: body.heightAnchor).isActive = true
        undoButton.target = self; undoButton.action = #selector(undoChange); undoButton.bezelStyle = .rounded
        redoButton.target = self; redoButton.action = #selector(redoChange); redoButton.bezelStyle = .rounded
        thumbnailButton.target = self; thumbnailButton.action = #selector(saveThumbnail); thumbnailButton.bezelStyle = .rounded
        thumbnailButton.toolTip = "将当前时刻设为壁纸库预览图，同时保存当前修改。"
        controls.append(thumbnailButton)
        historyButton.target = self; historyButton.action = #selector(openVersionHistory); historyButton.bezelStyle = .rounded
        historyButton.toolTip = "选择旧内容先预览，保存时生成新版本。"
        controls.append(historyButton)
        let bottom = stack([undoButton, redoButton, historyButton, button("导出作品…", #selector(exportArchive)), thumbnailButton, button("另存副本…", #selector(saveCopy)),
                            button("保存作品", #selector(saveDocument)), button("保存并设为默认壁纸", #selector(saveAndApply))])
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        for view in [top, body, status, bottom] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), top.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20), top.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 18), body.leadingAnchor.constraint(equalTo: top.leadingAnchor), body.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -14), status.leadingAnchor.constraint(equalTo: top.leadingAnchor), status.trailingAnchor.constraint(equalTo: top.trailingAnchor), status.heightAnchor.constraint(equalToConstant: 38),
            status.bottomAnchor.constraint(equalTo: bottom.topAnchor, constant: -10), bottom.trailingAnchor.constraint(equalTo: top.trailingAnchor), bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
    }

    private func buildTimeline() -> NSStackView {
        durationField.setAccessibilityLabel("动画时长（秒）"); durationField.delegate = self
        durationField.widthAnchor.constraint(equalToConstant: 55).isActive = true
        loopButton.target = self; loopButton.action = #selector(updatePreview)
        timeField.setAccessibilityLabel("时间轴位置（秒）"); timeField.delegate = self
        timeField.target = self; timeField.action = #selector(seekTypedTime)
        // Leaving this field must not replay a stale time after playback has
        // started. Return explicitly seeks; the slider remains live as well.
        timeField.cell?.sendsActionOnEndEditing = false
        timeField.toolTip = "输入秒数后按 Return 定位；也可拖动时间轴滑块。"
        timeField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        timeSlider.setAccessibilityLabel("时间轴帧位置"); timeSlider.isContinuous = true
        timeSlider.target = self; timeSlider.action = #selector(scrubTimeline)
        interpolation.addItems(withTitles: NativeCreationKeyframe.Interpolation.allCases.map(\.title))
        interpolation.addItem(withTitle: "各轨道过渡不同")
        interpolation.item(at: mixedInterpolationIndex)?.isEnabled = false
        interpolation.selectItem(at: 1); interpolation.setAccessibilityLabel("到下一关键帧的过渡")
        interpolation.target = self; interpolation.action = #selector(changeInterpolation)
        recordKeyButton.target = self; recordKeyButton.action = #selector(recordKeyframe); recordKeyButton.bezelStyle = .rounded
        deleteKeyButton.target = self; deleteKeyButton.action = #selector(deleteKeyframe); deleteKeyButton.bezelStyle = .rounded
        trackPicker.addItems(withTitles: ["全部属性"] + NativeCreationProperty.allCases.map(\.title))
        trackPicker.setAccessibilityLabel("动画属性轨道")
        trackPicker.target = self; trackPicker.action = #selector(changeTrack)
        curveButton.target = self; curveButton.action = #selector(editCurve); curveButton.bezelStyle = .rounded
        curveButton.toolTip = "先定位到已有关键帧；编辑它到下一帧的速度曲线。"
        timingButton.target = self; timingButton.action = #selector(editKeyframeTime); timingButton.bezelStyle = .rounded
        timingButton.toolTip = "打开时间图后可用 Shift 或 Command 多选时间点，整体移动或复制；目标冲突时保留原动画。"
        controls += [durationField, loopButton, timeField, timeSlider, trackPicker, interpolation, recordKeyButton, deleteKeyButton, curveButton, timingButton]
        let column = NSTableColumn(identifier: .init("key")); column.title = "所选图层的关键帧"; column.width = 450
        keyTable.addTableColumn(column); keyTable.dataSource = self; keyTable.delegate = self
        keyTable.rowHeight = 24; keyTable.allowsEmptySelection = true; keyTable.setAccessibilityLabel("图层关键帧")
        let scroll = NSScrollView(); scroll.documentView = keyTable; scroll.hasVerticalScroller = true
        scroll.heightAnchor.constraint(equalToConstant: 114).isActive = true
        timelineNote.font = .systemFont(ofSize: 11); timelineNote.textColor = .secondaryLabelColor
        let seek = stack([timeSlider, timeField, NSTextField(labelWithString: "秒")])
        let result = stack([
            stack([NSTextField(labelWithString: "时间轴 · 时长"), durationField, NSTextField(labelWithString: "秒"), loopButton]),
            seek, stack([NSTextField(labelWithString: "动画轨道"), trackPicker, curveButton, timingButton]),
            stack([recordKeyButton, deleteKeyButton, interpolation]), scroll, timelineNote
        ], vertical: true)
        seek.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        timelineNote.widthAnchor.constraint(equalTo: result.widthAnchor).isActive = true
        return result
    }

    func present(project: URL? = nil, archive: URL? = nil) {
        refreshCatalog()
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let requested = project.flatMap { NativeCreationStore.record(for: $0) } ?? restoreOnPresent
        restoreOnPresent = nil
        if let archive { importArchive(archive) }
        else if let requested, let latest = records.first(where: { $0.id == requested.id }), record?.version != latest.version {
            if canLeave() { load(latest) }
        } else if renderer == nil && !busy { render(save: false, apply: false) }
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateTimelineClock() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }

    private func refreshCatalog() {
        records = NativeCreationStore.records().items
        chooser.removeAllItems(); chooser.addItem(withTitle: "打开已有作品…")
        chooser.addItems(withTitles: records.map { $0.title })
    }
    private func normalizeSelection() {
        selected = min(max(0, selected), composition.layers.count - 1)
        selectionIDs.formIntersection(Set(composition.layers.map(\.id)))
        if selectionIDs.isEmpty { selectionIDs = [composition.layers[selected].id] }
        if !selectionIDs.contains(composition.layers[selected].id) {
            selected = composition.layers.lastIndex { selectionIDs.contains($0.id) }!
        }
    }
    private var selectionRows: IndexSet {
        IndexSet(composition.layers.indices.filter { selectionIDs.contains(composition.layers[$0].id) }.map { composition.layers.count - 1 - $0 })
    }
    private var historyState: History {
        History(document: composition, selection: selectionIDs, primary: composition.layers[selected].id)
    }
    private func restore(_ state: History) {
        composition = state.document; selectionIDs = state.selection
        selected = composition.layers.firstIndex { $0.id == state.primary } ?? 0
        normalizeSelection()
    }
    private func refreshFields() {
        rebuilding = true
        titleField.stringValue = composition.title; canvasWidth.stringValue = String(composition.width); canvasHeight.stringValue = String(composition.height)
        normalizeSelection()
        table.reloadData(); table.selectRowIndexes(selectionRows, byExtendingSelection: false)
        selectionSummary.stringValue = selectionIDs.count > 1 ? "已选 \(selectionIDs.count) 个图层。画布可整体移动、等比缩放；列表可批量排序、删除。单独选择一个图层可编辑属性与关键帧。" : "已选 1 个图层。Command 点击可增加选择。"
        let lockedCount = composition.layers.filter { selectionIDs.contains($0.id) && $0.isLocked }.count
        if lockedCount > 0 { selectionSummary.stringValue = "已选 \(selectionIDs.count) 个图层，其中 \(lockedCount) 个已锁定。请在图层列表解锁后修改。" }
        let layer = composition.layers[selected]
        playheadFrame = min(max(0, playheadFrame), endFrame)
        let pose = layer.motion(duration: composition.duration, loop: composition.loop).pose(at: Double(playheadFrame) / 60, preserveEndpoint: true, includeSwing: false)
        let values: [String: String] = ["name": layer.name, "x": readable(pose.x), "y": readable(pose.y), "width": String(layer.width), "height": String(layer.height), "rotation": readable(pose.rotation), "scaleX": readable(pose.scaleX), "scaleY": readable(pose.scaleY), "opacity": readable(pose.opacity), "color": layer.color, "text": layer.text, "fontSize": String(layer.fontSize), "swing": String(layer.swing), "period": String(layer.period)]
        for (key, value) in values { fields[key]?.stringValue = value }
        // Compare edits to the displayed precision, not an unrounded sample.
        // Merely seeking must not create a key or modify stored coordinates.
        displayedPose = try? poseFromFields()
        visibility.state = layer.visible ? .on : .off
        durationField.stringValue = String(composition.duration); loopButton.state = composition.loop ? .on : .off
        timeSlider.maxValue = Double(endFrame); timeSlider.doubleValue = Double(playheadFrame)
        timeField.stringValue = String(format: "%.3f", Double(playheadFrame) / 60)
        let frames = selectedFrames
        let tracks = layer.animationTracks.filter { selectedProperties.contains($0.property) }
        keyTable.reloadData()
        if let index = frames.firstIndex(of: playheadFrame) {
            keyTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let keys = tracks.compactMap { $0.keys.first { $0.frame == playheadFrame } }
            let same = keys.allSatisfy { $0.interpolation == keys.first?.interpolation && $0.curve == keys.first?.curve }
            interpolation.selectItem(at: same ? (NativeCreationKeyframe.Interpolation.allCases.firstIndex(of: keys[0].interpolation) ?? 1) : mixedInterpolationIndex)
        } else {
            keyTable.deselectAll(nil)
            if interpolation.indexOfSelectedItem == mixedInterpolationIndex { interpolation.selectItem(at: 1) }
        }
        let count = tracks.reduce(0) { $0 + $1.keys.count }
        timelineNote.stringValue = count == 0 ? "此轨道尚无关键帧。记录后，在另一个时刻修改并再次记录。" : "\(tracks.count) 条属性轨道 · \(count) 个关键帧 · 点击行定位；记录/删除只作用于所选轨道。"
        if selectionIDs.count > 1 { timelineNote.stringValue = "移动和缩放分别沿用各图层的属性动画；只在已有动画的属性上记录当前时刻。选择一个图层可查看关键帧。" }
        pauseButton.title = previewPaused ? "播放预览" : "暂停预览"
        rebuilding = false; refreshEnabled(); refreshCanvas()
    }
    private func readable(_ number: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), number)
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }
    private func refreshEnabled() {
        let single = selectionIDs.count == 1
        let editable = single && !composition.layers[selected].isLocked
        let hasLocked = composition.layers.contains { selectionIDs.contains($0.id) && $0.isLocked }
        for control in controls { control.isEnabled = !busy }
        table.isEnabled = !busy
        keyTable.isEnabled = !busy && single
        undoButton.isEnabled = !busy && !undoHistory.isEmpty; redoButton.isEnabled = !busy && !redoHistory.isEmpty
        pauseButton.isEnabled = !busy && renderer != nil
        marqueeButton.isEnabled = !busy && previewPaused && renderer != nil
        thumbnailButton.isEnabled = !busy && previewPaused && record != nil
        historyButton.isEnabled = !busy && record != nil
        for control in Array(fields.values) + [titleField, canvasWidth, canvasHeight, durationField] { control.isEnabled = !busy && previewPaused }
        for field in fields.values { field.isEnabled = !busy && previewPaused && editable }
        trackPicker.isEnabled = !busy && single
        visibility.isEnabled = !busy && previewPaused && editable; loopButton.isEnabled = !busy && previewPaused
        interpolation.isEnabled = !busy && previewPaused && editable
        recordKeyButton.isEnabled = !busy && previewPaused && editable && interpolation.indexOfSelectedItem != mixedInterpolationIndex
        curveButton.isEnabled = !busy && previewPaused && editable && !curveProperties.isEmpty
        timingButton.isEnabled = !busy && previewPaused && editable && selectedFrames.contains(playheadFrame)
        deleteKeyButton.isEnabled = !busy && previewPaused && editable && selectedFrames.contains(playheadFrame)
        fields["text"]?.isEnabled = !busy && previewPaused && editable && composition.layers[selected].kind == .text
        fields["fontSize"]?.isEnabled = !busy && previewPaused && editable && composition.layers[selected].kind == .text
        fields["height"]?.isEnabled = !busy && previewPaused && editable && composition.layers[selected].kind != .text
        fields["swing"]?.isEnabled = !busy && previewPaused && editable && !composition.layers[selected].hasAnimation(.rotation)
        fields["period"]?.isEnabled = fields["swing"]?.isEnabled ?? false
        lockSelectionButton.isEnabled = !busy && previewPaused && composition.layers.contains { selectionIDs.contains($0.id) && !$0.isLocked }
        unlockSelectionButton.isEnabled = !busy && previewPaused && hasLocked
        for button in controls.compactMap({ $0 as? NSButton }) {
            if let action = button.action, [#selector(raiseLayer), #selector(lowerLayer), #selector(removeLayer)].contains(action) {
                button.isEnabled = !busy && !hasLocked
            }
        }
        canvas.interactionEnabled = !busy && previewPaused && renderer != nil
    }
    @objc private func toggleMarqueeMode() {
        guard !busy, previewPaused, renderer != nil else { marqueeButton.state = canvas.marqueeMode ? .on : .off; return }
        canvas.marqueeMode = marqueeButton.state == .on
    }

    private func refreshCanvas() {
        guard let renderer, let renderedDocument else {
            canvas.update(size: CGSize(width: composition.width, height: composition.height), items: [], selected: [], primary: nil)
            return
        }
        let time = Double(playheadFrame) / 60
        let items = renderedDocument.layers.enumerated().compactMap { index, layer -> NativeEditorCanvas.Item? in
            guard let bounds = renderer.editorLayerBounds(at: index) else { return nil }
            return NativeEditorCanvas.Item(id: layer.id, name: layer.name, localBounds: bounds,
                                           pose: layer.motion(duration: renderedDocument.duration, loop: renderedDocument.loop).pose(at: time, preserveEndpoint: true),
                                           visible: layer.visible, locked: layer.isLocked)
        }
        canvas.update(size: CGSize(width: renderedDocument.width, height: renderedDocument.height), items: items, selected: selectionIDs, primary: composition.layers[selected].id)
    }
    private func prepareCanvasInteraction() -> Bool {
        guard !busy, previewPaused, renderer != nil, canvasOriginal == nil else { return false }
        do {
            try commitFields()
            if renderedDocument != composition {
                refreshFields(); render(save: false, apply: false)
                return false
            }
            return true
        } catch { showError(error); return false }
    }
    private func selectCanvasLayers(_ ids: Set<UUID>, primary: UUID?) {
        guard !ids.isEmpty, ids.isSubset(of: Set(composition.layers.map(\.id))) else { return }
        selectionIDs = ids
        if let index = composition.layers.firstIndex(where: { $0.id == primary && ids.contains($0.id) }) { selected = index }
        refreshFields()
    }
    private func beginCanvasChange(_ ids: Set<UUID>) -> Bool {
        guard !busy, previewPaused, renderedDocument == composition, canvasOriginal == nil,
              !ids.isEmpty, ids == selectionIDs, ids.isSubset(of: Set(composition.layers.map(\.id))) else { return false }
        guard (try? NativeCreationLayerEditing.requireEditable(ids, in: composition)) != nil else { return false }
        canvasOriginal = composition; canvasDraft = composition; canvasLayerIDs = ids
        return true
    }
    private func canvasMotions(in document: NativeCreationDocument, ids: Set<UUID>) -> [Int: NativeCreationMotion] {
        Dictionary(uniqueKeysWithValues: document.layers.enumerated().compactMap { index, layer in
            ids.contains(layer.id) ? (index, layer.motion(duration: document.duration, loop: document.loop)) : nil
        })
    }
    private func changeCanvasLayers(_ poses: [UUID: NativeCreationPose]) -> Bool {
        guard let original = canvasOriginal, Set(poses.keys) == canvasLayerIDs else { return false }
        do {
            let next = try NativeCreationLayerEditing.applying(poses, to: original, frame: playheadFrame)
            guard renderer?.updateEditorMotions(canvasMotions(in: next, ids: canvasLayerIDs)) == true else {
                throw SceneError.invalid("当前预览无法整体更新图层，请先更新预览。")
            }
            canvasDraft = next
            if canvasLayerIDs.count == 1, let changed = poses[composition.layers[selected].id] {
                for (key, value) in ["x": changed.x, "y": changed.y, "scaleX": changed.scaleX, "scaleY": changed.scaleY] {
                    fields[key]?.stringValue = readable(value)
                }
                displayedPose = try? poseFromFields()
            }
            status.textColor = .secondaryLabelColor
            status.stringValue = "正在调整 \(canvasLayerIDs.count) 个图层；松开整体提交，Esc 取消。"
            return true
        } catch { showError(error); return false }
    }
    private func finishCanvasChange(commit: Bool) {
        guard let original = canvasOriginal, let next = canvasDraft else { return }
        let ids = canvasLayerIDs
        canvasOriginal = nil; canvasDraft = nil; canvasLayerIDs = []
        if commit {
            remember(next); renderedDocument = next
            status.textColor = .secondaryLabelColor
            status.stringValue = next == original ? "所选图层未改变。" : "已调整 \(ids.count) 个图层，可一次撤销。保存作品后保留此更改。"
        } else {
            let restored = renderer?.updateEditorMotions(canvasMotions(in: original, ids: ids)) == true
            status.textColor = .secondaryLabelColor; status.stringValue = "已取消本次画布调整。"
            if !restored { renderedDocument = nil; refreshFields(); render(save: false, apply: false); return }
        }
        refreshFields()
    }
    private var selectedInterpolation: NativeCreationKeyframe.Interpolation {
        let choices = NativeCreationKeyframe.Interpolation.allCases
        return choices.indices.contains(interpolation.indexOfSelectedItem) ? choices[interpolation.indexOfSelectedItem] : .smooth
    }
    private var selectedProperties: [NativeCreationProperty] {
        let index = trackPicker.indexOfSelectedItem - 1
        let values = NativeCreationProperty.allCases
        return values.indices.contains(index) ? [values[index]] : values
    }
    private var selectedFrames: [Int] { selectionIDs.count == 1 ? composition.layers[selected].frames(for: selectedProperties) : [] }
    private var curveProperties: [NativeCreationProperty] {
        guard selectionIDs.count == 1 else { return [] }
        return composition.layers[selected].animationTracks.filter {
            selectedProperties.contains($0.property) && $0.keys.contains(where: { $0.frame == playheadFrame }) && $0.keys.contains(where: { $0.frame > playheadFrame })
        }.map(\.property)
    }
    @objc private func editKeyframeTime() {
        guard selectionIDs.count == 1, !composition.layers[selected].isLocked, !busy, previewPaused, let window else { return }
        do {
            try commitFields()
            guard selectedFrames.contains(playheadFrame) else { return }
            let layerID = composition.layers[selected].id
            let editor = NativeCreationKeyframeEditor(document: composition, layerIndex: selected,
                                                       sourceFrame: playheadFrame, properties: selectedProperties)
            timingEditor = editor; busy = true; refreshEnabled()
            editor.present(on: window) { [weak self] edit in
                guard let self else { return }
                self.timingEditor = nil; self.busy = false
                do {
                    if let edit {
                        let next = try edit.applying(to: self.composition, layerID: layerID)
                        self.remember(next); self.playheadFrame = edit.destinationFrame
                    }
                    self.refreshFields()
                    if self.renderedDocument != self.composition { self.render(save: false, apply: false) }
                } catch { self.refreshEnabled(); self.showError(error) }
            }
        } catch { showError(error) }
    }
    @objc private func editCurve() {
        guard selectionIDs.count == 1, !composition.layers[selected].isLocked, !busy, previewPaused, let window else { return }
        do {
            try commitFields()
            let properties = curveProperties, frame = playheadFrame, layerIndex = selected
            guard !properties.isEmpty else { return }
            let tracks = composition.layers[selected].animationTracks.filter { properties.contains($0.property) }
            let keys = tracks.compactMap { $0.keys.first { $0.frame == frame } }
            let first = keys[0]
            let same = keys.allSatisfy { $0.interpolation == first.interpolation && $0.curve == first.curve }
            let initial = first.curve ?? (first.interpolation == .linear ? .linear : first.interpolation == .smooth ? .smooth : .standard)
            let names = properties.map(\.title).joined(separator: "、")
            let scope = String(format: "%.3f 秒 · %@ · %d 段", Double(frame) / 60, names, properties.count) + (same ? "" : "（原过渡不同，应用后统一）")
            let editor = NativeCreationCurveEditor(curve: initial, scope: scope)
            curveEditor = editor; busy = true; refreshEnabled()
            editor.present(on: window) { [weak self] curve in
                guard let self else { return }
                self.curveEditor = nil; self.busy = false
                do {
                    if let curve {
                        var next = self.composition
                        next.layers[layerIndex].setInterpolation(.bezier, at: frame, properties: properties, curve: curve)
                        next.adoptTrackFormat(); _ = try next.validated(); self.remember(next)
                    }
                    self.refreshFields()
                    if self.renderedDocument != self.composition { self.render(save: false, apply: false) }
                } catch { self.refreshEnabled(); self.showError(error) }
            }
        } catch { showError(error) }
    }
    @objc private func changeTrack() {
        guard selectionIDs.count == 1, !busy else { return }
        let requestedIndex = trackPicker.indexOfSelectedItem
        // Keep the old table and selection together if a pending field fails
        // validation. Otherwise clicking an old row could seek the new track.
        trackPicker.selectItem(at: activeTrackIndex)
        do {
            let before = composition
            try commitFields()
            activeTrackIndex = requestedIndex; trackPicker.selectItem(at: requestedIndex)
            refreshFields()
            if before != composition { render(save: false, apply: false) }
        } catch { showError(error) }
    }
    private func poseFromFields() throws -> NativeCreationPose {
        func number(_ key: String) throws -> Double {
            guard let value = Double(fields[key]?.stringValue ?? ""), value.isFinite else { throw SceneError.invalid("请填写有效数值。") }
            return value
        }
        return try NativeCreationPose(x: number("x"), y: number("y"), scaleX: number("scaleX"), scaleY: number("scaleY"), rotation: number("rotation"), opacity: number("opacity"))
    }
    private func commitFields() throws {
        var next = composition
        next.title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let width = Int(canvasWidth.stringValue), let height = Int(canvasHeight.stringValue) else { throw SceneError.invalid("画布尺寸需填写整数像素。") }
        next.width = width; next.height = height
        guard let duration = Double(durationField.stringValue), duration.isFinite, (0.5...120).contains(duration) else { throw SceneError.invalid("动画时长应为 0.5–120 秒。") }
        next.duration = (duration * 60).rounded() / 60; next.loop = loopButton.state == .on
        if selectionIDs.count > 1 || composition.layers[selected].isLocked {
            _ = try next.validated(); remember(next); return
        }
        var layer = next.layers[selected]
        func number(_ key: String) throws -> Double {
            guard let text = fields[key]?.stringValue, let value = Double(text), value.isFinite else { throw SceneError.invalid("请填写有效数值，使用小数点表示小数。") }
            return value
        }
        layer.name = fields["name"]!.stringValue
        let pose = try poseFromFields()
        if let displayedPose { layer.edit(pose, comparedTo: displayedPose, at: playheadFrame) }
        layer.width = try number("width"); layer.height = try number("height")
        layer.color = fields["color"]!.stringValue
        layer.text = fields["text"]!.stringValue; layer.fontSize = try number("fontSize"); layer.swing = try number("swing"); layer.period = try number("period")
        layer.visible = visibility.state == .on
        next.layers[selected] = layer
        next.adoptTrackFormat()
        _ = try next.validated()
        remember(next)
    }
    private func remember(_ next: NativeCreationDocument) {
        guard next != composition else { return }
        undoHistory.append(historyState); if undoHistory.count > 50 { undoHistory.removeFirst() }
        let primary = composition.layers[selected].id
        redoHistory.removeAll(); composition = next
        selected = composition.layers.firstIndex { $0.id == primary } ?? min(selected, composition.layers.count - 1)
        normalizeSelection()
        dirty = true; refreshEnabled()
    }
    private func showError(_ error: Error) { status.stringValue = error.localizedDescription; status.textColor = .systemRed }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSTextField === timeField { return }
        if !rebuilding { dirty = true; redoHistory.removeAll(); refreshEnabled() }
    }
    @objc private func visibilityChanged() { dirty = true; redoHistory.removeAll(); refreshEnabled() }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === keyTable ? selectedFrames.count : composition.layers.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === keyTable {
            let frames = selectedFrames
            guard frames.indices.contains(row) else { return nil }
            let frame = frames[row]
            let values = composition.layers[selected].animationTracks.filter { selectedProperties.contains($0.property) }.compactMap { track -> String? in
                guard let key = track.keys.first(where: { $0.frame == frame }) else { return nil }
                return "\(track.property.title) \(readable(key.value)) · \(key.interpolation.title)"
            }
            let text = String(format: "%.3f 秒 · ", Double(frame) / 60) + values.joined(separator: "；")
            let label = NSTextField(labelWithString: text); label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.lineBreakMode = .byTruncatingTail; label.toolTip = text; label.setAccessibilityLabel(text); return label
        }
        guard composition.layers.indices.contains(row) else { return nil }
        let layer = composition.layers[composition.layers.count - 1 - row]
        let label = NSTextField(labelWithString: (layer.isLocked ? "锁定 · " : "") + (layer.visible ? "" : "隐藏 · ") + layer.name)
        label.lineBreakMode = .byTruncatingTail; return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView === keyTable {
            guard !rebuilding else { return }
            let frames = selectedFrames
            if frames.indices.contains(keyTable.selectedRow) { seek(frame: frames[keyTable.selectedRow]) }
            return
        }
        guard !rebuilding, !table.selectedRowIndexes.isEmpty else { return }
        let rows = table.selectedRowIndexes
        let requested = Set(rows.map { composition.layers[composition.layers.count - 1 - $0].id })
        guard requested != selectionIDs else { return }
        let row = rows.contains(table.clickedRow) ? table.clickedRow : table.selectedRow
        let primary = composition.layers[composition.layers.count - 1 - row].id
        do {
            try commitFields(); selectionIDs = requested
            selected = composition.layers.firstIndex { $0.id == primary }!
            refreshFields()
        } catch {
            showError(error); rebuilding = true
            table.selectRowIndexes(selectionRows, byExtendingSelection: false); rebuilding = false
        }
    }

    @objc private func updatePreview() {
        guard !busy else { return }
        do { try commitFields(); refreshFields(); render(save: false, apply: false) } catch { showError(error) }
    }
    @objc private func saveDocument() { save(apply: false) }
    @objc private func saveAndApply() { save(apply: true) }
    @objc private func saveThumbnail() { save(apply: false, replacePreview: true) }
    @objc private func chooseArchive() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "导入原生作品"
        panel.message = "选择 .wenative 作品文件。成功后保存为新的独立作品，可继续编辑和播放。"
        panel.allowedContentTypes = [NativeCreationArchive.contentType]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importArchive(url)
    }
    private func importArchive(_ url: URL) {
        guard !busy else { showError(SceneError.invalid("请等待当前保存或预览完成后，再导入作品。")); return }
        guard canLeave() else { return }
        busy = true; importing = true; importGeneration += 1
        let generation = importGeneration
        refreshEnabled(); status.textColor = .secondaryLabelColor
        status.stringValue = "正在读取原生作品…关闭编辑器可取消本次导入。"
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await NativeCreationArchiveIO.perform { try NativeCreationArchive.read(url) }
                guard importGeneration == generation else { return }
                importing = false; busy = false
                render(save: true, apply: false, imported: loaded)
            } catch {
                guard importGeneration == generation else { return }
                importing = false; busy = false; refreshEnabled(); showError(error)
            }
        }
    }
    @objc private func exportArchive() {
        guard !busy else { return }
        do { try commitFields(); refreshFields(); updateTimelineClock() } catch { showError(error); return }
        let panel = NSSavePanel(); panel.title = "导出原生作品"
        panel.message = "导出当前图层、图片与动画，便于备份和在本应用中导入。请使用新的文件名。"
        panel.allowedContentTypes = [NativeCreationArchive.contentType]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = NativeCreationArchive.suggestedName(composition.title)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateTimelineClock()
        let document = composition, images = self.images, time = Double(playheadFrame) / 60
        busy = true; refreshEnabled(); status.textColor = .secondaryLabelColor; status.stringValue = "正在导出原生作品…"
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false; refreshEnabled() }
            do {
                let count = try await NativeCreationArchiveIO.perform {
                    let bytes = try NativeCreationArchive.encode(document, images: images, time: time)
                    try NativeCreationArchive.write(bytes, to: url)
                    return bytes.count
                }
                status.stringValue = "已导出 \(url.lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file))。可用“导入作品”重新打开。"
            } catch { showError(error) }
        }
    }
    @objc private func saveCopy() {
        guard !busy else { return }
        do {
            try commitFields(); refreshFields()
            let suffix = " · 副本"
            var suggested = composition.title
            while suggested.utf8.count + suffix.utf8.count > 256 { suggested.removeLast() }
            let name = NSTextField(string: suggested + suffix)
            name.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
            name.setAccessibilityLabel("副本名称")
            let alert = NSAlert(); alert.messageText = "另存作品副本"
            alert.informativeText = "将当前编辑内容、图片和动画保存为独立作品，并继续编辑这个副本。"
            alert.accessoryView = name
            alert.addButton(withTitle: "保存副本"); alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = name
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            updateTimelineClock()
            render(save: true, apply: false, copyTitle: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch { showError(error) }
    }
    private func save(apply: Bool, replacePreview: Bool = false) {
        guard !busy else { return }
        do {
            updateTimelineClock()
            try commitFields(); refreshFields()
            if !dirty, !apply, !replacePreview, let time = record?.previewTime {
                status.textColor = .secondaryLabelColor
                status.stringValue = String(format: "作品已经保存。库中预览图为 %.2f 秒；可暂停并定位后更新预览图。", time)
                return
            }
            render(save: true, apply: apply)
        } catch { showError(error) }
    }
    private func render(save: Bool, apply: Bool, copyTitle: String? = nil, imported: NativeCreationArchive.Loaded? = nil,
                        restored: NativeCreationStore.Historical? = nil) {
        guard !busy else { return }
        var requested = restored?.saved.document ?? imported?.document ?? self.composition
        if imported != nil {
            requested.id = UUID()
            let suffix = " · 导入"
            while requested.title.utf8.count + suffix.utf8.count > 256 { requested.title.removeLast() }
            requested.title += suffix
        }
        if let copyTitle { requested.id = UUID(); requested.title = copyTitle }
        do { _ = try requested.validated() } catch { showError(error); return }
        let composition = requested, images = restored?.saved.images ?? imported?.images ?? self.images
        let expected = copyTitle == nil && imported == nil ? record?.version : nil
        let previewTime = restored.map { min($0.saved.document.duration, $0.saved.record.previewTime ?? 0) }
            ?? imported?.previewTime ?? (Double(playheadFrame) / 60)
        busy = true; refreshEnabled(); status.textColor = .secondaryLabelColor
        status.stringValue = save ? "正在生成作品预览图并保存…" : "正在准备实际引擎预览…"
        Task { [weak self] in
            guard let self else { return }
            defer { busy = false; refreshEnabled() }
            var unpresented: NativeCreationStore.Snapshot?
            do {
                let prepared = try await NativeCreationStore.perform { try NativeCreationStore.snapshot(composition, images: images, save: false, expectedVersion: nil) }
                unpresented = prepared
                let project = try WallpaperProject.load(from: prepared.project)
                let next = try NativeSceneRenderer.make(project: project, allowsEditorSeeking: true)
                next.setAudioOutputEnabled(false)
                guard next.seekEditor(to: previewTime) else { throw SceneError.invalid("作品未能建立可定位的原生动画预览。") }
                guard next.failedLayerCount == 0 else {
                    let reasons = next.diagnostics.filter { $0.hasPrefix("未加载图层 ") }.prefix(3).joined(separator: "；")
                    throw SceneError.invalid("有 \(next.failedLayerCount) 个图层未能加载，作品尚未保存。\(reasons)")
                }
                let saved: NativeCreationStore.Snapshot?
                if save {
                    let size = NativeCreationPreview.dimensions(width: composition.width, height: composition.height)
                    let preview = NativeCreationPreview(png: try next.editorPreviewPNG(width: size.width, height: size.height), time: previewTime)
                    saved = try await NativeCreationStore.perform { try NativeCreationStore.snapshot(composition, images: images, save: true, expectedVersion: expected, preview: preview) }
                    if copyTitle != nil || imported != nil { self.composition = composition; undoHistory = []; redoHistory = [] }
                    if imported != nil {
                        self.images = images; selectionIDs = []; selected = composition.layers.count - 1
                        playheadFrame = Int((previewTime * 60).rounded()); previewPaused = true
                    }
                    record = saved?.record; dirty = false; refreshCatalog(); onSaved?()
                } else { saved = nil }
                if let restored {
                    // Prepare and draw the historical content before replacing
                    // the current draft or its usable preview. Restoring alone
                    // never commits a new saved version or applies a desktop.
                    let size = NativeCreationPreview.dimensions(width: composition.width, height: composition.height)
                    _ = try next.editorPreviewPNG(width: size.width, height: size.height)
                    try await NativeCreationStore.perform { try NativeCreationStore.requireCurrent(restored.current) }
                    self.composition = composition; self.images = images; record = restored.current
                    undoHistory = []; redoHistory = []; selectionIDs = []; selected = composition.layers.count - 1
                    playheadFrame = Int((previewTime * 60).rounded()); previewPaused = true; dirty = true
                }
                stopPreview()
                snapshot = prepared; unpresented = nil; renderer = next; renderedDocument = composition
                let nextView = next.view
                nextView.translatesAutoresizingMaskIntoConstraints = false; previewFrame.addSubview(nextView, positioned: .below, relativeTo: canvas)
                NSLayoutConstraint.activate([nextView.leadingAnchor.constraint(equalTo: previewFrame.leadingAnchor), nextView.trailingAnchor.constraint(equalTo: previewFrame.trailingAnchor), nextView.topAnchor.constraint(equalTo: previewFrame.topAnchor), nextView.bottomAnchor.constraint(equalTo: previewFrame.bottomAnchor)])
                aspect?.isActive = false
                aspect = previewFrame.widthAnchor.constraint(equalTo: previewFrame.heightAnchor, multiplier: CGFloat(composition.width) / CGFloat(composition.height)); aspect?.isActive = true
                next.beginPresentation(); if !previewPaused { next.resume() }
                refreshFields()
                if save {
                    let action = imported != nil ? "已导入为新作品" : copyTitle == nil ? "已保存作品" : "已保存独立副本"
                    status.stringValue = String(format: "%@ · 预览图为 %.2f 秒。可从壁纸库使用或继续编辑。", action, previewTime)
                }
                else if restored != nil { status.stringValue = "已载入历史内容并暂停预览。点击“保存作品”生成新版本，已有版本会保留。" }
                else if record == nil { status.stringValue = "预览已更新。保存后作品才会进入壁纸库。" }
                else { status.stringValue = dirty ? "预览已更新。保存后更新作品版本。" : "已打开保存的作品，可继续编辑。" }
                if apply, let saved { onApply?(saved.project) }
            } catch {
                if let unpresented { NativeCreationStore.removePreview(unpresented) }
                showError(error)
            }
        }
    }
    @objc private func togglePreviewPause() {
        guard !busy else { return }
        window?.makeFirstResponder(canvas)
        if !previewPaused { updateTimelineClock(); seek(frame: playheadFrame); return }
        do {
            let before = composition; try commitFields()
            if !composition.loop && playheadFrame >= endFrame { playheadFrame = 0 }
            previewPaused = false; refreshFields()
            if before != composition { render(save: false, apply: false) }
            else { _ = renderer?.seekEditor(to: Double(playheadFrame) / 60); renderer?.resume() }
        } catch { showError(error) }
    }
    private func updateTimelineClock() {
        guard !busy, let renderer else { return }
        clock.stringValue = renderer.playbackDescription
        if !previewPaused {
            let raw = renderer.playbackTime
            let time = composition.loop ? raw.truncatingRemainder(dividingBy: composition.duration) : min(raw, composition.duration)
            playheadFrame = min(endFrame, max(0, Int((time * 60).rounded())))
            timeSlider.doubleValue = Double(playheadFrame)
            if window?.firstResponder !== timeField.currentEditor() { timeField.stringValue = String(format: "%.3f", Double(playheadFrame) / 60) }
            if !composition.loop && raw >= composition.duration { seek(frame: endFrame) }
        }
    }
    private func seek(frame: Int) {
        guard !busy else { return }
        do {
            let before = composition; try commitFields()
            previewPaused = true; playheadFrame = min(endFrame, max(0, frame)); refreshFields()
            if before != composition { render(save: false, apply: false) }
            else if renderer?.seekEditor(to: Double(playheadFrame) / 60) != true { render(save: false, apply: false) }
        } catch { showError(error) }
    }
    @objc private func scrubTimeline() { seek(frame: Int(timeSlider.doubleValue.rounded())) }
    @objc private func seekTypedTime() {
        guard let seconds = Double(timeField.stringValue), seconds.isFinite, seconds >= 0, seconds <= composition.duration else { showError(SceneError.invalid("定位时间需在 0 和作品时长之间。")); return }
        seek(frame: Int((seconds * 60).rounded()))
    }
    @objc private func recordKeyframe() {
        guard selectionIDs.count == 1, !composition.layers[selected].isLocked, !busy, previewPaused else { return }
        do {
            let original = composition.layers[selected]
            let requested = try poseFromFields()
            try commitFields(); var next = composition
            if playheadFrame > 0 {
                // A first key away from zero starts from the pre-edit base.
                // Committing the inspector must not replace that starting value.
                var base = next.layers[selected].basePose
                for property in selectedProperties where !original.hasAnimation(property) {
                    property.set(property.value(in: original.basePose), in: &base)
                }
                next.layers[selected].basePose = base
            }
            next.layers[selected].record(requested, at: playheadFrame, interpolation: selectedInterpolation, properties: selectedProperties)
            next.adoptTrackFormat()
            _ = try next.validated(); remember(next); refreshFields(); render(save: false, apply: false)
        } catch { showError(error) }
    }
    @objc private func deleteKeyframe() {
        guard selectionIDs.count == 1, !composition.layers[selected].isLocked, !busy, previewPaused else { return }
        do {
            try commitFields(); var next = composition
            next.layers[selected].deleteKeys(at: playheadFrame, properties: selectedProperties)
            next.adoptTrackFormat()
            _ = try next.validated(); remember(next); refreshFields(); render(save: false, apply: false)
        } catch { showError(error) }
    }
    @objc private func changeInterpolation() {
        guard selectionIDs.count == 1, !composition.layers[selected].isLocked, !busy, previewPaused else { return }
        do {
            try commitFields(); var next = composition
            guard selectedFrames.contains(playheadFrame), interpolation.indexOfSelectedItem != mixedInterpolationIndex else { return }
            next.layers[selected].setInterpolation(selectedInterpolation, at: playheadFrame, properties: selectedProperties)
            next.adoptTrackFormat()
            _ = try next.validated(); remember(next); refreshFields(); render(save: false, apply: false)
        } catch { showError(error) }
    }
    private func stopPreview() {
        canvas.cancelInteraction()
        renderer?.pause(); renderer?.view.removeFromSuperview(); renderer = nil
        renderedDocument = nil; refreshCanvas()
        if let snapshot { NativeCreationStore.removePreview(snapshot) }; snapshot = nil
    }
    @objc private func newDocument() {
        guard !busy, canLeave() else { return }
        stopPreview(); composition = .starter(); images = [:]; record = nil; undoHistory = []; redoHistory = []; selected = 2; selectionIDs = []; dirty = false; playheadFrame = 0; previewPaused = true
        refreshFields(); render(save: false, apply: false)
    }
    @objc private func openChosen() {
        let index = chooser.indexOfSelectedItem - 1; chooser.selectItem(at: 0)
        guard !busy, records.indices.contains(index), canLeave() else { return }
        load(records[index])
    }
    @objc private func openVersionHistory() {
        guard !busy, let record, let window else { return }
        canvas.cancelInteraction()
        busy = true; refreshEnabled(); status.textColor = .secondaryLabelColor
        status.stringValue = "正在读取作品历史版本…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let versions = try await NativeCreationStore.perform { try NativeCreationStore.history(for: record.id) }
                // Refresh the normal open menu too, so a version saved by
                // another window can be reopened after a restore is canceled.
                refreshCatalog()
                let editor = NativeCreationHistoryEditor(history: versions)
                historyEditor = editor
                editor.present(on: window) { [weak self] selected in
                    guard let self else { return }
                    self.historyEditor = nil; self.busy = false; self.refreshEnabled()
                    guard let selected else {
                        self.status.stringValue = "历史版本浏览已取消，当前编辑内容保留。"; return
                    }
                    guard self.canLeave() else { return }
                    self.restoreHistorical(selected, current: versions.current)
                }
            } catch { busy = false; refreshEnabled(); showError(error) }
        }
    }
    private func restoreHistorical(_ selectedRecord: NativeCreationStore.Record, current: NativeCreationStore.Record) {
        guard !busy else { return }
        busy = true; refreshEnabled(); status.stringValue = "正在载入历史内容…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let restored = try await NativeCreationStore.perform { try NativeCreationStore.loadHistorical(selectedRecord, expectedCurrent: current) }
                busy = false
                render(save: false, apply: false, restored: restored)
            } catch { busy = false; refreshEnabled(); showError(error) }
        }
    }
    private func load(_ selectedRecord: NativeCreationStore.Record) {
        guard !busy else { return }
        busy = true; refreshEnabled(); status.stringValue = "正在打开作品…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await NativeCreationStore.perform { try NativeCreationStore.load(selectedRecord) }
                stopPreview(); composition = loaded.document; images = loaded.images; record = loaded.record
                undoHistory = []; redoHistory = []; selectionIDs = []; selected = composition.layers.count - 1; dirty = false; playheadFrame = 0; previewPaused = true
                busy = false; refreshFields(); render(save: false, apply: false)
            } catch { busy = false; refreshEnabled(); showError(error) }
        }
    }
    @objc private func addSolid() { add(.solid) }
    @objc private func addText() { add(.text) }
    private func add(_ kind: NativeCreationDocument.Kind, image: NativeCreationImage? = nil) {
        guard !busy else { return }
        do {
            try commitFields()
            guard composition.layers.count < 64 else { throw SceneError.invalid("每个作品最多 64 个图层。") }
            var layer = NativeCreationDocument.Layer(kind: kind, name: kind == .text ? "文字" : kind == .image ? "图片" : "色块")
            layer.x = Double(composition.width) / 2; layer.y = Double(composition.height) / 2
            if let image {
                let id = UUID(); layer.imageID = id
                let scale = min(1, Double(composition.width) / Double(image.width), Double(composition.height) / Double(image.height))
                layer.width = Double(image.width) * scale; layer.height = Double(image.height) * scale
                images[id] = image
            }
            var next = composition; next.layers.append(layer); _ = try next.validated(); remember(next)
            selected = next.layers.count - 1; selectionIDs = [next.layers[selected].id]; refreshFields(); render(save: false, apply: false)
        } catch { showError(error) }
    }
    @objc private func addImage() {
        guard !busy else { return }
        do { try commitFields() } catch { showError(error); return }
        let panel = NSOpenPanel(); panel.title = "导入作品图片"; panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; importing = true; importGeneration += 1
        let generation = importGeneration
        refreshEnabled(); status.stringValue = "正在读取图片并制作本机副本…关闭编辑器可取消本次导入。"
        Task { [weak self] in
            guard let self else { return }
            do {
                let image = try await NativeCreationImageLoader.load(url)
                guard importGeneration == generation else { return }
                guard images.values.reduce(0, { $0 + $1.width * $1.height }) + image.width * image.height <= 32_000_000 else { throw SceneError.invalid("当前编辑会话的图片总像素超过 3200 万，请保存并重开以释放未使用素材。") }
                importing = false; busy = false; refreshEnabled(); add(.image, image: image)
            } catch {
                guard importGeneration == generation else { return }
                importing = false; busy = false; refreshEnabled(); showError(error)
            }
        }
    }
    @objc private func lockSelection() { setSelectionLocked(true) }
    @objc private func unlockSelection() { setSelectionLocked(false) }
    private func setSelectionLocked(_ locked: Bool) {
        guard !busy, previewPaused, canvasOriginal == nil else { return }
        do {
            try commitFields()
            let next = try NativeCreationLayerEditing.settingLocked(locked, selection: selectionIDs, in: composition)
            guard next != composition else { return }
            remember(next); refreshFields(); render(save: false, apply: false)
        } catch { showError(error) }
    }
    private func move(_ distance: Int) {
        guard !busy else { return }
        do {
            try commitFields()
            let next = try NativeCreationLayerEditing.reordered(selectionIDs, in: composition, towardFront: distance > 0)
            guard next != composition else { return }
            remember(next); refreshFields(); render(save: false, apply: false)
        } catch { showError(error) }
    }
    @objc private func raiseLayer() { move(1) }
    @objc private func lowerLayer() { move(-1) }
    @objc private func removeLayer() {
        guard !busy else { return }
        do {
            try commitFields()
            let next = try NativeCreationLayerEditing.removing(selectionIDs, from: composition)
            remember(next); refreshFields(); render(save: false, apply: false)
        } catch { showError(error) }
    }
    @objc private func undoChange() {
        guard !busy else { return }
        do { try commitFields() } catch { showError(error); return }
        guard let previous = undoHistory.popLast() else { return }
        redoHistory.append(historyState); restore(previous); dirty = true
        refreshFields(); render(save: false, apply: false)
    }
    @objc private func redoChange() {
        guard !busy, let next = redoHistory.popLast() else { return }
        undoHistory.append(historyState); restore(next); dirty = true
        refreshFields(); render(save: false, apply: false)
    }
    func canLeave() -> Bool {
        canvas.cancelInteraction()
        if importing {
            importGeneration += 1; importing = false; busy = false; refreshEnabled()
            status.stringValue = "本次文件导入已取消；已保存作品和现有图层保留。"
        }
        if busy { status.stringValue = "请等待当前保存或预览完成。"; window?.makeKeyAndOrderFront(nil); return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "作品还有未保存的修改"
        alert.informativeText = "继续编辑可先保存；放弃只影响当前未保存修改，已经保存的版本会保留。"
        alert.addButton(withTitle: "继续编辑"); alert.addButton(withTitle: "放弃未保存修改")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { canLeave() }
    func windowDidResignKey(_ notification: Notification) { canvas.cancelInteraction() }
    func windowWillStartLiveResize(_ notification: Notification) { canvas.cancelInteraction() }
    func windowWillClose(_ notification: Notification) {
        stopPreview(); timer?.invalidate(); timer = nil
        // Closing after an explicit discard restores the saved composition on next open.
        if dirty {
            restoreOnPresent = record
            composition = .starter(); images = [:]; record = nil; undoHistory = []; redoHistory = []; selected = 2; selectionIDs = []; dirty = false; playheadFrame = 0; previewPaused = true; refreshFields()
        }
    }
    func shutdown() { stopPreview(); timer?.invalidate(); timer = nil }
}
