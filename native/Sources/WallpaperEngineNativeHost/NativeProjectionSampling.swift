import Foundation

/// Projected RGB is independent of the ordinary spot cone and shadow depth.
/// The projection math follows the retained official shader evidence. Atlas
/// packing, black outside the square and half-texel subregion isolation are
/// native policies; the reference engine's border sampler remains unverified.
enum NativeProjectionSampling {
    static let metal = NativeSpotProjection.metal + """
    float3 nativeProjectionColor(texture2d<float> atlas, float3 delta,
        float4 right, float4 up, float4 forward, float4 region, bool nearest) {
        float3 projected = nativeSpotProjectionUV(delta,right,up,forward);
        if (projected.z <= 0.0 || !all(isfinite(region)) || any(region.zw <= 0.0)) return float3(0.0);
        float2 inset = min(float2(0.5) / float2(atlas.get_width(),atlas.get_height()),region.zw * 0.5);
        float2 uv = clamp(region.xy + projected.xy * region.zw,region.xy + inset,region.xy + region.zw - inset);
        constexpr sampler linearSampler(coord::normalized,address::clamp_to_edge,filter::linear);
        constexpr sampler nearestSampler(coord::normalized,address::clamp_to_edge,filter::nearest);
        return nearest ? atlas.sample(nearestSampler,uv,level(0.0)).rgb : atlas.sample(linearSampler,uv,level(0.0)).rgb;
    }
    """

    static let glsl = NativeSpotProjection.glsl + """
    vec3 nativeProjectionColor(sampler2D atlas, vec3 delta,
        vec4 right, vec4 up, vec4 forward, vec4 region, bool nearest) {
        vec3 projected = nativeSpotProjectionUV(delta,right,up,forward);
        if (projected.z <= 0.0 || any(isnan(region)) || any(isinf(region)) || any(lessThanEqual(region.zw,vec2(0.0)))) return vec3(0.0);
        vec2 size = vec2(textureSize(atlas,0));
        vec2 inset = min(vec2(0.5) / size,region.zw * 0.5);
        vec2 uv = clamp(region.xy + projected.xy * region.zw,region.xy + inset,region.xy + region.zw - inset);
        if (nearest) return texelFetch(atlas,clamp(ivec2(floor(uv * size)),ivec2(0),ivec2(size)-ivec2(1)),0).rgb;
        return textureLod(atlas,uv,0.0).rgb;
    }
    """
}
