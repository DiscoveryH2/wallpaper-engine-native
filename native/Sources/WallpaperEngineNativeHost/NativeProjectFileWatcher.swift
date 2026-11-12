import Foundation
import CoreServices

/// A file-open grant can update a folder's extended attributes after playback
/// has started. These attributes are not wallpaper content. Preserve all data,
/// ownership, topology, overflow and unknown events, including coalesced ones.
enum ProjectFileEvent {
    static func requiresReload(_ flags: FSEventStreamEventFlags) -> Bool {
        let kind = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsDir | kFSEventStreamEventFlagItemIsSymlink | kFSEventStreamEventFlagOwnEvent)
        let reason = flags & ~kind
        let metadata = FSEventStreamEventFlags(kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagHistoryDone)
        // Zero/unknown flags are not proof of a metadata-only event.
        return reason == 0 || reason & ~metadata != 0
    }
}

@MainActor
final class ProjectFileWatcher {
    private let directoryURL: URL
    private let onChange: @MainActor (String) -> Void
    private let queue = DispatchQueue(label: "io.wallpaper-engine-native.project-events")
    private var stream: FSEventStreamRef?
    private var isRunning = false
    private(set) var ignoredMetadataEvents = 0
    private var rootMonitor: DispatchSourceFileSystemObject?

    init(directoryURL: URL, onChange: @escaping @MainActor (String) -> Void) {
        self.directoryURL = directoryURL
        self.onChange = onChange
    }

    func start() {
        stop()
        isRunning = true
        ignoredMetadataEvents = 0
        // WatchRoot makes FSEvents open every ancestor. A project-folder grant
        // does not grant its parents; that synchronous open can wait for system
        // consent on the main thread. Watch the selected directory itself for
        // rename/delete/revoke and let FSEvents handle its descendants.
        let descriptor = directoryURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_EVTONLY | O_CLOEXEC) } ?? -1
        }
        if descriptor >= 0 {
            let monitor = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.rename, .delete, .revoke], queue: queue)
            monitor.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, isRunning else { return }
                    onChange("项目目录被移动、删除或访问失效")
                }
            }
            monitor.setCancelHandler { close(descriptor) }
            rootMonitor = monitor; monitor.resume()
        }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<ProjectFileWatcher>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<ProjectFileWatcher>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagIgnoreSelf
        )
        let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, paths, flags, _ in
                guard count > 0, let info else { return }
                let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var namesChanged: [String] = [], ignored = 0
                for index in 0..<count {
                    guard ProjectFileEvent.requiresReload(flags[index]) else { ignored += 1; continue }
                    if namesChanged.count < 3 {
                        namesChanged.append(String(URL(fileURLWithPath: String(cString: names[index])).lastPathComponent.prefix(160))
                            + String(format: " [0x%X]", flags[index]))
                    }
                }
                let reason = namesChanged.joined(separator: "、"), ignoredCount = ignored
                let watcher = Unmanaged<ProjectFileWatcher>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async {
                    guard watcher.isRunning else { return }
                    watcher.ignoredMetadataEvents += ignoredCount
                    if !reason.isEmpty { watcher.onChange(reason) }
                }
            },
            &context,
            [directoryURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            flags
        )
        guard let created else {
            fputs("Could not create project file watcher for \(directoryURL.path)\n", stderr)
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            fputs("Could not start project file watcher for \(directoryURL.path)\n", stderr)
            stop()
            return
        }
    }

    func stop() {
        isRunning = false
        rootMonitor?.cancel(); rootMonitor = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

}

