import Foundation

enum SteamLibraryError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let text) = self { return text }; return "Steam library error" }
}

// Bounded Valve KeyValues parser used only for library locations and Workshop manifests.
struct KeyValues {
    private static let maximumNestingDepth = 64
    var tokens: [String]
    var index = 0

    init(_ text: String) throws {
        let chars = Array(text)
        var i = 0, result: [String] = []
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }; continue
            }
            if c == "{" || c == "}" { result.append(String(c)); i += 1; continue }
            if c == "\"" {
                i += 1
                var value = "", closed = false
                while i < chars.count {
                    if chars[i] == "\"" { closed = true; i += 1; break }
                    if chars[i] == "\\", i + 1 < chars.count {
                        i += 1
                        switch chars[i] { case "n": value.append("\n"); case "t": value.append("\t"); default: value.append(chars[i]) }
                    } else { value.append(chars[i]) }
                    i += 1
                }
                guard closed else { throw SteamLibraryError.message("Incomplete Steam manifest string") }
                result.append(value)
            } else {
                var value = ""
                while i < chars.count, !chars[i].isWhitespace, chars[i] != "{", chars[i] != "}" {
                    value.append(chars[i]); i += 1
                }
                result.append(value)
            }
        }
        tokens = result
    }

    mutating func object(nested: Bool = false, depth: Int = 0) throws -> [String: Any] {
        guard depth <= Self.maximumNestingDepth else {
            throw SteamLibraryError.message("Steam manifest exceeds the KeyValues nesting limit")
        }
        var result: [String: Any] = [:]
        while index < tokens.count {
            let key = tokens[index]; index += 1
            if key == "}" {
                guard nested else { throw SteamLibraryError.message("Unexpected manifest delimiter") }
                return result
            }
            guard key != "{", index < tokens.count else { throw SteamLibraryError.message("Incomplete Steam manifest") }
            let value = tokens[index]; index += 1
            if value == "{" { result[key] = try object(nested: true, depth: depth + 1) }
            else if value == "}" { throw SteamLibraryError.message("Missing Steam manifest value") }
            else { result[key] = value }
        }
        guard !nested else { throw SteamLibraryError.message("Incomplete Steam manifest object") }
        return result
    }
}

struct SteamLibraryLocation {
    let root: URL
    var steamApps: URL { root.appendingPathComponent("steamapps", isDirectory: true) }
    var workshop: URL { steamApps.appendingPathComponent("workshop", isDirectory: true) }
    var content: URL { workshop.appendingPathComponent("content/431960", isDirectory: true) }
    var manifestURL: URL { workshop.appendingPathComponent("appworkshop_431960.acf") }

    func projectURL(_ id: String) -> URL? {
        guard SteamLibraryIndex.validID(id) else { return nil }
        let directory = content.appendingPathComponent(id, isDirectory: true).standardizedFileURL
        let file = directory.appendingPathComponent("project.json")
        // Steam library roots themselves may be symlinks; item directories and
        // project files must still remain inside that registered content root.
        guard SteamLibraryIndex.contains(directory, in: content), SteamLibraryIndex.contains(file, in: directory) else { return nil }
        return file
    }

    func manifest() throws -> [String: Any] {
        let data = try SteamLibraryIndex.read(manifestURL, limit: 16 * 1024 * 1024)
        guard let text = String(data: data, encoding: .utf8) else { throw SteamLibraryError.message("Steam manifest is not UTF-8") }
        var parser = try KeyValues(text)
        guard let object = try parser.object()["AppWorkshop"] as? [String: Any], object["appid"] as? String == "431960" else {
            throw SteamLibraryError.message("Unexpected Steam Workshop app manifest")
        }
        return object
    }

    func downloadPending(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: workshop.appendingPathComponent("downloads/431960/" + id).path)
    }
}

struct SteamLocalProject {
    let library: SteamLibraryLocation
    let id: String
    let url: URL
    let title: String
    let type: String
    let isInstalling: Bool
}

struct SteamSubscription {
    let id: String
    let title: String
    let enabled: Bool
    let available: Bool
    let needsDownload: Bool
    let state: UInt32
    let publishedTags: [String]?
    let allowMobileUpload: Bool?
    let favorite: Bool?
    let score: Double?
    let subscribedAt: UInt32?
    let updatedAt: UInt32?
    let sizeBytes: UInt64?

