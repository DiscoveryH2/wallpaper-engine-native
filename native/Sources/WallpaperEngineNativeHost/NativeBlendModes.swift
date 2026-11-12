import Foundation

/// Our implementation of the observed shader blend contract. Numeric modes and
/// special opacity rules come from the official Android reference inspected for
/// interoperability; no vendor shader is bundled. See BLENDING_SHAPES.md.
enum NativeBlendModes {
    static let names = [
        "普通", "变暗", "正片叠底", "颜色加深", "线性加深", "逐通道最小值",
        "变亮", "滤色", "颜色减淡", "饱和加法", "逐通道最大值", "叠加",
        "柔光", "强光", "亮光", "线性光", "点光", "实色混合", "差值",
        "排除", "线性加深", "反射", "辉光", "反差互补", "平均", "反向差值",
        "色相", "饱和度", "颜色", "亮度", "着色", "非饱和加法", "乘积加法"
    ]

    static func supports(_ mode: Int) -> Bool { names.indices.contains(mode) }

    private static func channelBody(for mode: Int) -> String {
        let operation: String
        switch mode {
        case 0: operation = "return foreground;"
        case 1, 5: operation = "return min(background, foreground);"
        case 2: operation = "return background * foreground;"
        case 3: operation = "return weNativeBlendBurn(background, foreground);"
        case 4, 20: operation = "return max(0.0, background + foreground - 1.0);"
        case 6, 10: operation = "return max(background, foreground);"
        case 7: operation = "return 1.0 - (1.0 - background) * (1.0 - foreground);"
        case 8: operation = "return weNativeBlendDodge(background, foreground);"
        case 9: operation = "return min(1.0, background + foreground);"
        case 11: operation = "return weNativeBlendOverlay(background, foreground);"
        case 12:
            operation = """
            if (foreground < 0.5) return background * (2.0 * foreground + background * (1.0 - 2.0 * foreground));
            return sqrt(background) * (2.0 * foreground - 1.0) + 2.0 * background * (1.0 - foreground);
            """
        case 13: operation = "return weNativeBlendOverlay(foreground, background);"
        case 14: operation = "return weNativeBlendVivid(background, foreground);"
        case 15:
            operation = """
            float shifted = background + 2.0 * foreground - 1.0;
            return foreground < 0.5 ? max(0.0, shifted) : shifted;
            """
        case 16: operation = "return foreground < 0.5 ? min(background, 2.0 * foreground) : max(background, 2.0 * foreground - 1.0);"
        case 17: operation = "return step(0.5, weNativeBlendVivid(background, foreground));"
        case 18: operation = "return abs(background - foreground);"
        case 19: operation = "return background + foreground - 2.0 * background * foreground;"
        case 21: operation = "return weNativeBlendReflect(background, foreground);"
        case 22: operation = "return weNativeBlendReflect(foreground, background);"
        case 23: operation = "return 1.0 - abs(background - foreground);"
        case 24: operation = "return (background + foreground) * 0.5;"
        case 25: operation = "return 1.0 - abs(1.0 - background - foreground);"
        default: operation = "return foreground;" // Vector operations below.
        }
        return operation
    }

    private static func resultBody(for mode: Int) -> String {
        let result: String
        switch mode {
        case 5, 10:
            // These two observed variants ignore the fourth argument, too.
            result = "return \(mode == 5 ? "min" : "max")(background, foreground);"
        case 26...29:
            let components: String
            switch mode {
            case 26: components = "front.x, back.y, back.z"
            case 27: components = "back.x, front.y, back.z"
            case 28: components = "front.x, front.y, back.z"
            default: components = "back.x, back.y, front.z"
            }
            result = """
            vec3 back = weNativeBlendToHSL(background), front = weNativeBlendToHSL(foreground);
            vec3 changed = weNativeBlendFromHSL(vec3(\(components)));
            return mix(background, changed, opacity);
            """
        case 30:
            result = "return mix(background, max(background.r, max(background.g, background.b)) * foreground, opacity);"
        case 31:
            result = "return background + foreground * opacity;"
        case 32:
            result = "return mix(background, background + background * foreground, opacity);"
        default:
            result = """
            vec3 changed = vec3(weNativeBlendChannel(background.r, foreground.r),
                                weNativeBlendChannel(background.g, foreground.g),
                                weNativeBlendChannel(background.b, foreground.b));
            return mix(background, changed, opacity);
            """
        }
        return result
    }

