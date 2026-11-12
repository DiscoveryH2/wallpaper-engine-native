import Foundation
import simd

/// One direct child declaration, with a separate material and bounded instances.
/// Parsing is done once. Child simulation never advances its parent's pool.
final class SceneParticleChildren {
    private enum EventKind: String { case staticSystem = "static", follow = "eventfollow", spawn = "eventspawn" }
    private struct Instance {
        let system: SceneParticles
        var anchor: SIMD3<Float>
        var age: Double
        let parentLifetime: Double?
        let parentDeathTime: Double?
        let trajectory: SceneParticles.EventTrajectory?
        var parentEnded = false
    }
    private struct EventPhase {
        let time: Double
        let birth: SceneParticles.BirthEvent?
        let ids: [SceneParticles.Spawn]
        var cursor = 0
        var visitCharged = false
        var poolAdvanced = false
        var poseVisitCharged = false
        var decisionMade = false
        var admittedChild: SceneParticles.Spawn?
    }
    let materialPath: String
    let warnings: [String]
    let maximumInstances: Int
    let reservedParticles: Int
    private let minimumWork: Int
    private let parent: SceneParticles
    private let template: SceneParticles
    var usesWorldGeometry: Bool { kind != .staticSystem && (template.usesWorldSpace || parent.usesWorldSpace) }
    /// Child projection is a property of its own system, not its parent.
    var usesPerspectiveProjection: Bool { template.usesPerspectiveProjection }
    /// Static local geometry remains in child coordinates. The draw model also
    /// reaches the material uniforms, so do not bake this matrix into vertices.
    var drawLocalTransform: simd_float4x4 { kind == .staticSystem ? localTransform : matrix_identity_float4x4 }
    var usesWorldEmission: Bool { template.usesWorldSpace }
    var requiresEmitterHistory: Bool { template.usesWorldSpace && !parent.usesWorldSpace }
    private let kind: EventKind
    private let localTransform: simd_float4x4
    private let declarationScale: SIMD3<Float>
    private let probability: Double
    private let declarationSalt: UInt64
    private var systems: [SceneParticles.Spawn: Instance] = [:]
    private var staticSystem: SceneParticles?
    private var staticFailed = false
    private var eventPhase: EventPhase?
    private var cachedVertices: [Float] = []
    private var cachedSamples: [[String: Any]] = []
    private var geometryTime = -Double.infinity
    private var birthConsumer: Int?
    private var isActivated = false
    private var frontier = -Double.infinity
    private var generation: UInt64?
    private var accepted = 0, rejected = 0, failures = 0
    private var retired = 0, consumedBirths = 0
    private var reachedParentEnd = 0, retiredAfterParentEnd = 0
    private var trajectoryWork = 0, trajectoryBacklog = 0.0
    private var worldBirths = 0
    private var cachedPostParentDeathQuads = 0
    private var recentRetirements: [[String: Any]] = []
    private var invalidGeometry = 0
    private var lastFailure = ""
    private var nextReport = 0.0
    private var latest: [String: Any] = [:]

