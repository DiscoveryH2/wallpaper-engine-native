import Foundation
import simd

/// Camera data and state shared with the existing reference-backed primitives.
/// GPU passes consume one completed frame and never advance camera clocks.
struct NativeMetalSceneCamera {
    struct Settings {
        let parallax: Bool, shake: Bool, fade: Bool
        let amount: Float, delay: Float, influence: Float
        let speed: Float, amplitude: Float, roughness: Float
        init(general: [String: Any]) {
            parallax = general["cameraparallax"] as? Bool == true
            shake = general["camerashake"] as? Bool == true
            fade = general["camerafade"] as? Bool ?? true
            amount = SceneValues.number(general["cameraparallaxamount"], 0.5)
            delay = SceneValues.number(general["cameraparallaxdelay"], 0.1)
            influence = SceneValues.number(general["cameraparallaxmouseinfluence"], 0)
            speed = SceneValues.number(general["camerashakespeed"], 3)
            amplitude = SceneValues.number(general["camerashakeamplitude"], 0.5)
            roughness = SceneValues.number(general["camerashakeroughness"], 1)
        }
    }
    struct Layer {
        let origin: SIMD3<Float>
        let depth: SIMD2<Float>
        init(object: [String: Any]) {
            origin = SceneValues.vector(object["origin"], .zero)
            let values = SceneValues.floats(object["parallaxDepth"])
            depth = values.count >= 2 ? SIMD2(values[0], values[1]) : SIMD2(repeating: 1)
        }
    }
    struct Frame {
        let fade: NativeCameraFade
        let projection: simd_float4x4
        let view: simd_float4x4
        let offsets: [SIMD3<Float>]
        let textMargins: SIMD4<Float>
        let right: SIMD3<Float>, up: SIMD3<Float>
        let particleProjection: NativeOrthographicProjection.ParticleFrame?
    }
    let canvas: SIMD2<Float>
    let orthographic: Bool
    let perspective: NativePerspectiveProjection
    let perspectiveFOV: Float
    let settings: Settings
    let fadeTint: SIMD3<Float>
    let layers: [Layer]
    private(set) var hierarchy: SceneHierarchy
    let legacy: NativeLegacyCamera
    let legacySignature: Data

    init(width: Float, height: Float, general: [String: Any], camera: [String: Any],
         objects: [[String: Any]], hierarchy: SceneHierarchy, assets: SceneAssets, properties: [String: Any] = [:]) throws {
        fadeTint = NativeCameraFade.tint(properties: properties)
        orthographic = general["orthogonalprojection"] is [String: Any]
        perspective = NativePerspectiveProjection(fov: general["fov"], near: general["nearz"], far: general["farz"])
        perspectiveFOV = NativeOrthographicProjection(perspectiveFOV: general["perspectiveoverridefov"]).perspectiveFOVDegrees
        canvas = SIMD2(width, height); settings = Settings(general: general)
        layers = objects.map { Layer(object: $0) }; self.hierarchy = hierarchy
        var documents: [String: Any] = [:]
        legacy = NativeLegacyCamera(camera: camera, orthographic: orthographic, loadJSON: { path in
            let document = try assets.json(path)
            documents[path] = document
            return document
        })
        legacySignature = try JSONSerialization.data(withJSONObject: ["camera": camera, "documents": documents, "orthographic": orthographic], options: [.sortedKeys])
    }

    @MainActor
    final class Runtime {
        private var source: NativeMetalSceneCamera
        private var legacy: NativeLegacyCamera
        private var uniforms = SceneFrameUniforms()
        private var settings: Settings
        private var hasActiveCamera = false
        private(set) var diagnostics: [String] = []
        var usesPointerInput: Bool { settings.parallax }
        var needsFrameUpdates: Bool {
            (!hasActiveCamera && legacy.hasPaths) || settings.parallax || (settings.shake && settings.amplitude != 0 && settings.speed != 0)
        }
        init(_ source: NativeMetalSceneCamera) {
            self.source = source; legacy = source.legacy; settings = source.settings
        }
        func preserveState(from previous: Runtime) {
            uniforms = previous.uniforms
            if source.legacySignature == previous.source.legacySignature { legacy = previous.legacy }
        }

        func detachParents(hierarchy: SceneHierarchy) { source.hierarchy = hierarchy }

