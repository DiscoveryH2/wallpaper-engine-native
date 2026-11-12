import Foundation
import simd

/// Owned model material. This is a bounded generic4 compatibility path,
/// not a copy of the vendor's headers. It implements GGX direct lighting and
/// distance fog, previous-frame reflection and point shadows. Point volumetrics
/// are integrated by a separate native scene pass.
enum NativeModelMaterial {
    static func combinations(_ definition: [String: Any]) throws -> [String: Int] {
        let chroma = definition["shader"] as? String == "chroma4"
        let switches = ["LIGHTING", "FOG", "REFLECTION", "NORMALMAP", "PBRMASKS",
            "METALLIC_MAP", "ROUGHNESS_MAP", "REFLECTION_MAP", "EMISSIVE_MAP", "TINTMASKALPHA",
            "RIMLIGHTING", "SHADINGGRADIENT"]
        var result = Dictionary(uniqueKeysWithValues: switches.map { ("NATIVE_" + $0, 0) })
        result["NATIVE_CHROMA"] = chroma ? 1 : 0
        result["NATIVE_LIGHTING"] = 1; result["NATIVE_FOG"] = 1
        guard definition["textures"] == nil || definition["textures"] is [Any],
              definition["combos"] == nil || definition["combos"] is [String: Any] else {
            throw SceneError.invalid("模型材质纹理和组合声明类型无效。")
        }
        let textures = definition["textures"] as? [Any] ?? []
        guard textures.count <= (chroma ? 9 : 8) else { throw SceneError.invalid("模型纹理槽位超过当前材质上限。") }
        func supplied(_ slot: Int) -> Bool {
            textures.indices.contains(slot) && (textures[slot] as? String).map { !$0.isEmpty } == true
        }
        // Resource annotations derive these two switches from supplied slots.
        // Explicit author choices take precedence; unused maps stay unloaded.
        result["NATIVE_NORMALMAP"] = supplied(1) ? 1 : 0
        result["NATIVE_PBRMASKS"] = supplied(2) ? 1 : 0
        // Explicit material sampler 7 is known from the official shader.
        // Resolving the engine-owned _alias_lightCookie remains separate.
        result["NATIVE_PROJECTION_SOURCE"] = supplied(7) ? 1 : 0
        for (name, raw) in definition["combos"] as? [String: Any] ?? [:] {
            guard let number = raw as? NSNumber, let value = Int(exactly: number.doubleValue) else {
                throw SceneError.invalid("模型材质组合 \(name) 不是有限整数。")
            }
            if switches.contains(name), [0, 1].contains(value) {
                result["NATIVE_" + name] = value
            } else if value != 0 {
                throw SceneError.invalid("模型材质组合 \(name)=\(value) 尚未实现。")
            }
        }
        for (slot, raw) in textures.enumerated() {
            guard raw is NSNull || (raw as? String).map({ !$0.isEmpty }) == true else {
                throw SceneError.invalid("模型材质纹理槽 \(slot) 名称无效。")
            }
            if slot >= 3, !(raw is NSNull) {
                let reflection = slot == 3 && raw as? String == "_rt_MipMappedFrameBuffer" && result["NATIVE_REFLECTION"] == 1
                guard reflection || slot == 4 || slot == 7 || (chroma && slot == 8) else {
                    throw SceneError.invalid("模型材质纹理槽 \(slot) 尚未实现。")
                }
            }
        }
        for (name, slot) in [("NORMALMAP", 1), ("PBRMASKS", 2)] {
            guard result["NATIVE_" + name] != 1 || supplied(slot) else {
                throw SceneError.invalid("模型材质 \(name) 缺少纹理槽 \(slot)。")
            }
        }
        if ["METALLIC_MAP", "ROUGHNESS_MAP", "REFLECTION_MAP", "EMISSIVE_MAP"].contains(where: { result["NATIVE_" + $0] == 1 }),
           result["NATIVE_PBRMASKS"] != 1 {
            throw SceneError.invalid("模型材质分量贴图需要启用 PBRMASKS 和纹理槽 2。")
        }
        return result
    }

