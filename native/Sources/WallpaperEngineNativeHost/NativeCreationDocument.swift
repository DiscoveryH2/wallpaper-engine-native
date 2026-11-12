import Foundation
import CoreGraphics
import ImageIO
import Darwin

struct NativeCreationDocument: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case solid, image, text }
    struct Layer: Codable, Equatable, Sendable {
        var id = UUID()
        var kind: Kind
        var name: String
        var x: Double = 960
        var y: Double = 540
        var width: Double = 700
        var height: Double = 220
        var rotation: Double = 0
        var opacity: Double = 1
        var color = "FFFFFF"
        var visible = true
        // Editor-only protection. Omitted in older documents and when unlocked.
        var editorLocked: Bool?
        var isLocked: Bool { editorLocked == true }
        var text = "Hello, Mac!"
        var fontSize: Double = 64
        var swing: Double = 0
        var period: Double = 6
        var imageID: UUID?
        var scaleX: Double?
        var scaleY: Double?
        var keyframes: [NativeCreationKeyframe]?
        var tracks: [NativeCreationTrack]?
    }
    var format = 3
    var id = UUID()
    var title = "我的原生壁纸"
    var width = 1920
    var height = 1080
    var layers: [Layer] = []
    var duration: Double = 8
    var loop = true

    init() {}
    private enum CodingKeys: String, CodingKey { case format, id, title, width, height, layers, duration, loop }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let storedFormat = try values.decode(Int.self, forKey: .format)
        guard [1, 2, 3, 4].contains(storedFormat) else { throw SceneError.invalid("此作品格式需要其他版本的原生编辑器。") }
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        layers = try values.decode([Layer].self, forKey: .layers)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration) ?? 8
        loop = try values.decodeIfPresent(Bool.self, forKey: .loop) ?? true
        guard storedFormat >= 3 || layers.allSatisfy({ $0.tracks == nil }) else { throw SceneError.invalid("属性轨道需要原生作品格式 3。") }
        guard storedFormat >= 4 || !layers.contains(where: { $0.tracks?.contains(where: \.usesBezier) == true }) else { throw SceneError.invalid("贝塞尔曲线需要原生作品格式 4。") }
        format = max(2, storedFormat)
    }

    static func starter() -> Self {
        var document = Self()
        var background = Layer(kind: .solid, name: "背景")
        background.width = 1920; background.height = 1080; background.color = "192A3A"
        var accent = Layer(kind: .solid, name: "动态色块")
        accent.width = 1150; accent.height = 360; accent.color = "2F7781"
        accent.rotation = -6; accent.swing = 3
        var text = Layer(kind: .text, name: "标题")
        text.width = 1000; text.height = 120
        document.layers = [background, accent, text]
        return document
    }

    func validated() throws -> Self {
        guard [2, 3, 4].contains(format), (format >= 3 || layers.allSatisfy({ $0.tracks == nil })), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 256, !title.contains("\0"),
              (64...7680).contains(width), (64...7680).contains(height), width * height <= 33_177_600,
              (1...64).contains(layers.count), Set(layers.map(\.id)).count == layers.count,
              layers.contains(where: \.visible) else {
            throw SceneError.invalid("作品需要名称、64–7680 像素的画布及 1–64 个图层，并至少显示一个图层；画布最多约 3300 万像素。")
        }
        guard format >= 4 || !layers.contains(where: { $0.tracks?.contains(where: \.usesBezier) == true }) else {
            throw SceneError.invalid("贝塞尔曲线需要原生作品格式 4。")
        }
        guard layers.filter({ $0.kind == .text }).count <= 32 else {
            throw SceneError.invalid("每个作品最多 32 个文字图层。")
        }
        guard layers.reduce(0, { $0 + $1.scalarKeyframeCount }) <= 6144 else {
            throw SceneError.invalid("每个作品最多 6144 个属性关键帧。")
        }
        for layer in layers {
            _ = try layer.motion(duration: duration, loop: loop).validated()
            guard !layer.name.isEmpty, layer.name.utf8.count <= 256, !layer.name.contains("\0"),
                  [layer.x, layer.y, layer.width, layer.height, layer.rotation, layer.opacity, layer.fontSize, layer.swing, layer.period].allSatisfy(\.isFinite),
                  abs(layer.x) <= 32768, abs(layer.y) <= 32768,
                  (1...16384).contains(layer.width), (1...16384).contains(layer.height),
                  (-360...360).contains(layer.rotation), (0...1).contains(layer.opacity),
                  (1...256).contains(layer.fontSize), (0...45).contains(layer.swing), (1...120).contains(layer.period),
                  Self.rgb(layer.color) != nil, layer.text.utf8.count <= 4096,
                  layer.kind != .text || !layer.text.isEmpty,
                  layer.kind != .image || layer.imageID != nil else {
                throw SceneError.invalid("图层“\(layer.name.prefix(80))”的参数无效。请检查尺寸、颜色、透明度、文字和动画范围。")
            }
        }
        return self
    }

    static func rgb(_ hex: String) -> [Double]? {
        let value = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard value.count == 6, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let number = UInt32(value, radix: 16) else { return nil }
        return [Double((number >> 16) & 255) / 255, Double((number >> 8) & 255) / 255, Double(number & 255) / 255]
    }

    /// Compile editable data into the same loose Scene format the native player reads.
    /// No authored Workshop file is modified or included implicitly.
    func resources(images: [UUID: NativeCreationImage], preview: NativeCreationPreview? = nil) throws -> [String: Data] {
        _ = try validated()
        var resources: [String: Data] = [:]
        var objects: [[String: Any]] = []
        var pixels = 0
        let imageIDs = Set(layers.compactMap { $0.kind == .image ? $0.imageID : nil })
        for id in imageIDs {
            guard let image = images[id] else { throw SceneError.invalid("作品缺少图片素材，请重新导入。") }
            pixels += image.width * image.height
            guard pixels <= 32_000_000 else { throw SceneError.invalid("作品图片总像素超过 3200 万，请减少图层或图片尺寸。") }
            resources["assets/\(id.uuidString).png"] = image.png
            resources["materials/\(id.uuidString).tex"] = image.texture()
            resources["models/\(id.uuidString).json"] = try Self.json(["material": "materials/\(id.uuidString).json", "autosize": true])
            resources["materials/\(id.uuidString).json"] = try Self.json(["passes": [[
                "shader": "genericimage2", "textures": [id.uuidString], "blending": "translucent",
                "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled"
            ]]])
        }
        for (index, layer) in layers.enumerated() {
            let angle = layer.rotation * .pi / 180
            var object: [String: Any] = [
                "id": index + 1, "name": layer.name, "origin": "\(layer.x) \(layer.y) 0",
                "size": "\(layer.width) \(layer.height)", "scale": "\(layer.scaleX ?? 1) \(layer.scaleY ?? 1) 1", "angles": "0 0 \(angle)",
                "visible": layer.visible, "color": Self.rgb(layer.color)!, "alpha": layer.opacity
            ]
            let motion = try JSONEncoder().encode(layer.motion(duration: duration, loop: loop))
            object["nativeEditorMotion"] = try JSONSerialization.jsonObject(with: motion)
            switch layer.kind {
            case .solid: object["image"] = "models/util/solidlayer.json"
            case .image: object["image"] = "models/\(layer.imageID!.uuidString).json"
            case .text:
                // With no authored geometry, the existing text backend uses four
                // scene units per point. Keep the editor's size in scene pixels.
                object.removeValue(forKey: "size")
                object["text"] = layer.text; object["pointsize"] = layer.fontSize / 4
                object["horizontalalign"] = "center"; object["verticalalign"] = "center"
                object["padding"] = 0; object["limitwidth"] = true
                object["maxwidth"] = min(4096, layer.width); object["limitrows"] = true; object["maxrows"] = 16
            }
            objects.append(object)
        }
        resources["scene.json"] = try Self.json(["general": ["orthogonalprojection": ["width": width, "height": height, "auto": false], "clearcolor": "0 0 0", "bloom": false, "nativeEditorFormat": format], "objects": objects])
        var editor: [String: Any] = ["format": format, "id": id.uuidString]
        var project: [String: Any] = ["title": title, "type": "scene", "file": "scene.json"]
        if let preview {
            try preview.validate(width: width, height: height, duration: duration)
            resources["preview.png"] = preview.png
            project["preview"] = "preview.png"; editor["previewTime"] = preview.time
        }
        project["nativeEditor"] = editor
        resources["project.json"] = try Self.json(project)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        resources["editor.json"] = try encoder.encode(self)
        guard resources["editor.json"]!.count <= 512 * 1024 else { throw SceneError.invalid("编辑数据超过 512 KiB，请减少文字或关键帧。") }
        guard resources.values.reduce(0, { $0 + $1.count }) <= 192 * 1024 * 1024 else {
            throw SceneError.invalid("作品素材超过 192 MiB，请减少图片。")
        }
        return resources
    }

    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}

