import Foundation
import ImageIO
import Darwin

enum SceneError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

// Observed directory layouts only. Real 0008 and 0023 archives use the same
// length-prefixed paths and relative offset/size table as the earlier samples.
// Every entry still passes the same path, size, bounds and overlap checks.
private let scenePackageVersions: Set<String> = ["PKGV0001", "PKGV0004", "PKGV0005", "PKGV0008", "PKGV0018", "PKGV0021", "PKGV0022", "PKGV0023"]
private let textureVersionMagic = Array("TEXV0005\0".utf8)
private let textureInfoMagic = Array("TEXI0001\0".utf8)
private let textureBlockMagicV2 = Array("TEXB0002\0".utf8)
private let textureBlockMagicV3 = Array("TEXB0003\0".utf8)
private let textureBlockMagicV4 = Array("TEXB0004\0".utf8)

// Limits apply before extracting, decompressing, or allocating derived pixels.
// A TEX container may hold a large padded base plus smaller authored mips;
// its encoded-file limit is separate from the selected mip's allocation limit.
private let sceneMaxPackageBytes = 512 * 1024 * 1024
private let sceneMaxLooseFiles = 10_000
private let sceneMaxIndexedBytes = 512 * 1024 * 1024
private let sceneMaxResourceBytes = 64 * 1024 * 1024
private let sceneMaxTextureResourceBytes = 128 * 1024 * 1024
private let sceneMaxTextBytes = 4 * 1024 * 1024
private let sceneMaxMeshVertices = 1_000_000
private let sceneMaxMeshIndices = 3_000_000
private let sceneMaxTextureDimension = 16_384
private let sceneMaxTextureMips = 16
private let sceneMaxTextureMipBytes = 64 * 1024 * 1024
private let sceneMaxTextureDecodedBytes = 256 * 1024 * 1024
private let sceneMaxTextureRGBABytes = 64 * 1024 * 1024

private func sceneResourceByteLimit(_ path: String) -> Int {
    path.lowercased().hasSuffix(".tex") ? sceneMaxTextureResourceBytes : sceneMaxResourceBytes
}

private func sceneInvalid(_ message: String) -> SceneError {
    .invalid(message)
}

// Wallpaper Engine's authored Scene documents are JSONC in practice: the
// checked-in Windows 26168761 Motion Blur effect, for example, contains a
// commented-out `preview` member.  Foundation only accepts strict JSON.  Keep
// this deliberately small rather than accepting a broader dialect: comments
// are recognized only outside strings, their non-newline bytes become spaces
// (so JSON parser offsets/lines stay meaningful), and all other JSON syntax
// remains Foundation's responsibility.
private func sceneJSONAdvanceLine(_ byte: UInt8, line: inout Int, previousWasCR: inout Bool) {
    switch byte {
    case 0x0D: // CR
        line += 1
        previousWasCR = true
    case 0x0A: // LF; CRLF is one logical line break.
        if !previousWasCR { line += 1 }
        previousWasCR = false
    default:
        previousWasCR = false
    }
}

private func sceneJSONLocation(_ bytes: [UInt8], at offset: Int) -> (line: Int, byteColumn: Int) {
    let end = min(max(offset, 0), bytes.count)
    var line = 1, byteColumn = 1, previousWasCR = false
    for byte in bytes.prefix(end) {
        switch byte {
        case 0x0D:
            line += 1; byteColumn = 1; previousWasCR = true
        case 0x0A:
            if !previousWasCR { line += 1 }
            byteColumn = 1; previousWasCR = false
        default:
            byteColumn += 1; previousWasCR = false
        }
    }
    return (line, byteColumn)
}

private func sceneJSONCNormalizedData(_ bytes: Data, path: String) throws -> (data: Data, changed: Bool) {
    // This is intentionally after the strict-JSON fast path in
    // `sceneJSONValue`: Foundation accepts UTF-16 JSON with a BOM, which is
    // already valid Scene JSON and must retain that existing behavior.  JSONC
    // comments themselves are accepted only in UTF-8 input.
    guard String(data: bytes, encoding: .utf8) != nil else {
        throw sceneInvalid("Scene JSON is not valid UTF-8: \(path)")
    }

    let source = Array(bytes)
    var normalized = source
    var cursor = 0
    var line = 1
    var inString = false
    var escaped = false
    var previousWasCR = false
    var changed = false
    let quote: UInt8 = 0x22
    let slash: UInt8 = 0x2F
    let backslash: UInt8 = 0x5C
    let asterisk: UInt8 = 0x2A
    let space: UInt8 = 0x20

    while cursor < source.count {
        let byte = source[cursor]
        if inString {
            if escaped {
                escaped = false
            } else if byte == backslash {
                escaped = true
            } else if byte == quote {
                inString = false
            }
            sceneJSONAdvanceLine(byte, line: &line, previousWasCR: &previousWasCR)
            cursor += 1
            continue
        }

        if byte == quote {
            inString = true
            sceneJSONAdvanceLine(byte, line: &line, previousWasCR: &previousWasCR)
            cursor += 1
            continue
        }
        guard byte == slash, cursor + 1 < source.count else {
            sceneJSONAdvanceLine(byte, line: &line, previousWasCR: &previousWasCR)
            cursor += 1
            continue
        }

        let next = source[cursor + 1]
        if next == slash {
            // Preserve both CR and LF exactly.  In particular, replacing the
            // CR in a CRLF comment would shift Foundation's reported line.
            normalized[cursor] = space
            normalized[cursor + 1] = space
            changed = true
            sceneJSONAdvanceLine(byte, line: &line, previousWasCR: &previousWasCR)
            sceneJSONAdvanceLine(next, line: &line, previousWasCR: &previousWasCR)
            cursor += 2
            while cursor < source.count, source[cursor] != 0x0D, source[cursor] != 0x0A {
                normalized[cursor] = space
                sceneJSONAdvanceLine(source[cursor], line: &line, previousWasCR: &previousWasCR)
                cursor += 1
            }
            continue
        }

        guard next == asterisk else {
            sceneJSONAdvanceLine(byte, line: &line, previousWasCR: &previousWasCR)
            cursor += 1
            continue
        }

        let openingLine = line
        normalized[cursor] = space
        normalized[cursor + 1] = space
        changed = true
        sceneJSONAdvanceLine(byte, line: &line, previousWasCR: &previousWasCR)
        sceneJSONAdvanceLine(next, line: &line, previousWasCR: &previousWasCR)
        cursor += 2
        var closed = false
        while cursor < source.count {
            let commentByte = source[cursor]
            if commentByte == asterisk, cursor + 1 < source.count, source[cursor + 1] == slash {
                normalized[cursor] = space
                normalized[cursor + 1] = space
                sceneJSONAdvanceLine(commentByte, line: &line, previousWasCR: &previousWasCR)
                sceneJSONAdvanceLine(source[cursor + 1], line: &line, previousWasCR: &previousWasCR)
                cursor += 2
                closed = true
                break
            }
            if commentByte != 0x0D, commentByte != 0x0A { normalized[cursor] = space }
            sceneJSONAdvanceLine(commentByte, line: &line, previousWasCR: &previousWasCR)
            cursor += 1
        }
        guard closed else {
            throw sceneInvalid("Unclosed block comment in Scene JSON \(path) at line \(openingLine).")
        }
    }

    return (changed ? Data(normalized) : bytes, changed)
}

