import AppKit
import simd

/// A value snapshot of geometry from a GPU-completed frame. Input inspection
/// never advances a camera, script, particle system or animation clock.
struct NativeMetalPointerFrame: Sendable {
    struct Region: Sendable {
        let id: String
        let bounds: CGRect
        let transform: simd_float4x4
    }
    let time: Double
    let worldTransform: simd_float4x4
    let regions: [Region]

    func world(_ point: SIMD2<Float>) -> SIMD3<Float>? {
        SceneParticlePointerInput.project(normalized: point, modelViewProjection: worldTransform).position
    }
    func targets(_ point: SIMD2<Float>) -> [String] {
        regions.compactMap { region in
            guard let local = SceneParticlePointerInput.project(normalized: point,
                modelViewProjection: region.transform).position,
                region.bounds.contains(CGPoint(x: Double(local.x), y: Double(local.y))) else { return nil }
            let clip = region.transform * SIMD4(local, 1)
            // The stored matrices retain OpenGL clip coordinates. Metal's
            // vertex conversion maps this same [-w,+w] range to [0,w].
            guard clip.z.isFinite, clip.w.isFinite, clip.w > 0,
                  clip.z >= -clip.w, clip.z <= clip.w else { return nil }
            return region.id
        }
    }
}

/// Native mouse-only adapter. Preview input comes from AppKit events. Desktop
/// input observes Finder's exposed desktop without taking its clicks or keys.
@MainActor
final class NativeMetalPointer {
    private weak var view: NSView?
    private weak var scripts: SceneScriptBridge?
    private var monitor: Any?
    private var active = false
    private var previewPoint: NSPoint?
    private var previewLeft = false
    private var previewRight = false
    private var lastPoint: NSPoint?
    private var hovered: [String] = []
    private var pressed: Set<String> = []
    private var lastWorld = SIMD3<Float>.zero
    private var lastScreen = SIMD2<Double>.zero
    private var exposed = false
    private var cachedWindows: [CGRect]?
    private var windowCheckTime = -Double.infinity
    private var previewCounts = [0, 0, 0]
    private var eventCounts = [String: Int]()
    private var rejectedSamples = 0
    private var discardedSamples = 0
    private var invalidProjectionCount = 0
    private var completedSequence = 0
    private var lastParticleInput = NativeMetalParticlePointerSample.inactive
    private(set) var frame: NativeMetalPointerFrame?

    init(view: NSView, scripts: SceneScriptBridge?) { self.view = view; self.scripts = scripts }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    func completed(_ frame: NativeMetalPointerFrame?, sequence: Int) {
        // GPU completions enqueue main-actor tasks. Do not assume those tasks
        // run in submission order, especially through a resize/property commit.
        guard sequence > completedSequence else { return }
        completedSequence = sequence; self.frame = frame
    }

    func invalidateScene() {
        frame = nil; hovered.removeAll(); pressed.removeAll(); lastPoint = nil
        lastParticleInput = .inactive
        discardedSamples = min(1_000_000_000, discardedSamples + (scripts?.discardPointerSamples() ?? 0))
    }

