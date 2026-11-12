import Foundation

/// The official rule stores the exact saved playlist name. Resolve that name
/// again when loading, so overwriting a named list does not pin an old UUID or
/// copy. This reference never represents a file path or a process to launch.
enum NativeApplicationPlaylistTarget {
    static func validatedName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 1024, !name.contains("\0") else {
            throw NativePlaylistError.invalid("应用程序规则的播放列表名称无效。")
        }
        return name
    }

    static func choices(from lists: [NativePlaylist]) throws -> [NativeApplicationRuleEditor.Item] {
        guard lists.count <= 1000, Set(lists.map(\.name)).count == lists.count else {
            throw NativePlaylistError.invalid("保存的播放列表目录无效。")
        }
        return try lists.map { list in
            _ = try list.validated()
            let name = try validatedName(list.name)
            return .init(label: name, file: name)
        }
    }

    static func resolve(_ name: String, from lists: [NativePlaylist]) throws -> NativePlaylist {
        _ = try validatedName(name)
        _ = try choices(from: lists)
        guard var list = lists.first(where: { $0.name == name }) else {
            throw NativePlaylistError.invalid("找不到已保存的播放列表“\(name)”，请重新选择规则目标。")
        }
        guard !list.entries.isEmpty else {
            throw NativePlaylistError.invalid("播放列表“\(name)”没有可播放的壁纸。")
        }
        list.normalize()
        return list
    }

    @MainActor
    static func resolve(_ name: String) throws -> NativePlaylist {
        try resolve(name, from: NativePlaylistStore.saved().lists)
    }
}
