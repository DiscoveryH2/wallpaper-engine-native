import Foundation

/// Only validated, ordered helper responses may change this persistent static
/// pose. Rendered path poses, parallax and shake never overwrite it.
struct NativeScriptCamera {
    struct Receipt {
        let reads: Int
        let writes: Int
        let pose: NativeCameraPose?
    }

    private(set) var pose: NativeCameraPose
    private var reads = 0
    private var writes = 0
    private var batches = 0

    init(pose: NativeCameraPose) { self.pose = pose }

    var scriptValue: [String: Any] {
        func vector(_ v: SIMD3<Float>) -> [String: Float] { ["x": v.x, "y": v.y, "z": v.z] }
        return ["eye": vector(pose.eye), "center": vector(pose.center), "up": vector(pose.up), "zoom": pose.zoom]
    }

    static func parse(_ raw: Any?) -> Receipt? {
        guard let raw = raw as? [String: Any],
              NativeAnimationJSON.number(raw["protocol"])?.doubleValue == 1 else { return nil }
        func count(_ raw: Any?) -> Int? {
            guard let value = NativeAnimationJSON.number(raw)?.doubleValue,
                  value.isFinite, value >= 0, value <= 4096, value.rounded(.towardZero) == value else { return nil }
            return Int(value)
        }
        guard let reads = count(raw["reads"]), let writes = count(raw["writes"]), reads + writes <= 4096 else { return nil }
        guard writes > 0 else {
            guard raw["transforms"] == nil else { return nil }
            return Receipt(reads: reads, writes: 0, pose: nil)
        }
        func scalar(_ raw: Any?) -> Float? {
            guard let value = NativeAnimationJSON.number(raw)?.doubleValue, value.isFinite,
                  abs(value) <= Double(Float.greatestFiniteMagnitude) else { return nil }
            return Float(value)
        }
        func vector(_ raw: Any?) -> SIMD3<Float>? {
            guard let raw = raw as? [String: Any], let x = scalar(raw["x"]),
                  let y = scalar(raw["y"]), let z = scalar(raw["z"]) else { return nil }
            return SIMD3(x, y, z)
        }
        guard let value = raw["transforms"] as? [String: Any], let eye = vector(value["eye"]),
              let center = vector(value["center"]), let up = vector(value["up"]), let zoom = scalar(value["zoom"]) else { return nil }
        let pose = NativeCameraPose(eye: eye, center: center, up: up, zoom: zoom)
        guard pose.frame() != nil else { return nil }
        return Receipt(reads: reads, writes: writes, pose: pose)
    }

    mutating func commit(_ receipt: Receipt) {
        if let next = receipt.pose { pose = next; batches = min(1_000_000_000, batches + 1) }
        reads = min(1_000_000_000, reads + receipt.reads)
        writes = min(1_000_000_000, writes + receipt.writes)
    }

    var runtimeDiagnostic: String? {
        guard reads > 0 || writes > 0 else { return nil }
        func vector(_ v: SIMD3<Float>) -> String { "(\(v.x), \(v.y), \(v.z))" }
        return "静态相机脚本运行快照：get=\(reads)，set=\(writes)，已提交写入批次=\(batches)；eye=\(vector(pose.eye))，center=\(vector(pose.center))，up=\(vector(pose.up))，zoom=\(pose.zoom)。"
    }
}
