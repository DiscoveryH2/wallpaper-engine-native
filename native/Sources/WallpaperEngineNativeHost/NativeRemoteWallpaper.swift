import AppKit
import WebKit

/// Remote pages never receive the local-project file workspace, media grants,
/// file manifests, or native script-message handlers.
@MainActor
final class NativeRemoteWallpaperView: NSObject, WallpaperRenderable, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let sourceURL: URL
    private var paused = true
    private var audioEnabled = false
    private var presented = false
    private var abandoned = false
    private var ready = false
    private var failure: String?
    private var generation = 0
    private var mediaUpdateRunning = false
    private var desiredMediaSuspension = true
    private var appliedMediaSuspension: Bool?
    private let timeout = NativePlaybackPreferences.load().loadingTimeout
    private let token = UUID().uuidString
    var playbackStateDidChange: (() -> Void)?
    var view: NSView { webView }
    var playbackDescription: String { failure ?? (ready ? "网页已加载。" : "网页加载中。") }
    var playbackNotice: String? { failure ?? (ready ? nil : "网页加载中。") }
    var diagnostics: [String] {
        ["远程 WebKit · 独立临时会话 · 无本机文件授权", playbackDescription,
         "网页媒体由原生暂停与页面桥控制；作者替换接口、Worker 及未配合的子帧不保证完全冻结或静音。"]
    }

    init(url: URL) {
        sourceURL = url
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.underPageBackgroundColor = .black
        let scripts = configuration.userContentController
        scripts.addUserScript(WKUserScript(source: WebPauseBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        scripts.addUserScript(WKUserScript(source: Self.mediaBridge(token: token), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        // System-enforced suspension precedes the first network load. Scripts
        // and muted HTML media cannot start audible playback while preparing.
        webView.setAllMediaPlaybackSuspended(true) { [weak self] in
            guard let self, !abandoned else { return }
            appliedMediaSuspension = true
            webView.load(URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout.seconds))
        }
    }

    func prepareForPresentation() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout.seconds
        do {
            while !ready {
                try Task.checkCancellation()
                if let failure { throw PropertyError.invalid(failure) }
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw PropertyError.invalid("网页加载或脚本响应超时，未切换壁纸。") }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try Task.checkCancellation(); try validatePreparedPresentation()
        } catch {
            abandoned = true; webView.stopLoading(); throw error
        }
    }
    func validatePreparedPresentation() throws {
        guard ready, failure == nil, !abandoned else { throw PropertyError.invalid(failure ?? "网页尚未准备完成，未切换壁纸。") }
    }
    func beginPresentation() { presented = true; updateState() }
    func pause() { paused = true; updateState() }
    func resume() { paused = false; updateState() }
    func setAudioOutputEnabled(_ enabled: Bool) { audioEnabled = enabled; updateState() }

    private func updateState() {
        desiredMediaSuspension = !presented || paused || abandoned
        let value = "window.__weNativeRemoteState?.(\(desiredMediaSuspension),\(audioEnabled && !desiredMediaSuspension));true"
        webView.evaluateJavaScript(value) { [weak self] _, _ in self?.applyMediaSuspension() }
        if desiredMediaSuspension { applyMediaSuspension() }
    }
    private func applyMediaSuspension() {
        guard !mediaUpdateRunning, appliedMediaSuspension != desiredMediaSuspension else { return }
        mediaUpdateRunning = true
        let value = desiredMediaSuspension
        webView.setAllMediaPlaybackSuspended(value) { [weak self] in
            guard let self else { return }
            mediaUpdateRunning = false; appliedMediaSuspension = value
            applyMediaSuspension()
        }
    }
    private func fail(_ message: String) {
        failure = message; ready = false; playbackStateDidChange?()
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        generation += 1; ready = false; failure = nil; playbackStateDidChange?()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateState() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let expected = generation
        webView.evaluateJavaScript("document.readyState !== 'loading'") { [weak self] result, error in
            guard let self, !abandoned, expected == generation else { return }
            guard error == nil, result as? Bool == true else { fail("网页脚本未响应，请重新加载。") ; return }
            ready = true; updateState(); playbackStateDidChange?()
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail("网页加载失败：" + error.localizedDescription) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail("网页加载失败：" + error.localizedDescription) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail("网页进程已退出，请重新加载壁纸。") }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let allowed = (try? NativeWallpaperURL.parse(url.absoluteString)) != nil || (action.targetFrame?.isMainFrame == false && url.absoluteString == "about:blank")
        guard action.targetFrame != nil, allowed else {
            if !presented, action.targetFrame?.isMainFrame != false { fail("网页导航地址不受支持，未切换壁纸。") }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let status = (response.response as? HTTPURLResponse)?.statusCode ?? 0
        guard response.canShowMIMEType, (200...299).contains(status) || status == 0 && !response.isForMainFrame else {
            if response.isForMainFrame { fail("网页返回错误（HTTP \(status)），未切换壁纸。") }
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    private static func mediaBridge(token: String) -> String {
        // This is a playback compatibility bridge, not a security sandbox.
        // WebKit's origin and file rules provide the resource boundary.
        #"""
        (() => {
          const token = '\#(token)';
          let paused = true, enabled = false;
          const desired = new WeakMap(), media = new Set(), contexts = new Map();
          const proto = HTMLMediaElement.prototype;
          const muted = Object.getOwnPropertyDescriptor(proto, 'muted');
          const apply = el => {
            if (!desired.has(el)) desired.set(el, muted.get.call(el));
            media.add(el); muted.set.call(el, !enabled || desired.get(el));
          };
          if (muted?.configurable) {
            Object.defineProperty(proto, 'muted', {...muted, set(value) {
              muted.set.call(this, value); desired.set(this, muted.get.call(this)); apply(this);
            }});
            const play = proto.play;
            proto.play = function(...args) { apply(this); return Reflect.apply(play, this, args); };
            new MutationObserver(() => document.querySelectorAll('audio,video').forEach(apply))
              .observe(document, {childList: true, subtree: true});
          }
          const Original = window.AudioContext || window.webkitAudioContext;
          if (Original) {
            const resume = Original.prototype.resume, suspend = Original.prototype.suspend;
            Original.prototype.resume = function() {
              const state = contexts.get(this);
              if (state) state.wants = true;
              if (!enabled && state) return new Promise((resolve,reject) => state.waiting.push({resolve,reject}));
              return resume.call(this);
            };
            Original.prototype.suspend = function() {
              const state = contexts.get(this); if (state) state.wants = false;
              return suspend.call(this);
            };
            const Wrapper = new Proxy(Original, {construct(target,args,newTarget) {
              const ctx = Reflect.construct(target,args,newTarget), state = {wants: ctx.state === 'running', waiting: []};
              contexts.set(ctx,state); if (!enabled) suspend.call(ctx).catch(() => {}); return ctx;
            }});
            window.AudioContext = Wrapper;
            if (window.webkitAudioContext) window.webkitAudioContext = Wrapper;
            contexts.apply = () => contexts.forEach((state,ctx) => {
              if (ctx.state === 'closed') { contexts.delete(ctx); return; }
              if (!enabled) suspend.call(ctx).catch(() => {});
              else if (state.wants) resume.call(ctx).then(() => {
                state.waiting.splice(0).forEach(p => p.resolve());
              }, error => state.waiting.splice(0).forEach(p => p.reject(error)));
            });
          }
          const send = target => { try { target.postMessage({weNative: token, paused, enabled}, '*'); } catch (_) {} };
          const set = (p,e) => {
            paused = !!p; enabled = !!e && !paused;
            window.__weNativeSetPaused?.(paused);
            media.forEach(el => { if (!el.isConnected && el.paused) media.delete(el); else apply(el); });
            contexts.apply?.();
            for (let i=0; i<window.frames.length; i++) send(window.frames[i]);
          };
          Object.defineProperty(window, '__weNativeRemoteState', {value: set});
          window.addEventListener('message', event => {
            if (event.data?.weNative !== token) return;
            if (event.source === window.parent && window.parent !== window) set(event.data.paused, event.data.enabled);
            else if (event.data.request) for (let i=0; i<window.frames.length; i++) if (event.source === window.frames[i]) send(event.source);
          });
          set(true,false);
          if (window.parent !== window) window.parent.postMessage({weNative: token,request: true}, '*');
        })();
        """#
    }
}

@MainActor
final class NativeOpenURLController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private let urlField = NSTextField(), nameField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let accept = NSButton(title: "确认", target: nil, action: nil)
    var onOpen: ((URL, String) -> Void)?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "从 URL 打开壁纸"; window.isReleasedWhenClosed = false
        super.init(window: window); window.delegate = self
        urlField.placeholderString = "http://"; urlField.identifier = .init("openWallpaperURL"); urlField.delegate = self
        nameField.identifier = .init("openWallpaperURLName")
        errorLabel.textColor = .systemRed; errorLabel.font = .systemFont(ofSize: 12)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "URL"), urlField], [NSTextField(labelWithString: "名称"), nameField]])
        grid.rowSpacing = 14; grid.columnSpacing = 14; grid.column(at: 0).width = 50
        accept.target = self; accept.action = #selector(openURL); accept.keyEquivalent = "\r"; accept.isEnabled = false; accept.identifier = .init("openWallpaperURLAccept")
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelURL)); cancel.keyEquivalent = "\u{1b}"; cancel.identifier = .init("openWallpaperURLCancel")
        let buttons = NSStackView(views: [NSView(), accept, cancel]); buttons.distribution = .fill; buttons.spacing = 10
        let stack = NSStackView(views: [grid, errorLabel, buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24), grid.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("Not archived") }
    func present() { window?.center(); showWindow(nil); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(urlField); NSApp.activate(ignoringOtherApps: true) }
    func controlTextDidChange(_ notification: Notification) { accept.isEnabled = !urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty; errorLabel.stringValue = "" }
    @objc private func cancelURL() { close() }
    @objc private func openURL() {
        do {
            let url = try NativeWallpaperURL.parse(urlField.stringValue)
            let name = String(nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            close(); onOpen?(url, name)
        } catch { errorLabel.stringValue = error.localizedDescription }
    }
}
