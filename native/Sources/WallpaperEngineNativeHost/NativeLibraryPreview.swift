import Foundation
import CoreGraphics
import ImageIO

/// A local preview is an image inside the selected project, never a URL, code,
/// or an instruction to grant access to another directory.
enum NativeLibraryPreview {
    struct Result {
        let image: CGImage?
        let message: String
    }

    static func load(project: URL) -> Result {
        do {
            guard project.isFileURL, project.lastPathComponent == "project.json" else { return unavailable() }
            // Open every component without following symlinks. Keeping these
            // descriptors alive pins the root even if a path is renamed.
            let root = try WebSourceFD.openAbsolute(project.deletingLastPathComponent(), directory: true)
            let metadata = try root.child("project.json", directory: false)
            let metadataBefore = WebFileSignature(try metadata.info())
            let data = try metadata.readSmall(maximum: 4 * 1024 * 1024)
            guard metadataBefore == WebFileSignature(try metadata.info()),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let path = object["preview"] as? String, !path.isEmpty else {
                return Result(image: nil, message: "项目未提供本机预览图")
            }
            guard path.utf8.count <= 4096, !path.hasPrefix("/"), !path.hasPrefix("~"),
                  !path.contains("\0"), !path.contains(":"), !path.contains("\\") else { return unavailable() }
            let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.count <= 16, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return unavailable() }
            var file = root
            for (index, name) in components.enumerated() {
                file = try file.child(name, directory: index < components.count - 1)
            }
            let before = WebFileSignature(try file.info())
            let bytes = try file.readSmall(maximum: 6 * 1024 * 1024)
            guard before == WebFileSignature(try file.info()), metadataBefore == WebFileSignature(try metadata.info()),
                  !bytes.isEmpty,
                  let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let kind = CGImageSourceGetType(source) as String?,
                  ["public.jpeg", "public.png", "com.compuserve.gif", "org.webmproject.webp", "public.heic", "public.heif"].contains(kind),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return unavailable() }
            if let editor = object["nativeEditor"] as? [String: Any], [2, 3, 4].contains(editor["format"] as? Int ?? -1),
               let time = editor["previewTime"] as? Double, time.isFinite, (0...120).contains(time) {
                return Result(image: image, message: String(format: "作品预览图 · %.2f 秒 · 保存时的画面", time))
            }
            return Result(image: image, message: "项目预览图 · 实际效果以播放为准")
        } catch { return unavailable() }
    }

    private static func unavailable() -> Result {
        Result(image: nil, message: "本机预览图暂不可用，仍可尝试打开项目")
    }
}
