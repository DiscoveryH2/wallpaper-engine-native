import Foundation
import OpenGL.GL3
import simd

/// Native implementation of the ordinary (non-HDR) scene bloom graph.
/// Shader equations and pass order come from static reference resources;
/// no vendor library or shader file is required at runtime.
final class NativeStandardBloom {
    typealias Parameters = NativeBloomParameters

    let width: Int
    let height: Int
    private let extraction: SceneTarget
    private let horizontal: SceneTarget
    private let vertical: SceneTarget
    private let extractShader: SceneShader
    private let blurShader: SceneShader
    private let generation: UInt64
    private var redraws: UInt64 = 0
    private var lastTime: Double?
    private var lastParameters: Parameters?
    private var firstPixels: (nonzero: Int, peak: UInt8, average: Double, error: GLenum)?

    init(width: Int, height: Int, previous: NativeStandardBloom?) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            throw SceneError.invalid("普通泛光输出尺寸超出 4096 上限。")
        }
        self.width = width; self.height = height
        if let previous {
            extractShader = previous.extractShader; blurShader = previous.blurShader
        } else {
            extractShader = try SceneShader(vertex: Self.vertex, fragment: Self.extractFragment,
                label: "native standard bloom extraction")
            blurShader = try SceneShader(vertex: Self.vertex, fragment: Self.blurFragment,
                label: "native standard bloom separable blur")
        }
        // Reference FBO divisors are 4, 8, 8, with ordinary 8-bit color.
        // These private buffers cannot alias an authored framebuffer sampler.
        extraction = try SceneTarget(width: max(2, width / 4), height: max(2, height / 4), withDepth: false, hdr: false)
        horizontal = try SceneTarget(width: max(2, width / 8), height: max(2, height / 8), withDepth: false, hdr: false)
        vertical = try SceneTarget(width: max(2, width / 8), height: max(2, height / 8), withDepth: false, hdr: false)
        generation = (previous?.generation ?? 0) + 1
        redraws = previous?.redraws ?? 0
    }

    func render(source: SceneTarget, parameters: Parameters, at time: Double, drawQuad: () -> Void) -> SceneTarget? {
        guard source.width == width, source.height == height,
              parameters.isFinite, time.isFinite else { return nil }
        glDisable(GLenum(GL_DEPTH_TEST)); glDepthMask(GLboolean(GL_FALSE))
        glDisable(GLenum(GL_BLEND)); glDisable(GLenum(GL_CULL_FACE))
        bind(target: extraction, input: source, shader: extractShader)
        glUniform2f(extractShader.location("sourceTexel"), 1 / Float(width), 1 / Float(height))
        glUniform1f(extractShader.location("strength"), parameters.strength)
        glUniform1f(extractShader.location("threshold"), parameters.threshold)
        glUniform3f(extractShader.location("tint"), parameters.tint.x, parameters.tint.y, parameters.tint.z)
        drawQuad()

        bind(target: horizontal, input: extraction, shader: blurShader)
        glUniform2f(blurShader.location("sampleStep"), 8 / Float(width), 0)
        drawQuad()
        bind(target: vertical, input: horizontal, shader: blurShader)
        glUniform2f(blurShader.location("sampleStep"), 0, 8 / Float(height))
        drawQuad()

        lastTime = time; lastParameters = parameters; redraws &+= 1
        if firstPixels == nil {
            // One bounded diagnostic capture per allocation generation. Never
            // read the full scene or keep a sequence of wallpaper pixels.
            var bytes = [UInt8](repeating: 0, count: vertical.width * vertical.height * 4)
            var pack: GLint = 4
            glGetIntegerv(GLenum(GL_PACK_ALIGNMENT), &pack)
            glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
            bytes.withUnsafeMutableBytes {
                glReadPixels(0, 0, GLsizei(vertical.width), GLsizei(vertical.height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
            }
            glPixelStorei(GLenum(GL_PACK_ALIGNMENT), pack)
            let error = glGetError()
            var nonzero = 0, peak: UInt8 = 0, total: UInt64 = 0
            for offset in stride(from: 0, to: bytes.count, by: 4) {
                let maximum = max(bytes[offset], bytes[offset + 1], bytes[offset + 2])
                if maximum != 0 { nonzero += 1 }
                peak = max(peak, maximum)
                total += UInt64(bytes[offset]) + UInt64(bytes[offset + 1]) + UInt64(bytes[offset + 2])
            }
            firstPixels = (nonzero, peak, Double(total) / Double(vertical.width * vertical.height * 3 * 255), error)
        }
        return vertical
    }

    var runtimeDiagnostic: String {
        guard let lastTime, let p = lastParameters, let pixels = firstPixels else {
            return "普通泛光：缓冲已就绪，尚未执行；由作者 bloom 开关控制。"
        }
        let bytes = (extraction.width * extraction.height + horizontal.width * horizontal.height + vertical.width * vertical.height) * 4
        return "普通泛光运行快照：场景时间 \(String(format: "%.6f", lastTime)) 秒，强度=\(p.strength)，阈值=\(p.threshold)，颜色=\(p.tint)；提取 \(extraction.width)×\(extraction.height)，双向模糊 \(vertical.width)×\(vertical.height)，RGBA8 共 \(bytes) 字节，代次 \(generation)，重绘 \(redraws) 帧；首次非零像素 \(pixels.nonzero)，峰值 \(pixels.peak)/255，RGB 均值 \(String(format: "%.6f", pixels.average))，GL \(pixels.error)。四点提取、亮度门控、饱和度处理和 13 点双向模糊；参数来自同一场景快照。"
    }

    private func bind(target: SceneTarget, input: SceneTarget, shader: SceneShader) {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), target.framebuffer)
        glViewport(0, 0, GLsizei(target.width), GLsizei(target.height))
        glUseProgram(shader.program)
        glActiveTexture(GLenum(GL_TEXTURE0)); glBindTexture(GLenum(GL_TEXTURE_2D), input.texture)
        glUniform1i(shader.location("g_Texture0"), 0)
    }

    private static let vertex = """
    attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 uv;
    void main() { gl_Position = vec4(a_Position, 1.0); uv = a_TexCoord; }
    """

    private static let extractFragment = """
    varying vec2 uv;
    uniform sampler2D g_Texture0;
    uniform vec2 sourceTexel;
    uniform float strength;
    uniform float threshold;
    uniform vec3 tint;
    void main() {
        vec3 averageColor = vec3(0.0);
        for (int y = -1; y <= 1; y += 2) {
            for (int x = -1; x <= 1; x += 2) {
                averageColor += texture(g_Texture0, uv + vec2(x, y) * sourceTexel).rgb * 0.25;
            }
        }
        float brightest = max(averageColor.r, max(averageColor.g, averageColor.b));
        vec3 gated = averageColor * clamp(brightest - threshold, 0.0, 1.0);
        float gray = dot(gated, vec3(0.2989, 0.5870, 0.1140));
        vec3 saturated = 2.0 * gated - vec3(gray);
        gl_FragColor = vec4(max(vec3(0.0), saturated * strength * tint), 1.0);
    }
    """

    private static let blurFragment = """
    varying vec2 uv;
    uniform sampler2D g_Texture0;
    uniform vec2 sampleStep;
    const float weights[7] = float[7](0.171834, 0.156756, 0.119007, 0.075189, 0.039533, 0.017298, 0.006299);
    void main() {
        vec3 color = vec3(0.0);
        for (int tap = -6; tap <= 6; tap++) {
            color += texture(g_Texture0, uv + float(tap) * sampleStep).rgb * weights[abs(tap)];
        }
        gl_FragColor = vec4(color, 1.0);
    }
    """
}
