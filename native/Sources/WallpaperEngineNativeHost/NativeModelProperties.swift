import Foundation

/// Property paths identify authored animation layers, independently of the
/// mutable playback order used by createAnimationLayer/destroyAnimationLayer.
enum NativeModelProperties {
    static let numbers: Set<String> = ["rate", "blend", "blendtime"]
    static let flags: Set<String> = ["visible", "additive", "blendin", "blendout"]
    static var keys: Set<String> { numbers.union(flags) }
    struct Address {
        let object: Int, layer: Int
        let property: String
    }
    static func address(_ path: String) -> Address? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 5, parts[0] == "objects", let object = Int(parts[1]), object >= 0,
              parts[2] == "animationlayers", let layer = Int(parts[3]), (0..<32).contains(layer),
              keys.contains(parts[4]) else { return nil }
        return Address(object: object, layer: layer, property: parts[4])
    }

    static func sample(_ player: NativeModelAnimation.Runtime, object: Int, time: Double,
                       timelines: SceneTimelines, resolve: (Any?) -> Any?) throws -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        let alive = Set(player.layers.map(\.key))
        for (index, layer) in player.source.layers.enumerated() where alive.contains(layer.key) {
            for key in keys where (layer.raw[key] as? [String: Any])?["animation"] != nil {
                let path = "/objects/\(object)/animationlayers/\(index)/\(key)"
                guard numbers.contains(key), let value = timelines.value(at: path, time: time, base: resolve(layer.raw[key])) else {
                    throw SceneError.invalid("\(path)：模型动画层时间轴没有有效采样。")
                }
                result[layer.key, default: [:]][key] = value
            }
        }
        return result
    }
}
