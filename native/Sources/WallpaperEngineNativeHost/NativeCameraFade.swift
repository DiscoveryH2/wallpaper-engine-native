import Foundation
import Metal
import simd

/// Final presentation overlay recovered from Scene::GetFadeAmount and the
/// official fade material. Its clock belongs to legacy camera.paths, including
/// when a modern Camera temporarily suspends that clock. It is not a new timer.
struct NativeCameraFade {
    let color: SIMD3<Float>
    let amount: Float
    var uniform: SIMD4<Float> { SIMD4(color, amount) }

    init(enabled: Bool, amount: Float, tint: SIMD3<Float>) {
        self.amount = enabled && amount.isFinite ? max(0, min(1, amount)) : 0
        color = tint * 0.7
    }

    static func tint(properties: [String: Any]) -> SIMD3<Float> {
        let raw = properties["schemecolor"]
        let value = SceneValues.vector((raw as? [String: Any])?["value"] ?? raw, SIMD3(0.315, 0.135, 0.1125))
        return value.x.isFinite && value.y.isFinite && value.z.isFinite ? value : SIMD3(0.315, 0.135, 0.1125)
    }

    static func opacity(time: Float, duration: Float) -> Float {
        guard time.isFinite, time >= 0, duration.isFinite, duration > 0 else { return 0 }
        // Keep the reference's Float subtraction and branch order. For paths
        // shorter than one second, the ending half-second takes precedence.
        let remaining = duration - time
        guard remaining < 0.5 || remaining > duration - 0.5 else { return 0 }
        let edgeTime = remaining < 0.5 ? remaining : duration - remaining
        return max(0, min(1, 1 - (edgeTime + edgeTime)))
    }

    var diagnostic: String {
        "相机路径淡入淡出：叠加不透明度 \(String(format: "%.6f", amount))，目标 RGB=(\(color.x), \(color.y), \(color.z))；使用旧版路径更新后的时钟，在泛光和残影捕获之后合成。"
    }
}

@MainActor
enum NativeMetalCameraFade {
    static func pipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Native camera path fade"
        descriptor.vertexFunction = library.makeFunction(name: "cameraFadeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cameraFadeFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.rgbBlendOperation = .add
        color.sourceRGBBlendFactor = .sourceAlpha
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.alphaBlendOperation = .add
        color.sourceAlphaBlendFactor = .zero
        color.destinationAlphaBlendFactor = .one
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    static func encode(_ fade: NativeCameraFade, target: MTLTexture, command: MTLCommandBuffer, pipeline: MTLRenderPipelineState) throws {
        guard fade.amount > 0 else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法合成相机路径淡入淡出。") }
        defer { encoder.endEncoding() }
        encoder.label = "Camera fade after scene presentation"
        encoder.setRenderPipelineState(pipeline); encoder.setCullMode(.none)
        var value = fade.uniform
        encoder.setFragmentBytes(&value, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    static let shader = """
    vertex float4 cameraFadeVertex(uint index [[vertex_id]]) {
        float2 corner = index == 0 ? float2(-1, -1) : index == 1 ? float2(3, -1) : float2(-1, 3);
        return float4(corner, 0, 1);
    }
    fragment float4 cameraFadeFragment(constant float4 &overlay [[buffer(0)]]) { return overlay; }
    """
}
