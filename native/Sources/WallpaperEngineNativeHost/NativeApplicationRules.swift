import Foundation

/// Identifiers and labels from stable build 26168761. These data types do not
/// launch applications, load wallpapers, or grant access to other applications.
enum NativeApplicationCondition: String, Codable, CaseIterable, Sendable {
    case running, focused, maximized, fullscreen, playingaudio
    var title: String {
        switch self {
        case .running: return "运行中"
        case .focused: return "成为焦点"
        case .maximized: return "最大化"
        case .fullscreen: return "全屏"
        case .playingaudio: return "正在播放音频"
        }
    }
    var translationKey: String { "ui_settings_playback_condition_is_" + (self == .playingaudio ? "playing_audio" : rawValue) }
}

enum NativeApplicationAction: String, Codable, CaseIterable, Sendable {
    case run, mute, pause, pauseall, stop, loadwallpaper, loadplaylist, loadprofile
    var requiresSelection: Bool { self == .loadwallpaper || self == .loadplaylist || self == .loadprofile }
    func translationKey(multimonitor: Bool) -> String {
        let suffix: String
        switch self {
        case .run: suffix = "keep_running"
        case .mute: suffix = "mute"
        case .pause: suffix = multimonitor ? "pause_per_monitor" : "pause"
        case .pauseall: suffix = "pause_all"
        case .stop: suffix = "stop"
        case .loadwallpaper: suffix = "load_wallpaper"
        case .loadplaylist: suffix = "load_playlist"
        case .loadprofile: suffix = "load_profile"
        }
        return "ui_settings_playback_" + suffix
    }
    func title(multimonitor: Bool) -> String {
        switch self {
        case .run: return "保持运行"
        case .mute: return "静音"
        case .pause: return multimonitor ? "按显示器暂停" : "暂停"
        case .pauseall: return "暂停所有"
        case .stop: return "停止（释放内存）"
        case .loadwallpaper: return "加载壁纸"
        case .loadplaylist: return "加载播放列表"
        case .loadprofile: return "加载配置文件"
        }
    }
    static func options(for condition: NativeApplicationCondition, multimonitor: Bool) -> [Self] {
        var result: [Self] = condition == .running ? [] : [.run]
        result += [.mute, .pause]
        if multimonitor && condition != .running && condition != .playingaudio { result.append(.pauseall) }
        if condition != .playingaudio { result.append(.stop) }
        return result + [.loadwallpaper, .loadplaylist, .loadprofile]
    }
}

enum NativeApplicationRuleError: Error, LocalizedError {
    case invalidExecutable, missingTarget, invalidTarget, tooManyRules, invalidArchive, staleEdit
    var errorDescription: String? {
        switch self {
        case .invalidExecutable: return "请选择应用程序，或填写可执行文件的名称。"
        case .missingTarget: return "请先选择壁纸、播放列表或配置文件。"
        case .invalidTarget: return "所选项目名称或位置无效。"
        case .tooManyRules: return "应用程序规则数量超出限制。"
        case .invalidArchive: return "无法读取已保存的应用程序规则。"
        case .staleEdit: return "规则列表已发生变化，请重新选择要编辑的规则。"
        }
    }
}

struct NativeApplicationRule: Codable, Equatable, Sendable {
    var executable: String
    var condition: NativeApplicationCondition = .running
    var action: NativeApplicationAction = .pause
    var file: String?

    /// The Windows parser lowercases executable names. macOS uses the actual
    /// native basename: it must not append ".exe" or identify an app by title.
    var executableKey: String { executable.lowercased() }
    func validated() throws -> Self {
        guard !executable.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              executable.utf8.count <= 1_024, executable != ".", executable != "..",
              !executable.contains("/"), !executable.contains("\\"),
              executable.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeApplicationRuleError.invalidExecutable
        }
        if action.requiresSelection {
            guard let file, !file.isEmpty else { throw NativeApplicationRuleError.missingTarget }
            guard file.utf8.count <= 8_192,
                  file.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
                throw NativeApplicationRuleError.invalidTarget
            }
        }
        return self
    }
}

