import AppKit
import Foundation
import OpenGL.GL3
import simd

/// OpenGL storage for native projected images.  It intentionally only packs
/// already-created GL textures: decoding, source-schema interpretation, and
/// projector shading live at higher layers.  The copy path is a framebuffer
/// blit, so a source is neither sampled nor rescaled while it enters the atlas.
final class NativeGLProjectionAtlas {
    struct Source {
        let id: String
        let texture: GLuint
        /// A missing revision means the provider cannot prove its contents are
        /// unchanged; that source is copied on every call to `encode`.
        var revision: UInt64? = nil
    }

    struct Frame {
        let texture: GLuint
        let layout: NativeProjectionAtlasLayout
        let copiedSources: Int

        /// Returns an atlas UV rectangle in the layout's top-left convention.
        /// `sourceRect` may describe a TEX animation frame, but it never
        /// changes which physical source pixels were copied into the atlas.
        func region(id: String, sourceRect: SIMD4<Float> = SIMD4(0, 0, 1, 1)) -> SIMD4<Float>? {
            let components = [sourceRect.x, sourceRect.y, sourceRect.z, sourceRect.w]
            guard let entry = layout.entries[id], components.allSatisfy(\.isFinite),
                  sourceRect.x >= 0, sourceRect.y >= 0, sourceRect.z > 0, sourceRect.w > 0,
                  sourceRect.x + sourceRect.z <= 1, sourceRect.y + sourceRect.w <= 1 else { return nil }
            let content = entry.normalizedContent
            return SIMD4(content.x + sourceRect.x * content.z,
                         content.y + sourceRect.y * content.w,
                         sourceRect.z * content.z,
                         sourceRect.w * content.w)
        }
    }

    enum Failure: Swift.Error, LocalizedError, Equatable {
        case invalid(String)

        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    private struct Signature: Equatable {
        let id: String
        let texture: GLuint
        let revision: UInt64?
    }

    /// All state modified by allocation and framebuffer blits.  Texture
    /// bindings are collected for every unit because deleting a resized old
    /// atlas while it is bound on any unit would otherwise mutate caller state.
    private struct GLState {
        let activeTexture: GLint
        let texture2DBindings: [GLint]
        let readFramebuffer: GLint
        let drawFramebuffer: GLint
        let readBuffer: GLint
        /// `GL_DRAW_BUFFERi` is per-FBO state.  Keeping every slot avoids
        /// collapsing a caller's multiple-render-target configuration into a
        /// single attachment during atlas-state restoration.
        let drawBuffers: [GLenum]
        let viewport: (GLint, GLint, GLint, GLint)
        let scissorBox: (GLint, GLint, GLint, GLint)
        let scissorEnabled: GLboolean
        let colorMask: (GLboolean, GLboolean, GLboolean, GLboolean)
        let clearColor: (GLfloat, GLfloat, GLfloat, GLfloat)

