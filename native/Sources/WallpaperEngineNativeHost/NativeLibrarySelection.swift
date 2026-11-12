import Foundation

/// The detail/playback selection and additional management selections are
/// separate in the official browser. Modifier selection never applies a file.
struct NativeLibrarySelection: Equatable {
    var primary: String?
    private(set) var additional: [String] = []
    var selected: Set<String> { Set(additional + [primary].compactMap { $0 }) }
    mutating func clearAdditional() { additional.removeAll() }
    mutating func choose(_ id: String?) {
        if id != primary { additional.removeAll(); primary = id }
    }
    mutating func add(_ ids: [String]) {
        var present = Set(additional)
        for id in ids where present.insert(id).inserted { additional.append(id) }
    }
    mutating func toggle(_ id: String) {
        if primary == id || additional.contains(id) {
            if primary == id { primary = nil }
            additional.removeAll { $0 == id }
        } else { additional.append(id) }
    }
    mutating func range(to id: String, order: [String]) {
        additional = [id]
        var inside = false
        for next in order {
            if next == id || next == primary { inside.toggle() }
            if inside { add([next]) }
        }
    }
    mutating func rectangle(_ ids: [String], command: Bool, shift: Bool) {
        if command { for id in ids { toggle(id) } }
        else {
            if !shift { primary = nil; additional.removeAll() }
            add(ids)
        }
    }
    func targets(clicked: String?, eligible: Set<String>) -> [String] {
        if additional.isEmpty, let clicked { return [clicked] }
        var result = additional
        if let primary, !result.contains(primary) { result.insert(primary, at: 0) }
        if let clicked, !result.contains(clicked) { result.insert(clicked, at: 0) }
        return result.filter { eligible.contains($0) }
    }
}

struct NativeLibraryDragPayload: Codable, Equatable {
    static let pasteboardType = "io.wallpaper-engine-native.library-items-v1"
    let owner: UUID
    let session: UUID
    let sourceFolder: String?
    let identities: [String]
    func encoded() -> Data? {
        guard !identities.isEmpty, identities.count <= 10_000, Set(identities).count == identities.count,
              identities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8192 }),
              let data = try? JSONEncoder().encode(self), data.count <= 2 * 1024 * 1024 else { return nil }
        return data
    }
    init(owner: UUID, session: UUID, sourceFolder: String?, identities: [String]) {
        self.owner = owner; self.session = session; self.sourceFolder = sourceFolder; self.identities = identities
    }
    init?(data: Data) {
        guard data.count <= 2 * 1024 * 1024, let value = try? JSONDecoder().decode(Self.self, from: data), value.encoded() != nil else { return nil }
        self = value
    }
}
