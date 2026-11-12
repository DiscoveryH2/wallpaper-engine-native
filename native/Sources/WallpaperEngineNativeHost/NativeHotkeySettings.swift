import AppKit

/// A deliberately small, flipped client surface for the Hotkeys sheet.  The
/// settings page's 34 pt control rows are not suitable for the reference
/// modal, whose body is a single independently-scrollable hotkey list.
@MainActor
private final class NativeHotkeySettingsSurface: NSView {
    var onResize: (() -> Void)?
    override var isFlipped: Bool { true }
    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        onResize?()
    }
    override func draw(_ dirtyRect: NSRect) {
        NativeLibraryBrowserStyle.background(effectiveAppearance).setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class NativeHotkeySettingsDocument: NSView {
    override var isFlipped: Bool { true }
}

/// Keeps a recorder and its trailing clear button as real accessibility
/// siblings.  A text-field AX element is a leaf on macOS, so declaring the
/// button as a child of the field would make the visible affordance disappear
/// from the actual accessibility tree.
@MainActor
private final class NativeHotkeyRecorderHost: NSView {
    let recorder: NativeHotkeyRecorder

    init(_ recorder: NativeHotkeyRecorder) {
        self.recorder = recorder
        super.init(frame: .zero)
        identifier = .init("hotkeyRecorderHost")
        addSubview(recorder)
        addSubview(recorder.clearButton)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        recorder.frame = bounds
        recorder.clearButton.frame = NSRect(x: max(0, bounds.width - 34), y: max(0, (bounds.height - 28) / 2), width: 28, height: 28)
    }
}

@MainActor
private final class NativeHotkeySettingsRow: NSView {
    let target: NativeHotkeyTarget
    let recorder: NativeHotkeyRecorder
    private let action = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let recorderHost: NativeHotkeyRecorderHost
    private let showsValue: Bool

    init(binding: NativeHotkeyBinding, index: Int, actionTitle: String, valueTitle: String?, onChange: @escaping (NativeHotkeyTarget, NativeHotkey?) -> Void) {
        target = binding.target
        recorder = NativeHotkeyRecorder()
        recorderHost = NativeHotkeyRecorderHost(recorder)
        showsValue = valueTitle != nil
        super.init(frame: .zero)
        identifier = .init("hotkeySettingsRow\(index)")
        action.stringValue = actionTitle
        action.font = NativeLibraryBrowserStyle.font(14)
        action.lineBreakMode = .byTruncatingTail
        action.textColor = NativeLibraryBrowserStyle.foreground(effectiveAppearance).withAlphaComponent(0.8)
        action.setAccessibilityLabel(actionTitle)
        addSubview(action)

        if let valueTitle {
            value.stringValue = valueTitle
            value.font = NativeLibraryBrowserStyle.font(12.6)
            value.lineBreakMode = .byTruncatingTail
            value.textColor = NativeLibraryBrowserStyle.foreground(effectiveAppearance).withAlphaComponent(0.5)
            value.toolTip = valueTitle
            value.setAccessibilityLabel(valueTitle)
            if let hint = Self.displayHint(for: binding.target) {
                value.toolTip = valueTitle + "\n" + hint
                value.setAccessibilityHelp(hint)
                recorder.setAccessibilityHelp(hint)
                recorder.clearButton.setAccessibilityHelp(hint)
            }
            addSubview(value)
        }

        recorder.identifier = .init("settingsHotkey\(index)")
        recorder.clearButton.identifier = .init("settingsHotkey\(index)Clear")
        recorder.setAccessibilityLabel(actionTitle + " 热键")
        recorder.clearButton.setAccessibilityLabel("清除" + actionTitle + "热键")
        recorder.hotkey = binding.hotkey
        recorder.onBeginRecording = { NativeProfileHotkeyService.shared.beginRecording() }
        recorder.onEndRecording = { NativeProfileHotkeyService.shared.endRecording() }
        recorder.onChange = { hotkey in onChange(binding.target, hotkey) }
        addSubview(recorderHost)
    }
    required init?(coder: NSCoder) { nil }

    /// The reference shows the wallpaper/list title without a monitor suffix.
    /// Retain that geometry while making equal titles on different displays
    /// distinguishable through hover and assistive technology.
    private static func displayHint(for target: NativeHotkeyTarget) -> String? {
        let location: String?
        switch target {
        case .wallpaper(let item): location = item.location
        case .playlist(_, let key): location = key
        case .profile, .system: return nil
        }
        guard let location, location != "default" else { return "默认桌面" }
        let screens = NativeDisplayDescriptor.connected()
        if let index = screens.firstIndex(where: { $0.key == location }) {
            return "显示器 \(index + 1) · \(screens[index].name)"
        }
        let name = NativeDisplayStore.load().displays[location]?.name ?? "显示器"
        return name + " · 未连接\n" + location
    }

    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        // The official title cell has a fixed 240 px width and 10 px inset.
        let titleWidth: CGFloat = min(240, max(0, bounds.width - 120))
        action.frame = NSRect(x: 10, y: 3, width: titleWidth, height: 22)
        recorderHost.frame = NSRect(x: 250, y: 0, width: max(56, bounds.width - 260), height: 28)
        value.frame = showsValue ? NSRect(x: 10, y: 32, width: max(0, bounds.width - 20), height: 18) : .zero
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        action.textColor = NativeLibraryBrowserStyle.foreground(effectiveAppearance).withAlphaComponent(0.8)
        value.textColor = NativeLibraryBrowserStyle.foreground(effectiveAppearance).withAlphaComponent(0.5)
    }

    var rowHeight: CGFloat { showsValue ? 60 : 28 }
}

