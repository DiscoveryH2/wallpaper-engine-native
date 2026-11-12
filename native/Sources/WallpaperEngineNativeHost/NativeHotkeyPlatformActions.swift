import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// User-facing failures for platform actions invoked by a global hotkey.  None
/// of these cases requests a new privacy permission or changes Finder state.
enum NativeHotkeyPlatformActionError: LocalizedError {
    case screenCapturePermissionUnavailable
    case desktopWallpaperUnavailable
    case screenSaverUnavailable
    case screenSaverLaunchFailed
    case screenshotEncodingFailed

    var errorDescription: String? {
        switch self {
        case .screenCapturePermissionUnavailable:
            return "未授予屏幕录制权限，无法截取当前桌面壁纸。"
        case .desktopWallpaperUnavailable:
            return "当前没有可截取的原生桌面壁纸窗口。"
        case .screenSaverUnavailable:
            return "未找到 macOS 自带的屏幕保护程序。"
        case .screenSaverLaunchFailed:
            return "无法启动 macOS 屏幕保护程序。"
        case .screenshotEncodingFailed:
            return "无法将桌面壁纸编码为 PNG。"
        }
    }
}

/// The platform-only part of global hotkey actions.  The host decides which
/// DesktopWindow is current and maps a saved hotkey target to one of these
/// calls; this type deliberately knows nothing about profiles or playlists.
///
/// Screenshot capture filters one exact window owned by this process. It never
/// reads the full display, Finder, or another application's pixels. The save
/// panel is always shown before a PNG is written, and a cancelled panel leaves
/// no file behind.
@MainActor
final class NativeHotkeyPlatformActions {
    static let shared = NativeHotkeyPlatformActions()

    /// The Apple-supplied ScreenSaverEngine location on this macOS release.
    /// This is a fixed system application path, not a shell command or a
    /// caller-provided executable.
    static let screenSaverApplicationURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app", isDirectory: true)
    private static let screenSaverBundleIdentifier = "com.apple.ScreenSaver.Engine"

    private let screenCaptureAccessPreflight: () -> Bool
    private let screenSaverLauncher: (URL) -> Bool
    // These four seams make it possible for the isolated GUI harness to prove
    // that a denied/cancelled request never reaches ScreenCaptureKit, a save
    // panel, or the filesystem. Production always uses the Apple APIs below.
    private let shareableContentProvider: () async throws -> SCShareableContent
    private let screenshotCapturer: (SCContentFilter, SCStreamConfiguration) async throws -> CGImage
    private let saveDestination: (DesktopWindow) -> URL?
    private let pngWriter: (CGImage, URL) throws -> Void

    init(screenCaptureAccessPreflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         screenSaverLauncher: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         shareableContentProvider: (() async throws -> SCShareableContent)? = nil,
         screenshotCapturer: ((SCContentFilter, SCStreamConfiguration) async throws -> CGImage)? = nil,
         saveDestination: ((DesktopWindow) -> URL?)? = nil,
         pngWriter: ((CGImage, URL) throws -> Void)? = nil) {
        self.screenCaptureAccessPreflight = screenCaptureAccessPreflight
        self.screenSaverLauncher = screenSaverLauncher
        self.shareableContentProvider = shareableContentProvider ?? { try await SCShareableContent.current }
        self.screenshotCapturer = screenshotCapturer ?? {
            try await SCScreenshotManager.captureImage(contentFilter: $0, configuration: $1)
        }
        self.saveDestination = saveDestination ?? { NativeHotkeyPlatformActions.choosePNGDestination(for: $0) }
        self.pngWriter = pngWriter ?? { try NativeHotkeyPlatformActions.writePNG($0, to: $1) }
    }

    @discardableResult
    func toggleDesktopIconVisibility() -> Bool {
        NativeDesktopIconVisibility.shared.toggleIconsHidden()
    }

    /// Starts the bundled macOS screen-saver host. This intentionally does not
    /// attempt to configure, terminate, or automate the system screen saver.
    func startScreenSaver() throws {
        let application = Self.screenSaverApplicationURL
        let executable = application.appendingPathComponent("Contents/MacOS/ScreenSaverEngine")
        guard Bundle(url: application)?.bundleIdentifier == Self.screenSaverBundleIdentifier,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NativeHotkeyPlatformActionError.screenSaverUnavailable
        }
        guard screenSaverLauncher(application) else {
            throw NativeHotkeyPlatformActionError.screenSaverLaunchFailed
        }
    }

    /// Captures only `desktopWindow`, after verifying that ScreenCaptureKit
    /// identifies it as a window owned by this application. It performs a
    /// preflight check only; it never calls a privacy prompt API.
    @discardableResult
    func captureDesktopWallpaper(from desktopWindow: DesktopWindow) async throws -> URL? {
        try Task.checkCancellation()
        guard screenCaptureAccessPreflight() else {
            throw NativeHotkeyPlatformActionError.screenCapturePermissionUnavailable
        }
        guard desktopWindow.isVisible, desktopWindow.windowNumber > 0 else {
            throw NativeHotkeyPlatformActionError.desktopWallpaperUnavailable
        }
        let expectedWindowNumber = desktopWindow.windowNumber
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let content = try await shareableContentProvider()
        try validateCurrentDesktopWindow(desktopWindow, number: expectedWindowNumber)
        guard let sourceWindow = content.windows.first(where: {
            Int($0.windowID) == expectedWindowNumber && $0.owningApplication?.processID == ownPID
        }) else {
            throw NativeHotkeyPlatformActionError.desktopWallpaperUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: sourceWindow)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        let backing = desktopWindow.convertToBacking(NSRect(origin: .zero, size: desktopWindow.frame.size))
        configuration.width = max(1, Int(backing.width.rounded(.up)))
        configuration.height = max(1, Int(backing.height.rounded(.up)))
        let image = try await screenshotCapturer(filter, configuration)
        try validateCurrentDesktopWindow(desktopWindow, number: expectedWindowNumber)
        NSApp.activate(ignoringOtherApps: true)
        guard let destination = saveDestination(desktopWindow) else { return nil }
        try validateCurrentDesktopWindow(desktopWindow, number: expectedWindowNumber)
        try pngWriter(image, destination)
        return destination
    }

    private func validateCurrentDesktopWindow(_ window: DesktopWindow, number: Int) throws {
        try Task.checkCancellation()
        guard window.isVisible, window.windowNumber == number else { throw CancellationError() }
    }

    private static func choosePNGDestination(for window: DesktopWindow) -> URL? {
        let panel = NSSavePanel()
        panel.title = "保存壁纸截屏"
        panel.message = "保存当前桌面壁纸画面。"
        panel.nameFieldStringValue = "Wallpaper Engine Native - \(window.displayName).png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func writePNG(_ image: CGImage, to destination: URL) throws {
        guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NativeHotkeyPlatformActionError.screenshotEncodingFailed
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            throw NativeHotkeyPlatformActionError.screenshotEncodingFailed
        }
    }
}
