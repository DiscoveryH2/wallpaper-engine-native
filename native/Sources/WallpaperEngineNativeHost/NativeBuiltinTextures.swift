import CryptoKit
import Darwin
import Foundation
import zlib

// Original texture data is a local, separately imported input. No APK code,
// shaders, JSON or native libraries are extracted or executed by this reader.
enum NativeBuiltinTextures {
    static let maximumArchiveBytes = 256 * 1024 * 1024
    static let maximumTextureBytes = 16 * 1024 * 1024
    static let maximumTotalBytes = 128 * 1024 * 1024
    static let maximumTextures = 4096
    static let maximumManifestBytes = 2 * 1024 * 1024
    // Download provenance is recorded in official-android-reference-inventory.
    // A hash identifies that observed download, not an APK signature verifier.
    // Future official releases require a new independently recorded digest.
    static let knownArchiveHash = "6982c82745444c5f2eef5a3d8c89ad807360bb5849a133548a6b25d18f4c4cb0"
    static let knownTextureIndexHash = "66e5cf3c8add2c552c0f7a05964a6dced75038c386b6f62d6c696c8cc46c8063"

    struct Entry: Codable, Sendable {
        let path: String
        let bytes: Int
        let sha256: String
        let crc32: UInt32
    }
    struct Manifest: Codable, Sendable {
        let schema: Int
        let archiveSHA256: String
        let archiveBytes: Int
        let sourceName: String
        let importedAt: String
        let entries: [Entry]
    }
    struct Receipt: Codable, Sendable {
        let archiveSHA256: String
        let textureCount: Int
        let textureBytes: Int
        let catalogPath: String
        let reusedExistingCatalog: Bool
    }
    private struct Activation: Codable { let schema: Int; let archiveSHA256: String }

    final class Snapshot: @unchecked Sendable {
        let manifest: Manifest
        private let directory: TextureDirectory
        private let entries: [String: Entry]
        fileprivate init(directory: TextureDirectory, expectedHash: String) throws {
            let bytes = try directory.read("manifest.json", maximum: maximumManifestBytes)
            let manifest = try JSONDecoder().decode(Manifest.self, from: bytes)
            guard manifest.schema == 1, manifest.archiveSHA256 == expectedHash,
                  expectedHash == knownArchiveHash, manifest.archiveBytes > 0,
                  manifest.archiveBytes <= maximumArchiveBytes,
                  !manifest.entries.isEmpty, manifest.entries.count <= maximumTextures else {
                throw TextureImportError.invalid("内置素材清单格式或大小不受支持。")
            }
            var entries: [String: Entry] = [:], total = 0
            for entry in manifest.entries {
                let key = try texturePath(entry.path)
                guard key == entry.path, entries[key] == nil, validHash(entry.sha256),
                      entry.bytes > 0, entry.bytes <= maximumTextureBytes else {
                    throw TextureImportError.invalid("内置素材清单包含无效或重复条目。")
                }
                total += entry.bytes
                guard total <= maximumTotalBytes else { throw TextureImportError.invalid("内置素材总大小超限。") }
                entries[key] = entry
            }
            guard indexDigest(manifest.entries) == knownTextureIndexHash else {
                throw TextureImportError.invalid("素材清单与已记录的官方纹理索引不一致。")
            }
            self.manifest = manifest; self.directory = directory; self.entries = entries
        }
        func contains(_ path: String) -> Bool { entries[path] != nil }
        func data(_ path: String) throws -> Data {
            guard let entry = entries[path] else { throw TextureImportError.invalid("内置素材不存在：\(path)") }
            let bytes = try directory.read(path, maximum: entry.bytes)
            guard bytes.count == entry.bytes, digest(bytes) == entry.sha256 else {
                throw TextureImportError.invalid("内置素材已发生变化，请重新导入：\(path)")
            }
            return bytes
        }
    }

