import AppKit

@MainActor
private final class NativeApplicationRulesSurface: NSView {
    var onResize: (() -> Void)?
    override var isFlipped: Bool { true }
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); onResize?() }
    override func draw(_ rect: NSRect) {
        NativeLibraryBrowserStyle.background(effectiveAppearance).setFill(); rect.fill()
        NativeLibraryBrowserStyle.border(effectiveAppearance).setFill()
        NSRect(x: 2, y: 458, width: max(0, bounds.width - 4), height: 1).fill()
    }
}

@MainActor
private final class NativeApplicationRulesDocument: NSView { override var isFlipped: Bool { true } }

@MainActor
final class NativeApplicationRulesController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private var editor: NativeApplicationRuleEditor
    private let applyRules: ([NativeApplicationRule]) throws -> Void
    private let applicationProvider: @Sendable () -> [String]
    private let wallpaperProvider: (@Sendable () -> NativeApplicationRuleLibrary.Catalog)?
    private let playlistProvider: (@MainActor () throws -> [NativePlaylist])?
    /// Profiles are saved by exact name in the rule, matching the original
    /// controller's name-based configuration lookup. The runtime resolves it
    /// again at activation, so an overwritten profile is never pinned here.
    private let profileProvider: (@MainActor () throws -> [NativeWallpaperProfile])?
    /// Configuration is allowed only when an injected native meter exists.
    /// Saving a rule still never grants capture permission or starts it.
    private let audioConditionConfigurable: Bool
    private let root = NativeApplicationRulesSurface()
    private let titleLabel = NSTextField(labelWithString: "应用程序规则")
    private let list = NSScrollView(), applicationList = NSScrollView()
    private let rulesDocument = NativeApplicationRulesDocument(), applicationsDocument = NativeApplicationRulesDocument()
    private let name = NSTextField(string: ""), condition = NSPopUpButton(), action = NSPopUpButton()
    private var labels: [NSTextField] = []
    private let message = NSTextField(labelWithString: "")
    private var createButton: NativeLibraryFooterButton!, confirmButton: NativeLibraryFooterButton!, cancelButton: NativeLibraryFooterButton!, clearButton: NativeLibraryFooterButton!
    private var applications: [String] = []
    private var applicationTask: Task<Void, Never>?
    private var wallpaperTask: Task<Void, Never>?, previewTask: Task<Void, Never>?
    private var wallpapers: [NativeApplicationRuleLibraryItem] = []
    private let wallpaperPreview = NSImageView(), workshopButton = NSButton(title: "在创意工坊中打开", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "找不到结果")
    private var previewGeneration = 0
    private var requestID = 0
    private var editViews: [NSView] = []
    private var multimonitor: Bool { NSScreen.screens.count > 1 }

    init(rules: [NativeApplicationRule], applications: @escaping @Sendable () -> [String] = {
        let own = ProcessInfo.processInfo.processIdentifier
        return Array(Set(NativeApplicationActivityReader.capture().processes.filter { $0.key != own }.map(\.value)))
    }, wallpapers: (@Sendable () -> NativeApplicationRuleLibrary.Catalog)? = nil,
       playlists: (@MainActor () throws -> [NativePlaylist])? = nil,
       profiles: (@MainActor () throws -> [NativeWallpaperProfile])? = nil,
       audioConditionConfigurable: Bool = false,
       apply: @escaping ([NativeApplicationRule]) throws -> Void) throws {
        editor = try .init(rules: rules); applyRules = apply; applicationProvider = applications
        wallpaperProvider = wallpapers; playlistProvider = playlists; profileProvider = profiles
        self.audioConditionConfigurable = audioConditionConfigurable
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 517), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "应用程序规则"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.contentView = root
        titleLabel.font = NativeLibraryBrowserStyle.font(18); root.addSubview(titleLabel)
        createButton = button("创建新规则", id: "applicationRulesCreate", primary: false, action: #selector(createRule))
        confirmButton = button("确认", id: "applicationRulesConfirm", primary: true, action: #selector(confirm))
        cancelButton = button("取消", id: "applicationRulesCancel", primary: false, action: #selector(cancelEditor))
        clearButton = button("清空", id: "applicationRulesClearName", primary: false, symbol: "xmark", action: #selector(clearName))
        clearButton.destructive = true; clearButton.showsText = false
        confirmButton.keyEquivalent = "\r"; cancelButton.keyEquivalent = "\u{1b}"; cancelButton.keyEquivalentModifierMask = []
        for (scroll, doc) in [(list, rulesDocument), (applicationList, applicationsDocument)] {
            scroll.documentView = doc; scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.scrollerStyle = .overlay
            root.addSubview(scroll)
        }
        list.identifier = .init("applicationRulesList"); applicationList.identifier = .init("applicationRulesApplications")
        name.identifier = .init("applicationRulesExecutable"); name.font = NativeLibraryBrowserStyle.font(14); name.delegate = self
        name.setAccessibilityLabel("应用程序名称")
        for (control, id, selector) in [(condition, "applicationRulesCondition", #selector(changeCondition)), (action, "applicationRulesAction", #selector(changeAction))] {
            control.identifier = .init(id); control.font = NativeLibraryBrowserStyle.font(14); control.autoenablesItems = false
            control.target = self; control.action = selector; root.addSubview(control)
        }
        condition.setAccessibilityLabel("条件"); action.setAccessibilityLabel("壁纸回放")
        for value in NativeApplicationCondition.allCases {
            condition.addItem(withTitle: value.title); condition.lastItem?.representedObject = value.rawValue
            if value == .playingaudio && !audioConditionConfigurable {
                condition.lastItem?.isEnabled = false; condition.lastItem?.toolTip = "当前未提供原生音频检测；保存规则不会申请权限。"
            } else if value == .playingaudio {
                condition.lastItem?.toolTip = "保存规则不会启用检测；请在设置中明确点击“启用音频检测”。"
            }
        }
        for text in ["应用程序名称", "条件", "壁纸回放"] {
            let label = NSTextField(labelWithString: text); label.font = NSFont(name: "Arial-BoldMT", size: 14) ?? .boldSystemFont(ofSize: 14)
            labels.append(label); root.addSubview(label)
        }
        root.addSubview(name); root.addSubview(message)
        wallpaperPreview.imageScaling = .scaleProportionallyUpOrDown; wallpaperPreview.identifier = .init("applicationRulesPreview")
        workshopButton.isBordered = false; workshopButton.contentTintColor = .systemBlue
        workshopButton.font = NativeLibraryBrowserStyle.font(14); workshopButton.target = self; workshopButton.action = #selector(openWorkshop)
        workshopButton.identifier = .init("applicationRulesOpenWorkshop")
        emptyLabel.font = NativeLibraryBrowserStyle.font(14); emptyLabel.alphaValue = 0.5
        root.addSubview(wallpaperPreview); root.addSubview(workshopButton)
        message.font = NativeLibraryBrowserStyle.font(12); message.textColor = .systemRed; message.lineBreakMode = .byTruncatingTail
        message.identifier = .init("applicationRulesMessage")
        editViews = [applicationList, name, condition, action, clearButton] + labels
        root.onResize = { [weak self] in self?.layout(); self?.rebuildRows(); self?.filterApplications() }
        refresh(); window.center()
    }
    required init?(coder: NSCoder) { nil }

    private func button(_ title: String, id: String, primary: Bool, symbol: String? = nil, action: Selector) -> NativeLibraryFooterButton {
        let button = NativeLibraryFooterButton(title: title, primary: primary, symbol: symbol, target: self, action: action)
        button.identifier = .init(id); root.addSubview(button); return button
    }
    func present(on parent: NSWindow) { guard let window else { return }; parent.beginSheet(window) }
    override func close() {
        cancelRequests()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }

    private func layout() {
        let width = max(400, root.bounds.width - 4), x: CGFloat = 2
        titleLabel.frame = NSRect(x: 17, y: 17, width: width - 30, height: 25)
        createButton.frame = NSRect(x: 17, y: 73, width: width - 30, height: 26)
        list.frame = NSRect(x: 17, y: 109, width: width - 30, height: 333)
        applicationList.frame = NSRect(x: 17, y: 88, width: width - 30, height: 200)
        let controlX = x + width / 3 + 15, controlWidth = width * 2 / 3 - 30
        for (index, label) in labels.enumerated() { label.frame = NSRect(x: 17, y: CGFloat(310 + 49 * index), width: width / 3 - 15, height: 20) }
        name.frame = NSRect(x: controlX, y: 303, width: controlWidth - 26, height: 34)
        clearButton.frame = NSRect(x: controlX + controlWidth - 26, y: 303, width: 26, height: 34)
        condition.frame = NSRect(x: controlX, y: 352, width: controlWidth, height: 34)
        action.frame = NSRect(x: controlX, y: 401, width: controlWidth, height: 34)
        wallpaperPreview.frame = NSRect(x: controlX, y: 352, width: 60, height: 60)
        workshopButton.frame = NSRect(x: controlX + 65, y: 352, width: max(0, controlWidth - 65), height: 24)
        cancelButton.frame = NSRect(x: x + width - 115, y: 474, width: 100, height: 26)
        confirmButton.frame = NSRect(x: cancelButton.frame.minX - (editor.page == .list ? 0 : 108.890625), y: 474, width: 100, height: 26)
        message.frame = NSRect(x: 17, y: 441, width: width - 30, height: 16)
    }
    private func refresh() {
        let editing = editor.page != .list
        let selecting = editor.page == .wallpaper
        let previewing = selecting && editor.draft.action == .loadwallpaper
        createButton.isHidden = editing; list.isHidden = editing; editViews.forEach { $0.isHidden = !editing }
        cancelButton.isHidden = !editing; message.stringValue = ""
        name.stringValue = selecting ? editor.search ?? "" : editor.draft.executable ?? ""
        name.identifier = .init(selecting ? "applicationRulesSearch" : "applicationRulesExecutable")
        name.setAccessibilityLabel(selecting ? "搜索" : "应用程序名称")
        labels[0].stringValue = selecting ? "搜索" : "应用程序名称"
        labels[1].stringValue = selecting ? "预览" : "条件"
        labels[1].isHidden = !editing || selecting && !previewing
        labels[2].isHidden = !editing || selecting
        condition.isHidden = !editing || selecting; action.isHidden = !editing || selecting
        wallpaperPreview.isHidden = !previewing
        workshopButton.isHidden = !previewing || selectedWallpaper?.workshopURL == nil
        condition.select(condition.itemArray.first { $0.representedObject as? String == editor.draft.condition.rawValue })
        updateActions(); updateConfirm(); layout(); rebuildRows(); filterApplications()
    }
    private func updateActions() {
        action.removeAllItems()
        let perDisplay = multimonitor && editor.draft.condition != .running && editor.draft.condition != .playingaudio
        for value in NativeApplicationAction.options(for: editor.draft.condition, multimonitor: multimonitor) {
            action.addItem(withTitle: value.title(multimonitor: perDisplay)); action.lastItem?.representedObject = value.rawValue
            if value.requiresSelection && !supportsSelection(value) {
                action.lastItem?.isEnabled = false; action.lastItem?.toolTip = "自动切换目标的规则暂不可用。"
            }
        }
        if let item = action.itemArray.first(where: { $0.representedObject as? String == editor.draft.action.rawValue }) { action.select(item) }
        else { action.selectItem(at: -1) }
    }
    private func updateConfirm() {
        if editor.page == .wallpaper {
            confirmButton.title = "创建"; confirmButton.setAccessibilityLabel("创建")
            confirmButton.isEnabled = wallpaperTask == nil && editor.selection != nil && (try? editor.draft.rule.validated()) != nil
            confirmButton.needsDisplay = true; return
        }
        confirmButton.title = editor.page == .list || editor.page == .edit ? "确认" : "创建"
        if editor.page != .list && editor.draft.action.requiresSelection { confirmButton.title = "下一步" }
        confirmButton.setAccessibilityLabel(confirmButton.title)
        var draft = editor.draft.rule
        if supportsSelection(draft.action) { draft.action = .pause }
        let actionIsAllowed = NativeApplicationAction.options(for: draft.condition, multimonitor: multimonitor).contains(draft.action)
        confirmButton.isEnabled = editor.page == .list || ((try? draft.validated()) != nil &&
            (!editor.draft.action.requiresSelection || supportsSelection(editor.draft.action)) &&
            (editor.draft.condition != .playingaudio || audioConditionConfigurable) && actionIsAllowed)
        confirmButton.needsDisplay = true
    }
    private func supportsSelection(_ action: NativeApplicationAction) -> Bool {
        action == .loadwallpaper && wallpaperProvider != nil || action == .loadplaylist && playlistProvider != nil ||
            action == .loadprofile && profileProvider != nil
    }
    private func rebuildRows() {
        rulesDocument.subviews.forEach { $0.removeFromSuperview() }
        rulesDocument.frame = NSRect(x: 0, y: 0, width: list.contentSize.width, height: max(list.contentSize.height, CGFloat(editor.rules.count) * 73))
        for (index, rule) in editor.rules.enumerated() {
            let row = NativeApplicationRulesDocument(frame: NSRect(x: 0, y: CGFloat(index) * 73, width: rulesDocument.bounds.width, height: 73))
            func label(_ text: String, _ frame: NSRect, size: CGFloat = 14, faded: Bool = false, right: Bool = false) {
                let view = NSTextField(labelWithString: text); view.font = NativeLibraryBrowserStyle.font(size)
                view.frame = frame; view.lineBreakMode = .byTruncatingTail; view.alignment = right ? .right : .left
                if faded { view.alphaValue = 0.5 }; row.addSubview(view)
            }
            label(rule.executable, NSRect(x: 5, y: 5, width: row.bounds.width - 76, height: 23), size: 16.8)
            // NSTextField needs four extra points for cell insets around the
            // reference's 56-point Chinese label; retain its right edge.
            label("条件", NSRect(x: 1, y: 28, width: 60, height: 20), faded: true, right: true)
            label("壁纸回放", NSRect(x: 1, y: 48, width: 60, height: 20), faded: true, right: true)
            label(rule.condition.title, NSRect(x: 71, y: 28, width: row.bounds.width - 76, height: 20))
            label(rule.action.title(multimonitor: multimonitor), NSRect(x: 71, y: 48, width: row.bounds.width - 76, height: 20))
            for (offset, title, symbol, selector) in [(0, "编辑", "square.and.pencil", #selector(editRule(_:))), (1, "删除", "trash", #selector(removeRule(_:)))] {
                let button = NativeLibraryFooterButton(title: title, primary: false, symbol: symbol, target: self, action: selector)
                button.identifier = .init("applicationRule\(index)\(offset == 0 ? "Edit" : "Delete")"); button.tag = index; button.showsText = false; button.destructive = offset == 1
                button.frame = NSRect(x: row.bounds.width - 65 + CGFloat(offset) * 30, y: 5, width: 26, height: 26); row.addSubview(button)
            }
            rulesDocument.addSubview(row)
        }
    }
    private func filterApplications() {
        applicationsDocument.subviews.forEach { $0.removeFromSuperview() }
        let selecting = editor.page == .wallpaper, query = name.stringValue
        let visible: [(String, Int)] = selecting
            ? editor.items.enumerated().filter { query.isEmpty || $0.element.label.localizedCaseInsensitiveContains(query) }.map { ($0.element.label, $0.offset) }
            : applications.enumerated().filter { query.isEmpty || $0.element.localizedCaseInsensitiveContains(query) }.map { ($0.element, $0.offset) }
        applicationsDocument.frame = NSRect(x: 0, y: 0, width: applicationList.contentSize.width, height: max(applicationList.contentSize.height, CGFloat(visible.count) * 22))
        for (index, value) in visible.enumerated() {
            let button = NSButton(title: value.0, target: self, action: selecting ? #selector(selectWallpaper(_:)) : #selector(selectApplication(_:)))
            button.isBordered = false; button.alignment = .left; button.font = NativeLibraryBrowserStyle.font(14)
            button.frame = NSRect(x: 0, y: CGFloat(index) * 22, width: applicationsDocument.bounds.width, height: 22)
            button.tag = value.1; button.identifier = .init("applicationRules\(selecting ? "Wallpaper" : "Process")\(index)"); applicationsDocument.addSubview(button)
        }
        if selecting && editor.items.isEmpty && wallpaperTask == nil {
            emptyLabel.frame = NSRect(x: 0, y: 0, width: applicationsDocument.bounds.width, height: 22); applicationsDocument.addSubview(emptyLabel)
        }
    }
    private func loadApplications() {
        requestID += 1; let request = requestID, provider = applicationProvider
        applicationTask?.cancel(); applicationTask = Task { [weak self] in
            let values = await Task.detached(priority: .utility) { provider().prefix(4096).sorted { $0.localizedCompare($1) == .orderedAscending } }.value
            guard let self, !Task.isCancelled, self.requestID == request, self.editor.page != .list else { return }
            self.applications = values; self.filterApplications(); self.applicationTask = nil
        }
    }
    @objc private func createRule() { editor.create(); refresh(); loadApplications(); window?.makeFirstResponder(name) }
    @objc private func editRule(_ sender: NSButton) { do { try editor.edit(at: sender.tag); refresh(); loadApplications() } catch { show(error) } }
    @objc private func removeRule(_ sender: NSButton) {
        do { var proposal = editor; try proposal.remove(at: sender.tag); try applyRules(proposal.rules); editor = proposal; refresh() } catch { show(error) }
    }
    @objc private func changeCondition() {
        guard let raw = condition.selectedItem?.representedObject as? String, let value = NativeApplicationCondition(rawValue: raw),
              value != .playingaudio || audioConditionConfigurable else { return }
        editor.changeCondition(value); updateActions(); updateConfirm()
    }
    @objc private func changeAction() {
        guard let raw = action.selectedItem?.representedObject as? String, let value = NativeApplicationAction(rawValue: raw),
              !value.requiresSelection || supportsSelection(value) else { return }
        editor.draft.action = value; updateConfirm()
    }
    @objc private func selectApplication(_ sender: NSButton) { name.stringValue = sender.title; editor.draft.executable = sender.title; filterApplications(); updateConfirm() }
    @objc private func clearName() {
        name.stringValue = ""
        if editor.page == .wallpaper { editor.clearSelection(); updatePreview() } else { editor.draft.executable = "" }
        filterApplications(); updateConfirm()
    }
    func controlTextDidChange(_ obj: Notification) {
        if editor.page == .wallpaper { editor.setSearch(name.stringValue) } else { editor.draft.executable = name.stringValue }
        filterApplications(); updateConfirm()
    }
    private func cancelRequests() {
        requestID += 1; previewGeneration += 1
        applicationTask?.cancel(); applicationTask = nil; wallpaperTask?.cancel(); wallpaperTask = nil; previewTask?.cancel(); previewTask = nil
    }
    @objc private func cancelEditor() {
        cancelRequests()
        if editor.page == .wallpaper { editor.cancelSelection(); refresh(); loadApplications() }
        else { editor.cancelEdit(); refresh() }
    }
    @objc private func confirm() {
        if editor.page == .list { close(); return }
        guard confirmButton.isEnabled else { return }
        if editor.page != .wallpaper && supportsSelection(editor.draft.action) { chooseWallpaper(); return }
        do { var proposal = editor; try proposal.commit(); try applyRules(proposal.rules); editor = proposal; refresh() } catch { show(error) }
    }
    private func show(_ error: Error) { message.stringValue = error.localizedDescription; message.toolTip = error.localizedDescription }

    private var selectedWallpaper: NativeApplicationRuleLibraryItem? { wallpapers.first { $0.file == editor.selection?.file } }
    private func chooseWallpaper() {
        if editor.draft.action == .loadprofile {
            guard let provider = profileProvider else { return }
            cancelRequests(); wallpapers = []; wallpaperPreview.image = nil
            do {
                let choices = try NativeApplicationProfileTarget.choices(from: provider())
                editor.choose(from: choices); refresh()
            } catch {
                editor.choose(from: []); refresh(); show(error)
            }
            window?.makeFirstResponder(name)
            return
        }
        if editor.draft.action == .loadplaylist {
            guard let provider = playlistProvider else { return }
            cancelRequests(); wallpapers = []; wallpaperPreview.image = nil
            do {
                let choices = try NativeApplicationPlaylistTarget.choices(from: provider())
                editor.choose(from: choices); refresh()
            } catch {
                editor.choose(from: []); refresh(); show(error)
            }
            window?.makeFirstResponder(name)
            return
        }
        guard let provider = wallpaperProvider else { return }
        let previous = editor.draft.file
        cancelRequests(); let request = requestID
        editor.choose(from: []); refresh(); wallpaperPreview.image = nil
        wallpaperTask = Task { [weak self] in
            let catalog = await Task.detached(priority: .utility) { provider() }.value
            guard let self, !Task.isCancelled, requestID == request, editor.page == .wallpaper else { return }
            wallpapers = Array(catalog.items.prefix(10_000))
            editor.draft.file = NativeApplicationRuleLibrary.Catalog(items: wallpapers).restoredFile(from: previous)
            editor.replaceChoices(wallpapers.map(\.item)); wallpaperTask = nil
            refresh(); updatePreview()
            if !catalog.warnings.isEmpty { message.stringValue = catalog.warnings.joined(separator: "；"); message.toolTip = message.stringValue }
        }
        updateConfirm(); filterApplications(); window?.makeFirstResponder(name)
    }
    @objc private func selectWallpaper(_ sender: NSButton) {
        editor.select(at: sender.tag); name.stringValue = editor.search ?? ""
        filterApplications(); updateConfirm(); updatePreview()
    }
    private func updatePreview() {
        previewGeneration += 1; let generation = previewGeneration
        previewTask?.cancel(); previewTask = nil; wallpaperPreview.image = nil
        workshopButton.isHidden = editor.page != .wallpaper || editor.draft.action != .loadwallpaper || selectedWallpaper?.workshopURL == nil
        guard editor.page == .wallpaper, editor.draft.action == .loadwallpaper, let project = selectedWallpaper?.project else { return }
        previewTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { NativeLibraryPreview.load(project: project) }.value
            guard let self, !Task.isCancelled, generation == previewGeneration, editor.page == .wallpaper else { return }
            wallpaperPreview.image = result.image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            wallpaperPreview.toolTip = result.message; previewTask = nil
        }
    }
    @objc private func openWorkshop() { if let url = selectedWallpaper?.workshopURL { NSWorkspace.shared.open(url) } }
}
