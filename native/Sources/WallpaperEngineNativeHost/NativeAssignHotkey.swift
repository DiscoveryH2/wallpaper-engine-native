import AppKit

/// Shared UI-side collision handling for the native user-target hotkey
/// entrypoints.  It intentionally follows the reference browser's order:
/// accepting an overwrite revokes the old owner immediately; the caller may
/// still defer creating its own target until a later Save/Confirm operation.
@MainActor
enum NativeHotkeyAssignmentUI {
    typealias OverwriteConfirmation = (NativeHotkeyBinding, @escaping (Bool) -> Void) -> Void

    enum ResolutionError: LocalizedError, Equatable {
        case declined
        case changed

        var errorDescription: String? {
            switch self {
            case .declined: return "已取消覆写热键。"
            case .changed: return "热键分配已变化，请重新输入按键组合。"
            }
        }
    }

    /// Resolve a candidate against the one shared V1+V2 pool.  `isCurrent`
    /// makes a delayed sheet answer harmless if the selected collection or
    /// draft changed while the sheet was open.
    static func resolve(_ hotkey: NativeHotkey?, for target: NativeHotkeyTarget,
                        in window: NSWindow?, confirmation: OverwriteConfirmation? = nil,
                        isCurrent: @escaping () -> Bool,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard let hotkey else { completion(.success(())); return }
        do {
            guard let conflict = try NativeHotkeyBindingStore.conflict(for: hotkey, excluding: target) else {
                completion(.success(())); return
            }
            let answer: (Bool) -> Void = { overwrite in
                guard isCurrent() else { return }
                guard overwrite else { completion(.failure(ResolutionError.declined)); return }
                do {
                    // Do not remove an arbitrary new owner if the pool changed
                    // while the confirmation sheet was being shown.
                    guard let current = try NativeHotkeyBindingStore.conflict(for: hotkey, excluding: target),
                          current.target == conflict.target else {
                        completion(.failure(ResolutionError.changed)); return
                    }
                    // This is deliberately before the caller's Save/Confirm:
                    // the source UI leaves this revocation in place even if a
                    // subsequent collection Save or standalone assignment is
                    // cancelled.
                    try NativeHotkeyBindingStore.removeBinding(conflict.target)
                    completion(.success(()))
                } catch { completion(.failure(error)) }
            }
            if let confirmation { confirmation(conflict, answer); return }
            guard let window else { completion(.failure(ResolutionError.changed)); return }
            let alert = NSAlert()
            alert.messageText = "覆写热键"
            alert.informativeText = "该键已分配给“\(conflict.target.title)”。是否将其分配到此处？"
            alert.addButton(withTitle: "确认"); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
        } catch { completion(.failure(error)) }
    }
}

/// Native equivalent of BrowseAssignHotkeyModalCtrl for one installed
/// wallpaper.  It owns only a draft.  The V2 target is written when the user
/// explicitly confirms; accepted collisions are the intentional exception
/// described by `NativeHotkeyAssignmentUI` above.
@MainActor
final class NativeAssignHotkeyController: NSWindowController, NSWindowDelegate {
    let target: NativeHotkeyTarget
    /// Test seam for the asynchronous overwrite alert. Production uses the
    /// exact Simplified-Chinese `NSAlert` in NativeHotkeyAssignmentUI.
    var confirmHotkeyOverwrite: NativeHotkeyAssignmentUI.OverwriteConfirmation?

