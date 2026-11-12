import Foundation
import simd

/// Cached inputs shared by every pass. Host input is ingested separately from
/// scene advancement, so expose/resize/hit queries cannot advance animation.
/// Shader pointer coordinates use bottom-left normalized screen coordinates;
/// SceneScript input retains its separate top-left pixel convention.
struct SceneFrameUniforms {
    private(set) var pointer = SIMD2<Float>(repeating: 0.5)
    private(set) var previousPointer = SIMD2<Float>(repeating: 0.5)
    private(set) var parallax = SIMD2<Float>(repeating: 0.5)
    private(set) var screen = SIMD2<Float>(1, 1)
    private(set) var canvas = SIMD2<Float>(1, 1)
    private(set) var amount: Float = 0
    private(set) var enabled = false
    private(set) var daytime: Float = 0
    private var pendingPointer = SIMD2<Float>(repeating: 0.5)
    private var filteredPosition = SIMD2<Float>(repeating: 0.5)
    private var sampledTime: Double?
    private var advanceCount: UInt64 = 0
    private var cachedRedrawCount: UInt64 = 0
    private var pausedRedrawCount: UInt64 = 0
    private var invalidClockCount: UInt64 = 0
    private var invalidInputCount: UInt64 = 0
    private var hostRate: Float = 0
    private var instantHostResponse = false

    /// The perspective branch in Scene::Update maps the normalized target to
    /// a signed domain before filtering. This affine read uses the same host
    /// adapter/clock; it does not apply amount or advance the state again.
    var signedParallax: SIMD2<Float> { (filteredPosition - SIMD2(repeating: 0.5)) * 2 }

    /// This adapter intentionally preserves the existing desktop sensitivity:
    /// a screen position in [0,1] maps to the half-range centered host signal.
    /// Android JNI supplies a different external signal; no Windows mapping is
    /// inferred from its name. Screen metadata may change during paused resize.
    private mutating func ingest(pointer input: SIMD2<Float>, screen size: SIMD2<Float>) {
        if input.x.isFinite && input.y.isFinite {
            pendingPointer = simd_clamp(input, .zero, SIMD2(repeating: 1))
        } else { invalidInputCount &+= 1 }
        if size.x.isFinite && size.y.isFinite { screen = simd_max(SIMD2(repeating: 1), size) }
    }

    mutating func update(pointer input: SIMD2<Float>, screen: SIMD2<Float>, canvas: SIMD2<Float>,
                         sceneTime: Double, paused: Bool, enabled: Bool,
                         amount: Float, delay: Float, influence: Float) {
        ingest(pointer: input, screen: screen)
        guard sceneTime.isFinite else { invalidClockCount &+= 1; return }
        let first = sampledTime == nil
        if !first {
            guard !paused else { cachedRedrawCount &+= 1; pausedRedrawCount &+= 1; return }
            guard let previousTime = sampledTime, sceneTime >= previousTime else {
                invalidClockCount &+= 1; return
            }
            guard sceneTime > previousTime else { cachedRedrawCount &+= 1; return }
        }
        let delta = sampledTime.map { Float(min(0.25, max(0, sceneTime - $0))) } ?? 0
        sampledTime = sceneTime
        previousPointer = first ? pendingPointer : pointer
        pointer = pendingPointer
        if canvas.x.isFinite && canvas.y.isFinite { self.canvas = simd_max(SIMD2(repeating: 1), canvas) }
        self.amount = amount.isFinite ? max(-10, min(10, amount)) : 0
        let sensitivity = influence.isFinite ? min(2 * max(-10, min(10, influence)), 2) : 0
        let boundedDelay = delay.isFinite ? max(0, min(60, delay)) : 0
        // Host policy, not a recovered Windows delay formula. The reference
        // uses an externally supplied rate (Android JNI param4 * 50), while the
        // desktop adapter keeps author delay as a response duration.
        instantHostResponse = boundedDelay <= 0.00001
        hostRate = instantHostResponse ? 0 : 1 / boundedDelay
        if !enabled || !self.enabled { filteredPosition = SIMD2(repeating: 0.5) }
        self.enabled = enabled
        if enabled && !first {
            let hostSignal = SIMD2<Float>(repeating: 0.5) - pointer
            let target = simd_clamp(hostSignal * sensitivity * -0.5 + SIMD2(repeating: 0.5),
                SIMD2(repeating: -0.5), SIMD2(repeating: 1.5))
            // Scene::Update: state += (target-state) * min(dt*rate, 1).
            // Even an instant response is applied only on a real scene step.
            let fraction: Float = instantHostResponse ? 1 : min(delta * hostRate, 1)
            filteredPosition += (target - filteredPosition) * fraction
        }
        parallax = simd_clamp(filteredPosition, .zero, SIMD2(repeating: 1))
        if !first { advanceCount &+= 1 }
        let components = Calendar.current.dateComponents([.hour, .minute, .second, .nanosecond], from: Date())
        let wholeSeconds = (components.hour ?? 0) * 3600 + (components.minute ?? 0) * 60 + (components.second ?? 0)
        let fractionalSeconds = Double(components.nanosecond ?? 0) / 1_000_000_000
        daytime = Float((Double(wholeSeconds) + fractionalSeconds) / 86400)
    }

