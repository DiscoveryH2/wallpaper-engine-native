import Foundation
import CoreFoundation
import simd

/// Our native representation of the legacy scene camera, independent of the
/// newer Camera object's AnimationGraph. REA is used only during development.
struct NativeCameraPose {
    var eye: SIMD3<Float>
    var center: SIMD3<Float>
    var up: SIMD3<Float>
    var zoom: Float = 1

    static let orthographic = NativeCameraPose(eye: .zero, center: SIMD3(0, 0, -1), up: SIMD3(0, 1, 0))
    static let perspective = NativeCameraPose(eye: SIMD3(repeating: 2), center: .zero, up: SIMD3(0, 1, 0))

    struct Frame {
        let view: simd_float4x4
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        static let identity = Frame(view: matrix_identity_float4x4, right: SIMD3(1, 0, 0), up: SIMD3(0, 1, 0))
    }

    func frame(offset: SIMD3<Float> = .zero) -> Frame? {
        guard zoom.isFinite,
              [eye, center, up, offset].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        // Double intermediates avoid overflowing the subtraction/length of
        // otherwise finite Float positions. The GPU still receives Float.
        let e = SIMD3<Double>(eye) + SIMD3<Double>(offset)
        let direction = SIMD3<Double>(center) - SIMD3<Double>(eye)
        let length = simd_length(direction)
        guard length.isFinite, length > 0 else { return nil }
        let forward = direction / length
        let rawRight = simd_cross(forward, SIMD3<Double>(up))
        let rightLength = simd_length(rawRight)
        guard rightLength.isFinite, rightLength > 0 else { return nil }
        let r = rawRight / rightLength, u = simd_cross(r, forward)
        let right = SIMD3<Float>(r), vertical = SIMD3<Float>(u), f = SIMD3<Float>(forward)
        let view = simd_float4x4(columns: (
            SIMD4(right.x, vertical.x, -f.x, 0), SIMD4(right.y, vertical.y, -f.y, 0),
            SIMD4(right.z, vertical.z, -f.z, 0),
            SIMD4(Float(-simd_dot(r, e)), Float(-simd_dot(u, e)), Float(simd_dot(forward, e)), 1)))
        func finite(_ matrix: simd_float4x4) -> Bool {
            (0..<4).allSatisfy { c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }
        }
        let determinant = simd_determinant(view)
        guard finite(view), determinant.isFinite, determinant != 0, finite(simd_inverse(view)) else { return nil }
        return Frame(view: view, right: right, up: vertical)
    }

    static func hermite(_ a: Self, _ b: Self, at s: Float) -> Self {
        // Both tangents are (B-A)/2. This is the two-key legacy formula,
        // not a four-key spline. The reference does not clamp s to [0, 1].
        let s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s
        let h01 = 3 * s2 - 2 * s3, h11 = s3 - s2
        func blend(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
            let tangent = (b - a) * 0.5
            return a * h00 + tangent * h10 + b * h01 + tangent * h11
        }
        let tangent = (b.zoom - a.zoom) * 0.5
        return Self(eye: blend(a.eye, b.eye), center: blend(a.center, b.center), up: blend(a.up, b.up),
            zoom: a.zoom * h00 + tangent * h10 + b.zoom * h01 + tangent * h11)
    }
}

struct NativeLegacyCamera {
    private struct Key {
        let time: Float
        let pose: NativeCameraPose
    }
    private struct Path {
        let sourceIndex: Int
        let duration: Float
        let keys: [Key]
    }
    private struct Sample {
        let sceneTime: Double
        let path: Int
        let key: Int
        let pathTime: Float
        let interpolated: Bool
        let accepted: Bool
    }

    let diagnostics: [String]
    private let paths: [Path]
    private let base: NativeCameraPose
    var staticPose: NativeCameraPose { base }
    var hasPaths: Bool { !paths.isEmpty }
    var fadeAmount: Float {
        guard paths.indices.contains(pathIndex) else { return 0 }
        return NativeCameraFade.opacity(time: pathTime, duration: paths[pathIndex].duration)
    }
    private let source: String?
    private(set) var pose: NativeCameraPose
    private var pathIndex = 0
    private var keyIndex = 0
    private var pathTime: Float = 0
    private var previousSceneTime: Double?
    private var sample: Sample?
    private var keyTransitions: UInt64 = 0
    private var pathTransitions: UInt64 = 0
    private var rejectedSamples: UInt64 = 0
    private var clockResets: UInt64 = 0
    private var invalidClockSteps: UInt64 = 0
    private var suspendedByObject = false