    init(parent: SceneParticles, declaration: [String: Any], document: [String: Any],
         instance: [String: Any], declarationIndex: Int) throws {
        let allowed: Set<String> = ["id", "name", "type", "maxcount", "origin", "angles", "scale", "probability", "flags", "controlpointstartindex"]
        guard Set(declaration.keys).isSubset(of: allowed),
              declaration["type"] == nil || declaration["type"] is String,
              let kind = EventKind(rawValue: declaration["type"] as? String ?? "static"),
              try Self.scalar(declaration["controlpointstartindex"], default: 0) == 0 else {
            throw SceneParticles.Error.unsupported("Only direct static, eventfollow or eventspawn children without control-point remapping are supported.")
        }
        self.kind = kind
        minimumWork = kind == .follow ? parent.minimumTrajectoryWork : (kind == .staticSystem ? 1 : 4)
        // Native static bootstrap creates exactly one system and does not read
        // event probability/maxcount. Only the child's own particle cap applies.
        let count = kind == .staticSystem ? 1 : try Self.scalar(declaration["maxcount"], default: 10)
        guard let count = Int(exactly: count), (1...512).contains(count) else {
            throw SceneParticles.Error.unsupported("Child maxcount must be an integer in 1...512.")
        }
        maximumInstances = count
        probability = kind == .staticSystem ? 1 : try Self.scalar(declaration["probability"], default: 1)
        let systemFlags = try Self.scalar(document["flags"], default: 0)
        let supportedFlags: [Double] = kind == .staticSystem ? [0, 2, 4, 6] : [0, 1, 2, 3]
        guard (0...1).contains(probability), try Self.scalar(declaration["flags"], default: 0) == 0,
              supportedFlags.contains(systemFlags) else {
            throw SceneParticles.Error.unsupported("Child declarations require default flags; static pools support local sequence-blend and perspective flags, while event pools support world-space and sequence-blend flags.")
        }
        if let nested = document["children"], !(nested is NSNull) {
            guard let entries = nested as? [Any], entries.isEmpty else {
                throw SceneParticles.Error.unsupported("Nested child systems are not supported; this declaration is skipped.")
            }
        }
        let supportedInitializers: Set<String> = ["lifetimerandom", "sizerandom", "velocityrandom", "colorrandom", "alpharandom", "rotationrandom", "angularvelocityrandom", "turbulentvelocityrandom"]
        guard let initializers = document["initializer"] as? [[String: Any]],
              initializers.allSatisfy({ supportedInitializers.contains(($0["name"] as? String ?? "").lowercased()) }) else {
            throw SceneParticles.Error.unsupported("Child initializer needs unimplemented event-attribute inheritance or another initializer.")
        }
        let points = document["controlpoint"] as? [[String: Any]] ?? []
        for point in points {
            guard try Self.scalar(point["flags"], default: 0) == 0,
                  try Self.vector(point["offset"], default: .zero) == .zero else {
                throw SceneParticles.Error.unsupported("Child control-point offsets/attachments are not implemented.")
            }
        }
        var inherited = instance
        // Event instances receive parent particle age (already rate-scaled).
        // Static instances receive the parent's requested particle time, also
        // already scaled and independent of the parent's scheduler backlog.
        if kind != .staticSystem { inherited["rate"] = 1 }
        let template = try SceneParticles(document: document, instance: inherited, orthographic: parent.usesOrthographicDefaults,
                                          inputTimeAlreadyScaled: kind == .staticSystem)
        guard template.supportsFollowingChild else {
            throw SceneParticles.Error.unsupported("Direct children currently require sprite rendering without force fields or continuous turbulence.")
        }
        if kind == .staticSystem {
            guard parent.acceptsLocalStaticChildren, template.acceptsLocalStaticChildren else {
                throw SceneParticles.Error.unsupported("Static children currently require local-space parent and child pools without unknown flag bits.")
            }
        }
        guard !template.usesWorldSpace || !template.hasPrewarm else {
            throw SceneParticles.Error.unsupported("World-space child prewarm before the parent birth is not decoded.")
        }
        reservedParticles = template.maximumParticles * count
        guard reservedParticles <= 4096 else { throw SceneParticles.Error.unsupported("Child declaration exceeds the 4096-particle budget.") }
        materialPath = template.materialPath
        self.parent = parent; self.template = template
        declarationSalt = UInt64(declarationIndex + 1) &* 0x9E37_79B9_7F4A_7C15
        let origin = try Self.vector(declaration["origin"], default: .zero)
        let angle = try Self.vector(declaration["angles"], default: .zero)
        let scale = try Self.vector(declaration["scale"], default: SIMD3(repeating: 1))
        guard simd_reduce_max(simd_abs(origin)) <= 1_000_000,
              simd_reduce_max(simd_abs(angle)) <= 1000,
              simd_reduce_max(simd_abs(scale)) <= 1000 else {
            throw SceneParticles.Error.unsupported("Child transform exceeds native bounds (origin 1000000, angle and absolute scale 1000).")
        }
        // REA's ParseParticleCommandBuffers multiplies each rotation column by
        // the authored signed scale, with no positive/nonzero requirement.
        // A zero world-child scale collapses emission offsets/velocities, not
        // sprite sizes. No inverse of this declaration matrix is needed here.
        declarationScale = scale
        let x = simd_quatf(angle: angle.x, axis: SIMD3(1,0,0))
        let y = simd_quatf(angle: angle.y, axis: SIMD3(0,1,0))
        let z = simd_quatf(angle: angle.z, axis: SIMD3(0,0,1))
        var matrix = simd_float4x4(z * y * x)
        matrix.columns.0 *= scale.x; matrix.columns.1 *= scale.y; matrix.columns.2 *= scale.z
        matrix.columns.3 = SIMD4(origin, 1)
        localTransform = matrix
        let behavior = kind == .spawn
            ? "eventspawn advances actual child pools at each accepted parent birth before deciding capacity. Finite emission drains; duration=0 continuous emission remains active. Pending work preserves its phase and the last coherent geometry, with bounded journal backpressure. Child particles survive the parent until their own emission and particles end."
            : "eventfollow consumes accepted parent births, samples an independent bounded trajectory copy, stops child emission at the parent lifetime, then drains existing particles. Its anchor freezes at the terminal position. Emission exactly at the cutoff is excluded. Missing recorded pointer or transform history fails explicitly."
        let transformNotes = simd_reduce_min(scale) <= 0
            ? ["Child declaration scale \(scale) is preserved, including zero or negative axes. The official parser directly multiplies its rotation columns by these values. World-space children transform emission offsets and initial velocities while retaining independently sized sprites; local child geometry uses the declaration matrix. Windows pixel parity remains unverified."]
            : []
        if kind == .staticSystem {
            warnings = template.warnings + transformNotes + ["Static children keep one independent local pool, with their own starttime and the inherited object rate applied once. They do not consume parent birth events or use event probability/maxcount. Declaration transforms are part of the draw model. REA traced bootstrap and draw behavior in the official Android library; fixed-step native prewarm ordering and Windows pixel parity remain unverified."]
        } else {
            warnings = template.warnings + transformNotes + [behavior + " World-space children place EACH particle at its birth, before the same trajectory evaluator advances to the phase anchor. Local children retain their instance transform. Object overrides are inherited; per-particle attribute inheritance and exact Windows ordering remain unverified."]
        }
    }

