import Foundation
import Metal

/// TEX type 5 maps to GL_COMPRESSED_RGBA8_ETC2_EAC in the observed native
/// loader. Decode with Apple's matching block format during resource loading;
/// the existing renderer continues to receive straight, unflipped RGBA8 bytes.
enum NativeETC2Decoder {
    private static let context = Result { try Context() }

    static func decode(_ blocks: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        // Check before device creation, multiplication or resource allocation.
        guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
            throw SceneError.invalid("ETC2 dimensions are outside the supported range.")
        }
        let outputBytes = width * height * 4
        let blocksWide = (width + 3) / 4, blocksHigh = (height + 3) / 4
        guard outputBytes <= 64 * 1024 * 1024,
              blocks.count == blocksWide * blocksHigh * 16 else {
            throw SceneError.invalid("ETC2 block length is invalid or RGBA output exceeds 64 MiB.")
        }
        return try context.get().decode(blocks, width: width, height: height,
                                        blocksWide: blocksWide, blocksHigh: blocksHigh,
                                        outputBytes: outputBytes)
    }

    private final class Context {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let lock = NSLock()
        // Access only under lock. A timed-out job keeps its GPU resources alive
        // through the retained command buffer; do not accumulate additional jobs.
        var unavailableReason: String?

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
                  device.supportsFamily(.apple2) else {
                throw SceneError.invalid("ETC2 requires an Apple GPU with EAC_RGBA8 support and unified memory.")
            }
            guard let queue = device.makeCommandQueue() else {
                throw SceneError.invalid("Cannot create the ETC2 Metal command queue.")
            }
            let options = MTLCompileOptions()
            options.fastMathEnabled = false
            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: Self.shader, options: options)
            } catch {
                throw SceneError.invalid("Cannot compile the ETC2 resource decoder: \(error.localizedDescription)")
            }
            guard let function = library.makeFunction(name: "decodeETC2") else {
                throw SceneError.invalid("The ETC2 compute function is missing.")
            }
            do { pipeline = try device.makeComputePipelineState(function: function) }
            catch { throw SceneError.invalid("Cannot create the ETC2 pipeline: \(error.localizedDescription)") }
            self.device = device
            self.queue = queue
        }

        func decode(_ blocks: [UInt8], width: Int, height: Int,
                    blocksWide: Int, blocksHigh: Int, outputBytes: Int) throws -> [UInt8] {
            lock.lock()
            defer { lock.unlock() }
            if let unavailableReason { throw SceneError.invalid(unavailableReason) }
            return try autoreleasepool {
                // Physical storage covers complete blocks, including tiny mips.
                // The compute output uses only the original logical dimensions.
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .eac_rgba8, width: blocksWide * 4,
                    height: blocksHigh * 4, mipmapped: false)
                descriptor.storageMode = .shared
                descriptor.usage = .shaderRead
                guard let source = device.makeTexture(descriptor: descriptor),
                      let output = device.makeBuffer(length: outputBytes, options: .storageModeShared) else {
                    throw SceneError.invalid("Cannot allocate the bounded ETC2 decode resources.")
                }
                source.label = "Original TEX ETC2/EAC blocks"
                output.label = "Decoded TEX straight RGBA8"
                blocks.withUnsafeBytes { bytes in
                    source.replace(region: MTLRegionMake2D(0, 0, blocksWide * 4, blocksHigh * 4),
                                   mipmapLevel: 0, withBytes: bytes.baseAddress!,
                                   bytesPerRow: blocksHigh == 1 ? 0 : blocksWide * 16)
                }
                let commandDescriptor = MTLCommandBufferDescriptor()
                commandDescriptor.retainedReferences = true
                guard let command = queue.makeCommandBuffer(descriptor: commandDescriptor),
                      let encoder = command.makeComputeCommandEncoder() else {
                    throw SceneError.invalid("Cannot encode the ETC2 resource conversion.")
                }
                command.label = "ETC2 to RGBA resource conversion"
                encoder.setComputePipelineState(pipeline)
                encoder.setTexture(source, index: 0)
                encoder.setBuffer(output, offset: 0, index: 0)
                var size = SIMD2<UInt32>(UInt32(width), UInt32(height))
                encoder.setBytes(&size, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                encoder.dispatchThreadgroups(MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
                                             threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
                encoder.endEncoding()
                let completion = DispatchSemaphore(value: 0)
                // The handler also explicitly owns both resources until real
                // completion, even when the CPU-side wait has timed out.
                command.addCompletedHandler { _ in
                    withExtendedLifetime((source, output)) { _ = completion.signal() }
                }
                command.commit()
                guard completion.wait(timeout: .now() + 5) == .success else {
                    let message = "ETC2 GPU conversion timed out; this decoder is disabled until the app restarts."
                    unavailableReason = message
                    throw SceneError.invalid(message)
                }
                guard command.status == .completed else {
                    throw SceneError.invalid("ETC2 GPU conversion failed: \(command.error?.localizedDescription ?? "unknown Metal error")")
                }
                return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: UInt8.self),
                                                 count: outputBytes))
            }
        }

        private static let shader = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void decodeETC2(texture2d<float, access::sample> source [[texture(0)]],
                               device uchar4 *output [[buffer(0)]],
                               constant uint2 &size [[buffer(1)]],
                               uint2 position [[thread_position_in_grid]]) {
            if (any(position >= size)) return;
            constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
            float2 uv = (float2(position) + 0.5f) / float2(source.get_width(), source.get_height());
            float4 rgba = source.sample(nearest, uv, level(0.0f));
            output[position.y * size.x + position.x] = uchar4(round(clamp(rgba, 0.0f, 1.0f) * 255.0f));
        }
        """
    }
}
