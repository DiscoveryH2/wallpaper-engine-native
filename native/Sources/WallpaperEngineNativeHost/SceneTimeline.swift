import Foundation

/// Numeric inline curves from the scene document. Time uses the renderer's
/// pause-aware monotonic clock; file rotations remain in radians.
final class SceneTimelines {
    private struct Track {
        let channels: [Int: NativeAnimationCurve]
        let fps: Double, length: Double
        let mode: String, relative: Bool, paused: Bool, wrapLoop: Bool
        let frameDuration: Float, duration: Float
        let name: String
        let parentKey: String?
        let events: [(time: Float, json: String)]
    }
    private var tracks: [String: Track] = [:]
    private var sourceProperties: [String: Any] = [:]
    private var objectIDs: [Int: String] = [:]
    private var playback: [String: SceneTimelinePlayback] = [:]
    /// The reference renderer samples a child's curves with its parent's graph.
    /// Script adapters still address the individual link's own (dormant) graph.
    private var clockOwners: [String: String] = [:]
    private var clockPaths: [String] { paths.filter { clockOwners[$0] == $0 } }
    private var clockSceneTime = 0.0
    private var hasAdvancedClock = false
    private var clockAdvances = 0
    private var clockResets = 0
    private var invalidClockSteps = 0
    private var commandCounts: [String: [String: Int]] = [:]
    private var commandBatches = 0
    private var nextReportTime = 0.0
    private var lastSamples: [String: [String: Any]] = [:]
    private var invalidPaths = Set<String>()
    private var eventDeliveryEnabled = false
    private var pendingEvents: [[String: Any]] = []
    private var queuedEvents = 0, sentEvents = 0, droppedEvents = 0
    var eventStatistics: [String: Int] {
        ["defined": clockPaths.reduce(0) { $0 + (tracks[$1]?.events.count ?? 0) },
         "authored": tracks.values.reduce(0) { $0 + $1.events.count }, "queued": queuedEvents,
         "sent": sentEvents, "pending": pendingEvents.count, "dropped": droppedEvents]
    }

    func setEventDeliveryEnabled(_ enabled: Bool) {
        eventDeliveryEnabled = enabled
        if !enabled { pendingEvents.removeAll(keepingCapacity: true) }
    }

    /// Keep survivor clocks in place, including their exact Float state and
    /// queued events. Commands for this request have already been committed.
    func retire(retainingSlots slots: Set<Int>) {
        func keep(_ path: String) -> Bool { NativeSceneLifecycle.Snapshot.retains(path: path, slots: slots) }
        tracks = tracks.filter { keep($0.key) }; sourceProperties = sourceProperties.filter { keep($0.key) }
        playback = playback.filter { keep($0.key) }; clockOwners = clockOwners.filter { keep($0.key) }
        objectIDs = objectIDs.filter { slots.contains($0.key) }
        commandCounts = commandCounts.filter { keep($0.key) }; lastSamples = lastSamples.filter { keep($0.key) }
        invalidPaths = invalidPaths.filter(keep)
        let before = pendingEvents.count
        pendingEvents.removeAll { !keep($0["path"] as? String ?? "") }
        droppedEvents = min(1_000_000_000, droppedEvents + before - pendingEvents.count)
    }

    /// Drain only when the bridge can accept a new frame. Property messages,
    /// pointer resets, helper backpressure and suspension leave this FIFO intact.
    func takeEvents(limit: Int = 128) -> [[String: Any]] {
        let count = min(pendingEvents.count, max(0, min(128, limit)))
        let result = Array(pendingEvents.prefix(count))
        pendingEvents.removeFirst(count)
        sentEvents = min(1_000_000_000, sentEvents + count)
        return result
    }
    private(set) var diagnostics: [String] = []
    /// Informational composition notes are distinct from unsupported behavior.
    /// Strict renderers reject the latter without matching localized text.
    private(set) var unsupportedDiagnostics: [String] = []
    var paths: [String] { tracks.keys.sorted() }
    var playingCount: Int { clockPaths.filter { tracks[$0]?.paused == false }.count }
    /// Runtime state for demand-driven renderers. Completed single graphs and
    /// paused graphs do not require repeated frames just to display their value.
    var needsFrameUpdates: Bool { clockPaths.contains { playback[$0].map { $0.playing && $0.rate != 0 } == true } }