enum NativeApplicationRulesStore {
    static let key = "nativeApplicationRulesV1"
    static let maximumRules = 1_024
    static let maximumBytes = 524_288
    private struct Archive: Codable { let version: Int; let rules: [NativeApplicationRule] }
    static func validate(_ rules: [NativeApplicationRule]) throws {
        guard rules.count <= maximumRules else { throw NativeApplicationRuleError.tooManyRules }
        for rule in rules { _ = try rule.validated() }
    }
    static func decode(_ data: Data) throws -> [NativeApplicationRule] {
        guard data.count <= maximumBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data), archive.version == 1 else {
            throw NativeApplicationRuleError.invalidArchive
        }
        try validate(archive.rules)
        return archive.rules
    }
    static func encode(_ rules: [NativeApplicationRule]) throws -> Data {
        try validate(rules)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(Archive(version: 1, rules: rules))
        guard data.count <= maximumBytes else { throw NativeApplicationRuleError.invalidArchive }
        return data
    }
    static func load(defaults: UserDefaults = .standard) throws -> [NativeApplicationRule] {
        guard let value = defaults.object(forKey: key) else { return [] }
        guard let data = value as? Data else { throw NativeApplicationRuleError.invalidArchive }
        return try decode(data)
    }
    static func save(_ rules: [NativeApplicationRule], defaults: UserDefaults = .standard) throws {
        // Validation and encoding finish before the only persistent mutation.
        let data = try encode(rules)
        if defaults.data(forKey: key) != data { defaults.set(data, forKey: key) }
    }
}

/// Ephemeral provenance for an audio event.  Rule archives only persist the
/// user's condition/action; an observation is never serialized or reused.
struct NativeApplicationAudioEvidence: Hashable, Sendable {
    let topologyID: UUID
    let generation: UInt64
    let isFresh: Bool
}

struct NativeApplicationConditionEvent: Hashable, Sendable {
    let executable: String
    let condition: NativeApplicationCondition
    /// Window observations have a concrete screen.  Audio process taps do
    /// not; nil follows the evaluator's global pause path rather than using a
    /// fabricated display id (such as 0).
    let display: UInt32?
    /// Non-nil only for a fresh, authenticated Process Audio Meter snapshot.
    let audioEvidence: NativeApplicationAudioEvidence?
    init(executable: String, condition: NativeApplicationCondition, display: UInt32?,
         audioEvidence: NativeApplicationAudioEvidence? = nil) {
        self.executable = executable; self.condition = condition; self.display = display
        self.audioEvidence = audioEvidence
    }
}

struct NativeApplicationRuleInput: Sendable {
    var runningExecutables: Set<String> = []
    /// Events must be observed conditions. An audio-I/O flag alone is not a
    /// playingaudio event; the official engine checks the session's peak level.
    var events: [NativeApplicationConditionEvent] = []
}

struct NativeApplicationRuleEffects: Equatable, Sendable {
    struct Selection: Equatable, Sendable {
        let ruleIndex: Int
        let loadIndex: Int
        let action: NativeApplicationAction
        let file: String
    }
    var muted = false
    var pausedDisplays: Set<UInt32> = []
    var pauseAll = false
    var stopAll = false
    var selection: Selection?
    var automaticEvents: [NativeApplicationConditionEvent] = []
}

/// Reconstructed from REA/Ghidra observations of the owned stable executable:
/// 1401359c0 (aggregate playback), 140135c40 (reverse load scan), 14003d050 /
/// 14003bba0 (window exceptions), 140138b80 (audio keep-running exception).
/// This is a decision model, not a claim that a host has executed its effects.
struct NativeApplicationRuleEvaluator: Sendable {
    private struct Entry: Sendable { let index: Int; let rule: NativeApplicationRule }
    private let playbackByExecutable: [String: [Entry]]
    private let loads: [Entry]
    init(rules: [NativeApplicationRule]) throws {
        try NativeApplicationRulesStore.validate(rules)
        var playback: [String: [Entry]] = [:], loads: [Entry] = []
        for (index, rule) in rules.enumerated() {
            let entry = Entry(index: index, rule: rule)
            if rule.action.requiresSelection { loads.append(entry) }
            else { playback[rule.executableKey, default: []].append(entry) }
        }
        playbackByExecutable = playback; self.loads = loads
    }
    func evaluate(_ input: NativeApplicationRuleInput) -> NativeApplicationRuleEffects {
        let running = Set(input.runningExecutables.map { $0.lowercased() })
        var result = NativeApplicationRuleEffects()
        var eventsByExecutable: [String: [NativeApplicationConditionEvent]] = [:]
        func apply(_ action: NativeApplicationAction, display: UInt32?) {
            switch action {
            case .mute: result.muted = true
            case .pause:
                if let display { result.pausedDisplays.insert(display) }
                else { result.pauseAll = true }
            case .pauseall: result.pauseAll = true
            case .stop: result.stopAll = true
            case .run, .loadwallpaper, .loadplaylist, .loadprofile: break
            }
        }
        for event in input.events where event.condition != .running {
            let key = event.executable.lowercased()
            eventsByExecutable[key, default: []].append(event)
            let matching = (playbackByExecutable[key] ?? []).filter { $0.rule.condition == event.condition }
            let suppressAutomatic = event.condition == .playingaudio
                ? matching.contains { $0.rule.action == .run } : !matching.isEmpty
            if !suppressAutomatic { result.automaticEvents.append(event) }
            for entry in matching { apply(entry.rule.action, display: event.display) }
        }
        for key in running {
            for entry in playbackByExecutable[key] ?? [] where entry.rule.condition == .running {
                apply(entry.rule.action, display: nil)
            }
        }
        // The official editor inserts new rules at the front; the native
        // selector scans its separate load vector from the back. Playback
        // effects above intentionally do not share this precedence rule.
        for (loadIndex, entry) in loads.enumerated().reversed() {
            let rule = entry.rule
            let matches = rule.condition == .running ? running.contains(rule.executableKey)
                : (eventsByExecutable[rule.executableKey] ?? []).contains { $0.condition == rule.condition }
            if matches, let file = rule.file {
                result.selection = .init(ruleIndex: entry.index, loadIndex: loadIndex, action: rule.action, file: file)
                break
            }
        }
        return result
    }
}

