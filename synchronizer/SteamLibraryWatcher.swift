import CoreServices
import Foundation

/// A bounded filesystem observation.  It is deliberately only a prompt to
/// query Steam again: neither an item ID nor a full hint proves that an item
/// finished installing or that its local manifest is current.
struct SteamLibraryChangeHint: Sendable {
    private(set) var itemIDs: Set<String> = []
    private(set) var fullReconcile = false

    init(itemIDs: Set<String> = [], fullReconcile: Bool = false) {
        merge(itemIDs: itemIDs, fullReconcile: fullReconcile)
    }

    mutating func merge(itemIDs next: Set<String>, fullReconcile all: Bool) {
        guard !fullReconcile else { return }
        if all { fullReconcile = true; itemIDs.removeAll(); return }
        itemIDs.formUnion(next)
        // An FSEvents storm must remain a bounded invalidation hint.  Falling
        // back to a full scan is safe because later Steam receipt checks still
        // decide what may publish.
        if itemIDs.count > 2_000 { fullReconcile = true; itemIDs.removeAll() }
    }
}

/// Watches registered library folders for local Steam download/install changes.
/// This observes filesystem changes, not account subscriptions or remote pushes.
final class SteamLibraryWatcher {
    private let onChange: @MainActor (SteamLibraryChangeHint) -> Void
    private let queue = DispatchQueue(label: "io.wallpaper-engine-native.library-events")
    private var stream: FSEventStreamRef?
    private var watched: [String] = []
    private var relevantRoots: [String] = []
    private var debounce: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var pendingHint: SteamLibraryChangeHint?
    private var firstPendingHintAt: TimeInterval?
    private var debounceGeneration: UInt64 = 0
    private var batchGeneration: UInt64 = 0
    private var activeBatchGeneration: UInt64?
    private var stopped = false

    init(onChange: @escaping @MainActor (SteamLibraryChangeHint) -> Void) { self.onChange = onChange }

    @MainActor func start() {
        // A previously cancelled timer can still reach GCD after this watcher
        // is restarted. Make every prior generation stale before accepting new
        // filesystem work.
        debounceGeneration &+= 1
        stopped = false
        refreshLocations()
    }

    @MainActor func refreshLocations() {
        guard !stopped else { return }
        let discovered = SteamLibraryIndex.locations().libraries
        relevantRoots = discovered.map { $0.workshop.path }
        var paths = Set<String>()
        for desired in discovered.map(\.steamApps) + [SteamLibraryIndex.configurationURL.deletingLastPathComponent()] {
            // Watch an existing ancestor so an unmounted/new library can appear.
            // Never watch filesystem root; the periodic discovery is the fallback.
            var parent = desired
            while parent.path != "/", !FileManager.default.fileExists(atPath: parent.path) { parent.deleteLastPathComponent() }
            if parent.path != "/" { paths.insert(parent.path) }
        }
        let next = paths.sorted()
        guard stream == nil || next != watched else { return }
        stopStream()
        watched = next
        guard !next.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<SteamLibraryWatcher>.fromOpaque(pointer).retain()
                return pointer
            }, release: { pointer in
                guard let pointer else { return }
                Unmanaged<SteamLibraryWatcher>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf)
        guard let created = FSEventStreamCreate(kCFAllocatorDefault, { _, info, count, rawPaths, flags, _ in
            guard let info, count > 0 else { return }
            let watcher = Unmanaged<SteamLibraryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let mustRescan = (0..<count).contains { index in
                let loss = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged |
                    kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)
                return flags[index] & loss != 0
            }
            DispatchQueue.main.async { [weak watcher] in watcher?.receive(paths, mustRescan: mustRescan) }
        }, &context, next as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else {
            fputs("Steam library watcher could not create an event stream; periodic discovery remains available.\n", stderr)
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        if !FSEventStreamStart(created) {
            stopStream()
            fputs("Steam library watcher failed to start; periodic discovery remains available.\n", stderr)
        } else { fputs("Steam library watcher active: \(next.count) filesystem roots\n", stderr) }
    }