    private static let scalarFunctions = """
        float weNativeBlendBurn(float background, float foreground) {
            if (foreground == 0.0) return 0.0;
            return max(0.0, 1.0 - (1.0 - background) / foreground);
        }
        float weNativeBlendDodge(float background, float foreground) {
            if (foreground == 1.0) return 1.0;
            return min(1.0, background / (1.0 - foreground));
        }
        float weNativeBlendVivid(float background, float foreground) {
            return foreground < 0.5 ? weNativeBlendBurn(background, 2.0 * foreground)
                : weNativeBlendDodge(background, 2.0 * foreground - 1.0);
        }
        float weNativeBlendReflect(float background, float foreground) {
            if (foreground == 1.0) return 1.0;
            return min(1.0, background * background / (1.0 - foreground));
        }
        float weNativeBlendOverlay(float background, float foreground) {
            return background < 0.5 ? 2.0 * background * foreground
                : 1.0 - 2.0 * (1.0 - background) * (1.0 - foreground);
        }
        """

    private static let hslFunctions = """
        vec3 weNativeBlendToHSL(vec3 color) {
        #ifdef HDR
            color = clamp(color, 0.0, 1.0);
        #endif
            float high = max(color.r, max(color.g, color.b));
            float low = min(color.r, min(color.g, color.b));
            float span = high - low, lightness = (high + low) * 0.5;
            if (span == 0.0) return vec3(0.0, 0.0, lightness);
            float hue;
            if (high == color.r) hue = (color.g - color.b) / span;
            else if (high == color.g) hue = 2.0 + (color.b - color.r) / span;
            else hue = 4.0 + (color.r - color.g) / span;
            float saturation = span / (lightness < 0.5 ? high + low : 2.0 - high - low);
            return vec3(fract(hue / 6.0), saturation, lightness);
        }
        vec3 weNativeBlendFromHSL(vec3 color) {
            vec3 phase = fract(color.x + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0;
            vec3 primary = clamp(abs(phase - 3.0) - 1.0, 0.0, 1.0);
            float span = (1.0 - abs(2.0 * color.z - 1.0)) * color.y;
            return color.z + (primary - 0.5) * span;
        }
        """

    /// The first ApplyBlending argument is intentionally unused. The official
    /// shader contract selects the operation at compile time using BLENDMODE.
    static func glsl(for mode: Int) -> String {
        scalarFunctions + "\nfloat weNativeBlendChannel(float background, float foreground) { \(channelBody(for: mode)) }\n"
            + hslFunctions + "\nvec3 ApplyBlending(int unusedMode, vec3 background, vec3 foreground, float opacity) { \(resultBody(for: mode)) }\n"
    }

    /// Some authored effects call the direct blend operation through a
    /// function-like opacity macro, independently of their BLENDMODE combo.
    /// Keep the saturation inside the operation, before interpolation; HDR
    /// input and extrapolating opacity therefore remain observable.
    static let directGLSL = """
        vec3 BlendLinearDodge(vec3 background, vec3 foreground) {
            return min(background + foreground, vec3(1.0));
        }
        #define BlendOpacity(background, foreground, operation, opacity) mix((background), operation((background), (foreground)), (opacity))
        """

    /// Metal's own image compositor chooses a validated layer mode at runtime.
    /// Both backends emit the same scalar and HSL equations; this is not a
    /// translation or execution of an author's shader source.
    static var metal: String {
        let channels = (0...25).map { "case \($0): { \(channelBody(for: $0)) }" }.joined(separator: "\n")
        let modes = [5, 10] + Array(26...32)
        let results = modes.map { "case \($0): { \(resultBody(for: $0)) }" }.joined(separator: "\n")
        let hsl = hslFunctions
            .replacingOccurrences(of: "weNativeBlendToHSL(vec3 color)", with: "weNativeBlendToHSL(vec3 color, bool hdr)")
            .replacingOccurrences(of: "#ifdef HDR", with: "if (hdr) {")
            .replacingOccurrences(of: "#endif", with: "}")
        let result = """
        vec3 nativeColorBlend(int mode, vec3 background, vec3 foreground, float opacity, bool hdr) {
            switch (mode) {
                \(results)
                default: { \(resultBody(for: 0)) }
            }
        }
        """
            .replacingOccurrences(of: "weNativeBlendChannel(", with: "weNativeBlendChannel(mode, ")
            .replacingOccurrences(of: "weNativeBlendToHSL(background)", with: "weNativeBlendToHSL(background, hdr)")
            .replacingOccurrences(of: "weNativeBlendToHSL(foreground)", with: "weNativeBlendToHSL(foreground, hdr)")
        return (scalarFunctions + hsl + """
        float weNativeBlendChannel(int mode, float background, float foreground) {
            switch (mode) { \(channels) default: return foreground; }
        }
        """ + result).replacingOccurrences(of: "vec3", with: "float3")
    }
}
