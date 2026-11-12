import Foundation
import simd

/// Same direct-light and distance-fog contract as the native OpenGL material.
/// Point shadows are capped by the authored budget and the native atlas limit.
enum NativeMetalModelLighting {
    static func frame(objects: [[String: Any]], general: [String: Any], transforms: [simd_float4x4], visible: [Bool]) -> NativeModelLightFrame {
        var frame = NativeModelLightFrame()
        let config = general["lightconfig"] as? [String: Any]
        let limit = Int(max(0, min(Float(NativePointShadows.maximumLights), SceneValues.number(config?["pointshadow"], 0))))
        let spotLimit = Int(max(0,min(Float(NativeModelLightFrame.maximumLights),SceneValues.number(config?["spotshadow"],0))))
        var shadows = 0, spots = 0
        frame.ambient = SceneValues.vector(general["ambientcolor"], frame.ambient)
        frame.skylight = SceneValues.vector(general["skylightcolor"], frame.skylight)
        for index in objects.indices where visible[index] {
            let object = objects[index]
            guard let kind = object["light"] as? String else { continue }
            guard ["lpoint", "lspot", "ldirectional"].contains(kind), frame.lights.count < NativeModelLightFrame.maximumLights else { frame.rejected += 1; continue }
            let color = SceneValues.vector(object["color"], SIMD3(repeating: 1)) * max(0, SceneValues.number(object["intensity"], 1))
            let exponent = max(0, SceneValues.number(object["exponent"], 2)), matrix = transforms[index]
            let position: SIMD4<Float>
            if kind == "ldirectional" {
                let axis = -SIMD3<Double>(Double(matrix[0].x), Double(matrix[0].y), Double(matrix[0].z)), size = simd_length(axis)
                guard size.isFinite, size > 0 else { frame.rejected += 1; continue }
                position = SIMD4(SIMD3<Float>(axis / size),0)
            } else {
                let radius = SceneValues.number(object["radius"],5)
                guard radius > 0 else { frame.rejected += 1; continue }
                position = SIMD4(matrix[3].x,matrix[3].y,matrix[3].z,radius)
            }
            guard [color.x,color.y,color.z,position.x,position.y,position.z,position.w,exponent].allSatisfy(\.isFinite) else { frame.rejected += 1; continue }
            let spot = kind == "lspot" ? NativeModelLightFrame.spotCone(object: object, transform: matrix) : nil
            if kind == "lspot", spot == nil, !SceneValues.visible(object["usecookie"] ?? false) { frame.rejected += 1; continue }
            var projection: NativeSpotProjection?
            if SceneValues.visible(object["usecookie"] ?? false) {
                guard kind == "lspot", let value = NativeSpotProjection(outerDegrees:SceneValues.number(object["outercone"],30),
                    radius:position.w,transform:matrix) else { frame.rejected += 1; continue }
                projection = value
            }
            var near: Float?
            var spotShadow: NativeSpotShadows?
            if kind == "lspot", SceneValues.visible(object["castshadow"] ?? false), spots < spotLimit {
                if let value = NativeSpotShadows(object: object,transform: matrix) { spotShadow = value; near = NativeSpotShadows.near; spots += 1 }
                else { frame.rejected += 1 }
            }
            if kind == "lpoint", SceneValues.visible(object["castshadow"] ?? false), shadows < limit {
                let value = max(0.05, SceneValues.number(object["lightsourcesize"], 0.05))
                if value.isFinite { near = value; shadows += 1 } else { frame.rejected += 1 }
            }
            var volume: SIMD2<Float>?
            if kind == "lpoint", SceneValues.visible(object["castvolumetrics"] ?? false) {
                let density = max(0, SceneValues.number(object["density"], 2))
                let power = max(0, SceneValues.number(object["volumetricsexponent"], 1))
                if density.isFinite, power.isFinite { volume = SIMD2(density, power) } else { frame.rejected += 1 }
            }
            frame.lights.append(.init(positionRadius:position,colorExponent:SIMD4(color,exponent),shadowNear:near,volumetrics:volume,spot:spot,spotShadow:spotShadow,projection:projection))
        }
        if general["fogdistance"] as? Bool == true {
            let start = SceneValues.number(general["fogdistancestart"],0), end = SceneValues.number(general["fogdistanceend"],1)
            let first = SceneValues.number(general["fogdistancestartdensity"],0), last = SceneValues.number(general["fogdistanceenddensity"],1)
            let span = end-start, range = last-first
            if span.isFinite, span > 0, range.isFinite {
                frame.fogEnabled = true; frame.fogParams = SIMD4(start,span,first,range)
                frame.fogColor = SceneValues.vector(general["fogdistancecolor"],.zero)
            } else { frame.rejected += 1 }
        }
        return frame
    }
}
