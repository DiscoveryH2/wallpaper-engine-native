import Foundation

/// Only properties with a real numeric renderer consumer are exported. The
/// full path keeps material writes separate from layer transforms and effects.
struct SceneScriptMaterial {
    struct Property {
        let name: String
        let path: String
        let value: [Float]
        let authored: Any?
        let user: Any?

        var metadata: [String: Any] {
            var property = (authored as? [String: Any]).map { $0.filter { ["value", "user"].contains($0.key) } }
                ?? ["value": authored ?? value]
            if let user { property["user"] = user }
            return ["name": name, "path": path, "value": value, "property": property]
        }
    }
    let path: String
    let properties: [Property]

    var metadata: [String: Any] { ["path": path, "properties": properties.map(\.metadata)] }

    func prepending(_ prefix: String) -> Self {
        Self(path: prefix + path, properties: properties.map {
            Property(name: $0.name, path: prefix + $0.path, value: $0.value, authored: $0.authored, user: $0.user)
        })
    }

    /// Multiple shader passes may consume a single authored material. Keep its
    /// stable index and reject conflicting names or initial values.
    static func merge(_ entries: [Self]) throws -> [Self] {
        var order: [String] = [], materials: [String: [Property]] = [:]
        for entry in entries {
            if materials[entry.path] == nil { order.append(entry.path); materials[entry.path] = [] }
            for property in entry.properties {
                if let previous = materials[entry.path]!.first(where: { $0.name == property.name }) {
                    guard previous.path == property.path, previous.value == property.value,
                          NSDictionary(dictionary: previous.metadata).isEqual(to: property.metadata) else {
                        throw SceneError.invalid("\(entry.path)：材质多个阶段的同名参数不一致。")
                    }
                } else { materials[entry.path]!.append(property) }
            }
        }
        // Renderer traversal can visit the final draw before its offscreen
        // stages. Script indices always follow the author's numeric pass index.
        order.sort {
            let first = Int($0.split(separator: "/").last ?? "") ?? -1
            let second = Int($1.split(separator: "/").last ?? "") ?? -1
            return first < second
        }
        // Shader metadata is a dictionary, so rebuilding the same shader can
        // enumerate properties differently. Scripts address them by name;
        // stable ordering keeps resource-interface validation deterministic.
        return order.map { Self(path: $0, properties: materials[$0]!.sorted { $0.name < $1.name }) }
    }
}
