import Foundation

/// Private, bounded NDJSON protocol between this app and its own watcher.
/// An invalidation is a reason to query Steam again, never an install receipt.
struct SteamEvent: Codable {
    let schema: Int
    let appid: UInt32
    let sequence: UInt64
    let kind: String
    let code: String
    let callbacks: [Int32]
    let item_ids: [String]
    let full_reconcile: Bool

    init(sequence: UInt64, kind: String, code: String = "ok", callbacks: [Int32] = [], items: [String] = [], full: Bool = false) {
        schema = 1; appid = 431960; self.sequence = sequence; self.kind = kind
        self.code = code; self.callbacks = callbacks; item_ids = items; full_reconcile = full
    }

    static let maximumLine = 65_536
    static let codes: Set<String> = ["ok", "client-not-running", "offline", "account-changed", "license-unconfirmed", "api-unavailable", "shutdown-requested"]
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let expected: Set<String> = ["schema", "appid", "sequence", "kind", "code", "callbacks", "item_ids", "full_reconcile"]
        guard Set(c.allKeys.map(\.stringValue)) == expected else { throw StreamError.invalid }
        func key(_ name: String) -> Key { Key(stringValue: name)! }
        schema = try c.decode(Int.self, forKey: key("schema"))
        appid = try c.decode(UInt32.self, forKey: key("appid"))
        sequence = try c.decode(UInt64.self, forKey: key("sequence"))
        kind = try c.decode(String.self, forKey: key("kind"))
        code = try c.decode(String.self, forKey: key("code"))
        callbacks = try c.decode([Int32].self, forKey: key("callbacks"))
        item_ids = try c.decode([String].self, forKey: key("item_ids"))
        full_reconcile = try c.decode(Bool.self, forKey: key("full_reconcile"))
        guard schema == 1, appid == 431960, sequence > 0, Self.codes.contains(code),
              callbacks.count <= 6, Set(callbacks).count == callbacks.count,
              item_ids.count <= 128, Set(item_ids).count == item_ids.count,
              item_ids.allSatisfy({ SteamLibraryIndex.validID($0) && UInt64($0).map { $0 > 0 } == true }) else { throw StreamError.invalid }
        switch kind {
        case "ready", "heartbeat":
            guard code == "ok", callbacks.isEmpty, item_ids.isEmpty, !full_reconcile else { throw StreamError.invalid }
        case "invalidated":
            guard code == "ok", !callbacks.isEmpty, Set(callbacks).isSubset(of: [101, 3418, 3405, 3406]),
                  full_reconcile || !item_ids.isEmpty else { throw StreamError.invalid }
        case "unavailable":
            guard code != "ok", callbacks.isEmpty, item_ids.isEmpty, !full_reconcile else { throw StreamError.invalid }
        case "shutting-down":
            guard code == "shutdown-requested", callbacks == [704], item_ids.isEmpty, full_reconcile else { throw StreamError.invalid }
        default: throw StreamError.invalid
        }
    }

    enum StreamError: Error { case invalid }
}

final class SteamEventWriter {
    private var sequence: UInt64 = 0
    func emit(_ kind: String, code: String = "ok", callbacks: [Int32] = [], items: [String] = [], full: Bool = false) throws {
        sequence += 1
        let event = SteamEvent(sequence: sequence, kind: kind, code: code, callbacks: callbacks, items: items, full: full)
        var data = try JSONEncoder().encode(event)
        guard data.count < SteamEvent.maximumLine else { throw SteamEvent.StreamError.invalid }
        data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