    func configureTexture(_ animation: SceneTextureAnimation?, width: Int, height: Int, imageWidth: Int, imageHeight: Int) throws {
        try template.configureTexture(animation, width: width, height: height, imageWidth: imageWidth, imageHeight: imageHeight)
    }

    func applyLiveOverrides(_ values: SceneParticles.LiveOverrides) throws {
        // Both child kinds consume a parent-scaled time. Never apply the object
        // rate twice, including when a new event instance copies the template.
        var childValues = values
        childValues.rate = 1
        try template.applyLiveOverrides(childValues)
        try staticSystem?.applyLiveOverrides(childValues)
        for instance in systems.values { try instance.system.applyLiveOverrides(childValues) }
    }

    func activate() {
        guard !isActivated else { return }
        isActivated = true
        parent.reserveChildWork(particles: reservedParticles, minimumWork: minimumWork)
        if kind != .staticSystem {
            parent.capturesEvents = true
            if birthConsumer == nil { birthConsumer = parent.registerBirthConsumer(followsTrajectory: kind == .follow) }
        }
    }

    func vertices(at time: Double, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>, drawModel: simd_float4x4) -> [Float] {
        guard parent.eventSceneTime == time else { return [] }
        if generation != parent.eventGeneration {
            generation = parent.eventGeneration; systems.removeAll(); staticSystem = nil; staticFailed = false
            eventPhase = nil; frontier = -Double.infinity
            cachedVertices.removeAll(); cachedSamples.removeAll(); geometryTime = -Double.infinity
            accepted = 0; rejected = 0; failures = 0; invalidGeometry = 0; lastFailure = ""; nextReport = 0
            retired = 0; consumedBirths = 0; worldBirths = 0
            reachedParentEnd = 0; retiredAfterParentEnd = 0
            trajectoryWork = 0; trajectoryBacklog = 0; cachedPostParentDeathQuads = 0
            recentRetirements.removeAll()
        }
        if kind == .staticSystem { return staticVertices(at: time, cameraRight: cameraRight, cameraUp: cameraUp, drawModel: drawModel) }
        // Each declaration reserves one affordable work step; the remainder is
        // proportional. Total shares stay within 20000 for the parsed bounds.
        let sharedBudget = parent.childWorkBudget
        let workBudget = SceneParticles.FrameBudget(operations: min(sharedBudget.remainingSchedulerOperations,
            parent.childWorkQuota(particles: reservedParticles, minimumWork: minimumWork)))
        let schedulerBefore = workBudget.remainingSchedulerOperations
        trajectoryWork = 0; trajectoryBacklog = 0
        guard let birthConsumer else { return [] }
        while workBudget.remainingSchedulerOperations > 0 {
            if eventPhase == nil {
                if let birth = parent.pendingBirths(for: birthConsumer).first {
                    eventPhase = EventPhase(time: birth.id.birthTime, birth: birth, ids: systems.keys.sorted())
                } else if frontier < parent.eventSimulationTime {
                    eventPhase = EventPhase(time: parent.eventSimulationTime, birth: nil, ids: systems.keys.sorted())
                } else { break }
            }
            guard var phase = eventPhase else { break }
            let complete = advanceEventPhase(&phase, budget: workBudget)
            if !complete { eventPhase = phase; break }
            frontier = phase.time; eventPhase = nil
            if phase.birth != nil {
                parent.consumeBirths(1, for: birthConsumer); consumedBirths += 1
            }
        }
        let queuedBirths = parent.pendingBirths(for: birthConsumer).count
        // A partially advanced transaction contains pools at different times.
        // Rendering it at an older frontier would rewind some of those pools.
        // Keep the last complete local geometry until the phase is complete.
        let geometryFrozen = eventPhase != nil
        var output: [Float] = geometryFrozen ? cachedVertices : []
        var samples: [[String: Any]] = geometryFrozen ? cachedSamples : []
        var postParentDeathQuads = geometryFrozen ? cachedPostParentDeathQuads : 0
        if !geometryFrozen {
            for id in systems.keys.sorted() {
                guard let instance = systems[id] else { continue }
                let child = instance.system
                // Event geometry is transformed on the CPU before the parent's
                // draw model, except for world-space particles which are already
                // placed in world coordinates at birth.
                let orientationModel = parent.usesWorldSpace ? localTransform : drawModel * localTransform
                let geometryModel = template.usesWorldSpace ? matrix_identity_float4x4 : orientationModel
                var vertices = child.vertices(at: instance.age, cameraRight: cameraRight, cameraUp: cameraUp,
                    capturePointer: false, workBudget: workBudget, orientationModel: orientationModel,
                    geometryModel: geometryModel)
                // World child vertices already contain their birth placement.
                // A local child of a world parent uses T(worldAnchor)*D; native
                // parent/inverse-parent factors cancel, even for zero Z scale.
                var finiteGeometry = true
                for offset in stride(from: 0, to: template.usesWorldSpace ? 0 : vertices.count, by: 12) {
                    let p = localTransform * SIMD4(vertices[offset], vertices[offset+1], vertices[offset+2], 1)
                    vertices[offset] = p.x + instance.anchor.x
                    vertices[offset+1] = p.y + instance.anchor.y
                    vertices[offset+2] = p.z + instance.anchor.z
                    if !vertices[offset].isFinite || !vertices[offset+1].isFinite || !vertices[offset+2].isFinite {
                        finiteGeometry = false; break
                    }
                }
                if !finiteGeometry { invalidGeometry += 1; vertices.removeAll() }
                output.append(contentsOf: vertices)
                if instance.parentEnded { postParentDeathQuads += vertices.count / 72 }
                if samples.count < 4 { samples.append(["parentBirth": id.emissionIndex, "parentEmitter": id.emitterIndex,
                    "birthTime": id.birthTime, "childAge": instance.age,
                    "parentLifetime": instance.parentLifetime.map { $0 as Any } ?? NSNull(),
                    "parentDeathTime": instance.parentDeathTime.map { $0 as Any } ?? NSNull(),
                    "parentEnded": instance.parentEnded, "childAcceptedBirths": child.eventAcceptedBirths,
                    "childStopAge": child.eventStopAge.map { $0 as Any } ?? NSNull(),
                    "lastChildDeathTime": child.eventLastDeathTime.map { $0 as Any } ?? NSNull(),
                    "worldBirths": child.worldBirths,
                    "worldParticles": child.usesWorldSpace ? child.eventRenderSamples : [],
                    "anchor": [instance.anchor.x,instance.anchor.y,instance.anchor.z],
                    "alive": child.currentAlive, "quads": vertices.count / 72]) }
            }
        }
        if !geometryFrozen {
            cachedVertices = output; cachedSamples = samples; geometryTime = frontier
            cachedPostParentDeathQuads = postParentDeathQuads
        }
        let maximumBacklog = systems.values.map { $0.system.schedulingBacklog }.max() ?? 0
        let backloggedSystems = systems.values.filter { $0.system.schedulingBacklog > 0 }.count
        let aliveParticles = systems.values.reduce(0) { $0 + $1.system.currentAlive }
        sharedBudget.remainingSchedulerOperations -= schedulerBefore - workBudget.remainingSchedulerOperations
        latest = ["sceneTime": time, "generation": parent.eventGeneration, "instances": systems.count,
            "declarationScale": [declarationScale.x, declarationScale.y, declarationScale.z],
            "parentSpace": parent.usesWorldSpace ? "world" : "local",
            "childSpace": template.usesWorldSpace ? "world" : "local", "worldBirths": worldBirths,
            "eventType": kind.rawValue, "consumedBirths": consumedBirths, "queuedBirths": queuedBirths,
            "retired": retired, "deferredFollowBirths": 0,
            "followReachedParentEnd": reachedParentEnd, "followRetiredAfterParentEnd": retiredAfterParentEnd,
            "drainingInstances": systems.values.filter { $0.parentEnded }.count,
            "postParentDeathQuads": postParentDeathQuads,
            "trajectoryWorkUnits": trajectoryWork, "trajectoryBacklog": trajectoryBacklog,
            "recentRetirements": recentRetirements,
            "geometryFrozen": geometryFrozen,
            "geometryTime": geometryTime.isFinite ? geometryTime as Any : NSNull(),
            "presentationBacklog": geometryTime.isFinite ? max(0, parent.eventSimulationTime - geometryTime) as Any : NSNull(),
            "pendingPhaseTime": eventPhase.map { $0.time as Any } ?? NSNull(),
            "pendingPhaseCursor": eventPhase?.cursor ?? 0,
            "pendingPhaseInstances": eventPhase?.ids.count ?? 0,
            "pendingPhaseDecisionMade": eventPhase?.decisionMade ?? false,
            "pendingPhasePoolAdvanced": eventPhase?.poolAdvanced ?? false,
            "pendingPoseVisitCharged": eventPhase?.poseVisitCharged ?? false,
            "pendingChildInitialization": eventPhase?.admittedChild != nil,
            "eventFrontier": frontier.isFinite ? frontier as Any : NSNull(),
            "eventTimeBacklog": frontier.isFinite ? max(0, parent.eventSimulationTime - frontier) as Any : NSNull(),
            "maxInstances": maximumInstances, "accepted": accepted, "rejected": rejected, "failures": failures,
            "invalidGeometry": invalidGeometry, "lastFailure": lastFailure,
            "schedulerOperations": schedulerBefore - workBudget.remainingSchedulerOperations,
            "declarationWorkQuota": schedulerBefore,
            "sharedSchedulerRemaining": sharedBudget.remainingSchedulerOperations,
            "maximumScheduleBacklog": maximumBacklog, "backloggedSystems": backloggedSystems,
            "aliveParticles": aliveParticles, "submittedQuads": output.count / 72, "samples": samples]
        return output
    }

