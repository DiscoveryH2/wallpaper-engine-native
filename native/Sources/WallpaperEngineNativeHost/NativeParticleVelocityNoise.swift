import Foundation

/// Independent Swift expression of the one-dimensional gradient noise observed
/// by REA in the official Android library. The fixed permutation is the standard
/// 256-entry noise permutation, also present in that reference. This does not
/// reproduce the engine's shared random stream or its frame-time sampling.
enum NativeParticleVelocityNoise {
    private static let permutation: [UInt8] = [
        151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225,
        140, 36, 103, 30, 69, 142, 8, 99, 37, 240, 21, 10, 23, 190, 6, 148,
        247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32,
        57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175,
        74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122,
        60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54,
        65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169,
        200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64,
        52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212,
        207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
        119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
        129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104,
        218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241,
        81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157,
        184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93,
        222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
    ]

    static func sample(_ coordinate: Double) -> Float {
        guard coordinate.isFinite else { return 0 }
        // Reduce in Double before indexing/converting: no unbounded integer
        // conversion or loss of all fractional bits after a long session.
        let remainder = coordinate.truncatingRemainder(dividingBy: 256)
        let bounded = remainder < 0 ? remainder + 256 : remainder
        let cell = Int(floor(bounded))
        let fraction = Float(bounded - Double(cell))
        func contribution(_ distance: Float, _ hash: UInt8) -> Float {
            let gradient = Float((hash & 7) + 1) * (hash & 8 == 0 ? 1 : -1)
            let attenuation = 1 - distance * distance
            let squared = attenuation * attenuation
            return squared * squared * gradient * distance
        }
        return 0.395 * (contribution(fraction, permutation[cell & 255]) +
            contribution(fraction - 1, permutation[(cell + 1) & 255]))
    }
}
