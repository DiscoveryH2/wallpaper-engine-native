import Foundation
import Metal
import CoreGraphics
import simd

/// Metal resources and draw encoding, independent of desktop/editor windows.
/// Asset textures are immutable after upload. Effect targets are bounded and
/// reused in command order; all image paths retain straight RGBA semantics.
@MainActor
final class NativeMetalRenderer {
    @MainActor private final class Context {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let library: MTLLibrary
        let samples: Int
        let msaaColorSeed: [MTLPixelFormat: MTLRenderPipelineState]
        let msaaDepthSeed: MTLRenderPipelineState
        let pipeline: MTLRenderPipelineState
        let scenePipelines: [MTLPixelFormat: [String: MTLRenderPipelineState]]
        let sceneLocalPipelines: [MTLPixelFormat: MTLRenderPipelineState]
        let sceneCompositePipelines: [MTLPixelFormat: [String: MTLRenderPipelineState]]
        let scenePresentation: MTLRenderPipelineState
        let cameraFade: MTLRenderPipelineState
        let modelPipelines: [MTLPixelFormat: [String: MTLRenderPipelineState]]
        let reflectionResize: [MTLPixelFormat: MTLRenderPipelineState]
        let historyColorResize: [MTLPixelFormat: MTLRenderPipelineState]
        let historyDepthResize: MTLRenderPipelineState
        let historyDepthWrite: MTLDepthStencilState
        let pointShadowPipeline: MTLRenderPipelineState
        let pointVolumePipelines: NativeMetalPointVolumetrics.Pipelines
        let particlePipelines: [MTLPixelFormat: [String: MTLRenderPipelineState]]
        let effectPipelines: [MTLPixelFormat: MTLRenderPipelineState]
        let bloomIntermediate: MTLRenderPipelineState
        let bloomPresentation: MTLRenderPipelineState
        let hdrFilter: MTLRenderPipelineState, hdrAdditive: MTLRenderPipelineState, hdrPresentation: MTLRenderPipelineState
        let samplers: [Bool: MTLSamplerState]
        let nearestSamplers: [Bool: MTLSamplerState]
        let depthStates: [Int: MTLDepthStencilState]
        var unavailableReason: String?
        func sampler(repeating: Bool, nearest: Bool) -> MTLSamplerState {
            (nearest ? nearestSamplers : samplers)[repeating]!
        }
        init(samples: Int = 1, shared: Context? = nil) throws {
            guard let device = shared?.device ?? MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
                  device.supportsTextureSampleCount(samples),
                  let queue = shared?.queue ?? device.makeCommandQueue() else { throw SceneError.invalid("无法创建 Apple Silicon Metal 渲染设备。") }
            self.device = device; self.queue = queue; self.samples = samples
            depthStates = try NativeMetalDepth.states(device: device)
            let options = MTLCompileOptions(); options.fastMathEnabled = false
            let library = try shared?.library ?? device.makeLibrary(source: NativeMetalRenderer.shader + NativeMetalParticles.shader + NativeMetalEffects.shader + NativeBlendModes.metal + NativeMetalCompositing.shader + NativeMetalBloom.shader + NativeMetalHDRBloom.shader + NativeMetalPointShadows.shader + NativeSpotShadows.metal + NativeMetalPointVolumetrics.shader + NativeMetalModels.shader + NativeMetalReflection.shader + NativeMetalSceneHistory.shader + NativeMetalCameraFade.shader + NativeMetalAntialiasing.shader, options: options)
            self.library = library
            cameraFade = try NativeMetalCameraFade.pipeline(device: device, library: library)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.rasterSampleCount = samples
            descriptor.label = "Native layered wallpaper"
            descriptor.vertexFunction = library.makeFunction(name: "nativeVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "nativeFragment")
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.isBlendingEnabled = true
            color.rgbBlendOperation = .add; color.alphaBlendOperation = .add
            color.sourceRGBBlendFactor = .sourceAlpha; color.destinationRGBBlendFactor = .oneMinusSourceAlpha
            color.sourceAlphaBlendFactor = .one; color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
            // The Scene presentation pass is opaque. Preserve the cleared
            // alpha=1 even when a non-blended material outputs fractional alpha.
            color.writeMask = [.red, .green, .blue]
            var scenes: [MTLPixelFormat: [String: MTLRenderPipelineState]] = [:]
            for format in [MTLPixelFormat.bgra8Unorm, .rgba16Float] {
                color.pixelFormat = format
                var modes: [String: MTLRenderPipelineState] = [:]
                for mode in ["normal", "translucent", "additive"] {
                    color.isBlendingEnabled = mode != "normal"
                    color.sourceRGBBlendFactor = .sourceAlpha
                    color.destinationRGBBlendFactor = mode == "additive" ? .one : .oneMinusSourceAlpha
                    color.sourceAlphaBlendFactor = mode == "additive" ? .sourceAlpha : .one
                    color.destinationAlphaBlendFactor = mode == "additive" ? .one : .oneMinusSourceAlpha
                    for depth in [false, true] {
                        descriptor.depthAttachmentPixelFormat = depth ? .depth32Float : .invalid
                        modes[mode + (depth ? ".depth" : "")] = try device.makeRenderPipelineState(descriptor: descriptor)
                    }
                }
                scenes[format] = modes
            }
            scenePipelines = scenes
            descriptor.vertexFunction = library.makeFunction(name: "particleVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "particleFragment")
            var particleModes: [MTLPixelFormat: [String: MTLRenderPipelineState]] = [:]
            for format in [MTLPixelFormat.bgra8Unorm, .rgba16Float] {
                color.pixelFormat = format
                var modes: [String: MTLRenderPipelineState] = [:]
                for mode in ["normal", "translucent", "additive"] {
                    color.isBlendingEnabled = mode != "normal"
                    color.sourceRGBBlendFactor = .sourceAlpha
                    color.destinationRGBBlendFactor = mode == "additive" ? .one : .oneMinusSourceAlpha
                    for depth in [false, true] {
                        descriptor.depthAttachmentPixelFormat = depth ? .depth32Float : .invalid
                        modes[mode + (depth ? ".depth" : "")] = try device.makeRenderPipelineState(descriptor: descriptor)
                    }
                }
                particleModes[format] = modes
            }
            particlePipelines = particleModes
            descriptor.vertexFunction = library.makeFunction(name: "modelVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "modelFragment")
            var models: [MTLPixelFormat: [String: MTLRenderPipelineState]] = [:]
            for format in [MTLPixelFormat.bgra8Unorm, .rgba16Float] {
                color.pixelFormat = format
                var modes: [String: MTLRenderPipelineState] = [:]
                for mode in ["normal", "translucent", "additive"] {
                    color.isBlendingEnabled = mode != "normal"
                    color.sourceRGBBlendFactor = .sourceAlpha
                    color.destinationRGBBlendFactor = mode == "additive" ? .one : .oneMinusSourceAlpha
                    for depth in [false, true] {
                        descriptor.depthAttachmentPixelFormat = depth ? .depth32Float : .invalid
                        modes[mode + (depth ? ".depth" : "")] = try device.makeRenderPipelineState(descriptor: descriptor)
                    }
                }
                models[format] = modes
            }
            modelPipelines = models
            let shadowDescriptor = MTLRenderPipelineDescriptor()
            shadowDescriptor.label = "Native point shadow depth"
            shadowDescriptor.vertexFunction = library.makeFunction(name: "pointShadowVertex")
            shadowDescriptor.depthAttachmentPixelFormat = .depth32Float
            pointShadowPipeline = try device.makeRenderPipelineState(descriptor: shadowDescriptor)
            pointVolumePipelines = try NativeMetalPointVolumetrics.Pipelines(device: device, library: library)
            descriptor.vertexFunction = library.makeFunction(name: "sceneVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "sceneFragment")
            descriptor.depthAttachmentPixelFormat = .invalid
            color.writeMask = .all; color.isBlendingEnabled = false
            descriptor.rasterSampleCount = 1
            var locals: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            for format in [MTLPixelFormat.rgba8Unorm, .rgba16Float] {
                color.pixelFormat = format
                locals[format] = try device.makeRenderPipelineState(descriptor: descriptor)
            }
            sceneLocalPipelines = locals
            descriptor.fragmentFunction = library.makeFunction(name: "sceneCompositeFragment")
            descriptor.rasterSampleCount = samples
            var composites: [MTLPixelFormat: [String: MTLRenderPipelineState]] = [:]
            color.writeMask = [.red, .green, .blue]
            for format in [MTLPixelFormat.bgra8Unorm, .rgba16Float] {
                color.pixelFormat = format
                var modes: [String: MTLRenderPipelineState] = [:]
                for mode in ["normal", "translucent", "additive"] {
                    color.isBlendingEnabled = mode != "normal"
                    color.sourceRGBBlendFactor = .sourceAlpha
                    color.destinationRGBBlendFactor = mode == "additive" ? .one : .oneMinusSourceAlpha
                    for depth in [false, true] {
                        descriptor.depthAttachmentPixelFormat = depth ? .depth32Float : .invalid
                        modes[mode + (depth ? ".depth" : "")] = try device.makeRenderPipelineState(descriptor: descriptor)
                    }
                }
                composites[format] = modes
            }
            sceneCompositePipelines = composites
            descriptor.rasterSampleCount = 1
            descriptor.depthAttachmentPixelFormat = .invalid
            color.writeMask = .all; color.isBlendingEnabled = false
            descriptor.vertexFunction = library.makeFunction(name: "effectVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "scenePresentFragment")
            color.pixelFormat = .bgra8Unorm
            scenePresentation = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "effectFragment")
            var effects: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            for format in [MTLPixelFormat.rgba8Unorm, .rgba16Float] {
                color.pixelFormat = format
                effects[format] = try device.makeRenderPipelineState(descriptor: descriptor)
            }
            effectPipelines = effects
            descriptor.fragmentFunction = library.makeFunction(name: "bloomFragment")
            color.pixelFormat = .rgba8Unorm
            bloomIntermediate = try device.makeRenderPipelineState(descriptor: descriptor)
            color.pixelFormat = .bgra8Unorm
            bloomPresentation = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "hdrFragment")
            hdrPresentation = try device.makeRenderPipelineState(descriptor: descriptor)
            color.pixelFormat = .rgba16Float
            hdrFilter = try device.makeRenderPipelineState(descriptor: descriptor)
            color.isBlendingEnabled = true; color.writeMask = [.red, .green, .blue]
            color.sourceRGBBlendFactor = .one; color.destinationRGBBlendFactor = .one
            color.sourceAlphaBlendFactor = .zero; color.destinationAlphaBlendFactor = .one
            hdrAdditive = try device.makeRenderPipelineState(descriptor: descriptor)
            descriptor.fragmentFunction = library.makeFunction(name: "reflectionResizeFragment")
            color.isBlendingEnabled = false; color.writeMask = .all
            var resize: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            for format in [MTLPixelFormat.bgra8Unorm, .rgba8Unorm, .rgba16Float] {
                color.pixelFormat = format
                resize[format] = try device.makeRenderPipelineState(descriptor: descriptor)
            }
            reflectionResize = resize
            descriptor.fragmentFunction = library.makeFunction(name: "sceneHistoryColorResizeFragment")
            var historyResize: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            for format in [MTLPixelFormat.bgra8Unorm, .rgba8Unorm, .rgba16Float] {
                color.pixelFormat = format
                historyResize[format] = try device.makeRenderPipelineState(descriptor: descriptor)
            }
            historyColorResize = historyResize
            let historyDepthDescriptor = MTLRenderPipelineDescriptor()
            historyDepthDescriptor.vertexFunction = library.makeFunction(name: "effectVertex")
            historyDepthDescriptor.fragmentFunction = library.makeFunction(name: "sceneHistoryDepthResizeFragment")
            historyDepthDescriptor.depthAttachmentPixelFormat = .depth32Float
            historyDepthResize = try device.makeRenderPipelineState(descriptor: historyDepthDescriptor)
            let historyWrite = MTLDepthStencilDescriptor()
            historyWrite.depthCompareFunction = .always; historyWrite.isDepthWriteEnabled = true
            guard let historyWriteState = device.makeDepthStencilState(descriptor: historyWrite) else { throw SceneError.invalid("无法创建场景历史深度状态。") }
            historyDepthWrite = historyWriteState
            descriptor.rasterSampleCount = samples
            descriptor.fragmentFunction = library.makeFunction(name: "msaaSeedColor")
            var seedPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
            for format in [MTLPixelFormat.bgra8Unorm, .rgba16Float] {
                color.pixelFormat = format
                seedPipelines[format] = try device.makeRenderPipelineState(descriptor: descriptor)
            }
            msaaColorSeed = seedPipelines
            historyDepthDescriptor.rasterSampleCount = samples
            historyDepthDescriptor.fragmentFunction = library.makeFunction(name: "msaaSeedDepth")
            msaaDepthSeed = try device.makeRenderPipelineState(descriptor: historyDepthDescriptor)
            var preparedSamplers: [Bool: MTLSamplerState] = [:]
            var preparedNearest: [Bool: MTLSamplerState] = [:]
            for repeating in [true, false] {
                let descriptor = MTLSamplerDescriptor()
                descriptor.minFilter = .linear; descriptor.magFilter = .linear; descriptor.mipFilter = .linear
                descriptor.sAddressMode = repeating ? .repeat : .clampToEdge
                descriptor.tAddressMode = repeating ? .repeat : .clampToEdge
                guard let sampler = device.makeSamplerState(descriptor: descriptor) else { throw SceneError.invalid("无法创建 Metal 纹理采样器。") }
                preparedSamplers[repeating] = sampler
                descriptor.minFilter = .nearest; descriptor.magFilter = .nearest; descriptor.mipFilter = .notMipmapped
                guard let nearest = device.makeSamplerState(descriptor: descriptor) else { throw SceneError.invalid("无法创建 Metal 邻近采样器。") }
                preparedNearest[repeating] = nearest
            }
            samplers = preparedSamplers
            nearestSamplers = preparedNearest
        }
    }
    private static let sharedContext = Result { try Context() }
    private static var multisampleContexts: [Int: Context] = [:]
    private static func context(samples: Int) throws -> Context {
        if samples == 1 { return try sharedContext.get() }
        if let context = multisampleContexts[samples] { return context }
        let context = try Context(samples: samples, shared: sharedContext.get())
        multisampleContexts[samples] = context
        return context
    }
    private var context: Context
    private var multisample = NativeMetalAntialiasing(samples: 1)
    private var lastTargetSize: (width: Int, height: Int)?
    var antialiasingQuality: NativeAntialiasing { NativeAntialiasing.allCases.first { $0.samples == context.samples }! }
    var antialiasingSnapshot: [String: Any] {
        ["samples": context.samples, "bytes": multisample.bytes, "generation": multisample.generation,
         "width": multisample.color?.width ?? 0, "height": multisample.color?.height ?? 0,
         "depthSamples": multisample.depth?.sampleCount ?? 0]
    }
    func prepareAntialiasing(_ quality: NativeAntialiasing) throws -> () -> Void {
        guard quality != antialiasingQuality else { return {} }
        let nextContext = try Self.context(samples: quality.samples)
        let next = NativeMetalAntialiasing(samples: quality.samples)
        let size = lastTargetSize ?? (width: 1280, height: 720)
        try next.prepare(device: context.device, width: size.width, height: size.height,
            format: sceneHDR ? .rgba16Float : .bgra8Unorm, withDepth: sceneUsesDepth)
        return { [weak self] in self?.context = nextContext; self?.multisample = next }
    }
    private func seedMultisample(target: MTLTexture, depth: MTLTexture?, command: MTLCommandBuffer) throws {
        try multisample.seed(color: target, depth: depth, command: command,
            colorPipeline: context.msaaColorSeed[target.pixelFormat]!, depthPipeline: context.msaaDepthSeed,
            depthWrite: context.historyDepthWrite)
    }
    let document: NativeCreationDocument?
    var title: String { document?.title ?? sceneTitle }
    var layerCount: Int { document?.layers.count ?? sceneLayers.count }
    var isGeneralScene: Bool { document == nil }
    private(set) var sceneNotes: [String] = []
    private var sceneTitle = ""
    private var sceneCanvas = SIMD3<Float>(1, 1, 1)
    private var sceneClear = SIMD3<Float>.zero
    private var sceneClearEnabled = true
    private var sceneAnimation: NativeMetalSceneAnimation.Runtime?
    private var scriptSource: NativeMetalSceneScript?
    private var initialSceneLayerOrder: NativeSceneLayerOrder?
    private var sceneLayerGraph: NativeMetalSceneLayerGraph?
    private var sceneLifecycle: NativeSceneLifecycle?
    private var authoredFileSignature: Data?
    private let creationQueue = DispatchQueue(label: "io.wallpaper-engine-native.scene-creation", qos: .userInitiated)
    private var lastSceneTime: Double?
    var sceneSnapshot: NativeSceneLifecycle.Snapshot? { sceneLifecycle?.snapshot }
    private(set) var sceneBuiltinFonts: NativeBuiltinFonts.Snapshot?
    var sceneMembershipDidChange: (() -> Void)?
    var sceneResourceCounts: [String: Int] {
        ["layers": sceneLayers.count, "textures": sceneResources.count, "textureBytes": textureBytes,
         "videos": sceneVideos.count, "sounds": sceneSounds?.layers.count ?? 0,
         "models": sceneModels?.scriptSignatures.count ?? 0,
         "particles": sceneLayers.filter { $0.particles != nil }.count,
         "texts": sceneLayers.filter { $0.text != nil }.count,
         "effectBytes": sceneEffects?.allocatedBytes ?? 0]
    }
    private var sceneVideos: [String: SceneVideoRuntime] = [:]
    var preparedVideoLibrary: SceneVideoLibrary { SceneVideoLibrary(entries: sceneVideos.mapValues { .success($0.asset) }) }
    /// Transport telemetry only: this proves presentation owner/clock hand-off
    /// in isolated renderer checks, not physical speaker audibility.
    var videoAudioRuntimeStates: [String: [String: Any]] { sceneVideos.mapValues(\.audioRuntimeState) }
    private var sceneSounds: NativeMetalSound?
    private var sceneAudioOutputEnabled = false
    private var sceneSoundBases: [Int: SceneSoundState] = [:]
    private var videoPTS: [String: Double] = [:]
    weak var sceneScripts: SceneScriptBridge? {
        didSet { sceneScripts?.retirementHandler = retirementHandler; sceneScripts?.creationHandler = creationHandler }
    }
    private var lastSceneFrame: NativeMetalSceneAnimation.Frame?
    private(set) var lastPointerFrame: NativeMetalPointerFrame?
    var needsScriptPointer: Bool { scriptSource?.usesPointer == true }
    var needsParticlePointer: Bool { sceneLayers.contains { $0.particles?.system.hasPointerForces == true } }
    var particlePointerSnapshots: [Int: [String: Any]] {
        Dictionary(uniqueKeysWithValues: sceneLayers.compactMap { layer in
            guard let particles = layer.particles, particles.system.hasPointerForces else { return nil }
            return (layer.source.objectIndex, particles.pointerSnapshot)
        })
    }
    private var sceneEffects: NativeMetalEffects?
    /// The effects instance that encoded each outstanding retained-history
    /// command. A later scene adoption can replace `sceneEffects` while the
    /// old command still owns and writes its private targets, so terminal
    /// finalization must use this exact instance rather than the current one.
    private var temporalHistorySubmissions: [ObjectIdentifier: NativeMetalEffects] = [:]
    private var sceneCompositing: NativeMetalCompositing?
    private var sceneReflection: NativeMetalReflection?
    private(set) var reflectionsEnabled = true
    private(set) var volumetricQuality: NativeVolumetricQuality = .high
    func setVolumetricQuality(_ quality: NativeVolumetricQuality) { volumetricQuality = quality }
    private(set) var shadowQuality: NativeShadowQuality = .high
    func setShadowQuality(_ quality: NativeShadowQuality) { shadowQuality = quality }
    func setReflectionsEnabled(_ enabled: Bool) { reflectionsEnabled = enabled }
    private var sceneHistory: NativeMetalSceneHistory?
    private var sceneBloomState = NativeSceneBloom(general: [:])
    private var sceneBloom: NativeMetalBloom?
    private(set) var postProcessingQuality: NativePostProcessingQuality = .ultra
    private(set) var textureResolutionRequest = NativeTextureResolutionRequest()
    private(set) var textureResolutionCanvas: NativeTextureCanvas = .unknown
    func setTextureResolutionRequest(_ request: NativeTextureResolutionRequest) { textureResolutionRequest = request }
    var postProcessingUsesHDR: Bool { sceneHDR }
    func setPostProcessingQuality(_ quality: NativePostProcessingQuality) { postProcessingQuality = quality }
    private var sceneHDR = false
    private var sceneHDRState = NativeHDRBloomParameters(general: [:])
    private var sceneHDRBloom: NativeMetalHDRBloom?

    /// Used only by the presentation view's admission gate. Direct/offscreen
    /// command clients remain covered by the per-command fallback finalizer.
    var requiresSequentialFrameSubmission: Bool { sceneEffects?.hasRetainedHistory == true }

    private func registerTemporalHistorySubmission(_ command: MTLCommandBuffer) {
        guard let effects = sceneEffects, effects.hasRetainedHistory else { return }
        let identifier = ObjectIdentifier(command)
        temporalHistorySubmissions[identifier] = effects
        // This keeps direct renderer clients (preview/offscreen tests) from
        // depending on the presentation view. The view calls the same
        // idempotent finalizer before releasing its temporal token, so handler
        // registration order is never a correctness condition.
        command.addCompletedHandler { [weak self, effects] completed in
            Task { @MainActor [weak self, effects] in
                effects.finishHistorySubmission(completed)
                self?.removeTemporalHistorySubmission(completed, expected: effects)
            }
        }
    }

    private func registeredCommand(_ command: MTLCommandBuffer) -> MTLCommandBuffer {
        registerTemporalHistorySubmission(command)
        return command
    }

    /// Explicitly completes retained history from the sole production frame
    /// submitter. Call only after the buffer is terminal; safe to repeat after
    /// the direct-client fallback above has already run.
    func finishTemporalSubmission(_ command: MTLCommandBuffer) {
        let identifier = ObjectIdentifier(command)
        guard let effects = temporalHistorySubmissions.removeValue(forKey: identifier) else { return }
        effects.finishHistorySubmission(command)
    }

    /// The view calls this if a command was encoded but never committed. Its
    /// effect tickets have not reached a scheduled handler, so removing the
    /// association cannot make private history appear initialized.
    func discardTemporalSubmission(_ command: MTLCommandBuffer) {
        temporalHistorySubmissions.removeValue(forKey: ObjectIdentifier(command))
    }

    private func removeTemporalHistorySubmission(_ command: MTLCommandBuffer, expected effects: NativeMetalEffects) {
        let identifier = ObjectIdentifier(command)
        guard let registered = temporalHistorySubmissions[identifier], registered === effects else { return }
        temporalHistorySubmissions.removeValue(forKey: identifier)
    }
    private var sceneCamera: NativeMetalSceneCamera.Runtime?
    private var sceneUsesDepth = false
    private var sceneDepthTarget = NativeMetalDepthTarget()
    var usesPointerInput: Bool { sceneCamera?.usesPointerInput == true }
    private struct SceneResource {
        let texture: MTLTexture
        let width: Int, height: Int, channels: Int
        let rect: SIMD4<Float>
        let repeating: Bool
        let animation: SceneTextureAnimation?
        var nearest: Bool = false
        var mipLevel: Int = 0
    }
    @MainActor private struct SceneLayer {
        var source: NativeMetalSceneSource.Layer
        let baseResource: SceneResource?
        var text: NativeMetalText.Runtime?
        let particles: NativeMetalParticles.Runtime?
        var resource: SceneResource {
            if let text { return SceneResource(texture: text.image, width: text.image.width, height: text.image.height,
                channels: 4, rect: SIMD4(0, 0, 1, 1), repeating: false, animation: nil) }
            return baseResource!
        }
        var bounds: CGRect { text?.bounds ?? source.bounds }
    }
    private struct SceneUniforms {
        var transform: simd_float4x4
        var geometry: SIMD4<Float>
        var atlas: SIMD4<Float>
        var color: SIMD4<Float>
        var appearance: SIMD4<Float>
        var background: SIMD4<Float>
        var resolution: SIMD4<Float>
        var composite: SIMD4<UInt32>
    }
    private var sceneLayers: [SceneLayer] = []
    private var sceneModels: NativeMetalModels.Runtime?
    private var scenePointShadows: NativeMetalPointShadows?
    private var scenePointVolumetrics: NativeMetalPointVolumetrics?
    private var scenePointVolumeBoundary: Int?
    private var sceneOrderDiagnostic: String?
    private var sceneResources: [String: SceneResource] = [:]
    private(set) var textureBytes = 0
    var device: MTLDevice { context.device }
    private struct Layer {
        let index: Int
        let texture: MTLTexture
        let bounds: CGRect
        let color: SIMD4<Float>
        let visible: Bool
    }
    private struct Uniforms {
        var projection: SIMD4<Float>
        var geometry: SIMD4<Float>
        var pose: SIMD4<Float>
        var rotationOpacity: SIMD4<Float>
        var color: SIMD4<Float>
    }
    private var layers: [Layer] = []
    private(set) var motions: [NativeCreationMotion]

    init(source: NativeCreationRenderSource) throws {
        context = try Self.sharedContext.get()
        if let error = context.unavailableReason { throw SceneError.invalid(error) }
        document = source.document
        textureResolutionCanvas = .orthographic(width: source.document.width, height: source.document.height)
        motions = source.document.layers.map { $0.motion(duration: source.document.duration, loop: source.document.loop) }
        var usedBytes = 0, textPixels = 0
        var textures: [UUID: MTLTexture] = [:], uploaded: [MTLTexture] = []
        func texture(width: Int, height: Int, rgba: [UInt8], name: String) throws -> MTLTexture {
            guard (1...4096).contains(width), (1...4096).contains(height), rgba.count == width * height * 4 else { throw SceneError.invalid("Metal 图片分配超过范围。") }
            var mipWidth = width, mipHeight = height, allocation = 0
            while true {
                allocation += mipWidth * mipHeight * 4
                if mipWidth == 1 && mipHeight == 1 { break }
                mipWidth = max(1, mipWidth / 2); mipHeight = max(1, mipHeight / 2)
            }
            guard usedBytes + allocation <= 256 * 1024 * 1024 else { throw SceneError.invalid("Metal 多级图片分配超过 256 MiB。") }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let result = context.device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 图层图片。") }
            result.label = name
            rgba.withUnsafeBytes { result.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
            usedBytes += allocation; uploaded.append(result)
            return result
        }
        let white = try texture(width: 1, height: 1, rgba: [255, 255, 255, 255], name: "Solid white")
        var prepared: [Layer] = []
        for (index, layer) in source.document.layers.enumerated() {
            let resource: MTLTexture, size: CGSize, offset: SIMD2<Float>
            switch layer.kind {
            case .solid:
                resource = white; size = CGSize(width: layer.width, height: layer.height); offset = .zero
            case .image:
                guard let id = layer.imageID, let image = source.images[id] else { throw SceneError.invalid("Metal 图层缺少图片。") }
                if let existing = textures[id] { resource = existing }
                else {
                    // Reuse the same PNG -> straight RGBA conversion as Scene.
                    let decoded = try SceneTexture.decode(image.texture())
                    resource = try texture(width: decoded.pixelWidth, height: decoded.pixelHeight, rgba: decoded.rgba, name: layer.name)
                    textures[id] = resource
                }
                size = CGSize(width: layer.width, height: layer.height); offset = .zero
            case .text:
                let object = source.objects[index]
                let layout = try SceneTextLayout(object: object, assets: source.assets)
                guard let bitmap = try layout.rasterize(object), bitmap.width * bitmap.height <= 8 * 1024 * 1024 - textPixels else {
                    throw SceneError.invalid("Metal 文字图片超过合计 8M 像素。")
                }
                textPixels += bitmap.width * bitmap.height
                resource = try texture(width: bitmap.width, height: bitmap.height, rgba: bitmap.rgba, name: layer.name)
                size = CGSize(width: bitmap.width, height: bitmap.height); offset = bitmap.offset
            }
            let rgb = NativeCreationDocument.rgb(layer.color)!
            prepared.append(Layer(index: index, texture: resource,
                                  bounds: CGRect(x: Double(offset.x) - size.width / 2, y: Double(offset.y) - size.height / 2, width: size.width, height: size.height),
                                  color: SIMD4(Float(rgb[0]), Float(rgb[1]), Float(rgb[2]), 1), visible: layer.visible))
        }
        textureBytes = usedBytes; layers = prepared
        let mipmaps = uploaded.filter { $0.mipmapLevelCount > 1 }
        if !mipmaps.isEmpty {
            let descriptor = MTLCommandBufferDescriptor(); descriptor.retainedReferences = true
            guard let command = context.queue.makeCommandBuffer(descriptor: descriptor), let blit = command.makeBlitCommandEncoder() else {
                throw SceneError.invalid("无法准备 Metal 多级图片。")
            }
            command.label = "Native texture mipmaps"
            for image in mipmaps { blit.generateMipmaps(for: image) }
            blit.endEncoding()
            try complete(command, operation: "图片准备")
        }
    }

    init(scene: NativeMetalSceneSource) throws {
        sceneBuiltinFonts = scene.builtinFonts
        context = try Self.sharedContext.get()
        if let error = context.unavailableReason { throw SceneError.invalid(error) }
        document = nil; motions = []
        sceneTitle = scene.title; sceneCanvas = SIMD3(scene.width, scene.height, scene.zoom)
        scenePointVolumeBoundary = scene.pointVolumeBoundary
        sceneUsesDepth = scene.pointVolumeBoundary != nil || scene.layers.contains { layer in
            layer.depth.test || layer.model?.needsDepth == true || layer.particles.map { $0.material.depth.test || $0.children.contains { $0.material.depth.test } } == true
        }
        let needsReflection = scene.layers.contains { $0.model?.needsReflection == true }
        if needsReflection {
            sceneReflection = NativeMetalReflection(device: context.device, resizePipelines: context.reflectionResize)
        }
        if scene.tracksFrameHistory {
            sceneHistory = NativeMetalSceneHistory(device: context.device, colorPipelines: context.historyColorResize,
                depthPipeline: context.historyDepthResize, depthWrite: context.historyDepthWrite,
                framing: NativeSceneHistoryFraming(canvas: scene.camera.orthographic ? scene.camera.canvas : nil))
        }
        if needsReflection || scene.tracksFrameHistory || scene.layers.contains(where: { $0.needsBackdrop }) {
            sceneCompositing = NativeMetalCompositing(device: context.device, presentation: context.scenePresentation)
        }
        sceneClear = scene.clearColor; sceneNotes = scene.diagnostics
        sceneClearEnabled = scene.clearEnabled
        sceneAnimation = try scene.animation.map { try NativeMetalSceneAnimation.Runtime($0) }
        scriptSource = scene.scripts
        initialSceneLayerOrder = scene.layerOrder
        sceneLayerGraph = scene.layerGraph
        sceneLifecycle = NativeSceneLifecycle(snapshot: scene.lifecycleSnapshot)
        authoredFileSignature = scene.authoredFileSignature
        sceneSoundBases = scene.soundStates
        if !scene.sounds.isEmpty { sceneSounds = try NativeMetalSound(sources: scene.sounds, states: scene.soundStates) }
        sceneCamera = NativeMetalSceneCamera.Runtime(scene.camera)
        sceneBloomState = scene.bloom; sceneHDR = scene.hdr; postProcessingQuality = scene.postProcessingQuality; textureResolutionRequest = scene.textureResolutionRequest; textureResolutionCanvas = scene.textureResolutionCanvas; sceneHDRState = scene.hdrBloom
        if scene.hdr {
            sceneHDRBloom = NativeMetalHDRBloom(device: context.device, filter: context.hdrFilter,
                additive: context.hdrAdditive, presentation: context.hdrPresentation, sampler: context.samplers[false]!)
        }
        sceneBloom = NativeMetalBloom(device: context.device, intermediate: context.bloomIntermediate,
            presentation: context.bloomPresentation, sampler: context.samplers[false]!)
        var resources: [String: SceneResource] = [:], uploaded: [MTLTexture] = []
        for (name, source) in scene.textures.sorted(by: { $0.key < $1.key }) {
            let width = source.pixelWidth, height = source.pixelHeight
            guard (1...16384).contains(width), (1...16384).contains(height), source.rgba.count == width * height * 4 else { throw SceneError.invalid("Metal Scene 纹理尺寸或数据无效。") }
            // Atlas mipmaps would mix different animation frames. Retain the
            // base level until per-frame mip generation is implemented.
            let mipmapped = !source.nearest && source.animation == nil && source.video == nil
            var mipWidth = width, mipHeight = height, allocation = width * height * 4
            while mipmapped && (mipWidth > 1 || mipHeight > 1) {
                mipWidth = max(1, mipWidth / 2); mipHeight = max(1, mipHeight / 2)
                allocation += mipWidth * mipHeight * 4
            }
            guard allocation <= 256 * 1024 * 1024 - textureBytes else { throw SceneError.invalid("Metal Scene 多级图片超过 256 MiB。") }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: mipmapped)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            guard let image = context.device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal Scene 图片。") }
            if let video = source.video { sceneVideos[name] = SceneVideoRuntime(video); videoPTS[name] = video.firstFrame.pts }
            image.label = name
            source.rgba.withUnsafeBytes { image.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
            textureBytes += allocation
            if image.mipmapLevelCount > 1 { uploaded.append(image) }
            resources[name] = SceneResource(texture: image, width: source.width, height: source.height, channels: source.channels,
                rect: SIMD4(0, 0, Float(source.imageWidth) / Float(source.width), Float(source.imageHeight) / Float(source.height)), repeating: source.repeating, animation: source.animation, nearest: source.nearest, mipLevel: source.mipLevel)
        }
        // Text images belong to the mutable text runtime. Keeping them in the
        // immutable texture/material tables would retain obsolete first images.
        let textNames = Set(scene.layers.filter { $0.text != nil }.map(\.texture))
        sceneResources = resources.filter { !textNames.contains($0.key) }
        sceneLayers = try scene.layers.map { layer in
            guard let resource = resources[layer.texture] else { throw SceneError.invalid("Metal Scene 图层缺少图片。") }
            let text = try layer.text.map { try NativeMetalText.Runtime($0, image: resource.texture, bounds: layer.bounds) }
            return SceneLayer(source: layer, baseResource: text == nil ? resource : nil, text: text,
                              particles: layer.particles.map { NativeMetalParticles.Runtime($0) })
        }
        let models = scene.layers.compactMap(\.model)
        if !models.isEmpty {
            sceneModels = try NativeMetalModels.Runtime(device: context.device, sources: models, layers: scene.layers)
        }
        if !models.isEmpty || scene.pointVolumeBoundary != nil {
            scenePointShadows = NativeMetalPointShadows(device: context.device, pipeline: context.pointShadowPipeline, depth: context.depthStates[3]!)
        }
        if scene.pointVolumeBoundary != nil {
            scenePointVolumetrics = NativeMetalPointVolumetrics(device: context.device, pipelines: context.pointVolumePipelines, depthDisabled: context.depthStates[0]!)
        }
        let effectTextures = sceneResources.mapValues { resource in
            NativeMetalEffects.Texture(image: resource.texture,
                resolution: SIMD4(Float(resource.width), Float(resource.height), resource.rect.z * Float(resource.width), resource.rect.w * Float(resource.height)),
                repeating: resource.repeating, nearest: resource.nearest)
        }
        sceneEffects = try NativeMetalEffects(device: context.device, pipelines: context.effectPipelines, hdr: scene.hdr,
            samplers: context.samplers, nearestSamplers: context.nearestSamplers, textures: effectTextures, sources: scene.layers,
            exportSources: scene.layerGraph?.producerObjectIndices ?? [], dynamicEffects: scene.scripts != nil)
        if !uploaded.isEmpty {
            let descriptor = MTLCommandBufferDescriptor(); descriptor.retainedReferences = true
            guard let command = context.queue.makeCommandBuffer(descriptor: descriptor), let blit = command.makeBlitCommandEncoder() else { throw SceneError.invalid("无法准备 Metal Scene 多级图片。") }
            command.label = "Scene texture mipmaps"
            for image in uploaded { blit.generateMipmaps(for: image) }
            blit.endEncoding(); try complete(command, operation: "Scene 图片准备")
        }
    }

    var requiresContinuousRedraw: Bool {
        let compositeProducers = sceneLayerGraph?.producerObjectIndices ?? []
        let projectedAnimation = sceneLayers.contains { layer in
            guard layer.source.visible || compositeProducers.contains(layer.source.objectIndex),
                  let model = layer.source.model else { return false }
            for material in model.materials.joined() where material.visible && material.lighting {
                if let texture = material.projectionTexture, sceneResources[texture]?.animation != nil { return true }
            }
            return false
        }
        return projectedAnimation || sceneHistory != nil || (reflectionsEnabled && sceneReflection != nil) || sceneModels?.hasAnimations == true || !sceneVideos.isEmpty || document != nil || sceneScripts?.ready == true || sceneAnimation?.needsFrameUpdates == true || sceneCamera?.needsFrameUpdates == true || sceneLayers.contains { layer in
            (layer.source.visible || compositeProducers.contains(layer.source.objectIndex)) && (layer.particles.map { $0.needsFrameUpdates } ?? (layer.resource.animation != nil))
        }
    }

    var modelAnimationSnapshots: [Int: [String: Any]] { sceneModels?.animationSnapshots ?? [:] }
    var pointVolumetricSnapshot: [String: Any] { scenePointVolumetrics?.snapshot ?? ["allocated": false] }
    var pointShadowSnapshot: [String: Any] { scenePointShadows?.snapshot ?? ["allocated": false] }
    var reflectionSnapshot: [String: Any] { sceneReflection?.snapshot ?? ["allocated": false] }
    var sceneHistorySnapshot: [String: Any] { sceneHistory?.snapshot ?? ["allocated": false] }

    func makeSceneScripts(publication: SceneScriptBridge.Publication = .immediate, resourceRegistry: SceneScriptAssetRegistry? = nil) throws -> SceneScriptBridge? {
        guard let scriptSource, let sceneAnimation else { return nil }
        return try scriptSource.makeBridge(animation: sceneAnimation, sounds: sceneSounds?.scriptStates ?? [:], models: sceneModels?.scriptStore, publication: publication, retirementHandler: retirementHandler, resourceFonts: sceneBuiltinFonts, resourceRegistry: resourceRegistry, creationHandler: creationHandler)
    }

    private var creationHandler: SceneScriptBridge.CreationHandler {
        { [weak self] configuration, time in
            guard let self else { throw SceneError.invalid("创建图层的播放实例已关闭。") }
            return try await prepareCreation(configuration, at: time, previous: self)
        }
    }

    private func prepareCreation(_ configuration: Data, at time: Double, previous: NativeMetalRenderer) async throws -> SceneScriptPreparedCreation {
        guard let source = previous.scriptSource, let snapshot = previous.sceneSnapshot, let revision = sceneSnapshot?.revision else {
            throw SceneError.invalid("当前播放实例没有可扩展的场景资源。")
        }
        let projectURL = source.projectURL
        let properties = try JSONSerialization.data(withJSONObject: source.properties, options: [.sortedKeys])
        let plan = try await NativeResourceWork.run(on: creationQueue) { _ in
            try NativeSceneCreationPlan(projectURL: projectURL, properties: properties, snapshot: snapshot, configuration: configuration)
        }
        let videos = try await SceneVideoLibrary.prepare(project: plan.project, snapshot: plan.snapshot)
        let postProcessing = previous.postProcessingQuality
        let textureResolution = previous.textureResolutionRequest
        let fontSelection = NativeMetalSceneSource.FontSelection.snapshot(previous.sceneBuiltinFonts)
        let prepared = try await NativeResourceWork.run(on: creationQueue) { _ in
            try NativePreparedSceneCreation(plan: plan, source: NativeMetalSceneSource.load(plan.project, properties: plan.properties, videos: videos, snapshot: plan.snapshot, fontSelection: fontSelection, postProcessing: postProcessing, textureResolution: textureResolution))
        }
        try Task.checkCancellation()
        guard sceneSnapshot?.revision == revision, prepared.source.authoredFileSignature == authoredFileSignature else {
            throw SceneError.invalid("场景在创建准备期间改变，保留现有画面。")
        }
        let candidate = try NativeMetalRenderer(scene: prepared.source)
        try candidate.preserveInsertionRuntime(from: previous, slots: snapshot.activeSlots, at: time)
        let resources = try candidate.preparedScriptInventory(at: time)
        return SceneScriptPreparedCreation(id: plan.id, inventory: resources.inventory, timelines: resources.timelines, models: resources.models,
            next: { [weak self, candidate] configuration, time in
                guard let self else { throw SceneError.invalid("创建图层的播放实例已关闭。") }
                return try await self.prepareCreation(configuration, at: time, previous: candidate)
            }, prepareCommit: { [weak self, candidate] retired, order in
                guard let self, self.sceneSnapshot?.revision == revision else { throw SceneError.invalid("创建图层结果已过期。") }
                // Refresh surviving clocks again at publication; a visible old
                // frame may have progressed while the helper was preparing.
                try candidate.preserveInsertionRuntime(from: self, slots: self.sceneSnapshot!.activeSlots, at: max(self.lastSceneTime ?? time, time))
                let retirement = retired.isEmpty ? nil : try candidate.prepareRetirement(retired, order: order)
                return { [weak self, candidate] in
                    guard let self else { return }
                    retirement?()
                    self.adoptCreatedScene(candidate)
                }
            })
    }

    private func preserveInsertionRuntime(from previous: NativeMetalRenderer, slots: Set<Int>, at time: Double) throws {
        context = previous.context; multisample = previous.multisample; lastTargetSize = previous.lastTargetSize
        reflectionsEnabled = previous.reflectionsEnabled; shadowQuality = previous.shadowQuality; volumetricQuality = previous.volumetricQuality
        if let current = sceneAnimation, let old = previous.sceneAnimation {
            try current.preserveInsertionRuntime(from: old, slots: slots, at: time)
        }
        if let current = sceneModels, let old = previous.sceneModels { current.preserveForInsertion(from: old, slots: slots) }
        if let current = sceneSounds, let old = previous.sceneSounds { current.preserveForInsertion(from: old) }
        let old = Dictionary(uniqueKeysWithValues: previous.sceneLayers.map { ($0.source.objectIndex, $0) })
        for index in sceneLayers.indices where slots.contains(sceneLayers[index].source.objectIndex) {
            if let layer = old[sceneLayers[index].source.objectIndex] { sceneLayers[index] = layer }
        }
        for (name, resource) in previous.sceneResources where sceneResources[name] != nil { sceneResources[name] = resource }
        for (name, runtime) in previous.sceneVideos where sceneVideos[name]?.asset.signature == runtime.asset.signature {
            sceneVideos[name] = runtime; videoPTS[name] = nil
        }
        if let camera = sceneCamera, let old = previous.sceneCamera { camera.preserveState(from: old) }
        if sceneUsesDepth && previous.sceneUsesDepth { sceneDepthTarget = previous.sceneDepthTarget }
        if sceneHistory != nil { sceneHistory = previous.sceneHistory ?? sceneHistory }
        if sceneReflection != nil { sceneReflection = previous.sceneReflection ?? sceneReflection }
        if sceneCompositing != nil { sceneCompositing = previous.sceneCompositing ?? sceneCompositing }
        sceneBloom = previous.sceneBloom
        if sceneHDR { sceneHDRBloom = previous.sceneHDRBloom ?? sceneHDRBloom }
        textureBytes = sceneResources.values.reduce(0) { total, resource in
            var bytes = 0, width = resource.texture.width, height = resource.texture.height
            for _ in 0..<resource.texture.mipmapLevelCount { bytes += width * height * 4; width = max(1, width / 2); height = max(1, height / 2) }
            return total + bytes
        } + sceneLayers.compactMap(\.text).reduce(0) { $0 + $1.bytes }
        guard textureBytes <= 256 * 1024 * 1024 else { throw SceneError.invalid("创建后保留的纹理超过 256 MiB。") }
    }

    /// Called only after the helper's complete response has validated. Keep the
    /// same renderer/view and helper, so desktop windows and callbacks survive.
    private func adoptCreatedScene(_ candidate: NativeMetalRenderer) {
        if let current = sceneSounds, let prepared = candidate.sceneSounds {
            current.adoptPrepared(prepared); candidate.sceneSounds = current
        }
        sceneTitle = candidate.sceneTitle; sceneCanvas = candidate.sceneCanvas
        sceneClear = candidate.sceneClear; sceneClearEnabled = candidate.sceneClearEnabled
        sceneNotes = candidate.sceneNotes; sceneAnimation = candidate.sceneAnimation
        scriptSource = candidate.scriptSource; initialSceneLayerOrder = candidate.initialSceneLayerOrder; sceneLayerGraph = candidate.sceneLayerGraph
        sceneLifecycle = candidate.sceneLifecycle; authoredFileSignature = candidate.authoredFileSignature; sceneBuiltinFonts = candidate.sceneBuiltinFonts
        sceneLayers = candidate.sceneLayers; sceneResources = candidate.sceneResources; textureBytes = candidate.textureBytes
        sceneModels = candidate.sceneModels; sceneVideos = candidate.sceneVideos; videoPTS = candidate.videoPTS
        sceneSounds = candidate.sceneSounds; sceneSoundBases = candidate.sceneSoundBases
        sceneSounds?.setOutputEnabled(sceneAudioOutputEnabled)
        for runtime in sceneVideos.values { runtime.setAudioOutputEnabled(sceneAudioOutputEnabled) }
        sceneEffects = candidate.sceneEffects; sceneCompositing = candidate.sceneCompositing
        sceneReflection = candidate.sceneReflection; sceneHistory = candidate.sceneHistory
        sceneBloom = candidate.sceneBloom; sceneBloomState = candidate.sceneBloomState
        context = candidate.context; multisample = candidate.multisample; lastTargetSize = candidate.lastTargetSize
        postProcessingQuality = candidate.postProcessingQuality
        textureResolutionRequest = candidate.textureResolutionRequest; textureResolutionCanvas = candidate.textureResolutionCanvas
        sceneHDR = candidate.sceneHDR; sceneHDRState = candidate.sceneHDRState; sceneHDRBloom = candidate.sceneHDRBloom
        sceneCamera = candidate.sceneCamera; sceneUsesDepth = candidate.sceneUsesDepth; sceneDepthTarget = candidate.sceneDepthTarget
        scenePointShadows = candidate.scenePointShadows; scenePointVolumetrics = candidate.scenePointVolumetrics
        scenePointVolumeBoundary = candidate.scenePointVolumeBoundary; sceneOrderDiagnostic = nil
        lastSceneFrame = nil; lastPointerFrame = nil
        sceneMembershipDidChange?()
    }

    private var retirementHandler: SceneScriptBridge.RetirementHandler {
        { [weak self] ids, order in
            guard let self else { throw SceneError.invalid("图层所属播放窗口已关闭。") }
            return try prepareRetirement(ids, order: order)
        }
    }

    private func prepareRetirement(_ ids: Set<String>, order: [String]) throws -> () -> Void {
        guard let sceneLifecycle, let scriptSource, let sceneAnimation else { throw SceneError.invalid("当前场景没有可删除的原生资源。") }
        let handles = ids.compactMap { sceneLifecycle.snapshot.handle(id: $0) }
        guard handles.count == ids.count else { throw SceneError.invalid("待删除图层与活动原生场景不一致。") }
        let transition = try sceneLifecycle.prepare(retiring: handles, order: order)
        let snapshot = transition.snapshot
        let nextLifecycle = NativeSceneLifecycle(snapshot: snapshot)
        let nextScripts = try scriptSource.retiring(to: snapshot)
        let commitAnimation = try sceneAnimation.prepareRetirement(to: snapshot)
        let slots = snapshot.activeSlots
        var nextLayers = sceneLayers.filter { slots.contains($0.source.objectIndex) }
        for index in nextLayers.indices {
            if let parent = nextLayers[index].source.parentIndex, !slots.contains(parent) { nextLayers[index].source.parentIndex = nil }
        }
        var textures = Set(nextLayers.map { $0.source.texture })
        for layer in nextLayers {
            if let particles = layer.source.particles {
                textures.insert(particles.material.texture)
                textures.formUnion(particles.children.map { $0.material.texture })
            }
            if let model = layer.source.model { textures.formUnion(model.materials.flatMap { $0 }.flatMap(\.textures)) }
            for pass in layer.source.effects.groups.flatMap(\.passes) {
                for input in pass.inputs.values { if case .texture(let name) = input { textures.insert(name) } }
            }
        }
        let nextOrder = try NativeSceneLayerOrder(objects: nextScripts.scene["objects"] as! [[String: Any]], activeSlots: slots, order: order)
        let hierarchy = SceneHierarchy(objects: nextScripts.scene["objects"] as! [[String: Any]])
        return { [weak self] in
            guard let self else { return }
            // Existing command buffers retain their GPU resources. Surviving
            // runtime objects keep their identity; no clock/player is rebuilt.
            commitAnimation()
            self.sceneLifecycle = nextLifecycle; self.scriptSource = nextScripts
            self.sceneLayers = nextLayers; self.initialSceneLayerOrder = nextOrder
            self.sceneCamera?.detachParents(hierarchy: hierarchy)
            self.sceneModels?.retire(ids: ids, retaining: nextLayers.map(\.source))
            self.sceneSounds?.retire(ids)
            self.sceneSoundBases = self.sceneSoundBases.filter { slots.contains($0.key) }
            self.sceneResources = self.sceneResources.filter { textures.contains($0.key) }
            self.sceneVideos = self.sceneVideos.filter { textures.contains($0.key) }
            self.videoPTS = self.videoPTS.filter { textures.contains($0.key) }
            self.sceneEffects?.retire(retainingSlots: slots, textures: textures)
            self.textureBytes = self.sceneResources.values.reduce(0) { total, resource in
                var bytes = 0, width = resource.texture.width, height = resource.texture.height
                for _ in 0..<resource.texture.mipmapLevelCount { bytes += width * height * 4; width = max(1, width / 2); height = max(1, height / 2) }
                return total + bytes
            } + nextLayers.compactMap(\.text).reduce(0) { $0 + $1.bytes }
            self.lastSceneFrame = nil; self.lastPointerFrame = nil
            self.sceneMembershipDidChange?()
        }
    }

    /// Resources already exist on this candidate renderer. Preparing their
    /// script inventory never starts another VM or changes the current view.
    func preparedScriptInventory(at time: Double) throws -> (inventory: SceneScriptInventory, timelines: SceneTimelines, models: NativeModelScriptStore?) {
        guard let scriptSource, let sceneAnimation else { throw SceneError.invalid("候选场景没有脚本资源描述。") }
        return (try scriptSource.makeInventory(animation: sceneAnimation, sounds: sceneSounds?.scriptStates ?? [:], at: time),
                sceneAnimation.timelineStore, sceneModels?.scriptStore)
    }

    var requiresSoundUpdates: Bool { sceneSounds?.requiresUpdates ?? false }
    var soundRuntimeStates: [[String: Any]] { sceneSounds?.layers.map(\.runtimeState) ?? [] }
    func setAudioOutputEnabled(_ enabled: Bool) {
        sceneAudioOutputEnabled = enabled
        sceneSounds?.setOutputEnabled(enabled)
        // Stop a retiring/secondary presentation synchronously instead of
        // leaving a duplicated-audio tail until a later draw callback.
        for runtime in sceneVideos.values { runtime.setAudioOutputEnabled(enabled) }
    }
    func suspendSounds() {
        sceneSounds?.suspend()
        for runtime in sceneVideos.values { runtime.suspendAudio() }
    }
    func refreshSounds(active: Bool) {
        sceneSounds?.refresh(states: lastSceneFrame?.sounds ?? sceneSoundBases, scripts: sceneScripts, active: active)
        guard let time = lastSceneTime else { return }
        for (key, runtime) in sceneVideos {
            runtime.syncAudio(playback: sceneScripts?.videoPlayback[key], sceneTime: time,
                              active: active, outputEnabled: sceneAudioOutputEnabled)
        }
    }

    func onVideoFrame(_ callback: @escaping @Sendable () -> Void) {
        for runtime in sceneVideos.values { runtime.setDidDecode(callback) }
    }
    func videosReady(at time: Double) throws -> Bool {
        var ready = true
        for (key, video) in sceneVideos {
            let playhead = sceneScripts?.videoPlayback[key]?.time(at: time, duration: video.asset.duration)
                ?? time.truncatingRemainder(dividingBy: video.asset.duration)
            if try !video.ready(at: playhead) { ready = false }
        }
        return ready
    }

    func validateScriptContinuity(from previous: NativeMetalRenderer) throws {
        guard authoredFileSignature == previous.authoredFileSignature else {
            throw SceneError.invalid("原始场景文件在设置期间发生变化，请等待项目重新加载后再应用设置。")
        }
        guard (sceneModels?.scriptSignatures ?? [:]) == (previous.sceneModels?.scriptSignatures ?? [:]) else {
            throw SceneError.invalid("模型动画资源在设置期间发生变化，请重新加载项目。")
        }
        guard scriptSource?.signature == previous.scriptSource?.signature else {
            throw SceneError.invalid("Scene 脚本或结构在设置期间发生变化，请重新加载项目后再修改设置。")
        }
        guard (sceneSounds?.signatures ?? []) == (previous.sceneSounds?.signatures ?? []) else {
            throw SceneError.invalid("声音资源或播放模式在设置期间发生变化，请重新加载项目。")
        }
    }

    func updateScripts(time: Double, size: CGSize, input: [String: Any] = [:]) {
        guard let scripts = sceneScripts else { return }
        scripts.publishForRendering()
        scripts.frame(runtime: time, screen: ["x": size.width, "y": size.height], input: input,
            audio: NativeAudioService.shared.active ? NativeAudioService.shared.snapshot : SceneMusicSpectrum.shared.snapshot,
            sounds: sceneSounds?.scriptStates ?? [:],
            timelineValues: sceneAnimation?.scriptInput(at: time) ?? [:])
    }

    func preserveSceneRuntime(from previous: NativeMetalRenderer) {
        setAudioOutputEnabled(previous.sceneAudioOutputEnabled)
        context = previous.context; multisample = previous.multisample; lastTargetSize = previous.lastTargetSize
        reflectionsEnabled = previous.reflectionsEnabled; shadowQuality = previous.shadowQuality; volumetricQuality = previous.volumetricQuality
        if let sceneModels, let old = previous.sceneModels { sceneModels.preserveGeometry(from: old) }
        if sceneUsesDepth && previous.sceneUsesDepth { sceneDepthTarget = previous.sceneDepthTarget }
        if (sceneSounds?.signatures ?? []) == (previous.sceneSounds?.signatures ?? []) { sceneSounds = previous.sceneSounds }
        for (key, runtime) in sceneVideos {
            if let old = previous.sceneVideos[key], old.asset.signature == runtime.asset.signature {
                sceneVideos[key] = old; videoPTS[key] = nil
            }
        }
        if let sceneAnimation, let previous = previous.sceneAnimation { sceneAnimation.preserveClock(from: previous) }
        // Property commits retain the view, clock, and size-keyed scratch
        // textures. The new description still supplies the new parameters.
        if document == nil, previous.document == nil {
            sceneBloom = previous.sceneBloom
            if scenePointVolumetrics != nil, sceneHDR == previous.sceneHDR, let old = previous.scenePointVolumetrics { scenePointVolumetrics = old }
            if sceneHDR == previous.sceneHDR, let previousHDR = previous.sceneHDRBloom { sceneHDRBloom = previousHDR }
            if sceneReflection != nil, sceneHDR == previous.sceneHDR, let history = previous.sceneReflection { sceneReflection = history }
            if sceneHistory != nil, sceneHDR == previous.sceneHDR, sceneUsesDepth == previous.sceneUsesDepth,
               let history = previous.sceneHistory { sceneHistory = history }
            if sceneCompositing != nil, sceneHDR == previous.sceneHDR, let previous = previous.sceneCompositing { sceneCompositing = previous }
        }
        if let sceneCamera, let previous = previous.sceneCamera { sceneCamera.preserveState(from: previous) }
        let old = Dictionary(uniqueKeysWithValues: previous.sceneLayers.map { ($0.source.objectIndex, $0) })
        for index in sceneLayers.indices {
            let layer = sceneLayers[index]
            if let particles = layer.particles, let previous = old[layer.source.objectIndex]?.particles { particles.preserve(from: previous) }
            if let text = layer.text, let previous = old[layer.source.objectIndex]?.text, text.signature == previous.signature,
               textureBytes - text.bytes + previous.bytes <= 256 * 1024 * 1024 {
                textureBytes += previous.bytes - text.bytes
                sceneLayers[index].text = previous
            }
        }
    }

    func animationNotes(at time: Double) -> [String] {
        let textures = sceneLayers.compactMap { layer -> String? in
            guard layer.particles == nil, let animation = layer.resource.animation else { return nil }
            let playhead = lastSceneFrame?.layers[layer.source.objectIndex].textureTime ?? time
            return "TEX 动画 \(layer.source.name)：第 \(animation.index(at: playhead) + 1)/\(animation.frames.count) 帧，周期 \(animation.duration) 秒，采样时间 \(playhead) 秒。"
        }.prefix(8).map { $0 }
        var notes = textures + sceneVideos.keys.sorted().compactMap { key in
            sceneVideos[key].map { $0.diagnostic + String(format: " · Metal 上传 PTS %.3f", videoPTS[key] ?? -1) + " · " + key }
        }
        notes += sceneAnimation?.diagnostics ?? []
        if let snapshot = sceneSnapshot {
            notes.append("Scene 运行结构：修订 \(snapshot.revision)，\(snapshot.count) 个活动图层；前 12 项 ID=\(snapshot.orderedIDs.prefix(12).joined(separator: ","))。脚本增删在完整回执发布时提交。")
        }
        if let sceneModels { notes.append(sceneModels.diagnostic) }
        if let scenePointShadows { notes.append(scenePointShadows.diagnostic) }
        if let scenePointVolumetrics { notes.append(scenePointVolumetrics.diagnostic) }
        if let sceneOrderDiagnostic { notes.append(sceneOrderDiagnostic) }
        if let sceneReflection { notes.append(sceneReflection.diagnostic) }
        if let sceneHistory { notes.append(sceneHistory.diagnostic) }
        notes += sceneSounds?.diagnostics ?? []
        notes += sceneEffects?.diagnostics ?? []
        notes += sceneCompositing?.diagnostics ?? []
        notes.append("全局抗锯齿：\(antialiasingQuality.title)；实际场景采样数 \(context.samples)，抗锯齿缓冲 \(multisample.bytes) 字节。")
        notes.append("全局纹理分辨率：\(textureResolutionRequest.quality.title)；请求跳过 \(textureResolutionRequest.preferredMip(canvas: textureResolutionCanvas)) 层，实际使用较小纹理 \(sceneResources.values.filter { $0.mipLevel > 0 }.count)/\(sceneResources.count) 张；GPU 图片含生成 mip \(textureBytes) 字节。")
        notes.append("全局后处理：\(postProcessingQuality.title)，场景缓冲 \(sceneHDR ? "RGBA16F" : "RGBA8")；最终输出 SDR。")
        notes += sceneHDR ? (sceneHDRBloom?.diagnostics ?? []) : (sceneBloom?.diagnostics ?? [])
        notes += sceneCamera?.diagnostics ?? []
        if sceneUsesDepth { notes.append(sceneDepthTarget.diagnostic) }
        for layer in sceneLayers {
            if let particles = layer.particles { notes += particles.diagnostics.map { layer.source.name + "：" + $0 } }
            if let text = layer.text { notes += text.diagnostics.map { layer.source.name + "：" + $0 } }
        }
        return notes
    }

    private func prepareSceneVideos(_ command: MTLCommandBuffer, time: Double) throws {
        for key in sceneVideos.keys.sorted() {
            guard let video = sceneVideos[key], let resource = sceneResources[key] else { continue }
            let playhead = sceneScripts?.videoPlayback[key]?.time(at: time, duration: video.asset.duration)
                ?? time.truncatingRemainder(dividingBy: video.asset.duration)
            let frame = try video.frame(at: playhead)
            guard videoPTS[key] != frame.pts else { continue }
            // GPU queue order protects previous readers. Never overwrite a
            // texture from the CPU while a submitted frame is sampling it.
            let row = ((video.asset.width * 4 + 255) / 256) * 256
            guard let buffer = context.device.makeBuffer(length: row * video.asset.height, options: .storageModeShared),
                  let blit = command.makeBlitCommandEncoder() else { throw SceneError.invalid("无法提交 Scene 视频帧。") }
            frame.rgba.withUnsafeBytes { bytes in
                for y in 0..<video.asset.height { memcpy(buffer.contents().advanced(by: y * row), bytes.baseAddress!.advanced(by: y * video.asset.width * 4), video.asset.width * 4) }
            }
            blit.copy(from: buffer, sourceOffset: 0, sourceBytesPerRow: row, sourceBytesPerImage: row * video.asset.height,
                sourceSize: MTLSize(width: video.asset.width, height: video.asset.height, depth: 1),
                to: resource.texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding(); videoPTS[key] = frame.pts
        }
    }

    private func prepareSceneText(_ command: MTLCommandBuffer, frame: NativeMetalSceneAnimation.Frame?) throws {
        var pixels = sceneLayers.reduce(0) { $0 + ($1.text?.pixels ?? 0) }, bytes = textureBytes
        // A published layer remains a live producer when hidden on the
        // desktop.  It must receive text updates and effect allocation before
        // graph consumers encode, but never becomes visible merely by being an
        // export source.
        let visible = Set(sceneLayers.filter { frame?.layers[$0.source.objectIndex].visible ?? $0.source.visible }.map { $0.source.objectIndex })
            .union(sceneLayerGraph?.producerObjectIndices ?? [])
        var changes: [Int: NativeMetalText.Runtime.Replacement] = [:]
        for index in sceneLayers.indices {
            let layer = sceneLayers[index]
            guard let text = layer.text, let description = layer.source.text else { continue }
            let properties = frame?.layers[layer.source.objectIndex].textProperties ?? description.properties
            text.anchor.update(properties)
            guard visible.contains(layer.source.objectIndex) else { continue }
            if let next = text.prepare(properties, device: context.device, command: command,
                pixelBudget: 8 * 1024 * 1024 - pixels + text.pixels,
                byteBudget: 256 * 1024 * 1024 - bytes + text.bytes) {
                changes[index] = next; pixels += next.pixels - text.pixels; bytes += next.bytes - text.bytes
            }
        }
        func bounds(replacements: Bool) -> [Int: CGRect] {
            Dictionary(uniqueKeysWithValues: sceneLayers.indices.map { index in
                (sceneLayers[index].source.objectIndex, replacements ? (changes[index]?.bounds ?? sceneLayers[index].bounds) : sceneLayers[index].bounds)
            })
        }
        do { try sceneEffects?.prepare(bounds: bounds(replacements: true), visible: visible) }
        catch {
            guard !changes.isEmpty else { throw error }
            // Invalid text dimensions must not replace the last valid image or
            // partially publish an effect layout. A visibility-only failure
            // still fails the frame explicitly, rather than omitting effects.
            for index in changes.keys { sceneLayers[index].text?.reject(error) }
            try sceneEffects?.prepare(bounds: bounds(replacements: false), visible: visible)
            return
        }
        for (index, next) in changes { sceneLayers[index].text?.commit(next) }
        textureBytes = bytes
    }

    /// Encode graph producers before the ordinary scene order.  The returned
    /// maps are per-command/per-frame, in validated topological order; no
    /// stale texture may satisfy a missing source on a later frame.
    private func encodeLayerCompositeExports(_ graph: NativeMetalSceneLayerGraph, command: MTLCommandBuffer,
                                             time: Double, frame: NativeMetalSceneAnimation.Frame?) throws -> (byID: [String: MTLTexture], byObject: [Int: MTLTexture]) {
        guard let effects = sceneEffects else { throw SceneError.invalid("Metal 图层纹理图缺少离屏效果资源。") }
        var byID: [String: MTLTexture] = [:], byObject: [Int: MTLTexture] = [:]
        for export in graph.exports {
            guard let layer = sceneLayers.first(where: { $0.source.objectIndex == export.producerObjectIndex }),
                  let prepared = effects.layer(at: export.producerObjectIndex, visibility: frame?.effectVisibility ?? [:], forLayerCompositeExport: true) else {
                throw SceneError.invalid("Metal 图层纹理源 \(export.id) 本帧没有已准备的独立输出。")
            }
            try encodeEffectBase(layer, target: prepared.working[0], command: command, time: time,
                                 state: frame?.layers[export.producerObjectIndex])
            let output = try effects.encode(prepared, command: command, parameters: frame?.effectParameters ?? [:],
                                            visibility: frame?.effectVisibility ?? [:], layerComposites: byID)
            // The graph validation makes duplicate ids impossible.  Preserve
            // that invariant at the encoder boundary as well, where a wrong
            // map overwrite would otherwise look like a plausible frame.
            guard byID[export.id] == nil, byObject[export.producerObjectIndex] == nil else {
                throw SceneError.invalid("Metal 图层纹理图出现重复导出。")
            }
            byID[export.id] = output; byObject[export.producerObjectIndex] = output
        }
        return (byID, byObject)
    }

    private struct SceneHistoryFrames {
        let reflection: NativeMetalReflection.Frame?
        let accumulation: NativeMetalSceneHistory.Frame?
    }

    private func encodeScene(_ command: MTLCommandBuffer, target: MTLTexture, time: Double,
                             frame: NativeMetalSceneAnimation.Frame?, camera: NativeMetalSceneCamera.Frame, paused: Bool,
                             particlePointer: NativeMetalParticlePointerSample) throws -> SceneHistoryFrames {
        let lighting = frame?.modelLighting ?? NativeModelLightFrame()
        let drawOrder = orderedSceneIndices()
        let volumeRequested = volumetricQuality != .disabled && lighting.lights.contains { $0.volumetrics != nil }
        guard !volumeRequested || scenePointVolumeBoundary != nil else { throw SceneError.invalid("当前 Metal 场景的模型排序不支持动态启用体积光。") }
        let modelPositions = drawOrder.indices.filter { sceneLayers[drawOrder[$0]].source.model != nil }
        let contiguous = modelPositions.first.map { modelPositions.last! - $0 + 1 == modelPositions.count } ?? true
        let volumeBoundary = contiguous ? (modelPositions.last.map { $0 + 1 } ?? 0) : nil
        let hasVolumes = volumeRequested && volumeBoundary != nil
        sceneOrderDiagnostic = volumeRequested && !contiguous
            ? "图层脚本排序：模型与其他图层交错，超出当前体积光合成范围；保留脚本绘制顺序并跳过体积光。" : nil
        if !hasVolumes { scenePointVolumetrics?.deactivate(time: time, quality: volumetricQuality) }
        var casters: [NativeMetalPointShadows.Caster] = []
        if let sceneModels {
            for layer in sceneLayers {
                let source = layer.source
                guard let resource = source.model else { continue }
                let state = frame?.layers[source.objectIndex], visible = state?.visible ?? source.visible
                if visible, state?.castsShadow ?? source.castsShadow {
                    let geometry = try sceneModels.geometry(for: resource)
                    casters.append(.init(resource: resource, geometry: geometry, model: state?.transform ?? source.transform,
                        bones: sceneModels.bones(instance: source.objectIndex, fallback: geometry.bones)))
                }
            }
        }
        let shadows = try scenePointShadows?.encode(lighting: lighting, casters: casters, time: time, command: command, quality: shadowQuality)
        let reflection = try (reflectionsEnabled ? sceneReflection : nil)?.begin(width: target.width, height: target.height, format: target.pixelFormat,
            time: time, paused: paused, command: command)
        lastTargetSize = (target.width, target.height)
        try multisample.prepare(device: context.device, width: target.width, height: target.height,
            format: target.pixelFormat, withDepth: sceneUsesDepth)
        let pass = NativeMetalEffects.renderPass(target)
        if sceneUsesDepth {
            pass.depthAttachment.texture = try sceneDepthTarget.prepare(device: context.device, width: target.width, height: target.height)
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.loadAction = .clear; pass.depthAttachment.storeAction = .store
        }
        let resolvedDepth = pass.depthAttachment.texture
        let clear = frame?.clearColor ?? sceneClear
        let history = try sceneHistory?.begin(target: target, depth: pass.depthAttachment.texture,
            time: time, paused: paused, clearEnabled: frame?.clearEnabled ?? sceneClearEnabled, clearColor: clear, command: command)
        multisample.attach(to: pass, color: target, depth: resolvedDepth)
        if history?.restored == true {
            try seedMultisample(target: target, depth: resolvedDepth, command: command)
            pass.colorAttachments[0].loadAction = .load
            if sceneUsesDepth { pass.depthAttachment.loadAction = .load }
        }
        let pipelineSuffix = sceneUsesDepth ? ".depth" : ""
        pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(clear.x), Double(clear.y), Double(clear.z), 1)
        var encoder = command.makeRenderCommandEncoder(descriptor: pass)
        guard encoder != nil else { throw SceneError.invalid("无法开始 Metal Scene 绘制。") }
        defer { encoder?.endEncoding() }
        sceneEffects?.beginFrame()
        let layerCompositeOutputs: (byID: [String: MTLTexture], byObject: [Int: MTLTexture])
        if let graph = sceneLayerGraph {
            // Metal cannot overlap the main render encoder with the local
            // export encoders.  Finish the initial clear, render the isolated
            // DAG, then resume this same scene target with load semantics.
            encoder?.endEncoding(); encoder = nil
            layerCompositeOutputs = try encodeLayerCompositeExports(graph, command: command, time: time, frame: frame)
            pass.colorAttachments[0].loadAction = .load
            if sceneUsesDepth { pass.depthAttachment.loadAction = .load }
            encoder = command.makeRenderCommandEncoder(descriptor: pass)
            guard encoder != nil else { throw SceneError.invalid("无法在图层纹理离屏绘制后继续 Metal Scene。") }
        } else { layerCompositeOutputs = ([:], [:]) }
        var particleBytes = 64 * 1024 * 1024
        var modelInstances = 0, modelDraws = 0, invalidModelNormals = 0
        func encodeVolumes() throws {
            guard hasVolumes else { return }
            encoder?.endEncoding(); encoder = nil
            guard let volume = scenePointVolumetrics, let depth = resolvedDepth, let shadows else { throw SceneError.invalid("Metal 体积光阶段缺少深度或阴影资源。") }
            let eye = simd_inverse(camera.view).columns.3
            try volume.encode(target: target, sceneDepth: depth, lighting: lighting, shadows: shadows,
                viewProjection: camera.projection * camera.view, eye: SIMD3(eye.x, eye.y, eye.z), time: time, command: command, quality: volumetricQuality)
            try seedMultisample(target: target, depth: nil, command: command)
            pass.colorAttachments[0].loadAction = .load; pass.depthAttachment.loadAction = .load
            encoder = command.makeRenderCommandEncoder(descriptor: pass)
            guard encoder != nil else { throw SceneError.invalid("无法在体积光之后继续绘制 Metal 图层。") }
        }
        for (position, index) in drawOrder.enumerated() {
            if position == volumeBoundary { try encodeVolumes() }
            let layer = sceneLayers[index]
            let source = layer.source
            let state = frame?.layers[source.objectIndex]
            guard state?.visible ?? source.visible else { continue }
            guard let view = NativeParallaxCamera.translated(camera.view, by: camera.offsets[source.objectIndex]) else {
                throw SceneError.invalid("Metal 图层视差矩阵无法安全表示。")
            }
            let authoredModel = state?.transform ?? source.transform
            let model = layer.text?.anchor.model(authoredModel, margins: camera.textMargins) ?? authoredModel
            let transform = camera.projection * view * model
            if let resource = source.model, let encoder {
                let result = try encodeModel(resource, encoder: encoder, target: target, model: model,
                    view: view, projection: camera.projection, lighting: lighting, instance: source.objectIndex, parameters: frame?.effectParameters ?? [:], reflection: reflection, shadows: shadows, time: time)
                modelInstances += 1; modelDraws += result.draws; invalidModelNormals += result.invalidNormal ? 1 : 0
                continue
            }
            if let particles = layer.particles, let encoder {
                var perspectiveProjection: simd_float4x4?, perspectiveView: simd_float4x4?
                if particles.system.usesPerspectiveProjection || particles.children.contains(where: { $0.usesPerspectiveProjection }) {
                    guard let perspective = camera.particleProjection else { throw SceneError.invalid("Metal 粒子透视参数无效。") }
                    var temporary = camera.view; temporary.columns.3.z = -perspective.distance
                    guard let translated = NativeParallaxCamera.translated(temporary, by: camera.offsets[source.objectIndex]) else { throw SceneError.invalid("Metal 粒子透视视图无效。") }
                    perspectiveProjection = perspective.matrix; perspectiveView = translated
                }
                var rootProjection = camera.projection, rootView = view
                if particles.system.usesPerspectiveProjection {
                    rootProjection = perspectiveProjection!; rootView = perspectiveView!
                }
                let rootTransform = rootProjection * rootView * (particles.system.usesWorldSpace ? matrix_identity_float4x4 : model)
                let input = particles.system.hasPointerForces ? particlePointer.project(rootTransform) : .init(position: nil, reason: "no-pointer-force")
                try particles.update(device: context.device, time: time, paused: paused, model: model,
                    right: camera.right, up: camera.up, remainingBytes: &particleBytes, pointer: input)
                for (index, mesh) in particles.meshes.enumerated() where mesh.count > 0 {
                    let material = index == 0 ? particles.source.material : particles.source.children[index - 1].material
                    guard let image = sceneResources[material.texture], let buffer = mesh.buffer else { throw SceneError.invalid("Metal 粒子缺少图像或顶点。") }
                    let matrix: simd_float4x4
                    if index == 0 {
                        matrix = rootTransform
                    } else {
                        let child = particles.children[index - 1]
                        let drawModel = child.usesWorldGeometry ? matrix_identity_float4x4 : model * child.drawLocalTransform
                        let childProjection = child.usesPerspectiveProjection ? perspectiveProjection! : camera.projection
                        let childView = child.usesPerspectiveProjection ? perspectiveView! : view
                        matrix = childProjection * childView * drawModel
                    }
                    guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }) else { throw SceneError.invalid("Metal 粒子变换包含非有限值。") }
                    var uniforms = NativeMetalParticles.Uniforms(transform: matrix,
                        appearance: SIMD4(Float(image.channels), material.overbright, material.depth.write && material.blend == "translucent" ? 1 : 0, 0), cutout: material.cutout)
                    encoder.setRenderPipelineState(context.particlePipelines[target.pixelFormat]![material.blend + pipelineSuffix]!)
                    encoder.setDepthStencilState(context.depthStates[sceneUsesDepth ? material.depth.key : 0]!)
                    encoder.setCullMode(.none)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<NativeMetalParticles.Uniforms>.stride, index: 0)
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<NativeMetalParticles.Uniforms>.stride, index: 0)
                    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
                    encoder.setFragmentTexture(image.texture, index: 0)
                    encoder.setFragmentSamplerState(context.sampler(repeating: image.repeating, nearest: image.nearest), index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.count)
                }
                continue
            }
            if let output = layerCompositeOutputs.byObject[source.objectIndex], let encoder {
                // A visible exporter reuses the exact isolated result that its
                // consumers sampled.  Re-encoding it here would update effect
                // history twice and could make its desktop appearance differ
                // from the published texture.
                guard !source.needsBackdrop else { throw SceneError.invalid("Metal 图层纹理源不能同时读取场景背景。") }
                encoder.setRenderPipelineState(context.scenePipelines[target.pixelFormat]![source.finalBlend + pipelineSuffix]!)
                encoder.setDepthStencilState(context.depthStates[sceneUsesDepth ? source.depth.key : 0]!)
                let image = SceneResource(texture: output, width: output.width, height: output.height, channels: 4,
                    rect: SIMD4(0, 0, 1, 1), repeating: false, animation: nil)
                try encodeSceneLayer(layer, encoder: encoder, transform: transform, time: time, state: state, completedEffect: image)
                continue
            }
            if let effects = sceneEffects, let prepared = effects.layer(at: source.objectIndex, visibility: frame?.effectVisibility ?? [:]) {
                encoder?.endEncoding(); encoder = nil
                try encodeEffectBase(layer, target: prepared.working[0], command: command, time: time, state: state)
                let output = try effects.encode(prepared, command: command, parameters: frame?.effectParameters ?? [:], visibility: frame?.effectVisibility ?? [:], layerComposites: layerCompositeOutputs.byID)
                let backdrop: MTLTexture?
                if source.needsBackdrop {
                    guard let sceneCompositing else { throw SceneError.invalid("Metal 图层缺少颜色合成器。") }
                    backdrop = try sceneCompositing.capture(target, command: command, mode: source.colorBlendMode)
                } else { backdrop = nil }
                pass.colorAttachments[0].loadAction = .load
                if sceneUsesDepth { pass.depthAttachment.loadAction = .load }
                encoder = command.makeRenderCommandEncoder(descriptor: pass)
                guard let encoder else { throw SceneError.invalid("无法继续 Metal Scene 合成。") }
                if let backdrop {
                    encoder.setRenderPipelineState(context.sceneCompositePipelines[target.pixelFormat]![source.finalBlend + pipelineSuffix]!)
                    encoder.setFragmentTexture(backdrop, index: 1)
                } else { encoder.setRenderPipelineState(context.scenePipelines[target.pixelFormat]![source.finalBlend + pipelineSuffix]!) }
                let image = SceneResource(texture: output, width: output.width, height: output.height, channels: 4,
                    rect: SIMD4(0, 0, 1, 1), repeating: false, animation: nil)
                encoder.setDepthStencilState(context.depthStates[sceneUsesDepth ? source.depth.key : 0]!)
                try encodeSceneLayer(layer, encoder: encoder, transform: transform, time: time, state: state, completedEffect: image)
            } else if let encoder {
                guard !source.needsBackdrop else { throw SceneError.invalid("Metal 颜色合成缺少局部图层目标。") }
                encoder.setRenderPipelineState(context.scenePipelines[target.pixelFormat]![source.finalBlend + pipelineSuffix]!)
                encoder.setDepthStencilState(context.depthStates[sceneUsesDepth ? source.depth.key : 0]!)
                try encodeSceneLayer(layer, encoder: encoder, transform: transform, time: time, state: state)
            }
        }
        if volumeBoundary == drawOrder.count { try encodeVolumes() }
        sceneModels?.record(time: time, instances: modelInstances, draws: modelDraws, lighting: lighting, invalidNormals: invalidModelNormals)
        sceneEffects?.endFrame(time: time)
        sceneCompositing?.endFrame(time: time)
        encoder?.endEncoding(); encoder = nil
        if let reflection { try sceneReflection?.capture(target, frame: reflection, command: command) }
        if let history { try sceneHistory?.capture(target: target, depth: resolvedDepth, frame: history, command: command) }
        return SceneHistoryFrames(reflection: reflection, accumulation: history)
    }

