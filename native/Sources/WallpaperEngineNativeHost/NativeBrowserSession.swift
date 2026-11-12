import Foundation

/// The official browser's cancel restores engine configuration. Browser layout,
/// library folders, subscriptions, imported files and granted OS permissions
/// are not part of this transaction.
@MainActor
final class NativeBrowserSession {
    private static let keys = ["lastProject", "wallpaperManualPlaybackState", "pauseWallpaperWhenCovered",
                               "pauseWallpaperInLowPowerMode", "wallpaperLoadingTimeoutSeconds",
                               NativeGeneralPlayback.key, NativeGraphicsSettings.key,
                               NativeProfileStore.currentNameKey]
    private let preferences: [String: Any]
    let displays = NativeDisplayStore.snapshot()
    private let playlists = NativePlaylistStore.snapshot()
    private let playlistProgress = NativePlaylistProgressStore.snapshot()
    /// Track every volatile screen present at Browser entry, not just the
    /// subset which happened to have a custom assignment.  A default-following
    /// screen can still have a display-content context/property edit that must
    /// not cross a later ID reuse boundary.
    private let initialSessionTargets: Set<String>
    private(set) var properties: [String: WallpaperPropertyStore.Snapshot] = [:]
    private var media: [String: WallpaperMediaGrants.Retention] = [:]
    /// A CoreGraphics `session:` key is only unique for a connected display
    /// generation.  Once it disappears while this Browser transaction is
    /// open, it remains invalid for this snapshot even if macOS subsequently
    /// assigns the same numerical ID to another monitor.
    private var invalidatedSessionTargets = Set<String>()
    /// Advances only when a Browser snapshot loses a volatile display
    /// generation.  A Cancel may spend time preparing a replacement
    /// controller, so the final hand-off needs a token in addition to the
    /// filtered accessors below: it must not commit values that were read
    /// before a disconnect notification and became stale while it awaited.
    private(set) var restorationGeneration: UInt64 = 0

    init() {
        initialSessionTargets = Set(NativeDisplayDescriptor.connected().map(\.key).filter { $0.hasPrefix("session:") })
        preferences = Dictionary(uniqueKeysWithValues: Self.keys.compactMap { key in
            UserDefaults.standard.object(forKey: key).map { (key, $0) }
        })
    }
    func capture(_ project: WallpaperProject) throws {
        let scope = project.propertyScope
        let identity = scope.identity
        guard properties[identity] == nil else { return }
        let snapshot = try WallpaperPropertyStore.Snapshot(project: project.projectURL, scope: scope)
        let tokens = Set(project.propertyDefinitions.filter(\.isMedia).compactMap {
            (project.userProperties[$0.key] as? [String: Any])?["value"] as? String
        }.filter(WallpaperMediaGrants.isToken))
        media[identity] = WallpaperMediaGrants.Retention(project: project.projectURL, tokens: tokens)
        properties[identity] = snapshot
    }

    /// Called for every topology notification before a browser cancellation
    /// can restore its snapshot. `connectedSessionKeys` must describe the
    /// topology observed by that notification (UUID/default keys are ignored).
    /// This is deliberately monotonic for the lifetime of one browser session:
    /// connection after a loss starts a new generation, never revives the old
    /// snapshot.
    func invalidateDisconnectedSessions(connectedSessionKeys: Set<String>) {
        let connected = Set(connectedSessionKeys.filter { $0.hasPrefix("session:") })
        let newlyInvalidated = snapshotSessionTargets
            .subtracting(connected)
            .subtracting(invalidatedSessionTargets)
        guard !newlyInvalidated.isEmpty else { return }
        invalidatedSessionTargets.formUnion(newlyInvalidated)
        restorationGeneration &+= 1
    }

    /// True only if no captured volatile target has disappeared since the
    /// caller assembled a Browser Cancel candidate.  The caller must check
    /// this at its final presentation boundary, after every `await` used to
    /// prepare that candidate.
    func isRestorationCurrent(_ generation: UInt64) -> Bool {
        generation == restorationGeneration
    }

    private var snapshotSessionTargets: Set<String> {
        var targets = initialSessionTargets
        targets.formUnion(NativeDisplayStore.sessionTargetKeys(in: displays))
        targets.formUnion(NativePlaylistStore.sessionTargetKeys(in: playlists))
        targets.formUnion(NativePlaylistProgressStore.sessionTargetKeys(in: playlistProgress))
        targets.formUnion(properties.values.compactMap { snapshot in
            snapshot.scope.storage == .sessionDisplay ? snapshot.scope.targetKey : nil
        })
        return targets
    }

    /// The layout used while preparing Browser Cancel's replacement
    /// controller.  Filtering here is as important as filtering the final
    /// store restore: otherwise a candidate can briefly prepare an old
    /// assignment for an unrelated monitor before the commit hook runs.
    var restorableDisplayLayout: NativeDisplayLayout {
        displays.layout.droppingDisconnectedSessionTargets(connectedSessionKeys: snapshotSessionTargets.subtracting(invalidatedSessionTargets))
    }

    /// Apply the same volatile-target eligibility rule to a layout owned by a
    /// profile or another Browser transaction carrier.  Such a layout can
    /// contain a `session:` assignment even when it was not the snapshot's
    /// primary display store, so callers must not bypass the Browser
    /// generation boundary by choosing it as the base layout for Cancel.
    func restorableDisplayLayout(_ layout: NativeDisplayLayout) -> NativeDisplayLayout {
        layout.droppingDisconnectedSessionTargets(
            connectedSessionKeys: snapshotSessionTargets.subtracting(invalidatedSessionTargets)
        )
    }

    /// Property bytes must be supplied to the rollback candidate through the
    /// same generation gate as the final property-store restore.
    var restorableProperties: [String: WallpaperPropertyStore.Snapshot] {
        properties.filter {
            !($0.value.scope.storage == .sessionDisplay && invalidatedSessionTargets.contains($0.value.scope.targetKey))
        }
    }

    /// AppDelegate also owns transient display-content contexts.  It uses
    /// this predicate to avoid overlaying an old session playlist/layout onto
    /// a replacement controller after a session ID was recycled.
    func canRestoreSessionTarget(_ key: String) -> Bool {
        !key.hasPrefix("session:") || !invalidatedSessionTargets.contains(key)
    }

    func restore() throws {
        try WallpaperPropertyStore.restore(Array(restorableProperties.values))
        NativeDisplayStore.restore(displays, excludingSessionTargets: invalidatedSessionTargets)
        NativePlaylistStore.restore(playlists, excludingSessionTargets: invalidatedSessionTargets)
        NativePlaylistProgressStore.restore(playlistProgress, excludingSessionTargets: invalidatedSessionTargets)
        for key in Self.keys {
            if let value = preferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    /// Call only once the browser's Accept/Cancel transaction has fully
    /// settled.  Dropping Retention first lets the complete, fail-closed scope
    /// inventory remove media grants introduced by an abandoned edit, while
    /// retaining every token still named by V1/UUID/session settings.
    func finishMediaTransaction() {
        let projects = Set(properties.values.map(\.project))
        media.removeAll()
        for project in projects {
            _ = WallpaperPropertyStore.pruneUnreferencedMediaGrants(project: project)
        }
    }
}
