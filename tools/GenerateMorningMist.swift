import Foundation
import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO

// Original procedural artwork. Development tool; no renderer or dependency
// from another wallpaper application is used or packaged.
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let width = 960, height = 540, fps: Int32 = 30, frames = 300
let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_600_000, AVVideoMaxKeyFrameIntervalKey: 30]])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
writer.add(input)
guard writer.startWriting() else { throw writer.error! }
writer.startSession(atSourceTime: .zero)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
for frame in 0..<frames {
    let deadline = Date().addingTimeInterval(10)
    while !input.isReadyForMoreMediaData && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
    guard input.isReadyForMoreMediaData else { fatalError("Video writer stalled") }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer) == kCVReturnSuccess,
          let pixel = buffer else { fatalError("Video allocation failed") }
    CVPixelBufferLockBaseAddress(pixel, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddress(pixel), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel), space: space,
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)!
    let phase = Double(frame) * 2 * .pi / Double(frames)
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.20, green: 0.31, blue: 0.48, alpha: 1),
        CGColor(srgbRed: 0.82, green: 0.62, blue: 0.62, alpha: 1),
        CGColor(srgbRed: 0.99, green: 0.86, blue: 0.68, alpha: 1)] as CFArray,
        locations: [0, 0.58, 1])!
    context.drawLinearGradient(background, start: .zero, end: CGPoint(x: 180, y: height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    let sunX = 690.0 + 28 * sin(phase), sunY = 345.0 + 16 * cos(phase)
    let glow = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 1, green: 0.9, blue: 0.70, alpha: 0.7),
        CGColor(srgbRed: 1, green: 0.8, blue: 0.60, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: sunX, y: sunY), startRadius: 0,
        endCenter: CGPoint(x: sunX, y: sunY), endRadius: 230, options: [])
    for layer in 0..<9 {
        let index = Double(layer)
        let path = CGMutablePath(); path.move(to: CGPoint(x: 0, y: 0))
        for x in stride(from: 0, through: width, by: 8) {
            let u = Double(x) / Double(width)
            let y = 80 + index * 25 + 34 * sin(u * 5.3 + phase + index * 0.42)
                + 12 * cos(u * 9.0 - phase + index * 0.7)
            path.addLine(to: CGPoint(x: Double(x), y: y))
        }
        path.addLine(to: CGPoint(x: width, y: 0)); path.closeSubpath()
        context.addPath(path)
        context.setFillColor(CGColor(srgbRed: 0.35 + index * 0.06, green: 0.50 + index * 0.035,
                                    blue: 0.64 + index * 0.02, alpha: 0.16))
        context.fillPath()
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else { throw writer.error! }
}
input.markAsFinished(); writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: fps))
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
guard finished.wait(timeout: .now() + 30) == .success, writer.status == .completed else { fatalError("Video writer failed") }
if CommandLine.arguments.count > 2 {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: destination))
    generator.appliesPreferredTrackTransform = true
    let image = try generator.copyCGImage(at: CMTime(seconds: 1, preferredTimescale: fps), actualTime: nil)
    let preview = URL(fileURLWithPath: CommandLine.arguments[2])
    guard let output = CGImageDestinationCreateWithURL(preview as CFURL, "public.png" as CFString, 1, nil) else { fatalError("Preview destination unavailable") }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Preview encoding failed") }
}
print("Generated original 960x540, 30 fps, 10 second looping wallpaper")