    init(camera: [String: Any], orthographic: Bool, loadJSON: (String) throws -> [String: Any]) {
        var notes: [String] = [], loaded: [Path] = [], selectedSource: String?
        func note(_ text: String) { if notes.count < 64 { notes.append(text) } }
        func numeric(_ raw: Any?) -> Float? {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return number.floatValue
        }
        func disabled(_ raw: Any?) -> Bool {
            guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            return number.boolValue
        }
        func vector(_ raw: Any?) -> SIMD3<Float>? {
            guard let text = raw as? String else { return nil }
            let parts = text.split(whereSeparator: \.isWhitespace)
            guard parts.count == 3 else { return nil }
            let values = parts.compactMap { Float($0) }
            guard values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
            return SIMD3(values[0], values[1], values[2])
        }
        // The constructor clears its vector BEFORE each outer paths[] item.
        // Only the final file's internal paths survive; earlier files need not
        // be read. A non-string final item also leaves no legacy paths.
        if let files = camera["paths"] as? [Any], let last = files.last {
            if files.count > 1 { note("旧版 camera.paths 按参考构造逻辑仅保留最后一个文件的路径。") }
            if let file = last as? String {
                selectedSource = file
                do {
                    let document = try loadJSON(file)
                    guard let entries = document["paths"] as? [Any] else {
                        throw SceneError.invalid("缺少 paths 数组。")
                    }
                    guard entries.count <= 1024 else { throw SceneError.invalid("超过原生的 1024 条路径上限。") }
                    var inspectedKeys = 0
                    for (index, entry) in entries.enumerated() {
                        // Structural termination precedes the disabled check.
                        guard let item = entry as? [String: Any],
                              let transforms = item["transforms"] as? [Any], !transforms.isEmpty else {
                            note("旧版相机路径 \(index + 1) 缺少非空 transforms，按参考加载器停止读取后续路径。")
                            break
                        }
                        if disabled(item["disabled"]) { continue }
                        guard transforms.count <= 65536 - inspectedKeys else {
                            note("旧版相机关键帧超过原生的 65536 项读取上限，停止读取后续路径。")
                            break
                        }
                        inspectedKeys += transforms.count
                        guard let duration = numeric(item["duration"]), duration.isFinite, duration > 0 else {
                            note("拒绝旧版相机路径 \(index + 1)：duration 必须为有限正数。")
                            continue
                        }
                        var keys: [Key] = [], invalid = false
                        for (keyIndex, raw) in transforms.enumerated() {
                            guard let key = raw as? [String: Any], !disabled(key["disabled"]) else { continue }
                            guard let eye = vector(key["eye"]), let center = vector(key["center"]), let up = vector(key["up"]) else { invalid = true; break }
                            let zoom = key["zoom"] == nil ? 1 : numeric(key["zoom"])
                            // Missing/non-numeric timestamps use ORIGINAL array
                            // indices, including disabled/non-object entries.
                            let timestamp = numeric(key["timestamp"]) ?? (keyIndex == 0 ? 0 : duration * (Float(keyIndex) / Float(transforms.count - 1)))
                            guard let zoom, zoom.isFinite, timestamp.isFinite,
                                  (duration - timestamp).isFinite else { invalid = true; break }
                            let candidate = NativeCameraPose(eye: eye, center: center, up: up, zoom: zoom)
                            guard candidate.frame() != nil else { invalid = true; break }
                            if let previous = keys.last,
                               !(timestamp > previous.time && (timestamp - previous.time).isFinite && (timestamp + previous.time).isFinite) {
                                invalid = true; break
                            }
                            keys.append(Key(time: timestamp, pose: candidate))
                        }
                        guard !invalid, !keys.isEmpty else {
                            note("拒绝旧版相机路径 \(index + 1)：关键帧为空、向量缺失或退化、数值无法安全表示，或时间戳未严格递增。此为原生保护边界。")
                            continue
                        }
                        loaded.append(Path(sourceIndex: index, duration: duration, keys: keys))
                    }
                } catch { note("旧版相机路径文件未加载：\(error.localizedDescription)") }
            } else { note("旧版 camera.paths 最后一项不是文件名，按参考构造逻辑清空路径。") }
        }
        var initial = NativeCameraPose.perspective
        for field in ["eye", "center", "up"] where camera[field] != nil {
            if let value = vector(camera[field]) {
                switch field {
                case "eye": initial.eye = value
                case "center": initial.center = value
                default: initial.up = value
                }
            } else { note("基础相机 \(field) 不是三个有限数值，采用构造默认值。") }
        }
        // In 2D the reference discards the editor camera when no paths remain.
        if orthographic && loaded.isEmpty { initial = .orthographic }
        if initial.frame() == nil {
            initial = orthographic ? .orthographic : .perspective
            note("基础相机方向退化或矩阵无效，采用默认相机。")
        }
        paths = loaded; base = initial; pose = initial; source = selectedSource
        if !loaded.isEmpty {
            note("旧版相机路径已加载：\(loaded.count) 条、\(loaded.reduce(0) { $0 + $1.keys.count }) 个有效关键帧；按参考顺序逐帧采样。")
        }
        diagnostics = notes
    }

