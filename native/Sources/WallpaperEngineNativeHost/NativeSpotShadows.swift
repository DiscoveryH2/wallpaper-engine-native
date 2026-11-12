import Foundation
import simd

/// REA Light::UpdateLightViewProjection (0x26cfa08): world Z / Y / -X
/// become normalized view rows, with FOV=2*outercone and ordinary near=0.05.
/// Exact normalization and the native depth bias are not Windows parity claims.
struct NativeSpotShadows {
    let projection: NativeSpotProjection
    var right: SIMD3<Float> { projection.right }
    var up: SIMD3<Float> { projection.up }
    var forward: SIMD3<Float> { projection.forward }
    var position: SIMD3<Float> { projection.position }
    var focal: Float { projection.focal }
    var far: Float { projection.far }
    static let near = NativeSpotProjection.near
    var rows: [SIMD4<Float>] { projection.rows }

    init?(object: [String: Any], transform: simd_float4x4) {
        let outer = SceneValues.number(object["outercone"],30)
        let radius = SceneValues.number(object["radius"],5)
        guard let value = NativeSpotProjection(outerDegrees: outer, radius: radius, transform: transform) else { return nil }
        projection = value
    }

    var viewProjection: simd_float4x4 {
        projection.viewProjection
    }

    // Each spot uses the first square of its atlas slot. Point lights keep their
    // six-face layout. Clamp each PCF texel inside the spot tile to prevent an
    // adjacent point face or spot from contributing at the cone boundary.
    static let glsl = """
    float nativeSpotShadowTap(sampler2DShadow atlas, vec4 center, vec2 offset, vec2 gradient, vec2 texel, vec4 bounds) {
        vec2 position = (clamp(center.xy+offset,bounds.xy,bounds.zw))/texel-.5;
        vec2 weight = fract(position), a = clamp((floor(position)+.5)*texel,bounds.xy,bounds.zw);
        vec2 b = clamp(a+vec2(texel.x,0),bounds.xy,bounds.zw);
        vec2 c = clamp(a+vec2(0,texel.y),bounds.xy,bounds.zw), d = clamp(a+texel,bounds.xy,bounds.zw);
        float va = texture(atlas,vec3(a,clamp(center.z+dot(a-center.xy,gradient),0.0,1.0)));
        float vb = texture(atlas,vec3(b,clamp(center.z+dot(b-center.xy,gradient),0.0,1.0)));
        float vc = texture(atlas,vec3(c,clamp(center.z+dot(c-center.xy,gradient),0.0,1.0)));
        float vd = texture(atlas,vec3(d,clamp(center.z+dot(d-center.xy,gradient),0.0,1.0)));
        return mix(mix(va,vb,weight.x),mix(vc,vd,weight.x),weight.y);
    }
    float nativeSpotVisibility(vec3 delta, vec3 normal, vec4 shadow, vec4 scale,
        vec4 right, vec4 up, vec4 forward, sampler2DShadow atlas, int quality) {
        vec3 local = vec3(dot(right.xyz,delta),dot(up.xyz,delta),dot(forward.xyz,delta));
        if (local.z <= shadow.y || local.z >= shadow.z) return 1.0;
        vec2 uv = local.xy/local.z*(.5*right.w)+.5;
        if (any(lessThan(uv,vec2(0))) || any(greaterThan(uv,vec2(1)))) return 1.0;
        vec2 dimensions = vec2(scale.z*2.0,floor(scale.z*2.0*scale.x/scale.y+.5));
        vec2 tile = vec2(mod(shadow.x-1.0,scale.z)*2.0,floor((shadow.x-1.0)/scale.z)*3.0);
        vec4 center = vec4((tile+uv)/dimensions,shadow.z/(shadow.z-shadow.y)*(1.0-shadow.y/local.z),1);
        vec4 bounds = vec4(tile/dimensions+scale.xy*.5,(tile+1.0)/dimensions-scale.xy*.5);
        // Inverse-transpose plane transform also handles nonorthogonal parent
        // axes (a rotated child below a nonuniformly scaled parent).
        float distance = dot(normal,delta), determinant = dot(right.xyz,cross(up.xyz,forward.xyz));
        vec2 gradient = vec2(0);
        if (abs(distance) > .000001*length(normal)*max(length(delta),.000001)) {
            vec2 plane = vec2(dot(normal,cross(up.xyz,forward.xyz)),dot(normal,cross(forward.xyz,right.xyz)))/determinant;
            gradient = -2.0*shadow.z*shadow.y/((shadow.z-shadow.y)*right.w*distance)*plane*dimensions;
        }
        if (quality == 1) return nativeSpotShadowTap(atlas,center,vec2(0),gradient,scale.xy,bounds);
        vec2 offsets[9] = vec2[9](vec2(0),vec2(1.02323,0),vec2(-1.02323,0),vec2(0,1.02323),vec2(0,-1.02323),
            vec2(.81616),vec2(-.81616),vec2(.81616,-.81616),vec2(-.81616,.81616));
        float sum = 0.0;
        for (int i=0;i<9;++i) sum += nativeSpotShadowTap(atlas,center,offsets[i]*scale.xy,gradient,scale.xy,bounds);
        return sum/9.0;
    }
    """