    private let recorder = NativeHotkeyRecorder()
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var confirm = NativeLibraryFooterButton(title: "确认", primary: true, symbol: nil, target: self, action: #selector(commit))
    private lazy var cancel = NativeLibraryFooterButton(title: "取消", primary: false, symbol: nil, target: self, action: #selector(dismiss))
    private var draft: NativeHotkey?
    private var request = 0

    init(target: NativeHotkeyTarget) throws {
        self.target = try target.validatedSyntax()
        let title: String
        switch self.target {
        case .wallpaper(let wallpaper): title = "将热键分配给壁纸 \(wallpaper.title)"
        case .playlist(let name, _): title = "将热键分配给播放列表 \(name)"
        case .profile(let name): title = "将热键分配给配置文件 \(name)"
        case .system(let action): title = "将热键分配给 \(action.title)"
        }
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 236),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "分配热键"; window.identifier = .init("nativeAssignHotkey"); window.isReleasedWhenClosed = false
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
        let heading = NSTextField(wrappingLabelWithString: title); heading.font = NativeLibraryBrowserStyle.font(18)
        heading.maximumNumberOfLines = 2; stack.addArrangedSubview(heading)
        let label = NSTextField(labelWithString: "输入热键："); label.font = NativeLibraryBrowserStyle.font(14)
        recorder.identifier = .init("assignHotkey"); recorder.toolTip = "点击后按下新的按键组合。"
        recorder.clearButton.identifier = .init("assignHotkeyClear"); recorder.clearButton.setAccessibilityLabel("清除热键")
        recorder.onBeginRecording = { NativeProfileHotkeyService.shared.beginRecording() }
        recorder.onEndRecording = { NativeProfileHotkeyService.shared.endRecording() }
        recorder.onInvalidInput = { [weak self] text in self?.showError(text) }
        recorder.onChange = { [weak self] value in self?.capture(value) }
        let holder = NSView(); holder.identifier = .init("assignHotkeyContainer")
        recorder.translatesAutoresizingMaskIntoConstraints = false; recorder.clearButton.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(recorder); holder.addSubview(recorder.clearButton)
        NSLayoutConstraint.activate([
            recorder.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            recorder.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            recorder.topAnchor.constraint(equalTo: holder.topAnchor),
            recorder.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            recorder.clearButton.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -6),
            recorder.clearButton.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            recorder.clearButton.widthAnchor.constraint(equalToConstant: 28),
            recorder.clearButton.heightAnchor.constraint(equalToConstant: 28),
            holder.heightAnchor.constraint(equalToConstant: 34)
        ])
        let row = NSStackView(views: [label, holder]); row.spacing = 16
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        message.font = NativeLibraryBrowserStyle.font(12); message.textColor = .systemRed; message.maximumNumberOfLines = 3
        message.identifier = .init("assignHotkeyMessage"); stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .vertical); stack.addArrangedSubview(spacer)
        confirm.identifier = .init("assignHotkeyConfirm"); confirm.keyEquivalent = "\r"; confirm.isEnabled = false
        cancel.identifier = .init("assignHotkeyCancel"); cancel.keyEquivalent = "\u{1b}"; cancel.keyEquivalentModifierMask = []
        let footer = NSStackView(views: [NSView(), confirm, cancel]); footer.spacing = 10
        stack.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { nil }

    func present(on parent: NSWindow) { guard let window else { return }; parent.beginSheet(window) }
    override func close() {
        request &+= 1; window?.makeFirstResponder(nil)
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    @objc private func dismiss() { close() }

    private func capture(_ value: NativeHotkey?) {
        request &+= 1; let generation = request
        guard let value else { draft = nil; recorder.hotkey = nil; message.stringValue = ""; refresh(); return }
        NativeHotkeyAssignmentUI.resolve(value, for: target, in: window, confirmation: confirmHotkeyOverwrite,
            isCurrent: { [weak self] in self?.request == generation && self?.recorder.hotkey == value }) { [weak self] result in
                guard let self, self.request == generation else { return }
                switch result {
                case .success:
                    self.draft = value; self.recorder.hotkey = value; self.message.stringValue = ""; self.refresh()
                case .failure(let error as NativeHotkeyAssignmentUI.ResolutionError) where error == .declined:
                    // The source clears the input after the user declines an
                    // overwrite, rather than restoring a previous chord.
                    self.draft = nil; self.recorder.hotkey = nil; self.message.stringValue = ""; self.refresh()
                case .failure(let error):
                    self.recorder.hotkey = self.draft; self.showError(error.localizedDescription)
                }
            }
    }

    @objc private func commit() {
        guard let draft else { return }
        do {
            try NativeHotkeyBindingStore.replace(target, hotkey: draft)
            close()
        } catch NativeHotkeyBindingError.conflict(_) {
            // A concurrent settings edit may have claimed the chord after
            // capture. Re-run the same source-ordered prompt instead of
            // silently replacing an arbitrary owner.
            let generation = request
            NativeHotkeyAssignmentUI.resolve(draft, for: target, in: window, confirmation: confirmHotkeyOverwrite,
                isCurrent: { [weak self] in self?.request == generation && self?.draft == draft }) { [weak self] result in
                    guard let self, self.request == generation else { return }
                    switch result {
                    case .success: self.commit()
                    case .failure(let error as NativeHotkeyAssignmentUI.ResolutionError) where error == .declined:
                        self.draft = nil; self.recorder.hotkey = nil; self.message.stringValue = ""; self.refresh()
                    case .failure(let error): self.showError(error.localizedDescription)
                    }
                }
        } catch { showError(error.localizedDescription) }
    }

    private func refresh() { confirm.isEnabled = draft != nil }
    private func showError(_ text: String) { message.stringValue = text; message.textColor = .systemRed; refresh() }
}
