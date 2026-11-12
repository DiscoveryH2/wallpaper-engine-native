import Foundation
import OpenGL.GL3
import simd

/// Native GL implementation, including authored shaders/scenes that have not
/// migrated to Metal. All downsample levels remain private RGBA16F targets.
final class NativeHDRBloom {
    let plan: NativeHDRBloomPlan
    private let levels: [SceneTarget]
    private let shader: SceneShader
    private let generation: UInt64
    private var frames: UInt64 = 0
    private(set) var runtimeDiagnostic = "HDR 泛光：缓冲已准备，等待作者开关。"

    init(width: Int, height: Int, previous: NativeHDRBloom?) throws {
        guard (1...4096).contains(width), (1...4096).contains(height) else { throw SceneError.invalid("HDR 泛光尺寸超过 4096 上限。") }
        plan = NativeHDRBloomPlan(width: width, height: height)
        shader = try previous?.shader ?? SceneShader(vertex: Self.vertex, fragment: Self.fragment, label: "native HDR bloom pyramid")
        levels = try plan.sizes.map { try SceneTarget(width: $0.x, height: $0.y, withDepth: false, hdr: true) }
        generation = (previous?.generation ?? 0) + 1
        frames = previous?.frames ?? 0
    }

    func render(source: SceneTarget, parameters: NativeHDRBloomParameters, time: Double, draw: () -> Void) -> SceneTarget? {
        guard source.width == plan.width, source.height == plan.height, time.isFinite,
              let p = parameters.resolve(available: levels.count) else { return nil }
        glDisable(GLenum(GL_DEPTH_TEST)); glDepthMask(GLboolean(GL_FALSE)); glDisable(GLenum(GL_CULL_FACE))
        glDisable(GLenum(GL_BLEND)); glUseProgram(shader.program)
        glUniform4f(shader.location("blend"), p.blend.x, p.blend.y, p.blend.z, p.blend.w)
        glUniform3f(shader.location("tint"), p.tint.x, p.tint.y, p.tint.z)
        glUniform1f(shader.location("strength"), p.strength)
        glUniform1f(shader.location("scatter"), p.scatter)
        for index in 0..<p.levels {
            stage(target: levels[index], source: index == 0 ? source : levels[index - 1], step: plan.step(sourceIndex: index), operation: index == 0 ? 0 : 1)
            draw()
        }
        if p.levels > 1 {
            glEnable(GLenum(GL_BLEND)); glBlendEquation(GLenum(GL_FUNC_ADD)); glBlendFuncSeparate(GLenum(GL_ONE), GLenum(GL_ONE), GLenum(GL_ZERO), GLenum(GL_ONE))
            for index in stride(from: p.levels - 1, through: 1, by: -1) {
                stage(target: levels[index - 1], source: levels[index], step: plan.step(sourceIndex: index),
                      operation: plan.bicubic(sourceIndex: index, levels: p.levels) ? 3 : 2)
                draw()
            }
        }
        glDisable(GLenum(GL_BLEND)); frames &+= 1
        runtimeDiagnostic = "HDR 泛光最近绘制：时间 \(String(format: "%.6f", time)) 秒，级数 \(p.levels)/\(levels.count)，强度 \(parameters.strength) → 提取 \(p.strength)，阈值 \(parameters.threshold)，柔化 \(parameters.feather)，散射 \(p.scatter)，颜色 \(p.tint)。RGBA16F \(plan.bytes) 字节，代次 \(generation)，\(frames) 帧；末两次回升使用双三次采样，逐级加法叠加。最终输出为 SDR。"
        return levels[0]
    }

    private func stage(target: SceneTarget, source: SceneTarget, step: SIMD2<Float>, operation: Int32) {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.framebuffer)
        glViewport(0, 0, GLsizei(target.width), GLsizei(target.height))
        glActiveTexture(GLenum(GL_TEXTURE0)); glBindTexture(GLenum(GL_TEXTURE_2D), source.texture)
        glUniform1i(shader.location("g_Texture0"), 0)
        glUniform1i(shader.location("operation"), operation)
        glUniform2f(shader.location("sampleStep"), step.x, step.y)
    }

    private static let vertex = """
    attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 uv;
    void main() { gl_Position = vec4(a_Position, 1.0); uv = a_TexCoord; }
    """

    // Independently expressed B-spline reconstruction. Pair adjacent weights
    // to reduce a 4x4 cubic footprint to four bilinear texture fetches.
    private static let fragment = """
    varying vec2 uv; uniform sampler2D g_Texture0;
    uniform vec2 sampleStep; uniform vec4 blend; uniform vec3 tint;
    uniform float strength; uniform float scatter; uniform int operation;
    vec4 cubicWeights(float f) {
        float a = 1.0-f, b = f*f, c = b*f;
        return vec4(a*a*a, 4.0-6.0*b+3.0*c, 1.0+3.0*f+3.0*b-3.0*c, c) / 6.0;
    }
    vec3 cubicSample(vec2 coordinate) {
        vec2 invSize = 2.0 * sampleStep;
        vec2 pixel = coordinate / invSize - 0.5;
        vec2 f = fract(pixel); pixel = floor(pixel);
        vec4 wx = cubicWeights(f.x), wy = cubicWeights(f.y);
        vec2 sx = vec2(wx.x+wx.y, wx.z+wx.w), sy = vec2(wy.x+wy.y, wy.z+wy.w);
        vec2 x = (pixel.x + vec2(-0.5,1.5) + vec2(wx.y,wx.w)/sx)*invSize.x;
        vec2 y = (pixel.y + vec2(-0.5,1.5) + vec2(wy.y,wy.w)/sy)*invSize.y;
        vec3 low = mix(texture(g_Texture0,vec2(x.x,y.x)).rgb,texture(g_Texture0,vec2(x.y,y.x)).rgb,sx.y);
        vec3 high = mix(texture(g_Texture0,vec2(x.x,y.y)).rgb,texture(g_Texture0,vec2(x.y,y.y)).rgb,sx.y);
        return mix(low,high,sy.y);
    }
    void main() {
        vec3 color = vec3(0.0);
        for (int y=-1; y<=1; y+=2) for (int x=-1; x<=1; x+=2) {
            vec2 coordinate = uv + vec2(x,y)*sampleStep;
            color += (operation == 3 ? cubicSample(coordinate) : texture(g_Texture0,coordinate).rgb)*0.25;
        }
        if (operation == 0) {
            color = max(color,vec3(0.0));
            float peak = max(color.r,max(color.g,color.b));
            float soft = clamp(peak-blend.y,0.0,blend.z);
            float gain = max(soft*soft*blend.w,peak-blend.x)/max(peak,0.00001);
            color *= gain*strength*tint;
        } else if (operation >= 2) color *= scatter;
        gl_FragColor = vec4(clamp(color,vec3(0.0),vec3(65504.0)),1.0);
    }
    """
}