    static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/WallpaperEngineNative/EngineResources", isDirectory: true)
    }

    static func activeSnapshot() throws -> Snapshot? {
        guard let root = try openRoot(create: false) else { return nil }
        guard let bytes = try root.readIfPresent("active.json", maximum: 1024) else { return nil }
        let active = try JSONDecoder().decode(Activation.self, from: bytes)
        guard active.schema == 1, validHash(active.archiveSHA256) else {
            throw TextureImportError.invalid("已启用的内置素材索引无效。")
        }
        return try Snapshot(directory: root.child(active.archiveSHA256), expectedHash: active.archiveSHA256)
    }

    // Synchronous by design: CLI runs this directly; AppKit calls it on a
    // detached task and awaits its cancellation/cleanup before termination.
    static func importArchive(_ url: URL) throws -> Receipt {
        guard url.isFileURL, url.path.hasPrefix("/"), url.pathExtension.lowercased() == "apk" else {
            throw TextureImportError.invalid("请选择本机的官方 Wallpaper Engine APK 文件。")
        }
        guard let root = try openRoot(create: true) else { throw TextureImportError.invalid("无法创建素材目录。") }
        let lock = try root.file(".import.lock", flags: O_RDWR | O_CREAT, mode: 0o600)
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw TextureImportError.invalid("已有一次内置素材导入正在进行，请稍后再试。")
        }
        defer { flock(lock, LOCK_UN) }
        let sourceFD = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard sourceFD >= 0 else { throw TextureImportError.system("打开 APK") }
        defer { close(sourceFD) }
        let archive = try readTextureFile(sourceFD, maximum: maximumArchiveBytes)
        try Task.checkCancellation()
        let archiveHash = digest(archive)
        guard archiveHash == knownArchiveHash else {
            throw TextureImportError.invalid("此 APK 尚未登记来源。当前支持已记录 SHA-256 的官方发行包；新版本需先更新来源记录。")
        }
        let members = try TextureZIP(archive).textures()
        let stagingName = ".import-" + UUID().uuidString
        let staging = try root.child(stagingName, create: true, exclusive: true)
        // Only paths created by this import are removed on failure. Existing
        // content-addressed catalogs and the old active pointer are untouched.
        var created: [String] = []
        var stagingPublished = false
        defer {
            if !stagingPublished {
                for path in created.reversed() { try? staging.removeFile(path) }
                try? staging.removeEmptyDirectories(for: created)
                _ = unlinkat(root.fd, stagingName, AT_REMOVEDIR)
            }
        }
        var entries: [Entry] = []
        for member in members {
            try Task.checkCancellation()
            let bytes = try member.inflate(from: archive)
            // Preserve the TEX bytes, including unsupported future formats.
            // Rendering admission and GPU budgets remain in SceneTexture.
            guard bytes.starts(with: Array("TEXV0005\0".utf8)) else {
                throw TextureImportError.invalid("素材不是当前支持的 TEX 容器：\(member.path)")
            }
            created.append(member.path)
            try staging.writeNew(member.path, data: bytes)
            entries.append(Entry(path: member.path, bytes: bytes.count, sha256: digest(bytes), crc32: member.crc))
        }
        let manifest = Manifest(schema: 1, archiveSHA256: archiveHash, archiveBytes: archive.count,
            sourceName: url.lastPathComponent, importedAt: ISO8601DateFormatter().string(from: Date()), entries: entries)
        guard indexDigest(entries) == knownTextureIndexHash else {
            throw TextureImportError.invalid("提取结果与已记录的官方纹理索引不一致。")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestBytes = try encoder.encode(manifest)
        guard manifestBytes.count <= maximumManifestBytes else { throw TextureImportError.invalid("素材清单超限。") }
        created.append("manifest.json"); try staging.writeNew("manifest.json", data: manifestBytes)
        try staging.sync()
        try Task.checkCancellation()
        var reused = false
        if let existing = try root.childIfPresent(archiveHash) {
            let snapshot = try Snapshot(directory: existing, expectedHash: archiveHash)
            guard snapshot.manifest.entries.count == entries.count else {
                throw TextureImportError.invalid("同一来源的已有素材目录不完整。")
            }
            for entry in entries {
                try Task.checkCancellation()
                guard snapshot.contains(entry.path), digest(try snapshot.data(entry.path)) == entry.sha256 else {
                    throw TextureImportError.invalid("同一来源的已有素材目录已改变，请保留现有目录并检查后重试。")
                }
            }
            reused = true
        } else {
            guard renameatx_np(root.fd, stagingName, root.fd, archiveHash, UInt32(RENAME_EXCL)) == 0 else { throw TextureImportError.system("发布素材目录") }
            stagingPublished = true
            try root.sync()
        }
        try Task.checkCancellation()
        let activeBytes = try encoder.encode(Activation(schema: 1, archiveSHA256: archiveHash))
        let activeName = ".active-" + UUID().uuidString
        try root.writeNew(activeName, data: activeBytes)
        defer { _ = unlinkat(root.fd, activeName, 0) }
        try Task.checkCancellation()
        guard renameat(root.fd, activeName, root.fd, "active.json") == 0 else { throw TextureImportError.system("启用素材目录") }
        try root.sync()
        return Receipt(archiveSHA256: archiveHash, textureCount: entries.count,
            textureBytes: entries.reduce(0) { $0 + $1.bytes }, catalogPath: storageURL.appendingPathComponent(archiveHash).path,
            reusedExistingCatalog: reused)
    }

    fileprivate static func openRoot(create: Bool) throws -> TextureDirectory? {
        // Existing system/user parents are not changed. Owned storage below
        // Application Support uses directory descriptors and refuses symlinks.
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true).resolvingSymlinksInPath()
        let fd = open(base.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw TextureImportError.system("打开 Application Support") }
        let parent = try TextureDirectory(fd: fd, requirePrivate: false)
        let app: TextureDirectory
        if create { app = try parent.child("WallpaperEngineNative", create: true) }
        else { guard let found = try parent.childIfPresent("WallpaperEngineNative") else { return nil }; app = found }
        if create { return try app.child("EngineResources", create: true) }
        return try app.childIfPresent("EngineResources")
    }
    fileprivate static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    fileprivate static func indexDigest(_ entries: [Entry]) -> String {
        let text = entries.sorted { $0.path < $1.path }.map { "\($0.path)\t\($0.bytes)\t\($0.sha256)\t\($0.crc32)\n" }.joined()
        return digest(Data(text.utf8))
    }
    fileprivate static func validHash(_ hash: String) -> Bool {
        hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    fileprivate static func texturePath(_ path: String) throws -> String {
        guard path.utf8.count <= 1024, path.hasPrefix("materials/"), path.hasSuffix(".tex"),
              path.utf8.allSatisfy({ (32...126).contains($0) }),
              !path.contains("\\"), !path.contains(":"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 255 }),
              !path.contains("//") else { throw TextureImportError.invalid("不安全的素材路径。") }
        return path.lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

// Optional font data uses a separate catalog and activation pointer, so an
// existing texture import is neither rewritten nor implicitly activated here.
// The APK is a source of bytes only: no APK executable or library is loaded.
enum NativeBuiltinFonts {
    static let knownIndexHash = "9c8da018f297a5ac55c5e39f92ef0d6f5ec830c65205d416b04b1d885015bb3f"
    typealias Entry = NativeBuiltinTextures.Entry
    typealias Manifest = NativeBuiltinTextures.Manifest
    struct Receipt: Codable, Sendable {
        let archiveSHA256: String
        let fontCount: Int
        let fontBytes: Int
        let catalogPath: String
        let reusedExistingCatalog: Bool
    }
    private struct Activation: Codable { let schema: Int; let archiveSHA256: String }

    final class Snapshot: @unchecked Sendable {
        let manifest: Manifest
        private let directory: TextureDirectory
        private let entries: [String: Entry]
        fileprivate init(directory: TextureDirectory, expectedHash: String) throws {
            let data = try directory.read("manifest.json", maximum: NativeBuiltinTextures.maximumManifestBytes)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schema == 1, expectedHash == NativeBuiltinTextures.knownArchiveHash,
                  manifest.archiveSHA256 == expectedHash, manifest.archiveBytes > 0,
                  manifest.archiveBytes <= NativeBuiltinTextures.maximumArchiveBytes,
                  !manifest.entries.isEmpty, manifest.entries.count <= NativeBuiltinTextures.maximumTextures else {
                throw TextureImportError.invalid("内置字体清单格式或大小无效。")
            }
            var entries: [String: Entry] = [:], total = 0
            for entry in manifest.entries {
                let path = try NativeBuiltinFonts.fontPath(entry.path)
                guard path == entry.path, entries[path] == nil, NativeBuiltinTextures.validHash(entry.sha256),
                      entry.bytes > 0, entry.bytes <= NativeBuiltinTextures.maximumTextureBytes else {
                    throw TextureImportError.invalid("内置字体清单包含无效或重复条目。")
                }
                total += entry.bytes
                guard total <= NativeBuiltinTextures.maximumTotalBytes else { throw TextureImportError.invalid("内置字体总大小超限。") }
                entries[path] = entry
            }
            guard NativeBuiltinTextures.indexDigest(manifest.entries) == knownIndexHash else {
                throw TextureImportError.invalid("字体清单与已记录的官方索引不一致。")
            }
            self.manifest = manifest; self.directory = directory; self.entries = entries
        }
        func contains(_ path: String) -> Bool {
            guard let key = try? NativeBuiltinFonts.fontPath(path) else { return false }
            return entries[key] != nil
        }
        func data(_ path: String) throws -> Data {
            let key = try NativeBuiltinFonts.fontPath(path)
            guard let entry = entries[key] else { throw TextureImportError.invalid("内置字体不存在：\(path)") }
            let bytes = try directory.read(key, maximum: entry.bytes)
            guard bytes.count == entry.bytes, NativeBuiltinTextures.digest(bytes) == entry.sha256 else {
                throw TextureImportError.invalid("内置字体已发生变化，请检查后重新导入：\(path)")
            }
            return bytes
        }
    }

    static var storageURL: URL { NativeBuiltinTextures.storageURL.appendingPathComponent("Fonts", isDirectory: true) }

    private static func openRoot(create: Bool) throws -> TextureDirectory? {
        guard let resources = try NativeBuiltinTextures.openRoot(create: create) else { return nil }
        if create { return try resources.child("Fonts", create: true) }
        return try resources.childIfPresent("Fonts")
    }
    static func activeSnapshot() throws -> Snapshot? {
        guard let root = try openRoot(create: false) else { return nil }
        return try activeSnapshot(root: root)
    }
    fileprivate static func activeSnapshot(root: TextureDirectory) throws -> Snapshot? {
        guard let bytes = try root.readIfPresent("active.json", maximum: 1024) else { return nil }
        let active = try JSONDecoder().decode(Activation.self, from: bytes)
        guard active.schema == 1, NativeBuiltinTextures.validHash(active.archiveSHA256) else {
            throw TextureImportError.invalid("已启用的内置字体索引无效。")
        }
        return try Snapshot(directory: root.child(active.archiveSHA256), expectedHash: active.archiveSHA256)
    }

    static func importArchive(_ url: URL) throws -> Receipt {
        guard url.isFileURL, url.path.hasPrefix("/"), url.pathExtension.lowercased() == "apk" else {
            throw TextureImportError.invalid("请选择本机的官方 Wallpaper Engine APK 文件。")
        }
        guard let root = try openRoot(create: true) else { throw TextureImportError.invalid("无法创建字体目录。") }
        return try importArchive(url, root: root, storageURL: storageURL)
    }
    fileprivate static func importArchive(_ url: URL, root: TextureDirectory, storageURL: URL) throws -> Receipt {
        guard url.isFileURL, url.path.hasPrefix("/"), url.pathExtension.lowercased() == "apk" else {
            throw TextureImportError.invalid("请选择本机的官方 Wallpaper Engine APK 文件。")
        }
        let lock = try root.file(".import.lock", flags: O_RDWR | O_CREAT, mode: 0o600)
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw TextureImportError.invalid("已有一次字体导入正在进行，请稍后再试。") }
        defer { flock(lock, LOCK_UN) }
        let sourceFD = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard sourceFD >= 0 else { throw TextureImportError.system("打开 APK") }
        defer { close(sourceFD) }
        let archive = try readTextureFile(sourceFD, maximum: NativeBuiltinTextures.maximumArchiveBytes)
        try Task.checkCancellation()
        let archiveHash = NativeBuiltinTextures.digest(archive)
        guard archiveHash == NativeBuiltinTextures.knownArchiveHash else {
            throw TextureImportError.invalid("此 APK 尚未登记来源；请使用已记录 SHA-256 的官方发行包。")
        }
        let members = try TextureZIP(archive).fonts()
        let stagingName = ".import-" + UUID().uuidString
        let staging = try root.child(stagingName, create: true, exclusive: true)
        var created: [String] = [], stagingPublished = false
        defer {
            if !stagingPublished {
                for path in created.reversed() { try? staging.removeFile(path) }
                try? staging.removeEmptyDirectories(for: created)
                _ = unlinkat(root.fd, stagingName, AT_REMOVEDIR)
            }
        }
        var entries: [Entry] = []
        for member in members {
            try Task.checkCancellation()
            let bytes = try member.inflate(from: archive)
            created.append(member.path)
            try staging.writeNew(member.path, data: bytes)
            entries.append(Entry(path: member.path, bytes: bytes.count, sha256: NativeBuiltinTextures.digest(bytes), crc32: member.crc))
        }
        guard NativeBuiltinTextures.indexDigest(entries) == knownIndexHash else {
            throw TextureImportError.invalid("提取结果与已记录的官方字体索引不一致。")
        }
        let manifest = Manifest(schema: 1, archiveSHA256: archiveHash, archiveBytes: archive.count,
            sourceName: url.lastPathComponent, importedAt: ISO8601DateFormatter().string(from: Date()), entries: entries)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestBytes = try encoder.encode(manifest)
        guard manifestBytes.count <= NativeBuiltinTextures.maximumManifestBytes else { throw TextureImportError.invalid("字体清单超限。") }
        created.append("manifest.json"); try staging.writeNew("manifest.json", data: manifestBytes)
        try staging.sync(); try Task.checkCancellation()
        var reused = false
        if let existing = try root.childIfPresent(archiveHash) {
            let snapshot = try Snapshot(directory: existing, expectedHash: archiveHash)
            guard snapshot.manifest.entries.count == entries.count else { throw TextureImportError.invalid("已有字体目录不完整。") }
            for entry in entries {
                try Task.checkCancellation()
                guard snapshot.contains(entry.path), NativeBuiltinTextures.digest(try snapshot.data(entry.path)) == entry.sha256 else {
                    throw TextureImportError.invalid("已有字体目录已改变，请保留并检查后重试。")
                }
            }
            reused = true
        } else {
            guard renameatx_np(root.fd, stagingName, root.fd, archiveHash, UInt32(RENAME_EXCL)) == 0 else { throw TextureImportError.system("发布字体目录") }
            stagingPublished = true
            try root.sync()
        }
        try Task.checkCancellation()
        let activeName = ".active-" + UUID().uuidString
        try root.writeNew(activeName, data: encoder.encode(Activation(schema: 1, archiveSHA256: archiveHash)))
        defer { _ = unlinkat(root.fd, activeName, 0) }
        try Task.checkCancellation()
        guard renameat(root.fd, activeName, root.fd, "active.json") == 0 else { throw TextureImportError.system("启用字体目录") }
        try root.sync()
        return Receipt(archiveSHA256: archiveHash, fontCount: entries.count, fontBytes: entries.reduce(0) { $0 + $1.bytes },
                       catalogPath: storageURL.appendingPathComponent(archiveHash).path, reusedExistingCatalog: reused)
    }

    fileprivate static func fontPath(_ path: String) throws -> String {
        let lower = path.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard path.utf8.count <= 1024, lower.hasPrefix("fonts/"),
              lower.hasSuffix(".ttf") || lower.hasSuffix(".otf"),
              path.utf8.allSatisfy({ (32...126).contains($0) }), !path.contains("\\"), !path.contains(":"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.count <= 255 }) else {
            throw TextureImportError.invalid("不安全的字体路径。")
        }
        return lower
    }
}

