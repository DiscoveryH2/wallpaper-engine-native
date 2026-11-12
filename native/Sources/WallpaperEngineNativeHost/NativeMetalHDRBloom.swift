import Foundation
import Metal
import simd

@MainActor
final class NativeMetalHDRBloom {
    struct Targets {
        let scene: MTLTexture
        let levels: [MTLTexture]
        let plan: NativeHDRBloomPlan
        var bytes: Int { scene.width * scene.height * 8 + plan.bytes }
    }
    private struct Uniforms {
        var blend: SIMD4<Float>
        var parameters: SIMD4<Float>
        var tint: SIMD4<Float>
        var operation: SIMD4<UInt32>
    }
    private let device: MTLDevice
    private let filter: MTLRenderPipelineState, additive: MTLRenderPipelineState, presentation: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var targets: Targets?
    private var generation: UInt64 = 0, frames: UInt64 = 0
    private(set) var diagnostics: [String] = []

    init(device: MTLDevice, filter: MTLRenderPipelineState, additive: MTLRenderPipelineState,
         presentation: MTLRenderPipelineState, sampler: MTLSamplerState) {
        self.device = device; self.filter = filter; self.additive = additive
        self.presentation = presentation; self.sampler = sampler
    }

    func prepare(width: Int, height: Int) throws -> Targets {
        guard (1...16384).contains(width), (1...16384).contains(height) else { throw SceneError.invalid("Metal HDR 输出尺寸无效。") }
        let scale = min(1, 4096 / Double(max(width, height)))
        let w = max(2, Int(Double(width)*scale)), h = max(2, Int(Double(height)*scale))
        if let targets, targets.scene.width == w, targets.scene.height == h { return targets }
        let plan = NativeHDRBloomPlan(width: w, height: h)
        guard w*h*8 + plan.bytes <= 192*1024*1024 else { throw SceneError.invalid("Metal HDR 场景与泛光缓冲超过 192 MiB。") }
        func texture(width: Int, height: Int, label: String) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let image = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal HDR 缓冲。") }
            image.label = label; return image
        }
        let prepared = try Targets(scene: texture(width: w, height: h, label: "HDR Scene"),
            levels: plan.sizes.enumerated().map { try texture(width: $0.element.x, height: $0.element.y, label: "HDR level \($0.offset)") }, plan: plan)
        targets = prepared; generation &+= 1
        return prepared
    }

    func encode(_ targets: Targets, enabled: Bool, parameters: NativeHDRBloomParameters, output: MTLTexture,
                command: MTLCommandBuffer, time: Double) throws {
        let p = parameters.resolve(available: targets.levels.count)
        let active = enabled && p != nil
        if active, let p {
            for index in 0..<p.levels {
                try draw(command, source: index == 0 ? targets.scene : targets.levels[index-1], second: targets.scene,
                    target: targets.levels[index], operation: index == 0 ? 0 : 1,
                    step: targets.plan.step(sourceIndex: index), parameters: p)
            }
            if p.levels > 1 {
                for index in stride(from: p.levels-1, through: 1, by: -1) {
                    try draw(command, source: targets.levels[index], second: targets.scene, target: targets.levels[index-1],
                        operation: targets.plan.bicubic(sourceIndex: index, levels: p.levels) ? 3 : 2,
                        step: targets.plan.step(sourceIndex: index), parameters: p)
                }
            }
        }
        try draw(command, source: targets.scene, second: active ? targets.levels[0] : targets.scene, target: output,
            operation: active ? 4 : 5, step: targets.plan.step(sourceIndex: 0), parameters: p)
        frames &+= 1
        var note = "Metal HDR 最近编码：时间 \(String(format: "%.6f", time)) 秒；"
        note += active ? "泛光 \(p!.levels)/\(targets.levels.count) 级，强度 \(parameters.strength) → 提取 \(p!.strength)，阈值 \(parameters.threshold)，柔化 \(parameters.feather)，散射 \(parameters.scatter)，颜色 \(parameters.tint)；" : (enabled ? "参数无效，本帧停用泛光；" : "作者关闭泛光；")
        note += "RGBA16F 场景 \(targets.scene.width)×\(targets.scene.height)，总缓冲 \(targets.bytes) 字节，代次 \(generation)，累计 \(frames) 帧。逐级缩小与加法回升，末两次回升双三次采样；最终 SDR 输出。GPU 完成由视图帧数单独报告。"
        diagnostics = [note]
    }

    private func draw(_ command: MTLCommandBuffer, source: MTLTexture, second: MTLTexture, target: MTLTexture,
                      operation: UInt32, step: SIMD2<Float>, parameters: NativeHDRBloomParameters.Resolved?) throws {
        guard source !== target, second !== target else { throw SceneError.invalid("Metal HDR 缓冲发生读写冲突。") }
        let upsample = operation == 2 || operation == 3
        let pass = NativeMetalEffects.renderPass(target)
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        if upsample { pass.colorAttachments[0].loadAction = .load }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法开始 Metal HDR 阶段。") }
        defer { encoder.endEncoding() }
        encoder.label = "HDR stage \(operation) \(target.width)x\(target.height)"
        encoder.setRenderPipelineState(operation >= 4 ? presentation : (upsample ? additive : filter))
        encoder.setCullMode(.none)
        var uniforms = Uniforms(blend: parameters?.blend ?? .zero,
            parameters: SIMD4(parameters?.strength ?? 0, parameters?.scatter ?? 0, step.x, step.y),
            tint: SIMD4(parameters?.tint ?? .zero, 1), operation: SIMD4(operation, 0, 0, 0))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(source, index: 0); encoder.setFragmentTexture(second, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    static let shader = """
    struct HDRUniforms { float4 blend; float4 parameters; float4 tint; uint4 operation; };
    float4 hdrWeights(float f) {
        float a=1-f, b=f*f, c=b*f;
        return float4(a*a*a,4-6*b+3*c,1+3*f+3*b-3*c,c)/6;
    }
    float3 hdrCubic(texture2d<float> source, sampler s, float2 uv, float2 step) {
        float2 inverseSize=2*step, pixel=uv/inverseSize-.5, f=fract(pixel);
        pixel=floor(pixel);
        float4 wx=hdrWeights(f.x), wy=hdrWeights(f.y);
        float2 sx=float2(wx.x+wx.y,wx.z+wx.w), sy=float2(wy.x+wy.y,wy.z+wy.w);
        float2 x=(pixel.x+float2(-.5,1.5)+float2(wx.y,wx.w)/sx)*inverseSize.x;
        float2 y=(pixel.y+float2(-.5,1.5)+float2(wy.y,wy.w)/sy)*inverseSize.y;
        float3 low=mix(source.sample(s,float2(x.x,y.x)).rgb,source.sample(s,float2(x.y,y.x)).rgb,sx.y);
        float3 high=mix(source.sample(s,float2(x.x,y.y)).rgb,source.sample(s,float2(x.y,y.y)).rgb,sx.y);
        return mix(low,high,sy.y);
    }
    fragment float4 hdrFragment(VertexOut in [[stage_in]], constant HDRUniforms &u [[buffer(0)]],
        texture2d<float> source [[texture(0)]], texture2d<float> bloom [[texture(1)]], sampler s [[sampler(0)]]) {
        uint operation=u.operation.x;
        if(operation==5) return float4(clamp(source.sample(s,in.uv).rgb,0.0,1.0),1);
        float3 color=0;
        for(int y=-1;y<=1;y+=2) for(int x=-1;x<=1;x+=2) {
            float2 uv=in.uv+float2(x,y)*u.parameters.zw;
            color+=(operation==4 ? bloom.sample(s,uv).rgb : (operation==3 ? hdrCubic(source,s,uv,u.parameters.zw) : source.sample(s,uv).rgb))*.25;
        }
        if(operation==4) return float4(clamp(source.sample(s,in.uv).rgb+color,0.0,1.0),1);
        if(operation==0) {
            color=max(color,float3(0));
            float peak=max(color.r,max(color.g,color.b));
            float soft=clamp(peak-u.blend.y,0.0,u.blend.z);
            float gain=max(soft*soft*u.blend.w,peak-u.blend.x)/max(peak,.00001);
            color*=gain*u.parameters.x*u.tint.rgb;
        } else if(operation>=2) color*=u.parameters.y;
        return float4(clamp(color,0.0,65504.0),1);
    }
    """
}