func sceneJSONValue(_ bytes: Data, path: String) throws -> Any {
    // Preserve all strict Foundation JSON behavior (including UTF-16 LE/BE
    // with a BOM) without copying or reinterpreting those bytes.
    do { return try JSONSerialization.jsonObject(with: bytes) }
    catch {
        let strictError = error
        let normalized = try sceneJSONCNormalizedData(bytes, path: path)
        // This was malformed strict JSON rather than JSONC.  Keep the
        // pre-existing Foundation failure shape instead of changing it merely
        // because the scanner was consulted after the fast path failed.
        guard normalized.changed else {
            throw sceneInvalid("Could not parse Scene JSON \(path): \(strictError.localizedDescription)")
        }
        do { return try JSONSerialization.jsonObject(with: normalized.data) }
        catch {
            let nsError = error as NSError
            if let index = (nsError.userInfo["NSJSONSerializationErrorIndex"] as? NSNumber)?.intValue {
                let location = sceneJSONLocation(Array(normalized.data), at: index)
                throw sceneInvalid("Could not parse Scene JSON \(path) at line \(location.line), byte column \(location.byteColumn): \(error.localizedDescription)")
            }
            throw sceneInvalid("Could not parse Scene JSON \(path): \(error.localizedDescription)")
        }
    }
}

private func sceneCheckedAdd(_ left: Int, _ right: Int, _ label: String) throws -> Int {
    let result = left.addingReportingOverflow(right)
    guard !result.overflow else { throw sceneInvalid("Integer overflow while reading \(label).") }
    return result.partialValue
}

private func sceneCheckedMultiply(_ left: Int, _ right: Int, _ label: String) throws -> Int {
    let result = left.multipliedReportingOverflow(by: right)
    guard !result.overflow else { throw sceneInvalid("Integer overflow while reading \(label).") }
    return result.partialValue
}

private func sceneInt(_ value: UInt32, _ label: String) throws -> Int {
    guard UInt64(value) <= UInt64(Int.max) else { throw sceneInvalid("\(label) exceeds this process's integer range.") }
    return Int(value)
}

private func sceneSafeRelativePath(_ rawPath: String) throws -> String {
    guard !rawPath.isEmpty,
          !rawPath.hasPrefix("/"),
          !rawPath.hasPrefix("~"),
          !rawPath.contains("\\"),
          !rawPath.contains(":"),
          !rawPath.utf8.contains(0)
    else {
        throw sceneInvalid("Unsafe Scene resource path: \(rawPath)")
    }
    let parts = rawPath.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty,
          !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else {
        throw sceneInvalid("Unsafe Scene resource path: \(rawPath)")
    }
    return parts.map(String.init).joined(separator: "/")
}

private func sceneCaseFoldedPath(_ path: String) -> String {
    path.lowercased(with: Locale(identifier: "en_US_POSIX"))
}

private func sceneIsContained(_ candidate: URL, in directory: URL) -> Bool {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
    let value = candidate.standardizedFileURL.resolvingSymlinksInPath().path
    return value == root || value.hasPrefix(root + "/")
}

private func sceneReadBoundedFile(_ url: URL, maximumBytes: Int, label: String) throws -> Data {
    guard maximumBytes >= 0 else { throw sceneInvalid("Negative read limit for \(label).") }
    let readLimit = try sceneCheckedAdd(maximumBytes, 1, "\(label) read limit")
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw sceneInvalid("Could not open \(label): \(error.localizedDescription)")
    }
    defer { try? handle.close() }
    do {
        let bytes = try handle.read(upToCount: readLimit) ?? Data()
        guard bytes.count <= maximumBytes else {
            throw sceneInvalid("\(label) exceeds its \(maximumBytes)-byte limit.")
        }
        return bytes
    } catch let error as SceneError {
        throw error
    } catch {
        throw sceneInvalid("Could not read \(label): \(error.localizedDescription)")
    }
}

struct SceneByteReader {
    private let storage: Data
    private(set) var offset = 0

    init(_ storage: Data) {
        self.storage = storage
    }

    private mutating func require(_ count: Int, _ label: String) throws {
        guard count >= 0 else { throw sceneInvalid("Negative length while reading \(label).") }
        let end = try sceneCheckedAdd(offset, count, label)
        guard end <= storage.count else {
            throw sceneInvalid("Truncated \(label) at byte \(offset).")
        }
    }

    mutating func readData(_ count: Int, _ label: String) throws -> Data {
        try require(count, label)
        let start = storage.startIndex + offset
        let end = start + count
        offset += count
        return Data(storage[start..<end])
    }

    mutating func skip(_ count: Int, _ label: String) throws {
        try require(count, label)
        offset += count
    }

    mutating func readUInt32(_ label: String) throws -> UInt32 {
        try require(4, label)
        let index = storage.startIndex + offset
        let value = UInt32(storage[index])
            | (UInt32(storage[index + 1]) << 8)
            | (UInt32(storage[index + 2]) << 16)
            | (UInt32(storage[index + 3]) << 24)
        offset += 4
        return value
    }

    mutating func readUInt16(_ label: String) throws -> UInt16 {
        try require(2, label)
        let index = storage.startIndex + offset
        let value = UInt16(storage[index]) | (UInt16(storage[index + 1]) << 8)
        offset += 2
        return value
    }

    mutating func readUInt8(_ label: String) throws -> UInt8 {
        try require(1, label)
        defer { offset += 1 }
        return storage[storage.startIndex + offset]
    }

    mutating func readUInt64(_ label: String) throws -> UInt64 {
        let lower = try readUInt32(label)
        return UInt64(lower) | (UInt64(try readUInt32(label)) << 32)
    }

    mutating func readFloat32(_ label: String) throws -> Float {
        Float(bitPattern: try readUInt32(label))
    }

    mutating func readUTF8(_ byteCount: Int, _ label: String) throws -> String {
        let raw = try readData(byteCount, label)
        guard let value = String(data: raw, encoding: .utf8) else {
            throw sceneInvalid("\(label) is not valid UTF-8.")
        }
        return value
    }

    mutating func readLengthPrefixedUTF8(maxBytes: Int, _ label: String) throws -> String {
        let byteCount = try sceneInt(readUInt32("\(label) length"), "\(label) length")
        guard byteCount <= maxBytes else {
            throw sceneInvalid("\(label) exceeds its \(maxBytes)-byte limit.")
        }
        return try readUTF8(byteCount, label)
    }

    mutating func expect(_ expected: [UInt8], _ label: String) throws {
        let actual = Array(try readData(expected.count, label))
        guard actual == expected else { throw sceneInvalid("Unexpected \(label).") }
    }

    mutating func readNullTerminatedUTF8(maxBytes: Int, _ label: String) throws -> String {
        let start = offset
        var length = 0
        while true {
            guard length <= maxBytes else {
                throw sceneInvalid("\(label) exceeds its \(maxBytes)-byte limit.")
            }
            try require(1, label)
            let byte = storage[storage.startIndex + offset]
            offset += 1
            if byte == 0 { break }
            length += 1
        }
        let lower = storage.startIndex + start
        let upper = lower + length
        guard let value = String(data: storage[lower..<upper], encoding: .utf8) else {
            throw sceneInvalid("\(label) is not valid UTF-8.")
        }
        return value
    }

    func requireEnd(_ label: String) throws {
        guard offset == storage.count else {
            throw sceneInvalid("Unsupported trailing bytes in \(label).")
        }
    }
}

// The index and archive are immutable after initialization. Each loose-file
// read opens its own handle and fresh URL; parsed JSON is returned to its caller.
final class SceneAssets: @unchecked Sendable {
    private enum Location {
        case package(offset: Int, length: Int)
        case loose(url: URL, length: Int)
    }

    private let directory: URL
    private let packageData: Data?
    private let index: [String: Location]

    init(directory: URL) throws {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw sceneInvalid("Scene directory is unavailable: \(directory.path)")
        }

