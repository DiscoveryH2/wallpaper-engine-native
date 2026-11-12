import Foundation
import simd

/// TEXS0003 stores nominal dimensions separately; TEXS0002 uses TEXI image
/// dimensions. Images use recorded rectangles; generic particles use a regular
/// grid derived from the first frame's extent. Multi-page and rotated layouts
/// remain explicit parser errors.
struct SceneTextureAnimation {
    struct Frame {
        let duration: Double
        let origin: SIMD2<Float>
        let size: SIMD2<Float>
    }
    let width: Int
    let height: Int
    let frames: [Frame]
    let sourceVersion: String
    let duration: Double
    private let frameEnds: [Double]

    init(width: Int, height: Int, frames: [Frame], sourceVersion: String = "TEXS0003") {
        self.width = width; self.height = height; self.frames = frames; self.sourceVersion = sourceVersion
        var total = 0.0
        frameEnds = frames.map { total += $0.duration; return total }
        duration = total
    }

    func index(at time: Double) -> Int {
        guard time.isFinite, duration > 0 else { return 0 }
        var cursor = time.truncatingRemainder(dividingBy: duration)
        if cursor < 0 { cursor += duration }
        var lower = 0, upper = frameEnds.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if cursor < frameEnds[middle] { upper = middle }
            else { lower = middle + 1 }
        }
        return min(lower, frames.count - 1)
    }

    func uv(at time: Double, atlasWidth: Int, atlasHeight: Int, staticFrame: Int? = nil) -> SIMD4<Float> {
        // A zero-duration sequence has no authored playback clock. Keep the
        // first frame unless a script explicitly selected another one.
        let selected = duration == 0 ? min(max(staticFrame ?? 0, 0), frames.count - 1) : index(at: time)
        let frame = frames[selected]
        return SIMD4(frame.origin.x / Float(atlasWidth), frame.origin.y / Float(atlasHeight),
                     frame.size.x / Float(atlasWidth), frame.size.y / Float(atlasHeight))
    }

    var particleAspectRatio: Float { frames[0].size.y / frames[0].size.x }

    var fractionalFrameCount: Int {
        frames.filter { $0.size.x != floor($0.size.x) || $0.size.y != floor($0.size.y) }.count
    }

    var subtexelFrameCount: Int { frames.filter { $0.size.x < 1 || $0.size.y < 1 }.count }

    func outOfAtlasFrameCount(width: Int, height: Int) -> Int {
        frames.filter { $0.origin.x < 0 || $0.origin.y < 0 ||
            $0.origin.x + $0.size.x > Float(width) || $0.origin.y + $0.size.y > Float(height) }.count
    }

    /// Independent expression of the generic-particle grid contract. Do not
    /// substitute serialized frame origins: those belong to image playback.
    /// The unpadded width matters when a page occupies only part of its storage.
    func particleUV(frame index: Int, atlasWidth: Int, atlasHeight: Int, imageWidth: Int) -> SIMD4<Float> {
        let extent = frames[0].size / SIMD2(Float(atlasWidth), Float(atlasHeight))
        let usedWidth = Float(imageWidth) / Float(atlasWidth)
        let cursor = Float(index) * extent.x / usedWidth
        let row = floor(cursor)
        let origin = SIMD2((cursor - row) * usedWidth, row * extent.y)
        // Retain the native host's half-texel inset to reduce adjacent-cell
        // filtering. This is a documented approximation of the original shader.
        let halfPixel = SIMD2(0.5 / Float(atlasWidth), 0.5 / Float(atlasHeight))
        let inset = simd_min(halfPixel, extent * 0.5)
        let size = simd_max(SIMD2<Float>.zero, extent - inset * 2)
        return SIMD4(origin.x + inset.x, origin.y + inset.y, size.x, size.y)
    }

    var scriptMetadata: [String: Any] {
        ["durations": frames.map(\.duration), "frameCount": frames.count, "duration": duration]
    }
}

/// A script snapshot anchors playback to wallpaper time, so rendering continues
/// smoothly between asynchronous JavaScriptCore responses. A joined animation
/// always uses global scene time; the texture itself has no mutable playhead.
struct SceneTexturePlayback: Equatable {
    let joined: Bool
    let playing: Bool
    let position: Double
    let anchor: Double
    let rate: Double
    let staticFrame: Int?

    init?(_ value: [String: Any]) {
        guard let joined = value["joined"] as? Bool, let playing = value["playing"] as? Bool,
              let position = value["position"] as? Double, let anchor = value["anchor"] as? Double,
              let rate = value["rate"] as? Double,
              position.isFinite, anchor.isFinite, rate.isFinite, abs(rate) <= 100 else { return nil }
        if let raw = value["staticFrame"], !(raw is NSNull) {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero) == number.doubleValue,
                  number.doubleValue >= 0, number.doubleValue < 4096 else { return nil }
            staticFrame = number.intValue
        } else { staticFrame = nil }
        self.joined = joined; self.playing = playing; self.position = position
        self.anchor = anchor; self.rate = rate
    }

    func time(at runtime: Double) -> Double {
        joined ? runtime : position + (playing ? (runtime - anchor) * rate : 0)
    }
}