/// Detached editor state mirrors the official create/edit/selection flow. The
/// hosting settings dialog owns persistence and its outer Cancel transaction.
struct NativeApplicationRuleEditor {
    enum Page: String { case list = "", create, edit, wallpaper }
    struct Draft: Equatable {
        var executable: String?
        var condition: NativeApplicationCondition = .running
        var action: NativeApplicationAction = .pause
        var file: String?
        var rule: NativeApplicationRule { .init(executable: executable ?? "", condition: condition, action: action, file: file) }
    }
    struct Item: Equatable, Sendable {
        let label: String
        let file: String
        /// For wallpaper selection, the official controller only restores a
        /// prior selection from the cache, not from its appended local files.
        var canRestoreSelection = true
    }
    private(set) var rules: [NativeApplicationRule]
    private(set) var page: Page = .list
    var draft = Draft()
    private(set) var search: String?
    private(set) var selection: Item?
    private(set) var items: [Item] = []
    private var editIndex: Int?
    private var original: NativeApplicationRule?
    private var lastPage: Page = .create

    init(rules: [NativeApplicationRule]) throws { try NativeApplicationRulesStore.validate(rules); self.rules = rules }
    mutating func create() { page = .create; draft = .init(); editIndex = nil; original = nil }
    mutating func edit(at index: Int) throws {
        guard rules.indices.contains(index) else { throw NativeApplicationRuleError.staleEdit }
        let rule = rules[index]
        draft = .init(executable: rule.executable, condition: rule.condition, action: rule.action, file: rule.file)
        editIndex = index; original = rule; page = .edit
    }
    mutating func changeCondition(_ condition: NativeApplicationCondition) {
        // The current stable controller retains an existing string action even
        // if the new condition's dropdown does not contain it.
        draft.condition = condition
    }
    mutating func cancelEdit() { page = .list }
    mutating func choose(from choices: [Item]) {
        guard page == .create || page == .edit, draft.action.requiresSelection else { return }
        lastPage = page; page = .wallpaper; search = nil
        replaceChoices(choices)
    }
    mutating func replaceChoices(_ choices: [Item]) {
        guard page == .wallpaper else { return }
        items = choices
        selection = choices.first { $0.canRestoreSelection && $0.file == draft.file }
        if selection == nil { draft.file = nil }
    }
    mutating func select(at index: Int) {
        guard page == .wallpaper, items.indices.contains(index) else { return }
        let item = items[index]; search = item.label; draft.file = item.file; selection = item
    }
    mutating func clearSelection() { search = ""; draft.file = nil; selection = nil }
    mutating func setSearch(_ value: String) { if page == .wallpaper { search = value } }
    mutating func cancelSelection() { page = lastPage; draft.file = nil; selection = nil }
    mutating func commit() throws {
        guard page != .list else { throw NativeApplicationRuleError.staleEdit }
        let rule = try draft.rule.validated()
        if let editIndex {
            guard rules.indices.contains(editIndex), rules[editIndex] == original else { throw NativeApplicationRuleError.staleEdit }
            rules[editIndex] = rule
        } else {
            guard rules.count < NativeApplicationRulesStore.maximumRules else { throw NativeApplicationRuleError.tooManyRules }
            rules.insert(rule, at: 0)
        }
        page = .list
    }
    mutating func remove(at index: Int) throws {
        guard page == .list, rules.indices.contains(index) else { throw NativeApplicationRuleError.staleEdit }
        rules.remove(at: index)
    }
}