    /// Scene::Draw walks to the highest parent, then translates the view by
    /// (root.origin - scene.focus) * root.parallaxDepth * amount. Applying the
    /// translation to each draw's view preserves V*T(offset)*M and keeps model
    /// uniforms in authored world space. This is the ordinary orthographic branch;
    /// Android fit-mode compensation and sensor overrides are not reproduced.
    func offset(origin: SIMD3<Float>, depth: SIMD2<Float>) -> SIMD3<Float> {
        guard enabled, amount != 0, origin.x.isFinite, origin.y.isFinite,
              depth.x.isFinite, depth.y.isFinite else { return .zero }
        let boundedDepth = simd_clamp(depth, SIMD2(repeating: -100), SIMD2(repeating: 100))
        let focus = SIMD2<Double>(filteredPosition) * SIMD2<Double>(canvas)
        let distance = SIMD2<Double>(Double(origin.x), Double(origin.y)) - focus
        let weightedDepth = SIMD2<Double>(boundedDepth) * SIMD2<Double>(repeating: Double(amount))
        let displacement = distance * weightedDepth
        let result = SIMD3<Float>(Float(displacement.x), Float(displacement.y), 0)
        return result.x.isFinite && result.y.isFinite ? result : .zero
    }

    func runtimeDiagnostic(paused: Bool) -> String {
        let time = sampledTime.map { String(format: "%.6f", $0) } ?? "未提交"
        let response = instantHostResponse ? "下一有效帧立即响应" : "host rate=\(hostRate)"
        return "视差输入快照：场景时间 \(time) 秒，暂停=\(paused)，启用=\(enabled)；推进 \(advanceCount) 次，缓存重绘 \(cachedRedrawCount) 次（暂停 \(pausedRedrawCount) 次），无效计时 \(invalidClockCount)，无效输入 \(invalidInputCount)；pointer=\(pointer)，previous=\(previousPointer)，parallax=\(parallax)，layerAmount=\(amount)，\(response)。鼠标及 delay 换算为原生兼容策略；未宣称 Windows 一致性。"
    }
}

/// Explicit coordinate transforms for author effects. Texture projection uses
/// normalized bottom-left layer coordinates and normalized scene clip space.
/// A clip-space intermediate quad has flipped Y relative to a layer quad,
/// because native offscreen textures retain the authored top-left image rows.
struct SceneEffectTransforms {
    let layerModel: simd_float4x4
    let sceneViewProjection: simd_float4x4
    let layerSize: SIMD2<Float>

    var textureProjection: simd_float4x4 {
        var textureToLocal = simd_float4x4(diagonal: SIMD4(layerSize.x, layerSize.y, 1, 1))
        textureToLocal.columns.3 = SIMD4(-layerSize.x / 2, -layerSize.y / 2, 0, 1)
        var clipToTexture = simd_float4x4(diagonal: SIMD4(0.5, 0.5, 1, 1))
        clipToTexture.columns.3 = SIMD4(0.5, 0.5, 0, 1)
        return clipToTexture * sceneViewProjection * layerModel * textureToLocal
    }

    func effectModel(layerGeometry: Bool) -> simd_float4x4 {
        if layerGeometry { return layerModel }
        return layerModel * simd_float4x4(diagonal: SIMD4(layerSize.x / 2, -layerSize.y / 2, 1, 1))
    }

    static func inverse(_ matrix: simd_float4x4) -> simd_float4x4? {
        let determinant = simd_determinant(matrix)
        guard determinant.isFinite, determinant != 0 else { return nil }
        let result = simd_inverse(matrix)
        let columns = [result.columns.0, result.columns.1, result.columns.2, result.columns.3]
        guard columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }) else { return nil }
        return result
    }
}