    func setActive(_ value: Bool) {
        guard let view else { return }
        let next = value && view.window != nil
        if !next {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            if active { discardedSamples = min(1_000_000_000, discardedSamples + (scripts?.discardPointerSamples() ?? 0)) }
            active = false; previewLeft = false; previewRight = false
            pressed.removeAll(); hovered.removeAll(); lastPoint = nil; exposed = false
            return
        }
        active = true
        let mode = NativeDesktopPointerRouting.mode(for: view.window)
        guard NativeDesktopPointerRouting.needsGlobalButtonMonitor(mode: mode,
                                                                    hasScripts: scripts != nil,
                                                                    monitorInstalled: monitor != nil) else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                self.observe(button: event.type == .leftMouseDown, forceExposure: true)
            }
        }
    }

    private struct Sample {
        let point: NSPoint
        let world: SIMD3<Float>
        let screen: [String: Double]
        let enabled: Bool
        let left: Bool, right: Bool
        let targets: [String]
        var input: [String: Any] {
            ["cursorWorldPosition": ["x": Double(world.x), "y": Double(world.y), "z": Double(world.z)],
             "cursorScreenPosition": screen, "cursorLeftDown": left, "cursorRightDown": right]
        }
        var event: [String: Any] {
            ["worldPosition": ["x": Double(world.x), "y": Double(world.y), "z": Double(world.z)], "screenPosition": screen]
        }
    }

    private func desktopExposed(_ window: NSWindow, force: Bool) -> Bool {
        let mouse = NSEvent.mouseLocation
        guard window.frame.contains(mouse),
              let relativeWindow = NativeDesktopPointerRouting.desktopCoverageRelativeWindowNumber(window.windowNumber),
              NativeDesktopPointerRouting.desktopFrontmostMayObserve(
                ignoresMouseEvents: window.ignoresMouseEvents,
                frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                ownBundleIdentifier: Bundle.main.bundleIdentifier) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        // Cache the window list, not the point result. A click always refreshes
        // it; hover polling refreshes at most every 100 ms at a stationary scene.
        if force || now - windowCheckTime >= 0.1 {
            windowCheckTime = now
            if let windows = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], relativeWindow) as? [[String: Any]] {
                cachedWindows = windows.compactMap { info in
                    guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                          (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                          NativeDesktopPointerRouting.listedWindowMayCoverDesktop(
                            listedWindowNumber: (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                            desktopWindowNumber: window.windowNumber),
                          let bounds = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
                    return CGRect(dictionaryRepresentation: bounds as CFDictionary)
                }
            } else { cachedWindows = nil }
        }
        guard let cachedWindows else { return false }
        let point = CGPoint(x: mouse.x, y: (NSScreen.screens.first?.frame.height ?? 0) - mouse.y)
        return !cachedWindows.contains { $0.contains(point) }
    }

    private func sample(button: Bool? = nil, forceExposure: Bool = false) -> Sample? {
        guard let view, let window = view.window, let frame else { return nil }
        let mode = NativeDesktopPointerRouting.mode(for: window)
        let desktop = mode == .desktop
        let physical = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let point = desktop ? physical : (previewPoint ?? physical)
        let normalized = SIMD2(Float((point.x - view.bounds.minX) / max(1, view.bounds.width)),
                               Float((point.y - view.bounds.minY) / max(1, view.bounds.height)))
        guard normalized.x.isFinite, normalized.y.isFinite else { return nil }
        let world = frame.world(normalized)
        if let world { lastWorld = world } else { invalidProjectionCount = min(1_000_000_000, invalidProjectionCount + 1) }
        let backing = view.convertToBacking(point), backingBounds = view.convertToBacking(view.bounds)
        let screen = ["x": Double(backing.x - backingBounds.minX), "y": Double(backingBounds.maxY - backing.y)]
        let isDesktopExposed = desktop ? desktopExposed(window, force: forceExposure) : false
        // A DesktopWindow must not require an NSApplication to sample its
        // exposed desktop region.  A detached/offscreen preview, conversely,
        // fails closed when no AppKit application exists.
        let applicationActive = mode == .preview && (NSApp?.isActive == true)
        let enabled = active && world != nil && view.bounds.contains(point) &&
            NativeDesktopPointerRouting.admitsInput(mode: mode, desktopExposed: isDesktopExposed,
                                                    isKeyWindow: window.isKeyWindow, applicationActive: applicationActive,
                                                    hasPreviewPoint: previewPoint != nil)
        let left = enabled && (button ?? (desktop ? NSEvent.pressedMouseButtons & 1 != 0 : previewLeft))
        let right = enabled && (desktop ? NSEvent.pressedMouseButtons & 2 != 0 : previewRight)
        exposed = enabled; lastScreen = SIMD2(screen["x"]!, screen["y"]!)
        return Sample(point: point, world: lastWorld, screen: screen, enabled: enabled, left: left, right: right,
                      targets: enabled ? frame.targets(normalized) : [])
    }

    @discardableResult
    private func observe(button: Bool? = nil, forceExposure: Bool = false, inputOnly: Bool = false) -> Sample? {
        guard active, let sample = sample(button: button, forceExposure: forceExposure) else { return nil }
        var events: [[String: Any]] = []
        func add(_ name: String, _ targets: [String]) {
            events.append(["name": name, "objectIDs": targets, "event": sample.event])
        }
        let old = Set(hovered), next = Set(sample.targets)
        let leaving = hovered.filter { !next.contains($0) }, entering = sample.targets.filter { !old.contains($0) }
        if !leaving.isEmpty { add("cursorLeave", leaving) }
        if !entering.isEmpty { add("cursorEnter", entering) }
        if sample.enabled, lastPoint != sample.point, !inputOnly { add("cursorMove", sample.targets) }
        hovered = sample.targets; lastPoint = sample.point
        if let down = button {
            if sample.enabled {
                add(down ? "cursorDown" : "cursorUp", sample.targets)
                if down { pressed = next }
                else {
                    let clicks = sample.targets.filter { pressed.contains($0) }
                    if !clicks.isEmpty { add("cursorClick", clicks) }
                    pressed.removeAll()
                }
            } else { pressed.removeAll() }
        }
        if !sample.enabled { pressed.removeAll() }
        // A sample without a solid hit still carries button transitions for
        // scripts polling input in update(). It invokes no layer callback.
        if events.isEmpty, button != nil || inputOnly { add("cursorMove", []) }
        if !events.isEmpty {
            if scripts?.pointerSample(events, input: sample.input) == true {
                for event in events { let name = event["name"] as! String; eventCounts[name] = min(1_000_000_000, (eventCounts[name] ?? 0) + 1) }
            } else { rejectedSamples = min(1_000_000_000, rejectedSamples + 1) }
        }
        return sample
    }

    func input() -> [String: Any] { observe()?.input ?? [:] }

    /// Particle forces need no script bridge and no completed-frame hit regions.
    /// The renderer projects this sample with the camera of the frame it draws.
    func particleInput() -> NativeMetalParticlePointerSample {
        lastParticleInput = currentParticleInput()
        return lastParticleInput
    }

    private func currentParticleInput() -> NativeMetalParticlePointerSample {
        guard active, let view, let window = view.window else {
            return .init(normalized: nil, reason: "paused-or-detached")
        }
        let mode = NativeDesktopPointerRouting.mode(for: window)
        let desktop = mode == .desktop
        let point: NSPoint
        if desktop {
            point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        } else {
            let applicationActive = NSApp?.isActive == true
            guard NativeDesktopPointerRouting.admitsInput(mode: mode, desktopExposed: false,
                                                           isKeyWindow: window.isKeyWindow, applicationActive: applicationActive,
                                                           hasPreviewPoint: previewPoint != nil) else {
                return .init(normalized: nil, reason: window.isKeyWindow && applicationActive ? "preview-pointer-not-tracked" : "preview-window-inactive")
            }
            guard let previewPoint else { return .init(normalized: nil, reason: "preview-pointer-not-tracked") }
            point = previewPoint
        }
        guard view.bounds.width > 0, view.bounds.height > 0, view.bounds.contains(point) else {
            return .init(normalized: nil, reason: "outside-wallpaper")
        }
        if desktop, !desktopExposed(window, force: false) {
            return .init(normalized: nil, reason: "desktop-covered-or-inactive")
        }
        return .init(normalized: SIMD2(Float((point.x - view.bounds.minX) / view.bounds.width),
                                       Float((point.y - view.bounds.minY) / view.bounds.height)), reason: "active")
    }

    func handle(_ event: NSEvent) {
        guard let view, let window = view.window else { return }
        // A normal DesktopWindow is click-through and receives no direct
        // events.  A hidden-icons DesktopWindow receives its own events but is
        // still a desktop presentation, never a preview.
        guard !NativeDesktopPointerRouting.isDesktopPresentation(window) || !window.ignoresMouseEvents else { return }
        previewPoint = view.convert(event.locationInWindow, from: nil)
        guard active else { previewLeft = false; previewRight = false; return }
        switch event.type {
        case .leftMouseDown:
            previewCounts[0] = min(1_000_000_000, previewCounts[0] + 1); previewLeft = true
            observe(button: true)
        case .leftMouseUp:
            previewCounts[1] = min(1_000_000_000, previewCounts[1] + 1); previewLeft = false
            observe(button: false)
        case .leftMouseDragged:
            previewCounts[2] = min(1_000_000_000, previewCounts[2] + 1); previewLeft = true; observe()
        case .rightMouseDown: previewRight = true; observe(inputOnly: true)
        case .rightMouseUp: previewRight = false; observe(inputOnly: true)
        case .rightMouseDragged: previewRight = true; observe()
        case .mouseExited:
            previewPoint = nil; previewLeft = false; previewRight = false; observe(inputOnly: true)
        default: observe()
        }
    }

    var diagnostic: String {
        if scripts == nil {
            return "Metal 粒子指针：输入=\(lastParticleInput.reason)，归一化位置=\(lastParticleInput.normalized.map { String(describing: $0) } ?? "无")；预览 down/up/drag=\(previewCounts)。各粒子的模拟坐标和力场状态见逐层记录；此场景不需要脚本指针命中区。"
        }
        let counts = ["cursorEnter", "cursorLeave", "cursorMove", "cursorDown", "cursorUp", "cursorClick"].map { "\($0)=\(eventCounts[$0] ?? 0)" }.joined(separator: ", ")
        return "Metal 指针运行快照：几何时间 \(frame.map { String(format: "%.6f", $0.time) } ?? "无已完成帧")，命中区 \(frame?.regions.count ?? 0)，当前可输入=\(exposed)，当前命中=\(hovered.prefix(8).joined(separator: ","))；预览 down/up/drag=\(previewCounts)；\(counts)；拒绝样本 \(rejectedSamples)，暂停/脱离丢弃排队项 \(discardedSamples)，投影保留 \(invalidProjectionCount)；屏幕=\(lastScreen)，世界=\(lastWorld)。"
    }
}
