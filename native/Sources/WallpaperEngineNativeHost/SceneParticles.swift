import Foundation
import simd

/// Computes a particle's unrotated sprite plane in the coordinate system in
/// which its vertices will be submitted. Renderer worldspace is independent
/// of the particle system's separate world-space *position* flag.
enum NativeParticleOrientation {
    enum Mode: String { case screen, upright, fixed }
    struct Frame { let right: SIMD3<Float>, up: SIMD3<Float> }

    static func frame(mode: Mode, axis: SIMD3<Float>, independent: Bool,
                      systemModel: simd_float4x4, geometryModel: simd_float4x4,
                      cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>) -> Frame? {
        func direction(_ matrix: simd_float4x4, _ vector: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3<Double>(Double(matrix.columns.0.x), Double(matrix.columns.0.y), Double(matrix.columns.0.z)) * vector.x
                + SIMD3<Double>(Double(matrix.columns.1.x), Double(matrix.columns.1.y), Double(matrix.columns.1.z)) * vector.y
                + SIMD3<Double>(Double(matrix.columns.2.x), Double(matrix.columns.2.y), Double(matrix.columns.2.z)) * vector.z
        }
        func unit(_ value: SIMD3<Double>) -> SIMD3<Double>? {
            let length = simd_length(value)
            guard length.isFinite, length > 1e-12 else { return nil }
            return value / length
        }
        guard let cameraR = unit(SIMD3<Double>(cameraRight)), let cameraU = unit(SIMD3<Double>(cameraUp)),
              let cameraNormal = unit(simd_cross(cameraR, cameraU)),
              let authoredAxis = unit(SIMD3<Double>(axis)) else { return nil }
        let worldRight: SIMD3<Double>, worldUp: SIMD3<Double>
        switch mode {
        case .screen:
            let referenceUp = independent ? cameraU : direction(systemModel, SIMD3(0, 1, 0))
            // Looking straight along the reference up has no unique roll.
            // Use camera up only for that degenerate configuration.
            guard let up = unit(referenceUp - cameraNormal * simd_dot(referenceUp, cameraNormal))
                    ?? unit(cameraU - cameraNormal * simd_dot(cameraU, cameraNormal)),
                  let right = unit(simd_cross(up, cameraNormal)) else { return nil }
            worldRight = right; worldUp = up
        case .upright:
            // REA FUN_02697320: the independent branch chooses world Y;
            // only the system-relative branch transforms the authored axis.
            let referenceUp = independent ? SIMD3<Double>(0, 1, 0) : direction(systemModel, authoredAxis)
            guard let up = unit(referenceUp) else { return nil }
            // The view-normal projection vanishes when the camera looks along
            // the upright axis. A projected camera-right gives a stable basis.
            guard let right = unit(simd_cross(up, cameraNormal))
                    ?? unit(cameraR - up * simd_dot(cameraR, up)) else { return nil }
            worldRight = right; worldUp = up
        case .fixed:
            // RendererBase parses fixed axis Y with a stored up of -Z. For
            // every nonzero X/Z component it constructs the tangent from Y;
            // a coarse near-parallel threshold changes texture orientation.
            let horizontal = SIMD3<Double>(authoredAxis.z, 0, -authoredAxis.x)
            let horizontalLength = simd_length(horizontal)
            let right: SIMD3<Double>, up: SIMD3<Double>
            if horizontalLength == 0 {
                up = SIMD3(0, 0, -1)
                guard let resolved = unit(simd_cross(up, authoredAxis)) else { return nil }
                right = resolved
            } else {
                guard horizontalLength.isFinite else { return nil }
                right = horizontal / horizontalLength
                guard let resolved = unit(simd_cross(authoredAxis, right)) else { return nil }
                up = resolved
            }
            worldRight = independent ? right : direction(systemModel, right)
            worldUp = independent ? up : direction(systemModel, up)
        }
        guard let right = localDirection(worldRight, through: geometryModel),
              let up = localDirection(worldUp, through: geometryModel) else { return nil }
        return Frame(right: right, up: up)
    }

    /// Invert the linear draw transform. A common 2D transform has zero Z
    /// scale; solve in its surviving plane when the requested vector lies in
    /// that plane. Other singular cases retain the old fallback and report it.
    private static func localDirection(_ world: SIMD3<Double>, through model: simd_float4x4) -> SIMD3<Float>? {
        let cols = (0..<3).map { i in
            SIMD3<Double>(Double(model[i].x), Double(model[i].y), Double(model[i].z))
        }
        guard cols.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
              world.x.isFinite, world.y.isFinite, world.z.isFinite else { return nil }
        let matrix = simd_double3x3(columns: (cols[0], cols[1], cols[2]))
        let maxLength = cols.map(simd_length).max() ?? 0
        let determinant = simd_determinant(matrix)
        var local: SIMD3<Double>
        if maxLength > 0, determinant.isFinite, abs(determinant) > 1e-12 * maxLength * maxLength * maxLength {
            local = simd_inverse(matrix) * world
        } else {
            let pairs = [(0, 1), (0, 2), (1, 2)]
            guard let pair = pairs.max(by: { simd_length_squared(simd_cross(cols[$0.0], cols[$0.1]))
                < simd_length_squared(simd_cross(cols[$1.0], cols[$1.1])) }) else { return nil }
            let a = cols[pair.0], b = cols[pair.1]
            let aa = simd_dot(a, a), ab = simd_dot(a, b), bb = simd_dot(b, b)
            let denominator = aa * bb - ab * ab
            guard denominator.isFinite, denominator > 1e-24 * max(1, aa * bb) else { return nil }
            let aw = simd_dot(a, world), bw = simd_dot(b, world)
            local = .zero
            local[pair.0] = (aw * bb - bw * ab) / denominator
            local[pair.1] = (bw * aa - aw * ab) / denominator
            let reconstructed = matrix * local
            guard simd_length(reconstructed - world) <= 1e-7 * max(1, simd_length(world)) else { return nil }
        }
        let magnitude = simd_length(local)
        guard magnitude.isFinite, magnitude > 1e-12 else { return nil }
        let result = SIMD3<Float>(local / magnitude)
        return result.x.isFinite && result.y.isFinite && result.z.isFinite ? result : nil
    }
}