        static func capture() -> GLState {
            func integer(_ parameter: GLenum) -> GLint {
                var value: GLint = 0
                glGetIntegerv(parameter, &value)
                return value
            }
            func integers4(_ parameter: GLenum) -> (GLint, GLint, GLint, GLint) {
                var values = [GLint](repeating: 0, count: 4)
                glGetIntegerv(parameter, &values)
                return (values[0], values[1], values[2], values[3])
            }
            let active = integer(GLenum(GL_ACTIVE_TEXTURE))
            let unitCount = max(1, integer(GLenum(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS)))
            var bindings: [GLint] = []
            bindings.reserveCapacity(Int(unitCount))
            for unit in 0..<unitCount {
                glActiveTexture(GLenum(GL_TEXTURE0) + GLenum(unit))
                bindings.append(integer(GLenum(GL_TEXTURE_BINDING_2D)))
            }
            glActiveTexture(GLenum(active))
            let drawBufferCount = max(1, integer(GLenum(GL_MAX_DRAW_BUFFERS)))
            var drawBuffers: [GLenum] = []
            drawBuffers.reserveCapacity(Int(drawBufferCount))
            for index in 0..<drawBufferCount {
                drawBuffers.append(GLenum(integer(GLenum(GL_DRAW_BUFFER0) + GLenum(index))))
            }
            var mask = [GLboolean](repeating: GLboolean(GL_FALSE), count: 4)
            glGetBooleanv(GLenum(GL_COLOR_WRITEMASK), &mask)
            var clear = [GLfloat](repeating: 0, count: 4)
            glGetFloatv(GLenum(GL_COLOR_CLEAR_VALUE), &clear)
            return GLState(
                activeTexture: active,
                texture2DBindings: bindings,
                readFramebuffer: integer(GLenum(GL_READ_FRAMEBUFFER_BINDING)),
                drawFramebuffer: integer(GLenum(GL_DRAW_FRAMEBUFFER_BINDING)),
                readBuffer: integer(GLenum(GL_READ_BUFFER)),
                drawBuffers: drawBuffers,
                viewport: integers4(GLenum(GL_VIEWPORT)),
                scissorBox: integers4(GLenum(GL_SCISSOR_BOX)),
                scissorEnabled: glIsEnabled(GLenum(GL_SCISSOR_TEST)),
                colorMask: (mask[0], mask[1], mask[2], mask[3]),
                clearColor: (clear[0], clear[1], clear[2], clear[3]))
        }

        func containsTextureBinding(_ texture: GLuint) -> Bool {
            texture2DBindings.contains(GLint(texture))
        }

