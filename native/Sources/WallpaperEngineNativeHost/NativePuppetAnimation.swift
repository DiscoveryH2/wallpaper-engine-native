import Foundation
import CoreFoundation
import simd

/// A single, fully weighted loop layer. Other author configurations fail
/// explicitly until their blend, event and script semantics are implemented.
final class NativePuppetAnimation {
    struct Sample {
        let frame: Int
        let fraction: Float
        let local: [simd_float4x4]
        let palette: [simd_float4x4]
    }
    let model: NativePuppetModel
    let clip: NativePuppetModel.Clip
    let rate: Double
    private let inverseBind: [simd_float4x4]
    private(set) var lastSceneTime: Double = 0
    private(set) var lastFrame = 0
    private(set) var lastFraction: Float = 0
    private(set) var updates = 0
    var runtimeDiagnostic: String {
        "木偶快照：时间 \(String(format: "%.3f", lastSceneTime)) 秒；动画 id=\(clip.id)，帧 \(lastFrame)/\(clip.frameCount)，插值 \(String(format: "%.3f", lastFraction))，更新 \(updates) 次；骨约束未实现。"
    }
    private static func invalid(_ message: String) -> SceneError { SceneError.invalid("Puppet animation: \(message)") }

    init(model: NativePuppetModel, layers: [[String: Any]]) throws {
        guard layers.count == 1, let layer = layers.first else { throw Self.invalid("only one authored animation layer is currently supported") }
        guard try Self.boolean(layer["visible"], default: true),
              try !Self.boolean(layer["additive"], default: false),
              try !Self.boolean(layer["blendin"], default: false),
              try !Self.boolean(layer["blendout"], default: false),
              try Self.number(layer["blend"], default: 1) == 1 else {
            throw Self.invalid("hidden, additive, partial and automatic blend layers are not implemented")
        }
        guard let rawID = layer["animation"] as? NSNumber, CFGetTypeID(rawID) != CFBooleanGetTypeID(),
              let id = UInt64(exactly: rawID.doubleValue), let clip = model.clips.first(where: { $0.id == id }) else {
            throw Self.invalid("authored animation id does not identify a clip")
        }
        let rate = try Self.number(layer["rate"], default: 1)
        guard rate.isFinite, rate > 0, rate <= 100, clip.mode.lowercased() == "loop",
              clip.tracks.count == model.bones.count,
              clip.tracks.allSatisfy({ $0.count == clip.frameCount + 1 }) else {
            throw Self.invalid("only a positive-rate loop with complete bone tracks is supported")
        }
        var world: [simd_float4x4] = [], inverse: [simd_float4x4] = []
        for bone in model.bones {
            let m = bone.parent < 0 ? bone.localBind : world[bone.parent] * bone.localBind
            let precise = simd_double4x4((0..<4).map { SIMD4<Double>(m[$0]) })
            let determinant = simd_determinant(precise)
            guard determinant.isFinite, determinant != 0 else { throw Self.invalid("bind matrix is singular") }
            let inv = simd_inverse(precise)
            let converted = simd_float4x4((0..<4).map { SIMD4<Float>(inv[$0]) })
            guard Self.finite(m), Self.finite(converted) else { throw Self.invalid("non-finite bind matrix") }
            world.append(m); inverse.append(converted)
        }
        self.model = model; self.clip = clip; self.rate = rate; self.inverseBind = inverse
    }

    func sample(at time: Double) throws -> Sample {
        guard time.isFinite, time >= 0 else { throw Self.invalid("invalid scene clock") }
        let duration = Double(clip.frameCount) / Double(clip.fps)
        let elapsed = (time * rate).truncatingRemainder(dividingBy: duration)
        guard elapsed.isFinite else { throw Self.invalid("clock overflow") }
        let framePosition = elapsed * Double(clip.fps)
        let frame = min(clip.frameCount - 1, Int(framePosition.rounded(.down)))
        let fraction = Float(framePosition - Double(frame))
        var local: [simd_float4x4] = [], world: [simd_float4x4] = [], palette: [simd_float4x4] = []
        local.reserveCapacity(model.bones.count); world.reserveCapacity(model.bones.count); palette.reserveCapacity(model.bones.count)
        for (index, bone) in model.bones.enumerated() {
            let first = clip.tracks[index][frame], second = clip.tracks[index][frame + 1]
            let position = first.position * (1 - fraction) + second.position * fraction
            let scale = first.scale * (1 - fraction) + second.scale * fraction
            var next = second.rotation.vector
            if simd_dot(first.rotation.vector, next) < 0 { next = -next }
            let combined = first.rotation.vector * (1 - fraction) + next * fraction
            let norm = simd_length(combined)
            guard norm.isFinite, norm > 0 else { throw Self.invalid("invalid interpolated quaternion") }
            let rotation = simd_quatf(vector: combined / norm)
            var matrix = simd_float4x4(rotation)
            matrix.columns.0 *= scale.x; matrix.columns.1 *= scale.y; matrix.columns.2 *= scale.z
            matrix.columns.3 = SIMD4(position, 1)
            let parent = bone.parent < 0 ? matrix : world[bone.parent] * matrix
            let skin = parent * inverseBind[index]
            guard Self.finite(matrix), Self.finite(parent), Self.finite(skin) else { throw Self.invalid("non-finite sampled pose") }
            local.append(matrix); world.append(parent); palette.append(skin)
        }
        return Sample(frame: frame, fraction: fraction, local: local, palette: palette)
    }

    /// CPU position skinning for the simple image shader. Normals and tangent
    /// attributes remain authored; lit 3D and morph shaders require more work.
    func imageVertices(shape: NativePuppetModel.Shape, at time: Double) throws -> [Float] {
        let sampled = try sample(at: time)
        lastSceneTime = time; lastFrame = sampled.frame; lastFraction = sampled.fraction; updates += 1
        var output: [Float] = []; output.reserveCapacity(shape.vertices.count / 20 * 12)
        for base in stride(from: 0, to: shape.vertices.count, by: 20) {
            let point = SIMD4(shape.vertices[base], shape.vertices[base+1], shape.vertices[base+2], Float(1))
            var transformed = SIMD4<Float>.zero
            for slot in 0..<4 {
                let weight = shape.vertices[base + 14 + slot]
                if weight == 0 { continue }
                let index = Int(shape.vertices[base + 10 + slot])
                guard sampled.palette.indices.contains(index) else { throw Self.invalid("joint index is out of range") }
                transformed += (sampled.palette[index] * point) * weight
            }
            guard transformed.x.isFinite, transformed.y.isFinite, transformed.z.isFinite else { throw Self.invalid("non-finite skinned vertex") }
            output.append(contentsOf: [transformed.x, transformed.y, transformed.z])
            output.append(contentsOf: shape.vertices[(base+3)..<(base+10)])
            output.append(contentsOf: shape.vertices[(base+18)..<(base+20)])
        }
        return output
    }

    private static func boolean(_ raw: Any?, default fallback: Bool) throws -> Bool {
        guard let raw else { return fallback }
        guard let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("expected a boolean layer property") }
        return number.boolValue
    }
    private static func number(_ raw: Any?, default fallback: Double) throws -> Double {
        guard let raw else { return fallback }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
            throw invalid("expected a finite numeric layer property")
        }
        return number.doubleValue
    }
    private static func finite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { col in (0..<4).allSatisfy { matrix[col][$0].isFinite } }
    }
}
