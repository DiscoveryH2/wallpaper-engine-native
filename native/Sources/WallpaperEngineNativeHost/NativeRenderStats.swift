import Foundation

/// 渲染读数：状态栏的一行，回答"现在跑多少帧、GPU 每帧花多久"。
///
/// Metal 场景由命令缓冲的完成回调交出 GPU 时间；OpenGL 回退路径只能数帧，
/// 所以那里报帧率、不报 GPU 毫秒。窗口取最近 2 秒。
final class NativeRenderStats {
    static let shared = NativeRenderStats()

    private struct Sample {
        let at: Double
        let gpu: Double?
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private let window: Double = 2
    private let capacity = 900

    private init() {}

    /// Metal 命令缓冲完成后调用，可能在任意线程。gpuSeconds 为 0 时只计帧。
    func record(gpuSeconds: Double, at uptime: Double) {
        guard uptime.isFinite else { return }
        let gpu = gpuSeconds.isFinite && gpuSeconds > 0 ? gpuSeconds : nil
        append(Sample(at: uptime, gpu: gpu))
    }

    /// OpenGL 回退路径的每次绘制调用。
    func recordFrame(at uptime: Double) {
        guard uptime.isFinite else { return }
        append(Sample(at: uptime, gpu: nil))
    }

    private func append(_ sample: Sample) {
        lock.lock()
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        while let first = samples.first, sample.at - first.at > window * 4 { samples.removeFirst() }
        lock.unlock()
    }

    /// 主线程读。样本不足时返回空串，状态栏不显示半截数据。
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        guard let last = samples.last else { return "" }
        let recent = samples.filter { last.at - $0.at <= window }
        guard recent.count >= 4, let first = recent.first else { return "" }
        let span = last.at - first.at
        guard span > 0.2 else { return "" }
        let fps = Double(recent.count - 1) / span
        let gpuSamples = recent.compactMap(\.gpu)
        guard gpuSamples.count >= 4 else { return String(format: "%.0f fps", fps) }
        let total = gpuSamples.reduce(0, +)
        let perFrame = total / Double(gpuSamples.count) * 1000
        let occupancy = min(100, total / span * 100)
        return String(format: "%.0f fps · GPU %.1fms/帧 · 占用 %.0f%%", fps, perFrame, occupancy)
    }
}
