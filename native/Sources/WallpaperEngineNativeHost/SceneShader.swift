import Foundation
import OpenGL.GL3

/// Compiles the documented subset of Wallpaper Engine's GLSL-like shader dialect
/// used by the local Scene renderer. It is deliberately a source translator, not
/// a copy of Wallpaper Engine's private shader headers.
final class SceneShader {
    let program: GLuint
    let uniformMetadata: [String: [String: Any]]
    let resolvedCombos: [String: Int]
    let usesNativeImageBlur: Bool
    private var uniformLocations: [String: GLint] = [:]

    init(vertex: String, fragment: String, combos: [String: Int] = [:], label: String, discardTransparentDepth: Bool = false, sceneHDR: Bool? = nil, geometry: String? = nil) throws {
        try Self.validateSourceSize(vertex, stage: "vertex", label: label)
        try Self.validateSourceSize(fragment, stage: "fragment", label: label)
        let linkedSources = try Self.reconcileVaryings(vertex: Self.normalizeHLSLVectorTypes(vertex), fragment: Self.normalizeHLSLVectorTypes(fragment))
        let vertexText = Self.withBuiltinDeclarations(linkedSources.vertex)
        let fragmentText = Self.withBuiltinDeclarations(linkedSources.fragment)
        try Self.validateSourceSize(vertexText, stage: "vertex", label: label)
        try Self.validateSourceSize(fragmentText, stage: "fragment", label: label)
        let vertexScan = try SceneShader.scan(vertexText, stage: "vertex", label: label)
        let fragmentScan = try SceneShader.scan(fragmentText, stage: "fragment", label: label)

        var effectiveCombos = vertexScan.comboDefaults
        for (name, value) in fragmentScan.comboDefaults where effectiveCombos[name] == nil {
            effectiveCombos[name] = value
        }
        for (name, value) in combos {
            guard Self.isIdentifier(name) else {
                throw Self.error("\(label): invalid combo identifier '\(name)'.")
            }
            effectiveCombos[name] = value
        }
        for name in vertexScan.referencedCombos.union(fragmentScan.referencedCombos) where effectiveCombos[name] == nil {
            // A resource annotation can reference an optional variant without declaring
            // it as [COMBO]. Wallpaper Engine treats its absent default as disabled.
            effectiveCombos[name] = 0
        }
        if let sceneHDR {
            // HDR is a scene capability, not an author-selectable effect combo.
            // Its absence matters: authored shaders and the reference header use
            // #ifdef HDR, which would also be true for a misleading HDR=0 define.
            let localHDR = #"(?m)^[ \t]*#[ \t]*(?:define|undef)[ \t]+HDR\b"#
            guard vertexText.range(of: localHDR, options: .regularExpression) == nil,
                  fragmentText.range(of: localHDR, options: .regularExpression) == nil else {
                throw Self.error("\(label): source-local HDR definitions are unsupported; HDR comes from scene.general.hdr.")
            }
            let expected = sceneHDR ? 1 : 0
            if let authored = effectiveCombos["HDR"], authored != expected {
                fputs("Scene HDR combo: \(label), author value \(authored) overridden by scene.general.hdr=\(sceneHDR)\n", stderr)
            }
            if sceneHDR { effectiveCombos["HDR"] = 1 }
            else { effectiveCombos.removeValue(forKey: "HDR") }
        }
        resolvedCombos = effectiveCombos
        usesNativeImageBlur = vertexText.contains("common_blur.h") || fragmentText.contains("common_blur.h")

        let vertexSource = try Self.translate(vertexText, stage: .vertex, combos: effectiveCombos, label: label)
        var fragmentSource = try Self.translate(fragmentText, stage: .fragment, combos: effectiveCombos, label: label)
        if discardTransparentDepth {
            let mainPattern = #"\bvoid\s+main\s*\(\s*(?:void\s*)?\)"#
            guard fragmentSource.range(of: mainPattern, options: .regularExpression) != nil else { throw Self.error("\(label): fragment shader has no main entry point.") }
            fragmentSource = fragmentSource.replacingOccurrences(of: mainPattern, with: "void weNativeAuthoredFragment()", options: .regularExpression)
            // Transparent pixels must not occlude subsequent geometry just because
            // their material enables depth writes. Keep all nonzero authored alpha.
            fragmentSource += "\nvoid main() { weNativeAuthoredFragment(); if (sceneFragColor.a <= 0.0) discard; }\n"
        }
        let metadata = try Self.mergeUniforms(vertexScan.uniforms, fragmentScan.uniforms, label: label)

        let vertexShader = try Self.compile(source: vertexSource, type: GLenum(GL_VERTEX_SHADER), label: "\(label) vertex")
        defer { glDeleteShader(vertexShader) }
        let fragmentShader = try Self.compile(source: fragmentSource, type: GLenum(GL_FRAGMENT_SHADER), label: "\(label) fragment")
        defer { glDeleteShader(fragmentShader) }
        var geometryShader: GLuint = 0
        defer { if geometryShader != 0 { glDeleteShader(geometryShader) } }
        if let geometry {
            try Self.validateSourceSize(geometry, stage: "geometry", label: label)
            // Only the owned model pipeline currently supplies this optional
            // stage. It uses native GLSL in/out declarations, not author inputs.
            let source = try Self.translate(geometry, stage: .vertex, combos: effectiveCombos, label: label)
            geometryShader = try Self.compile(source: source, type: GLenum(GL_GEOMETRY_SHADER), label: "\(label) geometry")
        }

        let linkedProgram = glCreateProgram()
        guard linkedProgram != 0 else {
            throw Self.error("\(label): glCreateProgram returned 0. Ensure a current OpenGL 3.3 Core context exists.")
        }
        glAttachShader(linkedProgram, vertexShader)
        glAttachShader(linkedProgram, fragmentShader)
        if geometryShader != 0 { glAttachShader(linkedProgram, geometryShader) }
        // SceneRenderer's VAO has this fixed, documented layout.
        Self.bindAttribute("a_Position", index: 0, to: linkedProgram)
        Self.bindAttribute("a_TexCoord", index: 1, to: linkedProgram)
        Self.bindAttribute("a_Normal", index: 2, to: linkedProgram)
        Self.bindAttribute("a_Tangent", index: 3, to: linkedProgram)
        Self.bindAttribute("a_Color", index: 4, to: linkedProgram)
        Self.bindAttribute("a_NativeNextTexCoord", index: 5, to: linkedProgram)
        Self.bindAttribute("a_NativeFrameBlend", index: 6, to: linkedProgram)
        Self.bindAttribute("a_NativeBoneIndices", index: 7, to: linkedProgram)
        Self.bindAttribute("a_NativeBoneWeights", index: 8, to: linkedProgram)
        glLinkProgram(linkedProgram)

        var linkStatus: GLint = 0
        glGetProgramiv(linkedProgram, GLenum(GL_LINK_STATUS), &linkStatus)
        guard linkStatus != 0 else {
            let log = Self.programLog(linkedProgram)
            glDeleteProgram(linkedProgram)
            throw Self.error("\(label): OpenGL program link failed.\n\(log)")
        }

        program = linkedProgram
        uniformMetadata = metadata
    }