    /// Unlike event instances, a static pool never depends on a parent's
    /// accepted particles, their lifetime or its event-journal frontier. One
    /// pool can render its actual reached time without a cross-instance phase.
    private func staticVertices(at time: Double, cameraRight: SIMD3<Float>, cameraUp: SIMD3<Float>, drawModel: simd_float4x4) -> [Float] {
        _ = discardInvalidStaticDraw(drawModel)
        let sharedBudget = parent.childWorkBudget
        let budget = SceneParticles.FrameBudget(operations: min(sharedBudget.remainingSchedulerOperations,
            parent.childWorkQuota(particles: reservedParticles, minimumWork: minimumWork)))
        let before = budget.remainingSchedulerOperations
        if !staticFailed, staticSystem == nil, before > 0 {
            staticSystem = SceneParticles(template: template, seedSalt: declarationSalt)
            accepted = 1
        }
        var output = cachedVertices
        var refreshed = false
        if let system = staticSystem, budget.remainingSchedulerOperations > 0 {
            budget.remainingSchedulerOperations -= 1
            output = system.vertices(at: parent.eventRequestedSimulationTime, cameraRight: cameraRight, cameraUp: cameraUp,
                capturePointer: false, workBudget: budget, orientationModel: drawModel, geometryModel: drawModel)
            if output.allSatisfy(\.isFinite) {
                cachedVertices = output
                geometryTime = system.eventSimulationTime
                refreshed = true
            } else {
                invalidGeometry += 1
                failStatic("Static child geometry is non-finite; this generation is disabled.")
                output = []
            }
        }
        sharedBudget.remainingSchedulerOperations -= before - budget.remainingSchedulerOperations
        latest = ["sceneTime": time, "requestedSceneTime": time,
            "declarationScale": [declarationScale.x, declarationScale.y, declarationScale.z],
            "requestedSimulationTime": parent.eventRequestedSimulationTime,
            "reachedSimulationTime": staticSystem.map { $0.eventSimulationTime as Any } ?? NSNull(),
            "generation": parent.eventGeneration, "eventType": "static", "failed": staticFailed,
            "failures": failures,
            "instances": staticSystem == nil ? 0 : 1, "maxInstances": 1, "accepted": accepted,
            "parentSpace": "local", "childSpace": "local", "consumedBirths": 0, "queuedBirths": 0,
            "schedulerOperations": before - budget.remainingSchedulerOperations,
            "declarationWorkQuota": before, "sharedSchedulerRemaining": sharedBudget.remainingSchedulerOperations,
            "geometryFrozen": !refreshed && !staticFailed,
            "geometryTime": geometryTime.isFinite ? geometryTime as Any : NSNull(),
            "maximumScheduleBacklog": staticSystem?.schedulingBacklog ?? 0,
            "aliveParticles": staticSystem?.currentAlive ?? 0, "submittedQuads": output.count / 72,
            "childAcceptedBirths": staticSystem?.eventAcceptedBirths ?? 0,
            "invalidGeometry": invalidGeometry, "lastFailure": lastFailure,
            "samples": staticSystem?.eventRenderSamples ?? []]
        return output
    }