    /// Tiny authored model scales are valid. Use Double for inversion instead
    /// of an absolute Float determinant cutoff (snowflake A uses 0.00002 in Z).
    static func normalMatrix(_ model: simd_float4x4) -> simd_float3x3? {
        let matrix = simd_double3x3((0..<3).map {
            SIMD3<Double>(Double(model[$0].x), Double(model[$0].y), Double(model[$0].z))
        })
        let determinant = simd_determinant(matrix)
        guard determinant.isFinite, determinant != 0 else { return nil }
        let inverseTranspose = simd_transpose(simd_inverse(matrix))
        let result = simd_float3x3((0..<3).map { SIMD3<Float>(inverseTranspose[$0]) })
        return (0..<3).allSatisfy({ column in (0..<3).allSatisfy { result[column][$0].isFinite } }) ? result : nil
    }

    static let vertex = """
    attribute vec3 a_Position;
    attribute vec3 a_Normal;
    attribute vec2 a_TexCoord;
    #if NATIVE_NORMALMAP && (NATIVE_LIGHTING || NATIVE_REFLECTION || NATIVE_CHROMA)
    attribute vec4 a_Tangent;
    varying vec3 modelTangent;
    varying vec3 modelBitangent;
    #endif
    uniform mat4 g_ModelMatrix;
    uniform mat4 g_ViewProjectionMatrix;
    uniform mat3 g_NativeNormalMatrix;
    #if NATIVE_BONE_COUNT > 0
    attribute vec4 a_NativeBoneIndices;
    attribute vec4 a_NativeBoneWeights;
    uniform mat4 g_NativeBones[NATIVE_BONE_COUNT];
    #endif
    varying vec3 modelWorldPosition;
    varying vec3 modelWorldNormal;
    varying vec2 modelUV;
    #if NATIVE_REFLECTION || NATIVE_CHROMA
    varying vec3 modelClipPosition;
    #endif
    void main() {
        vec4 localPosition = vec4(a_Position, 1.0);
        vec3 localNormal = a_Normal;
    #if NATIVE_NORMALMAP && (NATIVE_LIGHTING || NATIVE_REFLECTION || NATIVE_CHROMA)
        vec3 localTangent = a_Tangent.xyz;
    #endif
    #if NATIVE_BONE_COUNT > 0
        ivec4 joints = ivec4(a_NativeBoneIndices);
        mat4 skin = g_NativeBones[joints.x] * a_NativeBoneWeights.x
                  + g_NativeBones[joints.y] * a_NativeBoneWeights.y
                  + g_NativeBones[joints.z] * a_NativeBoneWeights.z
                  + g_NativeBones[joints.w] * a_NativeBoneWeights.w;
        // Reference bone palettes are affine mat4x3: only xyz is skinned,
        // then a fresh w=1 applies the instance translation. Preserve that
        // order even when authored weights sum only approximately to one.
        localPosition = vec4((skin * localPosition).xyz, 1.0);
        localNormal = mat3(skin) * localNormal;
    #if NATIVE_NORMALMAP && (NATIVE_LIGHTING || NATIVE_REFLECTION || NATIVE_CHROMA)
        localTangent = mat3(skin) * localTangent;
    #endif
    #endif
        vec4 world = g_ModelMatrix * localPosition;
        modelWorldPosition = world.xyz;
        modelWorldNormal = g_NativeNormalMatrix * localNormal;
    #if NATIVE_NORMALMAP && (NATIVE_LIGHTING || NATIVE_REFLECTION || NATIVE_CHROMA)
        modelTangent = g_NativeNormalMatrix * localTangent;
        modelBitangent = g_NativeNormalMatrix * (cross(localNormal, localTangent) * a_Tangent.w);
        modelWorldNormal = length(modelWorldNormal) > 0.0000001 ? normalize(modelWorldNormal) : vec3(0.0,0.0,1.0);
    #endif
        modelUV = a_TexCoord;
        gl_Position = g_ViewProjectionMatrix * world;
    #if NATIVE_REFLECTION || NATIVE_CHROMA
        modelClipPosition = gl_Position.xyw;
    #endif
    }
    """

