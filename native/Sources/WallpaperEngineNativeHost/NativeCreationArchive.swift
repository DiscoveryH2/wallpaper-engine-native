import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Portable authoring data. No paths, shaders, scripts or executable scene files
/// are read from the archive; the host compiles a new Scene after validation.
enum NativeCreationArchive {
    static let contentType = UTType(exportedAs: "io.wallpaper-engine-native.creation", conformingTo: .data)
    static let fileExtension = "wenative"
    private static let magic = Data("WENATIVE0001\n".utf8)
    private static let maximumFileBytes = 64 * 1024 * 1024
    private static let maximumHeaderBytes = 1024 * 1024
    private struct ImageEntry: Codable { let id: UUID; let byteCount: Int }
    private struct Header: Codable {
        let format: Int
        let document: NativeCreationDocument
        let previewTime: Double
        let images: [ImageEntry]
    }
    struct Loaded: Sendable {
        var document: NativeCreationDocument
        let images: [UUID: NativeCreationImage]
        let previewTime: Double
    }

    static func suggestedName(_ title: String) -> String {
        let safe = title.components(separatedBy: CharacterSet(charactersIn: "/:\0").union(.newlines)).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var name = safe.isEmpty ? "原生壁纸" : safe
        while name.utf8.count > 180 { name.removeLast() }
        return name + "." + fileExtension
    }

    static func encode(_ document: NativeCreationDocument, images: [UUID: NativeCreationImage], time: Double) throws -> Data {
        _ = try document.validated()
        guard time.isFinite, (0...document.duration).contains(time),
              try JSONEncoder().encode(document).count <= 512 * 1024 else { throw SceneError.invalid("作品内容或预览时间超出导出范围。") }
        let ids = Set(document.layers.compactMap { $0.kind == .image ? $0.imageID : nil }).sorted { $0.uuidString < $1.uuidString }
        var entries: [ImageEntry] = [], total = 0, pixels = 0
        for id in ids {
            guard let image = images[id], !image.png.isEmpty, image.png.count <= maximumFileBytes - total else {
                throw SceneError.invalid("作品缺少图片，或素材总量超过 64 MiB。")
            }
            total += image.png.count; pixels += image.width * image.height
            guard pixels <= 32_000_000 else { throw SceneError.invalid("作品图片总像素超过 3200 万。") }
            entries.append(ImageEntry(id: id, byteCount: image.png.count))
        }
        let header = try JSONEncoder().encode(Header(format: 1, document: document, previewTime: time, images: entries))
        guard header.count <= maximumHeaderBytes,
              magic.count + 4 + header.count + total + 32 <= maximumFileBytes else {
            throw SceneError.invalid("导出作品文件超过 64 MiB，请减少图片大小或数量。")
        }
        var data = magic
        var length = UInt32(header.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(header)
        for id in ids { data.append(images[id]!.png) }
        data.append(contentsOf: SHA256.hash(data: data))
        return data
    }

    static func read(_ url: URL) throws -> Loaded {
        guard url.isFileURL else { throw SceneError.invalid("请选择本机原生作品文件。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let raw = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard raw >= 0 else { throw WebSourceFD.failure("无法读取作品文件") }
        let file = WebSourceFD(raw), info = try file.info()
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= maximumFileBytes else {
            throw SceneError.invalid("作品必须是不超过 64 MiB 的普通文件。")
        }
        let bytes = try file.readSmall(maximum: maximumFileBytes)
        guard WebFileSignature(info) == WebFileSignature(try file.info()) else { throw SceneError.invalid("作品文件在读取时发生变化，请重新选择。") }
        return try decode(bytes)
    }

    private static func decode(_ data: Data) throws -> Loaded {
        let start = magic.count + 4, end = data.count - 32
        guard data.count <= maximumFileBytes, end > start, data.prefix(magic.count) == magic else {
            throw SceneError.invalid("这不是受支持的原生作品文件，或文件不完整。")
        }
        guard Data(SHA256.hash(data: data.prefix(end))) == data.suffix(32) else {
            throw SceneError.invalid("作品文件校验失败，可能未完整复制或内容已损坏。")
        }
        var length = 0
        for index in 0..<4 { length |= Int(data[magic.count + index]) << (index * 8) }
        guard length > 0, length <= maximumHeaderBytes, length <= end - start else { throw SceneError.invalid("作品文件头无效。") }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data.subdata(in: start..<(start + length))) }
        catch { throw SceneError.invalid("无法读取作品文档：\(error.localizedDescription)") }
        let document = try header.document.validated()
        guard header.format == 1, header.previewTime.isFinite, (0...document.duration).contains(header.previewTime),
              header.images.count <= 64, Set(header.images.map(\.id)).count == header.images.count,
              try JSONEncoder().encode(document).count <= 512 * 1024 else { throw SceneError.invalid("作品文件的版本、预览时间或素材数量无效。") }
        let expected = Set(document.layers.compactMap { $0.kind == .image ? $0.imageID : nil })
        guard expected == Set(header.images.map(\.id)) else { throw SceneError.invalid("作品图片清单与图层不一致。") }
        var offset = start + length, pixels = 0
        var images: [UUID: NativeCreationImage] = [:]
        for entry in header.images {
            guard entry.byteCount > 0, entry.byteCount <= end - offset else { throw SceneError.invalid("作品图片长度无效或内容不完整。") }
            let bytes = data.subdata(in: offset..<(offset + entry.byteCount)); offset += entry.byteCount
            guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
                  let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
                  (1...4096).contains(width), (1...4096).contains(height), width * height <= 32_000_000 - pixels else {
                throw SceneError.invalid("作品只接受单帧 PNG；每边最多 4096 像素，总像素最多 3200 万。")
            }
            pixels += width * height
            images[entry.id] = try NativeCreationImage.normalize(bytes)
        }
        guard offset == end else { throw SceneError.invalid("作品文件包含未声明的数据。") }
        return Loaded(document: document, images: images, previewTime: header.previewTime)
    }

    static func write(_ data: Data, to url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == fileExtension else { throw SceneError.invalid("请导出为 .wenative 作品文件。") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // The selected destination is the only external write. Existing files
        // are never replaced; a failed or interrupted write is not a valid archive.
        do { try data.write(to: url, options: .withoutOverwriting) }
        catch { throw SceneError.invalid("导出未完成：\(error.localizedDescription) 请使用新的文件名；已保存作品仍可继续使用。") }
    }
}

/// External files must not occupy the queue used to save the local library.
enum NativeCreationArchiveIO {
    private static let lock = NSLock()
    private static var active = false
    private static func begin() -> Bool { lock.lock(); defer { lock.unlock() }; guard !active else { return false }; active = true; return true }
    private static func finish() { lock.lock(); active = false; lock.unlock() }
    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        guard begin() else { throw SceneError.invalid("上一个作品文件仍在处理，请稍后重试。已有作品可继续编辑。") }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try operation() }
                finish(); continuation.resume(with: result)
            }
        }
    }
}
