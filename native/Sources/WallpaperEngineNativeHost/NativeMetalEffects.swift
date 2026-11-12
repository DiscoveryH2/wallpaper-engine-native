import Foundation
import Metal
import simd

/// Per-frame image effects use tracked private targets. Layers of equal size
/// reuse storage in command order; an input is never sampled while overwritten.
@MainActor
final class NativeMetalEffects {
    /// Source selection may recover only this deterministic, pre-render
    /// capacity rejection. Device/pipeline/asset failures remain real Metal
    /// errors and must not be silently reclassified as compatibility.
    static let frameBudgetError = "Metal 图片效果缓冲超过当前帧 128 MiB 上限。"
    static func isFrameBudgetError(_ error: Error) -> Bool {
        guard case let SceneError.invalid(message) = error else { return false }
        return message == frameBudgetError
    }
    struct Texture {
        let image: MTLTexture
        let resolution: SIMD4<Float>
        let repeating: Bool
        var nearest: Bool = false
    }
    struct Group {
        let source: NativeMetalSceneEffects.Group
        let named: [String: MTLTexture]
    }
    struct Layer {
        let name: String
        let needsBackdrop: Bool
        let working: [MTLTexture]
        let groups: [Group]
    }
    private struct Uniforms {
        var step: SIMD4<Float>
        var maskRect: SIMD4<Float>
        var color: SIMD4<Float>
        var parameters: SIMD4<Float>
        var options: SIMD4<UInt32>
    }
    private let device: MTLDevice
    private let pipelines: [MTLPixelFormat: MTLRenderPipelineState]
    private let samplers: [Bool: MTLSamplerState]
    private let nearestSamplers: [Bool: MTLSamplerState]
    private var textures: [String: Texture]
    private var sources: [NativeMetalSceneSource.Layer]
    /// Graph exporters need a local working texture even when their desktop
    /// layer is hidden or has no authored image effect.  They are prepared
    /// explicitly rather than being smuggled into the ordinary visible set.
    private let exportSources: Set<Int>
    private let hdr: Bool
    private let dynamicEffects: Bool
    private struct Layout: Equatable {
        let objectIndex: Int, width: Int, height: Int
    }
    private struct Target {
        let width: Int, height: Int
        let hdr: Bool
        var bytes: Int { width * height * (hdr ? 8 : 4) }
    }
    /// A clear cannot make a temporal target usable until its command buffer
    /// actually completes. Keep this state separately from the main-actor
    /// renderer, because Metal invokes completion handlers off the main actor.
    /// A clear which has not been scheduled is deliberately not recorded, so
    /// an abandoned/uncommitted command buffer never suppresses a later reset.
    /// We never let one pending command buffer suppress another: reentrant
    /// frames get their own clear rather than assuming queue timing.
    private struct HistoryTicket {
        let texture: ObjectIdentifier
        let command: ObjectIdentifier
        let generation: UInt64
    }
    private final class HistoryState: @unchecked Sendable {
        private enum TerminalOperation {
            case reset(HistoryTicket)
            case historyWrite(HistoryTicket)

            var texture: ObjectIdentifier {
                switch self {
                case let .reset(ticket), let .historyWrite(ticket): return ticket.texture
                }
            }
        }
        private struct Pending {
            let command: ObjectIdentifier
            let generation: UInt64
        }
        private let lock = NSLock()
        private var live = Set<ObjectIdentifier>()
        private var initialized = Set<ObjectIdentifier>()
        private var pending: [ObjectIdentifier: Pending] = [:]
        /// Last scheduled command which copied new temporal state into this
        /// target. A failed later write invalidates history even when its
        /// original clear completed successfully in an earlier frame.
        private var latestHistoryWrite: [ObjectIdentifier: UInt64] = [:]
        /// Tickets join this table only from a scheduled handler. Therefore an
        /// encoded-but-never-committed command cannot poison the next frame.
        /// Terminal processing is explicitly callable by the presentation
        /// owner, rather than depending on relative callback registration
        /// order between effects and the view.
        private var terminal: [ObjectIdentifier: [TerminalOperation]] = [:]
        private var nextGeneration: UInt64 = 0

