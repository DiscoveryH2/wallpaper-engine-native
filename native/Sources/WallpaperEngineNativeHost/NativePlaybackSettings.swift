import AppKit

@MainActor
private final class NativeSettingsTab: NSButton {
    override var intrinsicContentSize: NSSize { NSSize(width: ceil(title.size(withAttributes: [.font: NativeLibraryBrowserStyle.font(16.8)]).width) + 30, height: 34) }
    override func draw(_ dirtyRect: NSRect) {
        let accent = NativeLibraryBrowserStyle.accent(effectiveAppearance)
        (state == .on ? accent : NativeLibraryBrowserStyle.background(effectiveAppearance)).setFill(); bounds.fill()
        accent.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: NativeLibraryBrowserStyle.font(16.8), .foregroundColor: state == .on ? NSColor.white : NativeLibraryBrowserStyle.foreground(effectiveAppearance)]
        let size = title.size(withAttributes: attributes)
        title.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2), withAttributes: attributes)
        if window?.firstResponder === self { NSColor.keyboardFocusIndicatorColor.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3)).stroke() }
    }
}

@MainActor
private final class NativeSettingsContent: NativeSettingsFlippedView {
    var onResize: (() -> Void)?
    override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); onResize?() }
    override func draw(_ rect: NSRect) { NativeLibraryBrowserStyle.background(effectiveAppearance).setFill(); rect.fill() }
}

@MainActor
private class NativeSettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class NativeSettingsGroup: NativeSettingsFlippedView {
    let title: String
    var rows: [NSView] = []
    init(_ title: String) { self.title = title; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() { row.frame = NSRect(x: 10, y: CGFloat(15 + index * 34), width: max(0, bounds.width - 20), height: 34) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let background = NativeLibraryBrowserStyle.background(effectiveAppearance)
        let border = NativeLibraryBrowserStyle.dark(effectiveAppearance) ? NSColor(white: 59.5 / 255, alpha: 1) : .init(white: 187.0 / 255, alpha: 1)
        border.setStroke(); NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 8).offsetBy(dx: 0, dy: 3)).stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NativeLibraryBrowserStyle.font(14), .foregroundColor: NativeLibraryBrowserStyle.foreground(effectiveAppearance)]
        let label = title as NSString, size = label.size(withAttributes: attrs)
        background.setFill(); NSRect(x: 5, y: 0, width: size.width + 10, height: 20).fill()
        label.draw(at: NSPoint(x: 10, y: 0), withAttributes: attrs)
    }
}

@MainActor
private final class NativeSettingsRow: NativeSettingsFlippedView {
    let label: NSTextField, control: NSView
    init(_ title: String, _ control: NSView) {
        label = NSTextField(labelWithString: title); self.control = control
        super.init(frame: .zero); label.font = NativeLibraryBrowserStyle.font(14)
        label.lineBreakMode = .byTruncatingTail; addSubview(label); addSubview(control)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        if label.stringValue.isEmpty { label.frame = .zero; control.frame = NSRect(x: 0, y: 4, width: bounds.width, height: 26); return }
        let width: CGFloat = min(260, max(210, bounds.width * 0.42)), split = bounds.width - width
        label.frame = NSRect(x: 0, y: 8, width: max(0, split - 12), height: 20)
        control.frame = NSRect(x: split, y: 4, width: width, height: 26)
    }
}

@MainActor
private final class NativeSettingsPresetRow: NativeSettingsFlippedView {
    let buttons: [NativeLibraryFooterButton]
    init(buttons: [NativeLibraryFooterButton]) {
        self.buttons = buttons; super.init(frame: .zero)
        buttons.forEach(addSubview)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        // Official flex:1 buttons share a single border via margin-left:-1px.
        let width = (bounds.width + CGFloat(buttons.count - 1)) / CGFloat(buttons.count)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * (width - 1), y: 0, width: width, height: 26)
        }
    }
}

@MainActor
private final class NativeSettingsFrameRateRow: NativeSettingsFlippedView {
    let slider: NSSlider, value: NSTextField
    init(slider: NSSlider, value: NSTextField) {
        self.slider = slider; self.value = value; super.init(frame: .zero)
        addSubview(slider); addSubview(value)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        slider.frame = NSRect(x: 0, y: 0, width: max(0, bounds.width - 38), height: 26)
        value.frame = NSRect(x: max(0, bounds.width - 30), y: 3, width: 30, height: 20)
    }
}