    init?(_ object: [String: Any]) {
        guard let id = object["workshop_id"] as? String, SteamLibraryIndex.validID(id),
              let numeric = UInt64(id), numeric > 0,
              let title = object["title"] as? String,
              let enabled = object["enabled"] as? Bool,
              let needsDownload = object["needs_download"] as? Bool,
              let state = object["state"] as? UInt32 else { return nil }
        self.id = id; self.title = String(title.prefix(512)); self.enabled = enabled
        self.available = object["consumer_app_id"] as? UInt32 == 431960 && object["result"] as? Int == 1
        self.needsDownload = needsDownload; self.state = state
        if let tags = object["tags"] as? [String], tags.count <= 64,
           tags.allSatisfy({ !$0.isEmpty && $0.utf8.count < 256 && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) {
            publishedTags = tags
        } else { publishedTags = nil }
        allowMobileUpload = object["allow_mobile_upload"] as? Bool
        favorite = object["favorite"] as? Bool
        let score = object["score"] as? Double
        self.score = score.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        subscribedAt = object["time_subscribed"] as? UInt32
        updatedAt = object["time_updated"] as? UInt32
        let size = object["size_bytes"] as? UInt64
        sizeBytes = size.flatMap { $0 > 0 && $0 <= 16 * 1024 * 1024 * 1024 * 1024 ? $0 : nil }
    }
}

enum SteamLibraryIndex {
    static var steamRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }
    static var configurationURL: URL { steamRoot.appendingPathComponent("steamapps/libraryfolders.vdf") }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 20 && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func contains(_ candidate: URL, in root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        guard limit > 0, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw SteamLibraryError.message("\(url.lastPathComponent) is not a regular readable file")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw SteamLibraryError.message("\(url.lastPathComponent) exceeds the \(limit)-byte limit") }
        return data
    }

    static func locations() -> (libraries: [SteamLibraryLocation], warnings: [String]) {
        var roots = [steamRoot], warnings: [String] = []
        if FileManager.default.fileExists(atPath: configurationURL.path) {
            do {
                let data = try read(configurationURL, limit: 4 * 1024 * 1024)
                guard let text = String(data: data, encoding: .utf8) else { throw SteamLibraryError.message("libraryfolders.vdf is not UTF-8") }
                var parser = try KeyValues(text)
                let top = try parser.object()
                guard let entries = (top["libraryfolders"] ?? top["LibraryFolders"]) as? [String: Any] else {
                    throw SteamLibraryError.message("libraryfolders.vdf has no libraryfolders object")
                }
                let keys = entries.keys.filter { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                if keys.count > 128 { warnings.append("Steam 库超过 128 个，本次仅发现前 128 个库。") }
                for key in keys.prefix(128) {
                    // Modern files use an object with path; older files use a string.
                    guard let path = (entries[key] as? [String: Any])?["path"] as? String ?? entries[key] as? String,
                          path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096 else {
                        warnings.append("Steam 库 \(key) 的路径无效，未读取。")
                        continue
                    }
                    roots.append(URL(fileURLWithPath: path, isDirectory: true))
                }
            } catch { warnings.append("Steam 库配置尚未确认：\(error)") }
        }
        var seen = Set<String>()
        let libraries = roots.compactMap { root -> SteamLibraryLocation? in
            let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(canonical.path).inserted else { return nil }
            return SteamLibraryLocation(root: canonical)
        }
        return (libraries, warnings)
    }

    static func location(for project: URL, id: String? = nil) -> SteamLibraryLocation? {
        let value = id ?? project.deletingLastPathComponent().lastPathComponent
        guard validID(value), project.lastPathComponent == "project.json" else { return nil }
        let canonical = project.standardizedFileURL.resolvingSymlinksInPath()
        return locations().libraries.first {
            $0.projectURL(value)?.standardizedFileURL.resolvingSymlinksInPath() == canonical
        }
    }

    static func projects(maximum: Int = 10_000) -> (projects: [SteamLocalProject], libraries: [SteamLibraryLocation], warnings: [String], truncated: Int) {
        let discovered = locations()
        var warnings = discovered.warnings, result: [SteamLocalProject] = [], truncated = 0
        var seen = Set<String>()
        for library in discovered.libraries {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: library.root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                warnings.append("Steam 库暂不可用：\(library.root.path)")
                continue
            }
            guard FileManager.default.fileExists(atPath: library.content.path) else { continue }
            do {
                let folders = try FileManager.default.contentsOfDirectory(at: library.content, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for folder in folders where validID(folder.lastPathComponent) {
                    guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          let url = library.projectURL(folder.lastPathComponent), FileManager.default.fileExists(atPath: url.path) else { continue }
                    let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
                    guard seen.insert(canonical).inserted else { continue }
                    if result.count >= maximum { truncated += 1; continue }
                    do {
                        let data = try read(url, limit: 4 * 1024 * 1024)
                        guard let project = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = project["type"] as? String, type.utf8.count <= 128 else {
                            throw SteamLibraryError.message("project.json has no type")
                        }
                        result.append(SteamLocalProject(library: library, id: folder.lastPathComponent, url: url,
                            title: String((project["title"] as? String ?? folder.lastPathComponent).prefix(512)), type: type,
                            isInstalling: library.downloadPending(folder.lastPathComponent)))
                    } catch { warnings.append("项目 \(folder.lastPathComponent) 暂不可读：\(error)") }
                }
            } catch { warnings.append("Steam 库暂不可读：\(library.root.path)（\(error)）") }
        }
        if truncated > 0 { warnings.append("本次最多读取 \(maximum) 个项目，另有 \(truncated) 个尚未列出。") }
        return (result, discovered.libraries, warnings, truncated)
    }
}

