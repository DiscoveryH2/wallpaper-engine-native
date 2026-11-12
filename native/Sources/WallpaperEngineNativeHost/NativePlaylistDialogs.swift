import AppKit

@MainActor
private func playlistDialogHeader(_ title: String, width: CGFloat, identifier: String, target: AnyObject, action: Selector) -> NSStackView {
    let label = NSTextField(labelWithString: title); label.font = NativeLibraryBrowserStyle.font(18)
    let close = NativeLibraryFooterButton(title: "关闭", primary: false, symbol: "xmark", target: target, action: action)
    close.identifier = .init(identifier); close.showsText = false
    close.widthAnchor.constraint(equalToConstant: 26).isActive = true
    close.keyEquivalent = "\u{1b}"; close.keyEquivalentModifierMask = []
    let row = NSStackView(views: [label, NSView(), close]); row.alignment = .centerY
    row.widthAnchor.constraint(equalToConstant: width).isActive = true
    return row
}

@MainActor
final class NativePlaylistSettingsController: NSWindowController, NSWindowDelegate {
    var onApply: ((NativePlaylist) throws -> Void)?
    private var list: NativePlaylist
    private let mode = NSPopUpButton(), order = NSPopUpButton(), transition = NSPopUpButton()
    private let hours = NSTextField(string: ""), minutes = NSTextField(string: "")
    private let duration = NSSlider(value: 1500, minValue: 0, maxValue: 3000, target: nil, action: nil)
    private let durationLabel = NSTextField(labelWithString: "1500 ms")
    private let video = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let paused = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let begin = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let intro = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var timerRows: [NSView] = [], orderRow: NSView?, durationRow: NSView?
    private let transitionValues = ["-2", "none", "0"]

