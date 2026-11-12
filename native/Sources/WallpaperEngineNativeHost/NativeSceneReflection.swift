import Foundation
import OpenGL.GL3

/// A scene's completed pre-bloom color becomes its next simulation frame's
/// reflection source. Two textures preserve the source during paused redraws.
/// They never alias an active scene draw target or author effect target.
final class NativeSceneReflection {
    private var buffers: [SceneTarget]
    private var sampleIndex = 0
    private var captureIndex = 1
    private var capturedTime: Double?
    private var sampledTime: Double?
    private var captureDue = false
    private var captures: UInt64 = 0
    private var repeatedFrames: UInt64 = 0
    private let generation: UInt64
    let mipMapInfo: Float
    var sampleBindings = 0
    var sample: SceneTarget { buffers[sampleIndex] }

    init(width: Int, height: Int, hdr: Bool, previous: NativeSceneReflection?) throws {
        buffers = try (0..<2).map { _ in
            try SceneTarget(width: width, height: height, withDepth: false, hdr: hdr, mipmapped: true)
        }
        // REA: GLFbo uses ceil(log2(min dimension)) - 3, at least one.
        // OpenGL still generates the complete chain; this scalar is the
        // reference shader's roughness scale, not the allocated level count.
        mipMapInfo = Float(max(1, Int(ceil(log2(Double(max(2, min(width, height)))))) - 3))
        generation = (previous?.generation ?? 0) + 1
        if let previous {
            Self.copy(previous.sample, to: buffers[sampleIndex])
            Self.copy(previous.buffers[previous.captureIndex], to: buffers[captureIndex])
            capturedTime = previous.capturedTime
            sampledTime = previous.sampledTime
            captures = previous.captures
            repeatedFrames = previous.repeatedFrames
        }
    }

    func beginFrame(at time: Double, paused: Bool) {
        sampleBindings = 0
        // The pause click may occur after the last displayed simulation frame.
        // That small wall-clock remainder must not advance frozen history when
        // a reshape requests its first paused redraw.
        captureDue = time.isFinite && (capturedTime == nil || (!paused && time > capturedTime!))
        if captureDue, let capturedTime {
            swap(&sampleIndex, &captureIndex)
            sampledTime = capturedTime
        } else if !captureDue {
            repeatedFrames += 1
        }
    }

    func capture(source: SceneTarget, at time: Double) {
        guard captureDue else { return }
        Self.copy(source, to: buffers[captureIndex])
        capturedTime = time
        captures += 1
        captureDue = false
    }

    private static func copy(_ source: SceneTarget, to destination: SceneTarget) {
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), source.framebuffer)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), destination.framebuffer)
        glBlitFramebuffer(0, 0, GLint(source.width), GLint(source.height),
            0, 0, GLint(destination.width), GLint(destination.height),
            GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), destination.texture)
        glGenerateMipmap(GLenum(GL_TEXTURE_2D))
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
    }

    var runtimeDiagnostic: String {
        let source = sampledTime.map { String(format: "%.6f", $0) } ?? "初始黑色"
        let completed = capturedTime.map { String(format: "%.6f", $0) } ?? "未捕获"
        return "反射运行快照：\(sample.width)×\(sample.height)，\(sample.hdr ? "RGBA16F" : "RGBA8")，mip 粗糙度系数=\(mipMapInfo)，缓冲代次=\(generation)；本帧采样绑定=\(sampleBindings)，采样时间=\(source)，完成时间=\(completed)，捕获=\(captures)，重复时间重绘=\(repeatedFrames)。保存全局泛光前的上一帧场景；缩放保留历史，重复时间不推进反射。"
    }
}