    /// A flat triangle plane avoids unreliable screen derivatives at small
    /// triangle boundaries on the native OpenGL path. Positions here have
    /// already received the current skin palette and full instance transform.
    static let receiverVertex: String = {
        var source = vertex
        for name in ["modelWorldPosition", "modelWorldNormal", "modelUV", "modelTangent", "modelBitangent", "modelClipPosition"] {
            source = source.replacingOccurrences(of: "\\b" + name + "\\b", with: name + "Vertex", options: .regularExpression)
        }
        return source
    }()

    static let receiverGeometry = """
    layout(triangles) in;
    layout(triangle_strip, max_vertices = 3) out;
    in vec3 modelWorldPositionVertex[];
    in vec3 modelWorldNormalVertex[];
    in vec2 modelUVVertex[];
    out vec3 modelWorldPosition;
    out vec3 modelWorldNormal;
    out vec2 modelUV;
    flat out vec3 modelReceiverNormal;
    #if NATIVE_NORMALMAP && (NATIVE_LIGHTING || NATIVE_REFLECTION || NATIVE_CHROMA)
    in vec3 modelTangentVertex[];
    in vec3 modelBitangentVertex[];
    out vec3 modelTangent;
    out vec3 modelBitangent;
    #endif
    #if NATIVE_REFLECTION || NATIVE_CHROMA
    in vec3 modelClipPositionVertex[];
    out vec3 modelClipPosition;
    #endif
    void main() {
        vec3 plane = cross(modelWorldPositionVertex[1] - modelWorldPositionVertex[0],
                           modelWorldPositionVertex[2] - modelWorldPositionVertex[0]);
        for (int i = 0; i < 3; ++i) {
            gl_Position = gl_in[i].gl_Position;
            gl_PrimitiveID = gl_PrimitiveIDIn;
            modelWorldPosition = modelWorldPositionVertex[i];
            modelWorldNormal = modelWorldNormalVertex[i];
            modelUV = modelUVVertex[i];
            modelReceiverNormal = plane;
        #if NATIVE_NORMALMAP && (NATIVE_LIGHTING || NATIVE_REFLECTION || NATIVE_CHROMA)
            modelTangent = modelTangentVertex[i];
            modelBitangent = modelBitangentVertex[i];
        #endif
        #if NATIVE_REFLECTION || NATIVE_CHROMA
            modelClipPosition = modelClipPositionVertex[i];
        #endif
            EmitVertex();
        }
        EndPrimitive();
    }
    """