    init(list: NativePlaylist) {
        self.list = list
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "播放列表设置"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = NativeLibraryBrowserSurface(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.detachesHiddenViews = true; stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)])
        stack.addArrangedSubview(playlistDialogHeader(window.title, width: 560, identifier: "playlistSettingsClose", target: self, action: #selector(dismiss)))
        func row(_ title: String, _ control: NSView) -> NSStackView {
            let label = NSTextField(wrappingLabelWithString: title); label.font = NativeLibraryBrowserStyle.font(14)
            let row = NSStackView(views: [label, control]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 12
            label.widthAnchor.constraint(equalToConstant: 310).isActive = true
            row.widthAnchor.constraint(equalToConstant: 560).isActive = true
            stack.addArrangedSubview(row); return row
        }
        mode.addItems(withTitles: NativePlaylistMode.allCases.map(\.title)); mode.selectItem(at: NativePlaylistMode.allCases.firstIndex(of: list.settings.mode)!)
        mode.identifier = .init("playlistMode"); mode.target = self; mode.action = #selector(updateVisibility); _ = row("更换壁纸", mode)
        hours.stringValue = String(Int(list.settings.delay / 60)); minutes.stringValue = String(list.settings.delay.truncatingRemainder(dividingBy: 60))
        hours.identifier = .init("playlistHours"); minutes.identifier = .init("playlistMinutes")
        for field in [hours, minutes] { field.widthAnchor.constraint(equalToConstant: 92).isActive = true; field.font = NativeLibraryBrowserStyle.font(14) }
        let hourGroup = NSStackView(views: [NSTextField(labelWithString: "小时"), hours]); hourGroup.orientation = .vertical
        let minuteGroup = NSStackView(views: [NSTextField(labelWithString: "分钟"), minutes]); minuteGroup.orientation = .vertical
        timerRows.append(row("", NSStackView(views: [hourGroup, minuteGroup])))
        order.addItems(withTitles: ["随机", "有序"]); order.selectItem(at: list.settings.random ? 0 : 1); order.identifier = .init("playlistOrder")
        orderRow = row("播放顺序", order)
        transition.addItems(withTitles: ["无 (减少闪烁)", "无", "淡化"])
        transition.selectItem(at: transitionValues.firstIndex(of: list.settings.transition) ?? 2)
        transition.identifier = .init("playlistTransition"); transition.target = self; transition.action = #selector(updateVisibility)
        _ = row("显示壁纸过渡", transition)
        duration.doubleValue = list.settings.transitionMilliseconds; duration.target = self; duration.action = #selector(durationChanged)
        duration.identifier = .init("playlistTransitionDuration"); duration.widthAnchor.constraint(equalToConstant: 140).isActive = true
        durationLabel.font = NativeLibraryBrowserStyle.font(14); durationRow = row("过渡时间", NSStackView(views: [duration, durationLabel]))
        for (title, control, value, id) in [
            ("在视频结束时更换壁纸", video, list.settings.videoSequence, "playlistVideoSequence"),
            ("允许壁纸在暂停时更换", paused, list.settings.updateOnPause, "playlistUpdateOnPause"),
            ("总是从第一张壁纸开始", begin, list.settings.beginFirst, "playlistBeginFirst"),
            ("第一张壁纸仅在启动时播放", intro, list.settings.playIntro, "playlistIntro")
        ] {
            control.state = value ? .on : .off; control.identifier = .init(id); control.setAccessibilityLabel(title)
            control.target = self; control.action = #selector(updateVisibility); timerRows.append(row(title, control))
        }
        let notice = NSTextField(wrappingLabelWithString: "当前可使用淡化过渡；其他过渡效果仍在开发。")
        notice.font = NativeLibraryBrowserStyle.font(12); notice.textColor = .secondaryLabelColor; stack.addArrangedSubview(notice)
        errorLabel.textColor = .systemRed; errorLabel.font = NativeLibraryBrowserStyle.font(12); errorLabel.isHidden = true; stack.addArrangedSubview(errorLabel)
        let confirm = NativeLibraryFooterButton(title: "确认", primary: true, symbol: nil, target: self, action: #selector(apply))
        confirm.identifier = .init("playlistSettingsConfirm"); confirm.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), confirm]); footer.widthAnchor.constraint(equalToConstant: 560).isActive = true; stack.addArrangedSubview(footer)
        durationChanged(); updateVisibility()
    }
    required init?(coder: NSCoder) { nil }
    func present(on parent: NSWindow) { guard let window else { return }; parent.beginSheet(window) }
    override func close() { if let window, let parent = window.sheetParent { parent.endSheet(window) }; super.close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    @objc private func dismiss() { close() }
    @objc private func updateVisibility() {
        let selected = NativePlaylistMode.allCases[mode.indexOfSelectedItem]
        timerRows.forEach { $0.isHidden = selected != .timer }
        orderRow?.isHidden = selected == .daytime || selected == .dayofweek
        durationRow?.isHidden = transition.indexOfSelectedItem != 2
        intro.isEnabled = selected == .timer && begin.state == .on
        window?.contentView?.layoutSubtreeIfNeeded()
    }
    @objc private func durationChanged() { duration.doubleValue = (duration.doubleValue / 50).rounded() * 50; durationLabel.stringValue = "\(Int(duration.doubleValue)) ms" }
    @objc private func apply() {
        do {
            var next = list
            next.settings.mode = NativePlaylistMode.allCases[mode.indexOfSelectedItem]
            guard let h = Double(hours.stringValue), let m = Double(minutes.stringValue), h.isFinite, m.isFinite, h >= 0, m >= 0 else { throw NativePlaylistError.invalid("请输入有效的小时和分钟。") }
            next.settings.delay = h * 60 + m; next.settings.random = order.indexOfSelectedItem == 0
            next.settings.transition = transitionValues[transition.indexOfSelectedItem]; next.settings.transitionMilliseconds = duration.doubleValue
            next.settings.videoSequence = video.state == .on; next.settings.updateOnPause = paused.state == .on
            next.settings.beginFirst = begin.state == .on; next.settings.playIntro = intro.state == .on
            if next.settings.mode == .dayofweek, next.entries.count > 7 {
                let alert = NSAlert(); alert.messageText = "星期播放列表"; alert.informativeText = "星期播放列表不支持超过 7 张壁纸。立即移除多余的壁纸？"
                alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }; next.entries = Array(next.entries.prefix(7))
            }
            next.normalize(); _ = try next.validated(); try onApply?(next); close()
        } catch { errorLabel.stringValue = error.localizedDescription; errorLabel.isHidden = false }
    }
}

