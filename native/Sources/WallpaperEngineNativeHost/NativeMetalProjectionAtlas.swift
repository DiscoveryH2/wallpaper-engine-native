import Foundation
import Metal
import simd

/// Native storage for multiple projected images. Each physical source is copied
/// without resizing into an independent guttered rectangle. Source animation
/// rectangles remain a sampling parameter, so one TEX page can serve several
/// lights at different frame times. Packing is native policy, not a reference
/// Wallpaper Engine atlas-layout claim.
@MainActor
final class NativeMetalProjectionAtlas {
    struct Source {
        let id: String
        let texture: MTLTexture
        /// Nil means the provider cannot identify content changes reliably.
        /// Such a source is recopied on every submitted frame.
        var revision: UInt64? = nil
    }
    struct Frame {
        let texture: MTLTexture
        let layout: NativeProjectionAtlasLayout
        let copiedSources: Int

        /// Source-relative UV region, including a TEX animation frame. The
        /// physical texture is never cropped or rescaled during atlas creation.
        func region(id: String, sourceRect: SIMD4<Float> = SIMD4(0,0,1,1)) -> SIMD4<Float>? {
            guard let entry = layout.entries[id], [sourceRect.x,sourceRect.y,sourceRect.z,sourceRect.w].allSatisfy(\.isFinite),
                  sourceRect.z > 0, sourceRect.w > 0, sourceRect.x >= 0, sourceRect.y >= 0,
                  sourceRect.x + sourceRect.z <= 1, sourceRect.y + sourceRect.w <= 1 else { return nil }
            let rect = entry.normalizedContent
            return SIMD4(rect.x + sourceRect.x*rect.z,rect.y + sourceRect.y*rect.w,sourceRect.z*rect.z,sourceRect.w*rect.w)
        }
    }
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    private struct Signature: Equatable {
        let id: String, texture: ObjectIdentifier, revision: UInt64?
    }
    private let device: MTLDevice
    private let clearPipeline: MTLComputePipelineState, copyPipeline: MTLComputePipelineState
    private let maximumDimension: Int, maximumBytes: Int
    private var queue: ObjectIdentifier?
    private(set) var texture: MTLTexture?
    private var lastLayout: NativeProjectionAtlasLayout?
    private var lastSources: [Signature] = []
    private var lastCommand: MTLCommandBuffer?
    private(set) var allocations = 0

    init(device: MTLDevice, maximumDimension: Int = 16384, maximumBytes: Int = 256*1024*1024) throws {
        self.device = device; self.maximumDimension = maximumDimension; self.maximumBytes = maximumBytes
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        let library = try device.makeLibrary(source: Self.shader, options: options)
        guard let clear = library.makeFunction(name: "projectionAtlasClear"), let copy = library.makeFunction(name: "projectionAtlasCopy") else {
            throw Failure.invalid("Metal 投影纹理复制函数缺失。")
        }
        clearPipeline = try device.makeComputePipelineState(function: clear)
        copyPipeline = try device.makeComputePipelineState(function: copy)
    }

