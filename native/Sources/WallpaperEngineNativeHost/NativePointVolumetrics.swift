import Foundation
import OpenGL.GL3
import simd

/// Owned point-light integration, using the recovered quality-dependent sampling
/// contract. Sphere intervals are analytic in this backend; the reference
/// rasterizes a 24-segment sphere. No reference code is linked or loaded.
final class NativePointVolumetrics {
    let width: Int, height: Int
    let quality: NativeVolumetricQuality
    private let lightBuffer: SceneTarget
    private let blurBuffer: SceneTarget?
    private let blur: SceneShader?
    private let integrate: SceneShader
    private let combine: SceneShader
    private var depthTexture: GLuint = 0
    private var depthFramebuffer: GLuint = 0
    private var vertexArray: GLuint = 0
    private let generation: Int
    private var frames = 0
    private var lastLights = 0, lastShadowed = 0, lastBlurPasses = 0
    private var firstPixels = 0
    private var firstMaximum: Float = 0
    private var firstMean: Float = 0
    private var firstGLError: GLenum = 0
    private(set) var runtimeDiagnostic = "点光源体积光：尚未绘制。"

    init(width: Int, height: Int, hdr: Bool, previous: NativePointVolumetrics?, quality: NativeVolumetricQuality = .high) throws {
        guard quality != .disabled, width > 0, height > 0,
              width <= 16_384, height <= 16_384 else { throw SceneError.invalid("体积照明品质或目标尺寸无效。") }
        self.width = width; self.height = height
        self.quality = quality
        generation = (previous?.generation ?? 0) + 1
        integrate = try SceneShader(vertex: Self.vertex, fragment: Self.fragment, label: "native point volumetrics")
        combine = try SceneShader(vertex: Self.vertex, fragment: Self.composite, label: "native volumetric combine")
        glActiveTexture(GLenum(GL_TEXTURE0))
        let w = max(1, width / quality.divisor), h = max(1, height / quality.divisor)
        guard w * h <= 4 * 1024 * 1024 else { throw SceneError.invalid("体积光缓冲超过 4M 像素。") }
        lightBuffer = try SceneTarget(width: w, height: h, withDepth: false, hdr: hdr)
        blurBuffer = try quality.blurPasses > 0 ? SceneTarget(width: w, height: h, withDepth: false, hdr: hdr) : nil
        blur = try quality.blurPasses > 0 ? SceneShader(vertex: Self.vertex, fragment: Self.blurFragment, label: "native volume blur") : nil
        glGenVertexArrays(1, &vertexArray)
        glGenTextures(1, &depthTexture); glBindTexture(GLenum(GL_TEXTURE_2D), depthTexture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_DEPTH_COMPONENT24, GLsizei(width), GLsizei(height), 0,
                     GLenum(GL_DEPTH_COMPONENT), GLenum(GL_UNSIGNED_INT), nil)
        for parameter in [GL_TEXTURE_MIN_FILTER, GL_TEXTURE_MAG_FILTER] {
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(parameter), GL_NEAREST)
        }
        for parameter in [GL_TEXTURE_WRAP_S, GL_TEXTURE_WRAP_T] {
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(parameter), GL_CLAMP_TO_EDGE)
        }
        glGenFramebuffers(1, &depthFramebuffer); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), depthFramebuffer)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_ATTACHMENT), GLenum(GL_TEXTURE_2D), depthTexture, 0)
        glDrawBuffer(GLenum(GL_NONE)); glReadBuffer(GLenum(GL_NONE))
        let status = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        guard status == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            glDeleteFramebuffers(1, &depthFramebuffer); glDeleteTextures(1, &depthTexture); glDeleteVertexArrays(1, &vertexArray)
            throw SceneError.invalid("体积光场景深度目标不可用：\(status)。")
        }
    }

    func render(source: SceneTarget, frame: NativeModelLightFrame, shadows: NativePointShadows?,
                viewProjection: simd_float4x4, eye: SIMD3<Float>, time: Double) {
        let inverse = simd_inverse(viewProjection)
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { inverse[c][$0].isFinite } }) else {
            runtimeDiagnostic = "点光源体积光：相机逆矩阵非有限，当前帧未合成。"; return
        }
        // The sampled depth must not alias the active scene renderbuffer.
        glDisable(GLenum(GL_SCISSOR_TEST))
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), source.framebuffer)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), depthFramebuffer)
        glBlitFramebuffer(0, 0, GLint(width), GLint(height), 0, 0, GLint(width), GLint(height),
                          GLbitfield(GL_DEPTH_BUFFER_BIT), GLenum(GL_NEAREST))
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), lightBuffer.framebuffer)
        glViewport(0, 0, GLsizei(lightBuffer.width), GLsizei(lightBuffer.height))
        glDisable(GLenum(GL_DEPTH_TEST)); glDepthMask(GLboolean(GL_FALSE)); glDisable(GLenum(GL_CULL_FACE))
        glClearColor(0, 0, 0, 0); glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        glEnable(GLenum(GL_BLEND)); glBlendEquation(GLenum(GL_FUNC_ADD)); glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE))
        glUseProgram(integrate.program); glBindVertexArray(vertexArray)
        var matrix = inverse
        withUnsafePointer(to: &matrix) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: 16) {
                glUniformMatrix4fv(integrate.location("volumeInverseVP"), 1, GLboolean(GL_FALSE), $0)
            }
        }
        glUniform3f(integrate.location("volumeEye"), eye.x, eye.y, eye.z)
        glUniform2i(integrate.location("volumeSamples"), GLint(quality.shadowedSamples), GLint(quality.unshadowedSamples))
        glUniform1i(integrate.location("volumeFogEnabled"), frame.fogEnabled ? 1 : 0)
        Self.uniform(frame.fogParams, "volumeFog", integrate)
        glActiveTexture(GLenum(GL_TEXTURE0)); glBindTexture(GLenum(GL_TEXTURE_2D), depthTexture)
        glUniform1i(integrate.location("volumeSceneDepth"), 0)
        glActiveTexture(GLenum(GL_TEXTURE0 + 8)); glBindTexture(GLenum(GL_TEXTURE_2D), shadows?.texture ?? 0)
        glUniform1i(integrate.location("volumeShadowAtlas"), 8)
        if let shadows {
            Self.uniform(shadows.scale,
                         "volumeShadowScale", integrate)
        }
        var count = 0, shadowed = 0, inside = 0
        for (index, light) in frame.lights.enumerated() {
            guard let parameters = light.volumetrics else { continue }
            Self.uniform(light.positionRadius, "volumeOriginRadius", integrate)
            // colorExponent.rgb already contains intensity, applied exactly once.
            Self.uniform(SIMD4(light.colorExponent.x, light.colorExponent.y, light.colorExponent.z, parameters.x), "volumeRadianceDensity", integrate)
            glUniform1f(integrate.location("volumeExponent"), parameters.y)
            let binding = shadows?.bindings[index] ?? .zero
            Self.uniform(binding, "volumeShadow", integrate)
            glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)
            count += 1
            if binding.x >= 1 { shadowed += 1 }
            let position = SIMD3(light.positionRadius.x, light.positionRadius.y, light.positionRadius.z)
            if simd_length(eye - position) < light.positionRadius.w { inside += 1 }
        }
        if frames == 0 {
            // Once per allocation, observe the actual light buffer; this is
            // not a substitute for visual agreement with the Windows renderer.
            var pixels = [Float](repeating: 0, count: lightBuffer.width * lightBuffer.height * 4)
            pixels.withUnsafeMutableBytes {
                glReadPixels(0, 0, GLsizei(lightBuffer.width), GLsizei(lightBuffer.height), GLenum(GL_RGBA), GLenum(GL_FLOAT), $0.baseAddress)
            }
            var sum = 0.0
            for offset in stride(from: 0, to: pixels.count, by: 4) {
                let maximum = max(pixels[offset], max(pixels[offset + 1], pixels[offset + 2]))
                if maximum.isFinite, maximum > 0 { firstPixels += 1; firstMaximum = max(firstMaximum, maximum) }
                for channel in 0..<3 where pixels[offset + channel].isFinite { sum += Double(pixels[offset + channel]) }
            }
            firstMean = Float(sum / Double(lightBuffer.width * lightBuffer.height * 3))
        }
        lastBlurPasses = 0
        if let blurBuffer, let blur {
            glDisable(GLenum(GL_BLEND)); glUseProgram(blur.program)
            glActiveTexture(GLenum(GL_TEXTURE0)); glUniform1i(blur.location("volumeColor"), 0)
            for vertical in [false, true] {
                let output = vertical ? lightBuffer : blurBuffer, input = vertical ? blurBuffer : lightBuffer
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), output.framebuffer)
                glBindTexture(GLenum(GL_TEXTURE_2D), input.texture)
                glUniform2f(blur.location("volumeBlurStep"), vertical ? 0 : 1 / Float(input.width), vertical ? 1 / Float(input.height) : 0)
                glDrawArrays(GLenum(GL_TRIANGLES), 0, 3); lastBlurPasses += 1
            }
            glEnable(GLenum(GL_BLEND)); glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE))
        }
        lastLights = count; lastShadowed = shadowed
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), source.framebuffer)
        glViewport(0, 0, GLsizei(width), GLsizei(height)); glUseProgram(combine.program)
        glActiveTexture(GLenum(GL_TEXTURE0)); glBindTexture(GLenum(GL_TEXTURE_2D), lightBuffer.texture)
        glUniform1i(combine.location("volumeColor"), 0)
        glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)
        glDisable(GLenum(GL_BLEND)); glBindVertexArray(0)
        if frames == 0 { firstGLError = glGetError() }
        frames += 1
        runtimeDiagnostic = "点光源体积光：场景时间 \(String(format: "%.3f", time)) 秒；\(count) 盏 / 阴影 \(shadowed) 盏 / 相机在球内 \(inside) 盏；深度 \(width)×\(height)，光照缓冲 \(lightBuffer.width)×\(lightBuffer.height) \(lightBuffer.hdr ? "RGBA16F" : "RGBA8")，代次 \(generation)，绘制帧 \(frames)；品质 \(quality.title)，阴影 \(quality.shadowedSamples) / 无阴影 \(quality.unshadowedSamples) 次采样，模糊 \(lastBlurPasses) 次；首次非零像素 \(firstPixels)，峰值 \(String(format: "%.6f", firstMaximum))，RGB 均值 \(String(format: "%.6f", firstMean))，GL \(firstGLError)。模型后、粒子与全局泛光前加法合成；解析球体边界，距离雾已接入，高度雾和聚光灯体积光尚未实现。"
    }

    private static func uniform(_ value: SIMD4<Float>, _ name: String, _ shader: SceneShader) {
        glUniform4f(shader.location(name), value.x, value.y, value.z, value.w)
    }

    private static let vertex = """
    varying vec2 volumeUV;
    void main() {
        vec2 corner = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
        volumeUV = corner;
        gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
    }
    """
    private static let composite = """
    varying vec2 volumeUV;
    uniform sampler2D volumeColor;
    void main() { gl_FragColor = vec4(texture(volumeColor, volumeUV).rgb, 0.0); }
    """
    private static let blurFragment = """
    varying vec2 volumeUV;
    uniform sampler2D volumeColor;
    uniform vec2 volumeBlurStep;
    void main() {
        vec3 color = texture(volumeColor, volumeUV).rgb * 0.5;
        color += texture(volumeColor, volumeUV + volumeBlurStep).rgb * 0.25;
        color += texture(volumeColor, volumeUV - volumeBlurStep).rgb * 0.25;
        gl_FragColor = vec4(color, 0.0);
    }
    """
    private static let fragment = """
    varying vec2 volumeUV;
    uniform sampler2D volumeSceneDepth;
    uniform sampler2DShadow volumeShadowAtlas;
    uniform mat4 volumeInverseVP;
    uniform vec4 volumeOriginRadius;
    uniform vec4 volumeRadianceDensity;
    uniform float volumeExponent;
    uniform vec4 volumeShadow;
    uniform vec4 volumeShadowScale;
    uniform int volumeFogEnabled;
    uniform vec4 volumeFog;
    uniform vec3 volumeEye;
    uniform ivec2 volumeSamples;

    \(NativePointShadows.projectionGLSL)

    vec3 volumeWorld(float depth) {
        vec4 world = volumeInverseVP * vec4(volumeUV * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
        return world.xyz / world.w;
    }
    float volumeJitter(vec2 uv) {
        vec3 state = fract(vec3(uv.x, uv.y, uv.x) * 43758.5453);
        state += vec3(dot(state, state.yzx + vec3(19.19)));
        return fract((state.x + state.y) * state.z);
    }
    void main() {
        vec3 nearPoint = volumeWorld(0.0);
        vec3 scenePoint = volumeWorld(texture(volumeSceneDepth, volumeUV).r);
        vec3 segment = scenePoint - nearPoint;
        float sceneLength = length(segment);
        if (sceneLength <= 0.000001) discard;
        vec3 direction = segment / sceneLength;
        vec3 offset = nearPoint - volumeOriginRadius.xyz;
        float projection = dot(offset, direction);
        float discriminant = projection * projection - dot(offset, offset) + volumeOriginRadius.w * volumeOriginRadius.w;
        if (discriminant <= 0.0) discard;
        float root = sqrt(discriminant);
        float startDistance = max(0.0, -projection - root);
        float endDistance = min(sceneLength, -projection + root);
        float interval = endDistance - startDistance;
        if (interval <= 0.0) discard;
        bool shadowed = volumeShadow.x >= 1.0;
        int steps = shadowed ? volumeSamples.x : volumeSamples.y;
        float stepSize = interval / float(steps + 1);
        // GL framebuffer coordinates run upward; the recovered jitter uses
        // top-origin screen UV. Depth reconstruction stays in GL coordinates.
        float jitter = shadowed ? volumeJitter(vec2(volumeUV.x, 1.0 - volumeUV.y)) : 0.0;
        float radius = volumeOriginRadius.w * 0.99;
        float total = 0.0;
        for (int sampleIndex = 0; sampleIndex < 64; ++sampleIndex) {
            if (sampleIndex >= steps) break;
            float distanceAlongRay = startDistance + (float(sampleIndex + 1) + jitter) * stepSize;
            vec3 world = nearPoint + direction * distanceAlongRay;
            vec3 lightDelta = world - volumeOriginRadius.xyz;
            float falloff = clamp(1.0 - length(lightDelta) / radius, 0.0, 1.0);
            float contribution = pow(falloff, volumeExponent);
            if (shadowed) {
                vec4 projected = nativePointShadowCoordinates(lightDelta, volumeShadow, volumeShadowScale);
                if (projected.w > 0.5) contribution *= texture(volumeShadowAtlas, projected.xyz);
            }
            if (volumeFogEnabled != 0) {
                float distanceFraction = clamp((length(world - volumeEye) - volumeFog.x) / volumeFog.y, 0.0, 1.0);
                float fog = clamp(volumeFog.z + volumeFog.w * distanceFraction * distanceFraction, 0.0, 1.0);
                // Recovered expression is sample * ApplyFogAlpha(sample):
                // it squares the sample as well as attenuating by fog.
                contribution = contribution * contribution * (1.0 - fog * fog);
            }
            total += contribution;
        }
        float scale = volumeRadianceDensity.w * interval / radius * 0.05 / float(steps);
        gl_FragColor = vec4(volumeRadianceDensity.rgb * (total * scale), 0.0);
    }
    """

    var snapshot: [String: Any] {
        ["quality": quality.rawValue, "allocated": true, "width": lightBuffer.width, "height": lightBuffer.height,
         "sceneWidth": width, "sceneHeight": height, "lights": lastLights, "shadowedLights": lastShadowed,
         "shadowedSamples": quality.shadowedSamples, "unshadowedSamples": quality.unshadowedSamples,
         "blurPasses": lastBlurPasses, "blurAllocated": blurBuffer != nil, "hdr": lightBuffer.hdr]
    }

    deinit {
        glDeleteFramebuffers(1, &depthFramebuffer); glDeleteTextures(1, &depthTexture); glDeleteVertexArrays(1, &vertexArray)
    }
}
