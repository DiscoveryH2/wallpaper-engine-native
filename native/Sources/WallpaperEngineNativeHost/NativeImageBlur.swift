/// Native implementations of the common_blur shader interface. Sampling
/// positions and weights are recorded in native/IMAGE_BLUR.md; the original
/// reference header is development-only and is not bundled with this app.
enum NativeImageBlur {
    static let prototypes = """
    vec3 blur13(vec2 uv, vec2 stepValue);
    vec3 blur7(vec2 uv, vec2 stepValue);
    vec3 blur3(vec2 uv, vec2 stepValue);
    vec4 blur13a(vec2 uv, vec2 stepValue);
    vec4 blur7a(vec2 uv, vec2 stepValue);
    vec4 blur3a(vec2 uv, vec2 stepValue);
    vec2 blurRotateVec2(vec2 point, float angle);
    vec4 blurRadial13a(vec2 uv, vec2 center, float amount);
    vec4 blurRadial7a(vec2 uv, vec2 center, float amount);
    vec4 blurRadial3a(vec2 uv, vec2 center, float amount);
    """

    // The 13 and 7 kernels use paired bilinear samples, not integer pixel
    // offsets. Every channel is accumulated directly; the author's effect
    // shader owns masking and preservation of the original alpha channel.
    static let glsl = """
    const float weNativeBlur13Center = 0.1976406528809576;
    const vec2 weNativeBlur13Pairs[3] = vec2[3](
        vec2(1.4091998770852122, 0.2959855056006557),
        vec2(3.2979348079914822, 0.0935333619980593),
        vec2(5.2062900776825969, 0.0116608059608062)
    );
    const vec2 weNativeBlur7Taps[4] = vec2[4](
        vec2( 2.3515644035337887, 0.2028175528299753),
        vec2( 0.4694337796983720, 0.4044856614512112),
        vec2(-1.4091998770852121, 0.3213933537319605),
        vec2(-3.0000000000000000, 0.0713034319868530)
    );

    vec4 blur13a(vec2 uv, vec2 stepValue) {
        vec4 filtered = texture(g_Texture0, uv) * weNativeBlur13Center;
        for (int sampleIndex = 0; sampleIndex < 3; ++sampleIndex) {
            vec2 tap = weNativeBlur13Pairs[sampleIndex];
            vec2 offset = stepValue * tap.x;
            filtered += texture(g_Texture0, uv + offset) * tap.y;
            filtered += texture(g_Texture0, uv - offset) * tap.y;
        }
        return filtered;
    }
    vec4 blur7a(vec2 uv, vec2 stepValue) {
        vec4 filtered = vec4(0.0);
        for (int sampleIndex = 0; sampleIndex < 4; ++sampleIndex) {
            vec2 tap = weNativeBlur7Taps[sampleIndex];
            filtered += texture(g_Texture0, uv + stepValue * tap.x) * tap.y;
        }
        return filtered;
    }
    vec4 blur3a(vec2 uv, vec2 stepValue) {
        vec4 filtered = texture(g_Texture0, uv + stepValue) * 0.25;
        filtered += texture(g_Texture0, uv) * 0.5;
        filtered += texture(g_Texture0, uv - stepValue) * 0.25;
        return filtered;
    }
    vec3 blur13(vec2 uv, vec2 stepValue) { return blur13a(uv, stepValue).rgb; }
    vec3 blur7(vec2 uv, vec2 stepValue) { return blur7a(uv, stepValue).rgb; }
    vec3 blur3(vec2 uv, vec2 stepValue) { return blur3a(uv, stepValue).rgb; }

    vec2 blurRotateVec2(vec2 point, float angle) {
        float cosine = cos(angle), sine = sin(angle);
        return vec2(point.x * cosine - point.y * sine,
                    point.x * sine + point.y * cosine);
    }
    vec4 blurRadial13a(vec2 uv, vec2 center, float amount) {
        vec2 relative = uv - center;
        float angleScale = amount * 0.025;
        vec4 filtered = texture(g_Texture0, uv) * weNativeBlur13Center;
        for (int sampleIndex = 0; sampleIndex < 3; ++sampleIndex) {
            vec2 tap = weNativeBlur13Pairs[sampleIndex];
            vec2 displacement = blurRotateVec2(relative, tap.x * angleScale) - relative;
            filtered += texture(g_Texture0, center + displacement + relative) * tap.y;
            // The opposite sample mirrors the displacement. Rotating by the
            // negative angle would follow a different curve and change output.
            filtered += texture(g_Texture0, center - displacement + relative) * tap.y;
        }
        return filtered;
    }
    vec4 blurRadial7a(vec2 uv, vec2 center, float amount) {
        vec2 relative = uv - center;
        float angleScale = amount * 0.025;
        vec4 filtered = vec4(0.0);
        for (int sampleIndex = 0; sampleIndex < 4; ++sampleIndex) {
            vec2 tap = weNativeBlur7Taps[sampleIndex];
            vec2 displacement = blurRotateVec2(relative, tap.x * angleScale) - relative;
            filtered += texture(g_Texture0, center + displacement + relative) * tap.y;
        }
        return filtered;
    }
    vec4 blurRadial3a(vec2 uv, vec2 center, float amount) {
        vec2 relative = uv - center;
        vec2 displacement = blurRotateVec2(relative, amount * 0.025) - relative;
        vec4 filtered = texture(g_Texture0, center + relative) * 0.5;
        filtered += texture(g_Texture0, center + displacement + relative) * 0.25;
        filtered += texture(g_Texture0, center - displacement + relative) * 0.25;
        return filtered;
    }
    """
}
