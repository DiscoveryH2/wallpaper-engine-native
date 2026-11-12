import Foundation
import simd

/// Owned reader for the observed MDLS0003 / MDLA0006 branch. Every section is
/// bounded by its absolute end offset. Unsupported controllers, constraints,
/// remaps and auxiliary animation tracks fail explicitly instead of being skipped.
final class NativeModelSkeleton {
    static let maximumBones: UInt32 = 128
    struct Bone {
        let name: String
        let parent: Int
        let localBind: simd_float4x4
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
        let events: [Event]
        var reference: Reference? = nil
        var ownsTracks = true
        var sampleStart = 0
        var rootMotionFlags: UInt32 = 0
        var initialFrame: Int { reference?.frameOffset ?? 0 }
    }
    struct Reference {
        let animationIndex: Int
        let startFrame: Int
        let endFrame: Int
        let frameOffset: Int
        let rootBone: Int
    }
    struct Event {
        let time: Float
        let json: String
    }
    let bones: [Bone]
    let clips: [Clip]
    let bindWorld: [simd_float4x4]
    let inverseBind: [simd_float4x4]
    let animationBytes: Int
    let defaultPalette: [Float]
    let defaultPaletteIdentityError: Float

    private init(bones: [Bone], clips: [Clip], animationBytes: Int) throws {
        self.bones = bones; self.clips = clips; self.animationBytes = animationBytes
        var world: [simd_float4x4] = [], inverse: [simd_float4x4] = []
        for bone in bones {
            let matrix = bone.parent < 0 ? bone.localBind : world[bone.parent] * bone.localBind
            let precise = simd_double4x4((0..<4).map { SIMD4<Double>(matrix[$0]) })
            let determinant = simd_determinant(precise)
            guard determinant.isFinite, determinant != 0 else { throw SceneError.invalid("MDL bind matrix is singular.") }
            let inverted = simd_inverse(precise)
            let result = simd_float4x4((0..<4).map { SIMD4<Float>(inverted[$0]) })
            guard Self.finite(matrix), Self.finite(result) else { throw SceneError.invalid("MDL bind transform overflow.") }
            world.append(matrix); inverse.append(result)
        }
        bindWorld = world; inverseBind = inverse
        // Obj::SetConfig builds inverse world-bind matrices. With no active
        // animation layers, Obj::Update rebuilds world bind, then multiplies
        // currentWorld * inverseBind before uploading g_Bones. Embedded clips
        // are not automatically activated merely because they exist in MDLA.
        var packed: [Float] = [], error: Float = 0
        for index in bones.indices {
            let palette = world[index] * inverse[index]
            guard Self.finite(palette) else { throw SceneError.invalid("MDL default bone palette overflow.") }
            for column in 0..<4 {
                for row in 0..<4 {
                    let value = palette[column][row]
                    error = max(error, abs(value - (column == row ? 1 : 0)))
                    packed.append(value)
                }
            }
        }
        defaultPalette = packed; defaultPaletteIdentityError = error
    }

