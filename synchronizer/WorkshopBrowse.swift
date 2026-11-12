import Foundation
import CoreFoundation

/// AND between groups, OR within each group, followed by excluded tags.
/// Canonicalization makes the request/response check independent of UI order.
struct WorkshopBrowseFilters: Equatable {
    let required: [[String]]
    let excluded: [String]
    let keyValues: [String: String]
    static let empty = try! WorkshopBrowseFilters(required: [], excluded: [])
    var isEmpty: Bool { required.isEmpty && excluded.isEmpty && keyValues.isEmpty }
    var count: Int { required.reduce(0) { $0 + $1.count } + excluded.count + keyValues.count }
    var object: [String: Any] {
        var result: [String: Any] = ["required": required, "excluded": excluded]
        if !keyValues.isEmpty { result["keyValues"] = keyValues }
        return result
    }
    var json: String { String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)! }

    init(required: [[String]], excluded: [String], keyValues: [String: String] = [:]) throws {
        func valid(_ tag: String) -> Bool {
            !tag.isEmpty && tag.utf8.count <= 128 && tag == tag.trimmingCharacters(in: .whitespacesAndNewlines)
                && tag.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
        guard required.count <= 16, excluded.count <= 64, required.allSatisfy({ !$0.isEmpty && $0.count <= 64 }),
              required.flatMap({ $0 }).count <= 96, (required.flatMap({ $0 }) + excluded).allSatisfy(valid),
              Set(required.flatMap({ $0 })).isDisjoint(with: excluded) else { throw WorkshopBrowseRequest.BrowseError.invalidRequest }
        guard keyValues.count <= 16, keyValues.allSatisfy({ valid($0.key) && valid($0.value) }) else {
            throw WorkshopBrowseRequest.BrowseError.invalidRequest
        }
        self.required = Array(Set(required.map { Array(Set($0)).sorted() })).sorted { $0.lexicographicallyPrecedes($1) }
        self.excluded = Array(Set(excluded)).sorted()
        self.keyValues = keyValues
        guard self.json.utf8.count <= 8192 else { throw WorkshopBrowseRequest.BrowseError.invalidRequest }
    }
    init(json: String) throws {
        guard json.utf8.count <= 8192, let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WorkshopBrowseRequest.BrowseError.invalidRequest }
        try self.init(object: object)
    }
    init(object: [String: Any]) throws {
        guard Set(object.keys) == ["required", "excluded"] || Set(object.keys) == ["required", "excluded", "keyValues"],
              let required = object["required"] as? [[String]],
              let excluded = object["excluded"] as? [String] else { throw WorkshopBrowseRequest.BrowseError.invalidRequest }
        let keyValues: [String: String]
        if let value = object["keyValues"] {
            guard let parsed = value as? [String: String] else { throw WorkshopBrowseRequest.BrowseError.invalidRequest }
            keyValues = parsed
        } else { keyValues = [:] }
        try self.init(required: required, excluded: excluded, keyValues: keyValues)
    }
}

/// Steam CDN previews are optional. Other hosts, credentials, and redirects
/// outside this origin are never loaded by the native application.
enum WorkshopPreviewURL {
    static func parse(_ text: String) -> URL? {
        guard !text.isEmpty, text.utf8.count <= 2048,
              text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              parts.host?.lowercased() == "images.steamusercontent.com",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              parts.fragment == nil, !parts.path.isEmpty, let url = parts.url else { return nil }
        return url
    }
}

/// Input shared by the native browser and the owned Steam helper.
struct WorkshopBrowseRequest {
    enum Sort: String, CaseIterable {
        case relevant, trend, published, updated
        var queryType: Int32 {
            switch self {
            case .relevant: return 11
            case .trend: return 3
            case .published: return 1
            case .updated: return 19
            }
        }
    }
    let query: String
    let sort: Sort
    let cursor: String
    let filters: WorkshopBrowseFilters

    init(query: String, sort: String, cursor: String, filters: WorkshopBrowseFilters = .empty) throws {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.utf8.count <= 200,
              query.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let parsedSort = Sort(rawValue: sort),
              !cursor.isEmpty, cursor.utf8.count <= 255,
              cursor.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw BrowseError.invalidRequest
        }
        self.query = query; self.sort = parsedSort; self.cursor = cursor; self.filters = filters
    }

    var queryType: Int32 { query.isEmpty && sort == .relevant ? Sort.trend.queryType : sort.queryType }
    enum BrowseError: Error, CustomStringConvertible {
        case invalidRequest
        var description: String { "Invalid Workshop search text, sort order, or paging cursor" }
    }
}

struct WorkshopBrowsePage {
    struct Item {
        let id: String
        let title: String
        let state: UInt32
        let previewURL: URL?
        let sizeBytes: Int64?
        let sizeSource: String?
        /// `nil` means Steam did not provide a valid score. `0` is kept as a
        /// genuine 0% score and must not be conflated with missing metadata.
        let score: Double?
        /// Aggregate Steam vote counts. Both values must arrive together;
        /// neither describes the current account's personal vote.
        let votesUp: UInt32?
        let votesDown: UInt32?
        /// A raw, validated Unix timestamp. Presentation additionally rejects
        /// implausibly old/future values before asking the user's formatter.
        let updatedAt: UInt32?
        let tags: [String]

        /// Workshop's public tags, not Steam's generic EWorkshopFileType,
        /// identify Wallpaper Engine's playable kind. Only one canonical tag
        /// is safe to present as a type; conflicts stay intentionally unknown.
        var wallpaperTypeTag: String? {
            let known = ["Scene", "Video", "Web", "Application"]
            let matches = known.filter { tags.contains($0) }
            return matches.count == 1 ? matches[0] : nil
        }