    init(scene: [String: Any]) {
        var keyCount = 0, eventCount = 0, eventBytes = 0
        func unsupported(_ message: String) {
            diagnostics.append(message); unsupportedDiagnostics.append(message)
        }
        for (index, object) in (scene["objects"] as? [[String: Any]] ?? []).enumerated() {
            objectIDs[index] = (object["id"] as? NSNumber)?.stringValue ?? object["id"] as? String ?? "object-\(index)"
        }
        func collect(_ value: Any, path: String, depth: Int) {
            guard depth <= 32 else { return }
            if let object = value as? [String: Any] {
                if let animation = object["animation"] as? [String: Any] {
                    do {
                        guard tracks.count < 128 else { throw SceneError.invalid("超过 128 条时间轴上限。") }
                        let track = try Self.decode(animation, authoredValue: object["value"], keyCount: &keyCount, eventCount: &eventCount, eventBytes: &eventBytes)
                        tracks[path] = track
                        playback[path] = SceneTimelinePlayback(paused: track.paused)
                        sourceProperties[path] = object
                        let options = animation["options"] as? [String: Any] ?? [:]
                        if NativeAnimationJSON.boolean(options["random"]) == true { unsupported("\(path)：时间轴 random 标志尚未实现。") }
                        if object["script"] != nil { diagnostics.append("\(path)：时间轴与脚本共用属性；明确返回的脚本值优先，只有事件回调的脚本不覆盖曲线。") }
                    } catch { unsupported("\(path)：时间轴未加载：\(error.localizedDescription)") }
                }
                for key in object.keys.sorted() where !["animation", "script"].contains(key) {
                    let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    collect(object[key]!, path: path + "/" + escaped, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                for (index, item) in array.enumerated() { collect(item, path: path + "/\(index)", depth: depth + 1) }
            }
        }
        collect(scene, path: "", depth: 0)
        // RegisterPropertyLink resolves only a root on the same property owner,
        // by registered property key, including roots declared after children.
        // It is not a recursive parent graph; unresolved links keep their own
        // clock in compatibility rendering and are rejected by strict Metal.
        for path in paths {
            clockOwners[path] = path
            guard let key = tracks[path]?.parentKey else { continue }
            let owner = path.split(separator: "/").dropLast().joined(separator: "/")
            let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            let parent = "/" + owner + "/" + escaped
            guard parent != path, let root = tracks[parent], root.parentKey == nil else {
                unsupported("\(path)：联合时间轴 parent.key=\(key) 未找到同一属性对象上的独立主时间轴；兼容渲染使用自身时钟。")
                continue
            }
            clockOwners[path] = parent
            diagnostics.append("\(path)：曲线共用 \(parent) 的采样时钟；脚本动画对象仍保留自身状态。")
        }
    }

    private static func components(_ value: Any?) -> [Double]? {
        let result: [Double]
        if let number = NativeAnimationJSON.number(value) { result = [number.doubleValue] }
        else if let text = value as? String {
            let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            let numbers = parts.compactMap { Double($0) }
            guard numbers.count == parts.count else { return nil }
            result = numbers
        } else if let array = value as? [Any] {
            let numbers = array.compactMap { NativeAnimationJSON.number($0)?.doubleValue }
            guard numbers.count == array.count else { return nil }
            result = numbers
        } else { return nil }
        guard (1...4).contains(result.count), result.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { return nil }
        return result
    }

    /// Prepare a replacement inventory without changing the old store. Reuse
    /// is keyed by property definition AND stable object identity. A new layer
    /// occupying a retired slot starts at zero, even when its curve is equal.
    /// The caller supplies the scene time of the structural commit, so a new
    /// curve never catches up the wallpaper's entire previous lifetime.
    func preserveRuntime(from previous: SceneTimelines, retainingSlots: Set<Int>, at time: Double) throws {
        guard time.isFinite, time >= 0, time <= 1e9 else { throw SceneError.invalid("场景图层变更的时间无效。") }
        func eligible(_ path: String) -> Bool {
            let parts = path.split(separator: "/")
            if parts.first == "objects" {
                guard parts.count >= 3, let slot = Int(parts[1]), retainingSlots.contains(slot),
                      let id = objectIDs[slot], previous.objectIDs[slot] == id else { return false }
            }
            guard let current = sourceProperties[path], let old = previous.sourceProperties[path],
                  clockOwners[path] == previous.clockOwners[path],
                  let currentData = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]),
                  let oldData = try? JSONSerialization.data(withJSONObject: old, options: [.sortedKeys]) else { return false }
            return currentData == oldData
        }
        let retained = Set(paths.filter(eligible))
        for path in retained {
            playback[path] = previous.playback[path]
            commandCounts[path] = previous.commandCounts[path]
        }
        clockSceneTime = time; hasAdvancedClock = true
        clockAdvances = previous.clockAdvances; clockResets = previous.clockResets
        invalidClockSteps = previous.invalidClockSteps; commandBatches = previous.commandBatches
        nextReportTime = time
        eventDeliveryEnabled = previous.eventDeliveryEnabled
        pendingEvents = previous.pendingEvents.filter { ($0["path"] as? String).map(retained.contains) ?? false }
        queuedEvents = previous.queuedEvents; sentEvents = previous.sentEvents
        droppedEvents = min(1_000_000_000, previous.droppedEvents + previous.pendingEvents.count - pendingEvents.count)
    }