    static func decode(reader: inout SceneByteReader, marker: String) throws -> NativeModelSkeleton {
        guard marker == "MDLS0003" else { throw SceneError.invalid("Unsupported skeleton section: \(marker).") }
        var body = try section(&reader, label: marker)
        let count = try body.readUInt32("MDLS bone count")
        guard count > 0, count <= maximumBones else { throw SceneError.invalid("MDLS bone count exceeds 1...\(maximumBones).") }
        var bones: [Bone] = []
        for index in 0..<Int(count) {
            let name = try body.readNullTerminatedUTF8(maxBytes: 4096, "MDLS bone name")
            let flags = try body.readUInt32("MDLS bone flags")
            let parent = Int(Int32(bitPattern: try body.readUInt32("MDLS bone parent")))
            guard flags <= 1, (index == 0 ? parent == -1 : parent >= 0 && parent < index) else {
                throw SceneError.invalid("MDLS bone flags or parent order are unsupported.")
            }
            guard try body.readUInt32("MDLS matrix length") == 64 else { throw SceneError.invalid("MDLS matrix must have 64 bytes.") }
            let matrix = try readMatrix(&body, label: "MDLS local bind")
            guard try body.readNullTerminatedUTF8(maxBytes: 65536, "MDLS constraints").isEmpty else {
                throw SceneError.invalid("MDLS bone constraints are not implemented.")
            }
            bones.append(Bone(name: name, parent: parent, localBind: matrix))
        }
        guard try body.readUInt16("MDLS controller count") == 0,
              try body.readUInt8("MDLS separate matrix flag") == 0,
              try body.readUInt32("MDLS constraint link count") == 0,
              try body.readUInt16("MDLS IK count") == 0,
              try body.readUInt16("MDLS IK set count") == 0 else {
            throw SceneError.invalid("MDLS controllers, separate matrices, constraints or IK are not implemented.")
        }
        let boundsFlag = try body.readUInt8("MDLS bone bounds flag")
        guard boundsFlag <= 1 else { throw SceneError.invalid("Invalid MDLS bone bounds flag.") }
        if boundsFlag == 1 {
            for _ in bones {
                let size = try readVector(&body, label: "MDLS bone bounds size")
                guard size.x >= 0, size.y >= 0, size.z >= 0 else { throw SceneError.invalid("Invalid MDLS bone bounds size.") }
                _ = try readMatrix(&body, label: "MDLS bone bounds transform")
            }
        }
        guard try body.readUInt8("MDLS bone remap flag") == 0,
              try body.readUInt8("MDLS secondary remap flag") == 0 else {
            throw SceneError.invalid("MDLS bone remapping is not implemented.")
        }
        try body.requireEnd(marker)
        var clips: [Clip] = [], animationBytes = 0
        let next = try reader.readNullTerminatedUTF8(maxBytes: 16, "MDL following section")
        if !next.isEmpty {
            guard next == "MDLA0006" else { throw SceneError.invalid("Unsupported MDL following section: \(next).") }
            var animation = try section(&reader, label: next)
            let clipCount = Int(try animation.readUInt32("MDLA clip count"))
            guard clipCount <= 32 else { throw SceneError.invalid("MDLA exceeds 32 clips.") }
            var identifiers = Set<UInt64>(), eventCount = 0, eventBytes = 0
            for _ in 0..<clipCount {
                let id = try animation.readUInt64("MDLA clip id")
                guard identifiers.insert(id).inserted else { throw SceneError.invalid("Duplicate MDLA clip id.") }
                let name = try animation.readNullTerminatedUTF8(maxBytes: 4096, "MDLA clip name")
                let mode = try animation.readNullTerminatedUTF8(maxBytes: 64, "MDLA clip mode")
                let fps = try animation.readFloat32("MDLA fps")
                let frameCount = Int(try animation.readUInt32("MDLA frame count"))
                let flags = try animation.readUInt32("MDLA clip flags")
                let tracksCount = Int(try animation.readUInt32("MDLA bone tracks"))
                // MDLA bit 0 adds AnimationClip metadata after the extra-track
                // section. Bit 10 selects this clip's own (baked) key buffer;
                // otherwise Obj::Update samples the referenced buffer once,
                // adding startFrame. This is not a recursive clip graph.
                guard flags == 0 || (flags & 1 != 0 && flags & ~(UInt32(0x401) | NativeModelRootMotion.supportedMask) == 0) else {
                    throw SceneError.invalid("MDLA clip flags contain an unsupported motion component or animation feature.")
                }
                let ownsTracks = (flags & 0x401) != 1
                guard fps.isFinite, fps > 0, fps <= 240, frameCount > 0, frameCount <= 100_000,
                      (Float(frameCount) / fps).isFinite,
                      (Float(frameCount) * (1 / fps)).isFinite,
                      tracksCount == bones.count || (!ownsTracks && tracksCount == 0) else {
                    throw SceneError.invalid("MDLA frame rate, length, flags or track count is unsupported.")
                }
                let derivedBytes = tracksCount * (frameCount + 1) * MemoryLayout<Key>.stride
                guard derivedBytes <= 32 * 1024 * 1024 - animationBytes else { throw SceneError.invalid("MDLA keys exceed 32 MiB.") }
                animationBytes += derivedBytes
                var tracks: [[Key]] = []
                for _ in 0..<tracksCount {
                    guard try animation.readUInt32("MDLA track flags") == 0,
                          try animation.readUInt32("MDLA track byte length") == UInt32((frameCount + 1) * 36) else {
                        throw SceneError.invalid("MDLA supports dense 36-byte TRS keys only.")
                    }
                    var keys: [Key] = []; keys.reserveCapacity(frameCount + 1)
                    for _ in 0...frameCount {
                        let position = try readVector(&animation, label: "MDLA position")
                        let angles = try readVector(&animation, label: "MDLA Euler angles")
                        let scale = try readVector(&animation, label: "MDLA scale")
                        guard max(abs(angles.x), abs(angles.y), abs(angles.z)) <= 1_000_000,
                              scale.x != 0, scale.y != 0, scale.z != 0 else { throw SceneError.invalid("Invalid MDLA transform key.") }
                        // REA ParseInMemory converts the three stored Euler radians
                        // to qz * qy * qx before interpolation (not Euler lerp).
                        let rotation = simd_quatf(angle: angles.z, axis: SIMD3(0, 0, 1))
                            * simd_quatf(angle: angles.y, axis: SIMD3(0, 1, 0))
                            * simd_quatf(angle: angles.x, axis: SIMD3(1, 0, 0))
                        keys.append(Key(position: position, rotation: rotation, scale: scale))
                    }
                    tracks.append(keys)
                }
                // Controller / constraint tracks have no per-clip count: their
                // lengths come from MDLS, whose supported counts are zero above.
                guard try animation.readUInt32("MDLA auxiliary track count") == 0,
                      try animation.readUInt8("MDLA auxiliary bone track flag") == 0,
                      try animation.readUInt8("MDLA IK animation flag") == 0 else {
                    throw SceneError.invalid("MDLA auxiliary tracks and IK animation are not implemented.")
                }
                let lower = try readVector(&animation, label: "MDLA minimum bounds")
                let upper = try readVector(&animation, label: "MDLA maximum bounds")
                guard lower.x <= upper.x, lower.y <= upper.y, lower.z <= upper.z else { throw SceneError.invalid("Invalid MDLA bounds.") }
                guard try animation.readUInt8("MDLA additional bone track flag") == 0 else {
                    throw SceneError.invalid("MDLA extra bone tracks are not implemented.")
                }
                var reference: Reference?
                if flags & 1 != 0 {
                    reference = Reference(animationIndex: Int(try animation.readUInt16("MDLA referenced animation index")),
                        startFrame: Int(try animation.readUInt32("MDLA clip start frame")),
                        endFrame: Int(try animation.readUInt32("MDLA clip end frame")),
                        frameOffset: Int(try animation.readUInt32("MDLA clip initial frame")),
                        rootBone: Int(Int32(bitPattern: try animation.readUInt32("MDLA motion root bone"))))
                }
                let count = Int(try animation.readUInt32("MDLA event count"))
                guard count <= 256, eventCount + count <= 4096 else { throw SceneError.invalid("MDLA events exceed the 256 per-clip / 4096 per-model budget.") }
                var events: [Event] = []
                for _ in 0..<count {
                    // ParseInMemory stores a Float time followed by a C string.
                    // The stored clock value is authoritative, not JSON.frame.
                    let time = try animation.readFloat32("MDLA event time")
                    let json = try animation.readNullTerminatedUTF8(maxBytes: 4097, "MDLA event JSON")
                    let data = Data(json.utf8)
                    guard time.isFinite, abs(time) <= 1e9, data.count <= 4096,
                          eventBytes + data.count <= 256 * 1024,
                          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let name = object["name"] as? String, name.utf8.count <= 1024 else {
                        throw SceneError.invalid("MDLA event requires a finite time and bounded JSON object with a name.")
                    }
                    eventBytes += data.count
                    events.append(Event(time: time, json: json))
                }
                eventCount += count
                clips.append(Clip(id: id, name: name, mode: mode, fps: fps, frameCount: frameCount, tracks: tracks, events: events,
                    reference: reference, ownsTracks: ownsTracks, rootMotionFlags: flags & NativeModelRootMotion.supportedMask))
            }
            try animation.requireEnd(next)
            guard try reader.readNullTerminatedUTF8(maxBytes: 16, "MDL final marker").isEmpty else {
                throw SceneError.invalid("Additional MDL sections are not implemented.")
            }
        }
        // Resolve after all entries are read, as in the reference's final
        // pointer-fixup pass. Sharing Swift arrays does not duplicate key data.
        // Always select the serialized target buffer, never a previously
        // resolved alias: reference chains with no actual keys are invalid.
        let serialized = clips
        for index in clips.indices {
            guard let reference = clips[index].reference else { continue }
            guard serialized.indices.contains(reference.animationIndex),
                  reference.startFrame <= reference.endFrame,
                  reference.endFrame <= serialized[reference.animationIndex].frameCount,
                  reference.frameOffset <= clips[index].frameCount,
                  reference.rootBone == -1 || bones.indices.contains(reference.rootBone) else {
                throw SceneError.invalid("MDLA clip reference, interval, offset or motion-root index is invalid.")
            }
            if !clips[index].ownsTracks {
                let target = serialized[reference.animationIndex]
                guard target.tracks.count == bones.count,
                      reference.startFrame <= target.frameCount - clips[index].frameCount,
                      target.tracks.allSatisfy({ $0.count == target.frameCount + 1 }) else {
                    throw SceneError.invalid("MDLA referenced clip has no complete dense buffer for its sampled interval.")
                }
                clips[index] = Clip(id: clips[index].id, name: clips[index].name, mode: clips[index].mode,
                    fps: clips[index].fps, frameCount: clips[index].frameCount, tracks: target.tracks, events: clips[index].events,
                    reference: reference, ownsTracks: false, sampleStart: reference.startFrame, rootMotionFlags: clips[index].rootMotionFlags)
            }
        }
        return try NativeModelSkeleton(bones: bones, clips: clips, animationBytes: animationBytes)
    }

