import Foundation
import Metal

/// The existing Scene material contract: LEQUAL when enabled, and no depth
/// writes at all when depth testing is disabled (including write-only passes).
struct NativeMetalDepth: Equatable {
    let test: Bool
    let write: Bool
    static let disabled = Self(test: false, write: false)
    var key: Int { test ? (write ? 3 : 1) : 0 }

    private init(test: Bool, write: Bool) { self.test = test; self.write = write }
    init(_ definition: [String: Any]) throws {
        func enabled(_ key: String) throws -> Bool {
            guard let raw = definition[key] else { return false }
            guard let value = raw as? String, ["enabled", "disabled"].contains(value) else {
                throw SceneError.invalid("Metal 材质 \(key) 需要 enabled 或 disabled。")
            }
            return value == "enabled"
        }
        test = try enabled("depthtest"); write = try enabled("depthwrite")
    }

    @MainActor static func states(device: MTLDevice) throws -> [Int: MTLDepthStencilState] {
        var states: [Int: MTLDepthStencilState] = [:]
        for key in [0, 1, 3] {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = key == 0 ? .always : .lessEqual
            descriptor.isDepthWriteEnabled = key == 3
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
                throw SceneError.invalid("无法创建 Metal 深度状态。")
            }
            states[key] = state
        }
        return states
    }
}

/// One current-sized attachment per renderer. GPU commands retain prior
/// attachments through a resize; local image effects never own or clear it.
@MainActor
final class NativeMetalDepthTarget {
    private(set) var texture: MTLTexture?
    private(set) var allocations = 0
    func prepare(device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        guard (1...16384).contains(width), (1...16384).contains(height),
              width * height <= 64 * 1024 * 1024 else {
            throw SceneError.invalid("Metal 深度缓冲超过 16384 边长或 256 MiB。")
        }
        if let texture, texture.width == width, texture.height == height { return texture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
        guard let next = device.makeTexture(descriptor: descriptor) else {
            throw SceneError.invalid("无法分配 Metal 深度缓冲。")
        }
        next.label = "Scene depth across image effect passes"
        texture = next; allocations += 1
        return next
    }
    var diagnostic: String {
        guard let texture else { return "Metal 深度：当前场景未分配深度缓冲。" }
        return "Metal 深度：\(texture.width)×\(texture.height) Depth32Float，\(texture.width * texture.height * 4) 字节，累计分配 \(allocations) 次；按场景 clearenabled 决定清除或恢复历史，跨离屏效果保留；比较 LEQUAL。"
    }
}