    private static func decode(_ animation: [String: Any], authoredValue: Any?, keyCount: inout Int, eventCount: inout Int, eventBytes: inout Int) throws -> Track {
        guard let options = animation["options"] as? [String: Any],
              let number = NativeAnimationJSON.number(options["fps"]), number.floatValue.isFinite,
              number.floatValue > 0, number.floatValue <= 1000,
              let frameCount = NativeAnimationJSON.integer(options["length"]), frameCount > 0, frameCount <= 1_000_000_000 else {
            throw SceneError.invalid("时间轴 fps/length 无效，或超过原生 1000 fps / 1000000000 帧上限。")
        }
        let fps = number.floatValue, step: Float = 1 / fps, duration = Float(frameCount) / number.floatValue
        guard step.isFinite, step > 0, duration.isFinite, duration > 0 else {
            throw SceneError.invalid("时间轴时长不能用有限正数表示。")
        }
        let requestedMode = (options["mode"] as? String ?? "").lowercased()
        let mode = ["mirror", "single"].contains(requestedMode) ? requestedMode : "loop"
        let wrap = NativeAnimationJSON.boolean(options["wraploop"]) == true
        // CreatePropertyLinks converts authored 3-vector strings BEFORE parsing
        // curves. Presence of the relative member is the reference condition;
        // runtime/user/script values must not become a moving relative base.
        var relativeBase: [Double]?
        if animation["relative"] != nil, let text = authoredValue as? String {
            guard let values = components(text), values.count == 3 else {
                throw SceneError.invalid("relative 时间轴需要受支持的三分量作者值字符串。")
            }
            relativeBase = values
        }
        var channels: [Int: NativeAnimationCurve] = [:]
        for channel in 0..<4 {
            // ParseAnimation consumes contiguous c0...c3 arrays and stops at
            // the first missing/non-array channel. An empty curve yields zero.
            guard let entries = animation["c\(channel)"] as? [Any] else { break }
            guard entries.count <= 2048 else { throw SceneError.invalid("时间轴关键帧超过单通道 2048 项读取上限。") }
            let offset = channel < 3 ? relativeBase.map { Float($0[channel]) } : nil
            channels[channel] = try NativeAnimationCurve(entries, wrapAt: wrap ? frameCount : nil,
                inspectedKeys: &keyCount, keyLimit: 32768, valueOffset: offset)
        }
        guard !channels.isEmpty else { throw SceneError.invalid("时间轴缺少从 c0 开始的数值通道数组。") }
        let name = options["name"] as? String ?? ""
        guard name.utf8.count <= 1024 else { throw SceneError.invalid("时间轴名称超过 1 KiB。") }
        var parentKey: String?
        if let parent = options["parent"] {
            guard let reference = parent as? [String: Any], let key = reference["key"] as? String,
                  key.utf8.count <= 1024 else { throw SceneError.invalid("联合时间轴 parent 需要含有界字符串 key 的对象。") }
            parentKey = key.isEmpty ? nil : key
        }
        let entries = options["events"] as? [Any] ?? []
        guard entries.count <= 256, eventCount + entries.count <= 4096 else {
            throw SceneError.invalid("时间轴事件超过单轨 256 / 场景 4096 项上限。")
        }
        var events: [(time: Float, json: String)] = []
        var bytes = 0
        for entry in entries {
            // ParseAnimationEvents skips records without a string name and a
            // numeric frame; it preserves order, fractional frames and JSON.
            guard let event = entry as? [String: Any], let name = event["name"] as? String,
                  let frame = NativeAnimationJSON.number(event["frame"]) else { continue }
            let time = frame.floatValue * step
            guard name.utf8.count <= 1024, frame.doubleValue.isFinite, abs(frame.doubleValue) <= 1e9,
                  time.isFinite, JSONSerialization.isValidJSONObject(event) else {
                throw SceneError.invalid("时间轴事件名称、帧号或 JSON 数据超过受支持范围。")
            }
            let data = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
            bytes += data.count
            guard data.count <= 4096, eventBytes + bytes <= 256 * 1024 else {
                throw SceneError.invalid("时间轴事件超过单项 4 KiB / 场景 256 KiB 上限。")
            }
            events.append((time, String(decoding: data, as: UTF8.self)))
        }
        eventCount += entries.count; eventBytes += bytes
        return Track(channels: channels, fps: Double(fps), length: Double(frameCount), mode: mode,
            relative: relativeBase != nil, paused: NativeAnimationJSON.boolean(options["startpaused"]) == true,
            wrapLoop: wrap, frameDuration: step, duration: duration, name: name, parentKey: parentKey, events: events)
    }

