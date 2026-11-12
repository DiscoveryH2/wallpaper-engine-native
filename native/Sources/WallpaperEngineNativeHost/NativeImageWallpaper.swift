import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Static wallpapers keep their original resolution. Decoding happens on the
/// preparation queue, once per project, before any desktop window is replaced.
enum NativeWallpaperImage {
    static func decode(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier,
               UTType.heif.identifier, UTType.tiff.identifier, UTType.bmp.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= 16384, height <= 16384,
              Int64(width) * Int64(height) <= 64_000_000 else {
            throw PropertyError.invalid("无法读取静态图片。支持 PNG、JPEG、HEIC、TIFF 和 BMP；尺寸上限为 16384 边长、6400 万像素。")
        }
        // ImageIO applies EXIF orientation without the editor's 4096-pixel cap.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PropertyError.invalid("图片像素无法解码，未切换壁纸。")
        }
        return image
    }

    static func preview(_ image: CGImage) throws -> Data {
        let scale = min(1, 512.0 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PropertyError.invalid("无法生成图片预览。")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let scaled = context.makeImage(), let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PropertyError.invalid("无法生成图片预览。")
        }
        CGImageDestinationAddImage(output, scaled, nil)
        guard CGImageDestinationFinalize(output) else { throw PropertyError.invalid("无法保存图片预览。") }
        return data as Data
    }
}

@MainActor
final class NativeImageWallpaperView: NSView, WallpaperRenderable {
    let image: CGImage
    var view: NSView { self }
    var playbackDescription: String { "静态图片 · \(image.width) × \(image.height)" }
    init(image: CGImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("Not archived") }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard bounds.width > 0, bounds.height > 0, let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = max(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }
    func pause() {}
    func resume() {}
}