        var resources: [String: Location] = [:]
        var indexedBytes = 0
        var archive: Data?
        let packageURL = root.appendingPathComponent("scene.pkg")
        if FileManager.default.fileExists(atPath: packageURL.path) {
            let packageValues = try packageURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let resolvedPackageURL = packageURL.standardizedFileURL.resolvingSymlinksInPath()
            guard packageValues.isRegularFile == true,
                  packageValues.isSymbolicLink != true,
                  sceneIsContained(resolvedPackageURL, in: root) else {
                throw sceneInvalid("scene.pkg must be a regular, non-symbolic-link file inside the Scene directory.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: packageURL.path)
            let packageSize = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard packageSize >= 0, packageSize <= sceneMaxPackageBytes else {
                throw sceneInvalid("scene.pkg exceeds the \(sceneMaxPackageBytes)-byte package limit.")
            }
            let bytes = try sceneReadBoundedFile(packageURL, maximumBytes: sceneMaxPackageBytes, label: "scene.pkg")
            guard bytes.count == packageSize else {
                throw sceneInvalid("scene.pkg changed while it was indexed.")
            }
            let packageEntries = try Self.indexPackage(bytes)
            for (path, location) in packageEntries {
                resources[path] = location
            }
            indexedBytes = try sceneCheckedAdd(indexedBytes, packageSize, "package index size")
            archive = bytes
        }

        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in false }
        ) else {
            throw sceneInvalid("Could not enumerate Scene directory: \(root.path)")
        }

        var looseCount = 0
        while let object = enumerator.nextObject() {
            guard let url = object as? URL else { continue }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: resourceKeys)
            } catch {
                throw sceneInvalid("Could not inspect Scene resource \(url.path): \(error.localizedDescription)")
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            guard sceneIsContained(resolved, in: root) else { continue }
            if resolved.path == packageURL.standardizedFileURL.resolvingSymlinksInPath().path { continue }
            let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard resolved.path.hasPrefix(rootPath) else { continue }
            let relative = String(resolved.path.dropFirst(rootPath.count))
            let safePath = try sceneSafeRelativePath(relative)
            let size = values.fileSize ?? -1
            let resourceLimit = sceneResourceByteLimit(safePath)
            guard size >= 0, size <= resourceLimit else {
                throw sceneInvalid("Loose Scene resource \(safePath) exceeds the \(resourceLimit)-byte limit.")
            }
            looseCount += 1
            guard looseCount <= sceneMaxLooseFiles else {
                throw sceneInvalid("Scene directory exceeds the \(sceneMaxLooseFiles)-file limit.")
            }
            indexedBytes = try sceneCheckedAdd(indexedBytes, size, "loose resource index size")
            guard indexedBytes <= sceneMaxIndexedBytes else {
                throw sceneInvalid("Scene package and loose resources exceed the \(sceneMaxIndexedBytes)-byte limit.")
            }
            let key = sceneCaseFoldedPath(safePath)
            // A safe loose file intentionally overrides a same-named package member.
            resources[key] = .loose(url: resolved, length: size)
        }

        self.directory = root
        self.packageData = archive
        self.index = resources
    }

    func contains(_ path: String) -> Bool {
        guard let safePath = try? sceneSafeRelativePath(path) else { return false }
        return index[sceneCaseFoldedPath(safePath)] != nil
    }

    /// Only immutable package members can be compared across snapshots. Loose
    /// files may change independently of their indexed metadata and must use the
    /// ordinary decoder instead of an inventory retained by a previous view.
    func hasIdenticalPackagedResource(_ path: String, in previous: SceneAssets) -> Bool {
        guard let safePath = try? sceneSafeRelativePath(path) else { return false }
        let key = sceneCaseFoldedPath(safePath)
        guard case let .package(offset, length)? = index[key],
              case let .package(oldOffset, oldLength)? = previous.index[key],
              length == oldLength, offset >= 0, oldOffset >= 0, length >= 0,
              let bytes = packageData, let oldBytes = previous.packageData,
              offset <= bytes.count, length <= bytes.count - offset,
              oldOffset <= oldBytes.count, length <= oldBytes.count - oldOffset else { return false }
        guard length > 0 else { return true }
        return bytes.withUnsafeBytes { current in
            oldBytes.withUnsafeBytes { old in
                guard let a = current.baseAddress, let b = old.baseAddress else { return false }
                return memcmp(a.advanced(by: offset), b.advanced(by: oldOffset), length) == 0
            }
        }
    }

    /// Bounded header inspection without loading every static texture again.
    func prefix(_ path: String, count: Int) throws -> Data {
        let key = sceneCaseFoldedPath(try sceneSafeRelativePath(path))
        guard (0...4096).contains(count), let location = index[key] else { throw sceneInvalid("Invalid Scene header request.") }
        switch location {
        case .package(let offset, let length):
            guard let packageData else { throw sceneInvalid("Scene package is unavailable.") }
            return Data(packageData[(packageData.startIndex + offset)..<(packageData.startIndex + offset + min(count, length))])
        case .loose(let url, let length):
            // Directory-enumerator URLs cache their resource values. Create a
            // fresh URL before checking a later read against the original index.
            let current = URL(fileURLWithPath: url.path)
            let resolved = current.resolvingSymlinksInPath()
            let values = try current.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard sceneIsContained(resolved, in: directory), values.isRegularFile == true,
                  values.isSymbolicLink != true, values.fileSize == length else { throw sceneInvalid("Scene header resource changed after indexing.") }
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: min(count, length)) ?? Data()
            guard data.count == min(count, length) else { throw sceneInvalid("Truncated Scene resource header.") }
            return data
        }
    }

    func data(_ path: String, maximumBytes: Int = sceneMaxResourceBytes) throws -> Data {
        let safePath = try sceneSafeRelativePath(path)
        let resourceLimit = min(sceneResourceByteLimit(safePath), maximumBytes)
        guard let location = index[sceneCaseFoldedPath(safePath)] else {
            throw sceneInvalid("Scene resource does not exist: \(safePath)")
        }
        switch location {
        case .package(let offset, let length):
            guard length <= resourceLimit, let packageData else {
                throw sceneInvalid("Scene package resource exceeds the in-memory limit: \(safePath)")
            }
            let end = try sceneCheckedAdd(offset, length, "package resource range")
            guard end <= packageData.count else {
                throw sceneInvalid("Scene package resource is outside scene.pkg: \(safePath)")
            }
            let start = packageData.startIndex + offset
            return Data(packageData[start..<(start + length)])
        case .loose(let url, let indexedLength):
            let current = URL(fileURLWithPath: url.path)
            let resolved = current.standardizedFileURL.resolvingSymlinksInPath()
            guard sceneIsContained(resolved, in: directory) else {
                throw sceneInvalid("Loose Scene resource escaped its directory: \(safePath)")
            }
            let values = try current.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size == indexedLength, size <= resourceLimit else {
                throw sceneInvalid("Loose Scene resource changed after indexing: \(safePath)")
            }
            let bytes = try sceneReadBoundedFile(resolved, maximumBytes: indexedLength, label: "Scene resource \(safePath)")
            guard bytes.count == indexedLength else {
                throw sceneInvalid("Loose Scene resource changed while it was read: \(safePath)")
            }
            return bytes
        }
    }

    func text(_ path: String) throws -> String {
        let bytes = try data(path)
        guard bytes.count <= sceneMaxTextBytes else {
            throw sceneInvalid("Scene text resource exceeds the \(sceneMaxTextBytes)-byte limit: \(path)")
        }
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw sceneInvalid("Scene text resource is not UTF-8: \(path)")
        }
        return value
    }

    func jsonValue(_ path: String, maximumBytes: Int = sceneMaxTextBytes) throws -> Any {
        guard maximumBytes >= 0 else { throw sceneInvalid("Negative Scene JSON byte limit: \(path)") }
        let safePath = try sceneSafeRelativePath(path)
        let byteLimit = min(maximumBytes, sceneMaxTextBytes)
        let bytes = try data(safePath, maximumBytes: byteLimit)
        guard bytes.count <= byteLimit else {
            throw sceneInvalid("Scene JSON resource exceeds the \(byteLimit)-byte limit: \(safePath)")
        }
        return try sceneJSONValue(bytes, path: safePath)
    }

    func json(_ path: String) throws -> [String: Any] {
        let safePath = try sceneSafeRelativePath(path)
        guard let object = try jsonValue(safePath) as? [String: Any] else {
            throw sceneInvalid("Scene JSON root must be an object: \(safePath)")
        }
        return object
    }

    private static func indexPackage(_ archive: Data) throws -> [String: Location] {
        var reader = SceneByteReader(archive)
        let version = try reader.readLengthPrefixedUTF8(maxBytes: 64, "PKG version")
        guard scenePackageVersions.contains(version) else {
            throw sceneInvalid("Unsupported Scene package version: \(version)")
        }
        let entryCount = try sceneInt(reader.readUInt32("PKG entry count"), "PKG entry count")
        guard entryCount <= sceneMaxLooseFiles else {
            throw sceneInvalid("Scene package exceeds the \(sceneMaxLooseFiles)-entry limit.")
        }

        struct PendingEntry {
            let path: String
            let relativeOffset: Int
            let length: Int
        }
        var pending: [PendingEntry] = []
        var seen: Set<String> = []
        for entryIndex in 0..<entryCount {
            let rawPath = try reader.readLengthPrefixedUTF8(maxBytes: 4_096, "PKG entry \(entryIndex) path")
            let path = try sceneSafeRelativePath(rawPath)
            let key = sceneCaseFoldedPath(path)
            guard seen.insert(key).inserted else {
                throw sceneInvalid("Duplicate Scene package path: \(path)")
            }
            let relativeOffset = try sceneInt(reader.readUInt32("PKG entry \(entryIndex) offset"), "PKG entry offset")
            let length = try sceneInt(reader.readUInt32("PKG entry \(entryIndex) length"), "PKG entry length")
            let resourceLimit = sceneResourceByteLimit(path)
            guard length <= resourceLimit else {
                throw sceneInvalid("Scene package resource exceeds the \(resourceLimit)-byte limit: \(path)")
            }
            pending.append(PendingEntry(path: path, relativeOffset: relativeOffset, length: length))
        }

        let payloadOffset = reader.offset
        var ranges: [(start: Int, end: Int, path: String)] = []
        var result: [String: Location] = [:]
        for entry in pending {
            let start = try sceneCheckedAdd(payloadOffset, entry.relativeOffset, "PKG member offset")
            let end = try sceneCheckedAdd(start, entry.length, "PKG member length")
            guard end <= archive.count else {
                throw sceneInvalid("Scene package member escapes archive: \(entry.path)")
            }
            ranges.append((start, end, entry.path))
            result[sceneCaseFoldedPath(entry.path)] = .package(offset: start, length: entry.length)
        }
        let ordered = ranges.sorted { $0.start < $1.start }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.end > pair.1.start {
            throw sceneInvalid("Overlapping Scene package members: \(pair.0.path) and \(pair.1.path)")
        }
        return result
    }
}

