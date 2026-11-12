import Foundation

/// Bounded inverse of the particle-rate clock for replaying pointer samples.
/// A segment begins at a sampled scene time and stays in force until the next
/// change. At a zero-rate plateau, a query exactly on the plateau belongs to
/// the instant it was first reached; later particle times use the resume time.
final class SceneParticleRateHistory {
    private struct Segment {
        let scene: Double
        let particle: Double
        let rate: Double
    }
    private static let capacity = 4096
    private var storage: [Segment?] = []
    private var start = 0
    private var zeroBoundarySceneTime = 0.0
    private(set) var count = 0
    private(set) var discardedSegments = 0

    private func segment(_ index: Int) -> Segment { storage[(start + index) % Self.capacity]! }

    func reset(initialRate: Float) {
        if storage.isEmpty { storage = [Segment?](repeating: nil, count: Self.capacity) }
        start = 0; count = 1; discardedSegments = 0; zeroBoundarySceneTime = 0
        storage[0] = Segment(scene: 0, particle: 0, rate: Double(initialRate))
    }

    func noteFirstPointerObservation(sceneTime: Double, particleTime: Double) {
        // A scene can first be observed midway through an initial zero-rate
        // plateau. Its boundary input is that first observation, not an
        // invented sample at scene time zero before the view existed.
        if count > 0, discardedSegments == 0, segment(0).rate == 0, particleTime == 0, sceneTime.isFinite {
            zeroBoundarySceneTime = sceneTime
        }
    }

    func setRate(_ rate: Float, sceneTime: Double, particleTime: Double) {
        precondition(count > 0 && sceneTime.isFinite && particleTime.isFinite && rate.isFinite && rate >= 0)
        let last = segment(count - 1)
        precondition(sceneTime >= last.scene && particleTime >= last.particle)
        let next = Segment(scene: sceneTime, particle: particleTime, rate: Double(rate))
        if sceneTime == last.scene {
            // Several UI changes can occur without an intervening frame.
            precondition(particleTime == last.particle)
            storage[(start + count - 1) % Self.capacity] = next
        } else if last.rate != next.rate {
            if count == Self.capacity {
                storage[start] = next; start = (start + 1) % Self.capacity; discardedSegments += 1
            } else {
                storage[(start + count) % Self.capacity] = next; count += 1
            }
        }
    }

    func sceneTime(for particleTime: Double) -> Double? {
        guard particleTime.isFinite, particleTime >= 0, count > 0 else { return nil }
        if particleTime == 0 { return discardedSegments == 0 ? zeroBoundarySceneTime : nil }
        // Find the last segment strictly before the query. Strict comparison
        // is essential for a plateau: equal time uses the pre-pause segment.
        let chosen: Segment
        if segment(count - 1).particle < particleTime {
            chosen = segment(count - 1)
        } else {
            // Integration usually queries the latest frame or its predecessor.
            // Keep that path constant-time even for animated per-frame rates.
            var recent: Segment?
            if count >= 2 {
                for offset in 2...min(8, count) {
                    let candidate = segment(count - offset)
                    if candidate.particle < particleTime { recent = candidate; break }
                }
            }
            if let recent { chosen = recent }
            else {
                var low = 0, high = count
                while low < high {
                    let middle = (low + high) / 2
                    if segment(middle).particle < particleTime { low = middle + 1 } else { high = middle }
                }
                guard low > 0 else { return nil }
                chosen = segment(low - 1)
            }
        }
        guard chosen.rate > 0 else { return nil }
        let result = chosen.scene + (particleTime - chosen.particle) / chosen.rate
        return result.isFinite ? result : nil
    }
}
