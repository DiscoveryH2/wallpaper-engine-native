import AppKit
import MetalKit

@MainActor
final class NativeMetalCreationView: MTKView, NativeSceneRendering {
    var view: NSView { self }
    var failedLayerCount: Int { 0 }
    var propertyUpdateRevision: UInt64 {
        (renderer.sceneSnapshot?.revision ?? 0) &+ (scripts?.creationPreparationRevision ?? 0) &+ renderConfigurationRevision
    }
    private var renderConfigurationRevision: UInt64 = 0
    var antialiasingQuality: NativeAntialiasing { renderer.antialiasingQuality }
    var postProcessingQuality: NativePostProcessingQuality { renderer.postProcessingQuality }
    var textureResolutionQuality: NativeTextureResolution { renderer.textureResolutionRequest.quality }
    private var textureResolutionAttempt: String?
    private var textureResolutionFailure: String?
    private var renderer: NativeMetalRenderer
    private let editorSeekingAllowed: Bool
    private let sceneProject: WallpaperProject?
    private var sceneProperties: [String: Any]
    private var scripts: SceneScriptBridge?
    private var videoLibrary = SceneVideoLibrary()
    private var pointerInput: NativeMetalPointer?
    private var pointerTracking: NSTrackingArea?
    private var clock = ScenePlaybackClock()
    private var timer: Timer?
    private var frameRateLimit = 60
    private var soundTimer: Timer?
    private var presentationArmed = false
    private var editorEndpoint = false
    private var completedFrames = 0
    private var submittedSequence = 0
    private var lastCompletedTime = 0.0
    private var lastFrameSize = CGSize.zero
    private var lastGPUTime = 0.0
    private var failure: String?
    private var redrawPending = false
    private let inFlight = DispatchSemaphore(value: 3)
    /// Only retained-history effects use this extra admission. All ordinary
    /// scenes keep the independent three-command-buffer semaphore above.
    private let temporalSubmissionGate = NativeMetalTemporalSubmissionGate()

