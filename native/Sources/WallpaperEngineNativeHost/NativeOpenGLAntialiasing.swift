import AppKit
import OpenGL.GL3

/// Own the allocating context as well as the attachments: abandoning a
/// prepared display must release its names in the correct GL namespace.
final class NativeOpenGLAntialiasing {
    private let context: NSOpenGLContext
    private(set) var framebuffer: GLuint = 0
    private var color: GLuint = 0, depth: GLuint = 0
    let width: Int, height: Int, samples: Int, bytes: Int
    let hdr: Bool
    init(width: Int, height: Int, hdr: Bool, samples: Int) throws {
        guard let context = NSOpenGLContext.current else { throw SceneError.invalid("抗锯齿缺少 OpenGL 上下文。") }
        self.context = context; self.width = width; self.height = height; self.hdr = hdr; self.samples = samples
        bytes = try NativeAntialiasing.bytes(width: width, height: height, samples: samples, hdr: hdr, depth: true)
        var maximum: GLint = 0; glGetIntegerv(GLenum(GL_MAX_SAMPLES), &maximum)
        guard samples > 1, samples <= maximum else { throw SceneError.invalid("当前 OpenGL 设备不支持 MSAA x\(samples)。") }
        glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        func attachment(_ name: inout GLuint, format: GLenum, slot: GLenum) throws {
            glGenRenderbuffers(1, &name); glBindRenderbuffer(GLenum(GL_RENDERBUFFER), name)
            glRenderbufferStorageMultisample(GLenum(GL_RENDERBUFFER), GLsizei(samples), format, GLsizei(width), GLsizei(height))
            var actual: GLint = 0
            glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_SAMPLES), &actual)
            guard actual == samples, glGetError() == 0 else { throw SceneError.invalid("OpenGL 未能分配准确的 MSAA x\(samples) 缓冲。") }
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), slot, GLenum(GL_RENDERBUFFER), name)
        }
        do {
            try attachment(&color, format: GLenum(hdr ? GL_RGBA16F : GL_RGBA8), slot: GLenum(GL_COLOR_ATTACHMENT0))
            try attachment(&depth, format: GLenum(GL_DEPTH_COMPONENT24), slot: GLenum(GL_DEPTH_ATTACHMENT))
            guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { throw SceneError.invalid("OpenGL 抗锯齿缓冲不完整。") }
        } catch { release(); throw error }
    }
    func resolve(to target: SceneTarget) {
        blit(from: framebuffer, to: target.framebuffer, depth: true)
    }
    func seed(from target: SceneTarget, depth: Bool) {
        blit(from: target.framebuffer, to: framebuffer, depth: depth)
    }
    private func blit(from: GLuint, to: GLuint, depth: Bool) {
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), from); glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), to)
        glBlitFramebuffer(0, 0, GLint(width), GLint(height), 0, 0, GLint(width), GLint(height),
            GLbitfield(GL_COLOR_BUFFER_BIT | (depth ? GL_DEPTH_BUFFER_BIT : 0)), GLenum(GL_NEAREST))
    }
    private func release() {
        if color != 0 { glDeleteRenderbuffers(1, &color); color = 0 }
        if depth != 0 { glDeleteRenderbuffers(1, &depth); depth = 0 }
        if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer); framebuffer = 0 }
    }
    deinit {
        let previous = NSOpenGLContext.current; context.makeCurrentContext(); release()
        if let previous { previous.makeCurrentContext() } else { NSOpenGLContext.clearCurrentContext() }
    }
}