    /// Only the render boundary advances clocks. Repeated property reads,
    /// helper requests and diagnostics cannot consume elapsed time again.
    func advance(to time: Double) {
        guard !tracks.isEmpty else { return }
        guard time.isFinite, time >= 0, time <= 1e9 else {
            invalidClockSteps = min(1_000_000_000, invalidClockSteps + 1); return
        }
        if time < clockSceneTime {
            clockResets = min(1_000_000_000, clockResets + 1)
            clockSceneTime = time; return
        }
        guard time > clockSceneTime || !hasAdvancedClock else { return }
        let delta = Float(time - clockSceneTime)
        hasAdvancedClock = true
        clockSceneTime = time
        clockAdvances = min(1_000_000_000, clockAdvances + 1)
        for path in clockPaths {
            guard let track = tracks[path], var state = playback[path] else { continue }
            var windows: [SceneTimelineEventWindow] = []
            if state.advance(delta: delta, duration: track.duration, mode: track.mode, eventWindows: &windows) {
                playback[path] = state
                if eventDeliveryEnabled {
                    for window in windows {
                        for (index, event) in track.events.enumerated() where window.contains(event.time) {
                            guard pendingEvents.count < 1024 else {
                                droppedEvents = min(1_000_000_000, droppedEvents + 1); continue
                            }
                            pendingEvents.append(["path": path, "eventIndex": index])
                            queuedEvents = min(1_000_000_000, queuedEvents + 1)
                        }
                    }
                }
            } else {
                invalidClockSteps = min(1_000_000_000, invalidClockSteps + 1)
            }
        }
    }

