import Foundation
import simd

/// Bounded structural reader for the observed MDLV0023 puppet layout.
/// It retains author data for the renderer; decoding alone does not imply that
/// clipping, constraints or animation are being displayed by the host.
struct NativePuppetModel {
    struct RangeRecord {
        let words: SIMD4<UInt32>
    }
    struct ClippingMask {
        let id: UInt64
        let resource: String
        let flags: UInt32
        let inputs: [UInt32]
        let dependencies: [UInt32]
    }
    struct Shape {
        let materialPath: String
        let vertexFormat: UInt32
        let vertices: [Float] // 20 components: pos, normal, tangent, 4 joints, 4 weights, UV
        let indices: [UInt32]
        let extraPositionFormat: UInt32?
        let extraPositions: [SIMD3<Float>]
        let rangeRecords: [RangeRecord]
        let clippingMasks: [ClippingMask]
    }
    struct Bone {
        let name: String
        let flags: UInt32
        let parent: Int
        let localBind: simd_float4x4
        let constraintJSON: String
    }
    struct Key {
        let position: SIMD3<Float>
        let rotation: simd_quatf
        let scale: SIMD3<Float>
    }
    struct Clip {
        let id: UInt64
        let name: String
        let mode: String
        let fps: Float
        let frameCount: Int
        let tracks: [[Key]]
        let lowerBounds: SIMD3<Float>
        let upperBounds: SIMD3<Float>
    }

    let globalFormat: UInt32
    let shapes: [Shape]
    let bones: [Bone]
    let firstBoneTable: [UInt32]?
    let secondBoneTable: [UInt32]?
    let clips: [Clip]
    let extraBoneMatrices: [simd_float4x4]?

    private static let maxBones = 128
    private static let maxBytes = 64 * 1024 * 1024
    private static let maxAnimationBytes = 32 * 1024 * 1024
    private static func invalid(_ message: String) -> SceneError { SceneError.invalid("Puppet MDL: \(message)") }

