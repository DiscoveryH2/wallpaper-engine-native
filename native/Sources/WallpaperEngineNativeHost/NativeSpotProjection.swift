import Foundation
import simd

/// Shared spotlight projection geometry, independent of whether the light casts
/// a shadow. REA Light::UpdateLightViewProjection supplies world Z / Y / X as
/// right / up / forward and a square perspective with FOV = 2 * outercone.
/// Native normalization is exact; the reference uses a fast approximation.
struct NativeSpotProjection {
    let right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>
    let position: SIMD3<Float>, focal: Float, far: Float
    static let near: Float = 0.05
    // Four Float ULPs at UV=1 absorb division/FMA rounding at the closed
    // frustum edge (less than 0.008 texel at a 16K source). This native guard
    // is not evidence about the reference sampler's border behavior.
    private static let edgeTolerance = 4 * Float.ulpOfOne
    var rows: [SIMD4<Float>] { [SIMD4(right, focal), SIMD4(up, 0), SIMD4(forward, 0)] }

    init?(outerDegrees: Float, radius: Float, transform: simd_float4x4) {
        guard outerDegrees.isFinite, outerDegrees > 0, outerDegrees < 90,
              radius.isFinite, radius > 0 else { return nil }
        func unit(_ column: SIMD4<Float>) -> SIMD3<Float>? {
            let value = SIMD3<Double>(Double(column.x), Double(column.y), Double(column.z))
            let size = simd_length(value)
            return size.isFinite && size > 0 ? SIMD3<Float>(value / size) : nil
        }
        guard let r = unit(transform[2]), let u = unit(transform[1]), let f = unit(transform[0]),
              abs(simd_dot(r, simd_cross(u, f))) > 0.000001 else { return nil }
        right = r; up = u; forward = f
        position = SIMD3(transform[3].x, transform[3].y, transform[3].z)
        focal = 1 / tan(outerDegrees * .pi / 180)
        far = max(Self.near + 0.01, radius)
        guard [position.x, position.y, position.z, focal, far].allSatisfy(\.isFinite), focal > 0 else { return nil }
    }

    var viewProjection: simd_float4x4 {
        let back = -forward, near = Self.near
        let view = simd_float4x4(columns: (
            SIMD4(right.x, up.x, back.x, 0), SIMD4(right.y, up.y, back.y, 0),
            SIMD4(right.z, up.z, back.z, 0),
            SIMD4(-simd_dot(right, position), -simd_dot(up, position), -simd_dot(back, position), 1)))
        let projection = simd_float4x4(columns: (
            SIMD4(focal, 0, 0, 0), SIMD4(0, focal, 0, 0),
            SIMD4(0, 0, -(far + near) / (far - near), -1), SIMD4(0, 0, -2 * far * near / (far - near), 0)))
        return projection * view
    }

    /// Top-left texture coordinates. The reference CalculateProjectedCoords
    /// flips Y after perspective division. Cookie projection uses the square
    /// frustum, with no ordinary cone multiplier or shadow near/far rejection.
    /// Nil is a native sampling guard for behind/outside/nonfinite coordinates;
    /// it does not claim the reference texture's border sampler configuration.
    func textureCoordinates(world: SIMD3<Float>) -> SIMD2<Float>? {
        let delta = world - position
        let local = SIMD3(simd_dot(right, delta), simd_dot(up, delta), simd_dot(forward, delta))
        guard local.z > 0, [local.x, local.y, local.z].allSatisfy(\.isFinite) else { return nil }
        let uv = SIMD2(local.x, -local.y) / local.z * (0.5 * focal) + 0.5
        let tolerance = Self.edgeTolerance
        guard uv.x >= -tolerance, uv.x <= 1+tolerance, uv.y >= -tolerance, uv.y <= 1+tolerance else { return nil }
        return simd_clamp(uv, .zero, SIMD2(repeating: 1))
    }

    /// .xy are top-left UV; .z is 1 for a finite point in the projected square.
    /// Sampling remains separate so source TEX, video and rendered-layer storage
    /// can choose their own atlas and native texture-coordinate convention.
    static let metal = """
    float3 nativeSpotProjectionUV(float3 delta, float4 right, float4 up, float4 forward) {
        float3 local = float3(dot(right.xyz, delta), dot(up.xyz, delta), dot(forward.xyz, delta));
        if (!(local.z > 0.0) || !all(isfinite(local))) return float3(0);
        float2 uv = local.xy / local.z * float2(0.5, -0.5) * right.w + 0.5;
        constexpr float edgeTolerance = 0.000000476837158203125;
        if (!all(uv >= float2(-edgeTolerance)) || !all(uv <= float2(1+edgeTolerance))) return float3(0);
        return float3(clamp(uv, float2(0), float2(1)), 1);
    }
    """

    static let glsl = """
    vec3 nativeSpotProjectionUV(vec3 delta, vec4 right, vec4 up, vec4 forward) {
        vec3 local = vec3(dot(right.xyz, delta), dot(up.xyz, delta), dot(forward.xyz, delta));
        if (!(local.z > 0.0) || any(isnan(local)) || any(isinf(local))) return vec3(0);
        vec2 uv = local.xy / local.z * vec2(0.5, -0.5) * right.w + 0.5;
        const float edgeTolerance = 0.000000476837158203125;
        if (!all(greaterThanEqual(uv, vec2(-edgeTolerance))) || !all(lessThanEqual(uv, vec2(1+edgeTolerance)))) return vec3(0);
        return vec3(clamp(uv, vec2(0), vec2(1)), 1);
    }
    """
}