    /// Called synchronously by the bridge's successful response commit, before
    /// it can send queued property callbacks. A batch is atomic and ordered.
    func applyCommands(_ commands: [SceneTimelineCommand]) -> Bool {
        guard commands.count <= 256 else { return false }
        guard !commands.isEmpty else { return true }
        var updated = playback
        for command in commands {
            guard let track = tracks[command.path], var state = updated[command.path],
                  state.apply(command, frameDuration: track.frameDuration) else { return false }
            updated[command.path] = state
        }
        playback = updated
        commandBatches = min(1_000_000_000, commandBatches + 1)
        for command in commands {
            let name = command.action.rawValue
            let previousCount = commandCounts[command.path]?[name] ?? 0
            commandCounts[command.path, default: [:]][name] = min(1_000_000_000, previousCount + 1)
        }
        return true
    }

    private func sampledValue(at path: String, time: Double, base: Any?, record: Bool) -> Any? {
        guard let track = tracks[path], time.isFinite else { return nil }
        guard let clockPath = clockOwners[path], let clock = tracks[clockPath], let state = playback[clockPath] else { return nil }
        var snapshot = state.json
        snapshot.merge(["sceneTime": time, "clockSceneTime": clockSceneTime, "playing": state.playing,
            "applied": true, "relativeAtLoad": track.relative, "clockPath": clockPath,
            "commands": commandCounts[path] ?? [:]]) { _, next in next }
        func fail(_ reason: String) -> Any? {
            if record { invalidPaths.insert(path); snapshot["status"] = reason; lastSamples[path] = snapshot }
            return nil
        }
        guard let initial = Self.components(base), initial.count == track.channels.count else {
            return fail("属性数值维数与曲线通道数不匹配")
        }
        guard let blend = state.sample(length: Int(clock.length), frameDuration: clock.frameDuration) else { return fail("无效的帧采样位置") }
        var result = [Double](repeating: 0, count: initial.count)
        for (channel, curve) in track.channels {
            guard let value = curve.value(sample: blend, fallback: 0) else { return fail("非有限曲线输出") }
            result[channel] = Double(value)
        }
        let output: Any = result.count == 1 ? result[0] : result
        if record {
            snapshot["frame"] = Double(state.time / clock.frameDuration)
            snapshot["current"] = blend.frame; snapshot["next"] = blend.next
            snapshot["fraction"] = blend.fraction; snapshot["value"] = output; snapshot["status"] = "sampled"
            lastSamples[path] = snapshot
        }
        return output
    }

    func value(at path: String, time: Double, base: Any?) -> Any? {
        sampledValue(at: path, time: time, base: base, record: true)
    }