    private func orderedSceneIndices() -> [Int] {
        (sceneScripts?.sceneLayerOrder ?? initialSceneLayerOrder)?.drawIndices(sceneLayers.map { $0.source.objectIndex }) ?? Array(sceneLayers.indices)
    }

    private func pointerFrame(time: Double, frame: NativeMetalSceneAnimation.Frame?,
                              camera: NativeMetalSceneCamera.Frame) -> NativeMetalPointerFrame {
        let regions = orderedSceneIndices().compactMap { index -> NativeMetalPointerFrame.Region? in
            let layer = sceneLayers[index]
            let source = layer.source
            guard let id = source.pointerID else { return nil }
            // Invisible solid layers can be deliberate input regions. Hidden
            // ancestors suppress their entire subtree, as in the Scene path.
            if let parent = source.parentIndex,
               !(frame?.layers[parent].visible ?? sceneLayers[parent].source.visible) { return nil }
            guard let view = NativeParallaxCamera.translated(camera.view, by: camera.offsets[source.objectIndex]) else { return nil }
            let authoredModel = frame?.layers[source.objectIndex].transform ?? source.transform
            let model = layer.text?.anchor.model(authoredModel, margins: camera.textMargins) ?? authoredModel
            return NativeMetalPointerFrame.Region(id: id, bounds: layer.bounds, transform: camera.projection * view * model)
        }
        return NativeMetalPointerFrame(time: time, worldTransform: camera.projection * camera.view, regions: regions)
    }

