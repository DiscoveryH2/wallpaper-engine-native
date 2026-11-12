import Darwin
import Foundation

enum NativeCreationStore {
    struct Record: Codable, Equatable, Sendable {
        var format = 1
        let id: UUID
        let version: UUID
        let title: String
        let savedAt: Date
        var previewTime: Double?
        var directory: URL { root.appendingPathComponent(id.uuidString).appendingPathComponent(version.uuidString) }
        var project: URL { directory.appendingPathComponent("project.json") }
    }
    struct Loaded: Sendable {
        let record: Record
        let document: NativeCreationDocument
        let images: [UUID: NativeCreationImage]
    }
    struct History: Sendable {
        let current: Record
        let items: [Record]
        let skipped: Int
    }
    struct Historical: Sendable {
        let current: Record
        let saved: Loaded
    }
    struct Snapshot: Sendable {
        let directory: URL
        let record: Record?
        var project: URL { directory.appendingPathComponent("project.json") }
    }
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WallpaperEngineNative/CreatedProjects") }
    private static var previewRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/WallpaperEngineNative/EditorPreviews") }
    private static let queue = DispatchQueue(label: "io.wallpaper-engine-native.creation", qos: .userInitiated)

    static func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }

    private static func makeDirectory(_ parent: WebSourceFD, _ name: String) throws -> WebSourceFD {
        guard mkdirat(parent.raw, name, 0o700) == 0 || errno == EEXIST else { throw WebSourceFD.failure("无法创建作品目录") }
        let child = try parent.child(name, directory: true)
        guard try child.info().st_uid == getuid() else { throw SceneError.invalid("作品目录不属于当前用户。") }
        return child
    }

    private static func base(preview: Bool, create: Bool) throws -> WebSourceFD {
        let url = preview ? previewRoot : root
        if !create { return try WebSourceFD.openAbsolute(url, directory: true) }
        var directory = try WebSourceFD.openAbsolute(FileManager.default.homeDirectoryForCurrentUser, directory: true)
        for name in preview ? ["Library", "Caches", "WallpaperEngineNative", "EditorPreviews"] : ["Library", "Application Support", "WallpaperEngineNative", "CreatedProjects"] {
            directory = try makeDirectory(directory, name)
        }
        return directory
    }

    private static func write(_ bytes: Data, name: String, directory: WebSourceFD) throws {
        let fd = openat(directory.raw, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WebSourceFD.failure("无法写入作品文件") }
        defer { Darwin.close(fd) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw WebSourceFD.failure("作品文件写入失败") }
            offset += count
        }
        guard fsync(fd) == 0 else { throw WebSourceFD.failure("无法完成作品文件保存") }
    }

    static func snapshot(_ document: NativeCreationDocument, images: [UUID: NativeCreationImage], save: Bool, expectedVersion: UUID?, preview: NativeCreationPreview? = nil) throws -> Snapshot {
        let resources = try document.resources(images: images, preview: preview)
        let directory = try base(preview: !save, create: true)
        let baseURL = save ? root : previewRoot
        let total = resources.values.reduce(0, { $0 + $1.count })
        let capacity = try baseURL.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        guard let capacity, capacity > total + 512 * 1024 * 1024 else { throw SceneError.invalid("保存作品需要至少保留 512 MiB 可用空间。") }
        let version = UUID()
        let owner = save ? try makeDirectory(directory, document.id.uuidString) : directory
        if save {
            let current = try currentRecord(owner, id: document.id)
            guard current?.version == expectedVersion else { throw SceneError.invalid("作品已被另一窗口或版本更新，请重新打开后编辑；当前修改仍保留。") }
        }
        guard mkdirat(owner.raw, version.uuidString, 0o700) == 0 else { throw WebSourceFD.failure("无法准备作品版本") }
        let output = try owner.child(version.uuidString, directory: true)
        let outputURL = save ? root.appendingPathComponent(document.id.uuidString).appendingPathComponent(version.uuidString) : previewRoot.appendingPathComponent(version.uuidString)
        do {
            for (path, bytes) in resources.sorted(by: { $0.key < $1.key }) {
                let parts = path.split(separator: "/").map(String.init)
                var parent = output
                for part in parts.dropLast() { parent = try makeDirectory(parent, part) }
                try write(bytes, name: parts.last!, directory: parent)
            }
            let record = save ? Record(id: document.id, version: version, title: document.title, savedAt: Date(), previewTime: preview?.time) : nil
            if let record {
                let encoded = try JSONEncoder().encode(record)
                try write(encoded, name: "record.json", directory: output)
                // Recheck the head before the commit. The queue serializes this app's writers.
                guard try currentRecord(owner, id: document.id)?.version == expectedVersion else { throw SceneError.invalid("作品保存位置已更新，请重新打开后编辑。") }
                let temporary = ".current-\(UUID().uuidString).json"
                try write(encoded, name: temporary, directory: owner)
                guard renameat(owner.raw, temporary, owner.raw, "current.json") == 0 else {
                    unlinkat(owner.raw, temporary, 0)
                    throw WebSourceFD.failure("无法提交作品版本")
                }
                fsync(owner.raw)
            }
            return Snapshot(directory: outputURL, record: record)
        } catch {
            // A partial version is not published in current.json; prior versions remain valid.
            throw error
        }
    }

    private static func currentRecord(_ owner: WebSourceFD, id: UUID) throws -> Record? {
        var info = stat()
        if fstatat(owner.raw, "current.json", &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw WebSourceFD.failure("无法读取作品索引")
        }
        let record = try JSONDecoder().decode(Record.self, from: owner.child("current.json", directory: false).readSmall(maximum: 8192))
        guard record.format == 1, record.id == id, record.title.utf8.count <= 256,
              record.previewTime.map({ $0.isFinite && (0...120).contains($0) }) ?? true else { throw SceneError.invalid("作品索引无效。") }
        return record
    }

    static func records() -> (items: [Record], warning: String?) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], nil) }
        do {
            let base = try base(preview: false, create: false)
            var values: [Record] = [], skipped = 0
            for name in try base.names(maximum: 2048) {
                guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
                do {
                    let owner = try base.child(name, directory: true)
                    if let record = try currentRecord(owner, id: id) {
                        let version = try owner.child(record.version.uuidString, directory: true)
                        _ = try version.child("project.json", directory: false)
                        _ = try version.child("editor.json", directory: false)
                        values.append(record)
                    }
                } catch { skipped += 1 }
            }
            return (values.sorted { $0.savedAt > $1.savedAt }, skipped == 0 ? nil : "\(skipped) 项本机作品暂不可读")
        } catch { return ([], "本机作品目录暂不可读：\(error.localizedDescription)") }
    }

    static func record(for project: URL) -> Record? {
        let prefix = root.path + "/"
        guard project.isFileURL, project.path.hasPrefix(prefix) else { return nil }
        let parts = String(project.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard parts.count == 3, let id = UUID(uuidString: parts[0]), id.uuidString == parts[0],
              let version = UUID(uuidString: parts[1]), version.uuidString == parts[1], parts[2] == "project.json" else { return nil }
        do {
            let directory = try base(preview: false, create: false).child(parts[0], directory: true).child(parts[1], directory: true)
            let record = try JSONDecoder().decode(Record.self, from: directory.child("record.json", directory: false).readSmall(maximum: 8192))
            guard record.format == 1, record.id == id, record.version == version, record.title.utf8.count <= 256,
                  record.previewTime.map({ $0.isFinite && (0...120).contains($0) }) ?? true else { return nil }
            return record
        } catch { return nil }
    }

    static func load(_ record: Record) throws -> Loaded {
        let owner = try base(preview: false, create: false).child(record.id.uuidString, directory: true)
        guard try currentRecord(owner, id: record.id)?.version == record.version else { throw SceneError.invalid("作品已有更新版本，请重新选择。") }
        let version = try owner.child(record.version.uuidString, directory: true)
        return try loadContents(record, version: version)
    }

    private static func savedRecord(_ owner: WebSourceFD, id: UUID, version: UUID) throws -> Record {
        let directory = try owner.child(version.uuidString, directory: true)
        let record = try JSONDecoder().decode(Record.self, from: directory.child("record.json", directory: false).readSmall(maximum: 8192))
        guard record.format == 1, record.id == id, record.version == version,
              !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.title.contains("\0"), record.title.utf8.count <= 256,
              record.savedAt.timeIntervalSinceReferenceDate.isFinite,
              record.previewTime.map({ $0.isFinite && (0...120).contains($0) }) ?? true else {
            throw SceneError.invalid("作品历史版本记录无效。")
        }
        _ = try directory.child("project.json", directory: false)
        _ = try directory.child("editor.json", directory: false)
        return record
    }

    /// Lists completed, readable version directories without changing current.json.
    /// A version whose index commit failed can still be recovered if its files
    /// were completed; the list does not claim that it was previously current.
    static func history(for id: UUID) throws -> History {
        let owner = try base(preview: false, create: false).child(id.uuidString, directory: true)
        guard let current = try currentRecord(owner, id: id),
              try savedRecord(owner, id: id, version: current.version) == current else {
            throw SceneError.invalid("作品当前版本记录不一致，请重新打开作品。")
        }
        var items: [Record] = [], skipped = 0
        for name in try owner.names(maximum: 4096) {
            guard let version = UUID(uuidString: name), version.uuidString == name else { continue }
            do { items.append(try savedRecord(owner, id: id, version: version)) }
            catch { skipped += 1 }
        }
        guard try currentRecord(owner, id: id) == current else { throw SceneError.invalid("作品版本已更新，请重新打开历史版本窗口。") }
        return History(current: current, items: items.sorted {
            $0.savedAt == $1.savedAt ? $0.version.uuidString > $1.version.uuidString : $0.savedAt > $1.savedAt
        }, skipped: skipped)
    }

    static func requireCurrent(_ expected: Record) throws {
        let owner = try base(preview: false, create: false).child(expected.id.uuidString, directory: true)
        guard try currentRecord(owner, id: expected.id) == expected else {
            throw SceneError.invalid("作品已有更新版本；当前编辑内容仍保留，请重新打开历史版本窗口。")
        }
    }

    static func loadHistorical(_ selected: Record, expectedCurrent: Record) throws -> Historical {
        guard selected.id == expectedCurrent.id else { throw SceneError.invalid("历史版本不属于当前作品。") }
        try requireCurrent(expectedCurrent)
        let owner = try base(preview: false, create: false).child(selected.id.uuidString, directory: true)
        guard try savedRecord(owner, id: selected.id, version: selected.version) == selected else {
            throw SceneError.invalid("历史版本记录已改变，请重新选择。")
        }
        let saved = try loadContents(selected, version: owner.child(selected.version.uuidString, directory: true))
        try requireCurrent(expectedCurrent)
        return Historical(current: expectedCurrent, saved: saved)
    }

    private static func loadContents(_ record: Record, version: WebSourceFD) throws -> Loaded {
        let document = try JSONDecoder().decode(NativeCreationDocument.self, from: version.child("editor.json", directory: false).readSmall(maximum: 512 * 1024)).validated()
        guard document.id == record.id else { throw SceneError.invalid("作品身份与保存记录不符。") }
        var images: [UUID: NativeCreationImage] = [:]
        var pixels = 0
        for id in Set(document.layers.compactMap { $0.kind == .image ? $0.imageID : nil }) {
            let file = try version.child("assets", directory: true).child(id.uuidString + ".png", directory: false)
            let image = try NativeCreationImage.normalize(file.readSmall(maximum: 64 * 1024 * 1024))
            pixels += image.width * image.height
            guard pixels <= 32_000_000 else { throw SceneError.invalid("作品图片超出内存限制。") }
            images[id] = image
        }
        return Loaded(record: record, document: document, images: images)
    }

    static func removePreview(_ snapshot: Snapshot) {
        guard snapshot.record == nil, snapshot.directory.deletingLastPathComponent() == previewRoot,
              UUID(uuidString: snapshot.directory.lastPathComponent) != nil else { return }
        // Only this editor's generated cache snapshot; never a saved version or user-selected directory.
        try? FileManager.default.removeItem(at: snapshot.directory)
    }
}
