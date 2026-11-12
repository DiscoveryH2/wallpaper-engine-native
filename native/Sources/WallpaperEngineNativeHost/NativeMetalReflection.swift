import Foundation
import Metal

/// Two private pre-bloom histories, ordered on the renderer's command queue.
/// A paused redraw keeps its original input, including after a resize.
@MainActor
final class NativeMetalReflection {
    struct State {
        var buffers: [MTLTexture]
        var sampleIndex = 0, captureIndex = 1
        var sampledTime: Double?, capturedTime: Double?
        var captures: UInt64 = 0, repeats: UInt64 = 0, generation: UInt64 = 1
        var bytes: Int
    }
    final class Frame {
        var state: State
        let time: Double, captureDue: Bool
        var bindings = 0, captured = false
        var sample: MTLTexture { state.buffers[state.sampleIndex] }
        var mipScale: Float {
            Float(max(1, Int(ceil(log2(Double(max(2, min(sample.width, sample.height)))))) - 3))
        }
        init(state: State, time: Double, captureDue: Bool) {
            self.state = state; self.time = time; self.captureDue = captureDue
        }
    }
    // Track paused/resize submissions as well: they can write resized history
    // without capturing a new simulation frame, and GPU errors must not hide
    // behind a later successful submission.
    private struct Completion { let command: MTLCommandBuffer; let capturedTime: Double? }
    private let device: MTLDevice
    private let resizePipelines: [MTLPixelFormat: MTLRenderPipelineState]
    private var state: State?
    private var lastCommand: MTLCommandBuffer?
    private var completions: [Completion] = []
    private var completedCaptures: UInt64 = 0
    private var completedTime: Double?
    private var bindings = 0

    init(device: MTLDevice, resizePipelines: [MTLPixelFormat: MTLRenderPipelineState]) {
        self.device = device; self.resizePipelines = resizePipelines
    }

    static func allocation(width: Int, height: Int, format: MTLPixelFormat) throws -> Int {
        guard (1...4096).contains(width), (1...4096).contains(height),
              [.bgra8Unorm, .rgba8Unorm, .rgba16Float].contains(format) else {
            throw SceneError.invalid("Metal 反射历史的尺寸或格式不受支持。")
        }
        var w = width, h = height, pixels = w * h
        while w > 1 || h > 1 { w = max(1, w / 2); h = max(1, h / 2); pixels += w * h }
        let bytes = pixels * 2 * (format == .rgba16Float ? 8 : 4)
        guard bytes <= 384 * 1024 * 1024 else { throw SceneError.invalid("Metal 反射历史超过 384 MiB。") }
        return bytes
    }

    private func refreshCompleted() {
        while let first = completions.first, first.command.status == .completed {
            if let time = first.capturedTime { completedCaptures &+= 1; completedTime = time }
            completions.removeFirst()
        }
    }

    func begin(width: Int, height: Int, format: MTLPixelFormat, time: Double,
               paused: Bool, command: MTLCommandBuffer) throws -> Frame {
        guard time.isFinite else { throw SceneError.invalid("Metal 反射时间必须为有限数值。") }
        refreshCompleted()
        guard !completions.contains(where: { $0.command.status == .error }) else {
            throw SceneError.invalid("Metal 反射历史的 GPU 捕获失败，不能继续复用历史。")
        }
        if let lastCommand {
            guard [.committed, .scheduled, .completed].contains(lastCommand.status) else {
                throw SceneError.invalid("上一条 Metal 反射命令尚未提交或执行失败，不能复用历史。")
            }
        }
        guard completions.count < 16 else { throw SceneError.invalid("Metal 反射等待 GPU 的帧数超过限制。") }
        let bytes = try Self.allocation(width: width, height: height, format: format)
        var next: State
        if let state, state.buffers[0].width == width, state.buffers[0].height == height,
           state.buffers[0].pixelFormat == format {
            next = state
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: true)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            let buffers = try (0..<2).map { index -> MTLTexture in
                guard let image = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 反射历史。") }
                image.label = "Pre-bloom reflection history \(index)"
                return image
            }
            next = state ?? State(buffers: buffers, bytes: bytes)
            next.buffers = buffers; next.bytes = bytes
            if let state { next.generation = state.generation + 1 }
            for index in 0..<2 {
                let pass = NativeMetalEffects.renderPass(buffers[index])
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法初始化 Metal 反射历史。") }
                if let state {
                    guard state.buffers[index].pixelFormat == format, let pipeline = resizePipelines[format] else {
                        encoder.endEncoding(); throw SceneError.invalid("Metal 反射历史不能跨格式缩放。")
                    }
                    encoder.setRenderPipelineState(pipeline); encoder.setCullMode(.none)
                    encoder.setFragmentTexture(state.buffers[index], index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                }
                encoder.endEncoding()
            }
            guard let blit = command.makeBlitCommandEncoder() else { throw SceneError.invalid("无法生成 Metal 反射初始 mip。") }
            for image in buffers { blit.generateMipmaps(for: image) }
            blit.endEncoding()
        }
        let due = next.capturedTime == nil || (!paused && time > next.capturedTime!)
        if due, let previousTime = next.capturedTime {
            swap(&next.sampleIndex, &next.captureIndex); next.sampledTime = previousTime
        } else if !due { next.repeats &+= 1 }
        return Frame(state: next, time: time, captureDue: due)
    }

