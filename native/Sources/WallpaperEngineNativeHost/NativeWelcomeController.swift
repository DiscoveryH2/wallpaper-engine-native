import AppKit
import ServiceManagement

/// The native equivalent of the four-page first-run flow in the current
/// Wallpaper Engine public UI.  It deliberately records that the dialog was
/// *shown* before the user reaches the last page: the reference controller
/// writes `hasshownwelcomedialog` while it initialises the dialog, not after
/// its final button is pressed.
///
/// An existing native installation without this newer marker is never assumed
/// to be new.  The host asks this type before starting any restore path which
/// may materialise a preference or an Application Support directory.
enum NativeWelcomeState {
    static let key = "nativeWelcomeStateV1"
    static let productionBundleIdentifier = "io.wallpaper-engine-native.host"

    private struct State: Codable, Equatable {
        let format: Int
        let shown: Bool
    }

    enum AutomaticDecision: Equatable {
        case show
        case alreadyShown
        case legacyOrUnknown
    }

    /// Tests inject the two pieces of legacy evidence rather than inspecting a
    /// real application's preference domain or Application Support directory.
    /// A malformed marker is treated as legacy/unknown: an upgrade must never
    /// be surprised by a first-run dialog because a marker became unreadable.
    static func automaticDecision(defaults: UserDefaults,
                                  hasLegacyPreferences: Bool,
                                  applicationSupportExists: Bool) -> AutomaticDecision {
        if let data = defaults.data(forKey: key) {
            guard data.count <= 4096,
                  let state = try? JSONDecoder().decode(State.self, from: data),
                  state.format == 1, state.shown else { return .legacyOrUnknown }
            return .alreadyShown
        }
        guard defaults.object(forKey: key) == nil,
              !hasLegacyPreferences,
              !applicationSupportExists else { return .legacyOrUnknown }
        return .show
    }

    /// The normal application domain contains only product state at this
    /// point.  Any other stored key is conservative evidence of an earlier
    /// native installation.  This intentionally cannot distinguish an old
    /// installation whose every footprint was manually deleted from a new
    /// installation; that case remains manually accessible from the menu.
    static func hasLegacyPreferences(defaults: UserDefaults = .standard,
                                     bundleIdentifier: String = productionBundleIdentifier) -> Bool {
        guard let domain = defaults.persistentDomain(forName: bundleIdentifier) else { return false }
        return domain.keys.contains { $0 != key }
    }

    /// This is a path construction and an existence check only.  It must not
    /// create the directory just to decide whether first-run UI is eligible.
    static func applicationSupportExists(fileManager: FileManager = .default,
                                         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = homeDirectory.appendingPathComponent("Library/Application Support/WallpaperEngineNative", isDirectory: true)
        return fileManager.fileExists(atPath: path.path)
    }

    static func decisionForProductionLaunch(defaults: UserDefaults = .standard,
                                            fileManager: FileManager = .default,
                                            bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> AutomaticDecision {
        guard bundleIdentifier == productionBundleIdentifier else { return .legacyOrUnknown }
        return automaticDecision(defaults: defaults,
                                 hasLegacyPreferences: hasLegacyPreferences(defaults: defaults, bundleIdentifier: productionBundleIdentifier),
                                 applicationSupportExists: applicationSupportExists(fileManager: fileManager))
    }

    /// Persist the one-time marker before presenting an automatic welcome
    /// window.  A failed preference write does not make the window unsafe; it
    /// merely permits the same fresh install to be offered the dialog again.
    static func markShown(defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(State(format: 1, shown: true)), data.count <= 4096 else { return }
        defaults.set(data, forKey: key)
    }
}

@MainActor
private final class NativeWelcomePage: NSView {
    private var themeObserver: NSObjectProtocol?
    /// Welcome's deep-interface preview is deliberately local to this window.
    /// It must be able to show the ordinary dark skin even while an active
    /// seasonal override supplies Halloween or Winter to the rest of the app.
    var previewTheme: NativeInterfaceTheme? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        themeObserver = NotificationCenter.default.addObserver(forName: NativeInterfaceThemeRuntime.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
    }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let palette: NativeInterfaceThemePalette
        switch previewTheme {
        case .white: palette = .white
        case .dark: palette = .dark
        case .halloween: palette = .halloween
        case .winter: palette = .winter
        case nil: palette = NativeInterfaceThemeRuntime.palette(for: effectiveAppearance)
        }
        palette.background.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

/// First-run UI is intentionally native AppKit rather than a copied Windows
/// webview.  It preserves the official information order and one-time
/// semantics while mapping platform-specific Windows controls to macOS.
@MainActor
final class NativeWelcomeController: NSWindowController, NSWindowDelegate {
    private let preferences: () -> NativePlaybackPreferences
    private let applyPreferences: (NativePlaybackPreferences) -> Void
    private let loginState: () -> SMAppService.Status
    private let requestLoginItemChange: () -> Void
    private let defaults: UserDefaults
    private let automatic: Bool

