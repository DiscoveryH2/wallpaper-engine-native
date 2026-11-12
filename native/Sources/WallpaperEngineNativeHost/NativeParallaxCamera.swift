import simd

/// Pure matrix composition; input smoothing belongs to SceneFrameUniforms.
/// REA Scene::Update3DParallax rotates the completed view around the eye,
/// first about authored up, then about cross(forward, up). Android sensor
/// roll and fit-mode overrides are separate branches and are not implied here.
enum NativeParallaxCamera {
    struct ShaderInputs {
        let eye: SIMD3<Float>
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        let forward: SIMD3<Float>
        static let identity = ShaderInputs(eye: .zero, right: SIMD3(1, 0, 0),
            up: SIMD3(0, 1, 0), forward: SIMD3(0, 0, -1))
    }

    /// Scene::Update stores eye independently of the view stack. Main::Run
    /// copies view rows only after Update3DParallax, before drawing any layer.
    /// The ordinary orthographic shader eye is canvas-centered with z=2000;
    /// it is not the inverse translation of the per-layer view matrix.
    static func shaderInputs(view: simd_float4x4, pose: NativeCameraPose,
                             shake: SIMD3<Float>, canvas: SIMD2<Float>?) -> ShaderInputs? {
        var eye = SIMD3<Double>(pose.eye) + SIMD3<Double>(shake)
        if let canvas {
            eye.x += Double(canvas.x) * 0.5
            eye.y += Double(canvas.y) * 0.5
            eye.z = 2000
        }
        let shaderEye = SIMD3<Float>(eye)
        guard shaderEye.x.isFinite, shaderEye.y.isFinite, shaderEye.z.isFinite,
              let right = normalized(SIMD3<Double>(Double(view[0].x), Double(view[1].x), Double(view[2].x))),
              let up = normalized(SIMD3<Double>(Double(view[0].y), Double(view[1].y), Double(view[2].y))),
              let forward = normalized(-SIMD3<Double>(Double(view[0].z), Double(view[1].z), Double(view[2].z))) else { return nil }
        return ShaderInputs(eye: shaderEye, right: SIMD3<Float>(right),
            up: SIMD3<Float>(up), forward: SIMD3<Float>(forward))
    }

    static func translated(_ view: simd_float4x4, by offset: SIMD3<Float>) -> simd_float4x4? {
        guard offset.x.isFinite, offset.y.isFinite, offset.z.isFinite else { return nil }
        if offset == .zero { return view }
        var translation = matrix_identity_float4x4
        translation.columns.3 = SIMD4(offset, 1)
        let result = view * translation
        return finite(result) ? result : nil
    }

    static func perspective(base: NativeCameraPose.Frame, pose: NativeCameraPose,
                            shake: SIMD3<Float>, focus: SIMD2<Float>) -> NativeCameraPose.Frame? {
        guard focus.x.isFinite, focus.y.isFinite,
              [pose.eye, pose.center, pose.up, shake].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        if focus == .zero { return base }
        let eye = SIMD3<Double>(pose.eye) + SIMD3<Double>(shake)
        guard let forward = normalized(SIMD3<Double>(pose.center) - SIMD3<Double>(pose.eye)),
              let up = normalized(SIMD3<Double>(pose.up)),
              let right = normalized(simd_cross(forward, up)) else { return nil }
        let yaw = simd_double4x4(simd_quatd(angle: Double(focus.x) * 0.25, axis: up))
        let pitch = simd_double4x4(simd_quatd(angle: Double(focus.y) * -0.25, axis: right))
        var toEye = matrix_identity_double4x4, fromEye = matrix_identity_double4x4
        toEye.columns.3 = SIMD4(eye, 1)
        fromEye.columns.3 = SIMD4(-eye, 1)
        // Column-vector convention: V * T(eye) * R(up) * R(right) * T(-eye).
        // Shake has already translated eye and center together in base.view.
        let baseDouble = simd_double4x4((0..<4).map { SIMD4<Double>(base.view[$0]) })
        let composed = baseDouble * toEye * yaw * pitch * fromEye
        let view = simd_float4x4((0..<4).map { SIMD4<Float>(composed[$0]) })
        guard finite(view), let cameraWorld = SceneEffectTransforms.inverse(view),
              let right = normalized(SIMD3<Double>(Double(cameraWorld.columns.0.x), Double(cameraWorld.columns.0.y), Double(cameraWorld.columns.0.z))),
              let up = normalized(SIMD3<Double>(Double(cameraWorld.columns.1.x), Double(cameraWorld.columns.1.y), Double(cameraWorld.columns.1.z))) else { return nil }
        return NativeCameraPose.Frame(view: view, right: SIMD3<Float>(right), up: SIMD3<Float>(up))
    }

    private static func normalized(_ value: SIMD3<Double>) -> SIMD3<Double>? {
        let length = simd_length(value)
        guard length.isFinite, length > 1e-12 else { return nil }
        return value / length
    }

    private static func finite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { matrix[column][$0].isFinite } }
    }
}