    private static func section(_ reader: inout SceneByteReader, label: String) throws -> SceneByteReader {
        let end = Int(try reader.readUInt32("\(label) absolute end"))
        guard end >= reader.offset, end - reader.offset <= 64 * 1024 * 1024 else { throw SceneError.invalid("Invalid \(label) section end.") }
        return SceneByteReader(try reader.readData(end - reader.offset, label))
    }
    private static func readVector(_ reader: inout SceneByteReader, label: String) throws -> SIMD3<Float> {
        let value = SIMD3(try reader.readFloat32(label), try reader.readFloat32(label), try reader.readFloat32(label))
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { throw SceneError.invalid("Non-finite \(label).") }
        return value
    }
    private static func readMatrix(_ reader: inout SceneByteReader, label: String) throws -> simd_float4x4 {
        var columns: [SIMD4<Float>] = []
        for _ in 0..<4 {
            let xyz = try readVector(&reader, label: label)
            columns.append(SIMD4(xyz, try reader.readFloat32(label)))
        }
        let value = simd_float4x4(columns)
        guard finite(value), value[0].w == 0, value[1].w == 0, value[2].w == 0, value[3].w == 1 else {
            throw SceneError.invalid("Invalid affine \(label).")
        }
        return value
    }
    private static func finite(_ value: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in (0..<4).allSatisfy { value[column][$0].isFinite } }
    }
}
