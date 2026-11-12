import AppKit

protocol WorkshopPreviewFetching: AnyObject {
    func start()
    func cancel()
}
extension WorkshopPreviewRequest: WorkshopPreviewFetching {}

/// Shared by the visible tiles and inspector of one page. Limits both network
/// work and decoded memory; the request retains its existing Steam URL policy.
@MainActor
final class NativeWorkshopThumbnails {
    typealias Factory = (URL, @escaping (CGImage?) -> Void) -> WorkshopPreviewFetching
    private let factory: Factory
    private let cache = NSCache<NSString, NSImage>()
    private var requests: [String: WorkshopPreviewFetching] = [:]
    private var waiting: [(String, URL)] = []
    private var callbacks: [String: [(NSImage?) -> Void]] = [:]
    private var failed: Set<String> = []
    private var generation = 0

    init(factory: @escaping Factory = { WorkshopPreviewRequest(url: $0, completion: $1) }) {
        self.factory = factory
        cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 80
    }
    func image(for url: URL) -> NSImage? { cache.object(forKey: url.absoluteString as NSString) }
    func load(_ url: URL, retry: Bool = false, completion: @escaping (NSImage?) -> Void) {
        let key = url.absoluteString
        guard WorkshopPreviewURL.parse(key) != nil else { completion(nil); return }
        if let image = image(for: url) { completion(image); return }
        if retry { failed.remove(key) }
        guard !failed.contains(key) else { completion(nil); return }
        if callbacks[key] != nil { callbacks[key]?.append(completion); return }
        callbacks[key] = [completion]; waiting.append((key, url)); pump()
    }
    func cancelAll() {
        generation += 1
        let cancelled = Array(requests.values)
        requests.removeAll(); waiting.removeAll(); callbacks.removeAll(); failed.removeAll()
        cancelled.forEach { $0.cancel() }
    }
    private func pump() {
        while requests.count < 3, !waiting.isEmpty {
            let (key, url) = waiting.removeFirst(), expected = generation
            let request = factory(url) { [weak self] image in
                DispatchQueue.main.async {
                    guard let self, self.generation == expected else { return }
                    self.requests.removeValue(forKey: key)
                    let decoded = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    if let decoded, let image { self.cache.setObject(decoded, forKey: key as NSString, cost: image.bytesPerRow * image.height) }
                    else { self.failed.insert(key) }
                    let completions = self.callbacks.removeValue(forKey: key) ?? []
                    completions.forEach { $0(decoded) }
                    self.pump()
                }
            }
            requests[key] = request; request.start()
        }
    }
}
