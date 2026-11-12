import Foundation
import simd

/// Deterministic, graphics-API-independent placement for the projection-source
/// atlas. This is native resource policy, not a claim about Wallpaper Engine's
/// internal atlas strategy. Callers must clear the allocated atlas to black
/// before copying each `content` rectangle, which preserves the one-texel
/// gutter on every side without resizing a source texture.
struct NativeProjectionAtlasLayout {
    static let maximumSources = 12
    static let gutter = 1
    static let defaultMaximumDimension = 16_384
    static let defaultMaximumBytes = 256 * 1024 * 1024

    struct Input: Hashable, Sendable {
        let id: String
        let width: Int
        let height: Int

        init(id: String, width: Int, height: Int) {
            self.id = id
            self.width = width
            self.height = height
        }
    }

    struct Rect: Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        var maxX: Int { x + width }
        var maxY: Int { y + height }
    }

    struct Entry: Equatable, Sendable {
        let id: String
        /// The source-sized rectangle copied into the atlas.
        let content: Rect
        /// Content plus exactly one texel on all four sides. These texels are
        /// left black by the caller's clear pass and are never source-resampled.
        let allocated: Rect
        /// (uOffset, vOffset, uScale, vScale), top-left texture convention.
        let normalizedContent: SIMD4<Float>
    }

    enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidLimit(String)
        case unsupportedBytesPerPixel(Int)
        case invalidIdentifier
        case invalidSourceSize(String)
        case sourceExceedsDimension(String)
        case conflictingDuplicate(String)
        case tooManySources(Int)
        case arithmeticOverflow
        case cannotPack
        case byteBudgetExceeded

        var errorDescription: String? {
            switch self {
            case .invalidLimit(let name): return "投影图集 \(name) 必须为正数。"
            case .unsupportedBytesPerPixel(let value): return "投影图集仅支持每像素 4 或 8 字节，当前为 \(value)。"
            case .invalidIdentifier: return "投影图集纹理 ID 不能为空。"
            case .invalidSourceSize(let id): return "投影纹理 \(id) 的尺寸必须为正数。"
            case .sourceExceedsDimension(let id): return "投影纹理 \(id) 连同 1 像素边框超过图集边长限制。"
            case .conflictingDuplicate(let id): return "投影图集出现尺寸不同的重复纹理 ID：\(id)。"
            case .tooManySources(let count): return "投影图集最多支持 \(NativeProjectionAtlasLayout.maximumSources) 个不同纹理，当前为 \(count)。"
            case .arithmeticOverflow: return "投影图集尺寸或字节数溢出。"
            case .cannotPack: return "投影纹理无法在当前图集边长限制内保持原始分辨率排布。"
            case .byteBudgetExceeded: return "投影图集超过当前内存预算。"
            }
        }
    }

    let width: Int
    let height: Int
    let bytesPerPixel: Int
    let allocatedBytes: Int
    let entries: [String: Entry]

    init(inputs: [Input], maxDimension: Int = NativeProjectionAtlasLayout.defaultMaximumDimension,
         maximumBytes: Int = NativeProjectionAtlasLayout.defaultMaximumBytes, bytesPerPixel: Int = 4) throws {
        guard maxDimension > 0 else { throw Error.invalidLimit("最大边长") }
        guard maximumBytes > 0 else { throw Error.invalidLimit("最大字节数") }
        guard bytesPerPixel == 4 || bytesPerPixel == 8 else { throw Error.unsupportedBytesPerPixel(bytesPerPixel) }

        var unique: [String: Input] = [:]
        for input in inputs {
            guard !input.id.isEmpty else { throw Error.invalidIdentifier }
            guard input.width > 0, input.height > 0 else { throw Error.invalidSourceSize(input.id) }
            if let previous = unique[input.id] {
                guard previous.width == input.width, previous.height == input.height else { throw Error.conflictingDuplicate(input.id) }
                continue
            }
            unique[input.id] = input
        }
        guard unique.count <= Self.maximumSources else { throw Error.tooManySources(unique.count) }
        if unique.isEmpty {
            let required = try Self.bytes(width: 1, height: 1, bytesPerPixel: bytesPerPixel)
            guard required <= maximumBytes else { throw Error.byteBudgetExceeded }
            width = 1; height = 1; self.bytesPerPixel = bytesPerPixel; allocatedBytes = required; entries = [:]
            return
        }

        let padded = try unique.values.map { input -> PaddedInput in
            let paddedWidth = try Self.add(input.width, 2)
            let paddedHeight = try Self.add(input.height, 2)
            guard paddedWidth <= maxDimension, paddedHeight <= maxDimension else { throw Error.sourceExceedsDimension(input.id) }
            return PaddedInput(input: input, width: paddedWidth, height: paddedHeight)
        }.sorted { left, right in
            if left.height != right.height { return left.height > right.height }
            if left.width != right.width { return left.width > right.width }
            return left.input.id < right.input.id
        }

        let candidateWidths = try Self.candidateWidths(padded, maxDimension: maxDimension)
        var best: Candidate?
        var overflowObserved = false
        var byteBudgetObserved = false
        for candidateWidth in candidateWidths {
            guard let packed = try Self.pack(padded, candidateWidth: candidateWidth, maxDimension: maxDimension) else { continue }
            do {
                let required = try Self.bytes(width: packed.width, height: packed.height, bytesPerPixel: bytesPerPixel)
                guard required <= maximumBytes else { byteBudgetObserved = true; continue }
                let candidate = Candidate(width: packed.width, height: packed.height, bytes: required, entries: packed.entries)
                if let current = best {
                    if candidate.isPreferred(to: current) { best = candidate }
                } else { best = candidate }
            } catch Error.arithmeticOverflow {
                overflowObserved = true
            }
        }
        guard let best else {
            if overflowObserved { throw Error.arithmeticOverflow }
            if byteBudgetObserved { throw Error.byteBudgetExceeded }
            throw Error.cannotPack
        }
        width = best.width
        height = best.height
        self.bytesPerPixel = bytesPerPixel
        allocatedBytes = best.bytes
        entries = best.entries
    }

    private struct PaddedInput {
        let input: Input
        let width: Int
        let height: Int
    }

    private struct Packed {
        let width: Int
        let height: Int
        let entries: [String: Entry]
    }

    private struct Candidate {
        let width: Int
        let height: Int
        let bytes: Int
        let entries: [String: Entry]

        func isPreferred(to other: Candidate) -> Bool {
            let area = width * height
            let otherArea = other.width * other.height
            if area != otherArea { return area < otherArea }
            let longest = max(width, height), otherLongest = max(other.width, other.height)
            if longest != otherLongest { return longest < otherLongest }
            if width != other.width { return width < other.width }
            return height < other.height
        }
    }

    private static func candidateWidths(_ inputs: [PaddedInput], maxDimension: Int) throws -> [Int] {
        var candidates: Set<Int> = [maxDimension]
        for start in inputs.indices {
            var total = 0
            for end in start..<inputs.count {
                do { total = try add(total, inputs[end].width) }
                catch Error.arithmeticOverflow { break }
                if total <= maxDimension { candidates.insert(total) }
                else { break }
            }
        }
        let approximateArea = inputs.reduce(0.0) { partial, input in partial + Double(input.width) * Double(input.height) }
        let approximateWidth = ceil(approximateArea.squareRoot())
        if approximateWidth.isFinite, approximateWidth >= 1, approximateWidth <= Double(maxDimension) {
            candidates.insert(Int(approximateWidth))
        }
        return candidates.sorted()
    }

    private static func pack(_ inputs: [PaddedInput], candidateWidth: Int, maxDimension: Int) throws -> Packed? {
        guard candidateWidth > 0, candidateWidth <= maxDimension else { return nil }
        var x = 0, y = 0, rowHeight = 0, usedWidth = 0
        var result: [String: Entry] = [:]
        for input in inputs {
            if input.width > candidateWidth { return nil }
            let remaining = try add(x, input.width)
            if remaining > candidateWidth {
                y = try add(y, rowHeight)
                x = 0; rowHeight = 0
            }
            let bottom = try add(y, input.height)
            guard bottom <= maxDimension else { return nil }
            let right = try add(x, input.width)
            let allocated = Rect(x: x, y: y, width: input.width, height: input.height)
            let content = Rect(x: try add(x, Self.gutter), y: try add(y, Self.gutter),
                               width: input.input.width, height: input.input.height)
            result[input.input.id] = Entry(id: input.input.id, content: content, allocated: allocated,
                normalizedContent: .zero)
            x = right; rowHeight = max(rowHeight, input.height); usedWidth = max(usedWidth, right)
        }
        let usedHeight = try add(y, rowHeight)
        guard usedWidth > 0, usedHeight > 0 else { return nil }
        let normalized = result.mapValues { entry in
            let c = entry.content
            return Entry(id: entry.id, content: c, allocated: entry.allocated,
                normalizedContent: SIMD4(Float(c.x) / Float(usedWidth), Float(c.y) / Float(usedHeight),
                                        Float(c.width) / Float(usedWidth), Float(c.height) / Float(usedHeight)))
        }
        return Packed(width: usedWidth, height: usedHeight, entries: normalized)
    }

    private static func add(_ left: Int, _ right: Int) throws -> Int {
        let (value, overflow) = left.addingReportingOverflow(right)
        guard !overflow else { throw Error.arithmeticOverflow }
        return value
    }

    private static func bytes(width: Int, height: Int, bytesPerPixel: Int) throws -> Int {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else { throw Error.arithmeticOverflow }
        let (value, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
        guard !byteOverflow else { throw Error.arithmeticOverflow }
        return value
    }
}