    /// A paused redraw must also discard invalid geometry without advancing
    /// any particle clock. The next active frame reports the full diagnostics.
    @discardableResult
    func discardInvalidStaticDraw(_ model: simd_float4x4) -> Bool {
        guard kind == .staticSystem,
              !(0..<4).allSatisfy({ column in (0..<4).allSatisfy { model[column][$0].isFinite } }) else { return false }
        if !staticFailed { failStatic("Static child draw model is non-finite; this generation is disabled.") }
        latest["failed"] = true; latest["failures"] = failures; latest["lastFailure"] = lastFailure
        latest["instances"] = 0; latest["submittedQuads"] = 0; latest["aliveParticles"] = 0
        latest["geometryFrozen"] = false; latest["geometryTime"] = NSNull()
        latest["samples"] = [] as [[String: Any]]
        return true
    }

    private func failStatic(_ message: String) {
        staticFailed = true; failures += 1; lastFailure = message
        staticSystem = nil; cachedVertices.removeAll(); cachedSamples.removeAll()
        geometryTime = -Double.infinity
    }

    /// Complete one ordered transaction, retaining the exact cursor when work
    /// runs out. Admission and probability are evaluated once, after all older
    /// children have reached this time. A new child's prewarm is resumable too.
    private func advanceEventPhase(_ phase: inout EventPhase, budget: SceneParticles.FrameBudget) -> Bool {
        while phase.cursor < phase.ids.count {
            let id = phase.ids[phase.cursor]
            guard advanceInstance(id, phase: &phase, budget: budget) else { return false }
            phase.cursor += 1; phase.visitCharged = false; phase.poolAdvanced = false; phase.poseVisitCharged = false
        }
        guard let birth = phase.birth else { return true }
        if !phase.decisionMade {
            guard budget.remainingSchedulerOperations > 0 else { return false }
            budget.remainingSchedulerOperations -= 1
            let salt = Self.seed(birth.id) ^ declarationSalt
            if systems.count < maximumInstances, Self.chosen(salt, probability: probability) {
                let child = SceneParticles(template: template, seedSalt: salt)
                let trajectory = kind == .follow ? birth.makeTrajectory?() : nil
                let cutoffAge = birth.deathTime - birth.id.birthTime
                if kind == .follow && (trajectory == nil || !child.configureEventStop(at: cutoffAge)) {
                    failures += 1; lastFailure = "Follow birth lacks a trajectory or valid stop time."
                } else {
                    if child.usesWorldSpace {
                        let parentGeneration = parent.eventGeneration
                        let declaration = localTransform
                        let follows = kind == .follow
                        var spawnPlacement: simd_float4x4?
                        child.configureBirthPlacement { [weak parent] spawn, work in
                            guard let parent, parent.eventGeneration == parentGeneration else {
                                return .failed("World-space child parent generation changed.")
                            }
                            guard work.remainingSchedulerOperations > 0 else { return .pending(0) }
                            work.remainingSchedulerOperations -= 1
                            if let spawnPlacement { return .ready(spawnPlacement) }
                            let anchor: SIMD3<Float>
                            let parentTime: Double
                            if follows, let trajectory {
                                // Negative prewarm was rejected at admission.
                                switch trajectory.sample(at: min(spawn.birthTime, cutoffAge), workBudget: work) {
                                case .ready(let position): anchor = position
                                case .pending(let lag): return .pending(lag)
                                case .failed(let message): return .failed(message)
                                }
                                parentTime = birth.id.birthTime + spawn.birthTime
                            } else { anchor = birth.position; parentTime = birth.id.birthTime }
                            var translation = matrix_identity_float4x4
                            translation.columns.3 = SIMD4(anchor, 1)
                            if parent.usesWorldSpace {
                                let placement = translation * declaration
                                if !follows { spawnPlacement = placement }
                                return .ready(placement)
                            }
                            switch parent.authoredTransform(at: parentTime) {
                            case .ready(let model):
                                let placement = model * translation * declaration
                                if !follows { spawnPlacement = placement }
                                return .ready(placement)
                            case .failed(let message): return .failed(message)
                            }
                        }
                    }
                    systems[birth.id] = Instance(system: child, anchor: birth.position, age: 0,
                        parentLifetime: kind == .follow ? cutoffAge : nil,
                        parentDeathTime: kind == .follow ? birth.deathTime : nil, trajectory: trajectory)
                    phase.admittedChild = birth.id; accepted += 1
                }
            } else { rejected += 1 }
            phase.decisionMade = true
        }
        if let id = phase.admittedChild {
            guard advanceInstance(id, phase: &phase, budget: budget) else { return false }
        }
        return true
    }