    var onFinish: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    private let root = NativeWelcomePage(frame: .zero)
    private var pages: [NativeWelcomePage] = []
    private var dots: [NSButton] = []
    private var qualityButtons: [NSButton] = []
    private let status = NSTextField(wrappingLabelWithString: "")
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let browseWhenFinished = NSButton(checkboxWithTitle: "现在浏览壁纸", target: nil, action: nil)
    private let advanceButton = NSButton(title: "开始吧", target: nil, action: nil)
    private var page = 0 { didSet { updatePage() } }
    private var finished = false

    init(preferences: @escaping () -> NativePlaybackPreferences,
         applyPreferences: @escaping (NativePlaybackPreferences) -> Void,
         loginState: @escaping () -> SMAppService.Status,
         requestLoginItemChange: @escaping () -> Void,
         defaults: UserDefaults = .standard,
         automatic: Bool = false) {
        self.preferences = preferences
        self.applyPreferences = applyPreferences
        self.loginState = loginState
        self.requestLoginItemChange = requestLoginItemChange
        self.defaults = defaults
        self.automatic = automatic
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "欢迎使用 Wallpaper Engine Native"
        window.minSize = NSSize(width: 560, height: 430)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = root
        build()
        if automatic {
            // The reference controller assigns `qualityPreset = "medium"`
            // during welcome initialisation, and its settings watch applies
            // that preset immediately.  Restrict this to a truly fresh,
            // automatic presentation: manually reopening Welcome must never
            // overwrite an established user's quality choice.
            applyPreferences(NativeQualityPreset.medium.applying(to: preferences()))
            NativeWelcomeState.markShown(defaults: defaults)
            updateQualitySummary()
        }
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // The reference marks the dialog as seen before a user presses Finish.
        // Do not roll back a selected quality preset on a titlebar close.
        if automatic { NativeWelcomeState.markShown(defaults: defaults) }
        onClose?()
    }

    private func build() {
        for _ in 0..<4 {
            let view = NativeWelcomePage(frame: .zero)
            root.addSubview(view); pages.append(view)
        }
        buildIntroduction(in: pages[0])
        buildQuality(in: pages[1])
        buildMacOptions(in: pages[2])
        buildFinish(in: pages[3])

        for index in 0..<4 {
            let dot = NSButton(title: "●", target: self, action: #selector(selectPage(_:)))
            dot.tag = index; dot.identifier = .init("welcomePageDot\(index)")
            dot.bezelStyle = .inline; dot.font = .systemFont(ofSize: 14)
            dot.setAccessibilityLabel("欢迎页 \(index + 1) / 4")
            root.addSubview(dot); dots.append(dot)
        }
        browseWhenFinished.identifier = .init("welcomeBrowseWhenFinished")
        browseWhenFinished.state = .on
        browseWhenFinished.font = .systemFont(ofSize: 13)
        root.addSubview(browseWhenFinished)
        advanceButton.target = self; advanceButton.action = #selector(advance)
        advanceButton.identifier = .init("welcomeAdvance")
        advanceButton.bezelStyle = .rounded
        root.addSubview(advanceButton)
        root.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layout), name: NSView.frameDidChangeNotification, object: root)
        updatePage(); layout()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func headline(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .labelColor
        return label
    }

