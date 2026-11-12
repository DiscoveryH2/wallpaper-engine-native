import AppKit
import Foundation
import CryptoKit
import OpenGL.GL3
import simd

private let sceneObjectProperties = ["origin", "angles", "scale", "color", "alpha", "opacity", "visible", "parallaxDepth", "volume", "mintime", "maxtime"] + SceneTextLayout.properties
private let sceneCameraProperties = ["fov", "zoom", "queuemode"]
private let sceneLightProperties = ["intensity", "radius", "exponent", "innercone", "outercone", "lightsourcesize", "castvolumetrics", "usecookie", "density", "volumetricsexponent"]
private let sceneLightingProperties = ["ambientcolor", "skylightcolor", "clearcolor", "clearenabled", "fogdistance", "fogdistancecolor", "fogdistancestart", "fogdistanceend", "fogdistancestartdensity", "fogdistanceenddensity"]
private let sceneBloomProperties = ["bloom", "bloomstrength", "bloomthreshold", "bloomtint", "bloomhdrstrength", "bloomhdrthreshold", "bloomhdrfeather", "bloomhdrscatter", "bloomhdriterations"]
private func sceneProperties(for object: [String: Any]) -> [String] {
    sceneObjectProperties + (object["camera"] is String ? sceneCameraProperties : [])
        + (object["light"] is String ? sceneLightProperties : [])
        + (object["light"] is String || object["model"] is String ? ["castshadow"] : [])
        + (object["model"] is String ? ["rootmotion"] : [])
}
private let sceneParallaxProperties = ["cameraparallax", "cameraparallaxamount", "cameraparallaxdelay", "cameraparallaxmouseinfluence"]
private let sceneShakeProperties = ["camerashake", "camerashakespeed", "camerashakeamplitude", "camerashakeroughness", "camerafade"]
private let sceneProjectionProperties = ["fov", "nearz", "farz"]
private let sceneOrthographicProperties = ["zoom", "perspectiveoverridefov"]

// Runtime code is ours; the selected wallpaper retains its own geometry and GLSL.
// OpenGL is an Apple system framework. It is deprecated, so this backend is kept
// separate from resource decoding and scene construction for a future Metal path.
enum SceneValues {
    static func floats(_ raw: Any?, fallback: [Float] = []) -> [Float] {
        if let number = raw as? NSNumber { return [number.floatValue] }
        if let text = raw as? String { return text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { Float($0) } }
        if let array = raw as? [NSNumber] { return array.map(\.floatValue) }
        if let wrapped = raw as? [String: Any] {
            if wrapped["x"] != nil { return ["x", "y", "z", "w"].compactMap { (wrapped[$0] as? NSNumber)?.floatValue } }
            return floats(wrapped["value"], fallback: fallback)
        }
        return fallback
    }
    static func vector(_ raw: Any?, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        let a = floats(raw)
        return a.count >= 3 && a.prefix(3).allSatisfy(\.isFinite) ? SIMD3(a[0], a[1], a[2]) : fallback
    }
    static func number(_ raw: Any?, _ fallback: Float) -> Float {
        guard let v = floats(raw).first, v.isFinite else { return fallback }; return v
    }
    static func visible(_ raw: Any?) -> Bool {
        if let v = raw as? Bool { return v }
        if let wrapped = raw as? [String: Any], let v = wrapped["value"] as? Bool { return v }
        return true
    }
    static func transform(_ object: [String: Any]) -> simd_float4x4 {
        let origin = vector(object["origin"], .zero)
        let scale = vector(object["scale"], SIMD3(repeating: 1))
        let angles = vector(object["angles"], .zero)
        let qx = simd_quatf(angle: angles.x, axis: SIMD3(1, 0, 0))
        let qy = simd_quatf(angle: angles.y, axis: SIMD3(0, 1, 0))
        let qz = simd_quatf(angle: angles.z, axis: SIMD3(0, 0, 1))
        var matrix = simd_float4x4(qz * qy * qx)
        matrix.columns.0 *= scale.x; matrix.columns.1 *= scale.y; matrix.columns.2 *= scale.z
        matrix.columns.3 = SIMD4(origin, 1)
        return matrix
    }
}

private final class SceneGeometry {
    var vao: GLuint = 0
    private var vertexBuffer: GLuint = 0
    private var indexBuffer: GLuint = 0
    private(set) var count: GLsizei = 0
    private let indexed: Bool
    private var shapePoints: [SIMD2<Float>] = []

    init(vertices: [Float], indices: [UInt32] = [], particles: Bool = false, skinned: Bool = false) {
        indexed = !particles
        count = GLsizei(particles ? vertices.count / 12 : indices.count)
        glGenVertexArrays(1, &vao); glBindVertexArray(vao)
        glGenBuffers(1, &vertexBuffer); glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexBuffer)
        vertices.withUnsafeBytes { glBufferData(GLenum(GL_ARRAY_BUFFER), $0.count, $0.baseAddress, GLenum(particles ? GL_DYNAMIC_DRAW : GL_STATIC_DRAW)) }
        let stride = GLsizei((skinned ? 20 : 12) * MemoryLayout<Float>.size)
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 3, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, nil)
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, UnsafeRawPointer(bitPattern: (particles ? 3 : (skinned ? 18 : 10)) * 4))
        if particles {
            glEnableVertexAttribArray(4)
            glVertexAttribPointer(4, 4, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, UnsafeRawPointer(bitPattern: 5 * 4))
            glEnableVertexAttribArray(5)
            glVertexAttribPointer(5, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, UnsafeRawPointer(bitPattern: 9 * 4))
            glEnableVertexAttribArray(6)
            glVertexAttribPointer(6, 1, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, UnsafeRawPointer(bitPattern: 11 * 4))
        } else {
            glEnableVertexAttribArray(2); glVertexAttribPointer(2, 3, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, UnsafeRawPointer(bitPattern: 12))
            glEnableVertexAttribArray(3); glVertexAttribPointer(3, 4, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, UnsafeRawPointer(bitPattern: 24))
            if skinned {
                glEnableVertexAttribArray(7); glVertexAttribPointer(7, 4, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, UnsafeRawPointer(bitPattern: 40))
                glEnableVertexAttribArray(8); glVertexAttribPointer(8, 4, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride, UnsafeRawPointer(bitPattern: 56))
            }
            glGenBuffers(1, &indexBuffer); glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), indexBuffer)
            indices.withUnsafeBytes { glBufferData(GLenum(GL_ELEMENT_ARRAY_BUFFER), $0.count, $0.baseAddress, GLenum(GL_STATIC_DRAW)) }
        }
        glBindVertexArray(0)
    }

    static func quad(framebufferUV: Bool = false, width: Float = 2, height: Float = 2) -> SceneGeometry {
        let positions: [(Float, Float, Float, Float)] = [(-1,-1,0,framebufferUV ? 0 : 1), (1,-1,1,framebufferUV ? 0 : 1), (1,1,1,framebufferUV ? 1 : 0), (-1,1,0,framebufferUV ? 1 : 0)]
        let vertices: [Float] = positions.flatMap { x, y, u, v in [x * width / 2, y * height / 2, 0, 0, 0, 1, 1, 0, 0, 1, u, v] }
        let geometry = SceneGeometry(vertices: vertices, indices: [0,1,2,0,2,3])
        geometry.editorQuadSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        return geometry
    }

    private(set) var editorQuadSize: CGSize?

    static func shapeQuad(points: [SIMD2<Float>], height: Float) -> SceneGeometry {
        let geometry = SceneGeometry(vertices: shapeVertices(points, height: height), indices: [0,2,1,0,3,2])
        geometry.shapePoints = points
        return geometry
    }

    private static func shapeVertices(_ points: [SIMD2<Float>], height: Float) -> [Float] {
        points.flatMap { p in
            [(p.x - 0.5) * height, (0.5 - p.y) * height, 0, 0, 0, 1, 1, 0, 0, 1, p.x, p.y]
        }
    }

    func updateShape(points: [SIMD2<Float>], height: Float) {
        guard points != shapePoints else { return }
        let vertices = Self.shapeVertices(points, height: height)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexBuffer)
        vertices.withUnsafeBytes { glBufferData(GLenum(GL_ARRAY_BUFFER), $0.count, $0.baseAddress, GLenum(GL_DYNAMIC_DRAW)) }
        shapePoints = points
    }

    func update(_ vertices: [Float]) {
        count = GLsizei(vertices.count / 12)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexBuffer)
        vertices.withUnsafeBytes { glBufferData(GLenum(GL_ARRAY_BUFFER), $0.count, $0.baseAddress, GLenum(GL_DYNAMIC_DRAW)) }
    }
    func updateIndexedVertices(_ vertices: [Float]) {
        guard indexed, vertices.count % 12 == 0 else { return }
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexBuffer)
        vertices.withUnsafeBytes { glBufferData(GLenum(GL_ARRAY_BUFFER), $0.count, $0.baseAddress, GLenum(GL_DYNAMIC_DRAW)) }
    }
    func resizeQuad(width: Float, height: Float) {
        editorQuadSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        let positions: [(Float, Float, Float, Float)] = [(-1,-1,0,1), (1,-1,1,1), (1,1,1,0), (-1,1,0,0)]
        let vertices: [Float] = positions.flatMap { x, y, u, v in
            [x * width / 2, y * height / 2, 0, 0, 0, 1, 1, 0, 0, 1, u, v]
        }
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vertexBuffer)
        vertices.withUnsafeBytes { glBufferData(GLenum(GL_ARRAY_BUFFER), $0.count, $0.baseAddress, GLenum(GL_DYNAMIC_DRAW)) }
    }
    func draw() {
        glBindVertexArray(vao)
        if indexed { glDrawElements(GLenum(GL_TRIANGLES), count, GLenum(GL_UNSIGNED_INT), nil) }
        else { glDrawArrays(GLenum(GL_TRIANGLES), 0, count) }
        glBindVertexArray(0)
    }
    func drawPuppetRanges(_ selected: [Int], records: [NativePuppetModel.RangeRecord]) {
        guard indexed else { return }
        glBindVertexArray(vao)
        for index in selected where records.indices.contains(index) {
            let range = records[index].words
            glDrawElements(GLenum(GL_TRIANGLES), GLsizei(range.w), GLenum(GL_UNSIGNED_INT),
                           UnsafeRawPointer(bitPattern: Int(range.z) * MemoryLayout<UInt32>.size))
        }
        glBindVertexArray(0)
    }
    deinit {
        glDeleteBuffers(1, &vertexBuffer)
        if indexBuffer != 0 { glDeleteBuffers(1, &indexBuffer) }
        glDeleteVertexArrays(1, &vao)
    }
}

private final class SceneGLTexture {
    var name: GLuint = 0
    private(set) var width: Int
    private(set) var height: Int
    private(set) var imageWidth: Int
    private(set) var imageHeight: Int
    private(set) var channelCount: Int
    private var pixelWidth: Int
    private var pixelHeight: Int
    let animation: SceneTextureAnimation?
    let nearest: Bool
    var sourceType: UInt32 = 0
    var mipLevel: Int = 0
    var videoKey: String?
    var videoPTS: Double?
    init(width: Int, height: Int, imageWidth: Int? = nil, imageHeight: Int? = nil, rgba: [UInt8], repeating: Bool = true, channelCount: Int = 4, animation: SceneTextureAnimation? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil, compressedBC3: [UInt8]? = nil, nearest: Bool = false) {
        self.width = width; self.height = height
        self.pixelWidth = pixelWidth ?? width; self.pixelHeight = pixelHeight ?? height
        self.imageWidth = imageWidth ?? width; self.imageHeight = imageHeight ?? height
        self.channelCount = channelCount
        self.animation = animation
        self.nearest = nearest
        glGenTextures(1, &name); glBindTexture(GLenum(GL_TEXTURE_2D), name)
        // Rebase the selected authored mip to this GPU texture's level zero.
        // Logical dimensions remain separate, keeping normalized image UVs.
        if let compressedBC3 {
            // GL_COMPRESSED_RGBA_S3TC_DXT5_EXT. The caller checks support in
            // this context before the decoder retains original BC3 blocks.
            compressedBC3.withUnsafeBytes { glCompressedTexImage2D(GLenum(GL_TEXTURE_2D), 0, 0x83F3,
                GLsizei(self.pixelWidth), GLsizei(self.pixelHeight), 0, GLsizei($0.count), $0.baseAddress) }
        } else {
            rgba.withUnsafeBytes { glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(self.pixelWidth), GLsizei(self.pixelHeight), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress) }
        }
        // Automatic atlas mipmaps mix neighbouring frames. Keep the base level
        // until a per-frame mip chain is implemented.
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), nearest ? GL_NEAREST : (animation == nil ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), nearest ? GL_NEAREST : GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), repeating ? GL_REPEAT : GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), repeating ? GL_REPEAT : GL_CLAMP_TO_EDGE)
        if !nearest && animation == nil { glGenerateMipmap(GLenum(GL_TEXTURE_2D)) }
    }
    func replace(width: Int, height: Int, rgba: [UInt8]) {
        glBindTexture(GLenum(GL_TEXTURE_2D), name)
        rgba.withUnsafeBytes {
            if pixelWidth == width && pixelHeight == height {
                glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0, 0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
            } else {
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress)
            }
        }
        self.width = width; self.height = height; imageWidth = width; imageHeight = height
        pixelWidth = width; pixelHeight = height
        channelCount = 4
        if !nearest && animation == nil { glGenerateMipmap(GLenum(GL_TEXTURE_2D)) }
    }
    deinit { glDeleteTextures(1, &name) }
}

final class SceneTarget {
    var multisample: NativeOpenGLAntialiasing?
    var drawFramebuffer: GLuint { multisample?.framebuffer ?? framebuffer }
    func resolveSamples() { multisample?.resolve(to: self) }
    func seedSamples(depth: Bool) { multisample?.seed(from: self, depth: depth) }
    var framebuffer: GLuint = 0
    var texture: GLuint = 0
    var depth: GLuint = 0
    let width: Int, height: Int
    let hdr: Bool
    init(width: Int, height: Int, withDepth: Bool = true, hdr: Bool, mipmapped: Bool = false) throws {
        self.width = width; self.height = height; self.hdr = hdr
        glGenFramebuffers(1, &framebuffer); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glGenTextures(1, &texture); glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, hdr ? GL_RGBA16F : GL_RGBA8, GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA), GLenum(hdr ? GL_FLOAT : GL_UNSIGNED_BYTE), nil)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        if withDepth {
            glGenRenderbuffers(1, &depth); glBindRenderbuffer(GLenum(GL_RENDERBUFFER), depth)
            glRenderbufferStorage(GLenum(GL_RENDERBUFFER), GLenum(GL_DEPTH_COMPONENT24), GLsizei(width), GLsizei(height))
            glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_DEPTH_ATTACHMENT), GLenum(GL_RENDERBUFFER), depth)
        }
        guard glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE) else { throw SceneError.invalid("OpenGL 场景帧缓冲创建失败。") }
        if mipmapped {
            // Define the first history sample and every mip before it can be read.
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            glGenerateMipmap(GLenum(GL_TEXTURE_2D))
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR_MIPMAP_LINEAR)
        }
    }
    /// History targets can be sampled before the graph has written them during
    /// its first frame. Define that initial sample instead of relying on GPU
    /// allocation contents. Normal effect stages clear immediately before
    /// their own writes and do not need this path.
    func clearHistory() {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        glClearColor(0, 0, 0, 0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
    }
    deinit { if depth != 0 { glDeleteRenderbuffers(1, &depth) }; glDeleteTextures(1, &texture); glDeleteFramebuffers(1, &framebuffer) }
}

private struct ScenePass {
    var shader: SceneShader
    let definition: [String: Any]
    let textures: [Int: SceneGLTexture]
    let framebufferSlots: Set<Int>
    var uniforms: [String: [Float]]
    var scriptUniforms: [String: String] = [:]
    var timelineUniforms: [String: String] = [:]
    var userUniforms: [String: String] = [:]
    var materialUniforms: [String: String] = [:]
    var materialObject: SceneScriptMaterial? = nil
    var visibility: Any? = nil
    var visibilityPath: String? = nil
    var effectGroup: Int? = nil
    var graphTarget: String? = nil
    var graphBindings: [Int: String] = [:]
    /// A graph `command: copy` has no material. It retains the source key here
    /// so the render loop can encode a framebuffer copy at the authored point
    /// in the effect sequence.
    var graphCopySource: String? = nil
    var applyObjectAppearance = true
    var nativeModelMaterial = false
    var shadowShader: SceneShader? = nil
    var mipmappedFramebufferSlots: Set<Int> = []
    var layerCompositeSlots: [Int: String] = [:]
    func forModelInstance(_ index: Int) -> Self {
        var copy = self
        let prefix = "/objects/\(index)"
        copy.scriptUniforms = scriptUniforms.mapValues { prefix + $0 }
        copy.timelineUniforms = timelineUniforms.mapValues { prefix + $0 }
        copy.materialUniforms = materialUniforms.mapValues { prefix + $0 }
        copy.materialObject = materialObject?.prepending(prefix)
        return copy
    }
    var usesSceneTransforms: Bool {
        ["g_ModelMatrix", "g_ViewMatrix", "g_ProjectionMatrix", "g_ViewProjectionMatrix", "g_ModelViewProjectionMatrix"].contains { shader.location($0) >= 0 }
    }
}

/// Image effects operate on the image in its own coordinates, before that image
/// is placed into the scene. The last pass stays on the scene quad so a vertex
/// effect can move a corner beyond the original image bounds without clipping.
private struct SceneImageLayer {
    var targets: [SceneTarget]
    let stages: [ScenePass]
    var projection: simd_float4x4
    let blending: String
    let targetSpecs: [String: SceneEffectTargetSpec]
    var namedTargets: [String: SceneTarget]
    let historyTargets: Set<String>
    let copyPass: ScenePass
    let colorBlendMode: Int
}

private final class SceneTextState {
    let layout: SceneTextLayout
    let anchor: NativeTextAnchor.State
    let texture: SceneGLTexture
    var offset: SIMD2<Float>
    var uploads = 1
    init(layout: SceneTextLayout, texture: SceneGLTexture, offset: SIMD2<Float>, object: [String: Any]) throws {
        anchor = try NativeTextAnchor.State(object)
        self.layout = layout; self.texture = texture; self.offset = offset
    }
}

private struct ScenePuppetClip {
    let plan: NativePuppetClipPlan
    let textures: [SceneGLTexture]
    let maskPass: ScenePass
    let clippedPass: ScenePass
}

private struct SceneDraw {
    let name: String
    var geometry: SceneGeometry
    let transform: simd_float4x4
    let fullscreen: Bool
    let copyBackground: Bool
    let passes: [ScenePass]
    var particles: SceneParticles?
    var particleChildren: SceneParticleChildren? = nil
    var imageLayer: SceneImageLayer? = nil
    var objectIndex: Int? = nil
    var text: SceneTextState? = nil
    var captureBackground = false
    var alignmentOffset = SIMD2<Float>.zero
    var shapeHeight: Float? = nil
    var skeleton: NativeModelSkeleton? = nil
    var puppet: NativePuppetAnimation? = nil
    var puppetClip: ScenePuppetClip? = nil
    var modelBounds: NativePointShadows.Bounds? = nil
    var topLeftFullscreen = false
}

