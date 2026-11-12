import Foundation

/// Per-scene cap for image-effect working and named render targets. The
/// renderer counts pixels, so RGBA16F targets use twice the RGBA8 bytes.
enum NativeSceneBufferBudget {
    static func imageTargetPixels(physicalMemory: UInt64) -> Int {
        let baseline: UInt64 = 36 * 1024 * 1024
        let maximum: UInt64 = 128 * 1024 * 1024
        // On a 16 GiB Mac this permits 64 Mi pixels: 256 MiB in RGBA8 or
        // 512 MiB in RGBA16F. Preserve the existing floor on smaller Macs.
        let scaled = physicalMemory / 256
        return Int(max(baseline, min(maximum, scaled)))
    }
}
