import Foundation
import OpenGL.GL3
import simd

/// Resize framebuffer history using the same centered aspect-fill (2D) or
/// vertical-FOV (3D) framing as the scene. Camera motion is intentionally not
/// undone: it remains part of the authored trail between simulation frames.
struct NativeSceneHistoryFraming {
    let canvas: SIMD2<Float>?
    var automaticWidth = false

    func sourceUV(from: SIMD2<Int>, to: SIMD2<Int>, topDown: Bool) throws -> SIMD4<Float> {
        guard from.x > 0, from.y > 0, to.x > 0, to.y > 0,
              canvas == nil || (canvas!.x.isFinite && canvas!.y.isFinite && canvas!.x > 0 && canvas!.y > 0) else {
            throw SceneError.invalid("场景历史缩放的画布或输出尺寸无效。")
        }
        func frame(_ size: SIMD2<Int>) -> (size: SIMD2<Double>, center: SIMD2<Double>) {
            let aspect = max(0.001, Double(size.x) / Double(size.y))
            guard let canvas else { return (SIMD2(aspect, 1), .zero) }
            let width = automaticWidth ? Double(canvas.y) * aspect : Double(canvas.x)
            let height = min(Double(canvas.y), width / aspect)
            return (SIMD2(height * aspect, height), SIMD2(width, Double(canvas.y)) / 2)
        }
        let old = frame(from), new = frame(to), scale = new.size / old.size
        var offset = (new.center - old.center) / old.size + (SIMD2<Double>(repeating: 1) - scale) / 2
        if topDown { offset.y = 1 - scale.y - offset.y }
        return SIMD4(Float(scale.x), Float(scale.y), Float(offset.x), Float(offset.y))
    }
}

/// Separates a simulation frame's input from its most recent redraw output.
/// Re-exposing a paused window must not feed that output back into itself.
struct NativeSceneHistoryClock {
    private(set) var sampleIndex = 0, captureIndex = 1
    private(set) var capturedTime: Double?, sampledTime: Double?
    private(set) var frames: UInt64 = 0, redraws: UInt64 = 0, resets: UInt64 = 0
    private var advances = false

    mutating func begin(time: Double, paused: Bool) throws -> Bool {
        guard time.isFinite, time >= 0 else { throw SceneError.invalid("场景历史时间必须是非负有限值。") }
        let reset = !paused && capturedTime.map { time < $0 } == true
        if reset {
            sampleIndex = 0; captureIndex = 1; capturedTime = nil; sampledTime = nil; resets &+= 1
        }
        advances = capturedTime == nil || (!paused && time > capturedTime!)
        if advances, let capturedTime {
            swap(&sampleIndex, &captureIndex); sampledTime = capturedTime
        }
        return reset
    }

    mutating func finish(time: Double) {
        if advances { capturedTime = time; frames &+= 1 }
        else { redraws &+= 1 }
    }
}

/// Color and depth before global bloom, kept independently of scene ping-pong
/// targets. Both histories survive resizing; captures happen on every redraw
/// so a paused property edit becomes the next resumed frame's input.
final class NativeSceneHistory {
    private var buffers: [SceneTarget] = []
    private let framing: NativeSceneHistoryFraming
    private var clock = NativeSceneHistoryClock()
    private var pending: NativeSceneHistoryClock?
    private(set) var generation: UInt64 = 0
    private(set) var clearEnabled = true

    init(framing: NativeSceneHistoryFraming) { self.framing = framing }

    static func allocation(width: Int, height: Int, hdr: Bool) throws -> Int {
        guard (1...4096).contains(width), (1...4096).contains(height) else {
            throw SceneError.invalid("场景历史尺寸超过 4096 边长。")
        }
        let bytes = width * height * 2 * (hdr ? 12 : 8)
        guard bytes <= 384 * 1024 * 1024 else { throw SceneError.invalid("场景颜色与深度历史超过 384 MiB。") }
        return bytes
    }