    convenience init(source: NativeCreationRenderSource, allowsEditorSeeking: Bool) throws {
        try self.init(renderer: NativeMetalRenderer(source: source), allowsEditorSeeking: allowsEditorSeeking, project: nil)
    }
    convenience init(scene: NativeMetalSceneSource, project: WallpaperProject, videos: SceneVideoLibrary = SceneVideoLibrary()) throws {
        try self.init(renderer: NativeMetalRenderer(scene: scene), allowsEditorSeeking: false, project: project)
        videoLibrary = videos
    }
    private init(renderer: NativeMetalRenderer, allowsEditorSeeking: Bool, project: WallpaperProject?) throws {
        self.renderer = renderer
        editorSeekingAllowed = allowsEditorSeeking
        sceneProject = project; sceneProperties = project?.userProperties ?? [:]
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), device: renderer.device)
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true; autoResizeDrawable = true
        isPaused = true; enableSetNeedsDisplay = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        scripts = try renderer.makeSceneScripts(publication: .renderFrame)
        renderer.sceneScripts = scripts
        configureVideos()
        if renderer.needsScriptPointer || renderer.needsParticlePointer {
            pointerInput = NativeMetalPointer(view: self, scripts: scripts)
        }
        updateTrackingAreas()
        scripts?.initializationDidResolve = { [weak self] in
            self?.needsDisplay = true; self?.updateTimer()
        }
        fputs("Native Metal loaded: \(renderer.title), \(renderer.layerCount) layers, GPU \(renderer.device.name), \(renderer.textureBytes) texture bytes\n", stderr)
    }
    required init(coder: NSCoder) { fatalError("NativeMetalCreationView requires a creation source") }
    private func configureVideos() {
        renderer.sceneMembershipDidChange = { [weak self] in
            guard let self else { return }
            if pointerInput == nil && (renderer.needsScriptPointer || renderer.needsParticlePointer) {
                pointerInput = NativeMetalPointer(view: self, scripts: scripts)
            }
            pointerInput?.invalidateScene(); updateTrackingAreas()
            videoLibrary = renderer.preparedVideoLibrary
            configureVideos(); needsDisplay = true; updateTimer()
        }
        renderer.onVideoFrame { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, clock.isPaused || completedFrames == 0 else { return }
                needsDisplay = true
            }
        }
    }
    deinit { timer?.invalidate(); soundTimer?.invalidate() }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { pointerInput != nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { pointerInput != nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking); self.pointerTracking = nil }
        guard pointerInput != nil else { return }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); pointerTracking = tracking
        window?.acceptsMouseMovedEvents = true
    }
    override func mouseDown(with event: NSEvent) { pointerInput?.handle(event) }
    override func mouseUp(with event: NSEvent) { pointerInput?.handle(event) }
    override func mouseMoved(with event: NSEvent) { pointerInput?.handle(event) }
    override func mouseDragged(with event: NSEvent) { pointerInput?.handle(event) }
    override func mouseEntered(with event: NSEvent) { pointerInput?.handle(event) }
    override func mouseExited(with event: NSEvent) { pointerInput?.handle(event) }
    override func rightMouseDown(with event: NSEvent) { pointerInput?.handle(event) }
    override func rightMouseUp(with event: NSEvent) { pointerInput?.handle(event) }
    override func rightMouseDragged(with event: NSEvent) { pointerInput?.handle(event) }

    var playbackTime: Double { clock.time(at: ProcessInfo.processInfo.systemUptime) }
    var playbackDescription: String {
        if failure != nil { return "Metal · 渲染已停止，请查看运行诊断" }
        return String(format: "Metal · 场景时间 %.2f 秒 · %@", playbackTime, clock.isPaused ? "已暂停" : "正在播放")
    }
    var diagnostics: [String] {
        var result = ["渲染后端：Metal · \(renderer.device.name)。\(renderer.isGeneralScene ? "通用 Scene" : "原生创作")图层由自有 Metal shader 绘制。",
                      "Metal 图层：\(renderer.layerCount)；图片占用 \(renderer.textureBytes) 字节；最多 3 帧等待 GPU。",
                      String(format: "Metal 已完成 %d 帧；最近帧 %d×%d，场景时间 %.3f 秒，GPU %.3f 毫秒。GPU 完成不单独证明桌面合成正确。", completedFrames, Int(lastFrameSize.width), Int(lastFrameSize.height), lastCompletedTime, lastGPUTime * 1000)]
        result += renderer.sceneNotes + renderer.animationNotes(at: lastCompletedTime)
        if let scripts {
            result += [scripts.runtimeDiagnostic] + scripts.diagnostics.map { "SceneScript：" + $0 }
            if let camera = scripts.cameraRuntimeDiagnostic { result.append(camera) }
            for (id, playback) in scripts.texturePlayback.sorted(by: { $0.key < $1.key }).prefix(8) {
                result.append("Metal 脚本纹理 \(id)：joined=\(playback.joined)，playing=\(playback.playing)，position=\(playback.position)，rate=\(playback.rate)。")
            }
        }
        if renderer.isGeneralScene { result.append(renderer.requiresContinuousRedraw ? "按播放时钟更新脚本、粒子、纹理、属性或相机运动。" : "当前无活动动画，仅在显示或属性变化时重绘。") }
        for (index, motion) in renderer.motions.enumerated().prefix(8) {
            let pose = motion.pose(at: lastCompletedTime, preserveEndpoint: editorEndpoint)
            result.append(String(format: "图层 %d · %d 个属性关键帧 · X %.3f Y %.3f · 缩放 %.4f / %.4f · 旋转 %.3f° · 透明度 %.4f", index + 1, motion.scalarKeyframeCount, pose.x, pose.y, pose.scaleX, pose.scaleY, pose.rotation, pose.opacity))
        }
        if let pointerInput { result.append(pointerInput.diagnostic) }
        if let textureResolutionFailure { result.append("纹理分辨率未应用，保留原画面：" + textureResolutionFailure) }
        if let failure { result.append("Metal 错误：" + failure) }
        return result
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        clock.setAttached(window != nil && presentationArmed, at: ProcessInfo.processInfo.systemUptime)
        if window == nil { renderer.suspendSounds() }
        updateTimer()
        if window != nil { needsDisplay = true }
    }
    func beginPresentation() {
        guard !presentationArmed else { return }
        presentationArmed = true
        clock.setAttached(window != nil, at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true; updateTimer()
    }
    func refreshPresentation() {
        needsLayout = true; layoutSubtreeIfNeeded(); needsDisplay = true
    }
    func pause() {
        guard !clock.isPaused else { return }
        scripts?.suspend()
        renderer.suspendSounds()
        clock.setPaused(true, at: ProcessInfo.processInfo.systemUptime, holdingLastFrame: true); updateTimer()
        needsDisplay = true
    }
    func resume() {
        guard failure == nil else { return }
        scripts?.resume()
        editorEndpoint = false
        clock.setPaused(false, at: ProcessInfo.processInfo.systemUptime); updateTimer()
        needsDisplay = true
    }
    private func updateTimer() {
        updateSoundTimer()
        pointerInput?.setActive(presentationArmed && window != nil && !clock.isPaused && failure == nil)
        guard presentationArmed, window != nil, !clock.isPaused, failure == nil, renderer.requiresContinuousRedraw else {
            timer?.invalidate(); timer = nil; return
        }
        guard timer == nil else { return }
        let next = Timer(timeInterval: 1.0 / Double(frameRateLimit), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        RunLoop.main.add(next, forMode: .common); timer = next
    }

    func setFrameRateLimit(_ framesPerSecond: Int) {
        let value = min(240, max(10, framesPerSecond))
        guard value != frameRateLimit else { return }
        frameRateLimit = value; timer?.invalidate(); timer = nil
        // Timer replacement must not reset the scene clock or unpause playback.
        updateTimer()
    }

    func setReflectionsEnabled(_ enabled: Bool) {
        guard renderer.reflectionsEnabled != enabled else { return }
        renderer.setReflectionsEnabled(enabled)
        needsDisplay = true; updateTimer()
    }

    func setVolumetricQuality(_ quality: NativeVolumetricQuality) {
        guard renderer.volumetricQuality != quality else { return }
        renderer.setVolumetricQuality(quality); needsDisplay = true
    }
    func setShadowQuality(_ quality: NativeShadowQuality) {
        guard renderer.shadowQuality != quality else { return }
        renderer.setShadowQuality(quality); needsDisplay = true
    }

    func setAudioOutputEnabled(_ enabled: Bool) {
        renderer.setAudioOutputEnabled(enabled)
        refreshSounds(); updateSoundTimer()
    }
    private var soundPresentationActive: Bool {
        presentationArmed && window != nil && clock.hasSubmittedFrame && !clock.isPaused && failure == nil && (scripts?.initializationResolved ?? true)
    }
    private func refreshSounds() { renderer.refreshSounds(active: soundPresentationActive) }
    private func updateSoundTimer() {
        guard soundPresentationActive, renderer.requiresSoundUpdates else {
            soundTimer?.invalidate(); soundTimer = nil; return
        }
        guard soundTimer == nil else { return }
        // Static artwork does not need 60 GPU frames per second just to play
        // music. This timer only refreshes the bounded 30 Hz spectrum input.
        let next = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSounds(); self?.updateSoundTimer() }
        }
        RunLoop.main.add(next, forMode: .common); soundTimer = next
    }

    override func draw(_ dirtyRect: NSRect) {
        guard presentationArmed, window != nil, failure == nil else { return }
        // No first-frame submission or clock start before script init commits.
        guard scripts?.initializationResolved != false else { return }
        // Do this before asking MTKView for a drawable. A later property or
        // resize update may replace `renderer`, so the command path repeats
        // this nonmutating check after that update as well.
        guard !temporalSubmissionGate.blocks(requiresSequentialSubmission: renderer.requiresSequentialFrameSubmission) else {
            redrawPending = true; return
        }
        guard inFlight.wait(timeout: .now()) == .success else { redrawPending = true; return }
        redrawPending = false
        var submitted = false
        var encodedCommand: MTLCommandBuffer?
        var submissionRenderer: NativeMetalRenderer?
        defer {
            if !submitted {
                if let encodedCommand, let submissionRenderer { submissionRenderer.discardTemporalSubmission(encodedCommand) }
                inFlight.signal()
            }
        }
        guard currentRenderPassDescriptor != nil, let drawable = currentDrawable else { return }
        let time = playbackTime, size = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        refreshTextureResolutionForOutput(size)
        do {
            let renderer = self.renderer
            submissionRenderer = renderer
            let requiresTemporalSubmission = renderer.requiresSequentialFrameSubmission
            // `refreshTextureResolutionForOutput` above can publish a prepared
            // renderer. Re-check its static retained-history predicate before
            // encoding, but never release an old token on a revision/swap.
            guard !temporalSubmissionGate.blocks(requiresSequentialSubmission: requiresTemporalSubmission) else {
                redrawPending = true; return
            }
            if completedFrames == 0, try !renderer.videosReady(at: time) { return }
            if !clock.isPaused { renderer.updateScripts(time: time, size: size, input: pointerInput?.input() ?? [:]) }
            var pointer = SIMD2<Float>(repeating: 0.5)
            if renderer.usesPointerInput, let window {
                // Read the same screen position convention as the compatibility
                // renderer. Desktop windows keep Finder click-through; no event
                // tap, keyboard monitor, or new input permission is installed.
                let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                pointer = SIMD2(Float(point.x / max(1, bounds.width)), Float(point.y / max(1, bounds.height)))
            }
            let command = try renderer.command(target: drawable.texture, time: time, preserveEndpoint: editorEndpoint,
                                              paused: clock.isPaused, pointer: pointer,
                                              particlePointer: renderer.needsParticlePointer ? pointerInput?.particleInput() ?? .inactive : .inactive)
            encodedCommand = command
            refreshSounds()
            let pointerFrame = renderer.lastPointerFrame
            let renderedIdentity = ObjectIdentifier(renderer), renderedRevision = renderer.sceneSnapshot?.revision
            let temporalSubmission: NativeMetalTemporalSubmissionGate.Token?
            if requiresTemporalSubmission {
                // No await occurs between the preflight and this point. The
                // token exists only for a fully encoded command which is about
                // to be submitted, never for a missing drawable or throw.
                guard let token = temporalSubmissionGate.begin(requiresSequentialSubmission: true, renderer: renderedIdentity, revision: renderedRevision) else {
                    renderer.discardTemporalSubmission(command)
                    redrawPending = true; return
                }
                temporalSubmission = token
            } else { temporalSubmission = nil }
            submittedSequence += 1
            let pointerSequence = submittedSequence
            let admission = inFlight
            command.addCompletedHandler { [weak self] command in
                admission.signal()
                let error = command.status == .completed ? nil : command.error?.localizedDescription ?? "GPU 命令未完成。"
                let gpuTime = max(0, command.gpuEndTime - command.gpuStartTime)
                Task { @MainActor [weak self] in
                    // History tickets are completed before the matching token
                    // is released. This explicit call is independent of the
                    // renderer's direct/offscreen fallback callback order.
                    renderer.finishTemporalSubmission(command)
                    guard let self else { return }
                    let releasedTemporalSubmission = temporalSubmission.map { self.temporalSubmissionGate.finish($0) } ?? true
                    if let error { fail(error); return }
                    if ObjectIdentifier(renderer) == renderedIdentity, renderer.sceneSnapshot?.revision == renderedRevision {
                        pointerInput?.completed(pointerFrame, sequence: pointerSequence)
                    }
                    completedFrames += 1; lastCompletedTime = time; lastFrameSize = size; lastGPUTime = gpuTime
                    clock.submitFirstFrame(at: ProcessInfo.processInfo.systemUptime)
                    refreshSounds()
                    updateTimer()
                    // A stale/double callback cannot clear a newer token or
                    // create a second coalesced redraw wake-up.
                    if releasedTemporalSubmission, redrawPending { redrawPending = false; needsDisplay = true }
                }
            }
            command.present(drawable); command.commit(); submitted = true
            clock.recordSubmittedFrame(time: time)
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) {
        guard failure == nil else { return }
        failure = String(message.prefix(2048)); pause()
        fputs("Native Metal rendering stopped: \(message)\n", stderr)
    }

    func editorLayerBounds(at index: Int) -> CGRect? {
        editorSeekingAllowed ? renderer.bounds(at: index) : nil
    }
    @discardableResult
    func updateEditorMotion(_ motion: NativeCreationMotion, at index: Int) -> Bool {
        updateEditorMotions([index: motion])
    }
    @discardableResult
    func updateEditorMotions(_ motions: [Int: NativeCreationMotion]) -> Bool {
        guard editorSeekingAllowed, clock.isPaused, failure == nil, renderer.updateMotions(motions) else { return false }
        needsDisplay = true; return true
    }
    @discardableResult
    func seekEditor(to time: Double) -> Bool {
        guard editorSeekingAllowed, let document = renderer.document, failure == nil, time.isFinite, (0...document.duration).contains(time) else { return false }
        pause(); editorEndpoint = true
        clock.seek(to: time, at: ProcessInfo.processInfo.systemUptime)
        needsDisplay = true; return true
    }
    func editorPreviewPNG(width: Int, height: Int) throws -> Data {
        guard editorSeekingAllowed, clock.isPaused, window == nil, completedFrames == 0, failure == nil else {
            throw SceneError.invalid("当前 Metal 预览无法生成作品封面。")
        }
        return try renderer.previewPNG(width: width, height: height, time: playbackTime)
    }

    func prepareAntialiasing(_ quality: NativeAntialiasing) throws -> () -> Void {
        guard quality != antialiasingQuality else { return {} }
        guard scripts?.hasPendingCreation != true else { throw SceneError.invalid("脚本正在准备图层，暂时保留原抗锯齿品质。") }
        let commit = try renderer.prepareAntialiasing(quality)
        return { [weak self] in
            guard let self else { return }
            commit(); renderConfigurationRevision &+= 1; needsDisplay = true
        }
    }

    func prepareTextureResolution(_ quality: NativeTextureResolution, outputSize: CGSize) throws -> () -> Void {
        try prepareGraphicsQuality(postProcessingQuality, textureResolution: .init(quality: quality, outputSize: outputSize))
    }
    func refreshTextureResolutionForOutput(_ size: CGSize) {
        guard textureResolutionQuality == .automatic, renderer.textureResolutionRequest.outputSize != size else { return }
        let key = "\(size.width)x\(size.height):\(propertyUpdateRevision)"
        guard key != textureResolutionAttempt else { return }
        do { try prepareTextureResolution(.automatic, outputSize: size)(); textureResolutionFailure = nil }
        catch { textureResolutionAttempt = key; textureResolutionFailure = error.localizedDescription }
    }
    func preparePostProcessingQuality(_ quality: NativePostProcessingQuality) throws -> () -> Void {
        try prepareGraphicsQuality(quality, textureResolution: renderer.textureResolutionRequest)
    }
    private func prepareGraphicsQuality(_ quality: NativePostProcessingQuality, textureResolution: NativeTextureResolutionRequest) throws -> () -> Void {
        guard quality != postProcessingQuality || textureResolution != renderer.textureResolutionRequest else { return {} }
        let sameMip = textureResolution.preferredMip(canvas: renderer.textureResolutionCanvas) == renderer.textureResolutionRequest.preferredMip(canvas: renderer.textureResolutionCanvas)
        if quality == postProcessingQuality, sameMip, textureResolution.quality == textureResolutionQuality {
            return { [weak self] in self?.renderer.setTextureResolutionRequest(textureResolution) }
        }
        guard scripts?.hasPendingCreation != true else {
            throw SceneError.invalid("脚本正在准备图层，暂时保留原后处理和纹理品质。")
        }
        guard let project = sceneProject, quality != postProcessingQuality || !sameMip else {
            return { [weak self] in
                guard let self else { return }
                renderer.setPostProcessingQuality(quality); renderer.setTextureResolutionRequest(textureResolution)
                renderConfigurationRevision &+= 1; textureResolutionAttempt = nil; textureResolutionFailure = nil; needsDisplay = true
            }
        }
        // Even when only bloom is changing, this preparation is independent
        // of the live renderer. The controller commits all screens together.
        let source = try NativeMetalSceneSource.load(project, properties: sceneProperties, videos: videoLibrary,
            snapshot: renderer.sceneSnapshot, fontSelection: .snapshot(renderer.sceneBuiltinFonts), postProcessing: quality, textureResolution: textureResolution)
        let next = try NativeMetalRenderer(scene: source)
        try next.validateScriptContinuity(from: renderer)
        return { [weak self] in
            guard let self else { return }
            next.preserveSceneRuntime(from: renderer)
            next.sceneScripts = scripts
            renderer = next; renderConfigurationRevision &+= 1
            textureResolutionAttempt = nil; textureResolutionFailure = nil
            configureVideos(); updateTimer(); needsDisplay = true
        }
    }

    func prepareUserPropertyUpdate(_ changes: [String: Any]) async throws -> () -> Void {
        guard let project = sceneProject else { return {} }
        try Task.checkCancellation()
        guard scripts?.hasPendingCreation != true else {
            throw SceneError.invalid("壁纸脚本正在创建图层；请等待本次更新显示后重新应用设置。已暂停时请先恢复播放。")
        }
        let values = sceneProperties.merging(changes) { _, next in next }
        let source = try NativeMetalSceneSource.load(project, properties: values, videos: videoLibrary, snapshot: renderer.sceneSnapshot, fontSelection: .snapshot(renderer.sceneBuiltinFonts), postProcessing: postProcessingQuality, textureResolution: renderer.textureResolutionRequest)
        let next = try NativeMetalRenderer(scene: source)
        try next.validateScriptContinuity(from: renderer)
        try Task.checkCancellation()
        // The host checks propertyUpdateRevision for every prepared screen
        // before saving/committing. Both published membership and a creation
        // begun since preparation invalidate it. Keep this view and its clock.
        return { [weak self] in
            guard let self else { return }
            next.preserveSceneRuntime(from: renderer)
            next.sceneScripts = scripts
            renderer = next; sceneProperties = values
            configureVideos()
            scripts?.applyUserProperties(changes)
            updateTimer(); needsDisplay = true
        }
    }
}
