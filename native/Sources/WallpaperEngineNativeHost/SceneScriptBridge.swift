import AppKit
import Darwin
import Foundation

/// Only JSON crosses this boundary. Author code executes in a separate process
/// using Apple's JavaScriptCore, with no native objects exported into that VM.
/// One outstanding request bounds backpressure; a stalled helper is terminated.
@MainActor
final class SceneScriptBridge {
    /// Render consumers publish one complete reply at the next running frame.
    /// Immediate publication remains available to non-presenting analysis tools.
    enum Publication { case immediate, renderFrame }
    let publication: Publication
    private(set) var lastReceivedRequestID = 0
    var lastPublishedRequestID: Int { lastCommittedCommandRequestID }
    var hasPendingPublication: Bool { deferredResponse != nil }
    private(set) var values: [String: Any] = [:]
    private(set) var sceneValues: [String: Any] = [:]
    private(set) var sceneLayerOrder: NativeSceneLayerOrder
    private(set) var layerValues: [String: [String: Any]] = [:]
    private(set) var effectVisibilityValues: [String: Bool] = [:]
    private(set) var materialValues: [String: [Float]] = [:]
    private(set) var texturePlayback: [String: SceneTexturePlayback] = [:]
    private(set) var videoPlayback: [String: SceneVideoPlayback] = [:]
    private var videoKeys: Set<String> { inventory.videoKeys }
    private(set) var diagnostics: [String] = []
    private(set) var ready = false
    private var staticCamera: NativeScriptCamera
    var cameraPose: NativeCameraPose { staticCamera.pose }
    var cameraRuntimeDiagnostic: String? { staticCamera.runtimeDiagnostic }
    private var inventory: SceneScriptInventory
    private var maximumBindingCount = 0
    private struct InventoryUpdate {
        let inventory: SceneScriptInventory
        let retainedIDs: Set<String>
        let retainedBindings: Set<String>
        let timelines: SceneTimelines
        let models: NativeModelScriptStore?
        let commitResources: () -> Void
    }
    private var inventoryUpdate: InventoryUpdate?
    typealias CreationHandler = (Data, Double) async throws -> SceneScriptPreparedCreation
    var creationHandler: CreationHandler?
    private var creationUpdate: SceneScriptPreparedCreation?
    private var creationCount = 0
    private var preparingCreation = false
    private(set) var creationPreparationRevision: UInt64 = 0
    var hasPendingCreation: Bool { preparingCreation || creationUpdate != nil }
    private let assetRegistry: SceneScriptAssetRegistry
    private var resourceTask: Task<Void, Never>?
    private var activeNativeCall: Int?
    private(set) var nativeResourceCalls = 0
    var registeredAssets: [String] { assetRegistry.registrations.values.map(\.path).sorted() }
    typealias RetirementHandler = (Set<String>, [String]) throws -> (() -> Void)
    var retirementHandler: RetirementHandler?
    private(set) var inventoryRevision = 0
    private(set) var inventoryStatistics: [String: Int] = [:]
    var count: Int { inventory.count }
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let queue = DispatchQueue(label: "io.wallpaper-engine-native.scenescript")
    private enum RequestState { case idle, inFlight(Int), deferred(Int), committed(Int) }
    private var requestState: RequestState = .idle
    private var pending: Bool {
        switch requestState {
        case .inFlight, .deferred: return true
        case .idle, .committed: return false
        }
    }
    private var stopped = false
    private var suspended = false
    private var deferredResponse: (result: Result<[String: Any], Error>, sequence: Int, loading: Bool, operation: String, propertyKeys: [String])?
    private var sequence = 0
    private var watchdog: DispatchWorkItem?
    private var lastRuntime: Double?
    private var events: [[String: Any]] = []
    private var deliveredPointerSamples = 0
    private var deliveredPointerDownSamples = 0
    private var propertyChanges: [String: Any] = [:]
    private var soundCommands: [[String: String]] = []
    private var reportedFrames = false
    private var keys: Set<String> { inventory.keys }
    private var layerIDs: Set<String> { inventory.layerIDs }
    private var soundIDs: Set<String> { inventory.soundIDs }
    private var effectVisibilityPaths: Set<String> { inventory.effectVisibilityPaths }
    private var materialDimensions: [String: Int] { inventory.materialDimensions }
    private var timelineLimits: [String: Double] { inventory.timelineLimits }
    private var timelineStateProvider: () -> [String: [String: Any]]
    private var timelineCommandHandler: ([SceneTimelineCommand]) -> Bool
    private var timelineEvents: SceneTimelines?
    private var modelAnimations: NativeModelScriptStore?
    private var sentModelEvents = 0, committedModelEvents = 0, modelCallbackCalls = 0
    private var sentModelMarkers = 0, committedModelMarkers = 0, modelMarkerCalls = 0
    private var pendingModelEvents: [[String: Any]] = []
    private var sentAnimationEvents = 0, committedAnimationEvents = 0, animationCallbackCalls = 0
    private var lastCommittedCommandRequestID = 0
    private var reportedTimelineBatches = 0
    private var committedTimelineBatches = 0
    private var committedTimelineCommands = 0
    private var deferredResponseCount = 0
    private var frameDeferredResponseCount = 0
    private var loadedBindingCount: Int?
    private var disabledBindingCount: Int?
    private var pendingMedia: NativeMediaSnapshot?
    private(set) var committedMedia = NativeMediaSnapshot.disabled
    private var lastMediaDeliveryCounts: [String: Int] = [:]
    private var storage: SceneScriptStorage?
    var bindingPaths: [String] { keys.sorted() }
    var initializationResolved: Bool { ready || stopped }
    var initializationStatus: String { ready ? "ready" : stopped ? "failed" : "pending" }
    var runtimeDiagnostic: String {
        let request: String
        switch requestState {
        case .idle: request = "空闲"
        case .inFlight(let id): request = "请求 \(id) 处理中"
        case .deferred(let id): request = "请求 \(id) \(suspended ? "暂停待提交" : "待绘制帧提交")"
        case .committed(let id): request = "请求 \(id) 已提交"
        }
        return "SceneScript 运行快照：状态 \(initializationStatus)，已加载 \(loadedBindingCount.map(String.init) ?? "未回执")/\(count)，禁用 \(disabledBindingCount.map(String.init) ?? "未回执")；最近提交请求 \(lastCommittedCommandRequestID)，\(request)；发布模式 \(publication == .renderFrame ? "绘制帧" : "即时")，最近收到请求 \(lastReceivedRequestID)，帧边界延后 \(frameDeferredResponseCount) 次；时间轴命令 \(committedTimelineBatches) 批 / \(committedTimelineCommands) 条；动画事件已确认 \(committedAnimationEvents)/\(sentAnimationEvents)，回调调用 \(animationCallbackCalls) 次；模型动画命令 \(modelAnimations?.committedCommands ?? 0) 条，事件已确认 \(committedModelEvents)/\(sentModelEvents)，结束回调 \(modelCallbackCalls) 次，标记 \(committedModelMarkers)/\(sentModelMarkers)，标记回调 \(modelMarkerCalls) 次；场景属性覆盖 \(sceneValues.count)/19 项；图层排序提交 \(sceneLayerOrder.changes) 次，前 12 项 ID=\(sceneLayerOrder.indices.prefix(12).map { sceneLayerOrder.ids[$0] }.joined(separator: ","))；效果可见性覆盖 \(effectVisibilityValues.count) 项；材质参数覆盖 \(materialValues.count) 项；暂停延后回执 \(deferredResponseCount) 次；已发送指针样本 \(deliveredPointerSamples)（按下 \(deliveredPointerDownSamples)），待发送事件 \(events.count)。"
    }
    var initializationDidResolve: (() -> Void)? { didSet { notifyInitialization() } }
    private var initializationNotified = false