/// Native equivalent of the official Settings → 热键 modal.  Its bindings
/// persist as each row changes; the enclosing Settings window intentionally
/// has no hotkey snapshot to roll back on its own Cancel button.
@MainActor
final class NativeHotkeySettingsController: NSWindowController, NSWindowDelegate {
    /// Test-only prompt seam.  Production presents the exact Chinese alert.
    var confirmHotkeyOverwrite: ((NativeHotkeyBinding, @escaping (Bool) -> Void) -> Void)?

    private let closed: () -> Void
    private let root = NativeHotkeySettingsSurface()
    private let titleLabel = NSTextField(labelWithString: "热键")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let scroll = NSScrollView()
    private let hotkeyDocument = NativeHotkeySettingsDocument()
    private lazy var confirm = NativeLibraryFooterButton(title: "确认", primary: true, symbol: nil, target: self, action: #selector(finish))
    private var rows: [NativeHotkeyTarget: NativeHotkeySettingsRow] = [:]
    private var hotkeyRequest = 0
    private var catalogReadable = true
    private var didClose = false

    init(closed: @escaping () -> Void = {}) {
        self.closed = closed
        // 50 px header + 400 px reference list body + 58 px footer reserve.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 508),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "热键"
        panel.identifier = .init("nativeHotkeySettings")
        panel.minSize = NSSize(width: 520, height: 420)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = root
        root.onResize = { [weak self] in self?.layout() }

        titleLabel.font = NativeLibraryBrowserStyle.font(18)
        titleLabel.identifier = .init("hotkeySettingsTitle")
        root.addSubview(titleLabel)

        errorLabel.font = NativeLibraryBrowserStyle.font(12)
        errorLabel.textColor = .systemRed
        errorLabel.identifier = .init("hotkeySettingsMessage")
        errorLabel.maximumNumberOfLines = 2
        errorLabel.isHidden = true
        root.addSubview(errorLabel)

        scroll.documentView = hotkeyDocument
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.identifier = .init("hotkeySettingsList")
        root.addSubview(scroll)

        confirm.identifier = .init("hotkeySettingsConfirm")
        confirm.keyEquivalent = "\r"
        root.addSubview(confirm)
        layout()
        rebuildRows()
        panel.center()
    }
    required init?(coder: NSCoder) { nil }

    func present(on parent: NSWindow) {
        guard let window else { return }
        parent.beginSheet(window)
    }

    override func close() { finish() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(); return false }

    @objc private func finish() {
        guard !didClose else { return }
        hotkeyRequest &+= 1
        window?.makeFirstResponder(nil)
        if catalogReadable {
            do {
                try NativeHotkeyBindingStore.pruneEmptyUserActions()
            } catch {
                showError(error)
                return
            }
        }
        didClose = true
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        closed()
        super.close()
    }

    private func layout() {
        guard isWindowLoaded else { return }
        let width = root.bounds.width
        titleLabel.frame = NSRect(x: 20, y: 17, width: max(0, width - 40), height: 24)
        let errorHeight: CGFloat = errorLabel.isHidden ? 0 : 34
        errorLabel.frame = NSRect(x: 20, y: 44, width: max(0, width - 40), height: errorHeight)
        let listTop: CGFloat = 50 + errorHeight
        scroll.frame = NSRect(x: 20, y: listTop, width: max(1, width - 40), height: max(120, root.bounds.height - listTop - 58))
        confirm.frame = NSRect(x: max(20, width - 115), y: root.bounds.height - 38, width: 95, height: 26)
        let contentWidth = scroll.contentSize.width
        hotkeyDocument.setFrameSize(NSSize(width: contentWidth, height: max(hotkeyDocument.frame.height, scroll.contentSize.height)))
        layoutRows(width: contentWidth)
    }

    private func rebuildRows() {
        rows.removeAll()
        hotkeyDocument.subviews.forEach { $0.removeFromSuperview() }
        hotkeyDocument.setFrameSize(NSSize(width: scroll.contentSize.width, height: 0))
        do {
            let bindings = try NativeHotkeyBindingStore.snapshot()
            catalogReadable = true
            errorLabel.isHidden = true
            buildRows(bindings)
        } catch {
            catalogReadable = false
            errorLabel.isHidden = false
            errorLabel.stringValue = error.localizedDescription
            let unavailable = NSTextField(wrappingLabelWithString: "无法读取热键设置，原记录已保留。")
            unavailable.identifier = .init("hotkeySettingsUnavailable")
            unavailable.font = NativeLibraryBrowserStyle.font(14)
            unavailable.textColor = .secondaryLabelColor
            hotkeyDocument.addSubview(unavailable)
            unavailable.frame = NSRect(x: 10, y: 0, width: max(1, scroll.contentSize.width - 20), height: 40)
            hotkeyDocument.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(40, scroll.contentSize.height)))
        }
        layout()
    }

    private func buildRows(_ bindings: [NativeHotkeyBinding]) {
        let fixed = bindings.filter {
            if case .system = $0.target { return true }
            return false
        }
        var y: CGFloat = 0
        for group in NativeHotkeySystemAction.Group.allCases {
            let groupBindings = fixed.filter {
                if case .system(let action) = $0.target { return action.group == group }
                return false
            }
            let groupTitle: String
            switch group {
            case .playback: groupTitle = "回放"
            case .general: groupTitle = "常规"
            case .windows: groupTitle = "Windows"
            }
            y = addGroupHeader(groupTitle, at: y)
            for binding in groupBindings { y = addRow(binding, index: rows.count, at: y) }
            y += 20
        }

        let userBindings = bindings.filter(\.target.isUserAction)
        y = addGroupHeader("更改壁纸", at: y)
        if userBindings.isEmpty {
            let placeholder = NSTextField(wrappingLabelWithString: "您可以在壁纸浏览器中为壁纸、播放列表或配置文件分配热键。")
            placeholder.identifier = .init("hotkeySettingsEmptyUserActions")
            placeholder.font = NativeLibraryBrowserStyle.font(14)
            placeholder.textColor = NativeLibraryBrowserStyle.foreground(root.effectiveAppearance).withAlphaComponent(0.5)
            hotkeyDocument.addSubview(placeholder)
            placeholder.frame = NSRect(x: 10, y: y, width: max(1, scroll.contentSize.width - 20), height: 40)
            y += 50
        } else {
            for binding in userBindings { y = addRow(binding, index: rows.count, at: y) }
        }
        hotkeyDocument.setFrameSize(NSSize(width: scroll.contentSize.width, height: max(y, scroll.contentSize.height)))
    }

    @discardableResult
    private func addGroupHeader(_ title: String, at y: CGFloat) -> CGFloat {
        let header = NSTextField(labelWithString: title)
        header.font = NativeLibraryBrowserStyle.font(16.8)
        header.identifier = .init("hotkeySettingsGroup" + title)
        header.setAccessibilityLabel(title)
        hotkeyDocument.addSubview(header)
        header.frame = NSRect(x: 0, y: y, width: max(1, scroll.contentSize.width), height: 20)
        return y + 30 // 20 px header plus the reference's 10 px bottom gap.
    }

    @discardableResult
    private func addRow(_ binding: NativeHotkeyBinding, index: Int, at y: CGFloat) -> CGFloat {
        let row = NativeHotkeySettingsRow(binding: binding, index: index, actionTitle: actionTitle(for: binding.target), valueTitle: valueTitle(for: binding.target)) { [weak self] target, hotkey in
            self?.requestHotkey(hotkey, for: target)
        }
        rows[binding.target] = row
        hotkeyDocument.addSubview(row)
        row.frame = NSRect(x: 0, y: y, width: max(1, scroll.contentSize.width), height: row.rowHeight)
        return y + row.rowHeight
    }

    private func layoutRows(width: CGFloat) {
        for view in hotkeyDocument.subviews {
            if let row = view as? NativeHotkeySettingsRow {
                row.frame.size.width = width
                row.needsLayout = true
            } else if let label = view as? NSTextField {
                let isHeader = label.identifier?.rawValue.hasPrefix("hotkeySettingsGroup") == true
                label.frame.origin.x = isHeader ? 0 : 10
                label.frame.size.width = max(1, width - (isHeader ? 0 : 20))
            }
        }
    }

    private func requestHotkey(_ hotkey: NativeHotkey?, for target: NativeHotkeyTarget) {
        guard catalogReadable else { return }
        do {
            guard let hotkey, let conflict = try NativeHotkeyBindingStore.conflict(for: hotkey, excluding: target) else {
                try NativeHotkeyBindingStore.assign(target, hotkey: hotkey)
                rebuildRows()
                return
            }
            hotkeyRequest &+= 1
            let request = hotkeyRequest
            let respond: (Bool) -> Void = { [weak self] overwrite in
                guard let self, request == self.hotkeyRequest, self.rows[target]?.recorder.hotkey == hotkey,
                      (try? NativeHotkeyBindingStore.conflict(for: hotkey, excluding: target))?.target == conflict.target else { return }
                do {
                    if overwrite {
                        try NativeHotkeyBindingStore.replace(target, hotkey: hotkey, overwrite: true)
                    } else {
                        // Just like the reference, declining a collision
                        // clears the current input rather than restoring it.
                        try NativeHotkeyBindingStore.clear(target)
                    }
                    self.rebuildRows()
                } catch {
                    self.rebuildRows()
                    self.showError(error)
                }
            }
            if let confirmHotkeyOverwrite {
                confirmHotkeyOverwrite(conflict, respond)
            } else if let window {
                let alert = NSAlert()
                alert.messageText = "覆写热键"
                alert.informativeText = "该键已分配给“\(actionTitle(for: conflict.target))”。是否将其分配到此处？"
                alert.addButton(withTitle: "确认")
                alert.addButton(withTitle: "取消")
                alert.beginSheetModal(for: window) { response in respond(response == .alertFirstButtonReturn) }
            } else {
                respond(false)
            }
        } catch {
            rebuildRows()
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        errorLabel.stringValue = error.localizedDescription
        errorLabel.isHidden = false
        layout()
    }

    private func actionTitle(for target: NativeHotkeyTarget) -> String {
        switch target {
        case .system(let action): return action.title
        case .profile: return "选择配置文件"
        case .wallpaper: return "选择壁纸"
        case .playlist: return "选择播放列表"
        }
    }

    private func valueTitle(for target: NativeHotkeyTarget) -> String? {
        switch target {
        case .system: return nil
        case .profile(let name): return name
        case .wallpaper(let wallpaper): return wallpaper.title.isEmpty ? wallpaper.projectPath : wallpaper.title
        case .playlist(let name, _): return name
        }
    }
}