    static let metal = """
    float spotShadowTapMetal(depth2d<float> atlas, float4 center, float2 offset, float2 gradient, float2 texel, float4 bounds) {
        float2 position = clamp(center.xy+offset,bounds.xy,bounds.zw)/texel-.5;
        float2 weight = fract(position), a = clamp((floor(position)+.5)*texel,bounds.xy,bounds.zw);
        float2 b = clamp(a+float2(texel.x,0),bounds.xy,bounds.zw);
        float2 c = clamp(a+float2(0,texel.y),bounds.xy,bounds.zw), d = clamp(a+texel,bounds.xy,bounds.zw);
        constexpr sampler comparison(coord::normalized,address::clamp_to_edge,filter::nearest,compare_func::less_equal);
        float va = atlas.sample_compare(comparison,a,clamp(center.z+dot(a-center.xy,gradient),0.0,1.0));
        float vb = atlas.sample_compare(comparison,b,clamp(center.z+dot(b-center.xy,gradient),0.0,1.0));
        float vc = atlas.sample_compare(comparison,c,clamp(center.z+dot(c-center.xy,gradient),0.0,1.0));
        float vd = atlas.sample_compare(comparison,d,clamp(center.z+dot(d-center.xy,gradient),0.0,1.0));
        return mix(mix(va,vb,weight.x),mix(vc,vd,weight.x),weight.y);
    }
    float spotVisibilityMetal(float3 delta, float3 normal, float4 shadow, float4 scale,
        float4 right, float4 up, float4 forward, depth2d<float> atlas, bool lowQuality = false) {
        if (shadow.x < 1.0) return 1.0;
        float3 local = float3(dot(right.xyz,delta),dot(up.xyz,delta),dot(forward.xyz,delta));
        if (local.z <= shadow.y || local.z >= shadow.z) return 1.0;
        float2 uv = local.xy/local.z*(.5*right.w)+.5;
        if (any(uv < float2(0)) || any(uv > float2(1))) return 1.0;
        uv.y = 1.0-uv.y;
        float2 dimensions = float2(scale.z*2.0,floor(scale.z*2.0*scale.x/scale.y+.5));
        float2 tile = float2(fmod(shadow.x-1.0,scale.z)*2.0,floor((shadow.x-1.0)/scale.z)*3.0);
        float4 center = float4((tile+uv)/dimensions,shadow.z/(shadow.z-shadow.y)*(1.0-shadow.y/local.z),1);
        float4 bounds = float4(tile/dimensions+scale.xy*.5,(tile+1.0)/dimensions-scale.xy*.5);
        float distance = dot(normal,delta), determinant = dot(right.xyz,cross(up.xyz,forward.xyz));
        float2 gradient = float2(0);
        if (abs(distance) > .000001*length(normal)*max(length(delta),.000001)) {
            float2 plane = float2(dot(normal,cross(up.xyz,forward.xyz)),dot(normal,cross(forward.xyz,right.xyz)))/determinant;
            gradient = -2.0*shadow.z*shadow.y/((shadow.z-shadow.y)*right.w*distance)*plane*float2(dimensions.x,-dimensions.y);
        }
        if (lowQuality) return spotShadowTapMetal(atlas,center,float2(0),gradient,scale.xy,bounds);
        const float2 offsets[9] = {float2(0),float2(1.02323,0),float2(-1.02323,0),float2(0,1.02323),float2(0,-1.02323),
            float2(.81616),float2(-.81616),float2(.81616,-.81616),float2(-.81616,.81616)};
        float sum = 0.0;
        for (int i=0;i<9;++i) sum += spotShadowTapMetal(atlas,center,offsets[i]*scale.xy,gradient,scale.xy,bounds);
        return sum/9.0;
    }
    """
}
