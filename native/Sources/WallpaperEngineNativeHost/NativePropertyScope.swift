import Foundation

/// The local identity of one author-property set.  A project may legitimately
/// be rendered by more than one desktop window, so the project URL alone is
/// not a sufficient property identity once a user picks an individual screen.
///
/// `defaultWallpaper` deliberately remains the original V1 on-disk record.
/// Stable UUID displays use an independent V2 record.  A `session:` display is
/// valid only while the current process owns the screen; its values must stay
/// in memory and are therefore explicitly represented here rather than being
/// coerced to the default screen.
struct NativePropertyScope: Hashable, Sendable {
    enum Storage: Hashable, Sendable { case legacyDefault, persistentDisplay, sessionDisplay }

    let projectIdentity: String
    let targetKey: String
    let storage: Storage

    init(project: URL, target: NativeDisplayTarget = .defaultWallpaper) throws {
        projectIdentity = SavedWorkshopStore.settingsIdentity(project)
        switch target {
        case .defaultWallpaper:
            targetKey = target.key; storage = .legacyDefault
        case .display(let key):
            guard NativeDisplayLayout.validKey(key) else {
                throw PropertyError.invalid("显示器属性目标无效。")
            }
            targetKey = key
            storage = key.hasPrefix("uuid:") ? .persistentDisplay : .sessionDisplay
        }
    }

    var identity: String { projectIdentity + "\u{0}" + targetKey }
    /// Keep the established project-only clock for V1 records, so callers of
    /// the compatibility API retain their existing invalidation semantics.
    var revisionIdentity: String { usesLegacyRecord ? projectIdentity : identity }
    var usesLegacyRecord: Bool { storage == .legacyDefault }
    var persistent: Bool { storage != .sessionDisplay }
}
