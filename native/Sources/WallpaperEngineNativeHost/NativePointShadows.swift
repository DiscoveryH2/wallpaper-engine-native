import Foundation
import OpenGL.GL3
import simd

/// Owned depth renderer for the supported opaque generic4 model path.
/// The reference uses six views, a 2x3 tile, and quality-dependent guard space.
/// This GL backend derives lookup coordinates from the same projection used to
/// draw depth. It does not execute or link the analysis reference library.
final class NativePointShadows {
    static let maximumLights = 4
    static let maximumSlots = NativeModelLightFrame.maximumLights
    static let faceSize = 512
    static let fieldOfView: Float = 92 * .pi / 180
    static let focalScale: Float = 1 / tan(fieldOfView / 2)

    struct Bounds {
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>

        init?(vertices: [Float], skeleton: NativeModelSkeleton?) {
            let stride = skeleton == nil ? 12 : 20
            guard !vertices.isEmpty, vertices.count % stride == 0 else { return nil }
            var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var upper = -lower
            for offset in Swift.stride(from: 0, to: vertices.count, by: stride) {
                let local = SIMD4(vertices[offset], vertices[offset + 1], vertices[offset + 2], 1)
                var position = SIMD3(local.x, local.y, local.z)
                if let skeleton {
                    var posed = SIMD4<Float>.zero
                    for influence in 0..<4 {
                        let bone = Int(vertices[offset + 10 + influence])
                        guard bone >= 0, bone < skeleton.bones.count else { return nil }
                        let b = bone * 16, p = skeleton.defaultPalette
                        let matrix = simd_float4x4((0..<4).map { column in
                            SIMD4(p[b + column * 4], p[b + column * 4 + 1], p[b + column * 4 + 2], p[b + column * 4 + 3])
                        })
                        posed += (matrix * local) * vertices[offset + 14 + influence]
                    }
                    position = SIMD3(posed.x, posed.y, posed.z)
                }
                guard [position.x, position.y, position.z].allSatisfy(\.isFinite) else { return nil }
                lower = simd_min(lower, position); upper = simd_max(upper, position)
            }
            minimum = lower; maximum = upper
        }

        func isOutside(_ clip: simd_float4x4) -> Bool {
            let corners = (0..<8).map { mask -> SIMD4<Float> in
                clip * SIMD4(mask & 1 == 0 ? minimum.x : maximum.x,
                             mask & 2 == 0 ? minimum.y : maximum.y,
                             mask & 4 == 0 ? minimum.z : maximum.z, 1)
            }
            guard corners.allSatisfy({ [$0.x, $0.y, $0.z, $0.w].allSatisfy(\.isFinite) }) else { return false }
            // A box is rejected only if all corners lie beyond the same plane.
            // Intersecting the near plane or enclosing the light stays visible.
            for axis in 0..<3 {
                if corners.allSatisfy({ $0[axis] < -$0.w - 0.001 }) ||
                   corners.allSatisfy({ $0[axis] > $0.w + 0.001 }) { return true }
            }
            return false
        }
    }

    let quality: NativeShadowQuality
    let atlas: NativeShadowAtlasLayout
    var capacity: Int { atlas.capacity }
    var width: Int { atlas.width }
    var height: Int { atlas.height }
    var scale: SIMD4<Float> { atlas.scale(quality: quality) }
    private(set) var texture: GLuint = 0
    private var framebuffer: GLuint = 0
    private(set) var bindings: [Int: SIMD4<Float>] = [:]
    private(set) var runtimeDiagnostic = "点光源阴影：尚未绘制。"
    private var frames = 0
    private var firstDepthCoverage: [Int] = []