    /// Pool simulation and parent-pose replay are separate resumable stages.
    /// Publish the new age and anchor only when both have finished.
    private func advanceInstance(_ id: SceneParticles.Spawn, phase: inout EventPhase,
                                 budget: SceneParticles.FrameBudget) -> Bool {
        guard var instance = systems[id] else { return true }
        if !phase.visitCharged {
            guard budget.remainingSchedulerOperations > 0 else { return false }
            budget.remainingSchedulerOperations -= 1; phase.visitCharged = true
        }
        let age = max(0, phase.time - id.birthTime)
        if !phase.poolAdvanced {
            let before = instance.system.worldBirths
            let complete = instance.system.advanceEventPool(at: age, workBudget: budget)
            worldBirths += instance.system.worldBirths - before
            trajectoryWork += instance.system.placementWork
            trajectoryBacklog = max(trajectoryBacklog, instance.system.placementBacklog)
            if let failure = instance.system.spaceFailure {
                failures += 1; lastFailure = failure; systems.removeValue(forKey: id)
                return true
            }
            guard complete else { return false }
            phase.poolAdvanced = true
        }
        guard instance.system.eventPoolIsActive else {
            if let lifetime = instance.parentLifetime,
               let lastDeath = instance.system.eventLastDeathTime, lastDeath > lifetime {
                retiredAfterParentEnd += 1
            }
            if recentRetirements.count == 4 { recentRetirements.removeFirst() }
            recentRetirements.append(["parentBirth": id.emissionIndex, "parentEmitter": id.emitterIndex,
                "parentLifetime": instance.parentLifetime.map { $0 as Any } ?? NSNull(),
                "childAgeAtReclaim": age, "lastChildDeathTime": instance.system.eventLastDeathTime.map { $0 as Any } ?? NSNull(),
                "worldBirths": instance.system.worldBirths,
                "childAcceptedBirths": instance.system.eventAcceptedBirths])
            systems.removeValue(forKey: id); retired += 1
            return true
        }
        if let trajectory = instance.trajectory, let lifetime = instance.parentLifetime, !instance.parentEnded {
            if !phase.poseVisitCharged {
                guard budget.remainingSchedulerOperations > 0 else { return false }
                budget.remainingSchedulerOperations -= 1; phase.poseVisitCharged = true
            }
            let before = budget.remainingSchedulerOperations
            let sample = trajectory.sample(at: min(age, lifetime), workBudget: budget)
            trajectoryWork += before - budget.remainingSchedulerOperations
            switch sample {
            case .ready(let position):
                instance.anchor = position
                if let deathTime = instance.parentDeathTime, phase.time >= deathTime {
                    instance.parentEnded = true; reachedParentEnd += 1
                }
            case .pending(let lag):
                trajectoryBacklog = max(trajectoryBacklog, lag)
                return false
            case .failed(let message):
                failures += 1; lastFailure = message
                systems.removeValue(forKey: id)
                return true
            }
        }
        instance.age = age; systems[id] = instance
        return true
    }

