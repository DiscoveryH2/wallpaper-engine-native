import AppKit

@MainActor
final class NativeProfileCollectionsController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// Save keeps the target's hotkey deferred until profile persistence
    /// succeeds. Load editing writes its selected target immediately below.
    var onSave: ((String, NativeHotkey?) throws -> Void)?
    var onLoad: ((NativeWallpaperProfile) async throws -> Void)?
    /// Test-only seam for the asynchronous collision sheet. Production uses
    /// the exact Simplified-Chinese confirmation below.
    var confirmHotkeyOverwrite: ((NativeHotkeyBinding, @escaping (Bool) -> Void) -> Void)?
    private let saving: Bool
    private let name = NSTextField(string: "")
    private let hotkey = NativeHotkeyRecorder()
    private let table = NSTableView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "您尚未创建任何配置文件。")
    private lazy var confirm = NativeLibraryFooterButton(title: "确认", primary: true, symbol: nil, target: self, action: #selector(confirmSelection))
    private lazy var cancel = NativeLibraryFooterButton(title: "取消", primary: false, symbol: nil, target: self, action: #selector(dismiss))
    private let remove = NSButton(title: "删除", target: nil, action: nil)
    private var profiles: [NativeWallpaperProfile] = []
    private var busy = false
    private var catalogError = false
    private var task: Task<Void, Never>?
    private var pendingHotkey: NativeHotkey?
    private var hotkeyRequest = 0

    init(saving: Bool, name: String = "") {
        self.saving = saving
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: saving ? 288 : 450),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = saving ? "保存配置文件" : "加载配置文件"
        window.identifier = .init("nativeProfileCollections"); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let root = NativeLibraryBrowserSurface(); window.contentView = root
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
        let heading = NSTextField(labelWithString: window.title); heading.font = NativeLibraryBrowserStyle.font(18)
        stack.addArrangedSubview(heading)
        if saving {
            let label = NSTextField(labelWithString: "名称"); label.font = NativeLibraryBrowserStyle.font(14)
            self.name.stringValue = name; self.name.delegate = self; self.name.identifier = .init("profileName")
            let row = NSStackView(views: [label, self.name]); row.spacing = 16
            label.widthAnchor.constraint(equalToConstant: 64).isActive = true
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            let description = NSTextField(wrappingLabelWithString: "如果已存在相同名称的配置文件，则它将会被覆盖。")
            description.font = NativeLibraryBrowserStyle.font(12); stack.addArrangedSubview(description)
        } else {
            let column = NSTableColumn(identifier: .init("profileTitle")); column.width = 530; table.addTableColumn(column)
            table.headerView = nil; table.rowHeight = 32; table.delegate = self; table.dataSource = self
            table.identifier = .init("profileSavedList"); table.target = self; table.doubleAction = #selector(confirmSelection)
            let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = table
            scroll.heightAnchor.constraint(equalToConstant: 212).isActive = true
            stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            empty.font = NativeLibraryBrowserStyle.font(14); empty.identifier = .init("profileEmpty")
            stack.addArrangedSubview(empty)
        }
        // The original uses the same recorder for Save and Load. The native
        // control only receives local AppKit events; Carbon registration and
        // profile activation stay in NativeProfileHotkeyService.
        let hotkeyLabel = NSTextField(labelWithString: "热键"); hotkeyLabel.font = NativeLibraryBrowserStyle.font(14)
        hotkey.identifier = .init("profileHotkey"); hotkey.toolTip = "点击后按下新的按键组合。"
        hotkey.onBeginRecording = { NativeProfileHotkeyService.shared.beginRecording() }
        hotkey.onEndRecording = { NativeProfileHotkeyService.shared.endRecording() }
        hotkey.onInvalidInput = { [weak self] text in self?.showHotkeyError(text) }
        hotkey.onChange = { [weak self] value in self?.requestHotkey(value) }
        // A text-field AX role is a leaf in the real macOS accessibility
        // hierarchy. Put the existing clear button beside the recorder rather
        // than declaring a child which AX discards, while preserving the exact
        // overlap and geometry of the single visual field.
        let hotkeyContainer = NSView(); hotkeyContainer.identifier = .init("profileHotkeyContainer")
        hotkey.translatesAutoresizingMaskIntoConstraints = false
        hotkey.clearButton.translatesAutoresizingMaskIntoConstraints = false
        hotkeyContainer.addSubview(hotkey); hotkeyContainer.addSubview(hotkey.clearButton)
        NSLayoutConstraint.activate([
            hotkey.leadingAnchor.constraint(equalTo: hotkeyContainer.leadingAnchor),
            hotkey.trailingAnchor.constraint(equalTo: hotkeyContainer.trailingAnchor),
            hotkey.topAnchor.constraint(equalTo: hotkeyContainer.topAnchor),
            hotkey.bottomAnchor.constraint(equalTo: hotkeyContainer.bottomAnchor),
            hotkey.clearButton.trailingAnchor.constraint(equalTo: hotkeyContainer.trailingAnchor, constant: -6),
            hotkey.clearButton.centerYAnchor.constraint(equalTo: hotkeyContainer.centerYAnchor),
            hotkey.clearButton.widthAnchor.constraint(equalToConstant: 28),
            hotkey.clearButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        let hotkeyRow = NSStackView(views: [hotkeyLabel, hotkeyContainer]); hotkeyRow.spacing = 16
        hotkeyLabel.widthAnchor.constraint(equalToConstant: 64).isActive = true
        hotkeyContainer.heightAnchor.constraint(equalToConstant: 34).isActive = true
        hotkeyContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack.addArrangedSubview(hotkeyRow); hotkeyRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        message.font = NativeLibraryBrowserStyle.font(12); message.maximumNumberOfLines = 3
        message.identifier = .init("profileMessage"); stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical); stack.addArrangedSubview(spacer)
        remove.target = self; remove.action = #selector(deleteSelection); remove.identifier = .init("profileDelete")
        confirm.target = self; confirm.action = #selector(confirmSelection); confirm.identifier = .init("profileConfirm"); confirm.keyEquivalent = "\r"
        cancel.target = self; cancel.action = #selector(dismiss); cancel.identifier = .init("profileCancel")
        cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        let footer = NSStackView(views: saving ? [NSView(), confirm, cancel] : [remove, NSView(), confirm, cancel]); footer.spacing = 10
        stack.addArrangedSubview(footer); footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if saving { pendingHotkey = (try? NativeProfileHotkeyStore.binding(for: name))?.hotkey; hotkey.hotkey = pendingHotkey }
        else { reload() }
        refreshControls()
    }
    required init?(coder: NSCoder) { nil }
    func present(on parent: NSWindow) {
        guard let window else { return }; parent.beginSheet(window)
        if saving { window.makeFirstResponder(name) }
    }
    @discardableResult func cancelPendingLoad() -> Task<Void, Never>? { task?.cancel(); return task }
    override func close() {
        hotkeyRequest &+= 1; task?.cancel()
        window?.makeFirstResponder(nil)
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    @objc private func dismiss() { close() }
    func controlTextDidChange(_ notification: Notification) { refreshControls() }
    private func reload() {
        do { profiles = try NativeProfileStore.saved().profiles; catalogError = false; message.stringValue = "" }
        catch { profiles = []; catalogError = true; message.stringValue = error.localizedDescription; message.textColor = .systemRed }
        table.deselectAll(nil); table.reloadData(); empty.isHidden = !profiles.isEmpty || catalogError
        pendingHotkey = nil; hotkey.hotkey = nil; refreshControls()
    }
    private func refreshControls() {
        name.isEnabled = !busy; table.isEnabled = !busy
        hotkey.isEnabled = !busy && !catalogError && (saving || profiles.indices.contains(table.selectedRow))
        confirm.isEnabled = !busy && !catalogError && (saving ? !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : profiles.indices.contains(table.selectedRow))
        remove.isEnabled = !busy && !catalogError && profiles.indices.contains(table.selectedRow)
    }
    func numberOfRows(in tableView: NSTableView) -> Int { profiles.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard profiles.indices.contains(row) else { return nil }
        let text = NSTextField(labelWithString: profiles[row].name); text.font = NativeLibraryBrowserStyle.font(14); return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        hotkeyRequest &+= 1
        if profiles.indices.contains(table.selectedRow) {
            do {
                pendingHotkey = try NativeProfileHotkeyStore.binding(for: profiles[table.selectedRow].name)?.hotkey
                hotkey.hotkey = pendingHotkey
                if message.textColor == .systemRed { message.stringValue = "" }
            } catch { pendingHotkey = nil; hotkey.hotkey = nil; showHotkeyError(error.localizedDescription) }
        } else { pendingHotkey = nil; hotkey.hotkey = nil }
        refreshControls()
    }
    @objc private func confirmSelection() {
        guard confirm.isEnabled else { return }
        if saving {
            let target = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            resolveConflict(for: pendingHotkey, target: target) { [weak self] accepted in
                guard let self, accepted else { return }
                do {
                    guard let onSave = self.onSave else { return }
                    try onSave(target, self.pendingHotkey)
                    self.close()
                } catch { self.showHotkeyError(error.localizedDescription) }
            }
            return
        }
        guard profiles.indices.contains(table.selectedRow), let onLoad else { return }
        let chosen = profiles[table.selectedRow]
        busy = true; message.stringValue = "正在准备配置文件…"; message.textColor = .secondaryLabelColor; refreshControls()
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil; self.refreshControls() }
            do { try await onLoad(chosen); self.close() }
            catch is CancellationError { self.message.stringValue = "本次加载已取消。" }
            catch { self.message.stringValue = "未应用，保留原设置：" + error.localizedDescription; self.message.textColor = .systemRed }
        }
    }
    @objc private func deleteSelection() {
        guard !busy, profiles.indices.contains(table.selectedRow) else { return }
        do {
            try NativeProfileStore.removeNamed(profiles[table.selectedRow].name)
            reload()
        }
        catch { message.stringValue = error.localizedDescription; message.textColor = .systemRed }
    }

    private var hotkeyTarget: String? {
        if saving { return name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        return profiles.indices.contains(table.selectedRow) ? profiles[table.selectedRow].name : nil
    }

    private func requestHotkey(_ value: NativeHotkey?) {
        guard let target = hotkeyTarget, !target.isEmpty else {
            // A Save dialog can start recording before its name is entered.
            // Keep this purely local draft and resolve collisions on Confirm.
            pendingHotkey = value; return
        }
        resolveConflict(for: value, target: target) { [weak self] accepted in
            guard let self, accepted else { return }
            do {
                if self.saving {
                    self.pendingHotkey = value
                } else {
                    try NativeHotkeyBindingStore.assign(.profile(name: target), hotkey: value)
                    self.pendingHotkey = value
                }
                self.hotkey.hotkey = value
                self.message.stringValue = ""
            } catch { self.restoreHotkeyAfterFailure(error) }
        }
    }

    /// Return true only after a collision has either been removed or was not
    /// present. Accepting the alert removes the other profile immediately,
    /// including from a Save dialog; the current Save target remains deferred.
    private func resolveConflict(for value: NativeHotkey?, target: String, completion: @escaping (Bool) -> Void) {
        guard let value else { completion(true); return }
        do {
            let profileTarget = NativeHotkeyTarget.profile(name: target)
            guard let conflict = try NativeHotkeyBindingStore.conflict(for: value, excluding: profileTarget) else {
                completion(true); return
            }
            hotkeyRequest &+= 1; let request = hotkeyRequest
            let respond: (Bool) -> Void = { [weak self] overwrite in
                guard let self, request == self.hotkeyRequest else { return }
                // The user may have changed selection/name while a sheet was
                // open. Never let an old answer mutate a new target or remove
                // a binding which has already changed underneath the alert.
                guard self.hotkeyTarget == target, self.hotkey.hotkey == value,
                      (try? NativeHotkeyBindingStore.conflict(for: value, excluding: profileTarget))?.target == conflict.target else { return }
                if overwrite {
                    do {
                        // An accepted collision revokes the former owner
                        // immediately. For Save, the new profile's binding
                        // remains deferred until the user confirms the form.
                        try NativeHotkeyBindingStore.removeBinding(conflict.target)
                        completion(true)
                    } catch { self.restoreHotkeyAfterFailure(error) }
                } else {
                    // The original clears the current input after declining a
                    // conflict rather than restoring its previous combination.
                    self.clearCurrentHotkey(target: target)
                    completion(false)
                }
            }
            if let confirmHotkeyOverwrite { confirmHotkeyOverwrite(conflict, respond); return }
            guard let window else { respond(false); return }
            let alert = NSAlert()
            alert.messageText = "覆写热键"
            alert.informativeText = "该键已分配给“\(hotkeyActionTitle(for: conflict.target))”。是否将其分配到此处？"
            alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { response in respond(response == .alertFirstButtonReturn) }
        } catch { restoreHotkeyAfterFailure(error) }
    }

    private func clearCurrentHotkey(target: String) {
        do {
            if saving { pendingHotkey = nil }
            else { try NativeHotkeyBindingStore.clear(.profile(name: target)); pendingHotkey = nil }
            hotkey.hotkey = nil
        } catch { showHotkeyError(error.localizedDescription) }
    }

    private func hotkeyActionTitle(for target: NativeHotkeyTarget) -> String {
        switch target {
        case .system(let action): return action.title
        case .profile: return "选择配置文件"
        case .wallpaper: return "选择壁纸"
        case .playlist: return "选择播放列表"
        }
    }

    private func restoreHotkeyAfterFailure(_ error: Error) {
        // Registration/preparation failures must not erase a previously valid
        // live binding. Collision decline is the one deliberate clear path.
        hotkey.hotkey = pendingHotkey; showHotkeyError(error.localizedDescription)
    }

    private func showHotkeyError(_ text: String) {
        message.stringValue = text; message.textColor = .systemRed
    }
}
