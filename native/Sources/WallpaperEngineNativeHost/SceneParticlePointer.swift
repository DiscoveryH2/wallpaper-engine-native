import Foundation
import simd

/// Host eligibility and normalized coordinates are sampled once per frame.
/// Each particle layer projects them using its own current drawing transform.
struct NativeMetalParticlePointerSample {
    let normalized: SIMD2<Float>?
    let reason: String
    static let inactive = Self(normalized: nil, reason: "no-host-pointer")

    func project(_ transform: simd_float4x4) -> SceneParticlePointerInput {
        guard let normalized else { return .init(position: nil, reason: reason) }
        guard normalized.x.isFinite, normalized.y.isFinite else {
            return .init(position: nil, reason: "nonfinite-screen-position")
        }
        guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else {
            return .init(position: nil, reason: "outside-wallpaper")
        }
        return SceneParticlePointerInput.project(normalized: normalized, modelViewProjection: transform)
    }
}

/// A cursor is projected onto the particle system's local Z=0 plane. A full
/// 4x4 inverse would reject valid planar systems with authored scale.z == 0.
/// This inverse homography also retains parent transforms, mirroring, rotation,
/// view/crop and parallax from the exact matrix used for drawing the layer.
struct SceneParticlePointerInput {
    let position: SIMD3<Float>?
    let reason: String

    static func project(normalized: SIMD2<Float>, modelViewProjection m: simd_float4x4) -> Self {
        guard normalized.x.isFinite, normalized.y.isFinite else { return Self(position: nil, reason: "nonfinite-screen-position") }
        func column(_ c: SIMD4<Float>) -> SIMD3<Double> { SIMD3(Double(c.x), Double(c.y), Double(c.w)) }
        let columns = [column(m.columns.0), column(m.columns.1), column(m.columns.3)]
        let lengths = SIMD3(simd_length(columns[0]), simd_length(columns[1]), simd_length(columns[2]))
        guard lengths.x.isFinite, lengths.y.isFinite, lengths.z.isFinite,
              min(lengths.x, min(lengths.y, lengths.z)) > 1e-12 else {
            return Self(position: nil, reason: "degenerate-projected-plane")
        }
        // Column normalization makes the condition check independent of scene
        // resolution and ordinary author scale. It is still a bounded native
        // numerical policy, not an inferred Wallpaper Engine implementation.
        let h = simd_double3x3(columns: (columns[0] / lengths.x, columns[1] / lengths.y, columns[2] / lengths.z))
        let determinant = simd_determinant(h)
        guard determinant.isFinite, abs(determinant) > 1e-9 else {
            return Self(position: nil, reason: "edge-on-or-singular-projected-plane")
        }
        let clip = SIMD3<Double>(Double(normalized.x) * 2 - 1, Double(normalized.y) * 2 - 1, 1)
        let homogeneous = (simd_inverse(h) * clip) / lengths
        guard homogeneous.x.isFinite, homogeneous.y.isFinite, homogeneous.z.isFinite, abs(homogeneous.z) > 1e-12 else {
            return Self(position: nil, reason: "invalid-projected-plane-intersection")
        }
        let x = homogeneous.x / homogeneous.z, y = homogeneous.y / homogeneous.z
        guard x.isFinite, y.isFinite, max(abs(x), abs(y)) <= 1_000_000 else {
            return Self(position: nil, reason: "local-pointer-out-of-range")
        }
        let position = SIMD3<Float>(Float(x), Float(y), 0)
        let projected = m * SIMD4(position, 1)
        guard projected.w.isFinite, projected.w > 0.000001 else {
            return Self(position: nil, reason: "projected-plane-behind-camera")
        }
        return Self(position: position, reason: "projected-local-z0-plane")
    }
}

/// Causal input history: an integration step sees the last cursor observation
/// at or before its own time, never the newest cursor retroactively applied to
/// pre-roll or catch-up. Old/absent observations disable only the pointer force.
/// Samples carry both particle and scene times. During a zero-rate plateau,
/// the last observation is effective strictly after the frozen particle time;
/// already scheduled work at that exact boundary retains its original input.
final class SceneParticlePointerHistory {
    private struct Sample {
        let time: Double
        let sceneTime: Double?
        let position: SIMD3<Float>?
        let afterBoundary: Bool
    }
    private static let capacity = 4096
    // Most particle systems never reference the cursor. Allocate the ring only
    // when the renderer records an input for a pointer-linked system.
    private var storage: [Sample?] = []
    private var start = 0
    private var firstObservationTime: Double?
    private var lastObservationSceneTime: Double?
    private var pendingAfter: Sample?
    private(set) var count = 0
    private(set) var discardedSamples = 0
    private(set) var queries = 0
    private(set) var outsideCoverageQueries = 0
    private(set) var staleQueries = 0
    private(set) var inactiveQueries = 0
    private(set) var lostHistoryQueries = 0

