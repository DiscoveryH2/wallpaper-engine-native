import Foundation
import Metal

/// A backdrop is captured only between render encoders. The drawable remains
/// framebuffer-only: scenes that need a backdrop use a private render target.
@MainActor
final class NativeMetalCompositing {
    private let device: MTLDevice
    private let presentation: MTLRenderPipelineState
    private var scene: MTLTexture?
    private var backdrop: MTLTexture?
    private var generation: UInt64 = 0
    private var captures = 0
    private var modes: [Int] = []
    private(set) var diagnostics: [String] = []

    init(device: MTLDevice, presentation: MTLRenderPipelineState) {
        self.device = device; self.presentation = presentation
    }

    private func bytes(_ texture: MTLTexture?) -> Int {
        guard let texture else { return 0 }
        return texture.width * texture.height * (texture.pixelFormat == .rgba16Float ? 8 : 4)
    }

    private func allocate(width: Int, height: Int, format: MTLPixelFormat, other: MTLTexture?, label: String) throws -> MTLTexture {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              [.bgra8Unorm, .rgba16Float].contains(format),
              width * height * (format == .rgba16Float ? 8 : 4) + bytes(other) <= 128 * 1024 * 1024 else {
            throw SceneError.invalid("Metal 图层合成目标超过尺寸或 128 MiB 缓冲限制。")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
        guard let image = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 图层合成目标。") }
        image.label = label; generation &+= 1
        return image
    }

    func beginFrame(externalScene: Bool) {
        captures = 0; modes.removeAll(keepingCapacity: true)
        // Bloom already owns the scene target. Submitted commands retain any
        // previous private target until the GPU is finished with it.
        if externalScene { scene = nil }
    }

    func sceneForPresentation(width: Int, height: Int) throws -> MTLTexture {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { throw SceneError.invalid("Metal 合成输出尺寸无效。") }
        let scale = min(1, 4096 / Double(max(width, height)))
        let w = max(1, Int(Double(width) * scale)), h = max(1, Int(Double(height) * scale))
        if let scene, scene.width == w, scene.height == h { return scene }
        let prepared = try allocate(width: w, height: h, format: .bgra8Unorm, other: backdrop, label: "Scene before color compositing presentation")
        scene = prepared
        return prepared
    }

    func capture(_ source: MTLTexture, command: MTLCommandBuffer, mode: Int) throws -> MTLTexture {
        guard !source.isFramebufferOnly else { throw SceneError.invalid("Metal 颜色合成需要可复制的私有场景目标。") }
        if backdrop?.width != source.width || backdrop?.height != source.height || backdrop?.pixelFormat != source.pixelFormat {
            backdrop = try allocate(width: source.width, height: source.height, format: source.pixelFormat, other: scene, label: "Scene before current image layer")
        }
        guard let backdrop, backdrop !== source, let encoder = command.makeBlitCommandEncoder() else {
            throw SceneError.invalid("无法复制 Metal 图层背景或目标发生读写冲突。")
        }
        encoder.label = "Snapshot before image color blend \(mode)"
        encoder.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: source.width, height: source.height, depth: 1), to: backdrop,
                     destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.endEncoding(); captures += 1; modes.append(mode)
        return backdrop
    }

    func present(_ input: MTLTexture, output: MTLTexture, command: MTLCommandBuffer) throws {
        guard input !== output, let encoder = command.makeRenderCommandEncoder(descriptor: NativeMetalEffects.renderPass(output)) else {
            throw SceneError.invalid("无法呈现 Metal 颜色合成场景。")
        }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(presentation); encoder.setCullMode(.none)
        encoder.setFragmentTexture(input, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    func endFrame(time: Double) {
        let size = backdrop.map { "\($0.width)×\($0.height) \($0.pixelFormat == .rgba16Float ? "RGBA16F" : "BGRA8")" } ?? "未分配"
        diagnostics = ["Metal 图层颜色合成：场景时间 \(String(format: "%.6f", time)) 秒；\(captures) 次独立背景复制，模式 \(modes)；背景 \(size)，私有缓冲 \(bytes(scene) + bytes(backdrop)) 字节，代次 \(generation)。每层先完成局部效果，再读取该层之前的场景；颜色合成不再重复 alpha-over。GPU 完成由视图帧数单独报告。"]
    }

    static let shader = """
    fragment float4 sceneCompositeFragment(VertexOut in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
                                           texture2d<float> image [[texture(0)]], texture2d<float> backdrop [[texture(1)]],
                                           sampler imageSampler [[sampler(0)]]) {
        float4 foreground = sceneSample(in, u, image, imageSampler);
        uint2 pixel = min(uint2(in.position.xy), uint2(backdrop.get_width()-1, backdrop.get_height()-1));
        float4 background = backdrop.read(pixel);
        return float4(nativeColorBlend(int(u.composite.x), background.rgb, foreground.rgb, foreground.a, u.composite.y != 0), background.a);
    }
    fragment float4 scenePresentFragment(VertexOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        return float4(image.sample(linearSampler, in.uv).rgb, 1);
    }
    """
}