    static let fragment = """
    #if NATIVE_LIGHTING
    flat in vec3 modelReceiverNormal;
    #endif
    uniform sampler2D g_Texture0; // {"material":"albedo","default":"util/white"}
    #if NATIVE_NORMALMAP && (NATIVE_LIGHTING || NATIVE_REFLECTION || NATIVE_CHROMA)
    uniform sampler2D g_Texture1;
    uniform int g_NativeNormalFormat;
    varying vec3 modelTangent;
    varying vec3 modelBitangent;
    #endif
    #if NATIVE_PBRMASKS
    uniform sampler2D g_Texture2;
    #endif
    #if NATIVE_EMISSIVE_MAP
    uniform vec3 g_EmissiveColor; // {"material":"emissivecolor","default":"1 1 1"}
    uniform float g_EmissiveBrightness; // {"material":"emissivebrightness","default":1}
    #endif
    uniform vec3 g_TintColor; // {"material":"color","default":"1 1 1"}
    uniform float g_TintAlpha; // {"material":"alpha","default":1}
    uniform float g_Roughness; // {"material":"roughness","default":0.7}
    uniform float g_Metallic; // {"material":"metallic","default":0}
    uniform float g_Brightness; // {"material":"brightness","default":1}
    #if NATIVE_LIGHTING && NATIVE_SHADINGGRADIENT
    uniform sampler2D g_Texture4; // {"default":"gradient/gradient_toon_smooth"}
    uniform int g_NativeGradientFormat;
    #endif
    #if NATIVE_LIGHTING && NATIVE_RIMLIGHTING
    uniform float g_RimAmount; // {"material":"rimamount","default":2}
    uniform float g_RimExponent; // {"material":"rimexponent","default":4}
    #endif
    #if NATIVE_REFLECTION
    uniform sampler2D g_Texture3; // {"hidden":true,"default":"_rt_MipMappedFrameBuffer"}
    uniform float g_Texture3MipMapInfo;
    uniform int g_NativeReflectionEnabled;
    uniform float g_Reflectivity; // {"material":"reflectivity","default":1}
    uniform mat4 g_ViewProjectionMatrix;
    #endif
    #if NATIVE_REFLECTION || NATIVE_CHROMA
    uniform vec3 g_Screen;
    varying vec3 modelClipPosition;
    #endif
    #if NATIVE_CHROMA
    uniform vec3 g_TintFront; // {"material":"tintfront","default":"1 1 1"}
    uniform vec3 g_TintBack; // {"material":"tintback","default":"1 1 1"}
    uniform vec3 g_SpecularTint; // {"material":"speculartint","default":"1 1 1"}
    uniform float g_TintExponent; // {"material":"tintwexponent","default":1.5}
    uniform float g_TintPigmentation; // {"material":"tintpigmentation","default":0.5}
    #if NATIVE_LIGHTING || NATIVE_EMISSIVE_MAP
    uniform sampler2D g_Texture8; // {"material":"noise","default":"util/noise"}
    uniform vec4 g_Texture8Resolution;
    #endif
    #endif
    uniform vec3 g_EyePosition;
    uniform vec3 g_NativeAmbient;
    uniform vec3 g_NativeSkylight;
    uniform int g_NativeLightCount;
    uniform vec4 g_NativeLightPositionRadius[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeLightColorExponent[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeLightSpotDirection[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeLightSpotParameters[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeProjectionRight[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeProjectionUp[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeProjectionForward[\(NativeModelLightFrame.maximumLights)];
    #if NATIVE_LIGHTING && NATIVE_PROJECTION_SOURCE
    uniform sampler2D g_Texture7;
    uniform vec4 g_NativeProjectionRegion;
    uniform int g_NativeProjectionNearest;
    #endif
    uniform sampler2DShadow g_NativeShadowAtlas;
    uniform vec4 g_NativeLightShadow[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeShadowScale;
    uniform int g_NativeShadowQuality;
    uniform vec4 g_NativeSpotShadowRight[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeSpotShadowUp[\(NativeModelLightFrame.maximumLights)];
    uniform vec4 g_NativeSpotShadowForward[\(NativeModelLightFrame.maximumLights)];
    uniform int g_NativeFogEnabled;
    uniform vec3 g_NativeFogColor;
    uniform vec4 g_NativeFogParams;
    varying vec3 modelWorldPosition;
    varying vec3 modelWorldNormal;
    varying vec2 modelUV;

    vec3 modelUnit(vec3 v, vec3 fallbackValue) {
        float len = length(v);
        return len > 0.0000001 ? v / len : fallbackValue;
    }

    \(NativePointShadows.projectionGLSL)
    \(NativePointShadows.receiverGLSL)
    \(NativeSpotShadows.glsl)
    \(NativeProjectionSampling.glsl)

    float pointVisibility(int lightIndex, vec3 delta, vec3 receiverNormal) {
        vec4 shadow = g_NativeLightShadow[lightIndex];
        if (shadow.x < 1.0) return 1.0;
        if (shadow.w > .5) return nativeSpotVisibility(delta,receiverNormal,shadow,g_NativeShadowScale,
            g_NativeSpotShadowRight[lightIndex],g_NativeSpotShadowUp[lightIndex],g_NativeSpotShadowForward[lightIndex],g_NativeShadowAtlas,g_NativeShadowQuality);
        vec4 coordinates = nativePointShadowCoordinates(delta, shadow, g_NativeShadowScale);
        if (coordinates.w < 0.5) return 1.0;
        vec2 gradient = nativePointShadowReceiverGradient(delta, receiverNormal, shadow, g_NativeShadowScale);
        // An exactly constant-depth plane needs no per-texel correction.
        if (g_NativeShadowQuality == 1) return nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, vec2(0), gradient, g_NativeShadowScale.xy);
        if (all(equal(gradient, vec2(0.0)))) return nativePointShadowFlatVisibility(g_NativeShadowAtlas, coordinates, g_NativeShadowScale.xy);
        // Keep the nine-tap footprint and its bilinear weights, correcting the
        // receiver depth at all four texels in each tap. The 92-degree projection
        // guard keeps this entire footprint inside the selected face.
        vec2 crossStep = g_NativeShadowScale.xy * 1.02323;
        vec2 cornerStep = g_NativeShadowScale.xy * 0.81616;
        vec2 texel = g_NativeShadowScale.xy;
        float visible = nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, vec2(0.0), gradient, texel);
        visible += nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, vec2(crossStep.x, 0.0), gradient, texel);
        visible += nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, vec2(-crossStep.x, 0.0), gradient, texel);
        visible += nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, vec2(0.0, crossStep.y), gradient, texel);
        visible += nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, vec2(0.0, -crossStep.y), gradient, texel);
        visible += nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, cornerStep, gradient, texel);
        visible += nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, -cornerStep, gradient, texel);
        visible += nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, vec2(cornerStep.x, -cornerStep.y), gradient, texel);
        visible += nativePointShadowReceiverTap(g_NativeShadowAtlas, coordinates, vec2(-cornerStep.x, cornerStep.y), gradient, texel);
        return visible / 9.0;
    }

    vec3 modelLight(vec3 n, vec3 v, vec3 l, vec3 radiance, vec3 albedo, float metal, float rough, float shadow, bool pointLight, float lightEnergy, vec3 specularTint) {
        const float pi = 3.141592653589793;
        vec3 h = modelUnit(l + v, n);
        float nv = max(dot(n, v), 0.0);
        float dnl = dot(n, l);
        float nh = max(dot(n, h), 0.0);
        float hv = clamp(dot(h, v), 0.0, 1.0);
        float a2 = rough * rough * rough * rough;
        float denominator = nh * nh * (a2 - 1.0) + 1.0;
        float distribution = shadow * a2 / max(pi * denominator * denominator, 0.00000001);
        float k = (rough + 1.0) * (rough + 1.0) * 0.125;
        vec2 cosines = max(vec2(nv, dnl), vec2(0.001));
        vec2 visibility = cosines / (cosines * (1.0 - k) + k);
        vec3 reflectance = mix(vec3(0.04), albedo, metal);
        vec3 fresnel = reflectance + (vec3(1.0) - reflectance) * pow(max(1.0 - hv, 0.001), 5.0);
        vec3 nl = vec3(max(dnl * shadow, 0.0));
    #if NATIVE_LIGHTING && NATIVE_SHADINGGRADIENT
        float coordinate = max(min(shadow, dnl) * 0.5 + 0.5, 0.0);
        vec4 gradient = texture(g_Texture4, vec2(coordinate, 0.0));
        nl = (g_NativeGradientFormat == 8 || g_NativeGradientFormat == 9) ? gradient.rrr : gradient.rgb;
    #endif
        float diffuseMetal = metal;
    #if NATIVE_LIGHTING && NATIVE_RIMLIGHTING
        // A transformed tangent basis need not be unit length. Keep pow in
        // its finite domain; positive authored exponents retain their value.
        float rim = shadow * pow(max(1.0 - nv, 0.0), max(g_RimExponent, 0.000001))
            * g_RimAmount * nl.x * step(0.001, lightEnergy);
        nl = max(nl, vec3(rim));
        // The reference point light forms diffuse before rim, directional
        // light afterwards. Fresnel always uses the original metallic value.
        if (!pointLight) diffuseMetal -= clamp(rim, 0.0, 1.0);
    #endif
        vec3 specular = distribution * visibility.x * visibility.y * fresnel / max(4.0 * nv * nl, vec3(0.001));
        vec3 diffuse = albedo * (1.0 - diffuseMetal) * (vec3(1.0) - fresnel) / pi;
        return radiance * (diffuse + specular * specularTint) * nl;
    }

    void main() {
        vec4 texel = texture(g_Texture0, modelUV);
        float tintWeight = texel.a;
        vec3 base = texel.rgb * g_TintColor;
    #if NATIVE_TINTMASKALPHA
        base = mix(texel.rgb, vec3(max(texel.r,max(texel.g,texel.b))) * g_TintColor, texel.a);
        texel.a = 1.0;
    #endif
        vec3 geometricNormal = modelUnit(modelWorldNormal, vec3(0.0, 0.0, 1.0));
        vec3 normal = geometricNormal;
    #if NATIVE_NORMALMAP && (NATIVE_LIGHTING || NATIVE_REFLECTION || NATIVE_CHROMA)
        vec4 encoded = texture(g_Texture1, modelUV);
        vec2 xy = (g_NativeNormalFormat == 8 ? encoded.rg : encoded.ag) * 2.0 - 1.0;
        if ((g_NativeNormalFormat >= 3 && g_NativeNormalFormat <= 7) || g_NativeNormalFormat == 12) xy.y += 0.035;
        vec3 tangentNormal = vec3(xy, sqrt(clamp(1.0-dot(xy,xy),0.0,1.0)));
        normal = modelTangent*tangentNormal.x + modelBitangent*tangentNormal.y + modelWorldNormal*tangentNormal.z;
    #endif
        vec4 masks = vec4(1.0);
    #if NATIVE_PBRMASKS
        masks = texture(g_Texture2, modelUV);
    #endif
        vec3 eyeDelta = g_EyePosition - modelWorldPosition;
        vec3 view = modelUnit(eyeDelta, normal);
        vec3 specularTint = vec3(1.0);
    #if NATIVE_CHROMA
        float facingTint = dot(view, normal);
    #if NATIVE_TINTMASKALPHA
        float tintBlend = pow(max(facingTint, 0.0), max(g_TintExponent, 0.000001));
        base *= mix(vec3(1.0), mix(g_TintBack, g_TintFront, tintBlend), tintWeight);
        specularTint = mix(vec3(1.0), g_SpecularTint, tintWeight);
    #else
        base = texel.rgb * mix(g_TintBack, g_TintFront, facingTint);
        specularTint = g_SpecularTint;
    #endif
    #endif
        vec3 ambient = base;
        vec3 direct = vec3(0.0);
        float roughness = clamp(g_Roughness, 0.0, 1.0);
        float metal = clamp(g_Metallic, 0.0, 1.0);
    #if NATIVE_METALLIC_MAP
        metal = masks.r;
    #endif
    #if NATIVE_ROUGHNESS_MAP
        roughness = masks.g;
    #endif
    #if NATIVE_LIGHTING
        ambient = base * mix(g_NativeSkylight, g_NativeAmbient, clamp(geometricNormal.y * 0.5 + 0.5, 0.0, 1.0));
        float rough = max(roughness, 0.02);
        for (int i = 0; i < \(NativeModelLightFrame.maximumLights); ++i) {
            if (i >= g_NativeLightCount) break;
            vec4 spatial = g_NativeLightPositionRadius[i];
            vec4 energy = g_NativeLightColorExponent[i];
            vec3 delta = spatial.w > 0.0 ? spatial.xyz - modelWorldPosition : spatial.xyz;
            float attenuation = 1.0;
            if (spatial.w > 0.0) {
                float falloff = max(0.0, 1.0 - length(delta) / spatial.w);
                attenuation = falloff >= 0.00006103515625 ? pow(falloff + 0.00006103515625, energy.w) : 0.0;
            }
            float cone = 1.0;
            vec4 spot = g_NativeLightSpotDirection[i];
            vec4 coneParameters = g_NativeLightSpotParameters[i];
            if (coneParameters.y > 0.0 && coneParameters.z == 0.0) {
                float cosine = -dot(modelUnit(delta, normal), spot.xyz);
                float width = coneParameters.x - spot.w;
                float progress = width > 0.0 ? clamp((cosine - spot.w) / width, 0.0, 1.0) : step(spot.w, cosine);
                cone = progress * progress * (3.0 - 2.0 * progress);
            }
            float visible = spatial.w > 0.0 && attenuation > 0.0 ? pointVisibility(i, -delta, modelReceiverNormal) : 1.0;
            vec3 projectedColor = vec3(cone);
            if (coneParameters.z > 0.0) {
                projectedColor = vec3(0.0);
            #if NATIVE_PROJECTION_SOURCE
                projectedColor = nativeProjectionColor(g_Texture7,-delta,g_NativeProjectionRight[i],g_NativeProjectionUp[i],
                    g_NativeProjectionForward[i],g_NativeProjectionRegion,g_NativeProjectionNearest != 0);
            #endif
            }
            vec3 lightColor = energy.rgb * projectedColor;
            direct += modelLight(normal, view, modelUnit(delta, normal), lightColor * attenuation, base, metal, rough, visible,
                spatial.w > 0.0, lightColor.r + lightColor.g + lightColor.b, specularTint);
        }
    #endif
    #if NATIVE_EMISSIVE_MAP
        direct = max(direct, g_EmissiveColor * base * (masks.a * g_EmissiveBrightness));
    #endif
    #if NATIVE_CHROMA && (NATIVE_LIGHTING || NATIVE_EMISSIVE_MAP)
        vec2 noiseUV = (modelClipPosition.xy / modelClipPosition.z * 0.5 + 0.5) * g_Screen.xy / g_Texture8Resolution.xy;
        vec3 noise = texture(g_Texture8, noiseUV).rgb * 2.0 - 1.0;
        float projected = dot(noise - 2.0 * dot(view, noise) * view, normal);
        float wave = abs(sin(9.0 * length(eyeDelta) * projected));
        direct += vec3((wave * wave * wave - 0.25) * g_TintPigmentation * dot(direct, vec3(0.299, 0.587, 0.114)));
    #endif
        vec3 color = ambient + direct;
    #ifdef HDR
        float directLength = length(direct);
        color = clamp(color, 0.0, 1.0) + direct * (clamp(directLength - 2.0, 0.0, 1.0) * 0.5 / max(0.01, directLength));
    #endif
    #if NATIVE_REFLECTION
        // The desktop branch offsets a projected normal in screen coordinates.
        // This samples the previous scene before global bloom; it is not a
        // ray march or a cubemap. No author material is rewritten to enable it.
        if (g_NativeReflectionEnabled != 0) {
        float facing = clamp(abs(dot(normal, view)), 0.0, 1.0);
        vec3 projectedNormal = modelUnit(mat3(g_ViewProjectionMatrix) * normal, vec3(0.0, 0.0, 1.0));
        vec2 reflectedUV = modelClipPosition.xy / modelClipPosition.z * 0.5 + 0.5;
        reflectedUV += projectedNormal.xy * vec2(0.15, 0.15 * g_Screen.z) * pow(facing, 4.0) * 10.0;
        // Increasing-edge smoothstep keeps the reference edge fade defined in GLSL.
        vec2 edgeFade = (vec2(1.0) - smoothstep(vec2(1.0), vec2(1.3), reflectedUV))
                      * smoothstep(vec2(-0.3), vec2(0.0), reflectedUV);
        vec3 reflected = textureLod(g_Texture3, reflectedUV, roughness * g_Texture3MipMapInfo).rgb;
        reflected *= edgeFade.x * edgeFade.y * (1.0 - facing) * clamp(g_Reflectivity, 0.0, 1.0);
    #if NATIVE_REFLECTION_MAP
        reflected *= masks.b;
    #endif
        color += clamp(pow(max(vec3(0.001), reflected), vec3(2.0 - metal)), 0.0, 1.0);
        }
    #endif
    #ifdef HDR
        color *= g_Brightness;
    #if (NATIVE_LIGHTING || NATIVE_REFLECTION) && NATIVE_EMISSIVE_MAP
        color += g_EmissiveColor * color * max(0.0, masks.a * (g_EmissiveBrightness - 1.0));
    #endif
    #endif
    #if NATIVE_FOG
        if (g_NativeFogEnabled != 0) {
            float distanceFraction = clamp((length(eyeDelta) - g_NativeFogParams.x) / g_NativeFogParams.y, 0.0, 1.0);
            float fog = clamp(g_NativeFogParams.z + g_NativeFogParams.w * distanceFraction * distanceFraction, 0.0, 1.0);
            color = mix(color, g_NativeFogColor, fog);
        }
    #endif
        gl_FragColor = vec4(color, clamp(texel.a * g_TintAlpha, 0.0, 1.0));
    }
    """
}

