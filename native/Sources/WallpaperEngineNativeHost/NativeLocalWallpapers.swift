import CryptoKit
import Darwin
import Foundation

enum NativeWallpaperImportRequest: Sendable {
    case image(URL), video(URL), web(URL, name: String)
    var source: URL { switch self { case .image(let url), .video(let url), .web(let url, _): return url } }
    var type: String { switch self { case .image: return "image"; case .video: return "video"; case .web: return "web" } }
    var title: String {
        let candidate: String
        if case .web(let url, let name) = self { candidate = name.isEmpty ? (url.host ?? url.absoluteString) : name }
        else { candidate = source.deletingPathExtension().lastPathComponent }
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((value.isEmpty ? "未命名壁纸" : value).prefix(128))
    }
}

enum NativeWallpaperURL {
    static func parse(_ text: String) throws -> URL {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !text.contains("\\"), var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw PropertyError.invalid("请输入完整的 http:// 或 https:// 网页地址，不包含用户名和密码。")
        }
        components.scheme = scheme; components.host = host.lowercased()
        guard let url = components.url else { throw PropertyError.invalid("网页地址无效。") }
        return url
    }
}

private final class NativeImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
}

/// Only a successfully prepared renderer publishes current.json. An abandoned
/// import owns just its new version directory, never the user's source file.
enum NativeLocalWallpapers {
    private enum Retry: Error { case metadataChanged }
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WallpaperEngineNative/LocalWallpapers") }
    struct Record: Codable, Sendable {
        var format = 1
        let id: String
        let version: UUID
        let title: String
        let type: String
        let sourceRevision: String
        let createdAt: Date
        func project(in root: URL) -> URL { root.appendingPathComponent(id).appendingPathComponent(version.uuidString).appendingPathComponent("project.json") }
    }
    final class Prepared: @unchecked Sendable {
        let record: Record
        let root: URL
        let expectedVersion: UUID?
        private let lock = NSLock()
        private var published: Bool
        var project: URL { record.project(in: root) }
        fileprivate init(record: Record, root: URL, expectedVersion: UUID?, reused: Bool) {
            self.record = record; self.root = root; self.expectedVersion = expectedVersion; published = reused
        }
        func commit() throws {
            lock.lock(); defer { lock.unlock() }
            let owner = try WebSourceFD.openAbsolute(root, directory: true).child(record.id, directory: true)
            guard flock(owner.raw, LOCK_EX) == 0 else { throw WebSourceFD.failure("无法提交本机壁纸") }
            defer { flock(owner.raw, LOCK_UN) }
            let previous = try NativeLocalWallpapers.current(owner, id: record.id)
            if published {
                guard previous?.version == record.version else { throw PropertyError.invalid("本机壁纸已有更新版本，请重试。") }
                return
            }
            guard previous?.version == expectedVersion else { throw PropertyError.invalid("本机壁纸已被另一窗口更新，请重试。") }
            let name = ".current-" + UUID().uuidString
            do { try NativeLocalWallpapers.write(JSONEncoder().encode(record), name: name, to: owner) }
            catch { unlinkat(owner.raw, name, 0); throw error }
            guard renameat(owner.raw, name, owner.raw, "current.json") == 0 else {
                unlinkat(owner.raw, name, 0); throw WebSourceFD.failure("无法保存本机壁纸记录")
            }
            published = true
            fsync(owner.raw)
        }
        deinit {
            guard !published else { return }
            let directory = project.deletingLastPathComponent()
            WebMediaIO.queue.async {
                try? FileManager.default.removeItem(at: directory)
                // Atomic rmdir succeeds only if no published or concurrent
                // version remains; never recursively remove the owner.
                _ = Darwin.rmdir(directory.deletingLastPathComponent().path)
            }
        }
    }