        func frame(time: Double, paused: Bool, pointer: SIMD2<Float>, output: SIMD2<Float>, zoom: Float,
                   animation: NativeMetalSceneAnimation.Frame?, scriptPose: NativeCameraPose? = nil) throws -> Frame {
            settings = animation?.camera ?? source.settings
            // Both shared state machines ignore repeated scene times. The
            // pointer adapter also freezes pending input while paused.
            hasActiveCamera = animation?.activeCamera != nil
            legacy.advance(to: time, enabled: !hasActiveCamera)
            let fade = NativeCameraFade(enabled: settings.fade, amount: legacy.fadeAmount, tint: source.fadeTint)
            uniforms.update(pointer: pointer, screen: output, canvas: source.orthographic ? source.canvas : output, sceneTime: time,
                paused: paused, enabled: settings.parallax, amount: settings.amount,
                delay: settings.delay, influence: settings.influence)
            var notes: [String] = ["Metal 相机来源：\(hasActiveCamera ? "Camera 对象" : legacy.hasPaths ? "旧版相机路径" : "静态相机")。"], shake = SIMD3<Float>.zero
            if settings.shake {
                if let value = NativeCameraShake.translation(time: time, speed: settings.speed,
                    amplitude: settings.amplitude, roughness: settings.roughness, orthogonalHeight: source.orthographic ? source.canvas.y : nil) {
                    shake = value
                } else { notes.append("Metal 相机晃动参数无法安全表示，本帧保留基础相机。") }
            }
            let pose = animation?.activeCamera?.pose ?? (legacy.hasPaths ? legacy.pose : (scriptPose ?? legacy.pose))
            let shaken = pose.frame(offset: shake)
            let camera = shaken ?? pose.frame() ?? .identity
            if shaken == nil { notes.append("Metal 晃动视图无效，本帧保留未晃动的姿态。") }
            guard output.x.isFinite, output.y.isFinite, output.x > 0, output.y > 0 else {
                throw SceneError.invalid("Metal 相机输出尺寸无效。")
            }
            let aspect = max(0.001, output.x / output.y)
            if !source.orthographic {
                let projection = animation?.perspective ?? source.perspective
                guard let matrix = projection.matrix(aspect: aspect) else {
                    throw SceneError.invalid("Metal 透视投影无法安全表示。")
                }
                let parallax = uniforms.enabled ? NativeParallaxCamera.perspective(base: camera, pose: pose,
                    shake: shaken == nil ? .zero : shake, focus: uniforms.signedParallax) : nil
                let final = parallax ?? camera
                notes += projection.diagnostics
                notes.append("Metal 三维相机：场景时间 \(String(format: "%.6f", time)) 秒，暂停=\(paused)，fov=\(projection.fovDegrees)°，nearz=\(projection.near)，farz=\(projection.far)，aspect=\(aspect)，投影缩放=(\(matrix.columns.0.x), \(matrix.columns.1.y))；zoom 不参与三维投影。")
                notes.append("Metal 三维视差：启用=\(uniforms.enabled)，旋转已应用=\(parallax != nil)，shake=\(shake)。逐层二维视差偏移不用于透视场景。")
                if uniforms.enabled && parallax == nil { notes.append("Metal 三维视差无法安全表示，保留基础相机。") }
                notes.append(uniforms.runtimeDiagnostic(paused: paused))
                if legacy.hasPaths { notes.append(legacy.runtimeDiagnostic) }
                diagnostics = notes + [fade.diagnostic]
                return Frame(fade: fade, projection: matrix, view: final.view,
                    offsets: [SIMD3<Float>](repeating: .zero, count: source.layers.count), textMargins: .zero,
                    right: final.right, up: final.up, particleProjection: nil)
            }
            let visibleHeight = min(source.canvas.y, source.canvas.x / aspect)
            let projection = NativeOrthographicProjection(zoom: zoom)
            guard let projected = projection.frame(visibleWidth: visibleHeight * aspect,
                                                    visibleHeight: visibleHeight, cameraZoom: pose.zoom) else {
                throw SceneError.invalid("Metal 相机投影无法安全表示。")
            }
            notes += projection.diagnostics
            if projected.usedFallback { notes.append("Metal 相机总缩放无效，本帧缩放回退为 1。") }
            var center = matrix_identity_float4x4
            center.columns.3 = SIMD4(-source.canvas.x / 2, -source.canvas.y / 2, 0, 1)
            let view = center * camera.view
            var offsets = [SIMD3<Float>](repeating: .zero, count: source.layers.count)
            for index in source.hierarchy.order where !source.hierarchy.invalid.contains(index) {
                if let parent = source.hierarchy.parents[index] { offsets[index] = offsets[parent] }
                else {
                    let layer = animation?.layers[index].camera ?? source.layers[index]
                    offsets[index] = uniforms.offset(origin: layer.origin, depth: layer.depth)
                }
            }
            notes.append("Metal 相机最近编码：场景时间 \(String(format: "%.6f", time)) 秒，暂停=\(paused)，输出 \(Int(output.x))×\(Int(output.y))，总缩放=\(projected.appliedZoom)，shake=\(shake)，speed=\(settings.speed)，amplitude=\(settings.amplitude)，roughness=\(settings.roughness)。")
            notes.append(uniforms.runtimeDiagnostic(paused: paused))
            if legacy.hasPaths { notes.append(legacy.runtimeDiagnostic) }
            for index in source.layers.indices.prefix(12) {
                notes.append("Metal 图层 \(index + 1) 相机偏移=\(offsets[index])，父索引=\(source.hierarchy.parents[index].map(String.init) ?? "无")。")
            }
            diagnostics = notes + [fade.diagnostic]
            return Frame(fade: fade, projection: projected.matrix, view: view, offsets: offsets,
                textMargins: NativeTextAnchor.margins(canvas: source.canvas, aspect: aspect), right: camera.right, up: camera.up,
                particleProjection: NativeOrthographicProjection(perspectiveFOV: source.perspectiveFOV).particles(baseProjection: projected.matrix, aspect: aspect))
        }
    }
}