    private static func chosen(_ seed: UInt64, probability: Double) -> Bool {
        Double(seed >> 11) / Double(UInt64(1) << 53) < probability
    }

    /// A read-only snapshot for the compatibility panel. Opening it must not
    /// consume the periodic log interval or advance any simulation state.
    /// Rendering can sleep once all accepted events and child lifetimes drain.
    /// A delayed/continuous emitter remains active even with an empty live pool.
    var needsFrameUpdates: Bool {
        if kind == .staticSystem { return !staticFailed && (staticSystem?.eventPoolIsActive ?? true) }
        if eventPhase != nil { return true }
        guard let birthConsumer else { return true }
        if !parent.pendingBirths(for: birthConsumer).isEmpty { return true }
        return systems.values.contains { $0.system.eventPoolIsActive || (kind == .follow && !$0.parentEnded) }
    }

    var runtimeDiagnostic: String? {
        guard let time = latest["sceneTime"] as? Double else { return nil }
        func count(_ key: String) -> Int { latest[key] as? Int ?? 0 }
        let backlog = latest["maximumScheduleBacklog"] as? Double ?? 0
        let timeBacklog = latest["eventTimeBacklog"] as? Double ?? backlog
        let lastFailure = latest["lastFailure"] as? String ?? ""
        return "子粒子运行快照：时间 \(String(format: "%.2f", time)) 秒；\(kind.rawValue)，\(parent.usesWorldSpace ? "世界" : "局部")→\(template.usesWorldSpace ? "世界" : "局部")，声明缩放 \(declarationScale)。实例 \(count("instances"))/\(maximumInstances)，存活粒子 \(count("aliveParticles"))，提交四边形 \(count("submittedQuads"))，累计世界出生 \(count("worldBirths"))，排空实例 \(count("drainingInstances"))，父结束后四边形 \(count("postParentDeathQuads"))；失败 \(count("failures"))，无效几何 \(count("invalidGeometry"))，调度/事件积压 \(String(format: "%.3f/%.3f", backlog, timeBacklog)) 秒。\(lastFailure.isEmpty ? "" : " 最近失败：" + String(lastFailure.prefix(300)))"
    }