    /// Encode before consumers of the returned texture, on one tracked queue.
    /// A completed identical frame can be reused. Uncommitted/failed frames
    /// never certify content freshness; callers must discard a failed command.
    func encode(sources: [Source], command: MTLCommandBuffer) throws -> Frame {
        guard command.commandQueue.device.registryID == device.registryID,
              queue == nil || queue == ObjectIdentifier(command.commandQueue) else {
            throw Failure.invalid("Metal 投影纹理必须在同一设备和命令队列中更新。")
        }
        guard command.status == .notEnqueued else { throw Failure.invalid("Metal 投影纹理需要尚未提交的命令缓冲。") }
        var unique: [String: Source] = [:]
        for source in sources {
            let input = source.texture
            guard input.device.registryID == device.registryID, input.textureType == .type2D, input.sampleCount == 1,
                  !input.isFramebufferOnly, input.width > 0, input.height > 0,
                  [.rgba8Unorm,.bgra8Unorm,.rgba16Float,.r8Unorm,.rg8Unorm].contains(input.pixelFormat),
                  input.usage.isEmpty || input.usage.contains(.shaderRead) else {
                throw Failure.invalid("投影源需要本设备可读取的单采样二维纹理，格式为 RGBA/BGRA8、RGBA16F、R8 或 RG8。")
            }
            guard texture !== input else { throw Failure.invalid("投影图集不能在同一更新中作为自身输入。") }
            if let previous = unique[source.id] {
                guard previous.texture === input, previous.revision == source.revision else {
                    throw Failure.invalid("同一个投影源标识对应了不同纹理或内容修订。")
                }
            } else { unique[source.id] = source }
        }
        let ordered = unique.keys.sorted().map { unique[$0]! }
        let layout = try NativeProjectionAtlasLayout(inputs: ordered.map { .init(id:$0.id,width:$0.texture.width,height:$0.texture.height) },
            maxDimension:maximumDimension,maximumBytes:maximumBytes,bytesPerPixel:8)
        let signatures = ordered.map { Signature(id:$0.id,texture:ObjectIdentifier($0.texture),revision:$0.revision) }
        if let texture, let previous = lastLayout, lastCommand?.status == .completed,
           ordered.allSatisfy({ $0.revision != nil }), signatures == lastSources,
           layout.width == previous.width, layout.height == previous.height, layout.entries == previous.entries {
            // This command may consume the cached image later. Track that
            // use too, so another unsubmitted frame cannot overwrite it.
            lastCommand = command
            return Frame(texture:texture,layout:layout,copiedSources:0)
        }
        let output: MTLTexture
        var allocated = false
        if let previous = texture, lastCommand?.status == .completed,
           previous.width == layout.width, previous.height == layout.height { output = previous }
        else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,width:layout.width,height:layout.height,mipmapped:false)
            descriptor.storageMode = .private; descriptor.usage = [.shaderRead,.shaderWrite]
            guard let image = device.makeTexture(descriptor:descriptor) else { throw Failure.invalid("无法分配 Metal 投影纹理图集。") }
            image.label = "Native projected color atlas"; output = image; allocated = true
        }
        guard let encoder = command.makeComputeCommandEncoder() else { throw Failure.invalid("无法开始 Metal 投影纹理复制。") }
        encoder.label = "Clear and copy native projection textures"
        encoder.setComputePipelineState(clearPipeline); encoder.setTexture(output,index:0)
        encoder.dispatchThreads(MTLSize(width:output.width,height:output.height,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
        encoder.memoryBarrier(resources:[output])
        encoder.setComputePipelineState(copyPipeline); encoder.setTexture(output,index:1)
        for source in ordered {
            let entry = layout.entries[source.id]!
            var origin = SIMD2<UInt32>(UInt32(entry.content.x),UInt32(entry.content.y))
            encoder.setTexture(source.texture,index:0); encoder.setBytes(&origin,length:MemoryLayout<SIMD2<UInt32>>.stride,index:0)
            encoder.dispatchThreads(MTLSize(width:source.texture.width,height:source.texture.height,depth:1),threadsPerThreadgroup:MTLSize(width:8,height:8,depth:1))
        }
        encoder.endEncoding()
        texture = output; lastLayout = layout; lastSources = signatures; lastCommand = command
        queue = ObjectIdentifier(command.commandQueue)
        if allocated { allocations += 1 }
        return Frame(texture:output,layout:layout,copiedSources:ordered.count)
    }

    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void projectionAtlasClear(texture2d<float,access::write> output [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
        output.write(float4(0),p);
    }
    kernel void projectionAtlasCopy(texture2d<float,access::read> source [[texture(0)]],
        texture2d<float,access::write> output [[texture(1)]],constant uint2 &origin [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
        output.write(source.read(p),p+origin);
    }
    """
}