    private func encodeModel(_ source: NativeMetalModels.Resource, encoder: MTLRenderCommandEncoder,
                             target: MTLTexture, model: simd_float4x4, view: simd_float4x4,
                             projection: simd_float4x4, lighting: NativeModelLightFrame, instance: Int, parameters: [String: [Float]],
                             reflection: NativeMetalReflection.Frame?, shadows: NativeMetalPointShadows.Frame?, time: Double) throws -> (draws: Int, invalidNormal: Bool) {
        guard let sceneModels else { throw SceneError.invalid("Metal 模型运行时尚未准备。") }
        let geometry = try sceneModels.geometry(for: source)
        let inverse = simd_inverse(view), eye = inverse.columns.3
        let viewProjection = projection * view
        guard [model, viewProjection, viewProjection * model, inverse].allSatisfy({ matrix in
            (0..<4).allSatisfy { c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }
        }) else { throw SceneError.invalid("Metal 模型投影或相机逆矩阵含非有限数值，停止绘制。") }
        let normal3 = NativeModelMaterial.normalMatrix(model)
        var normal = matrix_identity_float4x4
        if let normal3 { for column in 0..<3 { normal[column] = SIMD4(normal3[column],0) } }
        guard let shadows else { throw SceneError.invalid("Metal 模型阴影采样目标缺失。") }
        var lights = lighting.lights.enumerated().flatMap { index, light in [light.positionRadius, light.colorExponent, shadows.bindings[index], light.spotDirection, light.spotParameters] + light.shadowRows + light.projectionRows }
        if lights.isEmpty { lights = Array(repeating: .zero,count: 11) }
        lights.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        let suffix = sceneUsesDepth ? ".depth" : ""
        var count = 0
        for (index, mesh) in geometry.meshes.enumerated() {
            encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 1)
            encoder.setVertexBuffer(sceneModels.bones(instance: instance, fallback: geometry.bones), offset: 0, index: 2)
            for material in source.materials[index] where material.visible {
                guard let image = sceneResources[material.texture] else { throw SceneError.invalid("Metal 模型材质图片缺失。") }
                let prefix = "/objects/\(instance)" + material.scriptMaterial.path + "/constantshadervalues/"
                let color = parameters[prefix + "color"] ?? [material.tint.x, material.tint.y, material.tint.z]
                let alpha = parameters[prefix + "alpha"]?.first ?? material.tint.w
                let roughness = parameters[prefix + "roughness"]?.first ?? material.roughness
                let metallic = parameters[prefix + "metallic"]?.first ?? material.metallic
                let brightness = parameters[prefix + "brightness"]?.first ?? material.brightness
                let reflectivity = parameters[prefix + "reflectivity"]?.first ?? material.reflectivity
                let emissiveColor = parameters[prefix + "emissivecolor"] ?? [material.emissive.x, material.emissive.y, material.emissive.z]
                let emissiveBrightness = parameters[prefix + "emissivebrightness"]?.first ?? material.emissive.w
                let normalImage = material.normalTexture.flatMap { sceneResources[$0] } ?? image
                let maskImage = material.maskTexture.flatMap { sceneResources[$0] } ?? image
                let gradientImage = material.gradientTexture.flatMap { sceneResources[$0] } ?? image
                let noiseImage = material.noiseTexture.flatMap { sceneResources[$0] } ?? image
                let projectionImage = material.projectionTexture.flatMap { sceneResources[$0] }
                guard !material.lighting || !lighting.lights.contains(where: { $0.projection != nil }) || projectionImage != nil else {
                    throw SceneError.invalid("投影灯光缺少资源：当前需要受光材质在纹理槽 7 显式指定 TEX 或视频；引擎资源别名尚未解析。")
                }
                let projectionRegion = projectionImage.map { resource in
                    resource.animation?.uv(at:time,atlasWidth:resource.width,atlasHeight:resource.height,staticFrame:nil) ?? resource.rect
                } ?? SIMD4<Float>(0,0,1,1)
                func chromaValue(_ name: String, _ fallback: SIMD4<Float>, scalar: String) -> SIMD4<Float> {
                    let rgb = parameters[prefix + name] ?? [fallback.x, fallback.y, fallback.z]
                    return SIMD4(rgb[0],rgb[1],rgb[2],parameters[prefix + scalar]?.first ?? fallback.w)
                }
                let specular = parameters[prefix + "speculartint"] ?? [material.chromaSpecular.x,material.chromaSpecular.y,material.chromaSpecular.z]
                let rimAmount = parameters[prefix + "rimamount"]?.first ?? material.rimAmount
                let rimExponent = parameters[prefix + "rimexponent"]?.first ?? material.rimExponent
                guard !reflectionsEnabled || !material.reflection || reflection != nil else { throw SceneError.invalid("Metal 模型反射历史缺失。") }
                var uniforms = NativeMetalModels.Uniforms(model: model, viewProjection: viewProjection, normal: normal,
                    tint: SIMD4(color[0],color[1],color[2],alpha), parameters: SIMD4(roughness,metallic,brightness,reflectionsEnabled ? 0 : 1), eye: eye,
                    ambient: SIMD4(lighting.ambient,0), skylight: SIMD4(lighting.skylight,0), fogColor: SIMD4(lighting.fogColor,0), fogParameters: lighting.fogParams,
                    reflection: SIMD4(material.reflection ? 1 : 0, reflectivity, reflection?.mipScale ?? 1, Float(target.width) / Float(target.height)), shadowScale: shadows.scale,
                    emissive: SIMD4(emissiveColor[0],emissiveColor[1],emissiveColor[2],emissiveBrightness),
                    stylization: SIMD4(rimAmount,rimExponent,material.rimLighting ? 1 : 0,Float(shadowQuality.index)),
                    chromaFront: chromaValue("tintfront", material.chromaFront, scalar: "tintwexponent"),
                    chromaBack: chromaValue("tintback", material.chromaBack, scalar: "tintpigmentation"),
                    chromaSpecular: SIMD4(specular[0],specular[1],specular[2],material.chroma ? 1 : 0),
                    chromaScreen: SIMD4(Float(target.width) / Float(noiseImage.width), Float(target.height) / Float(noiseImage.height),0,0),
                    projectionRegion: projectionRegion, projectionParameters: SIMD4(projectionImage?.nearest == true ? 1 : 0,0,0,0),
                    maps: SIMD4(material.normalTexture != nil ? material.normalFormat + 1 : 0, material.mapFlags, material.tintMask ? 1 : 0, material.gradientTexture != nil ? material.gradientFormat + 1 : 0),
                    flags: SIMD4(material.lighting ? 1 : 0, material.fog ? 1 : 0, sceneHDR ? 1 : 0, lighting.fogEnabled ? 1 : 0),
                    layout: SIMD4(UInt32(mesh.components), UInt32(geometry.boneCount), UInt32(lighting.lights.count), material.depth.write && material.blend == "translucent" ? 1 : 0))
                encoder.setRenderPipelineState(context.modelPipelines[target.pixelFormat]![material.blend + suffix]!)
                encoder.setDepthStencilState(context.depthStates[sceneUsesDepth ? material.depth.key : 0]!)
                encoder.setFrontFacing(.counterClockwise)
                encoder.setCullMode(material.cull ? .back : .none)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<NativeMetalModels.Uniforms>.stride, index: 0)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<NativeMetalModels.Uniforms>.stride, index: 0)
                encoder.setFragmentTexture(image.texture, index: 0)
                encoder.setFragmentTexture(reflection?.sample ?? image.texture, index: 1)
                encoder.setFragmentTexture(shadows.texture, index: 2)
                encoder.setFragmentTexture(normalImage.texture, index: 3)
                encoder.setFragmentTexture(maskImage.texture, index: 4)
                encoder.setFragmentTexture(gradientImage.texture, index: 5)
                encoder.setFragmentTexture(noiseImage.texture, index: 6)
                encoder.setFragmentTexture(projectionImage?.texture ?? image.texture, index: 7)
                encoder.setFragmentSamplerState(context.sampler(repeating: normalImage.repeating, nearest: normalImage.nearest), index: 1)
                encoder.setFragmentSamplerState(context.sampler(repeating: maskImage.repeating, nearest: maskImage.nearest), index: 2)
                encoder.setFragmentSamplerState(context.sampler(repeating: gradientImage.repeating, nearest: gradientImage.nearest), index: 3)
                encoder.setFragmentSamplerState(context.sampler(repeating: noiseImage.repeating, nearest: noiseImage.nearest), index: 4)
                if material.reflection { reflection?.bindings += 1 }
                encoder.setFragmentSamplerState(context.sampler(repeating: image.repeating, nearest: image.nearest), index: 0)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: mesh.count, indexType: .uint32, indexBuffer: mesh.indices, indexBufferOffset: 0)
                count += 1
            }
        }
        return (count, normal3 == nil)
    }

    private func encodeEffectBase(_ layer: SceneLayer, target: MTLTexture, command: MTLCommandBuffer,
                                  time: Double, state: NativeMetalSceneAnimation.LayerState?) throws {
        guard let encoder = command.makeRenderCommandEncoder(descriptor: NativeMetalEffects.renderPass(target)) else { throw SceneError.invalid("无法绘制 Metal 效果输入。") }
        defer { encoder.endEncoding() }
        encoder.setRenderPipelineState(context.sceneLocalPipelines[target.pixelFormat]!)
        let bounds = layer.bounds
        var projection = simd_float4x4(diagonal: SIMD4(2 / Float(bounds.width), 2 / Float(bounds.height), -2 / 10000, 1))
        projection.columns.3.x = -2 * Float(bounds.midX / bounds.width)
        projection.columns.3.y = -2 * Float(bounds.midY / bounds.height)
        try encodeSceneLayer(layer, encoder: encoder, transform: projection, time: time, state: state)
    }

    private func encodeSceneLayer(_ layer: SceneLayer, encoder: MTLRenderCommandEncoder, transform: simd_float4x4,
                                  time: Double, state: NativeMetalSceneAnimation.LayerState?, completedEffect: SceneResource? = nil) throws {
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { transform[c][$0].isFinite } }) else { throw SceneError.invalid("Metal 图层投影含非有限数值，停止绘制。") }
        let source = layer.source, image = completedEffect ?? layer.resource
        let copied = completedEffect != nil
        let atlas = image.animation?.uv(at: state?.textureTime ?? time, atlasWidth: image.width, atlasHeight: image.height, staticFrame: state?.textureFrame) ?? image.rect
        var uniforms = SceneUniforms(transform: transform,
            geometry: SIMD4(Float(layer.bounds.width), Float(layer.bounds.height), Float(layer.bounds.midX), Float(layer.bounds.midY)),
            atlas: atlas, color: SIMD4(copied ? SIMD3(repeating: 1) : (state?.color ?? source.color), 1),
            appearance: SIMD4(copied ? 1 : source.brightness, copied ? 1 : (state?.opacity ?? source.opacity), Float(image.channels), image.animation == nil ? 0 : 1),
            background: copied ? .zero : (state?.background ?? source.background), resolution: SIMD4(Float(image.width), Float(image.height), 0, 0),
            composite: SIMD4(UInt32(source.colorBlendMode), sceneHDR ? 1 : 0,
                copied && source.finalBlend != "normal" ? 1 : 0, source.depth.write && source.finalBlend == "translucent" ? 1 : 0))
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 0)
        encoder.setFragmentTexture(image.texture, index: 0)
        encoder.setFragmentSamplerState(context.sampler(repeating: image.repeating, nearest: image.nearest), index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    func bounds(at index: Int) -> CGRect? { layers.first { $0.index == index }?.bounds }
    func updateMotion(_ motion: NativeCreationMotion, at index: Int) -> Bool {
        updateMotions([index: motion])
    }
    func updateMotions(_ updates: [Int: NativeCreationMotion]) -> Bool {
        guard let document, !updates.isEmpty else { return false }
        var next = motions
        for (index, motion) in updates {
            guard motions.indices.contains(index), motion.duration == document.duration, motion.loop == document.loop,
                  (try? motion.validated()) != nil else { return false }
            next[index] = motion
        }
        guard next.reduce(0, { $0 + $1.scalarKeyframeCount }) <= 6144 else { return false }
        motions = next
        return true
    }

    func command(target: MTLTexture, time: Double, preserveEndpoint: Bool, paused: Bool = false,
                 pointer: SIMD2<Float> = SIMD2(repeating: 0.5),
                 particlePointer: NativeMetalParticlePointerSample = .inactive) throws -> MTLCommandBuffer {
        if let reason = context.unavailableReason { throw SceneError.invalid(reason) }
        let commandDescriptor = MTLCommandBufferDescriptor()
        commandDescriptor.retainedReferences = true
        guard target.width > 0, target.height > 0, target.pixelFormat == .bgra8Unorm,
              let command = context.queue.makeCommandBuffer(descriptor: commandDescriptor) else { throw SceneError.invalid("无法准备 Metal 绘制命令。") }
        command.label = "Native wallpaper frame"
        let animationFrame = try sceneAnimation?.frame(at: time, scripts: sceneScripts, models: sceneModels, paused: paused, displayOrder: initialSceneLayerOrder?.indices)
        lastSceneFrame = animationFrame
        lastSceneTime = time
        if document == nil {
            try prepareSceneVideos(command, time: time)
            try prepareSceneText(command, frame: animationFrame)
            guard let camera = try sceneCamera?.frame(time: time, paused: paused, pointer: pointer,
                output: SIMD2(Float(target.width), Float(target.height)), zoom: animationFrame?.zoom ?? sceneCanvas.z,
                animation: animationFrame, scriptPose: sceneScripts?.cameraPose) else { throw SceneError.invalid("Metal Scene 缺少相机。") }
            let bloom = animationFrame?.bloom ?? sceneBloomState
            let bloomEnabled = postProcessingQuality.allowsBloom && bloom.enabled
            let reflection: SceneHistoryFrames
            sceneCompositing?.beginFrame(externalScene: sceneHDR || (bloomEnabled && bloom.parameters.isFinite))
            if sceneHDR, let sceneHDRBloom {
                let targets = try sceneHDRBloom.prepare(width: target.width, height: target.height)
                reflection = try encodeScene(command, target: targets.scene, time: time, frame: animationFrame, camera: camera, paused: paused, particlePointer: particlePointer)
                try sceneHDRBloom.encode(targets, enabled: bloomEnabled, parameters: animationFrame?.hdrBloom ?? sceneHDRState,
                    output: target, command: command, time: time)
            } else if bloomEnabled, bloom.parameters.isFinite, let sceneBloom {
                let targets = try sceneBloom.prepare(width: target.width, height: target.height)
                reflection = try encodeScene(command, target: targets.scene, time: time, frame: animationFrame, camera: camera, paused: paused, particlePointer: particlePointer)
                try sceneBloom.encode(targets, parameters: bloom.parameters, output: target, command: command, time: time)
            } else {
                sceneBloom?.inactive(state: bloom, time: time)
                if let sceneCompositing {
                    let scene = try sceneCompositing.sceneForPresentation(width: target.width, height: target.height)
                    reflection = try encodeScene(command, target: scene, time: time, frame: animationFrame, camera: camera, paused: paused, particlePointer: particlePointer)
                    try sceneCompositing.present(scene, output: target, command: command)
                } else { reflection = try encodeScene(command, target: target, time: time, frame: animationFrame, camera: camera, paused: paused, particlePointer: particlePointer) }
            }
            if let frame = reflection.reflection { try sceneReflection?.finish(frame, command: command) }
            if let frame = reflection.accumulation { try sceneHistory?.finish(frame, command: command) }
            try NativeMetalCameraFade.encode(camera.fade, target: target, command: command, pipeline: context.cameraFade)
            lastPointerFrame = needsScriptPointer ? pointerFrame(time: time, frame: animationFrame, camera: camera) : nil
            return registeredCommand(command)
        }
        let clear = animationFrame?.clearColor ?? sceneClear
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        lastTargetSize = (target.width, target.height)
        try multisample.prepare(device: context.device, width: target.width, height: target.height, format: target.pixelFormat, withDepth: false)
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(clear.x), Double(clear.y), Double(clear.z), 1)
        multisample.attach(to: pass, color: target, depth: nil)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw SceneError.invalid("无法准备 Metal 图层绘制。") }
        defer { encoder.endEncoding() }
        guard let document else { throw SceneError.invalid("Metal 创作信息缺失。") }
        encoder.setRenderPipelineState(context.pipeline); encoder.setCullMode(.none)
        let aspect = Float(target.width) / Float(target.height)
        let canvasWidth = Float(document.width), canvasHeight = Float(document.height)
        // Match the existing centered, aspect-fill Scene camera.
        let visibleWidth = min(canvasWidth, canvasHeight * aspect)
        let visibleHeight = visibleWidth / aspect
        for layer in layers where layer.visible {
            let pose = motions[layer.index].pose(at: time, preserveEndpoint: preserveEndpoint)
            let radians = Float(pose.rotation * .pi / 180)
            var uniforms = Uniforms(projection: SIMD4(canvasWidth, canvasHeight, visibleWidth, visibleHeight),
                                    geometry: SIMD4(Float(layer.bounds.width), Float(layer.bounds.height), Float(layer.bounds.midX), Float(layer.bounds.midY)),
                                    pose: SIMD4(Float(pose.x), Float(pose.y), Float(pose.scaleX), Float(pose.scaleY)),
                                    rotationOpacity: SIMD4(cos(radians), sin(radians), Float(pose.opacity), 0), color: layer.color)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        return registeredCommand(command)
    }

    func previewPNG(width: Int, height: Int, time: Double) throws -> Data {
        guard (1...NativeCreationPreview.maximumDimension).contains(width), (1...NativeCreationPreview.maximumDimension).contains(height) else {
            throw SceneError.invalid("Metal 封面尺寸无效。")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = .renderTarget
        guard let output = context.device.makeTexture(descriptor: descriptor) else { throw SceneError.invalid("无法分配 Metal 作品封面。") }
        let command = try command(target: output, time: time, preserveEndpoint: true)
        try complete(command, operation: "封面生成")
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0) }
        for pixel in stride(from: 0, to: rgba.count, by: 4) { rgba.swapAt(pixel, pixel + 2) }
        return try NativeCreationPreview.encode(topDownRGBA: rgba, width: width, height: height)
    }

    private func complete(_ command: MTLCommandBuffer, operation: String) throws {
        let completion = DispatchSemaphore(value: 0)
        // Commands explicitly retain their resources until real GPU completion,
        // including when the bounded CPU wait below times out.
        command.addCompletedHandler { _ in completion.signal() }
        command.commit()
        guard completion.wait(timeout: .now() + 5) == .success else {
            let message = "Metal \(operation)超时，尚未保存新版本。请重新启动应用后再试。"
            context.unavailableReason = message
            throw SceneError.invalid(message)
        }
        finishTemporalSubmission(command)
        guard command.status == .completed else { throw SceneError.invalid("Metal \(operation)失败：\(command.error?.localizedDescription ?? "GPU 命令未完成")") }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms { float4 projection; float4 geometry; float4 pose; float4 rotationOpacity; float4 color; };
    struct VertexOut { float4 position [[position]]; float2 uv; };
    vertex VertexOut nativeVertex(uint id [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
        constexpr float2 corners[] = {float2(-.5,-.5), float2(.5,-.5), float2(.5,.5), float2(-.5,-.5), float2(.5,.5), float2(-.5,.5)};
        float2 p = (corners[id] * u.geometry.xy + u.geometry.zw) * u.pose.zw;
        float2 rotated = float2(p.x * u.rotationOpacity.x - p.y * u.rotationOpacity.y,
                               p.x * u.rotationOpacity.y + p.y * u.rotationOpacity.x);
        float2 clip = (rotated + u.pose.xy - u.projection.xy * .5) * 2 / u.projection.zw;
        return {float4(clip, 0, 1), float2(corners[id].x + .5, .5 - corners[id].y)};
    }
    fragment float4 nativeFragment(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]], texture2d<float> image [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        float4 color = image.sample(linearSampler, in.uv);
        return float4(color.rgb * u.color.rgb, color.a * u.rotationOpacity.z);
    }
    struct SceneUniforms {
        float4x4 transform; float4 geometry; float4 atlas; float4 color;
        float4 appearance; float4 background; float4 resolution; uint4 composite;
    };
    vertex VertexOut sceneVertex(uint id [[vertex_id]], constant SceneUniforms &u [[buffer(0)]]) {
        constexpr float2 corners[] = {float2(-.5,-.5), float2(.5,-.5), float2(.5,.5), float2(-.5,-.5), float2(.5,.5), float2(-.5,.5)};
        float2 local = corners[id] * u.geometry.xy + u.geometry.zw;
        float4 clip = u.transform * float4(local, 0, 1);
        clip.z = (clip.z + clip.w) * .5;
        return {clip, u.atlas.xy + float2(corners[id].x + .5, .5 - corners[id].y) * u.atlas.zw};
    }
    // Effect graphs retain straight-alpha storage for their authored passes.
    // The last translucent image must interpolate associated color: a blur
    // combine can contain very large RGB beside almost-zero alpha. Filtering
    // RGB and alpha independently produces bright fringes on the final quad.
    float4 sceneAssociatedSample(texture2d<float> image, float2 uv) {
        float2 position = uv * float2(image.get_width(), image.get_height()) - .5;
        int2 first = int2(floor(position)), maximum = int2(image.get_width()-1, image.get_height()-1);
        float2 f = fract(position);
        float4 a = image.read(uint2(clamp(first, int2(0), maximum)));
        float4 b = image.read(uint2(clamp(first + int2(1,0), int2(0), maximum)));
        float4 c = image.read(uint2(clamp(first + int2(0,1), int2(0), maximum)));
        float4 d = image.read(uint2(clamp(first + int2(1,1), int2(0), maximum)));
        a.rgb *= a.a; b.rgb *= b.a; c.rgb *= c.a; d.rgb *= d.a;
        float4 value = mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
        return float4(value.a > 0 ? value.rgb / value.a : float3(0), value.a);
    }
    float4 sceneSample(VertexOut in, constant SceneUniforms &u, texture2d<float> image, sampler imageSampler) {
        float2 uv = in.uv;
        if (u.appearance.w > .5) {
            float2 inset = min(.5 / u.resolution.xy, u.atlas.zw * .5);
            uv = clamp(uv, u.atlas.xy + inset, u.atlas.xy + u.atlas.zw - inset);
        }
        float4 color = u.composite.z ? sceneAssociatedSample(image, uv) : image.sample(imageSampler, uv);
        if (u.appearance.z < 1.5) color = float4(1, 1, 1, color.r);
        else if (u.appearance.z < 2.5) color = float4(color.rrr, color.g);
        color.rgb *= u.appearance.x * u.color.rgb;
        if (u.background.w > .5) { color.rgb = mix(u.background.rgb, color.rgb, color.a); color.a = 1; }
        color.a *= u.appearance.y;
        if (u.composite.w != 0 && color.a <= 0) discard_fragment();
        return color;
    }
    fragment float4 sceneFragment(VertexOut in [[stage_in]], constant SceneUniforms &u [[buffer(0)]],
                                  texture2d<float> image [[texture(0)]], sampler imageSampler [[sampler(0)]]) {
        return sceneSample(in, u, image, imageSampler);
    }
    """
}