    /// Cached samples from actual renderer/helper-input requests only. Opening
    /// the compatibility panel neither samples nor advances the scene clock.
    var runtimeDiagnostic: String? {
        guard !tracks.isEmpty else { return nil }
        var lines = ["属性时间轴运行：\(tracks.count) 条，整数帧曲线＋帧间混合；wraploop \(tracks.values.filter { $0.wrapLoop }.count) 条；发生无效采样的路径 \(invalidPaths.count) 条。以下为脚本覆盖前的最后采样。",
            "属性时间轴时钟：\(clockPaths.count) 个主时钟，\(tracks.count - clockPaths.count) 条关联曲线；原生 Float 逐帧推进 \(clockAdvances) 次，场景时间 \(clockSceneTime) 秒；时钟回退 \(clockResets)，无效计时步 \(invalidClockSteps)；已提交命令批次 \(commandBatches)。脚本命令操作各自属性的动画对象；关联曲线仍从主时钟采样。"]
        for path in paths.prefix(16) {
            guard let sample = lastSamples[path], let data = try? JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) else { continue }
            lines.append(path + "：" + String(decoding: data, as: UTF8.self))
        }
        if eventStatistics["defined", default: 0] > 0 {
            lines.append("动画事件：主时钟定义 \(eventStatistics["defined"]!)，文件定义 \(eventStatistics["authored"]!)，入队 \(queuedEvents)，已发送 \(sentEvents)，待发送 \(pendingEvents.count)，溢出丢弃 \(droppedEvents)。单轨保持作者顺序；跨主时钟按属性路径排序。")
        }
        if tracks.count > 16 { lines.append("仅显示前 16 条时间轴。") }
        return lines.joined(separator: "\n")
    }

    var scriptMetadata: [[String: Any]] {
        paths.compactMap { path in
            guard let track = tracks[path] else { return nil }
            let parts = path.split(separator: "/").map(String.init)
            let id = parts.count >= 3 && parts[0] == "objects" ? objectIDs[Int(parts[1]) ?? -1] ?? "" : ""
            return ["path": path, "objectID": id, "ownerPath": path.split(separator: "/").dropLast().map(String.init).joined(separator: "/"),
                    "clockPath": clockOwners[path] ?? path,
                    "layerProperty": parts.count == 3 && parts[0] == "objects" ? parts[2] : "",
                    "fps": track.fps, "length": track.length, "mode": track.mode, "name": track.name, "startpaused": track.paused,
                    "frameDuration": Double(track.frameDuration), "duration": Double(track.duration), "events": track.events.map(\.json)]
        }
    }

    var scriptStates: [String: [String: Any]] { playback.mapValues(\.json) }

    func scriptInput(at time: Double, resolveBase: (Any?) -> Any?) -> [String: Any] {
        var result: [String: Any] = [:]
        for path in paths {
            guard let value = value(at: path, time: time, base: resolveBase(sourceProperties[path])) else { continue }
            let parts = path.split(separator: "/")
            if parts.count == 3, parts[0] == "objects", parts[2] == "angles", let angles = value as? [Double] {
                result[path] = angles.map { $0 * 180 / .pi }
            } else { result[path] = value }
        }
        return result
    }

    func observation(at time: Double, context: [String: Any]) -> String? {
        guard !tracks.isEmpty, time >= nextReportTime else { return nil }
        // Short authored one-shot curves need an observable startup trajectory.
        // After two scene seconds, return to the existing sparse schedule.
        nextReportTime = time + (time < 2 ? 0.1 : time < 30 ? 5 : 60)
        let states = paths.compactMap { path -> [String: Any]? in
            guard let track = tracks[path] else { return nil }
            guard let clockPath = clockOwners[path], let graph = tracks[clockPath], let clock = playback[clockPath] else { return nil }
            let frame = clock.time / graph.frameDuration
            let base = (sourceProperties[path] as? [String: Any])?["value"]
            return ["path": path, "name": track.name, "frame": frame.isFinite ? Double(frame) as Any : NSNull(),
                    "clockPath": clockPath, "graph": clock.json, "scriptGraph": playback[path]?.json ?? [:], "playing": clock.playing, "applied": true,
                    "commands": commandCounts[path] ?? [:],
                    "mode": graph.mode, "length": graph.length, "fps": graph.fps,
                    "authoredBaseSample": sampledValue(at: path, time: time, base: base, record: false) ?? base ?? NSNull()]
        }
        var observation: [String: Any] = ["sceneTime": time, "clockSceneTime": clockSceneTime,
            "clockAdvances": clockAdvances, "clockResets": clockResets, "invalidClockSteps": invalidClockSteps,
            "commandBatches": commandBatches, "events": eventStatistics, "tracks": states]
        observation.merge(context) { _, next in next }
        guard let data = try? JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

}