/// A deliberately small, CPU-side subset of Wallpaper Engine particle documents.
///
/// Local systems return layer coordinates; bit-0 systems retain world positions
/// from birth and return world geometry. The renderer applies parallax separately.
final class SceneParticles {
    enum Error: LocalizedError {
        case malformed(String)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .malformed(let message), .unsupported(let message): return message
            }
        }
    }

    /// The relative material path declared by the particle document. Resolving and
    /// rendering that material is deliberately outside the particle simulator.
    let materialPath: String

    /// Compatibility decisions made while parsing. Warnings are intentionally kept
    /// alongside the instance so a renderer can expose them in its compatibility UI.
    private(set) var warnings: [String]

    static let liveInstanceKeys = ["count", "size", "alpha", "colorn", "rate"]
    struct LiveOverrides {
        let count: Float
        let size: Float
        let alpha: Float
        let color: SIMD3<Float>
        var rate: Float

        init(_ instance: [String: Any]) throws {
            count = try SceneParticles.instanceFactor(instance, name: "count")
            size = try SceneParticles.instanceFactor(instance, name: "size")
            alpha = try SceneParticles.instanceFactor(instance, name: "alpha", maximum: 16)
            rate = try SceneParticles.instanceFactor(instance, name: "rate")
            color = try SceneParticles.vector(instance["colorn"], named: "instance.colorn", default: SIMD3(repeating: 1))
            guard simd_reduce_min(color) >= 0, simd_reduce_max(color) <= 16 else {
                throw Error.unsupported("Native instance.colorn components must be in 0...16.")
            }
        }
    }

    private static let hardParticleLimit = 10_000
    private static let maximumEmitterCount = 16
    private struct ScalarRange {
        let lower: Float
        let upper: Float
        let exponent: Float

        init(_ first: Float, _ second: Float, exponent: Float = 1) {
            lower = Swift.min(first, second)
            upper = Swift.max(first, second)
            self.exponent = exponent
        }

        func sample(_ random: inout DeterministicRandom) -> Float {
            lower + (upper - lower) * powf(random.unitFloat(), exponent)
        }
    }

    private struct VectorRange {
        let lower: SIMD3<Float>
        let upper: SIMD3<Float>
        let exponent: Float

        init(_ first: SIMD3<Float>, _ second: SIMD3<Float>, exponent: Float = 1) {
            lower = simd_min(first, second)
            upper = simd_max(first, second)
            self.exponent = exponent
        }

        func sample(_ random: inout DeterministicRandom) -> SIMD3<Float> {
            let unit = SIMD3<Float>(powf(random.unitFloat(), exponent), powf(random.unitFloat(), exponent), powf(random.unitFloat(), exponent))
            return lower + (upper - lower) * unit
        }
    }

    private enum AngularRange {
        case planar(ScalarRange)
        case spatial(VectorRange)

        func sample(_ random: inout DeterministicRandom) -> SIMD3<Float> {
            switch self {
            case .planar(let range): return SIMD3(0, 0, range.sample(&random))
            case .spatial(let range): return range.sample(&random)
            }
        }
    }

    private struct AngularMovement {
        let force: SIMD3<Float>
        let drag: Float
    }

    private struct LifetimeChange {
        enum Target { case size, alpha, color }
        let target: Target
        let start: SIMD3<Float>
        let end: SIMD3<Float>
        let startTime: Float
        let endTime: Float

        func value(at progress: Float) -> SIMD3<Float> {
            let fraction: Float = endTime > startTime
                ? max(0, min(1, (progress - startTime) / (endTime - startTime)))
                : (progress >= startTime ? 1 : 0)
            return start + (end - start) * fraction
        }
    }

    private enum Renderer {
        case sprite(orientation: NativeParticleOrientation.Mode, axis: SIMD3<Float>, independent: Bool)
        case spriteTrail(length: Float, minimum: Float, maximum: Float)
        case ropeTrail(length: Float, segments: Int, subdivision: Int, uvScale: Float, fadeAlpha: Bool, fadeSize: Bool)
    }

    private struct ColorRange {
        let lower: SIMD4<Float>
        let upper: SIMD4<Float>
        let exponent: Float

        init(_ first: SIMD4<Float>, _ second: SIMD4<Float>, exponent: Float = 1) {
            lower = simd_min(first, second)
            upper = simd_max(first, second)
            self.exponent = exponent
        }

        func sample(_ random: inout DeterministicRandom) -> SIMD4<Float> {
            let unit = SIMD4<Float>(powf(random.unitFloat(), exponent), powf(random.unitFloat(), exponent), powf(random.unitFloat(), exponent), powf(random.unitFloat(), exponent))
            return lower + (upper - lower) * unit
        }
    }

    private enum EmitterShape {
        case boxRandom(directions: SIMD3<Float>, minimum: SIMD3<Float>, maximum: SIMD3<Float>)
        case sphereRandom(directions: SIMD3<Float>, minimum: Float, span: Float, axialMinimum: Float, signs: SIMD3<Float>)
    }

    private struct Emitter {
        let origin: SIMD3<Float>
        let shape: EmitterShape
        let rate: Double
        let instantaneous: Int
        let delay: Double
        let duration: Double
    }

    struct Spawn: Comparable, Hashable {
        let birthTime: Double
        let emitterIndex: Int
        let emissionIndex: Int

        static func < (left: Spawn, right: Spawn) -> Bool {
            if left.birthTime != right.birthTime { return left.birthTime < right.birthTime }
            if left.emitterIndex != right.emitterIndex { return left.emitterIndex < right.emitterIndex }
            return left.emissionIndex < right.emissionIndex
        }
    }

    struct EventParticle {
        let id: Spawn
        let age: Double
        let position: SIMD3<Float>
    }
    struct BirthEvent {
        let id: Spawn
        let position: SIMD3<Float>
        let lifetime: Double
        let deathTime: Double
        let makeTrajectory: (() -> EventTrajectory)?
    }
    enum TrajectorySample {
        case ready(SIMD3<Float>)
        case pending(Double)
        case failed(String)
    }
    /// Each admitted follower owns its integrator copy. A weak factory in the
    /// journal avoids retaining the parent through its own event records.
    final class EventTrajectory {
        fileprivate let evaluate: (Double, FrameBudget) -> TrajectorySample
        fileprivate init(_ evaluate: @escaping (Double, FrameBudget) -> TrajectorySample) {
            self.evaluate = evaluate
        }
        func sample(at age: Double, workBudget: FrameBudget) -> TrajectorySample {
            evaluate(age, workBudget)
        }
    }
    final class FrameBudget {
        var remainingSchedulerOperations: Int
        init(operations: Int = 20_000) { remainingSchedulerOperations = operations }
    }
    enum BirthPlacement {
        case ready(simd_float4x4)
        case pending(Double)
        case failed(String)
    }
    var usesWorldSpace: Bool { flags & 1 != 0 }
    var tracksEmitterTransforms: Bool { transformHistory != nil }
    var hasPrewarm: Bool { startTime > 0 }
    private var transformHistory: SceneParticleTransformHistory?
    private var birthPlacement: ((Spawn, FrameBudget) -> BirthPlacement)?
    private var pendingEmission: (spawn: Spawn, particle: Particle)?
    private(set) var spaceFailure: String?
    private(set) var worldBirths = 0
    private(set) var placementBacklog = 0.0
    private(set) var placementWork = 0

    // The renderer reserves at most 64 root histories per scene. Cloned child
    // pools share their parent's history through a weak provider, never a ring.
    func enableEmitterTransformHistory() {
        if transformHistory == nil { transformHistory = SceneParticleTransformHistory() }
    }
    func authoredTransform(at simulationTime: Double) -> SceneParticleTransformHistory.Lookup {
        transformHistory?.transform(at: simulationTime) ?? .failed("Emitter transform history was not reserved.")
    }
    func configureBirthPlacement(_ provider: @escaping (Spawn, FrameBudget) -> BirthPlacement) {
        precondition(previousRequest == nil && usesWorldSpace)
        birthPlacement = provider
    }
    // A child draw consumes the preceding parent draw's immutable frame snapshot.
    // Children never advance or mutate their parent's pool.
    var capturesEvents = false
    private(set) var eventParticles: [EventParticle] = []
    private(set) var eventGeneration: UInt64 = 0
    private(set) var eventSceneTime = -Double.infinity
    private(set) var eventSimulationTime = -Double.infinity
    private(set) var eventRequestedSimulationTime = -Double.infinity
    private(set) var schedulingBacklog = 0.0
    private(set) var childWorkBudget = FrameBudget()
    var maximumParticles: Int { particleLimit }
    var supportsFollowingChild: Bool {
        forces.isEmpty && turbulence.isEmpty && { if case .sprite = renderer { return true }; return false }()
    }
    // Frame interpolation and the orthographic-scene perspective override do
    // not change the local-space parent/child transform or pool lifecycle.
    var acceptsLocalStaticChildren: Bool { flags & ~6 == 0 }
    var usesPerspectiveProjection: Bool { flags & 4 != 0 }
    var currentAlive: Int { live.count }
    var eventAcceptedBirths: Int { acceptedBirths }
    var eventLastDeathTime: Double? { lastParticleDeathTime }
    var eventStopAge: Double? { eventEmissionCutoff }
    var eventRenderSamples: [[String: Any]] { latestObservation["samples"] as? [[String: Any]] ?? [] }
    private static let birthJournalCapacity = 8192
    private var birthJournal: [BirthEvent] = []
    private var birthJournalBase = 0
    private var birthConsumers: [Int] = []
    private var journalBlocked = false
    private var childReservations = 0
    private var childMinimumWorkReservations = 0
    private var capturesFollowTrajectories = false
    var minimumTrajectoryWork: Int { max(1, turbulence.count * 2) + 3 }

    func reserveChildWork(particles: Int, minimumWork: Int) {
        childReservations += particles; childMinimumWorkReservations += minimumWork
    }
    func childWorkQuota(particles: Int, minimumWork: Int) -> Int {
        guard childReservations > 0 else { return 0 }
        // Every declaration can afford one indivisible trajectory step even
        // with a small particle reservation. The rest remains proportional.
        return minimumWork + max(0, 20_000 - childMinimumWorkReservations) * particles / childReservations
    }

    // Only admitted draw groups register: a failed material must never leave an
    // unconsumed cursor that would stall its parent forever.
    func registerBirthConsumer(followsTrajectory: Bool = false) -> Int {
        capturesFollowTrajectories = capturesFollowTrajectories || followsTrajectory
        birthConsumers.append(birthJournalBase + birthJournal.count)
        return birthConsumers.count - 1
    }

    func pendingBirths(for consumer: Int) -> ArraySlice<BirthEvent> {
        guard birthConsumers.indices.contains(consumer) else { return [] }
        return birthJournal[(birthConsumers[consumer] - birthJournalBase)...]
    }

    func consumeBirths(_ count: Int, for consumer: Int) {
        guard birthConsumers.indices.contains(consumer), count >= 0,
              count <= birthJournalBase + birthJournal.count - birthConsumers[consumer] else { return }
        birthConsumers[consumer] += count
    }

    /// Direct event children have no force fields or nested events. Their pool
    /// can be advanced without producing geometry, so capacity is decided at
    /// each parent event rather than at the next rendered frame.
    func advanceEventPool(at time: Double, workBudget: FrameBudget) -> Bool {
        guard time.isFinite else { return false }
        let requested = max(0, time) * Double(instanceTimeMultiplier)
        guard requested.isFinite else { return false }
        let reached = advancePool(to: requested, sharedBudget: workBudget)
        schedulingBacklog = max(0, requested - reached)
        // Several emissions may share the same time. A frontier equal to the
        // request alone does not prove that a budget-limited burst is complete.
        let hasDueEmission = emitters.indices.contains { index in
            emissionTime(index: nextEmission[index], emitterIndex: index).map { $0 <= requested } ?? false
        }
        return reached >= requested && !hasDueEmission
    }

    /// Call only after a pool advance has reached its requested time. Waiting
    /// emitters are active even when they currently have no live particles.
    var eventPoolIsActive: Bool {
        !live.isEmpty || emitters.indices.contains { emissionTime(index: nextEmission[$0], emitterIndex: $0) != nil }
    }

    /// A clone's fixed stop time uses its own simulation clock. Prewarm births
    /// are negative; the parent's lifetime is measured from child age zero.
    /// This configuration survives the first advancePool reset.
    func configureEventStop(at age: Double) -> Bool {
        guard previousRequest == nil, age.isFinite, age >= 0 else { return false }
        let cutoff = age * Double(instanceTimeMultiplier)
        guard cutoff.isFinite else { return false }
        eventEmissionCutoff = cutoff
        return true
    }

    private struct Particle {
        let birthTime: Double
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        let lifetime: Float
        let size: Float
        let color: SIMD4<Float>
        let rotation: SIMD3<Float>
        let angularVelocity: SIMD3<Float>
        let oscillations: [SampledOscillation]
        let turbulence: [SampledTurbulence]
        var integratedPosition: SIMD3<Float>
        var integratedVelocity: SIMD3<Float>
        var integratedSteps: Int = 0
    }

    private struct Death {
        let time: Double
        let spawn: Spawn
    }

    private struct ControlPointForce {
        let point: SIMD3<Float>
        let followsPointer: Bool
        let strength: Float
        let distance: Float
    }

    private struct Turbulence {
        let scale: Float
        let timeScale: Float
        let mask: SIMD3<Float>
        let speed: ScalarRange
        let phase: ScalarRange

        func sample(_ random: inout DeterministicRandom) -> SampledTurbulence {
            SampledTurbulence(speed: speed.sample(&random),
                phase: SIMD3(phase.sample(&random), phase.sample(&random), phase.sample(&random)))
        }
    }

    /// Initial velocity uses a one-dimensional noise angle, not the continuous
    /// vector field used by the turbulence operator. Contributions are additive.
    private struct TurbulentVelocity {
        let scale: Float
        let timeScale: Float
        let offset: Float
        let speed: ScalarRange
        let phase: ScalarRange
        let forward: SIMD3<Float>
        let normal: SIMD3<Float>

        func sample(at birthTime: Double, random: inout DeterministicRandom) -> SIMD3<Float> {
            let noiseCoordinate = (max(0, birthTime) + Double(phase.sample(&random))) * Double(timeScale)
            let angle = NativeParticleVelocityNoise.sample(noiseCoordinate) * Float.pi * scale + offset
            let rotation = simd_quatf(angle: angle, axis: normal)
            return rotation.act(forward) * speed.sample(&random)
        }
    }

    private struct SampledTurbulence {
        let speed: Float
        let phase: SIMD3<Float>
    }

    private enum OscillationTarget { case position, alpha, size }

    private struct Oscillation {
        let target: OscillationTarget
        let frequency: ScalarRange
        let scale: ScalarRange
        let phase: ScalarRange
        let mask: SIMD3<Float>

        func sample(_ random: inout DeterministicRandom) -> SampledOscillation {
            SampledOscillation(target: target,
                frequency: SIMD3(frequency.sample(&random), frequency.sample(&random), frequency.sample(&random)),
                amplitude: SIMD3(scale.sample(&random), scale.sample(&random), scale.sample(&random)),
                phase: SIMD3(phase.sample(&random), phase.sample(&random), phase.sample(&random)),
                mask: mask, alphaRange: scale)
        }
    }

    private struct SampledOscillation {
        let target: OscillationTarget
        let frequency: SIMD3<Float>
        let amplitude: SIMD3<Float>
        let phase: SIMD3<Float>
        let mask: SIMD3<Float>
        let alphaRange: ScalarRange

        func wave(progress: Float) -> SIMD3<Float> {
            let angle = frequency * (2 * Float.pi * progress) + phase
            return SIMD3(sinf(angle.x), sinf(angle.y), sinf(angle.z))
        }

        func velocity(progress: Float, lifetime: Float) -> SIMD3<Float> {
            let angle = frequency * (2 * Float.pi * progress) + phase
            return SIMD3(cosf(angle.x), cosf(angle.y), cosf(angle.z)) * frequency * (2 * Float.pi / lifetime) * amplitude * mask
        }
    }

    /// A stable, implementation-owned random stream. Swift's standard random APIs
    /// intentionally vary per process, so they cannot be used for repeatable playback.
    private struct DeterministicRandom {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func unitFloat() -> Float {
            // Keep 24 random bits, matching Float's significand precision.
            Float(next() >> 40) / Float(1 << 24)
        }
    }

    private let emitters: [Emitter]
    private let lifetime: ScalarRange
    private let size: ScalarRange
    private let velocity: VectorRange
    private let turbulentVelocities: [TurbulentVelocity]
    let usesOrthographicDefaults: Bool
    private let color: ColorRange
    private let initialAlpha: ScalarRange?
    private let rotations: [AngularRange]
    private let angularVelocities: [AngularRange]
    private let angularMovement: AngularMovement?
    private let lifetimeChanges: [LifetimeChange]
    private let renderer: Renderer
    private let gravity: SIMD3<Float>
    private let drag: Float
    private let oscillations: [Oscillation]
    private let hasMovement: Bool
    private let fadeInFraction: Float?
    private let fadeOutStartFraction: Float?
    private let startTime: Double
    private let particleLimit: Int
    private var instanceSizeMultiplier: Float
    private let instanceSpeedMultiplier: Float
    private var instanceTimeMultiplier: Float
    // An anchor changes only when the rate changes, keeping the constant-rate
    // path identical to sceneTime * rate and avoiding accumulated frame drift.
    private var rateAnchorSceneTime = 0.0
    private var rateAnchorSimulationTime = 0.0
    private var lastRateSceneTime: Double?
    private var lastRateSimulationTime = 0.0
    private let rateHistory = SceneParticleRateHistory()
    private var pointerNeedsPiecewiseClock = false
    private var instanceAlphaMultiplier: Float
    private var instanceColor: SIMD3<Float>
    private var instanceCountMultiplier: Float
    private var requestedCountMultiplier: Float
    private var emissionClocks: [NativeParticleEmissionClock] = []
    private var countChanges: [(time: Double, count: Float)] = []
    private var committedCountChanges = 0
    private var lastCountChangeTime: Double?
    private let seed: UInt64
    private let forces: [ControlPointForce]
    private let turbulence: [Turbulence]
    private enum AnimationMode: String { case sequence, randomFrame = "randomframe" }
    private let sequenceMultiplier: Double
    private let animationMode: AnimationMode
    private let blendsSequenceFrames: Bool
    private let flags: Int
    private var textureAnimation: SceneTextureAnimation?
    private var atlasWidth = 1, atlasHeight = 1
    private var imageWidth = 1, imageHeight = 1
    private var spriteAspectRatio: Float = 1
    private var live: [Spawn: Particle] = [:]
    // Birth events are already ordered by the scheduler. Retain that order
    // instead of sorting thousands of dictionary keys on every display frame.
    private var birthOrder: [Spawn] = []
    private let retainsBirthOrder: Bool
    private var deaths: [Death] = []
    private var nextEmission: [Int] = []
    private var previousRequest: Double?
    private var scheduledThrough = 0.0
    private var acceptedBirths = 0
    private var rejectedBirths = 0
    private var eventEmissionCutoff: Double?
    private var lastParticleDeathTime: Double?
    private var nextReportTime = 0.0
    private var latestObservation: [String: Any] = [:]
    var pointerSnapshot: [String: Any] {
        latestObservation.filter { $0.key.hasPrefix("pointer") || ["sceneTime", "simulationTime"].contains($0.key) }
    }
    var pointerDiagnostic: String {
        let position = latestObservation["pointerLocalPosition"] as? [Float] ?? []
        return "粒子鼠标力场：输入=\(latestObservation["pointerInputReason"] as? String ?? "not-yet-observed")，模拟坐标=\(position)，本帧作用=\(latestObservation["pointerForceApplications"] as? Int ?? 0)，历史样本=\(latestObservation["pointerHistorySamples"] as? Int ?? 0)，过期查询=\(latestObservation["pointerStaleQueries"] as? Int ?? 0)，缺失查询=\(latestObservation["pointerLostHistoryQueries"] as? Int ?? 0)，速度时钟段=\(latestObservation["pointerRateHistorySegments"] as? Int ?? 0)，淘汰=\(latestObservation["pointerRateHistoryDiscardedSegments"] as? Int ?? 0)。沿用原生有界模拟，未证明 Windows 物理一致性。"
    }
    private var simulationFrames = 0
    private var simulationSeconds = 0.0
    private var maximumSimulationSeconds = 0.0
    private var frameDirectionSamples = 0
    private var frameResidualSteps = 0
    private let pointerHistory = SceneParticlePointerHistory()
    private var pointerInput = SceneParticlePointerInput(position: nil, reason: "not-yet-observed")
    private var framePointerApplications = 0
    private var framePointerMaximumAcceleration: Float = 0
    private var frameStrongestPointerSample: [String: Any] = [:]
    private var previousPointerReportPosition: SIMD3<Float>?
    private var previousPointerReportActive = false
    private var lastPointerReportTime = -Double.infinity
    private var pointerReportCount = 0
    private var firstPointerForceReported = false

    var hasPointerForces: Bool { forces.contains { $0.followsPointer } }

    init(document: [String: Any], instance: [String: Any], orthographic: Bool, seedSalt: UInt64 = 0,
         inputTimeAlreadyScaled: Bool = false) throws {
        retainsBirthOrder = true
        usesOrthographicDefaults = orthographic
        var parseWarnings: [String] = []

        guard let path = document["material"] as? String, !path.isEmpty else {
            throw Error.malformed("Particle document must contain a non-empty material path.")
        }
        materialPath = path

        let declaredMaximum = try Self.requiredWholeNumber(document["maxcount"], named: "maxcount")
        guard declaredMaximum > 0 else {
            throw Error.malformed("Particle maxcount must be greater than zero.")
        }
        particleLimit = Swift.min(declaredMaximum, Self.hardParticleLimit)
        if declaredMaximum > Self.hardParticleLimit {
            parseWarnings.append("Particle maxcount \(declaredMaximum) is capped at \(Self.hardParticleLimit) to keep CPU simulation bounded.")
        }

        let parsedStartTime = try Self.number(document["starttime"], named: "starttime", default: 0)
        guard parsedStartTime >= 0, parsedStartTime <= 3600 else {
            throw Error.malformed("Particle starttime must be in 0...3600 seconds.")
        }
        startTime = Double(parsedStartTime)
        if parsedStartTime > 0 {
            parseWarnings.append("starttime pre-emits the native particle pool before scene time zero; catch-up is bounded and reports any backlog.")
        }

        let countMultiplier = try Self.instanceFactor(instance, name: "count")
        instanceCountMultiplier = countMultiplier; requestedCountMultiplier = countMultiplier
        emitters = try Self.parseEmitters(document["emitter"], orthographic: orthographic, warnings: &parseWarnings)
        guard emitters.count <= Self.maximumEmitterCount else {
            throw Error.unsupported("Particle document has \(emitters.count) supported emitters; the native CPU renderer accepts at most \(Self.maximumEmitterCount).")
        }

        let initializerValues = try Self.parseInitializers(document["initializer"], orthographic: orthographic, warnings: &parseWarnings)
        let lifetimeMultiplier = try Self.instanceFactor(instance, name: "lifetime", allowZero: false)
        lifetime = ScalarRange(initializerValues.lifetime.lower * lifetimeMultiplier, initializerValues.lifetime.upper * lifetimeMultiplier, exponent: initializerValues.lifetime.exponent)
        size = initializerValues.size
        velocity = initializerValues.velocity
        turbulentVelocities = initializerValues.turbulentVelocities
        color = initializerValues.color
        initialAlpha = initializerValues.alpha
        rotations = initializerValues.rotations
        angularVelocities = initializerValues.angularVelocities

        guard lifetime.lower > 0, lifetime.upper.isFinite, lifetime.upper <= 3600 else {
            throw Error.malformed("Native particle lifetime must be positive and at most 3600 seconds after the instance multiplier.")
        }
        guard size.lower >= 0 else {
            throw Error.malformed("sizerandom must not produce a negative sprite size.")
        }
        let operatorValues = try Self.parseOperators(document["operator"], warnings: &parseWarnings)
        forces = try Self.parseControlPointForces(document: document, instance: instance, orthographic: orthographic, warnings: &parseWarnings)
        turbulence = try Self.parseTurbulence(document["operator"], warnings: &parseWarnings)
        gravity = operatorValues.gravity
        drag = operatorValues.drag
        oscillations = operatorValues.oscillations
        hasMovement = operatorValues.hasMovement
        angularMovement = operatorValues.angularMovement
        lifetimeChanges = operatorValues.changes
        fadeInFraction = operatorValues.fadeInFraction
        fadeOutStartFraction = operatorValues.fadeOutStartFraction

        if operatorValues.hasMovement {
            parseWarnings.append("movement uses analytic gravity/drag without fields, or fixed-step midpoint integration with control-point forces/turbulence. Exact units, force falloff and integration order remain unverified against Windows.")
        }
        if !hasMovement, !turbulence.isEmpty { parseWarnings.append("turbulence has no movement operator; it does not move particles.") }

        renderer = try Self.parseRenderer(document["renderer"], warnings: &parseWarnings)
        if case .ropeTrail(_, let segments, let subdivision, _, _, _) = renderer {
            guard forces.isEmpty, turbulence.isEmpty else {
                throw Error.unsupported("Rope trails with force fields need a bounded historical integrator; this combination is not rendered yet.")
            }
            guard particleLimit * segments * subdivision <= 65_536 else {
                throw Error.unsupported("Rope trail particle/segment product exceeds the 65536-quad budget.")
            }
        }

        instanceSizeMultiplier = try Self.instanceFactor(instance, name: "size")
        instanceSpeedMultiplier = try Self.instanceFactor(instance, name: "speed")
        let configuredRate = try Self.instanceFactor(instance, name: "rate")
        instanceTimeMultiplier = inputTimeAlreadyScaled ? 1 : configuredRate
        instanceAlphaMultiplier = try Self.instanceFactor(instance, name: "alpha", maximum: 16)
        if instanceAlphaMultiplier > 1 {
            parseWarnings.append("instance.alpha is an opacity multiplier and may exceed one; it is applied before the final sampled alpha is clamped to 0...1.")
        }
        instanceColor = try Self.vector(instance["colorn"], named: "instance.colorn", default: SIMD3(repeating: 1))
        guard simd_reduce_min(instanceColor) >= 0, simd_reduce_max(instanceColor) <= 16 else {
            throw Error.unsupported("Native instance.colorn components must be in 0...16.")
        }

        seed = Self.documentSeed(document, instance: instance) ^ seedSalt
        let multiplier = try Self.number(document["sequencemultiplier"], named: "sequencemultiplier", default: 1)
        guard multiplier >= 0, multiplier <= 1000 else { throw Error.unsupported("Native sequence multiplier must be in 0...1000.") }
        sequenceMultiplier = Double(multiplier)
        let rawMode = document["animationmode"]
        guard rawMode == nil || rawMode is NSNull || rawMode is String,
              let mode = AnimationMode(rawValue: (rawMode as? String ?? "sequence").lowercased()) else {
            throw Error.unsupported("Particle animationmode must be sequence or randomframe.")
        }
        animationMode = mode
        flags = try Self.requiredWholeNumber(document["flags"] is NSNull ? 0 : document["flags"] ?? 0, named: "particle flags")
        if flags & 4 != 0, !orthographic {
            throw Error.unsupported("The particle perspective flag is currently implemented only for 2D orthographic scenes.")
        }
        blendsSequenceFrames = flags & 2 == 0 && mode == .sequence
        if flags & 1 != 0 {
            guard flags & ~7 == 0 else { throw Error.unsupported("World-space combined flags \(flags) are not decoded.") }
            // The native mouse branch replaces the control-point translation.
            // Nonzero force/control-point offsets need separate operator decoding.
            guard forces.filter({ $0.followsPointer }).allSatisfy({ $0.point == .zero }) else {
                throw Error.unsupported("World-space pointer forces with nonzero offsets are not decoded.")
            }
            let points = document["controlpoint"] as? [[String: Any]] ?? []
            for point in points where (point["id"] as? NSNumber)?.intValue == 0 {
                guard try Self.vector(point["offset"], named: "controlpoint0.offset", default: .zero) == .zero,
                      try Self.requiredWholeNumber(point["flags"] ?? 0, named: "controlpoint0.flags") == 0 else {
                    throw Error.unsupported("World-space emission currently requires the default control point 0.")
                }
            }
            guard try Self.vector(instance["controlpoint0"], named: "instance.controlpoint0", default: .zero) == .zero else {
                throw Error.unsupported("World-space control point 0 overrides are not decoded.")
            }
            parseWarnings.append("World-space bit 0 uses birth-time authored transforms for emitter offsets and velocity. Emitter origin is added in simulation coordinates; size and gravity are not multiplied by the layer matrix. Later layer motion does not move existing particles. These branches were traced in the official Android library; Windows parity remains unverified.")
        } else if flags & ~7 != 0 {
            parseWarnings.append("Particle flags \(flags) include undecoded override/options beyond the supported low three bits; those options still use the earlier local approximation.")
        }
        if flags & 4 != 0 {
            parseWarnings.append("Particle perspective bit 2 uses general.perspectiveoverridefov (default 95 degrees) and the zoomed 2D projection to derive its per-draw camera distance, with reference clip planes. Existing camera centering/parallax and Windows pixel parity remain unverified.")
        }
        nextEmission = Array(repeating: 0, count: emitters.count)
        emissionClocks = emitters.map { NativeParticleEmissionClock(start: -Double(parsedStartTime) + $0.delay,
            duration: $0.duration, baseRate: $0.rate, baseBurst: $0.instantaneous, count: countMultiplier) }
        scheduledThrough = -startTime
        parseWarnings.append("The bounded native pool retains live particles until death and rejects emissions while full; exact simultaneous birth/death ordering has not been compared with Windows.")
        warnings = parseWarnings
    }

    /// A parsed template is immutable on the frame path. Copy configuration and
    /// texture metadata only; simulation pools, event cursors and clocks start fresh.
    init(template: SceneParticles, seedSalt: UInt64) {
        // Event pools may advance for many frames without generating geometry.
        // Keep only their live dictionary, never a history of expired IDs.
        retainsBirthOrder = false
        materialPath = template.materialPath; warnings = template.warnings
        emitters = template.emitters; lifetime = template.lifetime; size = template.size
        velocity = template.velocity; turbulentVelocities = template.turbulentVelocities
        usesOrthographicDefaults = template.usesOrthographicDefaults
        color = template.color; initialAlpha = template.initialAlpha
        rotations = template.rotations; angularVelocities = template.angularVelocities
        angularMovement = template.angularMovement; lifetimeChanges = template.lifetimeChanges
        renderer = template.renderer; gravity = template.gravity; drag = template.drag
        oscillations = template.oscillations; hasMovement = template.hasMovement
        fadeInFraction = template.fadeInFraction; fadeOutStartFraction = template.fadeOutStartFraction
        startTime = template.startTime; particleLimit = template.particleLimit
        instanceSizeMultiplier = template.instanceSizeMultiplier
        instanceSpeedMultiplier = template.instanceSpeedMultiplier
        instanceTimeMultiplier = template.instanceTimeMultiplier
        instanceAlphaMultiplier = template.instanceAlphaMultiplier; instanceColor = template.instanceColor
        instanceCountMultiplier = template.requestedCountMultiplier; requestedCountMultiplier = template.requestedCountMultiplier
        seed = template.seed ^ seedSalt; forces = template.forces; turbulence = template.turbulence
        sequenceMultiplier = template.sequenceMultiplier; flags = template.flags
        animationMode = template.animationMode; blendsSequenceFrames = template.blendsSequenceFrames
        textureAnimation = template.textureAnimation
        atlasWidth = template.atlasWidth; atlasHeight = template.atlasHeight
        imageWidth = template.imageWidth; imageHeight = template.imageHeight
        spriteAspectRatio = template.spriteAspectRatio
        nextEmission = Array(repeating: 0, count: emitters.count); scheduledThrough = -startTime
        emissionClocks = emitters.map { NativeParticleEmissionClock(start: -startTime + $0.delay,
            duration: $0.duration, baseRate: $0.rate, baseBurst: $0.instantaneous, count: requestedCountMultiplier) }
    }

    /// Preserve pools and random IDs. A density transition is committed after
    /// the preceding frame's scheduler work, including any bounded backlog.
    func applyLiveOverrides(_ values: LiveOverrides) throws {
        if values.count != requestedCountMultiplier {
            if let boundary = previousRequest {
                if countChanges.last?.time == boundary {
                    countChanges[countChanges.count - 1].count = values.count
                } else {
                    guard countChanges.count < 64 else {
                        throw Error.unsupported("Particle density changes are waiting for the scheduler; its 64-transition queue is full.")
                    }
                    countChanges.append((boundary, values.count))
                }
            } else {
                instanceCountMultiplier = values.count
                emissionClocks = emitters.map { NativeParticleEmissionClock(start: -startTime + $0.delay,
                    duration: $0.duration, baseRate: $0.rate, baseBurst: $0.instantaneous, count: values.count) }
            }
            requestedCountMultiplier = values.count
        }
        instanceSizeMultiplier = values.size; instanceAlphaMultiplier = values.alpha
        instanceColor = values.color
        if values.rate != instanceTimeMultiplier {
            if let previousSceneTime = lastRateSceneTime {
                rateAnchorSceneTime = previousSceneTime
                rateAnchorSimulationTime = lastRateSimulationTime
                if hasPointerForces {
                    rateHistory.setRate(values.rate, sceneTime: previousSceneTime, particleTime: lastRateSimulationTime)
                    pointerNeedsPiecewiseClock = true
                }
            }
            instanceTimeMultiplier = values.rate
        }
    }

    var runtimeDiagnostic: String {
        let time = latestObservation["sceneTime"] as? Double ?? 0
        let quads = latestObservation["submittedQuads"] as? Int ?? 0
        let summary = String(format: "粒子运行快照：时间 %.2f 秒；存活 %d / %d，四边形 %d；count=%.4f，发射率 %@；颜色 %@；接受出生 %d，拒绝 %d；密度更新 %d，待处理 %d；调度积压 %.4f 秒；代次 %llu。", time, live.count, particleLimit, quads,
            instanceCountMultiplier, emissionClocks.map { String(format: "%.3f", $0.rate) }.joined(separator: "/"),
            "\(instanceColor)", acceptedBirths, rejectedBirths, committedCountChanges, countChanges.count,
            schedulingBacklog, eventGeneration)
        guard let mode = latestObservation["spriteOrientation"] as? String, mode != "not-sprite" else { return summary }
        return summary + " Sprite 朝向=\(mode)，退化回退=\(latestObservation["spriteOrientationFallback"] as? Bool == true)。"
    }

    func configureTexture(_ animation: SceneTextureAnimation?, width: Int, height: Int, imageWidth: Int, imageHeight: Int) throws {
        if animation != nil, case .ropeTrail = renderer { throw Error.unsupported("Animated rope trail texture coordinates are not implemented.") }
        if animation != nil, flags & ~7 != 0 { throw Error.unsupported("Animated particle flags \(flags) contain undecoded options beyond world space, frame blending and perspective.") }
        textureAnimation = animation; atlasWidth = width; atlasHeight = height
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
        spriteAspectRatio = animation?.particleAspectRatio ?? (Float(imageHeight) / Float(imageWidth))
        guard spriteAspectRatio.isFinite, spriteAspectRatio > 0 else {
            throw Error.unsupported("Particle texture aspect ratio is not finite and positive.")
        }
        if animation != nil {
            warnings.append(animationMode == .randomFrame
                ? "randomframe assigns one stable frame per accepted particle with an independent deterministic random draw. Age and sequence multiplier do not change it; frames do not blend. Random ordering differs from the reference engine."
                : "Particle sequence spans each lifetime, multiplied by sequencemultiplier; TEX frame durations are ignored. The next frame clamps to the final frame, and flags bit 1 disables blending. Windows timing remains unverified.")
            warnings.append("Particle UVs use a regular grid from the first floating TEXS extent and frame count, with unpadded-width handling. Image animation uses serialized rectangles separately. The native half-texel inset remains a filtering approximation.")
        }
    }

    /// Twelve floats per vertex: position XYZ, first UV, RGBA, next UV, frame blend.
    /// The pool preserves particle lifetimes. Scheduling and nonlinear motion have
    /// explicit per-frame budgets; a backlog is retained and reported, never reset
    /// merely because a frame took longer than expected.
    func vertices(at time: Double, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>,
                  pointer: SceneParticlePointerInput = SceneParticlePointerInput(position: nil, reason: "input-not-provided"),
                  capturePointer: Bool = true, workBudget: FrameBudget? = nil,
                  authoredModel: simd_float4x4? = nil, orientationModel: simd_float4x4? = nil,
                  geometryModel: simd_float4x4? = nil) -> [Float] {
        let started = ProcessInfo.processInfo.systemUptime
        frameDirectionSamples = 0; frameResidualSteps = 0
        framePointerApplications = 0; framePointerMaximumAcceleration = 0; frameStrongestPointerSample = [:]
        pointerHistory.resetFrameCounters()
        guard time.isFinite else { return [] }
        let sceneTime = Swift.max(0, time)
        let rewound = lastRateSceneTime.map { sceneTime < $0 } ?? false
        let initialFrame = lastRateSceneTime == nil || rewound
        if rewound {
            // Detect seeking even when a zero rate made particle time flat.
            previousRequest = nil
            rateAnchorSceneTime = 0; rateAnchorSimulationTime = 0
        }
        if hasPointerForces && initialFrame {
            rateHistory.reset(initialRate: instanceTimeMultiplier)
            pointerNeedsPiecewiseClock = false
        }
        let requested = rateAnchorSimulationTime + (sceneTime - rateAnchorSceneTime) * Double(instanceTimeMultiplier)
        guard requested.isFinite else { return [] }
        // Constant positive rates can check freshness directly in particle
        // time. A flat interval needs scene-time inversion to retain its last
        // observation and to distinguish the two sides of the boundary.
        if hasPointerForces, let previousSceneTime = lastRateSceneTime,
           sceneTime > previousSceneTime, requested == lastRateSimulationTime {
            pointerNeedsPiecewiseClock = true
        }
        lastRateSceneTime = sceneTime; lastRateSimulationTime = requested
        preparePool(to: requested)
        transformHistory?.resetFrameCounters()
        // The extra scene timestamp distinguishes a later pose observed while
        // particle time was frozen from the pose at the frozen boundary.
        if let authoredModel { transformHistory?.record(time: requested, transform: authoredModel, sceneTime: sceneTime) }
        let simulationTime = advancePool(to: requested, sharedBudget: workBudget)
        schedulingBacklog = max(0, requested - simulationTime)
        eventSceneTime = time
        eventSimulationTime = simulationTime
        eventRequestedSimulationTime = requested
        if childReservations > 0 { childWorkBudget = FrameBudget() }
        eventParticles.removeAll(keepingCapacity: true)
        if hasPointerForces, capturePointer {
            let firstObservation = pointerHistory.count == 0
            if pointerHistory.append(time: requested, position: pointer.position, sceneTime: sceneTime) {
                if firstObservation && initialFrame { rateHistory.noteFirstPointerObservation(sceneTime: sceneTime, particleTime: requested) }
                pointerInput = pointer
            }
        }
        var physicsBudget = 100_000
        var physicsLag = 0.0, maximumAge = 0.0
        var pointerAffectedParticles = 0
        var samples: [[String: Any]] = []
        var output: [Float] = []
        output.reserveCapacity(live.count * 6 * 12)
        var spriteFrame: NativeParticleOrientation.Frame?
        var spriteMode = "not-sprite"
        var orientationFallback = false
        if case .sprite(let mode, let axis, let independent) = renderer {
            spriteMode = mode.rawValue
            let model = orientationModel ?? authoredModel ?? matrix_identity_float4x4
            let geometry = geometryModel ?? (usesWorldSpace ? matrix_identity_float4x4 : model)
            spriteFrame = NativeParticleOrientation.frame(mode: mode, axis: axis, independent: independent,
                systemModel: model, geometryModel: geometry, cameraRight: cameraRight, cameraUp: cameraUp)
            orientationFallback = spriteFrame == nil
        }
        if birthOrder.count > live.count * 2 + 1024 { birthOrder.removeAll { live[$0] == nil } }
        let renderOrder = retainsBirthOrder ? birthOrder : live.keys.sorted()
        for spawn in renderOrder {
            guard var particle = live[spawn] else { continue }
            let age = Float(simulationTime - particle.birthTime)
            guard age >= 0, age < particle.lifetime else { continue }
            let applicationsBefore = framePointerApplications
            let failedTransformsBefore = transformHistory?.failedQueries ?? 0
            let motion = position(for: &particle, age: Double(age), budget: &physicsBudget)
            if (transformHistory?.failedQueries ?? 0) != failedTransformsBefore {
                spaceFailure = "Required authored transform history was lost during world-space motion."
            }
            if framePointerApplications > applicationsBefore { pointerAffectedParticles += 1 }
            live[spawn] = particle
            physicsLag = max(physicsLag, motion.lag)
            var position = motion.position
            var currentVelocity = motion.velocity
            var alpha = alphaMultiplier(age: age, lifetime: particle.lifetime) * instanceAlphaMultiplier
            var sizeScale: Float = 1
            var rgb = SIMD3(particle.color.x, particle.color.y, particle.color.z)
            for change in lifetimeChanges {
                let value = change.value(at: age / particle.lifetime)
                switch change.target {
                case .size: sizeScale *= value.x
                case .alpha: alpha *= value.x
                case .color: rgb = value
                }
            }
            for oscillation in particle.oscillations {
                let wave = oscillation.wave(progress: age / particle.lifetime)
                switch oscillation.target {
                case .position:
                    position += wave * oscillation.amplitude * oscillation.mask
                    currentVelocity += oscillation.velocity(progress: age / particle.lifetime, lifetime: particle.lifetime)
                case .alpha:
                    alpha *= oscillation.alphaRange.lower + (oscillation.alphaRange.upper - oscillation.alphaRange.lower) * (0.5 + 0.5 * wave.x)
                case .size:
                    sizeScale *= oscillation.alphaRange.lower + (oscillation.alphaRange.upper - oscillation.alphaRange.lower) * (0.5 + 0.5 * wave.x)
                }
            }
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
                  currentVelocity.x.isFinite, currentVelocity.y.isFinite, currentVelocity.z.isFinite,
                  sizeScale.isFinite, alpha.isFinite else { continue }
            if capturesEvents { eventParticles.append(EventParticle(id: spawn, age: Double(age), position: position)) }
            maximumAge = max(maximumAge, Double(age))
            rgb *= instanceColor
            let tint = SIMD4<Float>(rgb, particle.color.w * alpha)
            let sequence = sequenceFrame(age: Double(age), lifetime: Double(particle.lifetime), spawn: spawn)
            let rotation = rotationAngles(for: particle, age: Double(age))
            let basis = spriteBasis(rotation: rotation, velocity: currentVelocity, cameraRight: cameraRight, cameraUp: cameraUp,
                spriteFrame: spriteFrame)
            let currentSize = particle.size * instanceSizeMultiplier * sizeScale
            guard currentSize.isFinite, tint.x.isFinite, tint.y.isFinite, tint.z.isFinite, tint.w.isFinite else { continue }
            if samples.count < 4 {
                let flow = hasMovement ? turbulenceVelocity(at: motion.position,
                    time: simulationTime - motion.lag, particle: particle) : .zero
                samples.append(["emitter": spawn.emitterIndex, "birthIndex": spawn.emissionIndex,
                    "age": Double(age), "lifetime": particle.lifetime,
                    "position": [position.x, position.y, position.z], "frame": sequence.index,
                    "frameBlend": sequence.blend, "velocity": [currentVelocity.x, currentVelocity.y, currentVelocity.z],
                    "rotationRadians": [rotation.x, rotation.y, rotation.z], "size": currentSize,
                    "color": [tint.x, tint.y, tint.z, tint.w], "trailStretch": basis.stretch,
                    "turbulenceVelocity": [flow.x, flow.y, flow.z]])
            }
            if case .ropeTrail(let length, let segments, let subdivision, let uvScale, let fadeAlpha, let fadeSize) = renderer {
                appendRope(particle: particle, age: age, length: length, segments: segments * subdivision,
                    halfWidth: max(0, currentSize) * 0.5, cameraRight: cameraRight, cameraUp: cameraUp,
                    color: tint, uv: sequence.first, uvScale: uvScale, fadeAlpha: fadeAlpha, fadeSize: fadeSize, into: &output)
            } else {
                appendSprite(center: position, halfSize: currentSize * 0.5,
                         right: basis.right, up: basis.up * basis.stretch,
                         color: tint, firstUV: sequence.first, nextUV: sequence.next, blend: sequence.blend,
                         into: &output)
            }
        }
        let elapsed = max(0, ProcessInfo.processInfo.systemUptime - started)
        simulationFrames += 1; simulationSeconds += elapsed
        maximumSimulationSeconds = max(maximumSimulationSeconds, elapsed)
        latestObservation = ["sceneTime": time, "simulationTime": simulationTime,
            "requestedSimulationTime": requested, "instanceRate": instanceTimeMultiplier, "alive": live.count,
            "coordinateSpace": usesWorldSpace ? "world" : "local", "worldBirths": worldBirths,
            "spaceFailure": spaceFailure ?? "", "placementBacklog": placementBacklog, "placementWorkUnits": placementWork,
            "pendingWorldEmission": pendingEmission != nil,
            "transformHistorySamples": transformHistory?.count ?? 0,
            "transformHistoryDiscarded": transformHistory?.discardedSamples ?? 0,
            "transformHistoryQueries": transformHistory?.queries ?? 0,
            "transformPrewarmQueries": transformHistory?.prewarmQueries ?? 0,
            "transformFailedQueries": transformHistory?.failedQueries ?? 0,
            "material": materialPath, "renderer": { switch renderer { case .sprite: return "sprite"; case .spriteTrail: return "spritetrail"; case .ropeTrail: return "ropetrail" } }(),
            "spriteOrientation": spriteMode, "spriteOrientationFallback": orientationFallback,
            "submittedQuads": output.count / 72, "eventGeneration": eventGeneration,
            "eventParticles": eventParticles.count,
            "birthJournalCount": birthJournal.count, "birthJournalCapacity": Self.birthJournalCapacity,
            "birthJournalConsumers": birthConsumers.count, "birthJournalBlocked": journalBlocked,
            "limit": particleLimit, "acceptedBirths": acceptedBirths, "rejectedBirths": rejectedBirths,
            "instanceCount": instanceCountMultiplier, "requestedInstanceCount": requestedCountMultiplier,
            "emissionRates": emissionClocks.map { $0.rate }, "instanceColor": [instanceColor.x, instanceColor.y, instanceColor.z],
            "committedCountChanges": committedCountChanges, "pendingCountChanges": countChanges.count,
            "lastCountChangeTime": lastCountChangeTime.map { $0 as Any } ?? NSNull(),
            "maximumAge": maximumAge, "scheduleBacklog": max(0, requested - simulationTime),
            "physicsBacklog": physicsLag, "sequenceFrames": textureAnimation?.frames.count ?? 0,
            "animationMode": animationMode.rawValue, "sequenceFrameBlending": blendsSequenceFrames,
            "spriteAspectRatio": spriteAspectRatio, "perspectiveProjection": usesPerspectiveProjection,
            "turbulenceOperators": turbulence.count, "turbulentVelocityInitializers": turbulentVelocities.count, "committedPhysicsWorkUnits": 100_000 - physicsBudget,
            "turbulenceDirectionSamples": frameDirectionSamples, "residualPhysicsSteps": frameResidualSteps,
            "pointerForceOperators": forces.filter { $0.followsPointer }.count,
            "pointerForceApplications": framePointerApplications, "pointerAffectedParticles": pointerAffectedParticles,
            "pointerMaximumAcceleration": framePointerMaximumAcceleration,
            "pointerStrongestSample": frameStrongestPointerSample,
            "pointerInputActive": pointerInput.position != nil, "pointerInputReason": pointerInput.reason,
            "pointerLocalPosition": pointerInput.position.map { [$0.x, $0.y, $0.z] } ?? [],
            "pointerHistorySamples": pointerHistory.count, "pointerHistoryDiscardedSamples": pointerHistory.discardedSamples,
            "pointerHistoryQueries": pointerHistory.queries, "pointerOutsideCoverageQueries": pointerHistory.outsideCoverageQueries,
            "pointerStaleQueries": pointerHistory.staleQueries, "pointerInactiveQueries": pointerHistory.inactiveQueries,
            "pointerLostHistoryQueries": pointerHistory.lostHistoryQueries,
            "pointerPiecewiseClock": pointerNeedsPiecewiseClock,
            "pointerRateHistorySegments": rateHistory.count, "pointerRateHistoryDiscardedSegments": rateHistory.discardedSegments,
            "simulationFrames": simulationFrames, "simulationMilliseconds": elapsed * 1000,
            "meanSimulationMilliseconds": simulationSeconds / Double(simulationFrames) * 1000,
            "maximumSimulationMilliseconds": maximumSimulationSeconds * 1000,
            "samples": samples]
        return spaceFailure == nil ? output : []
    }

    func observation(at time: Double) -> String? {
        let pointerActive = pointerInput.position != nil
        let pointerMoved: Bool
        if let a = pointerInput.position, let b = previousPointerReportPosition { pointerMoved = simd_length(a - b) > 2 }
        else { pointerMoved = pointerActive != previousPointerReportActive }
        let pointerChanged = hasPointerForces && pointerReportCount < 128 && time - lastPointerReportTime >= 0.5 &&
            (pointerMoved || pointerActive != previousPointerReportActive)
        // Sparse, short contacts can begin and end between periodic reports.
        // Retain one actual force observation per system without changing physics.
        let firstPointerForce = !firstPointerForceReported && framePointerApplications > 0
        guard time >= nextReportTime || pointerChanged || firstPointerForce else { return nil }
        if time >= nextReportTime { nextReportTime = time + (time < 30 ? 5 : 60) }
        if pointerChanged {
            pointerReportCount += 1; lastPointerReportTime = time
            previousPointerReportPosition = pointerInput.position; previousPointerReportActive = pointerActive
        }
        var report = latestObservation
        report["firstPointerForceObservation"] = firstPointerForce
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return nil }
        if firstPointerForce { firstPointerForceReported = true }
        return String(decoding: data, as: UTF8.self)
    }

    private func preparePool(to target: Double) {
        if previousRequest == nil || target < previousRequest! {
            eventGeneration &+= 1
            birthJournal.removeAll(keepingCapacity: true); birthJournalBase = 0
            birthConsumers = Array(repeating: 0, count: birthConsumers.count)
            live.removeAll(keepingCapacity: true); deaths.removeAll(keepingCapacity: true)
            birthOrder.removeAll(keepingCapacity: true)
            nextEmission = Array(repeating: 0, count: emitters.count)
            instanceCountMultiplier = requestedCountMultiplier
            emissionClocks = emitters.map { NativeParticleEmissionClock(start: -startTime + $0.delay,
                duration: $0.duration, baseRate: $0.rate, baseBurst: $0.instantaneous, count: requestedCountMultiplier) }
            countChanges.removeAll(keepingCapacity: true); committedCountChanges = 0; lastCountChangeTime = nil
            scheduledThrough = -startTime; acceptedBirths = 0; rejectedBirths = 0
            lastParticleDeathTime = nil
            simulationFrames = 0; simulationSeconds = 0; maximumSimulationSeconds = 0
            pointerHistory.reset(); pointerInput = SceneParticlePointerInput(position: nil, reason: "clock-reset")
            previousPointerReportPosition = nil; previousPointerReportActive = false
            lastPointerReportTime = -Double.infinity; pointerReportCount = 0
            firstPointerForceReported = false
            nextReportTime = 0
            transformHistory?.reset(); pendingEmission = nil; spaceFailure = nil
            worldBirths = 0; placementBacklog = 0; placementWork = 0
        }
        previousRequest = target
    }

    private func advancePool(to target: Double, sharedBudget: FrameBudget?) -> Double {
        preparePool(to: target)
        guard spaceFailure == nil else { return scheduledThrough }
        if let consumed = birthConsumers.min(), consumed > birthJournalBase {
            birthJournal.removeFirst(consumed - birthJournalBase); birthJournalBase = consumed
        }
        journalBlocked = false
        let limit = max(0, min(20_000, sharedBudget?.remainingSchedulerOperations ?? 20_000))
        let budget = FrameBudget(operations: limit)
        placementBacklog = 0; placementWork = 0
        defer { if let sharedBudget { sharedBudget.remainingSchedulerOperations -= limit - budget.remainingSchedulerOperations } }
        while let change = countChanges.first, change.time <= target {
            let reached = advanceEmissions(to: change.time, budget: budget)
            // A budget-limited burst can share the frontier timestamp. Finish
            // every due birth before changing its clock or pending placement.
            guard spaceFailure == nil, reached >= change.time,
                  !emitters.indices.contains(where: {
                      emissionTime(index: nextEmission[$0], emitterIndex: $0).map { $0 <= change.time } ?? false
                  }) else { return reached }
            for index in emissionClocks.indices { emissionClocks[index].setCount(change.count, at: change.time) }
            instanceCountMultiplier = change.count; committedCountChanges += 1; lastCountChangeTime = change.time
            countChanges.removeFirst()
        }
        return advanceEmissions(to: target, budget: budget)
    }

    private func advanceEmissions(to target: Double, budget: FrameBudget) -> Double {
        while true {
            let candidate = emitters.indices.compactMap { index -> Spawn? in
                guard let birth = emissionTime(index: nextEmission[index], emitterIndex: index) else { return nil }
                return Spawn(birthTime: birth,
                             emitterIndex: index, emissionIndex: nextEmission[index])
            }.min()
            guard let candidate, candidate.birthTime <= target else {
                expire(through: target); scheduledThrough = target; return target
            }
            guard budget.remainingSchedulerOperations > 0 else { return scheduledThrough }
            // Stop before expiration as well: otherwise a blocked birth would
            // remove particles newer than the simulation snapshot we report.
            if !birthConsumers.isEmpty, birthJournal.count >= Self.birthJournalCapacity {
                journalBlocked = true; return scheduledThrough
            }
            expire(through: candidate.birthTime)
            if live.count >= particleLimit, let death = deaths.first {
                // Skip only emissions known to occur while every slot is occupied.
                // An emission at the earliest death may reuse that released slot.
                for index in emitters.indices where nextEmission[index] >= 0 {
                    guard let birth = emissionTime(index: nextEmission[index], emitterIndex: index), birth <= target else { continue }
                    let next: Int
                    if death.time <= target {
                        next = emissionClocks[index].emissionIndex(at: death.time, strictlyAfter: false)
                    } else {
                        next = emissionClocks[index].emissionIndex(at: target, strictlyAfter: true)
                    }
                    if next > nextEmission[index] {
                        let skipped = next - nextEmission[index]
                        rejectedBirths = rejectedBirths > Int.max - skipped ? Int.max : rejectedBirths + skipped
                        nextEmission[index] = next
                    }
                }
                budget.remainingSchedulerOperations -= 1
                continue
            }
            if pendingEmission == nil {
                budget.remainingSchedulerOperations -= 1
                pendingEmission = (candidate, makeParticle(from: candidate))
            }
            guard let pending = pendingEmission, pending.spawn == candidate else {
                spaceFailure = "Pending emission order changed."; return scheduledThrough
            }
            var particle = pending.particle
            if usesWorldSpace {
                let before = budget.remainingSchedulerOperations
                let placement: BirthPlacement
                if let birthPlacement { placement = birthPlacement(candidate, budget) }
                else {
                    guard budget.remainingSchedulerOperations > 0 else { return scheduledThrough }
                    budget.remainingSchedulerOperations -= 1
                    switch authoredTransform(at: candidate.birthTime) {
                    case .ready(let model): placement = .ready(model)
                    case .failed(let message): placement = .failed(message)
                    }
                }
                placementWork += before - budget.remainingSchedulerOperations
                switch placement {
                case .ready(let model):
                    let origin = emitters[candidate.emitterIndex].origin
                    // EmitParticles adds emitter.origin AFTER the control-point
                    // matrix transforms the sampled volume offset.
                    let position = model * SIMD4(particle.position - origin, 1) + SIMD4(origin, 0)
                    let velocity = model * SIMD4(particle.velocity, 0)
                    guard [position.x,position.y,position.z,velocity.x,velocity.y,velocity.z].allSatisfy(\.isFinite) else {
                        spaceFailure = "World-space birth produced non-finite position or velocity."; return scheduledThrough
                    }
                    particle.position = SIMD3(position.x,position.y,position.z)
                    particle.velocity = SIMD3(velocity.x,velocity.y,velocity.z)
                    particle.integratedPosition = particle.position; particle.integratedVelocity = particle.velocity
                    worldBirths += 1
                case .pending(let lag): placementBacklog = lag; return scheduledThrough
                case .failed(let message): spaceFailure = message; return scheduledThrough
                }
            }
            let deathTime = candidate.birthTime + Double(particle.lifetime)
            live[candidate] = particle
            if !birthConsumers.isEmpty { birthJournal.append(makeBirthEvent(id: candidate, particle: particle, deathTime: deathTime)) }
            if retainsBirthOrder { birthOrder.append(candidate) }
            insertDeath(Death(time: deathTime, spawn: candidate))
            acceptedBirths = acceptedBirths == Int.max ? Int.max : acceptedBirths + 1
            nextEmission[candidate.emitterIndex] = candidate.emissionIndex == Int.max ? -1 : candidate.emissionIndex + 1
            scheduledThrough = candidate.birthTime
            pendingEmission = nil
        }
    }

    private func insertDeath(_ death: Death) {
        deaths.append(death)
        var index = deaths.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard deaths[index].time < deaths[parent].time else { break }
            deaths.swapAt(index, parent); index = parent
        }
    }

    private func expire(through time: Double) {
        while let first = deaths.first, first.time <= time {
            live.removeValue(forKey: first.spawn)
            lastParticleDeathTime = first.time
            if deaths.count == 1 { deaths.removeLast(); continue }
            deaths[0] = deaths.removeLast()
            var index = 0
            while index * 2 + 1 < deaths.count {
                var child = index * 2 + 1
                if child + 1 < deaths.count, deaths[child + 1].time < deaths[child].time { child += 1 }
                guard deaths[child].time < deaths[index].time else { break }
                deaths.swapAt(child, index); index = child
            }
        }
    }

    private func sequenceFrame(age: Double, lifetime: Double, spawn: Spawn) -> (first: SIMD4<Float>, next: SIMD4<Float>, blend: Float, index: Int) {
        guard let sequence = textureAnimation else {
            let rect = SIMD4<Float>(0,0,Float(imageWidth)/Float(atlasWidth),Float(imageHeight)/Float(atlasHeight))
            return (rect,rect,0,0)
        }
        if animationMode == .randomFrame {
            var random = DeterministicRandom(seed: Self.particleSeed(base: seed ^ 0x53_50_52_49_54_45_55_56,
                emitter: spawn.emitterIndex, emission: spawn.emissionIndex))
            let index = min(sequence.frames.count - 1, Int(random.unitFloat() * Float(sequence.frames.count)))
            let uv = sequence.particleUV(frame: index, atlasWidth: atlasWidth, atlasHeight: atlasHeight, imageWidth: imageWidth)
            return (uv, uv, 0, index)
        }
        // The serialized durations affect image playback, not particle life.
        let phase = (age / lifetime * sequenceMultiplier).truncatingRemainder(dividingBy: 1) * Double(sequence.frames.count)
        let index = min(sequence.frames.count - 1, max(0, Int(floor(phase))))
        func rect(_ index: Int) -> SIMD4<Float> {
            sequence.particleUV(frame: index, atlasWidth: atlasWidth, atlasHeight: atlasHeight, imageWidth: imageWidth)
        }
        return (rect(index), rect(min(index + 1, sequence.frames.count - 1)),
            blendsSequenceFrames ? Float(phase - floor(phase)) : 0, index)
    }

    private func emissionTime(index: Int, emitterIndex: Int) -> Double? {
        guard let time = emissionClocks[emitterIndex].birthTime(index: index),
              eventEmissionCutoff.map({ time < $0 }) ?? true else { return nil }
        return time
    }

    private func makeBirthEvent(id: Spawn, particle: Particle, deathTime: Double) -> BirthEvent {
        var factory: (() -> EventTrajectory)?
        if capturesFollowTrajectories {
            let generation = eventGeneration
            factory = { [weak self] in
                var copy = particle
                var lastRequestedAge = -Double.infinity
                return EventTrajectory { [weak self] age, budget in
                    guard let self else { return .failed("Parent trajectory owner was released.") }
                    guard self.eventGeneration == generation else { return .failed("Parent trajectory generation changed.") }
                    guard age.isFinite, age >= 0 else { return .failed("Invalid follow trajectory age.") }
                    // Match the parent renderer's Float age and cap at the
                    // sampled lifetime; the terminal position then stays fixed.
                    let target = Double(min(Float(age), particle.lifetime))
                    guard target >= lastRequestedAge else { return .failed("Follow trajectory cannot move backwards within a generation.") }
                    lastRequestedAge = target
                    let before = budget.remainingSchedulerOperations
                    var remaining = before
                    let lostBefore = self.pointerHistory.lostHistoryQueries
                    let transformsBefore = self.transformHistory?.failedQueries ?? 0
                    let motion = self.position(for: &copy, age: target, budget: &remaining)
                    budget.remainingSchedulerOperations -= before - remaining
                    guard self.pointerHistory.lostHistoryQueries == lostBefore else {
                        return .failed("Required recorded pointer history was evicted during follow replay.")
                    }
                    guard (self.transformHistory?.failedQueries ?? 0) == transformsBefore else {
                        return .failed("Required recorded emitter transform was evicted during follow replay.")
                    }
                    guard motion.lag <= 0 else { return .pending(motion.lag) }
                    var position = motion.position
                    for oscillation in copy.oscillations {
                        if case .position = oscillation.target {
                            position += oscillation.wave(progress: Float(target) / copy.lifetime) * oscillation.amplitude * oscillation.mask
                        }
                    }
                    guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                        return .failed("Follow trajectory produced a non-finite position.")
                    }
                    return .ready(position)
                }
            }
        }
        return BirthEvent(id: id, position: particle.position, lifetime: Double(particle.lifetime), deathTime: deathTime, makeTrajectory: factory)
    }

    private static func safeInteger(_ value: Double) -> Int {
        if value >= Double(Int.max) { return Int.max }
        if value <= Double(Int.min) { return Int.min }
        return Int(value)
    }

    private func makeParticle(from spawn: Spawn) -> Particle {
        var random = DeterministicRandom(seed: Self.particleSeed(base: seed, emitter: spawn.emitterIndex, emission: spawn.emissionIndex))
        // A separate stream keeps existing lifetime/size/color/oscillation draws
        // unchanged when this new operator starts consuming random values.
        var fieldRandom = DeterministicRandom(seed: Self.particleSeed(base: seed ^ 0x54_55_52_42_55_4C_45_4E,
            emitter: spawn.emitterIndex, emission: spawn.emissionIndex))
        let emitter = emitters[spawn.emitterIndex]
        let initialPosition = spawnPosition(for: emitter, random: &random)
        var initialVelocity = velocity.sample(&random)
        // Preserve unrelated attribute draws when this initializer is added.
        var velocityRandom = DeterministicRandom(seed: Self.particleSeed(base: seed ^ 0x56_45_4C_4F_43_49_54_59,
            emitter: spawn.emitterIndex, emission: spawn.emissionIndex))
        for initializer in turbulentVelocities {
            initialVelocity += initializer.sample(at: spawn.birthTime, random: &velocityRandom)
        }
        initialVelocity *= instanceSpeedMultiplier
        let initialLifetime = lifetime.sample(&random), initialSize = size.sample(&random)
        var initialColor = color.sample(&random)
        if let initialAlpha { initialColor.w *= initialAlpha.sample(&random) }
        // Repeated angular initializers are evaluated in serialized order; the
        // later assignment replaces the same attribute. Exact native ordering
        // is an explicit compatibility inference, not a deduplicated parse.
        var initialRotation = SIMD3<Float>.zero
        for range in rotations { initialRotation = range.sample(&random) }
        var initialAngularVelocity = SIMD3<Float>.zero
        for range in angularVelocities { initialAngularVelocity = range.sample(&random) }
        return Particle(
            birthTime: spawn.birthTime,
            position: initialPosition,
            velocity: initialVelocity,
            lifetime: initialLifetime,
            size: initialSize,
            color: initialColor,
            rotation: initialRotation,
            angularVelocity: initialAngularVelocity,
            oscillations: oscillations.map { $0.sample(&random) },
            turbulence: turbulence.map { $0.sample(&fieldRandom) },
            integratedPosition: initialPosition,
            integratedVelocity: initialVelocity
        )
    }

    private func spawnPosition(for emitter: Emitter, random: inout DeterministicRandom) -> SIMD3<Float> {
        switch emitter.shape {
        case .boxRandom(let directions, let minimum, let maximum):
            let unit = SIMD3<Float>(random.unitFloat(), random.unitFloat(), random.unitFloat())
            // Each side of the excluded central interval is sampled uniformly.
            // With min=0 this preserves the old uniform box random stream.
            let signed = unit * 2 - SIMD3<Float>(repeating: 1)
            let magnitude = minimum + (maximum - minimum) * simd_abs(signed)
            let sign = SIMD3<Float>(signed.x < 0 ? -1 : 1, signed.y < 0 ? -1 : 1, signed.z < 0 ? -1 : 1)
            return emitter.origin + magnitude * sign * directions
        case .sphereRandom(let directions, let minimum, let span, let axialMinimum, let signs):
            // REA: EmitParticles samples a volume ball (also for planar
            // emitters), scales its axes, then remaps the projected length.
            // The signed distance span is authored, not a sorted interval.
            let angle = 2 * Float.pi * random.unitFloat()
            let axial = axialMinimum + (1 - axialMinimum) * random.unitFloat()
            let radial = cbrtf(random.unitFloat())
            let transverse = sqrtf(max(0, 1 - axial * axial))
            let sample = SIMD3(axial, sinf(angle) * transverse, cosf(angle) * transverse) * radial * directions
            let length = simd_length(sample)
            // An exactly zero projection has no direction. Keep it finite at
            // the origin rather than reproducing the reference's reciprocal
            // singularity (e.g. a closed cone with its X multiplier zero).
            guard length > 0 else { return emitter.origin }
            var unit = sample / length
            // Sign folding precedes distance remapping in the reference.
            for axis in 0..<3 {
                if signs[axis] > 0 { unit[axis] = abs(unit[axis]) }
                else if signs[axis] < 0 { unit[axis] = -abs(unit[axis]) }
            }
            return emitter.origin + unit * (minimum + span * length)
        }
    }

    private func movementState(for particle: Particle, age: Float) -> (position: SIMD3<Float>, velocity: SIMD3<Float>) {
        guard hasMovement else { return (particle.position, .zero) }
        guard age > 0 else { return (particle.position, particle.velocity) }
        let acceleration = gravity * instanceSpeedMultiplier
        guard drag > 0 else { return (particle.position + particle.velocity * age + acceleration * (0.5 * age * age), particle.velocity + acceleration * age) }
        // Solve dv/dt = g - drag*v without a frame-rate-dependent simulation loop.
        // Series near zero avoids cancellation in t - (1 - exp(-d*t))/d.
        let t = Double(age), d = Double(drag), x = d * t
        let velocityIntegral: Double
        let accelerationIntegral: Double
        if x < 0.001 {
            velocityIntegral = t * (1 - x / 2 + x * x / 6)
            accelerationIntegral = t * t * (0.5 - x / 6 + x * x / 24)
        } else {
            velocityIntegral = -expm1(-x) / d
            accelerationIntegral = (t - velocityIntegral) / d
        }
        return (particle.position + particle.velocity * Float(velocityIntegral) + acceleration * Float(accelerationIntegral),
                particle.velocity * Float(exp(-x)) + acceleration * Float(velocityIntegral))
    }

    private func position(for particle: inout Particle, age: Double, budget: inout Int) -> (position: SIMD3<Float>, velocity: SIMD3<Float>, lag: Double) {
        guard hasMovement, !forces.isEmpty || !turbulence.isEmpty else {
            let state = movementState(for: particle, age: Float(age))
            return (state.position, state.velocity, 0)
        }
        let step = 1.0 / 120.0
        let targetSteps = Int(floor(age / step))
        // Charge both midpoint field samples. More operators reduce the number
        // of catch-up steps rather than multiplying unbounded per-frame work.
        let cost = max(1, turbulence.count * 2)
        let limit = min(targetSteps, particle.integratedSteps + budget / cost)
        while particle.integratedSteps < limit {
            let next = forceStep(position: particle.integratedPosition, velocity: particle.integratedVelocity,
                duration: step, time: particle.birthTime + Double(particle.integratedSteps) * step, particle: particle)
            particle.integratedPosition = next.position; particle.integratedVelocity = next.velocity
            particle.integratedSteps += 1; budget -= cost
        }
        let remainder = age - Double(particle.integratedSteps) * step
        let integratedTime = particle.birthTime + Double(particle.integratedSteps) * step
        guard particle.integratedSteps == targetSteps else {
            let flow = turbulenceVelocity(at: particle.integratedPosition, time: integratedTime, particle: particle)
            return (particle.integratedPosition, particle.integratedVelocity + flow, remainder)
        }
        // Residual/output evaluation is additionally bounded by the live-particle
        // and field-count limits, rather than charged to the catch-up budget.
        // Count every direction sample separately so diagnostics expose this work.
        // Keep residual interpolation off the cached grid to avoid frame-rate
        // dependent accumulation; a zero remainder needs no interpolation.
        let state: (position: SIMD3<Float>, velocity: SIMD3<Float>)
        if remainder > 0 {
            frameResidualSteps += 1
            state = forceStep(position: particle.integratedPosition, velocity: particle.integratedVelocity,
                duration: remainder, time: integratedTime, particle: particle)
        } else {
            state = (particle.integratedPosition, particle.integratedVelocity)
        }
        let flow = turbulenceVelocity(at: state.position, time: particle.birthTime + age, particle: particle)
        return (state.position, state.velocity + flow, 0)
    }

    private func rotationAngles(for particle: Particle, age: Double) -> SIMD3<Float> {
        guard let angularMovement else { return particle.rotation }
        let d = Double(angularMovement.drag), x = d * age
        let velocityIntegral: Double, accelerationIntegral: Double
        if x < 0.001 {
            velocityIntegral = age * (1 - x / 2 + x * x / 6)
            accelerationIntegral = age * age * (0.5 - x / 6 + x * x / 24)
        } else {
            velocityIntegral = -expm1(-x) / d
            accelerationIntegral = (age - velocityIntegral) / d
        }
        func angle(_ index: Int) -> Float {
            let value = Double(particle.rotation[index]) + Double(particle.angularVelocity[index]) * velocityIntegral
                + Double(angularMovement.force[index]) * accelerationIntegral
            return Float(value.truncatingRemainder(dividingBy: 2 * Double.pi))
        }
        return SIMD3(angle(0), angle(1), angle(2))
    }

    private func spriteBasis(rotation: SIMD3<Float>, velocity: SIMD3<Float>, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>,
                             spriteFrame: NativeParticleOrientation.Frame?) -> (right: SIMD3<Float>, up: SIMD3<Float>, stretch: Float) {
        switch renderer {
        case .sprite, .ropeTrail:
            let right = spriteFrame?.right ?? cameraRight, up = spriteFrame?.up ?? cameraUp
            let normal = simd_normalize(simd_cross(right, up))
            let cz = cosf(rotation.z), sz = sinf(rotation.z)
            if rotation.x == 0, rotation.y == 0 {
                return (right * cz + up * sz, up * cz - right * sz, 1)
            }
            let cx = cosf(rotation.x), sx = sinf(rotation.x), cy = cosf(rotation.y), sy = sinf(rotation.y)
            let x = simd_float3x3(columns: (SIMD3(1,0,0), SIMD3(0,cx,sx), SIMD3(0,-sx,cx)))
            let y = simd_float3x3(columns: (SIMD3(cy,0,-sy), SIMD3(0,1,0), SIMD3(sy,0,cy)))
            let z = simd_float3x3(columns: (SIMD3(cz,sz,0), SIMD3(-sz,cz,0), SIMD3(0,0,1)))
            let orientation = simd_float3x3(columns: (right, up, normal)) * z * y * x
            return (orientation.columns.0, orientation.columns.1, 1)
        case .spriteTrail(let length, let minimum, let maximum):
            let normal = simd_normalize(simd_cross(cameraRight, cameraUp))
            let projected = velocity - normal * simd_dot(velocity, normal)
            let speed = simd_length(projected)
            let direction = speed > 0.00001 ? projected / speed : cameraUp
            return (simd_cross(direction, normal), direction, max(minimum, min(maximum, speed * length)))
        }
    }

    private func acceleration(at position: SIMD3<Float>, time: Double) -> SIMD3<Float> {
        var result = gravity
        // Renderer ages are Float for compatibility with its existing pool.
        // Their rounded residual can extend slightly past the actual reached
        // frontier. Never consult a later pointer/transform for that sliver.
        let causalTime = eventSimulationTime.isFinite ? min(time, eventSimulationTime) : time
        let cursor: SIMD3<Float>?
        if !hasPointerForces { cursor = nil }
        else if pointerNeedsPiecewiseClock {
            cursor = pointerHistory.position(at: causalTime, sceneTime: rateHistory.sceneTime(for: causalTime), maximumSceneAge: 0.25)
        } else {
            cursor = pointerHistory.position(at: causalTime, maximumAge: 0.25 * Double(instanceTimeMultiplier))
        }
        for force in forces {
            let point: SIMD3<Float>
            if force.followsPointer {
                guard let cursor else { continue }
                point = cursor + force.point
            } else if usesWorldSpace {
                switch authoredTransform(at: causalTime) {
                case .ready(let matrix):
                    let transformed = matrix * SIMD4(force.point, 1)
                    point = SIMD3(transformed.x, transformed.y, transformed.z)
                case .failed: return SIMD3(repeating: .nan)
                }
            } else { point = force.point }
            let offset = point - position, distance = simd_length(offset)
            if distance > 0.00001, distance < force.distance {
                let acceleration = offset / distance * force.strength * (1 - distance / force.distance)
                result += acceleration
                if force.followsPointer {
                    framePointerApplications += 1
                    let actual = acceleration * instanceSpeedMultiplier, magnitude = simd_length(actual)
                    if magnitude > framePointerMaximumAcceleration {
                        framePointerMaximumAcceleration = magnitude
                        frameStrongestPointerSample = ["simulationTime": causalTime,
                            "particlePosition": [position.x, position.y, position.z],
                            "controlPointPosition": [point.x, point.y, point.z],
                            "acceleration": [actual.x, actual.y, actual.z], "distance": distance,
                            "strength": force.strength, "radius": force.distance]
                    }
                }
            }
        }
        return result * instanceSpeedMultiplier
    }

    private func turbulenceVelocity(at position: SIMD3<Float>, time: Double, particle: Particle) -> SIMD3<Float> {
        var result = SIMD3<Float>.zero
        frameDirectionSamples += turbulence.count
        for (index, field) in turbulence.enumerated() {
            let sample = particle.turbulence[index]
            let direction = NativeParticleTurbulence.direction(position: position, scale: field.scale,
                phase: sample.phase, time: time * Double(field.timeScale))
            result += direction * field.mask * (sample.speed * instanceSpeedMultiplier)
        }
        return result
    }

    private func forceStep(position: SIMD3<Float>, velocity: SIMD3<Float>, duration: Double, time: Double, particle: Particle) -> (position: SIMD3<Float>, velocity: SIMD3<Float>) {
        func advance(_ acceleration: SIMD3<Float>, _ duration: Double) -> (position: SIMD3<Float>, velocity: SIMD3<Float>) {
            let d = Double(drag), x = d * duration
            let a: Double, b: Double
            if x < 0.001 {
                a = duration * (1 - x / 2 + x * x / 6)
                b = duration * duration * (0.5 - x / 6 + x * x / 24)
            } else {
                a = -expm1(-x) / d; b = (duration - a) / d
            }
            return (position + velocity * Float(a) + acceleration * Float(b),
                    velocity * Float(exp(-x)) + acceleration * Float(a))
        }
        // Integrate dx/dt = baseVelocity + turbulentVelocity. The turbulent
        // speed is never accumulated into baseVelocity as an acceleration.
        // Existing analytic drag acts on baseVelocity; the field advects the
        // position and is included in the renderer's final trail velocity.
        let initialFlow = turbulenceVelocity(at: position, time: time, particle: particle)
        let midpoint = advance(acceleration(at: position, time: time), duration * 0.5).position + initialFlow * Float(duration * 0.5)
        let flow = turbulenceVelocity(at: midpoint, time: time + duration * 0.5, particle: particle)
        let result = advance(acceleration(at: midpoint, time: time + duration * 0.5), duration)
        return (result.position + flow * Float(duration), result.velocity)
    }

    private func alphaMultiplier(age: Float, lifetime: Float) -> Float {
        let lifetimeProgress = Swift.max(0, Swift.min(1, age / lifetime))
        var alpha: Float = 1
        if let fadeInFraction, fadeInFraction > 0 {
            alpha = Swift.min(alpha, lifetimeProgress / fadeInFraction)
        }
        if let fadeOutStartFraction, fadeOutStartFraction < 1 {
            alpha = Swift.min(alpha, (1 - lifetimeProgress) / (1 - fadeOutStartFraction))
        }
        return Swift.max(0, Swift.min(1, alpha))
    }

    private func appendSprite(
        center: SIMD3<Float>,
        halfSize: Float,
        right: SIMD3<Float>,
        up: SIMD3<Float>,
        color: SIMD4<Float>,
        firstUV: SIMD4<Float>,
        nextUV: SIMD4<Float>,
        blend: Float,
        into output: inout [Float]
    ) {
        let horizontal = right * halfSize
        let vertical = up * halfSize * spriteAspectRatio
        let bottomLeft = center - horizontal - vertical
        let bottomRight = center + horizontal - vertical
        let topRight = center + horizontal + vertical
        let topLeft = center - horizontal + vertical

        for (point,u,v) in [(bottomLeft,Float(0),Float(1)),(bottomRight,1,1),(topRight,1,0),
                            (bottomLeft,0,1),(topRight,1,0),(topLeft,0,0)] {
            output.append(contentsOf: [point.x,point.y,point.z,firstUV.x+u*firstUV.z,firstUV.y+v*firstUV.w,
                color.x,color.y,color.z,color.w,nextUV.x+u*nextUV.z,nextUV.y+v*nextUV.w,blend])
        }
    }

    private func appendRope(particle: Particle, age: Float, length: Float, segments: Int,
        halfWidth: Float, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>, color: SIMD4<Float>,
        uv: SIMD4<Float>, uvScale: Float, fadeAlpha: Bool, fadeSize: Bool, into output: inout [Float]) {
        guard length > 0, age > 0, halfWidth > 0 else { return }
        // The supported path is analytic and can be resampled without moving a
        // simulation cache backwards. Force-driven trajectories are rejected at
        // admission, so this never invents their history or replays pointer input.
        let span = min(length, age)
        var points: [SIMD3<Float>] = []
        for index in 0...segments {
            let sampleAge = age - span * Float(index) / Float(segments)
            var point = movementState(for: particle, age: sampleAge).position
            for oscillation in particle.oscillations where oscillation.target == .position {
                point += oscillation.wave(progress: sampleAge / particle.lifetime) * oscillation.amplitude * oscillation.mask
            }
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return }
            points.append(point)
        }
        let normal = simd_normalize(simd_cross(cameraRight, cameraUp))
        var sides: [SIMD3<Float>] = []
        for index in points.indices {
            let tangent = points[max(0,index-1)] - points[min(segments,index+1)]
            let side = simd_cross(tangent, normal), magnitude = simd_length(side)
            let width = halfWidth * (fadeSize ? 1 - Float(index) / Float(segments) : 1)
            sides.append((magnitude > 0.00001 ? side / magnitude : cameraRight) * width)
        }
        func append(_ index: Int, _ edge: Float) {
            let fraction = Float(index) / Float(segments)
            let point = points[index] + sides[index] * edge
            let u = uv.x + (edge + 1) * 0.5 * uv.z
            let v = uv.y + fraction * uvScale * uv.w
            let alpha = color.w * (fadeAlpha ? 1 - fraction : 1)
            output.append(contentsOf: [point.x,point.y,point.z,u,v,color.x,color.y,color.z,alpha,u,v,0])
        }
        for index in 0..<segments {
            if simd_length_squared(points[index] - points[index+1]) < 0.00000001 { continue }
            append(index, -1); append(index, 1); append(index+1, 1)
            append(index, -1); append(index+1, 1); append(index+1, -1)
        }
    }

    private static func parseEmitters(_ rawValue: Any?, orthographic: Bool, warnings: inout [String]) throws -> [Emitter] {
        guard let entries = rawValue as? [Any], !entries.isEmpty else {
            throw Error.malformed("Particle document must contain at least one emitter.")
        }
        guard entries.count <= maximumEmitterCount else { throw Error.unsupported("At most sixteen emitter declarations are accepted.") }
        var result: [Emitter] = []
        for (index, value) in entries.enumerated() {
            guard let entry = value as? [String: Any] else {
                throw Error.malformed("emitter[\(index)] must be an object.")
            }
            let name = try requiredName(entry, section: "emitter", index: index)
            let origin = try vector(entry["origin"], named: "emitter[\(index)].origin", default: .zero)
            if entry["origin"] == nil || entry["origin"] is NSNull {
                warnings.append("\(name) omits origin; using the particle-local origin (0, 0, 0). The serialized default is inferred.")
            }
            let rate = try number(entry["rate"], named: "\(name).rate", default: 10)
            guard rate >= 0, rate <= 1_000_000 else { throw Error.malformed("Native emitter rate must be in 0...1000000.") }
            if entry["rate"] == nil || entry["rate"] is NSNull {
                warnings.append("\(name) omits rate; using 10 particles/second, confirmed in the observed official Android EmitterBaseDefaults implementation. Windows parity remains unverified.")
            }
            let burst = try requiredWholeNumber(entry["instantaneous"] is NSNull ? 0 : entry["instantaneous"] ?? 0, named: "\(name).instantaneous")
            let duration = try number(entry["duration"], named: "\(name).duration", default: 0)
            let delay = try number(entry["delay"], named: "\(name).delay", default: 0)
            guard (0...1_000_000).contains(burst), (0...3600).contains(duration), (0...3600).contains(delay) else {
                throw Error.unsupported("Emitter burst, duration or delay exceeds native bounds.")
            }
            for field in ["speedmin", "speedmax", "controlpoint", "flags", "limitoneperframe"] {
                if let value = entry[field], !(value is NSNull), try number(value, named: "\(name).\(field)") != 0 {
                    throw Error.unsupported("Native emitter \(field) is not implemented for this configuration.")
                }
            }
            if burst > 0 || delay > 0 || duration > 0 {
                warnings.append("\(name): instantaneous births occur once at delay; continuous emission starts there and stops at duration (zero means unlimited). Burst count is floored after instance.count; exact simultaneous ordering remains unverified.")
            }
            switch name {
            case "boxrandom":
                let directions = try vector(entry["directions"], named: "boxrandom.directions", default: SIMD3(1,1,0))
                let minimum = try vector(entry["distancemin"], named: "boxrandom.distancemin", default: .zero)
                let maximum = try vector(entry["distancemax"], named: "boxrandom.distancemax", default: SIMD3(256,256,0))
                guard simd_reduce_min(minimum) >= 0, simd_reduce_min(maximum - minimum) >= 0,
                      simd_reduce_max(maximum) <= 1_000_000, simd_reduce_max(simd_abs(directions)) <= 1000 else {
                    throw Error.malformed("boxrandom distance vectors require 0 <= min <= max <= 1000000; direction magnitudes must be at most 1000.")
                }
                if entry["distancemax"] == nil || entry["distancemax"] is NSNull {
                    warnings.append("boxrandom uses the official observed 2D defaults: directions=(1,1,0), min=(0,0,0), max=(256,256,0), except where supplied. Native per-axis signed interval sampling has not been compared with Windows.")
                }
                result.append(Emitter(origin: origin, shape: .boxRandom(directions: directions, minimum: minimum, maximum: maximum),
                    rate: Double(rate), instantaneous: burst, delay: Double(delay), duration: Double(duration)))
            case "sphererandom":
                let directions = try vector(entry["directions"], named: "sphererandom.directions", default: SIMD3(1,1,0))
                if entry["directions"] == nil || entry["directions"] is NSNull {
                    warnings.append("sphererandom omits directions; using (1,1,0), observed in the official Android defaults. This projects the sampled sphere into X/Y; Windows parity remains unverified.")
                }
                guard simd_length_squared(directions) > 0 else {
                    throw Error.malformed("sphererandom directions must contain at least one non-zero axis.")
                }
                let minimum = try number(entry["distancemin"], named: "sphererandom.distancemin", default: 0)
                let maximum = try number(entry["distancemax"], named: "sphererandom.distancemax", default: orthographic ? 256 : 1)
                if entry["distancemin"] == nil || entry["distancemax"] == nil || entry["distancemin"] is NSNull || entry["distancemax"] is NSNull {
                    warnings.append("sphererandom omits a distance bound; reference defaults are min=0 and max=256 for 2D, 1 for 3D. Mapping the reference default flag to the scene's orthographic mode remains a compatibility inference.")
                }
                guard minimum >= 0, maximum >= 0, max(minimum, maximum) <= 1_000_000,
                      simd_reduce_max(simd_abs(directions)) <= 1000 else {
                    throw Error.malformed("sphererandom distance endpoints must be in 0...1000000; direction magnitudes must be at most 1000.")
                }
                if minimum > maximum {
                    warnings.append("sphererandom retains the authored negative distance span, as observed in the official Android parser. Large direction multipliers can move the remapped radius through zero; Windows behavior remains unverified.")
                }
                let cone = try number(entry["cone"], named: "sphererandom.cone", default: 0)
                guard abs(cone) <= 1_000_000 else { throw Error.unsupported("sphererandom cone magnitude exceeds the native numeric bound.") }
                let axialMinimum = -cosf(cone * Float.pi)
                if cone < 0 || cone > 1 {
                    warnings.append("sphererandom cone outside 0...1 uses the reference cosine mapping; editor and Windows behavior for such values remain unverified.")
                }
                if axialMinimum == 1 && directions.x == 0 {
                    warnings.append("sphererandom cone projects to zero; native particles remain at the emitter origin to avoid non-finite coordinates. Reference singular behavior is not reproduced.")
                }
                let sign = try vector(entry["sign"], named: "sphererandom.sign", default: .zero)
                if [sign.x, sign.y, sign.z].contains(where: { $0 != -1 && $0 != 0 && $0 != 1 }) {
                    warnings.append("sphererandom sign normally uses -1, 0 or 1. Other finite values use the observed Android sign mask and epsilon threshold; Windows behavior remains unverified.")
                }
                // REA's observed Android parser enables the sign mask only
                // when the sum of squared components exceeds FLT_EPSILON.
                // Normal editor values (-1, 0, 1) follow the public docs.
                let activeSigns: SIMD3<Float> = simd_length_squared(sign) > Float.ulpOfOne ? sign : .zero
                warnings.append("sphererandom follows the observed Android volume-ball/cone sample, axis scaling, sign folding and affine distance remap. Zero-length samples use a finite origin fallback. The native deterministic random stream, floating-point details and Windows pixels are not reproduced.")
                result.append(Emitter(
                    origin: origin,
                    shape: .sphereRandom(directions: directions, minimum: minimum, span: maximum - minimum, axialMinimum: axialMinimum, signs: activeSigns),
                    rate: Double(rate), instantaneous: burst, delay: Double(delay), duration: Double(duration)
                ))
            default:
                warnings.append("Unsupported emitter '\(name)' at emitter[\(index)] was ignored.")
            }
        }
        guard !result.isEmpty else {
            throw Error.unsupported("No supported boxrandom or sphererandom emitter is available.")
        }
        return result
    }

    private static func parseInitializers(_ rawValue: Any?, orthographic: Bool, warnings: inout [String]) throws -> (lifetime: ScalarRange, size: ScalarRange, velocity: VectorRange, color: ColorRange, rotations: [AngularRange], angularVelocities: [AngularRange], alpha: ScalarRange?, turbulentVelocities: [TurbulentVelocity]) {
        guard let entries = rawValue as? [Any] else {
            throw Error.malformed("Particle document must contain an initializer array.")
        }
        var lifetime: ScalarRange?
        var size: ScalarRange?
        var velocity: VectorRange?
        var turbulentVelocities: [TurbulentVelocity] = []
        var color: ColorRange?
        var rotations: [AngularRange] = [], angularVelocities: [AngularRange] = []
        var alpha: ScalarRange?
        guard entries.count <= 128 else { throw Error.unsupported("At most 128 particle initializers are supported.") }

        for (index, value) in entries.enumerated() {
            guard let entry = value as? [String: Any] else {
                throw Error.malformed("initializer[\(index)] must be an object.")
            }
            let name = try requiredName(entry, section: "initializer", index: index)
            switch name {
            case "lifetimerandom":
                guard lifetime == nil else { throw Error.malformed("Duplicate lifetimerandom initializer.") }
                lifetime = ScalarRange(
                    try number(entry["min"], named: "lifetimerandom.min"),
                    try number(entry["max"], named: "lifetimerandom.max"),
                    exponent: try exponent(entry, name: name, warnings: &warnings)
                )
            case "sizerandom":
                guard size == nil else { throw Error.malformed("Duplicate sizerandom initializer.") }
                size = ScalarRange(
                    try number(entry["min"], named: "sizerandom.min"),
                    try number(entry["max"], named: "sizerandom.max"),
                    exponent: try exponent(entry, name: name, warnings: &warnings)
                )
            case "velocityrandom":
                guard velocity == nil else { throw Error.malformed("Duplicate velocityrandom initializer.") }
                velocity = VectorRange(
                    try vector(entry["min"], named: "velocityrandom.min"),
                    try vector(entry["max"], named: "velocityrandom.max"),
                    exponent: try exponent(entry, name: name, warnings: &warnings)
                )
            case "turbulentvelocityrandom":
                turbulentVelocities.append(try turbulentVelocity(entry, orthographic: orthographic))
                guard turbulentVelocities.count <= 16 else { throw Error.unsupported("At most sixteen turbulent velocity initializers are supported.") }
            case "colorrandom":
                guard color == nil else { throw Error.malformed("Duplicate colorrandom initializer.") }
                let power = try exponent(entry, name: name, warnings: &warnings)
                let range = try colorRange(minimum: entry["min"], maximum: entry["max"], name: "colorrandom", exponent: power, warnings: &warnings)
                color = range
            case "alpharandom":
                guard alpha == nil else { throw Error.malformed("Duplicate alpharandom initializer.") }
                let lower = entry["min"] ?? 0.05
                let upper = entry["max"] ?? 1.0
                if entry["min"] == nil || entry["max"] == nil {
                    warnings.append("alpharandom omits a bound; using reference defaults min=0.05 and max=1 for omitted fields.")
                }
                let range = ScalarRange(try number(lower, named: "alpharandom.min"), try number(upper, named: "alpharandom.max"), exponent: try exponent(entry, name: name, warnings: &warnings))
                guard range.lower >= 0, range.upper <= 1 else { throw Error.malformed("alpharandom must be in 0...1.") }
                alpha = range
            case "rotationrandom", "angularvelocityrandom":
                let range = try angularRange(entry, name: name, warnings: &warnings)
                if name == "rotationrandom" { rotations.append(range) } else { angularVelocities.append(range) }
                guard rotations.count <= 16, angularVelocities.count <= 16 else { throw Error.unsupported("At most sixteen initializers for each angular attribute are supported.") }
            default:
                warnings.append("Unsupported initializer '\(name)' at initializer[\(index)] was ignored.")
            }
        }

        let resolvedLifetime = lifetime ?? {
            warnings.append("No lifetimerandom initializer was present; using a one-second particle lifetime.")
            return ScalarRange(1, 1)
        }()
        let resolvedSize = size ?? {
            warnings.append("No sizerandom initializer was present; using size 1.")
            return ScalarRange(1, 1)
        }()
        let resolvedVelocity = velocity ?? {
            if turbulentVelocities.isEmpty { warnings.append("No velocity initializer was present; using zero velocity.") }
            return VectorRange(.zero, .zero)
        }()
        let resolvedColor = color ?? {
            warnings.append("No colorrandom initializer was present; using opaque white.")
            return ColorRange(SIMD4<Float>(1, 1, 1, 1), SIMD4<Float>(1, 1, 1, 1))
        }()
        if rotations.count > 1 || angularVelocities.count > 1 {
            warnings.append("Repeated angular initializers are sampled in file order and the last assignment wins; this attribute ordering has not been compared with Windows.")
        }
        if !rotations.isEmpty || !angularVelocities.isEmpty {
            warnings.append("Native sprite rotation uses XYZ Euler angles in radians, composed Rz*Ry*Rx in the billboard basis; angular velocities use radians per simulation second. Units and Euler order remain compatibility inferences.")
        }
        if rotations.isEmpty { rotations = [.planar(ScalarRange(0, 0))] }
        if !turbulentVelocities.isEmpty {
            warnings.append("turbulentvelocityrandom adds noise-rotated forward velocity around the normalized right axis. Defaults and 1D noise equation were traced with REA in the official Android library. Native independent random draws and nonnegative particle birth-clock time approximate the original shared random stream and frame time; prewarm and rate changes are not Windows-identical. Audio-modulated phase is rejected.")
        }
        return (resolvedLifetime, resolvedSize, resolvedVelocity, resolvedColor, rotations, angularVelocities, alpha, turbulentVelocities)
    }

    private static func turbulentVelocity(_ entry: [String: Any], orthographic: Bool) throws -> TurbulentVelocity {
        let allowed: Set<String> = ["id", "name", "scale", "timescale", "offset", "phasemin", "phasemax", "speedmin", "speedmax", "forward", "right",
            "audioprocessingmode", "audioprocessingbounds", "audioprocessingexponent", "audioprocessingfrequencystart", "audioprocessingfrequencyend"]
        guard Set(entry.keys).isSubset(of: allowed) else {
            throw Error.unsupported("turbulentvelocityrandom contains an undecoded option.")
        }
        guard try number(entry["audioprocessingmode"], named: "turbulentvelocityrandom.audioprocessingmode", default: 0) == 0 else {
            throw Error.unsupported("Audio-modulated turbulent initial velocity is not implemented.")
        }
        let scale = try number(entry["scale"], named: "turbulentvelocityrandom.scale", default: 1)
        let timeScale = try number(entry["timescale"], named: "turbulentvelocityrandom.timescale", default: 1)
        let offset = try number(entry["offset"], named: "turbulentvelocityrandom.offset", default: 0)
        let phase = ScalarRange(try number(entry["phasemin"], named: "turbulentvelocityrandom.phasemin", default: 0),
            try number(entry["phasemax"], named: "turbulentvelocityrandom.phasemax", default: 0.1))
        let speed = ScalarRange(try number(entry["speedmin"], named: "turbulentvelocityrandom.speedmin", default: orthographic ? 100 : 0.5),
            try number(entry["speedmax"], named: "turbulentvelocityrandom.speedmax", default: orthographic ? 250 : 1))
        let forward = try vector(entry["forward"], named: "turbulentvelocityrandom.forward", default: SIMD3(0,1,0))
        let normal = try vector(entry["right"], named: "turbulentvelocityrandom.right", default: SIMD3(0,0,1))
        guard abs(scale) <= 1000, abs(timeScale) <= 1000, abs(offset) <= 10_000,
              max(abs(phase.lower), abs(phase.upper)) <= 1_000_000,
              max(abs(speed.lower), abs(speed.upper)) <= 1_000_000,
              simd_reduce_max(simd_abs(forward)) <= 1000, simd_reduce_max(simd_abs(normal)) <= 1000,
              simd_length_squared(normal) >= 0.00000001 else {
            throw Error.unsupported("Turbulent initial velocity exceeds native bounds or has a zero normal.")
        }
        return TurbulentVelocity(scale: scale, timeScale: timeScale, offset: offset, speed: speed, phase: phase,
            forward: forward, normal: simd_normalize(normal))
    }

    private static func exponent(_ entry: [String: Any], name: String, warnings: inout [String]) throws -> Float {
        let value = try number(entry["exponent"], named: name + ".exponent", default: 1)
        guard (0...1000).contains(value) else { throw Error.unsupported("Native initializer exponent must be in 0...1000.") }
        if value != 1 { warnings.append("\(name).exponent uses pow(uniform, \(value)) independently per component; the documented bias is preserved, but the exact Windows random distribution is unverified.") }
        return value
    }

    private static func angularRange(_ entry: [String: Any], name: String, warnings: inout [String]) throws -> AngularRange {
        func isVector(_ value: Any?) -> Bool {
            if let array = value as? [Any] { return array.count != 1 }
            if let string = value as? String { return string.split(whereSeparator: { $0.isWhitespace || $0 == "," }).count > 1 }
            return false
        }
        let power = try exponent(entry, name: name, warnings: &warnings)
        let defaultMaximum: Float = name == "rotationrandom" ? 2 * .pi : 0
        if entry["min"] == nil || entry["min"] is NSNull || entry["max"] == nil || entry["max"] is NSNull {
            warnings.append("\(name) omits a bound; native defaults are min=(0,0,0), max=(0,0,\(defaultMaximum)). Serialized defaults are inferred.")
        }
        if isVector(entry["min"]) || isVector(entry["max"]) {
            let low = try vector(entry["min"], named: name + ".min", default: .zero)
            let high = try vector(entry["max"], named: name + ".max", default: SIMD3(0,0,defaultMaximum))
            guard simd_reduce_max(abs(low)) <= 1_000_000, simd_reduce_max(abs(high)) <= 1_000_000 else { throw Error.unsupported("Angular bounds exceed native numeric limits.") }
            return .spatial(VectorRange(low, high, exponent: power))
        }
        let low = try number(entry["min"], named: name + ".min", default: 0)
        let high = try number(entry["max"], named: name + ".max", default: defaultMaximum)
        guard abs(low) <= 1_000_000, abs(high) <= 1_000_000 else { throw Error.unsupported("Angular bounds exceed native numeric limits.") }
        return .planar(ScalarRange(low, high, exponent: power))
    }

    private static func parseControlPointForces(document: [String: Any], instance: [String: Any], orthographic: Bool, warnings: inout [String]) throws -> [ControlPointForce] {
        let operators = document["operator"] as? [[String: Any]] ?? []
        let entries = operators.filter { ($0["name"] as? String)?.lowercased() == "controlpointattract" }
        guard entries.count <= 8 else { throw Error.unsupported("At most eight control-point forces are supported.") }
        guard !entries.isEmpty else { return [] }
        let controlPoints = document["controlpoint"] as? [[String: Any]] ?? []
        guard controlPoints.count <= 8 else { throw Error.malformed("Too many particle control points.") }
        var result: [ControlPointForce] = []
        for entry in entries {
            let index = try requiredWholeNumber(entry["controlpoint"] ?? 0, named: "controlpointattract.controlpoint")
            guard (0..<8).contains(index) else { throw Error.malformed("Control point index must be in 0...7.") }
            let matches = controlPoints.filter { ($0["id"] as? NSNumber)?.intValue == index }
            guard matches.count <= 1 else { throw Error.malformed("Duplicate control-point ID.") }
            if index != 0, matches.isEmpty {
                warnings.append("controlpointattract references missing point \(index); force is not applied."); continue
            }
            let point = matches.first ?? [:]
            let pointFlags = try requiredWholeNumber(point["flags"] ?? 0, named: "control point flags")
            if index != 0, pointFlags != 0 && pointFlags != 1 {
                warnings.append("controlpointattract point \(index) uses unimplemented flags \(pointFlags); world-space/parent copying is not applied."); continue
            }
            let pointFields: Set<String> = ["id", "flags", "offset", "locktopointer"]
            if index != 0, !Set(point.keys).isSubset(of: pointFields) {
                warnings.append("controlpointattract point \(index) has unimplemented control-point fields; that force is not applied."); continue
            }
            if let value = point["locktopointer"], !(value is Bool) {
                throw Error.malformed("Control point locktopointer must be a Boolean.")
            }
            let pointerRequested = point["locktopointer"] as? Bool ?? (pointFlags == 1)
            let followsPointer = index != 0 && pointerRequested
            if index == 0, pointerRequested || pointFlags != 0 {
                warnings.append("Control point 0 remains the particle-system origin; its pointer/world flags are not applied.")
            }
            if let explicit = point["locktopointer"] as? Bool, explicit != (pointFlags == 1), index != 0 {
                warnings.append("Control point \(index) has conflicting flags and locktopointer; the explicit Boolean takes precedence.")
            }
            let allowed: Set<String> = ["id","name","controlpoint","origin","scale","threshold"]
            if !Set(entry.keys).isSubset(of: allowed) {
                warnings.append("controlpointattract has additional unimplemented options; that force is not applied."); continue
            }
            let base = index == 0 ? SIMD3<Float>.zero : try vector(instance["controlpoint\(index)"] ?? point["offset"], named: "control point offset", default: .zero)
            let offset = try vector(entry["origin"], named: "controlpointattract.origin", default: .zero)
            let scale = try number(entry["scale"] ?? (orthographic ? 512 : 20), named: "controlpointattract.scale")
            let distance = try number(entry["threshold"] ?? (orthographic ? 512 : 5), named: "controlpointattract.threshold")
            if entry["scale"] == nil || entry["threshold"] == nil {
                warnings.append("controlpointattract omits scale or threshold; reference defaults are 512/512 for 2D and 20/5 for 3D. Mapping the reference flag to an orthographic scene is a compatibility inference; flags and delete-threshold semantics remain incomplete.")
            }
            guard abs(scale) <= 1_000_000, distance > 0, distance <= 1_000_000,
                  simd_reduce_max(abs(base + offset)) <= 1_000_000 else { throw Error.unsupported("Control-point force exceeds the native numeric bounds.") }
            result.append(ControlPointForce(point: base + offset, followsPointer: followsPointer, strength: scale, distance: distance))
        }
        if !result.isEmpty {
            warnings.append("controlpointattract uses simulation-space distances, linear falloff and 1/120-second midpoint field steps with analytic drag. World-space static points use the authored transform at the force sample time. Instance offsets take precedence. Exact force units, falloff and operator order remain native compatibility inferences.")
        }
        if result.contains(where: { $0.followsPointer }) {
            warnings.append("Pointer control points use explicit locktopointer or the observed legacy flags=1 mapping. The cursor is projected onto the simulation Z=0 plane: layer-local for local systems, scene-world for world systems, with current view/parallax. History is causal and bounded to 4096 samples; unavailable, pre-roll, expired or stale inputs disable that force. Other control-point flag bits, parent copying and dynamic offsets remain unsupported.")
        }
        return result
    }

    private static func parseTurbulence(_ rawValue: Any?, warnings: inout [String]) throws -> [Turbulence] {
        let entries = (rawValue as? [[String: Any]] ?? []).filter { ($0["name"] as? String)?.lowercased() == "turbulence" }
        guard entries.count <= 4 else { throw Error.unsupported("At most four turbulence operators per particle system are supported.") }
        var fields: [Turbulence] = []
        let supported: Set<String> = ["id", "name", "scale", "timescale", "mask", "speedmin", "speedmax", "phasemin", "phasemax"]
        for entry in entries {
            let unknown = Set(entry.keys).subtracting(supported).sorted()
            guard unknown.isEmpty else {
                warnings.append("turbulence has unimplemented options (\(unknown.joined(separator: ", "))); that field is not applied. Audio response and operator blending are not silently discarded.")
                continue
            }
            guard entry["speedmin"] != nil, entry["speedmax"] != nil else {
                warnings.append("turbulence omits a speed endpoint; its undocumented speed default is not guessed and that field is not applied.")
                continue
            }
            let scale = try number(entry["scale"], named: "turbulence.scale", default: 0.01)
            let timeScale = try number(entry["timescale"], named: "turbulence.timescale", default: 1)
            let mask = try vector(entry["mask"], named: "turbulence.mask", default: SIMD3(1, 1, 0))
            let speed = ScalarRange(try number(entry["speedmin"], named: "turbulence.speedmin"),
                try number(entry["speedmax"], named: "turbulence.speedmax"))
            let phase = ScalarRange(try number(entry["phasemin"], named: "turbulence.phasemin", default: 0),
                try number(entry["phasemax"], named: "turbulence.phasemax", default: 2 * Float.pi))
            guard abs(scale) <= 1000, abs(timeScale) <= 1000, simd_reduce_max(abs(mask)) <= 1000,
                  speed.lower >= 0, speed.upper <= 100_000,
                  abs(phase.lower) <= 1_000_000, abs(phase.upper) <= 1_000_000 else {
                throw Error.unsupported("turbulence exceeds native bounds: scale/time/mask ±1000, speed 0...100000, phase ±1000000.")
            }
            fields.append(Turbulence(scale: scale, timeScale: timeScale, mask: mask, speed: speed, phase: phase))
            let defaults = ["scale", "timescale", "mask", "phasemin", "phasemax"].filter { entry[$0] == nil }
            if !defaults.isEmpty {
                warnings.append("turbulence omitted \(defaults.joined(separator: ", ")); native defaults are scale=0.01, timescale=1, mask=(1,1,0), phase=0...2π. These defaults are compatibility inferences.")
            }
        }
        if !fields.isEmpty {
            warnings.append("turbulence uses a self-authored periodic 3D value-noise velocity field with quintic interpolation and independent per-particle speed/phase. Field advection is sampled at 1/120-second midpoints alongside gravity/drag/control-point forces. Noise formula, phase units, defaults, drag composition and operator order are not matched to Windows.")
        }
        return fields
    }

    private static func parseOperators(_ rawValue: Any?, warnings: inout [String]) throws -> (gravity: SIMD3<Float>, drag: Float, oscillations: [Oscillation], fadeInFraction: Float?, fadeOutStartFraction: Float?, hasMovement: Bool, angularMovement: AngularMovement?, changes: [LifetimeChange]) {
        guard let entries = rawValue as? [Any] else {
            throw Error.malformed("Particle document must contain an operator array.")
        }
        var gravity = SIMD3<Float>.zero
        var drag: Float = 0
        var oscillations: [Oscillation] = []
        var hasMovement = false
        var hasAlphaFade = false
        var fadeInFraction: Float?
        var fadeOutStartFraction: Float?
        var angularMovement: AngularMovement?
        var changes: [LifetimeChange] = []
        guard entries.count <= 128 else { throw Error.unsupported("At most 128 particle operators are supported.") }

        for (index, value) in entries.enumerated() {
            guard let entry = value as? [String: Any] else {
                throw Error.malformed("operator[\(index)] must be an object.")
            }
            let name = try requiredName(entry, section: "operator", index: index)
            switch name {
            case "movement":
                guard !hasMovement else { throw Error.malformed("Duplicate movement operator.") }
                gravity = try vector(entry["gravity"], named: "movement.gravity", default: .zero)
                drag = try number(entry["drag"], named: "movement.drag", default: 0)
                guard (0...1000).contains(drag) else { throw Error.unsupported("Native linear drag must be in 0...1000.") }
                hasMovement = true
            case "controlpointattract", "turbulence":
                break // Parsed separately with the field-specific data.
            case "angularmovement":
                let supported: Set<String> = ["id", "name", "force", "drag"]
                guard Set(entry.keys).isSubset(of: supported) else {
                    warnings.append("angularmovement has additional options, including potentially operator blending; that angular operator is not applied."); continue
                }
                guard angularMovement == nil else { throw Error.unsupported("Multiple angularmovement operators are not implemented.") }
                let force = try vector(entry["force"], named: "angularmovement.force", default: .zero)
                let angularDrag = try number(entry["drag"], named: "angularmovement.drag", default: 0)
                guard simd_reduce_max(abs(force)) <= 1_000_000, (0...1000).contains(angularDrag) else { throw Error.unsupported("Native angular force is bounded to ±1000000 and drag to 0...1000; negative drag is not implemented.") }
                angularMovement = AngularMovement(force: force, drag: angularDrag)
                warnings.append("angularmovement integrates constant force and linear drag analytically on XYZ Euler angles. Missing force/drag use zero. Operator blending and exact Windows integration order remain unsupported.")
            case "sizechange", "alphachange", "colorchange":
                let supported: Set<String> = ["id", "name", "starttime", "endtime", "startvalue", "endvalue"]
                guard Set(entry.keys).isSubset(of: supported) else {
                    warnings.append("\(name) has additional options; that lifetime-change operator is not applied."); continue
                }
                guard changes.count < 16 else { throw Error.unsupported("At most sixteen particle lifetime changes are supported.") }
                let startTime = try number(entry["starttime"], named: name + ".starttime", default: 0)
                let endTime = try number(entry["endtime"], named: name + ".endtime", default: 1)
                guard startTime >= 0, endTime >= startTime, endTime <= 1 else { throw Error.malformed("\(name) requires 0 <= starttime <= endtime <= 1.") }
                let start: SIMD3<Float>, end: SIMD3<Float>
                if name == "colorchange" {
                    guard entry["startvalue"] != nil, entry["endvalue"] != nil else {
                        warnings.append("colorchange omits a color endpoint; the unknown color default is not applied."); continue
                    }
                    start = try vector(entry["startvalue"], named: name + ".startvalue")
                    end = try vector(entry["endvalue"], named: name + ".endvalue")
                } else {
                    start = SIMD3(repeating: try number(entry["startvalue"], named: name + ".startvalue", default: 1))
                    end = SIMD3(repeating: try number(entry["endvalue"], named: name + ".endvalue", default: 0))
                }
                let upper: Float = name == "alphachange" ? 1 : (name == "colorchange" ? 16 : 1000)
                guard simd_reduce_min(start) >= 0, simd_reduce_min(end) >= 0,
                      simd_reduce_max(start) <= upper, simd_reduce_max(end) <= upper else { throw Error.unsupported("\(name) endpoints exceed native 0...\(upper) bounds.") }
                changes.append(LifetimeChange(target: name == "colorchange" ? .color : (name == "sizechange" ? .size : .alpha), start: start, end: end, startTime: startTime, endTime: endTime))
                warnings.append("\(name) linearly interpolates over normalized lifetime; size/alpha multiply the initial value, color assigns RGB before the instance tint. Missing times use 0...1; missing size/alpha values use 1...0. Defaults and operation composition remain compatibility inferences.")
            case "oscillateposition", "oscillatealpha", "oscillatesize":
                guard oscillations.count < 8 else { throw Error.unsupported("At most eight native particle oscillators are supported.") }
                let frequency = ScalarRange(
                    try number(entry["frequencymin"], named: "\(name).frequencymin", default: 1),
                    try number(entry["frequencymax"], named: "\(name).frequencymax", default: 1))
                let scale = ScalarRange(
                    try number(entry["scalemin"], named: "\(name).scalemin", default: 0),
                    try number(entry["scalemax"], named: "\(name).scalemax", default: 1))
                let phase = ScalarRange(
                    try number(entry["phasemin"], named: "\(name).phasemin", default: 0),
                    try number(entry["phasemax"], named: "\(name).phasemax", default: 2 * Float.pi))
                let mask = try vector(entry["mask"], named: "\(name).mask", default: SIMD3(1, 1, 0))
                guard frequency.lower >= 0, frequency.upper <= 10_000,
                      abs(scale.lower) <= 1_000_000, abs(scale.upper) <= 1_000_000,
                      abs(phase.lower) <= 1_000_000, abs(phase.upper) <= 1_000_000,
                      simd_reduce_max(abs(mask)) <= 1000 else { throw Error.unsupported("\(name) exceeds native oscillator bounds.") }
                if name == "oscillatealpha", scale.lower < 0 || scale.upper > 1 {
                    throw Error.unsupported("Native oscillatealpha scale bounds must be in 0...1.")
                }
                if name == "oscillatesize", scale.lower < 0 || scale.upper > 1000 {
                    throw Error.unsupported("Native oscillatesize scale bounds must be in 0...1000.")
                }
                oscillations.append(Oscillation(target: name == "oscillatealpha" ? .alpha : (name == "oscillatesize" ? .size : .position), frequency: frequency, scale: scale, phase: phase, mask: mask))
                warnings.append("\(name) uses a native sine over normalized lifetime with stable per-particle random phase/frequency; position adds a random amplitude per axis, alpha/size interpolate scale bounds. Missing phase defaults to 0...2π, position mask to X/Y, scale to 0...1. This is a compatibility approximation.")
            case "alphafade":
                guard !hasAlphaFade else { throw Error.malformed("Duplicate alphafade operator.") }
                hasAlphaFade = true
                if entry["fadeintime"] != nil {
                    let value = try number(entry["fadeintime"], named: "alphafade.fadeintime")
                    guard (0...1).contains(value) else { throw Error.malformed("alphafade.fadeintime must be a lifetime fraction in 0...1.") }
                    fadeInFraction = value
                }
                if entry["fadeouttime"] != nil {
                    let value = try number(entry["fadeouttime"], named: "alphafade.fadeouttime")
                    guard (0...1).contains(value) else { throw Error.malformed("alphafade.fadeouttime must be a lifetime fraction in 0...1.") }
                    fadeOutStartFraction = value
                }
            default:
                warnings.append("Unsupported operator '\(name)' at operator[\(index)] was ignored.")
            }
        }
        return (gravity, drag, oscillations, fadeInFraction, fadeOutStartFraction, hasMovement, angularMovement, changes)
    }

    private static func parseRenderer(_ rawValue: Any?, warnings: inout [String]) throws -> Renderer {
        guard let entries = rawValue as? [Any] else {
            warnings.append("Particle document has no renderer array. Wallpaper Engine documents Sprite as the default renderer, so the native host assumes a sprite renderer; this serialized-default behavior is not independently verified.")
            return .sprite(orientation: .screen, axis: SIMD3(0, 1, 0), independent: false)
        }
        guard !entries.isEmpty else {
            throw Error.malformed("Particle renderer array must not be empty.")
        }
        var selected: Renderer?
        guard entries.count <= 16 else { throw Error.unsupported("At most sixteen particle renderer declarations are accepted.") }
        for (index, value) in entries.enumerated() {
            guard let entry = value as? [String: Any] else {
                throw Error.malformed("renderer[\(index)] must be an object.")
            }
            let name = try requiredName(entry, section: "renderer", index: index)
            guard name == "sprite" || name == "spritetrail" || name == "ropetrail" else {
                warnings.append("Unsupported renderer '\(name)' at renderer[\(index)] does not contribute vertices.")
                continue
            }
            guard selected == nil else {
                warnings.append("Additional particle renderer \(name) is not composed; the first supported renderer is used."); continue
            }
            let supported: Set<String> = name == "sprite" ? ["id", "name", "flags", "orientation", "axis"] : name == "spritetrail"
                ? ["id", "name", "length", "minlength", "maxlength"]
                : ["id", "name", "length", "segments", "subdivision", "uvscale", "uvscrolling", "fadealpha", "fadesize"]
            guard Set(entry.keys).isSubset(of: supported) else {
                warnings.append("\(name) has unimplemented orientation/worldspace options; that renderer is not applied."); continue
            }
            if name == "sprite" {
                let modeName = (entry["orientation"] == nil || entry["orientation"] is NSNull)
                    ? "screen" : (entry["orientation"] as? String ?? "")
                guard let mode = NativeParticleOrientation.Mode(rawValue: modeName) else {
                    warnings.append("sprite orientation '\(modeName)' is not understood; that renderer is not applied."); continue
                }
                let requestedAxis = try vector(entry["axis"], named: "sprite.axis", default: SIMD3(0, 1, 0))
                // RendererBaseDefaults normalizes the axis, substituting Y for
                // a zero vector. Screen mode ignores the stored axis.
                let axis = requestedAxis == .zero ? SIMD3<Float>(0, 1, 0) : requestedAxis
                if mode == .screen, entry["axis"] != nil {
                    warnings.append("sprite axis is inactive for screen orientation, as observed in the official Android renderer. Windows orientation parity remains unverified.")
                }
                var independent = false
                if let rawFlags = entry["flags"] {
                    let flags = try requiredWholeNumber(rawFlags, named: "sprite.flags")
                    guard flags == 0 || flags == 1 else {
                        warnings.append("sprite flags \(flags) are not understood; that renderer is not applied."); continue
                    }
                    independent = flags == 1
                }
                if mode != .screen || independent {
                    warnings.append("sprite orientation uses the reference-backed axis or world-Y upright branch with the renderer worldspace flag, current camera and draw transform. Non-uniform scale, degenerate transforms, child orientation history and Windows visual parity remain unverified. The frame diagnostic reports fallback when the requested basis cannot be represented.")
                }
                selected = .sprite(orientation: mode, axis: axis, independent: independent)
            }
            else if name == "spritetrail" {
                let length = try number(entry["length"], named: "spritetrail.length", default: 1)
                let minimum = try number(entry["minlength"], named: "spritetrail.minlength", default: 1)
                let maximum = try number(entry["maxlength"], named: "spritetrail.maxlength", default: 1000)
                guard length >= 0, length <= 1000, minimum >= 0, maximum >= minimum, maximum <= 10000 else { throw Error.unsupported("Native sprite-trail length bounds are invalid or exceed supported limits.") }
                selected = .spriteTrail(length: length, minimum: minimum, maximum: maximum)
                warnings.append("spritetrail aligns the sprite's Y axis with projected velocity and scales its length by clamp(speed*length,minlength,maxlength); size sets the width. Missing length/min/max use 1/1/1000. Centering, units and exact Windows trail projection remain unverified; this is not a rope trail.")
            } else {
                let length = try number(entry["length"], named: "ropetrail.length", default: 1)
                let segments = try requiredWholeNumber(entry["segments"] ?? 4, named: "ropetrail.segments")
                let subdivision = try requiredWholeNumber(entry["subdivision"] ?? 1, named: "ropetrail.subdivision")
                let scale = try number(entry["uvscale"], named: "ropetrail.uvscale", default: 1)
                let scrolling = try number(entry["uvscrolling"], named: "ropetrail.uvscrolling", default: 0)
                let fadeAlpha = try number(entry["fadealpha"], named: "ropetrail.fadealpha", default: 0)
                let fadeSize = try number(entry["fadesize"], named: "ropetrail.fadesize", default: 0)
                guard (0...30).contains(length), (1...64).contains(segments), (1...8).contains(subdivision),
                      segments * subdivision <= 128, (0...64).contains(scale), scrolling == 0,
                      [Float(0),1].contains(fadeAlpha), [Float(0),1].contains(fadeSize) else {
                    throw Error.unsupported("Rope trail settings exceed native bounds or request unimplemented UV scrolling.")
                }
                selected = .ropeTrail(length: length, segments: segments, subdivision: subdivision,
                    uvScale: scale, fadeAlpha: fadeAlpha != 0, fadeSize: fadeSize != 0)
                warnings.append("ropetrail builds a joined strip along each particle's analytic trajectory, interpreting length as seconds. Defaults length=1, segments=4, subdivision=1, uvscale=1 and fade flags=false were found in the official Android library. Time units, interpolation, width history and UV direction remain compatibility inferences; no Windows parity is claimed.")
            }
        }
        guard let selected else { throw Error.unsupported("No supported sprite, sprite-trail or rope-trail renderer is available.") }
        return selected
    }

    private static func requiredName(_ object: [String: Any], section: String, index: Int) throws -> String {
        guard let raw = object["name"] as? String else {
            throw Error.malformed("\(section)[\(index)] must have a string name.")
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { throw Error.malformed("\(section)[\(index)] has an empty name.") }
        return name
    }

    private static func requiredWholeNumber(_ rawValue: Any?, named name: String) throws -> Int {
        let value = try number(rawValue, named: name)
        guard let integer = Int(exactly: value) else {
            throw Error.malformed("\(name) must be a whole number.")
        }
        return integer
    }

    private static func instanceFactor(_ object: [String: Any], name: String, maximum: Float = 1000, allowZero: Bool = true) throws -> Float {
        let value = try number(object[name], named: "instance.\(name)", default: 1)
        guard value >= 0, value <= maximum, allowZero || value > 0 else {
            throw Error.unsupported("Native instance.\(name) must be \(allowZero ? "non-negative" : "positive") and at most \(maximum).")
        }
        return value
    }

    private static func number(_ rawValue: Any?, named name: String, default defaultValue: Float? = nil) throws -> Float {
        if rawValue == nil || rawValue is NSNull {
            if let defaultValue { return defaultValue }
            throw Error.malformed("Missing numeric value for \(name).")
        }
        if let number = rawValue as? NSNumber {
            let value = number.floatValue
            guard value.isFinite else { throw Error.malformed("\(name) must be finite.") }
            return value
        }
        if let string = rawValue as? String, let value = Float(string.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite {
            return value
        }
        throw Error.malformed("\(name) must be a finite number.")
    }

    private static func vector(_ rawValue: Any?, named name: String, default defaultValue: SIMD3<Float>? = nil) throws -> SIMD3<Float> {
        if rawValue == nil || rawValue is NSNull, let defaultValue { return defaultValue }
        let components: [Float]
        if let string = rawValue as? String {
            components = try string.split(whereSeparator: { $0.isWhitespace || $0 == "," }).enumerated().map {
                try number(String($0.element), named: "\(name)[\($0.offset)]")
            }
        } else if let array = rawValue as? [Any] {
            components = try array.enumerated().map { index, value in
                try number(value, named: "\(name)[\(index)]")
            }
        } else if let vector = rawValue as? [String: Any], Set(vector.keys) == Set(["x", "y", "z"]) {
            components = try ["x", "y", "z"].map { try number(vector[$0], named: "\(name).\($0)") }
        } else {
            throw Error.malformed("\(name) must be a three-component vector string or array.")
        }
        guard components.count == 3, components.allSatisfy(\.isFinite) else {
            throw Error.malformed("\(name) must have exactly three finite components.")
        }
        return SIMD3<Float>(components[0], components[1], components[2])
    }

    private static func colorRange(minimum: Any?, maximum: Any?, name: String, exponent: Float = 1, warnings: inout [String]) throws -> ColorRange {
        let low = try color(minimum, named: "\(name).min")
        let high: SIMD4<Float>
        if maximum == nil || maximum is NSNull {
            let white: Float = Swift.max(low.x, low.y, low.z) > 1 ? 255 : 1
            high = SIMD4(white, white, white, 1)
            warnings.append("\(name) omits max; using opaque white in the same RGB units as min. This serialized default is inferred from the observed star/flare assets.")
        } else { high = try color(maximum, named: "\(name).max") }
        let greatestRGB = Swift.max(low.x, low.y, low.z, high.x, high.y, high.z)
        let scale: Float
        if greatestRGB <= 1 {
            scale = 1
        } else if greatestRGB <= 255 {
            scale = 255
            warnings.append("\(name) RGB values above 1 are normalized from an inferred 0...255 range.")
        } else {
            throw Error.unsupported("\(name) RGB values above 255 are not supported by the native sprite renderer.")
        }
        func normalize(_ value: SIMD4<Float>) -> SIMD4<Float> {
            let alpha = value.w > 1 ? value.w / 255 : value.w
            return SIMD4<Float>(value.x / scale, value.y / scale, value.z / scale, alpha)
        }
        return ColorRange(normalize(low), normalize(high), exponent: exponent)
    }

    private static func color(_ rawValue: Any?, named name: String) throws -> SIMD4<Float> {
        let values: [Float]
        if let string = rawValue as? String {
            values = try string.split(whereSeparator: { $0.isWhitespace || $0 == "," }).enumerated().map {
                try number(String($0.element), named: "\(name)[\($0.offset)]")
            }
        } else if let array = rawValue as? [Any] {
            values = try array.enumerated().map { index, value in
                try number(value, named: "\(name)[\(index)]")
            }
        } else {
            throw Error.malformed("\(name) must be an RGB or RGBA vector string or array.")
        }
        guard (values.count == 3 || values.count == 4), values.allSatisfy(\.isFinite) else {
            throw Error.malformed("\(name) must have three or four finite color components.")
        }
        return SIMD4<Float>(values[0], values[1], values[2], values.count == 4 ? values[3] : 1)
    }

    private static func documentSeed(_ document: [String: Any], instance: [String: Any]) -> UInt64 {
        // Sorting JSON keys makes the seed independent of dictionary iteration order.
        let data = (try? JSONSerialization.data(withJSONObject: ["document": document, "instance": instance], options: [.sortedKeys])) ?? Data()
        return data.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
    }

    private static func particleSeed(base: UInt64, emitter: Int, emission: Int) -> UInt64 {
        var value = base
        value ^= UInt64(truncatingIfNeeded: emitter) &* 0x9E37_79B9_7F4A_7C15
        value ^= UInt64(truncatingIfNeeded: emission) &* 0xBF58_476D_1CE4_E5B9
        value ^= value >> 30
        value &*= 0x94D0_49BB_1331_11EB
        return value ^ (value >> 27)
    }
}
