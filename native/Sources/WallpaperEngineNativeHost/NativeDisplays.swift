import AppKit
import ColorSync
import CoreGraphics
import Foundation

struct NativeDisplayAssignment: Codable, Equatable, Sendable {
    var name: String
    var enabled = true
    var projectPath: String?
    var projectTitle: String?
    var workshopID: String?
}

struct NativeDisplayLayout: Codable, Equatable, Sendable {
    var format = 1
    var displays: [String: NativeDisplayAssignment] = [:]
    var preferredAudioDisplay: String?

    static func validKey(_ key: String) -> Bool {
        if key.hasPrefix("uuid:") { return UUID(uuidString: String(key.dropFirst(5))) != nil }
        if key.hasPrefix("session:"), let id = UInt32(key.dropFirst(8)) { return id > 0 }
        return false
    }
    func validated() throws -> Self {
        guard format == 1, displays.count <= 64,
              preferredAudioDisplay.map(Self.validKey) ?? true else { throw PropertyError.invalid("显示器配置无效。") }
        for (key, item) in displays {
            guard Self.validKey(key), item.name.utf8.count <= 1024,
                  (item.projectTitle?.utf8.count ?? 0) <= 4096,
                  item.workshopID.map({ SteamLibraryIndex.validID($0) && (UInt64($0) ?? 0) > 0 }) ?? true else { throw PropertyError.invalid("显示器配置超出支持范围。") }
            if let path = item.projectPath {
                guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
                      URL(fileURLWithPath: path).standardizedFileURL.path == path,
                      URL(fileURLWithPath: path).lastPathComponent == "project.json" else { throw PropertyError.invalid("显示器壁纸必须是本机 project.json。") }
            } else if item.workshopID != nil { throw PropertyError.invalid("显示器的工坊记录缺少本机项目。") }
        }
        return self
    }

    /// Resolve only a recorded, host-owned Workshop copy. Other paths remain
    /// explicit local selections and cannot redirect into a Workshop item.
    static func resolvedProject(_ assignment: NativeDisplayAssignment) -> URL? {
        guard let path = assignment.projectPath else { return nil }
        let url = URL(fileURLWithPath: path)
        if let id = assignment.workshopID, SavedWorkshopStore.recordForProject(url)?.id == id,
           let current = SavedWorkshopStore.current(id) { return current.project }
        return url
    }

    /// Session display IDs are supplied by the current display server
    /// topology, rather than by a physical monitor.  They must therefore be
    /// dropped at the first observed disconnect, even if the display server
    /// later reuses the same numeric ID for another monitor.
    func droppingDisconnectedSessionTargets(connectedSessionKeys: Set<String>) -> Self {
        var result = self
        result.displays = displays.filter { key, _ in
            !key.hasPrefix("session:") || connectedSessionKeys.contains(key)
        }
        if let audio = preferredAudioDisplay, audio.hasPrefix("session:"),
           !connectedSessionKeys.contains(audio) {
            result.preferredAudioDisplay = nil
        }
        return result
    }
}