@MainActor
final class NativePlaylistCollectionsController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    var onLoad: ((NativePlaylist) throws -> Void)?
    /// The Save dialog owns a deferred draft, just like the official
    /// collections modal. The host saves the named playlist before applying
    /// the supplied binding, so an unsaved list can never be a live target.
    var onSave: ((String, NativeHotkey?) throws -> Void)?
    /// Test seam for the asynchronous overwrite prompt. Production uses the
    /// native Simplified-Chinese alert in NativeHotkeyAssignmentUI.
    var confirmHotkeyOverwrite: NativeHotkeyAssignmentUI.OverwriteConfirmation?
    private let saving: Bool
    /// The library captures one display context when it presents this sheet.
    /// A later monitor switch invalidates this controller, including a delayed
    /// overwrite confirmation, rather than applying its result to the new
    /// screen or default desktop.
    private let displayTarget: NativeDisplayTarget
    private let isContextCurrent: () -> Bool
    private let name = NSTextField(string: "")
    private let hotkey = NativeHotkeyRecorder()
    private let table = NSTableView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let remove = NSButton(title: "删除", target: nil, action: nil)
    private var lists: [NativePlaylist] = []
    private var pendingHotkey: NativeHotkey?
    private var hotkeyRequest = 0
    init(saving: Bool, name: String, target: NativeDisplayTarget = .defaultWallpaper,
         isContextCurrent: @escaping () -> Bool = { true }) {
        self.saving = saving
        self.displayTarget = target
        self.isContextCurrent = isContextCurrent
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: saving ? 526 : 466), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = saving ? "保存播放列表" : "打开播放列表"; window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let root = NativeLibraryBrowserSurface(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)])
        stack.addArrangedSubview(playlistDialogHeader(window.title, width: 460, identifier: "playlistCollectionsClose", target: self, action: #selector(dismiss)))
        if saving {
            stack.addArrangedSubview(NSTextField(labelWithString: "名称")); self.name.stringValue = name; self.name.identifier = .init("playlistSaveName"); self.name.delegate = self
            self.name.widthAnchor.constraint(equalToConstant: 460).isActive = true; stack.addArrangedSubview(self.name)
            let description = NSTextField(wrappingLabelWithString: "如果已存在相同名称的播放列表，则它将会被覆盖。")
            description.font = NativeLibraryBrowserStyle.font(12); stack.addArrangedSubview(description)
        }
        let column = NSTableColumn(identifier: .init("playlistName")); column.title = "播放列表"; column.width = 440; table.addTableColumn(column)
        table.headerView = nil; table.rowHeight = 30; table.dataSource = self; table.delegate = self
        table.identifier = .init("savedPlaylists"); table.target = self; table.doubleAction = #selector(confirm)
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.widthAnchor.constraint(equalToConstant: 460).isActive = true; scroll.heightAnchor.constraint(equalToConstant: 200).isActive = true; stack.addArrangedSubview(scroll)
        // The official playlist collection modal exposes the same local
        // recorder in both Save and Load modes. Save keeps a draft; Load edits
        // the selected named collection's shared binding immediately.
        let hotkeyLabel = NSTextField(labelWithString: "热键"); hotkeyLabel.font = NativeLibraryBrowserStyle.font(14)
        hotkey.identifier = .init("playlistHotkey"); hotkey.toolTip = "点击后按下新的按键组合。"
        hotkey.clearButton.identifier = .init("playlistHotkeyClear"); hotkey.clearButton.setAccessibilityLabel("清除热键")
        hotkey.onBeginRecording = { NativeProfileHotkeyService.shared.beginRecording() }
        hotkey.onEndRecording = { NativeProfileHotkeyService.shared.endRecording() }
        hotkey.onInvalidInput = { [weak self] text in self?.showHotkeyError(text) }
        hotkey.onChange = { [weak self] value in self?.requestHotkey(value) }
        let hotkeyContainer = NSView(); hotkeyContainer.identifier = .init("playlistHotkeyContainer")
        hotkey.translatesAutoresizingMaskIntoConstraints = false; hotkey.clearButton.translatesAutoresizingMaskIntoConstraints = false
        hotkeyContainer.addSubview(hotkey); hotkeyContainer.addSubview(hotkey.clearButton)
        NSLayoutConstraint.activate([
            hotkey.leadingAnchor.constraint(equalTo: hotkeyContainer.leadingAnchor),
            hotkey.trailingAnchor.constraint(equalTo: hotkeyContainer.trailingAnchor),
            hotkey.topAnchor.constraint(equalTo: hotkeyContainer.topAnchor),
            hotkey.bottomAnchor.constraint(equalTo: hotkeyContainer.bottomAnchor),
            hotkey.clearButton.trailingAnchor.constraint(equalTo: hotkeyContainer.trailingAnchor, constant: -6),
            hotkey.clearButton.centerYAnchor.constraint(equalTo: hotkeyContainer.centerYAnchor),
            hotkey.clearButton.widthAnchor.constraint(equalToConstant: 28),
            hotkey.clearButton.heightAnchor.constraint(equalToConstant: 28),
            hotkeyContainer.heightAnchor.constraint(equalToConstant: 34)
        ])
        let hotkeyRow = NSStackView(views: [hotkeyLabel, hotkeyContainer]); hotkeyRow.spacing = 16
        hotkeyLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        hotkeyRow.widthAnchor.constraint(equalToConstant: 460).isActive = true; stack.addArrangedSubview(hotkeyRow)
        message.font = NativeLibraryBrowserStyle.font(12); message.widthAnchor.constraint(equalToConstant: 460).isActive = true; stack.addArrangedSubview(message)
        remove.target = self; remove.action = #selector(deleteSaved); remove.identifier = .init("playlistDeleteSaved")
        let confirm = NativeLibraryFooterButton(title: "确认", primary: true, symbol: nil, target: self, action: #selector(confirm)); confirm.keyEquivalent = "\r"; confirm.identifier = .init("playlistCollectionsConfirm")
        let footer = NSStackView(views: [remove, NSView(), confirm]); footer.widthAnchor.constraint(equalToConstant: 460).isActive = true; stack.addArrangedSubview(footer)
        if saving, displayTarget.persistent {
            pendingHotkey = (try? NativeHotkeyBindingStore.binding(for: playlistTarget(name)))?.hotkey
            hotkey.hotkey = pendingHotkey
        }
        reload(); refreshControls()
    }
    required init?(coder: NSCoder) { nil }
    func present(on parent: NSWindow) {
        guard let window else { return }; parent.beginSheet(window)
        if saving { window.makeFirstResponder(name) }
    }
    override func close() {
        hotkeyRequest &+= 1; window?.makeFirstResponder(nil)
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
    }
    /// Called by the library before it renders another display context.
    /// Incrementing the request token makes a queued conflict completion inert
    /// even if AppKit delivers it after the sheet has been ordered out.
    func invalidateContext() { close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    @objc private func dismiss() { close() }
    func controlTextDidChange(_ notification: Notification) { refreshControls() }
    private func reload() {
        do { lists = try NativePlaylistStore.saved().lists; message.stringValue = lists.isEmpty ? "您尚未创建任何播放列表。" : "" }
        catch { message.stringValue = error.localizedDescription }
        table.deselectAll(nil); table.reloadData(); pendingHotkey = saving ? pendingHotkey : nil
        if !saving { hotkey.hotkey = nil }
        refreshControls()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { lists.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: lists[row].name); label.font = NativeLibraryBrowserStyle.font(14); return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        hotkeyRequest &+= 1
        guard isContextCurrent() else { return }
        if lists.indices.contains(table.selectedRow) {
            if saving { name.stringValue = lists[table.selectedRow].name }
            do {
                pendingHotkey = displayTarget.persistent
                    ? try NativeHotkeyBindingStore.binding(for: playlistTarget(lists[table.selectedRow].name))?.hotkey
                    : nil
                hotkey.hotkey = pendingHotkey
                if message.textColor == .systemRed { message.stringValue = "" }
            } catch { pendingHotkey = nil; hotkey.hotkey = nil; showHotkeyError(error.localizedDescription) }
        } else if !saving { pendingHotkey = nil; hotkey.hotkey = nil }
        refreshControls()
    }
    @objc private func confirm() {
        do {
            guard isContextCurrent() else {
                throw NativePlaylistError.invalid("显示器目标已切换，本次操作未保存。")
            }
            if saving {
                guard !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativePlaylistError.invalid("请输入播放列表名称。") }
                try onSave?(name.stringValue, pendingHotkey)
            }
            else { guard lists.indices.contains(table.selectedRow) else { return }; try onLoad?(lists[table.selectedRow]) }
            close()
        } catch { message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    }
    @objc private func deleteSaved() {
        guard isContextCurrent(), lists.indices.contains(table.selectedRow) else { return }
        do {
            // The source collection controller removes the user-target record
            // before deleting its matching saved playlist.
            if displayTarget.persistent {
                try NativeHotkeyBindingStore.removeBinding(playlistTarget(lists[table.selectedRow].name))
            }
            try NativePlaylistStore.removeNamed(lists[table.selectedRow].name); reload()
        }
        catch { message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    }

    private func playlistTarget(_ name: String) -> NativeHotkeyTarget {
        .playlist(name: name, location: displayTarget.hotkeyLocation)
    }
    private var selectedTarget: NativeHotkeyTarget? {
        guard displayTarget.persistent else { return nil }
        if saving {
            let savedName = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !savedName.isEmpty else { return nil }
            return playlistTarget(savedName)
        }
        guard lists.indices.contains(table.selectedRow) else { return nil }
        return playlistTarget(lists[table.selectedRow].name)
    }
    private func refreshControls() {
        let selected = lists.indices.contains(table.selectedRow)
        table.isEnabled = true; remove.isEnabled = selected
        hotkey.isEnabled = displayTarget.persistent && (saving || selected)
    }
    private func requestHotkey(_ value: NativeHotkey?) {
        hotkeyRequest &+= 1; let request = hotkeyRequest
        guard isContextCurrent() else { return }
        guard displayTarget.persistent else {
            pendingHotkey = nil; hotkey.hotkey = nil
            showHotkeyError("临时显示器不能保存全局播放列表热键。")
            return
        }
        guard let target = selectedTarget,
              (saving || lists.indices.contains(table.selectedRow)) else {
            // A Save dialog may collect a chord before its name is entered.
            // It remains a local draft until the user explicitly saves.
            pendingHotkey = value; return
        }
        guard let value else { clearCurrentHotkey(target); return }
        NativeHotkeyAssignmentUI.resolve(value, for: target, in: window, confirmation: confirmHotkeyOverwrite,
            isCurrent: { [weak self] in self?.isContextCurrent() == true && self?.hotkeyRequest == request && self?.hotkey.hotkey == value && self?.selectedTarget == target }) { [weak self] result in
                guard let self, self.isContextCurrent(), self.hotkeyRequest == request else { return }
                switch result {
                case .success:
                    do {
                        if self.saving { self.pendingHotkey = value }
                        else { try NativeHotkeyBindingStore.replace(target, hotkey: value) }
                        self.hotkey.hotkey = value; self.message.stringValue = ""
                    } catch { self.restoreHotkeyAfterFailure(error) }
                case .failure(let error as NativeHotkeyAssignmentUI.ResolutionError) where error == .declined:
                    // In Load mode the original shared binding is cleared on
                    // decline; Save only clears its unpersisted draft.
                    self.clearCurrentHotkey(target)
                case .failure(let error): self.restoreHotkeyAfterFailure(error)
                }
            }
    }
    private func clearCurrentHotkey(_ target: NativeHotkeyTarget) {
        do {
            if saving { pendingHotkey = nil }
            else { try NativeHotkeyBindingStore.removeBinding(target); pendingHotkey = nil }
            hotkey.hotkey = nil; message.stringValue = ""
        } catch { showHotkeyError(error.localizedDescription) }
    }
    private func restoreHotkeyAfterFailure(_ error: Error) {
        hotkey.hotkey = pendingHotkey; showHotkeyError(error.localizedDescription)
    }
    private func showHotkeyError(_ text: String) { message.stringValue = text; message.textColor = .systemRed }
}