    func capture(_ source: MTLTexture, frame: Frame, command: MTLCommandBuffer) throws {
        guard frame.captureDue else { return }
        guard !frame.captured else { throw SceneError.invalid("Metal 反射当前帧已捕获。") }
        let target = frame.state.buffers[frame.state.captureIndex]
        guard !source.isFramebufferOnly, source !== frame.sample, source !== target,
              source.width == target.width, source.height == target.height, source.pixelFormat == target.pixelFormat,
              let encoder = command.makeBlitCommandEncoder() else {
            throw SceneError.invalid("Metal 反射捕获目标不匹配或发生读写冲突。")
        }
        encoder.label = "Capture scene before global bloom"
        encoder.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                     sourceSize: MTLSize(width: source.width, height: source.height, depth: 1), to: target,
                     destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        encoder.generateMipmaps(for: target); encoder.endEncoding()
        frame.state.capturedTime = frame.time; frame.state.captures &+= 1; frame.captured = true
    }

    /// Publish only after the entire Scene and presentation were encoded.
    /// The caller commits immediately; a later frame rejects an unsubmitted
    /// predecessor instead of sampling its uninitialized or stale textures.
    func finish(_ frame: Frame, command: MTLCommandBuffer) throws {
        guard !frame.captureDue || frame.captured else { throw SceneError.invalid("Metal 反射未完成当前帧捕获编码。") }
        state = frame.state; bindings = frame.bindings; lastCommand = command
        completions.append(Completion(command: command, capturedTime: frame.captured ? frame.time : nil))
    }

    var snapshot: [String: Any] {
        refreshCompleted()
        guard let state else { return ["allocated": false] }
        return ["allocated": true, "width": state.buffers[0].width, "height": state.buffers[0].height,
                "format": state.buffers[0].pixelFormat == .rgba16Float ? "RGBA16F" : "RGBA8",
                "bytes": state.bytes, "generation": state.generation, "captures": state.captures,
                "completedCaptures": completedCaptures, "repeats": state.repeats, "bindings": bindings,
                "sampledTime": state.sampledTime as Any? ?? NSNull(), "capturedTime": state.capturedTime as Any? ?? NSNull(),
                "completedTime": completedTime as Any? ?? NSNull(),
                "pendingCaptures": completions.filter { $0.capturedTime != nil }.count, "pendingFrames": completions.count]
    }
    var diagnostic: String {
        let report = snapshot
        guard let state else { return "Metal 模型反射：尚未分配历史。" }
        let sampled = state.sampledTime.map { String(format: "%.6f", $0) } ?? "初始黑色"
        let captured = state.capturedTime.map { String(format: "%.6f", $0) } ?? "未捕获"
        return "Metal 模型反射：\(state.buffers[0].width)×\(state.buffers[0].height)，\(report["format"]!)；历史 \(state.bytes) 字节，代次 \(state.generation)；采样绑定 \(bindings)，采样时间 \(sampled)，已编码捕获时间 \(captured)，捕获 \(state.captures)，GPU 完成捕获 \(completedCaptures)，重复重绘 \(state.repeats)。输入来自全局泛光前的上一场景帧；暂停与缩放保留两份历史。"
    }

    static let shader = """
    fragment float4 reflectionResizeFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]]) {
        uint2 size = uint2(source.get_width(), source.get_height());
        uint2 pixel = min(uint2(clamp(in.uv, 0.0, 1.0) * float2(size)), size - 1);
        return source.read(pixel);
    }
    """
}
