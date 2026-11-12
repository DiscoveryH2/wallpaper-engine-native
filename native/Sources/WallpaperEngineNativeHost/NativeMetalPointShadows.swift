import Foundation
import Metal
import simd

/// Six views per point light, using the shared authored-space projection.
/// The atlas belongs to one renderer and is cleared before every scene frame.
/// Shadow and color passes consume the same immutable bone-palette upload.
@MainActor
final class NativeMetalPointShadows {
    struct Uniforms { var matrix: simd_float4x4; var layout: SIMD4<UInt32> }
    struct Caster {
        let resource: NativeMetalModels.Resource
        let geometry: NativeMetalModels.Runtime.Geometry
        let model: simd_float4x4
        let bones: MTLBuffer
    }
    struct Frame {
        let texture: MTLTexture
        let bindings: [SIMD4<Float>]
        let scale: SIMD4<Float>
    }
    private let device: MTLDevice, pipeline: MTLRenderPipelineState, depth: MTLDepthStencilState
    private(set) var texture: MTLTexture?
    private var lastCommand: MTLCommandBuffer?
    private var lastTime: Double = 0
    private var lastBindings: [SIMD4<Float>] = []
    private var quality: NativeShadowQuality = .high
    private var atlas: NativeShadowAtlasLayout?
    private var frames = 0, allocations = 0, lights = 0, draws = 0, culled = 0, skipped = 0, faces = 0, spots = 0

    init(device: MTLDevice, pipeline: MTLRenderPipelineState, depth: MTLDepthStencilState) {
        self.device = device; self.pipeline = pipeline; self.depth = depth
    }

