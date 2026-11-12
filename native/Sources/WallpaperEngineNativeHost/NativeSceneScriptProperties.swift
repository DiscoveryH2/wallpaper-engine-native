import Foundation
import CoreFoundation

/// The documented IScene settings share one checked JSON boundary across both
/// renderers. Defaults match the existing reference-backed render consumers.
enum NativeSceneScriptProperties {
    static let flags: Set<String> = ["bloom", "clearenabled", "camerafade", "camerashake", "cameraparallax"]
    static let colors: Set<String> = ["clearcolor", "ambientcolor", "skylightcolor"]
    static let defaults: [String: Any] = [
        "bloom": false, "bloomstrength": 2.0, "bloomthreshold": 0.65,
        "clearenabled": true, "clearcolor": [0.0, 0.0, 0.0],
        "ambientcolor": [0.2, 0.2, 0.2], "skylightcolor": [0.2, 0.2, 0.2],
        "fov": 50.0, "nearz": 0.1, "farz": 10_000.0,
        "camerafade": true, "camerashake": false, "camerashakespeed": 3.0,
        "camerashakeamplitude": 0.5, "camerashakeroughness": 1.0,
        "cameraparallax": false, "cameraparallaxamount": 0.5,
        "cameraparallaxdelay": 0.1, "cameraparallaxmouseinfluence": 0.0
    ]

    static func name(at path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count == 2, parts[0] == "general", defaults[String(parts[1])] != nil else { return nil }
        return String(parts[1])
    }

    private static func checked(_ value: Any, key: String, authored: Bool) -> Any? {
        guard defaults[key] != nil else { return nil }
        if flags.contains(key) {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        func number(_ raw: Any) -> Float? {
            let double = NativeAnimationJSON.number(raw)?.doubleValue
                ?? (authored ? (raw as? String).flatMap(Double.init) : nil)
            guard let double, double.isFinite, abs(double) <= Double(Float.greatestFiniteMagnitude) else { return nil }
            return Float(double)
        }
        if colors.contains(key) {
            let parts: [Any]
            if authored { parts = SceneValues.floats(value).map { $0 as Any } }
            else if let array = value as? [Any] { parts = array }
            else { return nil }
            guard parts.count == 3 else { return nil }
            let values = parts.compactMap(number)
            return values.count == 3 ? values : nil
        }
        return number(value)
    }

    static func metadata(scene: [String: Any], properties: [String: Any]) -> [String: Any] {
        let general = scene["general"] as? [String: Any] ?? [:]
        return defaults.reduce(into: [String: Any]()) { result, entry in
            let (key, fallback) = entry
            let definition = general[key] as? [String: Any]
            let base = checked(definition?["value"] ?? general[key] ?? fallback, key: key, authored: true) ?? fallback
            var property: [String: Any] = ["value": base]
            var current: Any = base
            if let user = definition?["user"] {
                property["user"] = user
                let name = user as? String ?? (user as? [String: Any])?["name"] as? String
                if let name, let raw = properties[name] {
                    let value = (raw as? [String: Any])?["value"] ?? raw
                    if let condition = (user as? [String: Any])?["condition"] {
                        current = String(describing: value) == String(describing: condition)
                    } else { current = value }
                }
            }
            result[key] = ["kind": flags.contains(key) ? "boolean" : colors.contains(key) ? "vec3" : "number",
                           "value": checked(current, key: key, authored: true) ?? base, "property": property]
        }
    }

    static func receipt(_ raw: Any?) -> [String: Any]? {
        guard let raw = raw as? [String: Any], raw.count <= defaults.count else { return nil }
        var values: [String: Any] = [:]
        for (key, raw) in raw {
            guard let value = checked(raw, key: key, authored: false) else { return nil }
            values[key] = value
        }
        return values
    }
}
