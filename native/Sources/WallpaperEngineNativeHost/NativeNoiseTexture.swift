import Foundation

/// Independently generated, tileable noise for engine-owned utility textures
/// that are not present in Workshop packages. These are explicit compatibility
/// approximations; their pixel values do not match the proprietary assets.
enum NativeNoiseTexture {
    /// Same deterministic fallback in both renderers; author/imported TEX
    /// resources take precedence. This is not the vendor noise image.
    static func whiteRGBA() -> [UInt8] {
        var state: UInt32 = 0x92f74a01
        var pixels: [UInt8] = []; pixels.reserveCapacity(256 * 256 * 4)
        for _ in 0..<(256 * 256) {
            for _ in 0..<3 {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                pixels.append(UInt8(truncatingIfNeeded: state))
            }
            pixels.append(255)
        }
        return pixels
    }
    static func rgba(size: Int = 256, fractal: Bool) -> [UInt8] {
        precondition(size > 0 && size <= 1024)
        var pixels = [UInt8](); pixels.reserveCapacity(size * size * 4)
        for y in 0..<size { for x in 0..<size {
            for channel in 0..<3 {
                var sum: Float = 0, weight: Float = 1, total: Float = 0
                for octave in 0..<(fractal ? 5 : 1) {
                    let period = (fractal ? 4 : 8) << octave
                    let px = Float(x) * Float(period) / Float(size), py = Float(y) * Float(period) / Float(size)
                    sum += gradientNoise(x: px, y: py, period: period, seed: UInt32(channel * 131 + octave * 17 + 0x5421)) * weight
                    total += weight; weight *= 0.5
                }
                pixels.append(UInt8(clamping: Int((0.5 + 0.5 * sum / total) * 255)))
            }
            pixels.append(255)
        } }
        return pixels
    }

    private static func gradientNoise(x: Float, y: Float, period: Int, seed: UInt32) -> Float {
        let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        func fade(_ t: Float) -> Float { t*t*t*(t*(t*6 - 15) + 10) }
        func gradient(_ gx: Int, _ gy: Int, _ dx: Float, _ dy: Float) -> Float {
            var hash = UInt32((gx % period + period) % period) &* 0x9e3779b1
            hash ^= UInt32((gy % period + period) % period) &* 0x85ebca77; hash ^= seed
            hash ^= hash >> 16; hash = hash &* 0x7feb352d; hash ^= hash >> 15
            let diagonal: Float = 0.70710678118
            switch hash & 7 {
            case 0: return dx
            case 1: return -dx
            case 2: return dy
            case 3: return -dy
            case 4: return (dx + dy) * diagonal
            case 5: return (dx - dy) * diagonal
            case 6: return (-dx + dy) * diagonal
            default: return (-dx - dy) * diagonal
            }
        }
        let a = gradient(ix, iy, fx, fy), b = gradient(ix + 1, iy, fx - 1, fy)
        let c = gradient(ix, iy + 1, fx, fy - 1), d = gradient(ix + 1, iy + 1, fx - 1, fy - 1)
        let u = fade(fx), v = fade(fy)
        return (a + (b - a) * u) * (1 - v) + (c + (d - c) * u) * v
    }
}