    init(capacity: Int, quality: NativeShadowQuality = .high) throws {
        self.quality = quality; atlas = try NativeShadowAtlasLayout(capacity: capacity, quality: quality)
        var maximum: GLint = 0; glGetIntegerv(GLenum(GL_MAX_TEXTURE_SIZE), &maximum)
        guard width <= maximum, height <= maximum else { throw SceneError.invalid("阴影品质超过此 OpenGL 设备的纹理尺寸限制。") }
        glGenTextures(1, &texture); glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_DEPTH_COMPONENT24, GLsizei(width), GLsizei(height), 0,
                     GLenum(GL_DEPTH_COMPONENT), GLenum(GL_UNSIGNED_INT), nil)
        for parameter in [GL_TEXTURE_MIN_FILTER, GL_TEXTURE_MAG_FILTER] {
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(parameter), GL_LINEAR)
        }
        for parameter in [GL_TEXTURE_WRAP_S, GL_TEXTURE_WRAP_T] {
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(parameter), GL_CLAMP_TO_EDGE)
        }
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_COMPARE_MODE), GL_COMPARE_REF_TO_TEXTURE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_COMPARE_FUNC), GL_LEQUAL)
        glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_ATTACHMENT), GLenum(GL_TEXTURE_2D), texture, 0)
        glDrawBuffer(GLenum(GL_NONE)); glReadBuffer(GLenum(GL_NONE))
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            glDeleteFramebuffers(1, &framebuffer); glDeleteTextures(1, &texture)
            throw SceneError.invalid("点光源阴影深度目标不可用：\(status)。")
        }
    }

    /// The callback draws one face with the current scene transforms. Its tuple
    /// records submitted and frustum-culled submeshes; no animation is advanced.
    func render(lights: [NativeModelLightFrame.Light], time: Double,
                draw: (simd_float4x4) -> (submitted: Int, culled: Int)) {
        bindings.removeAll(keepingCapacity: true)
        var previousDepthFunction: GLint = GL_LESS
        glGetIntegerv(GLenum(GL_DEPTH_FUNC), &previousDepthFunction)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glDisable(GLenum(GL_SCISSOR_TEST)); glDisable(GLenum(GL_BLEND))
        glEnable(GLenum(GL_DEPTH_TEST)); glDepthFunc(GLenum(GL_LEQUAL)); glDepthMask(GLboolean(GL_TRUE))
        glClearDepth(1); glClear(GLbitfield(GL_DEPTH_BUFFER_BIT))
        // Native GL slope/units bias, not a recovered Windows rasterizer value.
        glEnable(GLenum(GL_POLYGON_OFFSET_FILL)); glPolygonOffset(1, 1)
        var submitted = 0, culled = 0, slot = 0, views = 0, spots = 0
        var coverage: [Int] = []
        for (index, light) in lights.enumerated() where light.shadowNear != nil {
            guard slot < capacity, let near = light.shadowNear else { continue }
            let spatial = light.positionRadius
            let far = max(near + 0.01, spatial.w)
            let position = SIMD3(spatial.x, spatial.y, spatial.z)
            let count = light.spotShadow == nil ? 6 : 1
            views += count; if count == 1 { spots += 1 }
            for face in 0..<count {
                let origin = atlas.origin(slot: slot, face: face), size = atlas.faceSize
                let x = origin.x, y = origin.y
                glViewport(GLint(x), GLint(y), GLsizei(size), GLsizei(size))
                let result = draw(light.spotShadow?.viewProjection ?? Self.viewProjection(position: position, face: face, near: near, far: far, focalScale: quality.focalScale))
                submitted += result.submitted; culled += result.culled
                if frames == 0 {
                    // A single first-frame diagnostic confirms actual depth
                    // writes; draw-call counts alone cannot establish that.
                    var pixels = [Float](repeating: 1, count: size * size)
                    pixels.withUnsafeMutableBytes {
                        glReadPixels(GLint(x), GLint(y), GLsizei(size), GLsizei(size),
                                     GLenum(GL_DEPTH_COMPONENT), GLenum(GL_FLOAT), $0.baseAddress)
                    }
                    coverage.append(pixels.reduce(0) { $0 + ($1 < 1 && $1.isFinite ? 1 : 0) })
                }
            }
            bindings[index] = SIMD4(Float(slot + 1), near, far, light.spotShadow == nil ? 0 : 1)
            slot += 1
        }
        glDisable(GLenum(GL_POLYGON_OFFSET_FILL)); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glDepthFunc(GLenum(previousDepthFunction))
        if frames == 0 { firstDepthCoverage = coverage }
        frames += 1
        runtimeDiagnostic = "原生模型阴影：场景时间 \(String(format: "%.3f", time)) 秒；\(slot) 盏（聚光 \(spots)）/ \(views) 个视图，深度图 \(width)×\(height)，每面 \(atlas.faceSize)，品质 \(quality.title)；提交 \(submitted) 个网格，视锥外 \(culled)；绘制帧 \(frames)；首次各面有效深度像素 \(firstDepthCoverage)。仅不透明原生 generic4 模型；GL 偏移 1/1，\(quality.filterTaps) 点 PCF、逐纹素接收面修正，尚未与 Windows 逐像素对齐。"
    }

    static func viewProjection(position: SIMD3<Float>, face: Int, near: Float, far: Float, focalScale: Float = NativePointShadows.focalScale) -> simd_float4x4 {
        let directions: [SIMD3<Float>] = [SIMD3(1,0,0), SIMD3(-1,0,0), SIMD3(0,1,0), SIMD3(0,-1,0), SIMD3(0,0,1), SIMD3(0,0,-1)]
        let up: SIMD3<Float> = face == 2 ? SIMD3(0,0,1) : face == 3 ? SIMD3(0,0,-1) : SIMD3(0,1,0)
        let back = -directions[face], right = simd_cross(up, back)
        let view = simd_float4x4(columns: (
            SIMD4(right.x, up.x, back.x, 0), SIMD4(right.y, up.y, back.y, 0),
            SIMD4(right.z, up.z, back.z, 0), SIMD4(-simd_dot(right, position), -simd_dot(up, position), -simd_dot(back, position), 1)))
        let projection = simd_float4x4(columns: (
            SIMD4(focalScale,0,0,0), SIMD4(0,focalScale,0,0),
            SIMD4(0,0,-(far + near) / (far - near),-1), SIMD4(0,0,-2 * far * near / (far - near),0)))
        return projection * view
    }

    /// Shared face/projection mapping for surface PCF and volume comparisons.
    static let projectionGLSL = """
    vec4 nativePointShadowCoordinates(vec3 delta, vec4 shadow, vec4 scale) {
        vec3 magnitude = abs(delta);
        vec3 projected;
        int face;
        if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
            face = delta.x >= 0.0 ? 0 : 1;
            projected = vec3(delta.x >= 0.0 ? delta.z : -delta.z, delta.y, magnitude.x);
        } else if (magnitude.y >= magnitude.z) {
            face = delta.y >= 0.0 ? 2 : 3;
            projected = vec3(delta.x, delta.y >= 0.0 ? delta.z : -delta.z, magnitude.y);
        } else {
            face = delta.z >= 0.0 ? 4 : 5;
            projected = vec3(delta.z >= 0.0 ? -delta.x : delta.x, delta.y, magnitude.z);
        }
        if (projected.z <= shadow.y || projected.z >= shadow.z) return vec4(0.0);
        float slot = shadow.x - 1.0;
        vec2 tile = vec2(mod(slot, scale.z) * 2.0 + float(face % 2), floor(slot / scale.z) * 3.0 + float(face / 2));
        vec2 grid = vec2(scale.z * 2.0, floor(scale.z * 2.0 * scale.x / scale.y + 0.5));
        vec2 localUV = projected.xy / projected.z * (0.5 * scale.w) + 0.5;
        vec2 uv = (tile + localUV) / grid;
        float depth = shadow.z / (shadow.z - shadow.y) * (1.0 - shadow.y / projected.z);
        return vec4(uv, depth, 1.0);
    }
    """

    /// Receiver-plane depth is affine in a face's projected UV coordinates.
    /// Derive that plane from the rasterized triangle, never a smooth/normal-map
    /// shading normal. Each bilinear comparison needs its own reference depth:
    /// correcting only the nine tap centers still leaves errors inside a tap.
    static let receiverGLSL = """
    float nativePointShadowFlatVisibility(sampler2DShadow atlas, vec4 center, vec2 texel) {
        vec2 axial = texel * 1.02323, diagonal = texel * 0.81616;
        float value = texture(atlas, center.xyz);
        value += texture(atlas, vec3(center.xy + vec2(axial.x, 0.0), center.z));
        value += texture(atlas, vec3(center.xy - vec2(axial.x, 0.0), center.z));
        value += texture(atlas, vec3(center.xy + vec2(0.0, axial.y), center.z));
        value += texture(atlas, vec3(center.xy - vec2(0.0, axial.y), center.z));
        value += texture(atlas, vec3(center.xy + diagonal, center.z));
        value += texture(atlas, vec3(center.xy - diagonal, center.z));
        value += texture(atlas, vec3(center.xy + vec2(diagonal.x, -diagonal.y), center.z));
        value += texture(atlas, vec3(center.xy + vec2(-diagonal.x, diagonal.y), center.z));
        return value / 9.0;
    }
    vec2 nativePointShadowReceiverGradient(vec3 delta, vec3 normal, vec4 shadow, vec4 scale) {
        float distance = dot(normal, delta);
        if (!(abs(distance) > 0.000001 * length(normal) * max(length(delta), 0.000001))) return vec2(0.0);
        vec3 magnitude = abs(delta);
        vec2 faceNormal;
        if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
            faceNormal = vec2(delta.x >= 0.0 ? normal.z : -normal.z, normal.y);
        } else if (magnitude.y >= magnitude.z) {
            faceNormal = vec2(normal.x, delta.y >= 0.0 ? normal.z : -normal.z);
        } else {
            faceNormal = vec2(delta.z >= 0.0 ? -normal.x : normal.x, normal.y);
        }
        float factor = -2.0 * shadow.z * shadow.y / ((shadow.z - shadow.y) * scale.w * distance);
        return factor * faceNormal * vec2(scale.z * 2.0, floor(scale.z * 2.0 * scale.x / scale.y + 0.5));
    }
    float nativePointShadowReceiverTap(sampler2DShadow atlas, vec4 center, vec2 offset, vec2 gradient, vec2 texel) {
        vec2 position = (center.xy + offset) / texel - 0.5;
        vec2 weight = fract(position), a = (floor(position) + 0.5) * texel;
        vec2 b = a + vec2(texel.x, 0.0), c = a + vec2(0.0, texel.y), d = a + texel;
        // Sample at texel centers so the texture unit does not blend comparisons
        // made with an unrelated depth. Retain the original bilinear weights.
        float va = texture(atlas, vec3(a, clamp(center.z + dot(a - center.xy, gradient), 0.0, 1.0)));
        float vb = texture(atlas, vec3(b, clamp(center.z + dot(b - center.xy, gradient), 0.0, 1.0)));
        float vc = texture(atlas, vec3(c, clamp(center.z + dot(c - center.xy, gradient), 0.0, 1.0)));
        float vd = texture(atlas, vec3(d, clamp(center.z + dot(d - center.xy, gradient), 0.0, 1.0)));
        return mix(mix(va, vb, weight.x), mix(vc, vd, weight.x), weight.y);
    }
    """

    static let vertex = """
    attribute vec3 a_Position;
    uniform mat4 g_NativeShadowMatrix;
    #if NATIVE_BONE_COUNT > 0
    attribute vec4 a_NativeBoneIndices;
    attribute vec4 a_NativeBoneWeights;
    uniform mat4 g_NativeBones[NATIVE_BONE_COUNT];
    #endif
    void main() {
        vec4 local = vec4(a_Position, 1.0);
    #if NATIVE_BONE_COUNT > 0
        ivec4 joints = ivec4(a_NativeBoneIndices);
        mat4 skin = g_NativeBones[joints.x] * a_NativeBoneWeights.x
                  + g_NativeBones[joints.y] * a_NativeBoneWeights.y
                  + g_NativeBones[joints.z] * a_NativeBoneWeights.z
                  + g_NativeBones[joints.w] * a_NativeBoneWeights.w;
        local = vec4((skin * local).xyz, 1.0);
    #endif
        gl_Position = g_NativeShadowMatrix * local;
    }
    """
    static let fragment = "void main() { gl_FragColor = vec4(1.0); }"

    deinit {
        glDeleteFramebuffers(1, &framebuffer); glDeleteTextures(1, &texture)
    }
}