struct SceneMesh {
    let vertices: [Float]
    let indices: [UInt32]
    let materialPath: String
    let sourceIndexBits: Int
    let componentsPerVertex: Int
    var byteCount: Int { vertices.count * 4 + indices.count * 4 }
    var vertexCount: Int { vertices.count / componentsPerVertex }
}

struct SceneModel {
    let meshes: [SceneMesh]
    let skeleton: NativeModelSkeleton?

    /// The header contains a material-slot count followed by a shape count.
    /// Each shape has its own material paths and buffers. REA MdlData::ParseInMemory
    /// confirms v17 bounds, v15 per-shape format and v21 optional secondary buffers.
    /// The observed skinned layout inserts four UInt32 joints and four Float
    /// weights before UV. Joint indices become exact Float attributes only after
    /// validation; they must never be reinterpreted as tiny Float bit patterns.
    static func decode(_ data: Data) throws -> SceneModel {
        guard data.count <= sceneMaxResourceBytes else { throw sceneInvalid("MDL exceeds its resource limit.") }
        var reader = SceneByteReader(data)
        let version = try reader.readNullTerminatedUTF8(maxBytes: 16, "MDL version")
        guard ["MDLV0004", "MDLV0021"].contains(version) else {
            throw sceneInvalid("Unsupported MDL version: \(version).")
        }
        let modern = version == "MDLV0021"
        let format = try reader.readUInt32("MDL vertex format")
        let materialSlots = try reader.readUInt32("MDL material slots per shape")
        let shapeCount = try sceneInt(reader.readUInt32("MDL shape count"), "MDL shape count")
        let skinned = modern && format == 0x0180000f
        guard format == 0x0f || skinned else {
            throw sceneInvalid("\(version): vertex format 0x\(String(format, radix: 16)) requires unsupported attributes or skinning.")
        }
        guard materialSlots == 1, shapeCount > 0, shapeCount <= 256,
              modern || shapeCount == 1 else {
            throw sceneInvalid("\(version): unsupported material-slot or shape count.")
        }
        var result: [SceneMesh] = [], totalVertices = 0, totalIndices = 0
        for _ in 0..<shapeCount {
            let materialPath = try sceneSafeRelativePath(reader.readNullTerminatedUTF8(maxBytes: 4096, "MDL material path"))
            let flags = try reader.readUInt32("MDL shape flags")
            guard modern ? flags <= 1 : flags == 0 else {
                throw sceneInvalid("\(version): shape flags \(flags) require unsupported data.")
            }
            if modern {
                var bounds: [Float] = []
                for _ in 0..<6 { bounds.append(try reader.readFloat32("MDL shape bounds")) }
                guard bounds.allSatisfy(\.isFinite), (0..<3).allSatisfy({ bounds[$0] <= bounds[$0 + 3] }),
                      try reader.readUInt32("MDL shape vertex format") == format else {
                    throw sceneInvalid("\(version): invalid bounds or unsupported shape vertex format.")
                }
            }
            let components = skinned ? 20 : 12
            let stride = components * 4
            let vertexByteCount = try sceneInt(reader.readUInt32("MDL vertex byte count"), "MDL vertex byte count")
            guard vertexByteCount > 0, vertexByteCount % stride == 0, vertexByteCount <= sceneMaxResourceBytes,
                  vertexByteCount / stride <= sceneMaxMeshVertices - totalVertices else {
                throw sceneInvalid("\(version): unsupported vertex block or total vertex limit exceeded.")
            }
            let vertexCount = vertexByteCount / stride
            totalVertices += vertexCount
            var vertices: [Float] = []
            vertices.reserveCapacity(vertexCount * components)
            for _ in 0..<vertexCount {
                for component in 0..<components {
                    let value: Float
                    if skinned && (10..<14).contains(component) {
                        let joint = try reader.readUInt32("MDL joint index")
                        guard joint < NativeModelSkeleton.maximumBones else { throw sceneInvalid("MDL joint exceeds the bone limit.") }
                        value = Float(joint)
                    } else {
                        value = try reader.readFloat32("MDL vertex component")
                        guard value.isFinite else { throw sceneInvalid("\(version): non-finite vertex component.") }
                    }
                    vertices.append(value)
                }
                if skinned {
                    let base = vertices.count - components
                    let weights = vertices[(base + 14)..<(base + 18)]
                    guard weights.allSatisfy({ $0 >= 0 && $0 <= 1 }), abs(weights.reduce(0, +) - 1) <= 0.001 else {
                        throw sceneInvalid("MDL skin weights must be nonnegative and sum to one.")
                    }
                }
            }
            let indexBytes = flags & 1 == 0 ? 2 : 4
            let indexByteCount = try sceneInt(reader.readUInt32("MDL index byte count"), "MDL index byte count")
            guard indexByteCount > 0, indexByteCount % indexBytes == 0,
                  indexByteCount / indexBytes <= sceneMaxMeshIndices - totalIndices,
                  (indexByteCount / indexBytes) % 3 == 0 else {
                throw sceneInvalid("\(version): unsupported index block or total index limit exceeded.")
            }
            let indexCount = indexByteCount / indexBytes
            totalIndices += indexCount
            var indices: [UInt32] = []
            indices.reserveCapacity(indexCount)
            for _ in 0..<indexCount {
                let value = try indexBytes == 4 ? reader.readUInt32("MDL index") : UInt32(reader.readUInt16("MDL index"))
                guard value < UInt32(vertexCount) else { throw sceneInvalid("\(version): index exceeds vertex count.") }
                indices.append(value)
            }
            if modern {
                // The observed static shapes have neither v21 secondary block.
                // Do not silently discard morph or alternate attribute buffers.
                guard try reader.readUInt16("MDL secondary-buffer flags") == 0 else {
                    throw sceneInvalid("\(version): secondary vertex/index buffers are not supported.")
                }
            }
            result.append(SceneMesh(vertices: vertices, indices: indices,
                materialPath: materialPath, sourceIndexBits: indexBytes * 8, componentsPerVertex: components))
        }
        var skeleton: NativeModelSkeleton?
        if modern {
            let marker = try reader.readNullTerminatedUTF8(maxBytes: 16, "MDL skeleton marker")
            if !marker.isEmpty {
                guard skinned else { throw sceneInvalid("MDL metadata requires an unsupported vertex layout.") }
                skeleton = try NativeModelSkeleton.decode(reader: &reader, marker: marker)
            }
        }
        if skinned {
            guard let skeleton else { throw sceneInvalid("MDL skinned vertices have no skeleton.") }
            for mesh in result {
                for base in stride(from: 0, to: mesh.vertices.count, by: mesh.componentsPerVertex) {
                    guard (10..<14).allSatisfy({ Int(mesh.vertices[base + $0]) < skeleton.bones.count }) else {
                        throw sceneInvalid("MDL joint index exceeds the skeleton's bone count.")
                    }
                }
            }
        }
        try reader.requireEnd(version)
        return SceneModel(meshes: result, skeleton: skeleton)
    }
}

