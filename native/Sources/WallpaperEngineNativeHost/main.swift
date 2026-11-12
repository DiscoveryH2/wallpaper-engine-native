import AppKit
import AVFoundation
import CryptoKit
import CoreGraphics
import CoreServices
import Darwin
import Foundation
import OSLog
import ServiceManagement
import WebKit
import UniformTypeIdentifiers

private enum LaunchMode { case desktop, preview }

private enum HostError: LocalizedError {
    case usage
    case invalidArgument(String)
    case unreadableProject(Error)
    case malformedProject(String)
    case unsupportedProjectType(String)
    case unsafeResourcePath(String)
    case resourceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .usage: return LaunchConfiguration.usage
        case .invalidArgument(let message), .malformedProject(let message): return message
        case .unreadableProject(let error): return "Could not read project.json: \(error.localizedDescription)"
        case .unsupportedProjectType(let type):
            return "Unsupported Wallpaper Engine project type: \(type). The native host supports Web, Video, and a growing subset of Scene projects."
        case .unsafeResourcePath(let path): return "Refusing resource path outside the selected project directory: \(path)"
        case .resourceNotFound(let path): return "Wallpaper resource was not found or is not a regular file: \(path)"
        }
    }

    var recoveryMessage: String {
        switch self {
        case .unreadableProject(let error):
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain,
               [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(cocoa.code) {
                return "找不到壁纸的项目文件。请恢复原位置的文件后重试，或从壁纸库重新选择。"
            }
            return "无法读取壁纸的项目文件。请检查文件是否可访问，或重新下载完整壁纸后重试。"
        case .malformedProject:
            return "壁纸的项目说明文件无效或已损坏。请恢复完整文件或重新下载后重试。"
        case .resourceNotFound:
            return "壁纸缺少需要的资源文件。请恢复完整文件夹或重新下载后重试。"
        case .unsupportedProjectType:
            return "当前原生引擎尚不支持这类壁纸。请从壁纸库选择其他壁纸。"
        case .unsafeResourcePath:
            return "壁纸引用了项目文件夹以外的资源。请使用资源完整且位于同一文件夹内的项目。"
        case .usage, .invalidArgument:
            return errorDescription ?? "壁纸加载失败，请重新选择项目。"
        }
    }
}

private struct LaunchConfiguration {
    let projectURL: URL
    let mode: LaunchMode

    static let usage = """
    Usage:
      WallpaperEngineNativeHost --project /absolute/path/project.json [--desktop | --preview]
      WallpaperEngineNativeHost --import-engine-resources /absolute/path/wallpaper-engine.apk
      WallpaperEngineNativeHost --import-engine-fonts /absolute/path/wallpaper-engine.apk

    --desktop  display a supported project behind Finder desktop icons.
    --preview  display it in a normal interactive window (the default).
    Project types: web, video, and experimental scene, case-insensitive.
    --import-engine-resources imports original TEX data from a recorded official APK,
      prints a JSON receipt and exits. It does not execute or install Android code.
    --import-engine-fonts imports supported font data from the same recorded APK.
    """

    static var savedProjectURL: URL? {
        guard let path = UserDefaults.standard.string(forKey: "lastProject"), path.hasPrefix("/"),
              !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.lastPathComponent.lowercased() == "project.json" else { return nil }
        return url
    }
    static var restorationIssue: String? {
        UserDefaults.standard.object(forKey: "lastProject") != nil && savedProjectURL == nil
            ? "上次保存的壁纸位置无效，请从壁纸库重新选择，或点击“打开本地项目…”。" : nil
    }
    static func parse(arguments: [String]) throws -> LaunchConfiguration? {
        if arguments.count == 1 {
            // Preserve missing paths so the GUI can explain the failure and retry.
            return savedProjectURL.map { LaunchConfiguration(projectURL: $0, mode: .desktop) }
        }
        var project: String?
        var mode: LaunchMode = .preview
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--help", "-h": throw HostError.usage
            case "--project":
                index += 1
                guard index < arguments.count else {
                    throw HostError.invalidArgument("--project requires an absolute project.json path.")
                }
                project = arguments[index]
            case "--desktop": mode = .desktop
            case "--preview": mode = .preview
            default: throw HostError.invalidArgument("Unknown argument: \(arguments[index])")
            }
            index += 1
        }
        guard let project else { throw HostError.invalidArgument("--project is required.") }
        guard project.hasPrefix("/") else { throw HostError.invalidArgument("--project must be an absolute path.") }
        let projectURL = URL(fileURLWithPath: project).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw HostError.invalidArgument("Project file does not exist: \(projectURL.path)")
        }
        guard projectURL.lastPathComponent.lowercased() == "project.json" else {
            throw HostError.invalidArgument("--project must point to a file named project.json.")
        }
        return LaunchConfiguration(projectURL: projectURL, mode: mode)
    }
}

enum ProjectKind: String { case web, video, scene, image }

struct WallpaperProject: @unchecked Sendable {
    let projectURL: URL
    let directoryURL: URL
    let resourceURL: URL
    let metadataData: Data
    let title: String
    let kind: ProjectKind
    let propertyDefinitions: [WallpaperProperty]
    var userProperties: [String: Any]
    /// The property target is part of a live project's identity.  The same
    /// project may render on two displays, but each explicit display is an
    /// independent author-property context.
    var propertyTarget: NativeDisplayTarget = .defaultWallpaper
    var propertyRevision: WallpaperPropertyStore.Revision = .unresolved
    var propertyDiagnostics: [String]
    /// Scoped, recoverable local-setting state used by the property UI.  It
    /// is not an authorization capability; the media-grant layer remains the
    /// only path that can resolve local-file access.
    var propertyLoadIssues: [WallpaperPropertyLoadIssue] = []
    let generalProperties: [String: Any]

    var propertyScope: NativePropertyScope {
        // All targets originate from NativeDisplayTarget's validating
        // initializer or an active NativeDisplayLayout.  A project that is
        // already live must therefore always have a valid property scope.
        try! NativePropertyScope(project: projectURL, target: propertyTarget)
    }

    static func load(from projectURL: URL, propertyTarget: NativeDisplayTarget = .defaultWallpaper,
                     propertySnapshot: WallpaperPropertyStore.Snapshot? = nil) throws -> WallpaperProject {
        let canonicalProject = projectURL.standardizedFileURL.resolvingSymlinksInPath()
        let directory = canonicalProject.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let data: Data
        do { data = try Data(contentsOf: canonicalProject, options: .mappedIfSafe) }
        catch { throw HostError.unreadableProject(error) }
        guard data.count <= 4 * 1024 * 1024 else { throw HostError.malformedProject("project.json exceeds the 4 MB size limit.") }
        let root: [String: Any]
        do {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HostError.malformedProject("project.json must contain a JSON object.")
            }
            root = parsed
        } catch let error as HostError { throw error }
        catch { throw HostError.malformedProject("Could not parse project.json: \(error.localizedDescription)") }

        guard let rawType = root["type"] as? String, !rawType.isEmpty else {
            throw HostError.malformedProject("project.json has no non-empty string field named type.")
        }
        let kind: ProjectKind
        switch rawType.lowercased() {
        case "web": kind = .web
        case "video": kind = .video
        case "scene": kind = .scene
        case "image": kind = .image
        default: throw HostError.unsupportedProjectType(rawType)
        }
        guard let rawResource = root["file"] as? String, !rawResource.isEmpty else {
            throw HostError.malformedProject("project.json has no non-empty string field named file.")
        }
        let resource: URL
        if kind == .web, ["http", "https"].contains(URLComponents(string: rawResource)?.scheme?.lowercased() ?? "") {
            resource = try NativeWallpaperURL.parse(rawResource)
        } else if kind == .scene {
            // Scene entry points commonly live inside scene.pkg, not beside project.json.
            let assets = try SceneAssets(directory: directory)
            _ = try assets.json(rawResource)
            resource = directory.appendingPathComponent(rawResource)
        } else {
            resource = try resolveResource(rawResource, projectDirectory: directory)
        }
        let proposedTitle = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (proposedTitle?.isEmpty == false) ? proposedTitle! : resource.lastPathComponent
        let general = root["general"] as? [String: Any] ?? [:]
        let propertyDefinitions = WallpaperProperty.catalog(general["properties"] as? [String: Any] ?? [:])
        let propertyScope = try NativePropertyScope(project: canonicalProject, target: propertyTarget)
        let settings = WallpaperPropertyStore.load(project: canonicalProject, scope: propertyScope,
                                                   definitions: propertyDefinitions,
                                                   mediaEnabled: kind == .web && resource.isFileURL,
                                                   snapshot: propertySnapshot)
        // applyGeneralProperties describes host settings, not project metadata.
        let generalProperties: [String: Any] = ["fps": 60]

        return WallpaperProject(projectURL: canonicalProject, directoryURL: directory, resourceURL: resource, metadataData: data, title: title, kind: kind, propertyDefinitions: propertyDefinitions, userProperties: settings.payload, propertyTarget: propertyTarget, propertyRevision: settings.revision, propertyDiagnostics: settings.diagnostics, propertyLoadIssues: settings.issues, generalProperties: generalProperties)
    }

    private static func resolveResource(_ rawPath: String, projectDirectory: URL) throws -> URL {
        guard !rawPath.hasPrefix("/"), !rawPath.hasPrefix("~"), !rawPath.split(separator: "/").contains(where: { $0 == ".." }) else {
            throw HostError.unsafeResourcePath(rawPath)
        }
        let resource = projectDirectory.appendingPathComponent(rawPath).standardizedFileURL.resolvingSymlinksInPath()
        guard resource.isContained(in: projectDirectory) else { throw HostError.unsafeResourcePath(rawPath) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resource.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw HostError.resourceNotFound(rawPath)
        }
        return resource
    }

}

private extension URL {
    func isContained(in directory: URL) -> Bool {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == root || candidate.hasPrefix(root + "/")
    }
}

@MainActor
protocol WallpaperRenderable: AnyObject {
    var view: NSView { get }
    var diagnostics: [String] { get }
    var playbackDescription: String { get }
    var playbackNotice: String? { get }
    func prepareForPresentation() async throws
    func validatePreparedPresentation() throws
    func beginPresentation()
    func refreshPresentation()
    func pause()
    func resume()
    func applyUserProperties(_ changes: [String: Any])
    func prepareUserPropertyUpdate(_ changes: [String: Any]) async throws -> () -> Void
    var propertyUpdateRevision: UInt64 { get }
    func setAudioOutputEnabled(_ enabled: Bool)
    func setFrameRateLimit(_ framesPerSecond: Int)
    func setReflectionsEnabled(_ enabled: Bool)
    func setShadowQuality(_ quality: NativeShadowQuality)
    func setVolumetricQuality(_ quality: NativeVolumetricQuality)
    var antialiasingQuality: NativeAntialiasing { get }
    func prepareAntialiasing(_ quality: NativeAntialiasing) throws -> () -> Void
    var textureResolutionQuality: NativeTextureResolution { get }
    func prepareTextureResolution(_ quality: NativeTextureResolution, outputSize: CGSize) throws -> () -> Void
    var postProcessingQuality: NativePostProcessingQuality { get }
    func preparePostProcessingQuality(_ quality: NativePostProcessingQuality) throws -> () -> Void
}

extension WallpaperRenderable {
    var diagnostics: [String] { [] }
    var playbackDescription: String { "" }
    var playbackNotice: String? { nil }
    func prepareForPresentation() async throws {}
    func validatePreparedPresentation() throws {}
    func beginPresentation() {}
    func refreshPresentation() {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.needsDisplay = true
    }
    func applyUserProperties(_ changes: [String: Any]) {}
    func prepareUserPropertyUpdate(_ changes: [String: Any]) async throws -> () -> Void { { self.applyUserProperties(changes) } }
    var propertyUpdateRevision: UInt64 { 0 }
    func setAudioOutputEnabled(_ enabled: Bool) {}
    func setFrameRateLimit(_ framesPerSecond: Int) {}
    func setReflectionsEnabled(_ enabled: Bool) {}
    func setShadowQuality(_ quality: NativeShadowQuality) {}
    func setVolumetricQuality(_ quality: NativeVolumetricQuality) {}
    var antialiasingQuality: NativeAntialiasing { .none }
    func prepareAntialiasing(_ quality: NativeAntialiasing) throws -> () -> Void { {} }
    var textureResolutionQuality: NativeTextureResolution { .full }
    func prepareTextureResolution(_ quality: NativeTextureResolution, outputSize: CGSize) throws -> () -> Void { {} }
    var postProcessingQuality: NativePostProcessingQuality { .ultra }
    func preparePostProcessingQuality(_ quality: NativePostProcessingQuality) throws -> () -> Void { {} }
}

@MainActor
private final class WebWallpaperView: NSObject, WallpaperRenderable, WKNavigationDelegate {
    private let loadingTimeout = NativePlaybackPreferences.load().loadingTimeout
    let webView: WKWebView
    let projectDirectory: URL
    private let workspace: WebMediaWorkspace
    private var mediaState: WebMediaState
    private var nativeProperties: [String: Any]
    private let hasMediaProperties: Bool
    private var mediaTimer: Timer?
    private var mediaRefreshPending = false
    private var mediaRefreshError: String?
    private var webStatus = "网页加载中。"
    private var revision = 0
    private var retiredStates: [(revision: Int, state: WebMediaState, releaseAt: Date?)] = []
    private var propertyDeliveryPending = false
    private var manifestPending = false
    private var deliveryFailures = 0
    private var paused = false
    private var navigationReady = false
    private var documentResponsive = false
    private var navigationFailure: String?
    private var navigationDeadlineWorkItem: DispatchWorkItem?
    private var navigationDeadlineTicket: UUID?
    private var preparingPresentation = false
    private var abandonedPreparation = false
    private var navigationGeneration: UInt64 = 0
    private var activeNavigation: WKNavigation?
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryTicket: UUID?
    private var recoveryRetry: (delay: TimeInterval, attempt: Int)?
    private var recoveryAttempts: [TimeInterval] = []
    private var recoveryInProgress = false
    private var recoveryBlocked = false
    private var recoveryStatus: String?
    private var loadNotice: String? = "网页加载中。"
    var playbackStateDidChange: (() -> Void)?
    var reloadAdvice = "请通过 WE 菜单“重新加载项目”重试。"
    private var audioTimer: Timer?
    private var audioPending = false
    private var reportedAudioError = false
    private var audioOutputEnabled = false
    private var audioGeneration = 0
    private let audioOwner = UUID()
    private var ownAudioStatus = "Web 音乐频谱尚未开始。"
    private var pendingProperties: [String: Any] = [:]
    private var currentProperties: [String: Any]
    private let generalProperties: [String: Any]
    var view: NSView { webView }
    var playbackNotice: String? { loadNotice }
    var playbackDescription: String { loadNotice ?? recoveryStatus ?? "网页已加载。" }
    var mediaSourceRevision: String { workspace.sourceRevision }
    var diagnostics: [String] {
        var messages = ["WebKit：独立项目快照，\(workspace.projectFileCount) 个目录项目，\(workspace.projectByteCount) 字节。", webStatus, ownAudioStatus]
        if paused { messages.append("Web 暂停：主页面已注入的动画帧、计时器、CSS / Web Animations 及已播放的 HTML 媒体受控；Worker、子帧和作者自行替换的接口不保证冻结。") }
        if let recoveryStatus { messages.append(recoveryStatus) }
        messages += mediaState.diagnostics
        if let mediaRefreshError { messages.append(mediaRefreshError) }
        return messages
    }

    init(project: WallpaperProject, workspace: WebMediaWorkspace, state: WebMediaState) {
        self.workspace = workspace; mediaState = state
        projectDirectory = workspace.projectDirectory
        nativeProperties = project.userProperties
        currentProperties = state.properties
        hasMediaProperties = project.propertyDefinitions.contains { $0.isMedia }
        generalProperties = project.generalProperties
        let configuration = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: Self.propertyBridge(userProperties: state.properties, generalProperties: project.generalProperties, directories: state.directories, revision: 0), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: WebPauseBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: WebMusicBridge.script(readRoot: workspace.root), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = .black
        activeNavigation = webView.loadFileURL(workspace.entry, allowingReadAccessTo: workspace.root)
        if activeNavigation != nil { startNavigationDeadline() }
        else { failNavigation("无法开始加载网页入口。") }
        audioTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.deliverAudio() } }
        mediaTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshMedia(); self?.sampleStatus() } }
    }

    func prepareForPresentation() async throws {
        preparingPresentation = true
        defer { preparingPresentation = false }
        let deadline = ProcessInfo.processInfo.systemUptime + loadingTimeout.seconds
        do {
            while !documentResponsive {
                try Task.checkCancellation()
                if let navigationFailure { throw PropertyError.invalid("无法打开网页：" + navigationFailure) }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    failNavigation("网页加载或脚本响应超过 \(loadingTimeout.rawValue) 秒。"); webView.stopLoading()
                    throw PropertyError.invalid("网页加载超过 \(loadingTimeout.rawValue) 秒，未切换壁纸。")
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try Task.checkCancellation()
            try validatePreparedPresentation()
        } catch {
            abandonedPreparation = true
            invalidateDocument(); activeNavigation = nil
            recoveryWorkItem?.cancel(); recoveryWorkItem = nil; recoveryTicket = nil; recoveryRetry = nil
            webView.stopLoading()
            throw error
        }
    }

    func validatePreparedPresentation() throws {
        if let navigationFailure { throw PropertyError.invalid("无法打开网页：" + navigationFailure) }
        guard !abandonedPreparation, navigationReady, documentResponsive else {
            throw PropertyError.invalid("网页尚未完成加载和响应检查，未切换壁纸。")
        }
    }

    private func startNavigationDeadline() {
        navigationDeadlineWorkItem?.cancel()
        let generation = navigationGeneration, ticket = UUID()
        navigationDeadlineTicket = ticket
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.abandonedPreparation, self.navigationGeneration == generation,
                  self.navigationDeadlineTicket == ticket, !self.documentResponsive else { return }
            self.failNavigation("网页加载或脚本响应超过 \(self.loadingTimeout.rawValue) 秒。")
            self.webView.stopLoading()
        }
        navigationDeadlineWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + loadingTimeout.seconds, execute: work)
    }

    func pause() {
        paused = true; audioGeneration += 1; WebMusicSpectrum.shared.clear(audioOwner)
        ownAudioStatus = "Web 音乐频谱：已暂停，频谱已清空，分析副本已请求停止。"
        if let retry = recoveryRetry {
            recoveryWorkItem?.cancel(); recoveryWorkItem = nil; recoveryTicket = nil
            loadNotice = "网页进程已退出；继续播放时将尝试恢复（\(retry.attempt)/3）。"
            playbackStateDidChange?()
        }
        sendPauseState()
    }
    func resume() { paused = false; scheduleRecovery(); sendPauseState() }
    func setAudioOutputEnabled(_ enabled: Bool) {
        audioOutputEnabled = enabled; audioGeneration += 1
        if enabled { WebMusicSpectrum.shared.activate(audioOwner) }
        else {
            WebMusicSpectrum.shared.deactivate(audioOwner)
            if navigationReady { webView.evaluateJavaScript("window.__weNativePauseOwnAudio && window.__weNativePauseOwnAudio(true)", completionHandler: nil) }
        }
    }
    private func sendPauseState() {
        // Do not freeze author setup timers in a provisional document. The
        // desired state is delivered as soon as the page finishes navigating.
        guard navigationReady else { return }
        webView.evaluateJavaScript("window.__weNativeSetPaused && window.__weNativeSetPaused(\(paused ? "true" : "false"))", completionHandler: nil)
        let generation = audioGeneration
        let document = navigationGeneration
        webView.callAsyncJavaScript("return window.__weNativePauseOwnAudio ? await window.__weNativePauseOwnAudio(paused) : null;", arguments: ["paused": paused], in: nil, in: .page) { [weak self] result in
            guard let self, document == self.navigationGeneration, generation == self.audioGeneration, self.paused else { return }
            if case .success(let value) = result, let report = value as? [String: Any], let count = report["copies"] as? Int, let state = report["context"] as? String {
                self.ownAudioStatus = "Web 音乐频谱：已暂停，频谱已清空；分析副本=\(count)，AudioContext=\(state)。"
            }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView, !abandonedPreparation else { return }
        recoveryWorkItem?.cancel(); recoveryWorkItem = nil; recoveryTicket = nil; recoveryRetry = nil
        recoveryBlocked = false; activeNavigation = navigation
        invalidateDocument()
        navigationFailure = nil
        startNavigationDeadline()
        loadNotice = recoveryInProgress ? "网页正在恢复，内容将从头加载。" : "网页加载中。"
        playbackStateDidChange?()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, !abandonedPreparation, navigation != nil, navigation === activeNavigation else { return }
        activeNavigation = nil; navigationReady = true
        loadNotice = "正在确认网页响应…"
        webStatus = "网页已完成导航，正在确认脚本响应。"
        sendPauseState(); deliverPropertyChanges(); sampleStatus()
        let generation = navigationGeneration
        webView.evaluateJavaScript("true") { [weak self] value, error in
            guard let self, !self.abandonedPreparation, self.navigationGeneration == generation, self.navigationReady else { return }
            guard error == nil, (value as? Bool) == true else {
                self.failNavigation(error?.localizedDescription ?? "网页未能确认脚本响应。"); return
            }
            self.documentResponsive = true
            self.navigationDeadlineWorkItem?.cancel(); self.navigationDeadlineWorkItem = nil; self.navigationDeadlineTicket = nil
            self.loadNotice = nil; self.webStatus = "网页已完成导航和响应检查。"
            if self.recoveryInProgress { self.recoveryStatus = "网页已恢复；内容从头加载，作者设置已保留。" }
            self.recoveryInProgress = false
            self.playbackStateDidChange?()
        }
        playbackStateDidChange?()
    }

    private func invalidateDocument() {
        navigationReady = false; documentResponsive = false; navigationGeneration &+= 1; audioGeneration += 1
        navigationDeadlineWorkItem?.cancel(); navigationDeadlineWorkItem = nil; navigationDeadlineTicket = nil
        propertyDeliveryPending = false; audioPending = false; deliveryFailures = 0
        reportedAudioError = false; WebMusicSpectrum.shared.clear(audioOwner)
        ownAudioStatus = "网页尚未就绪，音乐频谱已清空。"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView, !abandonedPreparation, recoveryRetry == nil, !recoveryBlocked else { return }
        if preparingPresentation { failNavigation("网页内容进程在准备期间退出。"); return }
        invalidateDocument(); activeNavigation = nil; recoveryInProgress = false
        let now = ProcessInfo.processInfo.systemUptime
        recoveryAttempts.removeAll { now - $0 >= 60 }
        guard recoveryAttempts.count < 3 else {
            recoveryBlocked = true
            loadNotice = "网页连续退出，已停止自动恢复。" + reloadAdvice
            recoveryStatus = loadNotice; playbackStateDidChange?(); return
        }
        let delay: TimeInterval = [0.5, 2, 5][recoveryAttempts.count]
        recoveryAttempts.append(now)
        recoveryRetry = (delay, recoveryAttempts.count)
        if paused {
            loadNotice = "网页进程已退出；继续播放时将尝试恢复（\(recoveryAttempts.count)/3）。"
            recoveryStatus = loadNotice; playbackStateDidChange?()
        } else { scheduleRecovery() }
    }

    private func scheduleRecovery() {
        guard !abandonedPreparation, !paused, recoveryWorkItem == nil, let retry = recoveryRetry else { return }
        let document = navigationGeneration
        let ticket = UUID(); recoveryTicket = ticket
        loadNotice = "网页进程已退出，正在准备恢复（\(retry.attempt)/3）。"
        recoveryStatus = loadNotice; playbackStateDidChange?()
        let work = DispatchWorkItem { [weak self] in
            guard let self, document == self.navigationGeneration, self.recoveryTicket == ticket,
                  !self.paused, self.recoveryRetry != nil else { return }
            self.recoveryWorkItem = nil; self.recoveryTicket = nil; self.recoveryRetry = nil; self.recoveryInProgress = true
            // Reload the same private project snapshot. Current user scripts
            // contain the newest properties and authorized media manifests.
            self.loadNotice = "网页正在恢复，内容将从头加载。"
            self.playbackStateDidChange?()
            self.activeNavigation = self.webView.loadFileURL(self.workspace.entry, allowingReadAccessTo: self.workspace.root)
            if self.activeNavigation != nil { self.startNavigationDeadline() }
            else { self.failNavigation("网页恢复未能开始。") }
        }
        recoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retry.delay, execute: work)
    }

    func applyUserProperties(_ changes: [String: Any]) {
        Task { [weak self] in
            guard let self else { return }
            do { let update = try await self.prepareUserPropertyUpdate(changes); update() }
            catch { self.mediaRefreshError = error.localizedDescription }
        }
    }

    func prepareUserPropertyUpdate(_ changes: [String: Any]) async throws -> () -> Void {
        guard !changes.isEmpty else { return {} }
        guard retiredStates.count < 8 else { throw PropertyError.invalid("网页仍在接收上一批素材，请稍后再次应用。") }
        let next = nativeProperties.merging(changes) { _, value in value }
        let workspace = workspace, prior = mediaState
        let prepared = try await WebMediaIO.perform { try workspace.prepare(properties: next, previous: prior, tolerateUnavailable: true, requiredProperties: Set(changes.keys)) }
        try Task.checkCancellation()
        return { [weak self] in
            guard let self else { return }
            self.nativeProperties = next; self.commitMediaState(prepared)
        }
    }

    private func commitMediaState(_ state: WebMediaState) {
        let changed = state.properties.filter { !WallpaperProperty.equal($0.value, currentProperties[$0.key]) }
        let manifestChanged = !WallpaperProperty.equal(mediaState.directories, state.directories)
        guard !changed.isEmpty || manifestChanged else { mediaState = state; return }
        revision += 1
        // An unresponsive/replaced page cannot retain old selections forever.
        // A bridge acknowledgement shortens this grace period to ten seconds.
        if !state.sameResourcePaths(as: mediaState) { retiredStates.append((revision, mediaState, Date().addingTimeInterval(30))) }
        mediaState = state; currentProperties = state.properties
        pendingProperties.merge(changed) { _, next in next }; manifestPending = true
        mediaRefreshError = nil; deliveryFailures = 0
        // Future in-project navigations start with the current saved values.
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: Self.propertyBridge(userProperties: currentProperties, generalProperties: generalProperties, directories: state.directories, revision: revision), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: WebPauseBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: WebMusicBridge.script(readRoot: workspace.root), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        deliverPropertyChanges()
    }

    private func refreshMedia() {
        retiredStates.removeAll { ($0.releaseAt ?? .distantFuture) <= Date() }
        guard hasMediaProperties, !mediaRefreshPending, retiredStates.count < 8 else { return }
        mediaRefreshPending = true
        let workspace = workspace, prior = mediaState, values = nativeProperties
        WebMediaIO.queue.async { [weak self] in
            let result = Result { try workspace.prepare(properties: values, previous: prior, tolerateUnavailable: true) }
            DispatchQueue.main.async {
                guard let self else { return }; self.mediaRefreshPending = false
                guard self.mediaState === prior else { return }
                switch result {
                case .success(let state): self.commitMediaState(state)
                case .failure(let error): self.mediaRefreshError = "素材检查失败，保留当前画面：\(error.localizedDescription)"
                }
            }
        }
    }

    private func sampleStatus() {
        guard navigationReady else { return }
        let document = navigationGeneration
        webView.callAsyncJavaScript("return window.__weNativePropertyStatus ? window.__weNativePropertyStatus() : null;", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, document == self.navigationGeneration, self.navigationReady else { return }
            if case .success(let value) = result, let report = value as? [String: Any], let text = report["summary"] as? String {
                self.webStatus = String(text.prefix(4096))
            }
        }
    }

    private func deliverAudio() {
        guard navigationReady, !paused, !audioPending, webView.window != nil else { return }
        audioPending = true
        let system = NativeAudioService.shared.active
        let generation = audioGeneration
        let document = navigationGeneration
        let mode = system ? "system" : (audioOutputEnabled ? "wallpaper" : "shared-wallpaper")
        let values = system ? NativeAudioService.shared.snapshot.webValue : WebMusicSpectrum.shared.snapshot
        if system { WebMusicSpectrum.shared.clear(audioOwner) }
        webView.callAsyncJavaScript("return window.__weNativeAudio ? window.__weNativeAudio(values, mode) : null;", arguments: ["values": values, "mode": mode], in: nil, in: .page) { [weak self] result in
            guard let self, document == self.navigationGeneration else { return }; self.audioPending = false
            guard generation == self.audioGeneration, !self.paused else { return }
            if case .success(let value) = result, let report = value as? [String: Any] {
                if let text = report["summary"] as? String { self.ownAudioStatus = String(text.prefix(4096)) }
                if self.audioOutputEnabled, !system, !NativeAudioService.shared.active { WebMusicSpectrum.shared.publish(report, owner: self.audioOwner) }
            }
            if case .failure(let error) = result, !self.reportedAudioError {
                self.reportedAudioError = true; fputs("Web audio callback failed: \(error.localizedDescription)\n", stderr)
            }
        }
    }

    deinit { navigationDeadlineWorkItem?.cancel(); recoveryWorkItem?.cancel(); audioTimer?.invalidate(); mediaTimer?.invalidate() }

    private func deliverPropertyChanges() {
        guard navigationReady, !propertyDeliveryPending, !pendingProperties.isEmpty || manifestPending else { return }
        let changes = pendingProperties
        let submittedRevision = revision
        let document = navigationGeneration
        pendingProperties.removeAll(); manifestPending = false; propertyDeliveryPending = true
        webView.callAsyncJavaScript("return window.__weNativeUpdateProperties ? window.__weNativeUpdateProperties(changes, directories, revision) : false;", arguments: ["changes": changes, "directories": mediaState.directories, "revision": submittedRevision], in: nil, in: .page) { [weak self] result in
            guard let self, document == self.navigationGeneration else { return }; self.propertyDeliveryPending = false
            switch result {
            case .success(let accepted):
                if (accepted as? Bool) == true {
                    for index in self.retiredStates.indices where self.retiredStates[index].revision <= submittedRevision {
                        self.retiredStates[index].releaseAt = min(self.retiredStates[index].releaseAt ?? .distantFuture, Date().addingTimeInterval(10))
                    }
                    self.deliveryFailures = 0
                } else { self.webStatus = "网页尚未接收素材更新。" }
                fputs("Web property changes: \(changes.keys.sorted().joined(separator: ",")); bridge accepted \(accepted)\n", stderr)
            case .failure(let error):
                self.webStatus = "网页属性更新失败：\(error.localizedDescription)"
                self.pendingProperties = changes.merging(self.pendingProperties) { _, newer in newer }; self.manifestPending = true
                self.deliveryFailures += 1
            }
            self.sampleStatus()
            if self.deliveryFailures < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    guard let self, document == self.navigationGeneration else { return }
                    self.deliverPropertyChanges()
                }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if (url.isFileURL && url.isContained(in: projectDirectory)) || url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            fputs("Blocked web navigation outside wallpaper project: \(url.absoluteString)\n", stderr)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        navigationFailed(webView, navigation: navigation, error: error)
    }

    private func navigationFailed(_ webView: WKWebView, navigation: WKNavigation?, error: Error) {
        guard webView === self.webView, navigation != nil, navigation === activeNavigation else { return }
        failNavigation(error.localizedDescription)
    }

    private func failNavigation(_ detail: String) {
        invalidateDocument(); activeNavigation = nil
        recoveryWorkItem?.cancel(); recoveryWorkItem = nil; recoveryTicket = nil; recoveryRetry = nil; recoveryInProgress = false
        let message = String(detail.prefix(512))
        navigationFailure = message
        webStatus = "网页加载失败：" + message
        loadNotice = webStatus + " " + reloadAdvice
        if !recoveryAttempts.isEmpty { recoveryStatus = loadNotice }
        playbackStateDidChange?()
        fputs("Web wallpaper navigation failed: \(detail)\n", stderr)
    }

    private static func propertyBridge(userProperties: [String: Any], generalProperties: [String: Any], directories: [String: Any], revision: Int) -> String {
        let userData = (try? JSONSerialization.data(withJSONObject: userProperties, options: [.sortedKeys])) ?? Data("{}".utf8)
        let generalData = (try? JSONSerialization.data(withJSONObject: generalProperties, options: [.sortedKeys])) ?? Data("{}".utf8)
        let directoryData = (try? JSONSerialization.data(withJSONObject: directories, options: [.sortedKeys])) ?? Data("{}".utf8)
        return """
        (() => {
          // Capture native timers before the author-facing pause bridge is
          // injected. Host readiness and bounded retries must still complete
          // when a page finishes loading in the paused state.
          const hostSetTimeout = window.setTimeout.bind(window);
          const hostSetInterval = window.setInterval.bind(window);
          const hostClearInterval = window.clearInterval.bind(window);
          const decodeUTF8JSON = (value) => JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(value), (character) => character.charCodeAt(0))));
          const userProperties = decodeUTF8JSON('\(userData.base64EncodedString())');
          const generalProperties = decodeUTF8JSON('\(generalData.base64EncodedString())');
          let directories = decodeUTF8JSON('\(directoryData.base64EncodedString())');
          let revision = \(revision);
          const deliveredDirectories = new Map();
          const errors = [];
          const recordError = (scope, error) => {
            const message = String(scope + ': ' + (error && error.message || error)).slice(0, 512);
            if (errors.indexOf(message) < 0) { errors.push(message); if (errors.length > 8) errors.shift(); }
          };
          window.addEventListener('error', (event) => { if (event.message) recordError('script', event.message); });
          window.addEventListener('unhandledrejection', (event) => recordError('promise', event.reason));
          let pendingRandom = 0;
          window.wallpaperRequestRandomFileForProperty = (key, callback) => {
            if (typeof key !== 'string' || key.length > 512 || typeof callback !== 'function') throw new TypeError('Invalid directory request');
            if (pendingRandom >= 128) throw new RangeError('Too many pending directory requests');
            pendingRandom += 1;
            // No native paths or file operations come from page messages. The
            // list was already produced from an explicit native selection.
            window.setTimeout(() => {
              pendingRandom -= 1;
              const entry = Object.prototype.hasOwnProperty.call(directories, key) ? directories[key] : null;
              const files = entry && entry.mode === 'ondemand' ? entry.files : [];
              const path = files.length ? files[Math.floor(Math.random() * files.length)] : '';
              try { callback(key, path); } catch (error) { recordError('random file callback', error); }
            }, 0);
          };
          let initialDelivered = false;
          let pageReady = false;
          let pending = {};
          let retryTimer = null;
          let directoryAdded = 0, directoryRemoved = 0;
          const deliver = () => {
            if (!pageReady) return false;
            const listener = window.wallpaperPropertyListener;
            if (!listener || typeof listener !== 'object') return false;
            // Publish the ready file lists before properties such as slideshow
            // mode consume them. The official API specifies no cross-event order.
            for (const key of Object.keys(directories)) {
              const entry = directories[key];
              if (entry.mode !== 'fetchall') continue;
              const before = deliveredDirectories.get(key) || [];
              const previous = new Set(before), next = new Set(entry.files);
              const removed = before.filter((path) => !next.has(path));
              const added = entry.files.filter((path) => !previous.has(path));
              try {
                if (removed.length && typeof listener.userDirectoryFilesRemoved === 'function') { listener.userDirectoryFilesRemoved(key, removed.slice()); directoryRemoved += removed.length; }
                if (added.length && typeof listener.userDirectoryFilesAddedOrChanged === 'function') { listener.userDirectoryFilesAddedOrChanged(key, added.slice()); directoryAdded += added.length; }
                else if (added.length) recordError('directory ' + key, 'Missing userDirectoryFilesAddedOrChanged');
              } catch (error) { recordError('directory ' + key, error); }
              deliveredDirectories.set(key, entry.files.slice());
            }
            const changes = initialDelivered ? pending : userProperties;
            try { if (typeof listener.applyUserProperties === 'function' && Object.keys(changes).length) listener.applyUserProperties(changes); }
            catch (error) { recordError('applyUserProperties', error); }
            try { if (!initialDelivered && typeof listener.applyGeneralProperties === 'function') listener.applyGeneralProperties(generalProperties); }
            catch (error) { recordError('applyGeneralProperties', error); }
            initialDelivered = true; pending = {};
            return true;
          };
          const attempt = () => {
            let count = 0;
            if (retryTimer !== null) { hostClearInterval(retryTimer); retryTimer = null; }
            if (deliver()) return;
            retryTimer = hostSetInterval(() => { count += 1; if (deliver() || count >= 60) { hostClearInterval(retryTimer); retryTimer = null; } }, 50);
          };
          window.__weNativeUpdateProperties = (changes, nextDirectories, nextRevision) => {
            // A reloaded document may already start with this revision. Its
            // load handler owns initial delivery; do not call the author twice
            // for a pending update from before navigation or a native retry.
            if (nextRevision <= revision) return true;
            revision = nextRevision; directories = nextDirectories;
            for (const key of Object.keys(changes)) {
              // Avoid special-key assignment altering the bridge object's prototype.
              Object.defineProperty(userProperties, key, {value: changes[key], writable: true, enumerable: true, configurable: true});
              Object.defineProperty(pending, key, {value: changes[key], writable: true, enumerable: true, configurable: true});
            }
            attempt(); return true;
          };
          window.__weNativePropertyStatus = () => {
            const counts = Object.keys(directories).map((key) => key + '=' + directories[key].files.length).join(', ');
            const video = Array.from(document.querySelectorAll('video')).slice(0, 4).map((v) => v.videoWidth + '×' + v.videoHeight + ', ' + v.currentTime.toFixed(1) + 's, ready=' + v.readyState + (v.paused ? ', paused' : ', playing')).join('; ');
            const audio = Array.from(document.querySelectorAll('audio')).slice(0, 4).map((a) => a.currentTime.toFixed(1) + 's, ready=' + a.readyState + (a.paused ? ', paused' : ', playing')).join('; ');
            return {summary: 'Web 属性：' + (initialDelivered ? '已调用作者回调' : '等待作者监听器') + '，' + Object.keys(userProperties).length + ' 项，revision ' + revision
              + (counts ? '\\n目录：' + counts + '；已回调 added=' + directoryAdded + ', removed=' + directoryRemoved : '') + (video ? '\\nVideo: ' + video : '') + (audio ? '\\nAudio: ' + audio : '')
              + (errors.length ? '\\n脚本错误：' + errors.join(' | ') : '')};
          };
          // Authors may establish WebGL/media in window.load handlers. Waiting
          // one task past that event lets those handlers finish before defaults.
          const ready = () => hostSetTimeout(() => { pageReady = true; attempt(); }, 0);
          if (document.readyState === 'complete') ready(); else window.addEventListener('load', ready, { once: true });
        })();
        """
    }

}