    private func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    private func add(_ view: NSView, to page: NativeWelcomePage, identifier: String? = nil) {
        if let identifier { view.identifier = .init(identifier) }
        page.addSubview(view)
    }

    private func buildIntroduction(in page: NativeWelcomePage) {
        add(headline("欢迎使用 Wallpaper Engine Native"), to: page, identifier: "welcomeTitle")
        add(body("这是一个原生 macOS 动态壁纸引擎。你可以在此选择图形品质与启动方式；之后仍可从菜单重新打开欢迎页。"), to: page, identifier: "welcomeIntroduction")
        let language = NSTextField(labelWithString: "界面语言：简体中文")
        language.font = .systemFont(ofSize: 15)
        add(language, to: page, identifier: "welcomeLanguage")
        let note = body("壁纸库、Steam 创意工坊、播放设置和原生创作工具均可在下一步完成后访问。")
        add(note, to: page, identifier: "welcomeIntroNote")
    }

    private func buildQuality(in page: NativeWelcomePage) {
        add(headline("选择图形品质"), to: page, identifier: "welcomeQualityTitle")
        add(body("此选择会立即保存，并用于后续动态壁纸。品质预设会同时设定帧率、抗锯齿、后处理、阴影、体积照明和反射。"), to: page, identifier: "welcomeQualityExplanation")
        for (index, preset) in NativeQualityPreset.allCases.enumerated() {
            let button = NSButton(title: preset.title, target: self, action: #selector(selectQuality(_:)))
            button.tag = index; button.identifier = .init("welcomeQuality" + preset.rawValue)
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .rounded; button.isEnabled = preset.supportedByDevice
            button.toolTip = preset.supportedByDevice ? "应用\(preset.title)品质预设" : "当前 Mac 不支持此预设要求的 MSAA x2。"
            page.addSubview(button); qualityButtons.append(button)
        }
        add(status, to: page, identifier: "welcomeQualitySummary")
        status.font = .systemFont(ofSize: 14); status.textColor = .secondaryLabelColor
    }

    private func buildMacOptions(in page: NativeWelcomePage) {
        add(headline("macOS 启动与外观"), to: page, identifier: "welcomeMacOptionsTitle")
        add(body("“登录时启动”只会在你点击按钮时由 macOS 登记；欢迎向导不会自动申请权限、开启登录项或改动系统设置。"), to: page, identifier: "welcomeLoginExplanation")
        let login = NSButton(title: "更改登录时启动", target: self, action: #selector(changeLoginItem))
        login.identifier = .init("welcomeChangeLoginItem")
        page.addSubview(login)
        loginStatus.font = .systemFont(ofSize: 13); loginStatus.textColor = .secondaryLabelColor
        add(loginStatus, to: page, identifier: "welcomeLoginStatus")
        let appearance = NSButton(checkboxWithTitle: "在此欢迎窗口预览深色界面", target: self, action: #selector(togglePreviewAppearance(_:)))
        appearance.identifier = .init("welcomePreviewAppearance")
        appearance.font = .systemFont(ofSize: 14)
        page.addSubview(appearance)
        add(body("关闭预览后，欢迎窗口会恢复当前保存的应用主题。"), to: page, identifier: "welcomeAppearanceExplanation")
    }

    private func buildFinish(in page: NativeWelcomePage) {
        add(headline("已经准备好了"), to: page, identifier: "welcomeFinishTitle")
        add(body("完成后可以立即浏览壁纸库，选择本机项目或连接 Steam 创意工坊内容。图形品质和登录项随时可在应用菜单中调整。"), to: page, identifier: "welcomeFinishExplanation")
    }

    @objc private func selectPage(_ sender: NSButton) { page = min(3, max(0, sender.tag)) }
    @objc private func selectQuality(_ sender: NSButton) {
        guard NativeQualityPreset.allCases.indices.contains(sender.tag) else { return }
        let preset = NativeQualityPreset.allCases[sender.tag]
        guard preset.supportedByDevice else { return }
        applyPreferences(preset.applying(to: preferences()))
        updateQualitySummary()
    }
    @objc private func changeLoginItem() { requestLoginItemChange(); updateLoginStatus() }
    private func setPreviewAppearance(_ enabled: Bool) {
        let theme: NativeInterfaceTheme? = enabled ? .dark : nil
        window?.appearance = enabled ? NSAppearance(named: .darkAqua) : nil
        root.previewTheme = theme
        for page in pages { page.previewTheme = theme }
    }
    @objc private func togglePreviewAppearance(_ sender: NSButton) {
        setPreviewAppearance(sender.state == .on)
    }
    @objc private func advance() {
        if page < 3 { page += 1; return }
        finish()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        if automatic { NativeWelcomeState.markShown(defaults: defaults) }
        let browse = browseWhenFinished.state == .on
        close()
        onFinish?(browse)
    }

    private func updateQualitySummary() {
        let value = preferences()
        let graphics = value.graphics
        status.stringValue = "当前：\(value.general.framesPerSecond) 帧/秒 · \(graphics.antialiasing.title) · 后处理\(graphics.postProcessing.title) · 阴影\(graphics.shadows.title) · \(graphics.reflections ? "开启" : "关闭")反射"
        for (index, button) in qualityButtons.enumerated() {
            let preset = NativeQualityPreset.allCases[index]
            let selected = preset == graphics.preset
            button.state = selected ? .on : .off
            // An inactive macOS rounded button may intentionally mute its
            // pressed bezel. Keep the persisted choice unambiguous with a
            // compact title marker as well as the AppKit button state.
            button.title = selected ? "✓ \(preset.title)" : preset.title
            button.contentTintColor = selected ? .controlAccentColor : .labelColor
        }
    }

    private func updateLoginStatus() {
        loginStatus.stringValue = Self.loginPresentation(loginState())
    }

    static func loginPresentation(_ state: SMAppService.Status) -> String {
        switch state {
        case .notRegistered: return "登录时启动：未启用"
        case .enabled: return "登录时启动：已由 macOS 启用"
        case .requiresApproval: return "登录时启动：等待 macOS 允许"
        case .notFound: return "登录时启动：系统尚未确认状态"
        @unknown default: return "登录时启动：系统返回未知状态"
        }
    }

    private func updatePage() {
        guard !pages.isEmpty else { return }
        for (index, view) in pages.enumerated() { view.isHidden = index != page }
        for (index, dot) in dots.enumerated() {
            let selected = index == page
            // The glyph change keeps the current page distinguishable even in
            // an inactive AppKit window where tint alone is intentionally
            // subdued by the system.
            dot.title = selected ? "●" : "○"
            dot.contentTintColor = selected ? .controlAccentColor : .tertiaryLabelColor
        }
        browseWhenFinished.isHidden = page != 3
        advanceButton.title = page == 0 ? "开始吧" : page == 3 ? "全部完成" : "下一步"
        updateQualitySummary(); updateLoginStatus(); layout()
    }

    @objc private func layout() {
        let bounds = root.bounds
        let content = NSRect(x: 34, y: 28, width: max(1, bounds.width - 68), height: max(1, bounds.height - 122))
        for view in pages {
            view.frame = content
            layoutPage(view)
        }
        let dotWidth: CGFloat = 24
        let dotsStart = (bounds.width - CGFloat(dots.count) * dotWidth) / 2
        for (index, dot) in dots.enumerated() { dot.frame = NSRect(x: dotsStart + CGFloat(index) * dotWidth, y: bounds.height - 47, width: dotWidth, height: 20) }
        browseWhenFinished.frame = NSRect(x: 34, y: bounds.height - 42, width: 180, height: 22)
        advanceButton.frame = NSRect(x: bounds.width - 132, y: bounds.height - 49, width: 98, height: 30)
    }

    private func layoutPage(_ page: NativeWelcomePage) {
        let all = page.subviews
        guard let title = all.first(where: { $0.identifier?.rawValue.hasSuffix("Title") == true }) else { return }
        title.frame = NSRect(x: 0, y: 4, width: page.bounds.width, height: 32)
        if page === pages[0] {
            let content = all.filter { $0 !== title }
            if content.indices.contains(0) { content[0].frame = NSRect(x: 0, y: 58, width: page.bounds.width, height: 60) }
            if content.indices.contains(1) { content[1].frame = NSRect(x: 0, y: 148, width: page.bounds.width, height: 24) }
            if content.indices.contains(2) { content[2].frame = NSRect(x: 0, y: 194, width: page.bounds.width, height: 52) }
        } else if page === pages[1] {
            let content = all.filter { $0 !== title }
            if content.indices.contains(0) { content[0].frame = NSRect(x: 0, y: 48, width: page.bounds.width, height: 48) }
            // Keep the explanatory label out of the preset-button row.  Its
            // identifier shares the welcomeQuality prefix, so matching that
            // prefix alone compresses the label into a button-sized frame.
            let buttons = content.compactMap { $0 as? NSButton }.filter { $0.identifier?.rawValue.hasPrefix("welcomeQuality") == true }
            let width = (page.bounds.width - CGFloat(max(0, buttons.count - 1)) * 6) / CGFloat(max(1, buttons.count))
            for (index, button) in buttons.enumerated() { button.frame = NSRect(x: CGFloat(index) * (width + 6), y: 122, width: width, height: 30) }
            status.frame = NSRect(x: 0, y: 186, width: page.bounds.width, height: 48)
        } else if page === pages[2] {
            let content = all.filter { $0 !== title }
            if content.indices.contains(0) { content[0].frame = NSRect(x: 0, y: 48, width: page.bounds.width, height: 45) }
            if content.indices.contains(1) { content[1].frame = NSRect(x: 0, y: 122, width: 150, height: 30) }
            if content.indices.contains(2) { content[2].frame = NSRect(x: 170, y: 120, width: max(1, page.bounds.width - 170), height: 38) }
            if content.indices.contains(3) { content[3].frame = NSRect(x: 0, y: 194, width: page.bounds.width, height: 24) }
            if content.indices.contains(4) { content[4].frame = NSRect(x: 0, y: 236, width: page.bounds.width, height: 48) }
        } else {
            let content = all.filter { $0 !== title }
            if let text = content.first { text.frame = NSRect(x: 0, y: 58, width: page.bounds.width, height: 64) }
        }
    }

    // Isolated AppKit tests use these narrow hooks; they are not menu actions.
    var welcomeCurrentPage: Int { page }
    var welcomeBrowseSelected: Bool { browseWhenFinished.state == .on }
    func welcomeSelectPage(_ index: Int) { page = min(3, max(0, index)) }
    func welcomeSelectQuality(_ preset: NativeQualityPreset) {
        guard let index = NativeQualityPreset.allCases.firstIndex(of: preset) else { return }
        let button = qualityButtons[index]
        guard button.isEnabled else { return }
        selectQuality(button)
    }
    func welcomeSetBrowseSelected(_ value: Bool) { browseWhenFinished.state = value ? .on : .off }
    func welcomeSetPreviewAppearance(_ value: Bool) { setPreviewAppearance(value) }
    func welcomeAdvance() { advance() }
}

/// Owns the one currently-presented welcome controller.  A controller keeps a
/// completion guard after it is closed, so retaining it would make a later
/// manual "欢迎使用…" invocation appear but leave its final button inert.
/// Keeping this small lifecycle rule outside `AppDelegate` lets the exact
/// close/reopen path be exercised without starting the application host.
@MainActor
final class NativeWelcomePresentationStore {
    private(set) var currentController: NativeWelcomeController?

    func controllerForPresentation(make: () -> NativeWelcomeController) -> NativeWelcomeController {
        if currentController?.window?.isVisible == false { currentController = nil }
        if let currentController { return currentController }
        let controller = make()
        let originalClose = controller.onClose
        controller.onClose = { [weak self, weak controller] in
            originalClose?()
            self?.release(controller)
        }
        currentController = controller
        return controller
    }

    private func release(_ closing: NativeWelcomeController?) {
        guard currentController === closing else { return }
        currentController = nil
    }
}