private enum TextureImportError: LocalizedError {
    case invalid(String)
    case system(String, Int32 = errno)
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .system(let action, let code): return "\(action)失败：\(String(cString: strerror(code)))"
        }
    }
}

// An open directory is the capability for all descendant I/O. No imported
// path is converted into an unrestricted file URL at render time.
private final class TextureDirectory: @unchecked Sendable {
    let fd: Int32
    init(fd: Int32, requirePrivate: Bool = true) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), (!requirePrivate || info.st_mode & 0o022 == 0) else {
            close(fd); throw TextureImportError.invalid("素材目录所有者或权限无效。")
        }
        self.fd = fd
    }
    deinit { close(fd) }
    func child(_ name: String, create: Bool = false, exclusive: Bool = false) throws -> TextureDirectory {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw TextureImportError.invalid("目录名称无效。") }
        if create, mkdirat(fd, name, 0o700) != 0, exclusive || errno != EEXIST { throw TextureImportError.system("创建素材目录") }
        let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard childFD >= 0 else { throw TextureImportError.system("打开素材目录") }
        return try TextureDirectory(fd: childFD)
    }
    func childIfPresent(_ name: String) throws -> TextureDirectory? {
        let childFD = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if childFD < 0, errno == ENOENT { return nil }
        guard childFD >= 0 else { throw TextureImportError.system("打开素材目录") }
        return try TextureDirectory(fd: childFD)
    }
    func file(_ name: String, flags: Int32, mode: mode_t = 0) throws -> Int32 {
        let fileFD = openat(fd, name, flags | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode)
        guard fileFD >= 0 else { throw TextureImportError.system("打开素材文件") }
        var info = stat()
        guard fstat(fileFD, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, info.st_nlink == 1 else {
            close(fileFD); throw TextureImportError.invalid("素材文件类型、所有者或权限无效。")
        }
        return fileFD
    }
    private func parent(_ path: String, create: Bool = false) throws -> (TextureDirectory, String) {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw TextureImportError.invalid("素材相对路径无效。")
        }
        var directory = self
        for part in parts.dropLast() { directory = try directory.child(part, create: create) }
        return (directory, parts.last!)
    }
    func read(_ path: String, maximum: Int) throws -> Data {
        let (parent, name) = try parent(path)
        let fileFD = try parent.file(name, flags: O_RDONLY)
        defer { close(fileFD) }
        return try readTextureFile(fileFD, maximum: maximum)
    }
    func readIfPresent(_ name: String, maximum: Int) throws -> Data? {
        do { return try read(name, maximum: maximum) }
        catch TextureImportError.system(_, let code) where code == ENOENT { return nil }
    }
    func writeNew(_ path: String, data: Data) throws {
        let (parent, name) = try parent(path, create: true)
        let fileFD = try parent.file(name, flags: O_WRONLY | O_CREAT | O_EXCL, mode: 0o600)
        var complete = false
        defer { close(fileFD); if !complete { _ = unlinkat(parent.fd, name, 0) } }
        try data.withUnsafeBytes { buffer in
            var cursor = 0
            while cursor < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(fileFD, buffer.baseAddress!.advanced(by: cursor), min(1024 * 1024, buffer.count - cursor))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TextureImportError.system("写入素材") }
                cursor += count
            }
        }
        guard fsync(fileFD) == 0 else { throw TextureImportError.system("保存素材") }
        try parent.sync(); complete = true
    }
    func sync() throws { guard fsync(fd) == 0 else { throw TextureImportError.system("保存素材目录") } }
    func removeFile(_ path: String) throws {
        let (parent, name) = try parent(path)
        guard unlinkat(parent.fd, name, 0) == 0 else { throw TextureImportError.system("移除未完成素材") }
    }
    func removeEmptyDirectories(for paths: [String]) throws {
        var directories = Set<String>()
        for path in paths {
            var parts = path.split(separator: "/").map(String.init); _ = parts.popLast()
            while !parts.isEmpty { directories.insert(parts.joined(separator: "/")); _ = parts.popLast() }
        }
        for path in directories.sorted(by: { $0.split(separator: "/").count > $1.split(separator: "/").count }) {
            if let (parent, name) = try? parent(path) { _ = unlinkat(parent.fd, name, AT_REMOVEDIR) }
        }
    }
}