@MainActor
private final class VideoWallpaperView: NSView, WallpaperRenderable {
    private let loadingTimeout = NativePlaybackPreferences.load().loadingTimeout
    private let asset: AVURLAsset
    private let firstFrameGenerator: AVAssetImageGenerator
    private let player: AVPlayer
    private let playerLayer: AVPlayerLayer
    private var observers: [NSObjectProtocol] = []
    private var observations: [NSKeyValueObservation] = []
    private var metadataTask: Task<Void, Never>?
    private var metadataReady = false
    private var prerollStarted = false
    private var prepared = false
    private var failure: String?
    private var preparationID = UUID()
    private var paused = false
    private var presentationArmed = false
    private var loopSeekPending = false
    var playbackStateDidChange: (() -> Void)?
    var playbackDidEnd: (() -> Void)?
    var reloadAdvice = "请从 WE 菜单重新加载项目。"
    var view: NSView { self }
    var playbackNotice: String? {
        if let failure { return "视频播放失败：\(failure) \(reloadAdvice)" }
        if !prepared { return "正在加载视频…" }
        if paused { return nil }
        if loopSeekPending { return "正在衔接视频循环…" }
        if presentationArmed, player.timeControlStatus == .waitingToPlayAtSpecifiedRate { return "视频正在缓冲…" }
        if presentationArmed, player.timeControlStatus == .paused { return "视频等待播放…" }
        return nil
    }
    var diagnostics: [String] { failure.map { ["视频：" + $0] } ?? [] }
    var playbackDescription: String {
        let time = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? .nan
        let position = time.isFinite ? String(format: "%.2f", time) : "待就绪"
        let length = duration.isFinite ? String(format: " / %.2f", duration) : ""
        let state = failure != nil ? "播放失败" : !prepared ? "正在加载" : paused ? "已暂停" : player.rate > 0 ? "正在播放" : "等待播放"
        return "视频时间 \(position)\(length) 秒 · \(state)"
    }

