import Foundation
import simd

/// Shared model-space extraction for the observed MDLA root-motion branch.
/// Bone chains here deliberately omit animated scale; skinning does not.
enum NativeModelRootMotion {
    static let translationMask: UInt32 = 0x3800
    static let headingMask: UInt32 = 0x8000
    static let supportedMask: UInt32 = translationMask | headingMask

    struct Rigid {
        var position: SIMD3<Float>
        var rotation: simd_float3x3
    }
    struct Cursor {
        var pose: Rigid
        var time: Float
    }
    struct Description {
        let bone: Int
        let flags: UInt32
        let start: Rigid, end: Rigid, initial: Rigid
        let forward: SIMD3<Float>
        let startHeading: simd_float3x3
    }
    struct Result {
        let translation: SIMD3<Float>
        let turn: Float
        let cursor: Cursor
    }

    static func describe(_ clip: NativeModelSkeleton.Clip, bones: [NativeModelSkeleton.Bone]) throws -> Description? {
        guard clip.rootMotionFlags != 0, let reference = clip.reference, reference.rootBone >= 0 else { return nil }
        guard clip.rootMotionFlags & ~supportedMask == 0 else { throw invalid("未支持的运动分量") }
        let startFrame = clip.ownsTracks ? 0 : reference.startFrame
        let endFrame = clip.ownsTracks ? clip.frameCount : reference.endFrame
        let initialFrame = clip.ownsTracks ? 0 : startFrame + reference.frameOffset
        let start = try sample(clip, bones: bones, bone: reference.rootBone, frame: startFrame, next: startFrame, fraction: 0)
        let end = try sample(clip, bones: bones, bone: reference.rootBone, frame: endFrame, next: endFrame, fraction: 0)
        let initial = try sample(clip, bones: bones, bone: reference.rootBone, frame: initialFrame, next: initialFrame, fraction: 0)
        let forward = simd_inverse(start.rotation)[2]
        return try Description(bone: reference.rootBone, flags: clip.rootMotionFlags, start: start, end: end, initial: initial,
            forward: forward, startHeading: heading(start.rotation, forward: forward))
    }

    static func sample(_ clip: NativeModelSkeleton.Clip, bones: [NativeModelSkeleton.Bone], bone: Int,
                       frame: Int, next: Int, fraction: Float) throws -> Rigid {
        guard bones.indices.contains(bone), fraction.isFinite else { throw invalid("根骨骼或采样比例无效") }
        var result = Rigid(position: .zero, rotation: matrix_identity_float3x3), index = bone
        while index >= 0 {
            guard clip.tracks.indices.contains(index), clip.tracks[index].indices.contains(frame),
                  clip.tracks[index].indices.contains(next) else { throw invalid("根骨链采样超出关键帧范围") }
            let a = clip.tracks[index][frame], b = clip.tracks[index][next]
            let rotation = simd_float3x3(try NativeModelAnimation.nlerp(a.rotation, b.rotation, fraction))
            let position = a.position * (1 - fraction) + b.position * fraction
            result = Rigid(position: position + rotation * result.position, rotation: rotation * result.rotation)
            let parent = bones[index].parent
            guard parent < index else { throw invalid("根骨链父级顺序无效") }
            index = parent
        }
        guard finite(result.position), finite(result.rotation) else { throw invalid("根骨链矩阵溢出") }
        return result
    }

    static func extract(_ description: Description, current: Rigid, time: Float, previous: Cursor?,
                        weight: Float, remaining: Float, pose: inout [NativeModelSkeleton.Key]) throws -> Result {
        guard time.isFinite, weight.isFinite, remaining.isFinite, (0...1).contains(weight),
              (0...1).contains(remaining), pose.indices.contains(description.bone) else { throw invalid("根运动输入无效") }
        let currentHeading = try heading(current.rotation, forward: description.forward)
        let correction = description.startHeading * simd_inverse(currentHeading)
        var previous = previous ?? Cursor(pose: description.initial, time: 0)
        var cycle = SIMD3<Float>.zero
        // The reference compares wrapped Float clocks and corrects ONE cycle.
        // Reverse/mirror/large-step behavior must not be replaced by an invented
        // continuously unwrapped clock.
        if previous.time > time {
            cycle = description.end.position - description.start.position
            previous.pose.rotation = previous.pose.rotation * simd_inverse(description.end.rotation) * description.start.rotation
        }
        let previousHeading = try heading(previous.pose.rotation, forward: description.forward)
        var translation = correction * (current.position - previous.pose.position + cycle
            - currentHeading * description.start.position + previousHeading * description.start.position)
        var root = pose[description.bone]
        var position = root.position
        for axis in 0..<3 {
            if description.flags & (UInt32(0x800) << axis) != 0 {
                position[axis] += weight * (description.start.position[axis] - current.position[axis])
            } else { translation[axis] = 0 }
        }
        var turn: Float = 0
        if description.flags & headingMask != 0 {
            // This correction is not blend-weighted in the observed consumer.
            let rotation = simd_quatf(correction) * root.rotation
            if description.flags & 0xa800 == headingMask { position = correction * position }
            root = NativeModelSkeleton.Key(position: position, rotation: rotation, scale: root.scale)
            let delta = currentHeading * simd_inverse(previousHeading)
            turn = atan2(-delta[0].z, hypot(delta[1].z, delta[2].z)) * weight * remaining
        } else { root = NativeModelSkeleton.Key(position: position, rotation: root.rotation, scale: root.scale) }
        translation *= weight * remaining
        guard finite(position), finite(root.rotation.vector), finite(translation), turn.isFinite else { throw invalid("根运动提取溢出") }
        pose[description.bone] = root
        return Result(translation: translation, turn: turn, cursor: Cursor(pose: current, time: time))
    }