    func encode(lighting: NativeModelLightFrame, casters: [Caster], time: Double,
                command: MTLCommandBuffer, quality: NativeShadowQuality = .high) throws -> Frame {
        let selected = lighting.lights.enumerated().filter { quality != .disabled && $0.element.shadowNear != nil }
        guard selected.count <= NativePointShadows.maximumSlots else {
            throw SceneError.invalid("Metal 原生模型阴影超过 12 盏预算。")
        }
        let count = selected.count
        let atlas = try NativeShadowAtlasLayout(capacity: count, quality: quality)
        let size = atlas.faceSize, width = atlas.width, height = atlas.height
        if texture?.width != width || texture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let atlas = device.makeTexture(descriptor: descriptor) else {
                throw SceneError.invalid("无法分配 Metal 点光源阴影深度图。")
            }
            atlas.label = "Native point shadows: six views per light"
            texture = atlas; allocations += 1
        }
        guard let texture else { throw SceneError.invalid("Metal 点光源阴影深度图缺失。") }
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = texture; pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw SceneError.invalid("无法开始 Metal 点光源阴影绘制。")
        }
        defer { encoder.endEncoding() }
        encoder.label = "Point shadow atlas before scene color"
        encoder.setRenderPipelineState(pipeline); encoder.setDepthStencilState(depth)
        encoder.setFrontFacing(.counterClockwise)
        // Native policy, matching our OpenGL offset factors; not a recovered
        // Windows depth-format/bias equivalence claim.
        encoder.setDepthBias(1, slopeScale: 1, clamp: 0)
        var bindings = [SIMD4<Float>](repeating: .zero, count: lighting.lights.count)
        var submitted = 0, rejected = 0, nonOpaque = 0, views = 0, spotCount = 0
        for (slot, entry) in selected.enumerated() {
            let light = entry.element, near = light.shadowNear!
            let far = max(near + 0.01, light.positionRadius.w)
            guard near.isFinite, near >= 0.05, far.isFinite, far > near, light.positionRadius.w > 0 else {
                throw SceneError.invalid("Metal 点光源阴影近远裁剪面无效。")
            }
            bindings[entry.offset] = SIMD4(Float(slot + 1), near, far, light.spotShadow == nil ? 0 : 1)
            let position = SIMD3(light.positionRadius.x, light.positionRadius.y, light.positionRadius.z)
            let count = light.spotShadow == nil ? 6 : 1
            views += count; if count == 1 { spotCount += 1 }
            for face in 0..<count {
                let origin = atlas.origin(slot: slot, face: face), x = origin.x, y = origin.y
                encoder.setViewport(MTLViewport(originX: Double(x), originY: Double(y), width: Double(size), height: Double(size), znear: 0, zfar: 1))
                encoder.setScissorRect(MTLScissorRect(x: x, y: y, width: size, height: size))
                let projection = light.spotShadow?.viewProjection ?? NativePointShadows.viewProjection(position: position, face: face, near: near, far: far, focalScale: quality.focalScale)
                for caster in casters {
                    let matrix = projection * caster.model
                    guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }) else {
                        throw SceneError.invalid("Metal 阴影模型变换超出有限数值范围。")
                    }
                    for (index, mesh) in caster.geometry.meshes.enumerated() {
                        // A bind-pose box cannot conservatively bound an animated
                        // mesh. Until dynamic bounds exist, never cull skinned meshes.
                        if caster.geometry.boneCount == 0, mesh.bounds?.isOutside(matrix) == true { rejected += 1; continue }
                        var uniforms = Uniforms(matrix: matrix,
                            layout: SIMD4(UInt32(mesh.components), UInt32(caster.geometry.boneCount), 0, 0))
                        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 1)
                        encoder.setVertexBuffer(caster.bones, offset: 0, index: 2)
                        for material in caster.resource.materials[index] where material.visible {
                            guard material.blend == "normal" else { nonOpaque += 1; continue }
                            encoder.setCullMode(material.cull ? .back : .none)
                            encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32,
                                indexBuffer: mesh.indices, indexBufferOffset: 0)
                            submitted += 1
                        }
                    }
                }
            }
        }
        self.quality = quality; self.atlas = atlas
        lastTime = time; lastCommand = command; lastBindings = bindings; frames += 1
        lights = count; draws = submitted; culled = rejected; skipped = nonOpaque; faces = views; spots = spotCount
        return Frame(texture: texture, bindings: bindings,
            scale: atlas.scale(quality: quality))
    }

    var snapshot: [String: Any] {
        ["quality": quality.rawValue, "faceSize": atlas?.faceSize ?? 0, "filterTaps": quality.filterTaps, "columns": atlas?.columns ?? 0, "rows": atlas?.rows ?? 0, "allocated": texture != nil, "width": texture?.width ?? 0, "height": texture?.height ?? 0,
         "bytes": (texture?.width ?? 0) * (texture?.height ?? 0) * 4, "allocations": allocations,
         "time": lastTime, "encodedFrames": frames, "lights": lights, "faces": faces, "spotlights": spots,
         "draws": draws, "culled": culled, "nonOpaquePassesSkipped": skipped,
         "bindings": lastBindings.map { [$0.x, $0.y, $0.z, $0.w] },
         "lastFrameCompleted": lastCommand?.status == .completed,
         "lastFrameFailed": lastCommand?.status == .error,
         "lastFrameError": lastCommand?.error?.localizedDescription ?? ""]
    }
    var diagnostic: String {
        "Metal 原生模型阴影：场景时间 \(String(format: "%.6f", lastTime)) 秒；\(lights) 盏（聚光 \(spots)）/ \(faces) 个视图，Depth32Float \(texture?.width ?? 0)×\(texture?.height ?? 0)；\(draws) 次索引绘制，静态视锥剔除 \(culled)，跳过非不透明阶段 \(skipped)；已编码 \(frames) 帧，最近 GPU 完成=\(lastCommand?.status == .completed)。品质 \(quality.title)，每面 \(atlas?.faceSize ?? 0)，\(quality.filterTaps) 点 PCF、逐纹素接收面修正；原生偏移 1/1，未证明 Windows 像素一致性。"
    }

    static let shader = """
    struct PointShadowUniforms { float4x4 matrix; uint4 layout; };
    struct PointShadowVertex { float4 position [[position]]; };
    vertex PointShadowVertex pointShadowVertex(uint id [[vertex_id]], constant PointShadowUniforms &u [[buffer(0)]],
        const device float *vertices [[buffer(1)]], const device float4x4 *bones [[buffer(2)]]) {
        uint offset = id * u.layout.x;
        float4 local = float4(vertices[offset],vertices[offset+1],vertices[offset+2],1);
        if (u.layout.y > 0) {
            float4x4 skin = bones[uint(vertices[offset+10])] * vertices[offset+14]
                         + bones[uint(vertices[offset+11])] * vertices[offset+15]
                         + bones[uint(vertices[offset+12])] * vertices[offset+16]
                         + bones[uint(vertices[offset+13])] * vertices[offset+17];
            local = float4((skin * local).xyz,1);
        }
        float4 clip = u.matrix * local;
        clip.z = (clip.z + clip.w) * .5;
        return {clip};
    }
    float4 pointShadowCoordinatesMetal(float3 delta, float4 shadow, float4 scale) {
        float3 magnitude = abs(delta), projected;
        uint face;
        if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
            face = delta.x >= 0.0 ? 0 : 1;
            projected = float3(delta.x >= 0.0 ? delta.z : -delta.z,delta.y,magnitude.x);
        } else if (magnitude.y >= magnitude.z) {
            face = delta.y >= 0.0 ? 2 : 3;
            projected = float3(delta.x,delta.y >= 0.0 ? delta.z : -delta.z,magnitude.y);
        } else {
            face = delta.z >= 0.0 ? 4 : 5;
            projected = float3(delta.z >= 0.0 ? -delta.x : delta.x,delta.y,magnitude.z);
        }
        if (projected.z <= shadow.y || projected.z >= shadow.z) return float4(0);
        float slot = shadow.x - 1.0;
        float2 tile = float2(fmod(slot,scale.z)*2.0+float(face%2),floor(slot/scale.z)*3.0+float(face/2));
        float2 localUV = projected.xy/projected.z*(.5*scale.w)+.5;
        // Metal's viewport origin is at the top. Flip inside each face;
        // flipping the entire atlas would also reverse the face-row order.
        localUV.y = 1.0-localUV.y;
        float2 uv = (tile+localUV)/float2(scale.z*2.0,floor(scale.z*2.0*scale.x/scale.y+.5));
        float depth = shadow.z/(shadow.z-shadow.y)*(1.0-shadow.y/projected.z);
        return float4(uv,depth,1);
    }
    float2 pointShadowReceiverGradientMetal(float3 delta, float3 normal, float4 shadow, float4 scale) {
        float distance = dot(normal,delta);
        if (!(abs(distance) > .000001*length(normal)*max(length(delta),.000001))) return float2(0);
        float3 magnitude = abs(delta);
        float2 faceNormal;
        if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
            faceNormal = float2(delta.x >= 0.0 ? normal.z : -normal.z,normal.y);
        } else if (magnitude.y >= magnitude.z) {
            faceNormal = float2(normal.x,delta.y >= 0.0 ? normal.z : -normal.z);
        } else {
            faceNormal = float2(delta.z >= 0.0 ? -normal.x : normal.x,normal.y);
        }
        float factor = -2.0*shadow.z*shadow.y/((shadow.z-shadow.y)*scale.w*distance);
        // Match the per-face Metal viewport flip used by the coordinate lookup.
        return factor*faceNormal*float2(scale.z*2.0,-floor(scale.z*2.0*scale.x/scale.y+.5));
    }
    float pointShadowFlatVisibilityMetal(depth2d<float> atlas, float4 center, float2 texel) {
        constexpr sampler comparison(coord::normalized,address::clamp_to_edge,filter::linear,compare_func::less_equal);
        float2 axial=texel*1.02323,diagonal=texel*.81616;
        float value=atlas.sample_compare(comparison,center.xy,center.z);
        value+=atlas.sample_compare(comparison,center.xy+float2(axial.x,0),center.z);
        value+=atlas.sample_compare(comparison,center.xy-float2(axial.x,0),center.z);
        value+=atlas.sample_compare(comparison,center.xy+float2(0,axial.y),center.z);
        value+=atlas.sample_compare(comparison,center.xy-float2(0,axial.y),center.z);
        value+=atlas.sample_compare(comparison,center.xy+diagonal,center.z);
        value+=atlas.sample_compare(comparison,center.xy-diagonal,center.z);
        value+=atlas.sample_compare(comparison,center.xy+float2(diagonal.x,-diagonal.y),center.z);
        value+=atlas.sample_compare(comparison,center.xy+float2(-diagonal.x,diagonal.y),center.z);
        return value/9.0;
    }
    float pointShadowReceiverTapMetal(depth2d<float> atlas, float4 center, float2 offset, float2 gradient, float2 texel) {
        float2 position = (center.xy+offset)/texel-.5;
        float2 weight = fract(position), a = (floor(position)+.5)*texel;
        float2 b = a+float2(texel.x,0), c = a+float2(0,texel.y), d = a+texel;
        constexpr sampler comparison(coord::normalized,address::clamp_to_edge,filter::nearest,compare_func::less_equal);
        float va = atlas.sample_compare(comparison,a,clamp(center.z+dot(a-center.xy,gradient),0.0,1.0));
        float vb = atlas.sample_compare(comparison,b,clamp(center.z+dot(b-center.xy,gradient),0.0,1.0));
        float vc = atlas.sample_compare(comparison,c,clamp(center.z+dot(c-center.xy,gradient),0.0,1.0));
        float vd = atlas.sample_compare(comparison,d,clamp(center.z+dot(d-center.xy,gradient),0.0,1.0));
        return mix(mix(va,vb,weight.x),mix(vc,vd,weight.x),weight.y);
    }
    // A zero receiver normal denotes a point query with no surface plane.
    // Actual model fragments pass their rasterized geometric plane, independent
    // of smooth normals and normal maps. The atlas bias and PCF footprint stay
    // unchanged; the correction is per texel, not an extra blanket depth bias.
    float pointVisibilityMetal(float3 delta, float4 shadow, float4 scale, depth2d<float> atlas, float3 receiverNormal = float3(0), bool lowQuality = false) {
        if (shadow.x < 1.0) return 1.0;
        float4 c = pointShadowCoordinatesMetal(delta,shadow,scale);
        if (c.w < .5) return 1.0;
        float2 gradient = pointShadowReceiverGradientMetal(delta,receiverNormal,shadow,scale);
        if (lowQuality) return pointShadowReceiverTapMetal(atlas,c,float2(0),gradient,scale.xy);
        if (all(gradient == float2(0))) return pointShadowFlatVisibilityMetal(atlas,c,scale.xy);
        float2 crossOffset = scale.xy*1.02323, cornerOffset = scale.xy*.81616;
        float sum = pointShadowReceiverTapMetal(atlas,c,float2(0),gradient,scale.xy);
        sum += pointShadowReceiverTapMetal(atlas,c,float2(crossOffset.x,0),gradient,scale.xy);
        sum += pointShadowReceiverTapMetal(atlas,c,float2(-crossOffset.x,0),gradient,scale.xy);
        sum += pointShadowReceiverTapMetal(atlas,c,float2(0,crossOffset.y),gradient,scale.xy);
        sum += pointShadowReceiverTapMetal(atlas,c,float2(0,-crossOffset.y),gradient,scale.xy);
        sum += pointShadowReceiverTapMetal(atlas,c,cornerOffset,gradient,scale.xy);
        sum += pointShadowReceiverTapMetal(atlas,c,-cornerOffset,gradient,scale.xy);
        sum += pointShadowReceiverTapMetal(atlas,c,float2(cornerOffset.x,-cornerOffset.y),gradient,scale.xy);
        sum += pointShadowReceiverTapMetal(atlas,c,float2(-cornerOffset.x,cornerOffset.y),gradient,scale.xy);
        return sum/9.0;
    }
    """
}