@MainActor
enum NativeDisplayStore {
    private static let key = "nativeDisplayLayoutV1"
    private static var temporary: [String: NativeDisplayAssignment] = [:]
    private static var temporaryAudio: String?
    struct Snapshot {
        let layout: NativeDisplayLayout
        fileprivate let persistent: Any?
        fileprivate let temporary: [String: NativeDisplayAssignment]
        fileprivate let temporaryAudio: String?
    }
    static func snapshot() -> Snapshot {
        Snapshot(layout: load(), persistent: UserDefaults.standard.object(forKey: key), temporary: temporary, temporaryAudio: temporaryAudio)
    }
    /// Restore a browser/profile transaction while refusing to write a
    /// snapshot from a disconnected session display onto a newly reconnected
    /// screen that happens to receive the same CoreGraphics display ID.
    ///
    /// The current overlays for excluded targets are retained.  They can only
    /// describe a newer display generation; deleting them here would make a
    /// stale browser cancellation mutate that new monitor as well.
    static func restore(_ snapshot: Snapshot, excludingSessionTargets excluded: Set<String> = []) {
        if let value = snapshot.persistent { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        let currentTemporary = temporary
        temporary = snapshot.temporary.filter { !excluded.contains($0.key) }
        for key in excluded {
            if let current = currentTemporary[key] { temporary[key] = current }
        }
        if let audio = snapshot.temporaryAudio, !excluded.contains(audio) {
            temporaryAudio = audio
        } else if let current = temporaryAudio, excluded.contains(current) {
            // Preserve a preference chosen by a newer generation of this
            // same session key; no old snapshot may overwrite it.
            temporaryAudio = current
        } else {
            temporaryAudio = nil
        }
    }

    static func sessionTargetKeys(in snapshot: Snapshot) -> Set<String> {
        var keys = Set(snapshot.temporary.keys.filter { $0.hasPrefix("session:") })
        if let audio = snapshot.temporaryAudio, audio.hasPrefix("session:") { keys.insert(audio) }
        return keys
    }

    /// Removes runtime-only display assignments and audio routing for session
    /// screens that have disappeared.  Persistent UUID assignments and the
    /// default layout are intentionally untouched.
    @discardableResult
    static func discardDisconnectedSessionTargets(connectedSessionKeys: Set<String>) -> Set<String> {
        var discarded = Set(temporary.keys.filter {
            $0.hasPrefix("session:") && !connectedSessionKeys.contains($0)
        })
        temporary = temporary.filter { key, _ in
            !key.hasPrefix("session:") || connectedSessionKeys.contains(key)
        }
        if let audio = temporaryAudio, audio.hasPrefix("session:"), !connectedSessionKeys.contains(audio) {
            discarded.insert(audio)
            temporaryAudio = nil
        }
        return discarded
    }
    static func load() -> NativeDisplayLayout {
        var result = NativeDisplayLayout()
        if let data = UserDefaults.standard.data(forKey: key), data.count <= 128 * 1024,
           let decoded = try? JSONDecoder().decode(NativeDisplayLayout.self, from: data), let valid = try? decoded.validated() { result = valid }
        result.displays.merge(temporary) { _, current in current }
        if let temporaryAudio { result.preferredAudioDisplay = temporaryAudio }
        return result
    }
    static func save(_ layout: NativeDisplayLayout) throws {
        let valid = try layout.validated()
        var persistent = valid
        persistent.displays = valid.displays.filter { $0.key.hasPrefix("uuid:") }
        if persistent.preferredAudioDisplay?.hasPrefix("session:") == true { persistent.preferredAudioDisplay = nil }
        let data = try JSONEncoder().encode(persistent)
        guard data.count <= 128 * 1024 else { throw PropertyError.invalid("显示器设置超过大小上限。") }
        UserDefaults.standard.set(data, forKey: key)
        temporary = valid.displays.filter { $0.key.hasPrefix("session:") }
        temporaryAudio = valid.preferredAudioDisplay?.hasPrefix("session:") == true ? valid.preferredAudioDisplay : nil
    }
}

@MainActor
struct NativeDisplayDescriptor {
    let key: String
    let id: CGDirectDisplayID
    let name: String
    let screen: NSScreen
    let persistent: Bool
    var summary: String {
        let size = "\(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id))"
        return name + " · " + size + (id == CGMainDisplayID() ? " · 主屏幕" : "") + (CGDisplayIsInMirrorSet(id) != 0 ? " · 镜像显示" : "")
    }
    var signature: String {
        "\(key)|\(id)|\(NSStringFromRect(screen.frame))|\(screen.backingScaleFactor)|\(CGDisplayPixelsWide(id))|\(CGDisplayPixelsHigh(id))"
    }
    static func connected() -> [Self] {
        var seen = Set<String>()
        return NSScreen.screens.enumerated().compactMap { index, screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  id != kCGNullDirectDisplay, CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay else { return nil }
            let systemUUID: Unmanaged<CFUUID>? = CGDisplayCreateUUIDFromDisplayID(id)
            let raw = systemUUID.map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            var key = raw.flatMap { UUID(uuidString: $0) }.map { "uuid:" + $0.uuidString.lowercased() } ?? "session:\(id)"
            // Never conflate two logical screens that report a duplicate UUID.
            if seen.contains(key) { key = "session:\(id)" }
            guard seen.insert(key).inserted else { return nil }
            let reported = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return Self(key: key, id: id, name: reported.isEmpty ? "显示器 \(index + 1)" : reported, screen: screen, persistent: key.hasPrefix("uuid:"))
        }
    }
}

@MainActor
final class NativeDisplaySettingsController: NSWindowController, NSWindowDelegate {
    var onApply: ((NativeDisplayLayout) async throws -> Void)?
    var onChooseProject: ((@escaping (URL, String) -> Void) -> Void)?
    var onEditProperties: ((String) -> Void)?
    var canEditProperties: ((String) -> Bool)?
    var defaultTitle: (() -> String)?
    var runtimeReport: ((String) -> String)?
    var onCaptureProfile: ((NativeDisplayLayout) async throws -> NativeWallpaperProfile)?
    var onLoadProfile: ((NativeWallpaperProfile) async throws -> Void)?
    private let display = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let project = NSTextField(wrappingLabelWithString: "")
    private let choose = NSButton(title: "从壁纸库选择…", target: nil, action: nil)
    private let properties = NSButton(title: "调整当前显示壁纸的作者设置…", target: nil, action: nil)
    private let audio = NSButton(checkboxWithTitle: "优先从这块屏幕播放壁纸声音", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let result = NSTextField(wrappingLabelWithString: "")
    private let apply = NSButton(title: "应用显示器设置", target: nil, action: nil)
    private let loadProfile = NSButton(title: "加载配置文件", target: nil, action: nil)
    private let saveProfile = NSButton(title: "保存配置文件", target: nil, action: nil)
    private var profileCollections: NativeProfileCollectionsController?
    private var draft = NativeDisplayLayout()
    private var keys: [String] = []
    private var connected: [NativeDisplayDescriptor] = []
    private var task: Task<Void, Never>?
    private var timer: Timer?
    private var busy = false
    private var selectedKey: String? { keys.indices.contains(display.indexOfSelectedItem) ? keys[display.indexOfSelectedItem] : nil }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 710), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Wallpaper Engine Native · 显示器"
        window.identifier = .init("nativeDisplaySettings")
        window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        let heading = NSTextField(labelWithString: "显示器与壁纸")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "每块屏幕可跟随默认壁纸、使用独立壁纸或关闭动态壁纸。先选择配置，再点击应用；镜像屏幕共用同一画面。")
        note.textColor = .secondaryLabelColor
        mode.addItems(withTitles: ["跟随默认壁纸", "使用独立壁纸", "关闭动态壁纸"])
        display.setAccessibilityLabel("配置的显示器"); mode.setAccessibilityLabel("此屏幕的壁纸方式")
        display.target = self; display.action = #selector(selectionChanged)
        mode.target = self; mode.action = #selector(modeChanged)
        choose.target = self; choose.action = #selector(chooseProject)
        properties.target = self; properties.action = #selector(editProperties)
        audio.target = self; audio.action = #selector(audioChanged)
        apply.target = self; apply.action = #selector(applyChanges)
        loadProfile.target = self; loadProfile.action = #selector(showLoadProfiles); loadProfile.identifier = .init("displayLoadProfile")
        saveProfile.target = self; saveProfile.action = #selector(showSaveProfile); saveProfile.identifier = .init("displaySaveProfile")
        project.font = .systemFont(ofSize: 14, weight: .medium)
        project.maximumNumberOfLines = 3
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 5
        result.font = .systemFont(ofSize: 12); result.textColor = .secondaryLabelColor
        result.maximumNumberOfLines = 3
        let close = NSButton(title: "关闭", target: self, action: #selector(closePanel))
        let buttons = NSStackView(views: [close, apply]); buttons.spacing = 12
        let profiles = NSStackView(views: [loadProfile, saveProfile]); profiles.spacing = 12
        let stack = NSStackView(views: [heading, note, profiles, display, mode, project, choose, properties, audio, status, result, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24)
            ])
        }
        for view in [note, display, mode, project, status, result] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    /// A temporary application profile owns an unpersisted layout. Its editor
    /// must show that live layout, while ordinary callers still begin from the
    /// saved display configuration.
    func present(initialLayout: NativeDisplayLayout? = nil) {
        if !busy { draft = initialLayout ?? NativeDisplayStore.load(); result.stringValue = "" }
        refreshConnections()
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.updateRuntime() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }

    /// The browser's monitor overlay has separate “加载配置文件” and “保存
    /// 配置文件” controls.  Both operate on the complete display layout, so
    /// expose one focused entry point instead of making the overlay open the
    /// generic display panel and lose which action the user chose.
    func presentProfiles(saving: Bool, initialLayout: NativeDisplayLayout? = nil) {
        present(initialLayout: initialLayout)
        guard !busy, window?.attachedSheet == nil else { return }
        if saving { showSaveProfile() }
        else { showLoadProfiles() }
    }
    func refreshConnections() {
        let old = selectedKey
        connected = NativeDisplayDescriptor.connected()
        keys = connected.map(\.key)
        keys += draft.displays.keys.filter { !keys.contains($0) }.sorted()
        display.removeAllItems()
        for key in keys {
            display.addItem(withTitle: connected.first(where: { $0.key == key })?.summary ?? ((draft.displays[key]?.name ?? "显示器") + " · 未连接"))
        }
        if let old, let index = keys.firstIndex(of: old) { display.selectItem(at: index) }
        else if !keys.isEmpty { display.selectItem(at: 0) }
        refreshControls()
    }
    private func assignment(_ key: String) -> NativeDisplayAssignment {
        draft.displays[key] ?? NativeDisplayAssignment(name: connected.first(where: { $0.key == key })?.name ?? "显示器")
    }
    private func refreshControls() {
        loadProfile.isEnabled = !busy && onLoadProfile != nil
        saveProfile.isEnabled = !busy && onCaptureProfile != nil
        guard let key = selectedKey else {
            mode.isEnabled = false; choose.isEnabled = false; apply.isEnabled = false; audio.isEnabled = false; properties.isEnabled = false
            project.stringValue = "尚未发现可配置的屏幕"; updateRuntime(); return
        }
        let item = assignment(key)
        display.isEnabled = !busy; mode.isEnabled = !busy; audio.isEnabled = !busy
        apply.isEnabled = !busy
        mode.selectItem(at: !item.enabled ? 2 : item.projectPath == nil ? 0 : 1)
        choose.isEnabled = !busy && mode.indexOfSelectedItem == 1
        if mode.indexOfSelectedItem == 0 { project.stringValue = "默认壁纸：" + (defaultTitle?() ?? "尚未打开") }
        else if mode.indexOfSelectedItem == 2 { project.stringValue = "这块屏幕显示 macOS 原有背景；已选项目仍保留。" }
        else { project.stringValue = item.projectTitle ?? item.projectPath.map { URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent } ?? "尚未选择独立壁纸" }
        audio.state = draft.preferredAudioDisplay == key ? .on : .off
        updateRuntime()
    }
    private func updateRuntime() {
        guard let key = selectedKey else { status.stringValue = ""; return }
        let connection = connected.first(where: { $0.key == key })
        let persistence = connection?.persistent == false ? "\n系统未提供唯一标识，这块屏幕的设置仅在本次运行保留。" : ""
        status.stringValue = (runtimeReport?(key) ?? "尚未打开壁纸") + persistence
        status.toolTip = status.stringValue
        properties.isEnabled = !busy && (canEditProperties?(key) ?? false)
        if mode.indexOfSelectedItem == 0 { project.stringValue = "默认壁纸：" + (defaultTitle?() ?? "尚未打开") }
    }
    @objc private func selectionChanged() { refreshControls() }
    @objc private func modeChanged() {
        guard let key = selectedKey else { return }
        var item = assignment(key)
        switch mode.indexOfSelectedItem {
        case 0: item.enabled = true; item.projectPath = nil; item.projectTitle = nil; item.workshopID = nil
        case 1: item.enabled = true
        default: item.enabled = false
        }
        draft.displays[key] = item
        // An unchosen custom mode is kept in the controls until a project is selected.
        if mode.indexOfSelectedItem == 1, item.projectPath == nil {
            choose.isEnabled = !busy; project.stringValue = "请从壁纸库选择一张独立壁纸"; updateRuntime()
        } else { refreshControls() }
        result.stringValue = "尚未应用"
    }
    @objc private func chooseProject() {
        guard !busy, let key = selectedKey else { return }
        onChooseProject? { [weak self] url, title in
            guard let self, self.window?.isVisible == true, !self.busy, self.keys.contains(key) else { return }
            var item = self.assignment(key)
            item.enabled = true; item.projectPath = url.standardizedFileURL.path; item.projectTitle = title
            item.workshopID = SavedWorkshopStore.recordForProject(url)?.id
            self.draft.displays[key] = item
            self.result.stringValue = "尚未应用"; self.refreshControls()
            self.window?.makeKeyAndOrderFront(nil)
        }
    }
    @objc private func audioChanged() {
        guard let key = selectedKey else { return }
        draft.preferredAudioDisplay = audio.state == .on ? key : nil
        result.stringValue = "尚未应用"
    }
    @objc private func editProperties() { if let key = selectedKey { onEditProperties?(key) } }
    @objc private func applyChanges() {
        guard !busy, let action = onApply, let key = selectedKey else { return }
        if mode.indexOfSelectedItem == 1, assignment(key).projectPath == nil { result.stringValue = "请先选择独立壁纸。"; return }
        let proposed = draft
        busy = true; refreshControls(); result.stringValue = "正在准备屏幕壁纸…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil; self.refreshControls() }
            do {
                try await action(proposed)
                self.draft = NativeDisplayStore.load(); self.result.stringValue = "显示器设置已应用并保存。"
            } catch is CancellationError { self.result.stringValue = "本次更改已取消。" }
            catch { self.result.stringValue = "未应用，保留原设置：" + error.localizedDescription }
        }
    }
    @objc private func showSaveProfile() {
        guard !busy, let action = onCaptureProfile, let window, window.attachedSheet == nil else { return }
        if mode.indexOfSelectedItem == 1, let key = selectedKey, assignment(key).projectPath == nil {
            result.stringValue = "请先选择独立壁纸。"; return
        }
        let proposed = draft
        busy = true; refreshControls(); result.stringValue = "正在准备配置文件…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.task = nil; self.refreshControls() }
            do {
                let captured = try await action(proposed)
                try Task.checkCancellation()
                let dialog = NativeProfileCollectionsController(saving: true, name: captured.name)
                dialog.onSave = { [weak self] name, hotkey in
                    let mutation: NativeProfileHotkeyMutation = hotkey.map { .set($0, removeConflictingBindings: false) } ?? .clear
                    let saved = try NativeProfileStore.saveNamed(captured, name: name, hotkey: mutation)
                    self?.result.stringValue = "配置文件已保存：" + saved.name
                }
                self.result.stringValue = ""; self.profileCollections = dialog; dialog.present(on: window)
            } catch is CancellationError { self.result.stringValue = "本次保存已取消。" }
            catch { self.result.stringValue = error.localizedDescription }
        }
    }
    @objc private func showLoadProfiles() {
        guard !busy, let action = onLoadProfile, let window, window.attachedSheet == nil else { return }
        let dialog = NativeProfileCollectionsController(saving: false)
        dialog.onLoad = { [weak self] profile in
            try await action(profile)
            guard let self else { return }
            self.draft = NativeDisplayStore.load(); self.refreshConnections()
            self.result.stringValue = "配置文件已加载：" + profile.name
        }
        profileCollections = dialog; dialog.present(on: window)
    }
    @discardableResult func cancelPendingApply() -> Task<Void, Never>? {
        let pending = task; pending?.cancel()
        guard let profile = profileCollections?.cancelPendingLoad() else { return pending }
        return Task { await pending?.value; await profile.value }
    }
    @objc private func closePanel() { close() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate(); timer = nil; task?.cancel(); profileCollections?.close()
    }
}