        func restore() {
            for (unit, binding) in texture2DBindings.enumerated() {
                glActiveTexture(GLenum(GL_TEXTURE0) + GLenum(unit))
                glBindTexture(GLenum(GL_TEXTURE_2D), GLuint(binding))
            }
            glActiveTexture(GLenum(activeTexture))
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), GLuint(readFramebuffer))
            glReadBuffer(GLenum(readBuffer))
            glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), GLuint(drawFramebuffer))
            if drawFramebuffer == 0 {
                // The default framebuffer only accepts one draw buffer.
                glDrawBuffer(drawBuffers.first ?? GLenum(GL_NONE))
            } else {
                drawBuffers.withUnsafeBufferPointer { buffers in
                    glDrawBuffers(GLsizei(buffers.count), buffers.baseAddress)
                }
            }
            glViewport(viewport.0, viewport.1, viewport.2, viewport.3)
            glScissor(scissorBox.0, scissorBox.1, scissorBox.2, scissorBox.3)
            if scissorEnabled == GLboolean(GL_TRUE) { glEnable(GLenum(GL_SCISSOR_TEST)) }
            else { glDisable(GLenum(GL_SCISSOR_TEST)) }
            glColorMask(colorMask.0, colorMask.1, colorMask.2, colorMask.3)
            glClearColor(clearColor.0, clearColor.1, clearColor.2, clearColor.3)
        }
    }

    private let maximumDimension: Int
    private let maximumBytes: Int
    private var ownerContext: CGLContextObj?
    private var atlasTexture: GLuint = 0
    private var readFramebuffer: GLuint = 0
    private var drawFramebuffer: GLuint = 0
    private var lastLayout: NativeProjectionAtlasLayout?
    private var lastSources: [Signature] = []

    init(maxDimension: Int = NativeProjectionAtlasLayout.defaultMaximumDimension,
         maximumBytes: Int = NativeProjectionAtlasLayout.defaultMaximumBytes) {
        maximumDimension = maxDimension
        self.maximumBytes = maximumBytes
    }

    /// Performs the complete clear-and-copy operation synchronously in the
    /// currently-current CGL context.  A caller must use the same context for
    /// the lifetime of this atlas; sharing an OpenGL share group is not enough
    /// because FBO and state ownership are context-local here.
    func encode(sources: [Source]) throws -> Frame {
        try captureOrValidateCurrentContext()
        guard glGetError() == GLenum(GL_NO_ERROR) else {
            throw Failure.invalid("OpenGL 投影图集开始前上下文已有未处理错误。")
        }
        let state = GLState.capture()
        defer { state.restore() }

        let ordered = try validateAndOrder(sources, protectedTexture: atlasTexture)
        let layout = try NativeProjectionAtlasLayout(
            inputs: ordered.map { NativeProjectionAtlasLayout.Input(id: $0.id, width: Int($0.width), height: Int($0.height)) },
            maxDimension: maximumDimension,
            maximumBytes: maximumBytes,
            bytesPerPixel: 8)
        let signatures = ordered.map { Signature(id: $0.id, texture: $0.texture, revision: $0.revision) }

        if atlasTexture != 0, glIsTexture(atlasTexture) == GLboolean(GL_TRUE),
           let previous = lastLayout,
           ordered.allSatisfy({ $0.revision != nil }), signatures == lastSources,
           layout.width == previous.width, layout.height == previous.height, layout.entries == previous.entries {
            return Frame(texture: atlasTexture, layout: layout, copiedSources: 0)
        }

        let output = try allocateAtlas(for: layout, state: state)
        var completedCopy = false
        defer {
            if !completedCopy {
                // A failed clear/blit may have left a reusable texture partially
                // changed.  It must never qualify for the known-revision cache.
                lastLayout = nil
                lastSources.removeAll(keepingCapacity: false)
                if output != atlasTexture {
                    var transient = output
                    glDeleteTextures(1, &transient)
                }
            }
        }
        try attachAtlas(output, layout: layout)
        glDisable(GLenum(GL_SCISSOR_TEST))
        glColorMask(GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE), GLboolean(GL_TRUE))
        glClearColor(0, 0, 0, 0)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        try checkError("清除投影图集失败")

        for source in ordered {
            guard let entry = layout.entries[source.id] else {
                throw Failure.invalid("投影图集缺少已验证源 \(source.id) 的位置。")
            }
            glBindFramebuffer(GLenum(GL_READ_FRAMEBUFFER), readFramebuffer)
            glFramebufferTexture2D(GLenum(GL_READ_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), source.texture, 0)
            try requireCompleteFramebuffer(GLenum(GL_READ_FRAMEBUFFER), detail: "投影源 \(source.id) 不能作为完整的颜色帧缓冲附件")
            glReadBuffer(GLenum(GL_COLOR_ATTACHMENT0))
            glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), drawFramebuffer)
            glDrawBuffer(GLenum(GL_COLOR_ATTACHMENT0))

            // A layout rectangle is directly usable as the shared projection
            // sampler region.  Preserve source storage coordinates exactly:
            // source texel (x,y) goes to content+(x,y).  In particular, no
            // API-specific Y reflection is introduced at this atlas boundary.
            // Both rectangles retain exactly source.width x source.height; no
            // scaling path is present.
            let destinationBottom = entry.content.y
            glBlitFramebuffer(0, 0, source.width, source.height,
                              GLint(entry.content.x), GLint(destinationBottom),
                              GLint(entry.content.x + Int(source.width)), GLint(destinationBottom + Int(source.height)),
                              GLbitfield(GL_COLOR_BUFFER_BIT), GLenum(GL_NEAREST))
            try checkError("投影源 \(source.id) 复制到图集失败")
        }
        atlasTexture = output
        lastLayout = layout
        lastSources = signatures
        completedCopy = true
        return Frame(texture: output, layout: layout, copiedSources: ordered.count)
    }

    /// Explicitly releases the GL resources.  It refuses a foreign/no current
    /// context rather than deleting names against an unrelated context.
    func release() throws {
        try captureOrValidateCurrentContext()
        guard glGetError() == GLenum(GL_NO_ERROR) else {
            throw Failure.invalid("释放投影图集前上下文已有未处理错误。")
        }
        let state = GLState.capture()
        guard !state.containsTextureBinding(atlasTexture) else {
            throw Failure.invalid("投影图集仍绑定在调用方纹理单元；为避免释放隐式改写调用方状态，请先解绑后释放。")
        }
        guard (readFramebuffer == 0 || GLuint(state.readFramebuffer) != readFramebuffer),
              (drawFramebuffer == 0 || GLuint(state.drawFramebuffer) != drawFramebuffer) else {
            throw Failure.invalid("投影图集内部帧缓冲仍被当前调用方绑定；请先恢复调用方帧缓冲后释放。")
        }
        deleteResources()
        try checkError("释放投影图集资源失败")
    }

    deinit {
        // Destruction cannot make a context current safely.  If the owning
        // context is already current, releasing is correct; otherwise callers
        // must use `release()` while their renderer context remains current.
        if ownerContext != nil, ownerContext == CGLGetCurrentContext() {
            let state = GLState.capture()
            guard !state.containsTextureBinding(atlasTexture),
                  (readFramebuffer == 0 || GLuint(state.readFramebuffer) != readFramebuffer),
                  (drawFramebuffer == 0 || GLuint(state.drawFramebuffer) != drawFramebuffer) else { return }
            deleteResources()
        }
    }

    private struct ValidatedSource {
        let id: String
        let texture: GLuint
        let revision: UInt64?
        let width: GLint
        let height: GLint
    }

    private func captureOrValidateCurrentContext() throws {
        guard let current = CGLGetCurrentContext() else {
            throw Failure.invalid("更新投影图集需要当前 CGL OpenGL 上下文。")
        }
        if let ownerContext {
            guard ownerContext == current else {
                throw Failure.invalid("投影图集不能跨 CGL 上下文使用；请在创建它的渲染上下文中更新或释放。")
            }
        } else {
            ownerContext = current
        }
    }

    private func validateAndOrder(_ sources: [Source], protectedTexture: GLuint) throws -> [ValidatedSource] {
        var unique: [String: ValidatedSource] = [:]
        var textureOwners: [GLuint: String] = [:]
        for source in sources {
            guard !source.id.isEmpty else { throw Failure.invalid("投影源标识不能为空。") }
            guard source.texture != 0, glIsTexture(source.texture) == GLboolean(GL_TRUE) else {
                throw Failure.invalid("投影源 \(source.id) 不是当前 OpenGL 上下文中的有效二维纹理。")
            }
            guard source.texture != protectedTexture else {
                throw Failure.invalid("投影图集不能在同一更新中作为自身输入。")
            }
            if let owner = textureOwners[source.texture], owner != source.id {
                throw Failure.invalid("同一个 OpenGL 纹理句柄不能以不同投影源标识重复提交。")
            }
            textureOwners[source.texture] = source.id

            var width: GLint = 0, height: GLint = 0, format: GLint = 0
            glBindTexture(GLenum(GL_TEXTURE_2D), source.texture)
            glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_WIDTH), &width)
            glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_HEIGHT), &height)
            glGetTexLevelParameteriv(GLenum(GL_TEXTURE_2D), 0, GLenum(GL_TEXTURE_INTERNAL_FORMAT), &format)
            let inspectionError = glGetError()
            guard inspectionError == GLenum(GL_NO_ERROR) else {
                throw Failure.invalid("读取投影源 \(source.id) 的二维纹理尺寸或格式失败：OpenGL 错误 \(inspectionError)。")
            }
            guard width > 0, height > 0 else {
                throw Failure.invalid("投影源 \(source.id) 没有可复制的第 0 级二维像素。")
            }
            let allowed = [GLint(GL_RGBA8), GLint(GL_RGBA16F), GLint(GL_R8), GLint(GL_RG8)]
            guard allowed.contains(format) else {
                throw Failure.invalid("投影源 \(source.id) 的实际 OpenGL 内部格式不受支持；仅允许 RGBA8、RGBA16F、R8 或 RG8。")
            }
            let inspected = ValidatedSource(id: source.id, texture: source.texture, revision: source.revision, width: width, height: height)
            if let previous = unique[source.id] {
                guard previous.texture == inspected.texture, previous.revision == inspected.revision,
                      previous.width == inspected.width, previous.height == inspected.height else {
                    throw Failure.invalid("同一个投影源标识对应了冲突的纹理句柄、尺寸或内容修订。")
                }
            } else {
                unique[source.id] = inspected
            }
        }
        return unique.keys.sorted().compactMap { unique[$0] }
    }

    private func allocateAtlas(for layout: NativeProjectionAtlasLayout, state: GLState) throws -> GLuint {
        var maxTextureSize: GLint = 0
        glGetIntegerv(GLenum(GL_MAX_TEXTURE_SIZE), &maxTextureSize)
        guard layout.width <= Int(maxTextureSize), layout.height <= Int(maxTextureSize) else {
            throw Failure.invalid("当前 OpenGL 上下文的最大纹理边长不足以分配投影图集。")
        }
        let reuse = atlasTexture != 0 && glIsTexture(atlasTexture) == GLboolean(GL_TRUE) &&
            lastLayout?.width == layout.width && lastLayout?.height == layout.height
        if reuse { return atlasTexture }

        if atlasTexture != 0 {
            guard !state.containsTextureBinding(atlasTexture) else {
                throw Failure.invalid("旧投影图集仍绑定在调用方纹理单元；为保证状态不被隐式改变，需先解绑后才能按新尺寸重建。")
            }
        }
        var candidate: GLuint = 0
        glGenTextures(1, &candidate)
        guard candidate != 0 else { throw Failure.invalid("无法创建 OpenGL 投影图集纹理。") }
        glBindTexture(GLenum(GL_TEXTURE_2D), candidate)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GLint(GL_LINEAR))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GLint(GL_CLAMP_TO_EDGE))
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GLint(GL_CLAMP_TO_EDGE))
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GLint(GL_RGBA16F), GLsizei(layout.width), GLsizei(layout.height), 0,
                     GLenum(GL_RGBA), GLenum(GL_HALF_FLOAT), nil)
        do { try checkError("无法分配 RGBA16F 投影图集") }
        catch {
            glDeleteTextures(1, &candidate)
            throw error
        }
        if atlasTexture != 0 {
            var old = atlasTexture
            glDeleteTextures(1, &old)
            try checkError("替换旧投影图集失败")
            atlasTexture = 0
            lastLayout = nil
            lastSources.removeAll(keepingCapacity: false)
        }
        return candidate
    }

    private func attachAtlas(_ texture: GLuint, layout: NativeProjectionAtlasLayout) throws {
        if readFramebuffer == 0 { glGenFramebuffers(1, &readFramebuffer) }
        if drawFramebuffer == 0 { glGenFramebuffers(1, &drawFramebuffer) }
        guard readFramebuffer != 0, drawFramebuffer != 0 else {
            throw Failure.invalid("无法创建 OpenGL 投影图集帧缓冲。")
        }
        glBindFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), drawFramebuffer)
        glFramebufferTexture2D(GLenum(GL_DRAW_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        try requireCompleteFramebuffer(GLenum(GL_DRAW_FRAMEBUFFER), detail: "RGBA16F 投影图集帧缓冲不完整")
        glDrawBuffer(GLenum(GL_COLOR_ATTACHMENT0))
        glViewport(0, 0, GLsizei(layout.width), GLsizei(layout.height))
    }

    private func requireCompleteFramebuffer(_ target: GLenum, detail: String) throws {
        guard glCheckFramebufferStatus(target) == GLenum(GL_FRAMEBUFFER_COMPLETE) else {
            throw Failure.invalid(detail)
        }
        try checkError(detail)
    }

    private func checkError(_ operation: String) throws {
        let error = glGetError()
        guard error == GLenum(GL_NO_ERROR) else {
            throw Failure.invalid("\(operation)：OpenGL 错误 \(error)。")
        }
    }

    private func deleteResources() {
        if readFramebuffer != 0 {
            var value = readFramebuffer
            glDeleteFramebuffers(1, &value)
            readFramebuffer = 0
        }
        if drawFramebuffer != 0 {
            var value = drawFramebuffer
            glDeleteFramebuffers(1, &value)
            drawFramebuffer = 0
        }
        if atlasTexture != 0 {
            var value = atlasTexture
            glDeleteTextures(1, &value)
            atlasTexture = 0
        }
        lastLayout = nil
        lastSources.removeAll(keepingCapacity: false)
    }
}
