import Foundation

/// Immutable, bounded inputs for the shared native Camera implementation.
/// Each renderer creates its own queue/pose state. Property transactions may
/// retain that state only when object identities and path definitions agree.
struct NativeMetalCameraObjects {
    private(set) var objects: [[String: Any]]
    let orthographic: Bool
    private(set) var documents: [String: [String: Any]]
    let properties: [String: Any]
    private(set) var signature: Data
    let diagnostics: [String]

    func retiring(to snapshot: NativeSceneLifecycle.Snapshot) throws -> Self {
        var next = self
        next.objects = try snapshot.applyingMembership(to: ["objects": objects])["objects"] as! [[String: Any]]
        let paths = Set(next.objects.filter { $0["camera"] is String }.compactMap { $0["path"] as? String })
        next.documents = documents.filter { paths.contains($0.key) }
        let identities = next.objects.enumerated().map { index, object -> [String: Any] in
            var value: [String: Any] = ["id": SceneScriptBridge.objectID(object, index: index)]
            for key in ["camera", "path", "parent"] { if let raw = object[key] { value[key] = raw } }
            return value
        }
        next.signature = try JSONSerialization.data(withJSONObject: ["identities": identities, "documents": next.documents, "orthographic": orthographic], options: [.sortedKeys])
        return next
    }

    init(objects: [[String: Any]], orthographic: Bool, assets: SceneAssets, properties: [String: Any]) throws {
        self.objects = objects; self.orthographic = orthographic; self.properties = properties
        var documents: [String: [String: Any]] = [:], bytes = 0
        func keys(_ value: [String: Any], _ allowed: Set<String>, _ label: String) throws {
            guard Set(value.keys).isSubset(of: allowed) else {
                throw SceneError.invalid("\(label)：未迁移的 Camera 路径字段 \(Set(value.keys).subtracting(allowed).sorted())。")
            }
        }
        func curve(_ raw: Any?) throws {
            guard let raw else { return }
            guard let entries = raw as? [Any], entries.count <= 65536 else { throw SceneError.invalid("Camera 曲线需要有界关键帧数组。") }
            for entry in entries {
                guard let key = entry as? [String: Any] else { throw SceneError.invalid("Camera 关键帧不是对象。") }
                try keys(key, ["frame", "value", "step", "back", "front"], "Camera 关键帧")
                for name in ["back", "front"] {
                    if let handle = key[name] as? [String: Any] { try keys(handle, ["enabled", "x", "y"], "Camera 曲线手柄") }
                }
            }
        }
        for object in objects where object["camera"] is String {
            guard let raw = object["path"] else { continue }
            guard let name = raw as? String else { throw SceneError.invalid("Camera path 必须为包内资源名称。") }
            if documents[name] != nil { continue }
            let data = try assets.data(name, maximumBytes: 4 * 1024 * 1024)
            guard data.count <= 16 * 1024 * 1024 - bytes else { throw SceneError.invalid("Metal Camera 路径资源合计超过 16 MiB。") }
            bytes += data.count
            guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let paths = document["paths"] as? [[String: Any]], paths.count <= 1024 else {
                throw SceneError.invalid("Camera 路径列表无效或超过 1024 项。")
            }
            try keys(document, ["paths"], name)
            for path in paths {
                try keys(path, ["name", "options", "center", "eye", "up", "zoom", "fov", "visible"], name)
                guard let options = path["options"] as? [String: Any] else { throw SceneError.invalid("Camera 路径缺少 options。") }
                try keys(options, ["name", "fps", "length", "mode", "startpaused", "wraploop", "random", "events"], name)
                _ = try NativeCameraAnimationGraph(options: options)
                if let visible = path["visible"] as? [String: Any] {
                    try keys(visible, ["value", "user"], "Camera 路径 visible")
                    guard visible["value"] as? Bool != nil else { throw SceneError.invalid("Camera 路径可见性需要布尔初始值。") }
                    if let user = visible["user"] as? [String: Any] {
                        try keys(user, ["name", "condition"], "Camera 路径属性条件")
                        guard user["name"] is String else { throw SceneError.invalid("Camera 路径属性条件缺少名称。") }
                    } else if visible["user"] != nil, !(visible["user"] is String) {
                        throw SceneError.invalid("Camera 路径属性绑定无效。")
                    }
                } else if path["visible"] != nil, !(path["visible"] is Bool) {
                    throw SceneError.invalid("Camera 路径 visible 需要布尔值或用户属性。")
                }
                for vector in ["center", "eye", "up"] {
                    if let raw = path[vector] {
                        guard let value = raw as? [String: Any] else { throw SceneError.invalid("Camera \(vector) 曲线无效。") }
                        try keys(value, ["c0", "c1", "c2"], "Camera \(vector)")
                        for channel in ["c0", "c1", "c2"] { try curve(value[channel]) }
                    }
                }
                try curve(path["zoom"]); try curve(path["fov"])
            }
            documents[name] = document
        }
        self.documents = documents
        let identities = objects.enumerated().map { index, object -> [String: Any] in
            var value: [String: Any] = ["id": SceneScriptBridge.objectID(object, index: index)]
            for key in ["camera", "path", "parent"] { if let raw = object[key] { value[key] = raw } }
            return value
        }
        signature = try JSONSerialization.data(withJSONObject: ["identities": identities, "documents": documents, "orthographic": orthographic], options: [.sortedKeys])
        let prepared = try NativeSceneCameras(objects: objects, orthographic: orthographic, loadJSON: { name in
            guard let document = documents[name] else { throw SceneError.invalid("未准备 Camera 路径资源。") }
            return document
        })
        let expected = objects.filter { $0["camera"] is String }.reduce(0) { total, object in
            total + ((object["path"] as? String).flatMap { documents[$0]?["paths"] as? [Any] }?.count ?? 0)
        }
        guard prepared.loadedPathCount == expected else {
            throw SceneError.invalid("Metal Camera 路径未完整加载：" + prepared.diagnostics.joined(separator: " "))
        }
        diagnostics = prepared.diagnostics
    }

    func makeRuntime() throws -> NativeSceneCameras {
        try NativeSceneCameras(objects: objects, orthographic: orthographic, loadJSON: { name in
            guard let document = documents[name] else { throw SceneError.invalid("未准备 Camera 路径资源。") }
            return document
        })
    }

    func retainedCameraSlots(from previous: Self, slots: Set<Int>) throws -> Set<Int> {
        guard orthographic == previous.orthographic else { return [] }
        var result = Set<Int>()
        func data(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        for slot in slots where objects.indices.contains(slot) && previous.objects.indices.contains(slot) {
            let current = objects[slot], old = previous.objects[slot]
            guard current["camera"] is String, old["camera"] is String,
                  SceneScriptBridge.objectID(current, index: slot) == SceneScriptBridge.objectID(old, index: slot),
                  try data(current) == data(old) else { continue }
            if let path = current["path"] as? String {
                guard let next = documents[path], let before = previous.documents[path], try data(next) == data(before) else { continue }
            }
            result.insert(slot)
        }
        return result
    }

    func resolveVisibility(_ raw: Any?) -> Any? {
        guard let value = raw as? [String: Any], let fallback = value["value"] else { return raw }
        if let key = value["user"] as? String { return (properties[key] as? [String: Any])?["value"] ?? fallback }
        if let user = value["user"] as? [String: Any], let key = user["name"] as? String,
           let current = (properties[key] as? [String: Any])?["value"] {
            return user["condition"].map { String(describing: current) == String(describing: $0) } ?? current
        }
        return fallback
    }
}