    static func prepare(_ request: NativeWallpaperImportRequest, at location: URL = root) async throws -> Prepared {
        let token = NativeImportCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await WebMediaIO.perform {
                for attempt in 0..<3 {
                    do { return try prepare(request, at: location, cancellation: token) }
                    catch Retry.metadataChanged {
                        try token.check()
                        guard attempt < 2 else { throw PropertyError.invalid("素材信息仍在变化，请稍后重试。") }
                        // NSOpenPanel can update last-used metadata after it
                        // returns. Take a fresh snapshot; do not relax the
                        // before/after signature check on the accepted copy.
                        Thread.sleep(forTimeInterval: 0.03)
                    }
                }
                throw PropertyError.invalid("无法取得稳定的素材副本。")
            }
            try Task.checkCancellation()
            return result
        } onCancel: { token.cancel() }
    }

    private static func base(_ root: URL, create: Bool) throws -> WebSourceFD {
        if !create { return try WebSourceFD.openAbsolute(root, directory: true) }
        // No user-selected parent is enumerated. This walk is confined to the
        // app-owned destination (or a test-owned directory supplied by tests).
        if root == Self.root {
            let home = FileManager.default.homeDirectoryForCurrentUser
            guard root.path.hasPrefix(home.path + "/") else { throw PropertyError.invalid("本机壁纸目录必须位于当前用户目录内。") }
            var parent = try WebSourceFD.openAbsolute(home, directory: true)
            for name in root.path.dropFirst(home.path.count + 1).split(separator: "/") { parent = try directory(parent, String(name)) }
            return parent
        }
        var parent = try WebSourceFD.openAbsolute(root.deletingLastPathComponent(), directory: true)
        parent = try directory(parent, root.lastPathComponent)
        return parent
    }
    private static func directory(_ parent: WebSourceFD, _ name: String) throws -> WebSourceFD {
        guard mkdirat(parent.raw, name, 0o700) == 0 || errno == EEXIST else { throw WebSourceFD.failure("无法创建本机壁纸目录") }
        let result = try parent.child(name, directory: true)
        guard try result.info().st_uid == getuid() else { throw PropertyError.invalid("本机壁纸目录不属于当前用户。") }
        return result
    }
    private static func write(_ data: Data, name: String, to directory: WebSourceFD) throws {
        let raw = openat(directory.raw, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard raw >= 0 else { throw WebSourceFD.failure("无法写入本机壁纸") }
        defer { Darwin.close(raw) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(raw, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw WebSourceFD.failure("本机壁纸写入失败") }; offset += count
        }
        guard fsync(raw) == 0 else { throw WebSourceFD.failure("无法完成本机壁纸保存") }
    }
    private static func prepare(_ request: NativeWallpaperImportRequest, at root: URL, cancellation: NativeImportCancellation) throws -> Prepared {
        try cancellation.check()
        let source: URL
        if case .web = request { source = try NativeWallpaperURL.parse(request.source.absoluteString) }
        else {
            guard request.source.isFileURL else { throw PropertyError.invalid("请选择本机素材文件。") }
            source = request.source.standardizedFileURL
        }
        let scoped = source.isFileURL && source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let file: WebSourceFD?
        let signature: WebFileSignature?
        if source.isFileURL {
            // Open the explicitly selected file itself, without requesting its
            // parent/siblings or following a symlink at the selected leaf.
            let raw = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard raw >= 0 else { throw WebSourceFD.failure("无法打开所选素材") }
            let selected = WebSourceFD(raw), info = try selected.info()
            let limit: Int64 = request.type == "image" ? 256 * 1024 * 1024 : 4 * 1024 * 1024 * 1024
            guard info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= limit else {
                throw PropertyError.invalid("请选择普通文件；静态图片最大 256 MiB，视频最大 4 GiB。")
            }
            file = selected; signature = WebFileSignature(info)
        } else { file = nil; signature = nil }
        let identity = request.type + ":" + source.absoluteString
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let revision = signature?.revision ?? source.absoluteString
        let owner = try directory(base(root, create: true), id)
        let previous = try current(owner, id: id)
        if let previous, previous.sourceRevision == revision, previous.title == request.title {
            let version = try owner.child(previous.version.uuidString, directory: true)
            _ = try version.child("project.json", directory: false)
            return Prepared(record: previous, root: root, expectedVersion: previous.version, reused: true)
        }
        let record = Record(id: id, version: UUID(), title: request.title, type: request.type, sourceRevision: revision, createdAt: Date())
        let result = Prepared(record: record, root: root, expectedVersion: previous?.version, reused: false)
        let output = try directory(owner, record.version.uuidString)
        var project: [String: Any] = ["title": record.title, "type": record.type, "tags": ["Local", "Everyone"]]
        if let file, let signature {
            let ext = source.pathExtension.lowercased()
            guard ext.utf8.count <= 12, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                throw PropertyError.invalid("素材扩展名无效。")
            }
            let name = "wallpaper" + (ext.isEmpty ? "" : "." + ext)
            try copy(file, name: name, to: output, root: root, signature: signature, cancellation: cancellation)
            project["file"] = name
            if request.type == "image" {
                let image = try NativeWallpaperImage.decode(result.project.deletingLastPathComponent().appendingPathComponent(name))
                try cancellation.check()
                try write(NativeWallpaperImage.preview(image), name: "preview.png", to: output)
                project["preview"] = "preview.png"
            }
        } else { project["file"] = source.absoluteString }
        try cancellation.check()
        try write(JSONSerialization.data(withJSONObject: project, options: [.sortedKeys]), name: "project.json", to: output)
        try write(JSONEncoder().encode(record), name: "record.json", to: output)
        return result
    }
    private static func copy(_ source: WebSourceFD, name: String, to target: WebSourceFD, root: URL, signature: WebFileSignature, cancellation: NativeImportCancellation) throws {
        if fclonefileat(source.raw, target.raw, name, UInt32(CLONE_NOOWNERCOPY)) != 0 {
            guard [EXDEV, ENOTSUP, EINVAL, ENOSYS].contains(errno) else { throw WebSourceFD.failure("无法复制所选素材") }
            let available = (try FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
            guard available >= signature.size + 512 * 1024 * 1024 else { throw PropertyError.invalid("磁盘空间不足，未复制素材。") }
            let raw = openat(target.raw, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard raw >= 0 else { throw WebSourceFD.failure("无法创建素材副本") }
            defer { Darwin.close(raw) }
            var offset: Int64 = 0, buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while offset < signature.size {
                try cancellation.check()
                let capacity = Int(min(Int64(buffer.count), signature.size - offset))
                let count = buffer.withUnsafeMutableBytes { pread(source.raw, $0.baseAddress!, capacity, offset) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PropertyError.invalid("素材在复制时发生变化。") }
                var written = 0
                while written < count {
                    let n = buffer.withUnsafeBytes { Darwin.write(raw, $0.baseAddress!.advanced(by: written), count - written) }
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw WebSourceFD.failure("素材复制失败") }; written += n
                }
                offset += Int64(count)
            }
            guard fsync(raw) == 0 else { throw WebSourceFD.failure("无法完成素材复制") }
        }
        try cancellation.check()
        let after = try WebFileSignature(source.info())
        guard try target.child(name, directory: false).info().st_size == signature.size else { throw PropertyError.invalid("素材副本大小不完整，请重试。") }
        guard after == signature else {
            if after.device == signature.device, after.inode == signature.inode, after.size == signature.size,
               after.modifiedSeconds == signature.modifiedSeconds, after.modifiedNanoseconds == signature.modifiedNanoseconds {
                throw Retry.metadataChanged
            }
            throw PropertyError.invalid("素材在复制时发生变化，请重试。")
        }
    }
    private static func current(_ owner: WebSourceFD, id: String) throws -> Record? {
        var info = stat()
        if fstatat(owner.raw, "current.json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw WebSourceFD.failure("无法读取本机壁纸记录")
        }
        let record = try JSONDecoder().decode(Record.self, from: owner.child("current.json", directory: false).readSmall(maximum: 16384))
        guard record.format == 1, record.id == id, ["image", "video", "web"].contains(record.type),
              record.title.count <= 128, record.sourceRevision.utf8.count <= 8192 else { throw PropertyError.invalid("本机壁纸记录无效。") }
        return record
    }
    static func records(at location: URL = root) -> (items: [(record: Record, project: URL)], warning: String?) {
        guard FileManager.default.fileExists(atPath: location.path) else { return ([], nil) }
        do {
            let base = try base(location, create: false)
            var items: [(Record, URL)] = [], skipped = 0
            for id in try base.names(maximum: 4096) where id.utf8.count == 64 && id.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
                do {
                    let owner = try base.child(id, directory: true)
                    guard let record = try current(owner, id: id) else { continue }
                    _ = try owner.child(record.version.uuidString, directory: true).child("project.json", directory: false)
                    items.append((record, record.project(in: location)))
                } catch { skipped += 1 }
            }
            return (items, skipped == 0 ? nil : "\(skipped) 项离线壁纸暂不可读")
        } catch { return ([], "离线壁纸目录暂不可读：\(error.localizedDescription)") }
    }
    static func identity(for project: URL) -> String? {
        let prefix = root.path + "/"
        guard project.isFileURL, project.path.hasPrefix(prefix) else { return nil }
        let parts = project.path.dropFirst(prefix.count).split(separator: "/")
        guard parts.count == 3, parts[0].utf8.count == 64, parts[0].allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              UUID(uuidString: String(parts[1])) != nil, parts[2] == "project.json" else { return nil }
        return "local:" + parts[0]
    }
}
