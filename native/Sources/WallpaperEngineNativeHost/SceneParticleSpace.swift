import Foundation
import simd

/// Causal authored model transforms, excluding camera and parallax. A change
/// applies at its observed particle-clock time; catch-up never borrows a newer
/// pose. Identical consecutive matrices share one interval. Singular affine
/// transforms are valid (some original particle layers use scale.z == 0).
final class SceneParticleTransformHistory {
    enum Lookup {
        case ready(simd_float4x4)
        case failed(String)
    }
    private struct Sample {
        let time: Double
        let matrix: simd_float4x4?
        let afterBoundary: Bool
    }
    private static let capacity = 4096
    private var storage: [Sample?] = []
    private var start = 0
    private var first: Sample?
    private var lastObservationTime: Double?
    private var lastObservationSceneTime: Double?
    private var pendingAfter: Sample?
    private(set) var count = 0
    private(set) var discardedSamples = 0
    private(set) var queries = 0
    private(set) var prewarmQueries = 0
    private(set) var failedQueries = 0

    func reset() {
        start = 0; count = 0; first = nil; lastObservationTime = nil
        lastObservationSceneTime = nil; pendingAfter = nil
        discardedSamples = 0; resetFrameCounters()
    }

    func resetFrameCounters() { queries = 0; prewarmQueries = 0; failedQueries = 0 }

    private func sample(_ index: Int) -> Sample { storage[(start + index) % Self.capacity]! }

    private func appendSample(_ next: Sample) {
        if count > 0, Self.same(sample(count - 1).matrix, next.matrix) { return }
        if storage.isEmpty { storage = [Sample?](repeating: nil, count: Self.capacity) }
        if count == Self.capacity {
            storage[start] = next; start = (start + 1) % Self.capacity
            discardedSamples += 1
        } else {
            storage[(start + count) % Self.capacity] = next; count += 1
        }
    }

    func record(time: Double, transform: simd_float4x4, sceneTime: Double? = nil) {
        guard time.isFinite, sceneTime?.isFinite ?? true else { return }
        if let lastObservationTime {
            if time < lastObservationTime { reset() }
            else if time == lastObservationTime {
                guard let sceneTime, let previous = lastObservationSceneTime, sceneTime > previous else { return }
                lastObservationSceneTime = sceneTime
                // Preserve the pose for births at the already-requested time;
                // the latest paused pose takes effect only after the boundary.
                pendingAfter = Sample(time: time, matrix: Self.isFiniteAffine(transform) ? transform : nil,
                                      afterBoundary: true)
                return
            }
        }
        if let pendingAfter { appendSample(pendingAfter); self.pendingAfter = nil }
        lastObservationTime = time; lastObservationSceneTime = sceneTime
        let matrix = Self.isFiniteAffine(transform) ? transform : nil
        let next = Sample(time: time, matrix: matrix, afterBoundary: false)
        if first == nil { first = next }
        appendSample(next)
    }

    func transform(at time: Double) -> Lookup {
        queries += 1
        guard time.isFinite, let first, count > 0 else {
            failedQueries += 1
            return .failed("No finite authored transform observation for world-space particles.")
        }
        let selected: Sample
        if time < first.time {
            // Authored prewarm starts before the first displayed frame. Its
            // emitter pose is the initial observation, not a later live pose.
            prewarmQueries += 1; selected = first
        } else if let pendingAfter, time > pendingAfter.time {
            selected = pendingAfter
        } else if sample(0).time > time || (sample(0).time == time && sample(0).afterBoundary) {
            failedQueries += 1
            return .failed("Required recorded emitter transform was evicted.")
        } else if sample(count - 1).time < time || (sample(count - 1).time == time && !sample(count - 1).afterBoundary) {
            selected = sample(count - 1)
        } else {
            var low = 0, high = count - 1
            while high - low > 1 {
                let middle = (low + high) / 2
                let candidate = sample(middle)
                if candidate.time < time || (candidate.time == time && !candidate.afterBoundary) { low = middle } else { high = middle }
            }
            selected = sample(low)
        }
        guard let matrix = selected.matrix else {
            failedQueries += 1
            return .failed("World-space emission needs a finite affine authored transform.")
        }
        return .ready(matrix)
    }

    private static func same(_ a: simd_float4x4?, _ b: simd_float4x4?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (.some(let a), .some(let b)):
            return a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 &&
                a.columns.2 == b.columns.2 && a.columns.3 == b.columns.3
        default: return false
        }
    }

    private static func isFiniteAffine(_ matrix: simd_float4x4) -> Bool {
        for column in 0..<4 {
            for row in 0..<4 where !matrix[column][row].isFinite { return false }
        }
        return abs(matrix.columns.0.w) < 0.00001 && abs(matrix.columns.1.w) < 0.00001 &&
            abs(matrix.columns.2.w) < 0.00001 && abs(matrix.columns.3.w - 1) < 0.00001
    }
}
