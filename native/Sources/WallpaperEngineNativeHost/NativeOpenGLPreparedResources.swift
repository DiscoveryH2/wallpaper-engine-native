import Foundation

struct NativeOpenGLPreparationStatistics: Sendable {
    var workerWasMainThread = false
    var decodedModels = 0
    var reusedModelMaterialInventories = 0
    var cachedModels = 0
    var modelBytes = 0
    var decodedTextures = 0
    var cachedTextureBytes = 0
    var skippedTextures = 0
    var graphLimitReached = false
    var modelCacheHits = 0
    var textureCacheHits = 0
    var modelFallbackDecodes = 0
    var textureFallbackDecodes = 0
    var retainedObjects = 0
    var constructedObjects = 0
    var reusedCoreResources = false
    var constructionSeconds = 0.0
}

/// Immutable CPU results, owned by one worker until transferred to the GL
/// constructor. This contains no OpenGL names, contexts, or running players.
/// Prewarming is optional: a budget or unrecognized reference never removes
/// an existing renderer path; that path can still use its checked decoder.
final class NativeOpenGLPreparedResources: @unchecked Sendable {
    let scene: [String: Any]
    let models: [String: SceneModel]
    let textures: [String: Result<SceneTexture, Error>]
    let statistics: NativeOpenGLPreparationStatistics

    init(plan: NativeSceneCreationPlan, assets: SceneAssets,
         builtins: NativeBuiltinTextures.Snapshot?, supportsBC3: Bool,
         existingModels: Set<String>, existingTextures: Set<String>,
         previousAssets: SceneAssets, retainedModelPaths: [String: [String]],
         cancellation: NativeResourceCancellation, preferredMip: Int = 0) throws {
        var stats = NativeOpenGLPreparationStatistics()
        stats.workerWasMainThread = Thread.isMainThread
        var models: [String: SceneModel] = [:]
        var modelGeometryBytes = 0, modelAnimationBytes = 0
        let expanded = try NativeModelMaterials.expand(plan.snapshot.materializedScene(), assets: assets, cachedModelPaths: { path in
            try cancellation.check()
            guard let paths = retainedModelPaths[path.lowercased()],
                  assets.hasIdenticalPackagedResource(path, in: previousAssets) else { return nil }
            try cancellation.check()
            stats.reusedModelMaterialInventories += 1
            return paths
        }) { path in
            try cancellation.check()
            let key = path.lowercased()
            if let model = models[key] { return model }
            let model = try SceneModel.decode(assets.data(path))
            try cancellation.check()
            stats.decodedModels += 1
            let geometry = model.meshes.reduce(0) { $0 + $1.byteCount }
            let animation = model.skeleton?.animationBytes ?? 0
            if !existingModels.contains(key), geometry <= 128 * 1024 * 1024 - modelGeometryBytes,
               animation <= 32 * 1024 * 1024 - modelAnimationBytes {
                models[key] = model; modelGeometryBytes += geometry; modelAnimationBytes += animation
            }
            return model
        }
        stats.cachedModels = models.count; stats.modelBytes = modelGeometryBytes + modelAnimationBytes

        // Follow the new object's model, material, effect and particle JSONs.
        // Texture declarations are recognized in `textures` arrays/maps; names
        // in ordinary text or scripts must not cause unrelated image decoding.
        var pending: [String] = [], visited = Set<String>(), references: [String: String] = [:]
        var jsonBytes = 0
        func reference(_ name: String) {
            let path = name.hasSuffix(".tex") ? name : "materials/\(name).tex"
            let key = path.lowercased()
            guard !existingTextures.contains(key), assets.contains(path) || builtins?.contains(path) == true else { return }
            references[key] = path
        }
        func visit(_ value: Any, depth: Int = 0, textureDeclaration: Bool = false) throws {
            try cancellation.check()
            guard depth <= 64 else { stats.graphLimitReached = true; return }
            if let value = value as? String {
                if value.lowercased().hasSuffix(".json"), assets.contains(value), !visited.contains(value.lowercased()) { pending.append(value) }
                if textureDeclaration { reference(value) }
                if value == "models/util/solidlayer.json" { reference("util/white") }
            } else if let values = value as? [Any] {
                for value in values { try visit(value, depth: depth + 1, textureDeclaration: textureDeclaration) }
            } else if let values = value as? [String: Any] {
                if values["solidlayer"] as? Bool == true { reference("util/white") }
                for (key, value) in values { try visit(value, depth: depth + 1, textureDeclaration: textureDeclaration || key == "textures") }
            }
        }
        let objects = expanded["objects"] as! [[String: Any]]
        guard let slot = plan.snapshot.handle(id: plan.id)?.slot, objects.indices.contains(slot) else {
            throw SceneError.invalid("新图层没有可准备的资源位置。")
        }
        try visit(objects[slot])
        while let path = pending.popLast() {
            try cancellation.check()
            guard visited.insert(path.lowercased()).inserted else { continue }
            guard visited.count <= 5000 else { stats.graphLimitReached = true; break }
            // An unused incompatible JSON must not reject an otherwise valid
            // scene solely because optional prewarming looked at its name.
            do {
                let data = try assets.data(path, maximumBytes: 4 * 1024 * 1024)
                guard data.count <= 64 * 1024 * 1024 - jsonBytes else { stats.graphLimitReached = true; break }
                jsonBytes += data.count
                // Scene effect/material documents use the same JSONC grammar
                // as the checked render path.  Prewarming must not silently
                // skip their dependencies merely because an author left a
                // comment in the document.
                try visit(sceneJSONValue(data, path: path))
            } catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        var textures: [String: Result<SceneTexture, Error>] = [:]
        for key in references.keys.sorted() {
            try cancellation.check()
            guard textures.count < 256, stats.cachedTextureBytes < 256 * 1024 * 1024 else {
                stats.skippedTextures += 1; continue
            }
            let path = references[key]!
            do {
                let data: Data
                if assets.contains(path) {
                    guard !SceneVideoContainer.isVideo(try assets.prefix(path, count: 26)) else { continue }
                    data = try assets.data(path, maximumBytes: SceneTexture.maximumResourceBytes)
                } else { data = try builtins!.data(path) }
                try cancellation.check()
                let texture = try SceneTexture.decode(data, allowCompressedBC3: supportsBC3, preferredMip: preferredMip)
                try cancellation.check()
                let bytes = texture.compressedBC3?.count ?? texture.rgba.count
                guard bytes <= 256 * 1024 * 1024 - stats.cachedTextureBytes else { stats.skippedTextures += 1; continue }
                textures[key] = .success(texture); stats.decodedTextures += 1; stats.cachedTextureBytes += bytes
            } catch is CancellationError { throw CancellationError() }
            catch { textures[key] = .failure(error) }
        }
        try cancellation.check()
        self.scene = expanded; self.models = models; self.textures = textures; self.statistics = stats
    }
}