    /// Returns true when both attachments have been restored and must be loaded.
    func begin(target: SceneTarget, time: Double, paused: Bool, clearEnabled: Bool, clearColor: SIMD3<Float>) throws -> Bool {
        var next = clock
        let reset = try next.begin(time: time, paused: paused)
        _ = try Self.allocation(width: target.width, height: target.height, hdr: target.hdr)
        if let old = buffers.first, old.hdr != target.hdr { throw SceneError.invalid("场景历史不能跨颜色格式保留。") }
        if buffers.first?.width != target.width || buffers.first?.height != target.height {
            let resized = try (0..<2).map { _ in try SceneTarget(width: target.width, height: target.height, hdr: target.hdr) }
            if !reset, let old = buffers.first {
                let uv = try framing.sourceUV(from: SIMD2(old.width, old.height), to: SIMD2(target.width, target.height), topDown: false)
                if clock.sampledTime != nil { try Self.copy(buffers[clock.sampleIndex], to: resized[clock.sampleIndex], uv: uv, clearColor: clearColor) }
                if clock.capturedTime != nil { try Self.copy(buffers[clock.captureIndex], to: resized[clock.captureIndex], uv: uv, clearColor: clearColor) }
            }
            buffers = resized; generation &+= 1
        }
        let restore = !clearEnabled && next.sampledTime != nil
        if restore { try Self.copy(buffers[next.sampleIndex], to: target) }
        pending = next; self.clearEnabled = clearEnabled
        return restore
    }

    func capture(source: SceneTarget, time: Double) throws {
        guard var next = pending else { throw SceneError.invalid("场景历史缺少当前帧。") }
        try Self.copy(source, to: buffers[next.captureIndex])
        next.finish(time: time); clock = next; pending = nil
    }

    private static func copy(_ source: SceneTarget, to target: SceneTarget,
                             uv: SIMD4<Float> = SIMD4(1, 1, 0, 0), clearColor: SIMD3<Float> = .zero) throws {
        guard source !== target, source.hdr == target.hdr, source.depth != 0, target.depth != 0 else {
            throw SceneError.invalid("场景颜色与深度历史目标不匹配。")
        }
        glDisable(GLenum(GL_SCISSOR_TEST))
        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), source.framebuffer)
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), target.framebuffer)
        // Destination bounds may lie outside the viewport; GL clips the blit
        // without changing its scale. Uncovered regions have no old history.
        if source.width != target.width || source.height != target.height || uv != SIMD4(1, 1, 0, 0) {
            glColorMask(GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE))
            glDepthMask(GLboolean(GL_TRUE)); glClearColor(clearColor.x, clearColor.y, clearColor.z, 1); glClearDepth(1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT))
        }
        let x0 = GLint((-Double(uv.z) / Double(uv.x) * Double(target.width)).rounded())
        let y0 = GLint((-Double(uv.w) / Double(uv.y) * Double(target.height)).rounded())
        let x1 = GLint(((1 - Double(uv.z)) / Double(uv.x) * Double(target.width)).rounded())
        let y1 = GLint(((1 - Double(uv.w)) / Double(uv.y) * Double(target.height)).rounded())
        glBlitFramebuffer(0, 0, GLint(source.width), GLint(source.height), x0, y0, x1, y1,
            GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT), GLenum(GL_NEAREST))
        let error = glGetError()
        guard error == 0 else { throw SceneError.invalid("OpenGL 场景历史复制失败：\(error)。") }
    }

    var runtimeDiagnostic: String {
        guard let buffer = buffers.first else { return "场景清屏：历史尚未分配。" }
        let time = clock.capturedTime.map { String(format: "%.6f", $0) } ?? "未捕获"
        return "场景清屏：\(clearEnabled ? "开启" : "关闭")；颜色与深度历史 \(buffer.width)×\(buffer.height)，代次 \(generation)，场景帧 \(clock.frames)，重复重绘 \(clock.redraws)，重置 \(clock.resets)，捕获时间 \(time)。暂停重绘保持输入；尺寸变化按场景裁切保留两份历史；历史位于全局泛光之前。"
    }
}
