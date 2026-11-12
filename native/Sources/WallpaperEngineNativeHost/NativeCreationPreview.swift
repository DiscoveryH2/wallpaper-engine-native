import Foundation
import CoreGraphics
import ImageIO

/// A bounded image of the author's chosen time, produced by the Scene renderer.
struct NativeCreationPreview: Sendable {
    static let maximumDimension = 640
    let png: Data
    let time: Double

    static func dimensions(width: Int, height: Int) -> (width: Int, height: Int) {
        let factor = min(1, Double(maximumDimension) / Double(max(1, max(width, height))))
        return (max(1, Int((Double(width) * factor).rounded())), max(1, Int((Double(height) * factor).rounded())))
    }

    func validate(width: Int, height: Int, duration: Double) throws {
        let expected = Self.dimensions(width: width, height: height)
        guard time.isFinite, (0...duration).contains(time), !png.isEmpty, png.count <= 6 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == expected.width,
              properties[kCGImagePropertyPixelHeight] as? Int == expected.height else {
            throw SceneError.invalid("作品预览图无效，尚未保存新版本。")
        }
    }

    static func encode(bottomUpRGBA: [UInt8], width: Int, height: Int) throws -> Data {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              bottomUpRGBA.count == width * height * 4 else { throw SceneError.invalid("作品预览尺寸无效。") }
        let row = width * 4
        var pixels = [UInt8](repeating: 0, count: bottomUpRGBA.count)
        for y in 0..<height {
            pixels.replaceSubrange((y * row)..<((y + 1) * row),
                                   with: bottomUpRGBA[((height - 1 - y) * row)..<((height - y) * row)])
        }
        return try encode(topDownRGBA: pixels, width: width, height: height)
    }

    static func encode(topDownRGBA pixels: [UInt8], width: Int, height: Int) throws -> Data {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              pixels.count == width * height * 4 else { throw SceneError.invalid("作品预览尺寸无效。") }
        let row = width * 4
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: row, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw SceneError.invalid("无法生成作品预览图。")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw SceneError.invalid("无法编码作品预览图。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SceneError.invalid("作品预览图编码失败。") }
        return data as Data
    }
}