struct NativeCreationImage: Sendable {
    let png: Data
    let width: Int
    let height: Int

    static func importFile(_ url: URL) throws -> Self {
        guard url.isFileURL else { throw SceneError.invalid("请选择本机图片文件。") }
        // The open panel grants access to this file, not its parent directories.
        // Opening each parent for reading can request unrelated folder access.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw WebSourceFD.failure("无法读取所选图片") }
        let file = WebSourceFD(descriptor)
        guard try file.info().st_mode & S_IFMT == S_IFREG else { throw SceneError.invalid("所选图片必须是普通文件。") }
        let before = WebFileSignature(try file.info())
        let bytes = try file.readSmall(maximum: 64 * 1024 * 1024)
        guard before == WebFileSignature(try file.info()) else { throw SceneError.invalid("图片在读取时发生变化，请重新选择。") }
        return try normalize(bytes)
    }

    static func normalize(_ bytes: Data) throws -> Self {
        guard !bytes.isEmpty, bytes.count <= 64 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "public.heic", "public.heif", "public.tiff"].contains(type),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 128_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw SceneError.invalid("请选择有效的 PNG、JPEG、HEIC 或 TIFF 图片（文件不超过 64 MiB）。") }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { throw SceneError.invalid("无法准备图片副本。") }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer), output.length <= 64 * 1024 * 1024 else { throw SceneError.invalid("图片副本无法保存或超过大小限制。") }
        return Self(png: output as Data, width: image.width, height: image.height)
    }

    func texture() -> Data {
        var result = Data("TEXV0005\0TEXI0001\0".utf8)
        func append(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        for number in [0, 2, width, height, width, height, 0] { append(UInt32(number)) }
        result.append(Data("TEXB0003\0".utf8))
        for number in [1, 13, 1, width, height, 0, 0, png.count] { append(UInt32(number)) }
        result.append(png)
        return result
    }
}

/// A slow selected file must not occupy the queue that saves local projects.
/// Admission stays occupied until the actual read finishes, even if its UI is closed.
enum NativeCreationImageLoader {
    private static let lock = NSLock()
    private static var active = false
    private static func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return false }; active = true; return true
    }
    private static func finish() { lock.lock(); active = false; lock.unlock() }
    static func load(_ url: URL) async throws -> NativeCreationImage {
        guard begin() else { throw SceneError.invalid("上一张图片仍在等待文件系统返回。可以继续编辑已有图层，稍后再导入。") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try NativeCreationImage.importFile(url) }
                finish(); continuation.resume(with: result)
            }
        }
    }
}
