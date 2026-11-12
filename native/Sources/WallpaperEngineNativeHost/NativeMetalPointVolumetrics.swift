import Foundation
import Metal
import simd

/// Owned quality-dependent point-light integration. Scene depth is sampled only after
/// its render encoder has ended, then retained for later particle/overlay draws.
/// This shares the native OpenGL contract, not a Windows pixel-parity claim.
@MainActor
final class NativeMetalPointVolumetrics {
    struct Uniforms {
        var inverseVP: simd_float4x4
        var eyeFog: SIMD4<Float>, fog: SIMD4<Float>, originRadius: SIMD4<Float>
        var radianceDensity: SIMD4<Float>, shadow: SIMD4<Float>, shadowScale: SIMD4<Float>, parameters: SIMD4<Float>
    }
    struct Pipelines {
        let integrate: [MTLPixelFormat: MTLRenderPipelineState]
        let combine: [MTLPixelFormat: MTLRenderPipelineState]
        let blur: [MTLPixelFormat: MTLRenderPipelineState]
        init(device: MTLDevice, library: MTLLibrary) throws {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "pointVolumeVertex")
            let color = descriptor.colorAttachments[0]!
            color.isBlendingEnabled = true; color.writeMask = [.red, .green, .blue]
            color.rgbBlendOperation = .add; color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .zero; color.destinationAlphaBlendFactor = .one
            var integration: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            var composition: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            var filtering: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            for format in [MTLPixelFormat.bgra8Unorm, .rgba16Float] {
                color.pixelFormat = format
                color.isBlendingEnabled = true
                descriptor.fragmentFunction = library.makeFunction(name: "pointVolumeFragment")
                integration[format] = try device.makeRenderPipelineState(descriptor: descriptor)
                descriptor.fragmentFunction = library.makeFunction(name: "pointVolumeCombine")
                composition[format] = try device.makeRenderPipelineState(descriptor: descriptor)
                color.isBlendingEnabled = false
                descriptor.fragmentFunction = library.makeFunction(name: "pointVolumeBlur")
                filtering[format] = try device.makeRenderPipelineState(descriptor: descriptor)
            }
            integrate = integration; combine = composition; blur = filtering
        }
    }
    private let device: MTLDevice, pipelines: Pipelines, depthDisabled: MTLDepthStencilState
    private(set) var texture: MTLTexture?
    private var blurTexture: MTLTexture?
    private var quality: NativeVolumetricQuality = .high
    private var lastBlurPasses = 0
    private var lastCommand: MTLCommandBuffer?
    private var lastTime: Double = 0
    private var frames = 0, allocations = 0, lights = 0, shadowed = 0, inside = 0
    private var sceneSize = SIMD2<Int>.zero
    private var parameters: [[Float]] = []

    init(device: MTLDevice, pipelines: Pipelines, depthDisabled: MTLDepthStencilState) {
        self.device = device; self.pipelines = pipelines; self.depthDisabled = depthDisabled
    }

    func deactivate(time: Double, quality: NativeVolumetricQuality = .high) {
        texture = nil; lastCommand = nil; lastTime = time; lights = 0; shadowed = 0; inside = 0
        blurTexture = nil; self.quality = quality; lastBlurPasses = 0
        parameters = []; sceneSize = .zero
    }

    func encode(target: MTLTexture, sceneDepth: MTLTexture, lighting: NativeModelLightFrame,
                shadows: NativeMetalPointShadows.Frame, viewProjection: simd_float4x4,
                eye: SIMD3<Float>, time: Double, command: MTLCommandBuffer, quality: NativeVolumetricQuality = .high) throws {
        let selected = lighting.lights.enumerated().filter { $0.element.volumetrics != nil }
        guard quality != .disabled, !selected.isEmpty else { deactivate(time: time, quality: quality); return }
        let inverse = simd_inverse(viewProjection)
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { inverse[c][$0].isFinite } }),
              [eye.x, eye.y, eye.z].allSatisfy(\.isFinite),
              sceneDepth.width == target.width, sceneDepth.height == target.height,
              sceneDepth.pixelFormat == .depth32Float, sceneDepth.usage.contains(.shaderRead),
              selected.count <= NativeModelLightFrame.maximumLights, shadows.bindings.count == lighting.lights.count,
              let integrate = pipelines.integrate[target.pixelFormat], let combine = pipelines.combine[target.pixelFormat] else {
            throw SceneError.invalid("Metal 点光源体积光的相机、深度或灯光输入无效。")
        }
        let width = max(1, target.width / quality.divisor), height = max(1, target.height / quality.divisor)
        guard width * height <= 4 * 1024 * 1024 else { throw SceneError.invalid("Metal 体积光缓冲超过 4M 像素。") }
        if texture?.width != width || texture?.height != height || texture?.pixelFormat != target.pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let next = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 体积光缓冲。") }
            next.label = "Point volumetrics: quality-dependent additive light"
            texture = next; allocations += 1
        }
        if quality.blurPasses == 0 { blurTexture = nil }
        else if blurTexture?.width != width || blurTexture?.height != height || blurTexture?.pixelFormat != target.pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let next = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 体积光模糊缓冲。") }
            next.label = "Point volumetrics: separable blur scratch"; blurTexture = next; allocations += 1
        }
        guard let texture else { throw SceneError.invalid("Metal 体积光缓冲缺失。") }
        let pass = NativeMetalEffects.renderPass(texture)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法开始 Metal 体积光积分。") }
        encoder.label = "Point volumes after opaque models"
        encoder.setRenderPipelineState(integrate); encoder.setDepthStencilState(depthDisabled); encoder.setCullMode(.none)
        encoder.setFragmentTexture(sceneDepth, index: 0); encoder.setFragmentTexture(shadows.texture, index: 1)
        var shadowCount = 0, insideCount = 0, observed: [[Float]] = []
        for entry in selected {
            let light = entry.element, volume = light.volumetrics!, binding = shadows.bindings[entry.offset]
            var uniforms = Uniforms(inverseVP: inverse, eyeFog: SIMD4(eye, lighting.fogEnabled ? 1 : 0),
                fog: lighting.fogParams, originRadius: light.positionRadius,
                radianceDensity: SIMD4(light.colorExponent.x, light.colorExponent.y, light.colorExponent.z, volume.x),
                shadow: binding, shadowScale: shadows.scale,
                parameters: SIMD4(volume.y, Float(quality.shadowedSamples), Float(quality.unshadowedSamples), 0))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            if binding.x >= 1 { shadowCount += 1 }
            if simd_length(eye - SIMD3(light.positionRadius.x, light.positionRadius.y, light.positionRadius.z)) < light.positionRadius.w { insideCount += 1 }
            observed.append([volume.x, volume.y])
        }
        encoder.endEncoding()
        lastBlurPasses = 0
        if let blurTexture, let pipeline = pipelines.blur[target.pixelFormat] {
            for vertical in [false, true] {
                let input = vertical ? blurTexture : texture, output = vertical ? texture : blurTexture
                let pass = NativeMetalEffects.renderPass(output)
                guard let filter = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法开始 Metal 体积光模糊。") }
                filter.label = vertical ? "Volume blur vertical" : "Volume blur horizontal"
                filter.setRenderPipelineState(pipeline); filter.setDepthStencilState(depthDisabled); filter.setCullMode(.none)
                filter.setFragmentTexture(input, index: 0)
                var step = SIMD2<Float>(vertical ? 0 : 1 / Float(width), vertical ? 1 / Float(height) : 0)
                filter.setFragmentBytes(&step, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
                filter.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); filter.endEncoding(); lastBlurPasses += 1
            }
        }
        let compositePass = NativeMetalEffects.renderPass(target)
        compositePass.colorAttachments[0].loadAction = .load
        guard let composite = command.makeRenderCommandEncoder(descriptor: compositePass) else { throw SceneError.invalid("无法合成 Metal 体积光。") }
        composite.label = "Add point volumes before later layers and scene history"
        composite.setRenderPipelineState(combine); composite.setDepthStencilState(depthDisabled); composite.setCullMode(.none)
        composite.setFragmentTexture(texture, index: 0)
        composite.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); composite.endEncoding()
        self.quality = quality; lastCommand = command; lastTime = time; frames += 1; lights = selected.count
        shadowed = shadowCount; inside = insideCount; parameters = observed
        sceneSize = SIMD2(target.width, target.height)
    }

    var snapshot: [String: Any] {
        ["allocated": texture != nil, "width": texture?.width ?? 0, "height": texture?.height ?? 0,
         "sceneWidth": sceneSize.x, "sceneHeight": sceneSize.y, "allocations": allocations,
         "hdr": texture?.pixelFormat == .rgba16Float, "time": lastTime, "encodedFrames": frames,
         "lights": lights, "shadowedLights": shadowed, "cameraInsideLights": inside, "parameters": parameters,
         "quality": quality.rawValue, "shadowedSamples": quality.shadowedSamples, "unshadowedSamples": quality.unshadowedSamples,
         "blurPasses": lastBlurPasses, "blurAllocated": blurTexture != nil,
         "lastFrameCompleted": lastCommand?.status == .completed, "lastFrameFailed": lastCommand?.status == .error,
         "lastFrameError": lastCommand?.error?.localizedDescription ?? ""]
    }
    var diagnostic: String {
        "Metal 点光源体积光：场景时间 \(String(format: "%.6f", lastTime)) 秒；\(lights) 盏 / 阴影 \(shadowed) 盏 / 相机在球内 \(inside) 盏；深度 \(sceneSize.x)×\(sceneSize.y)，光照缓冲 \(texture?.width ?? 0)×\(texture?.height ?? 0) \(texture?.pixelFormat == .rgba16Float ? "RGBA16F" : "BGRA8")，累计分配 \(allocations) 次；已编码 \(frames) 帧，最近 GPU 完成=\(lastCommand?.status == .completed)。品质 \(quality.title)，阴影 \(quality.shadowedSamples) / 无阴影 \(quality.unshadowedSamples) 次采样，模糊 \(lastBlurPasses) 次；模型后、粒子与全局泛光前加法合成。解析球体边界、距离雾已接入；透明模型交错、高度雾和聚光灯体积光仍待实现。"
    }

    static let shader = """
    struct PointVolumeUniforms {
        float4x4 inverseVP;
        float4 eyeFog, fog, originRadius, radianceDensity, shadow, shadowScale, parameters;
    };
    struct PointVolumeVertex { float4 position [[position]]; float2 uv; };
    vertex PointVolumeVertex pointVolumeVertex(uint id [[vertex_id]]) {
        constexpr float2 positions[] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
        float2 p = positions[id];
        return {float4(p,0,1),float2(p.x*.5+.5,.5-p.y*.5)};
    }
    float3 pointVolumeWorld(float2 uv, float depth, constant PointVolumeUniforms &u) {
        // The camera matrix retains GL clip Z. Metal stored depth is [0,1]
        // and texture UV runs downwards; invert both conversions here only.
        float4 world = u.inverseVP * float4(uv.x*2-1,1-uv.y*2,depth*2-1,1);
        return world.xyz/world.w;
    }
    float pointVolumeJitter(float2 uv) {
        float3 state = fract(float3(uv.x,uv.y,uv.x)*43758.5453);
        state += dot(state,state.yzx+19.19);
        return fract((state.x+state.y)*state.z);
    }
    fragment float4 pointVolumeFragment(PointVolumeVertex in [[stage_in]], constant PointVolumeUniforms &u [[buffer(0)]],
        depth2d<float> sceneDepth [[texture(0)]], depth2d<float> shadows [[texture(1)]]) {
        constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
        constexpr sampler comparison(coord::normalized,address::clamp_to_edge,filter::linear,compare_func::less_equal);
        float3 nearPoint = pointVolumeWorld(in.uv,0,u);
        float3 segment = pointVolumeWorld(in.uv,sceneDepth.sample(nearest,in.uv),u)-nearPoint;
        float sceneLength = length(segment);
        if (!isfinite(sceneLength) || sceneLength <= .000001) return 0;
        float3 direction = segment/sceneLength, offset = nearPoint-u.originRadius.xyz;
        float projection = dot(offset,direction);
        float discriminant = projection*projection-dot(offset,offset)+u.originRadius.w*u.originRadius.w;
        if (discriminant <= 0) return 0;
        float root = sqrt(discriminant), start = max(0.0,-projection-root);
        float interval = min(sceneLength,-projection+root)-start;
        if (interval <= 0) return 0;
        bool shadowed = u.shadow.x >= 1;
        uint steps = uint(shadowed ? u.parameters.y : u.parameters.z);
        float step = interval/float(steps+1), jitter = shadowed ? pointVolumeJitter(in.uv) : 0;
        float radius = u.originRadius.w*.99, total = 0;
        for (uint i=0;i<steps;++i) {
            float3 world = nearPoint+direction*(start+(float(i+1)+jitter)*step);
            float3 delta = world-u.originRadius.xyz;
            float contribution = pow(clamp(1-length(delta)/radius,0.0,1.0),u.parameters.x);
            if (shadowed) {
                float4 projected = pointShadowCoordinatesMetal(delta,u.shadow,u.shadowScale);
                if (projected.w > .5) contribution *= shadows.sample_compare(comparison,projected.xy,projected.z);
            }
            if (u.eyeFog.w > .5) {
                float fraction = clamp((length(world-u.eyeFog.xyz)-u.fog.x)/u.fog.y,0.0,1.0);
                float fog = clamp(u.fog.z+u.fog.w*fraction*fraction,0.0,1.0);
                contribution = contribution*contribution*(1-fog*fog);
            }
            total += contribution;
        }
        float scale = u.radianceDensity.w*interval/radius*.05/float(steps);
        return float4(u.radianceDensity.rgb*(total*scale),0);
    }
    fragment float4 pointVolumeCombine(PointVolumeVertex in [[stage_in]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
        return float4(image.sample(linear,in.uv).rgb,0);
    }
    fragment float4 pointVolumeBlur(PointVolumeVertex in [[stage_in]], constant float2 &step [[buffer(0)]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
        float3 color = image.sample(linear,in.uv).rgb * .5;
        color += image.sample(linear,in.uv+step).rgb * .25;
        color += image.sample(linear,in.uv-step).rgb * .25;
        return float4(color,0);
    }
    """
}
