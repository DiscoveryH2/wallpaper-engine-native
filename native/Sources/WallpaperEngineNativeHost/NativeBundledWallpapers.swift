import CryptoKit
import Darwin
import Foundation

/// Original wallpapers shipped with this application. Immutable local copies
/// keep saved desktop paths independent of the app's installation location.
enum NativeBundledWallpapers {
    struct Entry: Codable, Equatable, Sendable {
        let id: String, revision: String, title: String, type: String
        let files: [String: String]
    }
    struct Catalog: Codable, Sendable { let version: Int; let wallpapers: [Entry] }
    struct Record: Equatable, Sendable {
        let entry: Entry
        let project: URL
        var title: String { entry.title }
        var type: String { entry.type }
        var id: String { entry.id }
        var revision: String { entry.revision }
    }
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WallpaperEngineNative/BundledWallpapers", isDirectory: true)
    }
    private static let lock = NSLock()
    private static let maximumFileBytes = 32 * 1024 * 1024
    private static let maximumEntryBytes = 64 * 1024 * 1024

    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func hex(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func parts(_ path: String) throws -> [String] {
        let result = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard path.utf8.count <= 512, (1...8).contains(result.count), result.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\\") && !$0.contains("\0") && !$0.contains(":") }) else {
            throw PropertyError.invalid("内置壁纸包含无效的素材位置。")
        }
        return result
    }
    private static func validate(_ entry: Entry) throws {
        guard (1...48).contains(entry.id.utf8.count), entry.id.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              hex(entry.revision), !entry.title.isEmpty, entry.title.utf8.count <= 256, !entry.title.contains("\0"),
              ["scene", "web", "video"].contains(entry.type), (2...256).contains(entry.files.count),
              entry.files["project.json"] != nil, entry.files["preview.png"] != nil, entry.files["record.json"] == nil else {
            throw PropertyError.invalid("内置壁纸目录无效。")
        }
        var identity = entry.id + "\n" + entry.title + "\n" + entry.type + "\n"
        for (name, digest) in entry.files.sorted(by: { $0.key < $1.key }) {
            _ = try parts(name)
            guard hex(digest) else { throw PropertyError.invalid("内置壁纸校验记录无效。") }
            identity += name + "\0" + digest + "\n"
        }
        guard hash(Data(identity.utf8)) == entry.revision else { throw PropertyError.invalid("内置壁纸版本校验失败。") }
    }
    private static func file(_ root: WebSourceFD, _ path: String) throws -> WebSourceFD {
        let names = try parts(path)
        var parent = root
        for name in names.dropLast() { parent = try parent.child(name, directory: true) }
        return try parent.child(names.last!, directory: false)
    }
    private static func contents(_ directory: WebSourceFD, entry: Entry) throws -> [String: Data] {
        var total = 0, data: [String: Data] = [:]
        for (name, digest) in entry.files.sorted(by: { $0.key < $1.key }) {
            let bytes = try file(directory, name).readSmall(maximum: min(maximumFileBytes, maximumEntryBytes-total))
            total += bytes.count
            guard hash(bytes) == digest else { throw PropertyError.invalid("内置壁纸素材已更改或损坏：\(name)。") }
            data[name] = bytes
        }
        guard let bytes = data["project.json"], bytes.count <= 256 * 1024,
              let project = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              project["title"] as? String == entry.title, project["type"] as? String == entry.type,
              project["preview"] as? String == "preview.png",
              let resource = project["file"] as? String, data[resource] != nil else {
            throw PropertyError.invalid("内置壁纸项目与素材目录不一致。")
        }
        return data
    }
    private static func directory(_ parent: WebSourceFD, _ name: String, create: Bool) throws -> WebSourceFD {
        if create, mkdirat(parent.raw, name, 0o700) != 0, errno != EEXIST { throw WebSourceFD.failure("无法创建内置壁纸目录") }
        let result = try parent.child(name, directory: true), info = try result.info()
        guard info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else { throw PropertyError.invalid("内置壁纸目录不能允许其他用户写入。") }
        return result
    }
    private static func openRoot(create: Bool) throws -> WebSourceFD {
        let support = root.deletingLastPathComponent().deletingLastPathComponent()
        // Application Support can be absent in a fresh user profile.
        if create { try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let base = try WebSourceFD.openAbsolute(support, directory: true)
        let app = try directory(base, "WallpaperEngineNative", create: create)
        return try directory(app, "BundledWallpapers", create: create)
    }
    private static func write(_ data: Data, name: String, to directory: WebSourceFD) throws {
        let fd = openat(directory.raw, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw WebSourceFD.failure("无法写入内置壁纸") }
        defer { Darwin.close(fd) }
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count-offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw WebSourceFD.failure("内置壁纸写入失败") }
            offset += count
        }
        guard fsync(fd) == 0 else { throw WebSourceFD.failure("无法完成内置壁纸写入") }
    }
    private static func readEntry(_ directory: WebSourceFD) throws -> Entry {
        let bytes = try directory.child("record.json", directory: false).readSmall(maximum: 256 * 1024)
        let value = try JSONDecoder().decode(Entry.self, from: bytes)
        try validate(value)
        return value
    }
    private static func install(_ entry: Entry, source: WebSourceFD, base: WebSourceFD) throws -> Record {
        let owner = try directory(base, entry.id, create: true)
        let location = root.appendingPathComponent(entry.id).appendingPathComponent(entry.revision)
        func existing() throws -> Record {
            let version = try directory(owner, entry.revision, create: false)
            guard try readEntry(version) == entry else { throw PropertyError.invalid("内置壁纸版本记录不一致，已保留原文件。") }
            _ = try contents(version, entry: entry)
            return Record(entry: entry, project: location.appendingPathComponent("project.json"))
        }
        var info = stat()
        if fstatat(owner.raw, entry.revision, &info, AT_SYMLINK_NOFOLLOW) == 0 { return try existing() }
        guard errno == ENOENT else { throw WebSourceFD.failure("无法确认内置壁纸版本") }
        let sourceFolder = try source.child(entry.id, directory: true)
        let data = try contents(sourceFolder, entry: entry)
        let temporary = ".pending-" + UUID().uuidString
        guard mkdirat(owner.raw, temporary, 0o700) == 0 else { throw WebSourceFD.failure("无法准备内置壁纸版本") }
        let pending = root.appendingPathComponent(entry.id).appendingPathComponent(temporary)
        defer { if FileManager.default.fileExists(atPath: pending.path) { try? FileManager.default.removeItem(at: pending) } }
        let output = try owner.child(temporary, directory: true)
        for (path, bytes) in data.sorted(by: { $0.key < $1.key }) {
            let names = try parts(path)
            var target = output
            for name in names.dropLast() { target = try directory(target, name, create: true) }
            try write(bytes, name: names.last!, to: target)
        }
        try write(JSONEncoder().encode(entry), name: "record.json", to: output)
        guard fsync(output.raw) == 0 else { throw WebSourceFD.failure("无法完成内置壁纸版本") }
        if renameat(owner.raw, temporary, owner.raw, entry.revision) != 0 {
            guard errno == EEXIST || errno == ENOTEMPTY else { throw WebSourceFD.failure("无法提交内置壁纸版本") }
            return try existing()
        }
        guard fsync(owner.raw) == 0 else { throw WebSourceFD.failure("无法保存内置壁纸目录") }
        return Record(entry: entry, project: location.appendingPathComponent("project.json"))
    }

    static func records(resources: URL? = Bundle.main.resourceURL?.appendingPathComponent("StarterWallpapers")) -> (items: [Record], warnings: [String]) {
        guard let resources, FileManager.default.fileExists(atPath: resources.path) else { return ([], []) }
        lock.lock(); defer { lock.unlock() }
        do {
            let source = try WebSourceFD.openAbsolute(resources.resolvingSymlinksInPath(), directory: true)
            let data = try source.child("catalog.json", directory: false).readSmall(maximum: 512 * 1024)
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            guard catalog.version == 1, (1...24).contains(catalog.wallpapers.count),
                  Set(catalog.wallpapers.map(\.id)).count == catalog.wallpapers.count else { throw PropertyError.invalid("内置壁纸目录版本无效。") }
            for entry in catalog.wallpapers { try validate(entry) }
            let base = try openRoot(create: true)
            var items: [Record] = [], warnings: [String] = []
            for entry in catalog.wallpapers {
                do { items.append(try install(entry, source: source, base: base)) }
                catch { warnings.append("内置壁纸“\(entry.title)”不可用：\(error.localizedDescription)") }
            }
            return (items, warnings)
        } catch { return ([], ["无法读取内置壁纸：\(error.localizedDescription)"]) }
    }

    static func record(for project: URL) -> Record? {
        let path = project.standardizedFileURL.path, prefix = root.path + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let names = String(path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        guard names.count == 3, names[2] == "project.json",
              let base = try? openRoot(create: false), let owner = try? directory(base, names[0], create: false),
              let version = try? directory(owner, names[1], create: false), let entry = try? readEntry(version),
              entry.id == names[0], entry.revision == names[1],
              (try? version.child("project.json", directory: false)) != nil else { return nil }
        return Record(entry: entry, project: project.standardizedFileURL)
    }
}