struct NativeModelLightFrame {
    // Wallpaper Engine 2.3 raised direct scene lighting to twelve. Shadow
    // atlases have a separate allocation budget in NativePointShadows.
    static let maximumLights = 12
    struct SpotCone {
        let directionOuterCosine: SIMD4<Float>
        let innerCosine: Float
    }
    static func spotCone(object: [String: Any], transform: simd_float4x4) -> SpotCone? {
        // REA Light::InitProps/constructor and Scene::UpdateLightingState:
        // 20/30 degree defaults, positive world X, with no axis normalization.
        let inner = SceneValues.number(object["innercone"], 20)
        let outer = SceneValues.number(object["outercone"], 30)
        guard inner.isFinite, outer.isFinite, inner >= 0, inner <= outer, outer <= 180 else { return nil }
        let axis = SIMD3(transform[0].x, transform[0].y, transform[0].z)
        let length = simd_length(SIMD3<Double>(Double(axis.x),Double(axis.y),Double(axis.z)))
        guard length.isFinite, length > 0, length <= Double(Float.greatestFiniteMagnitude) / 4 else { return nil }
        return SpotCone(directionOuterCosine: SIMD4(axis,cos(outer * .pi / 180)), innerCosine: cos(inner * .pi / 180))
    }
    struct Light {
        let positionRadius: SIMD4<Float>
        let colorExponent: SIMD4<Float>
        let shadowNear: Float?
        let volumetrics: SIMD2<Float>? // density, radial exponent; nil when disabled
        let spot: SpotCone?
        let spotShadow: NativeSpotShadows?
        let projection: NativeSpotProjection?
        var shadowRows: [SIMD4<Float>] { spotShadow?.rows ?? [.zero,.zero,.zero] }
        var projectionRows: [SIMD4<Float>] { projection?.rows ?? [.zero,.zero,.zero] }
        var spotDirection: SIMD4<Float> { spot?.directionOuterCosine ?? .zero }
        var spotParameters: SIMD4<Float> {
            if projection != nil { return SIMD4(0,1,1,0) }
            return spot.map { SIMD4($0.innerCosine,1,0,0) } ?? .zero
        }
        init(positionRadius: SIMD4<Float>, colorExponent: SIMD4<Float>, shadowNear: Float?, volumetrics: SIMD2<Float>?, spot: SpotCone? = nil, spotShadow: NativeSpotShadows? = nil, projection: NativeSpotProjection? = nil) {
            self.positionRadius = positionRadius; self.colorExponent = colorExponent
            self.shadowNear = shadowNear; self.volumetrics = volumetrics; self.spot = spot; self.spotShadow = spotShadow
            self.projection = projection
        }
    }
    var lights: [Light] = []
    var ambient = SIMD3<Float>(repeating: 0.2)
    var skylight = SIMD3<Float>(repeating: 0.2)
    var fogEnabled = false
    var fogColor = SIMD3<Float>.zero
    var fogParams = SIMD4<Float>(0, 1, 0, 0)
    var rejected = 0
}