    init(videoURL: URL) {
        asset = AVURLAsset(url: videoURL, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        firstFrameGenerator = AVAssetImageGenerator(asset: asset)
        firstFrameGenerator.maximumSize = CGSize(width: 256, height: 256)
        firstFrameGenerator.appliesPreferredTrackTransform = true
        let item = AVPlayerItem(asset: asset)
        player = AVPlayer(playerItem: item)
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: .zero)
        wantsLayer = true
        layer = playerLayer
        playerLayer.videoGravity = .resizeAspectFill
        player.actionAtItemEnd = .none
        player.isMuted = true
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.checkPlayerState() } },
            player.observe(\.status, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.checkPlayerState() } },
            player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.notifyStateChange() } }
        ]
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.failure == nil, !self.loopSeekPending else { return }
                if self.presentationArmed, !self.paused { self.playbackDidEnd?() }
                self.loopSeekPending = true
                self.notifyStateChange()
                self.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] completed in
                    Task { @MainActor in
                        guard let self else { return }
                        self.loopSeekPending = false
                        guard self.failure == nil else { return }
                        guard completed else { self.fail("视频循环定位失败。"); return }
                        if completed, self.presentationArmed, !self.paused { self.player.play() }
                        self.notifyStateChange()
                    }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] notification in
            let detail = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "视频未能播放到结尾。"
            MainActor.assumeIsolated { self?.fail(detail) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail("本地视频读取中断。") }
        })
    }

    required init?(coder: NSCoder) { nil }
    deinit {
        metadataTask?.cancel()
        firstFrameGenerator.cancelAllCGImageGeneration()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observations.forEach { $0.invalidate() }
    }
    override func layout() { super.layout(); playerLayer.frame = bounds }
    // Prepare the actual display player while the previous wallpaper remains
    // alive. The deadline also bounds metadata loading and preroll, without
    // awaiting a cancelled AVFoundation operation before releasing the UI.
    func prepareForPresentation() async throws {
        if prepared { try validatePreparedPresentation(); return }
        let ticket = preparationID
        if metadataTask == nil {
            let asset = asset
            let generator = firstFrameGenerator
            metadataTask = Task { [weak self] in
                do {
                    let playable = try await asset.load(.isPlayable)
                    let tracks = try await asset.loadTracks(withMediaType: .video)
                    let duration = try await asset.load(.duration).seconds
                    try Task.checkCancellation()
                    guard playable, !tracks.isEmpty, duration.isFinite, duration > 0 else {
                        throw PropertyError.invalid("文件不包含可播放的有限时长视频轨道。")
                    }
                    // Readiness/preroll can succeed even when sample payloads
                    // are corrupt. Require one real decoded image as well.
                    let frame = try await generator.image(at: .zero).image
                    try Task.checkCancellation()
                    guard let self, self.preparationID == ticket else { return }
                    guard frame.width > 0, frame.height > 0 else { self.fail("视频无法解码出画面。"); return }
                    self.metadataReady = true
                } catch {
                    guard !Task.isCancelled, let self, self.preparationID == ticket else { return }
                    self.fail(error.localizedDescription)
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + loadingTimeout.seconds
        do {
            while !prepared {
                try Task.checkCancellation()
                checkPlayerState()
                if let failure { throw PropertyError.invalid("无法打开视频：" + failure) }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    fail("等待视频就绪超过 \(loadingTimeout.rawValue) 秒。"); throw PropertyError.invalid("视频加载超过 \(loadingTimeout.rawValue) 秒，已保留原有壁纸。")
                }
                if metadataReady, player.currentItem?.status == .readyToPlay, !prerollStarted {
                    prerollStarted = true
                    player.preroll(atRate: 1) { [weak self] completed in
                        Task { @MainActor in
                            guard let self, self.preparationID == ticket, self.failure == nil else { return }
                            if completed { self.prepared = true }
                            else { self.fail("系统无法预备视频解码。"); }
                        }
                    }
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try Task.checkCancellation()
        } catch {
            preparationID = UUID(); metadataTask?.cancel(); asset.cancelLoading(); firstFrameGenerator.cancelAllCGImageGeneration()
            player.cancelPendingPrerolls(); player.pause()
            throw error
        }
    }
    func validatePreparedPresentation() throws {
        checkPlayerState()
        if let failure { throw PropertyError.invalid("无法打开视频：" + failure) }
        guard prepared, player.currentItem?.status == .readyToPlay else {
            throw PropertyError.invalid("视频尚未就绪，已保留原有壁纸。")
        }
    }
    private func checkPlayerState() {
        if player.currentItem?.status == .failed || player.status == .failed {
            fail(player.currentItem?.error?.localizedDescription ?? player.error?.localizedDescription ?? "系统无法播放此视频。")
        }
    }
    private func fail(_ detail: String) {
        guard failure == nil else { return }
        failure = String(detail.prefix(512))
        player.pause(); notifyStateChange()
    }
    private func notifyStateChange() { if presentationArmed { playbackStateDidChange?() } }
    func beginPresentation() { presentationArmed = true; resumeIfAllowed(); notifyStateChange() }
    private func resumeIfAllowed() { if prepared, failure == nil, presentationArmed, !paused, !loopSeekPending { player.play() } }
    func pause() { paused = true; player.pause(); notifyStateChange() }
    func resume() { paused = false; resumeIfAllowed(); notifyStateChange() }
    func setAudioOutputEnabled(_ enabled: Bool) { player.isMuted = !enabled }
}

@MainActor
private final class PreviewWindow: NSWindow {
    var onClose: (() -> Void)?
    override func close() {
        let callback = onClose; onClose = nil
        super.close()
        callback?()
    }
    init(title: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        minSize = NSSize(width: 480, height: 270)
        center()
    }
}


private struct PreparedWallpaper: @unchecked Sendable {
    let project: WallpaperProject
    let workspace: WebMediaWorkspace?
    let state: WebMediaState?
    var image: CGImage?
    var videos = SceneVideoLibrary()
}
private struct PreparedDisplayProjects: @unchecked Sendable {
    let defaultKey: String
    var projects: [String: PreparedWallpaper]
    var displayProjects: [String: String]
    /// A failed independent assignment falls back to the default wallpaper
    /// for that *same* display target, preserving its scoped properties.
    var fallbackProjects: [String: String]
    var warnings: [String: String]
}

@MainActor
private final class WallpaperController {
    private enum TransientPauseReason: Hashable {
        case systemSleep
        case displaySleep
        case inactiveSession
    }

    private let configuration: LaunchConfiguration
    private var applicationRuleOverride: Bool
    /// Wallpaper and playlist rules replace independent projects with their
    /// selected default. A profile rule instead owns the whole captured layout
    /// for its temporary presentation without writing that layout to defaults.
    private var applicationRuleUsesFullLayout: Bool
    var isApplicationRuleOverride: Bool { applicationRuleOverride }
    private var project: WallpaperProject?
    var currentProject: WallpaperProject? { project }
    private var windows: [NSWindow] = []
    private var renderables: [WallpaperRenderable] = []
    private var antialiasingAttempt: String?
    private var antialiasingFailure: String?
    private var postProcessingAttempt: String?
    private var postProcessingFailure: String?
    private var textureResolutionAttempt: String?
    private var textureResolutionFailure: String?
    private var displayProjects: [WallpaperProject] = []
    private var activeLayout = NativeDisplayLayout()
    private var displayWarnings: [String: String] = [:]
    private var watchers: [ProjectFileWatcher] = []
    private var assignmentCheckTask: Task<Void, Never>?
    private var assignmentCheckRequested = false
    private var audioOutputAllowed = true
    private var presentationOpacity: CGFloat = 1
    private var reloadWorkItem: DispatchWorkItem?
    private var pendingReloadReasons: [String] = []
    private var reloadHistory: [String] = []
    private var reloadTask: Task<Void, Never>?
    /// A desktop-wide stop cancels only background reload work; the selected
    /// project remains authoritative.  If cancellation is still unwinding when
    /// the last stop source clears, this marker schedules exactly one fresh
    /// rebuild from that retained selection.
    private var reloadAfterDesktopStop = false
    private var desktopRecoveryWork: DispatchWorkItem?
    private var desktopRecoveryReasons: Set<NativeDesktopRecoveryReason> = []
    private var desktopRecoveryHistory: [String] = []
    private var activeLoads = 0
    private var loadGeneration = 0
    /// Unlike a CoreGraphics display number, a `session:` key is only valid
    /// for the connection generation in which it was observed.  This value is
    /// advanced synchronously by AppDelegate's topology notification path,
    /// including for a pending controller that has not made a window yet.
    /// A prepared candidate captures it and must still match at its final
    /// commit boundary.
    private var observedDisplayTopologyGeneration = 0
    private var stopped = false
    private var ruleSuspended = false
    private var rulePolicyRevision = 0
    private var applyingProperties = false
    private var transientPauseReasons: Set<TransientPauseReason> = []
    private var playbackEnvironment = NativePlaybackEnvironment(preferences: .load())
    private var appliedPauseStates: [ObjectIdentifier: Bool] = [:]
    private var appliedPauseReasons: [ObjectIdentifier: String] = [:]
    private var audioOwnerIndex: Int?
    private var playbackTransitions: [String] = []
    private(set) var isPaused = false
    var statusChanged: ((String) -> Void)?
    var reloadFailed: ((Error) -> Void)?
    var projectDidLoad: (() -> Void)?
    var previewClosed: (() -> Void)?
    var willApplyProperties: ((WallpaperProject) throws -> Void)?
    var defaultVideoDidEnd: (() -> Void)?
    /// A display with an explicit assignment owns its own playback context.
    /// Keep its end event separate from the historical default scheduler so a
    /// video ending on one screen can never advance another screen's list.
    var displayVideoDidEnd: ((String) -> Void)?
    var previewIsIndependent = false
    var playbackSummary: String {
        if ruleSuspended {
            let source = playbackEnvironment.desktopStopRequest.primarySource?.summary ?? "播放策略"
            return source + (activeLoads > 0 ? "：正在停止壁纸…" : "：已停止壁纸并释放资源")
        }
        guard !renderables.isEmpty else { return project == nil ? "尚未打开壁纸" : "动态壁纸已关闭" }
        let paused = renderables.indices.compactMap { pauseReason(at: $0) }
        let notices = Array(Set(renderables.compactMap(\.playbackNotice))).sorted()
        if !notices.isEmpty {
            let policy = paused.count == renderables.count ? Array(Set(paused)).sorted() : []
            return (policy + notices).joined(separator: "；")
        }
        if paused.count == renderables.count { return Array(Set(paused)).sorted().joined(separator: "；") }
        if !paused.isEmpty { return "\(renderables.count - paused.count)/\(renderables.count) 块屏幕播放中" }
        return configuration.mode == .desktop ? "桌面播放中" : "窗口播放中"
    }
    var playbackReport: String {
        if ruleSuspended { return (project?.title ?? "壁纸") + "\n" + playbackSummary + "。停止状态解除后重新加载，保留原壁纸选择与手动暂停状态。" }
        var recovery = desktopRecoveryHistory.isEmpty ? "" : "\n桌面恢复记录：\n" + desktopRecoveryHistory.suffix(3).joined(separator: "\n")
        if let antialiasingFailure { recovery += "\n抗锯齿设置未应用：" + antialiasingFailure }
        if let postProcessingFailure { recovery += "\n后处理设置未应用：" + postProcessingFailure }
        if let textureResolutionFailure { recovery += "\n纹理分辨率未应用：" + textureResolutionFailure }
        guard !renderables.isEmpty else { return (project.map { $0.title + "\n已关闭动态壁纸，或当前没有可用显示器。" } ?? "尚未打开壁纸。") + recovery }
        let screens = renderables.indices.map { index in
            let name = (windows[index] as? DesktopWindow)?.displayName ?? "窗口预览"
            let reason = pauseReason(at: index)
            let details = renderables[index].playbackDescription
            return "\(name) · \(displayProjects[index].title)：\(reason ?? renderables[index].playbackNotice ?? "播放中")" + (details.isEmpty ? "" : "\n" + details)
        }
        let recent = playbackTransitions.suffix(3)
        return (["默认项目：" + (project?.title ?? "壁纸")] + screens + (recent.isEmpty ? [] : ["最近的播放变化："] + recent)).joined(separator: "\n") + recovery
    }
    var compatibilityReport: String {
        guard !renderables.isEmpty else { return "当前没有显示中的动态壁纸。" }
        return renderables.indices.map { index in
            let warning = (windows[index] as? DesktopWindow).flatMap { displayWarnings[$0.displayKey] }
            let notices = warning.map { ["独立项目暂时不可用，显示默认壁纸：" + $0] } ?? []
            let messages = Array(Set(renderables[index].diagnostics + displayProjects[index].propertyDiagnostics + notices)).sorted()
            let name = (windows[index] as? DesktopWindow)?.displayName ?? "窗口预览"
            return ([name + " · " + displayProjects[index].title] + (messages.isEmpty ? ["项目已加载，兼容性取决于其使用的功能。"] : messages)).joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n项目加载代次：\(loadGeneration)；已忽略 \(watchers.reduce(0) { $0 + $1.ignoredMetadataEvents }) 条纯扩展属性或历史边界通知。"
            + (reloadHistory.isEmpty ? "" : "\n最近重新加载记录：\n" + reloadHistory.suffix(3).joined(separator: "\n"))
    }

    init(configuration: LaunchConfiguration, initiallyPaused: Bool = false, audioOutputAllowed: Bool = true,
         applicationRuleOverride: Bool = false, applicationRuleUsesFullLayout: Bool = false) {
        self.configuration = configuration
        self.applicationRuleOverride = applicationRuleOverride
        self.applicationRuleUsesFullLayout = applicationRuleUsesFullLayout
        self.audioOutputAllowed = audioOutputAllowed
        isPaused = initiallyPaused
    }

    /// A per-display manual transaction can promote a temporary full profile
    /// into ordinary persisted desktop state without replacing unaffected
    /// windows.  Subsequent reload/recovery must therefore stop applying the
    /// old application's presentation-only layout policy.
    func relinquishApplicationRuleOverride() {
        applicationRuleOverride = false; applicationRuleUsesFullLayout = false
    }

    func start(layout: NativeDisplayLayout? = nil, strictKeys: Set<String> = [], propertySnapshots: [String: WallpaperPropertyStore.Snapshot] = [:], beforePresentation: (() throws -> Void)? = nil) async throws {
        try await loadAndPresent(layout: layout, strictKeys: strictKeys, propertySnapshots: propertySnapshots, beforePresentation: beforePresentation)
    }
    func enableAudioOutput() { audioOutputAllowed = true; updatePlaybackState() }
    func disableAudioOutput() { audioOutputAllowed = false; updatePlaybackState() }
    func setPresentationOpacity(_ value: CGFloat) {
        presentationOpacity = value; windows.forEach { $0.alphaValue = value }
    }
    func fadeIn(duration: Double, completion: @escaping () -> Void) {
        presentationOpacity = 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            for window in windows { window.animator().alphaValue = 1 }
        } completionHandler: { completion() }
    }
    var defaultPlaylistPaused: Bool {
        let indices = renderables.indices.filter { index in
            guard let window = windows[index] as? DesktopWindow else { return configuration.mode == .preview }
            return activeLayout.displays[window.displayKey]?.projectPath == nil
        }
        return indices.isEmpty || indices.allSatisfy { pauseReason(at: $0) != nil }
    }

    /// `activeLayout` is the renderer's committed layout, not a draft from the
    /// display panel.  AppDelegate uses this only as the source of a new
    /// target transaction; it never substitutes a missing display with the
    /// default target.
    var committedDisplayLayout: NativeDisplayLayout { activeLayout }

    func playlistPaused(forDisplay key: String) -> Bool {
        guard let index = windows.firstIndex(where: { ($0 as? DesktopWindow)?.displayKey == key }),
              renderables.indices.contains(index) else { return true }
        return pauseReason(at: index) != nil
    }

    func projectForDisplay(_ key: String) -> WallpaperProject? {
        guard let index = windows.firstIndex(where: { ($0 as? DesktopWindow)?.displayKey == key }), displayProjects.indices.contains(index) else { return nil }
        return displayProjects[index]
    }
    func displayStatus(_ key: String) -> String {
        guard configuration.mode == .desktop else { return "当前为窗口预览；返回桌面显示后可应用屏幕设置。" }
        guard NativeDisplayDescriptor.connected().contains(where: { $0.key == key }) else { return "屏幕未连接，已保存配置会在重新连接后尝试恢复。" }
        guard activeLayout.displays[key]?.enabled != false else { return "此屏幕的动态壁纸已关闭。" }
        guard let index = windows.firstIndex(where: { ($0 as? DesktopWindow)?.displayKey == key }), displayProjects.indices.contains(index) else { return "此屏幕尚无已加载的壁纸。" }
        var text = "当前显示：" + displayProjects[index].title
        text += "\n" + (pauseReason(at: index) ?? renderables[index].playbackNotice ?? "播放中") + " · " + renderables[index].playbackDescription
        if audioOwnerIndex == index { text += "\n壁纸声音由此屏幕输出。" }
        if let warning = displayWarnings[key] { text += "\n独立壁纸暂时不可用，当前显示默认壁纸。配置仍保留：" + warning }
        return text
    }

    /// Prepare every changed screen while the current desktop stays live.  A
    /// caller that owns additional preference bytes (per-display playlists and
    /// progress) supplies one last synchronous commit hook.  The hook runs
    /// only after all renderers are ready and immediately before layout bytes
    /// and windows become visible; it must restore its own snapshots on error.
    func applyDisplayLayout(_ proposal: NativeDisplayLayout, saveLayout: Bool = true,
                            beforeCommit: ((NativeDisplayLayout) throws -> Void)? = nil) async throws {
        guard configuration.mode == .desktop, !stopped else { throw PropertyError.invalid("请先返回桌面显示。") }
        let valid = try proposal.validated()
        let changed = Set(valid.displays.keys.filter { valid.displays[$0] != activeLayout.displays[$0] })
        // A chosen Steam project is retained before it becomes a persistent
        // display assignment. Cancellation may leave a valid saved copy, but
        // cannot change the committed display layout or current windows.
        let retained = try await SavedWorkshopStore.perform {
            var next = valid
            for (key, entry) in valid.displays {
                guard changed.contains(key), let path = entry.projectPath else { continue }
                var entry = entry
                let url = URL(fileURLWithPath: path)
                if SteamLibraryIndex.location(for: url) != nil {
                    let record = try SavedWorkshopStore.save(project: url, id: url.deletingLastPathComponent().lastPathComponent)
                    entry.projectPath = record.project.path; entry.projectTitle = record.title; entry.workshopID = record.id
                } else if let record = SavedWorkshopStore.recordForProject(url) {
                    entry.workshopID = record.id; entry.projectTitle = record.title
                }
                if let resolved = NativeDisplayLayout.resolvedProject(entry), entry.enabled { _ = try WallpaperProject.load(from: resolved) }
                next.displays[key] = entry
            }
            return try next.validated()
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        reloadTask?.cancel()
        try await loadAndPresent(layout: retained, saveLayout: saveLayout, strictKeys: changed,
                                 reuse: .matchingAssignments,
                                 beforePresentation: { try beforeCommit?(retained) })
    }

    func checkAssignedUpdates() {
        guard !stopped, configuration.mode == .desktop else { return }
        assignmentCheckRequested = true
        startAssignmentCheckIfReady()
    }

    private func startAssignmentCheckIfReady() {
        // An invalidation can arrive while an older scan is returning, while
        // a display change is preparing, or before the first host is committed.
        // Keep one pending hint and resolve it against the next stable layout.
        guard !stopped, !ruleSuspended, assignmentCheckRequested, assignmentCheckTask == nil, activeLoads == 0 else { return }
        assignmentCheckRequested = false
        let layout = activeLayout, generation = loadGeneration
        let actual = Dictionary(windows.enumerated().compactMap { index, window -> (String, String)? in
            guard let window = window as? DesktopWindow, displayProjects.indices.contains(index) else { return nil }
            return (window.displayKey, displayProjects[index].projectURL.path)
        }, uniquingKeysWith: { first, _ in first })
        assignmentCheckTask = Task { [weak self] in
            defer {
                self?.assignmentCheckTask = nil
                self?.startAssignmentCheckIfReady()
            }
            let changed = try? await WebMediaIO.perform {
                layout.displays.contains { key, entry in
                    guard entry.enabled, entry.workshopID != nil, let running = actual[key], let resolved = NativeDisplayLayout.resolvedProject(entry) else { return false }
                    return resolved.path != running
                }
            }
            guard let self, !Task.isCancelled, !self.stopped, !self.ruleSuspended else { return }
            guard generation == self.loadGeneration else {
                // The old result describes a presentation that has changed.
                // The original hint still needs a check against the new one.
                self.assignmentCheckRequested = true
                return
            }
            guard changed == true else { return }
            self.reloadNow(reason: "独立屏幕的工坊版本已更新", preserveUnchangedDisplays: true)
        }
    }

    var hotkeyDesktopWindows: [DesktopWindow] {
        guard configuration.mode == .desktop else { return [] }
        return windows.compactMap { $0 as? DesktopWindow }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        updatePlaybackState()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        updatePlaybackState()
    }

    func suspendForSystemSleep() { suspend(for: .systemSleep) }
    func resumeFromSystemSleep() { resume(after: .systemSleep); requestDesktopRecovery(.systemWake) }
    func suspendForDisplaySleep() { suspend(for: .displaySleep) }
    func resumeFromDisplaySleep() { resume(after: .displaySleep); requestDesktopRecovery(.displayWake) }
    func suspendForInactiveSession() { suspend(for: .inactiveSession) }
    func resumeFromInactiveSession() { resume(after: .inactiveSession); requestDesktopRecovery(.activeSession) }
    func updatePlaybackPolicy(_ environment: NativePlaybackEnvironment) {
        playbackEnvironment = environment
        guard !stopped else { return }
        let suspend = configuration.mode == .desktop && environment.stopsDesktop
        if suspend != ruleSuspended {
            rulePolicyRevision += 1
            ruleSuspended = suspend
            if suspend {
                // A policy stop means no decoded/pending presentation should
                // continue consuming resources.  Unlike `stop()`, do not
                // cancel an AppDelegate open transaction: an in-flight direct
                // `start` retries through the existing policy revision fence
                // and commits only project metadata while stopped.  These are
                // controller-local background reloads and checks instead.
                // This is intentionally unconditional: a candidate can still
                // be preparing its first metadata when the stop arrives. Its
                // load defer will retry recovery after a project exists.
                reloadAfterDesktopStop = true
                reloadTask?.cancel()
                reloadTask = nil
                reloadWorkItem?.cancel()
                reloadWorkItem = nil
                pendingReloadReasons.removeAll()
                desktopRecoveryWork?.cancel()
                desktopRecoveryWork = nil
                desktopRecoveryReasons.removeAll()
                if assignmentCheckTask != nil { assignmentCheckRequested = true }
                assignmentCheckTask?.cancel()
                clearPresentations()
                watchers.forEach { $0.stop() }; watchers.removeAll()
                publishPlaybackStatus()
            } else {
                // Keep this intent until the cancelled task actually unwinds.
                // Without it, a stop/release pair during preparation would
                // swallow CancellationError and leave the saved selection
                // permanently renderer-free.
                resumeDesktopStopIfReady()
            }
        }
        // A source handoff (for example fullscreen clears while a hotkey stop
        // remains) changes the explanatory text but must neither recreate nor
        // retain a renderer.  Publish the current union source immediately.
        if ruleSuspended {
            publishPlaybackStatus()
            return
        }
        updatePlaybackState()
    }

    /// Rebuild exactly once after the last global stop source clears. A stop
    /// can arrive before first-load metadata exists, and cancellation can
    /// unwind after release, so this guard is also called from the load defer.
    private func resumeDesktopStopIfReady() {
        guard reloadAfterDesktopStop, !stopped, !ruleSuspended, activeLoads == 0,
              transientPauseReasons.isEmpty, project != nil else { return }
        // A direct first-load transaction may have won the race with this
        // recovery marker. It already published a fresh renderer, so consume
        // the marker rather than letting some later empty transition reload it.
        guard renderables.isEmpty else { reloadAfterDesktopStop = false; return }
        reloadAfterDesktopStop = false
        reloadNow(reason: "停止状态解除")
    }

    @discardableResult
    func stop() -> Task<Void, Never>? {
        stopped = true; reloadAfterDesktopStop = false; loadGeneration += 1
        let pendingReload = reloadTask
        reloadTask?.cancel(); reloadTask = nil
        reloadWorkItem?.cancel()
        reloadWorkItem = nil
        desktopRecoveryWork?.cancel(); desktopRecoveryWork = nil; desktopRecoveryReasons.removeAll()
        watchers.forEach { $0.stop() }; watchers.removeAll()
        assignmentCheckTask?.cancel(); assignmentCheckTask = nil
        assignmentCheckRequested = false
        clearPresentations()
        return pendingReload
    }

    func reloadNow(reason: String = "手动重新加载", preserveUnchangedDisplays: Bool = false) {
        guard !stopped else { return }
        guard !ruleSuspended else {
            // A delayed file-watcher work item can race the stop transition.
            // Coalesce it into the mandatory fresh rebuild after the final
            // source clears rather than allocating resources while stopped.
            if configuration.mode == .desktop, project != nil { reloadAfterDesktopStop = true }
            return
        }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            let entry = "\(time) · \(reason)"
            reloadHistory.append(entry)
            if reloadHistory.count > 8 { reloadHistory.removeFirst(reloadHistory.count - 8) }
            fputs("Wallpaper reload requested: \(entry)\n", stderr)
            // A stop can cancel this task before it has entered
            // `loadAndPresent`. Do not let that stale task increment the
            // shared load generation after the final source has already
            // scheduled a fresh recovery reload.
            do {
                try Task.checkCancellation()
                try await self.loadAndPresent(reuse: preserveUnchangedDisplays ? .matchingAssignments : .none)
            }
            catch is CancellationError { }
            catch {
                fputs("Wallpaper reload failed: \(error.localizedDescription)\n", stderr)
                self.statusChanged?("重新加载失败")
                self.reloadFailed?(error)
            }
        }
    }

    func requestDesktopRecovery(_ reason: NativeDesktopRecoveryReason) {
        guard configuration.mode == .desktop, !stopped, !ruleSuspended else { return }
        desktopRecoveryReasons.insert(reason)
        scheduleDesktopRecovery()
    }

    /// Applies an already-observed session-display loss immediately.  Waiting
    /// for the delayed desktop reconciliation would let a reconnected monitor
    /// with the same CoreGraphics number inherit this controller's old
    /// renderer, layout, or process-local property scope.
    ///
    /// The caller computes `keys` from its previous topology before replacing
    /// that observation with the current one.  This controller deliberately
    /// does not infer a loss from a later current connection set: by then the
    /// same `session:` key may describe a different monitor generation.
    @discardableResult
    func observeDisconnectedSessionTargets(_ keys: Set<String>) -> Set<String> {
        let disconnected = Set(keys.filter { $0.hasPrefix("session:") })
        guard !disconnected.isEmpty, !stopped else { return [] }

        // This must also invalidate an empty pending candidate.  Its resource
        // preparation may have observed the old session before a window or
        // active layout existed, so filtering only live windows is unsound.
        observedDisplayTopologyGeneration &+= 1
        loadGeneration &+= 1

        var stillPresentSessionKeys = Set(activeLayout.displays.keys.filter {
            $0.hasPrefix("session:") && !disconnected.contains($0)
        })
        if let audio = activeLayout.preferredAudioDisplay,
           audio.hasPrefix("session:"), !disconnected.contains(audio) {
            stillPresentSessionKeys.insert(audio)
        }
        activeLayout = activeLayout.droppingDisconnectedSessionTargets(connectedSessionKeys: stillPresentSessionKeys)

        let removed = windows.enumerated().compactMap { index, window -> Presentation? in
            guard let desktop = window as? DesktopWindow,
                  disconnected.contains(desktop.displayKey),
                  renderables.indices.contains(index), displayProjects.indices.contains(index) else {
                return nil
            }
            return Presentation(window: window, renderable: renderables[index], project: displayProjects[index])
        }
        let kept = windows.enumerated().compactMap { index, window -> Presentation? in
            guard let desktop = window as? DesktopWindow,
                  !disconnected.contains(desktop.displayKey),
                  renderables.indices.contains(index), displayProjects.indices.contains(index) else {
                return nil
            }
            return Presentation(window: window, renderable: renderables[index], project: displayProjects[index])
        }
        let keptWindows = Set(kept.map { ObjectIdentifier($0.window) })
        let keptRenderers = Set(kept.map { ObjectIdentifier($0.renderable) })
        let previousStates = appliedPauseStates.filter { keptRenderers.contains($0.key) }
        let previousReasons = appliedPauseReasons.filter { keptRenderers.contains($0.key) }
        let previousAudioWindow = audioOwnerIndex.flatMap { windows.indices.contains($0) ? ObjectIdentifier(windows[$0]) : nil }

        // `clearPresentations(keeping:)` synchronously pauses, mutes and
        // closes removed renderers before their key can be reused.
        clearPresentations(keeping: keptWindows)
        var projectsToPrune = Set<URL>()
        for item in removed {
            guard case .display(let key) = item.project.propertyTarget,
                  disconnected.contains(key) else { continue }
            projectsToPrune.insert(item.project.projectURL)
        }
        for project in projectsToPrune {
            _ = WallpaperPropertyStore.pruneUnreferencedMediaGrants(project: project)
        }
        windows = kept.map(\.window); renderables = kept.map(\.renderable); displayProjects = kept.map(\.project)
        appliedPauseStates = previousStates; appliedPauseReasons = previousReasons
        audioOwnerIndex = windows.firstIndex { ObjectIdentifier($0) == previousAudioWindow }
        displayWarnings = displayWarnings.filter { !disconnected.contains($0.key) }
        updatePlaybackState(); publishPlaybackStatus()
        return Set(removed.compactMap { ($0.window as? DesktopWindow)?.displayKey })
    }

    private func scheduleDesktopRecovery() {
        desktopRecoveryWork?.cancel(); desktopRecoveryWork = nil
        // Pending events survive sleep and resource preparation. The last wake
        // notification or the load's defer schedules a single reconciliation.
        guard !stopped, !ruleSuspended, activeLoads == 0, transientPauseReasons.isEmpty,
              !desktopRecoveryReasons.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.recoverDesktop() }
        desktopRecoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func recoverDesktop() {
        desktopRecoveryWork = nil
        guard !stopped, !ruleSuspended, configuration.mode == .desktop, activeLoads == 0,
              transientPauseReasons.isEmpty, project != nil else { return }
        let reasons = desktopRecoveryReasons; desktopRecoveryReasons.removeAll()
        guard !reasons.isEmpty else { return }
        let displays = NativeDisplayDescriptor.connected().filter { activeLayout.displays[$0.key]?.enabled != false }
        let descriptors = Dictionary(uniqueKeysWithValues: displays.map { ($0.key, $0) })
        activeLayout = activeLayout.droppingDisconnectedSessionTargets(connectedSessionKeys: Set(descriptors.keys))
        let previousCount = windows.count
        let detachedSessionProjects = windows.enumerated().compactMap { index, window -> WallpaperProject? in
            guard let desktop = window as? DesktopWindow, descriptors[desktop.displayKey] == nil,
                  displayProjects.indices.contains(index),
                  case .display(let key) = displayProjects[index].propertyTarget,
                  key.hasPrefix("session:") else { return nil }
            return displayProjects[index]
        }
        let kept = windows.enumerated().compactMap { index, window -> Presentation? in
            guard let desktop = window as? DesktopWindow, descriptors[desktop.displayKey] != nil else { return nil }
            return Presentation(window: desktop, renderable: renderables[index], project: displayProjects[index])
        }
        let keptWindows = Set(kept.map { ObjectIdentifier($0.window) })
        let keptRenderers = Set(kept.map { ObjectIdentifier($0.renderable) })
        let previousStates = appliedPauseStates.filter { keptRenderers.contains($0.key) }
        let previousReasons = appliedPauseReasons.filter { keptRenderers.contains($0.key) }
        let previousAudioWindow = audioOwnerIndex.flatMap { windows.indices.contains($0) ? ObjectIdentifier(windows[$0]) : nil }
        // Detached displays stop drawing and producing sound even if preparing
        // a newly attached display later fails. Saved assignments remain intact.
        clearPresentations(keeping: keptWindows)
        // Session identifiers are deliberately not durable display identity.
        // Once the descriptor is gone, discard every in-memory override for
        // that volatile target (not merely this controller's currently shown
        // project); UUID/default records remain untouched.
        let detachedSessionKeys = Set(detachedSessionProjects.compactMap { project -> String? in
            guard case .display(let key) = project.propertyTarget else { return nil }
            return key.hasPrefix("session:") ? key : nil
        })
        _ = WallpaperPropertyStore.discardDisconnectedSessionTargets(detachedSessionKeys)
        for detached in detachedSessionProjects {
            _ = WallpaperPropertyStore.pruneUnreferencedMediaGrants(project: detached.projectURL)
        }
        windows = kept.map(\.window); renderables = kept.map(\.renderable); displayProjects = kept.map(\.project)
        appliedPauseStates = previousStates; appliedPauseReasons = previousReasons
        audioOwnerIndex = windows.firstIndex { ObjectIdentifier($0) == previousAudioWindow }
        displayWarnings = displayWarnings.filter { descriptors[$0.key] != nil }
        var adjusted = 0
        for item in kept {
            guard let window = item.window as? DesktopWindow, let descriptor = descriptors[window.displayKey] else { continue }
            if window.reconcile(with: descriptor) { adjusted += 1 }
            item.renderable.refreshPresentation()
        }
        updatePlaybackState(); publishPlaybackStatus()
        let removed = previousCount - kept.count
        guard kept.count != displays.count else {
            recordDesktopRecovery(reasons, detail: "保留 \(kept.count) 个播放实例，调整 \(adjusted) 块屏幕，移除 \(removed) 块屏幕")
            return
        }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.loadAndPresent(layout: self.activeLayout, reuse: .all)
                let preserved = self.windows.filter { keptWindows.contains(ObjectIdentifier($0)) }.count
                self.recordDesktopRecovery(reasons, detail: "保留 \(preserved) 个播放实例，新增 \(self.windows.count - preserved) 块屏幕，移除 \(previousCount - preserved) 块屏幕")
            } catch is CancellationError { }
            catch {
                guard !self.stopped else { return }
                self.recordDesktopRecovery(reasons, detail: "恢复未完成：" + String(error.localizedDescription.prefix(512)))
                self.statusChanged?("部分屏幕恢复未完成，可重新加载")
            }
        }
    }

    private func recordDesktopRecovery(_ reasons: Set<NativeDesktopRecoveryReason>, detail: String) {
        let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "\(time) · \(reasons.map(\.rawValue).sorted().joined(separator: "、"))：\(detail)"
        desktopRecoveryHistory.append(entry)
        if desktopRecoveryHistory.count > 8 { desktopRecoveryHistory.removeFirst(desktopRecoveryHistory.count - 8) }
        fputs("Native desktop recovery: \(entry)\n", stderr)
    }

    func applyPropertyValues(_ values: [String: Any], mediaSelections: [String: URL],
                             target requestedTarget: NativeDisplayTarget = .defaultWallpaper,
                             projectURL: URL? = nil) async throws -> (count: Int, payload: [String: Any]) {
        let requestedURL = projectURL?.standardizedFileURL.resolvingSymlinksInPath()
        func matchesRequestedScope(_ candidate: WallpaperProject) -> Bool {
            candidate.propertyTarget == requestedTarget &&
                (requestedURL == nil || candidate.projectURL == requestedURL)
        }
        // Never resolve an explicit screen through a same-project renderer on
        // another screen.  The default project keeps its original behaviour:
        // it owns every default/inherited display using the V1 scope.
        guard var project = displayProjects.first(where: matchesRequestedScope) ??
                self.project.flatMap({ matchesRequestedScope($0) ? $0 : nil }) else {
            throw PropertyError.invalid("请先在此显示器上打开这张壁纸。")
        }
        guard !stopped, activeLoads == 0, !applyingProperties else { throw PropertyError.invalid("正在准备壁纸或处理设置，请稍后重试。") }
        let scope = project.propertyScope
        guard scope.targetKey == requestedTarget.key,
              WallpaperPropertyStore.isCurrent(project.propertyRevision, for: scope) else {
            throw PropertyError.invalid("壁纸设置已改变，请重新打开设置窗口。")
        }
        applyingProperties = true; defer { applyingProperties = false }
        let generation = loadGeneration
        let targets = renderables.enumerated().filter { entry in
            let displayed = displayProjects[entry.offset]
            guard displayed.projectURL == project.projectURL else { return false }
            if displayed.propertyScope == scope { return true }
            // Default settings retain the legacy global behaviour for a
            // concrete screen that has not yet saved its own V2/session
            // override.  Once it has one, only that screen can change it.
            return requestedTarget == .defaultWallpaper && displayed.propertyRevision.legacyFallback != nil
        }.map(\.element)
        guard !targets.isEmpty else { throw PropertyError.invalid("此显示器的壁纸已切换，请重新打开设置。") }
        // A V1/default change still flows into every live display that has
        // not saved its own scope.  Capture each such scope before the write:
        // Browser Cancel later prepares those display renderers before it
        // restores V1, so their snapshots must carry the old fallback bytes.
        try willApplyProperties?(project)
        if requestedTarget == .defaultWallpaper {
            for displayed in displayProjects where displayed.projectURL == project.projectURL &&
                    displayed.propertyScope != scope && displayed.propertyRevision.legacyFallback != nil {
                try willApplyProperties?(displayed)
            }
        }
        let sourceProject = project
        let sourceRevision = (targets.first as? WebWallpaperView)?.mediaSourceRevision
        var values = values
        // Reservation pins a newly-created grant while the property JSON is
        // still uncommitted. Creation, property writes, and all-scope
        // inventory/prune share one transaction lock, so another display can
        // never observe this token as unreferenced in the gap.
        var pendingGrantReservation: WallpaperMediaGrants.Reservation?
        defer { pendingGrantReservation?.cancel() }
        let selected = try await WebMediaIO.perform {
            try WallpaperMediaGrants.reserve(project: sourceProject.projectURL) { builder in
                var grants: [String: String] = [:]
                for (key, source) in mediaSelections {
                    guard sourceProject.kind == .web, let property = sourceProject.propertyDefinitions.first(where: { $0.key == key }), property.isMedia, property.editable,
                          let sourceRevision else { throw PropertyError.invalid("当前项目不支持此素材选择。") }
                    grants[key] = try builder.create(source: source, property: property, sourceRevision: sourceRevision)
                }
                return grants
            }
        }
        pendingGrantReservation = selected.reservation
        selected.value.forEach { values[$0.key] = $0.value }
        try Task.checkCancellation()
        var changes: [String: Any] = [:]
        for (key, value) in values {
            guard let property = project.propertyDefinitions.first(where: { $0.key == key }), property.editable else { throw PropertyError.invalid("壁纸设置已改变，请重新打开设置窗口。") }
            let normalized = try property.normalized(value)
            if !WallpaperProperty.equal(normalized, (project.userProperties[key] as? [String: Any])?["value"]) { changes[key] = property.payload(normalized) }
        }
        guard !changes.isEmpty else { return (0, project.userProperties) }
        // Copies and validation finish before the settings file or live views
        // change. Dropping an uncommitted closure releases its prepared media.
        var updates: [() -> Void] = []
        let revisions = targets.map(\.propertyUpdateRevision)
        for target in targets { updates.append(try await target.prepareUserPropertyUpdate(changes)) }
        try Task.checkCancellation()
        guard !stopped, loadGeneration == generation else { throw PropertyError.invalid("壁纸在准备素材时已重新加载，未保存本次更改。请重新打开设置。") }
        guard targets.map(\.propertyUpdateRevision) == revisions else { throw PropertyError.invalid("壁纸脚本在准备素材期间改变了场景；本次设置尚未保存，请重新应用。") }
        guard WallpaperPropertyStore.isCurrent(project.propertyRevision, for: scope),
              displayProjects.contains(where: { $0.projectURL == project.projectURL && $0.propertyScope == scope }) ||
                self.project?.propertyScope == scope else {
            throw PropertyError.invalid("此显示器的壁纸已切换，请重新打开设置。")
        }
        project.userProperties.merge(changes) { _, next in next }
        let resolvedMediaIssueKeys = Set(changes.keys).filter { key in
            project.propertyDefinitions.first(where: { $0.key == key })?.isMedia == true
        }
        project.propertyLoadIssues.removeAll { resolvedMediaIssueKeys.contains($0.propertyKey) }
        let resolvedMediaDiagnostics = resolvedMediaIssueKeys.reduce(into: Set<String>()) { diagnostics, key in
            diagnostics.formUnion(WallpaperPropertyLoadIssue.mediaAuthorizationDiagnostics(propertyKey: key))
        }
        project.propertyDiagnostics.removeAll { resolvedMediaDiagnostics.contains($0) }
        try WallpaperPropertyStore.save(project: project.projectURL, scope: scope,
                                        definitions: project.propertyDefinitions, payload: project.userProperties)
        project.propertyRevision = WallpaperPropertyStore.revision(for: project.projectURL, scope: scope)
        if self.project?.projectURL == project.projectURL, self.project?.propertyScope == scope { self.project = project }
        for index in displayProjects.indices where displayProjects[index].projectURL == project.projectURL {
            if displayProjects[index].propertyScope == scope {
                displayProjects[index] = project
            } else if requestedTarget == .defaultWallpaper,
                      displayProjects[index].propertyRevision.legacyFallback != nil {
                var inherited = displayProjects[index]
                inherited.userProperties.merge(changes) { _, next in next }
                inherited.propertyLoadIssues.removeAll { resolvedMediaIssueKeys.contains($0.propertyKey) }
                inherited.propertyDiagnostics.removeAll { resolvedMediaDiagnostics.contains($0) }
                inherited.propertyRevision = WallpaperPropertyStore.revision(for: inherited.projectURL, scope: inherited.propertyScope)
                displayProjects[index] = inherited
            }
        }
        updates.forEach { $0() }
        // The store inventories V1, every UUID record (including disconnected
        // displays), and live session records before deleting grants.  It
        // returns false for unknown/corrupt records, preserving all grants.
        _ = WallpaperPropertyStore.pruneUnreferencedMediaGrants(project: project.projectURL)
        pendingGrantReservation?.commit()
        pendingGrantReservation = nil
        fputs("Wallpaper settings saved: \(project.title) [\(scope.targetKey)]; changed keys \(changes.keys.sorted().joined(separator: ","))\n", stderr)
        return (changes.count, project.userProperties)
    }

    private func scheduleReload(reason: String) {
        guard !stopped else { return }
        reloadWorkItem?.cancel()
        if pendingReloadReasons.count < 3 { pendingReloadReasons.append(reason) }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !stopped else { return }
            let reason = pendingReloadReasons.joined(separator: "；")
            pendingReloadReasons.removeAll()
            reloadNow(reason: "项目文件变化：" + reason)
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    private struct Presentation {
        let window: NSWindow
        let renderable: WallpaperRenderable
        let project: WallpaperProject
    }
    private enum PresentationReuse { case none, all, matchingAssignments }
    private enum PresentationError: Error { case displayConfigurationChanged, propertiesChanged, rulePolicyChanged }
    private func loadAndPresent(layout: NativeDisplayLayout? = nil, saveLayout: Bool = false, strictKeys: Set<String> = [], reuse: PresentationReuse = .none, propertySnapshots: [String: WallpaperPropertyStore.Snapshot] = [:], beforePresentation: (() throws -> Void)? = nil) async throws {
        loadGeneration += 1
        let generation = loadGeneration
        let topologyGeneration = observedDisplayTopologyGeneration
        activeLoads += 1
        defer {
            activeLoads -= 1
            if ruleSuspended && activeLoads == 0 { publishPlaybackStatus() }
            resumeDesktopStopIfReady()
            if !desktopRecoveryReasons.isEmpty { scheduleDesktopRecovery() }
            startAssignmentCheckIfReady()
        }
        // A display change during resource I/O is transient. Retry the current
        // request with fresh screens, keeping the previous presentation intact.
        for attempt in 0..<3 {
            try Task.checkCancellation()
            guard !stopped, generation == loadGeneration else { throw CancellationError() }
            do {
                try await prepareAndPresent(layout: layout, saveLayout: saveLayout, strictKeys: strictKeys, reuse: reuse, propertySnapshots: propertySnapshots, generation: generation, topologyGeneration: topologyGeneration, beforePresentation: beforePresentation)
                return
            } catch PresentationError.displayConfigurationChanged {
                guard attempt < 2 else { throw PropertyError.invalid("显示器仍在变化，已保留原有壁纸。请在显示器稳定后重新加载。") }
                try await Task.sleep(nanoseconds: 400_000_000)
            } catch PresentationError.propertiesChanged {
                guard attempt < 2 else { throw PropertyError.invalid("壁纸设置仍在变化，已保留原有壁纸。请在设置保存完成后重新加载。") }
                statusChanged?("设置已更新，正在重新准备壁纸…")
            } catch PresentationError.rulePolicyChanged {
                guard attempt < 2 else { throw PropertyError.invalid("应用程序规则仍在变化，请在规则稳定后重新加载壁纸。") }
            }
        }
    }

    private func prepareAndPresent(layout: NativeDisplayLayout?, saveLayout: Bool, strictKeys: Set<String>, reuse: PresentationReuse, propertySnapshots: [String: WallpaperPropertyStore.Snapshot], generation: Int, topologyGeneration: Int, beforePresentation: (() throws -> Void)?) async throws {
        let source = configuration.projectURL
        let suppliedLayout = layout
        let configuredLayout = try (suppliedLayout ?? (applicationRuleOverride && applicationRuleUsesFullLayout ? activeLayout : NativeDisplayStore.load())).validated()
        let requiredKeys = strictKeys.union(suppliedLayout == nil && applicationRuleOverride && applicationRuleUsesFullLayout
            ? Set(activeLayout.displays.keys) : [])
        // A temporary rule overrides projects for presentation only. Reapply
        // on file reload, stop recovery and display reconciliation, while
        // persisting any explicit screen edits in their original form.
        let layout = applicationRuleOverride && !applicationRuleUsesFullLayout
            ? configuredLayout.replacingProjectsForApplicationRule() : configuredLayout
        let policyRevision = rulePolicyRevision
        // Browser Cancel prepares the renderers from the exact property bytes
        // it captured when the browser opened, then restores those bytes only
        // at the final presentation boundary.  Such a snapshot is necessarily
        // older than an Apply made while the browser was open, so treating it
        // as an ordinary stale renderer here would reject Cancel before its
        // owned restore can run.  This is deliberately narrower than a
        // non-empty snapshot collection: it requires the final transaction
        // hook, the exact scope key, and a matching project/scope snapshot.
        // All other projects and all ordinary reloads still take the normal
        // revision-current path below.
        func restoresOwnedSnapshot(for project: WallpaperProject) -> Bool {
            guard beforePresentation != nil,
                  let snapshot = propertySnapshots[project.propertyScope.identity],
                  snapshot.scope == project.propertyScope else {
                return false
            }
            return snapshot.project.standardizedFileURL.resolvingSymlinksInPath()
                == project.projectURL.standardizedFileURL.resolvingSymlinksInPath()
        }
        if ruleSuspended {
            // A stopped wallpaper retains its project selection, not renderers,
            // decoded media, WebKit instances, or prepared scene resources.
            var metadata = try await WebMediaIO.perform {
                let scope = try NativePropertyScope(project: source)
                return try WallpaperProject.load(from: source, propertyTarget: .defaultWallpaper,
                                                 propertySnapshot: propertySnapshots[scope.identity])
            }
            repeat {
                try Task.checkCancellation()
                guard !stopped, generation == loadGeneration else { throw CancellationError() }
                guard ruleSuspended, policyRevision == rulePolicyRevision else { throw PresentationError.rulePolicyChanged }
                if NSApp.modalWindow == nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while true
            guard restoresOwnedSnapshot(for: metadata) ||
                    WallpaperPropertyStore.isCurrent(metadata.propertyRevision, for: metadata.propertyScope) else {
                throw PresentationError.propertiesChanged
            }
            guard !stopped, generation == loadGeneration,
                  topologyGeneration == observedDisplayTopologyGeneration else { throw CancellationError() }
            try beforePresentation?()
            // The host's transaction hook may await its preparation gate.
            // Recheck after it returns so an observed disconnect cannot commit
            // this candidate's old session renderer or property bytes.
            guard !stopped, generation == loadGeneration,
                  topologyGeneration == observedDisplayTopologyGeneration else { throw CancellationError() }
            if saveLayout { try NativeDisplayStore.save(configuredLayout) }
            if !propertySnapshots.isEmpty {
                metadata.propertyRevision = WallpaperPropertyStore.revision(for: metadata.projectURL, scope: metadata.propertyScope)
            }
            clearPresentations(); watchers.forEach { $0.stop() }; watchers.removeAll()
            project = metadata; activeLayout = layout; displayWarnings = [:]
            projectDidLoad?(); publishPlaybackStatus()
            return
        }
        let screens = configuration.mode == .desktop ? NativeDisplayDescriptor.connected() : []
        let topology = screens.map(\.signature).sorted()
        var retained: [String: Presentation] = [:]
        if reuse != .none, configuration.mode == .desktop {
            for (index, window) in windows.enumerated() {
                guard let window = window as? DesktopWindow, layout.displays[window.displayKey]?.enabled != false else { continue }
                retained[window.displayKey] = Presentation(window: window, renderable: renderables[index], project: displayProjects[index])
            }
        }
        let requests = screens.filter { layout.displays[$0.key]?.enabled != false }.map { ($0.key, layout.displays[$0.key]) }
        let reusable = retained.mapValues { (url: $0.project.projectURL, scope: $0.project.propertyScope, revision: $0.project.propertyRevision) }
        statusChanged?("正在准备壁纸…")
        let preparation = try await WebMediaIO.perform {
            var resources: [String: PreparedWallpaper] = [:]
            func prepare(_ url: URL, propertyTarget: NativeDisplayTarget) throws -> String {
                let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
                let scope = try NativePropertyScope(project: canonicalURL, target: propertyTarget)
                let identity = scope.identity
                if resources[identity] == nil {
                    let project = try WallpaperProject.load(from: canonicalURL, propertyTarget: propertyTarget,
                                                            propertySnapshot: propertySnapshots[identity])
                    let workspace = project.kind == .web && project.resourceURL.isFileURL ? try WebMediaWorkspace(project: project) : nil
                    let state = try workspace?.prepare(properties: project.userProperties, previous: nil, tolerateUnavailable: true)
                    let image = project.kind == .image ? try NativeWallpaperImage.decode(project.resourceURL) : nil
                    resources[identity] = PreparedWallpaper(project: project, workspace: workspace, state: state, image: image)
                }
                return identity
            }
            let defaultKey = try prepare(source, propertyTarget: .defaultWallpaper)
            var assignments: [String: String] = [:]
            var fallbacks: [String: String] = [:]
            var warnings: [String: String] = [:]
            var retainedKeys = Set<String>()
            for (key, assignment) in requests {
                let target = assignment.flatMap(NativeDisplayLayout.resolvedProject) ?? source
                // The default library context remains the legacy V1 record,
                // while every concrete display gets its own UUID/session scope
                // (initially inheriting V1 until the screen is edited).
                let propertyTarget = NativeDisplayTarget.display(key)
                let propertyScope = try NativePropertyScope(project: target, target: propertyTarget)
                fallbacks[key] = try prepare(source, propertyTarget: propertyTarget)
                // Screen settings and independent Workshop updates should not
                // reset players whose project and saved properties are unchanged.
                // Resolve immutable Workshop versions on the I/O queue before
                // choosing which existing players can survive the transaction.
                if let previous = reusable[key], reuse == .all ||
                    (previous.url.standardizedFileURL == target.standardizedFileURL &&
                     previous.scope == propertyScope &&
                     WallpaperPropertyStore.isCurrent(previous.revision, for: previous.scope)) {
                    retainedKeys.insert(key)
                    continue
                }
                do { assignments[key] = try prepare(target, propertyTarget: propertyTarget) }
                catch {
                    guard !requiredKeys.contains(key), assignment?.projectPath != nil else { throw error }
                    assignments[key] = fallbacks[key]!
                    warnings[key] = String(error.localizedDescription.prefix(1024))
                }
            }
            return (PreparedDisplayProjects(defaultKey: defaultKey, projects: resources, displayProjects: assignments,
                                            fallbackProjects: fallbacks, warnings: warnings), retainedKeys)
        }
        var prepared = preparation.0
        retained = retained.filter { preparation.1.contains($0.key) }
        guard !ruleSuspended, policyRevision == rulePolicyRevision else { throw PresentationError.rulePolicyChanged }
        for key in prepared.projects.keys.sorted() {
            guard let resource = prepared.projects[key], resource.project.kind == .scene else { continue }
            do {
                let task = Task.detached(priority: .userInitiated) { try await SceneVideoLibrary.prepare(project: resource.project) }
                prepared.projects[key]?.videos = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                guard !ruleSuspended, policyRevision == rulePolicyRevision else { throw PresentationError.rulePolicyChanged }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                if let policy = error as? PresentationError, policy == .rulePolicyChanged { throw policy }
                // Scene preparation also reads referenced JSON and model
                // resources. Give optional display assignments the same
                // recovery policy as metadata and renderer preparation.
                let affected = prepared.displayProjects.compactMap { $0.value == key ? $0.key : nil }
                guard key != prepared.defaultKey, !affected.isEmpty,
                      affected.allSatisfy({ !requiredKeys.contains($0) }) else { throw error }
                for display in affected {
                    prepared.displayProjects[display] = prepared.fallbackProjects[display] ?? prepared.defaultKey
                    prepared.warnings[display] = String(error.localizedDescription.prefix(1024))
                }
                prepared.projects.removeValue(forKey: key)
            }
        }
        try Task.checkCancellation()
        guard !stopped, generation == loadGeneration else { throw CancellationError() }
        guard !ruleSuspended, policyRevision == rulePolicyRevision else { throw PresentationError.rulePolicyChanged }
        // FSEvents can arrive while a compatibility alert or file picker owns
        // the modal session. Replacing its preview window at that point can
        // hide the alert and leave all ordinary window actions disabled.
        // Keep the current presentation alive, then commit only the newest
        // prepared request after the modal session has ended.
        while NSApp.modalWindow != nil {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            guard !stopped, generation == loadGeneration,
                  topologyGeneration == observedDisplayTopologyGeneration else { throw CancellationError() }
            guard !ruleSuspended, policyRevision == rulePolicyRevision else { throw PresentationError.rulePolicyChanged }
        }
        if configuration.mode == .desktop, topology != NativeDisplayDescriptor.connected().map(\.signature).sorted() {
            throw PresentationError.displayConfigurationChanged
        }
        guard var defaultProject = prepared.projects[prepared.defaultKey]?.project else { throw PropertyError.invalid("默认壁纸未准备完成。") }
        var warnings = prepared.warnings
        var created = try await makePresentations(prepared: prepared, screens: screens, strictKeys: requiredKeys, warnings: &warnings, retaining: retained)
        // Player preparation may suspend. Revalidate before saving settings or
        // touching live windows, including a modal opened during that wait.
        do {
            repeat {
                try Task.checkCancellation()
                guard !stopped, generation == loadGeneration else { throw CancellationError() }
                guard !ruleSuspended, policyRevision == rulePolicyRevision else { throw PresentationError.rulePolicyChanged }
                if configuration.mode == .desktop, topology != NativeDisplayDescriptor.connected().map(\.signature).sorted() {
                    throw PresentationError.displayConfigurationChanged
                }
                if NSApp.modalWindow == nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while true
            let retainedWindows = Set(retained.values.map { ObjectIdentifier($0.window) })
            for item in created where !retainedWindows.contains(ObjectIdentifier(item.window)) {
                try item.renderable.validatePreparedPresentation()
            }
            // A different controller may have saved the same project's
            // settings for this exact target while these views were preparing.
            // Never publish an older scope snapshot after the save succeeds.
            let retainedPropertiesCurrent = reuse != .matchingAssignments || retained.values.allSatisfy {
                restoresOwnedSnapshot(for: $0.project) ||
                    WallpaperPropertyStore.isCurrent($0.project.propertyRevision, for: $0.project.propertyScope)
            }
            guard retainedPropertiesCurrent,
                  prepared.projects.values.allSatisfy({ project in
                      restoresOwnedSnapshot(for: project.project) ||
                          WallpaperPropertyStore.isCurrent(project.project.propertyRevision, for: project.project.propertyScope)
                  }) else {
                throw PresentationError.propertiesChanged
            }
        } catch {
            let retainedWindows = Set(retained.values.map { ObjectIdentifier($0.window) })
            dispose(created.filter { !retainedWindows.contains(ObjectIdentifier($0.window)) })
            throw error
        }
        let oldWindows = Set(windows.map(ObjectIdentifier.init))
        let keptWindows = Set(created.map { ObjectIdentifier($0.window) }).intersection(oldWindows)
        let keptRenderers = Set(created.filter { keptWindows.contains(ObjectIdentifier($0.window)) }.map { ObjectIdentifier($0.renderable) })
        let previousPauseStates = appliedPauseStates.filter { keptRenderers.contains($0.key) }
        let previousPauseReasons = appliedPauseReasons.filter { keptRenderers.contains($0.key) }
        let previousAudioWindow = audioOwnerIndex.flatMap { windows.indices.contains($0) ? ObjectIdentifier(windows[$0]) : nil }
        for item in created {
            if reuse == .all, let key = (item.window as? DesktopWindow)?.displayKey, keptWindows.contains(ObjectIdentifier(item.window)) {
                warnings[key] = displayWarnings[key]
            }
        }
        do {
            try Task.checkCancellation()
            guard !stopped, generation == loadGeneration else { throw CancellationError() }
            // Validate any external ownership before persisting the layout.
            // Target-aware callers set `saveLayout: false` and atomically
            // commit layout/list/progress inside this hook; ordinary display
            // edits still use the following single layout write.
            guard !stopped, generation == loadGeneration,
                  topologyGeneration == observedDisplayTopologyGeneration else { throw CancellationError() }
            try beforePresentation?()
            // Keep this guard directly after the host callback.  It is the
            // only point at which a pending candidate can publish after an
            // awaited external transaction has yielded the main actor.
            guard !stopped, generation == loadGeneration,
                  topologyGeneration == observedDisplayTopologyGeneration else { throw CancellationError() }
            if saveLayout { try NativeDisplayStore.save(configuredLayout) }
            if !propertySnapshots.isEmpty {
                defaultProject.propertyRevision = WallpaperPropertyStore.revision(for: defaultProject.projectURL, scope: defaultProject.propertyScope)
                created = created.map { item in
                    var project = item.project
                    project.propertyRevision = WallpaperPropertyStore.revision(for: project.projectURL, scope: project.propertyScope)
                    return Presentation(window: item.window, renderable: item.renderable, project: project)
                }
            }
        }
        catch { dispose(created.filter { !keptWindows.contains(ObjectIdentifier($0.window)) }); throw error }
        clearPresentations(keeping: keptWindows)
        watchers.forEach { $0.stop() }; watchers.removeAll()
        project = defaultProject; activeLayout = layout
        displayWarnings = warnings
        windows = created.map(\.window); renderables = created.map(\.renderable); displayProjects = created.map(\.project)
        appliedPauseStates = previousPauseStates; appliedPauseReasons = previousPauseReasons
        // Newly prepared candidates were explicitly paused. Seed that actual
        // state so the normal policy resumes them when presentation commits.
        for item in created where !keptWindows.contains(ObjectIdentifier(item.window)) {
            appliedPauseStates[ObjectIdentifier(item.renderable)] = true
        }
        audioOwnerIndex = windows.firstIndex { ObjectIdentifier($0) == previousAudioWindow }
        let displays = Dictionary(uniqueKeysWithValues: screens.map { ($0.key, $0) })
        for window in windows {
            if let window = window as? DesktopWindow, let display = displays[window.displayKey] { window.reconcile(with: display) }
        }
        updatePlaybackState(recordTransitions: false)
        for window in windows {
            window.alphaValue = presentationOpacity
            if configuration.mode == .desktop { window.orderFrontRegardless() }
            else { window.makeKeyAndOrderFront(nil) }
        }
        for item in created {
            if !keptWindows.contains(ObjectIdentifier(item.window)) { item.renderable.beginPresentation() }
            item.renderable.refreshPresentation()
        }
        for path in Set(([defaultProject] + displayProjects).map { $0.projectURL.deletingLastPathComponent().path }) {
            let watcher = ProjectFileWatcher(directoryURL: URL(fileURLWithPath: path)) { [weak self] reason in self?.scheduleReload(reason: reason) }
            watcher.start(); watchers.append(watcher)
        }
        projectDidLoad?()
        publishPlaybackStatus()
    }

    private func dispose(_ presentations: [Presentation]) {
        for presentation in presentations {
            presentation.renderable.setAudioOutputEnabled(false); presentation.renderable.pause()
            (presentation.window as? PreviewWindow)?.onClose = nil
            presentation.window.orderOut(nil); presentation.window.close()
            presentation.window.contentView = nil
        }
    }
    private func makePresentations(prepared: PreparedDisplayProjects, screens: [NativeDisplayDescriptor], strictKeys: Set<String>, warnings: inout [String: String], retaining: [String: Presentation] = [:]) async throws -> [Presentation] {
        var result: [Presentation] = []
        func append(_ resource: PreparedWallpaper, window: NSWindow) async throws {
            do {
                let view = try makeRenderable(project: resource.project, webWorkspace: resource.workspace, webState: resource.state, videos: resource.videos, image: resource.image, outputSize: window.convertToBacking(window.contentView?.bounds ?? .zero).size)
                if !audioOutputAllowed { view.setAudioOutputEnabled(false) }
                // Other screens may still be decoding video. Hold every new
                // candidate until the whole presentation is ready to commit.
                view.pause()
                attach(view.view, to: window)
                try await view.prepareForPresentation()
                try Task.checkCancellation()
                guard !ruleSuspended else { throw PresentationError.rulePolicyChanged }
                result.append(Presentation(window: window, renderable: view, project: resource.project))
            } catch { (window as? PreviewWindow)?.onClose = nil; window.close(); throw error }
        }
        do {
            switch configuration.mode {
            case .preview:
                if let resource = prepared.projects[prepared.defaultKey] {
                    let prefix = resource.project.kind == .web ? "网页预览 · " : "静音预览 · "
                    let window = PreviewWindow(title: previewIsIndependent ? prefix + resource.project.title : resource.project.title)
                    if previewIsIndependent { window.onClose = { [weak self] in self?.previewClosed?() } }
                    try await append(resource, window: window)
                }
            case .desktop:
                for screen in screens {
                    if let retained = retaining[screen.key] { result.append(retained); continue }
                    guard let key = prepared.displayProjects[screen.key], let resource = prepared.projects[key] else { continue }
                    do { try await append(resource, window: DesktopWindow(display: screen)) }
                    catch is CancellationError { throw CancellationError() }
                    catch PresentationError.rulePolicyChanged { throw PresentationError.rulePolicyChanged }
                    catch {
                        let fallbackKey = prepared.fallbackProjects[screen.key] ?? prepared.defaultKey
                        guard !strictKeys.contains(screen.key), key != fallbackKey,
                              let fallback = prepared.projects[fallbackKey] else { throw error }
                        warnings[screen.key] = String(error.localizedDescription.prefix(1024))
                        try await append(fallback, window: DesktopWindow(display: screen))
                    }
                }
            }
            return result
        } catch {
            let retainedWindows = Set(retaining.values.map { ObjectIdentifier($0.window) })
            dispose(result.filter { !retainedWindows.contains(ObjectIdentifier($0.window)) })
            throw error
        }
    }

    private func makeRenderable(project: WallpaperProject, webWorkspace: WebMediaWorkspace?, webState: WebMediaState?, videos: SceneVideoLibrary, image: CGImage?, outputSize: CGSize) throws -> WallpaperRenderable {
        switch project.kind {
        case .web:
            if !project.resourceURL.isFileURL {
                let host = NativeRemoteWallpaperView(url: project.resourceURL)
                host.playbackStateDidChange = { [weak self] in self?.publishPlaybackStatus() }
                return host
            }
            guard let webWorkspace, let webState else { throw PropertyError.invalid("网页运行目录尚未就绪。") }
            let host = WebWallpaperView(project: project, workspace: webWorkspace, state: webState)
            if previewIsIndependent { host.reloadAdvice = "请关闭并重新打开动态预览。" }
            host.playbackStateDidChange = { [weak self] in self?.publishPlaybackStatus() }
            return host
        case .video:
            let host = VideoWallpaperView(videoURL: project.resourceURL)
            if previewIsIndependent { host.reloadAdvice = "请关闭并重新打开动态预览。" }
            host.playbackStateDidChange = { [weak self] in self?.publishPlaybackStatus() }
            host.playbackDidEnd = { [weak self, weak host] in
                guard let self, let host, !stopped, configuration.mode == .desktop,
                      let index = renderables.firstIndex(where: { $0 === host }),
                      let window = windows[index] as? DesktopWindow else { return }
                if activeLayout.displays[window.displayKey]?.projectPath == nil {
                    defaultVideoDidEnd?()
                } else {
                    displayVideoDidEnd?(window.displayKey)
                }
            }
            return host
        case .scene:
            return try NativeSceneRenderer.make(project: project, videos: videos, postProcessing: playbackEnvironment.preferences.graphics.postProcessing, antialiasing: playbackEnvironment.preferences.graphics.antialiasing, textureResolution: .init(quality: playbackEnvironment.preferences.graphics.textureResolution, outputSize: outputSize))
        case .image:
            guard let image else { throw PropertyError.invalid("静态图片尚未准备完成。") }
            return NativeImageWallpaperView(image: image)
        }
    }

    private func attach(_ view: NSView, to window: NSWindow) {
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        container.autoresizingMask = [.width, .height]
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
    }

    private func clearPresentations(keeping: Set<ObjectIdentifier> = []) {
        for (index, window) in windows.enumerated() where !keeping.contains(ObjectIdentifier(window)) {
            renderables[index].setAudioOutputEnabled(false); renderables[index].pause()
            (window as? PreviewWindow)?.onClose = nil
            window.orderOut(nil); window.close()
            window.contentView = nil
        }
        windows.removeAll()
        renderables.removeAll(); displayProjects.removeAll()
        appliedPauseStates = [:]; appliedPauseReasons = [:]; audioOwnerIndex = nil
    }

    private func pauseReason(at index: Int) -> String? {
        if isPaused { return "手动暂停" }
        if transientPauseReasons.contains(.systemSleep) { return "系统休眠，已暂停" }
        if transientPauseReasons.contains(.displaySleep) { return "显示器休眠，已暂停" }
        if transientPauseReasons.contains(.inactiveSession) { return "用户会话未激活，已暂停" }
        return playbackDecision(at: index).pauseReason
    }

    private func playbackDecision(at index: Int) -> NativePlaybackDecision {
        NativePlaybackDecision.evaluate(playbackEnvironment,
            display: windows.indices.contains(index) ? (windows[index] as? DesktopWindow)?.displayID : nil,
            desktop: configuration.mode == .desktop)
    }

    private func updateAntialiasing() {
        let quality = playbackEnvironment.preferences.graphics.antialiasing
        let targets = renderables.compactMap { $0 as? NativeSceneRendering }.filter { $0.antialiasingQuality != quality }
        guard !targets.isEmpty else { antialiasingAttempt = nil; antialiasingFailure = nil; return }
        let attempt = quality.rawValue + targets.map { "\(ObjectIdentifier($0)):\($0.propertyUpdateRevision)" }.joined(separator: ",")
        guard attempt != antialiasingAttempt else { return }
        antialiasingAttempt = attempt
        do {
            let commits = try targets.map { try $0.prepareAntialiasing(quality) }
            commits.forEach { $0() }; antialiasingFailure = nil
        } catch { antialiasingFailure = String(error.localizedDescription.prefix(1024)) }
    }

    private func updatePostProcessingQuality() {
        let quality = playbackEnvironment.preferences.graphics.postProcessing
        let targets = renderables.compactMap { $0 as? NativeSceneRendering }.filter { $0.postProcessingQuality != quality }
        guard !targets.isEmpty else { postProcessingAttempt = nil; postProcessingFailure = nil; return }
        let attempt = quality.rawValue + targets.map { "\(ObjectIdentifier($0)):\($0.propertyUpdateRevision)" }.joined(separator: ",")
        guard attempt != postProcessingAttempt else { return }
        postProcessingAttempt = attempt
        do {
            // Main-actor preparation and commit do not yield. All displays keep
            // their old resources if any candidate fails to prepare.
            let commits = try targets.map { try $0.preparePostProcessingQuality(quality) }
            commits.forEach { $0() }; postProcessingFailure = nil
        } catch { postProcessingFailure = String(error.localizedDescription.prefix(1024)) }
    }

    private func updateTextureResolution() {
        let quality = playbackEnvironment.preferences.graphics.textureResolution
        let targets: [(NativeSceneRendering, CGSize)] = renderables.enumerated().compactMap { index, view in
            guard let view = view as? NativeSceneRendering, view.textureResolutionQuality != quality else { return nil }
            let size = windows.indices.contains(index) ? windows[index].convertToBacking(windows[index].contentView?.bounds ?? .zero).size : view.view.convertToBacking(view.view.bounds).size
            return (view, size)
        }
        guard !targets.isEmpty else { textureResolutionAttempt = nil; textureResolutionFailure = nil; return }
        let attempt = quality.rawValue + targets.map { "\(ObjectIdentifier($0.0)):\($0.0.propertyUpdateRevision):\($0.1.width)x\($0.1.height)" }.joined(separator: ",")
        guard attempt != textureResolutionAttempt else { return }
        textureResolutionAttempt = attempt
        do {
            let commits = try targets.map { try $0.0.prepareTextureResolution(quality, outputSize: $0.1) }
            commits.forEach { $0() }; textureResolutionFailure = nil
        } catch { textureResolutionFailure = String(error.localizedDescription.prefix(1024)) }
    }

    private func updatePlaybackState(recordTransitions: Bool = true) {
        guard !stopped, !renderables.isEmpty else { return }
        updatePostProcessingQuality()
        updateAntialiasing()
        updateTextureResolution()
        let reasons = renderables.indices.map { pauseReason(at: $0) }
        let states = reasons.map { $0 != nil }
        let audible = states.indices.map { !states[$0] && !playbackDecision(at: $0).muted }
        // A single active presentation owns Scene/Video audio. Disable an old
        // owner before enabling another; paused displays cannot keep playing it.
        let preferred = states.indices.first { index in
            audible[index] && (windows[index] as? DesktopWindow)?.displayKey == activeLayout.preferredAudioDisplay
        }
        let owner = audioOutputAllowed ? (preferred ?? audible.firstIndex(of: true)) : nil
        if owner != audioOwnerIndex {
            for (index, target) in renderables.enumerated() where index != owner { target.setAudioOutputEnabled(false) }
            if let owner { renderables[owner].setAudioOutputEnabled(true) }
            audioOwnerIndex = owner
        }
        for (index, target) in renderables.enumerated() {
            target.setFrameRateLimit(playbackEnvironment.preferences.general.framesPerSecond)
            target.setReflectionsEnabled(playbackEnvironment.preferences.graphics.reflections)
            target.setShadowQuality(playbackEnvironment.preferences.graphics.shadows)
            target.setVolumetricQuality(playbackEnvironment.preferences.graphics.volumetrics)
            let identity = ObjectIdentifier(target)
            if appliedPauseStates[identity] != states[index] {
                if states[index] { target.pause() }
                else if appliedPauseStates[identity] != nil { target.resume() }
            }
            let text = reasons[index] ?? (playbackDecision(at: index).muted ? "播放中，已按策略静音" : "播放中")
            if recordTransitions, let previous = appliedPauseReasons[identity], previous != text {
                let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                let name = (windows[index] as? DesktopWindow)?.displayName ?? "窗口预览"
                playbackTransitions.append("\(time) · \(name)：\(text) · \(target.playbackDescription)")
                if playbackTransitions.count > 8 { playbackTransitions.removeFirst(playbackTransitions.count - 8) }
                fputs("Native playback transition: displayIndex=\(index), paused=\(states[index]), reason=\(text)\n", stderr)
            }
            appliedPauseStates[identity] = states[index]; appliedPauseReasons[identity] = text
        }
        publishPlaybackStatus()
    }

    private func publishPlaybackStatus() {
        if ruleSuspended { statusChanged?(playbackSummary); return }
        guard !renderables.isEmpty else {
            statusChanged?(project == nil ? "尚未打开壁纸" : "动态壁纸已关闭，或没有可用显示器")
            return
        }
        if antialiasingFailure != nil { statusChanged?("抗锯齿设置未应用，保留原画面；请查看播放状态。"); return }
        if postProcessingFailure != nil { statusChanged?("后处理设置未应用，保留原画面；请查看播放状态。"); return }
        if textureResolutionFailure != nil { statusChanged?("纹理分辨率未应用，保留原画面；请查看播放状态。"); return }
        if renderables.contains(where: { $0.playbackNotice != nil }) {
            statusChanged?(playbackSummary); return
        }
        let paused = renderables.indices.compactMap { pauseReason(at: $0) }
        if paused.count == renderables.count { statusChanged?(Array(Set(paused)).sorted().joined(separator: "；")) }
        else if !paused.isEmpty { statusChanged?("\(renderables.count - paused.count)/\(renderables.count) 块屏幕播放中") }
        else {
            let titles = Array(Set(displayProjects.map(\.title))).sorted()
            let title = titles.count == 1 ? titles[0] : "\(renderables.count) 块屏幕播放中"
            statusChanged?(title + (!displayWarnings.isEmpty ? " · 有屏幕使用默认壁纸" : renderables.contains(where: { !$0.diagnostics.isEmpty }) ? " · 部分兼容" : ""))
        }
    }

    private func suspend(for reason: TransientPauseReason) {
        guard transientPauseReasons.insert(reason).inserted else { return }
        updatePlaybackState()
    }

    private func resume(after reason: TransientPauseReason) {
        guard transientPauseReasons.remove(reason) != nil else { return }
        updatePlaybackState()
        // A desktop stop may already have cleared while sleep/session pauses
        // remain. Its renderer lifetime must wait for the final transient
        // reason as well, rather than allocating an invisible paused desktop.
        resumeDesktopStopIfReady()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var configuration: LaunchConfiguration?
    private var controller: WallpaperController?
    private var pendingController: WallpaperController?
    private var openTask: Task<Void, Never>?
    private var openRequestID: UUID?
    private var requestedConfiguration: LaunchConfiguration?
    private var requestedImport: NativeWallpaperImportRequest?
    private struct FailedProjectLoad {
        let request: LaunchConfiguration?
        var importRequest: NativeWallpaperImportRequest? = nil
        var applicationRule = false
        let message: String
    }
    private var failedProjectLoad: FailedProjectLoad?
    private var pendingOpenTasks: [UUID: Task<Void, Never>] = [:]
    private var playlistPlayback: NativePlaylistPlayback?
    // Rule lists are runtime overrides. Their position must never replace the
    // user's default playlist, its persisted progress, or lastProject.
    private var applicationPlaylistPlayback: NativePlaylistPlayback?
    private var openingApplicationPlaylistRequest: UUID?
    private var applicationPlaylistCatalog: Data?
    /// The prepared active profile is presentation-only. It is never written
    /// through NativeProfileStore.applySelection, which remains the manual UI
    /// action that persists display and playlist settings.
    private var applicationProfile: NativeWallpaperProfile?
    /// The unprepared saved catalog value gives temporary playlist transitions
    /// a synchronous exact-name generation check at their commit boundary.
    private var applicationProfileTarget: NativeWallpaperProfile?
    private var applicationProfileCatalogGeneration: Data?
    /// Non-default displays never borrow the default scheduler.  A session
    /// display is deliberately retained here only (never in preferences),
    /// while a UUID display can restore its list and position independently.
    private enum DisplayContentOwner: Equatable {
        case manual
        case profileTemporary
        case applicationTemporary

        var writesPreferences: Bool { self == .manual }
    }
    private struct DisplayContentContext: Equatable {
        var target: NativeDisplayTarget
        var playback: NativePlaylistPlayback? = nil
        var epoch = UUID()
        /// The pending request lives in the candidate copy until publication;
        /// recording only its identity here prevents a second timer/video-end
        /// request without exposing uncommitted position or elapsed time.
        var pendingID: UUID? = nil
        var owner: DisplayContentOwner = .manual

        var currentURL: URL? {
            playback?.currentEntry.flatMap { try? NativePlaylistLibrary.resolve($0.wallpaper) }
        }
    }
    private struct DisplayContentJob {
        let id: UUID
        let key: String
        let epoch: UUID
        let operation: @MainActor () async -> Void
    }
    private var displayContentContexts: [String: DisplayContentContext] = [:]
    private var displayContentQueue: [DisplayContentJob] = []
    private var displayContentActiveJob: DisplayContentJob?
    private var displayContentActiveTask: Task<Void, Never>?
    /// A layout removal is itself a controller transaction.  Hold the same
    /// lane while it awaits preparation so a queued per-display candidate
    /// cannot start in the gap and invalidate WallpaperController globally.
    private var displayContentMaintenanceInFlight = false
    /// Monitor-overlay removal begins in a UI-owned Task. Mirror its actual
    /// transaction here so Browser Cancel and termination can cancel and join
    /// it before restoring/releasing the shared WallpaperController.
    private var displayContentMaintenanceTask: Task<Void, Error>?
    private var playlistTimer: Timer?
    private var openingPlaylistRequest: UUID?
    private var retiringPlaylists: [UUID: WallpaperController] = [:]
    private struct ApplicationSelectionSnapshot {
        var configuration: LaunchConfiguration
        var target: String?
        var layout: NativeDisplayLayout
        var paused: Bool
        var displayContents: [String: DisplayContentContext]
    }
    private typealias ApplicationSelection = NativeApplicationSelection<ApplicationSelectionSnapshot>
    private var applicationSelection = ApplicationSelection()
    private var openingApplicationRequest: ApplicationSelection.Request?
    private var applicationSelectionNeedsRefresh = false
    private var applicationSelectionRefreshTask: Task<Void, Never>?
    private var applyingDisplayLayout = false
    private var profileHotkeyTask: Task<Void, Never>?
    private var hotkeyPlatformTask: Task<Void, Never>?
    private struct HotkeyContentRequest {
        let target: NativeHotkeyTarget
        let hotkey: NativeHotkey
        let playlist: NativePlaylist?
    }
    private var profileHotkeyRequestID: UUID?
    private final class ProfileLoadRequest {
        let profile: NativeWallpaperProfile
        let validateBeforeCommit: (() throws -> Void)?
        let hotkeyRequestID: UUID?
        var result: Result<Void, Error>?
        init(_ profile: NativeWallpaperProfile, validateBeforeCommit: (() throws -> Void)? = nil, hotkeyRequestID: UUID? = nil) {
            self.profile = profile; self.validateBeforeCommit = validateBeforeCommit; self.hotkeyRequestID = hotkeyRequestID
        }
    }
    private let projectLoadLog = Logger(subsystem: "io.wallpaper-engine-native.host", category: "ProjectLoading")
    private var builtinImportTask: Task<Void, Never>?
    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var resumeItem: NSMenuItem?
    private var loginItems: [NSMenuItem] = []
    private var loginSettingsItems: [NSMenuItem] = []
    private let workshop = WorkshopCoordinator()
    private var library: LibraryController?
    private struct BrowserSession {
        let configuration: LaunchConfiguration?
        let paused: Bool
        let snapshot: NativeBrowserSession
        let playlist: NativePlaylistPlayback?
        let applicationPlaylist: NativePlaylistPlayback?
        let displayContents: [String: DisplayContentContext]
        let applicationProfile: NativeWallpaperProfile?
        let applicationProfileTarget: NativeWallpaperProfile?
        let applicationSelection: ApplicationSelection
    }
    private var browserSession: BrowserSession?
    private var isFinishingBrowser = false
    private var acceptingBrowser = false
    private var propertyEditor: WallpaperPropertiesController?
    private var audioController: NativeAudioController?
    private var mediaController: NativeMediaController?
    // Factory construction is inert: no Process Tap/aggregate/IOProc exists
    // until the Settings confirmation reaches the monitor's explicit-start
    // API.  This service is intentionally separate from wallpaper spectrum.
    private let processAudioMeter = NativeProcessAudioMeterFactory.makeService()
    private lazy var playbackPolicy = NativePlaybackPolicyMonitor(audioMeter: processAudioMeter)
    private var playbackSettings: NativePlaybackSettingsController?
    private var displaySettings: NativeDisplaySettingsController?
    private var displayPicker: LibraryController?
    private var monitorSelection: NativeMonitorSelectionController?
    /// Library selection is presentation state only.  Content starts changing
    /// only after an explicit target-aware wallpaper/playlist callback.
    private var libraryDisplayTarget: NativeDisplayTarget = .defaultWallpaper
    private var transferController: NativeTransferController?
    private var applicationInfo: NativeApplicationInfoController?
    private let welcomePresentation = NativeWelcomePresentationStore()
    /// Browser-owned seasonal information is deliberately outside the Settings
    /// transaction. The sheet is eligible only over a real, visible wallpaper
    /// Library window, never while Settings is editing its own snapshot.
    private lazy var seasonalThemePromptCoordinator: NativeSeasonalThemePromptCoordinator = {
        NativeSeasonalThemePromptCoordinator(
            eligible: { [weak self] in self?.seasonalThemePromptPresentationAllowed ?? false },
            present: { [weak self] prompt, completion in
                guard let self, self.seasonalThemePromptPresentationAllowed,
                      let window = self.library?.window else { return false }
                return NativeSeasonalThemePromptSheet.present(prompt, on: window, completion: completion)
            },
            browseCollection: { [weak self] in self?.library?.showDiscover() },
            disableTheming: {
                NativeInterfaceThemeStore.saveSeasonalEnabled(false)
                NativeInterfaceThemeRuntime.applyStoredTheme()
            }
        )
    }()
    private var editor: NativeEditorController?
    private var openURLController: NativeOpenURLController?
    private var selectionPreview: WallpaperController?
    private var selectionPreviewTask: Task<Void, Never>?
    private var pendingPreviewTasks: [UUID: Task<Void, Never>] = [:]
    private var guiSession: Bool
    private var workspaceObservers: [NSObjectProtocol] = []
    private var systemIsSleeping = false
    private var displaysAreSleeping = false
    private var sessionIsInactive = false
    private var isTerminating = false
    /// The notification is the authoritative observation boundary for volatile
    /// CoreGraphics session IDs.  Keep the previous set so a rapid A -> none
    /// -> A topology sequence is still recognised as a loss even though the
    /// delayed recovery later sees A connected again.
    private var lastObservedSessionKeys: Set<String>?

    init(configuration: LaunchConfiguration?, guiSession: Bool = false) {
        self.configuration = configuration; self.guiSession = guiSession
        // Register the baseline before the screen-parameter observer is
        // installed.  Otherwise the first notification could already be the
        // missing-A topology and there would be no prior generation to
        // invalidate for default-following/property-only session displays.
        self.lastObservedSessionKeys = Set(NativeDisplayDescriptor.connected().map(\.key).filter { $0.hasPrefix("session:") })
    }

    private func connectPlaybackPolicy() {
        playbackPolicy.onChange = { [weak self] environment in
            self?.controller?.updatePlaybackPolicy(environment)
            self?.pendingController?.updatePlaybackPolicy(environment)
            self?.retiringPlaylists.values.forEach { $0.updatePlaybackPolicy(environment) }
            self?.selectionPreview?.updatePlaybackPolicy(environment)
            self?.updateLibraryPlayback()
            self?.playbackSettings?.refresh()
            self?.reconcileApplicationSelection()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture this before any launch/restore path can materialise a native
        // preference or Application Support folder.  A real existing install
        // is deliberately treated as legacy and keeps its established library
        // flow; only an empty production domain is eligible for first-run UI.
        let automaticWelcome = configuration == nil && NativeWelcomeState.decisionForProductionLaunch() == .show
        // The stable reference restores its chosen skin before constructing
        // settings or browser routes.  Do this before any native window is
        // created so every controller inherits the same initial appearance.
        NativeInterfaceThemeRuntime.applyStoredTheme()
        NSApp.setActivationPolicy(guiSession || configuration?.mode == .preview ? .regular : .accessory)
        buildStatusItem()
        buildMainMenu()
        observeWorkspaceSleepNotifications()
        connectPlaybackPolicy()
        playbackPolicy.start()
        connectProfileHotkeys()
        NativeMediaService.shared.restore()
        restorePlaylistPlayback()
        restoreDisplayPlaylistContexts()
        workshop.onProjectReady = { [weak self] url in self?.openProject(url, mode: .desktop) }
        workshop.onProjectUpdated = { [weak self] url in self?.workshopProjectUpdated(url) }
        workshop.onStatus = { [weak self] status in self?.updateStatus(status) }
        workshop.onLibraryChanged = { [weak self] in self?.applicationLibraryChanged() }
        workshop.onConnectionChanged = { [weak self] text in self?.library?.updateSteamConnection(text) }
        workshop.onSubscriptionsChanged = { [weak self] items in self?.library?.updateSubscriptions(items) }
        workshop.onFavoritesChanged = { [weak self] ids in self?.library?.updateFavorites(ids) }
        // Personal votes are selection-scoped, but the displayed vote must be
        // cleared immediately when its underlying Steam account envelope is
        // invalidated.  This does not fire merely because a user clicked a
        // vote button; the eventual exact read-after-write receipt remains
        // eligible for the same selection.
        workshop.onUserVotesInvalidated = { [weak self] in self?.library?.updateUserVotesInvalidated() }
        workshop.onTransfersChanged = { [weak self] snapshot in self?.transferController?.update(snapshot) }
        workshop.onTransferRequested = { [weak self] token in
            self?.showTransfers(nil); self?.transferController?.selectTransfer(token)
        }
        if let configuration { openProject(configuration.projectURL, mode: configuration.mode, startingPlaylist: true) }
        if automaticWelcome { presentWelcome(automatic: true) }
        else if guiSession || configuration == nil { presentLibrary(nil) }
        if configuration == nil, let issue = LaunchConfiguration.restorationIssue {
            failedProjectLoad = FailedProjectLoad(request: nil, message: issue)
            updateLibraryLoadFailure()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard !isTerminating else { return }
        guard urls.count == 1, let url = urls.first, url.isFileURL,
              url.pathExtension.lowercased() == NativeCreationArchive.fileExtension else {
            let alert = NSAlert(); alert.messageText = "请选择一个原生作品文件"
            alert.informativeText = "通过 .wenative 文件导入可编辑作品；普通壁纸项目请从“打开本地项目”选择。"
            alert.runModal(); return
        }
        presentEditor(project: nil, archive: url)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard editor?.canLeave() != false else { return .terminateCancel }
        isTerminating = true
        NativeProfileHotkeyService.shared.stop()
        hotkeyPlatformTask?.cancel(); hotkeyPlatformTask = nil
        let persistentDisplayProgress = displayContentContexts.values.compactMap { context -> (String, NativePlaylistPlayback?)? in
            guard context.owner == .manual, context.target.persistent else { return nil }
            return (context.target.key, context.playback)
        }
        // The monitor overlay owns its caller Task, but the host owns the
        // renderer transaction. Cancel both layers and join the latter before
        // tearing down controller/state below.
        monitorSelection?.close()
        let pendingDisplayMaintenance = displayContentMaintenanceTask
        pendingDisplayMaintenance?.cancel()
        cancelDisplayContentTransactions(removeContexts: true)
        let pendingDisplayContent = displayContentActiveTask
        NativeDesktopIconVisibility.shared.reset()
        profileHotkeyRequestID = nil
        let pendingProfileHotkey = profileHotkeyTask
        pendingProfileHotkey?.cancel(); profileHotkeyTask = nil
        applicationSelectionRefreshTask?.cancel()
        let pendingRuleRefresh = applicationSelectionRefreshTask
        applicationSelectionRefreshTask = nil
        playlistTimer?.invalidate(); playlistTimer = nil
        if playlistPlayback != nil { NativePlaylistProgressStore.save(playlistPlayback) }
        for (target, playback) in persistentDisplayProgress {
            NativePlaylistProgressStore.save(playback, target: target)
        }
        let retiredTransitions = finishPlaylistTransitions()
        let pendingBrowser = library?.cancelFinishing()
        updateLibraryLoadFailure()
        editor?.shutdown()
        playbackPolicy.stop()
        playbackSettings?.close()
        transferController?.close()
        let pendingDisplays = displaySettings?.cancelPendingApply()
        displaySettings?.close(); displayPicker?.close()
        let pendingOpens = Array(pendingOpenTasks.values)
        pendingOpens.forEach { $0.cancel() }; openTask = nil; openRequestID = nil
        let pendingImport = builtinImportTask
        pendingImport?.cancel(); builtinImportTask = nil
        let pendingPreviews = Array(pendingPreviewTasks.values)
        pendingPreviews.forEach { $0.cancel() }; selectionPreviewTask = nil
        let previewReload = selectionPreview?.stop(); selectionPreview = nil
        let pendingReload = pendingController?.stop()
        pendingController = nil
        let pendingPropertyEditor = propertyEditor?.cancelPendingApply()
        propertyEditor = nil
        NativeAudioService.shared.shutdown()
        NativeMediaService.shared.shutdown()
        removeWorkspaceSleepNotifications()
        workshop.stop()
        Task {
            await pendingBrowser?.value
            await pendingProfileHotkey?.value
            await pendingRuleRefresh?.value
            await pendingPropertyEditor?.value
            await pendingDisplayContent?.value
            _ = try? await pendingDisplayMaintenance?.value
            // An inspector edit is an immediate save request. Finish its last
            // valid value before stopping the renderer it is bound to.
            await library?.finishInlinePropertyEditing()?.value
            library?.cancelInlinePropertyEditing()
            browserSession = nil
            let currentReload = controller?.stop(); controller = nil
            let pendingApplies = WallpaperPropertiesController.cancelAllPendingApplications()
            for task in pendingOpens { await task.value }
            for task in retiredTransitions { await task.value }
            await pendingImport?.value
            for task in pendingPreviews { await task.value }
            await previewReload?.value
            await pendingReload?.value
            await currentReload?.value
            for task in pendingApplies { await task.value }
            await pendingDisplays?.value
            // A completed I/O job may have queued its final result on the main
            // queue. Let it release its owners before draining queued cleanup.
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                WebMediaIO.queue.async {
                    DispatchQueue.main.async { done.resume() }
                }
            }
            _ = try? await WebMediaIO.perform { () }
            _ = try? await SavedWorkshopStore.perform { () }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentLibrary(nil); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        NativeProfileHotkeyService.shared.stop()
        hotkeyPlatformTask?.cancel(); hotkeyPlatformTask = nil
        NativeDesktopIconVisibility.shared.reset()
        profileHotkeyRequestID = nil; profileHotkeyTask?.cancel(); profileHotkeyTask = nil
        playlistTimer?.invalidate(); playlistTimer = nil
        finishPlaylistTransitions()
        playbackPolicy.stop()
        applicationSelectionRefreshTask?.cancel(); applicationSelectionRefreshTask = nil
        pendingOpenTasks.values.forEach { $0.cancel() }; pendingController?.stop()
        builtinImportTask?.cancel()
        pendingPreviewTasks.values.forEach { $0.cancel() }; selectionPreview?.stop()
        displaySettings?.cancelPendingApply(); displayPicker?.close(); monitorSelection?.close()
        _ = WallpaperPropertiesController.cancelAllPendingApplications()
        NativeAudioService.shared.shutdown()
        NativeMediaService.shared.shutdown()
        removeWorkspaceSleepNotifications()
        workshop.stop()
        controller?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    private var playlistPresentationIsSuspended: Bool {
        isTerminating || isFinishingBrowser || controller?.currentProject == nil || configuration?.mode != .desktop ||
            openRequestID != nil || failedProjectLoad != nil || NSApp.modalWindow != nil ||
            library?.window?.attachedSheet != nil || displaySettings?.window?.isVisible == true
    }
    private var playlistIsSuspended: Bool { playlistPresentationIsSuspended || applicationSelection.ownsTemporarySelection }
    private var applicationPlaylistIsSuspended: Bool {
        playlistPresentationIsSuspended || (applicationSelection.current?.action != .loadplaylist &&
            applicationSelection.current?.action != .loadprofile) ||
            applicationSelection.current != applicationSelection.observed || applicationSelection.pending != nil ||
            playbackPolicy.environment.stopsDesktop
    }
    private func restorePlaylistPlayback() {
        do {
            if let list = try NativePlaylistStore.active().lists["default"] {
                playlistPlayback = NativePlaylistPlayback(list: list, now: ProcessInfo.processInfo.systemUptime, position: NativePlaylistProgressStore.load(for: list))
            }
        } catch { updateStatus(error.localizedDescription) }
        playlistTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advancePlaylist() }
        }
        if let playlistTimer { RunLoop.main.add(playlistTimer, forMode: .common) }
    }

    private func restoreDisplayPlaylistContexts() {
        do {
            let active = try NativePlaylistStore.active()
            let now = ProcessInfo.processInfo.systemUptime
            for (key, list) in active.lists where key != "default" {
                guard let target = try? NativeDisplayTarget(location: key) else { continue }
                let playback = NativePlaylistPlayback(list: list, now: now,
                    position: NativePlaylistProgressStore.load(for: list, target: key))
                displayContentContexts[key] = DisplayContentContext(target: target, playback: playback)
            }
        } catch { updateStatus(error.localizedDescription) }
    }
    private func changePlaylist(_ value: NativePlaylist) throws {
        guard !isTerminating, !isFinishingBrowser else { throw CancellationError() }
        _ = try value.validated()
        if openingPlaylistRequest != nil { cancelProjectLoad(report: false) }
        let now = ProcessInfo.processInfo.systemUptime
        var replacement = applicationSelection.ownsTemporarySelection ? applicationPlaylistPlayback : playlistPlayback
        if value.entries.isEmpty { replacement = nil }
        else if replacement != nil { replacement?.replace(value, now: now) }
        else {
            replacement = NativePlaylistPlayback(list: value, now: now)
            replacement?.manualSelection(key: controller?.currentProject.map { NativePlaylistLibrary.key(for: $0.projectURL) }, now: now)
        }
        if applicationSelection.ownsTemporarySelection {
            // A default-list edit is an explicit manual selection just like a
            // per-display list edit.  Persist the whole currently visible
            // composition and suppress the rule before it can restore its
            // original snapshot over the user's list.
            try promoteTemporaryDesktopToManual(defaultPlayback: replacement)
            return
        }
        try NativePlaylistStore.setActive(value, target: "default")
        playlistPlayback = replacement
        NativePlaylistProgressStore.save(playlistPlayback)
    }

    // MARK: Per-display content contexts

    /// The old default playlist path remains intentionally separate.  A
    /// target context is created only for an explicit display key, which is
    /// what prevents a missing UUID/session display from silently becoming the
    /// default desktop's scheduler.
    private func displayContentContext(for target: NativeDisplayTarget) throws -> DisplayContentContext {
        guard case .display(let key) = target else {
            throw NativePlaylistError.invalid("默认壁纸不使用独立显示器上下文。")
        }
        if let value = displayContentContexts[key] { return value }
        var playback: NativePlaylistPlayback?
        if let list = try NativePlaylistStore.active().lists[key] {
            playback = NativePlaylistPlayback(list: list, now: ProcessInfo.processInfo.systemUptime,
                                               position: NativePlaylistProgressStore.load(for: list, target: key))
            playback?.manualSelection(key: controller?.projectForDisplay(key).map { NativePlaylistLibrary.key(for: $0.projectURL) },
                                      now: ProcessInfo.processInfo.systemUptime)
        }
        let result = DisplayContentContext(target: target, playback: playback)
        displayContentContexts[key] = result
        return result
    }

    private func displayTargetIsConnected(_ target: NativeDisplayTarget) -> Bool {
        guard case .display(let key) = target else { return true }
        return NativeDisplayDescriptor.connected().contains { $0.key == key }
    }

    private func displayContentIsCurrent(key: String, epoch: UUID) -> Bool {
        // Selecting a display wallpaper is immediate, like the legacy
        // default selection.  The browser may therefore enter its accepted
        // finish path while this display candidate is still preparing. Keep
        // that explicit accepted choice eligible to publish; a Cancel keeps
        // `acceptingBrowser` false and still invalidates the candidate.
        !isTerminating && (!isFinishingBrowser || acceptingBrowser) &&
            displayContentContexts[key]?.epoch == epoch
    }

    /// Controller loading has one generation counter.  Rather than allow two
    /// display candidates to cancel each other unpredictably, feed targeted
    /// changes through one serial lane.  An epoch remains per target, so an
    /// obsolete queued request is discarded without cancelling unrelated
    /// target state.
    private func enqueueDisplayContent(target: NativeDisplayTarget, epoch: UUID,
                                       operation: @escaping @MainActor () async -> Void) {
        let job = DisplayContentJob(id: UUID(), key: target.key, epoch: epoch, operation: operation)
        displayContentQueue.append(job)
        startNextDisplayContentJob()
    }

    private func startNextDisplayContentJob() {
        guard !displayContentMaintenanceInFlight, displayContentActiveJob == nil, !displayContentQueue.isEmpty else { return }
        let job = displayContentQueue.removeFirst()
        guard displayContentIsCurrent(key: job.key, epoch: job.epoch) else {
            startNextDisplayContentJob(); return
        }
        displayContentActiveJob = job
        displayContentActiveTask = Task { @MainActor [weak self] in
            await job.operation()
            guard let self, self.displayContentActiveJob?.id == job.id else { return }
            self.displayContentActiveJob = nil; self.displayContentActiveTask = nil
            self.startNextDisplayContentJob()
        }
    }

    /// Invalidating an epoch is enough for an already-prepared candidate to
    /// fail its final commit check.  Cancel the actively awaited task as an
    /// optimisation; other queued targets retain their independent contexts.
    private func cancelDisplayContentTransactions(keys: Set<String>? = nil, removeContexts: Bool = false) {
        let affected = keys ?? Set(displayContentContexts.keys)
        let now = ProcessInfo.processInfo.systemUptime
        for key in affected {
            guard var context = displayContentContexts[key] else { continue }
            context.epoch = UUID(); context.pendingID = nil; context.playback?.cancelPending(now: now)
            if removeContexts { displayContentContexts.removeValue(forKey: key) }
            else { displayContentContexts[key] = context }
        }
        displayContentQueue.removeAll { affected.contains($0.key) }
        if let active = displayContentActiveJob, affected.contains(active.key) { displayContentActiveTask?.cancel() }
    }

    /// Persist the content part of one display at the same non-suspending
    /// commit boundary as its prepared renderer.  UUID bytes and progress are
    /// rolled back together with the layout on every failure.  `session:`
    /// contexts deliberately stay in the runtime dictionary/temporary layout
    /// overlay and never reach a UserDefaults payload.
    private func commitDisplayContent(layout: NativeDisplayLayout, target: NativeDisplayTarget,
                                      playback: NativePlaylistPlayback?, owner: DisplayContentOwner,
                                      epoch: UUID) throws {
        guard displayContentIsCurrent(key: target.key, epoch: epoch) else { throw CancellationError() }
        guard owner.writesPreferences else { return }
        if applicationSelection.ownsTemporarySelection {
            try promoteTemporaryDesktopToManual(layout: layout, replacing: target, playback: playback, epoch: epoch)
            return
        }
        let displays = NativeDisplayStore.snapshot()
        let playlists = NativePlaylistStore.snapshot()
        let progress = NativePlaylistProgressStore.snapshot()
        do {
            try NativeDisplayStore.save(layout)
            if target.persistent {
                var persistent = try NativePlaylistStore.active()
                persistent.lists = persistent.lists.filter { NativePlaylistStore.persistentTarget($0.key) }
                if let playback { persistent.lists[target.key] = playback.list }
                else { persistent.lists.removeValue(forKey: target.key) }
                try NativePlaylistStore.replacePersistent(persistent)
                NativePlaylistProgressStore.save(playback, target: target.key)
            } else {
                try NativePlaylistStore.setActive(playback?.list ?? .init(), target: target.key)
                NativePlaylistProgressStore.save(playback, target: target.key)
            }
        } catch {
            NativeDisplayStore.restore(displays)
            NativePlaylistStore.restore(playlists)
            NativePlaylistProgressStore.restore(progress)
            throw error
        }
    }

    /// A direct per-screen selection while an application rule/profile owns
    /// the desktop is a user takeover of the *whole* temporary composition.
    /// Persist the exact visible default/list contexts atomically, then
    /// suppress the unchanged rule.  Persisting just one target would let the
    /// next rule reconciliation silently rebuild the old temporary layout.
    private func promoteTemporaryDesktopToManual(layout: NativeDisplayLayout, replacing target: NativeDisplayTarget,
                                                  playback: NativePlaylistPlayback?, epoch: UUID,
                                                  removingTarget: Bool = false) throws {
        guard displayContentIsCurrent(key: target.key, epoch: epoch) else { throw CancellationError() }
        // This transaction owns the current serial job (if any).  Retire only
        // other target intents before taking the manual snapshot, so no queued
        // application-profile candidate can publish afterwards with its old
        // temporary owner.
        let otherTargets = Set(displayContentContexts.keys).subtracting([target.key])
        cancelDisplayContentTransactions(keys: otherTargets)
        let displays = NativeDisplayStore.snapshot()
        let playlists = NativePlaylistStore.snapshot()
        let progress = NativePlaylistProgressStore.snapshot()
        var nextContexts = displayContentContexts
        guard var selected = nextContexts[target.key], selected.epoch == epoch else { throw CancellationError() }
        if removingTarget {
            // Removing a screen is also a manual whole-desktop takeover.  Do
            // not retain the temporary profile's scheduler for a target the
            // user has explicitly cleared; otherwise a later rule exit could
            // restore its list/progress over this removal.
            nextContexts.removeValue(forKey: target.key)
        } else {
            selected.playback = playback; selected.pendingID = nil; selected.owner = .manual
            nextContexts[target.key] = selected
        }
        let defaultPlayback = applicationPlaylistPlayback ?? playlistPlayback
        do {
            try NativeDisplayStore.save(layout)
            var persistent = NativePlaylistStore.Active()
            if let defaultPlayback { persistent.lists["default"] = defaultPlayback.list }
            for context in nextContexts.values where context.target.persistent {
                if let list = context.playback?.list { persistent.lists[context.target.key] = list }
            }
            try NativePlaylistStore.replacePersistent(persistent)
            NativePlaylistProgressStore.save(defaultPlayback)
            for context in nextContexts.values where context.target.persistent {
                NativePlaylistProgressStore.save(context.playback, target: context.target.key)
            }
            for context in nextContexts.values where !context.target.persistent {
                try NativePlaylistStore.setActive(context.playback?.list ?? .init(), target: context.target.key)
                NativePlaylistProgressStore.save(context.playback, target: context.target.key)
            }
            // The selected context was removed before the loops above.  Clear
            // its progress explicitly; for a session target also remove the
            // in-memory overlay that `replacePersistent` intentionally keeps.
            // Otherwise a removed display can revive its old scheduler when a
            // later layout/profile reconciliation recreates that key.
            if removingTarget {
                if target.persistent {
                    NativePlaylistProgressStore.save(nil, target: target.key)
                } else {
                    try NativePlaylistStore.setActive(.init(), target: target.key)
                    NativePlaylistProgressStore.save(nil, target: target.key)
                }
            }
        } catch {
            NativeDisplayStore.restore(displays)
            NativePlaylistStore.restore(playlists)
            NativePlaylistProgressStore.restore(progress)
            throw error
        }
        displayContentContexts = nextContexts.mapValues { value in
            var value = value; value.owner = .manual; return value
        }
        playlistPlayback = defaultPlayback
        applicationPlaylistPlayback = nil; applicationProfile = nil; applicationProfileTarget = nil
        _ = applicationSelection.interruptedByUser()
        controller?.relinquishApplicationRuleOverride()
        if let current = controller?.currentProject?.projectURL {
            UserDefaults.standard.set(current.path, forKey: "lastProject")
            NativeManualPlaybackStore.save(project: current, paused: controller?.isPaused ?? false)
        }
    }

    /// The default playlist has no DisplayContentContext, but editing it while
    /// an application rule/profile is temporary is still a manual ownership
    /// transition.  Keep it symmetrical with the per-screen helper above:
    /// write the visible layout, default list, every persistent target list,
    /// and their progress as one rollback-able preference commit.
    private func promoteTemporaryDesktopToManual(defaultPlayback: NativePlaylistPlayback?) throws {
        guard applicationSelection.ownsTemporarySelection else { return }
        // Unlike a per-display transaction, this synchronous default-list
        // edit is not itself in the serial lane. Invalidate any in-flight or
        // queued target candidate before capturing its visible composition.
        cancelDisplayContentTransactions()
        let displays = NativeDisplayStore.snapshot()
        let playlists = NativePlaylistStore.snapshot()
        let progress = NativePlaylistProgressStore.snapshot()
        let layout = controller?.committedDisplayLayout ?? NativeDisplayStore.load()
        do {
            try NativeDisplayStore.save(layout)
            var persistent = NativePlaylistStore.Active()
            if let defaultPlayback { persistent.lists["default"] = defaultPlayback.list }
            for context in displayContentContexts.values where context.target.persistent {
                if let list = context.playback?.list { persistent.lists[context.target.key] = list }
            }
            try NativePlaylistStore.replacePersistent(persistent)
            NativePlaylistProgressStore.save(defaultPlayback)
            for context in displayContentContexts.values where context.target.persistent {
                NativePlaylistProgressStore.save(context.playback, target: context.target.key)
            }
            for context in displayContentContexts.values where !context.target.persistent {
                try NativePlaylistStore.setActive(context.playback?.list ?? .init(), target: context.target.key)
                NativePlaylistProgressStore.save(context.playback, target: context.target.key)
            }
        } catch {
            NativeDisplayStore.restore(displays)
            NativePlaylistStore.restore(playlists)
            NativePlaylistProgressStore.restore(progress)
            throw error
        }
        displayContentContexts = displayContentContexts.mapValues { value in
            var value = value; value.owner = .manual; return value
        }
        playlistPlayback = defaultPlayback
        applicationPlaylistPlayback = nil; applicationProfile = nil; applicationProfileTarget = nil
        _ = applicationSelection.interruptedByUser()
        controller?.relinquishApplicationRuleOverride()
        if let current = controller?.currentProject?.projectURL {
            UserDefaults.standard.set(current.path, forKey: "lastProject")
            NativeManualPlaybackStore.save(project: current, paused: controller?.isPaused ?? false)
        }
    }

    private func displayLayout(_ layout: NativeDisplayLayout, assigning url: URL, target: NativeDisplayTarget) throws -> NativeDisplayLayout {
        guard case .display(let key) = target,
              let descriptor = NativeDisplayDescriptor.connected().first(where: { $0.key == key }) else {
            throw NativePlaylistError.invalid("目标显示器当前未连接，原桌面保持不变。")
        }
        var next = layout
        var assignment = next.displays[key] ?? NativeDisplayAssignment(name: descriptor.name)
        assignment.name = descriptor.name; assignment.enabled = true
        assignment.projectPath = url.standardizedFileURL.path
        assignment.projectTitle = url.deletingLastPathComponent().lastPathComponent
        assignment.workshopID = SavedWorkshopStore.recordForProject(url)?.id
        next.displays[key] = assignment
        return try next.validated()
    }

    private func layout(_ layout: NativeDisplayLayout, overlaying contexts: [String: DisplayContentContext]) -> NativeDisplayLayout {
        var next = layout
        for (key, context) in contexts {
            guard case .display = context.target, let url = context.currentURL else { continue }
            var assignment = next.displays[key] ?? NativeDisplayAssignment(name: key)
            assignment.enabled = true; assignment.projectPath = url.standardizedFileURL.path
            assignment.projectTitle = url.deletingLastPathComponent().lastPathComponent
            assignment.workshopID = SavedWorkshopStore.recordForProject(url)?.id
            next.displays[key] = assignment
        }
        return (try? next.validated()) ?? layout
    }

    private func settledDisplayContents(_ contents: [String: DisplayContentContext]) -> [String: DisplayContentContext] {
        let now = ProcessInfo.processInfo.systemUptime
        return Dictionary(uniqueKeysWithValues: contents.map { key, value in
            var value = value; value.epoch = UUID(); value.pendingID = nil
            value.playback?.cancelPending(now: now)
            return (key, value)
        })
    }

    private func displayContents(for profile: NativeWallpaperProfile, owner: DisplayContentOwner,
                                 preservingSessions: [String: DisplayContentContext] = [:]) -> [String: DisplayContentContext] {
        var result = preservingSessions.filter { $0.key.hasPrefix("session:") }
        let now = ProcessInfo.processInfo.systemUptime
        for (key, list) in profile.displayPlaylists {
            guard let target = try? NativeDisplayTarget(location: key) else { continue }
            var playback = NativePlaylistPlayback(list: list, now: now)
            let selected = profile.layout.displays[key].flatMap(NativeDisplayLayout.resolvedProject).map { NativePlaylistLibrary.key(for: $0) }
            playback.manualSelection(key: selected, now: now)
            result[key] = DisplayContentContext(target: target, playback: playback, owner: owner)
        }
        return result
    }

    /// Portable profiles intentionally omit `session:` identities.  They
    /// remain live runtime displays, so merge their current assignment back
    /// into a profile presentation rather than falling through to default.
    private func profilePresentationLayout(_ profileLayout: NativeDisplayLayout) -> NativeDisplayLayout {
        var result = profileLayout
        let runtime = controller?.committedDisplayLayout ?? NativeDisplayStore.load()
        result.displays.merge(runtime.displays.filter { $0.key.hasPrefix("session:") }) { _, session in session }
        if runtime.preferredAudioDisplay?.hasPrefix("session:") == true {
            result.preferredAudioDisplay = runtime.preferredAudioDisplay
        }
        return (try? result.validated()) ?? profileLayout
    }

    private func persistentProfileLayout(_ layout: NativeDisplayLayout) -> NativeDisplayLayout {
        var result = layout
        result.displays = result.displays.filter { !$0.key.hasPrefix("session:") }
        if result.preferredAudioDisplay?.hasPrefix("session:") == true { result.preferredAudioDisplay = nil }
        return result
    }

    /// Prepare and publish one display assignment through WallpaperController's
    /// matching-assignment path.  Other windows are retained by that existing
    /// transaction; an error disposes only the new candidate and retains the
    /// old visible desktop.
    private func applyDisplayContent(url: URL, target: NativeDisplayTarget,
                                     proposedPlayback: NativePlaylistPlayback?, request: NativePlaylistPlayback.Request?,
                                     owner: DisplayContentOwner, epoch: UUID,
                                     validateBeforeCommit: (() throws -> Void)? = nil) async {
        guard displayContentIsCurrent(key: target.key, epoch: epoch),
              let active = controller, configuration?.mode == .desktop,
              displayTargetIsConnected(target) else { return }
        do {
            let proposal = try displayLayout(active.committedDisplayLayout, assigning: url, target: target)
            try await active.applyDisplayLayout(proposal, saveLayout: false) { [weak self] committedLayout in
                guard let self, self.controller === active,
                      self.displayContentIsCurrent(key: target.key, epoch: epoch) else { throw CancellationError() }
                try validateBeforeCommit?()
                var completed = proposedPlayback
                if let request {
                    guard completed?.complete(request, succeeded: true, now: ProcessInfo.processInfo.systemUptime) == true else {
                        throw CancellationError()
                    }
                }
                try self.commitDisplayContent(layout: committedLayout, target: target, playback: completed,
                                               owner: owner, epoch: epoch)
                guard var context = self.displayContentContexts[target.key], context.epoch == epoch else {
                    throw CancellationError()
                }
                context.playback = completed; context.pendingID = nil; context.owner = owner
                self.displayContentContexts[target.key] = context
            }
            guard controller === active, displayContentIsCurrent(key: target.key, epoch: epoch) else { return }
            updateLibraryCurrentProject(); library?.reloadPlaylist(); updatePlaybackMenu()
            updateStatus(active.playbackSummary)
        } catch is CancellationError {
            // A newer intent owns this display.  Keep the old context and old
            // renderer, rather than completing a stale pending request.
        } catch {
            if displayContentIsCurrent(key: target.key, epoch: epoch) {
                if var context = displayContentContexts[target.key] { context.pendingID = nil; displayContentContexts[target.key] = context }
                updateStatus("此屏幕未切换，保留原内容：" + error.localizedDescription)
            }
        }
    }

    private func openProject(_ url: URL, on target: NativeDisplayTarget,
                             validateBeforeCommit: (() throws -> Void)? = nil) {
        guard case .display = target, !isTerminating, !isFinishingBrowser else { return }
        guard displayTargetIsConnected(target) else {
            updateStatus("目标显示器当前未连接，原桌面保持不变。")
            return
        }
        do {
            var context = try displayContentContext(for: target)
            let now = ProcessInfo.processInfo.systemUptime
            let epoch = UUID(); context.epoch = epoch; context.pendingID = nil
            context.playback?.interruptedByUser(now: now)
            var proposed = context.playback
            proposed?.manualSelection(key: NativePlaylistLibrary.key(for: url), now: now)
            // Reserve the context while loading without exposing the unprepared
            // manual choice to ticks, profiles, or Browser Cancel snapshots.
            displayContentContexts[target.key] = context
            enqueueDisplayContent(target: target, epoch: epoch) { [weak self] in
                await self?.applyDisplayContent(url: url, target: target, proposedPlayback: proposed,
                                                request: nil, owner: .manual, epoch: epoch,
                                                validateBeforeCommit: validateBeforeCommit)
            }
        } catch { updateStatus(error.localizedDescription) }
    }

    private func changePlaylist(_ value: NativePlaylist, on target: NativeDisplayTarget) throws {
        guard case .display = target, !isTerminating, !isFinishingBrowser else { throw CancellationError() }
        guard displayTargetIsConnected(target) else {
            throw NativePlaylistError.invalid("目标显示器当前未连接，原桌面保持不变。")
        }
        _ = try value.validated()
        var context = try displayContentContext(for: target)
        let now = ProcessInfo.processInfo.systemUptime
        var replacement = NativePlaylistPlayback(list: value, now: now,
            position: NativePlaylistProgressStore.load(for: value, target: target.key))
        replacement.manualSelection(key: controller?.projectForDisplay(target.key).map { NativePlaylistLibrary.key(for: $0.projectURL) }, now: now)
        let displays = NativeDisplayStore.snapshot(), playlists = NativePlaylistStore.snapshot(), progress = NativePlaylistProgressStore.snapshot()
        do {
            let epoch = UUID(); context.epoch = epoch; context.pendingID = nil
            // Reserve first so an old timer candidate cannot win while this
            // synchronous playlist mutation claims manual ownership.
            displayContentContexts[target.key] = context
            if applicationSelection.ownsTemporarySelection {
                try promoteTemporaryDesktopToManual(layout: controller?.committedDisplayLayout ?? NativeDisplayStore.load(),
                                                     replacing: target, playback: replacement, epoch: epoch)
                return
            }
            if target.persistent {
                var active = try NativePlaylistStore.active(); active.lists = active.lists.filter { NativePlaylistStore.persistentTarget($0.key) }
                active.lists[target.key] = replacement.list
                try NativePlaylistStore.replacePersistent(active)
                NativePlaylistProgressStore.save(replacement, target: target.key)
            } else {
                try NativePlaylistStore.setActive(replacement.list, target: target.key)
                NativePlaylistProgressStore.save(replacement, target: target.key)
            }
            context.playback = replacement; context.owner = .manual
            displayContentContexts[target.key] = context
        } catch {
            NativeDisplayStore.restore(displays); NativePlaylistStore.restore(playlists); NativePlaylistProgressStore.restore(progress)
            throw error
        }
    }

    /// A playlist hotkey has the same prepare-before-replace rule as a timer
    /// tick.  It does not write a `session:` target to preferences, and it
    /// leaves the old target context/renderer intact if its first entry fails.
    private func activateDisplayPlaylist(_ list: NativePlaylist, target: NativeDisplayTarget,
                                         validateBeforeCommit: (() throws -> Void)? = nil) {
        guard case .display = target, !isTerminating, !isFinishingBrowser else { return }
        guard displayTargetIsConnected(target) else {
            updateStatus("目标显示器当前未连接，原桌面保持不变。")
            return
        }
        do {
            _ = try list.validated()
            var context = try displayContentContext(for: target)
            let now = ProcessInfo.processInfo.systemUptime
            var candidate = NativePlaylistPlayback(list: list, now: now,
                position: NativePlaylistProgressStore.load(for: list, target: target.key))
            guard let request = candidate.initial(now: now, date: Date()) else {
                throw NativePlaylistError.invalid("播放列表没有可播放的壁纸。")
            }
            let url = try NativePlaylistLibrary.resolve(request.entry.wallpaper)
            let epoch = UUID(); context.epoch = epoch; context.pendingID = request.id
            displayContentContexts[target.key] = context
            let proposed = candidate
            enqueueDisplayContent(target: target, epoch: epoch) { [weak self] in
                await self?.applyDisplayContent(url: url, target: target, proposedPlayback: proposed,
                                                request: request, owner: .manual, epoch: epoch,
                                                validateBeforeCommit: validateBeforeCommit)
            }
        } catch { updateStatus("热键未应用，保留原桌面：" + error.localizedDescription) }
    }

    /// Revert one display to the desktop default without touching another
    /// monitor.  The persistent layout/list/progress snapshots are restored
    /// together if the final target candidate loses ownership or fails.
    private func removeDisplayContentTarget(_ key: String) async throws {
        guard displayContentMaintenanceTask == nil else {
            throw NativePlaylistError.invalid("正在应用另一项显示器设置，请稍候重试。")
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            defer { self.displayContentMaintenanceTask = nil }
            try await self.performRemoveDisplayContentTarget(key)
        }
        displayContentMaintenanceTask = task
        try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            task.cancel()
        })
    }

    private func performRemoveDisplayContentTarget(_ key: String) async throws {
        let target = try NativeDisplayTarget(location: key)
        guard case .display = target else { throw NativePlaylistError.invalid("默认壁纸不能从显示器列表中移除。") }
        guard !displayContentMaintenanceInFlight else {
            throw NativePlaylistError.invalid("正在应用另一项显示器设置，请稍候重试。")
        }
        displayContentMaintenanceInFlight = true
        defer {
            displayContentMaintenanceInFlight = false
            startNextDisplayContentJob()
        }

        // WallpaperController has a single load generation.  Removing just
        // this target while another target is queued would allow that queued
        // candidate to begin between our await points, then leave it pending
        // when this transaction supersedes it.  Invalidate the whole lane and
        // wait for it to become idle before reserving the removal epoch.
        cancelDisplayContentTransactions()
        let pending = displayContentActiveTask
        await pending?.value
        try Task.checkCancellation()
        guard !isTerminating, !isFinishingBrowser else { throw CancellationError() }
        let removedSessionProject = target.persistent ? nil : controller?.projectForDisplay(key)?.projectURL
        var removalContext = try displayContentContext(for: target)
        let removalEpoch = UUID()
        removalContext.epoch = removalEpoch; removalContext.pendingID = nil
        removalContext.playback?.cancelPending(now: ProcessInfo.processInfo.systemUptime)
        displayContentContexts[key] = removalContext

        let displays = NativeDisplayStore.snapshot(), playlists = NativePlaylistStore.snapshot(), progress = NativePlaylistProgressStore.snapshot()
        func persistRemoval(_ layout: NativeDisplayLayout) throws {
            try Task.checkCancellation()
            do {
                try NativeDisplayStore.save(layout)
                if target.persistent {
                    var active = try NativePlaylistStore.active(); active.lists = active.lists.filter { NativePlaylistStore.persistentTarget($0.key) }
                    active.lists.removeValue(forKey: target.key)
                    try NativePlaylistStore.replacePersistent(active)
                    NativePlaylistProgressStore.save(nil, target: target.key)
                } else {
                    try NativePlaylistStore.setActive(.init(), target: target.key)
                    NativePlaylistProgressStore.save(nil, target: target.key)
                }
            } catch {
                NativeDisplayStore.restore(displays); NativePlaylistStore.restore(playlists); NativePlaylistProgressStore.restore(progress)
                throw error
            }
        }
        func disabledAssignment(in layout: NativeDisplayLayout) -> NativeDisplayLayout {
            var proposal = layout
            var assignment = proposal.displays[key] ?? NativeDisplayAssignment(
                name: NativeDisplayDescriptor.connected().first(where: { $0.key == key })?.name ?? "显示器")
            assignment.enabled = false
            assignment.projectPath = nil; assignment.projectTitle = nil; assignment.workshopID = nil
            proposal.displays[key] = assignment
            return proposal
        }
        if let active = controller, displayTargetIsConnected(target), configuration?.mode == .desktop {
            let proposal = disabledAssignment(in: active.committedDisplayLayout)
            try await active.applyDisplayLayout(proposal, saveLayout: false) { [weak self] committed in
                guard let self, self.controller === active,
                      self.displayContentIsCurrent(key: key, epoch: removalEpoch) else { throw CancellationError() }
                try Task.checkCancellation()
                if self.applicationSelection.ownsTemporarySelection {
                    try self.promoteTemporaryDesktopToManual(layout: committed, replacing: target,
                                                             playback: nil, epoch: removalEpoch, removingTarget: true)
                } else {
                    try persistRemoval(committed)
                    self.displayContentContexts.removeValue(forKey: key)
                }
            }
            try Task.checkCancellation()
        } else {
            let proposal = disabledAssignment(in: NativeDisplayStore.load())
            if applicationSelection.ownsTemporarySelection {
                try promoteTemporaryDesktopToManual(layout: proposal, replacing: target,
                                                     playback: nil, epoch: removalEpoch, removingTarget: true)
            } else {
                try persistRemoval(proposal)
                displayContentContexts.removeValue(forKey: key)
            }
        }
        try Task.checkCancellation()
        if let removedSessionProject {
            try? WallpaperPropertyStore.clearSession(project: removedSessionProject, target: target)
            _ = WallpaperPropertyStore.pruneUnreferencedMediaGrants(project: removedSessionProject)
        }
        updateLibraryCurrentProject(); library?.reloadPlaylist()
    }
    private func advancePlaylist() {
        reconcileApplicationSelection()
        let suspended = playlistIsSuspended
        if let request = playlistPlayback?.tick(now: ProcessInfo.processInfo.systemUptime, date: Date(),
            paused: controller?.defaultPlaylistPaused ?? true, video: controller?.currentProject?.kind == .video, suspended: suspended) {
            openPlaylistRequest(request)
        }
        if let request = applicationPlaylistPlayback?.tick(now: ProcessInfo.processInfo.systemUptime, date: Date(),
            paused: controller?.defaultPlaylistPaused ?? true, video: controller?.currentProject?.kind == .video,
            suspended: applicationPlaylistIsSuspended) {
            openApplicationPlaylistRequest(request)
        }
        advanceDisplayPlaylists()
    }

    private func advanceDisplayPlaylists() {
        guard !playlistPresentationIsSuspended, !playbackPolicy.environment.stopsDesktop else { return }
        let now = ProcessInfo.processInfo.systemUptime, date = Date()
        for key in displayContentContexts.keys.sorted() {
            guard var context = displayContentContexts[key], context.pendingID == nil,
                  context.target != .defaultWallpaper, displayTargetIsConnected(context.target),
                  var candidate = context.playback else { continue }
            // A normal wallpaper/list application rule temporarily hides the
            // user's independent displays.  Their schedulers must not advance
            // invisibly and accidentally claim manual ownership; a full
            // profile rule installs `.applicationTemporary` contexts instead.
            guard !applicationSelection.ownsTemporarySelection || context.owner != .manual else { continue }
            let paused = controller?.playlistPaused(forDisplay: key) ?? true
            guard let request = candidate.tick(now: now, date: date, paused: paused,
                                               video: controller?.projectForDisplay(key)?.kind == .video,
                                               suspended: false) else { continue }
            context.pendingID = request.id
            displayContentContexts[key] = context
            let url: URL
            do { url = try NativePlaylistLibrary.resolve(request.entry.wallpaper) }
            catch {
                context.pendingID = nil; displayContentContexts[key] = context
                continue
            }
            let epoch = context.epoch, target = context.target, owner = context.owner, proposed = candidate
            enqueueDisplayContent(target: target, epoch: epoch) { [weak self] in
                await self?.applyDisplayContent(url: url, target: target, proposedPlayback: proposed,
                                                request: request, owner: owner, epoch: epoch)
            }
        }
    }

    private func requestNextDisplayPlaylist(_ key: String, videoEnded: Bool) {
        guard !playlistPresentationIsSuspended, !playbackPolicy.environment.stopsDesktop,
              var context = displayContentContexts[key], context.pendingID == nil,
              displayTargetIsConnected(context.target), var candidate = context.playback else { return }
        guard !applicationSelection.ownsTemporarySelection || context.owner != .manual else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let paused = controller?.playlistPaused(forDisplay: key) ?? true
        let request = videoEnded
            ? candidate.videoEnded(now: now, paused: paused)
            : candidate.next(now: now)
        guard let request else { return }
        let url: URL
        do { url = try NativePlaylistLibrary.resolve(request.entry.wallpaper) }
        catch { updateStatus("此屏幕播放列表未切换：" + error.localizedDescription); return }
        context.pendingID = request.id; displayContentContexts[key] = context
        let epoch = context.epoch, target = context.target, owner = context.owner, proposed = candidate
        enqueueDisplayContent(target: target, epoch: epoch) { [weak self] in
            await self?.applyDisplayContent(url: url, target: target, proposedPlayback: proposed,
                                            request: request, owner: owner, epoch: epoch)
        }
    }

    /// Workshop revisions can replace a current UUID profile-playlist entry
    /// without changing the saved profile structure.  Refresh just that
    /// display and preserve its scheduler position; never restart the entire
    /// temporary profile list merely because one entry obtained a new version.
    private func refreshTemporaryProfileDisplayProjects(expectedProfile: NativeWallpaperProfile,
                                                         selection: NativeApplicationRuleEffects.Selection) {
        guard applicationSelection.current == selection, applicationSelection.observed == selection,
              applicationProfile == expectedProfile, selection.action == .loadprofile,
              !playlistPresentationIsSuspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for key in displayContentContexts.keys.sorted() {
            guard var context = displayContentContexts[key], context.owner == .applicationTemporary,
                  context.pendingID == nil, var candidate = context.playback,
                  let current = candidate.currentEntry,
                  let url = try? NativePlaylistLibrary.resolve(current.wallpaper),
                  controller?.projectForDisplay(key)?.projectURL != url else { continue }
            guard let request = candidate.refreshCurrent(now: now) else { continue }
            context.pendingID = request.id; displayContentContexts[key] = context
            let target = context.target, epoch = context.epoch, proposed = candidate
            enqueueDisplayContent(target: target, epoch: epoch) { [weak self] in
                await self?.applyDisplayContent(url: url, target: target, proposedPlayback: proposed,
                    request: request, owner: .applicationTemporary, epoch: epoch, validateBeforeCommit: { [weak self] in
                        guard let self, self.applicationSelection.current == selection,
                              self.applicationSelection.observed == selection,
                              self.applicationProfile == expectedProfile else { throw CancellationError() }
                    })
            }
        }
    }
    private func openPlaylistRequest(_ request: NativePlaylistPlayback.Request) {
        openProject(URL(fileURLWithPath: request.entry.wallpaper.projectPath), mode: .desktop, playlistRequest: request)
    }
    private func openApplicationPlaylistRequest(_ request: NativePlaylistPlayback.Request) {
        openProject(URL(fileURLWithPath: request.entry.wallpaper.projectPath), mode: .desktop, temporaryPlaylistRequest: request)
    }
    @discardableResult
    private func finishPlaylistTransitions() -> [Task<Void, Never>] {
        controller?.setPresentationOpacity(1)
        let tasks = retiringPlaylists.values.compactMap { $0.stop() }; retiringPlaylists.removeAll(); return tasks
    }

    private var canBeginApplicationSelection: Bool {
        !isTerminating && !isFinishingBrowser && !applyingDisplayLayout &&
            configuration?.mode == .desktop && controller?.currentProject != nil &&
            (openRequestID == nil || openingApplicationRequest?.id == openRequestID || openingApplicationPlaylistRequest != nil) &&
            (failedProjectLoad == nil || failedProjectLoad?.applicationRule == true || applicationSelection.current != nil) &&
            !playbackPolicy.environment.stopsDesktop && NSApp.modalWindow == nil &&
            library?.window?.attachedSheet == nil && propertyEditor?.hasPendingApplication != true
    }
    private func applicationSelectionSnapshot() -> ApplicationSelectionSnapshot? {
        guard let configuration, configuration.mode == .desktop, let project = controller?.currentProject else { return nil }
        return .init(configuration: configuration,
            target: try? NativeApplicationWallpaperTarget.capture(project: project.projectURL, title: project.title, type: project.kind.rawValue),
            layout: NativeDisplayStore.load(), paused: controller?.isPaused ?? false,
            displayContents: displayContentContexts)
    }
    /// Preserve malformed or wrong-typed data as a distinct generation. This
    /// lets an active rule notice that an invalid saved-profile catalog has
    /// replaced a valid one, while avoiding an unbounded retry of that target.
    private func applicationProfileCatalogFingerprint() -> Data? {
        guard let object = UserDefaults.standard.object(forKey: NativeProfileStore.savedKey) else { return nil }
        if let data = object as? Data { return Data([1]) + Data(SHA256.hash(data: data)) }
        return Data([2]) + Data(String(reflecting: type(of: object)).utf8)
    }
    private func reconcileApplicationSelection() {
        let desired = playbackPolicy.environment.applicationEffects.selection
        let catalog = UserDefaults.standard.data(forKey: NativePlaylistStore.savedKey)
        if catalog != applicationPlaylistCatalog {
            applicationPlaylistCatalog = catalog; applicationSelectionNeedsRefresh = true; applicationSelection.retry()
        }
        let profileCatalog = applicationProfileCatalogFingerprint()
        if profileCatalog != applicationProfileCatalogGeneration {
            applicationProfileCatalogGeneration = profileCatalog
            if desired?.action == .loadprofile || applicationSelection.current?.action == .loadprofile {
                applicationSelectionNeedsRefresh = true; applicationSelection.retry()
            }
        }
        if openingApplicationPlaylistRequest != nil, desired != applicationSelection.current || !canBeginApplicationSelection || applicationSelectionNeedsRefresh {
            cancelProjectLoad(report: false, cancelPlaylist: false)
        }
        let transition = applicationSelection.observe(desired, snapshot: desired != nil && !applicationSelection.ownsTemporarySelection ? applicationSelectionSnapshot() : nil,
            canBegin: canBeginApplicationSelection)
        if let cancelled = transition.cancelled, openRequestID == cancelled {
            cancelProjectLoad(report: false, cancelPlaylist: false, cancelApplicationSelection: false)
        }
        if let request = transition.request { openApplicationSelection(request) }
        else { checkApplicationSelectionUpdate() }
    }
    private func openApplicationSelection(_ request: ApplicationSelection.Request) {
        openProject(request.original.configuration.projectURL, mode: .desktop, applicationRequest: request)
    }
    private func checkApplicationSelectionUpdate() {
        guard applicationSelectionNeedsRefresh, applicationSelectionRefreshTask == nil,
              canBeginApplicationSelection, openRequestID == nil, applicationSelection.pending == nil else { return }
        guard let selected = applicationSelection.current, selected == applicationSelection.observed,
              let expected = controller, let configuration else { applicationSelectionNeedsRefresh = false; return }
        applicationSelectionNeedsRefresh = false
        let file = selected.file, previousURL = configuration.projectURL
        if selected.action == .loadplaylist {
            do {
                let list = try NativeApplicationPlaylistTarget.resolve(file)
                if list != applicationPlaylistPlayback?.list {
                    if let request = applicationSelection.refreshCurrent() { openApplicationSelection(request) }
                    return
                }
            } catch {
                updateStatus("规则播放列表更新暂时不可用，保留当前画面：" + error.localizedDescription)
                return
            }
        }
        if selected.action == .loadprofile {
            applicationSelectionRefreshTask = Task { [weak self] in
                guard let self else { return }
                defer { applicationSelectionRefreshTask = nil }
                do {
                    let profile = try NativeApplicationProfileTarget.resolve(file)
                    let prepared = try await SavedWorkshopStore.perform { try NativeProfileLibrary.prepare(profile) }
                    let playlistEntry = applicationPlaylistPlayback?.currentEntry
                    let playlistEntryURL: URL?
                    if let playlistEntry {
                        playlistEntryURL = try await SavedWorkshopStore.perform { try NativePlaylistLibrary.resolve(playlistEntry.wallpaper) }
                    } else { playlistEntryURL = nil }
                    try Task.checkCancellation()
                    guard !isTerminating, controller === expected, applicationSelection.current == selected,
                          applicationSelection.observed == selected else { return }
                    guard canBeginApplicationSelection, openRequestID == nil else { applicationSelectionNeedsRefresh = true; return }
                    if prepared != applicationProfile, let request = applicationSelection.refreshCurrent() {
                        openApplicationSelection(request)
                    } else if let playlistEntry, let playlistEntryURL,
                              applicationPlaylistPlayback?.list == prepared.playlist,
                              applicationPlaylistPlayback?.currentEntry == playlistEntry,
                              playlistEntryURL != configuration.projectURL,
                              let request = applicationPlaylistPlayback?.refreshCurrent(now: ProcessInfo.processInfo.systemUptime) {
                        openApplicationPlaylistRequest(request)
                    }
                    self.refreshTemporaryProfileDisplayProjects(expectedProfile: prepared, selection: selected)
                } catch is CancellationError { }
                catch {
                    if !isTerminating { updateStatus("规则配置文件更新暂时不可用，保留当前画面：" + error.localizedDescription) }
                }
            }
            return
        }
        let playlistEntry = selected.action == .loadplaylist ? applicationPlaylistPlayback?.currentEntry : nil
        applicationSelectionRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { applicationSelectionRefreshTask = nil }
            do {
                let url = try await SavedWorkshopStore.perform {
                    if let playlistEntry { return try NativePlaylistLibrary.resolve(playlistEntry.wallpaper) }
                    return try NativeApplicationWallpaperTarget.resolve(file)
                }
                try Task.checkCancellation()
                guard !isTerminating, controller === expected, applicationSelection.current == selected,
                      applicationSelection.observed == selected else { return }
                guard canBeginApplicationSelection, openRequestID == nil else { applicationSelectionNeedsRefresh = true; return }
                if url != previousURL {
                    if selected.action == .loadplaylist {
                        if applicationPlaylistPlayback?.currentEntry == playlistEntry,
                           let request = applicationPlaylistPlayback?.refreshCurrent(now: ProcessInfo.processInfo.systemUptime) { openApplicationPlaylistRequest(request) }
                    } else if let request = applicationSelection.refreshCurrent() { openApplicationSelection(request) }
                }
            } catch is CancellationError { }
            catch { if !isTerminating { updateStatus("规则壁纸更新暂时不可用，保留当前画面：" + error.localizedDescription) } }
        }
    }
    private func applicationLibraryChanged(forcePreview: Bool = false) {
        library?.refreshLibrary(forcePreview: forcePreview); displayPicker?.refreshLibrary()
        controller?.checkAssignedUpdates(); pendingController?.checkAssignedUpdates()
        applicationSelectionNeedsRefresh = true; applicationSelection.retry(); reconcileApplicationSelection()
    }
    private func workshopProjectUpdated(_ proposed: URL) {
        let url = SavedWorkshopStore.recordForProject(proposed).flatMap { SavedWorkshopStore.current($0.id)?.project } ?? proposed
        // A profile can reference this project as its default, an independent
        // display assignment, or the current temporary playlist entry. Its
        // refresh path distinguishes full profile replacement from a
        // position-preserving current-entry update.
        if applicationSelection.current?.action == .loadprofile {
            applicationSelectionNeedsRefresh = true; applicationSelection.retry(); reconcileApplicationSelection()
        }
        if let original = applicationSelection.original {
            guard SavedWorkshopStore.settingsIdentity(original.configuration.projectURL) == SavedWorkshopStore.settingsIdentity(url) else { return }
            let cancelled = applicationSelection.updateOriginal { $0.configuration = .init(projectURL: url, mode: .desktop) }
            if let cancelled, openRequestID == cancelled { cancelProjectLoad(report: false, cancelPlaylist: false, cancelApplicationSelection: false) }
            UserDefaults.standard.set(url.path, forKey: "lastProject")
            NativeManualPlaybackStore.save(project: url, paused: applicationSelection.original?.paused ?? original.paused)
            workshop.track(project: url)
            reconcileApplicationSelection()
        } else if openRequestID == nil, !isFinishingBrowser, let configuration,
                  SavedWorkshopStore.settingsIdentity(configuration.projectURL) == SavedWorkshopStore.settingsIdentity(url) {
            openProject(url, mode: configuration.mode, automaticUpdate: true)
        }
    }

    private func openProject(_ url: URL, mode: LaunchMode, retryingFailure: Bool = false, importing: NativeWallpaperImportRequest? = nil,
                             playlistRequest: NativePlaylistPlayback.Request? = nil, playlistWallpaper: NativePlaylistWallpaper? = nil, startingPlaylist: Bool = false,
                             applicationRequest: ApplicationSelection.Request? = nil, automaticUpdate: Bool = false,
                             temporaryPlaylistRequest: NativePlaylistPlayback.Request? = nil, profileRequest: ProfileLoadRequest? = nil,
                             hotkeyContent: HotkeyContentRequest? = nil) {
        guard !isTerminating, !isFinishingBrowser else { return }
        // Whole-desktop replacement and a single-display replacement share
        // WallpaperController's load generation.  Retain each display's
        // desired context but invalidate any candidate that has not published
        // before the global request takes ownership.
        cancelDisplayContentTransactions()
        let ruleRequest = applicationRequest != nil || temporaryPlaylistRequest != nil
        if !ruleRequest, playlistRequest == nil, !startingPlaylist, !automaticUpdate, profileRequest?.hotkeyRequestID == nil {
            invalidatePendingProfileHotkey()
        }
        let playlistOwner = temporaryPlaylistRequest == nil ? nil : applicationSelection.current
        let temporaryProfile = temporaryPlaylistRequest == nil ? nil : applicationProfile
        let temporaryProfileTarget = temporaryProfile == nil ? nil : applicationProfileTarget
        let temporaryProfileCatalog = temporaryProfile == nil ? nil : applicationProfileCatalogFingerprint()
        let playlistBeforeHotkey = hotkeyContent == nil ? nil : playlistPlayback
        // A content hotkey is a candidate selection until preparation succeeds.
        // Preserve the current scheduler as well as its visible position while
        // a broken or subsequently unbound target is still being prepared.
        if !ruleRequest, playlistRequest == nil, !startingPlaylist, !automaticUpdate, hotkeyContent == nil { playlistPlayback?.interruptedByUser(now: ProcessInfo.processInfo.systemUptime) }
        projectLoadLog.notice("Project load requested")
        if profileRequest == nil { displaySettings?.cancelPendingApply() }
        if !ruleRequest { workshop.beginSelection() }
        cancelProjectLoad(report: false, cancelPlaylist: false, cancelApplicationSelection: applicationRequest == nil)
        openingPlaylistRequest = playlistRequest?.id
        openingApplicationRequest = applicationRequest
        openingApplicationPlaylistRequest = temporaryPlaylistRequest?.id
        requestedConfiguration = LaunchConfiguration(projectURL: url, mode: mode)
        requestedImport = importing
        if !retryingFailure { failedProjectLoad = nil }
        updateLibraryLoadFailure()
        let requestID = applicationRequest?.id ?? UUID(); openRequestID = requestID
        if !ruleRequest { library?.updateProjectLoading(true) }
        updateStatus("正在加载新壁纸，原桌面保持当前内容。")
        let task = Task { [weak self] in
            guard let self else { return }
            var didCommit = false
            defer {
                if hotkeyContent != nil, !didCommit, openRequestID == requestID,
                   playlistPlayback?.list == playlistBeforeHotkey?.list {
                    // A superseded automatic load may finish cancellation
                    // after this request. Restore timing/backoff without its
                    // old pending ID, so that stale completion cannot mark a
                    // playable item unavailable or stall the scheduler.
                    var restored = playlistBeforeHotkey
                    restored?.cancelPending(now: ProcessInfo.processInfo.systemUptime)
                    playlistPlayback = restored
                }
                if profileRequest?.result == nil { profileRequest?.result = .failure(CancellationError()) }
                pendingOpenTasks.removeValue(forKey: requestID)
                if openRequestID == requestID {
                    openRequestID = nil; openTask = nil
                    requestedConfiguration = nil; requestedImport = nil
                    library?.updateProjectLoading(false)
                    openingPlaylistRequest = nil
                    openingApplicationRequest = nil
                    openingApplicationPlaylistRequest = nil
                }
            }
            projectLoadLog.notice("Project load task started")
            var next: WallpaperController?
            var initialPlaylist: NativePlaylistPlayback?
            var initialEntry: NativePlaylistPlayback.Request?
            var preparedProfile: NativeWallpaperProfile?
            var applicationProfileSelection: NativeWallpaperProfile?
            var preparedApplicationProfile: NativeWallpaperProfile?
            let preparationTime = ProcessInfo.processInfo.systemUptime
            do {
                try Task.checkCancellation()
                if let hotkeyContent {
                    try validateHotkeyContent(hotkeyContent)
                    if let list = hotkeyContent.playlist {
                        initialPlaylist = NativePlaylistPlayback(list: list, now: preparationTime)
                        initialEntry = initialPlaylist?.initial(now: preparationTime, date: Date())
                        guard initialEntry != nil else { throw NativePlaylistError.invalid("热键播放列表没有可播放的壁纸。") }
                    }
                }
                if let profileRequest {
                    let profile = profileRequest.profile
                    preparedProfile = try await SavedWorkshopStore.perform { try NativeProfileLibrary.prepare(profile) }
                    try Task.checkCancellation()
                }
                if let selection = applicationRequest?.selection, selection.action == .loadplaylist {
                    initialPlaylist = NativePlaylistPlayback(list: try NativeApplicationPlaylistTarget.resolve(selection.file), now: preparationTime)
                    initialEntry = initialPlaylist?.initial(now: preparationTime, date: Date())
                    guard initialEntry != nil else { throw NativePlaylistError.invalid("规则播放列表没有可播放的壁纸。") }
                }
                if let selection = applicationRequest?.selection, selection.action == .loadprofile {
                    let profile = try NativeApplicationProfileTarget.resolve(selection.file)
                    applicationProfileSelection = profile
                    preparedApplicationProfile = try await SavedWorkshopStore.perform { try NativeProfileLibrary.prepare(profile) }
                    if let list = preparedApplicationProfile?.playlist {
                        initialPlaylist = NativePlaylistPlayback(list: list, now: preparationTime)
                    }
                    try Task.checkCancellation()
                }
                while true {
                    do {
                        var readyURL = preparedApplicationProfile.map { URL(fileURLWithPath: $0.wallpaper.projectPath) }
                            ?? preparedProfile.map { URL(fileURLWithPath: $0.wallpaper.projectPath) } ?? url
                        if ruleRequest {
                            // Finish the user's last valid inspector edit before the
                            // loading row replaces it. This is the ordinary host path.
                            await library?.finishInlinePropertyEditing()?.value
                            try Task.checkCancellation()
                            guard openRequestID == requestID else { throw CancellationError() }
                            if let applicationRequest, !applicationSelection.canCommit(applicationRequest) { throw CancellationError() }
                            if let temporaryPlaylistRequest {
                                guard applicationPlaylistPlayback?.pending?.id == temporaryPlaylistRequest.id,
                                      playlistOwner != nil, applicationSelection.current == playlistOwner,
                                      applicationSelection.observed == playlistOwner else { throw CancellationError() }
                            }
                            library?.updateProjectLoading(true)
                            if let applicationRequest, initialPlaylist == nil, preparedApplicationProfile == nil,
                               let file = applicationRequest.selection?.file ?? applicationRequest.original.target {
                                readyURL = try await SavedWorkshopStore.perform { try NativeApplicationWallpaperTarget.resolve(file) }
                                try Task.checkCancellation()
                            }
                            requestedConfiguration = .init(projectURL: readyURL, mode: mode)
                        }
                        if let wallpaper = initialEntry?.entry.wallpaper ?? temporaryPlaylistRequest?.entry.wallpaper ?? playlistRequest?.entry.wallpaper ?? playlistWallpaper {
                            readyURL = try await SavedWorkshopStore.perform { try NativePlaylistLibrary.resolve(wallpaper) }
                            try Task.checkCancellation()
                        }
                        var imported: NativeLocalWallpapers.Prepared?
                        if let importing {
                            updateStatus("正在准备离线壁纸，原桌面保持当前内容。")
                            imported = try await NativeLocalWallpapers.prepare(importing)
                            try Task.checkCancellation()
                            readyURL = imported!.project
                        } else if SteamLibraryIndex.location(for: readyURL) != nil {
                            updateStatus("正在保存到本机壁纸库…")
                            let source = readyURL
                            let saved = try await SavedWorkshopStore.perform {
                                try SavedWorkshopStore.save(project: source, id: source.deletingLastPathComponent().lastPathComponent)
                            }
                            try Task.checkCancellation()
                            readyURL = saved.project
                        }
                        let nextConfiguration = LaunchConfiguration(projectURL: readyURL, mode: mode)
                        let preserveManualPause = ruleRequest ? applicationSelection.original?.paused ?? applicationRequest?.original.paused ?? false : profileRequest != nil ? controller?.isPaused ?? false : manualPause(for: readyURL)
                        let ruleProfile = preparedApplicationProfile ?? temporaryProfile
                        let applicationRuleLayout = ruleProfile.map { self.profilePresentationLayout($0.layout) } ?? (applicationRequest?.restoring == true
                            ? applicationRequest?.original.layout : applicationSelection.original?.layout ?? applicationRequest?.original.layout)
                        let applicationRuleStrictLayout = ruleProfile.map { self.profilePresentationLayout($0.layout) } ?? (applicationRequest?.restoring == true
                            ? applicationRequest?.original.layout : nil)
                        let strictRuleKeys = Set(applicationRuleStrictLayout?.displays.keys.map { $0 }
                            ?? preparedProfile?.layout.displays.keys.map { $0 } ?? [])
                        let candidate = WallpaperController(configuration: nextConfiguration, initiallyPaused: preserveManualPause, audioOutputAllowed: false,
                            applicationRuleOverride: applicationRequest?.selection != nil || temporaryPlaylistRequest != nil,
                            applicationRuleUsesFullLayout: ruleProfile != nil || applicationRequest?.restoring == true)
                        let playlistSettings = initialPlaylist?.list.settings ?? (temporaryPlaylistRequest != nil ? applicationPlaylistPlayback?.list.settings : playlistRequest != nil ? playlistPlayback?.list.settings : nil)
                        let fade = playlistSettings?.transition == "0" && controller != nil && mode == .desktop
                            ? (playlistSettings?.transitionMilliseconds ?? 0) / 1000 : 0
                        if fade > 0 { candidate.setPresentationOpacity(0) }
                        var retiringID: UUID?
                        next = candidate
                        configureCallbacks(candidate, requestID: requestID)
                        pendingController = candidate
                        if systemIsSleeping { candidate.suspendForSystemSleep() }
                        if displaysAreSleeping { candidate.suspendForDisplaySleep() }
                        if sessionIsInactive { candidate.suspendForInactiveSession() }
                        candidate.updatePlaybackPolicy(playbackPolicy.environment)
                        try await candidate.start(layout: ruleRequest ? applicationRuleLayout : preparedProfile.map { self.profilePresentationLayout($0.layout) },
                                                  strictKeys: strictRuleKeys) { [self] in
                            try Task.checkCancellation()
                            guard !self.isTerminating, self.openRequestID == requestID else { throw CancellationError() }
                            if let playlistRequest, self.playlistPlayback?.pending?.id != playlistRequest.id { throw CancellationError() }
                            if let applicationRequest {
                                guard self.canBeginApplicationSelection, self.applicationSelection.canCommit(applicationRequest) else { throw CancellationError() }
                                if applicationRequest.selection?.action == .loadplaylist,
                                   let initialPlaylist, let name = applicationRequest.selection?.file,
                                   try NativeApplicationPlaylistTarget.resolve(name) != initialPlaylist.list { throw CancellationError() }
                                if let applicationProfileSelection, let name = applicationRequest.selection?.file,
                                   try NativeApplicationProfileTarget.resolve(name) != applicationProfileSelection { throw CancellationError() }
                            }
                            if let temporaryPlaylistRequest {
                                guard self.canBeginApplicationSelection, playlistOwner != nil,
                                      self.applicationSelection.current == playlistOwner, self.applicationSelection.observed == playlistOwner,
                                      self.applicationPlaylistPlayback?.pending?.id == temporaryPlaylistRequest.id else { throw CancellationError() }
                                if let temporaryProfile {
                                    guard let temporaryProfileTarget,
                                          self.applicationProfile == temporaryProfile,
                                          self.applicationProfileTarget == temporaryProfileTarget,
                                          self.applicationProfileCatalogFingerprint() == temporaryProfileCatalog,
                                          self.applicationSelection.current?.action == .loadprofile,
                                          self.applicationSelection.current?.file == temporaryProfileTarget.name,
                                          try NativeApplicationProfileTarget.resolve(temporaryProfileTarget.name) == temporaryProfileTarget else {
                                        throw CancellationError()
                                    }
                                }
                            }
                            // Publish only after every new display has prepared and
                            // before replacing the old controller or lastProject.
                            if let hotkeyContent {
                                try self.validateHotkeyContent(hotkeyContent)
                                if let list = hotkeyContent.playlist { try NativePlaylistStore.setActive(list, target: "default") }
                            }
                            try imported?.commit()
                            if let preparedProfile {
                                guard !self.playbackPolicy.environment.stopsDesktop else {
                                    throw PropertyError.invalid("壁纸处于停止状态，请恢复播放后重试加载配置文件。")
                                }
                                try profileRequest?.validateBeforeCommit?()
                                try NativeProfileStore.applySelection(preparedProfile)
                                self.displayContentContexts = self.displayContents(for: preparedProfile, owner: .manual,
                                    preservingSessions: self.displayContentContexts)
                            }
                            // Loading can suspend while the user pauses or continues
                            // the current wallpaper. Transfer the latest intent at the
                            // same boundary that transfers presentation ownership.
                            let paused = ruleRequest ? self.applicationSelection.original?.paused ?? applicationRequest?.original.paused ?? false : profileRequest != nil ? self.controller?.isPaused ?? false : self.manualPause(for: readyURL)
                            if paused { candidate.pause() } else { candidate.resume() }
                            if let applicationRequest {
                                precondition(self.applicationSelection.commit(applicationRequest))
                                if let initialEntry { initialPlaylist?.complete(initialEntry, succeeded: true, now: ProcessInfo.processInfo.systemUptime) }
                                else if applicationRequest.selection?.action == .loadprofile {
                                    initialPlaylist?.manualSelection(key: NativePlaylistLibrary.key(for: readyURL), now: ProcessInfo.processInfo.systemUptime)
                                }
                                self.applicationPlaylistPlayback = initialPlaylist
                                self.applicationProfile = preparedApplicationProfile
                                self.applicationProfileTarget = applicationProfileSelection
                                if let preparedApplicationProfile {
                                    self.displayContentContexts = self.displayContents(for: preparedApplicationProfile,
                                        owner: .applicationTemporary,
                                        preservingSessions: applicationRequest.original.displayContents)
                                } else if applicationRequest.restoring == true {
                                    self.displayContentContexts = self.settledDisplayContents(applicationRequest.original.displayContents)
                                }
                            } else if let temporaryPlaylistRequest {
                                self.applicationPlaylistPlayback?.complete(temporaryPlaylistRequest, succeeded: true, now: ProcessInfo.processInfo.systemUptime)
                            } else if !startingPlaylist, !automaticUpdate, playlistRequest == nil {
                                self.applicationSelection.interruptedByUser(); self.applicationPlaylistPlayback = nil
                                self.applicationProfile = nil; self.applicationProfileTarget = nil
                            }
                            self.finishPlaylistTransitions()
                            if fade > 0, let old = self.controller {
                                let id = UUID(); retiringID = id; self.retiringPlaylists[id] = old
                                old.disableAudioOutput(); old.pause()
                            } else { self.controller?.stop() }
                            self.controller = candidate
                            self.configuration = nextConfiguration
                            self.propertyEditor?.close(); self.propertyEditor = nil
                            if !ruleRequest || applicationRequest?.restoring == true {
                                UserDefaults.standard.set(readyURL.path, forKey: "lastProject")
                                NativeManualPlaybackStore.save(project: readyURL, paused: candidate.isPaused)
                                self.workshop.track(project: readyURL)
                            }
                            self.pendingController = nil
                            self.openRequestID = nil; self.openTask = nil
                            self.openingPlaylistRequest = nil
                            self.openingApplicationRequest = nil
                            self.openingApplicationPlaylistRequest = nil
                            self.requestedConfiguration = nil; self.requestedImport = nil; self.failedProjectLoad = nil
                            if imported != nil { self.library?.importedProjectDidCommit(readyURL) }
                            self.updateLibraryLoadFailure()
                            self.library?.updateProjectLoading(false)
                            if !ruleRequest {
                                if hotkeyContent?.playlist != nil {
                                    if let initialEntry { initialPlaylist?.complete(initialEntry, succeeded: true, now: ProcessInfo.processInfo.systemUptime) }
                                    self.playlistPlayback = initialPlaylist
                                }
                                if let preparedProfile {
                                    self.playlistPlayback = preparedProfile.playlist.map { NativePlaylistPlayback(list: $0, now: ProcessInfo.processInfo.systemUptime) }
                                }
                                if let playlistRequest { self.playlistPlayback?.complete(playlistRequest, succeeded: true, now: ProcessInfo.processInfo.systemUptime) }
                                else if !automaticUpdate, hotkeyContent?.playlist == nil { self.playlistPlayback?.manualSelection(key: NativePlaylistLibrary.key(for: readyURL), now: ProcessInfo.processInfo.systemUptime, starting: startingPlaylist) }
                                if self.playlistPlayback != nil || preparedProfile != nil { NativePlaylistProgressStore.save(self.playlistPlayback) }
                            } else { self.playlistPlayback?.cancelPending(now: ProcessInfo.processInfo.systemUptime) }
                            if preparedProfile != nil || hotkeyContent?.playlist != nil { self.library?.reloadPlaylist() }
                            didCommit = true
                            profileRequest?.result = .success(())
                        }
                        // The request is already committed. A newer request may start
                        // before this continuation resumes; it must not retire this
                        // live wallpaper while its replacement is still preparing.
                        if !isTerminating, controller === candidate {
                            candidate.enableAudioOutput()
                            if let retiringID {
                                candidate.fadeIn(duration: fade) { [weak self] in self?.retiringPlaylists.removeValue(forKey: retiringID)?.stop() }
                            } else { candidate.setPresentationOpacity(1) }
                            NSApp.setActivationPolicy(guiSession || mode == .preview ? .regular : .accessory)
                            updatePlaybackMenu()
                            updateLibraryCurrentProject()
                            if openRequestID == nil { updateStatus(candidate.playbackSummary) }
                        }
                        projectLoadLog.notice("Project load committed")
                        break
                    } catch {
                        // Initial selection tries each unavailable entry without
                        // replacing the old desktop. A fixed preparation timestamp
                        // prevents slow failures from expiring this attempt's backoff.
                        if !didCommit, !(error is CancellationError), !Task.isCancelled,
                           let applicationRequest, applicationSelection.canCommit(applicationRequest),
                           openRequestID == requestID, let failedEntry = initialEntry {
                            initialPlaylist?.complete(failedEntry, succeeded: false, now: preparationTime)
                            if let following = initialPlaylist?.initial(now: preparationTime, date: Date()) {
                                next?.stop(); if pendingController === next { pendingController = nil }
                                next = nil; initialEntry = following
                                continue
                            }
                        }
                        throw error
                    }
                }
            } catch is CancellationError {
                if let applicationRequest, !didCommit, self.applicationSelection.canCommit(applicationRequest) {
                    _ = self.applicationSelection.observe(self.applicationSelection.observed, snapshot: nil, canBegin: false)
                }
                if let playlistRequest, !didCommit { self.playlistPlayback?.complete(playlistRequest, succeeded: false, now: ProcessInfo.processInfo.systemUptime) }
                if let temporaryPlaylistRequest, !didCommit, self.applicationPlaylistPlayback?.pending?.id == temporaryPlaylistRequest.id {
                    self.applicationPlaylistPlayback?.cancelPending(now: ProcessInfo.processInfo.systemUptime)
                }
                projectLoadLog.notice("Project load cancelled; task cancellation: \(Task.isCancelled, privacy: .public)")
                if !didCommit { next?.stop() }
                if pendingController === next { pendingController = nil }
                if openRequestID == requestID { updateStatus("加载已取消，桌面保持当前壁纸。") }
            }
            catch {
                if !didCommit { profileRequest?.result = .failure(error) }
                if let applicationRequest, !didCommit { self.applicationSelection.fail(applicationRequest) }
                if let playlistRequest, !didCommit { self.playlistPlayback?.complete(playlistRequest, succeeded: false, now: ProcessInfo.processInfo.systemUptime) }
                if let temporaryPlaylistRequest, !didCommit { self.applicationPlaylistPlayback?.complete(temporaryPlaylistRequest, succeeded: false, now: ProcessInfo.processInfo.systemUptime) }
                projectLoadLog.error("Project load failed: \(String(reflecting: type(of: error)), privacy: .public)")
                if !didCommit { next?.stop() }
                if pendingController === next { pendingController = nil }
                if !isTerminating, !Task.isCancelled, openRequestID == requestID {
                    if profileRequest != nil {
                        updateStatus("配置文件未应用，保留当前壁纸：" + error.localizedDescription)
                    } else if applicationRequest != nil {
                        failedProjectLoad = .init(request: requestedConfiguration, applicationRule: true, message: error.localizedDescription)
                        updateLibraryLoadFailure(); updateStatus("应用程序规则切换失败，保留当前壁纸。")
                    } else if let entry = temporaryPlaylistRequest ?? playlistRequest { updateStatus("播放列表暂时跳过“\(entry.entry.wallpaper.title)”：" + error.localizedDescription) }
                    else { reportFailure(error) }
                }
            }
        }
        openTask = task; pendingOpenTasks[requestID] = task
    }

    private func configureCallbacks(_ candidate: WallpaperController, requestID: UUID? = nil) {
        candidate.willApplyProperties = { [weak self] project in
            guard let self, !self.isFinishingBrowser || self.acceptingBrowser else { throw CancellationError() }
            try self.browserSession?.snapshot.capture(project)
        }
        candidate.statusChanged = { [weak self, weak candidate] title in
            guard let self, !isTerminating, let candidate else { return }
            if requestID != nil, openRequestID == requestID { updateStatus("正在加载新壁纸：" + title) }
            else if openRequestID == nil, controller === candidate { updateStatus(title) }
        }
        candidate.reloadFailed = { [weak self, weak candidate] error in
            guard let self, !isTerminating, let candidate, controller === candidate else { return }
            showReloadError(error)
        }
        candidate.projectDidLoad = { [weak self, weak candidate] in
            guard let self, !isTerminating, let candidate, controller === candidate else { return }
            propertyEditor?.close(); propertyEditor = nil
            updateLibraryCurrentProject()
        }
        candidate.defaultVideoDidEnd = { [weak self, weak candidate] in
            guard let self, let candidate, controller === candidate else { return }
            if !applicationPlaylistIsSuspended {
                if let request = applicationPlaylistPlayback?.videoEnded(now: ProcessInfo.processInfo.systemUptime, paused: candidate.defaultPlaylistPaused) { openApplicationPlaylistRequest(request) }
            } else if !playlistIsSuspended,
                      let request = playlistPlayback?.videoEnded(now: ProcessInfo.processInfo.systemUptime, paused: candidate.defaultPlaylistPaused) { openPlaylistRequest(request) }
        }
        candidate.displayVideoDidEnd = { [weak self, weak candidate] key in
            guard let self, let candidate, controller === candidate else { return }
            self.requestNextDisplayPlaylist(key, videoEnded: true)
        }
    }

    private func cancelProjectLoad(report: Bool = true, cancelPlaylist: Bool = true, cancelApplicationSelection: Bool = true) {
        if cancelApplicationSelection, let request = openingApplicationRequest {
            if report { applicationSelection.fail(request) }
            else { _ = applicationSelection.observe(applicationSelection.observed, snapshot: nil, canBegin: false) }
        }
        openingApplicationRequest = nil
        if openingApplicationPlaylistRequest != nil { applicationPlaylistPlayback?.cancelPending(now: ProcessInfo.processInfo.systemUptime) }
        openingApplicationPlaylistRequest = nil
        if cancelPlaylist { playlistPlayback?.cancelPending(now: ProcessInfo.processInfo.systemUptime) }
        openingPlaylistRequest = nil
        let wasLoading = openRequestID != nil
        openRequestID = nil
        requestedConfiguration = nil
        requestedImport = nil
        openTask?.cancel(); openTask = nil
        pendingController?.stop(); pendingController = nil
        library?.updateProjectLoading(false)
        if report, wasLoading { updateStatus("加载已取消，桌面保持当前壁纸。") }
    }

    private func finishBrowser(accepted: Bool) async throws {
        guard !isTerminating, !isFinishingBrowser else { throw CancellationError() }
        let pendingRule = openingApplicationRequest != nil || openingApplicationPlaylistRequest != nil ? openTask : nil
        isFinishingBrowser = true; acceptingBrowser = accepted
        reconcileApplicationSelection()
        defer { isFinishingBrowser = false; acceptingBrowser = false; reconcileApplicationSelection() }
        await pendingRule?.value
        if accepted {
            await library?.finishInlinePropertyEditing()?.value
            try Task.checkCancellation()
            guard !isTerminating else { throw CancellationError() }
            library?.cancelInlinePropertyEditing()
            browserSession?.snapshot.finishMediaTransaction()
            browserSession = nil
            return
        }
        guard let session = browserSession else { return }
        finishPlaylistTransitions()
        workshop.beginSelection()
        let opening = Array(pendingOpenTasks.values)
        cancelProjectLoad(report: false)
        monitorSelection?.close()
        let displayMaintenanceTask = displayContentMaintenanceTask
        displayMaintenanceTask?.cancel()
        cancelDisplayContentTransactions()
        let displayContentTask = displayContentActiveTask
        let inline = library?.cancelInlinePropertyEditing()
        let properties = propertyEditor?.cancelPendingApply(); propertyEditor = nil
        let display = displaySettings?.cancelPendingApply()
        displaySettings?.close(); displayPicker?.close(); displayPicker = nil
        playbackSettings?.close(); openURLController?.close()
        await inline?.value; await properties?.value; await display?.value; await displayContentTask?.value
        _ = try? await displayMaintenanceTask?.value
        for task in opening { await task.value }
        try Task.checkCancellation()
        guard !isTerminating else { throw CancellationError() }
        func restorableDisplayContents() -> [String: DisplayContentContext] {
            var result = session.displayContents.filter { session.snapshot.canRestoreSessionTarget($0.key) }
            // A new topology generation may already own a context for a
            // session key which was invalid in the Browser snapshot.
            // Cancelling the old Browser must not wipe that newer context.
            for (key, context) in displayContentContexts where !session.snapshot.canRestoreSessionTarget(key) {
                result[key] = context
            }
            return result
        }
        var restoredDisplayContents = restorableDisplayContents()
        let unchanged = configuration?.projectURL == session.configuration?.projectURL &&
            configuration?.mode == session.configuration?.mode &&
            (controller?.isApplicationRuleOverride ?? false) == (session.applicationSelection.current != nil) &&
            applicationProfile == session.applicationProfile &&
            applicationProfileTarget == session.applicationProfileTarget &&
            displayContentContexts == restoredDisplayContents &&
            (session.configuration == nil || controller?.currentProject != nil) &&
            session.snapshot.restorableProperties.isEmpty && NativeDisplayStore.load() == session.snapshot.restorableDisplayLayout
        if unchanged || session.configuration == nil {
            try session.snapshot.restore()
            if session.configuration == nil { controller?.stop(); controller = nil; configuration = nil }
            else if session.paused { controller?.pause() } else { controller?.resume() }
        } else if let original = session.configuration {
            // A Browser Cancel may yield while a replacement renderer is being
            // prepared.  If a session display vanishes during that await, all
            // values assembled before it are stale—even when macOS reconnects
            // another monitor under the same `session:` key.  Rebuild from
            // the snapshot's current filtered views, never settle the old
            // candidate/context collection.
            var restored = false
            for attempt in 0..<3 {
                let restoreGeneration = session.snapshot.restorationGeneration
                let restoreProperties = session.snapshot.restorableProperties
                let restoreContents = restorableDisplayContents()
                let profileLayout = session.applicationProfile?.layout ?? session.snapshot.restorableDisplayLayout
                let baseLayout = session.snapshot.restorableDisplayLayout(profileLayout)
                let presentationLayout = layout(baseLayout, overlaying: restoreContents)
                let strictKeys = Set((session.applicationProfile?.layout.displays.keys.map { $0 } ?? []).filter {
                    session.snapshot.canRestoreSessionTarget($0)
                })
                let candidate = WallpaperController(configuration: original, initiallyPaused: session.paused, audioOutputAllowed: false,
                    applicationRuleOverride: session.applicationSelection.current != nil,
                    applicationRuleUsesFullLayout: session.applicationProfile != nil)
                configureCallbacks(candidate)
                pendingController = candidate
                if systemIsSleeping { candidate.suspendForSystemSleep() }
                if displaysAreSleeping { candidate.suspendForDisplaySleep() }
                if sessionIsInactive { candidate.suspendForInactiveSession() }
                candidate.updatePlaybackPolicy(playbackPolicy.environment)
                library?.updateStatus("正在恢复打开壁纸库时的配置…")
                do {
                    try await candidate.start(layout: presentationLayout,
                        strictKeys: strictKeys,
                        propertySnapshots: restoreProperties) { [self] in
                        try Task.checkCancellation()
                        guard !isTerminating, isFinishingBrowser,
                              session.snapshot.isRestorationCurrent(restoreGeneration) else {
                            throw CancellationError()
                        }
                        try session.snapshot.restore()
                        // `restore()` is synchronous, but keep this second
                        // predicate at the ownership boundary: an externally
                        // driven commit hook must never hand off after its
                        // Browser snapshot generation was invalidated.
                        guard session.snapshot.isRestorationCurrent(restoreGeneration) else {
                            throw CancellationError()
                        }
                        controller?.stop(); controller = candidate; configuration = original
                        pendingController = nil
                    }
                    candidate.enableAudioOutput()
                    // Do not carry contexts read before candidate.start's
                    // await into the final settled state.
                    restoredDisplayContents = restorableDisplayContents()
                    restored = true
                    break
                } catch {
                    candidate.stop()
                    if pendingController === candidate { pendingController = nil }
                    if !session.snapshot.isRestorationCurrent(restoreGeneration), attempt < 2 {
                        continue
                    }
                    updateLibraryCurrentProject()
                    throw error
                }
            }
            guard restored else { throw CancellationError() }
        }
        failedProjectLoad = nil
        // Restore (if needed) and the candidate handoff have both succeeded.
        // Now old Browser-retention pins can be released and the fail-closed
        // all-scope inventory may reclaim abandoned replacement grants.
        session.snapshot.finishMediaTransaction()
        browserSession = nil
        applicationSelection = session.applicationSelection
        playlistPlayback = session.playlist
        applicationPlaylistPlayback = session.applicationPlaylist
        displayContentContexts = settledDisplayContents(restoredDisplayContents)
        applicationProfile = session.applicationProfile
        applicationProfileTarget = session.applicationProfileTarget
        applicationPlaylistPlayback?.cancelPending(now: ProcessInfo.processInfo.systemUptime)
        playlistPlayback?.cancelPending(now: ProcessInfo.processInfo.systemUptime)
        library?.reloadPlaylist()
        playbackPolicy.reloadPreferences()
        if let original = applicationSelection.original { workshop.track(project: original.configuration.projectURL) }
        else if let project = controller?.currentProject { workshop.track(project: project.projectURL) }
        updateLibraryLoadFailure(); updateLibraryCurrentProject(); updatePlaybackMenu()
        updateStatus(controller?.playbackSummary ?? "尚未打开壁纸")
    }

    @objc private func presentLibrary(_ sender: Any?) {
        guard !isTerminating, !isFinishingBrowser else { return }
        // An aborted seasonal modal remains suppressed only for this Browser
        // session. Re-presenting the same Library window must not clear that
        // in-memory guard and immediately show the sheet again.
        let startsBrowserSession = browserSession == nil
        if browserSession == nil {
            if openingApplicationRequest != nil || openingApplicationPlaylistRequest != nil { cancelProjectLoad(report: false, cancelPlaylist: false) }
            browserSession = BrowserSession(configuration: configuration,
                paused: controller?.isPaused ?? configuration.map { NativeManualPlaybackStore.isPaused(for: $0.projectURL) } ?? false,
                snapshot: NativeBrowserSession(), playlist: playlistPlayback, applicationPlaylist: applicationPlaylistPlayback,
                displayContents: displayContentContexts,
                applicationProfile: applicationProfile, applicationProfileTarget: applicationProfileTarget,
                applicationSelection: applicationSelection)
        }
        guiSession = true; NSApp.setActivationPolicy(.regular)
        if library == nil {
            let created = LibraryController()
            created.onFinish = { [weak self] accepted in try await self?.finishBrowser(accepted: accepted) }
            created.onSelect = { [weak self] url in self?.openProject(url, mode: .desktop) }
            created.onPlaylistChange = { [weak self] value in try self?.changePlaylist(value) }
            created.onPlaylistSelect = { [weak self] entry in self?.openProject(URL(fileURLWithPath: entry.wallpaper.projectPath), mode: .desktop, playlistWallpaper: entry.wallpaper) }
            created.onSelectForTarget = { [weak self] url, key in
                guard let self, let target = try? NativeDisplayTarget(location: key) else { return }
                if target == .defaultWallpaper { self.openProject(url, mode: .desktop) }
                else { self.openProject(url, on: target) }
            }
            created.onPlaylistChangeForTarget = { [weak self] value, key in
                guard let self else { throw CancellationError() }
                let target = try NativeDisplayTarget(location: key)
                if target == .defaultWallpaper { try self.changePlaylist(value) }
                else { try self.changePlaylist(value, on: target) }
            }
            created.onPlaylistSelectForTarget = { [weak self] entry, key in
                guard let self, let target = try? NativeDisplayTarget(location: key) else { return }
                let url = (try? NativePlaylistLibrary.resolve(entry.wallpaper)) ?? URL(fileURLWithPath: entry.wallpaper.projectPath)
                if target == .defaultWallpaper {
                    self.openProject(url, mode: .desktop, playlistWallpaper: entry.wallpaper)
                } else {
                    self.openProject(url, on: target)
                }
            }
            created.onDisplaysForTarget = { [weak self] key in self?.presentMonitorSelection(selectedKey: key) }
            created.onDownload = { [weak self] in self?.workshop.enterItem() }
            created.onBrowse = { [weak self] request, completion in
                guard let self else { completion(nil, "查询服务不可用"); return }
                self.workshop.browse(request, completion: completion)
            }
            created.onSyncSubscriptions = { [weak self] in self?.workshop.requestSubscriptionCheck() }
            created.onDownloadSubscription = { [weak self] id in self?.workshop.downloadAndOpen(id) }
            // This is the sole host path for the account-writing Steam verb.
            // The browser reaches it only after an explicit subscribe or
            // unsubscribe action; WorkshopCoordinator holds the UI callback
            // until the same-account post-write subscription snapshot has
            // converged.
            created.onSubscriptionChange = { [weak self] id, subscribed, completion in
                guard let self else {
                    completion(.unconfirmed("steam-subscription-host-unavailable: 应用宿主已释放；订阅状态未确认，请刷新后再决定是否重试。"))
                    return
                }
                self.workshop.requestSubscriptionChange(id: id, subscribed: subscribed, completion: completion)
            }
            // Favorites use the same account-mutation coordinator queue as
            // subscribe/unsubscribe. The coordinator invokes completion only
            // after the exact Steam callback and a fresh same-account list
            // snapshot have both converged.
            created.onFavoriteChange = { [weak self] id, favorited, completion in
                guard let self else {
                    completion(.unconfirmed("steam-favorite-host-unavailable: 应用宿主已释放；收藏状态未确认，请刷新后再决定是否重试。"))
                    return
                }
                self.workshop.requestFavoriteChange(id: id, favorited: favorited, completion: completion)
            }
            // The browser passes only canonical IDs and an opaque selected
            // detail generation.  Coordinator replies include the same
            // generation, account/session-fenced, so the browser can ignore
            // a late completion after a page or selection transition.
            created.onUserVoteRefresh = { [weak self] id, selectionGeneration, completion in
                guard let self else {
                    completion(.unconfirmed("steam-vote-get-host-unavailable: 应用宿主已释放；个人投票读取未确认。"))
                    return
                }
                self.workshop.requestUserVoteRefresh(id: id, selectionGeneration: selectionGeneration, completion: completion)
            }
            created.onUserVoteChange = { [weak self] id, direction, selectionGeneration, completion in
                guard let self else {
                    completion(.unconfirmed("steam-vote-set-host-unavailable: 应用宿主已释放；个人投票请求结果未确认，不会自动重试。"))
                    return
                }
                self.workshop.requestUserVoteChange(id: id, direction: direction,
                                                     selectionGeneration: selectionGeneration, completion: completion)
            }
            created.onShowTransfers = { [weak self] in self?.showTransfers(nil) }
            created.onCreate = { [weak self] in self?.showEditor(nil) }
            created.onEdit = { [weak self] url in self?.presentEditor(project: url) }
            created.onPreview = { [weak self] url in self?.previewSelection(url) }
            created.onCancelPreview = { [weak self] in self?.cancelSelectionPreview() }
            created.onCancelProjectLoad = { [weak self] in self?.cancelProjectLoad() }
            created.onRetryProjectLoad = { [weak self] in self?.retryFailedProject() }
            created.onOpenLocal = { [weak self] in self?.chooseOfflineWallpaper() }
            created.onOpenStatic = { [weak self] in self?.chooseStaticWallpaper() }
            created.onOpenURL = { [weak self] in self?.chooseWallpaperURL() }
            created.onTogglePlayback = { [weak self] in
                guard let self, self.controller != nil else { return }
                if self.controller?.isPaused == true { self.resume(nil) } else { self.pause(nil) }
            }
            created.onProperties = { [weak self] in self?.showProperties(nil) }
            created.onApplyPropertiesForTarget = { [weak self] url, target, values, media in
                guard let self, let active = self.controller,
                      self.libraryDisplayTarget == target,
                      let current = self.libraryCurrentProject(), current.projectURL == url,
                      current.propertyTarget == target else {
                    throw PropertyError.invalid("壁纸已切换，请在当前壁纸的属性中调整。")
                }
                let result = try await active.applyPropertyValues(values, mediaSelections: media,
                                                                    target: target, projectURL: url)
                guard self.controller === active, self.libraryDisplayTarget == target else { throw CancellationError() }
                self.library?.setPropertyProject(self.libraryCurrentProject(), target: target)
                return result
            }
            created.onDisplays = { [weak self] in self?.showDisplays(nil) }
            created.onPlaybackSettings = { [weak self] in self?.showPlaybackSettings(nil) }
            created.onCompatibility = { [weak self] in self?.showCompatibility(nil) }
            created.updateSteamConnection(workshop.connectionDescription)
            created.updateSubscriptions(workshop.subscriptions)
            created.updateFavorites(workshop.favoriteIDs)
            library = created
        }
        updateLibraryCurrentProject()
        updateLibraryPlayback()
        library?.updateProjectLoading(openRequestID != nil)
        updateLibraryLoadFailure()
        library?.present()
        // Browser options are initialized after the real Library is visible.
        // Defer one run-loop turn so a just-ended sheet cannot overlap this
        // official informational modal. No prompt state is written if the
        // eligibility gate is false.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if startsBrowserSession { self.seasonalThemePromptCoordinator.beginLibraryPresentationSession() }
            else { self.seasonalThemePromptCoordinator.requestPresentationIfEligible() }
        }
    }

    private var seasonalThemePromptPresentationAllowed: Bool {
        guard !isTerminating, let library, library.window?.isVisible == true,
              library.window?.attachedSheet == nil,
              playbackSettings?.window?.isVisible != true,
              NSApp.modalWindow == nil else { return false }
        return true
    }

    private func updateLibraryLoadFailure() {
        let message = failedProjectLoad.map { failure in
            if failure.applicationRule { return "应用程序规则切换失败，当前画面已保留。\n" + failure.message }
            let name = failure.importRequest?.title ?? failure.request?.projectURL.deletingLastPathComponent().lastPathComponent
            return "无法加载壁纸" + (name.map { "：" + String($0.prefix(128)) } ?? "") + "\n" + failure.message
        }
        library?.updateLoadFailure(message, retryable: (failedProjectLoad?.request != nil || failedProjectLoad?.applicationRule == true) && !isTerminating)
    }
    private func retryFailedProject() {
        guard !isTerminating, openRequestID == nil else { return }
        if failedProjectLoad?.applicationRule == true {
            failedProjectLoad = nil; applicationSelection.retry(); updateLibraryLoadFailure(); reconcileApplicationSelection(); return
        }
        guard let request = failedProjectLoad?.request else { return }
        openProject(request.projectURL, mode: request.mode, retryingFailure: true, importing: failedProjectLoad?.importRequest)
    }

    private func updateLibraryPlayback() {
        library?.updatePlayback(available: controller?.currentProject != nil, paused: controller?.isPaused ?? false,
                                status: controller?.playbackSummary ?? "尚未打开壁纸")
    }

    /// A selected-row preview owns its own renderer and never commits
    /// lastProject, display assignments, Steam selection or desktop ownership.
    private func previewSelection(_ url: URL) {
        guard !isTerminating else { return }
        selectionPreviewTask?.cancel(); selectionPreview?.stop()
        let candidate = WallpaperController(configuration: LaunchConfiguration(projectURL: url, mode: .preview), audioOutputAllowed: false)
        candidate.previewIsIndependent = true
        selectionPreview = candidate
        candidate.previewClosed = { [weak self, weak candidate] in
            guard let self, self.selectionPreview === candidate else { return }
            self.selectionPreviewTask?.cancel(); self.selectionPreviewTask = nil
            candidate?.stop(); self.selectionPreview = nil
            self.library?.updateLivePreview(loading: false, message: "预览已关闭，桌面保持当前壁纸。")
        }
        candidate.reloadFailed = { [weak self] error in self?.library?.updateLivePreview(loading: false, message: "预览重新加载失败：" + error.localizedDescription) }
        candidate.updatePlaybackPolicy(playbackPolicy.environment)
        if systemIsSleeping { candidate.suspendForSystemSleep() }
        if displaysAreSleeping { candidate.suspendForDisplaySleep() }
        if sessionIsInactive { candidate.suspendForInactiveSession() }
        library?.updateLivePreview(loading: true, message: "正在准备独立预览，桌面保持当前壁纸。")
        let requestID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { pendingPreviewTasks.removeValue(forKey: requestID) }
            do {
                try await candidate.start(); try Task.checkCancellation()
                guard selectionPreview === candidate else { candidate.stop(); return }
                let sound = candidate.currentProject?.kind == .web ? "网页预览保留作品声音" : "静音预览"
                library?.updateLivePreview(loading: false, message: "\(sound)：\(candidate.currentProject?.title ?? "壁纸")。关闭预览窗口即可结束。")
                NSApp.activate(ignoringOtherApps: true)
            } catch {
                candidate.stop()
                if selectionPreview === candidate {
                    selectionPreview = nil
                    library?.updateLivePreview(loading: false, message: error is CancellationError ? "预览已取消。" : "预览失败：" + error.localizedDescription)
                }
            }
            if selectionPreview === candidate || selectionPreview == nil { selectionPreviewTask = nil }
        }
        selectionPreviewTask = task; pendingPreviewTasks[requestID] = task
    }

    private func cancelSelectionPreview() {
        guard selectionPreviewTask != nil else { return }
        selectionPreviewTask?.cancel(); selectionPreviewTask = nil
        selectionPreview?.stop(); selectionPreview = nil
        library?.updateLivePreview(loading: false, message: "预览已取消，桌面保持当前壁纸。")
    }

    private func libraryCurrentProject() -> WallpaperProject? {
        switch libraryDisplayTarget {
        case .defaultWallpaper: return controller?.currentProject
        case .display(let key): return controller?.projectForDisplay(key)
        }
    }

    private func updateLibraryCurrentProject() {
        let project = libraryCurrentProject()
        library?.setPropertyProject(project, target: libraryDisplayTarget)
        library?.setCurrentProject(project?.projectURL, title: project?.title, type: project?.kind.rawValue, desktop: configuration?.mode == .desktop)
    }

    private func displayTargetTitle(_ target: NativeDisplayTarget) -> String {
        switch target {
        case .defaultWallpaper: return "默认壁纸"
        case .display(let key):
            if let index = NativeDisplayDescriptor.connected().firstIndex(where: { $0.key == key }) {
                return "\(index + 1) · \(NativeDisplayDescriptor.connected()[index].name)"
            }
            return "未连接的显示器"
        }
    }

    private func selectLibraryDisplayTarget(_ key: String) {
        do {
            let target = try NativeDisplayTarget(location: key)
            propertyEditor?.close(); propertyEditor = nil
            libraryDisplayTarget = target
            try library?.setDisplayTarget(target, title: displayTargetTitle(target))
            updateLibraryCurrentProject(); library?.reloadPlaylist()
        } catch { updateStatus(error.localizedDescription) }
    }

    private func presentMonitorSelection(selectedKey: String?) {
        guard let window = library?.window else { return }
        if monitorSelection == nil {
            let picker = NativeMonitorSelectionController()
            picker.onSelectTarget = { [weak self] key in self?.selectLibraryDisplayTarget(key) }
            picker.onRemoveTarget = { [weak self] key in
                guard let self else { throw CancellationError() }
                try await self.removeDisplayContentTarget(key)
                // Removing content does not change the selected monitor.
                // A subsequent wallpaper choice must re-enable this screen,
                // not unexpectedly replace the default desktop instead.
                self.selectLibraryDisplayTarget(key)
            }
            picker.onShowProfiles = { [weak self, weak picker] saving in
                guard let self else { return }
                // The overlay owns a complete display-layout action.  Close
                // it before presenting the matching load/save sheet, while
                // leaving the library's selected screen context untouched.
                picker?.close()
                self.showDisplays(nil)
                let temporaryLayout: NativeDisplayLayout?
                if let profile = self.applicationProfile,
                   self.applicationSelection.current?.action == .loadprofile {
                    temporaryLayout = self.profilePresentationLayout(profile.layout)
                } else {
                    temporaryLayout = nil
                }
                self.displaySettings?.presentProfiles(saving: saving, initialLayout: temporaryLayout)
            }
            monitorSelection = picker
        }
        monitorSelection?.present(on: window, selectedKey: selectedKey ?? libraryDisplayTarget.key)
    }

    @objc private func presentWorkshop(_ sender: Any?) {
        presentLibrary(sender)
        library?.showWorkshop()
    }

    @objc private func presentWelcome(_ sender: Any?) { presentWelcome(automatic: false) }

    private func presentWelcome(automatic: Bool) {
        let controller = welcomePresentation.controllerForPresentation {
            let controller = NativeWelcomeController(
                preferences: { [weak self] in self?.playbackPolicy.environment.preferences ?? NativePlaybackPreferences.load() },
                applyPreferences: { [weak self] value in self?.playbackPolicy.updatePreferences(value) },
                loginState: { SMAppService.mainApp.status },
                requestLoginItemChange: { [weak self] in self?.toggleLoginItem(nil) },
                automatic: automatic)
            controller.onFinish = { [weak self] browse in
                guard browse else { return }
                self?.presentLibrary(nil)
            }
            return controller
        }
        controller.present()
    }

    @objc private func chooseProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "选择壁纸项目文件夹"
        panel.message = "请选择包含 project.json 及素材的完整文件夹。应用需要读取项目内的图片、材质或视频。"
        panel.canChooseDirectories = true
        // A file selection does not grant access to its parent or siblings.
        // Scene indexing needs the whole project; opening an ungranted parent
        // can leave Foundation directory enumeration blocked on macOS.
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        projectLoadLog.notice("Project picker response: \(response.rawValue, privacy: .public); has selection: \(panel.url != nil, privacy: .public)")
        if response == .OK, let selected = panel.url {
            openProject(selected.appendingPathComponent("project.json"), mode: .desktop)
        }
    }

    private func chooseOfflineWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "打开离线壁纸（动态）"
        panel.message = "选择视频，或包含 project.json 和全部素材的壁纸文件夹。"
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        if (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            openProject(selected.appendingPathComponent("project.json"), mode: .desktop)
        } else { openProject(selected, mode: .desktop, importing: .video(selected)) }
    }
    private func chooseStaticWallpaper() {
        let panel = NSOpenPanel()
        panel.title = "打开背景图片（静态）"
        panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .heif, .tiff, .bmp]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        openProject(selected, mode: .desktop, importing: .image(selected))
    }
    private func chooseWallpaperURL() {
        if openURLController == nil {
            let dialog = NativeOpenURLController()
            dialog.onOpen = { [weak self] url, name in self?.openProject(url, mode: .desktop, importing: .web(url, name: name)) }
            openURLController = dialog
        }
        openURLController?.present()
    }

    @objc private func screenParametersChanged() {
        displaySettings?.refreshConnections()
        guard !isTerminating else { return }
        // The controller also detects a changed topology, but invalidate the
        // per-display epoch first: a fully prepared candidate must not publish
        // its old screen geometry after a hot-plug/reorder notification.
        let connected = Set(NativeDisplayDescriptor.connected().map(\.key))
        let connectedSessionKeys = Set(connected.filter { $0.hasPrefix("session:") })
        // A topology cycle that macOS never reports as absent cannot be
        // distinguished from a continuous connection.  For every reported
        // absence, however, retain the loss as a generation boundary before
        // replacing this observation with the newly connected set.
        let disconnected = lastObservedSessionKeys.map { $0.subtracting(connectedSessionKeys) } ?? []
        lastObservedSessionKeys = connectedSessionKeys
        browserSession?.snapshot.invalidateDisconnectedSessions(connectedSessionKeys: connected)
        let gone = Set(displayContentContexts.keys).subtracting(connected)
        let vanishedSessions = Set(gone.filter { $0.hasPrefix("session:") })
        let staleDisplaySessions = NativeDisplayStore.discardDisconnectedSessionTargets(connectedSessionKeys: connected)
        let stalePlaylistSessions = NativePlaylistStore.discardDisconnectedSessionTargets(connectedSessionKeys: connected)
        let staleProgressSessions = NativePlaylistProgressStore.discardDisconnectedSessionTargets(connectedSessionKeys: connected)
        // Property storage is keyed by project identity *and* target.  Clear
        // every process-local project record for the observed session target,
        // not just the project currently visible on that display.
        let stalePropertySessions = WallpaperPropertyStore.discardDisconnectedSessionTargets(disconnected)
        // Do this before recovery scheduling.  Pending controllers may still
        // be awaiting resource preparation and have no display-content
        // context, layout entry, or window yet; their topology generation is
        // nevertheless invalidated by the observed loss.
        let controllerLost = controller?.observeDisconnectedSessionTargets(disconnected) ?? []
        let pendingLost = pendingController?.observeDisconnectedSessionTargets(disconnected) ?? []
        // A zero-duration playlist transition can retain the outgoing
        // controller during its fade.  It owns real windows too, so it must
        // receive the same immediate generation barrier instead of waiting for
        // its eventual retirement cleanup.
        retiringPlaylists.values.forEach { _ = $0.observeDisconnectedSessionTargets(disconnected) }
        let staleSessions = disconnected
            .union(vanishedSessions)
            .union(staleDisplaySessions)
            .union(stalePlaylistSessions)
            .union(staleProgressSessions)
            .union(stalePropertySessions)
            .union(controllerLost)
            .union(pendingLost)
        for key in staleSessions {
            // A session key may name a different monitor after the next
            // topology event.  Remove its purely in-memory scheduler instead
            // of allowing a later same-number screen to inherit it.
            try? NativePlaylistStore.setActive(.init(), target: key)
            NativePlaylistProgressStore.save(nil, target: key)
        }
        // UUID identities are stable across a disconnect/reconnect. Keep their
        // scheduler context (with a fresh epoch) so it can resume on the same
        // physical display, while dropping only volatile session identities.
        cancelDisplayContentTransactions(keys: staleSessions, removeContexts: true)
        cancelDisplayContentTransactions()
        controller?.requestDesktopRecovery(.displayConfiguration)
        pendingController?.requestDesktopRecovery(.displayConfiguration)
    }
    @objc private func importEngineResources(_ sender: Any?) {
        guard !isTerminating, builtinImportTask == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 Wallpaper Engine 内置纹理"
        panel.message = "选择官方 Wallpaper Engine APK。仅导入纹理数据，素材单独保存在本机。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateStatus("正在导入内置纹理…")
        let worker = Task.detached(priority: .utility) { try NativeBuiltinTextures.importArchive(url) }
        builtinImportTask = Task { [weak self] in
            guard let self else { worker.cancel(); _ = try? await worker.value; return }
            defer { builtinImportTask = nil }
            do {
                let receipt = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard !isTerminating else { return }
                fputs("Builtin texture import: \(receipt.textureCount) textures, \(receipt.textureBytes) bytes, \(receipt.archiveSHA256)\n", stderr)
                updateStatus("已导入 \(receipt.textureCount) 张内置纹理")
                controller?.reloadNow()
            } catch is CancellationError { }
            catch {
                guard !isTerminating else { return }
                updateStatus("内置纹理导入失败")
                let alert = NSAlert()
                alert.messageText = "无法导入内置纹理"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true); alert.runModal()
            }
        }
    }
    @objc private func importEngineFonts(_ sender: Any?) {
        guard !isTerminating, builtinImportTask == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 Wallpaper Engine 内置字体"
        panel.message = "选择已记录的官方 Wallpaper Engine APK。仅导入字体数据，不安装或运行 APK。"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updateStatus("正在导入内置字体…")
        let worker = Task.detached(priority: .utility) { try NativeBuiltinFonts.importArchive(url) }
        builtinImportTask = Task { [weak self] in
            guard let self else { worker.cancel(); _ = try? await worker.value; return }
            defer { builtinImportTask = nil }
            do {
                let receipt = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                try Task.checkCancellation()
                guard !isTerminating else { return }
                fputs("Builtin font import: \(receipt.fontCount) fonts, \(receipt.fontBytes) bytes, \(receipt.archiveSHA256)\n", stderr)
                updateStatus("已导入 \(receipt.fontCount) 个内置字体")
                controller?.reloadNow()
            } catch is CancellationError { }
            catch {
                guard !isTerminating else { return }
                updateStatus("内置字体导入失败")
                let alert = NSAlert()
                alert.messageText = "无法导入内置字体"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning; alert.addButton(withTitle: "好")
                NSApp.activate(ignoringOtherApps: true); alert.runModal()
            }
        }
    }
    @objc private func previewCurrentProject(_ sender: Any?) {
        guard let project = controller?.currentProject else { presentLibrary(nil); return }
        openProject(project.projectURL, mode: .preview)
        if configuration?.mode == .preview { NSApp.activate(ignoringOtherApps: true) }
    }
    @objc private func showCurrentProjectOnDesktop(_ sender: Any?) {
        guard let project = controller?.currentProject else { presentLibrary(nil); return }
        openProject(project.projectURL, mode: .desktop)
    }
    private func manualPause(for project: URL) -> Bool {
        if let controller, let configuration {
            return SavedWorkshopStore.settingsIdentity(configuration.projectURL) == SavedWorkshopStore.settingsIdentity(project) && controller.isPaused
        }
        return NativeManualPlaybackStore.isPaused(for: project)
    }
    private func saveManualPause() {
        guard let controller, let configuration else { return }
        let cancelled = applicationSelection.updateOriginal { $0.paused = controller.isPaused }
        if let cancelled, openRequestID == cancelled { cancelProjectLoad(report: false, cancelPlaylist: false, cancelApplicationSelection: false) }
        NativeManualPlaybackStore.save(project: applicationSelection.original?.configuration.projectURL ?? configuration.projectURL, paused: controller.isPaused)
        reconcileApplicationSelection()
    }
    @objc private func pause(_ sender: Any?) {
        guard !isFinishingBrowser else { return }
        controller?.pause(); saveManualPause(); updatePlaybackMenu()
    }
    @objc private func resume(_ sender: Any?) {
        guard !isFinishingBrowser else { return }
        controller?.resume(); saveManualPause(); updatePlaybackMenu()
    }
    @objc private func reload(_ sender: Any?) { if !isFinishingBrowser { controller?.reloadNow() } }
    @objc private func showProperties(_ sender: Any?) {
        guard let controller, let project = libraryCurrentProject() else { presentLibrary(nil); return }
        presentProperties(project, controller: controller, target: libraryDisplayTarget)
    }
    private func presentProperties(_ project: WallpaperProject, controller: WallpaperController, target: NativeDisplayTarget) {
        guard project.propertyTarget == target else {
            updateStatus("此显示器的壁纸仍在切换，请稍后重新打开设置。")
            return
        }
        propertyEditor?.close()
        let editor = WallpaperPropertiesController(project: project)
        let scope = project.propertyScope
        editor.onApply = { [weak self, weak controller] values, media in
            guard let self, let controller, self.controller === controller else {
                throw PropertyError.invalid("当前壁纸已经关闭。")
            }
            let live: WallpaperProject?
            switch target {
            case .defaultWallpaper: live = controller.currentProject
            case .display(let key): live = controller.projectForDisplay(key)
            }
            guard live?.projectURL == project.projectURL, live?.propertyScope == scope else {
                throw PropertyError.invalid("此显示器的壁纸已切换，请重新打开设置。")
            }
            let result = try await controller.applyPropertyValues(values, mediaSelections: media,
                                                                    target: target, projectURL: project.projectURL)
            guard self.controller === controller else { throw CancellationError() }
            let committed: WallpaperProject?
            switch target {
            case .defaultWallpaper: committed = controller.currentProject
            case .display(let key): committed = controller.projectForDisplay(key)
            }
            guard committed?.propertyScope == scope else { throw CancellationError() }
            if self.libraryDisplayTarget == target {
                self.library?.setPropertyProject(committed, target: target)
            }
            return result
        }
        propertyEditor = editor; editor.present()
    }
    @objc private func showCompatibility(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "当前壁纸兼容情况"
        var reports = [controller?.compatibilityReport ?? "请先打开一张壁纸。"]
        if let preview = selectionPreview {
            reports.append("独立预览（不改变默认桌面）：\n" + preview.compatibilityReport + "\n" + preview.playbackReport)
        }
        alert.informativeText = reports.joined(separator: "\n\n")
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func showPlaybackSettings(_ sender: Any?) {
        if playbackSettings == nil {
            playbackSettings = NativePlaybackSettingsController(monitor: playbackPolicy) { [weak self] in
                self?.controller?.playbackReport ?? "尚未打开壁纸。"
            }
        }
        playbackSettings?.present()
    }
    @objc private func showDisplays(_ sender: Any?) {
        if displaySettings == nil {
            let panel = NativeDisplaySettingsController()
            panel.defaultTitle = { [weak self] in self?.controller?.currentProject?.title ?? "尚未打开" }
            panel.runtimeReport = { [weak self] key in self?.controller?.displayStatus(key) ?? "请先从壁纸库打开一张默认壁纸。" }
            panel.canEditProperties = { [weak self] key in self?.controller?.projectForDisplay(key) != nil }
            panel.onCaptureProfile = { [weak self] layout in
                guard let self else { throw CancellationError() }
                return try await self.captureProfile(layout: layout)
            }
            panel.onLoadProfile = { [weak self] profile in
                guard let self else { throw CancellationError() }
                try await self.applyProfile(profile)
            }
            panel.onApply = { [weak self] layout in
                guard let self, !self.isTerminating, !self.isFinishingBrowser, let current = self.controller else { throw PropertyError.invalid("请先从壁纸库打开一张默认壁纸。") }
                if self.applicationProfile != nil, self.applicationSelection.current?.action == .loadprofile {
                    try await self.applyTemporaryProfileDisplayLayout(layout)
                    return
                }
                guard !self.displayContentMaintenanceInFlight else {
                    throw NativePlaylistError.invalid("正在应用另一项显示器设置，请稍候重试。")
                }
                self.displayContentMaintenanceInFlight = true
                self.applyingDisplayLayout = true
                defer {
                    self.displayContentMaintenanceInFlight = false
                    self.startNextDisplayContentJob()
                    self.applyingDisplayLayout = false
                    self.reconcileApplicationSelection()
                }
                self.cancelProjectLoad(report: false)
                self.cancelDisplayContentTransactions()
                let pendingDisplayContent = self.displayContentActiveTask
                await pendingDisplayContent?.value
                try Task.checkCancellation()
                self.workshop.beginSelection()
                try await current.applyDisplayLayout(layout)
                try Task.checkCancellation()
                guard self.controller === current else { throw CancellationError() }
                self.applicationSelection.updateOriginal { $0.layout = NativeDisplayStore.load() }
                self.updateLibraryCurrentProject()
            }
            panel.onChooseProject = { [weak self] completion in
                guard let self, !self.isTerminating else { return }
                self.displayPicker?.close()
                let picker = LibraryController(purpose: .displaySelection)
                picker.onChooseProject = { [weak self, weak picker] url, title in
                    guard let self, self.displayPicker === picker else { return }
                    picker?.close(); completion(url, title)
                    self.displayPicker = nil
                }
                let current = self.controller?.currentProject
                picker.setCurrentProject(current?.projectURL, title: current?.title, type: current?.kind.rawValue, desktop: true)
                self.displayPicker = picker; picker.present()
            }
            panel.onEditProperties = { [weak self] key in
                guard let self, let controller = self.controller, let project = controller.projectForDisplay(key) else { return }
                guard let target = try? NativeDisplayTarget(location: key) else { return }
                self.presentProperties(project, controller: controller, target: target)
            }
            displaySettings = panel
        }
        let temporaryProfileLayout: NativeDisplayLayout?
        if let profile = applicationProfile, applicationSelection.current?.action == .loadprofile {
            // Saved profiles deliberately omit volatile session displays. The
            // settings draft must still describe their current live content;
            // persistence strips them only at the manual-profile boundary.
            temporaryProfileLayout = profilePresentationLayout(profile.layout)
        } else {
            temporaryProfileLayout = nil
        }
        displaySettings?.present(initialLayout: temporaryProfileLayout)
    }
    private func captureProfile(layout: NativeDisplayLayout) async throws -> NativeWallpaperProfile {
        let profileRuleActive = applicationProfile != nil && applicationSelection.current?.action == .loadprofile
        guard !isTerminating, !isFinishingBrowser,
              let configuration = profileRuleActive ? configuration : applicationSelection.original?.configuration ?? configuration,
              configuration.mode == .desktop else { throw PropertyError.invalid("请先从壁纸库打开一张默认壁纸。") }
        let playlist: NativePlaylist?
        let displayPlaylists: [String: NativePlaylist]
        let name: String
        if profileRuleActive {
            playlist = applicationPlaylistPlayback?.list
            displayPlaylists = displayContentContexts.values.reduce(into: [:]) { result, context in
                guard context.target.persistent, let list = context.playback?.list else { return }
                result[context.target.key] = list
            }
            name = applicationProfile?.name ?? NativeProfileStore.currentName
        } else {
            let captured = try NativeProfileStore.capturableActivePlaylists()
            playlist = captured.playlist; displayPlaylists = captured.displayPlaylists
            name = NativeProfileStore.currentName
        }
        var profile = try await SavedWorkshopStore.perform {
            // A session display has no cross-launch identity.  Let the profile
            // validator report that fact to the user rather than silently
            // dropping this live screen from the saved composition.
            try NativeProfileLibrary.capture(project: configuration.projectURL, layout: layout,
                                             playlist: playlist, displayPlaylists: displayPlaylists)
        }
        try Task.checkCancellation(); profile.name = name
        return try profile.validated()
    }
    /// An explicit display edit during a temporary profile becomes a manual
    /// desktop selection. Capture it before any preference mutation, then use
    /// the normal profile transaction so candidate failure leaves the rule
    /// presentation untouched and success suppresses the unchanged rule.
    private func applyTemporaryProfileDisplayLayout(_ layout: NativeDisplayLayout) async throws {
        guard !isTerminating, !isFinishingBrowser, openRequestID == nil,
              let expectedProfile = applicationProfile, let expectedTarget = applicationProfileTarget,
              applicationSelection.current?.action == .loadprofile,
              applicationSelection.current?.file == expectedTarget.name,
              let active = configuration, active.mode == .desktop else {
            throw CancellationError()
        }
        let playlist = applicationPlaylistPlayback?.list
        let displayPlaylists: [String: NativePlaylist] = displayContentContexts.values.reduce(into: [:]) { result, context in
            guard context.target.persistent, let list = context.playback?.list else { return }
            result[context.target.key] = list
        }
        let catalog = applicationProfileCatalogFingerprint()
        var manual = try await SavedWorkshopStore.perform {
            // The same rule applies while a temporary profile is active: an
            // explicit edit must either preserve every selected screen in a
            // portable profile or fail without changing the temporary one.
            try NativeProfileLibrary.capture(project: active.projectURL, layout: layout,
                                             playlist: playlist, displayPlaylists: displayPlaylists)
        }
        try Task.checkCancellation()
        guard configuration?.projectURL == active.projectURL, applicationProfile == expectedProfile,
              applicationProfileTarget == expectedTarget, applicationProfileCatalogFingerprint() == catalog,
              applicationSelection.current?.action == .loadprofile,
              applicationSelection.current?.file == expectedTarget.name else { throw CancellationError() }
        // This is a changed manual desktop, not a write-through overwrite of
        // the selected saved profile. The empty current-name state tells Save
        // Profile to ask for a name again.
        manual.name = ""
        try await applyProfile(manual)
    }
    private func activateContentOrSystemHotkey(_ target: NativeHotkeyTarget, hotkey: NativeHotkey) {
        guard profileHotkeysMayApply else { return }
        do {
            guard try NativeHotkeyBindingStore.binding(for: target)?.hotkey == hotkey else { return }
            switch target {
            case .profile:
                // The compatibility callback below retains the full profile
                // preparation and final exact-name validation transaction.
                return
            case .system(let action):
                activateSystemHotkey(action)
            case .wallpaper(let item):
                let request = HotkeyContentRequest(target: target, hotkey: hotkey, playlist: nil)
                try validateHotkeyContent(request)
                let destination = try NativeDisplayTarget(location: item.location)
                let url = URL(fileURLWithPath: item.projectPath)
                if destination == .defaultWallpaper {
                    openProject(url, mode: .desktop, hotkeyContent: request)
                } else {
                    openProject(url, on: destination, validateBeforeCommit: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try self.validateHotkeyContent(request)
                    })
                }
            case .playlist(let name, let location):
                let list = try NativeApplicationPlaylistTarget.resolve(name)
                guard let first = list.entries.first else { throw NativePlaylistError.invalid("播放列表没有可播放的壁纸。") }
                let destination = try NativeDisplayTarget(location: location)
                if destination == .defaultWallpaper {
                    let request = HotkeyContentRequest(target: target, hotkey: hotkey, playlist: list)
                    try validateHotkeyContent(request)
                    openProject(URL(fileURLWithPath: first.wallpaper.projectPath), mode: .desktop, hotkeyContent: request)
                } else {
                    let request = HotkeyContentRequest(target: target, hotkey: hotkey, playlist: list)
                    try validateHotkeyContent(request)
                    activateDisplayPlaylist(list, target: destination, validateBeforeCommit: { [weak self] in
                        guard let self else { throw CancellationError() }
                        try self.validateHotkeyContent(request)
                        guard try NativeApplicationPlaylistTarget.resolve(name) == list else { throw CancellationError() }
                    })
                }
            }
        } catch {
            updateStatus("热键未应用，保留原桌面：" + error.localizedDescription)
        }
    }

    private func validateHotkeyContent(_ request: HotkeyContentRequest) throws {
        guard profileHotkeysMayApply, !playbackPolicy.environment.stopsDesktop,
              try NativeHotkeyBindingStore.binding(for: request.target)?.hotkey == request.hotkey else { throw CancellationError() }
        let destination: NativeDisplayTarget
        switch request.target {
        case .wallpaper(let item): destination = try NativeDisplayTarget(location: item.location)
        case .playlist(_, let location): destination = try NativeDisplayTarget(location: location)
        default: throw CancellationError()
        }
        // A persisted session ID can refer to another screen after relaunch.
        // Reject legacy/imported records too, not only new UI assignments.
        guard destination.persistent else {
            throw NativePlaylistError.invalid("临时显示器不能使用持久热键，原桌面保持不变。")
        }
        if case .playlist(let name, _) = request.target {
            guard try NativeApplicationPlaylistTarget.resolve(name) == request.playlist else { throw CancellationError() }
        }
    }

    private func activateSystemHotkey(_ action: NativeHotkeySystemAction) {
        guard profileHotkeysMayApply else { return }
        switch action {
        case .pause:
            guard let controller else { updateStatus("请先打开一张壁纸。"); return }
            if controller.isPaused { resume(nil) } else { pause(nil) }
        case .stop:
            invalidatePendingProfileHotkey()
            cancelProjectLoad(report: false)
            playbackPolicy.toggleHotkeyStopped()
            updateStatus(playbackPolicy.environment.hotkeyPlayback.stopped ? "壁纸已停止并释放资源；再次按下热键可恢复。" : "已解除热键停止状态。")
        case .mute:
            playbackPolicy.toggleHotkeyMuted()
            updateStatus(playbackPolicy.environment.hotkeyPlayback.muted ? "壁纸已静音。" : "已解除热键静音状态。")
        case .nextWallpaper:
            guard !playlistPresentationIsSuspended, !playbackPolicy.environment.stopsDesktop else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if let window = controller?.hotkeyDesktopWindows.first(where: { $0.screen?.frame.contains(NSEvent.mouseLocation) == true }),
               let context = displayContentContexts[window.displayKey], context.playback != nil,
               !applicationSelection.ownsTemporarySelection || context.owner != .manual {
                requestNextDisplayPlaylist(window.displayKey, videoEnded: false)
                return
            }
            if applicationSelection.ownsTemporarySelection {
                guard !applicationPlaylistIsSuspended, let request = applicationPlaylistPlayback?.next(now: now) else {
                    updateStatus("当前临时桌面没有可切换的播放列表。"); return
                }
                openApplicationPlaylistRequest(request)
            } else if let request = playlistPlayback?.next(now: now) { openPlaylistRequest(request) }
            else { updateStatus("当前没有可切换的播放列表。") }
        case .toggleRecord:
            let audio = NativeAudioService.shared
            guard !audio.busy else { updateStatus(audio.status); return }
            if audio.active { audio.stop() } else { audio.start() }
            updateStatus(audio.status)
        case .toggleIcons:
            guard !(controller?.hotkeyDesktopWindows.isEmpty ?? true) else {
                updateStatus("请先打开一张桌面壁纸。"); return
            }
            let hidden = NativeHotkeyPlatformActions.shared.toggleDesktopIconVisibility()
            updateStatus(hidden ? "桌面图标已隐藏。" : "桌面图标已恢复显示。")
        case .screenshot:
            guard hotkeyPlatformTask == nil else { return }
            let windows = controller?.hotkeyDesktopWindows ?? []
            guard let window = windows.first(where: { $0.screen?.frame.contains(NSEvent.mouseLocation) == true }) ?? windows.first else {
                updateStatus("当前没有可截取的原生桌面壁纸。"); return
            }
            hotkeyPlatformTask = Task { [weak self] in
                guard let self else { return }
                defer { hotkeyPlatformTask = nil }
                do {
                    if let url = try await NativeHotkeyPlatformActions.shared.captureDesktopWallpaper(from: window) {
                        if !isTerminating { updateStatus("壁纸截屏已保存：" + url.lastPathComponent) }
                    }
                } catch is CancellationError { }
                catch { if !isTerminating { updateStatus(error.localizedDescription) } }
            }
        case .screensaver:
            do { try NativeHotkeyPlatformActions.shared.startScreenSaver() }
            catch { updateStatus(error.localizedDescription) }
        case .windowBrowser: presentLibrary(nil)
        case .windowSettings: showPlaybackSettings(nil)
        case .windowEditor: showEditor(nil)
        }
    }

    private func connectProfileHotkeys() {
        NativeProfileHotkeyService.shared.onActivateTarget = { [weak self] target, hotkey in
            self?.activateContentOrSystemHotkey(target, hotkey: hotkey)
        }
        NativeProfileHotkeyService.shared.onActivate = { [weak self] name, hotkey in
            self?.activateProfileHotkey(name, hotkey: hotkey)
        }
        NativeProfileHotkeyService.shared.onError = { [weak self] message in self?.updateStatus(message) }
        NativeProfileHotkeyService.shared.start()
    }
    private func invalidatePendingProfileHotkey() {
        profileHotkeyRequestID = nil
        profileHotkeyTask?.cancel(); profileHotkeyTask = nil
    }
    private var profileHotkeysMayApply: Bool {
        !isTerminating && !isFinishingBrowser && !applyingDisplayLayout &&
            !systemIsSleeping && !displaysAreSleeping && !sessionIsInactive &&
            NSApp.modalWindow == nil && !NSApp.windows.contains(where: { $0.attachedSheet != nil })
    }
    private func activateProfileHotkey(_ name: String, hotkey: NativeHotkey) {
        guard profileHotkeysMayApply else { return }
        profileHotkeyTask?.cancel()
        let requestID = UUID(); profileHotkeyRequestID = requestID
        profileHotkeyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if profileHotkeyRequestID == requestID { profileHotkeyTask = nil; profileHotkeyRequestID = nil }
            }
            do {
                try Task.checkCancellation()
                guard profileHotkeysMayApply,
                      try NativeProfileHotkeyStore.bindings().contains(where: { $0.profileName == name && $0.hotkey == hotkey }) else {
                    throw CancellationError()
                }
                let profile = try NativeApplicationProfileTarget.resolve(name)
                try await applyProfile(profile, hotkeyRequestID: requestID, validateBeforeCommit: { [weak self] in
                    guard let self, self.profileHotkeysMayApply, self.profileHotkeyRequestID == requestID,
                          try NativeProfileHotkeyStore.bindings().contains(where: { $0.profileName == name && $0.hotkey == hotkey }),
                          try NativeApplicationProfileTarget.resolve(name) == profile else { throw CancellationError() }
                })
                updateStatus("配置文件已加载：" + name)
            } catch is CancellationError {
                // A newer user action or a changed target owns presentation.
            } catch {
                if !isTerminating, profileHotkeyRequestID == requestID {
                    updateStatus("热键未应用，保留原桌面：" + error.localizedDescription)
                }
            }
        }
    }
    private func applyProfile(_ profile: NativeWallpaperProfile, hotkeyRequestID: UUID? = nil, validateBeforeCommit: (() throws -> Void)? = nil) async throws {
        // A manual choice invalidates hotkey intent before any editor flush
        // can suspend. An older hotkey may not have opened a renderer yet.
        if hotkeyRequestID == nil { invalidatePendingProfileHotkey() }
        _ = try profile.validated(); _ = try NativeProfileStore.supportedPlaylist()
        guard !playbackPolicy.environment.stopsDesktop else {
            throw PropertyError.invalid("壁纸处于停止状态，请恢复播放后重试加载配置文件。")
        }
        await library?.finishInlinePropertyEditing()?.value
        try Task.checkCancellation()
        guard !isTerminating, !isFinishingBrowser else { throw CancellationError() }
        try validateBeforeCommit?()
        let request = ProfileLoadRequest(profile, validateBeforeCommit: validateBeforeCommit, hotkeyRequestID: hotkeyRequestID)
        openProject(URL(fileURLWithPath: profile.wallpaper.projectPath), mode: .desktop, profileRequest: request)
        guard let task = openTask, let id = openRequestID else { throw CancellationError() }
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.openRequestID == id else { return }
                self.cancelProjectLoad(report: false)
            }
        })
        try (request.result ?? .failure(CancellationError())).get()
    }
    @objc private func showTransfers(_ sender: Any?) {
        if transferController == nil {
            let panel = NativeTransferController()
            panel.onPauseQueue = { [weak self] in self?.workshop.toggleTransferPause() }
            panel.onRetry = { [weak self] token in self?.workshop.retryTransfer(token) }
            panel.onStop = { [weak self] token in self?.workshop.stopTransfer(token) }
            panel.onOpen = { [weak self] token in self?.workshop.openTransfer(token) }
            panel.onClear = { [weak self] in self?.workshop.clearFinishedTransfers() }
            panel.onDownload = { [weak self] in self?.workshop.enterItem() }
            panel.onRetrySaving = { [weak self] in self?.workshop.retrySavingTransfers() }
            transferController = panel
        }
        transferController?.update(workshop.transferSnapshot)
        transferController?.present()
    }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }

    @objc private func showApplicationInfo(_ sender: Any?) {
        if applicationInfo == nil { applicationInfo = NativeApplicationInfoController() }
        applicationInfo?.present()
    }

    @objc private func showEditor(_ sender: Any?) { presentEditor(project: nil) }
    private func presentEditor(project: URL?, archive: URL? = nil) {
        if editor == nil {
            let created = NativeEditorController()
            created.onSaved = { [weak self] in self?.applicationLibraryChanged(forcePreview: true) }
            created.onApply = { [weak self] url in self?.openProject(url, mode: .desktop) }
            editor = created
        }
        editor?.present(project: project, archive: archive)
    }

    /// Registration is changed only by an explicit menu action. The system's
    /// current status, not a saved preference, is the source of truth.
    @objc private func toggleLoginItem(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .notRegistered, .notFound:
                try service.register()
            case .enabled, .requiresApproval:
                try service.unregister()
            @unknown default:
                throw HostError.invalidArgument("macOS 返回了无法识别的登录项状态。")
            }
            refreshLoginItems()
            switch service.status {
            case .enabled: updateStatus("登录时启动已启用")
            case .notRegistered: updateStatus("登录时启动已关闭")
            case .requiresApproval: updateStatus("登录项已登记，等待系统允许")
            case .notFound: updateStatus("macOS 尚未确认登录项")
            @unknown default: updateStatus("macOS 登录项状态未知")
            }
        } catch {
            refreshLoginItems()
            fputs("Login item change failed: \(error.localizedDescription)\n", stderr)
            updateStatus("登录项设置未完成")
            let alert = NSAlert()
            alert.messageText = "无法更改登录时启动"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openLoginSettings(_ sender: Any?) {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func makeLoginItem() -> NSMenuItem {
        let entry = item("登录时启动", #selector(toggleLoginItem(_:)))
        loginItems.append(entry)
        return entry
    }

    private func makeLoginSettingsItem() -> NSMenuItem {
        let entry = item("打开系统设置中的登录项…", #selector(openLoginSettings(_:)))
        loginSettingsItems.append(entry)
        return entry
    }

    private func refreshLoginItems() {
        let status = SMAppService.mainApp.status
        for entry in loginItems {
            switch status {
            case .notRegistered:
                entry.title = "登录时启动"; entry.state = .off
                entry.toolTip = "点击后由 macOS 登记；下次登录时恢复上次壁纸。"
            case .enabled:
                entry.title = "登录时启动"; entry.state = .on
                entry.toolTip = "macOS 已允许该登录项；点击可关闭。"
            case .requiresApproval:
                entry.title = "登录时启动（需要系统允许）"; entry.state = .mixed
                entry.toolTip = "登录项已经登记，但尚未获系统允许；点击可取消登记。"
            case .notFound:
                entry.title = "登录时启动（系统状态未确认）"; entry.state = .mixed
                entry.toolTip = "macOS 尚未找到该登录项；点击可尝试登记，结果由系统确认。"
            @unknown default:
                entry.title = "登录时启动（状态未知）"; entry.state = .off
                entry.toolTip = "macOS 返回了无法识别的状态。"
            }
        }
        for entry in loginSettingsItems { entry.isEnabled = status == .requiresApproval || status == .notFound }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshLoginItems() }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let result = NSMenuItem(title: title, action: action, keyEquivalent: key)
        result.target = self
        return result
    }
    private func buildStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "WE"
        status.button?.toolTip = "Wallpaper Engine Native"
        let menu = NSMenu(title: "Wallpaper Engine Native")
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "请选择壁纸", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(item("壁纸库…", #selector(presentLibrary(_:)), "l"))
        menu.addItem(item("欢迎使用…", #selector(presentWelcome(_:))))
        menu.addItem(item("壁纸编辑器…", #selector(showEditor(_:)), "e"))
        menu.addItem(item("浏览创意工坊…", #selector(presentWorkshop(_:))))
        menu.addItem(item("打开本地项目…", #selector(chooseProject(_:)), "o"))
        menu.addItem(item("导入内置纹理…", #selector(importEngineResources(_:))))
        menu.addItem(item("导入内置字体…", #selector(importEngineFonts(_:))))
        menu.addItem(item("默认壁纸设置…", #selector(showProperties(_:)), ","))
        menu.addItem(item("显示器…", #selector(showDisplays(_:))))
        menu.addItem(item("下载与更新…", #selector(showTransfers(_:))))
        menu.addItem(item("播放与节能…", #selector(showPlaybackSettings(_:))))
        menu.addItem(item("声音响应…", #selector(showAudio(_:)), "u"))
        menu.addItem(item("媒体信息…", #selector(showMedia(_:)), "m"))
        menu.addItem(item("窗口预览默认壁纸", #selector(previewCurrentProject(_:)), "p"))
        menu.addItem(item("返回桌面显示", #selector(showCurrentProjectOnDesktop(_:)), "d"))
        for entry in workshop.menuItems() { menu.addItem(entry) }
        menu.addItem(.separator())
        let pause = item("暂停", #selector(pause(_:)))
        let resume = item("继续", #selector(resume(_:)))
        pause.isEnabled = false; resume.isEnabled = false
        menu.addItem(pause); menu.addItem(resume)
        menu.addItem(item("重新加载项目", #selector(reload(_:)), "r"))
        menu.addItem(item("查看兼容情况…", #selector(showCompatibility(_:))))
        menu.addItem(.separator())
        menu.addItem(makeLoginItem())
        menu.addItem(makeLoginSettingsItem())
        menu.addItem(.separator())
        menu.addItem(item("关于 Wallpaper Engine Native…", #selector(showApplicationInfo(_:))))
        menu.addItem(item("退出", #selector(quit(_:)), "q"))
        status.menu = menu; statusItem = status; pauseItem = pause; resumeItem = resume
    }
    private func buildMainMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.delegate = self
        appMenu.addItem(item("关于 Wallpaper Engine Native…", #selector(showApplicationInfo(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("壁纸库…", #selector(presentLibrary(_:)), "l"))
        appMenu.addItem(item("欢迎使用…", #selector(presentWelcome(_:))))
        appMenu.addItem(item("壁纸编辑器…", #selector(showEditor(_:)), "e"))
        appMenu.addItem(item("浏览创意工坊…", #selector(presentWorkshop(_:))))
        appMenu.addItem(item("打开本地项目…", #selector(chooseProject(_:)), "o"))
        appMenu.addItem(item("导入内置纹理…", #selector(importEngineResources(_:))))
        appMenu.addItem(item("导入内置字体…", #selector(importEngineFonts(_:))))
        appMenu.addItem(item("默认壁纸设置…", #selector(showProperties(_:)), ","))
        appMenu.addItem(item("显示器…", #selector(showDisplays(_:))))
        appMenu.addItem(item("下载与更新…", #selector(showTransfers(_:))))
        appMenu.addItem(item("播放与节能…", #selector(showPlaybackSettings(_:))))
        appMenu.addItem(item("声音响应…", #selector(showAudio(_:)), "u"))
        appMenu.addItem(item("媒体信息…", #selector(showMedia(_:)), "m"))
        appMenu.addItem(item("窗口预览默认壁纸", #selector(previewCurrentProject(_:)), "p"))
        appMenu.addItem(item("返回桌面显示", #selector(showCurrentProjectOnDesktop(_:)), "d"))
        appMenu.addItem(item("查看兼容情况…", #selector(showCompatibility(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item("暂停", #selector(pause(_:))))
        appMenu.addItem(item("继续", #selector(resume(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(makeLoginItem())
        appMenu.addItem(makeLoginSettingsItem())
        appMenu.addItem(.separator())
        appMenu.addItem(item("退出 Wallpaper Engine Native", #selector(quit(_:)), "q"))
        app.submenu = appMenu; menu.addItem(app)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        let redoItem = NSMenuItem(title: "重做", action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        edit.insertItem(redoItem, at: 1)
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }
    @objc private func showAudio(_ sender: Any?) {
        if audioController == nil { audioController = NativeAudioController() }
        audioController?.showWindow(nil); audioController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func showMedia(_ sender: Any?) {
        if mediaController == nil { mediaController = NativeMediaController() }
        mediaController?.present()
    }

    private func updateStatus(_ title: String) {
        fputs("Wallpaper Engine Native status: \(title)\n", stderr)
        statusItem?.menu?.item(at: 0)?.title = title
        library?.updateStatus(title)
        updateLibraryPlayback()
    }

    private func updatePlaybackMenu() {
        let isManuallyPaused = controller?.isPaused ?? false
        let hasController = controller != nil
        pauseItem?.isEnabled = hasController && !isManuallyPaused
        resumeItem?.isEnabled = hasController && isManuallyPaused
        updateLibraryPlayback()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLoginItem(_:)) {
            switch SMAppService.mainApp.status {
            case .notRegistered, .enabled, .requiresApproval, .notFound: return !isTerminating
            @unknown default: return false
            }
        }
        if menuItem.action == #selector(openLoginSettings(_:)) {
            let status = SMAppService.mainApp.status
            return status == .requiresApproval || status == .notFound
        }
        if menuItem.action == #selector(importEngineResources(_:)) { return !isTerminating && builtinImportTask == nil }
        if menuItem.action == #selector(importEngineFonts(_:)) { return !isTerminating && builtinImportTask == nil }
        if menuItem.action == #selector(previewCurrentProject(_:)) { return controller != nil && configuration?.mode != .preview }
        if menuItem.action == #selector(showCurrentProjectOnDesktop(_:)) { return controller != nil && configuration?.mode != .desktop }
        if menuItem.action == #selector(pause(_:)) { return controller != nil && controller?.isPaused == false }
        if menuItem.action == #selector(resume(_:)) { return controller?.isPaused == true }
        return true
    }

    private func observeWorkspaceSleepNotifications() {
        removeWorkspaceSleepNotifications()
        let workspace = NSWorkspace.shared
        let notificationCenter = workspace.notificationCenter
        workspaceObservers = [
            notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.controller?.requestDesktopRecovery(.activeSpace)
                    self?.pendingController?.requestDesktopRecovery(.activeSpace)
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemIsSleeping = true
                    self?.controller?.suspendForSystemSleep()
                    self?.pendingController?.suspendForSystemSleep()
                    self?.selectionPreview?.suspendForSystemSleep()
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.systemIsSleeping = false
                    self?.controller?.resumeFromSystemSleep()
                    self?.pendingController?.resumeFromSystemSleep()
                    self?.selectionPreview?.resumeFromSystemSleep()
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displaysAreSleeping = true
                    self?.controller?.suspendForDisplaySleep()
                    self?.pendingController?.suspendForDisplaySleep()
                    self?.selectionPreview?.suspendForDisplaySleep()
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displaysAreSleeping = false
                    self?.controller?.resumeFromDisplaySleep()
                    self?.pendingController?.resumeFromDisplaySleep()
                    self?.selectionPreview?.resumeFromDisplaySleep()
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionIsInactive = true
                    self?.controller?.suspendForInactiveSession()
                    self?.pendingController?.suspendForInactiveSession()
                    self?.selectionPreview?.suspendForInactiveSession()
                }
            },
            notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: workspace, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionIsInactive = false
                    self?.controller?.resumeFromInactiveSession()
                    self?.pendingController?.resumeFromInactiveSession()
                    self?.selectionPreview?.resumeFromInactiveSession()
                }
            }
        ]
    }

    private func removeWorkspaceSleepNotifications() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers { notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }
    private func reportFailure(_ error: Error) {
        let detail = String(error.localizedDescription.prefix(2048))
        let message = (error as? HostError)?.recoveryMessage ?? detail
        fputs("Wallpaper Engine Native: \(detail)\n", stderr)
        failedProjectLoad = FailedProjectLoad(request: requestedConfiguration, importRequest: requestedImport, message: message)
        updateStatus("加载失败：" + message)
        presentLibrary(nil)
    }
    private func showReloadError(_ error: Error) {
        statusItem?.button?.toolTip = error.localizedDescription
        library?.updateStatus("重新加载失败：" + error.localizedDescription)
    }
}

do {
    if CommandLine.arguments.dropFirst().contains("--import-engine-resources") {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--import-engine-resources",
              CommandLine.arguments[2].hasPrefix("/") else {
            throw HostError.invalidArgument("--import-engine-resources requires one absolute APK path and no other arguments.")
        }
        let receipt = try NativeBuiltinTextures.importArchive(URL(fileURLWithPath: CommandLine.arguments[2]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
        exit(EXIT_SUCCESS)
    }
    if CommandLine.arguments.dropFirst().contains("--import-engine-fonts") {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--import-engine-fonts",
              CommandLine.arguments[2].hasPrefix("/") else {
            throw HostError.invalidArgument("--import-engine-fonts requires one absolute APK path and no other arguments.")
        }
        let receipt = try NativeBuiltinFonts.importArchive(URL(fileURLWithPath: CommandLine.arguments[2]))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(receipt), as: UTF8.self))
        exit(EXIT_SUCCESS)
    }
    let configuration = try LaunchConfiguration.parse(arguments: CommandLine.arguments)
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate(configuration: configuration, guiSession: CommandLine.arguments.count == 1)
        application.delegate = delegate
        application.run()
    }
} catch HostError.usage {
    print(LaunchConfiguration.usage)
    exit(EXIT_SUCCESS)
} catch {
    fputs("Wallpaper Engine Native host: \(error.localizedDescription)\n\n\(LaunchConfiguration.usage)\n", stderr)
    exit(EXIT_FAILURE)
}