        func retain(_ identifiers: Set<ObjectIdentifier>) {
            lock.lock(); defer { lock.unlock() }
            live = identifiers
            initialized.formIntersection(identifiers)
            pending = pending.filter { identifiers.contains($0.key) }
            latestHistoryWrite = latestHistoryWrite.filter { identifiers.contains($0.key) }
            terminal = terminal.compactMapValues { operations in
                let retained = operations.filter { identifiers.contains($0.texture) }
                return retained.isEmpty ? nil : retained
            }
        }

        /// Returns nil only if a completed clear or this exact command buffer
        /// already owns a clear. A different command buffer must encode its
        /// own clear; it could still be abandoned or fail before execution.
        func reserve(texture: ObjectIdentifier, command: ObjectIdentifier) -> HistoryTicket? {
            lock.lock(); defer { lock.unlock() }
            guard live.contains(texture), !initialized.contains(texture) else { return nil }
            if let pending = pending[texture], pending.command == command { return nil }
            nextGeneration &+= 1
            return HistoryTicket(texture: texture, command: command, generation: nextGeneration)
        }

        func scheduled(_ ticket: HistoryTicket) {
            lock.lock(); defer { lock.unlock() }
            guard live.contains(ticket.texture), !initialized.contains(ticket.texture) else { return }
            if let existing = pending[ticket.texture], existing.generation > ticket.generation { return }
            pending[ticket.texture] = Pending(command: ticket.command, generation: ticket.generation)
            terminal[ticket.command, default: []].append(.reset(ticket))
        }

        /// Every `copy` into a retained history target receives a completion
        /// ticket. A successful copy needs no state change; a failed newest
        /// write forces a transparent reset before a later retry can sample it.
        func reserveHistoryWrite(texture: ObjectIdentifier, command: ObjectIdentifier) -> HistoryTicket? {
            lock.lock(); defer { lock.unlock() }
            guard live.contains(texture) else { return nil }
            nextGeneration &+= 1
            return HistoryTicket(texture: texture, command: command, generation: nextGeneration)
        }

        func historyWriteScheduled(_ ticket: HistoryTicket) {
            lock.lock(); defer { lock.unlock() }
            guard live.contains(ticket.texture), (latestHistoryWrite[ticket.texture] ?? 0) < ticket.generation else { return }
            latestHistoryWrite[ticket.texture] = ticket.generation
            terminal[ticket.command, default: []].append(.historyWrite(ticket))
        }

        /// Apply every reset/copy state transition for one command exactly
        /// once. The view invokes this synchronously before releasing its
        /// temporal admission token. Per-command fallback callbacks use the
        /// same idempotent path for offscreen/direct renderer clients.
        func finalize(command: ObjectIdentifier, succeeded: Bool) {
            lock.lock(); defer { lock.unlock() }
            let operations = terminal.removeValue(forKey: command) ?? []
            for operation in operations {
                switch operation {
                case let .reset(ticket):
                    guard live.contains(ticket.texture), pending[ticket.texture]?.generation == ticket.generation else { continue }
                    pending[ticket.texture] = nil
                    if succeeded { initialized.insert(ticket.texture) }
                    else { initialized.remove(ticket.texture) }
                case let .historyWrite(ticket):
                    guard live.contains(ticket.texture), latestHistoryWrite[ticket.texture] == ticket.generation else { continue }
                    if !succeeded { initialized.remove(ticket.texture) }
                }
            }
        }
    }
    private var layout: [Layout] = []
    private var pool: [String: MTLTexture] = [:]
    private var layers: [Int: Layer] = [:]
    private(set) var allocatedBytes = 0
    private var layoutChanges = 0, allocations = 0
    private var frameStages = 0, frameGroups = 0, frameLayers = 0, frameCopies = 0
    private(set) var copyCommandCount = 0
    private let historyState = HistoryState()
    private var frameNotes: [String] = []
    private(set) var diagnostics: [String] = []

    /// Presence of a retained target is a static property of the prepared
    /// effect graph. It is intentionally conservative: a currently invisible
    /// group still requires serialized submission because visibility can
    /// change before the next encoded frame.
    var hasRetainedHistory: Bool {
        sources.contains { source in preparedGroups(source).contains { !$0.historyTargets.isEmpty } }
    }

    /// Must run after `command.status` is terminal. This is idempotent so the
    /// renderer's direct/offscreen fallback and the presentation view may both
    /// request it without making callback ordering part of correctness.
    func finishHistorySubmission(_ command: MTLCommandBuffer) {
        historyState.finalize(command: ObjectIdentifier(command), succeeded: command.status == .completed)
    }

