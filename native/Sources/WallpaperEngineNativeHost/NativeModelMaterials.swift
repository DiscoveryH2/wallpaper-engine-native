import Foundation

/// Internal addresses for material documents referenced by an MDL. The author
/// still supplies ordinary external material files; no new Scene format or
/// public model-layer methods are introduced.
enum NativeModelMaterials {
    static let key = "_nativeModelMaterials"
    static let chromaDimensions = ["tintfront": 3, "tintback": 3, "speculartint": 3, "tintpigmentation": 1, "tintwexponent": 1]
    static let dimensions = ["color": 3, "alpha": 1, "roughness": 1, "metallic": 1, "brightness": 1, "reflectivity": 1, "emissivecolor": 3, "emissivebrightness": 1, "rimamount": 1, "rimexponent": 1].merging(chromaDimensions) { _, next in next }

    static func owner(object: Int, material: Int) -> String {
        "/objects/\(object)/\(key)/\(material)"
    }

    static func isOwner(_ path: String) -> Bool {
        let p = path.split(separator: "/")
        return p.count == 4 && p[0] == "objects" && Int(p[1]).map { $0 >= 0 } == true
            && p[2] == Substring(key) && Int(p[3]).map { $0 >= 0 } == true
    }

    static func parameter(_ path: String) -> (object: Int, name: String, count: Int)? {
        let p = path.split(separator: "/").map(String.init)
        guard p.count == 8, p[0] == "objects", let object = Int(p[1]), object >= 0,
              p[2] == key, let material = Int(p[3]), material >= 0,
              p[4] == "passes", let pass = Int(p[5]), pass >= 0,
              p[6] == "constantshadervalues", let count = dimensions[p[7]] else { return nil }
        return (object, p[7], count)
    }

    /// Meshes sharing a material share its state within one model instance.
    /// Other model instances receive their own property/curve/script addresses.
    static func paths(_ model: SceneModel) -> [String] {
        var result: [String] = [], seen = Set<String>()
        for mesh in model.meshes where seen.insert(mesh.materialPath.lowercased()).inserted {
            result.append(mesh.materialPath)
        }
        return result
    }

    /// Extract only internally expanded inventories for models successfully
    /// loaded by the retained view. Conflicting instances cannot be reused.
    static func retainedPaths(scene: [String: Any], activeSlots: Set<Int>, eligible: Set<String>) -> [String: [String]] {
        guard let objects = scene["objects"] as? [[String: Any]] else { return [:] }
        var result: [String: [String]] = [:], ambiguous = Set<String>()
        for index in activeSlots.sorted() where objects.indices.contains(index) {
            let object = objects[index]
            guard let model = object["model"] as? String else { continue }
            let key = model.lowercased()
            guard eligible.contains(key), !ambiguous.contains(key),
                  let documents = object[Self.key] as? [[String: Any]] else { continue }
            var paths: [String] = []
            for document in documents {
                guard let path = document["resource"] as? String, !path.isEmpty else {
                    ambiguous.insert(key); result.removeValue(forKey: key); break
                }
                paths.append(path)
            }
            guard !ambiguous.contains(key) else { continue }
            if let existing = result[key], existing != paths {
                ambiguous.insert(key); result.removeValue(forKey: key)
            } else { result[key] = paths }
        }
        return result
    }

    static func expand(_ input: [String: Any], assets: SceneAssets,
                       cachedModelPaths: ((String) throws -> [String]?)? = nil,
                       loadModel: ((String) throws -> SceneModel)? = nil) throws -> [String: Any] {
        guard var objects = input["objects"] as? [[String: Any]], objects.count <= 5000 else {
            throw SceneError.invalid("模型材质展开需要有效的场景对象列表。")
        }
        var documents: [String: [[String: Any]]] = [:]
        var instanceBytes = 0, passCount = 0
        for index in objects.indices {
            guard objects[index][key] == nil else { throw SceneError.invalid("场景不能声明内部模型材质地址。") }
            guard let path = objects[index]["model"] as? String else { continue }
            let cacheKey = path.lowercased()
            if documents[cacheKey] == nil {
                guard documents.count < 512 else { throw SceneError.invalid("模型材质资源超过 512 份。") }
                let names: [String]
                if let cached = try cachedModelPaths?(path) { names = cached }
                else { names = paths(try loadModel?(path) ?? SceneModel.decode(assets.data(path))) }
                guard names.count <= 128 else { throw SceneError.invalid("单模型材质超过 128 份。") }
                documents[cacheKey] = try names.map { name in
                    let material = try assets.json(name)
                    guard let passes = material["passes"] as? [[String: Any]], !passes.isEmpty, passes.count <= 32 else {
                        throw SceneError.invalid("\(name)：模型材质需要 1...32 个阶段。")
                    }
                    return ["resource": name, "passes": passes]
                }
            }
            let materials = documents[cacheKey]!
            let bytes = try JSONSerialization.data(withJSONObject: materials).count
            guard bytes <= 4 * 1024 * 1024, bytes <= 16 * 1024 * 1024 - instanceBytes else {
                throw SceneError.invalid("模型材质实例声明超过单实例 4 MiB / 场景 16 MiB。")
            }
            passCount += materials.reduce(0) { $0 + ($1["passes"] as! [[String: Any]]).count }
            guard passCount <= 8192 else { throw SceneError.invalid("模型材质实例阶段超过 8192 项。") }
            instanceBytes += bytes
            objects[index][key] = materials
        }
        var result = input; result["objects"] = objects
        return result
    }
}