    static func heading(_ rotation: simd_float3x3, forward: SIMD3<Float>) throws -> simd_float3x3 {
        let direction = rotation * forward, length = hypot(direction.x, direction.z)
        guard length.isFinite, length > 0 else { throw invalid("根骨骼朝向没有有效水平投影") }
        let x = direction.x / length, z = direction.z / length
        return simd_float3x3(SIMD3(z, 0, -x), SIMD3(0, 1, 0), SIMD3(x, 0, z))
    }

    struct Input {
        let origin: SIMD3<Float>, angles: SIMD3<Float>, scale: SIMD3<Float>
        let parent: simd_float4x4
        let enabled: Bool
        let curveOverrides: Set<String>
        init(object: [String: Any], parent: simd_float4x4 = matrix_identity_float4x4, curveOverrides: Set<String> = []) throws {
            func vector(_ name: String, _ fallback: SIMD3<Float>) throws -> SIMD3<Float> {
                guard let raw = object[name] else { return fallback }
                let values = SceneValues.floats(raw)
                guard values.count == 3, values.allSatisfy(\.isFinite) else { throw invalid("模型 \(name) 必须是有限三维向量") }
                return SIMD3(values[0], values[1], values[2])
            }
            origin = try vector("origin", .zero); angles = try vector("angles", .zero); scale = try vector("scale", SIMD3(repeating: 1))
            if let value = object["rootmotion"] {
                guard let flag = NativeAnimationJSON.boolean(value) else { throw invalid("rootmotion 必须是布尔值") }
                enabled = flag
            } else { enabled = true }
            guard NativeModelAnimation.finite(parent) else { throw invalid("模型父级矩阵溢出") }
            self.parent = parent; self.curveOverrides = curveOverrides
        }
    }
    /// Position/angles belong to the model instance, not its shared mesh.
    /// Track authored input separately from accumulated motion so stale cached
    /// script values do not reset it; explicit writes still realign every time.
    struct ObjectState {
        var origin: SIMD3<Float>, angles: SIMD3<Float>, enabled: Bool
        private var inputOrigin: SIMD3<Float>, inputAngles: SIMD3<Float>
        private var inputEnabled: Bool
        private var time: Double?
        init(_ input: Input) {
            origin = input.origin; angles = input.angles; enabled = input.enabled
            inputOrigin = input.origin; inputAngles = input.angles
            inputEnabled = input.enabled
        }
        mutating func prepare(_ input: Input, time: Double, paused: Bool, writes: [String: Any]) throws {
            if input.origin != inputOrigin || (!paused && time != self.time && input.curveOverrides.contains("origin")) { origin = input.origin }
            if input.angles != inputAngles || (!paused && time != self.time && input.curveOverrides.contains("angles")) { angles = input.angles }
            if input.enabled != inputEnabled { enabled = input.enabled }
            if let value = writes["origin"] { origin = try Input(object: ["origin": value]).origin }
            if let value = writes["angles"] { angles = try Input(object: ["angles": value]).angles }
            if let value = writes["rootmotion"] {
                guard let flag = NativeAnimationJSON.boolean(value) else { throw invalid("脚本根运动开关无效") }
                enabled = flag
            }
            inputOrigin = input.origin; inputAngles = input.angles; inputEnabled = input.enabled; self.time = time
        }
        mutating func apply(_ result: Result, input: Input) throws {
            let world = input.parent * SceneValues.transform(["origin": [origin.x, origin.y, origin.z],
                "angles": [angles.x, angles.y, angles.z], "scale": [input.scale.x, input.scale.y, input.scale.z]])
            let translated = world * SIMD4(result.translation, 0)
            var nextAngles = angles
            if result.turn != 0 {
                if abs(angles.x) + abs(angles.z) < 0.0001 {
                    nextAngles.y = fmod(angles.y + result.turn, 2 * .pi)
                } else {
                    let object = simd_quatf(angle: angles.z, axis: SIMD3(0, 0, 1))
                        * simd_quatf(angle: angles.y, axis: SIMD3(0, 1, 0)) * simd_quatf(angle: angles.x, axis: SIMD3(1, 0, 0))
                    let matrix = simd_float3x3(object * simd_quatf(angle: result.turn, axis: SIMD3(0, 1, 0)))
                    let z = atan2(matrix[0].y, matrix[0].x), y = atan2(-matrix[0].z, hypot(matrix[0].x, matrix[0].y))
                    let x = atan2(sin(z) * matrix[2].x - cos(z) * matrix[2].y, cos(z) * matrix[1].y - sin(z) * matrix[1].x)
                    nextAngles = SIMD3(x, y, z)
                }
            }
            let nextOrigin = origin + SIMD3(translated.x, translated.y, translated.z)
            guard NativeModelAnimation.finite(world), finite(nextOrigin), finite(nextAngles) else { throw invalid("模型根位移或转向溢出") }
            origin = nextOrigin; angles = nextAngles
        }
        var properties: [String: Any] { ["origin": [origin.x, origin.y, origin.z], "angles": [angles.x, angles.y, angles.z], "rootmotion": enabled] }
        var scriptProperties: [String: Any] { ["origin": [origin.x, origin.y, origin.z], "angles": [angles.x, angles.y, angles.z].map { $0 * 180 / .pi }, "rootmotion": enabled] }
    }

    private static func finite(_ value: SIMD3<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
    private static func finite(_ value: SIMD4<Float>) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite }
    private static func finite(_ value: simd_float3x3) -> Bool { (0..<3).allSatisfy { finite(value[$0]) } }
    private static func invalid(_ text: String) -> SceneError { .invalid("模型根运动：" + text + "；保留上一有效状态。") }
}