        var positiveRate: Double? {
            guard let votesUp, let votesDown else { return nil }
            let total = UInt64(votesUp) + UInt64(votesDown)
            guard total > 0 else { return nil }
            return Double(votesUp) / Double(total)
        }

        var hasConfirmedVotes: Bool { votesUp != nil && votesDown != nil }

        static func localizedUpdatedDate(_ value: UInt32?, now: Date = Date(), locale: Locale = .current,
                                         timeZone: TimeZone = .current) -> String? {
            guard let value, value >= 946_684_800 else { return nil } // 2000-01-01
            let date = Date(timeIntervalSince1970: TimeInterval(value))
            // A corrupt UInt32 can otherwise be displayed as year 2106. A
            // small future allowance tolerates server/client clock skew.
            guard date <= now.addingTimeInterval(366 * 24 * 60 * 60) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = locale; formatter.timeZone = timeZone
            formatter.dateStyle = .medium; formatter.timeStyle = .short
            return formatter.string(from: date)
        }
    }
    let items: [Item]
    let total: UInt32
    let returned: Int
    let unavailable: Int
    let nextCursor: String?
    let cached: Bool

    init?(_ raw: [String: Any], request: WorkshopBrowseRequest) {
        func number(_ name: String) -> UInt32? {
            guard let value = raw[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  let exact = UInt32(exactly: value.doubleValue) else { return nil }
            return exact
        }
        guard raw["status"] as? String == "workshop-page", number("appid") == 431960,
              raw["source"] as? String == "official_steam_api", raw["query"] as? String == request.query,
              raw["sort"] as? String == request.sort.rawValue, raw["cursor"] as? String == request.cursor,
              let total = number("total"), let returned = number("returned"), returned <= 50, returned <= total,
              let unavailable = number("unavailable"), unavailable <= returned,
              let rows = raw["items"] as? [[String: Any]], rows.count == Int(returned - unavailable),
              let hasNext = raw["has_next"] as? Bool, let next = raw["next_cursor"] as? String,
              let cached = raw["query_cached"] as? Bool else { return nil }
        if let filters = raw["filters"] as? [String: Any] {
            guard (try? WorkshopBrowseFilters(object: filters)) == request.filters else { return nil }
        } else if !request.filters.isEmpty || raw["filters"] != nil { return nil }
        if hasNext {
            guard !next.isEmpty, next != request.cursor,
                  (try? WorkshopBrowseRequest(query: "", sort: "trend", cursor: next)) != nil else { return nil }
        } else if !next.isEmpty { return nil }
        var items: [Item] = [], ids = Set<String>()
        for row in rows {
            func rowNumber(_ name: String) -> UInt32? {
                guard let value = row[name] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      let exact = UInt32(exactly: value.doubleValue) else { return nil }
                return exact
            }
            guard let id = row["workshop_id"] as? String, SteamLibraryIndex.validID(id),
                  let value = UInt64(id), value > 0, ids.insert(id).inserted,
                  let title = row["title"] as? String, !title.isEmpty, title.utf8.count <= 512,
                  let stateValue = row["state"] as? NSNumber,
                  CFGetTypeID(stateValue) != CFBooleanGetTypeID(),
                  let state = UInt32(exactly: stateValue.doubleValue) else { return nil }
            // Keep untrusted titles as plain text and discard control characters.
            let safeTitle = String(String.UnicodeScalarView(title.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }))
            guard !safeTitle.isEmpty else { return nil }
            let previewURL = (row["preview_url"] as? String).flatMap(WorkshopPreviewURL.parse)
            let sizeValue = row["size_bytes"] as? NSNumber
            let source = row["size_source"] as? String
            let size = sizeValue.flatMap { value -> Int64? in
                guard CFGetTypeID(value) != CFBooleanGetTypeID(), ["total_files", "legacy_file"].contains(source ?? ""),
                      let result = Int64(exactly: value.doubleValue), result > 0,
                      result <= 16 * 1024 * 1024 * 1024 * 1024 else { return nil }
                return result
            }
            let score = (row["score"] as? NSNumber).flatMap { value -> Double? in
                let result = value.doubleValue
                guard CFGetTypeID(value) != CFBooleanGetTypeID(), result.isFinite, (0...1).contains(result) else { return nil }
                return result
            }
            let updatedAt = (row["time_updated"] as? NSNumber).flatMap { value -> UInt32? in
                guard CFGetTypeID(value) != CFBooleanGetTypeID(),
                      let result = UInt32(exactly: value.doubleValue), result > 0 else { return nil }
                return result
            }
            let rawVotesUp = rowNumber("votes_up"), rawVotesDown = rowNumber("votes_down")
            // A partial or malformed vote pair must never turn into a made-up
            // percentage. Absent fields stay absent for legacy helper output.
            let hasAnyVoteField = row["votes_up"] != nil || row["votes_down"] != nil
            let votesUp: UInt32?
            let votesDown: UInt32?
            if hasAnyVoteField, let rawVotesUp, let rawVotesDown {
                votesUp = rawVotesUp; votesDown = rawVotesDown
            } else { votesUp = nil; votesDown = nil }
            items.append(Item(id: id, title: safeTitle, state: state, previewURL: previewURL,
                              sizeBytes: size, sizeSource: size == nil ? nil : source,
                              score: score, votesUp: votesUp, votesDown: votesDown, updatedAt: updatedAt,
                              tags: (row["tags"] as? [String] ?? []).prefix(64).filter {
                                  !$0.isEmpty && $0.utf8.count <= 256 && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
                              }))
        }
        self.items = items; self.total = total; self.returned = Int(returned); self.unavailable = Int(unavailable)
        self.nextCursor = hasNext ? next : nil; self.cached = cached
    }
}