struct SceneTexture {
    static let maximumResourceBytes = sceneMaxTextureResourceBytes
    // Keep level-zero dimensions for authored UVs, autosize and uniforms.
    // rgba contains only pixelWidth x pixelHeight at the selected mipLevel.
    let width: Int
    let height: Int
    let imageWidth: Int
    let imageHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let mipLevel: Int
    let sourceType: UInt32
    let flags: UInt32
    let channelCount: Int
    let rgba: [UInt8]
    /// Original BC3 blocks, only requested after checking the active GL context.
    /// This avoids expanding a large static base image merely to upload it again.
    let compressedBC3: [UInt8]?
    let animation: SceneTextureAnimation?

    static func decode(_ data: Data, allowCompressedBC3: Bool = false, preferredMip: Int = 0) throws -> SceneTexture {
        guard (0...1).contains(preferredMip) else { throw sceneInvalid("Unsupported texture quality mip request.") }
        var reader = SceneByteReader(data)
        try reader.expect(textureVersionMagic, "TEXV0005 marker")
        try reader.expect(textureInfoMagic, "TEXI0001 marker")
        let type = try reader.readUInt32("TEX type")
        let flags = try reader.readUInt32("TEX flags")
        guard flags & 32 == 0 else { throw sceneInvalid("Scene video textures require the prepared AVFoundation path.") }
        let textureWidth = try sceneInt(reader.readUInt32("TEX texture width"), "TEX texture width")
        let textureHeight = try sceneInt(reader.readUInt32("TEX texture height"), "TEX texture height")
        let imageWidth = try sceneInt(reader.readUInt32("TEX image width"), "TEX image width")
        let imageHeight = try sceneInt(reader.readUInt32("TEX image height"), "TEX image height")
        for (name, value) in [("texture width", textureWidth), ("texture height", textureHeight), ("image width", imageWidth), ("image height", imageHeight)] {
            guard value > 0, value <= sceneMaxTextureDimension else {
                throw sceneInvalid("TEX \(name) is outside the supported range.")
            }
        }
        guard imageWidth <= textureWidth, imageHeight <= textureHeight else {
            throw sceneInvalid("TEX image dimensions exceed the texture storage dimensions.")
        }
        _ = try reader.readUInt32("TEXI unknown u32")
        let blockMarker = Array(try reader.readData(textureBlockMagicV2.count, "TEXB marker"))
        let texBlockVersion: String
        switch blockMarker {
        case textureBlockMagicV2:
            texBlockVersion = "TEXB0002"
        case textureBlockMagicV3:
            texBlockVersion = "TEXB0003"
        case textureBlockMagicV4:
            texBlockVersion = "TEXB0004"
        default:
            throw sceneInvalid("Unsupported TEX block marker: \(String(decoding: blockMarker.prefix(8), as: UTF8.self)).")
        }
        guard try reader.readUInt32("TEX image count") == 1 else {
            throw sceneInvalid("Only one-image \(texBlockVersion) containers are supported.")
        }
        let freeImageFormat: UInt32?
        if blockMarker != textureBlockMagicV2 {
            freeImageFormat = try reader.readUInt32("TEX freeimage format")
        } else {
            freeImageFormat = nil
        }
        if blockMarker == textureBlockMagicV4 {
            // Sixteen current Workshop textures contain this additional u32
            // before mip count. Only zero is observed; its semantics are unknown.
            guard try reader.readUInt32("TEXB0004 additional header") == 0 else {
                throw sceneInvalid("Unsupported nonzero TEXB0004 additional header.")
            }
        }
        let isObservedImage = freeImageFormat == 2 || freeImageFormat == 13
        if !isObservedImage && blockMarker != textureBlockMagicV2 {
            guard freeImageFormat == UInt32.max else {
                throw sceneInvalid("Unsupported \(texBlockVersion) freeimage format.")
            }
        }
        let mipCount = try sceneInt(reader.readUInt32("TEX mip count"), "TEX mip count")
        guard mipCount > 0, mipCount <= sceneMaxTextureMips else {
            throw sceneInvalid("TEX mip count exceeds the supported range.")
        }
        // High performance skips exactly the base level when an authored
        // replacement exists. A single-level texture retains its original data.
        let requestedMip = min(preferredMip, mipCount - 1)
        guard [0, 4, 5, 8, 9].contains(type) else {
            throw sceneInvalid("Unsupported TEX type \(type); supported layouts are RGBA type 0, BC3 type 4, ETC2/EAC type 5, RG8 type 8 and R8 type 9.")
        }
        if isObservedImage {
            // Filtering and addressing do not change the embedded image bytes.
            // Bits 0/1/2 select nearest, clamp and atlas semantics respectively.
            guard type == 0, flags & ~UInt32(7) == 0 else {
                throw sceneInvalid("Embedded JPEG/PNG support requires type 0 and only nearest/clamp/atlas flags.")
            }
        }

        var previousWidth: Int?
        var previousHeight: Int?
        var totalDecoded = 0
        var firstRGBA: [UInt8]?
        var firstWidth = 0
        var firstHeight = 0
        var selectedMip = 0
        var compressedBC3: [UInt8]?
        for mipIndex in 0..<mipCount {
            let width = try sceneInt(reader.readUInt32("TEX mip \(mipIndex) width"), "TEX mip width")
            let height = try sceneInt(reader.readUInt32("TEX mip \(mipIndex) height"), "TEX mip height")
            let compression = try reader.readUInt32("TEX mip \(mipIndex) compression")
            let decodedCount = try sceneInt(reader.readUInt32("TEX mip \(mipIndex) decoded length"), "TEX mip decoded length")
            let storedCount = try sceneInt(reader.readUInt32("TEX mip \(mipIndex) stored length"), "TEX mip stored length")
            guard width > 0, height > 0, width <= sceneMaxTextureDimension, height <= sceneMaxTextureDimension else {
                throw sceneInvalid("TEX mip \(mipIndex) dimensions are unsupported.")
            }
            if let previousWidth, let previousHeight {
                guard width == max(1, previousWidth / 2), height == max(1, previousHeight / 2) else {
                    throw sceneInvalid("TEX mip \(mipIndex) dimensions do not follow the observed half-size chain.")
                }
            } else {
                let expectedBaseWidth = isObservedImage ? imageWidth : textureWidth
                let expectedBaseHeight = isObservedImage ? imageHeight : textureHeight
                guard width == expectedBaseWidth, height == expectedBaseHeight else {
                    throw sceneInvalid("TEX base mip dimensions do not match the observed \(isObservedImage ? "embedded image" : "texture storage") dimensions.")
                }
            }
            previousWidth = width
            previousHeight = height
            guard storedCount > 0, storedCount <= sceneMaxTextureResourceBytes else {
                throw sceneInvalid("TEX mip \(mipIndex) exceeds the supported stored-data limit.")
            }
            if !isObservedImage {
                guard decodedCount > 0, decodedCount <= sceneMaxTextureDecodedBytes else {
                    throw sceneInvalid("TEX mip \(mipIndex) exceeds the supported declared-data limit.")
                }
            }
            let expectedPixelCount = try sceneCheckedMultiply(
                try sceneCheckedMultiply(width, height, "TEX mip \(mipIndex) pixels"), 4, "TEX mip \(mipIndex) RGBA bytes"
            )
            let expectedDecodedCount: Int
            if type == 0 {
                expectedDecodedCount = expectedPixelCount
            } else if type == 8 || type == 9 {
                expectedDecodedCount = try sceneCheckedMultiply(
                    try sceneCheckedMultiply(width, height, "TEX channel pixels"), type == 8 ? 2 : 1, "TEX channel bytes"
                )
            } else {
                let blocksWide = (width + 3) / 4
                let blocksHigh = (height + 3) / 4
                expectedDecodedCount = try sceneCheckedMultiply(
                    try sceneCheckedMultiply(blocksWide, blocksHigh, "TEX type \(type) blocks"), 16, "TEX type \(type) block bytes"
                )
            }
            let decodedBudget: Int
            if isObservedImage {
                guard decodedCount == 0, compression == 0 else {
                    throw sceneInvalid("Observed embedded JPEG/PNG mip \(mipIndex) must use compression 0 and decoded length 0.")
                }
                decodedBudget = expectedPixelCount
            } else {
                guard decodedCount == expectedDecodedCount else {
                    throw sceneInvalid("TEX mip \(mipIndex) decoded length does not match its verified layout.")
                }
                decodedBudget = decodedCount
            }
            totalDecoded = try sceneCheckedAdd(totalDecoded, decodedBudget, "TEX decoded total")
            guard totalDecoded <= sceneMaxTextureDecodedBytes else {
                throw sceneInvalid("TEX decoded mip total exceeds the memory limit.")
            }
            if isObservedImage {
                let stored = try reader.readData(storedCount, "TEX mip \(mipIndex) payload")
                if mipIndex == requestedMip {
                    let jpegRGBA = try decodeObservedImage(stored, format: freeImageFormat!, width: width, height: height, label: "TEX mip \(mipIndex)")
                    firstWidth = max(1, textureWidth >> mipIndex)
                    firstHeight = max(1, textureHeight >> mipIndex)
                    selectedMip = mipIndex
                    firstRGBA = try placeImageInTextureStorage(
                        jpegRGBA,
                        imageWidth: width,
                        imageHeight: height,
                        textureWidth: firstWidth,
                        textureHeight: firstHeight,
                        label: "TEX embedded image selected mip"
                    )
                }
                continue
            }
            guard compression == 0 || compression == 1 else {
                throw sceneInvalid("Unsupported TEX mip \(mipIndex) compression flag \(compression).")
            }
            if compression == 0, storedCount != decodedCount {
                throw sceneInvalid("Uncompressed TEX mip \(mipIndex) has mismatched lengths.")
            }
            // Select the highest authored raw/BC3/ETC2/channel mip that fits the
            // existing decode and RGBA budgets. Never expand an oversized base
            // just to discard it. All mip headers and payload ranges are still
            // checked; unused compressed streams are not decompressed.
            // An explicitly requested atlas mip is already authored. Retain
            // logical atlas/frame dimensions so normalized frame UVs agree.
            // Do not apply further automatic budget reduction to an atlas.
            let keepBC3 = allowCompressedBC3 && type == 4 && flags & 4 == 0
                && (expectedPixelCount > sceneMaxTextureRGBABytes || requestedMip > 0)
            let selectMip = firstRGBA == nil && (expectedPixelCount <= sceneMaxTextureRGBABytes || keepBC3)
                && decodedCount <= sceneMaxTextureMipBytes && mipIndex >= requestedMip
                && (mipIndex == requestedMip || flags & 4 == 0)
            guard selectMip else {
                try reader.skip(storedCount, "TEX mip \(mipIndex) payload")
                continue
            }
            let stored = try reader.readData(storedCount, "TEX mip \(mipIndex) payload")
            let decoded: [UInt8]
            switch compression {
            case 0:
                guard storedCount == decodedCount else {
                    throw sceneInvalid("Uncompressed TEX mip \(mipIndex) has mismatched lengths.")
                }
                decoded = Array(stored)
            case 1:
                decoded = try decodeRawLZ4(stored, expectedCount: decodedCount, label: "TEX mip \(mipIndex)")
            default:
                throw sceneInvalid("Unsupported TEX mip \(mipIndex) compression flag \(compression).")
            }
            if selectMip {
                let outputBytes = try sceneCheckedMultiply(
                    try sceneCheckedMultiply(width, height, "TEX output pixels"), 4, "TEX output RGBA bytes"
                )
                guard keepBC3 || outputBytes <= sceneMaxTextureRGBABytes else {
                    throw sceneInvalid("TEX first mip RGBA output exceeds the memory limit.")
                }
                firstWidth = width
                firstHeight = height
                selectedMip = mipIndex
                if keepBC3 {
                    compressedBC3 = decoded
                    firstRGBA = []
                } else if type == 0 {
                    firstRGBA = decoded
                } else if type == 5 {
                    firstRGBA = try NativeETC2Decoder.decode(decoded, width: width, height: height)
                } else if type == 8 || type == 9 {
                    // Keep the GL R/RG sampling convention for authored masks
                    // and flow maps. Base image sampling converts the channel
                    // interpretation separately, without corrupting mask reads.
                    let channels = type == 8 ? 2 : 1
                    var rgba = [UInt8](repeating: 0, count: outputBytes)
                    for pixel in 0..<(width * height) {
                        rgba[pixel * 4] = decoded[pixel * channels]
                        if channels == 2 { rgba[pixel * 4 + 1] = decoded[pixel * channels + 1] }
                        rgba[pixel * 4 + 3] = 255
                    }
                    firstRGBA = rgba
                } else {
                    firstRGBA = try decodeBC3(decoded, width: width, height: height)
                }
            }
        }
        var animation: SceneTextureAnimation?
        if reader.offset < data.count {
            let marker = Array(try reader.readData(9, "TEXS marker"))
            let sequenceVersion: String
            switch marker {
            case Array("TEXS0002\0".utf8): sequenceVersion = "TEXS0002"
            case Array("TEXS0003\0".utf8): sequenceVersion = "TEXS0003"
            default: throw sceneInvalid("Unsupported TEXS sequence marker: \(String(decoding: marker.prefix(8), as: UTF8.self)).")
            }
            let count = try sceneInt(reader.readUInt32("TEXS frame count"), "TEXS frame count")
            // The older sequence does not serialize these two words; the
            // reference reader obtains its nominal dimensions from TEXI.
            let frameWidth = try sequenceVersion == "TEXS0002" ? imageWidth : sceneInt(reader.readUInt32("TEXS frame width"), "TEXS frame width")
            let frameHeight = try sequenceVersion == "TEXS0002" ? imageHeight : sceneInt(reader.readUInt32("TEXS frame height"), "TEXS frame height")
            guard flags & 4 != 0, count > 0, count <= 4096,
                  frameWidth > 0, frameHeight > 0,
                  frameWidth <= sceneMaxTextureDimension, frameHeight <= sceneMaxTextureDimension else {
                throw sceneInvalid("Invalid \(sequenceVersion) frame inventory or missing sequence flag.")
            }
            var frames: [SceneTextureAnimation.Frame] = []
            for index in 0..<count {
                let page = try reader.readUInt32("TEXS frame page")
                let duration = try reader.readFloat32("TEXS frame duration")
                let x = try reader.readFloat32("TEXS frame x"), y = try reader.readFloat32("TEXS frame y")
                let ux = try reader.readFloat32("TEXS frame ux"), uy = try reader.readFloat32("TEXS frame uy")
                let vx = try reader.readFloat32("TEXS frame vx"), vy = try reader.readFloat32("TEXS frame vy")
                guard page == 0, [duration,x,y,ux,uy,vx,vy].allSatisfy(\.isFinite),
                      (sequenceVersion == "TEXS0002" ? duration >= 0 : duration > 0), duration <= 3600,
                      abs(x) <= 1_048_576, abs(y) <= 1_048_576,
                      ux > 0, vy > 0, ux <= Float(sceneMaxTextureDimension), vy <= Float(sceneMaxTextureDimension),
                      uy == 0, vx == 0 else {
                    throw sceneInvalid("TEXS frame \(index) is invalid or exceeds the single-page, axis-aligned coordinate limits.")
                }
                // Native TEXS keeps floating extents independent of the nominal
                // integer header. Out-of-atlas coordinates are sampler input,
                // not memory addresses: preserve authored repeat/clamp behavior.
                frames.append(.init(duration: Double(duration), origin: SIMD2(x,y), size: SIMD2(ux,vy)))
            }
            animation = SceneTextureAnimation(width: frameWidth, height: frameHeight, frames: frames, sourceVersion: sequenceVersion)
        } else if flags & 4 != 0 {
            throw sceneInvalid("TEX declares an animation but has no supported TEXS metadata.")
        }
        try reader.requireEnd("TEXV0005/TEXI0001/\(texBlockVersion)")
        guard let firstRGBA else {
            throw sceneInvalid("TEX has no supported authored mip within the 64 MiB decode/RGBA limits; animated atlases require the selected authored level.")
        }
        return SceneTexture(
            width: textureWidth,
            height: textureHeight,
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            pixelWidth: firstWidth,
            pixelHeight: firstHeight,
            mipLevel: selectedMip,
            sourceType: type,
            flags: flags,
            channelCount: type == 9 ? 1 : type == 8 ? 2 : 4,
            rgba: firstRGBA,
            compressedBC3: compressedBC3,
            animation: animation
        )
    }
}

