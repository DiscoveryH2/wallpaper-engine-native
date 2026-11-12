import Foundation
import Metal

/// CoreText layout stays independent of the GPU. A replacement texture is
/// published only after the renderer has also prepared its effect geometry.
struct NativeMetalText {
    static let strings: Set<String> = ["text", "font", "horizontalalign", "verticalalign", "anchor"]
    static let numbers: Set<String> = ["pointsize", "padding", "maxwidth", "maxrows"]
    static let flags: Set<String> = ["limitwidth", "limitrows", "limituseellipsis", "opaquebackground", "blockalign"]
    static let scriptKeys = strings.union(numbers).union(flags)
    static let layoutKeys = Set(SceneTextLayout.properties).subtracting(["opaquebackground", "backgroundcolor", "backgroundbrightness"])

    let authored: [String: Any]
    let properties: [String: Any]
    let assets: SceneAssets
    let builtinFonts: NativeBuiltinFonts.Snapshot?
    let signature: Data
    let initialLayoutDiagnostic: String

    init(authored: [String: Any], resolved: [String: Any], assets: SceneAssets, builtinFonts: NativeBuiltinFonts.Snapshot?, directory: URL, layoutDiagnostic: String) throws {
        self.authored = authored; self.assets = assets; self.builtinFonts = builtinFonts
        properties = Self.layoutProperties(resolved)
        signature = try JSONSerialization.data(withJSONObject: ["directory": directory.path, "object": authored], options: [.sortedKeys])
        initialLayoutDiagnostic = layoutDiagnostic
    }

    static func layoutProperties(_ object: [String: Any]) -> [String: Any] {
        object.filter { layoutKeys.contains($0.key) }
    }

    static func allocation(width: Int, height: Int) -> Int {
        var w = width, h = height, bytes = w * h * 4
        while w > 1 || h > 1 { w = max(1, w / 2); h = max(1, h / 2); bytes += w * h * 4 }
        return bytes
    }

    static func validateAlignment(_ object: [String: Any]) throws {
        guard ["left", "center", "right"].contains(object["horizontalalign"] as? String ?? "center"),
              ["top", "center", "bottom"].contains(object["verticalalign"] as? String ?? "center") else {
            throw SceneError.invalid("文字对齐需要 left/center/right 与 top/center/bottom。")
        }
    }

    @MainActor
    final class Runtime {
        struct Replacement {
            let image: MTLTexture
            let bounds: CGRect
            let bytes: Int
            let properties: [String: Any]
            var pixels: Int { image.width * image.height }
        }
        let signature: Data
        let anchor: NativeTextAnchor.State
        private let layout: SceneTextLayout
        private let initialLayoutDiagnostic: String
        private var requested: NSDictionary
        private var displayed: [String: Any]
        private(set) var image: MTLTexture
        private(set) var bounds: CGRect
        private(set) var bytes: Int
        private var rasterizations = 1, uploads = 1, rejected = 0
        private var notes: [String] = []
        var pixels: Int { image.width * image.height }

        init(_ source: NativeMetalText, image: MTLTexture, bounds: CGRect) throws {
            signature = source.signature
            anchor = try NativeTextAnchor.State(source.properties)
            initialLayoutDiagnostic = source.initialLayoutDiagnostic
            layout = try SceneTextLayout(object: source.authored, assets: source.assets, builtinFonts: source.builtinFonts)
            try layout.useRenderedLayout(source.properties)
            requested = NSDictionary(dictionary: source.properties.filter { $0.key != "anchor" }); displayed = source.properties
            self.image = image; self.bounds = bounds
            bytes = NativeMetalText.allocation(width: image.width, height: image.height)
        }

        func prepare(_ properties: [String: Any], device: MTLDevice, command: MTLCommandBuffer,
                     pixelBudget: Int, byteBudget: Int) -> Replacement? {
            let properties = properties.filter { $0.key != "anchor" }
            // Unchanged strings and layout never enter CoreText or allocate GPU
            // storage, even when other scene layers need continuous animation.
            guard !requested.isEqual(to: properties) else { return nil }
            requested = NSDictionary(dictionary: properties)
            do {
                try NativeMetalText.validateAlignment(properties)
                rasterizations += 1
                guard let bitmap = try layout.rasterize(properties) else { return nil }
                let allocation = NativeMetalText.allocation(width: bitmap.width, height: bitmap.height)
                guard bitmap.width * bitmap.height <= pixelBudget, allocation <= byteBudget else {
                    throw SceneError.invalid("文字更新超过合计 8M 像素或场景 256 MiB 多级图片上限，保留上一张图片。")
                }
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: bitmap.width, height: bitmap.height, mipmapped: true)
                descriptor.storageMode = .shared; descriptor.usage = .shaderRead
                guard let next = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 文字图片。") }
                next.label = "Scene text replacement"
                bitmap.rgba.withUnsafeBytes { next.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bitmap.width * 4) }
                if next.mipmapLevelCount > 1 {
                    guard let blit = command.makeBlitCommandEncoder() else { throw SceneError.invalid("无法生成 Metal 文字多级图片。") }
                    blit.generateMipmaps(for: next); blit.endEncoding()
                }
                let bounds = CGRect(x: Double(bitmap.offset.x) - Double(bitmap.width) / 2,
                    y: Double(bitmap.offset.y) - Double(bitmap.height) / 2, width: Double(bitmap.width), height: Double(bitmap.height))
                return Replacement(image: next, bounds: bounds, bytes: allocation, properties: properties)
            } catch { reject(error); return nil }
        }

        func commit(_ next: Replacement) {
            image = next.image; bounds = next.bounds; bytes = next.bytes; displayed = next.properties; uploads += 1
        }

        func reject(_ error: Error) {
            rejected += 1
            let message = error.localizedDescription
            if !notes.contains(message), notes.count < 16 { notes.append(message) }
        }

        var diagnostics: [String] {
            let text = String((displayed["text"] as? String ?? "").prefix(80))
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            return ["Metal 文字：\(image.width)×\(image.height)，排版 \(rasterizations) 次、图片提交 \(uploads) 次、拒绝 \(rejected) 次；当前图片含 mip \(bytes) 字节；内容「\(text)」；边界 \(bounds)。", layout.runtimeDiagnostic ?? initialLayoutDiagnostic] + anchor.diagnostics + layout.diagnostics + notes
        }
    }
}