@MainActor
final class SceneWallpaperView: NSOpenGLView, NativeSceneRendering {
    var backendSelectionNote: String?
    private(set) var failedLayerCount = 0
    var view: NSView { self }
    var propertyUpdateRevision: UInt64 {
        (lifecycleSnapshot?.revision ?? 0) &+ (scripts?.creationPreparationRevision ?? 0) &+ renderConfigurationRevision
    }
    private var diagnosticNotes: [String] = []
    private var imageBlurBindings = 0
    private var imageBlurVariants = Set<String>()
    private var puppetVerticesReserved = 0
    private var puppetAnimationBytesReserved = 0
    private var puppetMasksReserved = 0
    private var puppetMaskPasses = 0
    /// Reservations belong to the stable object slot and are retired with it.
    /// A staged insertion can sum these without reconstructing survivor pools.
    private struct ObjectAllocation {
        var emitterHistories = 0, worldChildInstances = 0
        var childParticles = 0, childInstances = 0
        var puppetVertices = 0, puppetAnimationBytes = 0, puppetMasks = 0
        mutating func add(_ other: Self) {
            emitterHistories += other.emitterHistories; worldChildInstances += other.worldChildInstances
            childParticles += other.childParticles; childInstances += other.childInstances
            puppetVertices += other.puppetVertices; puppetAnimationBytes += other.puppetAnimationBytes; puppetMasks += other.puppetMasks
        }
    }
    private var objectAllocations: [Int: ObjectAllocation] = [:]
    private var objectDiagnosticNotes: [Int: [String]] = [:]
    private var diagnosticOwner: Int?
    private var incrementalCreationSlots: Set<Int>?
    var diagnostics: [String] {
        let children = draws.compactMap { draw -> String? in
            guard let state = draw.particleChildren?.runtimeDiagnostic else { return nil }
            let identity = draw.objectIndex.map { "（图层 \($0 + 1)）" } ?? ""
            return "\(draw.name)\(identity)：\(state)"
        }
        var result = ["渲染后端：OpenGL · Scene 兼容路径。"] + diagnosticNotes
        if let lifecycleSnapshot {
            result.append("活动场景：修订 \(lifecycleSnapshot.revision)，\(lifecycleSnapshot.count) 个图层；\(draws.count) 个绘制组。")
        }
        if let preparation = creationPreparationStatistics {
            result.append("最近动态创建：后台准备纹理 \(preparation.decodedTextures) 份、模型 \(preparation.decodedModels) 份，复用模型材质清单 \(preparation.reusedModelMaterialInventories) 份；上传复用 \(preparation.textureCacheHits)/\(preparation.modelCacheHits) 份，主线程回退解码 \(preparation.textureFallbackDecodes)/\(preparation.modelFallbackDecodes) 份。GPU 构造仍在所属上下文执行。")
            result.append(String(format: "最近动态创建：复用 %d 个已有图层，构造 %d 个图层；场景资源构造 %.2f 毫秒。", preparation.retainedObjects, preparation.constructedObjects, preparation.constructionSeconds * 1000))
        }
        for draw in draws {
            guard let text = draw.text else { continue }
            result += (["OpenGL 文字：\(text.texture.width)×\(text.texture.height)，图片提交 \(text.uploads) 次，排版偏移 \(text.offset)。"]
                + [text.layout.runtimeDiagnostic].compactMap { $0 } + text.anchor.diagnostics).map { draw.name + "：" + $0 }
        }
        result += videoRuntimes.keys.sorted().compactMap { key in videoRuntimes[key].map { $0.diagnostic + " · " + key } }
        result += textures.values.compactMap { texture in texture.videoPTS.map { "OpenGL 视频上传 PTS \($0) · \(texture.videoKey ?? "")" } }
        if let backendSelectionNote { result.append(backendSelectionNote) }
        if let projectionRuntimeDiagnostic { result.append(projectionRuntimeDiagnostic) }
        if let orthographicRuntimeDiagnostic { result.append(orthographicRuntimeDiagnostic) }
        result.append(legacyCamera.runtimeDiagnostic)
        result.append(NativeCameraFade(enabled: generalValue("camerafade") as? Bool ?? true, amount: legacyCamera.fadeAmount, tint: NativeCameraFade.tint(properties: properties)).diagnostic)
        result.append(sceneCameras.runtimeDiagnostic)
        result.append(frameUniforms.runtimeDiagnostic(paused: sceneClock.isPaused))
        if let parallaxViewDiagnostic { result.append(parallaxViewDiagnostic) }
        if let modelRuntimeDiagnostic { result.append(modelRuntimeDiagnostic) }
        if let reflectionHistory { result.append(reflectionHistory.runtimeDiagnostic) }
        if let sceneHistory { result.append(sceneHistory.runtimeDiagnostic) }
        if let pointShadows { result.append(pointShadows.runtimeDiagnostic) }
        if let pointVolumetrics { result.append(pointVolumetrics.runtimeDiagnostic) }
        if let standardBloom { result.append(standardBloom.runtimeDiagnostic) }
        if let hdrBloom { result.append(hdrBloom.runtimeDiagnostic) }
        if layerTargetPixels > 0 {
            result.append("图层效果缓冲：已分配 \(layerTargetPixels) 像素，上限 \(layerTargetLimitDescription) 像素；RGBA16F 每像素占用字节多于 RGBA8。")
        }
        if draws.contains(where: { $0.puppetClip != nil }) {
            result.append("木偶遮罩快照：当前帧执行 \(puppetMaskPasses) 次遮罩合成；仅支持已验证规划器接受的简单范围。")
        }
        if imageBlurBindings > 0 {
            result.append("精确模糊绑定快照：场景时间 \(String(format: "%.6f", currentSceneTime)) s，当前帧 \(imageBlurBindings) 次；\(imageBlurVariants.sorted().joined(separator: "；"))。最多列出 16 种绑定参数；绑定不等于逐像素一致性。")
        }
        if let compositeRuntimeDiagnostic { result.append(compositeRuntimeDiagnostic) }
        if let timelineDiagnostic = timelines.runtimeDiagnostic { result.append(timelineDiagnostic) }
        if !nativeCreationMotions.isEmpty {
            let animated = nativeCreationMotions.values.filter { $0.hasKeyframes }.count
            result.append("原生作品动画：\(nativeCreationMotions.count) 个图层，\(animated) 层含关键帧；场景时间 \(String(format: "%.3f", currentSceneTime)) 秒。以下为已计算的图层变换，不代表像素一致性。")
            for index in nativeCreationPoses.keys.sorted().prefix(8) {
                guard let pose = nativeCreationPoses[index], let motion = nativeCreationMotions[index] else { continue }
                result.append(String(format: "图层 %d · %d 个属性关键帧 · X %.3f Y %.3f · 缩放 %.4f / %.4f · 旋转 %.3f° · 透明度 %.4f", index + 1, motion.scalarKeyframeCount, pose.x, pose.y, pose.scaleX, pose.scaleY, pose.rotation, pose.opacity))
            }
        }
        result.append("全局抗锯齿：\(antialiasingQuality.title)；实际场景采样数 \(targets.first?.multisample?.samples ?? 1)，抗锯齿缓冲 \(targets.reduce(0) { $0 + ($1.multisample?.bytes ?? 0) }) 字节。")
        result.append("全局纹理分辨率：\(textureResolutionQuality.title)；请求跳过 \(textureResolutionRequest.preferredMip(canvas: textureResolutionCanvas)) 层，实际使用较小纹理 \(textures.values.filter { $0.mipLevel > 0 }.count)/\(textures.count) 张；纹理基础层保留 \(textureBytes) 字节。")
        if let textureResolutionFailure { result.append("纹理分辨率未应用，保留原画面：" + textureResolutionFailure) }
        result.append("全局后处理：\(postProcessingQuality.title)，场景缓冲 \(sceneHDR ? "RGBA16F" : "RGBA8")；最终输出 SDR。")
        if let scripts { result.append(scripts.runtimeDiagnostic) }
        if scripts != nil { result.append(pointerRuntimeDiagnostic) }
        if let camera = scripts?.cameraRuntimeDiagnostic {
            result.append(camera + " 当前视图来源：\(cameraPoseSource)；活动路径优先，静态姿态不含视差或抖动。")
        }
        let puppets = draws.compactMap { draw in draw.puppet.map { "\(draw.name)：\($0.runtimeDiagnostic)" } }
        result.append(contentsOf: puppets.prefix(32))
        if puppets.count > 32 { result.append("木偶动画运行快照仅显示前 32 个图层。") }
        let particles = draws.compactMap { draw in draw.particles.map { "\(draw.name)：\($0.runtimeDiagnostic)" } }
        result.append(contentsOf: particles.prefix(64))
        if particles.count > 64 { result.append("粒子运行快照仅显示前 64 个系统。") }
        result.append(contentsOf: children.prefix(64))
        if children.count > 64 { result.append("子粒子运行快照仅显示前 64 个系统。") }
        return result
    }
    private var assets: SceneAssets
    private let projectURL: URL
    private let authoredFileSignature: Data
    private let creationQueue: DispatchQueue
    private var resourceContext: NSOpenGLContext?
    private var preparedModels: [String: SceneModel] = [:]
    private var preparedTextures: [String: Result<SceneTexture, Error>] = [:]
    private var creationPreparationStatistics: NativeOpenGLPreparationStatistics?
    private let builtinTextures: NativeBuiltinTextures.Snapshot?
    private let builtinTextureError: String?
    private let builtinFonts: NativeBuiltinFonts.Snapshot?
    private let builtinFontError: String?
    private var scene: [String: Any]
    private var lifecycleSnapshot: NativeSceneLifecycle.Snapshot?
    private let strictResourcePreparation: Bool
    private var initialSceneLayerOrder: NativeSceneLayerOrder?
    private var renderConfigurationRevision: UInt64 = 0
    private(set) var antialiasingQuality: NativeAntialiasing = .none
    private(set) var postProcessingQuality: NativePostProcessingQuality = .ultra
    private var textureResolutionRequest = NativeTextureResolutionRequest()
    var textureResolutionQuality: NativeTextureResolution { textureResolutionRequest.quality }
    private var textureResolutionCanvas: NativeTextureCanvas { NativeTextureCanvas(scene: scene) }
    private var textureResolutionAttempt: String?
    private var textureResolutionFailure: String?
    private var sceneHDR: Bool { postProcessingQuality.usesHDR(authored: (scene["general"] as? [String: Any])?["hdr"] as? Bool == true) }
    private var hierarchy: SceneHierarchy
    private var properties: [String: Any]
    private var draws: [SceneDraw] = []
    private struct ModelShape {
        let geometry: SceneGeometry
        let passes: [ScenePass]
        let skeleton: NativeModelSkeleton?
        let bounds: NativePointShadows.Bounds?
    }
    private var modelResources: [String: Result<[ModelShape], Error>] = [:]
    private var modelResourceSizes: [String: (geometry: Int, animation: Int, shapes: Int, skeletons: Int)] = [:]
    private var modelBufferBytes = 0
    private var modelInstanceCount = 0
    private var modelShapeCount = 0
    private var skinnedModelInstanceCount = 0
    private var skeletonResourceCount = 0
    private var modelAnimationBytes = 0
    private var modelLightFrame = NativeModelLightFrame()
    private var modelRuntimeDiagnostic: String?
    private var modelAnimations: [Int: NativeModelAnimation.Runtime] = [:]
    private var modelScriptStore = NativeModelScriptStore()
    var modelAnimationSnapshots: [Int: [String: Any]] { modelAnimations.mapValues(\.snapshot) }
    private var pointShadows: NativePointShadows?
    private var shadowShaders: [Int: SceneShader] = [:]
    private var shadowAllocationFailed = false
    private var pointVolumetrics: NativePointVolumetrics?
    private var volumeAllocationFailed = false
    private var textures: [String: SceneGLTexture] = [:]
    private var textureReservations: [String: Int] = [:]
    private var videoLibrary: SceneVideoLibrary
    private var videoRuntimes: [String: SceneVideoRuntime] = [:]
    /// Transport telemetry, not a claim that an attached output device made
    /// the otherwise silent test material audible.
    var videoAudioRuntimeStates: [String: [String: Any]] { videoRuntimes.mapValues(\.audioRuntimeState) }
    private var displayedMediaRevision = -1
    private var displayedMediaArtwork: NativeMediaArtwork?
    private var mediaTextureReports = 0
    private var textureBytes = 0
    private var textPixelCount = 0
    private var textLayerCount = 0
    private var layerTargetPixels = 0
    private let layerTargetPixelLimit = NativeSceneBufferBudget.imageTargetPixels(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    private var layerTargetLimitDescription: String { String(format: "%.1fM", Double(layerTargetPixelLimit) / (1024 * 1024)) }
    private var imageTargetPool: [String: [SceneTarget]] = [:]
    /// Cumulative native effect-graph copies for diagnostics and isolated
    /// offscreen verification. It intentionally does not reset every frame.
    private var graphCopyCommandCount = 0
    private var compositeOrder: [(id: String, draw: Int)] = []
    private var compositeTargets: [String: SceneTarget] = [:]
    private var compositeReady = Set<String>()
    private var compositeFrames = 0
    private var compositeRuntimeDiagnostic: String?
    private var fullscreenInput: SceneTarget?
    private var puppetMaskTarget: SceneTarget?
    private var puppetMaskShader: SceneShader?
    private var puppetClippedShader: SceneShader?
    private var targets: [SceneTarget] = []
    private var hdrBloom: NativeHDRBloom?
    private var standardBloom: NativeStandardBloom?
    private var reflectionHistory: NativeSceneReflection?
    private var reflectionsEnabled = true
    private var volumetricQuality: NativeVolumetricQuality = .high
    func setVolumetricQuality(_ quality: NativeVolumetricQuality) {
        guard volumetricQuality != quality else { return }
        volumetricQuality = quality; volumeAllocationFailed = false; needsDisplay = true
    }
    private var shadowQuality: NativeShadowQuality = .high
    func setShadowQuality(_ quality: NativeShadowQuality) {
        guard shadowQuality != quality else { return }
        shadowQuality = quality; shadowAllocationFailed = false; needsDisplay = true
    }
    // Arbitrary author shaders may use this resource for something other than
    // model reflections. Their authored behavior remains independent.
    private var needsReflectionHistory: Bool {
        draws.contains { draw in
            (draw.passes + (draw.imageLayer?.stages ?? [])).contains {
                !$0.mipmappedFramebufferSlots.isEmpty && (reflectionsEnabled || !$0.nativeModelMaterial)
            }
        }
    }
    func setReflectionsEnabled(_ enabled: Bool) {
        guard reflectionsEnabled != enabled else { return }
        reflectionsEnabled = enabled; needsDisplay = true
    }
    private var sceneHistory: NativeSceneHistory?
    private var reflectionPassCount: Int {
        draws.reduce(0) { total, draw in
            total + (draw.passes + (draw.imageLayer?.stages ?? [])).filter { !$0.mipmappedFramebufferSlots.isEmpty }.count
        }
    }
    private var screenQuad: SceneGeometry!
    private var imageQuad: SceneGeometry!
    private var presentShader: SceneShader!
    private var imageCopyShader: SceneShader!
    private var imageBlendShaders: [Int: SceneShader] = [:]
    private var timer: Timer?
    private var sceneClock = ScenePlaybackClock()
    private let presentationID = UUID().uuidString
    private var presentationArmed = false
    private let constructionStartedAt = ProcessInfo.processInfo.systemUptime
    private var startupWaitStartedAt: Double?
    private var startupPlaceholderFrames = 0
    private var reportedFrameError = false
    private var renderedFrames: UInt64 = 0
    private var previousSceneTime: Double?
    private var scripts: SceneScriptBridge?
    private var preparesScriptEffects = false
    private var sounds: [SceneSoundLayer] = []
    private var soundBytes = 0
    private var soundOutputEnabled = false
    private let musicOwner = UUID()
    private var lastAudioSource = ""
    private var timelines: SceneTimelines
    private var nativeCreationMotions: [Int: NativeCreationMotion] = [:]
    private var nativeCreationPoses: [Int: NativeCreationPose] = [:]
    private var editorSeekingAllowed = false
    private var editorEndpoint = false
    private var currentSceneTime: Double = 0
    private var audioSpectrum = NativeAudioSpectrum.silence
    private var cursorTracking: NSTrackingArea?
    private var globalMouseMonitor: Any?
    private var previousCursor: NSPoint?
    private var cursorPressTargets: [String] = []
    private var loggedMouseButtons = 0
    private var previewCursor: NSPoint?
    private var previewLeftDown = false
    private var previewPointerCounts = [0, 0, 0]
    private var pointerDownFrames = 0
    private var pointerInputEnabled = false
    private var pointerLastScreen = SIMD2<Double>.zero
    private var pointerRuntimeDiagnostic: String {
        "脚本指针运行快照：预览 down/up/drag=\(previewPointerCounts)，按下状态渲染帧=\(pointerDownFrames)，当前可输入=\(pointerInputEnabled)，屏幕坐标=\(pointerLastScreen)，预览按下=\(previewLeftDown)。"
    }
    private var frameUniforms = SceneFrameUniforms()
    private var lastReportedPointer = SIMD2<Float>(repeating: -2)
    private var lastReportedParallax = SIMD2<Float>(repeating: -2)
    private var lastPointerReportTime = -Double.infinity
    private var pointerReportCount = 0
    private var frameCameraInputs = NativeParallaxCamera.ShaderInputs.identity
    private var parallaxViewDiagnostic: String?
    private var cameraShakeOffset = SIMD3<Float>.zero
    private var cameraShakeReported = false
    private var lastCameraShakeReportTime = -Double.infinity
    private var cameraShakeReportCount = 0
    private var perspectiveParameters = NativePerspectiveProjection()
    private var orthographicParameters = NativeOrthographicProjection()
    private var legacyCamera: NativeLegacyCamera
    private var sceneCameras: NativeSceneCameras
    private var activeCameraPose: NativeCameraPose {
        if let active = sceneCameras.active { return active.pose }
        if legacyCamera.hasPaths { return legacyCamera.pose }
        return scripts?.cameraPose ?? legacyCamera.pose
    }
    private var cameraPoseSource: String {
        sceneCameras.active != nil ? "Camera 对象" : legacyCamera.hasPaths ? "旧版相机路径" : "静态相机"
    }
    private var projectionSnapshot: (time: Double, aspect: Float, scale: SIMD2<Float>, fallback: Bool)?
    private var orthographicSnapshot: (time: Double, aspect: Float, zoom: Float, scale: SIMD2<Float>, fallback: Bool)?
    private var particleProjectionSnapshot: NativeOrthographicProjection.ParticleFrame?
    private var projectionRuntimeDiagnostic: String? {
        guard let snapshot = projectionSnapshot else { return nil }
        let source = sceneCameras.active == nil ? "general" : "活动 Camera 对象"
        return "三维相机运行快照：场景时间 \(String(format: "%.2f", snapshot.time)) 秒；fov=\(perspectiveParameters.fovDegrees)°，nearz=\(perspectiveParameters.near)，farz=\(perspectiveParameters.far)，aspect=\(snapshot.aspect)；投影缩放=(\(snapshot.scale.x), \(snapshot.scale.y))，输出矩阵回退=\(snapshot.fallback)。fov 来源=\(source)；裁剪距离来自 general；zoom 不参与三维投影。"
    }
    private var orthographicRuntimeDiagnostic: String? {
        guard let snapshot = orthographicSnapshot else { return nil }
        let perspectiveGroups = draws.filter { $0.particles?.usesPerspectiveProjection == true || $0.particleChildren?.usesPerspectiveProjection == true }.count
        let particleText: String
        if let frame = particleProjectionSnapshot {
            particleText = "临时相机距离=\(frame.distance)，near=\(frame.near)，far=\(frame.far)，透视缩放=(\(frame.matrix.columns.0.x), \(frame.matrix.columns.1.y))"
        } else { particleText = "临时透视矩阵无效；启用该标志的图层无法绘制" }
        return "二维相机运行快照：场景时间 \(String(format: "%.2f", snapshot.time)) 秒；general.zoom=\(orthographicParameters.zoom)，活动相机 zoom=\(activeCameraPose.zoom)，实际缩放=\(snapshot.zoom)，aspect=\(snapshot.aspect)，正交缩放=(\(snapshot.scale.x), \(snapshot.scale.y))，输出矩阵回退=\(snapshot.fallback)；perspectiveoverridefov=\(orthographicParameters.perspectiveFOVDegrees)°，声明透视的绘制组=\(perspectiveGroups)，\(particleText)。参考库额外缩放因子尚未适配。"
    }

    convenience init?(project: WallpaperProject, allowsEditorSeeking: Bool = false, videos: SceneVideoLibrary = SceneVideoLibrary(), snapshot: NativeSceneLifecycle.Snapshot? = nil, creationQueue: DispatchQueue? = nil, postProcessing: NativePostProcessingQuality = .ultra, textureResolution: NativeTextureResolutionRequest = .init()) throws {
        try self.init(project: project, allowsEditorSeeking: allowsEditorSeeking, videos: videos, snapshot: snapshot,
            preparedCreation: nil, previous: nil, preparationQueue: creationQueue, postProcessing: postProcessing, textureResolution: textureResolution)
    }

    private init?(project: WallpaperProject, allowsEditorSeeking: Bool, videos: SceneVideoLibrary,
                  snapshot: NativeSceneLifecycle.Snapshot?, preparedCreation: NativePreparedOpenGLSceneCreation?,
                  previous: SceneWallpaperView?, preparationQueue: DispatchQueue? = nil,
                  postProcessing: NativePostProcessingQuality = .ultra, textureResolution: NativeTextureResolutionRequest = .init(), preparingQuality: Bool = false) throws {
        antialiasingQuality = previous?.antialiasingQuality ?? .none
        postProcessingQuality = postProcessing; textureResolutionRequest = textureResolution
        projectURL = project.projectURL
        creationQueue = preparationQueue ?? previous?.creationQueue ?? DispatchQueue(label: "io.wallpaper-engine-native.opengl-creation")
        preparedModels = preparedCreation?.decoded.models ?? [:]
        preparedTextures = preparedCreation?.decoded.textures ?? [:]
        creationPreparationStatistics = preparedCreation?.decoded.statistics
        videoLibrary = videos
        strictResourcePreparation = snapshot != nil
        let sceneAssets = try preparedCreation?.assets ?? SceneAssets(directory: project.directoryURL)
        assets = sceneAssets
        do { builtinTextures = try NativeBuiltinTextures.activeSnapshot(); builtinTextureError = nil }
        catch { builtinTextures = nil; builtinTextureError = error.localizedDescription }
        if let previous {
            builtinFonts = previous.builtinFonts; builtinFontError = previous.builtinFontError
        } else {
            do { builtinFonts = try NativeBuiltinFonts.activeSnapshot(); builtinFontError = nil }
            catch { builtinFonts = nil; builtinFontError = error.localizedDescription }
        }
        let original = try preparedCreation == nil ? assets.json(project.resourceURL.path.replacingOccurrences(of: project.directoryURL.path + "/", with: "")) : [:]
        authoredFileSignature = try preparedCreation?.authoredFileSignature ?? Data(SHA256.hash(data: JSONSerialization.data(withJSONObject: original, options: [.sortedKeys])))
        let authored = try snapshot?.materializedScene() ?? original
        // The lifecycle budget must not reject a formerly renderable static
        // project. Keep its existing renderer and report the unavailable API.
        let lifecycleError: String?
        do { lifecycleSnapshot = try snapshot ?? NativeSceneLifecycle(scene: authored).snapshot; lifecycleError = nil }
        catch { lifecycleSnapshot = nil; lifecycleError = error.localizedDescription }
        scene = try preparedCreation?.scene ?? NativeModelMaterials.expand(authored, assets: assets)
        guard let objects = scene["objects"] as? [[String: Any]], objects.count <= 5000 else { throw SceneError.invalid("scene.json 缺少对象列表或超过 5000 个对象。") }
        initialSceneLayerOrder = try lifecycleSnapshot.map { try NativeSceneLayerOrder(objects: objects, activeSlots: $0.activeSlots, order: $0.orderedIDs) }
        hierarchy = SceneHierarchy(objects: objects)
        timelines = SceneTimelines(scene: scene)
        if let rawFormat = (scene["general"] as? [String: Any])?["nativeEditorFormat"] {
            guard let editorFormat = NativeAnimationJSON.integer(rawFormat), [2, 3, 4].contains(editorFormat) else {
                throw SceneError.invalid("此原生作品的动画格式不受当前版本支持。")
            }
            guard objects.count <= 64 else { throw SceneError.invalid("原生作品超过 64 个图层。") }
            var keyCount = 0
            for (index, object) in objects.enumerated() {
                guard let raw = object["nativeEditorMotion"] as? [String: Any] else { throw SceneError.invalid("原生作品缺少图层动画数据。") }
                let data = try JSONSerialization.data(withJSONObject: raw)
                guard data.count <= 64 * 1024 else { throw SceneError.invalid("图层动画数据过大。") }
                let motion = try JSONDecoder().decode(NativeCreationMotion.self, from: data).validated()
                guard editorFormat >= 4 || motion.format < 3 else { throw SceneError.invalid("贝塞尔曲线需要原生作品格式 4。") }
                keyCount += motion.scalarKeyframeCount
                guard keyCount <= 6144 else { throw SceneError.invalid("原生作品超过 6144 个属性关键帧。") }
                nativeCreationMotions[index] = motion
            }
            editorSeekingAllowed = allowsEditorSeeking
        }
        legacyCamera = NativeLegacyCamera(camera: scene["camera"] as? [String: Any] ?? [:],
            orthographic: (scene["general"] as? [String: Any])?["orthogonalprojection"] is [String: Any],
            loadJSON: { try sceneAssets.json($0) })
        sceneCameras = try NativeSceneCameras(objects: objects,
            orthographic: (scene["general"] as? [String: Any])?["orthogonalprojection"] is [String: Any],
            loadJSON: { try sceneAssets.json($0) })
        properties = project.userProperties
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion4_1Core),
            UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAlphaSize), 8,
            UInt32(NSOpenGLPFADepthSize), 24, 0
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else { throw SceneError.invalid("此 Mac 无法创建 OpenGL 4.1 场景上下文。") }
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), pixelFormat: format)
        wantsBestResolutionOpenGLSurface = true
        guard let context = previous?.resourceContext ?? openGLContext else { throw SceneError.invalid("OpenGL 上下文不可用。") }
        resourceContext = context
        let previousContext = NSOpenGLContext.current
        context.makeCurrentContext()
        defer {
            if preparedCreation != nil || preparingQuality {
                if let previousContext { previousContext.makeCurrentContext() }
                else { NSOpenGLContext.clearCurrentContext() }
            }
        }
        var interval: GLint = 1
        context.setValues(&interval, for: .swapInterval)
        if let previous {
            screenQuad = previous.screenQuad; imageQuad = previous.imageQuad
            imageCopyShader = previous.imageCopyShader; presentShader = previous.presentShader
            creationPreparationStatistics?.reusedCoreResources = true
        } else {
            screenQuad = SceneGeometry.quad(framebufferUV: true)
            imageQuad = SceneGeometry.quad()
            imageCopyShader = try SceneShader(vertex: Self.nativeImageVertex, fragment: Self.nativeImageFragment, label: "native image result")
        }
        if let lifecycleError { note("动态图层操作未启用，保留原有场景加载：" + lifecycleError) }
        if let builtinTextureError { note("内置素材库未加载：\(builtinTextureError)") }
        if let builtinFontError { note("内置字体库未加载：\(builtinFontError)") }
        if let builtinTextures {
            fputs("Scene builtin texture catalog: \(builtinTextures.manifest.archiveSHA256), \(builtinTextures.manifest.entries.count) entries, immutable snapshot\n", stderr)
        }
        for message in hierarchy.diagnostics { note(message) }
        for message in legacyCamera.diagnostics { note(message) }
        for message in sceneCameras.diagnostics { note(message) }
        if hierarchy.parents.contains(where: { $0 != nil }) {
            fputs("Scene hierarchy: \(hierarchy.parents.count) objects, \(hierarchy.parents.compactMap { $0 }.count) parent links, \(hierarchy.invalid.count) invalid objects\n", stderr)
        }
        // A quality replacement retains the existing effect interface. Do
        // not add author-hidden effects that the live static scene omitted.
        preparesScriptEffects = preparingQuality
            ? (previous?.preparesScriptEffects ?? SceneScriptBridge.hasScripts(scene))
            : (preparedCreation != nil || SceneScriptBridge.hasScripts(scene))
        if let previous {
            if preparingQuality {
                // Reuse pixels only when their authored mip selection agrees.
                // Video and live media textures keep their decoders and content.
                let sameMip = textureResolutionRequest.preferredMip(canvas: textureResolutionCanvas) == previous.textureResolutionRequest.preferredMip(canvas: previous.textureResolutionCanvas)
                textures = previous.textures.filter { sameMip || $0.value.videoKey != nil || ["$mediaThumbnail", "$mediaPreviousThumbnail"].contains($0.key) }
                textureReservations = previous.textureReservations.filter { textures[$0.key] != nil }
                textureBytes = textureReservations.values.reduce(0, +)
                videoRuntimes = previous.videoRuntimes
            } else { seedCreationResources(from: previous) }
        }
        try buildScene()
        for runtime in videoRuntimes.values where preparedCreation == nil && !preparingQuality {
            runtime.setDidDecode { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, sceneClock.isPaused || renderedFrames == 0 else { return }
                    needsDisplay = true
                }
            }
        }
        if previous == nil { try buildPostprocess() }
        updateProjectionParameters()
        let metadata = try scriptResourceMetadata()
        let timelineStore = timelines
        modelScriptStore.resolve = { [weak self] in self?.propertyValue($0) }
        let retirement: SceneScriptBridge.RetirementHandler? = lifecycleSnapshot == nil ? nil : { [weak self] ids, order in
            guard let self else { throw SceneError.invalid("图层所属 OpenGL 播放窗口已关闭。") }
            return try prepareRetirement(ids, order: order)
        }
        if preparedCreation == nil && !preparingQuality {
        scripts = try SceneScriptBridge(scene: scene, properties: properties, camera: legacyCamera.staticPose, propertyTypes: Dictionary(uniqueKeysWithValues: project.propertyDefinitions.map { ($0.key, $0.type) }), textureAnimations: metadata.animations, videoTextures: metadata.videos, sounds: soundStates, timelines: timelines.scriptMetadata, timelineValues: timelines.scriptInput(at: 0, resolveBase: propertyValue),
            timelineStateProvider: { timelineStore.scriptStates },
            timelineCommandHandler: { timelineStore.applyCommands($0) }, projectURL: project.projectURL, effectVisibilityBases: metadata.visibility, materials: metadata.materials, timelineEvents: timelineStore, modelAnimations: modelScriptStore, publication: .renderFrame,
            activeLayerSlots: lifecycleSnapshot?.activeSlots, initialLayerOrder: lifecycleSnapshot?.orderedIDs,
            initialLayerConfigurations: try lifecycleSnapshot?.initialConfigurations(), retirementHandler: retirement, resourceAssets: assets, resourceFonts: builtinFonts, creationHandler: lifecycleSnapshot == nil ? nil : creationHandler)
        }
        let diagnosticBindings = try scripts?.bindingPaths ?? (preparedCreation == nil && !preparingQuality ? [] : preparedScriptInventory(at: 0).keys.sorted())
        if !diagnosticBindings.isEmpty {
            note("SceneScript：\(diagnosticBindings.count) 段脚本使用系统 JavaScriptCore 独立进程；已实现接口以运行诊断为准。")
            let allPasses = draws.flatMap { $0.passes + ($0.imageLayer?.stages ?? []) }
            var supported = Set(allPasses.flatMap { Array($0.scriptUniforms.values) + Array($0.materialUniforms.values) } + allPasses.compactMap { $0.visibilityPath })
            supported.formUnion(sceneBloomProperties.map { "/general/" + $0 })
            supported.formUnion(sceneParallaxProperties.map { "/general/" + $0 })
            supported.formUnion(sceneShakeProperties.map { "/general/" + $0 })
            supported.formUnion(sceneLightingProperties.map { "/general/" + $0 })
            supported.formUnion((isOrthogonalScene ? sceneOrthographicProperties : sceneProjectionProperties).map { "/general/" + $0 })
            for (index, player) in modelAnimations {
                for layer in player.source.layers.indices {
                    supported.formUnion(NativeModelProperties.keys.map { "/objects/\(index)/animationlayers/\(layer)/" + $0 })
                }
            }
            for (index, object) in (scene["objects"] as? [[String: Any]] ?? []).enumerated() {
                for property in sceneProperties(for: object) { supported.insert("/objects/\(index)/\(property)") }
                if object["particle"] is String {
                    for key in SceneParticles.liveInstanceKeys { supported.insert("/objects/\(index)/instanceoverride/\(key)") }
                }
            }
            for path in diagnosticBindings where !supported.contains(path) { note("SceneScript 输出尚未接入渲染属性：\(path)") }
            note("SceneScript 鼠标命中当前按 2D solid 图层矩形处理；3D 射线命中、逐像素透明区域与完整事件传播仍待实现。")
        }
        note("音频接口接收壁纸自身音乐的本机频谱；系统声音需在“声音响应”中手动开启并授权。频段、强度和播放位置对齐仍为兼容实现，尚未与 Windows 原版校准。")
        let allPasses = draws.flatMap { $0.passes + ($0.imageLayer?.stages ?? []) }
        var timelineTargets = Set(allPasses.flatMap { Array($0.timelineUniforms.values) })
        timelineTargets.formUnion(sceneBloomProperties.map { "/general/" + $0 })
        timelineTargets.formUnion(sceneParallaxProperties.map { "/general/" + $0 })
        timelineTargets.formUnion(sceneShakeProperties.map { "/general/" + $0 })
        timelineTargets.formUnion(sceneLightingProperties.map { "/general/" + $0 })
        timelineTargets.formUnion((isOrthogonalScene ? sceneOrthographicProperties : sceneProjectionProperties).map { "/general/" + $0 })
        for (index, player) in modelAnimations {
            for layer in player.source.layers.indices {
                timelineTargets.formUnion(NativeModelProperties.numbers.map { "/objects/\(index)/animationlayers/\(layer)/" + $0 })
            }
        }
        for draw in draws { if let index = draw.objectIndex {
            for key in sceneObjectProperties { timelineTargets.insert("/objects/\(index)/\(key)") }
            if draw.particles != nil || draw.particleChildren != nil {
                for key in SceneParticles.liveInstanceKeys { timelineTargets.insert("/objects/\(index)/instanceoverride/\(key)") }
            }
        } }
        for sound in sounds { timelineTargets.insert("/objects/\(sound.objectIndex)/volume") }
        for (index, object) in objects.enumerated() where object["light"] is String {
            for key in sceneProperties(for: object) { timelineTargets.insert("/objects/\(index)/\(key)") }
        }
        for index in sceneCameras.indices {
            for key in sceneProperties(for: objects[index]) { timelineTargets.insert("/objects/\(index)/\(key)") }
            var parent = hierarchy.parents[index], visited = Set<Int>()
            while let value = parent, visited.insert(value).inserted {
                for key in ["origin", "angles", "scale", "visible"] { timelineTargets.insert("/objects/\(value)/\(key)") }
                parent = hierarchy.parents[value]
            }
        }
        for message in timelines.diagnostics { note("时间轴：" + message) }
        for path in timelines.paths where !timelineTargets.contains(path) { note("时间轴尚未接入渲染属性：\(path)") }
        if !timelines.paths.isEmpty { fputs("Scene timelines: \(timelines.paths.count) parsed, \(timelines.playingCount) autoplay, \(timelines.paths.filter { timelineTargets.contains($0) }.count) rendering targets\n", stderr) }
        let renderer = glGetString(GLenum(GL_RENDERER)).map { String(cString: $0) } ?? "unknown"
        fputs("Scene loaded: \(project.title), \(draws.count) draw groups, GPU \(renderer)\n", stderr)
        fputs("Scene sound layers loaded: \(sounds.count), \(soundBytes) compressed resource bytes\n", stderr)
        fputs("Scene allocation: \(textureBytes) base texture bytes, \(layerTargetPixels)/\(layerTargetPixelLimit) effect target pixels (working \(sceneHDR ? "RGBA16F" : "RGBA8"); named buffers retain their declared precision), \(imageTargetPool.count) shared dimensions\n", stderr)
        for message in diagnostics { fputs("Scene compatibility: \(message)\n", stderr) }
        scripts?.initializationDidResolve = { [weak self] in self?.needsDisplay = true }
        // Uploads now own the required GPU data. Do not retain a second CPU
        // copy for the lifetime of the playing scene or a paused transaction.
        preparedModels.removeAll(); preparedTextures.removeAll()
    }

    private func scriptResourceMetadata() throws -> (animations: [String: [String: Any]], videos: [String: [String: Any]], visibility: [String: Bool], materials: [String: [SceneScriptMaterial]]) {
        let objects = scene["objects"] as! [[String: Any]]
        var videoTextures: [String: [String: Any]] = [:]
        for draw in draws {
            if let index = draw.objectIndex, draw.particles == nil,
               let texture = ((draw.imageLayer?.stages ?? []) + draw.passes).first?.textures[0],
               let key = texture.videoKey, let video = videoRuntimes[key] {
                videoTextures[SceneScriptBridge.objectID(objects[index], index: index)] = video.asset.metadata(key: key)
            }
        }
        var textureAnimations: [String: [String: Any]] = [:]
        for draw in draws {
            if let index = draw.objectIndex, draw.particles == nil,
               let texture = ((draw.imageLayer?.stages ?? []) + draw.passes).first?.textures[0],
               let animation = texture.animation {
                textureAnimations[SceneScriptBridge.objectID(objects[index], index: index)] = animation.scriptMetadata
            }
        }
        let visibilityPasses = draws.flatMap { $0.passes + ($0.imageLayer?.stages ?? []) }
        var effectVisibilityBases: [String: Bool] = [:]
        var scriptMaterials: [String: [SceneScriptMaterial]] = [:]
        for pass in visibilityPasses {
            if let path = pass.visibilityPath {
                effectVisibilityBases[path] = SceneValues.visible(propertyValue(pass.visibility))
                if let material = pass.materialObject { scriptMaterials[path, default: []].append(material) }
            } else if let material = pass.materialObject {
                let owner = material.path.components(separatedBy: "/passes/")[0]
                if NativeModelMaterials.isOwner(owner) { scriptMaterials[owner, default: []].append(material) }
            }
        }
        scriptMaterials = try scriptMaterials.mapValues { try SceneScriptMaterial.merge($0) }
        return (textureAnimations, videoTextures, effectVisibilityBases, scriptMaterials)
    }

    private func preparedScriptInventory(at time: Double) throws -> SceneScriptInventory {
        let metadata = try scriptResourceMetadata()
        return try SceneScriptInventory(scene: scene, properties: properties,
            textureAnimations: metadata.animations, videoTextures: metadata.videos, sounds: soundStates,
            timelines: timelines.scriptMetadata, timelineValues: timelines.scriptInput(at: time, resolveBase: propertyValue),
            effectVisibilityBases: metadata.visibility, materials: metadata.materials,
            activeLayerSlots: lifecycleSnapshot?.activeSlots, initialLayerOrder: lifecycleSnapshot?.orderedIDs,
            initialLayerConfigurations: try lifecycleSnapshot?.initialConfigurations())
    }

    private func withResourceContext<T>(_ operation: () throws -> T) rethrows -> T {
        let previous = NSOpenGLContext.current
        resourceContext?.makeCurrentContext()
        defer {
            if let previous { previous.makeCurrentContext() }
            else { NSOpenGLContext.clearCurrentContext() }
        }
        return try operation()
    }

    /// A staged view never presents or creates a second script process. Its
    /// GL resources belong to the original view's exact context, including VAOs
    /// and framebuffers, which cannot be moved between shared contexts.
    private var creationHandler: SceneScriptBridge.CreationHandler {
        { [weak self] configuration, time in
            guard let self else { throw SceneError.invalid("创建图层的 OpenGL 播放实例已关闭。") }
            return try await prepareCreation(configuration, at: time, previous: self)
        }
    }

    private func prepareCreation(_ configuration: Data, at time: Double, previous: SceneWallpaperView) async throws -> SceneScriptPreparedCreation {
        guard let snapshot = previous.lifecycleSnapshot, let revision = lifecycleSnapshot?.revision else {
            throw SceneError.invalid("当前 OpenGL 场景没有可扩展的资源清单。")
        }
        let url = projectURL
        let values = try JSONSerialization.data(withJSONObject: previous.properties, options: [.sortedKeys])
        let builtins = builtinTextures
        let supportsBC3 = withResourceContext { compressedTextureFormats().contains(0x83F3) }
        let existingModels = Set(previous.modelResources.keys)
        let existingTextures = Set(previous.textures.keys.map { ($0.hasSuffix(".tex") ? $0 : "materials/\($0).tex").lowercased() })
        let previousAssets = previous.assets
        let textureMip = previous.textureResolutionRequest.preferredMip(canvas: previous.textureResolutionCanvas)
        let successfulModels = Set(previous.modelResources.compactMap { key, result in
            if case .success = result { return key }; return nil
        })
        let retainedModelPaths = previous.failedLayerCount == 0 && snapshot.activeSlots.allSatisfy({ previous.objectAllocations[$0] != nil })
            ? NativeModelMaterials.retainedPaths(scene: previous.scene, activeSlots: snapshot.activeSlots, eligible: successfulModels) : [:]
        let prepared = try await NativeResourceWork.run(on: creationQueue) { cancellation in
            try NativePreparedOpenGLSceneCreation(plan: NativeSceneCreationPlan(projectURL: url,
                properties: values, snapshot: snapshot, configuration: configuration), builtins: builtins,
                supportsBC3: supportsBC3, existingModels: existingModels, existingTextures: existingTextures,
                previousAssets: previousAssets, retainedModelPaths: retainedModelPaths,
                cancellation: cancellation, preferredMip: textureMip)
        }
        let videos = try await SceneVideoLibrary.prepare(project: prepared.plan.project, snapshot: prepared.plan.snapshot,
            preparedAssets: prepared.assets, expandedSceneJSON: prepared.expandedSceneJSON)
        try Task.checkCancellation()
        guard lifecycleSnapshot?.revision == revision, prepared.authoredFileSignature == authoredFileSignature else {
            throw SceneError.invalid("场景在 OpenGL 创建准备期间改变，保留现有画面。")
        }
        var project = prepared.plan.project; project.userProperties = prepared.plan.properties
        let constructionStarted = ProcessInfo.processInfo.systemUptime
        guard let candidate = try SceneWallpaperView(project: project, allowsEditorSeeking: false, videos: videos,
            snapshot: prepared.plan.snapshot, preparedCreation: prepared, previous: previous, postProcessing: previous.postProcessingQuality, textureResolution: previous.textureResolutionRequest) else {
            throw SceneError.invalid("OpenGL 图层资源准备失败。")
        }
        candidate.creationPreparationStatistics?.constructionSeconds = ProcessInfo.processInfo.systemUptime - constructionStarted
        try candidate.withResourceContext {
            try candidate.preserveCreationRuntime(from: previous, slots: snapshot.activeSlots, at: time)
        }
        let inventory = try candidate.preparedScriptInventory(at: time)
        return SceneScriptPreparedCreation(id: prepared.plan.id, inventory: inventory,
            timelines: candidate.timelines, models: candidate.modelScriptStore,
            next: { [weak self, candidate] configuration, time in
                guard let self else { throw SceneError.invalid("创建图层的 OpenGL 播放实例已关闭。") }
                return try await self.prepareCreation(configuration, at: time, previous: candidate)
            }, prepareCommit: { [weak self, candidate] retired, order in
                guard let self, self.lifecycleSnapshot?.revision == revision else {
                    throw SceneError.invalid("OpenGL 创建结果已过期。")
                }
                return try candidate.withResourceContext {
                    try candidate.preserveCreationRuntime(from: self, slots: self.lifecycleSnapshot!.activeSlots,
                        at: max(self.currentSceneTime, time))
                    let retirement = retired.isEmpty ? nil : try candidate.prepareRetirement(retired, order: order)
                    return { [weak self, candidate] in
                        guard let self else { return }
                        self.withResourceContext {
                            retirement?()
                            self.adoptCreatedScene(candidate)
                        }
                    }
                }
            })
    }

    func prepareAntialiasing(_ quality: NativeAntialiasing) throws -> () -> Void {
        guard quality != antialiasingQuality else { return {} }
        guard scripts?.hasPendingCreation != true else { throw SceneError.invalid("脚本正在准备图层，暂时保留原抗锯齿品质。") }
        let width = targets.first?.width ?? 1280, height = targets.first?.height ?? 720
        let prepared: [NativeOpenGLAntialiasing] = try withResourceContext {
            _ = try NativeAntialiasing.bytes(width: width, height: height, samples: quality.samples, hdr: sceneHDR, depth: true, targets: 2)
            return try quality == .none ? [] : (0..<2).map { _ in try NativeOpenGLAntialiasing(width: width, height: height, hdr: sceneHDR, samples: quality.samples) }
        }
        return { [weak self, prepared] in
            guard let self else { return }
            self.withResourceContext {
                for (index, target) in self.targets.enumerated() { target.multisample = prepared.isEmpty ? nil : prepared[index] }
                self.antialiasingQuality = quality; self.renderConfigurationRevision &+= 1; self.needsDisplay = true
            }
        }
    }

    func prepareTextureResolution(_ quality: NativeTextureResolution, outputSize: CGSize) throws -> () -> Void {
        try prepareGraphicsQuality(postProcessingQuality, textureResolution: .init(quality: quality, outputSize: outputSize))
    }
    func refreshTextureResolutionForOutput(_ size: CGSize) {
        guard textureResolutionQuality == .automatic, textureResolutionRequest.outputSize != size else { return }
        let key = "\(size.width)x\(size.height):\(propertyUpdateRevision)"
        guard key != textureResolutionAttempt else { return }
        do { try prepareTextureResolution(.automatic, outputSize: size)(); textureResolutionFailure = nil }
        catch { textureResolutionAttempt = key; textureResolutionFailure = error.localizedDescription }
    }
    func preparePostProcessingQuality(_ quality: NativePostProcessingQuality) throws -> () -> Void {
        try prepareGraphicsQuality(quality, textureResolution: textureResolutionRequest)
    }
    private func prepareGraphicsQuality(_ quality: NativePostProcessingQuality, textureResolution: NativeTextureResolutionRequest) throws -> () -> Void {
        guard quality != postProcessingQuality || textureResolution != textureResolutionRequest else { return {} }
        let sameMip = textureResolution.preferredMip(canvas: textureResolutionCanvas) == textureResolutionRequest.preferredMip(canvas: textureResolutionCanvas)
        if quality == postProcessingQuality, sameMip, textureResolution.quality == textureResolutionQuality {
            return { [weak self] in self?.textureResolutionRequest = textureResolution }
        }
        guard scripts?.hasPendingCreation != true else {
            throw SceneError.invalid("脚本正在准备图层，暂时保留原后处理和纹理品质。")
        }
        let authoredHDR = (scene["general"] as? [String: Any])?["hdr"] as? Bool == true
        guard quality.usesHDR(authored: authoredHDR) != sceneHDR || !sameMip else {
            return { [weak self] in
                guard let self else { return }
                postProcessingQuality = quality; textureResolutionRequest = textureResolution
                textureResolutionAttempt = nil; textureResolutionFailure = nil
                renderConfigurationRevision &+= 1; needsDisplay = true
            }
        }
        var project = try WallpaperProject.load(from: projectURL); project.userProperties = properties
        guard let candidate = try SceneWallpaperView(project: project, allowsEditorSeeking: editorSeekingAllowed,
            videos: videoLibrary, snapshot: lifecycleSnapshot, preparedCreation: nil, previous: self,
            postProcessing: quality, textureResolution: textureResolution, preparingQuality: true), candidate.authoredFileSignature == authoredFileSignature,
            candidate.failedLayerCount == failedLayerCount, candidate.draws.count == draws.count,
            zip(candidate.draws, draws).allSatisfy({ $0.objectIndex == $1.objectIndex && $0.name == $1.name }) else {
            throw SceneError.invalid("场景在准备画质时改变或包含无法重建的资源，保留原画面。")
        }
        try candidate.withResourceContext {
            let before = try preparedScriptInventory(at: currentSceneTime)
            let after = try candidate.preparedScriptInventory(at: currentSceneTime)
            _ = try after.retainedBindings(from: before, retaining: before.layerIDs)
            guard before.layerIDs == after.layerIDs, before.materialDimensions == after.materialDimensions,
                  before.timelineLimits == after.timelineLimits else {
                throw SceneError.invalid("后处理准备改变了脚本接口，保留原画面。")
            }
            if let target = targets.first { try candidate.prepareFramebuffers(width: target.width, height: target.height) }
        }
        return { [weak self, candidate] in
            guard let self else { return }
            self.withResourceContext { [self] in
                // Keep CPU simulations and script receivers while replacing
                // GPU resources for the new precision or authored mip.
                candidate.timelines = self.timelines; candidate.sceneCameras = self.sceneCameras; candidate.legacyCamera = self.legacyCamera
                candidate.modelAnimations = self.modelAnimations; candidate.modelScriptStore = self.modelScriptStore
                candidate.sounds = self.sounds; candidate.soundBytes = self.soundBytes
                for index in self.draws.indices {
                    candidate.draws[index].particles = self.draws[index].particles
                    candidate.draws[index].particleChildren = self.draws[index].particleChildren
                    candidate.draws[index].puppet = self.draws[index].puppet
                    candidate.draws[index].text = self.draws[index].text
                    if self.draws[index].particles != nil || self.draws[index].particleChildren != nil || self.draws[index].puppet != nil {
                        candidate.draws[index].geometry = self.draws[index].geometry
                    }
                }
                candidate.reflectionsEnabled = self.reflectionsEnabled; candidate.shadowQuality = self.shadowQuality
                candidate.volumetricQuality = self.volumetricQuality; candidate.pointShadows = self.pointShadows
                if candidate.sceneHDR == self.sceneHDR {
                    candidate.sceneHistory = self.sceneHistory; candidate.reflectionHistory = self.reflectionHistory
                    candidate.hdrBloom = self.hdrBloom; candidate.standardBloom = self.standardBloom
                    candidate.pointVolumetrics = self.pointVolumetrics
                }
                self.adoptCreatedScene(candidate)
                self.targets = candidate.targets
                self.renderConfigurationRevision &+= 1
                self.textureResolutionAttempt = nil; self.textureResolutionFailure = nil
                self.shadowAllocationFailed = false; self.volumeAllocationFailed = false
            }
        }
    }

    private func seedCreationResources(from previous: SceneWallpaperView) {
        textures = previous.textures; textureReservations = previous.textureReservations
        textureBytes = textureReservations.values.reduce(0, +)
        videoRuntimes = previous.videoRuntimes
        modelResources = previous.modelResources; modelResourceSizes = previous.modelResourceSizes
        modelBufferBytes = previous.modelBufferBytes; modelAnimationBytes = previous.modelAnimationBytes
        modelShapeCount = previous.modelShapeCount; skeletonResourceCount = previous.skeletonResourceCount
        imageTargetPool = previous.imageTargetPool; layerTargetPixels = previous.layerTargetPixels
        imageBlendShaders = previous.imageBlendShaders; shadowShaders = previous.shadowShaders
        puppetMaskShader = previous.puppetMaskShader; puppetClippedShader = previous.puppetClippedShader
        guard let old = previous.lifecycleSnapshot, let next = lifecycleSnapshot,
              previous.failedLayerCount == 0, next.count == old.count + 1,
              old.order.allSatisfy(next.contains),
              old.activeSlots.allSatisfy({ previous.objectAllocations[$0] != nil }),
              let inserted = next.order.first(where: { !old.contains($0) }) else { return }
        let slots = old.activeSlots, ids = Set(old.orderedIDs)
        incrementalCreationSlots = [inserted.slot]
        creationPreparationStatistics?.retainedObjects = slots.count
        draws = previous.draws
        textPixelCount = draws.compactMap(\.text).reduce(0) { $0 + $1.texture.width * $1.texture.height }
        textLayerCount = draws.filter { $0.text != nil }.count
        textureBytes += textPixelCount * 4
        sounds = previous.sounds.filter { ids.contains($0.objectID) }
        soundBytes = sounds.reduce(0) { $0 + $1.byteCount }
        modelAnimations = previous.modelAnimations.filter { slots.contains($0.key) }
        modelScriptStore.players = previous.modelScriptStore.players.filter { ids.contains($0.key) }
        modelScriptStore.staticModelIDs = previous.modelScriptStore.staticModelIDs.intersection(ids)
        modelScriptStore.inheritProtocol(from: previous.modelScriptStore)
        modelInstanceCount = previous.modelInstanceCount; skinnedModelInstanceCount = previous.skinnedModelInstanceCount
        objectAllocations = previous.objectAllocations.filter { slots.contains($0.key) }
        objectDiagnosticNotes = previous.objectDiagnosticNotes.filter { slots.contains($0.key) }
        let totals = objectAllocations.values.reduce(into: ObjectAllocation()) { $0.add($1) }
        puppetVerticesReserved = totals.puppetVertices; puppetAnimationBytesReserved = totals.puppetAnimationBytes
        puppetMasksReserved = totals.puppetMasks
        for slot in slots.sorted() { for message in objectDiagnosticNotes[slot] ?? [] { note(message) } }
    }

    private func preserveCreationRuntime(from previous: SceneWallpaperView, slots: Set<Int>, at time: Double) throws {
        try timelines.preserveRuntime(from: previous.timelines, retainingSlots: slots, at: time)
        sceneCameras.preserveRuntime(from: previous.sceneCameras, retainingSlots: slots, at: time)
        legacyCamera = previous.legacyCamera
        let retained = previous.draws.filter { $0.objectIndex.map(slots.contains) ?? false }
        draws = retained + draws.filter { $0.objectIndex.map { !slots.contains($0) } ?? true }
        for slot in slots {
            if let player = previous.modelAnimations[slot] { modelAnimations[slot] = player }
        }
        let oldObjects = previous.scene["objects"] as! [[String: Any]]
        let retainedIDs = Set(slots.filter(oldObjects.indices.contains).map { SceneScriptBridge.objectID(oldObjects[$0], index: $0) })
        for id in retainedIDs {
            if let player = previous.modelScriptStore.players[id] { modelScriptStore.players[id] = player }
        }
        modelScriptStore.inheritProtocol(from: previous.modelScriptStore)
        let oldSounds = Dictionary(uniqueKeysWithValues: previous.sounds.map { ($0.objectID, $0) })
        sounds = sounds.map { retainedIDs.contains($0.objectID) ? oldSounds[$0.objectID] ?? $0 : $0 }
        for (key, texture) in previous.textures where textures[key] != nil { textures[key] = texture }
        for (key, video) in previous.videoRuntimes where videoRuntimes[key]?.asset.signature == video.asset.signature {
            videoRuntimes[key] = video
        }
        // A survivor can resize an effect target while this candidate waits
        // for publication. Preserve its latest reusable targets as well as
        // the new targets already constructed for this insertion.
        for (key, current) in previous.imageTargetPool {
            var merged = imageTargetPool[key] ?? []
            var identities = Set(merged.map(ObjectIdentifier.init))
            for target in current where identities.insert(ObjectIdentifier(target)).inserted { merged.append(target) }
            imageTargetPool[key] = merged
        }
        reflectionsEnabled = previous.reflectionsEnabled; shadowQuality = previous.shadowQuality; volumetricQuality = previous.volumetricQuality
        reflectionHistory = previous.reflectionHistory ?? reflectionHistory
        sceneHistory = previous.sceneHistory ?? sceneHistory
        hdrBloom = previous.hdrBloom ?? hdrBloom; standardBloom = previous.standardBloom ?? standardBloom
        pointShadows = previous.pointShadows ?? pointShadows; pointVolumetrics = previous.pointVolumetrics ?? pointVolumetrics
        compositeTargets = previous.compositeTargets
        fullscreenInput = previous.fullscreenInput ?? fullscreenInput
        puppetMaskTarget = previous.puppetMaskTarget ?? puppetMaskTarget
        retireUnusedResources(objects: scene["objects"] as! [[String: Any]], slots: lifecycleSnapshot!.activeSlots)
        guard textureBytes <= 256 * 1024 * 1024, layerTargetPixels <= layerTargetPixelLimit else {
            throw SceneError.invalid("创建后保留的 OpenGL 资源超过场景预算。")
        }
    }

    private func adoptCreatedScene(_ candidate: SceneWallpaperView) {
        antialiasingQuality = candidate.antialiasingQuality
        postProcessingQuality = candidate.postProcessingQuality
        textureResolutionRequest = candidate.textureResolutionRequest
        scene = candidate.scene; lifecycleSnapshot = candidate.lifecycleSnapshot
        diagnosticNotes = candidate.diagnosticNotes
        objectAllocations = candidate.objectAllocations; objectDiagnosticNotes = candidate.objectDiagnosticNotes
        puppetVerticesReserved = candidate.puppetVerticesReserved; puppetAnimationBytesReserved = candidate.puppetAnimationBytesReserved
        puppetMasksReserved = candidate.puppetMasksReserved
        creationPreparationStatistics = candidate.creationPreparationStatistics
        assets = candidate.assets; hierarchy = candidate.hierarchy; initialSceneLayerOrder = candidate.initialSceneLayerOrder
        draws = candidate.draws; timelines = candidate.timelines; sceneCameras = candidate.sceneCameras
        modelAnimations = candidate.modelAnimations; modelScriptStore = candidate.modelScriptStore
        modelScriptStore.resolve = { [weak self] in self?.propertyValue($0) }
        modelResources = candidate.modelResources; modelResourceSizes = candidate.modelResourceSizes
        modelBufferBytes = candidate.modelBufferBytes; modelAnimationBytes = candidate.modelAnimationBytes
        modelShapeCount = candidate.modelShapeCount; skeletonResourceCount = candidate.skeletonResourceCount
        modelInstanceCount = candidate.modelInstanceCount; skinnedModelInstanceCount = candidate.skinnedModelInstanceCount
        textures = candidate.textures; textureReservations = candidate.textureReservations; textureBytes = candidate.textureBytes
        textPixelCount = candidate.textPixelCount; textLayerCount = candidate.textLayerCount
        videoLibrary = candidate.videoLibrary; videoRuntimes = candidate.videoRuntimes
        for runtime in videoRuntimes.values { runtime.setAudioOutputEnabled(soundOutputEnabled) }
        sounds = candidate.sounds; soundBytes = candidate.soundBytes
        imageTargetPool = candidate.imageTargetPool; layerTargetPixels = candidate.layerTargetPixels
        imageBlendShaders = candidate.imageBlendShaders; shadowShaders = candidate.shadowShaders
        compositeOrder = candidate.compositeOrder; compositeTargets = candidate.compositeTargets; compositeReady.removeAll()
        fullscreenInput = candidate.fullscreenInput; puppetMaskTarget = candidate.puppetMaskTarget
        puppetMaskShader = candidate.puppetMaskShader; puppetClippedShader = candidate.puppetClippedShader
        reflectionHistory = candidate.reflectionHistory; sceneHistory = candidate.sceneHistory
        hdrBloom = candidate.hdrBloom; standardBloom = candidate.standardBloom
        pointShadows = candidate.pointShadows; pointVolumetrics = candidate.pointVolumetrics
        nativeCreationMotions = candidate.nativeCreationMotions
        nativeCreationPoses = nativeCreationPoses.filter { lifecycleSnapshot!.activeSlots.contains($0.key) }
        previousCursor = nil; cursorPressTargets.removeAll(); failedLayerCount = candidate.failedLayerCount
        for runtime in videoRuntimes.values {
            runtime.setDidDecode { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, sceneClock.isPaused || renderedFrames == 0 else { return }
                    needsDisplay = true
                }
            }
        }
        refreshSounds(); needsDisplay = true
    }

    required init?(coder: NSCoder) { nil }
    override var isOpaque: Bool { true }

    /// The helper has finished its callbacks, but its entire reply is still
    /// behind the frame publication barrier. Prepare only CPU membership here.
    private func prepareRetirement(_ ids: Set<String>, order: [String]) throws -> () -> Void {
        guard let context = resourceContext, let lifecycleSnapshot else { throw SceneError.invalid("OpenGL 场景上下文或生命周期不可用。") }
        let handles = ids.compactMap { lifecycleSnapshot.handle(id: $0) }
        guard handles.count == ids.count else { throw SceneError.invalid("待删除图层与活动 OpenGL 场景不一致。") }
        let graph = NativeSceneLifecycle(snapshot: lifecycleSnapshot)
        let next = try graph.prepare(retiring: handles, order: order).snapshot
        let nextScene = try next.applyingMembership(to: scene)
        let objects = nextScene["objects"] as! [[String: Any]]
        let nextOrder = try NativeSceneLayerOrder(objects: objects, activeSlots: next.activeSlots, order: order)
        let nextHierarchy = SceneHierarchy(objects: objects)
        let nextDraws = draws.filter { $0.objectIndex.map(next.activeSlots.contains) ?? true }
        return { [weak self] in
            guard let self else { return }
            // A load reply may arrive while another window's GL context is
            // current. Every released GL object belongs to this exact context.
            let previous = NSOpenGLContext.current
            context.makeCurrentContext()
            defer {
                if let previous { previous.makeCurrentContext() }
                else { NSOpenGLContext.clearCurrentContext() }
            }
            scene = nextScene; self.lifecycleSnapshot = next; hierarchy = nextHierarchy
            initialSceneLayerOrder = nextOrder; draws = nextDraws
            objectAllocations = objectAllocations.filter { next.activeSlots.contains($0.key) }
            objectDiagnosticNotes = objectDiagnosticNotes.filter { next.activeSlots.contains($0.key) }
            let totals = objectAllocations.values.reduce(into: ObjectAllocation()) { $0.add($1) }
            puppetVerticesReserved = totals.puppetVertices; puppetAnimationBytesReserved = totals.puppetAnimationBytes
            puppetMasksReserved = totals.puppetMasks
            timelines.retire(retainingSlots: next.activeSlots)
            sceneCameras.retire(retainingSlots: next.activeSlots)
            modelScriptStore.retire(ids)
            modelAnimations = modelAnimations.filter { next.activeSlots.contains($0.key) }
            for sound in sounds where ids.contains(sound.objectID) { sound.suspend() }
            sounds.removeAll { ids.contains($0.objectID) }
            soundBytes = sounds.reduce(0) { $0 + $1.byteCount }
            if soundOutputEnabled { SceneMusicSpectrum.shared.update(owner: musicOwner, inputs: sounds.compactMap { $0.musicInput }) }
            nativeCreationMotions = nativeCreationMotions.filter { next.activeSlots.contains($0.key) }
            nativeCreationPoses = nativeCreationPoses.filter { next.activeSlots.contains($0.key) }
            retireUnusedResources(objects: objects, slots: next.activeSlots)
            previousCursor = nil; cursorPressTargets.removeAll()
            needsDisplay = true
        }
    }

    /// Draw groups retain their actual resource objects. Prune caches by those
    /// identities, including hidden effect inputs and child-particle passes.
    /// Survivor players, decoders, particles and GPU objects are never rebuilt.
    private func retireUnusedResources(objects: [[String: Any]], slots: Set<Int>) {
        let passes = draws.flatMap { draw -> [ScenePass] in
            draw.passes + (draw.imageLayer?.stages ?? []) + [draw.imageLayer?.copyPass,
                draw.puppetClip?.maskPass, draw.puppetClip?.clippedPass].compactMap { $0 }
        }
        let usedTextures = Set((passes.flatMap { $0.textures.values } + draws.flatMap { $0.puppetClip?.textures ?? [] }).map(ObjectIdentifier.init))
        textures = textures.filter { usedTextures.contains(ObjectIdentifier($0.value)) }
        textureReservations = textureReservations.filter { textures[$0.key] != nil }
        let videoKeys = Set(textures.values.compactMap(\.videoKey))
        for (key, runtime) in videoRuntimes where !videoKeys.contains(key) {
            runtime.setAudioOutputEnabled(false)
        }
        videoRuntimes = videoRuntimes.filter { videoKeys.contains($0.key) }
        textPixelCount = draws.compactMap(\.text).reduce(0) { $0 + $1.texture.width * $1.texture.height }
        textLayerCount = draws.filter { $0.text != nil }.count
        textureBytes = textureReservations.values.reduce(0, +) + textPixelCount * 4
        let modelPaths = Set(slots.compactMap { (objects[$0]["model"] as? String)?.lowercased() })
        modelResources = modelResources.filter { modelPaths.contains($0.key) }
        modelResourceSizes = modelResourceSizes.filter { modelPaths.contains($0.key) }
        modelBufferBytes = modelResourceSizes.values.reduce(0) { $0 + $1.geometry }
        modelAnimationBytes = modelResourceSizes.values.reduce(0) { $0 + $1.animation }
        modelShapeCount = modelResourceSizes.values.reduce(0) { $0 + $1.shapes }
        skeletonResourceCount = modelResourceSizes.values.reduce(0) { $0 + $1.skeletons }
        modelInstanceCount = slots.filter { objects[$0]["model"] != nil }.count
        skinnedModelInstanceCount = Set(draws.filter { $0.skeleton != nil }.compactMap(\.objectIndex)).count
        let boneCounts = Set(draws.compactMap { $0.skeleton?.bones.count })
        shadowShaders = shadowShaders.filter { boneCounts.contains($0.key) }
        let blendModes = Set(draws.compactMap { $0.imageLayer?.colorBlendMode })
        imageBlendShaders = imageBlendShaders.filter { blendModes.contains($0.key) }
        let ownedTargets = draws.flatMap { ($0.imageLayer?.targets ?? []) + Array($0.imageLayer?.namedTargets.values ?? [:].values) }
        let targetIDs = Set(ownedTargets.map(ObjectIdentifier.init))
        imageTargetPool = imageTargetPool.mapValues { $0.filter { targetIDs.contains(ObjectIdentifier($0)) } }.filter { !$0.value.isEmpty }
        compositeOrder.removeAll(); configureLayerComposites(objects: objects)
        let compositeIDs = Set(compositeOrder.map(\.id))
        compositeTargets = compositeTargets.filter { compositeIDs.contains($0.key) }
        compositeReady.removeAll(); compositeRuntimeDiagnostic = nil
        if !draws.contains(where: { $0.topLeftFullscreen }) { fullscreenInput = nil }
        if !draws.contains(where: { $0.puppetClip != nil }) { puppetMaskTarget = nil; puppetMaskShader = nil; puppetClippedShader = nil }
        if reflectionPassCount == 0 { reflectionHistory = nil }
        if modelInstanceCount == 0 { pointShadows = nil; pointVolumetrics = nil; modelRuntimeDiagnostic = nil }
        var counted = Set<ObjectIdentifier>()
        layerTargetPixels = (ownedTargets + Array(compositeTargets.values) + [puppetMaskTarget].compactMap { $0 }).reduce(0) {
            $0 + (counted.insert(ObjectIdentifier($1)).inserted ? $1.width * $1.height : 0)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sceneClock.setAttached(window != nil && presentationArmed, at: ProcessInfo.processInfo.systemUptime)
        if window != nil && presentationArmed && !sceneClock.isPaused { startTimer(); installMouseMonitor() }
        else {
            timer?.invalidate(); timer = nil
            sounds.forEach { $0.suspend() }
            // A view can detach during display/window reconfiguration without
            // going through the controller's ordinary pause/dispose path.
            // Audio must not survive that detached presentation.
            for runtime in videoRuntimes.values { runtime.suspendAudio() }
            SceneMusicSpectrum.shared.clear(owner: musicOwner)
        }
        if window == nil, let monitor = globalMouseMonitor { NSEvent.removeMonitor(monitor); globalMouseMonitor = nil }
    }
    func beginPresentation() {
        guard !presentationArmed else { return }
        presentationArmed = true
        sceneClock.setAttached(window != nil, at: ProcessInfo.processInfo.systemUptime)
        // A paused presentation still needs its initialized, time-zero image.
        needsDisplay = true
        if window != nil && !sceneClock.isPaused { startTimer(); installMouseMonitor() }
    }
    func refreshPresentation() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        openGLContext?.update()
        needsDisplay = true
    }
    var playbackDescription: String {
        let time = sceneClock.time(at: ProcessInfo.processInfo.systemUptime)
        return String(format: "场景时间 %.2f 秒 · %@", time, sceneClock.isPaused ? "已暂停" : "正在播放")
    }
    var playbackTime: Double { sceneClock.time(at: ProcessInfo.processInfo.systemUptime) }
    /// Exposed only to the native authoring window, using the same quads and
    /// text layout offsets as actual rendering. Ordinary wallpapers cannot edit.
    func editorLayerBounds(at index: Int) -> CGRect? {
        guard editorSeekingAllowed, nativeCreationMotions[index] != nil,
              let draw = draws.first(where: { $0.objectIndex == index && !$0.fullscreen }),
              let size = draw.geometry.editorQuadSize, size.width > 0, size.height > 0 else { return nil }
        let offset = draw.alignmentOffset + (draw.text?.offset ?? .zero)
        return CGRect(x: CGFloat(offset.x) - size.width / 2, y: CGFloat(offset.y) - size.height / 2, width: size.width, height: size.height)
    }
    @discardableResult
    func updateEditorMotion(_ motion: NativeCreationMotion, at index: Int) -> Bool {
        updateEditorMotions([index: motion])
    }
    @discardableResult
    func updateEditorMotions(_ updates: [Int: NativeCreationMotion]) -> Bool {
        guard editorSeekingAllowed, sceneClock.isPaused, scripts == nil, timelines.paths.isEmpty, sounds.isEmpty,
              !updates.isEmpty else { return false }
        var next = nativeCreationMotions
        for (index, motion) in updates {
            guard let previous = nativeCreationMotions[index], previous.duration == motion.duration, previous.loop == motion.loop,
                  (try? motion.validated()) != nil else { return false }
            next[index] = motion
        }
        guard next.values.reduce(0, { $0 + $1.scalarKeyframeCount }) <= 6144 else { return false }
        nativeCreationMotions = next
        needsDisplay = true
        return true
    }
    @discardableResult
    func seekEditor(to time: Double) -> Bool {
        guard editorSeekingAllowed, scripts == nil, timelines.paths.isEmpty, sounds.isEmpty,
              time.isFinite, (0...120).contains(time) else { return false }
        pause()
        editorEndpoint = true
        sceneClock.seek(to: time, at: ProcessInfo.processInfo.systemUptime)
        currentSceneTime = time; previousSceneTime = time
        needsDisplay = true
        return true
    }
    /// Render an unpresented native creation into our own offscreen target.
    /// This never captures a desktop/window or includes editor selection handles.
    func editorPreviewPNG(width: Int, height: Int) throws -> Data {
        guard editorSeekingAllowed, sceneClock.isPaused, window == nil, renderedFrames == 0,
              scripts == nil, timelines.paths.isEmpty, sounds.isEmpty, failedLayerCount == 0,
              (1...NativeCreationPreview.maximumDimension).contains(width),
              (1...NativeCreationPreview.maximumDimension).contains(height), let context = openGLContext else {
            throw SceneError.invalid("当前预览无法生成作品预览图。")
        }
        context.makeCurrentContext()
        guard glGetError() == GLenum(GL_NO_ERROR) else { throw SceneError.invalid("预览准备发生图形错误，尚未保存新版本。") }
        defer { glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 4); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0) }
        try prepareFramebuffers(width: width, height: height)
        let output = try SceneTarget(width: width, height: height, withDepth: false, hdr: false)
        defer { withExtendedLifetime(output) {} }
        let time = sceneClock.time(at: ProcessInfo.processInfo.systemUptime)
        render(time: time, width: width, height: height, outputWidth: width, outputHeight: height,
               outputFramebuffer: output.framebuffer)
        glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0)); glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
        glBindBuffer(GLenum(GL_PIXEL_PACK_BUFFER), 0)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), $0.baseAddress) }
        guard glGetError() == GLenum(GL_NO_ERROR) else { throw SceneError.invalid("作品预览图绘制失败，尚未保存新版本。") }
        return try NativeCreationPreview.encode(bottomUpRGBA: pixels, width: width, height: height)
    }
    private var presentationContext: [String: Any] {
        ["presentationID": presentationID, "windowNumber": window?.windowNumber ?? -1,
         "displayID": (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? "unknown"]
    }
    private var frameRateLimit = 60
    func setFrameRateLimit(_ framesPerSecond: Int) {
        let value = min(240, max(10, framesPerSecond))
        guard value != frameRateLimit else { return }
        frameRateLimit = value; timer?.invalidate(); timer = nil
        if window != nil && presentationArmed && !sceneClock.isPaused { startTimer() }
    }
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / Double(frameRateLimit), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    func pause() {
        guard !sceneClock.isPaused else { return }
        sceneClock.setPaused(true, at: ProcessInfo.processInfo.systemUptime, holdingLastFrame: true)
        // Redraw exactly the last submitted scene time and published script
        // state. Neither the wall-clock remainder nor a pending reply advances it.
        needsDisplay = true
        scripts?.suspend()
        timer?.invalidate(); timer = nil
        sounds.forEach { $0.suspend() }
        // Scene texture audio is not part of SceneSoundLayer; stop it here so
        // a paused desktop never waits for a subsequent OpenGL draw to mute.
        for runtime in videoRuntimes.values { runtime.suspendAudio() }
        SceneMusicSpectrum.shared.clear(owner: musicOwner)
    }
    func resume() {
        guard sceneClock.isPaused else { return }
        sceneClock.setPaused(false, at: ProcessInfo.processInfo.systemUptime)
        editorEndpoint = false
        scripts?.resume()
        if window != nil && presentationArmed { startTimer(); installMouseMonitor() }
    }
    func applyUserProperties(_ changes: [String: Any]) {
        properties.merge(changes) { _, next in next }
        scripts?.applyUserProperties(changes)
        refreshSounds()
        needsDisplay = true
        fputs("Scene property changes: \(changes.keys.sorted().joined(separator: ",")); material bindings updated without reload\n", stderr)
    }
    func prepareUserPropertyUpdate(_ changes: [String: Any]) async throws -> () -> Void {
        guard scripts?.hasPendingCreation != true else {
            throw SceneError.invalid("壁纸脚本正在创建图层；请等待本次更新显示后重新应用设置。已暂停时请先恢复播放。")
        }
        return { [weak self] in self?.applyUserProperties(changes) }
    }
    override func reshape() { super.reshape(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        guard let window, let context = openGLContext else { return }
        context.makeCurrentContext()
        let backing = convertToBacking(bounds)
        let initializationResolved = scripts?.initializationResolved ?? true
        guard presentationArmed, window.isVisible, initializationResolved else {
            if presentationArmed && window.isVisible && !initializationResolved && startupWaitStartedAt == nil {
                startupWaitStartedAt = ProcessInfo.processInfo.systemUptime
                fputs("Scene startup waiting: script initialization; sceneTime 0; presentation \(presentationID)\n", stderr)
            }
            startupPlaceholderFrames += 1
            let color = SceneValues.vector((scene["general"] as? [String: Any])?["clearcolor"], .zero)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
            glViewport(0, 0, GLsizei(max(1, Int(backing.width))), GLsizei(max(1, Int(backing.height))))
            glClearColor(color.x, color.y, color.z, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            context.flushBuffer()
            return
        }
        // Bound the framebuffer allocation independently of display scale.
        let factor = min(1.0, 4096.0 / max(1, max(backing.width, backing.height)))
        let width = max(1, Int(backing.width * factor)), height = max(1, Int(backing.height * factor))
        refreshTextureResolutionForOutput(CGSize(width: width, height: height))
        do {
            try prepareFramebuffers(width: width, height: height)
            let time = sceneClock.time(at: ProcessInfo.processInfo.systemUptime)
            if renderedFrames == 0 {
                var ready = true
                for (key, video) in videoRuntimes {
                    let playhead = scripts?.videoPlayback[key]?.time(at: time, duration: video.asset.duration)
                        ?? time.truncatingRemainder(dividingBy: video.asset.duration)
                    if try !video.ready(at: playhead) { ready = false }
                }
                if !ready { return }
            }
            render(time: time, width: width, height: height, outputWidth: max(1,Int(backing.width)), outputHeight: max(1,Int(backing.height)))
            context.flushBuffer()
            renderedFrames += 1
            if renderedFrames == 1 {
                let error = glGetError()
                let submittedAt = ProcessInfo.processInfo.systemUptime
                sceneClock.submitFirstFrame(at: submittedAt)
                fputs("Scene first frame submitted: \(width)x\(height), GL error \(error), sceneTime \(time)\n", stderr)
                var startup: [String: Any] = ["sceneTime": time, "scriptInitialization": scripts?.initializationStatus ?? "not-required",
                    "paused": sceneClock.isPaused, "placeholderFrames": startupPlaceholderFrames,
                    "preparationSeconds": submittedAt - constructionStartedAt,
                    "scriptWaitSeconds": startupWaitStartedAt.map { submittedAt - $0 } ?? 0,
                    "submittedAtUptime": submittedAt]
                startup.merge(presentationContext) { _, next in next }
                if let data = try? JSONSerialization.data(withJSONObject: startup, options: [.sortedKeys]) {
                    fputs("Scene startup submitted: \(String(decoding: data, as: UTF8.self))\n", stderr)
                }
                note("首帧提交：\(width)×\(height)，\(draws.count) 个绘制组，OpenGL 错误码 \(error)。这只记录渲染调用状态，不代表画面完整性。")
                refreshSounds()
            }
        } catch {
            if !reportedFrameError {
                fputs("Scene frame failed: \(error.localizedDescription)\n", stderr)
                note("场景绘制失败：\(error.localizedDescription)")
                reportedFrameError = true
            }
        }
    }

    private func prepareFramebuffers(width: Int, height: Int) throws {
        if targets.first?.width != width || targets.first?.height != height || targets.first?.hdr != sceneHDR {
            _ = try NativeAntialiasing.bytes(width: width, height: height, samples: antialiasingQuality.samples, hdr: sceneHDR, depth: true, targets: 2)
            let newTargets = try [SceneTarget(width: width, height: height, hdr: sceneHDR), SceneTarget(width: width, height: height, hdr: sceneHDR)]
            if antialiasingQuality != .none {
                for target in newTargets { target.multisample = try NativeOpenGLAntialiasing(width: width, height: height, hdr: sceneHDR, samples: antialiasingQuality.samples) }
            }
            let newHDRBloom = sceneHDR ? try NativeHDRBloom(width: width, height: height, previous: hdrBloom) : nil
            let newStandardBloom = sceneHDR ? nil : try NativeStandardBloom(width: width, height: height, previous: standardBloom)
            let general = scene["general"] as? [String: Any] ?? [:]
            let ortho = general["orthogonalprojection"] as? [String: Any]
            let canvasHeight = max(1, SceneValues.number(ortho?["height"], 1080))
            let framing = NativeSceneHistoryFraming(canvas: ortho.map {
                SIMD2(max(1, SceneValues.number($0["width"], canvasHeight)), canvasHeight)
            }, automaticWidth: ortho != nil && ortho?["width"] == nil)
            let newHistory = general["clearenabled"] != nil || SceneScriptBridge.hasScripts(scene)
                ? sceneHistory ?? NativeSceneHistory(framing: framing) : nil
            let newFullscreenInput = draws.contains(where: { $0.topLeftFullscreen })
                ? try SceneTarget(width: width, height: height, withDepth: false, hdr: sceneHDR) : nil
            targets = newTargets; hdrBloom = newHDRBloom; standardBloom = newStandardBloom
            sceneHistory = newHistory
            fullscreenInput = newFullscreenInput
            if draws.contains(where: { $0.puppetClip != nil }) {
                let oldPixels = puppetMaskTarget.map { $0.width * $0.height } ?? 0
                let delta = width * height - oldPixels
                do {
                    guard delta <= layerTargetPixelLimit - layerTargetPixels else {
                        throw SceneError.invalid("木偶遮罩缓冲超过场景像素预算。")
                    }
                    let newMask = try SceneTarget(width: width, height: height, withDepth: false, hdr: false)
                    puppetMaskTarget = newMask; layerTargetPixels += delta
                } catch { note("木偶遮罩缓冲不可用，继续绘制未裁剪网格：\(error.localizedDescription)") }
            }
            fputs("Scene framebuffer: \(width)x\(height), \(sceneHDR ? "RGBA16F" : "RGBA8"), scene.general.hdr=\(sceneHDR)\n", stderr)
        }
        if needsReflectionHistory,
           reflectionHistory?.sample.width != width || reflectionHistory?.sample.height != height || reflectionHistory?.sample.hdr != sceneHDR {
            reflectionHistory = try NativeSceneReflection(width: width, height: height, hdr: sceneHDR, previous: reflectionHistory)
        }
    }

    private func note(_ message: String) {
        if let diagnosticOwner, !(objectDiagnosticNotes[diagnosticOwner] ?? []).contains(message) {
            objectDiagnosticNotes[diagnosticOwner, default: []].append(message)
        }
        if !diagnosticNotes.contains(message) { diagnosticNotes.append(message) }
    }

    func setAudioOutputEnabled(_ enabled: Bool) {
        soundOutputEnabled = enabled
        for runtime in videoRuntimes.values { runtime.setAudioOutputEnabled(enabled) }
        if enabled { SceneMusicSpectrum.shared.activate(owner: musicOwner) }
        else { sounds.forEach { $0.suspend() }; SceneMusicSpectrum.shared.deactivate(owner: musicOwner) }
        if !sounds.isEmpty { fputs("Scene sound output: \(enabled ? "primary presentation" : "disabled for secondary/retired presentation")\n", stderr) }
    }

    private var soundStates: [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for sound in sounds { result[sound.objectID] = sound.scriptState }
        return result
    }

    private func refreshSounds(states: [[String: Any]]? = nil, visibility: [Bool]? = nil) {
        // Initial script stop/pause commands are consumed before autoplay.
        let active = soundOutputEnabled && window != nil && sceneClock.hasSubmittedFrame && !sceneClock.isPaused && (scripts?.initializationResolved ?? true)
        refreshVideoAudio(active: active)
        guard !sounds.isEmpty else { return }
        for command in scripts?.takeSoundCommands() ?? [] {
            if let sound = sounds.first(where: { $0.objectID == command["id"] }), let action = command["action"] { sound.command(action) }
        }
        let resolvedStates = states ?? hierarchy.parents.indices.map { objectState($0) }
        let visible = visibility ?? hierarchy.resolve(local: resolvedStates.map(SceneValues.transform), visible: resolvedStates.map { SceneValues.visible($0["visible"]) }).visible
        for sound in sounds {
            sound.update(volume: resolvedStates[sound.objectIndex]["volume"], visible: visible[sound.objectIndex], active: active, minimum: resolvedStates[sound.objectIndex]["mintime"], maximum: resolvedStates[sound.objectIndex]["maxtime"])
            for message in sound.diagnostics { note("\(sound.name)：\(message)") }
        }
    }

    /// Kept separate from `refreshSounds`: a Scene video can be the only
    /// audio-bearing resource, and every call still uses the exact same
    /// presentation-owner / first-submitted-frame policy as Scene sounds.
    func refreshVideoAudio(active: Bool) {
        for (key, runtime) in videoRuntimes {
            runtime.syncAudio(playback: scripts?.videoPlayback[key], sceneTime: currentSceneTime,
                              active: active, outputEnabled: soundOutputEnabled)
        }
    }

    private func updateAudioSpectrum() {
        let system = NativeAudioService.shared
        if system.active {
            SceneMusicSpectrum.shared.clear(owner: musicOwner)
            audioSpectrum = system.snapshot
        } else {
            if soundOutputEnabled { SceneMusicSpectrum.shared.update(owner: musicOwner, inputs: sounds.compactMap { $0.musicInput }) }
            audioSpectrum = SceneMusicSpectrum.shared.snapshot
            for message in SceneMusicSpectrum.shared.diagnostics { note("壁纸音乐频谱：" + message) }
        }
        let source = system.active ? "system capture" : "wallpaper music resources (silence when absent)"
        if source != lastAudioSource {
            lastAudioSource = source
            fputs("Scene audio spectrum source: \(source)\n", stderr)
        }
    }

    /// Only authored direct values and combo equality are interpreted here.
    /// This is not an evaluator for arbitrary editor condition expressions.
    private func propertyValue(_ raw: Any?) -> Any? {
        guard let wrapped = raw as? [String: Any], let fallback = wrapped["value"] else { return raw }
        if let key = wrapped["user"] as? String, let property = properties[key] as? [String: Any] { return property["value"] ?? fallback }
        if let reference = wrapped["user"] as? [String: Any], let key = reference["name"] as? String,
           let value = (properties[key] as? [String: Any])?["value"] {
            if let expected = reference["condition"] { return String(describing: value) == String(describing: expected) }
            return value
        }
        return fallback
    }

    private func particleInstance(_ object: [String: Any], index: Int) -> [String: Any] {
        var instance = object["instanceoverride"] as? [String: Any] ?? [:]
        for key in Array(instance.keys) { instance[key] = propertyValue(instance[key]) }
        for key in SceneParticles.liveInstanceKeys {
            let path = "/objects/\(index)/instanceoverride/\(key)"
            if let value = timelines.value(at: path, time: currentSceneTime, base: instance[key]) { instance[key] = value }
            if let value = scripts?.value(at: path, fallback: nil) { instance[key] = value }
        }
        return instance
    }

    private func passVisible(_ pass: ScenePass) -> Bool {
        if let path = pass.visibilityPath, let value = scripts?.value(at: path, fallback: nil) { return SceneValues.visible(value) }
        return SceneValues.visible(propertyValue(pass.visibility))
    }

    private func potentiallyVisible(_ value: Any?) -> Bool {
        if let wrapped = value as? [String: Any], wrapped["user"] != nil || wrapped["script"] != nil { return true }
        return SceneValues.visible(value)
    }

    private func objectState(_ index: Int, includeModelMotion: Bool = true) -> [String: Any] {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        guard objects.indices.contains(index) else { return [:] }
        var object = objects[index]
        let keys = sceneProperties(for: object)
        for key in keys {
            if let value = propertyValue(object[key]) { object[key] = value }
        }
        let authoredValues = object
        if object["camera"] is String {
            let base = NativeSceneCameras.TransformState(origin: SceneValues.vector(object["origin"], .zero), angles: SceneValues.vector(object["angles"], .zero))
            let state = sceneCameras.state(index: index, base: base)
            object["origin"] = [state.origin.x, state.origin.y, state.origin.z]
            object["angles"] = [state.angles.x, state.angles.y, state.angles.z]
        }
        for key in keys {
            if let value = timelines.value(at: "/objects/\(index)/\(key)", time: currentSceneTime, base: authoredValues[key]) { object[key] = value }
        }
        let id = SceneScriptBridge.objectID(object, index: index)
        object["id"] = id
        if let updates = scripts?.layerValues[id] {
            for key in keys {
                if modelAnimations[index]?.hasRootMotion == true && ["origin", "angles", "rootmotion"].contains(key) { continue }
                if let value = updates[key] { object[key] = key == "angles" ? SceneValues.floats(value).map { $0 * .pi / 180 } : value }
            }
        }
        for key in keys {
            if modelAnimations[index]?.hasRootMotion == true && ["origin", "angles", "rootmotion"].contains(key) { continue }
            if let value = scripts?.value(at: "/objects/\(index)/\(key)", fallback: nil) {
                object[key] = key == "angles" ? SceneValues.floats(value).map { $0 * .pi / 180 } : value
            }
        }
        if let motion = nativeCreationMotions[index] {
            let pose = motion.pose(at: currentSceneTime, preserveEndpoint: editorEndpoint)
            nativeCreationPoses[index] = pose
            object["origin"] = [pose.x, pose.y, 0]
            object["scale"] = [pose.scaleX, pose.scaleY, 1]
            object["angles"] = [0, 0, pose.rotation * .pi / 180]
            object["alpha"] = pose.opacity
        }
        if includeModelMotion, let motion = modelAnimations[index]?.motion { object.merge(motion.properties) { _, next in next } }
        return object
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTracking { removeTrackingArea(cursorTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(tracking); cursorTracking = tracking
        window?.acceptsMouseMovedEvents = true
    }

    private func installMouseMonitor() {
        let mode = NativeDesktopPointerRouting.mode(for: window)
        guard NativeDesktopPointerRouting.needsGlobalButtonMonitor(mode: mode,
                                                                    hasScripts: scripts != nil,
                                                                    monitorInstalled: globalMouseMonitor != nil) else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.desktopCursorIsExposed() else { return }
                self.routeMouseButton(down: event.type == .leftMouseDown)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        previewPointerCounts[0] = min(1_000_000_000, previewPointerCounts[0] + 1)
        previewCursor = convert(event.locationInWindow, from: nil); previewLeftDown = true
        routeMouseButton(down: true)
    }
    override func mouseUp(with event: NSEvent) {
        previewPointerCounts[1] = min(1_000_000_000, previewPointerCounts[1] + 1)
        previewCursor = convert(event.locationInWindow, from: nil); previewLeftDown = false
        routeMouseButton(down: false)
    }
    override func mouseMoved(with event: NSEvent) {
        previewCursor = convert(event.locationInWindow, from: nil); queuePreviewMove()
    }
    override func mouseDragged(with event: NSEvent) {
        previewPointerCounts[2] = min(1_000_000_000, previewPointerCounts[2] + 1)
        previewCursor = convert(event.locationInWindow, from: nil); previewLeftDown = true
        queuePreviewMove()
    }
    override func mouseEntered(with event: NSEvent) { previewCursor = convert(event.locationInWindow, from: nil) }
    override func mouseExited(with event: NSEvent) { previewCursor = nil; previewLeftDown = false }

    /// Mouse-only observation retains Finder click-through. Ordinary windows
    /// covering that point suppress desktop input; no keyboard hook is installed.
    private func desktopCursorIsExposed() -> Bool {
        guard let window, NativeDesktopPointerRouting.isDesktopPresentation(window),
              let relativeWindow = NativeDesktopPointerRouting.desktopCoverageRelativeWindowNumber(window.windowNumber),
              window.frame.contains(NSEvent.mouseLocation),
              NativeDesktopPointerRouting.desktopFrontmostMayObserve(
                ignoresMouseEvents: window.ignoresMouseEvents,
                frontmostBundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                ownBundleIdentifier: Bundle.main.bundleIdentifier
              ) else { return false }
        let point = CGPoint(x: NSEvent.mouseLocation.x, y: (NSScreen.screens.first?.frame.height ?? 0) - NSEvent.mouseLocation.y)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], relativeWindow) as? [[String: Any]] else { return false }
        for info in windows {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 0,
                  NativeDesktopPointerRouting.listedWindowMayCoverDesktop(
                    listedWindowNumber: (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                    desktopWindowNumber: window.windowNumber),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.contains(point),
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return false
        }
        return true
    }

    private func cursorState() -> (point: NSPoint, world: SIMD3<Float>, screen: [String: Double], inside: Bool) {
        let windowPoint = window?.convertPoint(fromScreen: NSEvent.mouseLocation) ?? .zero
        let desktop = NativeDesktopPointerRouting.isDesktopPresentation(window)
        let point = desktop ? convert(windowPoint, from: nil) : (previewCursor ?? convert(windowPoint, from: nil))
        let camera = camera(aspect: Float(max(1, bounds.width) / max(1, bounds.height)))
        let normalized = SIMD2<Float>(Float(point.x / max(1, bounds.width)), Float(point.y / max(1, bounds.height)))
        let world = SceneParticlePointerInput.project(normalized: normalized,
            modelViewProjection: camera.projection * camera.view).position ?? .zero
        let backing = convertToBacking(point)
        // IInput screen coordinates begin at the wallpaper's top-left; scene
        // world coordinates retain the authored bottom-left 2D origin.
        let backingHeight = convertToBacking(bounds).height
        return (point, SIMD3(world.x, world.y, 0), ["x": backing.x, "y": backingHeight - backing.y], bounds.contains(point))
    }

    private func cursorTargets(point: NSPoint) -> [String] {
        let objects = scene["objects"] as? [[String: Any]] ?? []
        let states = objects.indices.map { objectState($0) }
        let resolved = hierarchy.resolve(local: states.map(SceneValues.transform), visible: states.map { SceneValues.visible($0["visible"]) })
        let offsets = parallaxOffsets(states: states)
        let normalized = SIMD2<Float>(Float(point.x / max(1, bounds.width)), Float(point.y / max(1, bounds.height)))
        let baseCamera = camera(aspect: Float(max(1, bounds.width) / max(1, bounds.height)))
        var result: [String] = []
        for index in (scripts?.sceneLayerOrder ?? initialSceneLayerOrder)?.indices ?? Array(objects.indices) {
            let object = states[index]
            // Authors also use invisible solid layers as input regions (for
            // example Day/Night's drag area). Preserve their own hit region,
            // while a hidden/invalid ancestor suppresses the whole child tree.
            let parentVisible = hierarchy.parents[index].map { resolved.visible[$0] } ?? true
            let acceptsPointer = object["solid"] as? Bool ?? (object["image"] is String)
            guard !hierarchy.invalid.contains(index), parentVisible, acceptsPointer else { continue }
            let text = draws.first { $0.objectIndex == index && $0.text != nil }?.text
            let size = text.map { [Float($0.texture.width), Float($0.texture.height)] } ?? SceneValues.floats(object["size"])
            guard size.count >= 2, size.prefix(2).allSatisfy({ $0.isFinite && $0 > 0 }) else { continue }
            let model = text?.anchor.model(resolved.transforms[index], margins: textAnchorMargins) ?? resolved.transforms[index]
            guard let layerCamera = parallaxCamera(baseCamera, offset: offsets[index]),
                  let local = SceneParticlePointerInput.project(normalized: normalized,
                    modelViewProjection: layerCamera.projection * layerCamera.view * model).position else { continue }
            let offset = text?.offset ?? (object["image"] is String ? ((try? imageAlignment(object["alignment"], size: size)) ?? .zero) : .zero)
            if abs(local.x - offset.x) <= size[0] / 2, abs(local.y - offset.y) <= size[1] / 2 {
                result.append(SceneScriptBridge.objectID(object, index: index))
            }
        }
        return result
    }

    private func cursorEvent(_ cursor: (point: NSPoint, world: SIMD3<Float>, screen: [String: Double], inside: Bool)) -> [String: Any] {
        ["worldPosition": ["x": Double(cursor.world.x), "y": Double(cursor.world.y), "z": 0], "screenPosition": cursor.screen]
    }

    private func cursorInput(_ cursor: (point: NSPoint, world: SIMD3<Float>, screen: [String: Double], inside: Bool), leftDown: Bool) -> [String: Any] {
        ["cursorScreenPosition": cursor.screen,
         "cursorWorldPosition": ["x": Double(cursor.world.x), "y": Double(cursor.world.y), "z": 0],
         "cursorLeftDown": leftDown, "cursorRightDown": false]
    }

    private func queuePreviewMove() {
        guard !sceneClock.isPaused, sceneClock.hasSubmittedFrame else { return }
        let cursor = cursorState()
        let mode = NativeDesktopPointerRouting.mode(for: window)
        // Desktop input is sampled once per rendered frame in updateScripts.
        // Hide Desktop Icons lets this same DesktopWindow receive AppKit move
        // events, but queuing them here as well would emit a second
        // cursorMove before updateScripts advances previousCursor.
        guard mode == .preview else { return }
        // Test and offscreen hosts may not have constructed NSApplication;
        // previews fail closed in that case instead of dereferencing the AppKit
        // global while the desktop path remains independent of app activity.
        let applicationActive = NSApp?.isActive == true
        guard cursor.inside, NativeDesktopPointerRouting.admitsInput(
            mode: mode,
            desktopExposed: false,
            isKeyWindow: window?.isKeyWindow == true,
            applicationActive: applicationActive,
            hasPreviewPoint: previewCursor != nil
        ) else { return }
        scripts?.event(name: "cursorMove", objectIDs: cursorTargets(point: cursor.point), event: cursorEvent(cursor),
                       input: cursorInput(cursor, leftDown: previewLeftDown))
    }

    private func routeMouseButton(down: Bool) {
        guard !sceneClock.isPaused, sceneClock.hasSubmittedFrame, scripts != nil else { return }
        let cursor = cursorState()
        let mode = NativeDesktopPointerRouting.mode(for: window)
        let desktop = mode == .desktop
        // The offscreen OpenGL host can render a desktop view without an
        // NSApplication. Desktop admission does not depend on active-app
        // state, so preserve that boundary and avoid touching NSApp unless
        // this is an actual preview presentation.
        let applicationActive = mode == .preview && (NSApp?.isActive == true)
        guard cursor.inside, NativeDesktopPointerRouting.admitsInput(
            mode: mode,
            desktopExposed: desktop && desktopCursorIsExposed(),
            isKeyWindow: window?.isKeyWindow == true,
            applicationActive: applicationActive,
            hasPreviewPoint: previewCursor != nil
        ) else { cursorPressTargets = []; return }
        let targets = cursorTargets(point: cursor.point)
        if loggedMouseButtons < 12 {
            loggedMouseButtons += 1
            fputs("SceneScript pointer \(down ? "down" : "up"): world \(cursor.world.x),\(cursor.world.y), targets \(targets.joined(separator: ","))\n", stderr)
        }
        scripts?.event(name: down ? "cursorDown" : "cursorUp", objectIDs: targets, event: cursorEvent(cursor), input: cursorInput(cursor, leftDown: down))
        if down { cursorPressTargets = targets }
        else {
            scripts?.event(name: "cursorClick", objectIDs: targets.filter { cursorPressTargets.contains($0) }, event: cursorEvent(cursor), input: cursorInput(cursor, leftDown: false))
            cursorPressTargets = []
        }
    }

    private func updateScripts(time: Double) {
        guard !sceneClock.isPaused, let scripts else { return }
        for message in scripts.diagnostics { note("SceneScript：" + message) }
        let cursor = cursorState()
        let mode = NativeDesktopPointerRouting.mode(for: window)
        let desktop = mode == .desktop
        // See routeMouseButton(_:): desktop-only render hosts do not require
        // an NSApplication merely to reject/accept pointer samples.
        let applicationActive = mode == .preview && (NSApp?.isActive == true)
        let inputEnabled = cursor.inside && NativeDesktopPointerRouting.admitsInput(
            mode: mode,
            desktopExposed: desktop && desktopCursorIsExposed(),
            isKeyWindow: window?.isKeyWindow == true,
            applicationActive: applicationActive,
            hasPreviewPoint: previewCursor != nil
        )
        pointerInputEnabled = inputEnabled
        pointerLastScreen = SIMD2(cursor.screen["x"] ?? 0, cursor.screen["y"] ?? 0)
        if inputEnabled && (desktop ? NSEvent.pressedMouseButtons & 1 != 0 : previewLeftDown) {
            pointerDownFrames = min(1_000_000_000, pointerDownFrames + 1)
        }
        if desktop, inputEnabled, previousCursor != cursor.point {
            scripts.event(name: "cursorMove", objectIDs: cursorTargets(point: cursor.point), event: cursorEvent(cursor),
                          input: cursorInput(cursor, leftDown: NSEvent.pressedMouseButtons & 1 != 0))
        }
        previousCursor = cursor.point
        let size = convertToBacking(bounds).size
        scripts.frame(runtime: time, screen: ["x": size.width, "y": size.height], input: [
            "cursorScreenPosition": cursor.screen,
            "cursorWorldPosition": ["x": Double(cursor.world.x), "y": Double(cursor.world.y), "z": 0],
            "cursorLeftDown": inputEnabled && (desktop ? NSEvent.pressedMouseButtons & 1 != 0 : previewLeftDown),
            "cursorRightDown": inputEnabled && NSEvent.pressedMouseButtons & 2 != 0
        ], audio: audioSpectrum, sounds: soundStates, timelineValues: timelines.scriptInput(at: time, resolveBase: propertyValue))
    }

    private func buildScene() throws {
        guard let objects = scene["objects"] as? [[String: Any]], objects.count <= 5000 else { throw SceneError.invalid("scene.json 缺少对象列表或超过 5000 个对象。") }
        let totals = objectAllocations.values.reduce(into: ObjectAllocation()) { $0.add($1) }
        var emitterHistoryReservations = totals.emitterHistories
        var worldChildInstanceReservations = totals.worldChildInstances
        var sceneChildParticleReservations = totals.childParticles, sceneChildInstanceReservations = totals.childInstances
        let activeSlots = lifecycleSnapshot?.activeSlots
        for (objectIndex, object) in objects.enumerated() where (activeSlots?.contains(objectIndex) ?? true) && (incrementalCreationSlots?.contains(objectIndex) ?? true) {
            creationPreparationStatistics?.constructedObjects += 1
            let objectPath = "/objects/\(objectIndex)"
            let firstDraw = draws.count
            let reservationsBeforeObject = (emitterHistoryReservations, worldChildInstanceReservations,
                sceneChildParticleReservations, sceneChildInstanceReservations)
            let puppetBefore = (puppetVerticesReserved, puppetAnimationBytesReserved, puppetMasksReserved)
            let failuresBefore = failedLayerCount
            diagnosticOwner = objectIndex
            defer {
                if failedLayerCount == failuresBefore {
                    objectAllocations[objectIndex] = ObjectAllocation(
                        emitterHistories: emitterHistoryReservations - reservationsBeforeObject.0,
                        worldChildInstances: worldChildInstanceReservations - reservationsBeforeObject.1,
                        childParticles: sceneChildParticleReservations - reservationsBeforeObject.2,
                        childInstances: sceneChildInstanceReservations - reservationsBeforeObject.3,
                        puppetVertices: puppetVerticesReserved - puppetBefore.0,
                        puppetAnimationBytes: puppetAnimationBytesReserved - puppetBefore.1,
                        puppetMasks: puppetMasksReserved - puppetBefore.2)
                }
                diagnosticOwner = nil
            }
            let name = object["name"] as? String ?? "Object"
            do {
            let transform = SceneValues.transform(object)
            var handledImageEffects = false
            if NativeSceneTransformNode.matches(object) {
                // Hierarchy and SceneScript use this slot even though it owns
                // no geometry, material, audio player, camera or light.
                continue
            } else if object["camera"] is String {
                // Camera layers participate in hierarchy and scripting but
                // have no material or draw group of their own.
                continue
            } else if let light = object["light"] as? String {
                if !["lpoint", "lspot", "ldirectional"].contains(light) { note("\(name)：灯光类型 \(light) 尚未接入原生模型材质。") }
                if !["lpoint", "lspot"].contains(light), SceneValues.visible(propertyValue(object["castshadow"]) ?? false) {
                    note("\(name)：此灯光类型的投影阴影尚未实现。")
                }
                if light != "lpoint", SceneValues.visible(propertyValue(object["castvolumetrics"]) ?? false) {
                    note("\(name)：此灯光类型的体积光尚未实现。")
                }
                continue
            } else if object["sound"] != nil {
                guard sounds.count < 32 else { throw SceneError.invalid("场景声音层超过当前 32 层上限。") }
                let id = SceneScriptBridge.objectID(object, index: objectIndex)
                guard !sounds.contains(where: { $0.objectID == id }) else { throw SceneError.invalid("声音层 ID 重复。") }
                let sound = try SceneSoundLayer(object: object, index: objectIndex, assets: assets, remainingBytes: 128 * 1024 * 1024 - soundBytes, initialVolume: propertyValue(object["volume"]), initialMinimum: propertyValue(object["mintime"]), initialMaximum: propertyValue(object["maxtime"]))
                sounds.append(sound); soundBytes += sound.byteCount
                for message in sound.diagnostics { note("\(name)：\(message)") }
                continue
            } else if let model = object["model"] as? String {
                let shapes = try modelShapes(model)
                let id = SceneScriptBridge.objectID(object, index: objectIndex)
                guard modelScriptStore.players[id] == nil, !modelScriptStore.staticModelIDs.contains(id) else { throw SceneError.invalid("模型图层 ID 重复。") }
                if let animation = try NativeModelAnimation.Source.make(object["animationlayers"], skeleton: shapes.first?.skeleton, includeEmpty: true, resolve: propertyValue) {
                    guard modelAnimations.count < 256,
                          modelAnimations.values.reduce(0, { $0 + $1.source.layers.count }) + animation.layers.count <= 2048 else {
                        throw SceneError.invalid("模型动画超过每场景 256 实例 / 2048 层预算。")
                    }
                    modelAnimations[objectIndex] = NativeModelAnimation.Runtime(animation)
                    modelScriptStore.players[id] = modelAnimations[objectIndex]!
                } else { modelScriptStore.staticModelIDs.insert(id) }
                for shape in shapes {
                    draws.append(SceneDraw(name: name, geometry: shape.geometry, transform: transform,
                        fullscreen: false, copyBackground: false, passes: shape.passes.map { $0.forModelInstance(objectIndex) }, particles: nil,
                        skeleton: shape.skeleton, modelBounds: shape.bounds))
                }
            } else if let particlePath = object["particle"] as? String {
                let document = try assets.json(particlePath)
                let instance = particleInstance(object, index: objectIndex)
                let system = try SceneParticles(document: document, instance: instance,
                    orthographic: (scene["general"] as? [String: Any])?["orthogonalprojection"] is [String: Any])
                for (key, raw) in object["instanceoverride"] as? [String: Any] ?? [:] {
                    if let wrapped = raw as? [String: Any], wrapped["user"] != nil || wrapped["script"] != nil {
                        if SceneParticles.liveInstanceKeys.contains(key) {
                            if key == "rate" {
                                note("\(name)：instance.rate 已接入用户属性/属性脚本；连续时间与鼠标、世界坐标历史使用有界回放。Windows 同帧顺序尚未对齐。")
                            } else {
                                note("\(name)：instance.\(key) 已接入用户属性/属性脚本；运行中保留粒子池。密度按原生发射相位更新，Windows 同帧顺序尚未对齐。")
                            }
                        } else {
                            note("\(name)：instance.\(key) 仅读取初始用户属性；运行中修改该参数尚未实现。")
                        }
                    }
                }
                if system.usesWorldSpace {
                    guard emitterHistoryReservations < 64 else { throw SceneError.invalid("世界坐标发射器历史超过每场景 64 份上限。") }
                    system.enableEmitterTransformHistory(); emitterHistoryReservations += 1
                }
                let passes = try material(system.materialPath, particle: true)
                if passes.count > 1, passes.contains(where: { $0.textures[0]?.animation != nil }) {
                    throw SceneError.invalid("\(name): 多材质 pass 的粒子序列尚未支持。")
                }
                if let texture = passes.first?.textures[0] {
                    try system.configureTexture(texture.animation, width: texture.width, height: texture.height, imageWidth: texture.imageWidth, imageHeight: texture.imageHeight)
                }
                for warning in system.warnings { note("\(name): \(warning)") }
                draws.append(SceneDraw(name: name, geometry: SceneGeometry(vertices: [], particles: true), transform: transform, fullscreen: false, copyBackground: false, passes: passes, particles: system))
                if let rawChildren = document["children"], !(rawChildren is NSNull) {
                    if let children = rawChildren as? [[String: Any]], children.count <= 16 {
                        var reservedParticles = 0, reservedInstances = 0
                        for (childIndex, declaration) in children.enumerated() {
                            do {
                                guard let path = declaration["name"] as? String, !path.isEmpty else {
                                    throw SceneError.invalid("子粒子缺少资源路径。")
                                }
                                let child = try SceneParticleChildren(parent: system, declaration: declaration,
                                    document: assets.json(path), instance: instance, declarationIndex: childIndex)
                                guard reservedParticles + child.reservedParticles <= 4096,
                                      reservedInstances + child.maximumInstances <= 512 else {
                                    throw SceneError.invalid("子粒子总量超过每个父系统 4096 个粒子或 512 个实例的上限。")
                                }
                                guard sceneChildParticleReservations + child.reservedParticles <= 32_768,
                                      sceneChildInstanceReservations + child.maximumInstances <= 4096 else {
                                    throw SceneError.invalid("子粒子总预留超过每场景 32768 个粒子或 4096 个实例的上限。")
                                }
                                if child.usesWorldEmission {
                                    guard worldChildInstanceReservations + child.maximumInstances <= 2048 else {
                                        throw SceneError.invalid("世界坐标子实例超过每场景 2048 个名额的上限。")
                                    }
                                }
                                let childPasses = try material(child.materialPath, particle: true)
                                guard childPasses.count == 1, childPasses[0].framebufferSlots.isEmpty else {
                                    throw SceneError.invalid("子粒子仅支持单 pass，且不能读取场景帧缓冲。")
                                }
                                if let texture = childPasses.first?.textures[0] {
                                    try child.configureTexture(texture.animation, width: texture.width, height: texture.height, imageWidth: texture.imageWidth, imageHeight: texture.imageHeight)
                                }
                                if child.requiresEmitterHistory, !system.tracksEmitterTransforms {
                                    guard emitterHistoryReservations < 64 else { throw SceneError.invalid("子粒子需要的发射器历史超过每场景 64 份上限。") }
                                    system.enableEmitterTransformHistory(); emitterHistoryReservations += 1
                                }
                                reservedParticles += child.reservedParticles; reservedInstances += child.maximumInstances
                                sceneChildParticleReservations += child.reservedParticles
                                sceneChildInstanceReservations += child.maximumInstances
                                child.activate()
                                if child.usesWorldEmission { worldChildInstanceReservations += child.maximumInstances }
                                for warning in child.warnings { note("\(name) child[\(childIndex)]: \(warning)") }
                                draws.append(SceneDraw(name: name + " child[\(childIndex)]", geometry: SceneGeometry(vertices: [], particles: true),
                                    transform: transform, fullscreen: false, copyBackground: false, passes: childPasses, particles: nil, particleChildren: child))
                            } catch { note("未加载子粒子 \(name)[\(childIndex)]：\(error.localizedDescription)") }
                        }
                    } else { note("\(name)：children 格式无效或超过 16 项，子粒子未加载。") }
                }
            } else if let image = object["image"] as? String {
                let builtinProjectLayer = image.lowercased(with: Locale(identifier: "en_US_POSIX")) == "models/util/projectlayer.json" && !assets.contains(image)
                if builtinProjectLayer {
                    draws.append(try projectLayer(object: object, name: name, objectPath: objectPath))
                    handledImageEffects = true
                } else if image == "models/util/composelayer.json", !potentiallyVisible(object["visible"]) {
                    // Invisible, solid Compose layers are also authored input
                    // regions. Their scripts are collected independently.
                    continue
                } else if image == "models/util/composelayer.json" {
                    draws.append(try compositionLayer(object: object, name: name, objectPath: objectPath))
                    handledImageEffects = true
                } else if image != "models/util/fullscreenlayer.json" {
                    let model = image == "models/util/solidlayer.json" && !assets.contains(image)
                        ? ["solidlayer": true, "material": "materials/util/solidlayer.json"] as [String: Any]
                        : try assets.json(image)
                    guard let path = model["material"] as? String else { throw SceneError.invalid("\(name): Image 模型缺少 material：\(image)") }
                    if model["fullscreen"] as? Bool == true {
                        draws.append(SceneDraw(name: name, geometry: imageQuad, transform: matrix_identity_float4x4, fullscreen: true, copyBackground: object["copybackground"] as? Bool == true, passes: try material(path), particles: nil))
                    } else {
                        var draw = try imageLayer(object: object, model: model, materialPath: path, name: name, objectPath: objectPath)
                        if let raw = model["puppet"], !(raw is NSNull) {
                            let resource = (raw as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "未识别的模型资源"
                            do {
                                guard let puppetPath = raw as? String, !puppetPath.isEmpty,
                                      let layers = object["animationlayers"] as? [[String: Any]],
                                      (object["effects"] as? [Any] ?? []).isEmpty,
                                      let image = draw.imageLayer, image.stages.isEmpty, image.colorBlendMode == 0,
                                      draw.passes.count == 1, draw.passes[0].usesSceneTransforms else {
                                    throw SceneError.invalid("仅支持直接绘制、无图片效果且具有一个静态动画层的木偶图层。")
                                }
                                let puppetModel = try NativePuppetModel.decode(assets.data(puppetPath))
                                guard puppetModel.shapes.count == 1, let shape = puppetModel.shapes.first,
                                      shape.materialPath.lowercased() == path.lowercased() else {
                                    throw SceneError.invalid("木偶当前仅支持一个与图片相同材质的网格。")
                                }
                                let vertexCount = shape.vertices.count / 20
                                let clipBytes = puppetModel.clips.reduce(0) { total, clip in
                                    total + clip.tracks.reduce(0) { $0 + $1.count * MemoryLayout<NativePuppetModel.Key>.stride }
                                }
                                guard vertexCount <= 100_000 - puppetVerticesReserved,
                                      clipBytes <= 32 * 1024 * 1024 - puppetAnimationBytesReserved else {
                                    throw SceneError.invalid("木偶网格或动画数据超过当前场景预算。")
                                }
                                let player = try NativePuppetAnimation(model: puppetModel, layers: layers)
                                let vertices = try player.imageVertices(shape: shape, at: 0)
                                draw.geometry = SceneGeometry(vertices: vertices, indices: shape.indices)
                                draw.puppet = player
                                puppetVerticesReserved += vertexCount; puppetAnimationBytesReserved += clipBytes
                                if !shape.clippingMasks.isEmpty {
                                    do {
                                        let original = draw.passes[0]
                                        guard let shaderName = original.definition["shader"] as? String,
                                              ["genericimage2", "genericimage4"].contains(shaderName),
                                              !assets.contains("shaders/\(shaderName).vert"),
                                              !assets.contains("shaders/\(shaderName).frag"),
                                              let base = original.textures[0], base.animation == nil,
                                              base.width == base.imageWidth, base.height == base.imageHeight,
                                              original.textures.keys.allSatisfy({ $0 == 0 }),
                                              original.framebufferSlots.isEmpty, original.layerCompositeSlots.isEmpty else {
                                            throw SceneError.invalid("当前遮罩路径要求无动画图集的原生图片材质和单一原始纹理。")
                                        }
                                        let plan = try NativePuppetClipPlan(shape: shape, boneOrder: puppetModel.secondBoneTable)
                                        guard shape.clippingMasks.count <= 16 - puppetMasksReserved else {
                                            throw SceneError.invalid("木偶遮罩超过当前场景 16 次合成的预算。")
                                        }
                                        for mask in shape.clippingMasks {
                                            let path = mask.resource.hasSuffix(".tex") ? mask.resource : "materials/\(mask.resource).tex"
                                            guard assets.contains(path) else { throw SceneError.invalid("缺少作者遮罩纹理：\(path)") }
                                        }
                                        let masks = try shape.clippingMasks.map { try texture($0.resource) }
                                        if puppetMaskShader == nil {
                                            puppetMaskShader = try SceneShader(vertex: Self.nativeImageVertex,
                                                fragment: Self.puppetMaskFragment, label: "native puppet mask")
                                        }
                                        if puppetClippedShader == nil {
                                            let clipped = "uniform sampler2D g_NativePuppetMask;\nuniform vec2 g_NativeMaskResolution;\n" +
                                                Self.nativeImageFragment.replacingOccurrences(of: "gl_FragColor = color;",
                                                    with: "color.a *= texture(g_NativePuppetMask, gl_FragCoord.xy / g_NativeMaskResolution).r; gl_FragColor = color;")
                                            puppetClippedShader = try SceneShader(vertex: Self.nativeImageVertex,
                                                fragment: clipped, label: "native puppet clipped image")
                                        }
                                        var maskPass = original, clippedPass = original
                                        maskPass.shader = puppetMaskShader!; clippedPass.shader = puppetClippedShader!
                                        draw.puppetClip = ScenePuppetClip(plan: plan, textures: masks,
                                                                         maskPass: maskPass, clippedPass: clippedPass)
                                        puppetMasksReserved += shape.clippingMasks.count
                                        note("\(name)：有限的非嵌套木偶遮罩按作者网格范围分组；排序与混合仍为研发实现，Windows 一致性未验证。")
                                    } catch {
                                        note("\(name)：木偶遮罩未进入有限路径（\(error.localizedDescription)）；继续绘制未裁剪网格。")
                                    }
                                }
                                note("\(name)：单动画层的木偶网格使用 CPU 骨骼插值；附加矩阵及骨约束语义尚未实现，图层外观为研发近似。")
                            } catch {
                                note("\(name)：Puppet Warp 资源 \(resource) 未进入网格路径（\(error.localizedDescription)）；继续使用静态图片近似。")
                            }
                        }
                        draws.append(draw)
                        handledImageEffects = true
                    }
                }
            } else if object["text"] != nil {
                draws.append(try textLayer(object: objectState(objectIndex), authored: object, name: name, objectPath: objectPath))
                handledImageEffects = true
            } else if object["shape"] != nil {
                draws.append(try shapeLayer(object: object, name: name, objectPath: objectPath))
                handledImageEffects = true
            } else {
                throw SceneError.invalid("\(name): 场景对象类型尚未支持。")
            }
            if !handledImageEffects, let effects = object["effects"] as? [[String: Any]] {
                for (effectIndex, effect) in effects.enumerated() where potentiallyVisible(effect["visible"]) {
                    guard object["image"] as? String == "models/util/fullscreenlayer.json" else { throw SceneError.invalid("\(name): 单个图层的离屏效果尚未实现。") }
                    guard let path = effect["file"] as? String else { throw SceneError.invalid("\(name): 效果缺少文件路径。") }
                    let definition = try assets.json(path)
                    let overrides = effect["passes"] as? [[String: Any]] ?? []
                    guard let passes = definition["passes"] as? [[String: Any]] else { throw SceneError.invalid("\(path): 效果缺少 passes。") }
                    for (index, pass) in passes.enumerated() {
                        guard let path = pass["material"] as? String else { throw SceneError.invalid("\(name): 效果 pass 缺少 material。") }
                        do {
                            let materialPasses = try material(path, override: overrides.indices.contains(index) ? overrides[index] : [:], framebuffer: true, scriptPrefix: objectPath + "/effects/\(effectIndex)/passes/\(index)").map { original -> ScenePass in
                                var pass = original; pass.visibility = effect["visible"]; pass.visibilityPath = objectPath + "/effects/\(effectIndex)/visible"; return pass
                            }
                            let topLeft = materialPasses.allSatisfy { $0.mipmappedFramebufferSlots.isEmpty }
                            guard topLeft || materialPasses.allSatisfy({ $0.layerCompositeSlots.isEmpty }) else {
                                throw SceneError.invalid("全屏材质同时读取图层纹理与历史 mip 帧缓冲的坐标组合尚未实现。")
                            }
                            draws.append(SceneDraw(name: name + " effect", geometry: topLeft ? imageQuad : screenQuad, transform: matrix_identity_float4x4, fullscreen: true, copyBackground: true, passes: materialPasses, particles: nil, topLeftFullscreen: topLeft))
                        } catch {
                            // Keep a visible compatibility record instead of silently claiming fidelity.
                            note("跳过不兼容效果 \(path)：\(error.localizedDescription)")
                        }
                    }
                }
            }
            for drawIndex in firstDraw..<draws.count { draws[drawIndex].objectIndex = objectIndex }
            if object["model"] is String {
                modelInstanceCount += 1
                if draws[firstDraw..<draws.count].contains(where: { $0.skeleton != nil }) { skinnedModelInstanceCount += 1 }
            }
            } catch {
                failedLayerCount += 1
                draws.removeSubrange(firstDraw..<draws.count)
                (emitterHistoryReservations, worldChildInstanceReservations,
                    sceneChildParticleReservations, sceneChildInstanceReservations) = reservationsBeforeObject
                note("未加载图层 \(name)：\(error.localizedDescription)")
            }
        }
        guard !strictResourcePreparation || failedLayerCount == 0 else {
            throw SceneError.invalid("场景变更的图层资源未完整准备，保留原场景。" + diagnostics.suffix(8).joined(separator: "\n"))
        }
        // A scene can start with only transform nodes and create its first
        // drawable from an init callback. Its clear frame is still valid.
        let hasTransformNode = objects.enumerated().contains { index, object in
            (activeSlots?.contains(index) ?? true) && NativeSceneTransformNode.matches(object)
        }
        guard !draws.isEmpty || strictResourcePreparation || hasTransformNode else { throw SceneError.invalid("没有可渲染图层。" + diagnostics.prefix(8).joined(separator: "\n")) }
        sounds.sort { $0.objectIndex < $1.objectIndex }
        configureLayerComposites(objects: objects)
        let general = scene["general"] as? [String: Any] ?? [:]
        if sceneHDR {
            note("HDR 泛光接入 RGBA16F 多级缓冲、阈值柔化、散射和加法回升；独立读取 bloomhdr 参数。最终为 SDR 输出，尚未与 Windows 逐像素对齐。")
        } else {
            note("普通泛光按参考资源与 REA 静态依据接入：四点提取、亮度门控、颜色和 13 点双向模糊；作者开关、强度、阈值、颜色支持用户参数、属性脚本及时间轴，尚未与 Windows 逐像素对齐。")
        }
        if potentiallyVisible(general["cameraparallax"]), general["cameraparallax"] != nil {
            note("视差按有效场景帧采样并在暂停时冻结；2D 将父对象偏移应用到逐层视图，3D 在基础相机后绕 eye 按 up/right 顺序旋转。矩阵组合有 REA 依据，macOS 鼠标、delay 和画布映射仍为兼容策略；传感器与额外 fit-mode 分支未适配。")
        }
        if general["orthogonalprojection"] is [String: Any] {
            note("2D 场景按项目分辨率居中并填满屏幕；无活动 Camera 对象和旧版路径时重置基础相机。参考库额外缩放因子尚未复现。")
        }
        note("Scene 支持范围：静态 MDL、已实现骨架格式的默认姿态、自带 GLSL、图片及离屏效果、全屏图层、已实现的粒子与 SceneScript 接口；木偶支持单循环动画层的有限路径；普通模型已接入受支持的密集骨骼动画、多层混合、动画层脚本及事件。模型外部材质的已消费数值参数支持属性脚本与曲线；约束、IK 和完整模型功能仍需适配。")
    }

    private func modelShapes(_ path: String) throws -> [ModelShape] {
        let key = path.lowercased()
        if let cached = modelResources[key] { return try cached.get() }
        guard modelResources.count < 512 else { throw SceneError.invalid("模型资源超过每场景 512 份上限。") }
        let result: Result<[ModelShape], Error> = Result {
            let model: SceneModel
            if let decoded = preparedModels[key] {
                model = decoded; creationPreparationStatistics?.modelCacheHits += 1
            } else {
                model = try SceneModel.decode(assets.data(path)); creationPreparationStatistics?.modelFallbackDecodes += 1
            }
            let meshes = model.meshes
            let bytes = meshes.reduce(0) { $0 + $1.byteCount }
            guard bytes <= 128 * 1024 * 1024 - modelBufferBytes else {
                throw SceneError.invalid("模型几何缓冲超过每场景 128 MiB 上限。")
            }
            let animationBytes = model.skeleton?.animationBytes ?? 0
            guard animationBytes <= 32 * 1024 * 1024 - modelAnimationBytes else {
                throw SceneError.invalid("模型动画数据超过每场景 32 MiB 上限。")
            }
            var sharedMaterials: [String: [ScenePass]] = [:]
            let materialPaths = NativeModelMaterials.paths(model)
            let shapes = try meshes.map { mesh in
                let passes: [ScenePass]
                if let cached = sharedMaterials[mesh.materialPath] { passes = cached }
                else {
                    let materialIndex = materialPaths.firstIndex { $0.lowercased() == mesh.materialPath.lowercased() }!
                    passes = try material(mesh.materialPath, scriptPrefix: "/\(NativeModelMaterials.key)/\(materialIndex)/passes",
                        boneCount: model.skeleton?.bones.count ?? 0, indexedMaterialPasses: true)
                    sharedMaterials[mesh.materialPath] = passes
                }
                return ModelShape(geometry: SceneGeometry(vertices: mesh.vertices, indices: mesh.indices, skinned: model.skeleton != nil),
                    passes: passes, skeleton: model.skeleton, bounds: NativePointShadows.Bounds(vertices: mesh.vertices, skeleton: model.skeleton))
            }
            modelBufferBytes += bytes
            modelAnimationBytes += animationBytes
            modelShapeCount += meshes.count
            modelResourceSizes[key] = (bytes, animationBytes, meshes.count, model.skeleton == nil ? 0 : 1)
            let detail = meshes.map { "\($0.vertexCount) 顶点 / \($0.indices.count / 3) 三角形 / 原始 \($0.sourceIndexBits) 位索引" }.joined(separator: "; ")
            note("\(path)：\(meshes.count) 个网格，\(detail)；几何和材质由所有实例共用。")
            if let skeleton = model.skeleton {
                skeletonResourceCount += 1
                let clips = skeleton.clips.map { "id=\($0.id)，\($0.frameCount) 帧 / \($0.fps) fps / \($0.mode)" }.joined(separator: "; ")
                note("\(path)：\(skeleton.bones.count) 节骨架、4 权重 GPU 蒙皮；默认姿态按父级世界矩阵×逆绑定矩阵生成，单位矩阵最大残差 \(skeleton.defaultPaletteIdentityError)。\(skeleton.clips.count) 段内嵌动画已读取：\(clips)。无 animationlayers 时保持默认姿态；已声明的受支持层使用独立时钟和绑定姿态相对混合。")
            }
            return shapes
        }
        modelResources[key] = result
        return try result.get()
    }

    private func imageLayer(object: [String: Any], model: [String: Any], materialPath: String, name: String, objectPath: String) throws -> SceneDraw {
        let basePasses: [ScenePass]
        if model["solidlayer"] as? Bool == true {
            let instance = object["instance"] as? [String: Any] ?? [:]
            let builtin: [String: Any] = ["passes": [["shader": "genericimage2", "combos": ["version": 2],
                "textures": ["util/white"], "blending": "translucent", "cullmode": "nocull", "depthtest": "disabled", "depthwrite": "disabled"]]]
            basePasses = try material(materialPath, override: instance, supplied: assets.contains(materialPath) ? nil : builtin)
            note("\(name): solidlayer 使用原生矩形、颜色、透明度及图片效果链。")
        } else { basePasses = try material(materialPath) }
        guard !basePasses.isEmpty else { throw SceneError.invalid("\(name): 图片材质为空。") }
        var size = SceneValues.floats(object["size"])
        // Image model documents may declare an explicit quad size. The scene
        // instance takes precedence; autosize is the final texture-size fallback.
        if size.count < 2, model["width"] != nil, model["height"] != nil {
            size = [SceneValues.number(model["width"], 0), SceneValues.number(model["height"], 0)]
        }
        if size.count < 2, model["autosize"] as? Bool == true, let texture = basePasses.first?.textures[0] {
            size = [Float(texture.animation?.width ?? texture.imageWidth), Float(texture.animation?.height ?? texture.imageHeight)]
        }
        guard size.count >= 2, size.prefix(2).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 16384 }) else {
            throw SceneError.invalid("\(name): 图片尺寸缺失或超过 16384。")
        }
        var draw = try composeImage(object: object, basePasses: basePasses, size: size, name: name, objectPath: objectPath)
        draw.alignmentOffset = try imageAlignment(object["alignment"], size: size)
        return draw
    }

    private func shapeLayer(object: [String: Any], name: String, objectPath: String) throws -> SceneDraw {
        guard object["shape"] as? String == "quad", object["size"] == nil,
              let projection = (scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Any],
              projection["auto"] as? Bool != true,
              let rawHeight = projection["height"] as? NSNumber else {
            throw SceneError.invalid("\(name): shape 当前支持显式 2D 场景尺寸下的默认 quad。")
        }
        guard let integerHeight = Int(exactly: rawHeight.doubleValue), (1...16384).contains(integerHeight) else {
            throw SceneError.invalid("\(name): shape 场景高度必须是 1–16384 的整数。")
        }
        let height = Float(integerHeight)
        guard let effects = object["effects"] as? [[String: Any]], effects.count == 1,
              let path = effects[0]["file"] as? String else {
            throw SceneError.invalid("\(name): shape 当前需要单个直接绘制效果；多效果链仍待实现。")
        }
        let effect = effects[0], document = try assets.json(path)
        guard let definitions = document["passes"] as? [[String: Any]], definitions.count == 1,
              let materialPath = definitions[0]["material"] as? String else {
            throw SceneError.invalid("\(name): shape 当前需要单个材质 pass。")
        }
        let graph = try SceneEffectGraph(document: document, namespace: "shape", hdr: false)
        guard graph.targets.isEmpty, graph.passes.count == 1,
              graph.passes[0].bindings.isEmpty, graph.passes[0].target == nil else {
            throw SceneError.invalid("\(name): shape 命名缓冲和间接效果仍待实现。")
        }
        let overrides = effect["passes"] as? [[String: Any]] ?? []
        guard overrides.count <= 1 else { throw SceneError.invalid("\(name): shape pass 覆盖数量不匹配。") }
        var override = overrides.first ?? [:]
        var combos = override["combos"] as? [String: Any] ?? [:]
        combos["DIRECTDRAW"] = 1
        override["combos"] = combos
        // The observed ShapeLayer forces the final material to additive mode.
        override["blending"] = "additive"
        var passes = try material(materialPath, override: override,
                                  scriptPrefix: objectPath + "/effects/0/passes/0")
        guard passes.count == 1, passes[0].framebufferSlots.isEmpty,
              passes[0].shader.location("g_Texture0") < 0,
              passes[0].shader.location("g_ModelViewProjectionMatrix") >= 0,
              passes[0].shader.resolvedCombos["DIRECTDRAW"] == 1 else {
            throw SceneError.invalid("\(name): shape 需要独立生成颜色且使用图层矩阵的 DIRECTDRAW 着色器。")
        }
        passes[0].visibility = effect["visible"]
        passes[0].visibilityPath = objectPath + "/effects/0/visible"
        passes[0].effectGroup = 0
        let points = try shapePoints(uniforms: resolvedUniforms(pass: passes[0], object: object))
        let geometry = SceneGeometry.shapeQuad(points: points, height: height)
        fputs("Scene shape loaded: \(name), quad, canvas-height \(height), points \(points), additive, DIRECTDRAW=1\n", stderr)
        note("\(name): quad 几何与加法合成按官方 Android 静态分析接入；内置噪声仍是自研近似，尚未与 Windows 原版逐像素核对。")
        return SceneDraw(name: name, geometry: geometry, transform: SceneValues.transform(object),
                         fullscreen: false, copyBackground: false, passes: passes, particles: nil, shapeHeight: height)
    }

    private func shapePoints(uniforms: [String: [Float]]) throws -> [SIMD2<Float>] {
        let points = try (0..<4).map { index -> SIMD2<Float> in
            guard let value = uniforms["g_Point\(index)"], value.count == 2,
                  value.allSatisfy({ $0.isFinite && abs($0) <= 32 }) else {
                throw SceneError.invalid("shape 四角必须是有限的 point0–point3，分量绝对值不超过 32。")
            }
            return SIMD2(value[0], value[1])
        }
        // An inverted or singular homography has no usable shape surface. Skip
        // that frame instead of passing its inverse NaNs into the shader.
        let spanX = points.map(\.x).max()! - points.map(\.x).min()!
        let spanY = points.map(\.y).max()! - points.map(\.y).min()!
        let extent = max(spanX, spanY)
        let minimumTurn = max(Float(0.0000001), extent * extent * 0.000001)
        guard spanX >= 0.0001, spanY >= 0.0001 else {
            throw SceneError.invalid("shape 四角跨度过小，该帧不绘制。")
        }
        let turns = (0..<4).map { index -> Float in
            let a = points[(index + 1) % 4] - points[index]
            let b = points[(index + 2) % 4] - points[(index + 1) % 4]
            return a.x * b.y - a.y * b.x
        }
        guard turns.allSatisfy({ $0 > minimumTurn }) || turns.allSatisfy({ $0 < -minimumTurn }) else {
            throw SceneError.invalid("shape 四角退化、自交或接近奇异，该帧不绘制。")
        }
        return points
    }

    private func imageAlignment(_ value: Any?, size: [Float]) throws -> SIMD2<Float> {
        switch value as? String ?? "center" {
        case "center": return .zero
        case "left": return SIMD2(size[0] / 2, 0)
        case "right": return SIMD2(-size[0] / 2, 0)
        case "top": return SIMD2(0, -size[1] / 2)
        case "bottom": return SIMD2(0, size[1] / 2)
        default: throw SceneError.invalid("尚未支持图片 alignment：\(String(describing: value))")
        }
    }

    private func composeImage(object: [String: Any], basePasses: [ScenePass], size: [Float], name: String, objectPath: String, privateTargets: Bool = false, captureScene: Bool = false) throws -> SceneDraw {
        let blendMode: Int
        if let raw = object["colorBlendMode"], !(raw is NSNull) {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = Int(exactly: number.doubleValue), NativeBlendModes.supports(value) else {
                throw SceneError.invalid("\(name)：colorBlendMode 需要已支持的静态整数 0–32。")
            }
            blendMode = value
        } else { blendMode = 0 }
        let imageColor = SceneValues.vector(object["color"], SIMD3(repeating: 1))
        let opacity = max(0, min(1, SceneValues.number(object["alpha"] ?? object["opacity"], 1)))
        var stages = basePasses.map { pass -> ScenePass in
            var uniforms = pass.uniforms
            uniforms["g_NativeImageColor"] = [imageColor.x, imageColor.y, imageColor.z]
            uniforms["g_NativeImageOpacity"] = [opacity]
            var result = pass
            result.uniforms = uniforms
            return result
        }
        let effects = object["effects"] as? [[String: Any]] ?? []
        var targetSpecs: [String: SceneEffectTargetSpec] = [:]
        var historyTargets = Set<String>()
        guard effects.count <= 64 else { throw SceneError.invalid("\(name): 图片效果超过 64 个。") }
        for (effectIndex, effect) in effects.enumerated() where preparesScriptEffects || potentiallyVisible(effect["visible"]) {
            let path = effect["file"] as? String ?? "(未指定)"
            do {
                guard effect["file"] is String else { throw SceneError.invalid("\(name): 图片效果缺少路径。") }
                let document = try assets.json(path)
                guard let passes = document["passes"] as? [[String: Any]], passes.count <= 32 else { throw SceneError.invalid("\(path): 图片效果 passes 无效。") }
                let overrides = effect["passes"] as? [[String: Any]] ?? []
                let graph = try SceneEffectGraph(document: document, namespace: String(effectIndex), hdr: (scene["general"] as? [String: Any])?["hdr"] as? Bool == true)
                var effectStages: [ScenePass] = []
                for (index, pass) in passes.enumerated() {
                    let wiring = graph.passes[index]
                    if case let .copy(source) = wiring.command {
                        guard let target = wiring.target else { throw SceneError.invalid("\(path): copy 缺少 target。") }
                        var copy = ScenePass(shader: imageCopyShader, definition: [:], textures: [:], framebufferSlots: [], uniforms: [:])
                        copy.visibility = effect["visible"]; copy.visibilityPath = objectPath + "/effects/\(effectIndex)/visible"
                        copy.effectGroup = effectIndex; copy.graphTarget = target; copy.graphCopySource = source
                        effectStages.append(copy)
                        continue
                    }
                    guard let materialPath = pass["material"] as? String else { throw SceneError.invalid("\(path): 效果 pass 缺少 material。") }
                    let compiled = try material(materialPath, override: overrides.indices.contains(index) ? overrides[index] : [:], framebuffer: true, scriptPrefix: objectPath + "/effects/\(effectIndex)/passes/\(index)", boundSlots: Set(wiring.bindings.keys))
                    guard compiled.count == 1 || (graph.targets.isEmpty && wiring.bindings.isEmpty) else { throw SceneError.invalid("命名缓冲的效果 pass 当前需要单个材质 pass。") }
                    effectStages += compiled.map { original -> ScenePass in
                        var pass = original
                        pass.visibility = effect["visible"]; pass.visibilityPath = objectPath + "/effects/\(effectIndex)/visible"
                        pass.effectGroup = effectIndex; pass.graphTarget = wiring.target; pass.graphBindings = wiring.bindings
                        return pass
                    }
                    guard stages.count + effectStages.count <= 128 else { throw SceneError.invalid("\(name): 图片渲染阶段超过 128 个。") }
                }
                // A multipass effect is a single operation. Keeping only its
                // downsample or horizontal half after another pass fails would
                // corrupt the input to every subsequent effect.
                stages += effectStages
                targetSpecs.merge(graph.targets) { old, _ in old }
                historyTargets.formUnion(graph.historyTargets)
                let audioResolutions = [16,32,64].filter { resolution in
                    effectStages.contains { $0.shader.location("g_AudioSpectrum\(resolution)Left[0]") >= 0 || $0.shader.location("g_AudioSpectrum\(resolution)Right[0]") >= 0 }
                }
                fputs("Scene image effect loaded: \(name), \(path), \(effectStages.count) passes, audio arrays \(audioResolutions)\n", stderr)
            } catch {
                note("\(name): 完整跳过不兼容图片效果 \(path)，保留进入该效果前的图像：\(error.localizedDescription)")
            }
        }
        let copyShader: SceneShader
        let needsBackdrop = blendMode != 0 && blendMode != 31
        let finalBlend = blendMode == 31 ? "additive" : (basePasses.first?.definition["blending"] as? String ?? "translucent")
        if needsBackdrop {
            if let cached = imageBlendShaders[blendMode] { copyShader = cached }
            else {
                copyShader = try SceneShader(vertex: Self.imageBlendVertex, fragment: Self.imageBlendFragment,
                    combos: ["BLENDMODE": blendMode], label: "native image blend \(blendMode)", sceneHDR: sceneHDR)
                imageBlendShaders[blendMode] = copyShader
            }
            note("\(name)：colorBlendMode=\(blendMode)（\(NativeBlendModes.names[blendMode])）在图层效果完成后与此前场景合成；尚未与 Windows 输出逐像素对齐。")
            if !effects.isEmpty { note("\(name)：颜色混合使用图层矩形内的效果结果，顶点效果超出矩形的部分仍可能裁切。") }
        } else {
            copyShader = imageCopyShader
            if blendMode == 31 { note("\(name)：colorBlendMode=31 按 REA 静态确认的分支使用普通着色器及 GPU 加法混合，不读取背景。") }
        }
        let copyPass = ScenePass(shader: copyShader, definition: ["blending": finalBlend], textures: [:], framebufferSlots: [0], uniforms: ["g_Brightness": [1], "g_NativeImageOpacity": [1], "g_NativeImageColor": [1,1,1], "g_NativeTextOpaque": [0]], applyObjectAppearance: captureScene)
        if captureScene || needsBackdrop || stages.last?.usesSceneTransforms == false {
            // Always capture into an intermediate first, even if all authored
            // effects are hidden. Sampling the destination scene texture while
            // drawing into it would be undefined framebuffer feedback.
            guard stages.count < 128 else { throw SceneError.invalid("合成图层阶段超过 128 个。") }
            stages.append(copyPass)
        }
        let last = stages.removeLast()
        var layerTargets: [SceneTarget] = []
        var namedTargets: [String: SceneTarget] = [:]
        if !stages.isEmpty {
            let factor = min(1, 4096 / max(size[0], size[1]))
            let width = max(1, Int(ceil(size[0] * factor))), height = max(1, Int(ceil(size[1] * factor)))
            let key = "\(width)x\(height)"
            // One intermediate needs one target; two need two. Three are only
            // necessary when a longer effect retains its original input while
            // subsequent stages alternate. Named outputs have their own targets.
            let workingCount = max(1, min(3, stages.filter { $0.graphTarget == nil }.count))
            let cached = privateTargets ? [] : (imageTargetPool[key] ?? [])
            let additionalCount = max(0, workingCount - cached.count)
            let namedPixels = targetSpecs.values.reduce(0) { total, spec in let (w,h) = spec.dimensions(width: width, height: height); return total + w*h }
            let additionalPixels = width * height * additionalCount + namedPixels
            guard layerTargetPixels + additionalPixels <= layerTargetPixelLimit else { throw SceneError.invalid("图片及命名效果缓冲超过当前 \(layerTargetLimitDescription) 像素上限。") }
            let expanded = cached + (try (0..<additionalCount).map { _ in try SceneTarget(width: width, height: height, withDepth: false, hdr: sceneHDR) })
            namedTargets = try makeNamedTargets(targetSpecs, historyTargets: historyTargets, width: width, height: height)
            // Publish allocations only after all buffers for the layer succeed.
            if !privateTargets { imageTargetPool[key] = expanded }
            layerTargets = Array(expanded.prefix(workingCount))
            layerTargetPixels += additionalPixels
            if !namedTargets.isEmpty {
                let layouts = namedTargets.keys.sorted().map { key in
                    "\(key)=\(namedTargets[key]!.width)x\(namedTargets[key]!.height) \(targetSpecs[key]!.hdr ? "RGBA16F" : "RGBA8") from \(targetSpecs[key]!.authoredFormat)"
                }.joined(separator: ", ")
                fputs("Scene effect buffers: \(name), \(layouts)\n", stderr)
            }
            // Working buffers may be shared. Published cross-layer results use
            // dedicated targets that survive until all consumers finish.
            if factor < 1 { note("\(name): 离屏图片效果缩小到最长边 4096 像素。") }
        }
        // A top-left texture convention is retained inside the layer, including
        // masks loaded from TEX files. Flipping the local projection writes its
        // top row to GL texture row 0; scene composition uses the normal Y axis.
        let projection = simd_float4x4(diagonal: SIMD4(2 / size[0], -2 / size[1], -2 / 10000, 1))
        return SceneDraw(name: name, geometry: SceneGeometry.quad(width: size[0], height: size[1]), transform: SceneValues.transform(object), fullscreen: false, copyBackground: false, passes: [last], particles: nil, imageLayer: SceneImageLayer(targets: layerTargets, stages: stages, projection: projection, blending: finalBlend, targetSpecs: targetSpecs, namedTargets: namedTargets, historyTargets: historyTargets, copyPass: copyPass, colorBlendMode: blendMode), captureBackground: captureScene)
    }

    private func makeNamedTargets(_ specs: [String: SceneEffectTargetSpec], historyTargets: Set<String>, width: Int, height: Int) throws -> [String: SceneTarget] {
        var result: [String: SceneTarget] = [:]
        for (key, spec) in specs {
            let (w,h) = spec.dimensions(width: width, height: height)
            let target = try SceneTarget(width: w, height: h, withDepth: false, hdr: spec.hdr)
            if historyTargets.contains(key) { target.clearHistory() }
            result[key] = target
        }
        return result
    }

    private func textLayer(object: [String: Any], authored: [String: Any], name: String, objectPath: String) throws -> SceneDraw {
        guard textLayerCount < 32 else { throw SceneError.invalid("文字图层超过当前 32 层上限。") }
        let layout = try SceneTextLayout(object: authored, assets: assets, builtinFonts: builtinFonts)
        guard let bitmap = try layout.rasterize(object) else { throw SceneError.invalid("文字位图未初始化。") }
        let pixels = bitmap.width * bitmap.height
        guard textPixelCount + pixels <= 8 * 1024 * 1024, textureBytes + pixels * 4 <= 256 * 1024 * 1024 else { throw SceneError.invalid("文字纹理超过合计 8M 像素或场景 256 MiB 上限。") }
        let texture = SceneGLTexture(width: bitmap.width, height: bitmap.height, rgba: bitmap.rgba, repeating: false)
        let shader = try SceneShader(vertex: Self.nativeImageVertex, fragment: Self.nativeImageFragment, label: "native text")
        let pass = ScenePass(shader: shader, definition: ["blending": "translucent", "depthtest": object["depthtest"] ?? "disabled"],
                             textures: [0: texture], framebufferSlots: [], uniforms: ["g_Brightness": [1]])
        var draw = try composeImage(object: object, basePasses: [pass], size: [Float(bitmap.width), Float(bitmap.height)], name: name, objectPath: objectPath, privateTargets: true)
        draw.text = try SceneTextState(layout: layout, texture: texture, offset: bitmap.offset, object: object)
        if !isOrthogonalScene, !["none", "center"].contains(object["anchor"] as? String ?? "none") {
            note("\(name)：三维相机的文字屏幕锚点尚未实现；当前仅补偿二维居中填充裁切。")
        }
        textPixelCount += pixels; textureBytes += pixels * 4; textLayerCount += 1
        for warning in layout.diagnostics { note("\(name)：\(warning)") }
        fputs("Scene text loaded: \(name), \(bitmap.width)x\(bitmap.height), \(draw.imageLayer?.stages.count ?? 0) effect stages\n", stderr)
        return draw
    }

    private func compositionLayer(object: [String: Any], name: String, objectPath: String) throws -> SceneDraw {
        guard let config = object["config"] as? [String: Any], config["passthrough"] as? Bool == true else {
            throw SceneError.invalid("\(name)：当前合成图层仅支持 passthrough=true 的场景区域采样。")
        }
        let size = SceneValues.floats(object["size"])
        guard size.count >= 2, size.prefix(2).allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 16384 }) else { throw SceneError.invalid("合成图层尺寸无效。") }
        let shader = try SceneShader(vertex: Self.compositionVertex, fragment: Self.compositionFragment, label: "native scene composition")
        let pass = ScenePass(shader: shader, definition: ["blending": "translucent"], textures: [:], framebufferSlots: [0], uniforms: [:])
        let draw = try composeImage(object: object, basePasses: [pass], size: size, name: name, objectPath: objectPath, captureScene: true)
        note("\(name)：合成图层按变换后的范围采样此前已绘制的场景，再应用原始效果；父子合成与全部 config 语义尚未实现。")
        return draw
    }

    /// The recorded engine's built-in project layer carries passthrough and
    /// autosize flags. Its texture-change path uses the scene canvas dimensions
    /// rather than the authored instance size. Other canvas modes need their
    /// own resizing rules, so do not silently treat them as fixed 2D canvases.
    private func projectLayer(object: [String: Any], name: String, objectPath: String) throws -> SceneDraw {
        guard let general = scene["general"] as? [String: Any],
              let projection = general["orthogonalprojection"] as? [String: Any],
              projection["auto"] == nil || projection["auto"] as? Bool == false,
              let rawWidth = projection["width"] as? NSNumber, CFGetTypeID(rawWidth) != CFBooleanGetTypeID(),
              let rawHeight = projection["height"] as? NSNumber, CFGetTypeID(rawHeight) != CFBooleanGetTypeID() else {
            throw SceneError.invalid("\(name)：内置项目层目前需要明确的固定二维画布尺寸。")
        }
        let width = rawWidth.doubleValue, height = rawHeight.doubleValue
        guard width.isFinite, height.isFinite, (1...16384).contains(width), (1...16384).contains(height) else {
            throw SceneError.invalid("\(name)：内置项目层画布尺寸无效。")
        }
        let noEffects = object["effects"] == nil || (object["effects"] as? [Any])?.isEmpty == true
        if noEffects, object["colorBlendMode"] == nil {
            // Capture directly at the output resolution. Routing an identity
            // passthrough through a canvas-sized intermediate resamples a
            // detailed background twice and can blur an otherwise unchanged
            // region. A separate scene target avoids sampling while writing.
            let shader = try SceneShader(vertex: Self.compositionVertex, fragment: Self.compositionFragment, label: "native project passthrough")
            let pass = ScenePass(shader: shader, definition: ["blending": "translucent", "depthtest": "disabled", "depthwrite": "disabled"],
                                 textures: [:], framebufferSlots: [0], uniforms: [:])
            note("\(name)：内置项目层以 \(width)×\(height) 画布尺寸直接透传已有场景；嵌套合成、自动尺寸及原版像素一致性仍待核对。")
            return SceneDraw(name: name, geometry: SceneGeometry.quad(width: Float(width), height: Float(height)),
                             transform: SceneValues.transform(object), fullscreen: false, copyBackground: true,
                             passes: [pass], particles: nil, captureBackground: true)
        }
        var resolved = object
        var config = object["config"] as? [String: Any] ?? [:]
        config["passthrough"] = true
        resolved["config"] = config
        resolved["size"] = "\(width) \(height)"
        let draw = try compositionLayer(object: resolved, name: name, objectPath: objectPath)
        note("\(name)：内置项目层以 \(width)×\(height) 画布尺寸透传已有场景；嵌套合成、自动尺寸及原版像素一致性仍待核对。")
        return draw
    }

    private func updateText(_ index: Int, object: [String: Any]) {
        guard let text = draws[index].text else { return }
        do {
            guard let bitmap = try text.layout.rasterize(object) else { return }
            let oldPixels = text.texture.width * text.texture.height, newPixels = bitmap.width * bitmap.height
            let difference = newPixels - oldPixels
            guard textPixelCount + difference <= 8 * 1024 * 1024, textureBytes + difference * 4 <= 256 * 1024 * 1024 else { throw SceneError.invalid("文字纹理总量超出上限，保留上一帧。") }
            if text.texture.width != bitmap.width || text.texture.height != bitmap.height, var layer = draws[index].imageLayer {
                if !layer.targets.isEmpty {
                    let oldNamed = layer.namedTargets.values.reduce(0) { $0 + $1.width * $1.height }
                    let newNamed = layer.targetSpecs.values.reduce(0) { total, spec in let (w,h) = spec.dimensions(width: bitmap.width, height: bitmap.height); return total + w*h }
                    let targetCount = layer.targets.count
                    let targetDifference = difference * targetCount + newNamed - oldNamed
                    guard layerTargetPixels + targetDifference <= layerTargetPixelLimit else { throw SceneError.invalid("文字离屏缓冲超出场景 \(layerTargetLimitDescription) 像素上限。") }
                    layer.targets = try (0..<targetCount).map { _ in try SceneTarget(width: bitmap.width, height: bitmap.height, withDepth: false, hdr: sceneHDR) }
                    layer.namedTargets = try makeNamedTargets(layer.targetSpecs, historyTargets: layer.historyTargets, width: bitmap.width, height: bitmap.height)
                    layerTargetPixels += targetDifference
                }
                layer.projection = simd_float4x4(diagonal: SIMD4(2 / Float(bitmap.width), -2 / Float(bitmap.height), -2 / 10000, 1))
                draws[index].imageLayer = layer
                draws[index].geometry.resizeQuad(width: Float(bitmap.width), height: Float(bitmap.height))
            }
            text.texture.replace(width: bitmap.width, height: bitmap.height, rgba: bitmap.rgba)
            text.offset = bitmap.offset; text.uploads += 1
            textPixelCount += difference; textureBytes += difference * 4
            for warning in text.layout.diagnostics {
                let message = "\(draws[index].name)：\(warning)"
                if !diagnosticNotes.contains(message) { note(message); fputs("Scene compatibility: \(message)\n", stderr) }
            }
        } catch {
            let message = "\(draws[index].name)：\(error.localizedDescription)"
            if !diagnosticNotes.contains(message) { note(message); fputs("Scene text update: \(message)\n", stderr) }
        }
    }

    private func material(_ path: String, override: [String: Any] = [:], particle: Bool = false, framebuffer: Bool = false, scriptPrefix authoredPrefix: String? = nil, boundSlots: Set<Int> = [], supplied: [String: Any]? = nil, boneCount: Int = 0, indexedMaterialPasses: Bool = false) throws -> [ScenePass] {
        let root = try supplied ?? assets.json(path)
        guard let definitions = root["passes"] as? [[String: Any]], definitions.count <= 32 else { throw SceneError.invalid("\(path): material passes 无效。") }
        return try definitions.enumerated().map { passIndex, original in
            let scriptPrefix = authoredPrefix.map { indexedMaterialPasses ? $0 + "/\(passIndex)" : $0 }
            var definition = original
            for (key, value) in override {
                if let new = value as? [String: Any], let old = definition[key] as? [String: Any] { definition[key] = old.merging(new) { _, n in n } }
                else { definition[key] = value }
            }
            // Resolve system references before shader combinations and sampler
            // slots are established. Null slots retain the authored material.
            if let userTextures = definition["usertextures"] as? [Any] {
                guard userTextures.count <= 8 else { throw SceneError.invalid("\(path): 动态纹理槽位超过 8 个。") }
                var declared = definition["textures"] as? [Any] ?? []
                for (slot, raw) in userTextures.enumerated() where !(raw is NSNull) {
                    guard let reference = raw as? [String: Any], reference["type"] as? String == "system",
                          let name = reference["name"] as? String, ["$mediaThumbnail", "$mediaPreviousThumbnail"].contains(name) else {
                        throw SceneError.invalid("\(path): 此动态纹理引用尚未实现。")
                    }
                    while declared.count <= slot { declared.append(NSNull()) }
                    declared[slot] = name
                }
                definition["textures"] = declared
            }
            guard let name = definition["shader"] as? String else { throw SceneError.invalid("\(path): pass 缺少 shader。") }
            if let blend = definition["blending"] as? String, !["normal", "translucent", "additive"].contains(blend) {
                throw SceneError.invalid("\(path): 尚未实现材质混合方式 \(blend)。")
            }
            if let cull = definition["cullmode"] as? String, !["normal", "nocull"].contains(cull) {
                throw SceneError.invalid("\(path): 尚未实现剔除方式 \(cull)。")
            }
            let shader: SceneShader
            var isNativeModel = false
            if particle && name == "genericparticle" {
                shader = try SceneShader(vertex: Self.particleVertex, fragment: Self.particleFragment, label: "native sprite")
            } else if ["generic4", "chroma4"].contains(name), !assets.contains("shaders/\(name).vert"), !assets.contains("shaders/\(name).frag") {
                var combinations = try NativeModelMaterial.combinations(definition)
                if combinations["NATIVE_LIGHTING"] == 1, combinations["NATIVE_PROJECTION_SOURCE"] != 1,
                   (scene["objects"] as? [[String:Any]] ?? []).contains(where: { SceneValues.visible(propertyValue($0["usecookie"]) ?? false) }) {
                    throw SceneError.invalid("投影灯光资源尚未解析：当前需要受光模型材质在纹理槽 7 显式指定资源。")
                }
                combinations["NATIVE_BONE_COUNT"] = boneCount
                let receiverPlane = combinations["NATIVE_LIGHTING"] == 1
                shader = try SceneShader(vertex: receiverPlane ? NativeModelMaterial.receiverVertex : NativeModelMaterial.vertex,
                    fragment: NativeModelMaterial.fragment, combos: combinations, label: "native " + name, sceneHDR: sceneHDR,
                    geometry: receiverPlane ? NativeModelMaterial.receiverGeometry : nil)
                isNativeModel = true
                if name == "chroma4" { note("原生 Chroma 模型材质：视角着色、Alpha 着色遮罩、高光颜色与噪声颗粒；噪声槽 8 与点光阴影使用独立绑定。") }
                if combinations["NATIVE_LIGHTING"] == 1 && (combinations["NATIVE_RIMLIGHTING"] == 1 || combinations["NATIVE_SHADINGGRADIENT"] == 1) { note("原生模型卡通材质：明暗渐变与边缘光按每盏灯计算；R8/RG88 渐变取红通道，点光和方向光保留不同的漫反射顺序。") }
                note("原生模型贴图：法线=\(combinations["NATIVE_NORMALMAP"] ?? 0)，PBR=\(combinations["NATIVE_PBRMASKS"] ?? 0)，Alpha 着色遮罩=\(combinations["NATIVE_TINTMASKALPHA"] ?? 0)；支持各贴图独立寻址与材质自发光参数。")
                note("generic4 使用自研 GGX 直接照明、半球环境光、距离雾、作者启用的上一帧反射及点光源阴影；最多 \(NativeModelLightFrame.maximumLights) 盏点光/方向光，其中最多 4 盏点光投影。阴影投射仅支持受支持的不透明原生模型，聚光阴影使用单个透视视图；方向光阴影及高度雾尚未实现；点光体积光采用独立原生积分，直接照明 roughness 下限为 0.02；未与 Windows 逐像素对齐。")
                if (definition["combos"] as? [String: Any])?["REFLECTION"] as? Int == 1 {
                    note("\(path)：REFLECTION 读取上一帧、全局泛光之前的完整场景；采用桌面分支的投影法线偏移和 roughness mip 采样。")
                }
            } else if ["genericimage2", "genericimage4"].contains(name),
                      !assets.contains("shaders/\(name).vert"), !assets.contains("shaders/\(name).frag") {
                // Exported native image materials use both VERSION and version.
                // Normalize only this owned fallback, never author shader macros.
                var combos: [String: Int] = [:]
                for (key, rawValue) in definition["combos"] as? [String: Any] ?? [:] {
                    guard let numeric = rawValue as? NSNumber,
                          let value = Int(exactly: numeric.doubleValue) else {
                        throw SceneError.invalid("\(name) 的组合 \(key) 必须是有限整数。")
                    }
                    let canonical = key.lowercased()
                    if let previous = combos[canonical], previous != value {
                        throw SceneError.invalid("\(name) 的组合 \(key) 大小写变体具有冲突值。")
                    }
                    combos[canonical] = value
                }
                guard !combos.contains(where: { key, value in
                    if key == "spritesheet" { return ![0,1].contains(value) }
                    return name == "genericimage2" && key == "version" ? ![0, 1, 2].contains(value) : value != 0
                }) else {
                    throw SceneError.invalid("\(name) 的非默认着色器组合尚未实现。")
                }
                shader = try SceneShader(vertex: Self.nativeImageVertex, fragment: Self.nativeImageFragment, label: "native " + name)
                note("\(name) 使用自研图片采样、亮度、颜色与透明度实现；高级内置变体仍需适配，版本差异尚未与 Windows 原版逐像素核对。")
                if combos["version"] == 2 { note("genericimage2 version 2 使用同一自研基本采样路径；尚未逐像素核对官方版本差异。") }
            } else {
                let comboValues = definition["combos"] as? [String: Any] ?? [:]
                var combos = comboValues.compactMapValues { ($0 as? NSNumber)?.intValue }
                // An omitted opacity mask means the optional mask branch is disabled.
                if combos["MASK"] == nil { combos["MASK"] = 0 }
                let vertex = try shaderSource("shaders/\(name).vert"), fragment = try shaderSource("shaders/\(name).frag")
                for (combo, value) in try SceneShader.textureCombos(vertex: vertex, fragment: fragment, textures: definition["textures"] as? [Any] ?? []) where comboValues[combo] == nil { combos[combo] = value }
                shader = try SceneShader(vertex: vertex, fragment: fragment, combos: combos, label: name, discardTransparentDepth: definition["blending"] as? String == "translucent" && definition["depthwrite"] as? String == "enabled", sceneHDR: sceneHDR)
                if fragment.contains("ApplyBlending") {
                    let mode = shader.resolvedCombos["BLENDMODE"] ?? 0
                    note("BLENDMODE=\(mode)（\(NativeBlendModes.names[mode])）使用自研公式；编号与特殊规则已对照官方 Android 公开资源，尚未与 Windows 输出逐像素对齐。")
                    fputs("Scene blend compiled: \(name), mode \(mode), \(NativeBlendModes.names[mode]), compile-time selection\n", stderr)
                }
                if shader.usesNativeImageBlur { note("common_blur 已按参考资源的固定采样位置和权重实现 3/7/13 核、RGB/RGBA 与径向接口；RGBA 直接累加，透明度保留和遮罩由作者效果处理。Windows 逐像素一致性尚未建立。") }
                if fragment.contains("common_composite.h") { note("common_composite 已实现普通彩色替换和颜色乘数；其他模式仍明确报告不兼容。") }
            }
            var uniforms: [String: [Float]] = [:]
            var scriptUniforms: [String: String] = [:]
            var timelineUniforms: [String: String] = [:]
            var userUniforms: [String: String] = [:]
            var materialUniforms: [String: String] = [:]
            var materialProperties: [SceneScriptMaterial.Property] = []
            var boundTextures: [Int: SceneGLTexture] = [:]
            var framebufferSlots = Set(framebuffer ? [0] : []).union(boundSlots)
            var mipmappedFramebufferSlots = Set<Int>()
            var layerCompositeSlots: [Int: String] = [:]
            let declared = definition["textures"] as? [Any] ?? []
            let constants = definition["constantshadervalues"] as? [String: Any] ?? [:]
            let userValues = definition["usershadervalues"] as? [String: Any] ?? [:]
            let textureLimit = isNativeModel && name == "chroma4" ? 9 : 8
            for (uniform, info) in shader.uniformMetadata {
                let key = info["material"] as? String ?? uniform
                let property = (userValues[key] as? String).flatMap { properties[$0] }
                let value = property ?? propertyValue(constants[key]) ?? info["default"]
                if (info["glslType"] as? String ?? info["type"] as? String) == "sampler2D" {
                    // Shader variants may compile out an annotated sampler. Its
                    // unavailable default texture must not reject an effect that
                    // never reads it. Linked locations also cover optimizer use.
                    guard shader.location(uniform) >= 0 else { continue }
                    guard uniform.hasPrefix("g_Texture"), let slot = Int(uniform.dropFirst(9)), slot >= 0, slot < textureLimit else { continue }
                    if boundSlots.contains(slot) { continue }
                    let textureName = declared.indices.contains(slot) ? declared[slot] as? String : nil
                    let resolved = textureName ?? (value as? String)
                    if let resolved {
                        if resolved.hasPrefix("_rt_") {
                            if resolved == "_rt_FullFrameBuffer" { framebufferSlots.insert(slot) }
                            else if resolved == "_rt_MipMappedFrameBuffer" { mipmappedFramebufferSlots.insert(slot) }
                            else if let id = layerCompositeID(resolved) { layerCompositeSlots[slot] = id; framebufferSlots.remove(slot) }
                            else { throw SceneError.invalid("尚未实现渲染目标 \(resolved)。") }
                        } else { boundTextures[slot] = try texture(resolved) }
                    } else if slot == 0 && framebuffer { framebufferSlots.insert(slot) }
                    else { boundTextures[slot] = try texture("util/white") }
                } else {
                    let numeric = SceneValues.floats(value)
                    if !numeric.isEmpty && numeric.allSatisfy(\.isFinite) { uniforms[uniform] = numeric }
                    let kind = info["glslType"] as? String ?? info["type"] as? String ?? ""
                    let dimensions = ["float": 1, "vec2": 2, "vec3": 3, "vec4": 4]
                    if let scriptPrefix, let count = dimensions[kind], count == numeric.count,
                       shader.location(uniform) >= 0, numeric.allSatisfy({ $0.isFinite && abs($0) <= 16384 }) {
                        let path = scriptPrefix + "/constantshadervalues/" + SceneScriptBridge.path(key)
                        materialUniforms[uniform] = path
                        materialProperties.append(SceneScriptMaterial.Property(name: key, path: path, value: numeric,
                            authored: constants[key] ?? info["default"], user: userValues[key]))
                    }
                    if let propertyName = userValues[key] as? String, properties[propertyName] != nil { userUniforms[uniform] = propertyName }
                    if let propertyName = (constants[key] as? [String: Any])?["user"] as? String, properties[propertyName] != nil { userUniforms[uniform] = propertyName }
                    if property == nil, let scriptPrefix, (constants[key] as? [String: Any])?["script"] is String {
                        scriptUniforms[uniform] = scriptPrefix + "/constantshadervalues/" + SceneScriptBridge.path(key)
                    }
                    if let scriptPrefix, (constants[key] as? [String: Any])?["animation"] is [String: Any] {
                        timelineUniforms[uniform] = scriptPrefix + "/constantshadervalues/" + SceneScriptBridge.path(key)
                    }
                }
            }
            // Author-provided materials can bind textures lacking editor annotations.
            for (slot, value) in declared.enumerated() where slot < textureLimit && shader.location("g_Texture\(slot)") >= 0 {
                if boundSlots.contains(slot) { continue }
                guard let name = value as? String else { continue }
                if name == "_rt_FullFrameBuffer" { framebufferSlots.insert(slot) }
                else if name == "_rt_MipMappedFrameBuffer" { mipmappedFramebufferSlots.insert(slot) }
                else if let id = layerCompositeID(name) { layerCompositeSlots[slot] = id; framebufferSlots.remove(slot) }
                else if name.hasPrefix("_rt_") { throw SceneError.invalid("尚未实现渲染目标 \(name)。") }
                else if boundTextures[slot] == nil { boundTextures[slot] = try texture(name) }
            }
            if particle && boundTextures[0] == nil { boundTextures[0] = try texture("util/white") }
            for (slot, texture) in boundTextures where texture.animation != nil {
                let mainImage = slot == 0 && ((particle && name == "genericparticle") || (!particle && shader.location("g_NativeAtlasRect") >= 0))
                let projectionImage = slot == 7 && isNativeModel && shader.location("g_NativeProjectionRegion") >= 0
                guard mainImage || projectionImage else {
                    throw SceneError.invalid("\(path): 序列纹理当前支持原生图片、genericparticle 主纹理和模型投影槽 7；其他纹理槽尚未实现。")
                }
            }
            if let combos = definition["combos"] as? [String: Any],
               combos.contains(where: { $0.key.lowercased() == "spritesheet" && ($0.value as? NSNumber)?.intValue == 1 }),
               boundTextures[0]?.animation == nil {
                throw SceneError.invalid("\(path): spritesheet 材质缺少已支持的 TEXS 序列数据。")
            }
            guard boneCount == 0 || isNativeModel else { throw SceneError.invalid("\(path)：此骨架材质的顶点着色器尚未实现。") }
            var shadowShader: SceneShader?
            if isNativeModel, (definition["blending"] as? String ?? "normal") == "normal" {
                if shadowShaders[boneCount] == nil {
                    shadowShaders[boneCount] = try SceneShader(vertex: NativePointShadows.vertex,
                        fragment: NativePointShadows.fragment, combos: ["NATIVE_BONE_COUNT": boneCount], label: "native point shadow depth")
                }
                shadowShader = shadowShaders[boneCount]
            } else if isNativeModel {
                note("\(path)：透明/叠加材质可接收点光阴影，但暂不投射阴影。")
            }
            let materialObject = try scriptPrefix.map { prefix in
                try SceneScriptMaterial.merge([SceneScriptMaterial(path: prefix, properties: materialProperties)])[0]
            }
            return ScenePass(shader: shader, definition: definition, textures: boundTextures, framebufferSlots: framebufferSlots, uniforms: uniforms, scriptUniforms: scriptUniforms, timelineUniforms: timelineUniforms, userUniforms: userUniforms, materialUniforms: materialUniforms, materialObject: materialObject, nativeModelMaterial: isNativeModel, shadowShader: shadowShader, mipmappedFramebufferSlots: mipmappedFramebufferSlots, layerCompositeSlots: layerCompositeSlots)
        }
    }

    /// Expand author-provided headers through the same bounded asset store. The
    /// engine headers remain for our own dialect prelude, never a client DLL.
    private func shaderSource(_ path: String, stack: [String] = []) throws -> String {
        guard stack.count < 16, !stack.contains(path.lowercased()) else { throw SceneError.invalid("着色器 include 循环或嵌套超过 16 层：\(path)") }
        let source = try assets.text(path)
        let builtins: Set<String> = ["common.h", "common_vertex.h", "common_fragment.h", "common_blending.h", "common_perspective.h", "common_blur.h", "common_composite.h"]
        let directory = path.split(separator: "/").dropLast().joined(separator: "/")
        let pattern = try NSRegularExpression(pattern: #"^\s*#include\s+\"([^\"]+)\"\s*(?://.*)?$"#)
        var lines: [String] = [], bytes = 0
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (index, line) in normalized.components(separatedBy: "\n").enumerated() {
            var expanded = line
            if let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) {
                let include = String(line[range])
                if !builtins.contains(include) {
                    let choices = [directory + "/" + include, "shaders/" + include]
                    guard let resolved = choices.first(where: { assets.contains($0) }) else { throw SceneError.invalid("\(path): 缺少着色器 include \(include)") }
                    expanded = try shaderSource(resolved, stack: stack + [path.lowercased()]) + "\n#line \(index + 2)\n"
                }
            }
            bytes += expanded.utf8.count + 1
            guard bytes <= 1_048_576 else { throw SceneError.invalid("\(path): 展开后的着色器超过 1 MiB。") }
            lines.append(expanded)
        }
        return lines.joined(separator: "\n")
    }

    private func compressedTextureFormats() -> [GLint] {
        var count: GLint = 0
        glGetIntegerv(GLenum(GL_NUM_COMPRESSED_TEXTURE_FORMATS), &count)
        guard count > 0, count <= 256 else { return [] }
        var formats = [GLint](repeating: 0, count: Int(count))
        glGetIntegerv(GLenum(GL_COMPRESSED_TEXTURE_FORMATS), &formats)
        return formats
    }

    private func texture(_ name: String) throws -> SceneGLTexture {
        if let existing = textures[name] { return existing }
        let previousBytes = textureBytes
        guard textures.count < 256 else { throw SceneError.invalid("此 Scene 超过当前 256 张纹理的运行上限。") }
        let texture: SceneGLTexture
        let path = name.hasSuffix(".tex") ? name : "materials/\(name).tex"
        if ["$mediaThumbnail", "$mediaPreviousThumbnail"].contains(name) {
            // Reserve the maximum base image once; later updates cannot bypass
            // the per-scene budget. Transparent before a real cover is read.
            let reserved = 1024 * 1024 * 4
            guard textureBytes + reserved <= 256 * 1024 * 1024 else { throw SceneError.invalid("媒体纹理超过场景 256 MiB 上限。") }
            textureBytes += reserved
            texture = SceneGLTexture(width: 1, height: 1, rgba: [0,0,0,0], repeating: false)
        } else if let video = try videoLibrary.asset(path) {
            let data = try assets.data(path, maximumBytes: SceneTexture.maximumResourceBytes)
            guard video.matches(data), textureBytes + video.width * video.height * 4 <= 256 * 1024 * 1024 else { throw SceneError.invalid("Scene 视频已改变或超过纹理预算。") }
            let key = path.lowercased()
            if videoRuntimes[key] == nil { videoRuntimes[key] = SceneVideoRuntime(video) }
            texture = SceneGLTexture(width: video.width, height: video.height, rgba: video.firstFrame.rgba, repeating: video.flags & 2 == 0, nearest: video.flags & 1 != 0)
            texture.videoKey = key; texture.videoPTS = video.firstFrame.pts
            textureBytes += video.width * video.height * 4
        } else if assets.contains(path) || builtinTextures?.contains(path) == true {
            let fromProject = assets.contains(path)
            let decoded: SceneTexture
            if let prepared = preparedTextures[path.lowercased()] {
                decoded = try prepared.get(); creationPreparationStatistics?.textureCacheHits += 1
            } else {
                let data = try fromProject ? assets.data(path, maximumBytes: SceneTexture.maximumResourceBytes) : builtinTextures!.data(path)
                decoded = try SceneTexture.decode(data, allowCompressedBC3: compressedTextureFormats().contains(0x83F3), preferredMip: textureResolutionRequest.preferredMip(canvas: textureResolutionCanvas))
                creationPreparationStatistics?.textureFallbackDecodes += 1
            }
            let storedBytes = decoded.compressedBC3?.count ?? decoded.rgba.count
            guard textureBytes + storedBytes <= 256 * 1024 * 1024 else { throw SceneError.invalid("此 Scene 的纹理基础层存储超过当前 256 MiB 上限。") }
            var maximumSize: GLint = 0
            glGetIntegerv(GLenum(GL_MAX_TEXTURE_SIZE), &maximumSize)
            guard decoded.pixelWidth <= maximumSize, decoded.pixelHeight <= maximumSize else { throw SceneError.invalid("纹理尺寸超过当前 GPU 上限。") }
            texture = SceneGLTexture(width: decoded.width, height: decoded.height, imageWidth: decoded.imageWidth, imageHeight: decoded.imageHeight, rgba: decoded.rgba, repeating: decoded.flags & 2 == 0, channelCount: decoded.channelCount, animation: decoded.animation, pixelWidth: decoded.pixelWidth, pixelHeight: decoded.pixelHeight, compressedBC3: decoded.compressedBC3, nearest: decoded.flags & 1 != 0)
            texture.sourceType = decoded.sourceType; texture.mipLevel = decoded.mipLevel
            if decoded.compressedBC3 != nil {
                var uploadedWidth: GLint = 0, uploadedHeight: GLint = 0, compressed: GLint = 0, uploadedBytes: GLint = 0
                glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_WIDTH), &uploadedWidth)
                glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_HEIGHT), &uploadedHeight)
                glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_COMPRESSED), &compressed)
                glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_COMPRESSED_IMAGE_SIZE), &uploadedBytes)
                let error = glGetError()
                guard uploadedWidth == decoded.pixelWidth, uploadedHeight == decoded.pixelHeight,
                      compressed != 0, uploadedBytes == storedBytes, error == 0 else {
                    throw SceneError.invalid("BC3 压缩纹理上传未完成：\(uploadedWidth)×\(uploadedHeight)，\(uploadedBytes) 字节，GL=\(error)。")
                }
                note("\(path)：保留原始 BC3 压缩纹理 \(uploadedWidth)×\(uploadedHeight)，GPU 基础层 \(uploadedBytes) 字节，GL=\(error)；未展开已选择的压缩纹理。")
            }
            textureBytes += storedBytes
            if !fromProject {
                fputs("Scene builtin texture loaded: \(path), \(storedBytes) base storage bytes, \(decoded.width)x\(decoded.height), archive \(builtinTextures!.manifest.archiveSHA256)\n", stderr)
            }
            if decoded.mipLevel > 0 {
                note("\(path)：原始纹理 \(decoded.width)×\(decoded.height)，使用包内 mip \(decoded.mipLevel)（\(decoded.pixelWidth)×\(decoded.pixelHeight)，\(decoded.rgba.count) 字节）；保留作者图像尺寸和 UV，细节受选定层级限制。")
                fputs("Scene texture mip selected: \(path), level \(decoded.mipLevel), logical \(decoded.width)x\(decoded.height), image \(decoded.imageWidth)x\(decoded.imageHeight), upload \(decoded.pixelWidth)x\(decoded.pixelHeight), RGBA bytes \(decoded.rgba.count)\n", stderr)
                var uploadedWidth: GLint = 0, uploadedHeight: GLint = 0
                glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_WIDTH), &uploadedWidth)
                glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_HEIGHT), &uploadedHeight)
                let uploadError = glGetError()
                note("大纹理 GPU 层级 0：\(uploadedWidth)×\(uploadedHeight)，上传错误码 \(uploadError)，解码首像素 RGBA \(decoded.rgba.prefix(4).map(String.init).joined(separator: ","))。")
            }
            if let animation = decoded.animation {
                fputs("Scene texture sequence loaded: \(name), \(animation.frames.count) frames, nominal \(animation.width)x\(animation.height), \(animation.duration) seconds, \(animation.sourceVersion) single atlas, fractional extents \(animation.fractionalFrameCount), sampler-addressed outside frames \(animation.outOfAtlasFrameCount(width: decoded.width, height: decoded.height))\n", stderr)
                if animation.duration == 0 {
                    note("\(name)：序列没有帧时长；图片默认显示首帧，可通过脚本选帧，粒子按各自生命周期选帧。")
                }
                if animation.subtexelFrameCount > 0 {
                    note("\(name)：\(animation.subtexelFrameCount) 个序列帧含小于一个纹素的尺寸；原生采样将该轴收缩到中心，属于尚未与原版逐像素对齐的过滤近似。")
                }
            }
        } else if name == "util/white" {
            texture = SceneGLTexture(width: 1, height: 1, rgba: [255,255,255,255])
        } else if name == "util/perlin_256" || name == "util/clouds_256" {
            let rgba = NativeNoiseTexture.rgba(fractal: name == "util/clouds_256")
            guard textureBytes + rgba.count <= 256 * 1024 * 1024 else { throw SceneError.invalid("此 Scene 的解码纹理超过当前 256 MiB 上限。") }
            texture = SceneGLTexture(width: 256, height: 256, rgba: rgba)
            textureBytes += rgba.count
            note("\(name) 使用自研可平铺梯度噪声；clouds 使用五层叠加。效果仍执行原作者着色器，噪声像素和运动细节属于兼容近似。")
        } else if name == "util/noise" {
            let rgba = NativeNoiseTexture.whiteRGBA()
            guard rgba.count <= 256 * 1024 * 1024 - textureBytes else { throw SceneError.invalid("此 Scene 的解码纹理超过当前 256 MiB 上限。") }
            texture = SceneGLTexture(width: 256, height: 256, rgba: rgba)
            textureBytes += rgba.count
            note("util/noise 使用自研确定性噪声纹理，未复制官方内置纹理。")
        } else if name == "particle/halo_6" || name == "particle/halo" {
            var rgba: [UInt8] = []; rgba.reserveCapacity(128*128*4)
            for y in 0..<128 { for x in 0..<128 {
                let dx = Float(x) / 63.5 - 1, dy = Float(y) / 63.5 - 1
                let radius = dx*dx + dy*dy
                let alpha = max(0, min(1, exp(-radius * 9) * (1 - min(1,radius))))
                rgba += [255,255,255,UInt8(alpha * 255)]
            } }
            texture = SceneGLTexture(width: 128, height: 128, rgba: rgba, repeating: false)
            note("\(name) 使用自研径向光晕，粒子外观为兼容近似。")
        } else { throw SceneError.invalid("缺少或尚未支持纹理：\(name)") }
        textures[name] = texture
        textureReservations[name] = textureBytes - previousBytes
        return texture
    }

    private func commitMediaTextures() {
        // Called only with this view's GL context current. An in-flight helper
        // response keeps its exact immutable snapshot; newer service values
        // cannot replace the image ahead of the matching script state.
        guard !sceneClock.isPaused || renderedFrames == 0 else { return }
        let media = scripts?.committedMedia ?? NativeMediaService.shared.snapshot
        guard media.revision != displayedMediaRevision else { return }
        let changed = media.artwork?.digest != displayedMediaArtwork?.digest
        if changed {
            let previous = media.artwork == nil ? nil : displayedMediaArtwork
            for (name, image) in [("$mediaThumbnail", media.artwork), ("$mediaPreviousThumbnail", previous)] {
                if let texture = textures[name] {
                    texture.replace(width: image?.width ?? 1, height: image?.height ?? 1, rgba: image?.rgba ?? [0,0,0,0])
                }
            }
            if mediaTextureReports < 64 {
                mediaTextureReports += 1
                let report: [String: Any] = ["presentationID": presentationID, "revision": media.revision,
                    "currentSize": [media.artwork?.width ?? 0, media.artwork?.height ?? 0],
                    "previousSize": [previous?.width ?? 0, previous?.height ?? 0], "hasScriptBridge": scripts != nil]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) {
                    fputs("Scene media textures committed: \(String(decoding: data, as: UTF8.self))\n", stderr)
                }
            }
        }
        displayedMediaArtwork = media.artwork
        displayedMediaRevision = media.revision
    }

    private typealias SceneCamera = (view: simd_float4x4, projection: simd_float4x4,
        right: SIMD3<Float>, up: SIMD3<Float>, orthographicFrame: NativeOrthographicProjection.Frame?,
        parallaxApplied: Bool, parallaxFallback: Bool)

    private var isOrthogonalScene: Bool {
        (scene["general"] as? [String: Any])?["orthogonalprojection"] is [String: Any]
    }

    private func updateProjectionParameters() {
        if isOrthogonalScene {
            orthographicParameters = NativeOrthographicProjection(zoom: generalValue("zoom"),
                perspectiveFOV: generalValue("perspectiveoverridefov"))
            for message in orthographicParameters.diagnostics { note(message) }
        } else {
            perspectiveParameters = NativePerspectiveProjection(fov: sceneCameras.active?.fov ?? generalValue("fov"),
                near: generalValue("nearz"), far: generalValue("farz"))
            for message in perspectiveParameters.diagnostics { note(message) }
        }
    }

    private var textAnchorMargins: SIMD4<Float> {
        guard let general = scene["general"] as? [String: Any],
              let ortho = general["orthogonalprojection"] as? [String: Any] else { return .zero }
        let aspect = Float(max(1, bounds.width) / max(1, bounds.height))
        let height = max(1, SceneValues.number(ortho["height"], 1080))
        let width = max(1, SceneValues.number(ortho["width"], height * aspect))
        return NativeTextAnchor.margins(canvas: SIMD2(width, height), aspect: aspect)
    }

    private func camera(aspect: Float) -> SceneCamera {
        let general = scene["general"] as? [String: Any] ?? [:]
        // Consume the cached pose. Hit queries may call this multiple times.
        let pose = activeCameraPose
        let shakenFrame = pose.frame(offset: cameraShakeOffset)
        let cameraFrame = shakenFrame ?? pose.frame() ?? .identity
        if shakenFrame == nil { note("相机晃动后的视图矩阵无效，保留未晃动的有效姿态。") }
        if let ortho = general["orthogonalprojection"] as? [String: Any] {
            let projectHeight = max(1, SceneValues.number(ortho["height"], 1080))
            let projectWidth = max(1, SceneValues.number(ortho["width"], projectHeight * aspect))
            let visibleHeight = min(projectHeight, projectWidth / max(0.001, aspect))
            let visibleWidth = visibleHeight * max(0.001, aspect)
            var canvasCenter = matrix_identity_float4x4
            canvasCenter.columns.3 = SIMD4(-projectWidth / 2, -projectHeight / 2, 0, 1)
            let view = canvasCenter * cameraFrame.view
            let frame = orthographicParameters.frame(visibleWidth: visibleWidth, visibleHeight: visibleHeight, cameraZoom: pose.zoom)
            let projection = frame?.matrix ?? matrix_identity_float4x4
            let fallback = frame?.usedFallback ?? true
            if fallback { note("二维相机缩放非正或输出矩阵无法安全求逆，总缩放回退为 1；若画布尺寸也无效则保留单位矩阵。") }
            return (view, projection, cameraFrame.right, cameraFrame.up, frame, false, false)
        }
        let projection = perspectiveParameters.matrix(aspect: aspect)
            ?? NativePerspectiveProjection().matrix(aspect: aspect.isFinite ? max(0.001, min(1000, aspect)) : 1)
            ?? matrix_identity_float4x4
        guard frameUniforms.enabled else {
            return (cameraFrame.view, projection, cameraFrame.right, cameraFrame.up, nil, false, false)
        }
        let composed = NativeParallaxCamera.perspective(base: cameraFrame, pose: pose,
            shake: shakenFrame == nil ? .zero : cameraShakeOffset, focus: frameUniforms.signedParallax)
        let finalFrame = composed ?? cameraFrame
        return (finalFrame.view, projection, finalFrame.right, finalFrame.up, nil, composed != nil, composed == nil)
    }

    /// The reference temporarily replaces the 2D projection for flags bit 2,
    /// then restores it before drawing child systems. At z=0 this preserves the
    /// base 2D framing; depth changes projected size/position for this draw only.
    private func perspectiveParticleCamera(base: SceneCamera, aspect: Float) -> SceneCamera? {
        guard isOrthogonalScene else { return nil }
        particleProjectionSnapshot = orthographicParameters.particles(baseProjection: base.projection, aspect: aspect)
        guard let frame = particleProjectionSnapshot else { return nil }
        var view = base.view
        view.columns.3.z = -frame.distance
        return (view, frame.matrix, base.right, base.up, nil, base.parallaxApplied, base.parallaxFallback)
    }

    private func generalValue(_ key: String) -> Any? {
        let authored = (scene["general"] as? [String: Any])?[key]
        let value = propertyValue(authored)
        let timed = timelines.value(at: "/general/" + key, time: currentSceneTime, base: value)
        return scripts?.value(at: "/general/" + key, fallback: nil) ?? timed ?? value
    }

    private func updateCameraShake() {
        cameraShakeOffset = .zero
        guard generalValue("camerashake") as? Bool == true else { return }
        let projection = (scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Any]
        let height = projection.map { max(1, SceneValues.number($0["height"], 1080)) }
        let speed = SceneValues.number(generalValue("camerashakespeed"), 3)
        let amplitude = SceneValues.number(generalValue("camerashakeamplitude"), 0.5)
        let roughness = SceneValues.number(generalValue("camerashakeroughness"), 1)
        guard let offset = NativeCameraShake.translation(time: currentSceneTime, speed: speed,
                amplitude: amplitude, roughness: roughness, orthogonalHeight: height) else {
            note("相机晃动：本帧计算非有限或位移超过 100 万场景单位，保留基础相机。")
            return
        }
        cameraShakeOffset = offset
        if !cameraShakeReported {
            cameraShakeReported = true
            note("相机晃动已接入作者参数、属性和时间轴，使用场景时钟并随暂停冻结；平移公式来自 REA 对官方 Android 库的静态分析，尚未与 Windows 输出逐像素对齐。")
        }
        if cameraShakeReportCount < 8, currentSceneTime - lastCameraShakeReportTime >= 1 {
            cameraShakeReportCount += 1; lastCameraShakeReportTime = currentSceneTime
            fputs("Scene camera shake: time=\(currentSceneTime), offset=\(offset), speed=\(speed), amplitude=\(amplitude), roughness=\(roughness), orthogonalHeight=\(height.map(String.init(describing:)) ?? "none")\n", stderr)
        }
    }

    private func updateFrameUniforms(width: Int, height: Int) {
        let cursor = cursorState()
        let normalized = SIMD2(Float(cursor.point.x / max(1, bounds.width)), Float(cursor.point.y / max(1, bounds.height)))
        let projection = (scene["general"] as? [String: Any])?["orthogonalprojection"] as? [String: Any]
        let canvas = SIMD2(SceneValues.number(projection?["width"], Float(width)), SceneValues.number(projection?["height"], Float(height)))
        let enabled = generalValue("cameraparallax") as? Bool ?? false
        frameUniforms.update(pointer: normalized, screen: SIMD2(Float(width), Float(height)), canvas: canvas,
            sceneTime: currentSceneTime, paused: sceneClock.isPaused, enabled: enabled,
            amount: SceneValues.number(generalValue("cameraparallaxamount"), 0.5),
            delay: SceneValues.number(generalValue("cameraparallaxdelay"), 0.1),
            influence: SceneValues.number(generalValue("cameraparallaxmouseinfluence"), 0))
        if enabled, pointerReportCount < 64, currentSceneTime - lastPointerReportTime >= 1,
           simd_length(frameUniforms.pointer - lastReportedPointer) > 0.05 || simd_length(frameUniforms.parallax - lastReportedParallax) > 0.002 {
            lastPointerReportTime = currentSceneTime; lastReportedPointer = frameUniforms.pointer
            lastReportedParallax = frameUniforms.parallax; pointerReportCount += 1
            fputs("Scene pointer uniforms: time=\(currentSceneTime), pointer=\(frameUniforms.pointer), previous=\(frameUniforms.previousPointer), parallax=\(frameUniforms.parallax), layerAmount=\(frameUniforms.amount), screen=\(frameUniforms.screen)\n", stderr)
        }
    }

    /// Scene::Draw pushes V*T(offset) around each renderable and then restores V.
    /// The root controls the subtree, but its authored model remains unchanged.
    private func parallaxOffsets(states: [[String: Any]]) -> [SIMD3<Float>] {
        var offsets = [SIMD3<Float>](repeating: .zero, count: states.count)
        guard isOrthogonalScene, frameUniforms.enabled, frameUniforms.amount != 0 else { return offsets }
        for index in hierarchy.order where !hierarchy.invalid.contains(index) {
            if let parent = hierarchy.parents[index] { offsets[index] = offsets[parent] }
            else {
                let values = SceneValues.floats(states[index]["parallaxDepth"])
                let depth = values.count >= 2 ? SIMD2(values[0], values[1]) : SIMD2<Float>(repeating: 1)
                let origin = SceneValues.vector(states[index]["origin"], .zero)
                offsets[index] = frameUniforms.offset(origin: origin, depth: depth)
            }
        }
        return offsets
    }

    private func parallaxCamera(_ base: SceneCamera, offset: SIMD3<Float>) -> SceneCamera? {
        guard let view = NativeParallaxCamera.translated(base.view, by: offset) else { return nil }
        return (view, base.projection, base.right, base.up, base.orthographicFrame,
            base.parallaxApplied, base.parallaxFallback)
    }

    private func render(time: Double, width: Int, height: Int, outputWidth: Int, outputHeight: Int, outputFramebuffer: GLuint = 0) {
        if !sceneClock.isPaused { scripts?.publishForRendering() }
        puppetMaskPasses = 0
        currentSceneTime = time
        imageBlurBindings = 0
        imageBlurVariants.removeAll(keepingCapacity: true)
        if needsReflectionHistory { reflectionHistory?.beginFrame(at: time, paused: sceneClock.isPaused) }
        commitMediaTextures()
        for texture in textures.values {
            guard let key = texture.videoKey, let video = videoRuntimes[key] else { continue }
            let playhead = scripts?.videoPlayback[key]?.time(at: Double(time), duration: video.asset.duration)
                ?? Double(time).truncatingRemainder(dividingBy: video.asset.duration)
            do {
                let frame = try video.frame(at: playhead)
                if texture.videoPTS != frame.pts {
                    texture.replace(width: video.asset.width, height: video.asset.height, rgba: frame.rgba)
                    texture.videoPTS = frame.pts
                }
            } catch { note("Scene 视频停止：" + error.localizedDescription); pause() }
        }
        if !sceneClock.isPaused || renderedFrames == 0 { timelines.advance(to: time) }
        updateAudioSpectrum()
        updateScripts(time: time)
        if !sceneClock.isPaused || renderedFrames == 0, let observation = timelines.observation(at: time, context: presentationContext) { fputs("Scene timeline runtime: \(observation)\n", stderr) }
        let delta = previousSceneTime.map { Float(min(0.25, max(0, time - $0))) } ?? 0
        previousSceneTime = time
        var states = hierarchy.parents.indices.map { objectState($0, includeModelMotion: false) }
        let objects = scene["objects"] as? [[String: Any]] ?? []
        let cameraBases = Dictionary(uniqueKeysWithValues: sceneCameras.indices.map { index in
            (index, NativeSceneCameras.TransformState(
                origin: SceneValues.vector(propertyValue(objects[index]["origin"]), .zero),
                angles: SceneValues.vector(propertyValue(objects[index]["angles"]), .zero)))
        })
        let localVisibility = states.map { SceneValues.visible($0["visible"]) }
        let resolved: (transforms: [simd_float4x4], visible: [Bool])
        do {
            resolved = try sceneCameras.advance(to: time, states: &states, bases: cameraBases,
                hierarchy: hierarchy, localVisibility: localVisibility, transform: SceneValues.transform, resolve: propertyValue,
                displayOrder: (scripts?.sceneLayerOrder ?? initialSceneLayerOrder)?.indices,
                beforeObject: { index, parent, visible, state in
                guard let animation = modelAnimations[index] else { return }
                let samples = try NativeModelProperties.sample(animation, object: index, time: time, timelines: timelines, resolve: propertyValue)
                let overrides = Set(["origin", "angles"].filter { (objects[index][$0] as? [String: Any])?["animation"] != nil })
                let input = try animation.hasRootMotion ? NativeModelRootMotion.Input(object: state, parent: parent, curveOverrides: overrides) : nil
                try animation.update(time: time, visible: visible, paused: sceneClock.isPaused, samples: samples, motionInput: input, resolve: propertyValue)
                if let motion = animation.motion { state.merge(motion.properties) { _, next in next } }
            })
        } catch { note("模型动画停止：" + error.localizedDescription); pause(); return }
        updateModelLighting(states: states, transforms: resolved.transforms, visibility: resolved.visible, time: time)
        renderPointShadows(states: states, transforms: resolved.transforms, visibility: resolved.visible, time: time)
        legacyCamera.advance(to: time, enabled: sceneCameras.active == nil)
        updateProjectionParameters()
        updateCameraShake()
        updateFrameUniforms(width: outputWidth, height: outputHeight)
        let color = SceneValues.vector(generalValue("clearcolor"), .zero)
        let restored: Bool
        do {
            restored = try sceneHistory?.begin(target: targets[0], time: time, paused: sceneClock.isPaused,
                clearEnabled: generalValue("clearenabled") as? Bool ?? true, clearColor: color) ?? false
        } catch { note("场景历史停止：" + error.localizedDescription); pause(); return }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), targets[0].drawFramebuffer)
        glViewport(0,0,GLsizei(width),GLsizei(height))
        glEnable(GLenum(GL_MULTISAMPLE))
        if restored { targets[0].seedSamples(depth: true); glBindFramebuffer(GLenum(GL_FRAMEBUFFER), targets[0].drawFramebuffer) }
        glDepthMask(GLboolean(GL_TRUE)); glClearColor(color.x,color.y,color.z,1)
        if !restored { glClearDepth(1); glClear(GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)) }
        let aspect = Float(width) / Float(height)
        let baseCamera = camera(aspect: aspect)
        if isOrthogonalScene {
            // Only the completed frame path records this snapshot. Hit-region
            // queries also create a camera, but must not change diagnostics.
            orthographicSnapshot = (time, aspect, baseCamera.orthographicFrame?.appliedZoom ?? 1,
                SIMD2(baseCamera.projection.columns.0.x, baseCamera.projection.columns.1.y),
                baseCamera.orthographicFrame?.usedFallback ?? true)
        } else {
            let usedFallback = perspectiveParameters.matrix(aspect: aspect) == nil
            projectionSnapshot = (time, aspect, SIMD2(baseCamera.projection.columns.0.x, baseCamera.projection.columns.1.y), usedFallback)
        }
        let particleCamera = perspectiveParticleCamera(base: baseCamera, aspect: aspect)
        let acceptedShake = activeCameraPose.frame(offset: cameraShakeOffset) == nil ? SIMD3<Float>.zero : cameraShakeOffset
        if let inputs = NativeParallaxCamera.shaderInputs(view: baseCamera.view, pose: activeCameraPose,
                shake: acceptedShake, canvas: isOrthogonalScene ? frameUniforms.canvas : nil) {
            frameCameraInputs = inputs
        } else { note("相机着色器输入非有限或方向退化，保留上一有效快照。") }
        refreshSounds(states: states, visibility: resolved.visible)
        let offsets = parallaxOffsets(states: states)
        // Hidden solid text still owns an input region. Anchor state therefore
        // updates for all text before visibility filtering and offscreen draws.
        for draw in draws {
            if let text = draw.text, let index = draw.objectIndex { text.anchor.update(states[index]) }
        }
        // Update before compositing, so consumers cannot observe a previous-frame mesh.
        for draw in draws {
            guard let puppet = draw.puppet, let shape = puppet.model.shapes.first else { continue }
            do { draw.geometry.updateIndexedVertices(try puppet.imageVertices(shape: shape, at: time)) }
            catch {
                let message = "\(draw.name)：木偶姿态更新失败，保留上一有效网格：\(error.localizedDescription)"
                if !diagnosticNotes.contains(message) { note(message) }
            }
        }
        renderLayerComposites(states: states, transforms: resolved.transforms, visibility: resolved.visible,
                              offsets: offsets, baseCamera: baseCamera, time: time, delta: delta)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), targets[0].drawFramebuffer)
        glViewport(0, 0, GLsizei(width), GLsizei(height))
        let nonzeroOffsets = offsets.filter { $0 != .zero }.count
        parallaxViewDiagnostic = "视差视图快照：场景时间 \(String(format: "%.6f", time)) 秒；模式=\(isOrthogonalScene ? "二维逐层视图" : "三维相机旋转")，非零图层偏移 \(nonzeroOffsets)；三维分支启用=\(baseCamera.parallaxApplied)，矩阵回退=\(baseCamera.parallaxFallback)，有符号输入=\(frameUniforms.signedParallax)。相机着色器快照 eye=\(frameCameraInputs.eye)，forward=\(frameCameraInputs.forward)，right=\(frameCameraInputs.right)，up=\(frameCameraInputs.up)。模型保持作者空间；输入映射仍为本机兼容策略。"
        // Sample the shared input once per frame; only particle layers that
        // actually reference a pointer control point need the plane projection.
        let hasPointerParticles = draws.contains { $0.particles?.hasPointerForces == true }
        let particleCursor = hasPointerParticles ? cursorState() : nil
        let particlePointerReason: String
        if let cursor = particleCursor, cursor.inside {
            let mode = NativeDesktopPointerRouting.mode(for: window)
            let desktop = mode == .desktop
            let applicationActive = mode == .preview && (NSApp?.isActive == true)
            let admitted = NativeDesktopPointerRouting.admitsInput(
                mode: mode,
                desktopExposed: desktop && desktopCursorIsExposed(),
                isKeyWindow: window?.isKeyWindow == true,
                applicationActive: applicationActive,
                hasPreviewPoint: previewCursor != nil
            )
            if admitted { particlePointerReason = "active" }
            else if desktop { particlePointerReason = "desktop-covered-or-inactive" }
            else if window?.isKeyWindow != true || !applicationActive { particlePointerReason = "preview-window-inactive" }
            else { particlePointerReason = "preview-pointer-not-tracked" }
        } else { particlePointerReason = "outside-wallpaper" }
        // Property paths and draw resources retain their authored indices;
        // display order changes only at a complete script-frame commit.
        let drawOrder = (scripts?.sceneLayerOrder ?? initialSceneLayerOrder)?.drawIndices(draws.map(\.objectIndex)) ?? Array(draws.indices)
        let volumeBoundary = pointVolumeBoundary(states: states, visibility: resolved.visible, drawOrder: drawOrder)
        var current = 0
        for (drawPosition, drawIndex) in drawOrder.enumerated() {
            if drawPosition == volumeBoundary {
                renderPointVolumetrics(source: targets[current], vp: baseCamera.projection * baseCamera.view, time: time)
            }
            let objectIndex = draws[drawIndex].objectIndex
            let object = objectIndex.map { states[$0] }
            if let objectIndex, !resolved.visible[objectIndex] { continue }
            if let object { updateText(drawIndex, object: object) }
            let draw = draws[drawIndex]
            let projectionCamera: SceneCamera
            if isOrthogonalScene && (draw.particles?.usesPerspectiveProjection == true || draw.particleChildren?.usesPerspectiveProjection == true) {
                guard let particleCamera else {
                    let message = "\(draw.name)：粒子透视投影参数无效，未绘制该层。"
                    if !diagnosticNotes.contains(message) { note(message) }
                    continue
                }
                projectionCamera = particleCamera
                if renderedFrames == 0 {
                    fputs("Scene particle perspective: \(draw.name), viewZ \(particleCamera.view.columns.3.z), projection \(particleCamera.projection.columns.0.x) \(particleCamera.projection.columns.1.y) \(particleCamera.projection.columns.2.z) \(particleCamera.projection.columns.3.z)\n", stderr)
                }
            } else { projectionCamera = baseCamera }
            let offset = objectIndex.map { offsets[$0] } ?? .zero
            guard let camera = parallaxCamera(projectionCamera, offset: offset) else {
                note("\(draw.name)：视差图层视图非有限，跳过该绘制组。")
                continue
            }
            let vp = camera.projection * camera.view
            var transform = objectIndex.map { draw.fullscreen ? draw.transform : resolved.transforms[$0] } ?? draw.transform
            let authoredParticleModel = objectIndex.map { resolved.transforms[$0] } ?? draw.transform
            // World geometry already includes its birth-time model. Per-layer
            // parallax now lives in camera.view for both local/world systems.
            let particleViewModel = matrix_identity_float4x4
            if draw.alignmentOffset != .zero {
                var offset = matrix_identity_float4x4
                offset.columns.3 = SIMD4(draw.alignmentOffset.x, draw.alignmentOffset.y, 0, 1)
                transform = transform * offset
            }
            if let text = draw.text {
                transform = text.anchor.model(transform, margins: textAnchorMargins)
                var offset = matrix_identity_float4x4
                offset.columns.3 = SIMD4(text.offset.x, text.offset.y, 0, 1)
                transform = transform * offset
            }
            if let children = draw.particleChildren {
                transform = transform * children.drawLocalTransform
            }
            if let index = objectIndex, draw.particles != nil || draw.particleChildren != nil {
                do {
                    let values = try SceneParticles.LiveOverrides(particleInstance(objects[index], index: index))
                    try draw.particles?.applyLiveOverrides(values)
                    try draw.particleChildren?.applyLiveOverrides(values)
                } catch { note("\(draw.name)：粒子参数更新未应用：\(error.localizedDescription)") }
            }
            if sceneClock.isPaused, renderedFrames > 0,
               let children = draw.particleChildren, children.discardInvalidStaticDraw(transform) {
                draw.geometry.update([])
                continue
            }
            // Resize/expose can redraw a paused view even without its timer.
            // Keep the existing particle geometry so neither backlog catch-up
            // nor a changed pointer advances its physical state while paused.
            if let particles = draw.particles, !sceneClock.isPaused || renderedFrames == 0 {
                let pointer: SceneParticlePointerInput
                if particles.hasPointerForces, particlePointerReason == "active", let cursor = particleCursor {
                    let normalized = SIMD2<Float>(Float(cursor.point.x / max(1, bounds.width)), Float(cursor.point.y / max(1, bounds.height)))
                    pointer = SceneParticlePointerInput.project(normalized: normalized,
                        modelViewProjection: vp * (particles.usesWorldSpace ? particleViewModel : transform))
                } else { pointer = SceneParticlePointerInput(position: nil, reason: particlePointerReason) }
                let vertices = particles.vertices(at: time, cameraRight: camera.right, cameraUp: camera.up,
                    pointer: pointer, capturePointer: !sceneClock.isPaused, authoredModel: authoredParticleModel,
                    orientationModel: transform)
                draw.geometry.update(vertices)
                if renderedFrames == 0 { fputs("Scene particles submitted: \(draw.name), \(vertices.count / 72) quads in first frame\n", stderr) }
                if let observation = particles.observation(at: time) { fputs("Scene particle runtime: \(draw.name), \(observation)\n", stderr) }
            } else if let children = draw.particleChildren, !sceneClock.isPaused || renderedFrames == 0 {
                let vertices = children.vertices(at: time, cameraRight: camera.right, cameraUp: camera.up, drawModel: transform)
                draw.geometry.update(vertices)
                if renderedFrames == 0 { fputs("Scene child particles submitted: \(draw.name), \(vertices.count / 72) quads in first frame\n", stderr) }
                if let observation = children.observation(at: time) { fputs("Scene child particle runtime: \(draw.name), \(observation)\n", stderr) }
            }
            // World geometry uses the identity model in both renderer and
            // material; parallax must not be added to its birth transform or
            // reintroduced through g_Model* / inverse uniforms.
            if draw.particles?.usesWorldSpace == true || draw.particleChildren?.usesWorldGeometry == true {
                transform = particleViewModel
            }
            let effectTransforms = draw.imageLayer.map { layer in
                SceneEffectTransforms(layerModel: transform, sceneViewProjection: vp,
                    layerSize: SIMD2(2 / abs(layer.projection.columns.0.x), 2 / abs(layer.projection.columns.1.y)))
            }
            targets[current].resolveSamples()
            var layerSource: SceneTarget?
            var effectGroup: Int?
            var effectInput: SceneTarget?
            var finalPasses = activePasses(draw.passes)
            if let layer = draw.imageLayer {
                let active = activePasses(layer.stages + draw.passes)
                let needsCopy = active.last?.usesSceneTransforms == false
                finalPasses = needsCopy ? [layer.copyPass] : Array(active.suffix(1))
                let intermediateStages = needsCopy ? active : Array(active.dropLast())
                for stage in intermediateStages {
                    if let copySource = stage.graphCopySource {
                        guard let targetKey = stage.graphTarget,
                              let sourceTarget = layer.namedTargets[copySource],
                              let destination = layer.namedTargets[targetKey],
                              sourceTarget !== destination,
                              sourceTarget.width == destination.width, sourceTarget.height == destination.height,
                              sourceTarget.hdr == destination.hdr else {
                            let message = "\(draw.name)：效果 copy 命名缓冲无效、同一目标或规格不一致。"
                            if !diagnosticNotes.contains(message) { note(message); fputs("Scene graph: \(message)\n", stderr) }
                            continue
                        }
                        // A permitted graph copy writes an authored unique
                        // history target. It deliberately does not clear that
                        // target: the following frame must see this result.
                        glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), sourceTarget.framebuffer)
                        glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
                        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), destination.framebuffer)
                        glDrawBuffer(GLenum(GL_COLOR_ATTACHMENT0))
                        glBlitFramebuffer(0, 0, GLint(sourceTarget.width), GLint(sourceTarget.height),
                                          0, 0, GLint(destination.width), GLint(destination.height),
                                          GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
                        let error = glGetError()
                        guard error == 0 else {
                            let message = "\(draw.name)：效果 copy 的 OpenGL 帧缓冲复制失败，GL=\(error)。"
                            if !diagnosticNotes.contains(message) { note(message); fputs("Scene graph: \(message)\n", stderr) }
                            continue
                        }
                        graphCopyCommandCount += 1
                        continue
                    }
                    let source = layerSource ?? targets[current]
                    if stage.effectGroup != effectGroup {
                        effectGroup = stage.effectGroup; effectInput = stage.effectGroup == nil ? nil : source
                    }
                    let inputs = graphInputs(stage, layer: layer, previous: effectInput ?? source)
                    let destination: SceneTarget?
                    if let key = stage.graphTarget { destination = layer.namedTargets[key] }
                    else {
                        destination = layer.targets.first { candidate in
                            candidate !== source && candidate !== effectInput && !inputs.values.contains(where: { $0 === candidate })
                        }
                    }
                    guard let destination, !inputs.values.contains(where: { $0 === destination }), destination !== source else {
                        let message = "\(draw.name)：拒绝读取正在写入的效果缓冲。"
                        if !diagnosticNotes.contains(message) { note(message); fputs("Scene graph: \(message)\n", stderr) }
                        continue
                    }
                    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), destination.framebuffer)
                    glViewport(0, 0, GLsizei(destination.width), GLsizei(destination.height))
                    glClearColor(0,0,0,0); glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                    bind(pass: stage, model: matrix_identity_float4x4, view: matrix_identity_float4x4, projection: layer.projection, vp: layer.projection, time: Float(time), delta: delta, source: source, object: object, renderTargets: inputs, effectTransforms: effectTransforms, layerGeometry: stage.usesSceneTransforms)
                    setMatrix(vp * transform, name: "g_NativeCaptureMatrix", shader: stage.shader)
                    // Keep straight alpha in intermediate images. Compositing is
                    // applied once when the final image enters the scene.
                    glDisable(GLenum(GL_BLEND)); glDisable(GLenum(GL_DEPTH_TEST)); glDepthMask(GLboolean(GL_FALSE)); glDisable(GLenum(GL_CULL_FACE))
                    if stage.usesSceneTransforms { draw.geometry.draw() } else { screenQuad.draw() }
                    if renderedFrames == 0, let group = stage.effectGroup {
                        fputs("Scene effect executed: \(draw.name), group \(group), \(stage.definition["shader"] as? String ?? "native"), output \(stage.graphTarget ?? "layer") \(destination.width)x\(destination.height), binds \(stage.graphBindings.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")), geometry \(stage.usesSceneTransforms ? "layer" : "clip")\n", stderr)
                    }
                    if stage.graphTarget == nil { layerSource = destination }
                }
                glViewport(0,0,GLsizei(width),GLsizei(height))
            }
            for pass in finalPasses {
                var shapeUniforms: [String: [Float]]?
                if let height = draw.shapeHeight {
                    let values = resolvedUniforms(pass: pass, object: object)
                    do { draw.geometry.updateShape(points: try shapePoints(uniforms: values), height: height) }
                    catch {
                        let message = "\(draw.name)：\(error.localizedDescription)"
                        if !diagnosticNotes.contains(message) { note(message); fputs("Scene shape skipped: \(message)\n", stderr) }
                        continue
                    }
                    shapeUniforms = values
                }
                targets[current].resolveSamples()
                var source = layerSource ?? targets[current]
                if draw.topLeftFullscreen, let input = fullscreenInput {
                    // Author image UVs start at the top. Flip the scene input
                    // once instead of flipping every unrelated TEX/composite
                    // sampler or rewriting the author's shader expressions.
                    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), source.framebuffer)
                    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), input.framebuffer)
                    glBlitFramebuffer(0, 0, GLint(width), GLint(height), 0, GLint(height), GLint(width), 0,
                                      GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
                    source = input
                }
                if pass.effectGroup != effectGroup {
                    effectGroup = pass.effectGroup; effectInput = pass.effectGroup == nil ? nil : source
                }
                var inputs = draw.imageLayer.map { graphInputs(pass, layer: $0, previous: effectInput ?? source) } ?? [:]
                let imageMode = draw.imageLayer?.colorBlendMode ?? 0
                let blendsScene = imageMode != 0 && imageMode != 31
                if blendsScene || (draw.imageLayer == nil && (draw.copyBackground || !pass.framebufferSlots.isEmpty)) {
                    // Color blending samples the completed layer and the scene
                    // independently. Copy the scene before writing the result;
                    // source may instead be a shared offscreen layer texture.
                    let sceneSource = targets[current]
                    if blendsScene { inputs[4] = sceneSource }
                    let next = 1-current
                    glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), sceneSource.drawFramebuffer)
                    glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), targets[next].drawFramebuffer)
                    glBlitFramebuffer(0,0,GLint(width),GLint(height),0,0,GLint(width),GLint(height),GLbitfield(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT),GLenum(GL_NEAREST))
                    current = next
                }
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), targets[current].drawFramebuffer)
                bind(pass: pass, model: transform, view: camera.view, projection: draw.fullscreen ? matrix_identity_float4x4 : camera.projection, vp: draw.fullscreen ? matrix_identity_float4x4 : vp, time: Float(time), delta: delta, source: source, object: object, renderTargets: inputs, effectTransforms: effectTransforms, uniformValues: shapeUniforms)
                if let skeleton = draw.skeleton {
                    (draw.objectIndex.flatMap { modelAnimations[$0]?.palette } ?? skeleton.defaultPalette).withUnsafeBufferPointer {
                        glUniformMatrix4fv(pass.shader.location("g_NativeBones[0]"), GLsizei(skeleton.bones.count), GLboolean(GL_FALSE), $0.baseAddress)
                    }
                }
                setMatrix(vp * transform, name: "g_NativeCaptureMatrix", shader: pass.shader)
                if let image = draw.imageLayer { setBlend(image.blending) }
                if let clip = draw.puppetClip, let shape = draw.puppet?.model.shapes.first,
                   let maskTarget = puppetMaskTarget, maskTarget.width == width, maskTarget.height == height {
                    for command in clip.plan.commands {
                        switch command {
                        case .normal(let ranges):
                            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), targets[current].drawFramebuffer)
                            bind(pass: pass, model: transform, view: camera.view, projection: camera.projection,
                                 vp: vp, time: Float(time), delta: delta, source: source, object: object,
                                 renderTargets: inputs, effectTransforms: effectTransforms, uniformValues: shapeUniforms)
                            if let image = draw.imageLayer { setBlend(image.blending) }
                            draw.geometry.drawPuppetRanges(ranges, records: shape.rangeRecords)
                        case .masked(let mask, let sources, let targetsToDraw):
                            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), maskTarget.framebuffer)
                            glViewport(0, 0, GLsizei(width), GLsizei(height))
                            glClearColor(0, 0, 0, 0); glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                            bind(pass: clip.maskPass, model: transform, view: camera.view, projection: camera.projection,
                                 vp: vp, time: Float(time), delta: delta, source: source, object: object,
                                 renderTargets: inputs, effectTransforms: effectTransforms)
                            glActiveTexture(GLenum(GL_TEXTURE0 + 7)); glBindTexture(GLenum(GL_TEXTURE_2D), clip.textures[mask].name)
                            glUniform1i(clip.maskPass.shader.location("g_NativePuppetSourceMask"), 7)
                            glDisable(GLenum(GL_DEPTH_TEST)); glDepthMask(GLboolean(GL_FALSE)); glDisable(GLenum(GL_CULL_FACE))
                            glBlendEquation(GLenum(GL_FUNC_ADD)); setBlend("translucent")
                            draw.geometry.drawPuppetRanges(sources, records: shape.rangeRecords)
                            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), targets[current].drawFramebuffer)
                            bind(pass: clip.clippedPass, model: transform, view: camera.view, projection: camera.projection,
                                 vp: vp, time: Float(time), delta: delta, source: source, object: object,
                                 renderTargets: inputs, effectTransforms: effectTransforms, uniformValues: shapeUniforms)
                            glActiveTexture(GLenum(GL_TEXTURE0 + 7)); glBindTexture(GLenum(GL_TEXTURE_2D), maskTarget.texture)
                            glUniform1i(clip.clippedPass.shader.location("g_NativePuppetMask"), 7)
                            glUniform2f(clip.clippedPass.shader.location("g_NativeMaskResolution"), Float(width), Float(height))
                            if let image = draw.imageLayer { setBlend(image.blending) }
                            draw.geometry.drawPuppetRanges(targetsToDraw, records: shape.rangeRecords)
                            puppetMaskPasses += 1
                        }
                    }
                } else {
                    draw.geometry.draw()
                }
                if renderedFrames == 0, let group = pass.effectGroup {
                    fputs("Scene effect executed: \(draw.name), group \(group), final \(pass.definition["shader"] as? String ?? "native"), binds \(pass.graphBindings.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))\n", stderr)
                }
            }
        }
        if volumeBoundary == draws.count {
            renderPointVolumetrics(source: targets[current], vp: baseCamera.projection * baseCamera.view, time: time)
        }
        targets[current].resolveSamples()
        if needsReflectionHistory { reflectionHistory?.capture(source: targets[current], at: time) }
        do { try sceneHistory?.capture(source: targets[current], time: time) }
        catch { note("场景历史停止：" + error.localizedDescription); pause(); return }
        glDisable(GLenum(GL_DEPTH_TEST)); glDepthMask(GLboolean(GL_FALSE)); glDisable(GLenum(GL_BLEND)); glDisable(GLenum(GL_CULL_FACE))
        let bloom = postProcessingQuality.allowsBloom && generalValue("bloom") as? Bool == true
        var bloomTexture = targets[current].texture
        var finalBloomStrength: Float = 0
        if bloom, !sceneHDR, let standardBloom {
            let parameters = NativeStandardBloom.Parameters(
                strength: SceneValues.number(generalValue("bloomstrength"), 2),
                threshold: SceneValues.number(generalValue("bloomthreshold"), 0.65),
                tint: SceneValues.vector(generalValue("bloomtint"), SIMD3(repeating: 1)))
            if let completed = standardBloom.render(source: targets[current], parameters: parameters, at: time, drawQuad: { screenQuad.draw() }) {
                bloomTexture = completed.texture
                // Strength and tint were already applied before blur and RGBA8
                // storage. Applying strength again here changes the reference.
                finalBloomStrength = 1
            } else { note("普通泛光参数无法安全表示或尺寸不匹配，本帧不合成泛光；场景本身继续显示。") }
        } else if bloom, sceneHDR, let hdrBloom {
            var general: [String: Any] = [:]
            for key in sceneBloomProperties { general[key] = generalValue(key) }
            if let completed = hdrBloom.render(source: targets[current], parameters: NativeHDRBloomParameters(general: general), time: time, draw: { screenQuad.draw() }) {
                bloomTexture = completed.texture; finalBloomStrength = 1
            } else { note("HDR 泛光参数或尺寸无效，本帧只显示原场景。") }
        }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), outputFramebuffer)
        glViewport(0,0,GLsizei(outputWidth),GLsizei(outputHeight))
        glUseProgram(presentShader.program)
        bindTexture(targets[current].texture, slot: 0, shader: presentShader)
        // The non-bloom target has never been rendered into. Bind defined pixels
        // even with strength=0 so an uninitialized floating-point NaN cannot leak.
        bindTexture(bloomTexture, slot: 1, shader: presentShader)
        glUniform1f(presentShader.location("strength"), finalBloomStrength)
        glUniform1i(presentShader.location("hdrBloom"), sceneHDR && finalBloomStrength != 0 ? 1 : 0)
        let fade = NativeCameraFade(enabled: generalValue("camerafade") as? Bool ?? true, amount: legacyCamera.fadeAmount, tint: NativeCameraFade.tint(properties: properties))
        glUniform4f(presentShader.location("cameraFade"), fade.color.x, fade.color.y, fade.color.z, fade.amount)
        glUniform2f(presentShader.location("sampleStep"), 1/Float(targets[current].width), 1/Float(targets[current].height))
        screenQuad.draw()
        glUseProgram(0)
        sceneClock.recordSubmittedFrame(time: time)
    }

    private func graphInputs(_ pass: ScenePass, layer: SceneImageLayer, previous: SceneTarget) -> [Int: SceneTarget] {
        var inputs: [Int: SceneTarget] = [:]
        for (slot, key) in pass.graphBindings {
            inputs[slot] = key == SceneEffectGraph.previous ? previous : layer.namedTargets[key]
        }
        return inputs
    }

    private func layerCompositeID(_ name: String) -> String? {
        let prefix = "_rt_imageLayerComposite_"
        guard name.hasPrefix(prefix), name.hasSuffix("_a") else { return nil }
        let id = String(name.dropFirst(prefix.count).dropLast(2))
        guard let value = Int(id), value >= 0, String(value) == id else { return nil }
        return id
    }

    /// Resolve references from compiled, active sampler bindings. A published
    /// image is independent of scene order and of its layer's on-screen visibility.
    private func configureLayerComposites(objects: [[String: Any]]) {
        func passes(_ draw: SceneDraw) -> [ScenePass] { (draw.imageLayer?.stages ?? []) + draw.passes }
        let requested = Set(draws.flatMap { passes($0).flatMap { $0.layerCompositeSlots.values } })
        guard !requested.isEmpty else { return }
        guard requested.count <= 64 else { note("图层纹理引用超过当前 64 个源图层上限，相关效果未启用。"); return }
        var candidates: [String: [Int]] = [:]
        for index in draws.indices {
            if let objectIndex = draws[index].objectIndex {
                candidates[SceneScriptBridge.objectID(objects[objectIndex], index: objectIndex), default: []].append(index)
            }
        }
        var visiting = Set<String>(), valid = Set<String>(), invalid = Set<String>()
        func visit(_ id: String) -> Bool {
            if valid.contains(id) { return true }
            if invalid.contains(id) { return false }
            if visiting.contains(id) { invalid.insert(id); note("图层纹理引用存在循环：\(id)。"); return false }
            guard let indices = candidates[id], indices.count == 1,
                  let index = indices.first, let layer = draws[index].imageLayer,
                  let objectIndex = draws[index].objectIndex,
                  objects[objectIndex]["shape"] == nil, draws[index].skeleton == nil,
                  draws[index].puppetClip == nil, !draws[index].captureBackground,
                  layer.colorBlendMode == 0, !draws[index].fullscreen else {
                invalid.insert(id); note("图层纹理源 \(id) 缺失、重复，或不是当前支持的独立图片/文字图层。"); return false
            }
            let sourcePasses = passes(draws[index])
            guard sourcePasses.first?.framebufferSlots.contains(0) == false,
                  sourcePasses.allSatisfy({ pass in
                      pass.mipmappedFramebufferSlots.isEmpty && !(pass.definition["textures"] as? [Any] ?? []).compactMap({ $0 as? String }).contains("_rt_FullFrameBuffer")
                  }) else {
                invalid.insert(id); note("图层纹理源 \(id) 依赖场景帧缓冲，尚未支持导出。"); return false
            }
            visiting.insert(id)
            let dependencies = Set(sourcePasses.flatMap { $0.layerCompositeSlots.values }).sorted()
            var complete = true
            for dependency in dependencies { if !visit(dependency) { complete = false } }
            visiting.remove(id)
            guard complete, !invalid.contains(id) else { invalid.insert(id); return false }
            valid.insert(id); compositeOrder.append((id, index)); return true
        }
        for id in requested.sorted() { _ = visit(id) }
        note("图层纹理引用：\(compositeOrder.count)/\(requested.count) 个源按依赖顺序离屏绘制，隐藏状态仅控制其进入桌面；结果使用独立缓冲。支持图片/文字的 _rt_imageLayerComposite_<id>_a，场景合成、循环、骨架/形状源与其他后缀仍待实现。")
    }

    private func activePasses(_ passes: [ScenePass]) -> [ScenePass] {
        // An unavailable input disables the whole image effect, including its
        // intermediate stages. Never sample a previous frame or another layer.
        let blockedGroups = Set(passes.filter { !$0.layerCompositeSlots.values.allSatisfy(compositeReady.contains) }.compactMap(\.effectGroup))
        return passes.filter {
            passVisible($0) && $0.layerCompositeSlots.values.allSatisfy(compositeReady.contains)
                && ($0.effectGroup.map { !blockedGroups.contains($0) } ?? true)
        }
    }

    private func renderLayerComposites(states: [[String: Any]], transforms: [simd_float4x4],
                                       visibility: [Bool], offsets: [SIMD3<Float>], baseCamera: SceneCamera,
                                       time: Double, delta: Float) {
        compositeReady.removeAll(keepingCapacity: true)
        var descriptions: [String] = []
        for entry in compositeOrder {
            guard let objectIndex = draws[entry.draw].objectIndex else { continue }
            let object = states[objectIndex]
            updateText(entry.draw, object: object)
            let draw = draws[entry.draw]
            guard let layer = draw.imageLayer else { continue }
            let allPasses = layer.stages + draw.passes
            guard allPasses.flatMap({ $0.layerCompositeSlots.values }).allSatisfy(compositeReady.contains) else { continue }
            let active = activePasses(allPasses)
            guard !active.isEmpty, let camera = parallaxCamera(baseCamera, offset: offsets[objectIndex]) else { continue }
            let size = SIMD2<Float>(2 / abs(layer.projection.columns.0.x), 2 / abs(layer.projection.columns.1.y))
            let factor = min(1, 4096 / max(size.x, size.y))
            let width = max(1, Int(ceil(size.x * factor))), height = max(1, Int(ceil(size.y * factor)))
            do {
                if compositeTargets[entry.id]?.width != width || compositeTargets[entry.id]?.height != height {
                    let oldPixels = compositeTargets[entry.id].map { $0.width * $0.height } ?? 0
                    let difference = width * height - oldPixels
                    guard layerTargetPixels + difference <= layerTargetPixelLimit else { throw SceneError.invalid("图层纹理输出超过场景 \(layerTargetLimitDescription) 像素上限。") }
                    let target = try SceneTarget(width: width, height: height, withDepth: false, hdr: sceneHDR)
                    compositeTargets[entry.id] = target; layerTargetPixels += difference
                }
                guard let output = compositeTargets[entry.id] else { continue }
                var model = transforms[objectIndex]
                if let text = draw.text { model = text.anchor.model(model, margins: textAnchorMargins) }
                let offset = draw.alignmentOffset + (draw.text?.offset ?? .zero)
                var translation = matrix_identity_float4x4; translation.columns.3 = SIMD4(offset.x, offset.y, 0, 1)
                model = model * translation
                let vp = camera.projection * camera.view
                let effectTransforms = SceneEffectTransforms(layerModel: model, sceneViewProjection: vp, layerSize: size)
                var source = targets[0], effectInput: SceneTarget?, group: Int?
                var completed = true
                for (index, pass) in active.enumerated() {
                    if pass.effectGroup != group { group = pass.effectGroup; effectInput = group == nil ? nil : source }
                    var inputs = graphInputs(pass, layer: layer, previous: effectInput ?? source)
                    for (slot, id) in pass.layerCompositeSlots { inputs[slot] = compositeTargets[id] }
                    let destination: SceneTarget?
                    if let key = pass.graphTarget { destination = layer.namedTargets[key] }
                    else if index == active.count - 1 { destination = output }
                    else { destination = layer.targets.first { candidate in candidate !== source && candidate !== effectInput && !inputs.values.contains(where: { $0 === candidate }) } }
                    guard let destination, destination !== source, !inputs.values.contains(where: { $0 === destination }) else {
                        throw SceneError.invalid("图层纹理源缺少独立工作缓冲或发生读写冲突。")
                    }
                    glBindFramebuffer(GLenum(GL_FRAMEBUFFER), destination.framebuffer)
                    glViewport(0, 0, GLsizei(destination.width), GLsizei(destination.height))
                    glClearColor(0,0,0,0); glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
                    bind(pass: pass, model: matrix_identity_float4x4, view: matrix_identity_float4x4,
                         projection: layer.projection, vp: layer.projection, time: Float(time), delta: delta,
                         source: source, object: object, renderTargets: inputs, effectTransforms: effectTransforms,
                         layerGeometry: pass.usesSceneTransforms)
                    glDisable(GLenum(GL_BLEND)); glDisable(GLenum(GL_DEPTH_TEST)); glDepthMask(GLboolean(GL_FALSE)); glDisable(GLenum(GL_CULL_FACE))
                    if pass.usesSceneTransforms { draw.geometry.draw() } else { screenQuad.draw() }
                    if pass.graphTarget == nil { source = destination }
                    if index == active.count - 1, destination !== output { completed = false }
                }
                let error = glGetError()
                guard completed, error == 0 else { throw SceneError.invalid("图层纹理输出未完成，GL=\(error)。") }
                compositeReady.insert(entry.id)
                descriptions.append("\(entry.id)=\(width)×\(height)，隐藏=\(!visibility[objectIndex])")
            } catch {
                let message = "图层纹理源 \(entry.id)：\(error.localizedDescription)"
                if !diagnosticNotes.contains(message) { note(message) }
            }
        }
        if !compositeOrder.isEmpty {
            compositeFrames += 1
            compositeRuntimeDiagnostic = "图层纹理快照：场景时间 \(String(format: "%.6f", time)) 秒，完成 \(compositeReady.count)/\(compositeOrder.count)，重绘 \(compositeFrames) 帧；\(descriptions.joined(separator: "；"))。结果保持至本帧消费者完成，隐藏源不单独绘制到桌面。"
        }
    }

    private func resolvedUniforms(pass: ScenePass, object: [String: Any]?) -> [String: [Float]] {
        var uniforms = pass.uniforms
        for (uniform, key) in pass.userUniforms {
            let value = SceneValues.floats(properties[key])
            if !value.isEmpty, value.count <= 4, value.allSatisfy(\.isFinite) { uniforms[uniform] = value }
        }
        for (uniform, path) in pass.timelineUniforms {
            let value = SceneValues.floats(timelines.value(at: path, time: currentSceneTime, base: uniforms[uniform]))
            if !value.isEmpty, value.count <= 4, value.allSatisfy(\.isFinite) { uniforms[uniform] = value }
        }
        for (uniform, key) in pass.scriptUniforms {
            let value = SceneValues.floats(scripts?.value(at: key, fallback: nil))
            if !value.isEmpty, value.count <= 4, value.allSatisfy(\.isFinite) { uniforms[uniform] = value }
        }
        for (uniform, path) in pass.materialUniforms {
            if let value = scripts?.materialValues[path] { uniforms[uniform] = value }
        }
        if let object, pass.applyObjectAppearance {
            let color = SceneValues.vector(object["color"], SIMD3(repeating: 1))
            uniforms["g_NativeImageColor"] = [color.x, color.y, color.z]
            uniforms["g_NativeImageOpacity"] = [max(0, min(1, SceneValues.number(object["alpha"] ?? object["opacity"], 1)))]
            let background = SceneValues.vector(object["backgroundcolor"], .zero) * SceneValues.number(object["backgroundbrightness"], 1)
            uniforms["g_NativeTextBackground"] = [background.x, background.y, background.z]
            uniforms["g_NativeTextOpaque"] = [object["text"] != nil && object["opaquebackground"] as? Bool == true ? 1 : 0]
        }
        return uniforms
    }

    private func bind(pass: ScenePass, model: simd_float4x4, view: simd_float4x4, projection: simd_float4x4, vp: simd_float4x4, time: Float, delta: Float, source: SceneTarget, object: [String: Any]? = nil, renderTargets: [Int: SceneTarget] = [:], effectTransforms: SceneEffectTransforms? = nil, layerGeometry: Bool = true, uniformValues: [String: [Float]]? = nil) {
        let shader = pass.shader
        glUseProgram(shader.program)
        if pass.definition["depthtest"] as? String == "enabled" { glEnable(GLenum(GL_DEPTH_TEST)); glDepthFunc(GLenum(GL_LEQUAL)) } else { glDisable(GLenum(GL_DEPTH_TEST)) }
        glDepthMask(GLboolean(pass.definition["depthwrite"] as? String == "enabled" ? GL_TRUE : GL_FALSE))
        if pass.definition["cullmode"] as? String == "normal" { glEnable(GLenum(GL_CULL_FACE)); glCullFace(GLenum(GL_BACK)); glFrontFace(GLenum(GL_CCW)) } else { glDisable(GLenum(GL_CULL_FACE)) }
        setBlend(pass.definition["blending"] as? String ?? "normal")
        let uniforms = uniformValues ?? resolvedUniforms(pass: pass, object: object)
        if shader.usesNativeImageBlur {
            imageBlurBindings += 1
            if imageBlurVariants.count < 16 {
                let label = pass.definition["shader"] as? String ?? "unknown"
                let kernel = shader.resolvedCombos["KERNEL"].map(String.init) ?? "unset"
                let alpha = shader.resolvedCombos["BLURALPHA"].map(String.init) ?? "unset"
                let axis = shader.resolvedCombos["VERTICAL"].map(String.init) ?? "unset"
                let scale = (uniforms["g_Scale"] ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")
                imageBlurVariants.insert("\(label) KERNEL=\(kernel) BLURALPHA=\(alpha) VERTICAL=\(axis) scale=[\(scale)]")
            }
        }
        for (name, value) in uniforms {
            let location = shader.location(name)
            if let type = shader.uniformMetadata[name]?["glslType"] as? String, ["int", "bool"].contains(type), let first = value.first {
                glUniform1i(location, GLint(max(Float(Int32.min), min(Float(Int32.max - 128), first))))
                continue
            }
            switch value.count {
            case 1: glUniform1f(location,value[0])
            case 2: glUniform2f(location,value[0],value[1])
            case 3: glUniform3f(location,value[0],value[1],value[2])
            case 4: glUniform4f(location,value[0],value[1],value[2],value[3])
            default: break
            }
        }
        for (name, matrix) in ["g_ModelMatrix": model, "g_ViewMatrix": view, "g_ProjectionMatrix": projection, "g_ViewProjectionMatrix": vp, "g_ModelViewProjectionMatrix": vp * model] {
            var matrix = matrix
            withUnsafePointer(to: &matrix) { pointer in pointer.withMemoryRebound(to: Float.self, capacity: 16) { glUniformMatrix4fv(shader.location(name),1,GLboolean(GL_FALSE),$0) } }
        }
        bindFrameUniforms(shader: shader, model: model, vp: vp, object: object, effects: effectTransforms, layerGeometry: layerGeometry, authoredUniforms: Set(uniforms.keys))
        if pass.nativeModelMaterial {
            glUniform1i(shader.location("g_NativeReflectionEnabled"), reflectionsEnabled ? 1 : 0)
            bindModelLighting(shader: shader, model: model)
            if modelLightFrame.lights.contains(where: { $0.projection != nil }), shader.location("g_Texture7") < 0 {
                note("投影灯光已启用，但此受光材质没有显式投影资源；对应灯光输出黑色，资源别名尚未解析。")
            }
            glUniform1i(shader.location("g_NativeNormalFormat"), GLint(pass.textures[1]?.sourceType ?? 0))
            glUniform1i(shader.location("g_NativeGradientFormat"), GLint(pass.textures[4]?.sourceType ?? 0))
        }
        glUniform1f(shader.location("g_Time"),time)
        glUniform1f(shader.location("g_DeltaTime"),delta)
        glUniform1f(shader.location("g_Frametime"),delta)
        for resolution in [16,32,64] {
            guard let channels = audioSpectrum.bands[resolution] else { continue }
            for (suffix, values) in [("Left", channels.left), ("Right", channels.right)] {
                let location = shader.location("g_AudioSpectrum\(resolution)\(suffix)[0]")
                if location >= 0 { values.withUnsafeBufferPointer { glUniform1fv(location, GLsizei(resolution), $0.baseAddress) } }
            }
        }
        for slot in 0..<(pass.nativeModelMaterial && shader.location("g_Texture8") >= 0 ? 9 : 8) {
            var width = source.width, height = source.height, imageWidth = source.width, imageHeight = source.height
            var channels = 4
            var mipMapInfo: Float = 0
            if let target = renderTargets[slot] ?? pass.layerCompositeSlots[slot].flatMap({ compositeReady.contains($0) ? compositeTargets[$0] : nil }) {
                bindTexture(target.texture, slot: slot, shader: shader)
                width = target.width; height = target.height; imageWidth = target.width; imageHeight = target.height
            }
            else if pass.nativeModelMaterial && !reflectionsEnabled && pass.mipmappedFramebufferSlots.contains(slot) {
                bindTexture(0, slot: slot, shader: shader)
            }
            else if pass.mipmappedFramebufferSlots.contains(slot), let history = reflectionHistory {
                let target = history.sample
                bindTexture(target.texture, slot: slot, shader: shader)
                width = target.width; height = target.height; imageWidth = target.width; imageHeight = target.height
                mipMapInfo = history.mipMapInfo
                history.sampleBindings += 1
            }
            else if pass.framebufferSlots.contains(slot) { bindTexture(source.texture, slot: slot, shader: shader) }
            else if let texture = pass.textures[slot] {
                bindTexture(texture.name,slot:slot,shader:shader)
                width = texture.width; height = texture.height; imageWidth = texture.imageWidth; imageHeight = texture.imageHeight
                channels = texture.channelCount
            }
            glUniform4f(shader.location("g_Texture\(slot)Resolution"),Float(width),Float(height),Float(imageWidth),Float(imageHeight))
            if pass.mipmappedFramebufferSlots.contains(slot) {
                glUniform1f(shader.location("g_Texture\(slot)MipMapInfo"), mipMapInfo)
            }
            if slot == 0 {
                glUniform1i(shader.location("g_NativeTextureChannels"), GLint(channels))
                var rect = SIMD4<Float>(0, 0, Float(imageWidth) / Float(width), Float(imageHeight) / Float(height))
                var animated = false
                if renderTargets[0] == nil, pass.layerCompositeSlots[0] == nil, !pass.framebufferSlots.contains(0),
                   let animation = pass.textures[0]?.animation {
                    var animationTime = Double(time), staticFrame: Int?
                    if let object {
                        let id = SceneScriptBridge.objectID(object, index: -1)
                        animationTime = scripts?.texturePlayback[id]?.time(at: Double(time)) ?? animationTime
                        staticFrame = scripts?.texturePlayback[id]?.staticFrame
                    }
                    rect = animation.uv(at: animationTime, atlasWidth: width, atlasHeight: height, staticFrame: staticFrame)
                    animated = true
                }
                glUniform4f(shader.location("g_NativeAtlasRect"), rect.x, rect.y, rect.z, rect.w)
                glUniform1i(shader.location("g_NativeAtlasEnabled"), animated ? 1 : 0)
            }
            if slot == 7, pass.nativeModelMaterial {
                var rect = SIMD4<Float>(0,0,Float(imageWidth)/Float(width),Float(imageHeight)/Float(height))
                if renderTargets[7] == nil, pass.layerCompositeSlots[7] == nil, let animation = pass.textures[7]?.animation {
                    rect = animation.uv(at:Double(time),atlasWidth:width,atlasHeight:height,staticFrame:nil)
                }
                glUniform4f(shader.location("g_NativeProjectionRegion"),rect.x,rect.y,rect.z,rect.w)
                glUniform1i(shader.location("g_NativeProjectionNearest"),pass.textures[7]?.nearest == true ? 1 : 0)
            }
        }
    }

    private func setMatrix(_ value: simd_float4x4, name: String, shader: SceneShader) {
        let location = shader.location(name)
        guard location >= 0 else { return }
        var matrix = value
        withUnsafePointer(to: &matrix) { pointer in pointer.withMemoryRebound(to: Float.self, capacity: 16) { glUniformMatrix4fv(location, 1, GLboolean(GL_FALSE), $0) } }
    }

    private func updateModelLighting(states: [[String: Any]], transforms: [simd_float4x4],
                                     visibility: [Bool], time: Double) {
        guard modelInstanceCount > 0 || states.contains(where: { $0["light"] is String }) else { modelLightFrame = .init(); return }
        var frame = NativeModelLightFrame()
        let lightConfig = (scene["general"] as? [String: Any])?["lightconfig"] as? [String: Any]
        let configuredShadows = max(0, min(Float(NativePointShadows.maximumLights), SceneValues.number(lightConfig?["pointshadow"], 0)))
        let shadowLimit = Int(configuredShadows)
        let spotLimit = Int(max(0,min(Float(NativeModelLightFrame.maximumLights),SceneValues.number(lightConfig?["spotshadow"],0))))
        var shadowCount = 0, spotCount = 0
        frame.ambient = SceneValues.vector(generalValue("ambientcolor"), frame.ambient)
        frame.skylight = SceneValues.vector(generalValue("skylightcolor"), frame.skylight)
        for index in states.indices where visibility[index] {
            let state = states[index]
            guard let kind = state["light"] as? String else { continue }
            guard ["lpoint", "lspot", "ldirectional"].contains(kind), frame.lights.count < NativeModelLightFrame.maximumLights else {
                frame.rejected += 1; continue
            }
            let intensity = max(0, SceneValues.number(state["intensity"], 1))
            let color = SceneValues.vector(state["color"], SIMD3(repeating: 1)) * intensity
            let exponent = max(0, SceneValues.number(state["exponent"], 2))
            let matrix = transforms[index]
            let location: SIMD4<Float>
            if kind == "ldirectional" {
                // REA Scene::UpdateLightingState, kind 3: negate world column 0.
                // Light::InitProps maps ldirectional to kind 3. The shader uses
                // this as world-to-light; do not substitute the camera's Z axis.
                let axis = -SIMD3<Double>(Double(matrix[0].x), Double(matrix[0].y), Double(matrix[0].z))
                let length = simd_length(axis)
                guard length.isFinite, length > 0 else { frame.rejected += 1; continue }
                location = SIMD4(SIMD3<Float>(axis / length), 0)
            } else {
                let radius = SceneValues.number(state["radius"], 5)
                guard radius > 0 else { frame.rejected += 1; continue }
                location = SIMD4(matrix[3].x, matrix[3].y, matrix[3].z, radius)
            }
            guard [color.x, color.y, color.z, location.x, location.y, location.z, location.w, exponent].allSatisfy(\.isFinite) else {
                frame.rejected += 1; continue
            }
            let spot = kind == "lspot" ? NativeModelLightFrame.spotCone(object: state, transform: matrix) : nil
            if kind == "lspot", spot == nil, !SceneValues.visible(state["usecookie"] ?? false) { frame.rejected += 1; continue }
            var projection: NativeSpotProjection?
            if SceneValues.visible(state["usecookie"] ?? false) {
                guard kind == "lspot", let value = NativeSpotProjection(outerDegrees:SceneValues.number(state["outercone"],30),
                    radius:location.w,transform:matrix) else {
                    frame.rejected += 1; note("投影灯光需要聚光灯、非退化变换和 0 < 外锥角 < 90 度。"); continue
                }
                projection = value
            }
            var shadowNear: Float?
            var spotShadow: NativeSpotShadows?
            if kind == "lspot", SceneValues.visible(state["castshadow"] ?? false), spotCount < spotLimit {
                if let value = NativeSpotShadows(object: state,transform: matrix) { spotShadow = value; shadowNear = NativeSpotShadows.near; spotCount += 1 }
                else { frame.rejected += 1; note("聚光阴影需要非退化变换和 0 < 外锥角 < 90 度；当前保留直接照明。") }
            }
            if kind == "lpoint", SceneValues.visible(state["castshadow"] ?? false) {
                if shadowCount < shadowLimit {
                    // REA Light::InitProps maps lightsourcesize to +0x284;
                    // the ordinary-depth point projection clamps it to 0.05.
                    shadowNear = max(0.05, SceneValues.number(state["lightsourcesize"], 0.05))
                    shadowCount += 1
                } else {
                    note("点光源阴影数量受 scene.general.lightconfig.pointshadow 和原生最多 4 盏的限制；超出灯光仍提供直接照明。")
                }
            }
            var volumetrics: SIMD2<Float>?
            if kind == "lpoint", SceneValues.visible(state["castvolumetrics"] ?? false) {
                let density = max(0, SceneValues.number(state["density"], 2))
                let power = max(0, SceneValues.number(state["volumetricsexponent"], 1))
                volumetrics = SIMD2(density, power)
            }
            frame.lights.append(.init(positionRadius: location, colorExponent: SIMD4(color, exponent),
                                      shadowNear: shadowNear, volumetrics: volumetrics, spot: spot, spotShadow: spotShadow, projection: projection))
        }
        if generalValue("fogdistance") as? Bool == true {
            let start = SceneValues.number(generalValue("fogdistancestart"), 0)
            let end = SceneValues.number(generalValue("fogdistanceend"), 1)
            let first = SceneValues.number(generalValue("fogdistancestartdensity"), 0)
            let last = SceneValues.number(generalValue("fogdistanceenddensity"), 1)
            let span = end - start, densityRange = last - first
            if span.isFinite, span > 0, densityRange.isFinite {
                frame.fogEnabled = true
                frame.fogParams = SIMD4(start, span, first, densityRange)
                frame.fogColor = SceneValues.vector(generalValue("fogdistancecolor"), .zero)
            } else { frame.rejected += 1 }
        }
        modelLightFrame = frame
        let lights = frame.lights.map { "位置/半径=\($0.positionRadius)，颜色/指数=\($0.colorExponent)" }.joined(separator: "; ")
        var skeletonDetail = ""
        if let index = draws.first(where: { $0.skeleton != nil })?.objectIndex {
            skeletonDetail = " 首个骨架实例 id=\(states[index]["id"] ?? "unknown")，世界位置=\(transforms[index].columns.3)，角度弧度=\(SceneValues.vector(states[index]["angles"], .zero))。"
        }
        let animationDetail = modelAnimations.keys.sorted().map { key in
            let value = modelAnimations[key]!
            return "对象 \(key)：\(value.layers.count) 层，时钟 \(value.states.map { String(format: "%.6f", $0.clock.time) }.joined(separator: ","))，推进 \(value.advances)，姿态 \(value.revision)"
        }.joined(separator: "; ")
        modelRuntimeDiagnostic = "模型运行快照：场景时间 \(String(format: "%.3f", time)) 秒；\(modelInstanceCount) 个实例共用 \(modelShapeCount) 个网格，几何缓冲 \(modelBufferBytes) 字节；骨架 \(skeletonResourceCount) 份 / 蒙皮实例 \(skinnedModelInstanceCount) 个 / 动画数据 \(modelAnimationBytes) 字节；独立骨骼动画实例 \(modelAnimations.count)：\(animationDetail)；直接灯光 \(frame.lights.count)，拒绝/超限 \(frame.rejected)，距离雾=\(frame.fogEnabled)，参数=\(frame.fogParams)。\(lights)\(skeletonDetail)"
    }

    private func renderPointShadows(states: [[String: Any]], transforms: [simd_float4x4], visibility: [Bool], time: Double) {
        let lightCount = modelLightFrame.lights.filter { $0.shadowNear != nil }.count
        guard lightCount > 0, shadowQuality != .disabled else { pointShadows = nil; shadowAllocationFailed = false; return }
        guard !shadowAllocationFailed else { return }
        if pointShadows?.capacity != lightCount || pointShadows?.quality != shadowQuality {
            do { pointShadows = try NativePointShadows(capacity: lightCount, quality: shadowQuality) }
            catch {
                pointShadows = nil; shadowAllocationFailed = true
                note("点光源阴影未绘制：\(error.localizedDescription)")
                return
            }
        }
        let casters = draws.filter { draw in
            guard let index = draw.objectIndex, states[index]["model"] is String,
                  visibility[index], SceneValues.visible(states[index]["castshadow"]) else { return false }
            if !draw.passes.contains(where: { $0.shadowShader != nil }) {
                note("\(draw.name)：当前材质不在点光阴影投射支持范围内。")
                return false
            }
            return true
        }
        pointShadows?.render(lights: modelLightFrame.lights, time: time) { vp in
            var submitted = 0, culled = 0
            for draw in casters {
                guard let index = draw.objectIndex else { continue }
                let mvp = vp * transforms[index]
                // A bind-pose AABB cannot cull an animated mesh safely. Submit
                // animated casters until a conservative animated bound is built.
                if modelAnimations[index] == nil && draw.modelBounds?.isOutside(mvp) == true { culled += 1; continue }
                for pass in draw.passes where passVisible(pass) {
                    guard let shader = pass.shadowShader else { continue }
                    glUseProgram(shader.program)
                    if pass.definition["cullmode"] as? String == "normal" {
                        glEnable(GLenum(GL_CULL_FACE)); glCullFace(GLenum(GL_BACK)); glFrontFace(GLenum(GL_CCW))
                    } else { glDisable(GLenum(GL_CULL_FACE)) }
                    setMatrix(mvp, name: "g_NativeShadowMatrix", shader: shader)
                    if let skeleton = draw.skeleton {
                        (modelAnimations[index]?.palette ?? skeleton.defaultPalette).withUnsafeBufferPointer {
                            glUniformMatrix4fv(shader.location("g_NativeBones[0]"), GLsizei(skeleton.bones.count), GLboolean(GL_FALSE), $0.baseAddress)
                        }
                    }
                    draw.geometry.draw(); submitted += 1
                }
            }
            return (submitted, culled)
        }
    }

    private func pointVolumeBoundary(states: [[String: Any]], visibility: [Bool], drawOrder: [Int]) -> Int? {
        guard volumetricQuality != .disabled, modelLightFrame.lights.contains(where: { $0.volumetrics != nil }) else {
            pointVolumetrics = nil; volumeAllocationFailed = false; return nil
        }
        guard !isOrthogonalScene else {
            pointVolumetrics = nil
            note("点光源体积光尚未接入二维逐层视差场景。")
            return nil
        }
        let visible = drawOrder.indices.filter { position in
            draws[drawOrder[position]].objectIndex.map { visibility[$0] } ?? true
        }
        let models = visible.filter { position in draws[drawOrder[position]].objectIndex.map { states[$0]["model"] is String } ?? false }
        let opaque = models.allSatisfy { position in draws[drawOrder[position]].passes.allSatisfy {
            $0.nativeModelMaterial && ($0.definition["blending"] as? String ?? "normal") == "normal"
                && $0.definition["depthwrite"] as? String == "enabled"
        } }
        // A single opaque block can have background images before it. Mixed
        // translucent/model blocks require the reference's full sort pipeline.
        let contiguous = models.first.map { first in
            let last = models.last!
            return visible.filter { $0 >= first && $0 <= last }.count == models.count
        } ?? true
        guard opaque, contiguous else {
            pointVolumetrics = nil
            note("点光源体积光：当前模型与透明层的交错/材质超出已恢复的合成顺序，保留原绘制顺序并跳过体积光。")
            return nil
        }
        return models.last.map { $0 + 1 } ?? 0
    }

    private func renderPointVolumetrics(source: SceneTarget, vp: simd_float4x4, time: Double) {
        guard !volumeAllocationFailed else { return }
        source.resolveSamples()
        defer {
            source.seedSamples(depth: false)
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), source.drawFramebuffer)
            glViewport(0, 0, GLsizei(source.width), GLsizei(source.height))
        }
        if pointVolumetrics?.width != source.width || pointVolumetrics?.height != source.height || pointVolumetrics?.quality != volumetricQuality {
            do {
                pointVolumetrics = try NativePointVolumetrics(width: source.width, height: source.height,
                    hdr: sceneHDR, previous: pointVolumetrics, quality: volumetricQuality)
            } catch {
                pointVolumetrics = nil; volumeAllocationFailed = true
                note("点光源体积光未合成：\(error.localizedDescription)")
                glBindFramebuffer(GLenum(GL_FRAMEBUFFER), source.framebuffer)
                glViewport(0, 0, GLsizei(source.width), GLsizei(source.height))
                return
            }
        }
        pointVolumetrics?.render(source: source, frame: modelLightFrame, shadows: pointShadows,
                                 viewProjection: vp, eye: frameCameraInputs.eye, time: time)
    }

    private func bindModelLighting(shader: SceneShader, model: simd_float4x4) {
        let authoredNormal = NativeModelMaterial.normalMatrix(model)
        if authoredNormal == nil {
            note("静态模型出现不可逆或非有限变换；法线矩阵临时使用单位矩阵，几何仍保留作者变换。该帧照明属于回退结果。")
        }
        var normal = authoredNormal ?? matrix_identity_float3x3
        withUnsafePointer(to: &normal) { pointer in
            // SIMD3 columns have padding; explicitly pack the nine GL values.
            let packed = (0..<3).flatMap { column in (0..<3).map { pointer.pointee[column][$0] } }
            packed.withUnsafeBufferPointer { glUniformMatrix3fv(shader.location("g_NativeNormalMatrix"), 1, GLboolean(GL_FALSE), $0.baseAddress) }
        }
        let frame = modelLightFrame
        for (name, color) in [("g_NativeAmbient", frame.ambient), ("g_NativeSkylight", frame.skylight), ("g_NativeFogColor", frame.fogColor)] {
            glUniform3f(shader.location(name), color.x, color.y, color.z)
        }
        glUniform1i(shader.location("g_NativeLightCount"), GLint(frame.lights.count))
        glUniform1i(shader.location("g_NativeShadowQuality"), GLint(shadowQuality.index))
        // Chroma's authored noise occupies slot 8. Keep the owned shadow
        // sampler on a separate unit when that sampler is active.
        let shadowSlot: GLint = shader.location("g_Texture8") >= 0 ? 9 : 8
        glActiveTexture(GLenum(GL_TEXTURE0 + shadowSlot)); glBindTexture(GLenum(GL_TEXTURE_2D), pointShadows?.texture ?? 0)
        glUniform1i(shader.location("g_NativeShadowAtlas"), shadowSlot)
        if let pointShadows {
            let scale = pointShadows.scale
            glUniform4f(shader.location("g_NativeShadowScale"), scale.x, scale.y, scale.z, scale.w)
        }
        for (index, light) in frame.lights.enumerated() {
            for (name, value) in [("g_NativeLightPositionRadius", light.positionRadius), ("g_NativeLightColorExponent", light.colorExponent),
                                  ("g_NativeLightSpotDirection", light.spotDirection), ("g_NativeLightSpotParameters", light.spotParameters),
                                  ("g_NativeSpotShadowRight", light.shadowRows[0]), ("g_NativeSpotShadowUp", light.shadowRows[1]), ("g_NativeSpotShadowForward", light.shadowRows[2]),
                                  ("g_NativeProjectionRight", light.projectionRows[0]), ("g_NativeProjectionUp", light.projectionRows[1]), ("g_NativeProjectionForward", light.projectionRows[2])] {
                glUniform4f(shader.location("\(name)[\(index)]"), value.x, value.y, value.z, value.w)
            }
            let shadow = pointShadows?.bindings[index] ?? .zero
            glUniform4f(shader.location("g_NativeLightShadow[\(index)]"), shadow.x, shadow.y, shadow.z, shadow.w)
        }
        glUniform1i(shader.location("g_NativeFogEnabled"), frame.fogEnabled ? 1 : 0)
        let fog = frame.fogParams
        glUniform4f(shader.location("g_NativeFogParams"), fog.x, fog.y, fog.z, fog.w)
    }

    private func bindFrameUniforms(shader: SceneShader, model: simd_float4x4, vp: simd_float4x4,
                                   object: [String: Any]?, effects: SceneEffectTransforms?, layerGeometry: Bool,
                                   authoredUniforms: Set<String>) {
        let state = frameUniforms
        glUniform2f(shader.location("g_PointerPosition"), state.pointer.x, state.pointer.y)
        glUniform2f(shader.location("g_PointerPositionLast"), state.previousPointer.x, state.previousPointer.y)
        glUniform2f(shader.location("g_ParallaxPosition"), state.parallax.x, state.parallax.y)
        glUniform1f(shader.location("g_Daytime"), state.daytime)
        glUniform3f(shader.location("g_Screen"), state.screen.x, state.screen.y, state.screen.x / state.screen.y)
        glUniform2f(shader.location("g_TexelSize"), 1 / state.screen.x, 1 / state.screen.y)
        glUniform2f(shader.location("g_TexelSizeHalf"), 0.5 / state.screen.x, 0.5 / state.screen.y)
        let color = SceneValues.vector(object?["color"], SIMD3(repeating: 1))
        let alpha = max(0, min(1, SceneValues.number(object?["alpha"] ?? object?["opacity"], 1)))
        // Several bundled effects reuse g_Color/g_Alpha as annotated material
        // controls. Their explicit defaults, script values and user bindings
        // take precedence over the layer's generic appearance constants.
        if !authoredUniforms.contains("g_Alpha") { glUniform1f(shader.location("g_Alpha"), alpha) }
        if !authoredUniforms.contains("g_Color") { glUniform3f(shader.location("g_Color"), color.x, color.y, color.z) }
        if !authoredUniforms.contains("g_Color4") { glUniform4f(shader.location("g_Color4"), color.x, color.y, color.z, alpha) }

        func vector(_ column: SIMD4<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
            let value = SIMD3(column.x, column.y, column.z), length = simd_length(value)
            return length.isFinite && length > 0.000001 ? value / length : fallback
        }
        func bindVector(_ name: String, _ value: SIMD3<Float>) { glUniform3f(shader.location(name), value.x, value.y, value.z) }
        bindVector("g_EyePosition", frameCameraInputs.eye)
        bindVector("g_ViewRight", frameCameraInputs.right)
        bindVector("g_ViewUp", frameCameraInputs.up)
        bindVector("g_ViewForward", frameCameraInputs.forward)
        let layerModel = effects?.layerModel ?? model
        bindVector("g_OrientationRight", vector(layerModel.columns.0, fallback: SIMD3(1,0,0)))
        bindVector("g_OrientationUp", vector(layerModel.columns.1, fallback: SIMD3(0,1,0)))
        bindVector("g_OrientationForward", vector(layerModel.columns.2, fallback: SIMD3(0,0,1)))
        func inverse(_ matrix: simd_float4x4, _ name: String) {
            guard shader.location(name) >= 0 else { return }
            if let inverse = SceneEffectTransforms.inverse(matrix) { setMatrix(inverse, name: name, shader: shader) }
            else {
                // A zero-scale layer can legitimately collapse during animation.
                // Do not pass NaN/Inf from its nonexistent inverse to the GPU.
                setMatrix(matrix_identity_float4x4, name: name, shader: shader)
                note("\(name)：图层变换退化时暂用单位逆矩阵；该时刻的效果坐标无法唯一恢复。")
            }
        }
        inverse(model, "g_ModelMatrixInverse")
        inverse(vp * model, "g_ModelViewProjectionMatrixInverse")
        if let effects {
            let effectModel = effects.effectModel(layerGeometry: layerGeometry)
            let effectMVP = effects.sceneViewProjection * effectModel
            let textureProjection = effects.textureProjection
            setMatrix(effects.layerModel, name: "g_LayerModelMatrix", shader: shader)
            setMatrix(effectModel, name: "g_EffectModelMatrix", shader: shader)
            setMatrix(effectMVP, name: "g_EffectModelViewProjectionMatrix", shader: shader)
            inverse(effectMVP, "g_EffectModelViewProjectionMatrixInverse")
            setMatrix(textureProjection, name: "g_EffectTextureProjectionMatrix", shader: shader)
            inverse(textureProjection, "g_EffectTextureProjectionMatrixInverse")
            if renderedFrames == 0, shader.location("g_ParallaxPosition") >= 0 {
                fputs("Scene effect view inputs: layerSize=\(effects.layerSize), textureProjectionDiagonal=\(SIMD3(textureProjection.columns.0.x,textureProjection.columns.1.y,textureProjection.columns.2.z)), parallax=\(state.parallax), coordinates=normalized-bottom-left\n", stderr)
            }
        }
    }

    private func setBlend(_ name: String) {
        switch name {
        case "translucent": glEnable(GLenum(GL_BLEND)); glBlendFuncSeparate(GLenum(GL_SRC_ALPHA),GLenum(GL_ONE_MINUS_SRC_ALPHA),GLenum(GL_ONE),GLenum(GL_ONE_MINUS_SRC_ALPHA))
        case "additive": glEnable(GLenum(GL_BLEND)); glBlendFunc(GLenum(GL_SRC_ALPHA),GLenum(GL_ONE))
        default: glDisable(GLenum(GL_BLEND))
        }
    }

    private func bindTexture(_ texture: GLuint, slot: Int, shader: SceneShader) {
        glActiveTexture(GLenum(GL_TEXTURE0 + Int32(slot))); glBindTexture(GLenum(GL_TEXTURE_2D),texture)
        glUniform1i(shader.location("g_Texture\(slot)"),GLint(slot))
    }

    private func buildPostprocess() throws {
        presentShader = try SceneShader(vertex: Self.screenVertex, fragment: """
        varying vec2 uv; uniform sampler2D g_Texture0; uniform sampler2D g_Texture1;
        uniform float strength; uniform int hdrBloom; uniform vec2 sampleStep; uniform vec4 cameraFade;
        void main() {
            vec3 glow = vec3(0.0);
            if (strength != 0.0) {
                if (hdrBloom != 0) {
                    for (int y=-1;y<=1;y+=2) for (int x=-1;x<=1;x+=2)
                        glow += texture(g_Texture1,uv+vec2(x,y)*sampleStep).rgb*0.25;
                } else glow = texture(g_Texture1,uv).rgb;
            }
            vec3 presented=clamp(texture(g_Texture0,uv).rgb+glow*strength,0.0,1.0);
            gl_FragColor=vec4(mix(presented,cameraFade.rgb,cameraFade.a),1.0);
        }
        """, label: "native SDR present")
    }
    private static let screenVertex = """
    attribute vec3 a_Position; attribute vec2 a_TexCoord; varying vec2 uv;
    void main() { gl_Position=vec4(a_Position,1.0); uv=a_TexCoord; }
    """
    private static let compositionVertex = """
    attribute vec3 a_Position;
    uniform mat4 g_ModelViewProjectionMatrix;
    uniform mat4 g_NativeCaptureMatrix;
    varying vec4 capturePosition;
    void main() {
        gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
        capturePosition = g_NativeCaptureMatrix * vec4(a_Position, 1.0);
    }
    """
    private static let compositionFragment = """
    uniform sampler2D g_Texture0;
    varying vec4 capturePosition;
    void main() {
        vec2 uv = capturePosition.xy / capturePosition.w * 0.5 + 0.5;
        if (capturePosition.w <= 0.0 || any(lessThan(uv,vec2(0.0))) || any(greaterThan(uv,vec2(1.0)))) gl_FragColor = vec4(0.0);
        else gl_FragColor = texture(g_Texture0, uv);
    }
    """
    private static let nativeImageVertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    uniform mat4 g_ModelViewProjectionMatrix;
    uniform vec4 g_Texture0Resolution;
    uniform vec4 g_NativeAtlasRect;
    varying vec2 uv;
    void main() {
        gl_Position = mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix);
        uv = g_NativeAtlasRect.xy + a_TexCoord * g_NativeAtlasRect.zw;
    }
    """
    private static let imageBlendVertex = """
    attribute vec3 a_Position;
    attribute vec2 a_TexCoord;
    uniform mat4 g_ModelViewProjectionMatrix;
    varying vec2 layerUV;
    varying vec3 scenePosition;
    void main() {
        gl_Position = g_ModelViewProjectionMatrix * vec4(a_Position, 1.0);
        layerUV = a_TexCoord;
        scenePosition = gl_Position.xyw;
    }
    """
    private static let imageBlendFragment = """
    uniform sampler2D g_Texture0;
    uniform sampler2D g_Texture4;
    uniform vec3 g_NativeImageColor;
    uniform float g_NativeImageOpacity;
    varying vec2 layerUV;
    varying vec3 scenePosition;
    void main() {
        vec4 layer = texture(g_Texture0, layerUV);
        layer.rgb *= g_NativeImageColor;
        layer.a *= g_NativeImageOpacity;
        vec2 screenUV = scenePosition.xy / scenePosition.z * 0.5 + 0.5;
        vec4 background = texture(g_Texture4, screenUV);
        gl_FragColor = vec4(ApplyBlending(BLENDMODE, background.rgb, layer.rgb, layer.a), background.a);
    }
    """
    private static let nativeImageFragment = """
    varying vec2 uv;
    uniform sampler2D g_Texture0;
    uniform vec4 g_Texture0Resolution;
    uniform vec4 g_NativeAtlasRect;
    uniform int g_NativeAtlasEnabled;
    uniform int g_NativeTextureChannels; // {"default":4}
    uniform float g_Brightness; // {"material":"Brightness","default":1}
    uniform float g_NativeImageOpacity; // {"default":1}
    uniform vec3 g_NativeImageColor; // {"default":"1 1 1"}
    uniform vec3 g_NativeTextBackground; // {"default":"0 0 0"}
    uniform float g_NativeTextOpaque; // {"default":0}
    void main() {
        vec2 sampleUV = uv;
        if (g_NativeAtlasEnabled != 0) {
            vec2 halfPixel = vec2(0.5) / g_Texture0Resolution.xy;
            vec2 inset = min(halfPixel, g_NativeAtlasRect.zw * 0.5);
            sampleUV = clamp(uv, g_NativeAtlasRect.xy + inset, g_NativeAtlasRect.xy + g_NativeAtlasRect.zw - inset);
        }
        vec4 color = texture(g_Texture0,sampleUV);
        // Base image R8 stores alpha; RG8 stores grayscale plus alpha. Effects
        // still sample the underlying R/RG channels directly, as documented.
        if (g_NativeTextureChannels == 1) color = vec4(1.0, 1.0, 1.0, color.r);
        else if (g_NativeTextureChannels == 2) color = vec4(vec3(color.r), color.g);
        color.rgb *= g_Brightness * g_NativeImageColor;
        if (g_NativeTextOpaque > 0.5) {
            color.rgb = mix(g_NativeTextBackground, color.rgb, color.a);
            color.a = 1.0;
        }
        color.a *= g_NativeImageOpacity;
        gl_FragColor = color;
    }
    """
    // Development approximation of the reference mask pass. The source
    // texture supplies coverage; the author's mask texture supplies red.
    private static let puppetMaskFragment = """
    varying vec2 uv;
    uniform sampler2D g_Texture0;
    uniform sampler2D g_NativePuppetSourceMask;
    uniform int g_NativeTextureChannels;
    void main() {
        vec4 source = texture(g_Texture0, uv);
        float coverage = source.a;
        if (g_NativeTextureChannels == 1) coverage = source.r;
        else if (g_NativeTextureChannels == 2) coverage = source.g;
        float maskValue = texture(g_NativePuppetSourceMask, uv).r;
        float softCoverage = coverage * coverage;
        softCoverage *= softCoverage;
        float alpha = softCoverage + (coverage - softCoverage) * maskValue;
        gl_FragColor = vec4(maskValue * alpha, 0.0, 0.0, alpha);
    }
    """
    private static let particleVertex = """
    attribute vec3 a_Position; attribute vec2 a_TexCoord; attribute vec4 a_Color;
    attribute vec2 a_NativeNextTexCoord; attribute float a_NativeFrameBlend;
    uniform mat4 g_ModelViewProjectionMatrix; varying vec2 uv; varying vec4 color;
    varying vec2 nextUV; varying float frameBlend;
    void main() { gl_Position=mul(vec4(a_Position,1.0),g_ModelViewProjectionMatrix); uv=a_TexCoord; color=a_Color; nextUV=a_NativeNextTexCoord; frameBlend=a_NativeFrameBlend; }
    """
    private static let particleFragment = """
    uniform sampler2D g_Texture0; varying vec2 uv; varying vec4 color;
    uniform int g_NativeTextureChannels;
    varying vec2 nextUV; varying float frameBlend;
    vec4 particleSample(vec2 coordinates) {
        vec4 value=texture(g_Texture0,coordinates);
        // Match the original particle color/alpha interpretation, while
        // preserving raw R/RG texture channels for masks and flow effects.
        if (g_NativeTextureChannels==1) return vec4(1.0,1.0,1.0,value.r);
        if (g_NativeTextureChannels==2) return vec4(vec3(value.r),value.g);
        return value;
    }
    void main() {
        vec4 sampled=particleSample(uv);
        if (frameBlend>0.0) {
            vec4 other=particleSample(nextUV);
            sampled=mix(sampled,other,frameBlend);
        }
        gl_FragColor=sampled*color; gl_FragColor.a=clamp(gl_FragColor.a,0.0,1.0);
    }
    """

    deinit {
        timer?.invalidate()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        let previous = NSOpenGLContext.current
        resourceContext?.makeCurrentContext()
        draws.removeAll(); modelResources.removeAll(); textures.removeAll(); targets.removeAll(); hdrBloom = nil; standardBloom = nil; reflectionHistory = nil; sceneHistory = nil; pointVolumetrics = nil
        pointShadows = nil; shadowShaders.removeAll()
        compositeTargets.removeAll(); fullscreenInput = nil; imageTargetPool.removeAll()
        screenQuad = nil; imageQuad = nil; presentShader = nil; imageCopyShader = nil
        imageBlendShaders.removeAll(); puppetMaskTarget = nil; puppetMaskShader = nil; puppetClippedShader = nil
        if let previous { previous.makeCurrentContext() }
        else { NSOpenGLContext.clearCurrentContext() }
    }
}