    func observation(at time: Double) -> String? {
        guard time >= nextReport else { return nil }
        nextReport = time + (time < 30 ? 5 : 60)
        guard let data = try? JSONSerialization.data(withJSONObject: latest, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func seed(_ id: SceneParticles.Spawn) -> UInt64 {
        var value = id.birthTime.bitPattern ^ UInt64(truncatingIfNeeded: id.emissionIndex)
        value ^= UInt64(truncatingIfNeeded: id.emitterIndex) &* 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
    private static func scalar(_ raw: Any?, default fallback: Double) throws -> Double {
        if raw == nil || raw is NSNull { return fallback }
        let value = (raw as? NSNumber)?.doubleValue ?? (raw as? String).flatMap(Double.init)
        guard let value, value.isFinite else { throw SceneParticles.Error.malformed("Child value must be a finite number.") }
        return value
    }
    private static func vector(_ raw: Any?, default fallback: SIMD3<Float>) throws -> SIMD3<Float> {
        if raw == nil || raw is NSNull { return fallback }
        let parts: [Any]
        if let value = raw as? String { parts = value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init) }
        else if let value = raw as? [Any] { parts = value }
        else { throw SceneParticles.Error.malformed("Child vector must contain three finite values.") }
        guard parts.count == 3 else { throw SceneParticles.Error.malformed("Child vector must contain three finite values.") }
        let values = try parts.map { Float(try scalar($0, default: 0)) }
        guard values.allSatisfy(\.isFinite) else { throw SceneParticles.Error.malformed("Child vector overflow.") }
        return SIMD3(values[0],values[1],values[2])
    }
}
