import AppKit

/// Native controls for the verified public-build filter structure and semantics.
@MainActor
final class NativeWorkshopFiltersView: NSScrollView {
    typealias Choice = NativeWorkshopFilterCatalog.Choice
    typealias Group = NativeWorkshopFilterState.Group
    var onChange: ((WorkshopBrowseFilters) -> Void)?
    private(set) var state = NativeWorkshopFilterState()
    private var allowedButtons: [(Group, String, NSButton)] = []
    private var featureButtons: [(String, NSButton)] = []
    private let mobile = NSButton()
    private var sections: [String: NativeWorkshopFilterSection] = [:]
    static let types = NativeWorkshopFilterCatalog.types
    static let ages = NativeWorkshopFilterCatalog.ages
    static let resolutions = NativeWorkshopFilterCatalog.resolutions
    static let genres = NativeWorkshopFilterCatalog.genres
    static let features = NativeWorkshopFilterCatalog.features
    var filters: WorkshopBrowseFilters { state.filters }
    var isDefault: Bool { state.isDefault }

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true; drawsBackground = false; borderType = .noBorder
        contentView = NativeWorkshopFilterClipView()
        let body = NSStackView(); body.orientation = .vertical; body.alignment = .leading; body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false; documentView = body
        func append(_ view: NSView) {
            body.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        let reset = NativeWorkshopFilterActionButton(title: NativeWorkshopFilterCatalog.resetTitle) { [weak self] in
            self?.state = NativeWorkshopFilterState(); self?.refresh(); self?.changed()
        }
        reset.identifier = NSUserInterfaceItemIdentifier("resetWorkshopFilters")
        append(reset)
        let special = NSStackView(); special.orientation = .vertical; special.alignment = .leading; special.spacing = 5
        let heading = NSTextField(labelWithString: NativeWorkshopFilterCatalog.showOnlyTitle)
        heading.font = .systemFont(ofSize: 13, weight: .semibold); special.addArrangedSubview(heading)
        for choice in Self.features {
            let button = NSButton(checkboxWithTitle: choice.title, target: self, action: #selector(featureChanged(_:)))
            button.state = .off
            button.identifier = NSUserInterfaceItemIdentifier("workshopTag_" + choice.tag)
            button.toolTip = "只显示具有此特征的壁纸。"
            special.addArrangedSubview(button); featureButtons.append((choice.tag, button))
        }
        mobile.setButtonType(.switch); mobile.title = NativeWorkshopFilterCatalog.mobileTitle
        mobile.target = self; mobile.action = #selector(mobileChanged)
        mobile.identifier = NSUserInterfaceItemIdentifier("workshopMobileCompatible")
        // The original places mobile compatibility directly after Approved.
        special.insertArrangedSubview(mobile, at: 2)
        append(special)
        let typeSection = section("type", title: NativeWorkshopFilterCatalog.typeTitle, expanded: true)
        for choice in Self.types where choice.tag != "Application" { addAllowed(choice, group: .type, to: typeSection.body) }
        let divider = NSBox(); divider.boxType = .separator; typeSection.body.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: typeSection.body.widthAnchor).isActive = true
        for choice in NativeWorkshopFilterCatalog.categories { addAllowed(choice, group: .category, to: typeSection.body) }
        append(typeSection)
        let ageSection = section("age", title: NativeWorkshopFilterCatalog.ageTitle, expanded: true)
        for choice in Self.ages { addAllowed(choice, group: .age, to: ageSection.body) }
        append(ageSection)
        let resolutionSection = section("resolution", title: NativeWorkshopFilterCatalog.resolutionTitle, expanded: false)
        for spec in NativeWorkshopFilterCatalog.resolutionSections {
            let label = NSTextField(labelWithString: spec.title); label.font = .systemFont(ofSize: 12, weight: .semibold)
            resolutionSection.body.addArrangedSubview(label)
            let tags = spec.range.map { Self.resolutions[$0].tag }
            addAllNone(group: .resolution, tags: tags, suffix: String(spec.range.lowerBound), to: resolutionSection.body)
            for index in spec.range { addAllowed(Self.resolutions[index], group: .resolution, to: resolutionSection.body) }
        }
        for choice in Self.resolutions.dropFirst(23) { addAllowed(choice, group: .resolution, to: resolutionSection.body) }
        append(resolutionSection)
        let genreSection = section("genre", title: NativeWorkshopFilterCatalog.genreTitle, expanded: false)
        addAllNone(group: .genre, tags: nil, suffix: "all", to: genreSection.body)
        for choice in Self.genres { addAllowed(choice, group: .genre, to: genreSection.body) }
        append(genreSection)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10),
            body.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    private func section(_ key: String, title: String, expanded: Bool) -> NativeWorkshopFilterSection {
        let section = NativeWorkshopFilterSection(key: key, title: title, expanded: expanded)
        sections[key] = section; return section
    }
    private func addAllowed(_ choice: Choice, group: Group, to stack: NSStackView) {
        let button = NSButton(checkboxWithTitle: choice.title, target: self, action: #selector(allowedChanged(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("workshopAllowed_" + group.rawValue + "_" + choice.tag)
        button.setAccessibilityLabel(choice.title)
        stack.addArrangedSubview(button); allowedButtons.append((group, choice.tag, button))
    }
    private func addAllNone(group: Group, tags: [String]?, suffix: String, to stack: NSStackView) {
        var buttons: [NSButton] = []
        for enabled in [true, false] {
            let button = NativeWorkshopFilterActionButton(title: enabled ? NativeWorkshopFilterCatalog.allTitle : NativeWorkshopFilterCatalog.noneTitle) { [weak self] in
                guard let self else { return }
                self.state.setAll(in: group, to: enabled, tags: tags); self.refresh(); self.changed()
            }
            button.identifier = NSUserInterfaceItemIdentifier("workshopAll_" + group.rawValue + "_" + suffix + "_" + (enabled ? "on" : "off"))
            buttons.append(button)
        }
        let row = NSStackView(views: buttons); row.spacing = 6; stack.addArrangedSubview(row)
    }
    @objc private func allowedChanged(_ sender: NSButton) {
        guard let entry = allowedButtons.first(where: { $0.2 === sender }) else { return }
        state.setAllowed(entry.1, in: entry.0, to: sender.state == .on); changed()
    }
    @objc private func featureChanged(_ sender: NSButton) {
        guard let entry = featureButtons.first(where: { $0.1 === sender }) else { return }
        state.setFeature(entry.0, to: sender.state == .on ? .included : .unrestricted)
        changed()
    }
    @objc private func mobileChanged() { state.mobileOnly = mobile.state == .on; changed() }
    private func changed() { onChange?(filters) }
    private func refresh() {
        for (group, tag, button) in allowedButtons { button.state = state.isAllowed(tag, in: group) ? .on : .off }
        for (tag, button) in featureButtons {
            switch state.features[tag] ?? .unrestricted {
            case .unrestricted: button.state = .off
            case .included: button.state = .on
            case .excluded: button.state = .mixed
            }
        }
        mobile.state = state.mobileOnly ? .on : .off
    }
}

final class NativeWorkshopFilterClipView: NSClipView { override var isFlipped: Bool { true } }

@MainActor
final class NativeWorkshopFilterSection: NSStackView {
    let body = NSStackView()
    private let header = NSButton()
    private let title: String
    private var expanded: Bool
    init(key: String, title: String, expanded: Bool, namespace: String = "workshop") {
        self.title = title; self.expanded = expanded
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 5
        header.isBordered = false; header.alignment = .left; header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.target = self; header.action = #selector(toggle)
        header.identifier = NSUserInterfaceItemIdentifier(namespace + "Section_" + key)
        header.setAccessibilityLabel(title)
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 5
        addArrangedSubview(header); addArrangedSubview(body)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        update()
    }
    required init?(coder: NSCoder) { nil }
    @objc private func toggle() { expanded.toggle(); update() }
    private func update() {
        header.title = (expanded ? "▾ " : "▸ ") + title
        header.setAccessibilityValue(expanded ? 1 : 0)
        setVisibilityPriority(expanded ? .mustHold : .notVisible, for: body)
    }
}

@MainActor
final class NativeWorkshopFilterActionButton: NSButton {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; action = #selector(invoke)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func invoke() { handler() }
}

