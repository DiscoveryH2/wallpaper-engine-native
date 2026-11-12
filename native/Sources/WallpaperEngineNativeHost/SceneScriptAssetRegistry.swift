import Foundation

/// Only this serial queue accesses the lazily opened index. A renderer may
/// supply its immutable SceneAssets snapshot to avoid rereading an archive.
private final class SceneScriptAssetReader: @unchecked Sendable {
    let queue: DispatchQueue
    private let directory: URL
    private let builtinFonts: NativeBuiltinFonts.Snapshot?
    private var assets: SceneAssets?

    init(directory: URL, assets: SceneAssets?, builtinFonts: NativeBuiltinFonts.Snapshot?, queue: DispatchQueue) {
        self.directory = directory; self.assets = assets; self.builtinFonts = builtinFonts; self.queue = queue
    }

    func check(_ path: String) async throws {
        try await NativeResourceWork.run(on: queue) { cancellation in
            let source: SceneAssets
            if let assets = self.assets { source = assets }
            else {
                source = try SceneAssets(directory: self.directory)
                try cancellation.check(); self.assets = source
            }
            try cancellation.check()
            if source.contains(path) {
                // Checks disappearance, size changes and symlinks after indexing;
                // it does not prove a same-size file's contents are unchanged.
                _ = try source.prefix(path, count: 1)
            } else if let fonts = self.builtinFonts, fonts.contains(path) {
                // Imported data is read through the scene's immutable snapshot.
                // A full bounded read also validates the recorded digest before
                // publishing a script handle; it never installs a system font.
                _ = try fonts.data(path)
            } else { throw SceneError.invalid("注册素材不存在或路径无效：\(path)") }
        }
    }

    func releaseIndex() { queue.async { self.assets = nil } }
}

/// Runtime declarations belong to a project instance. Preparation performs no
/// main-thread I/O and does not publish a registration until commit validates.
@MainActor
final class SceneScriptAssetRegistry {
    struct Registration {
        let path: String
        var option: Bool?
    }
    struct PreparedRegistration: Sendable {
        fileprivate let registry: UUID
        fileprivate let key: String
        let path: String
        fileprivate let option: Bool?
    }
    private let identity = UUID()
    private let reader: SceneScriptAssetReader
    private var closed = false
    private(set) var registrations: [String: Registration] = [:]
    static let maximumRegistrations = 2048

    init(projectURL: URL, assets: SceneAssets? = nil, builtinFonts: NativeBuiltinFonts.Snapshot? = nil,
         queue: DispatchQueue = DispatchQueue(label: "io.wallpaper-engine-native.scene-assets", qos: .userInitiated)) {
        reader = SceneScriptAssetReader(directory: projectURL.deletingLastPathComponent(), assets: assets, builtinFonts: builtinFonts, queue: queue)
    }

    func prepare(_ path: String, option: Bool? = nil) async throws -> PreparedRegistration {
        guard !closed, !path.isEmpty, path.utf8.count <= 4096 else {
            throw SceneError.invalid("素材注册已关闭，或路径为空、超过 4096 字节。")
        }
        let key = path.lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard registrations[key] != nil || registrations.count < Self.maximumRegistrations else {
            throw SceneError.invalid("脚本注册素材超过 2048 项。")
        }
        try Task.checkCancellation()
        try await reader.check(path)
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        return PreparedRegistration(registry: identity, key: key, path: path, option: option)
    }

    func commit(_ prepared: PreparedRegistration) throws -> String {
        guard !closed, prepared.registry == identity,
              registrations[prepared.key] != nil || registrations.count < Self.maximumRegistrations else {
            throw SceneError.invalid("素材准备已过期、属于其他实例或超过注册上限。")
        }
        var entry = registrations[prepared.key] ?? Registration(path: prepared.path, option: nil)
        if let option = prepared.option { entry.option = option }
        registrations[prepared.key] = entry
        return prepared.path
    }

    func register(_ path: String, option: Bool? = nil) async throws -> String {
        let prepared = try await prepare(path, option: option)
        try Task.checkCancellation()
        return try commit(prepared)
    }

    func close() {
        closed = true; registrations.removeAll(); reader.releaseIndex()
    }
}
