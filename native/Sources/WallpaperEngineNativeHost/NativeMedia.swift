import AppKit
import CryptoKit
import Foundation
import ImageIO

struct NativeMediaArtwork: Sendable {
    let digest: String
    let width: Int, height: Int
    let rgba: [UInt8]
    let primary: [Double], secondary: [Double], tertiary: [Double], text: [Double], contrast: [Double]

    static func decode(_ data: Data) throws -> NativeMediaArtwork {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 100_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw NativeMediaError.invalid("封面不是受支持的有界图片。") }
        let w = image.width, h = image.height
        guard w > 0, h > 0, w <= 1024, h <= 1024 else { throw NativeMediaError.invalid("封面缩略图超过上限。") }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw NativeMediaError.invalid("无法解码封面像素。") }
        // Scene textures use straight alpha, unlike the CoreGraphics buffer.
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            for c in 0..<3 { pixels[i + c] = a > 0 ? UInt8(min(255, (Int(pixels[i + c]) * 255 + a / 2) / a)) : 0 }
        }
        var bins: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        let step = max(1, w * h / 16384)
        for pixel in stride(from: 0, to: w * h, by: step) {
            let i = pixel * 4
            guard pixels[i + 3] >= 128 else { continue }
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            let old = bins[key] ?? (0,0,0,0)
            bins[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        let ranked = bins.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
        var colors: [[Double]] = []
        for (_, bin) in ranked {
            let color = [bin.r,bin.g,bin.b].map { Double($0) / Double(bin.count) / 255 }
            if colors.allSatisfy({ zip($0,color).reduce(0.0) { $0 + pow($1.0 - $1.1, 2) } > 0.04 }) { colors.append(color) }
            if colors.count == 3 { break }
        }
        if colors.isEmpty { colors = [[0,0,0]] }
        while colors.count < 3 { colors.append(colors[0]) }
        func luminance(_ c: [Double]) -> Double {
            let v = c.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722
        }
        let light = luminance(colors[0])
        let contrast = [Double](repeating: (light + 0.05) / 0.05 >= 1.05 / (light + 0.05) ? 0 : 1, count: 3)
        let text = colors.dropFirst().first { let value = luminance($0); return (max(light,value) + 0.05) / (min(light,value) + 0.05) >= 4.5 } ?? contrast
        let digest = SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined() + ":\(w)x\(h)"
        return NativeMediaArtwork(digest: digest, width: w, height: h, rgba: pixels, primary: colors[0], secondary: colors[1], tertiary: colors[2], text: text, contrast: contrast)
    }
}

struct NativeMediaSnapshot: Sendable {
    var revision = 0
    var enabled = false
    var observed = false
    var state = 0
    var itemSequence = 0
    var identity = ""
    var title = "", artist = ""
    var position: Double?, duration: Double?
    var artwork: NativeMediaArtwork?
    static let disabled = NativeMediaSnapshot()
    var scriptValue: [String: Any] {
        let black: [Double] = [0,0,0], white: [Double] = [1,1,1]
        let properties: [String: String] = ["title": title, "artist": artist]
        let thumbnail: [String: Any] = ["hasThumbnail": artwork != nil,
            "primaryColor": artwork?.primary ?? black, "secondaryColor": artwork?.secondary ?? black,
            "tertiaryColor": artwork?.tertiary ?? black, "textColor": artwork?.text ?? white,
            "highContrastColor": artwork?.contrast ?? white]
        var value: [String: Any] = ["revision": revision, "enabled": enabled, "observed": observed, "state": state,
            "itemSequence": itemSequence, "properties": properties, "thumbnailID": artwork?.digest ?? "", "thumbnail": thumbnail]
        if let position, let duration, position.isFinite, duration.isFinite, duration > 0 {
            value["timeline"] = ["position": min(duration,max(0,position)), "duration": duration]
        }
        return value
    }
    var semanticIdentity: String {
        var value = scriptValue; value.removeValue(forKey: "revision"); value.removeValue(forKey: "itemSequence")
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

enum NativeMediaError: LocalizedError {
    case invalid(String)
    case appleEvent(Int32)
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return text
        case .appleEvent(let code): return "“音乐”返回读取错误 \(code)。"
        }
    }
}

/// One opt-in provider for all presentations. Only the current Music item is
/// read; neither the library nor playback commands are queried or changed.
@MainActor
final class NativeMediaService {
    static let shared = NativeMediaService()
    private(set) var snapshot = NativeMediaSnapshot.disabled
    private(set) var enabled = false
    private(set) var requestingPermission = false
    private(set) var status = "媒体信息已关闭。"
    private let queue = DispatchQueue(label: "io.wallpaper-engine-native.music-metadata", qos: .utility)
    private let reader = MusicMediaReader()
    private var timer: Timer?
    private var pending = false
    private var generation = 0
    private var revision = 0
    private var itemSequence = 0
    private var stopped = false

