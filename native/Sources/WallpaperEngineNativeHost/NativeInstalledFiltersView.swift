import AppKit

/// Installed and online browsing share labels and controls, but not defaults
/// or predicates. A change here only filters the local browser inventory.
@MainActor
final class NativeInstalledFiltersView: NSScrollView {
    typealias Group = NativeInstalledFilterState.Group
    private(set) var state: NativeInstalledFilterState
    var onChange: ((NativeInstalledFilterState) -> Void)?
    var onReset: (() -> Void)?
    private var allowedButtons: [(Group, String, NSButton)] = []
    private var featureButtons: [(String, NSButton)] = []
    private let mobile = NSButton()
    private let favorites = NSButton()
    init(state: NativeInstalledFilterState) {
        self.state = state
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("installedFilterSidebar")
        hasVerticalScroller = true; drawsBackground = false; borderType = .noBorder
        contentView = NativeWorkshopFilterClipView()
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false; documentView = body
        func append(_ view: NSView) {
            body.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let reset = NativeWorkshopFilterActionButton(title: NativeWorkshopFilterCatalog.resetTitle) { [weak self] in self?.onReset?() }
        reset.identifier = NSUserInterfaceItemIdentifier("resetInstalledFilters"); append(reset)
        let special = NSStackView(); special.orientation = .vertical; special.alignment = .leading; special.spacing = 5
        let heading = NSTextField(labelWithString: NativeWorkshopFilterCatalog.showOnlyTitle)
        heading.font = .systemFont(ofSize: 13, weight: .semibold); special.addArrangedSubview(heading)
        for choice in NativeWorkshopFilterCatalog.features {
            let button = NSButton(checkboxWithTitle: choice.title, target: self, action: #selector(featureChanged(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("installedTag_" + choice.tag)
            special.addArrangedSubview(button); featureButtons.append((choice.tag, button))
        }
        mobile.setButtonType(.switch); mobile.title = NativeWorkshopFilterCatalog.mobileTitle
        mobile.target = self; mobile.action = #selector(mobileChanged)
        mobile.identifier = NSUserInterfaceItemIdentifier("installedMobileCompatible")
        favorites.setButtonType(.switch); favorites.title = "我的收藏"
        favorites.target = self; favorites.action = #selector(favoritesChanged)
        favorites.identifier = NSUserInterfaceItemIdentifier("installedFavoritesOnly")
        special.insertArrangedSubview(favorites, at: 2)
        special.insertArrangedSubview(mobile, at: 3); append(special)
        setFavoritesAvailable(false)
        let types = section(.type, title: NativeWorkshopFilterCatalog.typeTitle, expanded: true)
        for choice in Group.type.choices { addAllowed(choice, group: .type, to: types.body) }
        let divider = NSBox(); divider.boxType = .separator; types.body.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: types.body.widthAnchor).isActive = true
        for choice in Group.category.choices { addAllowed(choice, group: .category, to: types.body) }
        append(types)
        let ages = section(.age, title: NativeWorkshopFilterCatalog.ageTitle, expanded: true)
        for choice in Group.age.choices { addAllowed(choice, group: .age, to: ages.body) }; append(ages)
        let resolutions = section(.resolution, title: NativeWorkshopFilterCatalog.resolutionTitle, expanded: false)
        for spec in NativeWorkshopFilterCatalog.resolutionSections {
            let label = NSTextField(labelWithString: spec.title); label.font = .systemFont(ofSize: 12, weight: .semibold)
            resolutions.body.addArrangedSubview(label)
            addAllNone(.resolution, tags: spec.range.map { Group.resolution.choices[$0].tag }, suffix: String(spec.range.lowerBound), to: resolutions.body)
            for index in spec.range { addAllowed(Group.resolution.choices[index], group: .resolution, to: resolutions.body) }
        }
        for choice in Group.resolution.choices.dropFirst(23) { addAllowed(choice, group: .resolution, to: resolutions.body) }
        append(resolutions)
        let sources = section(.source, title: "来源", expanded: true)
        for choice in Group.source.choices { addAllowed(choice, group: .source, to: sources.body) }; append(sources)
        let genres = section(.genre, title: NativeWorkshopFilterCatalog.genreTitle, expanded: false)
        addAllNone(.genre, tags: nil, suffix: "all", to: genres.body)
        for choice in Group.genre.choices { addAllowed(choice, group: .genre, to: genres.body) }; append(genres)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            body.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4)
        ])
        setState(state)
    }
    required init?(coder: NSCoder) { nil }
    private func section(_ group: Group, title: String, expanded: Bool) -> NativeWorkshopFilterSection {
        NativeWorkshopFilterSection(key: group.rawValue, title: title, expanded: expanded, namespace: "installed")
    }
    private func addAllowed(_ choice: NativeWorkshopFilterCatalog.Choice, group: Group, to stack: NSStackView) {
        let button = NSButton(checkboxWithTitle: choice.title, target: self, action: #selector(allowedChanged(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("installedAllowed_" + group.rawValue + "_" + choice.tag)
        stack.addArrangedSubview(button); allowedButtons.append((group, choice.tag, button))
    }
    private func addAllNone(_ group: Group, tags: [String]?, suffix: String, to stack: NSStackView) {
        let row = NSStackView(); row.spacing = 6
        for enabled in [true, false] {
            let button = NativeWorkshopFilterActionButton(title: enabled ? NativeWorkshopFilterCatalog.allTitle : NativeWorkshopFilterCatalog.noneTitle) { [weak self] in
                guard let self else { return }
                self.state.setAll(in: group, to: enabled, tags: tags); self.setState(self.state); self.onChange?(self.state)
            }
            button.identifier = NSUserInterfaceItemIdentifier("installedAll_" + group.rawValue + "_" + suffix + "_" + (enabled ? "on" : "off"))
            row.addArrangedSubview(button)
        }
        stack.addArrangedSubview(row)
    }
    func setState(_ value: NativeInstalledFilterState) {
        state = value
        for (group, tag, button) in allowedButtons { button.state = state.isAllowed(tag, in: group) ? .on : .off }
        for (tag, button) in featureButtons { button.state = state.features[tag] == 1 ? .on : state.features[tag] == 2 ? .mixed : .off }
        mobile.state = state.mobileOnly ? .on : .off
        favorites.state = state.favoritesOnly ? .on : .off
    }
    func setFavoritesAvailable(_ available: Bool) {
        favorites.isEnabled = available
        favorites.toolTip = available ? "只显示此 Steam 账号收藏的壁纸。" : "Steam 收藏状态尚未读取；请连接 Steam 并同步订阅。"
    }
    @objc private func allowedChanged(_ sender: NSButton) {
        guard let (group, tag, _) = allowedButtons.first(where: { $0.2 === sender }) else { return }
        state.setAllowed(tag, in: group, to: sender.state == .on); onChange?(state)
    }
    @objc private func featureChanged(_ sender: NSButton) {
        guard let (tag, _) = featureButtons.first(where: { $0.1 === sender }) else { return }
        state.setFeature(tag, to: sender.state == .on ? 1 : 0); onChange?(state)
    }
    @objc private func mobileChanged() { state.mobileOnly = mobile.state == .on; onChange?(state) }
    @objc private func favoritesChanged() { state.favoritesOnly = favorites.state == .on; onChange?(state) }
}