    func retire(retainingSlots slots: Set<Int>, textures names: Set<String>) {
        sources.removeAll { !slots.contains($0.objectIndex) }
        textures = textures.filter { names.contains($0.key) }
        layers = layers.filter { slots.contains($0.key) }
        layout.removeAll { !slots.contains($0.objectIndex) }
        let used = Set(layers.values.flatMap { $0.working + $0.groups.flatMap { Array($0.named.values) } }.map { ObjectIdentifier($0) })
        pool = pool.filter { used.contains(ObjectIdentifier($0.value)) }
        historyState.retain(used)
        allocatedBytes = pool.values.reduce(0) { $0 + $1.width * $1.height * ($1.pixelFormat == .rgba16Float ? 8 : 4) }
    }

    init(device: MTLDevice, pipelines: [MTLPixelFormat: MTLRenderPipelineState], hdr: Bool, samplers: [Bool: MTLSamplerState], nearestSamplers: [Bool: MTLSamplerState],
         textures: [String: Texture], sources: [NativeMetalSceneSource.Layer], exportSources: Set<Int> = [], dynamicEffects: Bool) throws {
        self.device = device; self.pipelines = pipelines; self.samplers = samplers; self.textures = textures
        self.nearestSamplers = nearestSamplers
        self.dynamicEffects = dynamicEffects
        self.exportSources = exportSources
        self.sources = sources.filter { !(dynamicEffects ? $0.effects.groups : $0.effects.active).isEmpty || $0.needsBackdrop || exportSources.contains($0.objectIndex) }; self.hdr = hdr
        try prepare(bounds: Dictionary(uniqueKeysWithValues: sources.map { ($0.objectIndex, $0.bounds) }),
                    visible: Set(sources.filter(\.visible).map(\.objectIndex)).union(exportSources))
    }

    private func preparedGroups(_ source: NativeMetalSceneSource.Layer) -> [NativeMetalSceneEffects.Group] {
        dynamicEffects ? source.effects.groups : source.effects.active
    }