private func readTextureFile(_ fd: Int32, maximum: Int) throws -> Data {
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
          before.st_size > 0, before.st_size <= maximum else { throw TextureImportError.invalid("素材输入不是常规文件或超过读取上限。") }
    var result = Data(); result.reserveCapacity(Int(before.st_size))
    var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
    while true {
        try Task.checkCancellation()
        let count = Darwin.read(fd, &buffer, min(buffer.count, maximum - result.count + 1))
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw TextureImportError.system("读取素材") }
        if count == 0 { break }
        guard result.count + count <= maximum else { throw TextureImportError.invalid("素材读取期间超过大小上限。") }
        result.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    guard fstat(fd, &after) == 0, before.st_size == after.st_size, result.count == before.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
        throw TextureImportError.invalid("素材在读取期间发生变化，请重试。")
    }
    return result
}

private struct TextureZIP {
    let data: Data
    init(_ data: Data) { self.data = data }
    struct Member {
        let path: String
        let method: Int
        let crc: UInt32
        let bytes: Int
        let range: Range<Int>
        func inflate(from archive: Data) throws -> Data {
            var output: Data
            if method == 0 {
                guard range.count == bytes else { throw TextureImportError.invalid("ZIP stored 大小不一致。") }
                output = archive.subdata(in: range)
            } else {
                // One extra byte detects output exceeding its declared size.
                output = Data(count: bytes + 1)
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                    throw TextureImportError.invalid("无法初始化系统解压器。")
                }
                defer { inflateEnd(&stream) }
                try archive.withUnsafeBytes { input in
                    try output.withUnsafeMutableBytes { target in
                        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: range.lowerBound))
                        stream.avail_in = uInt(range.count)
                        while true {
                            try Task.checkCancellation()
                            let offset = Int(stream.total_out)
                            guard offset < target.count else { throw TextureImportError.invalid("ZIP 解压超过声明大小。") }
                            stream.next_out = target.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset)
                            stream.avail_out = uInt(min(64 * 1024, target.count - offset))
                            let oldIn = stream.total_in, oldOut = stream.total_out
                            let status = zlib.inflate(&stream, Z_NO_FLUSH)
                            if status == Z_STREAM_END { break }
                            guard status == Z_OK, stream.total_in > oldIn || stream.total_out > oldOut else {
                                throw TextureImportError.invalid("ZIP deflate 数据损坏。")
                            }
                        }
                        guard stream.total_in == range.count, stream.total_out == bytes else {
                            throw TextureImportError.invalid("ZIP 解压长度或尾部不一致。")
                        }
                    }
                }
                output.removeLast()
            }
            let actual = output.withUnsafeBytes { zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
            guard UInt32(truncatingIfNeeded: actual) == crc else { throw TextureImportError.invalid("ZIP 素材 CRC 校验失败：\(path)") }
            return output
        }
    }
    private func u16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset <= data.count - 2 else { throw TextureImportError.invalid("ZIP 字段越界。") }
        return data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian) }
    }
    private func u32(_ offset: Int) throws -> Int {
        guard offset >= 0, offset <= data.count - 4 else { throw TextureImportError.invalid("ZIP 字段越界。") }
        return data.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian) }
    }
    private func checkExtra(_ start: Int, _ count: Int, allowAlignmentPadding: Bool = false) throws {
        let end = start + count
        guard end <= data.count else { throw TextureImportError.invalid("ZIP extra 越界。") }
        var cursor = start
        while cursor < end {
            // The recorded official APK has zipalign zero padding in local
            // headers (including a page-aligned .so). This is not a ZIP64 TLV.
            if allowAlignmentPadding, data[cursor..<end].allSatisfy({ $0 == 0 }) { return }
            guard end - cursor >= 4 else { throw TextureImportError.invalid("ZIP extra 不完整。") }
            let tag = try u16(cursor), size = try u16(cursor + 2)
            guard tag != 1, size <= end - cursor - 4 else { throw TextureImportError.invalid("不支持 ZIP64 或损坏的 extra。") }
            cursor += 4 + size
        }
    }
    private enum Selection { case textures, fonts }
    func textures() throws -> [Member] { try selected(.textures) }
    func fonts() throws -> [Member] { try selected(.fonts) }

    private func selected(_ selection: Selection) throws -> [Member] {
        guard data.count >= 22 else { throw TextureImportError.invalid("APK 的 ZIP 目录不完整。") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 22 - 65535), by: -1) {
            if try u32(offset) == 0x06054b50, try offset + 22 + u16(offset + 20) == data.count { end = offset; break }
        }
        guard let end else { throw TextureImportError.invalid("找不到 APK 的 ZIP 目录。") }
        let count = try u16(end + 10), centralSize = try u32(end + 12), centralStart = try u32(end + 16)
        guard try u16(end + 4) == 0, try u16(end + 6) == 0, try u16(end + 8) == count,
              count > 0, count <= 4096, centralStart + centralSize == end else {
            throw TextureImportError.invalid("不支持分卷、ZIP64 或非标准 ZIP 目录。")
        }
        var cursor = centralStart, total = 0
        var members: [Member] = [], ranges: [Range<Int>] = [], names = Set<String>(), textureNames = Set<String>()
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor >= 0, cursor + 46 <= end, try u32(cursor) == 0x02014b50 else { throw TextureImportError.invalid("ZIP 中央目录损坏。") }
            let creator = try u16(cursor + 4) >> 8, flags = try u16(cursor + 8), method = try u16(cursor + 10)
            let crc = UInt32(try u32(cursor + 16)), compressed = try u32(cursor + 20), bytes = try u32(cursor + 24)
            let nameSize = try u16(cursor + 28), extraSize = try u16(cursor + 30), commentSize = try u16(cursor + 32)
            let attrs = try u32(cursor + 38), local = try u32(cursor + 42)
            let next = cursor + 46 + nameSize + extraSize + commentSize
            guard next <= end, nameSize > 0, nameSize <= 4096, try u16(cursor + 34) == 0,
                  flags & ~0x080e == 0, method == 0 || method == 8,
                  compressed != 0xffffffff, bytes != 0xffffffff, local != 0xffffffff,
                  !(creator == 3 && (attrs >> 16) & 0xf000 == 0xa000) else { throw TextureImportError.invalid("APK 包含不支持的 ZIP 成员。") }
            try checkExtra(cursor + 46 + nameSize, extraSize)
            let nameBytes = data.subdata(in: cursor + 46..<cursor + 46 + nameSize)
            guard let name = String(data: nameBytes, encoding: .utf8), !name.contains("\0"), !name.contains("\\"),
                  !name.contains(":"), !name.hasPrefix("/"), !name.hasPrefix("~") else { throw TextureImportError.invalid("ZIP 成员路径无效。") }
            let pathWithoutSlash = name.hasSuffix("/") ? String(name.dropLast()) : name
            guard pathWithoutSlash.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  names.insert(name).inserted else {
                throw TextureImportError.invalid("ZIP 包含路径穿越或重复成员。")
            }
            guard local >= 0, local + 30 <= centralStart, try u32(local) == 0x04034b50,
                  try u16(local + 6) == flags, try u16(local + 8) == method, try u16(local + 26) == nameSize else {
                throw TextureImportError.invalid("ZIP 本地目录与中央目录不一致。")
            }
            let localExtra = try u16(local + 28), payload = local + 30 + nameSize + localExtra
            guard payload <= centralStart, compressed <= centralStart - payload,
                  data.subdata(in: local + 30..<local + 30 + nameSize) == nameBytes else { throw TextureImportError.invalid("ZIP 成员范围或名称不一致。") }
            try checkExtra(local + 30 + nameSize, localExtra, allowAlignmentPadding: true)
            var memberEnd = payload + compressed
            if flags & 8 != 0 {
                var descriptorEnds: [Int] = []
                if memberEnd + 12 <= centralStart, try u32(memberEnd) == crc,
                   try u32(memberEnd + 4) == compressed, try u32(memberEnd + 8) == bytes { descriptorEnds.append(memberEnd + 12) }
                if memberEnd + 16 <= centralStart, try u32(memberEnd) == 0x08074b50,
                   try u32(memberEnd + 4) == crc, try u32(memberEnd + 8) == compressed,
                   try u32(memberEnd + 12) == bytes { descriptorEnds.append(memberEnd + 16) }
                guard descriptorEnds.count == 1 else { throw TextureImportError.invalid("ZIP 数据描述符不一致或有歧义。") }
                memberEnd = descriptorEnds[0]
                guard try (u32(local + 14) == 0 || u32(local + 14) == crc),
                      try (u32(local + 18) == 0 || u32(local + 18) == compressed),
                      try (u32(local + 22) == 0 || u32(local + 22) == bytes) else { throw TextureImportError.invalid("ZIP 本地长度不一致。") }
            } else {
                guard try u32(local + 14) == crc, try u32(local + 18) == compressed, try u32(local + 22) == bytes else {
                    throw TextureImportError.invalid("ZIP 本地校验或长度不一致。")
                }
            }
            ranges.append(local..<memberEnd)
            let lowerName = name.lowercased(with: Locale(identifier: "en_US_POSIX"))
            let isSelected: Bool
            switch selection {
            case .textures: isSelected = name.hasPrefix("assets/materials/") && lowerName.hasSuffix(".tex")
            case .fonts: isSelected = name.hasPrefix("assets/fonts/") && (lowerName.hasSuffix(".ttf") || lowerName.hasSuffix(".otf"))
            }
            if isSelected {
                // APK res/ entries can legitimately differ only by case. They
                // are never written; only selected TEX destinations need the
                // stricter case-insensitive collision guard used by macOS.
                let relativePath = String(name.dropFirst("assets/".count))
                let path: String
                switch selection {
                case .textures: path = try NativeBuiltinTextures.texturePath(relativePath)
                case .fonts: path = try NativeBuiltinFonts.fontPath(relativePath)
                }
                guard textureNames.insert(path).inserted, bytes > 0, bytes <= NativeBuiltinTextures.maximumTextureBytes,
                      members.count < NativeBuiltinTextures.maximumTextures else { throw TextureImportError.invalid("ZIP 素材大小、数量或名称超限。") }
                total += bytes
                guard total <= NativeBuiltinTextures.maximumTotalBytes else { throw TextureImportError.invalid("ZIP 纹理总大小超过 128 MiB。") }
                members.append(Member(path: path, method: method, crc: crc, bytes: bytes, range: payload..<payload + compressed))
            }
            cursor = next
        }
        guard cursor == end, !members.isEmpty else { throw TextureImportError.invalid("APK 中没有可导入的对应内置素材。") }
        let ordered = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<ordered.count where ordered[index - 1].upperBound > ordered[index].lowerBound {
            throw TextureImportError.invalid("ZIP 成员范围重叠。")
        }
        return members.sorted { $0.path < $1.path }
    }
}
