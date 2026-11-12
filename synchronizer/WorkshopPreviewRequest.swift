import Foundation
import CoreGraphics
import ImageIO

/// One bounded, cookie-free request for the selected Workshop preview.
/// Delegate callbacks are serialized; image decoding stays off the main queue.
final class WorkshopPreviewRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let byteLimit = 6 * 1024 * 1024
    private static let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.wallpaper-engine-native.workshop-preview"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let completion: (CGImage?) -> Void
    private var payload = Data()
    private var accepted = false
    private var session: URLSession!
    private var task: URLSessionDataTask!

    init(url: URL, completion: @escaping (CGImage?) -> Void) {
        self.completion = completion
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: Self.delegateQueue)
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        task = session.dataTask(with: request)
    }

    func start() { task.resume() }
    func cancel() { task.cancel(); session.invalidateAndCancel() }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, WorkshopPreviewURL.parse(url.absoluteString) != nil else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, WorkshopPreviewURL.parse(url.absoluteString) != nil,
              http.mimeType?.lowercased().hasPrefix("image/") == true,
              http.expectedContentLength < 0 || http.expectedContentLength <= Int64(Self.byteLimit) else {
            completionHandler(.cancel); return
        }
        accepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard accepted, data.count <= Self.byteLimit - payload.count else { dataTask.cancel(); return }
        payload.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let image = error == nil && accepted ? Self.decode(payload) : nil
        payload.removeAll(keepingCapacity: false)
        completion(image)
        session.finishTasksAndInvalidate()
    }

    private static func decode(_ data: Data) -> CGImage? {
        guard !data.isEmpty, data.count <= byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let kind = CGImageSourceGetType(source) as String?,
              ["public.jpeg", "public.png", "com.compuserve.gif", "org.webmproject.webp", "public.heic", "public.heif"].contains(kind),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 32_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