private func decodeObservedImage(_ data: Data, format: UInt32, width: Int, height: Int, label: String) throws -> [UInt8] {
    let jpeg = data.count >= 3 && Array(data.prefix(3)) == [0xFF, 0xD8, 0xFF]
    let png = Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard (format == 2 && jpeg) || (format == 13 && png) else {
        throw sceneInvalid("\(label) does not match its observed JPEG/PNG format marker.")
    }
    let noCache: CFDictionary = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, noCache),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
          let actualWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
          let actualHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
          actualWidth.int64Value == Int64(width), actualHeight.int64Value == Int64(height) else {
        throw sceneInvalid("\(label) is not an image with the declared \(width)x\(height) dimensions.")
    }
    let byteCount = try sceneCheckedMultiply(
        try sceneCheckedMultiply(width, height, "\(label) pixels"), 4, "\(label) RGBA bytes"
    )
    guard byteCount <= sceneMaxTextureRGBABytes else {
        throw sceneInvalid("\(label) RGBA output exceeds the memory limit.")
    }
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, noCache) else {
        throw sceneInvalid("\(label) could not be decoded after its metadata was validated.")
    }
    var rgba = Array(repeating: UInt8(0), count: byteCount)
    let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
        guard let baseAddress = buffer.baseAddress,
              let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return false
        }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw sceneInvalid("Could not allocate an RGBA context for \(label).") }
    // ImageIO/CoreGraphics produces premultiplied RGBA. Scene shaders expect
    // straight alpha, including transparent PNGs used as compositing overlays.
    if format == 13 {
        for index in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = Int(rgba[index + 3])
            if alpha > 0 && alpha < 255 {
                for component in 0..<3 { rgba[index + component] = UInt8(min(255, (Int(rgba[index + component]) * 255 + alpha / 2) / alpha)) }
            }
        }
    }
    return rgba
}