    func restore() {
        guard UserDefaults.standard.bool(forKey: "musicMediaEnabled") else { return }
        enabled = true; publish(NativeMediaSnapshot(enabled: true)); startTimer(); refresh()
    }
    func requestEnable() {
        guard !requestingPermission, !stopped else { return }
        guard let pid = Self.musicPID else { status = "请先打开系统“音乐”应用，再点击允许读取。"; return }
        generation += 1
        let token = generation
        requestingPermission = true; status = "等待 macOS 确认读取“音乐”的权限…"
        queue.async { [weak self] in
            let permission = MusicMediaReader.permission(pid: pid, ask: true)
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.generation == token else { return }
                self.requestingPermission = false
                if permission == 0 {
                    self.enabled = true
                    UserDefaults.standard.set(true, forKey: "musicMediaEnabled")
                    self.publish(NativeMediaSnapshot(enabled: true))
                    self.startTimer(); self.refresh()
                } else {
                    self.status = "“音乐”读取权限未获允许（\(permission)）。可在系统设置的自动化权限中调整后重试。"
                }
            }
        }
    }
    func disable() {
        generation += 1; enabled = false; requestingPermission = false
        timer?.invalidate(); timer = nil
        UserDefaults.standard.set(false, forKey: "musicMediaEnabled")
        publish(.disabled); status = "媒体信息已关闭。"
        queue.async { [reader] in reader.reset() }
    }
    func shutdown() {
        guard !stopped else { return }
        stopped = true; generation += 1; requestingPermission = false
        timer?.invalidate(); timer = nil
        queue.async { [reader] in reader.reset() }
        // Quitting is not the user's "disable" action. Preserve that setting.
    }
    private static var musicPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first(where: { !$0.isTerminated })?.processIdentifier
    }
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    private func refresh() {
        guard enabled, !pending, !stopped else { return }
        guard let pid = Self.musicPID else {
            status = "已启用；“音乐”当前未运行。保留最后一次确认的信息，等待应用运行。"
            return
        }
        pending = true
        let token = generation
        queue.async { [weak self, reader] in
            let result = Result { try reader.read(pid: pid) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pending = false
                guard !self.stopped, self.enabled, self.generation == token else { return }
                switch result {
                case .success(let value):
                    self.publish(value)
                    self.status = value.state == 0 ? "已启用；“音乐”当前没有正在播放或暂停的曲目。" : "正在读取“音乐”：\(value.state == 1 ? "播放中" : "已暂停")\n\(value.title)\n\(value.artist)\n封面：\(value.artwork == nil ? "暂无" : "已取得")"
                case .failure(let error):
                    // An unavailable observation is not a stopped player or a
                    // missing cover. Keep the last complete, confirmed item.
                    self.status = "暂时无法读取“音乐”；保留最后一次确认的信息。\n\(error.localizedDescription)"
                }
            }
        }
    }
    private func publish(_ value: NativeMediaSnapshot) {
        guard value.identity != snapshot.identity || value.semanticIdentity != snapshot.semanticIdentity else { return }
        if value.identity != snapshot.identity { itemSequence += 1 }
        revision += 1
        var next = value; next.revision = revision; next.itemSequence = itemSequence; snapshot = next
        // No song titles, artist names, artwork bytes or persistent track IDs
        // enter the diagnostic log.
        fputs("Native media snapshot: revision \(revision), enabled \(next.enabled), observed \(next.observed), state \(next.state), artwork \(next.artwork != nil), timeline \(next.position != nil && next.duration != nil)\n", stderr)
    }
}

@MainActor
final class NativeMediaController: NSWindowController {
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let enableButton = NSButton(title: "允许读取“音乐”", target: nil, action: nil)
    private let disableButton = NSButton(title: "关闭媒体信息", target: nil, action: nil)
    private var timer: Timer?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 370), styleMask: [.titled,.closable], backing: .buffered, defer: false)
        window.title = "媒体信息"; window.isReleasedWhenClosed = false
        super.init(window: window)
        let explanation = NSTextField(wrappingLabelWithString: "将系统“音乐”当前曲目的歌名、艺人、封面和进度显示在支持媒体信息的壁纸中。首次开启需要 macOS 的自动化授权。\n\n当前支持“音乐”应用；其他播放器仍待适配。数据仅在本机用于壁纸，不保存播放历史。")
        explanation.font = .systemFont(ofSize: 13)
        statusLabel.maximumNumberOfLines = 6
        statusLabel.lineBreakMode = .byTruncatingTail
        enableButton.target = self; enableButton.action = #selector(enable)
        disableButton.target = self; disableButton.action = #selector(disable)
        let close = NSButton(title: "关闭窗口", target: self, action: #selector(closePanel))
        let buttons = NSStackView(views: [enableButton,disableButton,close]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [explanation,statusLabel,buttons]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -24)])
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func present() {
        refresh(); showWindow(nil); NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
    }
    private func refresh() {
        let service = NativeMediaService.shared
        statusLabel.stringValue = service.status
        enableButton.isEnabled = !service.enabled && !service.requestingPermission
        disableButton.isEnabled = service.enabled || service.requestingPermission
    }
    @objc private func enable() { NativeMediaService.shared.requestEnable(); refresh() }
    @objc private func disable() { NativeMediaService.shared.disable(); refresh() }
    @objc private func closePanel() { close() }
    deinit { timer?.invalidate() }
}
