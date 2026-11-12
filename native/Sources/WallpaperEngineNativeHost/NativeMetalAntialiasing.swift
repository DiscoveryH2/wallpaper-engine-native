import Metal

/// Keep per-sample color/depth across draw encoders. Each encoder resolves for
/// consumers (effects, volume light and history) while preserving its samples.
@MainActor
final class NativeMetalAntialiasing {
    private(set) var color: MTLTexture?
    private(set) var depth: MTLTexture?
    private(set) var bytes = 0
    private(set) var generation = 0
    let samples: Int
    init(samples: Int) { self.samples = samples }

    func prepare(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat, withDepth: Bool) throws {
        guard samples > 1 else { return }
        guard device.supportsTextureSampleCount(samples), [.bgra8Unorm, .rgba16Float].contains(format) else {
            throw SceneError.invalid("当前 Metal 设备不支持 MSAA x\(samples)。")
        }
        if let color, color.width == width, color.height == height, color.pixelFormat == format, (depth != nil) == withDepth { return }
        let size = try NativeAntialiasing.bytes(width: width, height: height, samples: samples, hdr: format == .rgba16Float, depth: withDepth)
        func make(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.textureType = .type2DMultisample; descriptor.sampleCount = samples
            descriptor.storageMode = .private; descriptor.usage = .renderTarget
            guard let result = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 抗锯齿缓冲。") }
            result.label = "Native scene MSAA x\(samples)"
            return result
        }
        let nextColor = try make(format), nextDepth = try withDepth ? make(.depth32Float) : nil
        color = nextColor; depth = nextDepth; bytes = size; generation += 1
    }

    func attach(to pass: MTLRenderPassDescriptor, color resolvedColor: MTLTexture, depth resolvedDepth: MTLTexture?) {
        guard samples > 1 else { return }
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = resolvedColor
        pass.colorAttachments[0].storeAction = .storeAndMultisampleResolve
        if let depth, let resolvedDepth {
            pass.depthAttachment.texture = depth; pass.depthAttachment.resolveTexture = resolvedDepth
            pass.depthAttachment.storeAction = .storeAndMultisampleResolve
            // A deterministic sample, not an average of unrelated surfaces.
            pass.depthAttachment.depthResolveFilter = .sample0
        }
    }

    /// Reconstitute all color samples after a single-sample operation; retain
    /// per-sample depth unless restoring the previous scene's resolved history.
    func seed(color source: MTLTexture, depth sourceDepth: MTLTexture?, command: MTLCommandBuffer,
              colorPipeline: MTLRenderPipelineState, depthPipeline: MTLRenderPipelineState,
              depthWrite: MTLDepthStencilState) throws {
        guard samples > 1, let color else { return }
        let pass = NativeMetalEffects.renderPass(color)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法恢复抗锯齿颜色缓冲。") }
        encoder.setRenderPipelineState(colorPipeline); encoder.setCullMode(.none)
        encoder.setFragmentTexture(source, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6); encoder.endEncoding()
        if let sourceDepth, let depth {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = .dontCare; pass.depthAttachment.storeAction = .store
            guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法恢复抗锯齿深度缓冲。") }
            encoder.setRenderPipelineState(depthPipeline); encoder.setDepthStencilState(depthWrite); encoder.setCullMode(.none)
            encoder.setFragmentTexture(sourceDepth, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6); encoder.endEncoding()
        }
    }

    static let shader = """
    fragment float4 msaaSeedColor(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
        return source.read(uint2(in.position.xy));
    }
    fragment SceneHistoryDepthOut msaaSeedDepth(VertexOut in [[stage_in]], depth2d<float> source [[texture(0)]]) {
        return {source.read(uint2(in.position.xy))};
    }
    """
}