    private func notifyInitialization() {
        guard initializationResolved, !initializationNotified, let callback = initializationDidResolve else { return }
        initializationNotified = true
        callback()
    }

    static func path(_ component: String) -> String {
        component.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    init?(scene: [String: Any], properties: [String: Any], camera: NativeCameraPose, propertyTypes: [String: String] = [:], textureAnimations: [String: [String: Any]] = [:], videoTextures: [String: [String: Any]] = [:], sounds: [String: [String: Any]] = [:], timelines: [[String: Any]] = [], timelineValues: [String: Any] = [:], timelineStateProvider: @escaping () -> [String: [String: Any]], timelineCommandHandler: @escaping ([SceneTimelineCommand]) -> Bool, projectURL: URL, layerWriteCapabilities: [String: [String]]? = nil, allowedBindingPaths: Set<String>? = nil, pointerInputAvailable: Bool? = nil, bindingInitialValues: [String: Any] = [:], effectVisibilityBases: [String: Bool] = [:], materials: [String: [SceneScriptMaterial]] = [:], timelineEvents: SceneTimelines? = nil, modelAnimations: NativeModelScriptStore? = nil, publication: Publication = .immediate, activeLayerSlots: Set<Int>? = nil, initialLayerOrder: [String]? = nil, initialLayerConfigurations: [String: [String: Any]]? = nil, retirementHandler: RetirementHandler? = nil, resourceAssets: SceneAssets? = nil, resourceFonts: NativeBuiltinFonts.Snapshot? = nil, resourceRegistry: SceneScriptAssetRegistry? = nil, creationHandler: CreationHandler? = nil) throws {
        self.publication = publication
        self.staticCamera = NativeScriptCamera(pose: camera)
        self.timelineStateProvider = timelineStateProvider
        self.timelineCommandHandler = timelineCommandHandler
        self.timelineEvents = timelineEvents
        self.modelAnimations = modelAnimations
        self.retirementHandler = retirementHandler
        self.creationHandler = creationHandler
        assetRegistry = resourceRegistry ?? SceneScriptAssetRegistry(projectURL: projectURL, assets: resourceAssets, builtinFonts: resourceFonts)
        let inventory = try SceneScriptInventory(scene: scene, properties: properties,
            textureAnimations: textureAnimations, videoTextures: videoTextures, sounds: sounds,
            timelines: timelines, timelineValues: timelineValues, layerWriteCapabilities: layerWriteCapabilities,
            allowedBindingPaths: allowedBindingPaths, bindingInitialValues: bindingInitialValues,
            effectVisibilityBases: effectVisibilityBases, materials: materials, activeLayerSlots: activeLayerSlots,
            initialLayerOrder: initialLayerOrder, initialLayerConfigurations: initialLayerConfigurations)
        guard inventory.count > 0 else { return nil }
        self.inventory = inventory
        maximumBindingCount = inventory.count
        sceneLayerOrder = inventory.sceneLayerOrder
        let payload = try inventory.message()
        let bindings = payload["bindings"] as! [[String: Any]], layers = payload["layers"] as! [[String: Any]]
        do { storage = try SceneScriptStorage(project: projectURL) }
        catch { report("本地存储暂不可用，当前使用会话内数据：\(error.localizedDescription)") }
        values = inventory.initialValues
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("Tools/we-scene-script"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SceneError.invalid("应用内的 SceneScript 执行组件缺失，请重新构建。")
        }
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        timelineEvents?.setEventDeliveryEnabled(true)
        modelAnimations?.enableEvents()
        // Close the parent's copies of the child's pipe endpoints, so EOF also
        // closes the reader after a crash or timeout.
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        // WallpaperProject also serves the Web API, whose payload uses {value:…}.
        // SceneScript applyUserProperties receives direct property values.
        let sceneProperties = properties.mapValues { ($0 as? [String: Any])?["value"] ?? $0 }
        let projection = (scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Any] ?? [:]
        let screen = NSScreen.main?.frame.size ?? NSSize(width: 1280, height: 720)
        let media = NativeMediaService.shared.snapshot
        send(["op": "load", "bindings": bindings, "layers": layers, "properties": sceneProperties,
              "inventoryAvailable": activeLayerSlots != nil || retirementHandler != nil,
              "destructionAvailable": retirementHandler != nil,
              "creationAvailable": creationHandler != nil,
              "sceneProperties": NativeSceneScriptProperties.metadata(scene: scene, properties: properties),
              "timelines": timelines, "timelineValues": timelineValues, "models": modelAnimations?.metadata ?? [:],
              "propertyTypes": propertyTypes, "layerWriteCapabilities": layerWriteCapabilities as Any? ?? NSNull(),
              "pointerInputAvailable": pointerInputAvailable ?? (layerWriteCapabilities == nil),
              "storage": storage?.initial ?? ["global": [:], "screens": [:]],
              "storageScreen": (NSScreen.main?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "main",
              "canvas": ["x": projection["width"] ?? 1280, "y": projection["height"] ?? 720],
              "screen": ["x": screen.width, "y": screen.height], "media": media.scriptValue], loading: true, media: media)
    }

    /// Prepare native resources before calling this method. One in-flight
    /// inventory owns the normal request slot; the renderer callback runs only
    /// after its complete reply validates at the existing publication boundary.
    /// This internal entry point does not yet expose author create/destroy APIs.
    func replaceInventory(with next: SceneScriptInventory, retaining ids: Set<String>,
                          timelines: SceneTimelines, models: NativeModelScriptStore? = nil,
                          commitResources: @escaping () -> Void) throws {
        guard ready, !pending, !suspended, !stopped, inventoryUpdate == nil, inventoryRevision < 1_000_000_000 else {
            throw SceneError.invalid("脚本清单替换需要已就绪、未暂停且没有待提交请求的播放实例。")
        }
        let retainedBindings = try next.retainedBindings(from: inventory, retaining: ids)
        guard Set(timelines.paths) == Set(next.timelineLimits.keys) else {
            throw SceneError.invalid("候选脚本清单与原生时间轴资源不一致。")
        }
        var message = try next.message()
        let models = models ?? NativeModelScriptStore()
        let modelMetadata = models.metadata
        let expectedModels = Set((message["layers"] as! [[String: Any]]).filter { $0["model"] as? Bool == true }.map { $0["id"] as! String })
        guard Set(modelMetadata.keys) == expectedModels else { throw SceneError.invalid("候选模型脚本清单缺少实际原生资源。") }
        let previousMetadata = modelAnimations?.metadata ?? [:]
        for id in ids.intersection(expectedModels) {
            guard let before = previousMetadata[id], let after = modelMetadata[id],
                  try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys]) == JSONSerialization.data(withJSONObject: after, options: [.sortedKeys]) else {
                throw SceneError.invalid("结构变更不能替换存活模型的动画资源接口。")
            }
        }
        if let previous = modelAnimations { models.inheritProtocol(from: previous) }
        message["op"] = "inventory"
        message["inventoryProtocol"] = 1
        message["inventoryRevision"] = inventoryRevision + 1
        message["retainedLayerIDs"] = ids.sorted()
        message["retainedBindings"] = retainedBindings.sorted()
        message["models"] = modelMetadata
        message["runtime"] = lastRuntime ?? 0
        inventoryUpdate = InventoryUpdate(inventory: next, retainedIDs: ids, retainedBindings: retainedBindings,
                                         timelines: timelines, models: models, commitResources: commitResources)
        maximumBindingCount = max(maximumBindingCount, next.count)
        send(message, loading: false)
        if stopped { throw SceneError.invalid("候选脚本清单未能送达；继续使用原有场景资源。") }
    }