    @MainActor private func receive(_ paths: [String], mustRescan: Bool) {
        guard !stopped else { return }
        let config = SteamLibraryIndex.configurationURL.path
        guard mustRescan || paths.contains(where: { isRelevant($0, configuration: config) }) else { return }
        let hint = changeHint(paths, mustRescan: mustRescan, configuration: config)
        let plan = enqueue(hint, now: ProcessInfo.processInfo.systemUptime)
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushPending(generation: plan.generation, batch: plan.batch) }
        }
        debounce = task
        // A trailing debounce absorbs normal multi-file Steam writes. The
        // five-second cap prevents a continuous write storm from postponing an
        // update hint indefinitely; the coordinator provides a second bounded
        // five-second reconciliation debounce.
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.delay, execute: task)
    }

    /// The plan is separate from GCD execution so every pending batch has one
    /// monotonic identity.  This makes stale timer execution harmless and keeps
    /// the maximum wait bounded from the first filesystem observation.
    @MainActor private func enqueue(_ hint: SteamLibraryChangeHint, now: TimeInterval) -> (generation: UInt64, batch: UInt64, delay: TimeInterval) {
        var batch = activeBatchGeneration ?? 0
        if var pendingHint { pendingHint.merge(itemIDs: hint.itemIDs, fullReconcile: hint.fullReconcile); self.pendingHint = pendingHint }
        else {
            self.pendingHint = hint; firstPendingHintAt = now
            batchGeneration &+= 1; batch = batchGeneration; activeBatchGeneration = batch
            let task = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.flushDeadline(batch: batch) }
            }
            deadline = task
            // This deadline is intentionally never cancelled by later writes.
            // It is the hard upper bound for one burst; only an earlier flush,
            // stop or restart can invalidate it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
        }
        batch = activeBatchGeneration ?? batchGeneration
        debounce?.cancel()
        debounceGeneration &+= 1
        let generation = debounceGeneration
        let first = firstPendingHintAt ?? now
        let delay = min(0.75, max(0, 5 - (now - first)))
        return (generation, batch, delay)
    }

    @MainActor private func flushPending(generation: UInt64, batch: UInt64) {
        // DispatchWorkItem.cancel() is advisory: an item that has already
        // reached GCD may still run. Only the latest receive may consume the
        // shared pending hint.
        guard !stopped, debounceGeneration == generation, activeBatchGeneration == batch else { return }
        flush(batch: batch)
    }

    @MainActor private func flushDeadline(batch: UInt64) {
        guard !stopped, activeBatchGeneration == batch else { return }
        // A current trailing work item can still run after cancellation, so
        // retire its generation before consuming the shared batch.
        debounce?.cancel(); debounce = nil; debounceGeneration &+= 1
        flush(batch: batch)
    }

    @MainActor private func flush(batch: UInt64) {
        guard activeBatchGeneration == batch else { return }
        let pending = pendingHint ?? SteamLibraryChangeHint(fullReconcile: true)
        debounce?.cancel(); debounce = nil
        deadline?.cancel(); deadline = nil
        pendingHint = nil; firstPendingHintAt = nil; activeBatchGeneration = nil
        refreshLocations()
        fputs("Steam library filesystem change: rediscovering local projects\n", stderr)
        onChange(pending)
    }

    /// Extract an ID only from the exact registered Workshop content shape.
    /// ACF/configuration changes, an ancestor/root notification and any path
    /// that does not expose a single valid ID become a bounded full hint.  This
    /// fail-closed behavior avoids treating an ambiguous FSEvent as evidence
    /// that an arbitrary item was safely installed.
    private func changeHint(_ paths: [String], mustRescan: Bool, configuration: String) -> SteamLibraryChangeHint {
        if mustRescan { return SteamLibraryChangeHint(fullReconcile: true) }
        var ids = Set<String>(), full = mustRescan
        for path in paths {
            // An FSEvents batch can include unrelated app/game writes.  Only
            // paths that pass the same relevance gate as `receive` may affect
            // this Wallpaper Engine hint.
            guard isRelevant(path, configuration: configuration) else { continue }
            if path == configuration { full = true; continue }
            var recognized = false
            for root in relevantRoots {
                let content = root + "/content/431960"
                let manifest = root + "/appworkshop_431960.acf"
                if path == manifest || path == root || root.hasPrefix(path + "/") ||
                    path == content || content.hasPrefix(path + "/") {
                    full = true; recognized = true; break
                }
                let prefix = content + "/"
                guard path.hasPrefix(prefix) else { continue }
                recognized = true
                let remainder = String(path.dropFirst(prefix.count))
                guard let id = remainder.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init),
                      SteamLibraryIndex.validID(id), UInt64(id).map({ $0 > 0 }) == true else {
                    full = true; break
                }
                ids.insert(id)
            }
            // The outer relevance filter has already ruled out unrelated paths.
            // If a registered root was observed but no exact item can be named,
            // safely rescan saved records rather than silently dropping it.
            if !recognized { full = true }
        }
        return SteamLibraryChangeHint(itemIDs: ids, fullReconcile: full)
    }

    private func isRelevant(_ path: String, configuration: String) -> Bool {
        if path == configuration { return true }
        return relevantRoots.contains { root in
            let appContent = root + "/content/431960"
            let appManifest = root + "/appworkshop_431960.acf"
            // Retain the root/ancestor cases because FSEvents can coalesce a
            // change upward, but never treat another Steam app's Workshop
            // subtree or ACF as Wallpaper Engine content.
            return path == root || root.hasPrefix(path + "/") || path == appManifest ||
                path == appContent || path.hasPrefix(appContent + "/") || appContent.hasPrefix(path + "/")
        }
    }

    @MainActor func stop() {
        stopped = true
        debounceGeneration &+= 1
        batchGeneration &+= 1; activeBatchGeneration = nil
        debounce?.cancel(); debounce = nil; deadline?.cancel(); deadline = nil
        pendingHint = nil; firstPendingHintAt = nil
        stopStream()
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
