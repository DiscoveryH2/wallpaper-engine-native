import Foundation

/// A stable owner for native model players. Property transactions may replace
/// renderer resources while the helper keeps this exact store and object IDs.
@MainActor final class NativeModelScriptStore {
    var players: [String: NativeModelAnimation.Runtime] = [:]
    var staticModelIDs = Set<String>()
    var resolve: (Any?) -> Any? = { ($0 as? [String: Any])?["value"] ?? $0 }
    private var serial = 0
    private var eventCursor = 0
    var scriptSerial: Int { serial }
    private(set) var committedCommands = 0

    /// A prepared inventory owns different players but shares the helper's
    /// monotonically increasing animation identity namespace. Copying counters
    /// does not rebind or mutate any player in the previous renderer.
    func inheritProtocol(from previous: NativeModelScriptStore) {
        guard self !== previous else { return }
        serial = max(serial, previous.serial)
        eventCursor = previous.eventCursor
        committedCommands = max(committedCommands, previous.committedCommands)
    }

    var metadata: [String: Any] {
        var result: [String: Any] = players.mapValues { player in
            ["rootMotion": player.hasRootMotion, "authoredKeys": player.source.layers.map(\.key), "clips": player.source.skeleton.clips.map { clip in
                ["id": String(clip.id), "name": clip.name, "fps": Double(clip.fps),
                 "frameCount": clip.frameCount, "mode": clip.mode, "initialFrame": clip.initialFrame,
                 "frameDuration": Double(1 / clip.fps), "duration": Double(Float(clip.frameCount) / clip.fps),
                 "events": clip.events.map(\.json)] as [String: Any]
            }] as [String: Any]
        }
        for id in staticModelIDs { result[id] = ["clips": [], "authoredKeys": []] as [String: Any] }
        return result
    }
    var states: [String: Any] {
        var result: [String: Any] = players.mapValues { $0.scriptState(resolve: resolve) }
        for id in staticModelIDs { result[id] = [] as [Any] }
        return result
    }
    var transforms: [String: Any] { players.compactMapValues { $0.motion?.scriptProperties } }
    func enableEvents() { for player in players.values { player.deliverEvents = true } }
    func disableEvents() { for player in players.values { player.disableEvents() } }
    func retire(_ ids: Set<String>) {
        for id in ids { players.removeValue(forKey: id)?.disableEvents(); staticModelIDs.remove(id) }
        // Preserve serial: earlier commands in this batch may have allocated
        // animation handles even on the models that have just been removed.
    }
    func takeEvents() throws -> [[String: Any]] {
        guard !players.values.contains(where: { $0.eventOverflow }) else { throw SceneError.invalid("模型动画事件超过队列上限。") }
        var result: [[String: Any]] = []
        let ids = players.keys.sorted()
        var emptyVisits = 0
        // Bounded batches retain overflow for later requests. Rotate owners so
        // one busy model cannot prevent another model's events from arriving.
        while result.count < 128, !ids.isEmpty, emptyVisits < ids.count {
            let id = ids[eventCursor % ids.count]
            eventCursor = (eventCursor + 1) % ids.count
            let events = players[id]!.takeEvents(maximum: 1)
            if events.isEmpty { emptyVisits += 1 } else { emptyVisits = 0 }
            for event in events {
                result.append(event.merging(["id": id]) { _, next in next })
            }
        }
        return result
    }