    func location(_ name: String) -> GLint {
        if let cached = uniformLocations[name] { return cached }
        let resolved = name.withCString { glGetUniformLocation(program, $0) }
        uniformLocations[name] = resolved
        return resolved
    }

    deinit {
        if program != 0 {
            glDeleteProgram(program)
        }
    }

    static func textureCombos(vertex: String, fragment: String, textures: [Any]) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for source in [vertex, fragment] {
            for (uniform, metadata) in try scan(source, stage: "texture binding", label: "material").uniforms {
                guard metadata["glslType"] as? String == "sampler2D", let combo = metadata["combo"] as? String,
                      uniform.hasPrefix("g_Texture"), let slot = Int(uniform.dropFirst(9)) else { continue }
                let supplied = textures.indices.contains(slot) && (textures[slot] as? String).map { !$0.isEmpty } == true
                result[combo] = max(result[combo] ?? 0, supplied ? 1 : 0)
            }
        }
        return result
    }
}

private extension SceneShader {
    enum Stage {
        case vertex
        case fragment
    }

    struct ScanResult {
        var comboDefaults: [String: Int]
        var referencedCombos: Set<String>
        var uniforms: [String: [String: Any]]
    }

    static func error(_ message: String) -> NSError {
        NSError(domain: "SceneShader", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static func isIdentifier(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    static func validateSourceSize(_ source: String, stage: String, label: String) throws {
        let byteCount = source.lengthOfBytes(using: .utf8)
        guard byteCount <= maximumSourceBytes else {
            throw error("\(label) \(stage) shader is \(byteCount) bytes, exceeding the \(maximumSourceBytes)-byte source limit.")
        }
    }

    /// Exported effects sometimes keep HLSL float2/3/4 spellings. Normalize
    /// lexical type tokens before dimension inference; leave comments, strings
    /// and preprocessor definitions untouched rather than changing metadata.
    static func normalizeHLSLVectorTypes(_ source: String) throws -> String {
        let tokens = try NSRegularExpression(pattern: #"//[^\r\n]*|/\*[\s\S]*?\*/|\"(?:\\.|[^\"\\])*\"|(?m)^[ \t]*#[^\r\n]*|\bfloat([234])\b"#)
        let input = source as NSString, output = NSMutableString(string: source)
        for token in tokens.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard token.range(at: 1).location != NSNotFound else { continue }
            output.replaceCharacters(in: token.range, with: "vec" + input.substring(with: token.range(at: 1)))
        }
        return output as String
    }

    static func scan(_ source: String, stage: String, label: String) throws -> ScanResult {
        var defaults: [String: Int] = [:]
        var uniforms: [String: [String: Any]] = [:]
        var comboReferences = Set<String>()
        let lines = source.components(separatedBy: .newlines)

        for (offset, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let jsonRange = trimmed.range(of: #"^//\s*\[COMBO\]\s*"#, options: .regularExpression) {
                let jsonText = String(trimmed[jsonRange.upperBound...])
                let annotation = try parseJSONObject(jsonText, description: "\(label) \(stage) combo on line \(offset + 1)")
                guard let name = annotation["combo"] as? String, isIdentifier(name) else {
                    throw error("\(label) \(stage) combo on line \(offset + 1) has no valid 'combo' name.")
                }
                if annotation["default"] == nil {
                    // Some exported checkbox declarations (for example COPYBG)
                    // omit the default. A material override still takes priority;
                    // otherwise the undeclared optional branch remains disabled.
                    comboReferences.insert(name)
                    continue
                }
                guard let defaultValue = integer(annotation["default"]) else {
                    throw error("\(label) \(stage) combo '\(name)' has no integer default.")
                }
                if let existing = defaults[name], existing != defaultValue {
                    throw error("\(label) declares combo '\(name)' with conflicting defaults \(existing) and \(defaultValue).")
                }
                defaults[name] = defaultValue
            }

            guard let match = uniformMatch(in: line) else { continue }
            let glslType = match.glslType
            let name = match.name
            var metadata: [String: Any] = ["glslType": glslType]
            if let annotationText = match.annotation {
                let annotation = try parseJSONObject(annotationText, description: "\(label) \(stage) uniform '\(name)' on line \(offset + 1)")
                metadata.merge(annotation) { _, new in new }
                // `type` belongs to the original editor UI annotation (for example
                // `color`). Render binding uses glslType so that UI semantics survive.
                metadata["glslType"] = glslType
                if let combo = annotation["combo"] as? String {
                    guard isIdentifier(combo) else {
                        throw error("\(label) \(stage) uniform '\(name)' has invalid combo name '\(combo)'.")
                    }
                    comboReferences.insert(combo)
                }
            }
            if let existing = uniforms[name], let existingType = existing["glslType"] as? String, existingType != glslType {
                throw error("\(label) declares uniform '\(name)' as both \(existingType) and \(glslType).")
            }
            uniforms[name] = metadata
        }
        return ScanResult(comboDefaults: defaults, referencedCombos: comboReferences, uniforms: uniforms)
    }

    static func parseJSONObject(_ text: String, description: String) throws -> [String: Any] {
        guard let data = text.data(using: .utf8) else {
            throw error("\(description) is not valid UTF-8 JSON.")
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw error("\(description) must be a JSON object.")
            }
            return object
        } catch let failure as NSError where failure.domain == "SceneShader" {
            throw failure
        } catch {
            throw Self.error("\(description) is malformed JSON: \(error.localizedDescription)")
        }
    }

    static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    struct UniformMatch {
        let glslType: String
        let name: String
        let annotation: String?
    }

    static func uniformMatch(in line: String) -> UniformMatch? {
        // Do not require end-of-line: some compact local shaders put a following
        // `varying` declaration on the same line after a semicolon.
        let pattern = #"^\s*uniform\s+([A-Za-z_][A-Za-z0-9_]*)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*\[[^\]]+\])?\s*;[ \t]*(?://[ \t]*(\{.*\}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
            return String(line[swiftRange])
        }
        guard let glslType = group(1), let name = group(2) else { return nil }
        return UniformMatch(glslType: glslType, name: name, annotation: group(3))
    }

    static func mergeUniforms(_ first: [String: [String: Any]], _ second: [String: [String: Any]], label: String) throws -> [String: [String: Any]] {
        var result = first
        for (name, incoming) in second {
            if let current = result[name], let firstType = current["glslType"] as? String, let secondType = incoming["glslType"] as? String, firstType != secondType {
                throw error("\(label) declares uniform '\(name)' as both \(firstType) and \(secondType).")
            }
            result[name] = (result[name] ?? [:]).merging(incoming) { old, new in
                // The source annotation in either stage is the same material metadata;
                // retain the existing value if the other stage only lacks a key.
                new is NSNull ? old : new
            }
        }
        return result
    }

    static func translate(_ originalSource: String, stage: Stage, combos: [String: Int], label: String) throws -> String {
        try rejectUnknownIncludes(in: originalSource, label: label)
        if originalSource.contains("common_composite.h") {
            guard (combos["COMPOSITE"] ?? 0) == 0, (combos["COMPOSITEMONO"] ?? 0) == 0, (combos["BLENDMODE"] ?? 0) == 0 else { throw error("\(label): common_composite 当前仅支持普通彩色替换模式。") }
        }
        let usesBlending = containsApplyBlending(in: originalSource) || originalSource.contains("common_blending.h")
        let blendMode = combos["BLENDMODE"] ?? 0
        if usesBlending {
            guard NativeBlendModes.supports(blendMode) else {
                throw error("\(label): BLENDMODE=\(blendMode) 超出已核对的 0–32 范围。")
            }
            guard originalSource.range(of: #"(?m)^\s*#\s*(?:define|undef)\s+BLENDMODE\b"#, options: .regularExpression) == nil else {
                throw error("\(label): 着色器内部重定义 BLENDMODE 的预处理顺序尚未支持。")
            }
        }

        var source = removeKnownIncludes(from: originalSource)
        source = try normalizeBareConditionals(source, combos: combos)
        source = try NativeShaderScalarExpressions.adaptRemainderDeclarations(source, combos: combos)
        source = try NativeShaderVectorExpressions.adapt(source)
        source = source.replacingOccurrences(of: #"(?m)^\s*#version[^\n]*\n?"#, with: "", options: .regularExpression)
        source = source.replacingOccurrences(of: #"\battribute\b"#, with: "in", options: .regularExpression)
        let varyingReplacement = stage == .vertex ? "out" : "in"
        source = source.replacingOccurrences(of: #"\bvarying\b"#, with: varyingReplacement, options: .regularExpression)

        if stage == .fragment {
            source = source.replacingOccurrences(of: #"\bddx\s*\("#, with: "dFdx(", options: .regularExpression)
            source = source.replacingOccurrences(of: #"\bddy\s*\("#, with: "dFdy(", options: .regularExpression)
            source = source.replacingOccurrences(of: #"\bgl_FragColor\b"#, with: "sceneFragColor", options: .regularExpression)
        }

        let definitions = combos.keys.sorted().map { "#define \($0) \(combos[$0] ?? 0)" }.joined(separator: "\n")
        let outputDeclaration = stage == .fragment ? "layout(location = 0) out vec4 sceneFragColor;" : ""
        let usesBlur = originalSource.contains("common_blur.h")
        let usesComposite = originalSource.contains("common_composite.h")
        let colorFunctions = [("rgb2hsv", nativeRGBFunction), ("hsv2rgb", nativeHSVFunction)].compactMap { name, implementation -> String? in
            // Do not shadow an author's own definition or prototype.
            originalSource.range(of: "\\bvec3\\s+" + name + "\\s*\\(", options: .regularExpression) == nil ? implementation : nil
        }.joined(separator: "\n")
        let prototypes = (usesBlur ? NativeImageBlur.prototypes : "") + (usesComposite ? "\nvec2 ApplyCompositeOffset(vec2 uv, vec2 size);\nvec4 ApplyComposite(vec4 original, vec4 filtered);" : "")
        return """
        #version 330 core
        // Generated compatibility prelude. It implements only functions used by this renderer.
        \(definitions)
        \(compatibilityPrelude)
        \(colorFunctions)
        \(usesBlending ? NativeBlendModes.glsl(for: blendMode) : "")
        \(originalSource.contains("common_blending.h") ? NativeBlendModes.directGLSL : "")
        \(outputDeclaration)
        \(prototypes)
        #line 1
        \(source)
        \(usesBlur ? NativeImageBlur.glsl : "")
        \(usesComposite ? nativeCompositeFunctions : "")
        """
    }

    /// HLSL can consume only the first components of a wider vertex output.
    /// GLSL requires both declarations to match. Preserve the vertex payload,
    /// and give the fragment's authored name an explicit narrowed expression.
    static func reconcileVaryings(vertex: String, fragment: String) throws -> (vertex: String, fragment: String) {
        let pattern = try NSRegularExpression(pattern: #"\bvarying\s+(float|vec[234])\s+([A-Za-z_][A-Za-z0-9_]*)\s*;"#)
        func declarations(_ source: String) -> [String: [(type: String, range: NSRange)]] {
            let ns = source as NSString
            var result: [String: [(type: String, range: NSRange)]] = [:]
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                result[ns.substring(with: match.range(at: 2)), default: []].append((ns.substring(with: match.range(at: 1)), match.range))
            }
            return result
        }
        let outputs = declarations(vertex), inputs = declarations(fragment)
        var vertex = vertex, fragment = fragment
        let dimensions = ["float": 1, "vec2": 2, "vec3": 3, "vec4": 4]
        for name in inputs.keys.sorted() {
            guard let incoming = inputs[name], incoming.count == 1, let outgoing = outputs[name], outgoing.count == 1,
                  let width = dimensions[incoming[0].type], let written = dimensions[outgoing[0].type], width < written else { continue }
            let alias = "weNativeVarying_" + name
            guard !vertex.contains(alias), !fragment.contains(alias) else { continue }
            vertex = vertex.replacingOccurrences(of: "\\b" + name + "\\b", with: alias, options: .regularExpression)
            let declaration = "varying " + outgoing[0].type + " " + alias + ";\n#define " + name + " (" + alias + "." + String("xyzw".prefix(width)) + ")\n"
            fragment = fragment.replacingOccurrences(of: "\\bvarying\\s+" + incoming[0].type + "\\s+" + name + "\\s*;", with: declaration, options: .regularExpression)
        }
        return (vertex, fragment)
    }

    static func withBuiltinDeclarations(_ source: String) -> String {
        guard source.contains("common_composite.h") else { return source }
        return "uniform vec3 g_NativeCompositeColor; // {\"material\":\"compositecolor\",\"default\":\"1 1 1\",\"type\":\"color\"}\n" + source
    }

    /// HLSL's preprocessor treats an undefined identifier in #if as zero. The
    /// macOS GLSL driver rejects it even in comparisons such as SPECULAR == 1.
    /// Substitute only inside #if/#elif; #ifdef and defined(NAME) keep their
    /// original meaning. Locally declared macros are left to the compiler.
    static func normalizeBareConditionals(_ source: String, combos: [String: Int]) throws -> String {
        let define = try NSRegularExpression(pattern: #"(?m)^\s*#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let ns = source as NSString
        let declared = Set(define.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { ns.substring(with: $0.range(at: 1)) })
        let conditional = try NSRegularExpression(pattern: #"(?m)^([ \t]*#[ \t]*(?:if|elif)[ \t]+)([^\r\n]*)$"#)
        let identifiers = try NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        let defined = try NSRegularExpression(pattern: #"\bdefined\s*(?:\(\s*[A-Za-z_][A-Za-z0-9_]*\s*\)|[A-Za-z_][A-Za-z0-9_]*)"#)
        let result = NSMutableString(string: source)
        for match in conditional.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let expression = ns.substring(with: match.range(at: 2)).components(separatedBy: "//")[0]
            // Leave multi-line or block-comment directives untouched rather than
            // changing the meaning of code that this bounded adapter cannot parse.
            if expression.contains("\\") || expression.contains("/*") { continue }
            let protected = defined.matches(in: expression, range: NSRange(expression.startIndex..., in: expression)).map(\.range)
            let value = expression as NSString
            for token in identifiers.matches(in: expression, range: NSRange(expression.startIndex..., in: expression)).reversed() {
                let name = value.substring(with: token.range)
                if combos[name] == nil && !declared.contains(name) && name != "__VERSION__" && !protected.contains(where: { NSIntersectionRange($0, token.range).length > 0 }) {
                    result.replaceCharacters(in: NSRange(location: match.range(at: 2).location + token.range.location, length: token.range.length), with: "0")
                }
            }
        }
        return result as String
    }

    static func rejectUnknownIncludes(in source: String, label: String) throws {
        var includeCount = 0
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#include") else { continue }
            includeCount += 1
            guard includeCount <= maximumIncludeCount else {
                throw error("\(label): shader declares more than \(maximumIncludeCount) includes; refusing oversized include expansion.")
            }
            guard let firstQuote = line.firstIndex(of: "\""),
                  let secondQuote = line[line.index(after: firstQuote)...].firstIndex(of: "\"") else {
                throw error("\(label): malformed #include directive '\(line)'.")
            }
            let name = String(line[line.index(after: firstQuote)..<secondQuote])
            guard knownIncludes.contains(name) else {
                throw error("\(label): unsupported shader include '\(name)'. Recognized headers: \(knownIncludes.sorted().joined(separator: ", ")).")
            }
        }
    }

    static func removeKnownIncludes(from source: String) -> String {
        source.components(separatedBy: .newlines).map { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("#include") ? "" : line
        }.joined(separator: "\n")
    }

    static func containsApplyBlending(in source: String) -> Bool {
        source.range(of: #"\bApplyBlending\s*\("#, options: .regularExpression) != nil
    }

    static let knownIncludes: Set<String> = ["common.h", "common_vertex.h", "common_fragment.h", "common_blending.h", "common_perspective.h", "common_blur.h", "common_composite.h"]
    static let maximumSourceBytes = 1_048_576
    static let maximumIncludeCount = 64

    static let nativeCompositeFunctions = """
    vec2 ApplyCompositeOffset(vec2 uv, vec2 size) { return uv; }
    vec4 ApplyComposite(vec4 original, vec4 filtered) {
        return vec4(filtered.rgb * g_NativeCompositeColor, filtered.a);
    }
    """

    // Standard HSV conversion, implemented independently of vendor headers.
    // Hue is in [0,1); achromatic colors have zero hue and saturation.
    static let nativeRGBFunction = """
    vec3 rgb2hsv(vec3 color) {
        float maximum = max(color.r, max(color.g, color.b));
        float minimum = min(color.r, min(color.g, color.b));
        float delta = maximum - minimum;
        float hue = 0.0;
        if (delta > 0.000001) {
            if (maximum == color.r) hue = (color.g - color.b) / delta;
            else if (maximum == color.g) hue = 2.0 + (color.b - color.r) / delta;
            else hue = 4.0 + (color.r - color.g) / delta;
            hue = fract(hue / 6.0);
        }
        return vec3(hue, maximum > 0.000001 ? delta / maximum : 0.0, maximum);
    }
    """
    static let nativeHSVFunction = """
    vec3 hsv2rgb(vec3 color) {
        vec3 hue = clamp(abs(fract(color.x + vec3(0.0, 2.0/3.0, 1.0/3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
        return color.z * mix(vec3(1.0), hue, color.y);
    }
    """

    // Original compatibility functions written for this renderer from documented API
    // names and standard GLSL semantics. They do not incorporate client shader code.
    static let compatibilityPrelude = """
    #define M_PI 3.14159265359
    #define M_PI_HALF 1.57079632679
    #define M_PI_2 6.28318530718
    #define SQRT_2 1.41421356237
    #define SQRT_3 1.73205080756

    float lerp(float a, float b, float t) { return mix(a,b,t); }
    vec2 lerp(vec2 a, vec2 b, float t) { return mix(a,b,t); }
    vec3 lerp(vec3 a, vec3 b, float t) { return mix(a,b,t); }
    vec4 lerp(vec4 a, vec4 b, float t) { return mix(a,b,t); }
    vec2 lerp(vec2 a, vec2 b, vec2 t) { return mix(a,b,t); }
    vec3 lerp(vec3 a, vec3 b, vec3 t) { return mix(a,b,t); }
    vec4 lerp(vec4 a, vec4 b, vec4 t) { return mix(a,b,t); }
    float atan2(float y, float x) { return atan(y,x); }
    float weNativeRemainder(float x, float y) { return x - trunc(x / y) * y; }

    float frac(float value) { return fract(value); }
    vec2 frac(vec2 value) { return fract(value); }
    vec3 frac(vec3 value) { return fract(value); }
    vec4 frac(vec4 value) { return fract(value); }

    float saturate(float value) { return clamp(value, 0.0, 1.0); }
    vec2 saturate(vec2 value) { return clamp(value, vec2(0.0), vec2(1.0)); }
    vec3 saturate(vec3 value) { return clamp(value, vec3(0.0), vec3(1.0)); }
    vec4 saturate(vec4 value) { return clamp(value, vec4(0.0), vec4(1.0)); }

    vec2 CAST2(float value) { return vec2(value); }
    vec2 CAST2(int value) { return vec2(float(value)); }
    vec2 CAST2(vec2 value) { return value; }
    vec2 CAST2(vec3 value) { return value.xy; }
    vec2 CAST2(vec4 value) { return value.xy; }
    vec3 CAST3(float value) { return vec3(value); }
    vec3 CAST3(int value) { return vec3(float(value)); }
    vec3 CAST3(vec3 value) { return value; }
    vec3 CAST3(vec4 value) { return value.xyz; }
    vec4 CAST4(float value) { return vec4(value); }
    vec4 CAST4(int value) { return vec4(float(value)); }
    vec4 CAST4(vec4 value) { return value; }
    mat3 CAST3X3(mat4 value) { return mat3(value); }
    mat3 CAST3X3(mat3 value) { return value; }

    // Exported blur_combine uses an integer literal as its scalar endpoint.
    // Convert that endpoint explicitly for the macOS GLSL compiler.
    float mix(float a, int b, float t) { return mix(a, float(b), t); }
    vec2 mix(float a, vec2 b, float t) { return mix(vec2(a), b, t); }
    vec3 mix(float a, vec3 b, float t) { return mix(vec3(a), b, t); }
    vec4 mix(float a, vec4 b, float t) { return mix(vec4(a), b, t); }
    vec2 mix(vec2 a, float b, float t) { return mix(a, vec2(b), t); }
    vec3 mix(vec3 a, float b, float t) { return mix(a, vec3(b), t); }
    vec4 mix(vec4 a, float b, float t) { return mix(a, vec4(b), t); }

    vec4 texSample2D(sampler2D samplerValue, vec2 coordinate) { return texture(samplerValue, coordinate); }
    float greyscale(vec3 value) { return dot(value, vec3(0.299, 0.587, 0.114)); }
    vec2 rotateVec2(vec2 value, float angle) {
        float cosine = cos(angle), sine = sin(angle);
        return vec2(cosine * value.x - sine * value.y, sine * value.x + cosine * value.y);
    }
    vec2 rotateVec2(vec3 value, float angle) { return rotateVec2(value.xy, angle); }
    vec2 rotateVec2(vec4 value, float angle) { return rotateVec2(value.xy, angle); }

    // Solve the eight coefficients of a unit-square-to-quad homography.
    // This is our implementation of projective geometry, not vendor header code.
    mat3 squareToQuad(vec2 p0, vec2 p1, vec2 p2, vec2 p3) {
        vec2 d1 = p1 - p2;
        vec2 d2 = p3 - p2;
        vec2 d3 = p0 - p1 + p2 - p3;
        float determinantValue = d1.x * d2.y - d2.x * d1.y;
        vec2 perspective = vec2(0.0);
        if (dot(d3, d3) > 1e-12) {
            if (abs(determinantValue) < 1e-8) return mat3(1.0);
            perspective = vec2(d3.x * d2.y - d2.x * d3.y, d1.x * d3.y - d3.x * d1.y) / determinantValue;
        }
        vec2 column0 = p1 - p0 + perspective.x * p1;
        vec2 column1 = p3 - p0 + perspective.y * p3;
        return mat3(vec3(column0, perspective.x), vec3(column1, perspective.y), vec3(p0, 1.0));
    }

    vec2 mul(mat2 matrixValue, vec2 vectorValue) { return matrixValue * vectorValue; }
    vec3 mul(mat3 matrixValue, vec3 vectorValue) { return matrixValue * vectorValue; }
    vec4 mul(mat4 matrixValue, vec4 vectorValue) { return matrixValue * vectorValue; }
    mat2 mul(mat2 left, mat2 right) { return left * right; }
    mat3 mul(mat3 left, mat3 right) { return left * right; }
    mat4 mul(mat4 left, mat4 right) { return left * right; }

    // SceneRenderer supplies column-major matrices (glUniformMatrix4fv transpose = GL_FALSE).
    // WE source often spells mul(vector, matrix); map that spelling to matrix * vector
    // so the mesh shaders retain M * v semantics under OpenGL.
    vec2 mul(vec2 vectorValue, mat2 matrixValue) { return matrixValue * vectorValue; }
    vec3 mul(vec3 vectorValue, mat3 matrixValue) { return matrixValue * vectorValue; }
    vec4 mul(vec4 vectorValue, mat4 matrixValue) { return matrixValue * vectorValue; }
    """

    static func bindAttribute(_ name: String, index: GLuint, to program: GLuint) {
        name.withCString { glBindAttribLocation(program, index, $0) }
    }

    static func compile(source: String, type: GLenum, label: String) throws -> GLuint {
        let shader = glCreateShader(type)
        guard shader != 0 else {
            throw error("\(label): glCreateShader returned 0. Ensure a current OpenGL 3.3 Core context exists.")
        }
        source.withCString { pointer in
            var sourcePointer: UnsafePointer<GLchar>? = pointer
            glShaderSource(shader, 1, &sourcePointer, nil)
        }
        glCompileShader(shader)
        var status: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &status)
        guard status != 0 else {
            let log = shaderLog(shader)
            glDeleteShader(shader)
            throw error("\(label): OpenGL shader compilation failed.\n\(log)")
        }
        return shader
    }

    static func shaderLog(_ shader: GLuint) -> String {
        var length: GLint = 0
        glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &length)
        guard length > 1 else { return "No compiler log was provided." }
        var characters = [GLchar](repeating: 0, count: Int(length))
        glGetShaderInfoLog(shader, length, nil, &characters)
        return String(cString: characters)
    }

    static func programLog(_ program: GLuint) -> String {
        var length: GLint = 0
        glGetProgramiv(program, GLenum(GL_INFO_LOG_LENGTH), &length)
        guard length > 1 else { return "No linker log was provided." }
        var characters = [GLchar](repeating: 0, count: Int(length))
        glGetProgramInfoLog(program, length, nil, &characters)
        return String(cString: characters)
    }
}