    /// Build the complete next frame plan before publishing it. Removed sizes
    /// leave the cache; retained command buffers own any textures still in use.
    /// All commands use the same tracked queue, including reuse across frames.
    func prepare(bounds: [Int: CGRect], visible: Set<Int>) throws {
        var nextLayout: [Layout] = []
        for source in sources where visible.contains(source.objectIndex) || exportSources.contains(source.objectIndex) {
            let bounds = bounds[source.objectIndex] ?? source.bounds
            let size = SIMD2(Float(bounds.width), Float(bounds.height))
            guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0 else { throw SceneError.invalid("Metal 效果图层尺寸无效。") }
            let factor = min(1, 4096 / max(size.x, size.y))
            let width = max(1, Int(ceil(size.x * factor))), height = max(1, Int(ceil(size.y * factor)))
            nextLayout.append(Layout(objectIndex: source.objectIndex, width: width, height: height))
        }
        guard nextLayout != layout else { return }
        var required: [String: Target] = [:]
        func key(width: Int, height: Int, slot: String, hdr: Bool) -> String {
            "\(width)x\(height):\(slot):\(hdr ? "16F" : "8")"
        }
        func require(width: Int, height: Int, slot: String, hdr: Bool) -> String {
            let name = key(width: width, height: height, slot: slot, hdr: hdr)
            required[name] = Target(width: width, height: height, hdr: hdr)
            return name
        }
        var descriptions: [(NativeMetalSceneSource.Layer, [String], [[String: String]])] = []
        for shape in nextLayout {
            let source = sources.first { $0.objectIndex == shape.objectIndex }!
            let width = shape.width, height = shape.height
            // A graph export remains sampled after this source finishes. Its
            // result may be any of the three ping-pong working slots, so all
            // three become object-owned for the full frame. Ordinary effects
            // still share same-size scratch storage after their immediate
            // scene composition, which keeps the pre-existing pool behavior.
            let workingPrefix = exportSources.contains(source.objectIndex) ? "work:export:\(source.objectIndex):" : "work:"
            let working = (0..<3).map { require(width: width, height: height, slot: workingPrefix + String($0), hdr: hdr) }
            var slot = 0, groups: [[String: String]] = []
            for group in preparedGroups(source) {
                var named: [String: String] = [:]
                for (name, spec) in group.targets.sorted(by: { $0.key < $1.key }) {
                    let (w, h) = spec.dimensions(width: width, height: height)
                    // A `unique` target carries frame history. It must not be
                    // aliased with an equally-sized target in another object:
                    // objectIndex is part of its pool identity on purpose.
                    let prefix = spec.unique ? "unique:\(source.objectIndex):" : "named:"
                    named[name] = require(width: w, height: h, slot: prefix + String(slot), hdr: spec.hdr); slot += 1
                }
                groups.append(named)
            }
            descriptions.append((source, working, groups))
        }
        let bytes = required.values.reduce(0) { $0 + $1.bytes }
        guard bytes <= 128 * 1024 * 1024 else { throw SceneError.invalid(Self.frameBudgetError) }
        var nextPool: [String: MTLTexture] = [:], created = 0
        for (name, spec) in required.sorted(by: { $0.key < $1.key }) {
            if let existing = pool[name] { nextPool[name] = existing; continue }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: spec.hdr ? .rgba16Float : .rgba8Unorm, width: spec.width, height: spec.height, mipmapped: false)
            // Texture usage does not expose separate blit-source/destination
            // flags on macOS. The private render target is legal for the
            // explicit copy encoder below; declare only actual MTLTextureUsage
            // members required by rendering and later sampling.
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            guard let image = device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 效果缓冲。") }
            image.label = "Scene effect \(name)"; nextPool[name] = image; created += 1
        }
        var nextLayers: [Int: Layer] = [:]
        for (source, working, groups) in descriptions {
            nextLayers[source.objectIndex] = Layer(name: source.name, needsBackdrop: source.needsBackdrop, working: working.map { nextPool[$0]! },
                groups: zip(preparedGroups(source), groups).map { Group(source: $0.0, named: $0.1.mapValues { nextPool[$0]! }) })
        }
        pool = nextPool
        historyState.retain(Set(nextPool.values.map { ObjectIdentifier($0) }))
        layers = nextLayers; layout = nextLayout; allocatedBytes = bytes
        layoutChanges += 1; allocations += created
    }

    func layer(at objectIndex: Int, visibility: [String: Bool], forLayerCompositeExport: Bool = false) -> Layer? {
        guard let layer = layers[objectIndex], forLayerCompositeExport || layer.needsBackdrop || layer.groups.contains(where: {
            visibility[$0.source.visibilityPath] ?? $0.source.enabled
        }) else { return nil }
        return layer
    }

    func beginFrame() { frameStages = 0; frameGroups = 0; frameLayers = 0; frameCopies = 0; frameNotes.removeAll(keepingCapacity: true) }
    func endFrame(time: Double) {
        guard !sources.isEmpty else { diagnostics = []; return }
        diagnostics = ["Metal 图片效果：本帧编码 \(frameLayers) 层、\(frameGroups) 组、\(frameStages) 个处理阶段（copy \(frameCopies) 次）；场景时间 \(String(format: "%.6f", time)) 秒。缓冲 \(pool.count) 个、\(allocatedBytes) 字节，布局提交 \(layoutChanges) 次、累计分配 \(allocations) 个；仅缓存当前可见尺寸。RGBA8 / RGBA16F 按缓冲声明分配、最长边 4096；GPU 完成由视图帧数单独报告。"] + frameNotes
    }

    /// The caller has rendered the layer's base appearance into working[0].
    /// Named outputs do not replace the accumulated result. `previous` keeps
    /// referring to the entry image for the entire group, even across passes.
    func encode(_ layer: Layer, command: MTLCommandBuffer, parameters: [String: [Float]], visibility: [String: Bool], layerComposites: [String: MTLTexture] = [:]) throws -> MTLTexture {
        var current = layer.working[0]
        let commandIdentifier = ObjectIdentifier(command)
        var clearedInThisCommand = Set<ObjectIdentifier>()
        var historyWritesInThisCommand = Set<ObjectIdentifier>()
        frameLayers += 1
        for group in layer.groups where visibility[group.source.visibilityPath] ?? group.source.enabled {
            for key in group.source.historyTargets.sorted() {
                guard let history = group.named[key] else { throw SceneError.invalid("Metal Motion Blur history target 缺失。") }
                let identifier = ObjectIdentifier(history)
                guard clearedInThisCommand.insert(identifier).inserted,
                      let ticket = historyState.reserve(texture: identifier, command: commandIdentifier) else { continue }
                // The first accumulation pass samples this before any graph
                // write. Define it once per allocated texture; do not repeat
                // the clear on later frames, or temporal accumulation vanishes.
                let descriptor = Self.renderPass(history)
                guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else {
                    throw SceneError.invalid("无法初始化 Metal Motion Blur history。")
                }
                encoder.label = "\(layer.name) / Motion Blur history reset"
                encoder.endEncoding()
                // The handlers intentionally move state only after `commit`:
                // unscheduled buffers can be discarded without causing a
                // future frame to sample private, undefined storage. The
                // state itself is locked because these callbacks are not
                // main-actor isolated.
                let state = historyState
                command.addScheduledHandler { _ in state.scheduled(ticket) }
                command.addCompletedHandler { completed in
                    state.finalize(command: ObjectIdentifier(completed), succeeded: completed.status == .completed)
                }
                if frameNotes.count < 16 { frameNotes.append("\(layer.name)：初始化唯一效果历史 [\(key)] 为透明黑。") }
            }
            let previous = current
            frameGroups += 1
            for pass in group.source.passes {
                if pass.operation == .copy {
                    guard let sourceKey = pass.copySource, let targetKey = pass.target,
                          let source = group.named[sourceKey], let destination = group.named[targetKey],
                          source !== destination, source.width == destination.width, source.height == destination.height,
                          source.pixelFormat == destination.pixelFormat else {
                        throw SceneError.invalid("Metal 效果 copy 需要不同且同规格的命名缓冲。")
                    }
                    guard let blit = command.makeBlitCommandEncoder() else { throw SceneError.invalid("无法开始 Metal 效果 copy。") }
                    blit.label = "\(layer.name) / effect copy \(sourceKey) → \(targetKey)"
                    blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOriginMake(0, 0, 0),
                              sourceSize: MTLSizeMake(source.width, source.height, 1), to: destination,
                              destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOriginMake(0, 0, 0))
                    blit.endEncoding()
                    // A history clear may have completed in a prior frame, but
                    // this write can still fail. Track every retained-history
                    // copy so a retry clears rather than samples partial state.
                    let destinationIdentifier = ObjectIdentifier(destination)
                    if group.source.historyTargets.contains(targetKey), historyWritesInThisCommand.insert(destinationIdentifier).inserted,
                       let ticket = historyState.reserveHistoryWrite(texture: destinationIdentifier, command: commandIdentifier) {
                        let state = historyState
                        command.addScheduledHandler { _ in state.historyWriteScheduled(ticket) }
                        command.addCompletedHandler { completed in
                            state.finalize(command: ObjectIdentifier(completed), succeeded: completed.status == .completed)
                        }
                    }
                    frameCopies += 1; copyCommandCount += 1
                    if frameNotes.count < 16 { frameNotes.append("\(layer.name)：copy \(sourceKey) → \(targetKey) \(source.width)×\(source.height)。") }
                    continue
                }
                let scaleValue = try pass.scale.sampled(parameters), colorValue = try pass.color.sampled(parameters)
                let alpha = try pass.alpha.sampled(parameters)[0]
                let amount = try pass.amount.sampled(parameters)[0]
                if pass.operation == .motionBlurAccumulation,
                   (!amount.isFinite || !(0.01...1).contains(amount)) {
                    throw SceneError.invalid("Metal Motion Blur Accumulation rate 必须在 0.01…1。")
                }
                let scale = SIMD2(scaleValue[0], scaleValue[1]), color = SIMD3(colorValue[0], colorValue[1], colorValue[2])
                func local(_ image: MTLTexture) -> Texture {
                    Texture(image: image, resolution: SIMD4(Float(image.width), Float(image.height), Float(image.width), Float(image.height)), repeating: false)
                }
                var inputs: [Int: Texture] = [:]
                for (slot, input) in pass.inputs {
                    switch input {
                    case .current: inputs[slot] = local(current)
                    case .graph(let name):
                        guard let image = name == SceneEffectGraph.previous ? previous : group.named[name] else { throw SceneError.invalid("Metal 效果命名输入缺失。") }
                        inputs[slot] = local(image)
                    case .texture(let name):
                        guard let image = textures[name] else { throw SceneError.invalid("Metal 效果纹理缺失。") }
                        inputs[slot] = image
                    case .layerComposite(let id):
                        // The caller creates this map afresh in graph
                        // topological order every frame.  There is no cache or
                        // previous-frame fallback for a missing producer.
                        guard let image = layerComposites[id] else { throw SceneError.invalid("Metal 图层纹理源 \(id) 本帧不可用。") }
                        inputs[slot] = local(image)
                    }
                }
                let destination: MTLTexture?
                if let target = pass.target { destination = group.named[target] }
                else { destination = layer.working.first { image in image !== current && image !== previous && !inputs.values.contains { $0.image === image } } }
                guard let destination, !inputs.values.contains(where: { $0.image === destination }), let input = inputs[0] else { throw SceneError.invalid("Metal 效果缺少独立输出，或发生纹理读写冲突。") }
                let descriptor = Self.renderPass(destination)
                guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { throw SceneError.invalid("无法开始 Metal 效果阶段。") }
                encoder.label = "\(layer.name) / \(pass.operation)"
                encoder.setRenderPipelineState(pipelines[destination.pixelFormat]!); encoder.setCullMode(.none)
                let maskSlot = (pass.operation == .precise || pass.operation == .motionBlurAccumulation) ? 2 : 1
                let mask = inputs[maskSlot] ?? input
                let step = pass.vertical ? SIMD2<Float>(0, scale.y / input.resolution.w) : SIMD2<Float>(scale.x / input.resolution.z, 0)
                var uniforms = Uniforms(step: SIMD4(step.x, step.y, 1 / input.resolution.x, 1 / input.resolution.y),
                    maskRect: SIMD4(mask.resolution.z / mask.resolution.x, mask.resolution.w / mask.resolution.y, 0, 0),
                    // Unassociating an almost transparent blur can exceed
                    // half-float range. Bound RGB before target conversion;
                    // an infinity would contaminate interpolation and bloom.
                    color: SIMD4(color, destination.pixelFormat == .rgba16Float ? 65504 : 1),
                    parameters: SIMD4(pass.operation == .motionBlurAccumulation ? amount : alpha, 0, 0, 0),
                    options: SIMD4(pass.operation.rawValue, UInt32(pass.kernel), pass.mask ? 1 : 0, pass.blurAlpha ? 1 : 0))
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                // All three arguments are valid even when the selected kernel
                // does not read a slot; no stale binding from an earlier pass.
                for slot in 0..<3 {
                    let resource = inputs[slot] ?? input
                    encoder.setFragmentTexture(resource.image, index: slot)
                    encoder.setFragmentSamplerState((resource.nearest ? nearestSamplers : samplers)[resource.repeating]!, index: slot)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                encoder.endEncoding()
                if pass.target == nil { current = destination }
                frameStages += 1
                if frameNotes.count < 16 {
                    frameNotes.append("\(layer.name)：\(pass.operation)，kernel=\(pass.kernel)，vertical=\(pass.vertical)，scale=\(scale)，color=\(color)，mask=\(pass.mask)，blurAlpha=\(pass.blurAlpha)，输出 \(destination.width)×\(destination.height) \(destination.pixelFormat == .rgba16Float ? "RGBA16F" : "RGBA8")\(pass.target.map { " [\($0)]" } ?? " [图层]")。")
                }
            }
        }
        return current
    }

    static func renderPass(_ target: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        return pass
    }

    // Independently written MSL; coefficients and operation ordering follow
    // the inspected resource interfaces recorded in METAL_EFFECTS.md.
    static let shader = """
    struct EffectUniforms { float4 step; float4 maskRect; float4 color; float4 parameters; uint4 options; };
    vertex VertexOut effectVertex(uint id [[vertex_id]]) {
        constexpr float2 p[] = {float2(-1,-1),float2(1,-1),float2(1,1),float2(-1,-1),float2(1,1),float2(-1,1)};
        return {float4(p[id], 0, 1), float2(p[id].x * .5 + .5, .5 - p[id].y * .5)};
    }
    float4 preciseBlur(texture2d<float> image, sampler s, float2 uv, float2 step, uint kernelSize) {
        if (kernelSize == 2) return image.sample(s, uv + step) * .25 + image.sample(s, uv) * .5 + image.sample(s, uv - step) * .25;
        if (kernelSize == 1) {
            constexpr float2 taps[] = {float2(2.3515644035337887, .2028175528299753), float2(.4694337796983720, .4044856614512112),
                                      float2(-1.4091998770852121, .3213933537319605), float2(-3, .0713034319868530)};
            float4 result = 0;
            for (uint i = 0; i < 4; ++i) result += image.sample(s, uv + step * taps[i].x) * taps[i].y;
            return result;
        }
        constexpr float2 pairs[] = {float2(1.4091998770852122, .2959855056006557), float2(3.2979348079914822, .0935333619980593), float2(5.2062900776825969, .0116608059608062)};
        float4 result = image.sample(s, uv) * .1976406528809576;
        for (uint i = 0; i < 3; ++i) {
            float2 offset = step * pairs[i].x;
            result += image.sample(s, uv + offset) * pairs[i].y;
            result += image.sample(s, uv - offset) * pairs[i].y;
        }
        return result;
    }
    float4 ordinaryBlur(texture2d<float> image, sampler s, float2 uv, float2 step, uint kernelSize) {
        if (kernelSize == 2) return image.sample(s, uv - step) * .25 + image.sample(s, uv) * .5 + image.sample(s, uv + step) * .25;
        constexpr float weights13[] = {.006299,.017298,.039533,.075189,.119007,.156756,.171834,.156756,.119007,.075189,.039533,.017298,.006299};
        constexpr float weights7[] = {.071303,.131514,.189879,.214607,.189879,.131514,.071303};
        float4 result = 0;
        if (kernelSize == 1) { for (int i = 0; i < 7; ++i) result += image.sample(s, uv + step * float(i - 3)) * weights7[i]; }
        else { for (int i = 0; i < 13; ++i) result += image.sample(s, uv + step * float(i - 6)) * weights13[i]; }
        return result;
    }
    fragment float4 effectFragment(VertexOut in [[stage_in]], constant EffectUniforms &u [[buffer(0)]],
        texture2d<float> a [[texture(0)]], texture2d<float> b [[texture(1)]], texture2d<float> c [[texture(2)]],
        sampler sa [[sampler(0)]], sampler sb [[sampler(1)]], sampler sc [[sampler(2)]]) {
        // Official Motion Blur accumulation: Texture0 is this frame,
        // Texture1 is the unique history target, and an optional Texture2 mask
        // moves the rate toward 1. Its subsequent graph command copies this
        // result into the history target; that copy is encoded separately.
        if (u.options.x == 7) {
            float rate = u.parameters.x;
            if (u.options.z) rate += (1.0 - rate) * (1.0 - c.sample(sc, in.uv * u.maskRect.xy).r);
            return mix(b.sample(sb, in.uv), a.sample(sa, in.uv), rate);
        }
        // The checked Motion Blur combine shader is an identity fullscreen
        // sample from the just-written accumulation target.
        if (u.options.x == 8) return a.sample(sa, in.uv);
        if (u.options.x >= 4 && u.options.x <= 6) {
            float4 source = a.sample(sa, in.uv);
            float coverage = u.options.z ? b.sample(sb, in.uv * u.maskRect.xy).r : 1.0;
            source.a *= coverage * u.parameters.x;
            return source;
        }
        if (u.options.x == 0) {
            float4 result = preciseBlur(a, sa, in.uv, u.step.xy, u.options.y);
            if (u.options.z || !u.options.w) {
                float4 original = b.sample(sb, in.uv);
                if (u.options.z) result = mix(original, result, c.sample(sc, in.uv * u.maskRect.xy).r);
                if (!u.options.w) result.a = original.a;
            }
            return result;
        }
        if (u.options.x == 1) return ordinaryBlur(a, sa, in.uv, u.step.xy, u.options.y);
        if (u.options.x == 2) {
            constexpr float2 corners[] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
            float4 sum = 0; float weight = 0;
            for (uint i = 0; i < 4; ++i) { float4 value = a.sample(sa, in.uv + corners[i] * u.step.zw); sum += value * value.a; weight += value.a; }
            return float4(sum.rgb / max(.001, weight), sum.a * .25);
        }
        float4 result = a.sample(sa, in.uv), original = c.sample(sc, in.uv);
        result.rgb = result.rgb / (result.a > 0 ? result.a : 1) * u.color.rgb;
        if (u.options.z) result = mix(original, result, b.sample(sb, in.uv * u.maskRect.xy).r);
        if (!u.options.w) result.a = original.a;
        // Match the target's representable range after mask composition, as
        // ordinary UNORM conversion does. Clamping before mixing changes masks.
        result.rgb = clamp(result.rgb, float3(-u.color.w), float3(u.color.w));
        return result;
    }
    """
}