@MainActor
final class NativePlaybackSettingsController: NSWindowController, NSWindowDelegate {
    private let monitor: NativePlaybackPolicyMonitor
    private let playbackReport: () -> String
    private let root = NativeSettingsContent()
    private let scroll = NSScrollView(), settingsDocument = NativeSettingsFlippedView()
    private var tabs: [NSButton] = []
    private var presetButtons: [NativeLibraryFooterButton] = []
    private var page = 0
    private var pageGroups: [[NativeSettingsGroup]] = [[], [], []]
    private let focus = NSPopUpButton(), maximized = NSPopUpButton(), fullscreen = NSPopUpButton(), audio = NSPopUpButton(), battery = NSPopUpButton()
    private let interfaceTheme = NSPopUpButton()
    private let seasonalTheme = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var audioDetection: NativeLibraryFooterButton!
    private let lowPower = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let loadingWait = NSPopUpButton()
    private let fps = NSSlider(value: 60, minValue: 10, maxValue: 240, target: nil, action: nil)
    private let shadowQuality = NSPopUpButton()
    private let volumetricQuality = NSPopUpButton()
    private let antialiasing = NSPopUpButton()
    private let postProcessing = NSPopUpButton()
    private let textureResolution = NSPopUpButton()
    private let reflections = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let fpsValue = NSTextField(labelWithString: "60")
    private let status = NSTextField(wrappingLabelWithString: "")
    private var acceptButton: NSButton!, cancelButton: NSButton!
    private var timer: Timer?
    private var snapshot: NativePlaybackPreferenceSnapshot?
    private var applicationRulesController: NativeApplicationRulesController?
    /// Hotkeys follow the official modal's immediate-persistence behavior.
    /// They deliberately do not participate in the outer Settings snapshot:
    /// cancelling Settings must not undo an edit already made in this sheet.
    private var hotkeySettingsController: NativeHotkeySettingsController?