    func reset() {
        start = 0; count = 0; discardedSamples = 0
        firstObservationTime = nil; lastObservationSceneTime = nil; pendingAfter = nil
        resetFrameCounters()
    }

    func resetFrameCounters() {
        queries = 0; outsideCoverageQueries = 0; staleQueries = 0; inactiveQueries = 0
        lostHistoryQueries = 0
    }

    private func sample(_ index: Int) -> Sample { storage[(start + index) % Self.capacity]! }

    private func appendSample(_ next: Sample) {
        if count == Self.capacity {
            storage[start] = next
            start = (start + 1) % Self.capacity; discardedSamples += 1
        } else {
            storage[(start + count) % Self.capacity] = next
            count += 1
        }
    }

    @discardableResult
    func append(time: Double, position: SIMD3<Float>?, sceneTime: Double? = nil) -> Bool {
        guard time.isFinite, sceneTime?.isFinite ?? true else { return false }
        if storage.isEmpty { storage = [Sample?](repeating: nil, count: Self.capacity) }
        if count > 0 {
            if time < sample(count - 1).time { reset() }
            else if time == sample(count - 1).time {
                guard let sceneTime, let previous = lastObservationSceneTime, sceneTime > previous else { return false }
                lastObservationSceneTime = sceneTime
                // No simulation occurs while time is flat. Keep only the last
                // future observation, without evicting the boundary sample.
                pendingAfter = Sample(time: time, sceneTime: sceneTime, position: position, afterBoundary: true)
                return true
            }
        }
        if let pendingAfter { appendSample(pendingAfter); self.pendingAfter = nil }
        if firstObservationTime == nil { firstObservationTime = time }
        lastObservationSceneTime = sceneTime
        appendSample(Sample(time: time, sceneTime: sceneTime, position: position, afterBoundary: false))
        return true
    }

    private func selected(at time: Double) -> Sample? {
        guard count > 0, time.isFinite else { outsideCoverageQueries += 1; return nil }
        if let pendingAfter, time > pendingAfter.time { return pendingAfter }
        func eligible(_ sample: Sample) -> Bool {
            sample.time < time || (sample.time == time && !sample.afterBoundary)
        }
        guard eligible(sample(0)) else {
            outsideCoverageQueries += 1
            // Prewarm before any observation has no pointer by definition.
            // Data recorded and subsequently evicted is a distinct failure.
            if discardedSamples > 0, let firstObservationTime, time >= firstObservationTime { lostHistoryQueries += 1 }
            return nil
        }
        if eligible(sample(count - 1)) { return sample(count - 1) }
        // Normal fixed-step integration queries the last few display samples;
        // fall back to binary search for longer catch-up intervals.
        for offset in 2...min(8, count) {
            let candidate = sample(count - offset)
            if eligible(candidate) { return candidate }
        }
        var low = 0, high = count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if eligible(sample(middle)) { low = middle } else { high = middle }
        }
        return sample(low)
    }

    func position(at time: Double, maximumAge: Double) -> SIMD3<Float>? {
        queries += 1
        guard let selected = selected(at: time) else { return nil }
        guard time - selected.time <= maximumAge else { staleQueries += 1; return nil }
        guard let position = selected.position else { inactiveQueries += 1; return nil }
        return position
    }

    func position(at time: Double, sceneTime: Double?, maximumSceneAge: Double) -> SIMD3<Float>? {
        queries += 1
        guard let selected = selected(at: time) else { return nil }
        // A lost rate interval is different from an inactive pointer. Follow
        // trajectories detect this counter and fail rather than invent input.
        guard let sceneTime, let observed = selected.sceneTime, sceneTime.isFinite, sceneTime >= observed else {
            // An explicit inactive observation needs no freshness calculation:
            // the force is disabled whether or not its rate interval survived.
            if selected.position == nil { inactiveQueries += 1; return nil }
            lostHistoryQueries += 1; return nil
        }
        guard sceneTime - observed <= maximumSceneAge else { staleQueries += 1; return nil }
        guard let position = selected.position else { inactiveQueries += 1; return nil }
        return position
    }
}
