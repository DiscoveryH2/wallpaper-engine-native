import Foundation

struct NativeInstalledSort: Equatable, Codable {
    enum Criterion: String, CaseIterable, Codable {
        case name, rating, favorite, filesize, subscriptiondate, updatedate
        var title: String {
            switch self {
            case .name: return "名称"; case .rating: return "分级"; case .favorite: return "收藏"
            case .filesize: return "文件大小"; case .subscriptiondate: return "订阅日期"; case .updatedate: return "最近更新"
            }
        }
    }
    struct Entry {
        let title: String
        var rating: Double = 0
        var favorite = false
        var filesize: Double = 0
        var subscriptiondate: Double = 0
        var updatedate: Double = 0
    }
    var criterion: Criterion = .name
    var descending = false
    // localeCompare uses lexical, not numeric/natural ordering. The runtime
    // locale is kept explicit for the independent JS comparison fixture.
    func precedes(_ a: Entry, _ b: Entry, locale: Locale = .current) -> Bool {
        func name() -> Bool {
            let value = a.title.compare(b.title, options: [], locale: locale)
            return descending ? value == .orderedDescending : value == .orderedAscending
        }
        switch criterion {
        case .name: return name()
        case .favorite:
            if a.favorite == b.favorite { return name() }
            return descending ? b.favorite : a.favorite
        case .rating:
            if a.rating == b.rating { return name() }
            return descending ? a.rating < b.rating : a.rating > b.rating
        case .filesize, .subscriptiondate, .updatedate:
            let left = criterion == .filesize ? a.filesize : criterion == .subscriptiondate ? a.subscriptiondate : a.updatedate
            let right = criterion == .filesize ? b.filesize : criterion == .subscriptiondate ? b.subscriptiondate : b.updatedate
            if left == 0 && right == 0 { return name() }
            // Nonzero ties retain incoming order in the official JS sort.
            return descending ? left < right : left > right
        }
    }
    static func stored(_ defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: "libraryInstalledSortV1"), data.count <= 1024,
           let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        let old = defaults.string(forKey: "librarySortOrder")
        return .init(criterion: old == "savedRecent" ? .updatedate : .name, descending: old == "descending")
    }
    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "libraryInstalledSortV1") }
    }
}