    static func decode(_ data: Data) throws -> NativePuppetModel {
        guard data.count <= maxBytes else { throw invalid("resource exceeds 64 MiB") }
        var r = SceneByteReader(data)
        guard try r.readNullTerminatedUTF8(maxBytes: 16, "puppet version") == "MDLV0023" else {
            throw invalid("only the observed MDLV0023 layout is supported")
        }
        let globalFormat = try r.readUInt32("puppet global vertex format")
        let slots = try r.readUInt32("puppet material slot count")
        let count = Int(try r.readUInt32("puppet shape count"))
        guard [UInt32(0x01800009), UInt32(0x0180000f)].contains(globalFormat), slots == 1,
              (1...256).contains(count) else { throw invalid("unsupported header or shape count") }
        var shapes: [Shape] = []
        var totalVertices = 0, totalIndices = 0
        for _ in 0..<count {
            let materialPath = try safePath(r.readNullTerminatedUTF8(maxBytes: 4096, "puppet material"))
            let flags = try r.readUInt32("puppet shape flags")
            guard flags <= 1 else { throw invalid("unsupported shape flags") }
            let lower = try vector(&r, "puppet lower bounds"), upper = try vector(&r, "puppet upper bounds")
            guard lower.x <= upper.x, lower.y <= upper.y, lower.z <= upper.z else { throw invalid("invalid shape bounds") }
            let format = try r.readUInt32("puppet shape vertex format")
            guard format == 0x0180000f else { throw invalid("unsupported shape vertex attributes") }
            let vertexBytes = Int(try r.readUInt32("puppet vertex bytes"))
            guard vertexBytes > 0, vertexBytes % 80 == 0, vertexBytes <= maxBytes,
                  vertexBytes / 80 <= 1_000_000 - totalVertices else { throw invalid("invalid vertex block") }
            let vertexCount = vertexBytes / 80
            totalVertices += vertexCount
            var vertices: [Float] = []; vertices.reserveCapacity(vertexCount * 20)
            for _ in 0..<vertexCount {
                for component in 0..<20 {
                    if (10..<14).contains(component) {
                        let joint = try r.readUInt32("puppet joint index")
                        guard joint < UInt32(maxBones) else { throw invalid("joint index exceeds limit") }
                        vertices.append(Float(joint))
                    } else {
                        let value = try r.readFloat32("puppet vertex component")
                        guard value.isFinite else { throw invalid("non-finite vertex component") }
                        vertices.append(value)
                    }
                }
                let base = vertices.count - 20
                let weights = vertices[(base + 14)..<(base + 18)]
                guard weights.allSatisfy({ $0 >= 0 && $0 <= 1 }), abs(weights.reduce(0,+) - 1) <= 0.001 else {
                    throw invalid("skin weights must be in 0...1 and sum to one")
                }
            }
            let indexSize = flags & 1 == 0 ? 2 : 4
            let indexBytes = Int(try r.readUInt32("puppet index bytes"))
            guard indexBytes > 0, indexBytes % indexSize == 0, indexBytes / indexSize % 3 == 0,
                  indexBytes / indexSize <= 3_000_000 - totalIndices else { throw invalid("invalid index block") }
            let indexCount = indexBytes / indexSize
            totalIndices += indexCount
            var indices: [UInt32] = []; indices.reserveCapacity(indexCount)
            for _ in 0..<indexCount {
                let value = try indexSize == 2 ? UInt32(r.readUInt16("puppet index")) : r.readUInt32("puppet index")
                guard value < UInt32(vertexCount) else { throw invalid("index exceeds vertex count") }
                indices.append(value)
            }
            let extraFlag = try r.readUInt8("puppet extra vertex flag")
            guard extraFlag <= 1 else { throw invalid("invalid extra vertex flag") }
            var extraFormat: UInt32?, extra: [SIMD3<Float>] = []
            if extraFlag == 1 {
                extraFormat = try r.readUInt32("puppet extra vertex format")
                let bytes = Int(try r.readUInt32("puppet extra vertex bytes"))
                guard extraFormat == 1, bytes == vertexCount * 12 else { throw invalid("unsupported extra vertex block") }
                extra.reserveCapacity(vertexCount)
                for _ in 0..<vertexCount { extra.append(try vector(&r, "puppet extra vertex")) }
            }
            let rangeFlag = try r.readUInt8("puppet range flag")
            guard rangeFlag <= 1 else { throw invalid("invalid range flag") }
            var ranges: [RangeRecord] = []
            if rangeFlag == 1 {
                let bytes = Int(try r.readUInt32("puppet range bytes"))
                guard bytes % 16 == 0, bytes <= maxBytes, bytes / 16 <= 100_000 else { throw invalid("invalid range block") }
                ranges.reserveCapacity(bytes / 16)
                for _ in 0..<(bytes / 16) {
                    let a = try r.readUInt32("range word"), b = try r.readUInt32("range word")
                    let start = try r.readUInt32("range start"), length = try r.readUInt32("range count")
                    guard UInt64(start) + UInt64(length) <= UInt64(indexCount), start % 3 == 0, length % 3 == 0 else {
                        throw invalid("range extends beyond index buffer")
                    }
                    ranges.append(RangeRecord(words: SIMD4(a,b,start,length)))
                }
            }
            let maskCount = Int(try r.readUInt32("puppet clipping mask count"))
            guard maskCount <= 256 else { throw invalid("too many clipping masks") }
            var masks: [ClippingMask] = []
            for _ in 0..<maskCount {
                let id = try r.readUInt64("clipping mask id")
                let resource = try safePath(r.readNullTerminatedUTF8(maxBytes: 4096, "clipping mask resource"))
                let maskFlags = try r.readUInt32("clipping mask flags")
                let inputs = try words(&r, "clipping mask inputs")
                let dependencies = try words(&r, "clipping mask dependencies")
                masks.append(ClippingMask(id: id, resource: resource, flags: maskFlags, inputs: inputs, dependencies: dependencies))
            }
            shapes.append(Shape(materialPath: materialPath, vertexFormat: format, vertices: vertices, indices: indices,
                extraPositionFormat: extraFormat, extraPositions: extra, rangeRecords: ranges, clippingMasks: masks))
        }
        let marker = try r.readNullTerminatedUTF8(maxBytes: 16, "puppet skeleton marker")
        guard marker == "MDLS0004" else { throw invalid("unsupported skeleton marker: \(marker)") }
        var skeleton = try section(&r, marker)
        let boneCount = Int(try skeleton.readUInt32("puppet bone count"))
        guard (1...maxBones).contains(boneCount) else { throw invalid("invalid bone count") }
        var bones: [Bone] = []
        for index in 0..<boneCount {
            let name = try skeleton.readNullTerminatedUTF8(maxBytes: 4096, "bone name")
            let flags = try skeleton.readUInt32("bone flags")
            let parent = Int(Int32(bitPattern: try skeleton.readUInt32("bone parent")))
            guard index == 0 ? parent == -1 : parent >= 0 && parent < index else { throw invalid("invalid bone parent order") }
            guard try skeleton.readUInt32("bone matrix bytes") == 64 else { throw invalid("invalid bone matrix length") }
            let local = try matrix(&skeleton, "bone bind")
            let json = try skeleton.readNullTerminatedUTF8(maxBytes: 65536, "bone constraint")
            if !json.isEmpty {
                guard let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8)), decoded is [String: Any] else {
                    throw invalid("invalid bone constraint JSON")
                }
            }
            bones.append(Bone(name: name, flags: flags, parent: parent, localBind: local, constraintJSON: json))
        }
        guard try skeleton.readUInt16("controller count") == 0,
              try skeleton.readUInt8("separate matrices") == 0,
              try skeleton.readUInt32("constraint links") == 0,
              try skeleton.readUInt16("IK count") == 0,
              try skeleton.readUInt16("IK set count") == 0 else {
            throw invalid("controllers, linked constraints and IK are not yet decoded")
        }
        let boundsFlag = try skeleton.readUInt8("bone bounds flag")
        guard boundsFlag <= 1 else { throw invalid("invalid bone bounds flag") }
        if boundsFlag == 1 {
            for _ in 0..<boneCount {
                let bounds = try vector(&skeleton, "bone bounds size")
                guard bounds.x >= 0, bounds.y >= 0, bounds.z >= 0 else { throw invalid("negative bone bounds") }
                _ = try matrix(&skeleton, "bone bounds matrix")
            }
        }
        let firstTable = try table(&skeleton, count: boneCount, label: "first bone table")
        if let firstTable, firstTable.contains(where: { $0 >= UInt32(boneCount) }) { throw invalid("bone table index exceeds bone count") }
        let secondTable = try table(&skeleton, count: boneCount, label: "second bone table")
        try skeleton.requireEnd(marker)
        for shape in shapes {
            for base in stride(from: 0, to: shape.vertices.count, by: 20) {
                guard (10..<14).allSatisfy({ Int(shape.vertices[base + $0]) < boneCount }) else {
                    throw invalid("joint index exceeds bone count")
                }
            }
        }
        let animationMarker = try r.readNullTerminatedUTF8(maxBytes: 16, "puppet animation marker")
        guard animationMarker == "MDLA0006" else { throw invalid("unsupported animation marker: \(animationMarker)") }
        var animation = try section(&r, animationMarker)
        let clipCount = Int(try animation.readUInt32("clip count"))
        guard clipCount <= 32 else { throw invalid("too many animation clips") }
        var clips: [Clip] = [], identifiers = Set<UInt64>(), animationBytes = 0
        for _ in 0..<clipCount {
            let id = try animation.readUInt64("clip id")
            guard identifiers.insert(id).inserted else { throw invalid("duplicate animation id") }
            let name = try animation.readNullTerminatedUTF8(maxBytes: 4096, "clip name")
            let mode = try animation.readNullTerminatedUTF8(maxBytes: 64, "clip mode")
            let fps = try animation.readFloat32("clip fps")
            let frameCount = Int(try animation.readUInt32("clip frame count"))
            let flags = try animation.readUInt32("clip flags")
            let tracksCount = Int(try animation.readUInt32("clip track count"))
            guard fps.isFinite, fps > 0, fps <= 240, (1...100_000).contains(frameCount),
                  flags == 0, tracksCount == boneCount else { throw invalid("unsupported clip header") }
            let derived = tracksCount * (frameCount + 1) * MemoryLayout<Key>.stride
            guard derived <= maxAnimationBytes - animationBytes else { throw invalid("animation keys exceed 32 MiB") }
            animationBytes += derived
            var tracks: [[Key]] = []
            for _ in 0..<tracksCount {
                guard try animation.readUInt32("track flags") == 0,
                      Int(try animation.readUInt32("track bytes")) == (frameCount + 1) * 36 else {
                    throw invalid("unsupported animation track")
                }
                var keys: [Key] = []; keys.reserveCapacity(frameCount + 1)
                for _ in 0...frameCount {
                    let pos = try vector(&animation, "key position"), angle = try vector(&animation, "key rotation")
                    let scale = try vector(&animation, "key scale")
                    // A zero animation scale can represent a fully closed or
                    // flattened part; only bind matrices need to be invertible.
                    guard max(abs(angle.x),abs(angle.y),abs(angle.z)) <= 1_000_000 else { throw invalid("invalid key transform") }
                    let q = simd_quatf(angle: angle.z, axis: SIMD3(0,0,1))
                        * simd_quatf(angle: angle.y, axis: SIMD3(0,1,0))
                        * simd_quatf(angle: angle.x, axis: SIMD3(1,0,0))
                    keys.append(Key(position: pos, rotation: q, scale: scale))
                }
                tracks.append(keys)
            }
            guard try animation.readUInt32("auxiliary track count") == 0,
                  try animation.readUInt8("auxiliary bone track flag") == 0,
                  try animation.readUInt8("IK animation flag") == 0 else { throw invalid("unsupported auxiliary animation") }
            let lower = try vector(&animation, "clip bounds minimum"), upper = try vector(&animation, "clip bounds maximum")
            guard lower.x <= upper.x, lower.y <= upper.y, lower.z <= upper.z,
                  try animation.readUInt8("additional bone track flag") == 0,
                  try animation.readUInt32("animation event count") == 0 else { throw invalid("unsupported animation bounds or events") }
            clips.append(Clip(id: id, name: name, mode: mode, fps: fps, frameCount: frameCount, tracks: tracks,
                              lowerBounds: lower, upperBounds: upper))
        }
        try animation.requireEnd(animationMarker)
        let extraMarker = try r.readNullTerminatedUTF8(maxBytes: 16, "puppet extra section")
        var extraMatrices: [simd_float4x4]?
        if !extraMarker.isEmpty {
            guard extraMarker == "MDLE0002" else { throw invalid("unsupported extra section: \(extraMarker)") }
            var extra = try section(&r, extraMarker)
            let bytes = Int(try extra.readUInt32("extra matrices bytes"))
            guard bytes == boneCount * 64 else { throw invalid("unsupported extra matrix block") }
            var matrices: [simd_float4x4] = []
            for _ in 0..<boneCount { matrices.append(try matrix(&extra, "extra bone matrix")) }
            try extra.requireEnd(extraMarker)
            extraMatrices = matrices
            guard try r.readNullTerminatedUTF8(maxBytes: 16, "puppet final marker").isEmpty else {
                throw invalid("additional sections are unsupported")
            }
        }
        try r.requireEnd("puppet MDL")
        return NativePuppetModel(globalFormat: globalFormat, shapes: shapes, bones: bones,
                                 firstBoneTable: firstTable, secondBoneTable: secondTable,
                                 clips: clips, extraBoneMatrices: extraMatrices)
    }

    private static func safePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\"),
              !path.contains(":"), !path.utf8.contains(0),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw invalid("unsafe resource path") }
        return path
    }
    private static func vector(_ reader: inout SceneByteReader, _ label: String) throws -> SIMD3<Float> {
        let v = SIMD3(try reader.readFloat32(label), try reader.readFloat32(label), try reader.readFloat32(label))
        guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { throw invalid("non-finite \(label)") }
        return v
    }
    private static func matrix(_ reader: inout SceneByteReader, _ label: String) throws -> simd_float4x4 {
        var columns: [SIMD4<Float>] = []
        for _ in 0..<4 {
            let xyz = try vector(&reader, label), w = try reader.readFloat32(label)
            guard w.isFinite else { throw invalid("non-finite \(label)") }
            columns.append(SIMD4(xyz,w))
        }
        let result = simd_float4x4(columns)
        guard result[0].w == 0, result[1].w == 0, result[2].w == 0, result[3].w == 1 else {
            throw invalid("non-affine \(label)")
        }
        return result
    }
    private static func section(_ reader: inout SceneByteReader, _ label: String) throws -> SceneByteReader {
        let end = Int(try reader.readUInt32("\(label) absolute end"))
        guard end >= reader.offset, end - reader.offset <= maxBytes else { throw invalid("invalid \(label) section end") }
        return SceneByteReader(try reader.readData(end - reader.offset, label))
    }
    private static func words(_ reader: inout SceneByteReader, _ label: String) throws -> [UInt32] {
        let count = Int(try reader.readUInt32("\(label) count"))
        guard count <= 4096 else { throw invalid("too many \(label)") }
        var values: [UInt32] = []; values.reserveCapacity(count)
        for _ in 0..<count { values.append(try reader.readUInt32(label)) }
        return values
    }
    private static func table(_ reader: inout SceneByteReader, count: Int, label: String) throws -> [UInt32]? {
        let flag = try reader.readUInt8("\(label) flag")
        guard flag <= 1 else { throw invalid("invalid \(label) flag") }
        guard flag == 1 else { return nil }
        var result: [UInt32] = []; result.reserveCapacity(count)
        for _ in 0..<count { result.append(try reader.readUInt32(label)) }
        return result
    }
}