    nonisolated static func objectID(_ object: [String: Any], index: Int) -> String {
        if let number = object["id"] as? NSNumber { return number.stringValue }
        if let text = object["id"] as? String { return text }
        return "object-\(index)"
    }

    nonisolated static func hasScripts(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= 32 else { return false }
        if let object = value as? [String: Any] {
            if let script = object["script"] as? String, !script.isEmpty { return true }
            return object.values.contains { hasScripts($0, depth: depth + 1) }
        }
        if let array = value as? [Any] { return array.contains { hasScripts($0, depth: depth + 1) } }
        return false
    }

    func value(at path: String, fallback: Any?) -> Any? {
        if let key = NativeSceneScriptProperties.name(at: path), let value = sceneValues[key] { return value }
        return materialValues[path] as Any? ?? effectVisibilityValues[path] as Any? ?? values[path] ?? fallback
    }

    func suspend() { suspended = true }

    func resume() {
        guard suspended, !stopped else { return }
        suspended = false
        if publication == .immediate { commitDeferredResponse() }
        flushPropertyChanges()
    }

    /// Call before reading any script-driven frame state, including media and
    /// timeline inputs. A received reply never changes an exposed/paused redraw.
    func publishForRendering() {
        guard publication == .renderFrame, !suspended, !stopped else { return }
        commitDeferredResponse()
    }

    private func commitDeferredResponse() {
        guard let response = deferredResponse else { return }
        deferredResponse = nil
        guard case .deferred(let id) = requestState, id == response.sequence else {
            report("SceneScript 延后回执的请求状态不一致。"); stop(); return
        }
        commit(response.result, sequence: response.sequence, loading: response.loading, operation: response.operation, propertyKeys: response.propertyKeys)
    }

    func applyUserProperties(_ changes: [String: Any]) {
        guard !stopped else { return }
        propertyChanges.merge(changes.mapValues { ($0 as? [String: Any])?["value"] ?? $0 }) { _, next in next }
        flushPropertyChanges()
    }

    private func flushPropertyChanges() {
        guard ready, !pending, !stopped, !suspended, !propertyChanges.isEmpty else { return }
        let changes = propertyChanges
        propertyChanges.removeAll()
        send(["op": "properties", "properties": changes], loading: false)
    }

    func event(name: String, objectIDs: [String], event: [String: Any], input: [String: Any]? = nil) {
        // Global input polling also needs real button transitions when no
        // solid layer is hit (for example a 3D manual camera script).
        guard !stopped, !suspended, !objectIDs.isEmpty || input != nil else { return }
        // Mouse movement can be coalesced, but clicks retain their order.
        if name == "cursorMove", events.last?["name"] as? String == name { events.removeLast() }
        guard events.count < 128 else { report("鼠标事件队列已满；部分事件未处理。"); return }
        var envelope: [String: Any] = ["name": name, "objectIDs": objectIDs, "event": event]
        if let input { envelope["input"] = input }
        events.append(envelope)
    }

    /// One native observation may produce leave/enter/up/click together. Keep
    /// the complete group and its one input sample atomic under backpressure.
    @discardableResult
    func pointerSample(_ sample: [[String: Any]], input: [String: Any]) -> Bool {
        guard !stopped, !suspended, !sample.isEmpty, sample.count <= 128 else { return false }
        if sample.count == 1, sample[0]["name"] as? String == "cursorMove",
           events.last?["name"] as? String == "cursorMove", events.last?["input"] != nil { events.removeLast() }
        guard sample.count <= 128 - events.count else { report("鼠标事件队列已满；完整输入样本未处理。"); return false }
        var group = sample
        group[0]["input"] = input
        events.append(contentsOf: group)
        return true
    }

    @discardableResult
    func discardPointerSamples() -> Int {
        let count = events.count
        events.removeAll(keepingCapacity: true)
        return count
    }

    func takeSoundCommands() -> [[String: String]] {
        let result = soundCommands
        soundCommands.removeAll(keepingCapacity: true)
        return result
    }

    func frame(runtime: Double, screen: [String: Double], input: [String: Any], audio: NativeAudioSpectrum, sounds: [String: [String: Any]] = [:], timelineValues: [String: Any] = [:]) {
        guard ready, !stopped, !suspended else { return }
        guard runtime.isFinite, runtime >= 0 else { return }
        publishForRendering()
        guard ready, !pending, !stopped else { return }
        // Initialization already ran at scene time zero. Deliver updates only
        // after simulation time advances, including the first real frame.
        let delta = min(0.25, max(0, runtime - (lastRuntime ?? 0)))
        guard delta > 0 else {
            if let previous = lastRuntime, runtime < previous { lastRuntime = runtime }
            return
        }
        lastRuntime = runtime
        // A short drag can deliver down/move/up between two render frames.
        // Retain one real input sample per accepted request, in order, and
        // deliver only its associated event prefix. Never replay update with
        // fabricated timestamps or drop the final release state.
        let inputIndices = events.indices.filter { events[$0]["input"] != nil }
        let boundary = inputIndices.count > 1 ? inputIndices[1] : events.count
        let frameEvents = Array(events.prefix(boundary))
        let queuedInput = frameEvents.compactMap { $0["input"] as? [String: Any] }.first
        let frameInput = queuedInput ?? input
        events.removeFirst(boundary)
        if queuedInput != nil {
            deliveredPointerSamples = min(1_000_000_000, deliveredPointerSamples + 1)
            if frameInput["cursorLeftDown"] as? Bool == true {
                deliveredPointerDownSamples = min(1_000_000_000, deliveredPointerDownSamples + 1)
            }
        }
        let media = NativeMediaService.shared.snapshot
        let animationEvents = timelineEvents?.takeEvents() ?? []
        sentAnimationEvents = min(1_000_000_000, sentAnimationEvents + animationEvents.count)
        send(["op": "frame", "runtime": runtime, "frametime": delta, "screen": screen, "input": frameInput, "events": frameEvents, "animationEvents": animationEvents, "audio": audio.scriptValue, "sounds": sounds, "timelineValues": timelineValues, "media": media.scriptValue], loading: false, media: media)
    }