private func placeImageInTextureStorage(
    _ image: [UInt8],
    imageWidth: Int,
    imageHeight: Int,
    textureWidth: Int,
    textureHeight: Int,
    label: String
) throws -> [UInt8] {
    guard imageWidth > 0, imageHeight > 0,
          imageWidth <= textureWidth, imageHeight <= textureHeight else {
        throw sceneInvalid("\(label) image dimensions are outside the texture storage dimensions.")
    }
    let imageRowBytes = try sceneCheckedMultiply(imageWidth, 4, "\(label) image row bytes")
    let expectedImageBytes = try sceneCheckedMultiply(imageRowBytes, imageHeight, "\(label) image bytes")
    guard image.count == expectedImageBytes else {
        throw sceneInvalid("\(label) decoded image length is invalid.")
    }
    let textureRowBytes = try sceneCheckedMultiply(textureWidth, 4, "\(label) texture row bytes")
    let textureByteCount = try sceneCheckedMultiply(textureRowBytes, textureHeight, "\(label) texture bytes")
    guard textureByteCount <= sceneMaxTextureRGBABytes else {
        throw sceneInvalid("\(label) texture storage exceeds the RGBA memory limit.")
    }
    // FreeImage-format 2 stores JPEGs at the authored dimensions only. Padding
    // is not encoded, so preserve it as zeroed RGBA rather than inventing pixels.
    var storage = Array(repeating: UInt8(0), count: textureByteCount)
    for row in 0..<imageHeight {
        let sourceStart = row * imageRowBytes
        let destinationStart = row * textureRowBytes
        storage.replaceSubrange(
            destinationStart..<(destinationStart + imageRowBytes),
            with: image[sourceStart..<(sourceStart + imageRowBytes)]
        )
    }
    return storage
}

