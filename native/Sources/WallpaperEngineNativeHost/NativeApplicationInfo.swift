import AppKit

@MainActor
final class NativeApplicationInfoController: NSWindowController {
    private let location = NSTextField(wrappingLabelWithString: "")

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 370),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "关于 Wallpaper Engine Native"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        let title = NSTextField(labelWithString: "Wallpaper Engine Native")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info["CFBundleVersion"] as? String ?? "未知"
        let minimumOS = info["LSMinimumSystemVersion"] as? String ?? "14.0"
        let versionLabel = NSTextField(labelWithString: "版本 \(version)（\(build)）")
        versionLabel.textColor = .secondaryLabelColor
        let description = NSTextField(wrappingLabelWithString:
            "在 Mac 上管理和播放动态壁纸，通过 Steam 获取创意工坊内容。独立开发的开源项目。")
        let requirement = NSTextField(labelWithString: "适用于 Apple Silicon · macOS \(minimumOS) 或更新版本")
        requirement.font = .systemFont(ofSize: 12)
        requirement.textColor = .secondaryLabelColor
        let locationTitle = NSTextField(labelWithString: "正在运行的应用")
        locationTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        location.font = .systemFont(ofSize: 12)
        location.textColor = .secondaryLabelColor
        location.isSelectable = true
        location.lineBreakMode = .byCharWrapping
        location.maximumNumberOfLines = 4
        let reveal = NSButton(title: "在 Finder 中显示", target: self, action: #selector(revealApplication))
        reveal.bezelStyle = .rounded
        let stack = NSStackView(views: [title, versionLabel, description, requirement, locationTitle, location, reveal])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.setCustomSpacing(6, after: title)
        stack.setCustomSpacing(6, after: locationTitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = window.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            location.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func present() {
        location.stringValue = Bundle.main.bundleURL.path
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