    private func send(_ message: [String: Any], loading: Bool, media: NativeMediaSnapshot? = nil) {
        guard !pending, !stopped else { return }
        do {
            if let media {
                guard try JSONSerialization.data(withJSONObject: media.scriptValue).count <= 32 * 1024 else {
                    throw SceneError.invalid("媒体元数据超过 32 KiB 上限。")
                }
            }
            guard sequence < 9_007_199_254_740_991 else { throw SceneError.invalid("SceneScript 请求序号超过精确整数范围。") }
            let requestSequence = sequence + 1
            var outgoing = message
            outgoing["sceneLayerProtocol"] = 1
            outgoing["scenePropertyProtocol"] = 1
            outgoing["timelineProtocol"] = 2
            outgoing["requestID"] = requestSequence
            outgoing["cameraProtocol"] = 1
            outgoing["camera"] = staticCamera.scriptValue
            // Fetch after the preceding response's command commit, including
            // load and queued properties requests that do not pass through render.
            outgoing["timelineStates"] = inventoryUpdate?.timelines.scriptStates ?? timelineStateProvider()
            let requestModels = inventoryUpdate.map { $0.models } ?? modelAnimations
            outgoing["modelProtocol"] = 1
            outgoing["modelStates"] = requestModels?.states ?? [:]
            outgoing["modelTransforms"] = requestModels?.transforms ?? [:]
            outgoing["modelSerial"] = requestModels?.scriptSerial ?? 0
            let modelEvents = try requestModels?.takeEvents() ?? []
            pendingModelEvents = modelEvents
            outgoing["modelEvents"] = modelEvents
            sentModelEvents = min(1_000_000_000, sentModelEvents + modelEvents.count)
            sentModelMarkers = min(1_000_000_000, sentModelMarkers + modelEvents.filter { $0["kind"] as? String == "marker" }.count)
            var data = try JSONSerialization.data(withJSONObject: outgoing, options: [.sortedKeys])
            guard data.count <= 4 * 1024 * 1024 else { throw SceneError.invalid("SceneScript 请求超过 4 MiB。") }
            data.append(10)
            sequence = requestSequence; requestState = .inFlight(requestSequence)
            pendingMedia = media
            let operation = message["op"] as? String ?? ""
            let propertyKeys = (message["properties"] as? [String: Any])?.keys.sorted() ?? []
            let timeout = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, case .inFlight(let id) = self.requestState, id == requestSequence else { return }
                    self.report("SceneScript 执行超过 2 秒，已终止脚本进程并保留最后一帧属性。")
                    self.stop()
                }
            }
            watchdog = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
            continueExchange(writing: data, sequence: requestSequence, nextCallID: 1,
                loading: loading, operation: operation, propertyKeys: propertyKeys)
        } catch { report(error.localizedDescription); stop() }
    }

    private func ownsRequest(_ id: Int) -> Bool {
        guard !stopped, case .inFlight(let current) = requestState else { return false }
        return current == id && sequence == id
    }

    /// A suspended resource request never occupies the pipe queue or the main
    /// actor. The next pipe exchange starts only after its result is accepted.
    private func continueExchange(writing data: Data, sequence requestSequence: Int, nextCallID: Int,
                                  loading: Bool, operation: String, propertyKeys: [String]) {
        guard ownsRequest(requestSequence) else { return }
        let writeHandle = input.fileHandleForWriting, readHandle = output.fileHandleForReading
        queue.async { [weak self] in
            let result: Result<[String: Any], Error>
            do {
                try writeHandle.write(contentsOf: data)
                result = .success(try Self.readResponse(readHandle))
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.receiveExchange(result, sequence: requestSequence, nextCallID: nextCallID,
                        loading: loading, operation: operation, propertyKeys: propertyKeys)
                }
            }
        }
    }

    private func receiveExchange(_ result: Result<[String: Any], Error>, sequence requestSequence: Int, nextCallID: Int,
                                 loading: Bool, operation: String, propertyKeys: [String]) {
        guard ownsRequest(requestSequence) else { return }
        guard case .success(let message) = result, message["nativeCallProtocol"] != nil else {
            receive(result, sequence: requestSequence, loading: loading, operation: operation, propertyKeys: propertyKeys)
            return
        }
        guard nextCallID <= 256, activeNativeCall == nil,
              NativeAnimationJSON.integer(message["nativeCallProtocol"]) == 1,
              NativeAnimationJSON.integer(message["requestID"]) == requestSequence,
              NativeAnimationJSON.integer(message["callID"]) == nextCallID else {
            report("SceneScript 原生请求序号无效或超过单批 256 次。")
            stop(); return
        }
        activeNativeCall = nextCallID
        do {
            if message["method"] as? String == "createLayer" {
                let data = try validateCreationCall(message)
                // A settings candidate must not replace this renderer while
                // its asynchronous creation owns resources for the old one.
                preparingCreation = true; creationPreparationRevision &+= 1
                let handler = creationUpdate?.next ?? creationHandler!
                let runtime = lastRuntime ?? 0
                resourceTask = Task { [weak self] in
                    let prepared: Result<SceneScriptPreparedCreation, Error>
                    do { prepared = .success(try await handler(data, runtime)) }
                    catch { prepared = .failure(error) }
                    guard !Task.isCancelled, let self, self.ownsRequest(requestSequence), self.activeNativeCall == nextCallID else { return }
                    let reply: Result<Any, Error>
                    do { reply = .success(try self.stageCreation(prepared.get())) }
                    catch { reply = .failure(error) }
                    self.preparingCreation = false
                    self.replyToNativeCall(reply, sequence: requestSequence, callID: nextCallID,
                        loading: loading, operation: operation, propertyKeys: propertyKeys)
                }
                return
            }
            let request = try validateNativeResourceCall(message, sequence: requestSequence)
            let registry = assetRegistry
            // The task retains its preparation service, not the playback view
            // or bridge. Closing a view cancels this wait and drops late results.
            resourceTask = Task { [weak self] in
                let prepared: Result<SceneScriptAssetRegistry.PreparedRegistration, Error>
                do { prepared = .success(try await registry.prepare(request.file, option: request.option)) }
                catch { prepared = .failure(error) }
                guard !Task.isCancelled, let self, self.ownsRequest(requestSequence), self.activeNativeCall == nextCallID else { return }
                let reply: Result<Any, Error>
                do { reply = .success(try registry.commit(prepared.get())) }
                catch { reply = .failure(error) }
                self.replyToNativeCall(reply, sequence: requestSequence, callID: nextCallID,
                    loading: loading, operation: operation, propertyKeys: propertyKeys)
            }
        } catch {
            replyToNativeCall(.failure(error), sequence: requestSequence, callID: nextCallID,
                loading: loading, operation: operation, propertyKeys: propertyKeys)
        }
    }

    private func replyToNativeCall(_ result: Result<Any, Error>, sequence requestSequence: Int, callID: Int,
                                   loading: Bool, operation: String, propertyKeys: [String]) {
        guard ownsRequest(requestSequence), activeNativeCall == callID else { return }
        activeNativeCall = nil; resourceTask = nil
        var reply: [String: Any] = ["nativeCallProtocol": 1, "requestID": requestSequence, "callID": callID]
        switch result {
        case .success(let value): reply["ok"] = true; reply["value"] = value
        case .failure(let error): reply["ok"] = false; reply["error"] = String(error.localizedDescription.prefix(2048))
        }
        do {
            var data = try JSONSerialization.data(withJSONObject: reply)
            guard data.count <= 4 * 1024 * 1024 else { throw SceneError.invalid("原生资源回执超过 4 MiB。") }
            data.append(10)
            continueExchange(writing: data, sequence: requestSequence, nextCallID: callID + 1,
                loading: loading, operation: operation, propertyKeys: propertyKeys)
        } catch { report(error.localizedDescription); stop() }
    }

    nonisolated private static func readResponse(_ handle: FileHandle) throws -> [String: Any] {
        var response = Data(), chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw SceneError.invalid("SceneScript 进程已关闭输出。") }
            response.append(contentsOf: chunk.prefix(count))
            guard response.count <= 1024 * 1024 else { throw SceneError.invalid("SceneScript 响应超过 1 MiB。") }
            if let newline = response.firstIndex(of: 10) {
                guard newline == response.index(before: response.endIndex) else { throw SceneError.invalid("SceneScript 响应分帧无效。") }
                response.removeLast(); break
            }
        }
        guard let parsed = try JSONSerialization.jsonObject(with: response) as? [String: Any] else { throw SceneError.invalid("SceneScript 响应不是对象。") }
        return parsed
    }

    private func validateNativeResourceCall(_ message: [String: Any], sequence requestSequence: Int) throws -> (file: String, option: Bool?) {
        guard !stopped, case .inFlight(let id) = requestState, id == requestSequence,
              let method = message["method"] as? String, let arguments = message["arguments"] as? [String: Any],
              let binding = message["bindingKey"] as? String,
              (creationUpdate?.inventory.keys ?? inventoryUpdate?.inventory.keys ?? inventory.keys).contains(binding) else {
            throw SceneError.invalid("原生资源请求不属于当前活动脚本。")
        }
        nativeResourceCalls = min(1_000_000_000, nativeResourceCalls + 1)
        switch method {
        case "registerAsset":
            guard message["scope"] as? String == "module", let file = arguments["file"] as? String,
                  arguments["option"] == nil || (arguments["option"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else {
                throw SceneError.invalid("素材注册需要模块全局作用域、路径及可选布尔参数。")
            }
            return (file, arguments["option"] as? Bool)
        default: throw SceneError.invalid("尚未支持的原生资源请求：\(method)")
        }
    }

    private func validateCreationCall(_ message: [String: Any]) throws -> Data {
        guard creationHandler != nil, inventoryUpdate == nil, creationCount < 256,
              inventoryRevision + creationCount < 1_000_000_000,
              message["scope"] as? String == "callback", let arguments = message["arguments"] as? [String: Any],
              let binding = message["bindingKey"] as? String,
              (creationUpdate?.inventory.keys ?? inventory.keys).contains(binding),
              let configuration = arguments["configuration"], configuration is String || configuration is [String: Any] else {
            throw SceneError.invalid("当前调用尚不能创建图层：需要活动回调、可创建的渲染器和有效配置，且单批不超过 256 次。")
        }
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.fragmentsAllowed, .sortedKeys])
        guard data.count <= 1024 * 1024 else { throw SceneError.invalid("新图层配置超过 1 MiB。") }
        nativeResourceCalls = min(1_000_000_000, nativeResourceCalls + 1)
        return data
    }

    private func stageCreation(_ prepared: SceneScriptPreparedCreation) throws -> [String: Any] {
        let previous = creationUpdate?.inventory ?? inventory
        guard prepared.inventory.layerIDs == previous.layerIDs.union([prepared.id]), !previous.layerIDs.contains(prepared.id),
              Set(prepared.timelines.paths) == Set(prepared.inventory.timelineLimits.keys) else {
            throw SceneError.invalid("新图层资源清单与实际创建结果不一致。")
        }
        let retained = try prepared.inventory.retainedBindings(from: previous, retaining: previous.layerIDs)
        var message = try prepared.inventory.message()
        let models = prepared.models
        let expected = Set((message["layers"] as! [[String: Any]]).filter { $0["model"] as? Bool == true }.map { $0["id"] as! String })
        guard Set(models?.metadata.keys.map { $0 } ?? []) == expected else { throw SceneError.invalid("新图层模型元数据缺少实际资源。") }
        message["bindings"] = (message["bindings"] as! [[String: Any]]).map { binding in
            var binding = binding
            do {
                let (source, exports, imports) = try lowerModule(binding["source"] as! String)
                binding["source"] = source; binding["exports"] = exports; binding["imports"] = imports
            } catch { binding["prepareError"] = error.localizedDescription; binding.removeValue(forKey: "source") }
            return binding
        }
        message["models"] = models?.metadata ?? [:]
        message["modelStates"] = models?.states ?? [:]
        message["modelTransforms"] = models?.transforms ?? [:]
        message["modelSerial"] = models?.scriptSerial ?? 0
        message["timelineStates"] = prepared.timelines.scriptStates
        message["retainedBindings"] = retained.sorted()
        message["retainedLayerIDs"] = previous.layerIDs.sorted()
        message["inventoryRevision"] = inventoryRevision + creationCount + 1
        let result: [String: Any] = ["id": prepared.id, "inventory": message]
        guard try JSONSerialization.data(withJSONObject: result).count < 4 * 1024 * 1024 - 1024 else {
            throw SceneError.invalid("新图层脚本清单超过原生回应容量。")
        }
        creationUpdate = prepared; creationCount += 1
        maximumBindingCount = max(maximumBindingCount, prepared.inventory.count)
        return result
    }

    private func receive(_ result: Result<[String: Any], Error>, sequence requestSequence: Int, loading: Bool, operation: String, propertyKeys: [String]) {
        guard !stopped, case .inFlight(let id) = requestState, id == requestSequence, sequence == requestSequence else { return }
        watchdog?.cancel(); watchdog = nil
        lastReceivedRequestID = requestSequence
        if !loading && (suspended || publication == .renderFrame) {
            // Keep one bounded reply under backpressure until its consumer's
            // next running frame, even if it arrived just before the pause.
            deferredResponse = (result, requestSequence, loading, operation, propertyKeys)
            requestState = .deferred(requestSequence)
            if suspended {
                deferredResponseCount = min(1_000_000_000, deferredResponseCount + 1)
                fputs("SceneScript response deferred during pause: \(operation)\n", stderr)
            } else { frameDeferredResponseCount = min(1_000_000_000, frameDeferredResponseCount + 1) }
            return
        }
        commit(result, sequence: requestSequence, loading: loading, operation: operation, propertyKeys: propertyKeys)
    }

    private func commit(_ result: Result<[String: Any], Error>, sequence requestSequence: Int, loading: Bool, operation: String, propertyKeys: [String]) {
        guard !stopped, sequence == requestSequence, requestSequence > lastCommittedCommandRequestID else { return }
        switch requestState {
        case .inFlight(let id), .deferred(let id): guard id == requestSequence else { return }
        case .idle, .committed: return
        }
        // Initialization runs at scene time zero and may establish a paused
        // first image. Later frame/property responses retain the pause barrier.
        switch result {
        case .failure(let error): report(error.localizedDescription); stop()
        case .success(let response):
            for error in (response["errors"] as? [String] ?? []).prefix(128) { report(error) }
            guard response["ok"] as? Bool == true else { report("SceneScript 请求执行失败。"); stop(); return }
            let requestInventory = creationUpdate?.inventory ?? inventoryUpdate?.inventory ?? inventory
            var acceptedInventory = requestInventory
            var acceptedOrder = creationUpdate?.inventory.sceneLayerOrder ?? inventoryUpdate?.inventory.sceneLayerOrder ?? sceneLayerOrder
            let retired: Set<String>
            do {
                guard let ids = response["sceneRetirements"] as? [String], Set(ids).count == ids.count else {
                    throw SceneError.invalid("SceneScript 图层删除回执无效。")
                }
                retired = Set(ids)
                guard retired.count + creationCount <= NativeSceneLifecycle.maximumMutations else {
                    throw SceneError.invalid("本帧图层创建与删除合计超过 256 项。")
                }
                if !retired.isEmpty {
                    guard inventoryUpdate == nil, retirementHandler != nil else { throw SceneError.invalid("当前播放实例没有准备图层删除。") }
                    acceptedInventory = try requestInventory.retiring(retired)
                    acceptedOrder = acceptedInventory.sceneLayerOrder
                }
                guard NativeAnimationJSON.integer(response["inventoryProtocol"]) == 1,
                      NativeAnimationJSON.integer(response["inventoryRevision"]) == inventoryRevision + creationCount + ((inventoryUpdate != nil || !retired.isEmpty) ? 1 : 0) else {
                    throw SceneError.invalid("SceneScript 结构修订回执不匹配；保留现有场景。")
                }
            } catch { report(error.localizedDescription); stop(); return }
            let videoKeys = acceptedInventory.videoKeys, effectVisibilityPaths = acceptedInventory.effectVisibilityPaths
            let materialDimensions = acceptedInventory.materialDimensions
            // Deletion happens after this request's callbacks. Commands issued
            // before/during destroy still address the current native stores.
            let timelineLimits = retired.isEmpty ? acceptedInventory.timelineLimits : requestInventory.timelineLimits
            let requestModels = creationUpdate.map { $0.models } ?? inventoryUpdate.map { $0.models } ?? modelAnimations
            if inventoryUpdate != nil {
                guard NativeAnimationJSON.integer(response["inventoryProtocol"]) == 1,
                      NativeAnimationJSON.integer(response["inventoryRevision"]) == inventoryRevision + 1 else {
                    report("SceneScript 结构清单回执不匹配；保留原有场景资源。"); stop(); return
                }
            }
            guard NativeAnimationJSON.integer(response["sceneLayerProtocol"]) == 1,
                  let layerOrder = acceptedOrder.receipt(response["sceneLayerOrder"]) else {
                report("SceneScript 图层顺序回执不是完整且唯一的场景清单；整批未应用。"); stop(); return
            }
            guard NativeAnimationJSON.integer(response["scenePropertyProtocol"]) == 1,
                  let sceneValues = NativeSceneScriptProperties.receipt(response["sceneValues"]) else {
                report("SceneScript 场景属性回执类型或范围无效；该请求未应用。"); stop(); return
            }
            guard let rawVideos = response["videoTextures"] as? [String: [String: Any]], rawVideos.count <= 8,
                  Set(rawVideos.keys).isSubset(of: videoKeys) else {
                report("SceneScript 视频纹理回执无效；该请求未应用。"); stop(); return
            }
            var videos: [String: SceneVideoPlayback] = [:]
            for (key, raw) in rawVideos {
                guard let value = SceneVideoPlayback(raw) else { report("SceneScript 视频播放参数无效；该请求未应用。"); stop(); return }
                videos[key] = value
            }
            // Validate the complete effect snapshot before committing any
            // timeline commands or other response state. Only real consumers
            // supplied by this renderer are allowed to receive these writes.
            guard let rawEffects = response["effects"] as? [String: Any], rawEffects.count <= 4096,
                  Set(rawEffects.keys).isSubset(of: effectVisibilityPaths) else {
                report("SceneScript 效果可见性回执的路径无效；该请求未应用。"); stop(); return
            }
            var effects: [String: Bool] = [:]
            for (path, raw) in rawEffects {
                guard let value = NativeAnimationJSON.boolean(raw) else {
                    report("SceneScript 效果可见性不是布尔值；该请求未应用。"); stop(); return
                }
                effects[path] = value
            }
            guard let rawMaterials = response["materials"] as? [String: Any], rawMaterials.count <= 16384 else {
                report("SceneScript 材质参数回执无效；该请求未应用。"); stop(); return
            }
            var materialValues: [String: [Float]] = [:]
            for (path, raw) in rawMaterials {
                guard let count = materialDimensions[path], let components = raw as? [Any], components.count == count else {
                    report("SceneScript 材质参数回执的路径或维数无效；该请求未应用。"); stop(); return
                }
                var values: [Float] = []
                for component in components {
                    guard let number = NativeAnimationJSON.number(component), number.doubleValue.isFinite,
                          abs(number.doubleValue) <= 16384 else {
                        report("SceneScript 材质参数回执的数值无效；该请求未应用。"); stop(); return
                    }
                    values.append(number.floatValue)
                }
                materialValues[path] = values
            }
            if let media = pendingMedia {
                guard response["mediaRevision"] as? Int == media.revision else { report("SceneScript 媒体回执版本不匹配，保留上一份画面状态。"); stop(); return }
            }
            guard NativeAnimationJSON.number(response["timelineProtocol"])?.doubleValue == 2,
                  NativeAnimationJSON.number(response["requestID"])?.doubleValue == Double(requestSequence),
                  let rawCommands = response["timelineCommands"] as? [Any], rawCommands.count <= 256 else {
                report("SceneScript 时间轴协议、请求序号或命令数量无效。"); stop(); return
            }
            var commands: [SceneTimelineCommand] = []
            for (ordinal, raw) in rawCommands.enumerated() {
                guard let raw = raw as? [String: Any],
                      let command = SceneTimelineCommand(raw, ordinal: ordinal, lengths: timelineLimits) else {
                    report("SceneScript 时间轴命令顺序、路径或参数无效；整批未应用。"); stop(); return
                }
                commands.append(command)
            }
            // Validate all camera values before any command side effects.
            guard let camera = NativeScriptCamera.parse(response["camera"]) else {
                report("SceneScript 静态相机回执无效；该请求未应用。"); stop(); return
            }
            guard let eventCounts = response["animationEventCounts"] as? [String: Any],
                  NativeAnimationJSON.integer(eventCounts["received"]) == sentAnimationEvents,
                  let calls = NativeAnimationJSON.integer(eventCounts["calls"]),
                  calls >= animationCallbackCalls, calls <= min(1_000_000_000, sentAnimationEvents * maximumBindingCount) else {
                report("SceneScript 动画事件回执计数无效；该请求未应用。"); stop(); return
            }
            guard NativeAnimationJSON.integer(response["modelProtocol"]) == 1,
                  let modelCounts = response["modelEventCounts"] as? [String: Any],
                  NativeAnimationJSON.integer(modelCounts["received"]) == sentModelEvents,
                  let modelCalls = NativeAnimationJSON.integer(modelCounts["calls"]),
                  modelCalls >= modelCallbackCalls, modelCalls <= min(1_000_000_000, sentModelEvents * 32),
                  NativeAnimationJSON.integer(modelCounts["markers"]) == sentModelMarkers,
                  let markerCalls = NativeAnimationJSON.integer(modelCounts["markerCalls"]),
                  markerCalls >= modelMarkerCalls, markerCalls <= min(1_000_000_000, sentModelMarkers * maximumBindingCount) else {
                report("SceneScript 模型动画协议或事件回执无效；整批未应用。"); stop(); return
            }
            let commitRetirement: (() -> Void)?
            do {
                if let creation = creationUpdate { commitRetirement = try creation.prepareCommit(retired, response["sceneLayerOrder"] as! [String]) }
                else { commitRetirement = retired.isEmpty ? nil : try retirementHandler!(retired, response["sceneLayerOrder"] as! [String]) }
            } catch { report(error.localizedDescription); stop(); return }
            let commitModels: () -> Void
            do {
                if let requestModels { commitModels = try requestModels.prepare(response["modelCommands"], acknowledging: pendingModelEvents) }
                else {
                    guard let empty = response["modelCommands"] as? [Any], empty.isEmpty else { throw SceneError.invalid("当前渲染器未提供模型动画对象。") }
                    commitModels = {}
                }
            } catch { report(error.localizedDescription); stop(); return }
            let timelineAccepted = creationUpdate.map { $0.timelines.applyCommands(commands) } ?? inventoryUpdate.map { $0.timelines.applyCommands(commands) } ?? timelineCommandHandler(commands)
            guard timelineAccepted else {
                report("SceneScript 时间轴命令无法生成有限状态；整批未应用。"); stop(); return
            }
            commitModels()
            let commitResources = inventoryUpdate?.commitResources ?? commitRetirement
            if !retired.isEmpty {
                inventory = acceptedInventory; sceneLayerOrder = acceptedOrder
                if creationUpdate == nil { inventoryRevision += 1 }
                values = values.filter { inventory.keys.contains($0.key) }
                layerValues = layerValues.filter { !retired.contains($0.key) }
                texturePlayback = texturePlayback.filter { !retired.contains($0.key) }
                soundCommands.removeAll { retired.contains($0["id"] ?? "") }
                // Geometry from an earlier GPU frame may have queued input.
                // It cannot target an owner that no longer exists.
                events = events.compactMap { event in
                    var event = event
                    let ids = (event["objectIDs"] as? [String] ?? []).filter { !retired.contains($0) }
                    guard !ids.isEmpty else { return nil }
                    event["objectIDs"] = ids; return event
                }
            }
            if let creation = creationUpdate {
                let previousValues = values.filter { acceptedInventory.keys.contains($0.key) }
                inventory = acceptedInventory
                values = inventory.initialValues.merging(previousValues) { _, retained in retained }
                if timelineEvents !== creation.timelines { timelineEvents?.setEventDeliveryEnabled(false) }
                let next = creation.timelines
                timelineEvents = next; timelineStateProvider = { next.scriptStates }; timelineCommandHandler = { next.applyCommands($0) }
                modelAnimations = creation.models
                timelineEvents?.setEventDeliveryEnabled(true); modelAnimations?.enableEvents()
                sceneLayerOrder = acceptedOrder
                inventoryRevision += creationCount + (retired.isEmpty ? 0 : 1)
                creationUpdate = nil; creationCount = 0
            }
            if let update = inventoryUpdate {
                if timelineEvents !== update.timelines { timelineEvents?.setEventDeliveryEnabled(false) }
                if modelAnimations !== update.models { modelAnimations?.disableEvents() }
                let previousValues = values.filter { update.retainedBindings.contains($0.key) }
                inventory = update.inventory
                values = inventory.initialValues.merging(previousValues) { _, retained in retained }
                layerValues = layerValues.filter { update.retainedIDs.contains($0.key) }
                texturePlayback = texturePlayback.filter { update.retainedIDs.contains($0.key) }
                soundCommands = soundCommands.filter { update.retainedIDs.contains($0["id"] ?? "") }
                let nextTimelines = update.timelines
                timelineEvents = nextTimelines
                timelineStateProvider = { nextTimelines.scriptStates }
                timelineCommandHandler = { nextTimelines.applyCommands($0) }
                modelAnimations = update.models
                timelineEvents?.setEventDeliveryEnabled(true); modelAnimations?.enableEvents()
                sceneLayerOrder = update.inventory.sceneLayerOrder
                inventoryRevision += 1; inventoryUpdate = nil
            }
            modelCallbackCalls = modelCalls; committedModelEvents = sentModelEvents
            committedModelMarkers = sentModelMarkers; modelMarkerCalls = markerCalls
            staticCamera.commit(camera)
            self.sceneValues = sceneValues
            if let statistics = response["inventoryStatistics"] as? [String: Int],
               statistics.count <= 16, statistics.values.allSatisfy({ (0...16384).contains($0) }) {
                inventoryStatistics = statistics
            }
            sceneLayerOrder.commit(layerOrder)
            effectVisibilityValues = effects
            self.materialValues = materialValues
            videoPlayback = videos
            committedAnimationEvents = sentAnimationEvents; animationCallbackCalls = calls
            // Commit before releasing backpressure or delivering queued user
            // properties. The lifecycle rejects a duplicate I/O/deferred reply.
            lastCommittedCommandRequestID = requestSequence
            requestState = .committed(requestSequence)
            if !commands.isEmpty {
                committedTimelineBatches = min(1_000_000_000, committedTimelineBatches + 1)
                committedTimelineCommands = min(1_000_000_000, committedTimelineCommands + commands.count)
            }
            if let loaded = response["loadedBindings"] as? Int, (0...count).contains(loaded),
               let disabled = response["disabledBindings"] as? Int, (0...loaded).contains(disabled) {
                loadedBindingCount = loaded; disabledBindingCount = disabled
            }
            if !commands.isEmpty, reportedTimelineBatches < 128 {
                reportedTimelineBatches += 1
                fputs("SceneScript timeline commands committed: request \(requestSequence), \(commands.count) ordered commands\n", stderr)
            }
            // A timeline script that only handles events has no value override.
            // Clear its previous response before applying this complete snapshot.
            for key in timelineLimits.keys { values.removeValue(forKey: key) }
            if let incoming = response["values"] as? [String: Any] {
                for (key, value) in incoming where keys.contains(key) { values[key] = value }
            }
            if let incoming = response["layers"] as? [String: [String: Any]] {
                for (id, value) in incoming where layerIDs.contains(id) { layerValues[id] = value }
            }
            if let incoming = response["soundCommands"] as? [[String: String]] {
                for command in incoming.prefix(128) {
                    guard let id = command["id"], soundIDs.contains(id), let action = command["action"], ["play", "pause", "stop"].contains(action) else {
                        report("SceneScript 声音命令无效或引用未加载的声音层。"); continue
                    }
                    guard soundCommands.count < 256 else { report("SceneScript 声音命令队列已满。"); break }
                    soundCommands.append(["id": id, "action": action])
                }
            }
            if let incoming = response["textureAnimations"] as? [String: [String: Any]] {
                for (id, value) in incoming where layerIDs.contains(id) {
                    if let playback = SceneTexturePlayback(value) {
                        if !loading, texturePlayback[id] != playback {
                            fputs("SceneScript texture playback changed: layer \(id), joined \(playback.joined), playing \(playback.playing), position \(playback.position), rate \(playback.rate)\n", stderr)
                        }
                        texturePlayback[id] = playback
                    }
                }
                if loading, !incoming.isEmpty, let data = try? JSONSerialization.data(withJSONObject: incoming, options: [.sortedKeys]) {
                    fputs("SceneScript texture playback initialized: \(String(decoding: data, as: UTF8.self))\n", stderr)
                }
            }
            if let incoming = response["storage"] as? [String: Any], let storage {
                do { try storage.save(incoming) }
                catch { report("SceneScript 本地存储保存失败：\(error.localizedDescription)") }
            }
            if let media = pendingMedia {
                committedMedia = media; pendingMedia = nil
                if let counts = response["mediaDeliveryCounts"] as? [String: Int], counts != lastMediaDeliveryCounts {
                    let allowed: Set<String> = ["mediaStatusChanged","mediaPropertiesChanged","mediaThumbnailChanged","mediaPlaybackChanged","mediaTimelineChanged"]
                    let bounded = counts.filter { allowed.contains($0.key) && $0.value >= 0 && $0.value <= 1_000_000_000 }
                    if let data = try? JSONSerialization.data(withJSONObject: ["revision": media.revision, "enabled": media.enabled, "state": media.state, "hasThumbnail": media.artwork != nil, "handlerCalls": bounded], options: [.sortedKeys]) {
                        fputs("SceneScript media committed: \(String(decoding: data, as: UTF8.self))\n", stderr)
                    }
                    lastMediaDeliveryCounts = bounded
                }
            }
            if loading {
                ready = true
                let loaded = response["loadedBindings"] as? Int ?? 0
                let disabled = response["disabledBindings"] as? Int ?? 0
                fputs("SceneScript loaded: \(loaded)/\(count) bindings, \(disabled) disabled, isolated system JavaScriptCore helper\n", stderr)
                let audioRegistrations = response["audioRegistrations"] as? Int ?? 0
                fputs("SceneScript audio buffers registered: \(audioRegistrations); capture is controlled separately by the user\n", stderr)
            } else if operation == "properties" {
                fputs("SceneScript property callback delivered: \(propertyKeys.joined(separator: ","))\n", stderr)
            } else if operation == "frame", !reportedFrames {
                reportedFrames = true
                let incoming = (response["values"] as? [String: Any])?.count ?? 0
                fputs("SceneScript first frame: \(incoming) returned property values; \(values.count - incoming) retained initial values\n", stderr)
                let numeric = (response["values"] as? [String: Any] ?? [:]).filter { $0.value is NSNumber }
                if let data = try? JSONSerialization.data(withJSONObject: ["timeOfDay": response["timeOfDay"] ?? NSNull(), "numericValues": numeric], options: [.sortedKeys]), data.count <= 8192 {
                    fputs("SceneScript first numeric state: \(String(decoding: data, as: UTF8.self))\n", stderr)
                }
            }
            commitResources?()
            flushPropertyChanges()
            notifyInitialization()
        }
    }

    private func report(_ message: String) {
        let bounded = String(message.prefix(2048))
        guard diagnostics.count < 128, !diagnostics.contains(bounded) else { return }
        diagnostics.append(bounded)
        fputs("SceneScript compatibility: \(bounded)\n", stderr)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true; ready = false; requestState = .idle
        resourceTask?.cancel(); resourceTask = nil; activeNativeCall = nil; assetRegistry.close()
        deferredResponse = nil
        inventoryUpdate = nil
        creationUpdate = nil; creationCount = 0; preparingCreation = false
        pendingMedia = nil
        timelineEvents?.setEventDeliveryEnabled(false)
        modelAnimations?.disableEvents(); pendingModelEvents.removeAll()
        watchdog?.cancel(); watchdog = nil; events.removeAll(); propertyChanges.removeAll()
        // This is the Process instance we launched, never a name-based kill.
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close()
        notifyInitialization()
    }

    deinit {
        resourceTask?.cancel()
        timelineEvents?.setEventDeliveryEnabled(false)
        watchdog?.cancel()
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }
}