    /// Validate against current native clocks, never the older snapshot sent
    /// to the helper. No command mutates a player until the whole batch passes.
    func prepare(_ raw: Any?, acknowledging events: [[String: Any]] = []) throws -> () -> Void {
        guard let commands = raw as? [[String: Any]], commands.count <= 256 else { throw SceneError.invalid("模型动画命令需要有界数组。") }
        var drafts: [String: NativeModelAnimation.Runtime.Draft] = [:]
        var nextSerial = serial
        func invalid() -> SceneError { .invalid("模型动画命令顺序、对象、属性或参数无效；整批未应用。") }
        for (ordinal, command) in commands.enumerated() {
            guard NativeAnimationJSON.integer(command["ordinal"]) == ordinal,
                  let id = command["id"] as? String, let player = players[id],
                  let key = command["key"] as? String, key.utf8.count <= 128,
                  let action = command["action"] as? String else { throw invalid() }
            var draft = drafts[id] ?? player.draft
            if action == "transform" {
                guard player.hasRootMotion, Set(command.keys) == ["ordinal", "id", "key", "action", "value"],
                      ["origin", "angles", "rootmotion"].contains(key), let value = command["value"] else { throw invalid() }
                if key == "rootmotion" {
                    guard let flag = NativeAnimationJSON.boolean(value) else { throw invalid() }
                    draft.motionWrites[key] = flag
                } else {
                    let vector = SceneValues.floats(value)
                    guard vector.count == 3, vector.allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else { throw invalid() }
                    draft.motionWrites[key] = key == "angles" ? vector.map { $0 * .pi / 180 } : vector
                }
            } else if action == "create" {
                guard Set(command.keys) == ["ordinal", "id", "key", "action", "clip", "config", "single"],
                      nextSerial < 1_000_000_000, key == "script:\(nextSerial + 1)",
                      draft.layers.count < 32, !draft.layers.contains(where: { $0.key == key }),
                      let clipID = command["clip"] as? String,
                      let clip = player.source.skeleton.clips.first(where: { String($0.id) == clipID }),
                      let single = NativeAnimationJSON.boolean(command["single"]),
                      var config = command["config"] as? [String: Any],
                      Set(config.keys).isSubset(of: ["name", "rate", "blend", "visible", "additive", "blendin", "blendout", "blendtime", "autosort", "index"]) else { throw invalid() }
                if let name = config["name"] { guard let name = name as? String, name.utf8.count <= 4096 else { throw invalid() } }
                // Dynamic config is scalar: author code must not smuggle new
                // property links, scripts or resources through this protocol.
                for (name, value) in config where name != "name" {
                    guard NativeAnimationJSON.number(value) != nil || NativeAnimationJSON.boolean(value) != nil else { throw invalid() }
                }
                if config["blendin"] == nil { config["blendin"] = true }
                if config["blendout"] == nil { config["blendout"] = true }
                let layer = NativeModelAnimation.Layer(key: key, clip: clip, raw: config)
                _ = try layer.controls(resolve: { $0 })
                let insertion = try NativeModelAnimation.insertionIndex(config, count: draft.layers.count) { i in
                    try draft.layers[i].controls(samples: player.propertySamples[draft.layers[i].key] ?? [:], overrides: draft.states[i].overrides, resolve: resolve).additive
                }
                var state = NativeModelAnimation.State(clip: clip); state.single = single; state.removeAtEnd = single
                draft.layers.insert(layer, at: insertion); draft.states.insert(state, at: insertion)
                nextSerial += 1
            } else {
                guard let index = draft.layers.firstIndex(where: { $0.key == key }) else { throw invalid() }
                let layer = draft.layers[index]
                switch action {
                case "destroy":
                    guard Set(command.keys) == ["ordinal", "id", "key", "action"] else { throw invalid() }
                    if !key.hasPrefix("script:") { draft.removed.insert(key) }
                    draft.layers.remove(at: index); draft.states.remove(at: index)
                case "play", "pause", "stop", "setFrame", "rate":
                    var translated = command; translated.removeValue(forKey: "id"); translated.removeValue(forKey: "key")
                    translated["path"] = key; translated["ordinal"] = 0
                    guard let intent = SceneTimelineCommand(translated, ordinal: 0, lengths: [key: Double(layer.clip.frameCount)]),
                          draft.states[index].clock.apply(intent, frameDuration: 1 / layer.clip.fps) else { throw invalid() }
                    if action == "rate" { draft.states[index].overrides["rate"] = intent.value! }
                    if action == "stop" { draft.states[index].fadedIn = false }
                    if action == "setFrame" { draft.states[index].suppressEndedOnce = true }
                case "blend", "blendtime", "visible", "additive", "blendin", "blendout":
                    guard Set(command.keys) == ["ordinal", "id", "key", "action", "value"] else { throw invalid() }
                    if NativeModelProperties.flags.contains(action) {
                        guard let value = NativeAnimationJSON.boolean(command["value"]) else { throw invalid() }
                        draft.states[index].overrides[action] = value
                    } else {
                        let maximum: Float = action == "blendtime" ? 3600 : 1
                        guard let value = NativeAnimationJSON.number(command["value"])?.floatValue, value.isFinite, (0...maximum).contains(value) else { throw invalid() }
                        draft.states[index].overrides[action] = value
                    }
                default: throw invalid()
                }
            }
            drafts[id] = draft
            let total = players.reduce(0) { $0 + (drafts[$1.key]?.layers.count ?? $1.value.layers.count) }
            guard total <= 2048 else { throw SceneError.invalid("模型动画超过每场景 2048 层预算。") }
        }
        // Temporary layers remain addressable while their ended callback is
        // in flight. Retire them after that response commits, even if callback
        // code calls play(), matching reference destruction after callbacks.
        for event in events {
            if event["kind"] as? String == "marker" { continue }
            guard let id = event["id"] as? String, let key = event["key"] as? String, let player = players[id] else { throw invalid() }
            var draft = drafts[id] ?? player.draft
            if let index = draft.layers.firstIndex(where: { $0.key == key }), draft.states[index].pendingRemoval {
                draft.layers.remove(at: index); draft.states.remove(at: index); drafts[id] = draft
            }
        }
        return { [self] in
            for (id, draft) in drafts { players[id]!.commit(draft) }
            serial = nextSerial
            committedCommands = min(1_000_000_000, committedCommands + commands.count)
        }
    }
}
