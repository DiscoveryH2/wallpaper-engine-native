import Foundation
import CoreGraphics

enum NativeTextureResolution: String, Codable, CaseIterable, Sendable {
    case full, half, automatic = "auto"
    var title: String {
        switch self { case .full: return "高质量"; case .half: return "高性能"; case .automatic: return "自动" }
    }
}

enum NativeTextureCanvas: Equatable, Sendable {
    case orthographic(width: Int, height: Int), perspective, unknown
    init(scene: [String: Any]) {
        let general = scene["general"] as? [String: Any] ?? [:]
        guard let raw = general["orthogonalprojection"] else { self = .perspective; return }
        guard let values = raw as? [String: Any], values["auto"] as? Bool != true,
              let width = values["width"] as? NSNumber, let height = values["height"] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              (1...16384).contains(width.doubleValue), (1...16384).contains(height.doubleValue) else {
            self = .unknown; return
        }
        self = .orthographic(width: width.intValue, height: height.intValue)
    }
}

/// REA, Windows public build 26168761: 0x14017e6f0 decides whether to
/// skip one authored mip. Float arithmetic and strict comparisons follow
/// its MULSS/COMISS instructions. Unknown canvas/output keeps full quality.
struct NativeTextureResolutionRequest: Equatable, Sendable {
    var quality: NativeTextureResolution = .full
    var outputSize = CGSize(width: 1280, height: 720)
    func preferredMip(canvas: NativeTextureCanvas) -> Int {
        switch quality {
        case .full: return 0
        case .half: return 1
        case .automatic:
            guard outputSize.width.isFinite, outputSize.height.isFinite,
                  (1...32768).contains(outputSize.width), (1...32768).contains(outputSize.height) else { return 0 }
            let area = Float(outputSize.width) * Float(outputSize.height)
            switch canvas {
            case .orthographic(let width, let height): return Float(width * height) > area * 3.9 ? 1 : 0
            case .perspective: return area < 1_969_920 ? 1 : 0
            case .unknown: return 0
            }
        }
    }
}