    init(monitor: NativePlaybackPolicyMonitor, report: @escaping () -> String) {
        self.monitor = monitor; playbackReport = report
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Wallpaper Engine Native · 设置"; window.minSize = NSSize(width: 680, height: 600); window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self; window.contentView = root
        acceptButton = NativeLibraryFooterButton(title: "确认", primary: true, symbol: nil, target: self, action: #selector(accept))
        cancelButton = NativeLibraryFooterButton(title: "取消", primary: false, symbol: nil, target: self, action: #selector(cancel))
        root.onResize = { [weak self] in self?.layout() }
        for (index, title) in ["性能", "常规", "关于"].enumerated() {
            let button = NativeSettingsTab(title: title, target: self, action: #selector(selectPage(_:)))
            button.tag = index; button.identifier = .init("settingsTab\(index)"); button.setAccessibilityLabel(title)
            root.addSubview(button); tabs.append(button)
        }
        scroll.documentView = settingsDocument; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay; root.addSubview(scroll)
        acceptButton.target = self; acceptButton.action = #selector(accept); acceptButton.identifier = .init("settingsConfirm"); acceptButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancel); cancelButton.identifier = .init("settingsCancel"); cancelButton.keyEquivalent = "\u{1b}"
        root.addSubview(acceptButton); root.addSubview(cancelButton)
        buildPerformance(); buildGeneral(); buildAbout(); refresh(); layout(); window.center()
    }
    required init?(coder: NSCoder) { nil }

    private func group(_ title: String, page: Int, rows: [(String, NSView)]) {
        let group = NativeSettingsGroup(title)
        for (title, control) in rows { let row = NativeSettingsRow(title, control); group.rows.append(row); group.addSubview(row) }
        pageGroups[page].append(group); settingsDocument.addSubview(group)
    }
    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text); label.font = NativeLibraryBrowserStyle.font(12); label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail; label.toolTip = text; return label
    }
    private func unavailable(_ title: String, id: String, reason: String) -> NSPopUpButton {
        let control = NSPopUpButton(); control.addItem(withTitle: title); control.isEnabled = false
        control.identifier = .init(id); control.toolTip = reason; control.setAccessibilityHelp(reason); return control
    }
    private func actions(_ control: NSPopUpButton, id: String, values: [NativePlaybackAction]) {
        control.identifier = .init(id); control.target = self; control.action = #selector(changed)
        control.font = NativeLibraryBrowserStyle.font(14); control.autoenablesItems = false
        for action in values { control.addItem(withTitle: action.title(multimonitor: NSScreen.screens.count > 1)); control.lastItem?.representedObject = action.rawValue }
    }
    private func buildPerformance() {
        let windowActions: [NativePlaybackAction] = [.run, .mute, .pause, .pauseall]
        actions(focus, id: "settingsPlaybackFocus", values: windowActions)
        // Official SettingsCtrl offers one global `stop` action here.  The
        // host releases all desktop presentations when any matching monitor
        // is covered/maximized; it is not a per-display stop option.
        actions(maximized, id: "settingsPlaybackMaximized", values: windowActions + [.stop])
        actions(fullscreen, id: "settingsPlaybackFullscreen", values: windowActions + [.stop])
        // Choosing an action merely stores policy intent.  It cannot invoke a
        // Process Tap; that transition is reserved for the separate button.
        actions(audio, id: "settingsPlaybackAudio", values: [.run, .mute, .pause])
        audio.setAccessibilityLabel("其他应用程序播放音频时")
        audio.toolTip = "此处只设置壁纸动作。要开始检测，需点击下方按钮并确认系统音频检测用途。"
        actions(battery, id: "settingsPlaybackBattery", values: [.run, .pause, .stop])
        audioDetection = NativeLibraryFooterButton(title: "启用音频检测…", primary: false, symbol: "waveform", target: self, action: #selector(toggleAudioDetection))
        audioDetection.identifier = .init("settingsAudioDetection")
        let sleep = unavailable("暂停", id: "settingsPlaybackSleep", reason: "目前显示器休眠时暂停；恢复后继续播放。")
        let rules = NSButton(title: "编辑", target: self, action: #selector(editApplicationRules)); rules.identifier = .init("settingsApplicationRules")
        rules.toolTip = "按应用程序控制壁纸的运行、静音、暂停或停止。"
        group("回放", page: 0, rows: [("其他应用程序成为焦点时：", focus), ("其他应用程序最大化时：", maximized),
              ("其他应用程序全屏时：", fullscreen), ("其他应用程序播放音频时：", audio), ("音频检测：", audioDetection), ("显示屏休眠时：", sleep),
              ("笔记本电脑使用电池时：", battery), ("应用程序规则：", rules)])
        fps.identifier = .init("settingsFrameRate"); fps.target = self; fps.action = #selector(changed); fps.isContinuous = true
        fps.setAccessibilityLabel("帧率"); fps.toolTip = "调整 Metal / OpenGL 场景的动画帧率；视频按文件帧率播放，网页帧率控制仍在开发。"
        fpsValue.font = NativeLibraryBrowserStyle.font(14); fpsValue.alignment = .right
        let fpsRow = NativeSettingsFrameRateRow(slider: fps, value: fpsValue)
        for preset in NativeQualityPreset.allCases {
            let button = NativeLibraryFooterButton(title: preset.title, primary: true, symbol: nil, target: self, action: #selector(applyPreset(_:)))
            button.identifier = .init("settingsPreset" + preset.rawValue)
            button.isEnabled = preset.supportedByDevice
            button.toolTip = preset.supportedByDevice ? "应用\(preset.title)品质预设（\(preset.framesPerSecond) 帧/秒）。" : "当前图形设备不支持此预设要求的 MSAA x2。"
            presetButtons.append(button)
        }
        let presets = NativeSettingsPresetRow(buttons: presetButtons)
        shadowQuality.identifier = .init("settingsShadows"); shadowQuality.setAccessibilityLabel("阴影")
        shadowQuality.font = NativeLibraryBrowserStyle.font(14)
        shadowQuality.target = self; shadowQuality.action = #selector(changed)
        for quality in NativeShadowQuality.allCases {
            shadowQuality.addItem(withTitle: quality.title); shadowQuality.lastItem?.representedObject = quality.rawValue
        }
        shadowQuality.toolTip = "控制原生模型的点光源和聚光灯阴影；方向光阴影及自定义材质仍在适配。"
        volumetricQuality.identifier = .init("settingsVolumetrics"); volumetricQuality.setAccessibilityLabel("体积照明")
        volumetricQuality.font = NativeLibraryBrowserStyle.font(14)
        volumetricQuality.target = self; volumetricQuality.action = #selector(changed)
        for quality in NativeVolumetricQuality.allCases {
            volumetricQuality.addItem(withTitle: quality.title); volumetricQuality.lastItem?.representedObject = quality.rawValue
        }
        volumetricQuality.toolTip = "控制原生点光源的体积照明；聚光灯与作者自定义效果仍在适配。"
        antialiasing.identifier = .init("settingsAntialiasing"); antialiasing.setAccessibilityLabel("抗锯齿")
        antialiasing.font = NativeLibraryBrowserStyle.font(14)
        antialiasing.target = self; antialiasing.action = #selector(changed)
        antialiasing.autoenablesItems = false
        for quality in NativeAntialiasing.allCases {
            antialiasing.addItem(withTitle: quality.title); antialiasing.lastItem?.representedObject = quality.rawValue
            antialiasing.lastItem?.isEnabled = quality.supportedByDevice
            if !quality.supportedByDevice { antialiasing.lastItem?.toolTip = "当前 Mac 的图形设备不支持此采样数。" }
        }
        antialiasing.toolTip = "平滑场景中的几何边缘。更高采样数会增加显存占用和图形负载；灰色选项不受当前设备支持。"
        postProcessing.identifier = .init("settingsPostProcessing"); postProcessing.setAccessibilityLabel("后处理")
        postProcessing.font = NativeLibraryBrowserStyle.font(14)
        postProcessing.target = self; postProcessing.action = #selector(changed)
        for quality in NativePostProcessingQuality.allCases {
            postProcessing.addItem(withTitle: quality.title); postProcessing.lastItem?.representedObject = quality.rawValue
        }
        postProcessing.toolTip = "控制场景泛光；超高保留作品的 HDR 场景处理。当前显示输出为 SDR。"
        textureResolution.identifier = .init("settingsTextureResolution"); textureResolution.setAccessibilityLabel("纹理分辨率")
        textureResolution.font = NativeLibraryBrowserStyle.font(14)
        textureResolution.target = self; textureResolution.action = #selector(changed)
        for quality in NativeTextureResolution.allCases {
            textureResolution.addItem(withTitle: quality.title); textureResolution.lastItem?.representedObject = quality.rawValue
        }
        textureResolution.toolTip = "高性能使用作品自带的下一层纹理；自动根据画布和输出尺寸选择。只有一层纹理的作品保持原质量。"
        reflections.identifier = .init("settingsReflection"); reflections.setAccessibilityLabel("反射")
        reflections.target = self; reflections.action = #selector(changed)
        reflections.toolTip = "控制 Metal / OpenGL 原生模型材质的反射；作品自行绘制的镜面和网页、视频内容不受此开关影响。"
        group("品质", page: 0, rows: [("", presets), ("帧率", fpsRow),
            ("抗锯齿", antialiasing),
            ("后处理", postProcessing),
            ("纹理分辨率", textureResolution),
            ("阴影", shadowQuality),
            ("体积照明", volumetricQuality),
            ("反射", reflections)])
    }
    private func buildGeneral() {
        lowPower.identifier = .init("settingsLowPower"); lowPower.setAccessibilityLabel("macOS 低电量模式时暂停")
        lowPower.target = self; lowPower.action = #selector(changed)
        loadingWait.identifier = .init("wallpaperLoadingTimeout"); loadingWait.setAccessibilityLabel("网页与视频加载等待时间")
        for timeout in NativeLoadingTimeout.allCases { loadingWait.addItem(withTitle: timeout.title); loadingWait.lastItem?.tag = timeout.rawValue }
        loadingWait.target = self; loadingWait.action = #selector(changed)
        let hotkeys = NSButton(title: "编辑", target: self, action: #selector(editHotkeys))
        hotkeys.identifier = .init("settingsHotkeys"); hotkeys.setAccessibilityLabel("热键")
        hotkeys.toolTip = "配置全局操作、壁纸、播放列表和配置文件的热键。"
        interfaceTheme.identifier = .init("settingsInterfaceTheme"); interfaceTheme.setAccessibilityLabel("主题")
        interfaceTheme.target = self; interfaceTheme.action = #selector(changedTheme(_:)); interfaceTheme.font = NativeLibraryBrowserStyle.font(14)
        for theme in NativeInterfaceTheme.allCases {
            interfaceTheme.addItem(withTitle: theme.title); interfaceTheme.lastItem?.representedObject = theme.rawValue
        }
        seasonalTheme.identifier = .init("settingsSeasonalTheme"); seasonalTheme.setAccessibilityLabel("使用季节主题")
        seasonalTheme.target = self; seasonalTheme.action = #selector(changedTheme(_:))
        seasonalTheme.toolTip = "在万圣节和冬季期间临时使用对应主题；结束后恢复你选择的主题。"
        group("外观", page: 1, rows: [("主题：", interfaceTheme), ("使用季节主题：", seasonalTheme),
              ("界面语言", note("简体中文"))])
        group("macOS", page: 1, rows: [("热键：", hotkeys), ("低电量模式时暂停", lowPower),
              ("网页与视频加载等待", loadingWait), ("加载等待", note("用于新打开或重新加载的壁纸"))])
        status.font = NativeLibraryBrowserStyle.font(12); status.textColor = .secondaryLabelColor; status.isSelectable = true
        group("播放状态", page: 1, rows: [])
        pageGroups[1].last?.addSubview(status)
    }
    private func buildAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版本"
        group("Wallpaper Engine Native", page: 2, rows: [("版本", note(version)), ("运行环境", note("macOS 原生")),
              ("界面参考", note("Steam 稳定版 · 简体中文")), ("实现", note("独立开发的 macOS 壁纸引擎")),
              ("兼容状态", note("持续开发中；尚未完整复现全部功能"))])
    }
    private func layout() {
        guard isWindowLoaded else { return }
        var x: CGFloat = 19
        for tab in tabs {
            tab.state = tab.tag == page ? .on : .off; tab.needsDisplay = true
            let width = tab.intrinsicContentSize.width; tab.frame = NSRect(x: x, y: 5, width: width, height: 34); x += width + 4
        }
        scroll.frame = NSRect(x: 19, y: 44, width: max(1, root.bounds.width - 38), height: max(1, root.bounds.height - 92))
        let width = scroll.contentSize.width
        var y: CGFloat = 20
        for (index, groups) in pageGroups.enumerated() {
            for group in groups {
                group.isHidden = index != page
                guard index == page else { continue }
                let height = index == 1 && group.rows.isEmpty ? CGFloat(340) : CGFloat(group.rows.count * 34 + 30)
                group.frame = NSRect(x: 0, y: y, width: width, height: height); group.needsLayout = true
                if index == 1 && group.rows.isEmpty { status.frame = group.bounds.insetBy(dx: 10, dy: 22) }
                y += height + 10
            }
        }
        settingsDocument.setFrameSize(NSSize(width: width, height: max(y, scroll.contentSize.height)))
        cancelButton.frame = NSRect(x: root.bounds.width - 99, y: root.bounds.height - 36, width: 80, height: 30)
        acceptButton.frame = NSRect(x: root.bounds.width - 185, y: root.bounds.height - 36, width: 80, height: 30)
    }
    @objc private func selectPage(_ sender: NSButton) { page = sender.tag; layout(); scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
    func present() {
        if snapshot == nil { snapshot = .init() }
        refresh(); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func refresh() {
        let preferences = monitor.environment.preferences, general = monitor.environment.preferences.general
        let interfaceThemeSettings = NativeInterfaceThemeStore.load()
        interfaceTheme.select(interfaceTheme.itemArray.first { $0.representedObject as? String == interfaceThemeSettings.theme.rawValue })
        seasonalTheme.state = interfaceThemeSettings.seasonalEnabled ? .on : .off
        for (control, value, perDisplay) in [(focus, general.focus, true), (maximized, general.maximized, true),
                                              (fullscreen, general.fullscreen, true), (audio, general.audio, false),
                                              (battery, general.battery, false)] {
            if let item = control.itemArray.first(where: { $0.representedObject as? String == value.rawValue }) { control.select(item) }
            for item in control.itemArray {
                if let raw = item.representedObject as? String, let action = NativePlaybackAction(rawValue: raw) {
                    item.title = action.title(multimonitor: perDisplay && NSScreen.screens.count > 1)
                }
            }
        }
        let audioState = monitor.audioDetectionState
        let configurable = monitor.audioDetectionConfigurable
        audio.isEnabled = configurable
        audio.toolTip = configurable ? "此处只设置壁纸动作。要开始检测，需点击下方按钮并确认系统音频检测用途。" : monitor.audioDetectionStatusText
        switch audioState {
        case .active:
            audioDetection.title = "停止音频检测"; audioDetection.isEnabled = true
        case .starting, .stopping:
            audioDetection.title = audioState == .starting ? "正在启用…" : "正在停止…"; audioDetection.isEnabled = false
        case .waitingForApplicationTargets:
            audioDetection.title = "重新检测目标应用…"; audioDetection.isEnabled = configurable
        case .unavailable:
            audioDetection.title = "重试音频检测…"; audioDetection.isEnabled = configurable
        case .off:
            audioDetection.title = "启用音频检测…"; audioDetection.isEnabled = configurable
        case .unsupported:
            audioDetection.title = "音频检测不可用"; audioDetection.isEnabled = false
        }
        audioDetection.toolTip = monitor.audioDetectionStatusText
        lowPower.state = preferences.pauseInLowPowerMode ? .on : .off; loadingWait.selectItem(withTag: preferences.loadingTimeout.rawValue)
        reflections.state = preferences.graphics.reflections ? .on : .off
        shadowQuality.select(shadowQuality.itemArray.first { $0.representedObject as? String == preferences.graphics.shadows.rawValue })
        volumetricQuality.select(volumetricQuality.itemArray.first { $0.representedObject as? String == preferences.graphics.volumetrics.rawValue })
        antialiasing.select(antialiasing.itemArray.first { $0.representedObject as? String == preferences.graphics.antialiasing.rawValue })
        postProcessing.select(postProcessing.itemArray.first { $0.representedObject as? String == preferences.graphics.postProcessing.rawValue })
        textureResolution.select(textureResolution.itemArray.first { $0.representedObject as? String == preferences.graphics.textureResolution.rawValue })
        fps.integerValue = general.framesPerSecond; fpsValue.stringValue = String(general.framesPerSecond)
        status.stringValue = (monitor.environment.onBattery ? "当前由电池供电。" : "当前未使用电池供电。") + "\n" + (monitor.environment.lowPowerMode ? "低电量模式：已开启。" : "低电量模式：未开启。") +
            (monitor.environment.windowGeometryAvailable ? "" : "\n暂时无法判断窗口范围，保留上次窗口规则状态。") +
            (monitor.applicationRulesNotice.map { "\n" + $0 } ?? "") + "\n\n" + playbackReport()
    }
    @objc private func applyPreset(_ sender: NSButton) {
        guard let index = presetButtons.firstIndex(where: { $0 === sender }), sender.isEnabled else { return }
        let preset = NativeQualityPreset.allCases[index]
        guard preset.supportedByDevice else { return }
        monitor.updatePreferences(preset.applying(to: monitor.environment.preferences))
        refresh()
    }
    @objc private func changed() {
        var preferences = monitor.environment.preferences
        func value(_ control: NSPopUpButton) -> NativePlaybackAction { NativePlaybackAction(rawValue: control.selectedItem?.representedObject as? String ?? "run") ?? .run }
        preferences.general = .init(focus: value(focus), maximized: value(maximized), fullscreen: value(fullscreen),
                                    battery: value(battery), audio: value(audio), framesPerSecond: Int(fps.doubleValue.rounded()))
        preferences.graphics.antialiasing = NativeAntialiasing(rawValue: antialiasing.selectedItem?.representedObject as? String ?? "none") ?? .none
        preferences.graphics.postProcessing = NativePostProcessingQuality(rawValue: postProcessing.selectedItem?.representedObject as? String ?? "ultra") ?? .ultra
        preferences.graphics.textureResolution = NativeTextureResolution(rawValue: textureResolution.selectedItem?.representedObject as? String ?? "full") ?? .full
        preferences.graphics.reflections = reflections.state == .on
        preferences.graphics.shadows = NativeShadowQuality(rawValue: shadowQuality.selectedItem?.representedObject as? String ?? "high") ?? .high
        preferences.graphics.volumetrics = NativeVolumetricQuality(rawValue: volumetricQuality.selectedItem?.representedObject as? String ?? "high") ?? .high
        // Keep the legacy boolean conservative for an older build that cannot
        // decode the new `stop` enum value: its fallback must pause rather
        // than unexpectedly keep a fullscreen-covered wallpaper running.
        preferences.pauseWhenCovered = [.pause, .pauseall, .stop].contains(preferences.general.fullscreen)
        preferences.pauseInLowPowerMode = lowPower.state == .on
        preferences.loadingTimeout = NativeLoadingTimeout(rawValue: loadingWait.selectedItem?.tag ?? 60) ?? .normal
        monitor.updatePreferences(preferences); refresh()
    }
    @objc private func changedTheme(_ sender: Any?) {
        guard let sender = sender as? NSView else { return }
        if sender === interfaceTheme {
            let theme = NativeInterfaceTheme(rawValue: interfaceTheme.selectedItem?.representedObject as? String ?? "") ?? .white
            NativeInterfaceThemeStore.saveTheme(theme)
        } else if sender === seasonalTheme {
            NativeInterfaceThemeStore.saveSeasonalEnabled(seasonalTheme.state == .on)
        } else {
            return
        }
        NativeInterfaceThemeRuntime.applyStoredTheme()
        // Theme actions do not get to bypass normal playback preference
        // synchronization, but unrelated controls must never materialize or
        // overwrite a theme value merely because Settings is open.
        changed()
    }
    @objc private func toggleAudioDetection() {
        switch NativeAudioDetectionSettingsAction.resolve(state: monitor.audioDetectionState,
                                                          configurable: monitor.audioDetectionConfigurable,
                                                          needsObservation: monitor.audioDetectionNeedsObservation) {
        case .stop:
            audioDetection.isEnabled = false
            monitor.stopAudioDetection { [weak self] _ in self?.refresh() }
        case .disabled:
            refresh()
        case .explainNoObservationNeeded:
            let alert = NSAlert()
            alert.messageText = "没有需要检测的音频动作"
            alert.informativeText = "请先将“其他应用程序播放音频时”设为“静音”或“暂停”，或保存一个非“保持运行”的音频应用程序规则。此操作不会请求系统权限。"
            alert.addButton(withTitle: "好")
            if let window { alert.beginSheetModal(for: window) }
        case .requestConfirmation:
            let alert = NSAlert()
            alert.messageText = "启用音频检测？"
            alert.informativeText = "为了在其他应用实际播放音频时执行你设置的壁纸动作，macOS 可能要求“系统音频捕获”权限。检测只保留实时峰值，不保存、上传或回放音频；你可随时在此停止。"
            alert.addButton(withTitle: "启用")
            alert.addButton(withTitle: "取消")
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self] response in
                NativeAudioDetectionSettingsAction.startIfConfirmed(response == .alertFirstButtonReturn) {
                    self?.audioDetection.isEnabled = false
                    self?.monitor.enableAudioDetectionFromExplicitUserAction { _ in self?.refresh() }
                }
            }
        }
    }
    @objc private func accept() { snapshot = nil; close() }
    @objc private func editApplicationRules() {
        guard let window else { return }
        do {
            let controller = try NativeApplicationRulesController(rules: monitor.applicationRules,
                wallpapers: { NativeApplicationRuleLibrary.wallpapers() }, playlists: { try NativePlaylistStore.saved().lists },
                profiles: { try NativeProfileStore.saved().profiles },
                audioConditionConfigurable: monitor.audioDetectionConfigurable) { [weak self] rules in
                guard let self else { throw NativeApplicationRuleError.staleEdit }
                try self.monitor.updateApplicationRules(rules)
            }
            applicationRulesController = controller; controller.present(on: window)
        } catch {
            let alert = NSAlert(); alert.messageText = "无法打开应用程序规则"; alert.informativeText = error.localizedDescription
            alert.beginSheetModal(for: window)
        }
    }
    @objc private func editHotkeys() {
        guard let window else { return }
        let controller = NativeHotkeySettingsController { [weak self] in
            self?.hotkeySettingsController = nil
        }
        hotkeySettingsController?.close()
        hotkeySettingsController = controller
        controller.present(on: window)
    }
    @objc private func cancel() { close() }
    override func close() {
        applicationRulesController?.close(); applicationRulesController = nil
        hotkeySettingsController?.close(); hotkeySettingsController = nil
        if let snapshot {
            // A Settings cancel must never leave an uncommitted async enable
            // running behind the closed panel. A completed explicit session is
            // intentionally not stopped here; reload reconciles it only if the
            // restored rules no longer require audio observation.
            monitor.cancelPendingAudioDetectionStart()
            snapshot.restore(); self.snapshot = nil; monitor.reloadPreferences()
            NativeInterfaceThemeRuntime.applyStoredTheme()
        }
        timer?.invalidate(); timer = nil; super.close()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }
    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}
