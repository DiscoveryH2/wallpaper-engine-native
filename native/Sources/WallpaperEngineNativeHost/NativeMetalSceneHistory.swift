import Foundation
import Metal

@MainActor
final class NativeMetalSceneHistory {
    struct Buffer { let color: MTLTexture; let depth: MTLTexture? }
    struct State {
        let buffers: [Buffer]
        var clock = NativeSceneHistoryClock()
        var generation: UInt64 = 1
        let bytes: Int
    }
    final class Frame {
        var state: State
        let time: Double, clearEnabled: Bool, restored: Bool
        var captured = false
        init(state: State, time: Double, clearEnabled: Bool, restored: Bool) {
            self.state = state; self.time = time; self.clearEnabled = clearEnabled; self.restored = restored
        }
    }
    private let device: MTLDevice
    private let colorPipelines: [MTLPixelFormat: MTLRenderPipelineState]
    private let depthPipeline: MTLRenderPipelineState
    private let depthWrite: MTLDepthStencilState
    private let framing: NativeSceneHistoryFraming
    private struct ResizeUniforms { var uv: SIMD4<Float>; var clear: SIMD4<Float> }
    private var state: State?
    private var commands: [MTLCommandBuffer] = []
    private var lastCommand: MTLCommandBuffer?
    private var completed: UInt64 = 0
    private var clearEnabled = true

    init(device: MTLDevice, colorPipelines: [MTLPixelFormat: MTLRenderPipelineState],
         depthPipeline: MTLRenderPipelineState, depthWrite: MTLDepthStencilState, framing: NativeSceneHistoryFraming) {
        self.device = device; self.colorPipelines = colorPipelines
        self.depthPipeline = depthPipeline; self.depthWrite = depthWrite
        self.framing = framing
    }

    static func allocation(width: Int, height: Int, format: MTLPixelFormat, depth: Bool) throws -> Int {
        guard (1...4096).contains(width), (1...4096).contains(height),
              [.bgra8Unorm, .rgba8Unorm, .rgba16Float].contains(format) else {
            throw SceneError.invalid("Metal 场景历史的尺寸或格式不受支持。")
        }
        let bytes = width * height * 2 * ((format == .rgba16Float ? 8 : 4) + (depth ? 4 : 0))
        guard bytes <= 384 * 1024 * 1024 else { throw SceneError.invalid("Metal 场景颜色与深度历史超过 384 MiB。") }
        return bytes
    }

    private func refresh() {
        while commands.first?.status == .completed { commands.removeFirst(); completed &+= 1 }
    }

