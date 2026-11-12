import Foundation

/// Native state matching the query rules in public build 26168761.
/// Ordinary groups allow checked tags; feature tags independently require or exclude.
struct NativeWorkshopFilterState: Equatable {
    enum Group: String, CaseIterable { case type, category, age, resolution, genre }
    enum Feature: Int { case unrestricted = 0, included = 1, excluded = 2 }
    private(set) var allowed: [Group: Set<String>]
    private(set) var features: [String: Feature] = [:]
    var mobileOnly = false

    init() {
        allowed = Dictionary(uniqueKeysWithValues: Group.allCases.map { group in
            (group, Set(NativeWorkshopFilterCatalog.choices(for: group).map(\.tag)))
        })
        allowed[.type]?.remove("Application")
        allowed[.age] = ["Everyone"]
        allowed[.genre]?.remove("Unspecified")
    }
    var isDefault: Bool { self == Self() }
    func isAllowed(_ tag: String, in group: Group) -> Bool { allowed[group]?.contains(tag) == true }
    mutating func setAllowed(_ tag: String, in group: Group, to value: Bool) {
        guard NativeWorkshopFilterCatalog.choices(for: group).contains(where: { $0.tag == tag }) else { return }
        if value { allowed[group, default: []].insert(tag) }
        else { allowed[group]?.remove(tag) }
    }
    mutating func setAll(in group: Group, to value: Bool, tags: [String]? = nil) {
        for tag in tags ?? NativeWorkshopFilterCatalog.choices(for: group).map(\.tag) {
            // The official Workshop 'all genres' action keeps Unspecified excluded.
            setAllowed(tag, in: group, to: value && !(group == .genre && tag == "Unspecified"))
        }
    }
    mutating func setFeature(_ tag: String, to value: Feature) {
        guard NativeWorkshopFilterCatalog.features.contains(where: { $0.tag == tag }) else { return }
        if value == .unrestricted { features.removeValue(forKey: tag) }
        else { features[tag] = value }
    }
    var filters: WorkshopBrowseFilters {
        var excluded: [String] = [], required: [[String]] = []
        for group in Group.allCases {
            let choices = NativeWorkshopFilterCatalog.choices(for: group).map(\.tag)
            let disabled = choices.filter { !isAllowed($0, in: group) }
            // The official query treats a whole unchecked group as unrestricted;
            // genres retain only the Unspecified exclusion in that case.
            if disabled.count == choices.count {
                if group == .genre { excluded.append("Unspecified") }
            } else { excluded.append(contentsOf: disabled) }
        }
        for (tag, state) in features {
            if state == .included { required.append([tag]) }
            else if state == .excluded { excluded.append(tag) }
        }
        if mobileOnly { excluded.append(contentsOf: ["Application", "Web"]) }
        return try! WorkshopBrowseFilters(required: required, excluded: excluded,
            keyValues: mobileOnly ? ["app_workshop_eula_version": "3"] : [:])
    }
}
