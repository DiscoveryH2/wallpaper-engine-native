import Foundation
import CryptoKit

/// These values have one owner during preparation; the immutable result crosses
/// from the resource queue to the main actor only after preparation completes.
final class NativeSceneCreationPlan: @unchecked Sendable {
    let project: WallpaperProject
    let properties: [String: Any]
    let snapshot: NativeSceneLifecycle.Snapshot
    let id: String
    init(projectURL: URL, properties: Data, snapshot: NativeSceneLifecycle.Snapshot, configuration: Data) throws {
        project = try WallpaperProject.load(from: projectURL)
        self.properties = try JSONSerialization.jsonObject(with: properties) as! [String: Any]
        let raw = try JSONSerialization.jsonObject(with: configuration, options: [.fragmentsAllowed])
        var object: [String: Any]
        if let value = raw as? [String: Any] { object = value }
        else if let text = raw as? String {
            if let data = text.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { object = value }
            else {
                guard !text.isEmpty, text.utf8.count <= 4096 else { throw SceneError.invalid("创建素材路径为空或超过 4096 字节。") }
                let path = text.lowercased()
                if path.hasPrefix("models/") { object = [path.hasSuffix(".json") ? "image" : "model": text] }
                else if path.hasPrefix("particles/") { object = ["particle": text] }
                else if path.hasPrefix("sounds/") { object = ["sound": text] }
                else { throw SceneError.invalid("该素材入口尚未接入原生图层创建，请提供场景图层配置。") }
            }
        } else { throw SceneError.invalid("创建图层需要 JSON 对象、JSON 字符串或素材路径。") }
        let kinds = ["image", "text", "particle", "model", "sound", "camera", "light"]
            .filter { object[$0] != nil }
        guard kinds.count == 1 || NativeSceneTransformNode.matches(object) else {
            throw SceneError.invalid("新图层必须是受支持的场景对象或纯变换节点。")
        }
        var id: String
        repeat { id = String(UInt64.random(in: (1 << 53)...UInt64.max)) } while snapshot.handle(id: id) != nil
        object.removeValue(forKey: "id")
        if object["name"] == nil { object["name"] = "Created layer" }
        self.id = id
        self.snapshot = try NativeSceneLifecycle(snapshot: snapshot).prepare(inserting: [.init(id: id, configuration: object)]).snapshot
    }
}

final class NativePreparedSceneCreation: @unchecked Sendable {
    let plan: NativeSceneCreationPlan
    let source: NativeMetalSceneSource
    init(plan: NativeSceneCreationPlan, source: NativeMetalSceneSource) { self.plan = plan; self.source = source }
}

/// The worker owns these decoded values until handing them to the GL owner.
/// No OpenGL context or resource is created on the worker queue.
final class NativePreparedOpenGLSceneCreation: @unchecked Sendable {
    let plan: NativeSceneCreationPlan
    let assets: SceneAssets
    let scene: [String: Any]
    let expandedSceneJSON: Data
    let decoded: NativeOpenGLPreparedResources
    let authoredFileSignature: Data
    init(plan: NativeSceneCreationPlan, builtins: NativeBuiltinTextures.Snapshot?, supportsBC3: Bool,
         existingModels: Set<String>, existingTextures: Set<String>, previousAssets: SceneAssets,
         retainedModelPaths: [String: [String]], cancellation: NativeResourceCancellation, preferredMip: Int = 0) throws {
        self.plan = plan
        let assets = try SceneAssets(directory: plan.project.directoryURL)
        self.assets = assets
        let original = try assets.json(plan.project.resourceURL.path.replacingOccurrences(of: plan.project.directoryURL.path + "/", with: ""))
        authoredFileSignature = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])))
        decoded = try NativeOpenGLPreparedResources(plan: plan, assets: assets, builtins: builtins,
            supportsBC3: supportsBC3, existingModels: existingModels, existingTextures: existingTextures,
            previousAssets: previousAssets, retainedModelPaths: retainedModelPaths,
            cancellation: cancellation, preferredMip: preferredMip)
        scene = decoded.scene
        expandedSceneJSON = try JSONSerialization.data(withJSONObject: scene, options: [.sortedKeys])
    }
}

@MainActor
final class SceneScriptPreparedCreation {
    let id: String
    let inventory: SceneScriptInventory
    let timelines: SceneTimelines
    let models: NativeModelScriptStore?
    let next: SceneScriptBridge.CreationHandler
    let prepareCommit: SceneScriptBridge.RetirementHandler
    init(id: String, inventory: SceneScriptInventory, timelines: SceneTimelines, models: NativeModelScriptStore?,
         next: @escaping SceneScriptBridge.CreationHandler, prepareCommit: @escaping SceneScriptBridge.RetirementHandler) {
        self.id = id; self.inventory = inventory; self.timelines = timelines; self.models = models
        self.next = next; self.prepareCommit = prepareCommit
    }
}
