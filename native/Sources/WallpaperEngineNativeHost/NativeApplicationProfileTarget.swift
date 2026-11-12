import Foundation

/// Application rules retain the exact user-visible saved-profile name. The
/// profile itself is deliberately resolved again at activation time: overwrite
/// must update an active rule, while a deletion or malformed catalog must leave
/// the already published desktop alone.
@MainActor
enum NativeApplicationProfileTarget {
    static func validatedName(_ name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 1_024, !name.contains("\0") else {
            throw NativeApplicationRuleError.invalidTarget
        }
        return name
    }

    static func choices(from profiles: [NativeWallpaperProfile]) throws -> [NativeApplicationRuleEditor.Item] {
        guard profiles.count <= 1_000, Set(profiles.map(\.name)).count == profiles.count else {
            throw NativePlaylistError.invalid("保存的配置文件目录无效。")
        }
        return try profiles.map { profile in
            _ = try profile.validated()
            let name = try validatedName(profile.name)
            return .init(label: name, file: name)
        }
    }

    static func resolve(_ name: String, from profiles: [NativeWallpaperProfile]) throws -> NativeWallpaperProfile {
        _ = try validatedName(name)
        _ = try choices(from: profiles)
        guard let profile = profiles.first(where: { $0.name == name }) else {
            throw NativePlaylistError.invalid("找不到已保存的配置文件“\(name)”，请重新选择规则目标。")
        }
        return try profile.validated()
    }

    static func resolve(_ name: String) throws -> NativeWallpaperProfile {
        try resolve(name, from: NativeProfileStore.saved().profiles)
    }
}