private func decodeRawLZ4(_ data: Data, expectedCount: Int, label: String) throws -> [UInt8] {
    guard expectedCount >= 0, expectedCount <= sceneMaxTextureMipBytes else {
        throw sceneInvalid("\(label) declares an unsupported LZ4 output size.")
    }
    let source = Array(data)
    var input = 0
    var output: [UInt8] = []
    output.reserveCapacity(expectedCount)

    func extendedLength(_ initial: Int, _ input: inout Int) throws -> Int {
        var length = initial
        while true {
            guard input < source.count else { throw sceneInvalid("Truncated LZ4 length in \(label).") }
            let value = Int(source[input])
            input += 1
            length = try sceneCheckedAdd(length, value, "LZ4 length")
            if value != 255 { return length }
        }
    }

    while input < source.count {
        let token = source[input]
        input += 1
        var literalLength = Int(token >> 4)
        if literalLength == 15 { literalLength = try extendedLength(literalLength, &input) }
        let literalEnd = try sceneCheckedAdd(input, literalLength, "LZ4 literals")
        guard literalEnd <= source.count else { throw sceneInvalid("LZ4 literal run exceeds input in \(label).") }
        guard output.count + literalLength <= expectedCount else { throw sceneInvalid("LZ4 literal run exceeds output in \(label).") }
        output.append(contentsOf: source[input..<literalEnd])
        input = literalEnd
        if input == source.count { break }

        guard input + 2 <= source.count else { throw sceneInvalid("Truncated LZ4 match offset in \(label).") }
        let matchOffset = Int(source[input]) | (Int(source[input + 1]) << 8)
        input += 2
        guard matchOffset > 0, matchOffset <= output.count else { throw sceneInvalid("Invalid LZ4 match offset in \(label).") }
        var matchLength = Int(token & 0x0F) + 4
        if token & 0x0F == 15 { matchLength = try extendedLength(matchLength, &input) }
        guard output.count + matchLength <= expectedCount else { throw sceneInvalid("LZ4 match run exceeds output in \(label).") }
        for _ in 0..<matchLength { output.append(output[output.count - matchOffset]) }
    }
    guard input == source.count, output.count == expectedCount else {
        throw sceneInvalid("LZ4 payload does not exactly match the declared output for \(label).")
    }
    return output
}

private func decodeBC3(_ blocks: [UInt8], width: Int, height: Int) throws -> [UInt8] {
    let blocksWide = (width + 3) / 4
    let blocksHigh = (height + 3) / 4
    let blockCount = try sceneCheckedMultiply(blocksWide, blocksHigh, "BC3 block count")
    let expectedCount = try sceneCheckedMultiply(blockCount, 16, "BC3 block bytes")
    guard blocks.count == expectedCount else { throw sceneInvalid("BC3 block data length is invalid.") }
    let outputCount = try sceneCheckedMultiply(try sceneCheckedMultiply(width, height, "BC3 pixels"), 4, "BC3 RGBA bytes")
    guard outputCount <= sceneMaxTextureRGBABytes else { throw sceneInvalid("BC3 RGBA output exceeds the memory limit.") }
    var rgba = Array(repeating: UInt8(0), count: outputCount)

    func rgb565(_ value: UInt16) -> (UInt8, UInt8, UInt8) {
        (
            UInt8((UInt32((value >> 11) & 0x1F) * 255) / 31),
            UInt8((UInt32((value >> 5) & 0x3F) * 255) / 63),
            UInt8((UInt32(value & 0x1F) * 255) / 31)
        )
    }
    func interpolate(_ first: UInt8, _ second: UInt8, _ firstWeight: UInt32, _ secondWeight: UInt32, _ divisor: UInt32) -> UInt8 {
        UInt8((UInt32(first) * firstWeight + UInt32(second) * secondWeight) / divisor)
    }

    for blockIndex in 0..<blockCount {
        let offset = blockIndex * 16
        let alpha0 = blocks[offset]
        let alpha1 = blocks[offset + 1]
        var alphaIndexBits: UInt64 = 0
        for byte in 0..<6 { alphaIndexBits |= UInt64(blocks[offset + 2 + byte]) << UInt64(byte * 8) }
        var alphaPalette = Array(repeating: UInt8(0), count: 8)
        alphaPalette[0] = alpha0
        alphaPalette[1] = alpha1
        if alpha0 > alpha1 {
            alphaPalette[2] = interpolate(alpha0, alpha1, 6, 1, 7)
            alphaPalette[3] = interpolate(alpha0, alpha1, 5, 2, 7)
            alphaPalette[4] = interpolate(alpha0, alpha1, 4, 3, 7)
            alphaPalette[5] = interpolate(alpha0, alpha1, 3, 4, 7)
            alphaPalette[6] = interpolate(alpha0, alpha1, 2, 5, 7)
            alphaPalette[7] = interpolate(alpha0, alpha1, 1, 6, 7)
        } else {
            alphaPalette[2] = interpolate(alpha0, alpha1, 4, 1, 5)
            alphaPalette[3] = interpolate(alpha0, alpha1, 3, 2, 5)
            alphaPalette[4] = interpolate(alpha0, alpha1, 2, 3, 5)
            alphaPalette[5] = interpolate(alpha0, alpha1, 1, 4, 5)
            alphaPalette[6] = 0
            alphaPalette[7] = 255
        }

        let color0 = UInt16(blocks[offset + 8]) | (UInt16(blocks[offset + 9]) << 8)
        let color1 = UInt16(blocks[offset + 10]) | (UInt16(blocks[offset + 11]) << 8)
        var colorIndexBits: UInt32 = 0
        for byte in 0..<4 { colorIndexBits |= UInt32(blocks[offset + 12 + byte]) << UInt32(byte * 8) }
        let firstColor = rgb565(color0)
        let secondColor = rgb565(color1)
        // BC3/DXT5 always uses the four-colour interpolation form, including
        // blocks whose endpoint ordering differs from BC1's opaque mode.
        let colorPalette: [(UInt8, UInt8, UInt8)] = [
            firstColor,
            secondColor,
            (
                interpolate(firstColor.0, secondColor.0, 2, 1, 3),
                interpolate(firstColor.1, secondColor.1, 2, 1, 3),
                interpolate(firstColor.2, secondColor.2, 2, 1, 3)
            ),
            (
                interpolate(firstColor.0, secondColor.0, 1, 2, 3),
                interpolate(firstColor.1, secondColor.1, 1, 2, 3),
                interpolate(firstColor.2, secondColor.2, 1, 2, 3)
            )
        ]

        let originX = (blockIndex % blocksWide) * 4
        let originY = (blockIndex / blocksWide) * 4
        for localPixel in 0..<16 {
            let x = originX + (localPixel % 4)
            let y = originY + (localPixel / 4)
            guard x < width, y < height else { continue }
            let alpha = alphaPalette[Int((alphaIndexBits >> UInt64(localPixel * 3)) & 0x07)]
            let color = colorPalette[Int((colorIndexBits >> UInt32(localPixel * 2)) & 0x03)]
            let output = (y * width + x) * 4
            rgba[output] = color.0
            rgba[output + 1] = color.1
            rgba[output + 2] = color.2
            rgba[output + 3] = alpha
        }
    }
    return rgba
}