    func begin(target: MTLTexture, depth: MTLTexture?, time: Double, paused: Bool,
               clearEnabled: Bool, clearColor: SIMD3<Float>, command: MTLCommandBuffer) throws -> Frame {
        refresh()
        guard !commands.contains(where: { $0.status == .error }), commands.count < 16 else {
            throw SceneError.invalid("Metal 场景历史 GPU 失败或待完成帧超过 16，停止复用历史。")
        }
        if let lastCommand {
            guard [.committed, .scheduled, .completed].contains(lastCommand.status),
                  lastCommand.commandQueue === command.commandQueue else {
                throw SceneError.invalid("Metal 场景历史的前帧未提交或命令队列改变。")
            }
        }
        guard !target.isFramebufferOnly, depth == nil || (depth!.width == target.width && depth!.height == target.height && depth!.pixelFormat == .depth32Float) else {
            throw SceneError.invalid("Metal 场景历史需要可复制的颜色和匹配的深度目标。")
        }
        let bytes = try Self.allocation(width: target.width, height: target.height, format: target.pixelFormat, depth: depth != nil)
        var clock = state?.clock ?? NativeSceneHistoryClock()
        let reset = try clock.begin(time: time, paused: paused)
        var next: State
        if let state, state.buffers[0].color.width == target.width, state.buffers[0].color.height == target.height,
           state.buffers[0].color.pixelFormat == target.pixelFormat, (state.buffers[0].depth != nil) == (depth != nil) {
            next = state
        } else {
            if let state {
                guard state.buffers[0].color.pixelFormat == target.pixelFormat,
                      (state.buffers[0].depth != nil) == (depth != nil) else {
                    throw SceneError.invalid("Metal 场景历史不能跨颜色或深度格式复用。")
                }
            }
            func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: target.width, height: target.height, mipmapped: false)
                descriptor.storageMode = .private; descriptor.usage = [.shaderRead, .renderTarget]
                guard let result = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 场景历史。") }
                return result
            }
            let buffers = try (0..<2).map { _ in Buffer(color: try texture(target.pixelFormat), depth: depth == nil ? nil : try texture(.depth32Float)) }
            next = State(buffers: buffers, generation: (state?.generation ?? 0) + 1, bytes: bytes)
            // Copy only initialized histories. On rewind no old pixel may leak.
            if let state, !reset {
                if state.clock.sampledTime != nil { try resize(state.buffers[state.clock.sampleIndex], to: buffers[state.clock.sampleIndex], clearColor: clearColor, command: command) }
                if state.clock.capturedTime != nil { try resize(state.buffers[state.clock.captureIndex], to: buffers[state.clock.captureIndex], clearColor: clearColor, command: command) }
            }
        }
        next.clock = clock
        let restored = !clearEnabled && clock.sampledTime != nil
        if restored { try copy(next.buffers[clock.sampleIndex], to: Buffer(color: target, depth: depth), command: command) }
        return Frame(state: next, time: time, clearEnabled: clearEnabled, restored: restored)
    }

    func capture(target: MTLTexture, depth: MTLTexture?, frame: Frame, command: MTLCommandBuffer) throws {
        guard !frame.captured else { throw SceneError.invalid("Metal 场景历史重复捕获。") }
        try copy(Buffer(color: target, depth: depth), to: frame.state.buffers[frame.state.clock.captureIndex], command: command)
        frame.state.clock.finish(time: frame.time); frame.captured = true
    }

    /// Publish only after presentation has also been encoded. An abandoned or
    /// failed command cannot be mistaken for a valid previous scene frame.
    func finish(_ frame: Frame, command: MTLCommandBuffer) throws {
        guard frame.captured else { throw SceneError.invalid("Metal 场景历史尚未完成捕获。") }
        state = frame.state; clearEnabled = frame.clearEnabled; lastCommand = command; commands.append(command)
    }

    private func copy(_ source: Buffer, to target: Buffer, command: MTLCommandBuffer) throws {
        guard source.color !== target.color, source.color.width == target.color.width,
              source.color.height == target.color.height, source.color.pixelFormat == target.color.pixelFormat,
              (source.depth != nil) == (target.depth != nil), let blit = command.makeBlitCommandEncoder() else {
            throw SceneError.invalid("Metal 场景历史复制的格式或尺寸不匹配。")
        }
        defer { blit.endEncoding() }
        for (a, b) in [(source.color, target.color)] + (source.depth.map { [($0, target.depth!)] } ?? []) {
            guard a !== b else { throw SceneError.invalid("Metal 场景历史读写冲突。") }
            blit.copy(from: a, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: a.width, height: a.height, depth: 1), to: b, destinationSlice: 0,
                destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
    }

    private func resize(_ source: Buffer, to target: Buffer, clearColor: SIMD3<Float>, command: MTLCommandBuffer) throws {
        guard let colorPipeline = colorPipelines[target.color.pixelFormat] else { throw SceneError.invalid("Metal 场景历史缺少缩放管线。") }
        let uv = try framing.sourceUV(from: SIMD2(source.color.width, source.color.height),
            to: SIMD2(target.color.width, target.color.height), topDown: true)
        var uniforms = ResizeUniforms(uv: uv, clear: SIMD4(clearColor, 1))
        let pass = NativeMetalEffects.renderPass(target.color)
        guard let color = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("Metal 场景颜色历史缩放失败。") }
        color.setRenderPipelineState(colorPipeline); color.setCullMode(.none)
        color.setFragmentBytes(&uniforms, length: MemoryLayout<ResizeUniforms>.stride, index: 0)
        color.setFragmentTexture(source.color, index: 0); color.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6); color.endEncoding()
        if let sourceDepth = source.depth, let targetDepth = target.depth {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = targetDepth; pass.depthAttachment.loadAction = .dontCare; pass.depthAttachment.storeAction = .store
            guard let depth = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("Metal 场景深度历史缩放失败。") }
            depth.setRenderPipelineState(depthPipeline); depth.setDepthStencilState(depthWrite); depth.setCullMode(.none)
            depth.setFragmentBytes(&uniforms, length: MemoryLayout<ResizeUniforms>.stride, index: 0)
            depth.setFragmentTexture(sourceDepth, index: 0); depth.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6); depth.endEncoding()
        }
    }

    var snapshot: [String: Any] {
        refresh()
        guard let state else { return ["allocated": false] }
        return ["allocated": true, "width": state.buffers[0].color.width, "height": state.buffers[0].color.height,
            "format": state.buffers[0].color.pixelFormat == .rgba16Float ? "RGBA16F" : "RGBA8", "depth": state.buffers[0].depth != nil,
            "bytes": state.bytes, "generation": state.generation, "frames": state.clock.frames, "redraws": state.clock.redraws,
            "resets": state.clock.resets, "sampledTime": state.clock.sampledTime as Any? ?? NSNull(),
            "capturedTime": state.clock.capturedTime as Any? ?? NSNull(), "completedSubmissions": completed,
            "pendingSubmissions": commands.count, "clearEnabled": clearEnabled]
    }
    var diagnostic: String {
        let report = snapshot
        guard let state else { return "Metal 场景清屏：历史尚未分配。" }
        return "Metal 场景清屏：\(clearEnabled ? "开启" : "关闭")；\(state.buffers[0].color.width)×\(state.buffers[0].color.height)，\(report["format"]!)，\(state.buffers[0].depth == nil ? "无深度图层" : "保留 Depth32Float")，历史 \(state.bytes) 字节，代次 \(state.generation)；场景帧 \(state.clock.frames)，重复重绘 \(state.clock.redraws)，GPU 完成提交 \(completed)。保存全局泛光前的颜色与深度；暂停和缩放保留输入，时间回退重新初始化。"
    }

    static let shader = """
    struct SceneHistoryResizeUniforms { float4 uv; float4 clear; };
    fragment float4 sceneHistoryColorResizeFragment(VertexOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                                    constant SceneHistoryResizeUniforms& u [[buffer(0)]]) {
        float2 uv = in.uv * u.uv.xy + u.uv.zw;
        if (any(uv < 0.0) || any(uv >= 1.0)) return u.clear;
        uint2 size = uint2(source.get_width(), source.get_height());
        return source.read(min(uint2(uv * float2(size)), size - 1));
    }
    struct SceneHistoryDepthOut { float depth [[depth(any)]]; };
    fragment SceneHistoryDepthOut sceneHistoryDepthResizeFragment(VertexOut in [[stage_in]], depth2d<float> source [[texture(0)]],
                                                                 constant SceneHistoryResizeUniforms& u [[buffer(0)]]) {
        float2 uv = in.uv * u.uv.xy + u.uv.zw;
        if (any(uv < 0.0) || any(uv >= 1.0)) return {1.0};
        uint2 size = uint2(source.get_width(), source.get_height());
        uint2 pixel = min(uint2(uv * float2(size)), size - 1);
        return {source.read(pixel)};
    }
    """
}
