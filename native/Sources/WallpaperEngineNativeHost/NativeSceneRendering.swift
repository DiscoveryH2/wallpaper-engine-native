import AppKit
import Foundation
import ImageIO

/// The editor and desktop share a renderer contract, including deterministic
/// authoring operations. Neither caller needs to know the graphics API.
@MainActor
protocol NativeSceneRendering: WallpaperRenderable {
    var failedLayerCount: Int { get }
    var playbackTime: Double { get }
    func editorLayerBounds(at index: Int) -> CGRect?
    @discardableResult func updateEditorMotion(_ motion: NativeCreationMotion, at index: Int) -> Bool
    @discardableResult func updateEditorMotions(_ motions: [Int: NativeCreationMotion]) -> Bool
    @discardableResult func seekEditor(to time: Double) -> Bool
    func editorPreviewPNG(width: Int, height: Int) throws -> Data
}

struct NativeCreationRenderSource {
    let document: NativeCreationDocument
    let images: [UUID: NativeCreationImage]
    let objects: [[String: Any]]
    let assets: SceneAssets

    /// Metal currently implements the complete native authoring format. Check
    /// its compiled resources too, so an externally modified Scene never loses
    /// authored material/effect behavior merely because it retains editor data.
    static func load(_ project: WallpaperProject) throws -> Self {
        guard let metadata = try JSONSerialization.jsonObject(with: project.metadataData) as? [String: Any],
              let editor = metadata["nativeEditor"] as? [String: Any], [2, 3, 4].contains(editor["format"] as? Int ?? -1),
              metadata["file"] as? String == "scene.json", project.propertyDefinitions.isEmpty,
              metadata["general"] == nil else { throw SceneError.invalid("项目不属于当前原生创作格式。") }
        let assets = try SceneAssets(directory: project.directoryURL)
        let document = try JSONDecoder().decode(NativeCreationDocument.self, from: assets.data("editor.json", maximumBytes: 512 * 1024)).validated()
        guard editor["id"] as? String == document.id.uuidString, editor["format"] as? Int == document.format else { throw SceneError.invalid("编辑文档与项目身份或格式不一致。") }
        var images: [UUID: NativeCreationImage] = [:], pixels = 0, encodedBytes = 0
        for id in Set(document.layers.compactMap { $0.kind == .image ? $0.imageID : nil }) {
            let data = try assets.data("assets/\(id.uuidString).png", maximumBytes: 64 * 1024 * 1024)
            encodedBytes += data.count
            // The persisted format stores each PNG both as an asset and in TEX,
            // with a combined resource ceiling of 192 MiB.
            guard encodedBytes <= 96 * 1024 * 1024,
                  let image = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(image) as String? == "public.png", CGImageSourceGetCount(image) == 1,
                  let info = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
                  (1...4096).contains(width), (1...4096).contains(height), width * height <= 32_000_000 - pixels else {
                throw SceneError.invalid("原生作品图片超过格式范围。")
            }
            pixels += width * height
            images[id] = NativeCreationImage(png: data, width: width, height: height)
        }
        let resources = try document.resources(images: images)
        for (path, expected) in resources where path != "editor.json" && path != "project.json" && !path.hasPrefix("assets/") {
            let actual = try assets.data(path, maximumBytes: max(expected.count, 512 * 1024))
            let equal: Bool
            if path.hasSuffix(".json") {
                let left = try JSONSerialization.jsonObject(with: expected) as? NSDictionary
                let right = try JSONSerialization.jsonObject(with: actual) as? NSDictionary
                equal = left != nil && left == right
            } else { equal = expected == actual }
            guard equal else { throw SceneError.invalid("\(path) 与编辑文档不同，保留原 Scene 的渲染语义。") }
        }
        let scene = try JSONSerialization.jsonObject(with: resources["scene.json"]!) as! [String: Any]
        return Self(document: document, images: images, objects: scene["objects"] as! [[String: Any]], assets: assets)
    }
}

@MainActor
enum NativeSceneRenderer {
    static func make(project: WallpaperProject, allowsEditorSeeking: Bool = false, videos: SceneVideoLibrary = SceneVideoLibrary(), postProcessing: NativePostProcessingQuality = .ultra, antialiasing: NativeAntialiasing = .none, textureResolution: NativeTextureResolutionRequest = .init()) throws -> NativeSceneRendering {
        let metadata = try JSONSerialization.jsonObject(with: project.metadataData) as? [String: Any]
        var legacyReason: String?
        if metadata?["nativeEditor"] != nil {
            let source: NativeCreationRenderSource?
            do { source = try NativeCreationRenderSource.load(project) }
            catch { source = nil; legacyReason = "原生文档未采用 Metal：\(error.localizedDescription)" }
            if let source {
                let view = try NativeMetalCreationView(source: source, allowsEditorSeeking: allowsEditorSeeking)
                try view.preparePostProcessingQuality(postProcessing)(); try view.prepareAntialiasing(antialiasing)()
                try view.prepareTextureResolution(textureResolution.quality, outputSize: textureResolution.outputSize)(); return view
            }
        } else if !allowsEditorSeeking {
            let source: NativeMetalSceneSource?
            do { source = try NativeMetalSceneSource.load(project, videos: videos, postProcessing: postProcessing, textureResolution: textureResolution) }
            catch { source = nil; legacyReason = "通用 Scene 保留 OpenGL：\(error.localizedDescription)" }
            if let source {
                do {
                    let view = try NativeMetalCreationView(scene: source, project: project, videos: videos)
                    try view.prepareAntialiasing(antialiasing)(); return view
                } catch {
                    // Resource allocation happens after structural source
                    // admission.  Recover only the known deterministic frame
                    // budget rejection; any device/pipeline/asset failure is
                    // still surfaced to the caller rather than hidden as a
                    // compatibility fallback.
                    guard NativeMetalEffects.isFrameBudgetError(error) else { throw error }
                    legacyReason = "通用 Scene 保留 OpenGL：Metal 图层效果缓冲超过 128 MiB 上限。"
                }
            }
        }
        guard let renderer = try SceneWallpaperView(project: project, allowsEditorSeeking: allowsEditorSeeking, videos: videos, postProcessing: postProcessing, textureResolution: textureResolution) else {
            throw SceneError.invalid("系统未能创建 Scene 渲染视图。")
        }
        try renderer.prepareAntialiasing(antialiasing)()
        renderer.backendSelectionNote = legacyReason
        return renderer
    }
}
