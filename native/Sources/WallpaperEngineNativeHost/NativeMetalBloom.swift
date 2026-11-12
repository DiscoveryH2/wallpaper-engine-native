import Foundation
import Metal
import simd

/// Whole-scene postprocessing. All resources are tracked device textures and
/// share the renderer's command queue; previous dimensions survive through any
/// already submitted commands that retain those resources.
@MainActor
final class NativeMetalBloom {
    struct Targets {
        let scene: MTLTexture
        let extraction: MTLTexture
        let horizontal: MTLTexture
        let vertical: MTLTexture
        let bytes: Int
    }
    private struct Uniforms {
        var parameters: SIMD4<Float>
        var tint: SIMD4<Float>
        var operation: SIMD4<UInt32>
    }
    private let device: MTLDevice
    private let intermediatePipeline: MTLRenderPipelineState
    private let presentationPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var targets: Targets?
    private var generation: UInt64 = 0, frames: UInt64 = 0
    private(set) var diagnostics: [String] = []

    init(device: MTLDevice, intermediate: MTLRenderPipelineState, presentation: MTLRenderPipelineState,
         sampler: MTLSamplerState) {
        self.device = device; intermediatePipeline = intermediate; presentationPipeline = presentation
        self.sampler = sampler
    }

    func prepare(width: Int, height: Int) throws -> Targets {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw SceneError.invalid("Metal 泛光输出尺寸无效。") }
        let scale = min(1, 4096 / Double(max(width, height)))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        if let targets, targets.scene.width == w, targets.scene.height == h { return targets }
        let sizes = [(w, h), (max(2, w / 4), max(2, h / 4)), (max(2, w / 8), max(2, h / 8))]
        let bytes = (sizes[0].0 * sizes[0].1 + sizes[1].0 * sizes[1].1 + 2 * sizes[2].0 * sizes[2].1) * 4
        guard bytes <= 80 * 1024 * 1024 else { throw SceneError.invalid("Metal 场景与泛光缓冲超过 80 MiB。") }
        func texture(_ size: (Int, Int), format: MTLPixelFormat, label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size.0, height: size.1, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let image = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 泛光缓冲。") }
            image.label = label; return image
        }
        let prepared = try Targets(scene: texture(sizes[0], format: .bgra8Unorm, label: "Scene before bloom"),
            extraction: texture(sizes[1], format: .rgba8Unorm, label: "Bloom quarter extraction"),
            horizontal: texture(sizes[2], format: .rgba8Unorm, label: "Bloom eighth horizontal"),
            vertical: texture(sizes[2], format: .rgba8Unorm, label: "Bloom eighth vertical"), bytes: bytes)
        // Publish only after every allocation succeeds.
        targets = prepared; generation &+= 1
        return prepared
    }

    func inactive(state: NativeSceneBloom, time: Double) {
        diagnostics = [state.enabled
            ? "Metal 普通泛光：场景时间 \(String(format: "%.6f", time)) 秒，参数或颜色乘数无法安全表示，本帧只显示原场景。"
            : "Metal 普通泛光：场景时间 \(String(format: "%.6f", time)) 秒，作者开关关闭，本帧直接绘制场景；保留缓冲 \(targets?.bytes ?? 0) 字节。"]
    }

    func encode(_ targets: Targets, parameters p: NativeBloomParameters, output: MTLTexture,
                command: MTLCommandBuffer, time: Double) throws {
        guard p.isFinite, time.isFinite, output.pixelFormat == .bgra8Unorm else { throw SceneError.invalid("Metal 泛光参数或输出无效。") }
        let width = Float(targets.scene.width), height = Float(targets.scene.height)
        try draw(command, input: targets.scene, second: targets.scene, target: targets.extraction, operation: 0,
                 step: SIMD2(1 / width, 1 / height), parameters: p)
        try draw(command, input: targets.extraction, second: targets.extraction, target: targets.horizontal, operation: 1,
                 step: SIMD2(8 / width, 0), parameters: p)
        try draw(command, input: targets.horizontal, second: targets.horizontal, target: targets.vertical, operation: 1,
                 step: SIMD2(0, 8 / height), parameters: p)
        try draw(command, input: targets.scene, second: targets.vertical, target: output, operation: 2,
                 step: .zero, parameters: p)
        frames &+= 1
        diagnostics = ["Metal 普通泛光最近编码：场景时间 \(String(format: "%.6f", time)) 秒，强度=\(p.strength)，阈值=\(p.threshold)，颜色=\(p.tint)；场景 \(targets.scene.width)×\(targets.scene.height)，提取 \(targets.extraction.width)×\(targets.extraction.height)，双向模糊 \(targets.vertical.width)×\(targets.vertical.height)，输出 \(output.width)×\(output.height)；4 个目标共 \(targets.bytes) 字节，代次 \(generation)，累计编码 \(frames) 帧。三步滤波后相加，强度仅用于提取；GPU 完成由视图帧数单独报告。"]
    }

    private func draw(_ command: MTLCommandBuffer, input: MTLTexture, second: MTLTexture, target: MTLTexture,
                      operation: UInt32, step: SIMD2<Float>, parameters p: NativeBloomParameters) throws {
        guard input !== target, second !== target else { throw SceneError.invalid("Metal 泛光目标发生读写冲突。") }
        let pass = NativeMetalEffects.renderPass(target)
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法开始 Metal 泛光阶段。") }
        defer { encoder.endEncoding() }
        encoder.label = "Scene bloom stage \(operation)"
        encoder.setRenderPipelineState(operation == 2 ? presentationPipeline : intermediatePipeline)
        encoder.setCullMode(.none)
        var uniforms = Uniforms(parameters: SIMD4(p.strength, p.threshold, step.x, step.y), tint: SIMD4(p.tint, 1),
                                operation: SIMD4(operation, 0, 0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(input, index: 0); encoder.setFragmentTexture(second, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // The same ordinary bloom equations as NativeStandardBloom, expressed in
    // independently maintained MSL. This is not the image-blur combine pass.
    static let shader = """
    struct BloomUniforms { float4 parameters; float4 tint; uint4 operation; };
    fragment float4 bloomFragment(VertexOut in [[stage_in]], constant BloomUniforms &u [[buffer(0)]],
        texture2d<float> source [[texture(0)]], texture2d<float> blurred [[texture(1)]], sampler s [[sampler(0)]]) {
        if (u.operation.x == 0) {
            float3 average = 0;
            for (int y = -1; y <= 1; y += 2) {
                for (int x = -1; x <= 1; x += 2) {
                    average += source.sample(s, in.uv + float2(x, y) * u.parameters.zw).rgb * .25;
                }
            }
            float maximum = max(average.r, max(average.g, average.b));
            float3 gated = average * clamp(maximum - u.parameters.y, 0.0, 1.0);
            float gray = dot(gated, float3(.2989, .5870, .1140));
            return float4(max(float3(0), (2 * gated - gray) * u.parameters.x * u.tint.rgb), 1);
        }
        if (u.operation.x == 1) {
            constexpr float weights[] = {.171834,.156756,.119007,.075189,.039533,.017298,.006299};
            float3 color = 0;
            for (int tap = -6; tap <= 6; ++tap) color += source.sample(s, in.uv + float(tap) * u.parameters.zw).rgb * weights[abs(tap)];
            return float4(color, 1);
        }
        return float4(source.sample(s, in.uv).rgb + blurred.sample(s, in.uv).rgb, 1);
    }
    """
}
