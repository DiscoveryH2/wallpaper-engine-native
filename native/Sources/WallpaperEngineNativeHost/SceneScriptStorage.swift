import Foundation
import CryptoKit

/// Wallpaper scripts only exchange bounded JSON. The host chooses a fixed file
/// keyed by the project path; script keys can never become filesystem paths.
final class SceneScriptStorage {
    private let url: URL
    private var saved: Data?
    let initial: [String: Any]

    init(project: URL) throws {
        let identity = SavedWorkshopStore.settingsIdentity(project)
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        url = parent.appendingPathComponent("WallpaperEngineNative/SceneScript", isDirectory: true).appendingPathComponent(digest + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 100 * 1024 else {
                throw SceneError.invalid("SceneScript 本地存储超过 100 KiB。")
            }
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SceneError.invalid("SceneScript 本地存储格式无效。") }
            initial = root
            saved = try Self.validated(root)
        } else { initial = ["global": [:], "screens": [:]] }
    }

    func save(_ root: [String: Any]) throws {
        let data = try Self.validated(root)
        guard data != saved else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        saved = data
        fputs("SceneScript local storage saved: \(data.count) bytes\n", stderr)
    }

    private static func validated(_ root: [String: Any]) throws -> Data {
        guard Set(root.keys) == Set(["global", "screens"]), root["global"] is [String: Any],
              let screens = root["screens"] as? [String: [String: Any]], screens.count <= 64,
              JSONSerialization.isValidJSONObject(root) else { throw SceneError.invalid("SceneScript 本地存储结构无效。") }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        guard data.count <= 100 * 1024 else { throw SceneError.invalid("SceneScript 本地存储超过 100 KiB。") }
        return data
    }
}