    /// Only the render loop advances this cursor. Inspection and mouse-hit
    /// queries consume cached pose; repeated/paused scene times do not advance.
    mutating func advance(to time: Double, enabled: Bool = true) {
        suspendedByObject = !enabled
        guard time.isFinite, time >= 0 else { Self.increment(&invalidClockSteps); return }
        guard previousSceneTime != time else { return }
        if let previousSceneTime, time < previousSceneTime {
            pathIndex = 0; keyIndex = 0; pathTime = 0; pose = base
            self.previousSceneTime = nil
            Self.increment(&clockResets)
        }
        let delta = previousSceneTime.map { Float(time - $0) } ?? 0
        previousSceneTime = time
        // Keep the scene-clock anchor current while a Camera object owns the
        // view. Reactivation must not catch up the hidden legacy path.
        guard enabled else { return }
        guard !paths.isEmpty else { return }
        let path = paths[pathIndex], current = path.keys[keyIndex]
        let next = keyIndex + 1 < path.keys.count ? path.keys[keyIndex + 1] : nil
        let threshold: Float, candidate: NativeCameraPose, interpolated: Bool
        if let next, pathTime >= current.time {
            let s = (pathTime - current.time) / (next.time - current.time)
            candidate = .hermite(current.pose, next.pose, at: s)
            threshold = next.time; interpolated = true
        } else {
            candidate = current.pose; interpolated = false
            threshold = pathTime < current.time ? current.time + (next?.time ?? 0) : path.duration - current.time
        }
        let accepted = candidate.frame() != nil
        if accepted { pose = candidate } else { Self.increment(&rejectedSamples) }
        sample = Sample(sceneTime: time, path: pathIndex, key: keyIndex, pathTime: pathTime,
            interpolated: interpolated, accepted: accepted)
        let nextTime = pathTime + delta
        guard delta.isFinite, nextTime.isFinite, threshold.isFinite else { Self.increment(&invalidClockSteps); return }
        // Sample BEFORE delta; strict >, at most one transition per draw.
        // A regular key transition keeps time. A path transition clears it.
        pathTime = nextTime
        if pathTime > threshold {
            if let next, next.time < path.duration {
                keyIndex += 1
                Self.increment(&keyTransitions)
            } else {
                keyIndex = 0; pathTime = 0
                pathIndex = (pathIndex + 1) % paths.count
                Self.increment(&pathTransitions)
            }
        }
    }

    private static func increment(_ counter: inout UInt64) { if counter != .max { counter += 1 } }

    var runtimeDiagnostic: String {
        func vector(_ v: SIMD3<Float>) -> String { "(\(v.x), \(v.y), \(v.z))" }
        let state: String
        if let sample {
            state = "文件=\(source ?? "")；\(paths.count) 条路径；场景时间 \(String(format: "%.2f", sample.sceneTime)) 秒；已采样路径=\(paths[sample.path].sourceIndex + 1)、关键帧=\(sample.key + 1)/\(paths[sample.path].keys.count)、路径时间=\(sample.pathTime)，插值=\(sample.interpolated)，采样有效=\(sample.accepted)；下一游标=\(pathIndex + 1)/\(keyIndex + 1)/\(pathTime)；关键帧切换=\(keyTransitions)，路径切换=\(pathTransitions)"
        } else { state = "无活动旧版路径，采用基础相机" }
        return "旧版相机运行快照：\(state)；eye=\(vector(pose.eye))，center=\(vector(pose.center))，up=\(vector(pose.up))，zoom=\(pose.zoom)；被 Camera 对象暂停=\(suspendedByObject)；无效采样保留上一有效姿态=\(rejectedSamples)，时钟重置=\(clockResets)，无效计时步=\(invalidClockSteps)。"
    }
}
