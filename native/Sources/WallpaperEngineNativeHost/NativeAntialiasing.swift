import Foundation
import Metal

/// Values and labels follow the public Steam UI. Existing native installs keep
/// their previous single-sample rendering until explicitly changed.
enum NativeAntialiasing: String, CaseIterable, Codable {
    case none, x2, x4, x8
    var samples: Int {
        switch self { case .none: return 1; case .x2: return 2; case .x4: return 4; case .x8: return 8 }
    }
    var title: String { self == .none ? "无" : "MSAA " + rawValue }
    var supportedByDevice: Bool { self == .none || MTLCreateSystemDefaultDevice()?.supportsTextureSampleCount(samples) == true }

    /// This is additional scene storage, independent of effects and histories.
    /// Check before multiplying large untrusted dimensions or allocating GPU RAM.
    static func bytes(width: Int, height: Int, samples: Int, hdr: Bool, depth: Bool, targets: Int = 1) throws -> Int {
        guard (1...4096).contains(width), (1...4096).contains(height), [1, 2, 4, 8].contains(samples),
              (1...2).contains(targets) else { throw SceneError.invalid("抗锯齿缓冲的尺寸或采样数无效。") }
        let bytes = samples == 1 ? 0 : width * height * samples * ((hdr ? 8 : 4) + (depth ? 4 : 0)) * targets
        guard bytes <= 768 * 1024 * 1024 else { throw SceneError.invalid("抗锯齿缓冲超过每个播放实例 768 MiB 的上限，保留原品质。") }
        return bytes
    }
}
