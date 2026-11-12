import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum PropertyError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct WallpaperProperty: @unchecked Sendable {
    let key: String
    let definition: [String: Any]
    var type: String { (definition["type"] as? String ?? "unknown").lowercased() }
    var isMedia: Bool { type == "file" || type == "directory" }
    var mediaFileType: String { (definition["fileType"] as? String ?? "image").lowercased() }
    var directoryMode: String { (definition["mode"] as? String ?? "ondemand").lowercased() }
    var displayCondition: String? {
        guard let value = definition["condition"] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    var defaultValue: Any? {
        // Author paths are data, never local-file authorization.
        if isMedia { return "" }
        if type == "textinput" { return definition["value"] ?? "" }
        if type == "color", let text = definition["value"] as? String, text.hasPrefix("#"), text.count == 7,
           let value = UInt32(text.dropFirst(), radix: 16) {
            return [Double((value >> 16) & 255), Double((value >> 8) & 255), Double(value & 255)].map { String($0 / 255) }.joined(separator: " ")
        }
        return definition["value"]
    }
    var label: String {
        let text = String((definition["text"] as? String ?? key).prefix(4096))
        if text == "ui_browse_properties_scheme_color" { return "主题配色" }
        // Strip formatting as text, without loading HTML or its external resources.
        let plain = text.replacingOccurrences(of: "<br\\s*/?>", with: " · ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return String(plain.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "·"))).prefix(512))
    }
    var options: [[String: Any]] { definition["options"] as? [[String: Any]] ?? [] }
    var order: Double { (definition["order"] as? NSNumber)?.doubleValue ?? 0 }
    var editable: Bool {
        if isMedia { return ["image", "video"].contains(mediaFileType) && (type != "directory" || ["ondemand", "fetchall"].contains(directoryMode)) }
        guard let value = defaultValue, ["color", "slider", "bool", "combo", "textinput"].contains(type) else { return false }
        return (try? normalized(value)) != nil
    }

    static func catalog(_ definitions: [String: Any]) -> [WallpaperProperty] {
        definitions.compactMap { key, value in
            guard let definition = value as? [String: Any] else { return nil }
            return WallpaperProperty(key: key, definition: definition)
        }.sorted { $0.order == $1.order ? $0.key < $1.key : $0.order < $1.order }
    }

    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs, let rhs,
              let a = try? JSONSerialization.data(withJSONObject: ["v": lhs], options: [.sortedKeys]),
              let b = try? JSONSerialization.data(withJSONObject: ["v": rhs], options: [.sortedKeys]) else { return lhs == nil && rhs == nil }
        return a == b
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    var sliderRange: (min: Double, max: Double, step: Double)? {
        guard let minimum = Self.number(definition["min"]), let maximum = Self.number(definition["max"]),
              minimum < maximum, abs(minimum) <= 1e12, abs(maximum) <= 1e12 else { return nil }
        let precision = max(1, min(9, (definition["precision"] as? NSNumber)?.intValue ?? 2))
        let fallback = definition["fraction"] as? Bool == true ? pow(10, Double(1 - precision)) : 1
        let step = Self.number(definition["step"]) ?? fallback
        guard step > 0, step.isFinite else { return nil }
        return (minimum, maximum, step)
    }

    func normalized(_ value: Any) throws -> Any {
        switch type {
        case "bool":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw invalid("需要开关值") }
            return number.boolValue
        case "slider":
            guard let number = Self.number(value), let range = sliderRange,
                  number >= range.min, number <= range.max else { throw invalid("数值必须位于滑块范围内") }
            // Author defaults and saved values may lie between UI steps.
            // Validation must not change their meaning on load or save.
            return number
        case "color":
            guard let text = value as? String, text.utf8.count <= 256 else { throw invalid("需要 RGB 颜色") }
            let parts = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
            guard parts.count == 3, text.split(whereSeparator: { $0.isWhitespace }).count == 3,
                  parts.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw invalid("RGB 分量必须在 0 到 1 之间") }
            return text
        case "combo":
            guard options.count <= 512, options.contains(where: { Self.equal($0["value"], value) }) else { throw invalid("选项已改变或无效") }
            guard value is String || Self.number(value) != nil || (value as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) == true else { throw invalid("选项值必须是文本、数值或开关") }
            return value
        case "textinput":
            guard let text = value as? String, text.utf8.count <= 65536 else { throw invalid("文本不能超过 64 KiB") }
            return text
        case "file", "directory":
            guard editable, let token = value as? String, token.isEmpty || WallpaperMediaGrants.isToken(token) else { throw invalid("素材必须通过选择框授权") }
            return token
        default: throw invalid("该属性类型尚未支持编辑")
        }
    }

    func snappedSlider(_ value: Double) throws -> Double {
        guard type == "slider", let range = sliderRange,
              let number = Self.number(try normalized(value)) else { throw invalid("无效的滑块数值") }
        guard let origin = Decimal(string: String(range.min)),
              var increment = Decimal(string: String(range.step)),
              let input = Decimal(string: String(number)) else { throw invalid("无效的数值范围") }
        // Compute the step index in decimal too: 0.15 / 0.1 in binary can
        // fall just below the midpoint and round down instead of up.
        var distance = input - origin, quotient = Decimal(), count = Decimal()
        let result = NSDecimalDivide(&quotient, &distance, &increment, .plain)
        guard result == .noError || result == .lossOfPrecision else { throw invalid("无效的数值范围") }
        NSDecimalRound(&count, &quotient, 0, .plain)
        // NSDecimalNumber.doubleValue can produce a neighboring Double (for
        // example 0.45999999999999996 for 0.46). Parse its canonical decimal
        // text so saving uses the same value as JSON and direct text input.
        guard let snapped = Double(NSDecimalNumber(decimal: origin + count * increment).stringValue),
              snapped.isFinite else { throw invalid("无效的数值范围") }
        return min(range.max, max(range.min, snapped))
    }

    func sliderInput(_ text: String, preserving value: Any?) throws -> Double {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The field is a short display of a Double. Returning that display as
        // data would silently lose precision even when the field was untouched.
        if let number = Self.number(value), text == Self.formatNumber(number),
           let preserved = Self.number(try normalized(number)) { return preserved }
        guard let number = Double(text) else { throw invalid("请输入数值") }
        return try snappedSlider(number)
    }

    static func formatNumber(_ value: Double) -> String {
        String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    func payload(_ value: Any) -> [String: Any] {
        var result: [String: Any] = ["value": value]
        if type == "combo", let option = options.first(where: { Self.equal($0["value"], value) }), let label = option["label"] as? String { result["text"] = label }
        return result
    }

    private func invalid(_ message: String) -> PropertyError { .invalid("\(label)：\(message)。") }
}

/// A recoverable condition attached to one effective property value.  These
/// are intentionally runtime state rather than a new field in the author's
/// JSON or the local setting record: a local-media token is already opaque,
/// and an unreadable token must never be treated as a transferable grant.
enum WallpaperPropertyLoadIssue: Equatable, Sendable {
    case unavailableMediaAuthorization(propertyKey: String)
    /// The token has been proved to belong to an older immutable saved copy of
    /// this same Workshop item. It is still unavailable to the current copy;
    /// the distinction only improves the user's recovery guidance.
    case priorSavedVersionMediaAuthorization(propertyKey: String)

    var propertyKey: String {
        switch self {
        case .unavailableMediaAuthorization(let propertyKey),
             .priorSavedVersionMediaAuthorization(let propertyKey):
            return propertyKey
        }
    }

    /// The full visible explanation. This deliberately describes a saved-copy
    /// boundary, not a source-file update: a Steam manifest can change even
    /// when the source bytes did not.
    var presentation: String {
        switch self {
        case .unavailableMediaAuthorization:
            return "本机素材授权不可用，请重新选择。"
        case .priorSavedVersionMediaAuthorization:
            return "当前保存版本未持有此授权；该授权仅存在于同一壁纸的已验证历史版本。请重新选择素材以授权当前版本。旧授权不会自动迁移或删除。"
        }
    }

    var fieldPresentation: String {
        switch self {
        case .unavailableMediaAuthorization:
            return "本机素材授权不可用，请重新选择"
        case .priorSavedVersionMediaAuthorization:
            return "旧保存版本授权不可用，请重新选择"
        }
    }

    var diagnostic: String {
        switch self {
        case .unavailableMediaAuthorization(let propertyKey):
            return "本机素材授权不可用（\(propertyKey)），请重新选择。"
        case .priorSavedVersionMediaAuthorization(let propertyKey):
            return "本机素材授权仅存在于历史保存版本（\(propertyKey)），请重新选择。"
        }
    }

    static func mediaAuthorizationDiagnostics(propertyKey: String) -> Set<String> {
        [WallpaperPropertyLoadIssue.unavailableMediaAuthorization(propertyKey: propertyKey).diagnostic,
         WallpaperPropertyLoadIssue.priorSavedVersionMediaAuthorization(propertyKey: propertyKey).diagnostic]
    }
}

/// Store only local overrides. Steam-owned project.json and scene.pkg are read-only.
enum WallpaperPropertyStore {
    /// Project metadata can expose up to 256 fields.  Historical provenance is
    /// optional explanatory work, never authorization, so cap it across one
    /// synchronous load instead of multiplying a bounded lineage scan by every
    /// invalid media field.
    private static let maximumHistoricalAuthorizationLookupsPerLoad = 8
    struct Revision: Equatable, Sendable {
        /// The record selected for this target (V1 default, V2 UUID, or an
        /// in-memory session record).
        let primary: UInt64
        /// A target with no own record inherits V1 until it is edited. Keep
        /// that dependency explicit so a concurrent default edit cannot publish
        /// an older prepared renderer for an inheriting display.
        let legacyFallback: UInt64?
        /// Revisions are capabilities for one specific property scope, not
        /// merely counters. Fresh A/B scopes otherwise both begin at zero and
        /// could accidentally validate each other.
        fileprivate let scopeIdentity: String?
        fileprivate let legacyFallbackIdentity: String?

        static let unresolved = Revision(primary: 0, legacyFallback: nil, scopeIdentity: nil, legacyFallbackIdentity: nil)

        fileprivate init(primary: UInt64, legacyFallback: UInt64?, scopeIdentity: String?, legacyFallbackIdentity: String?) {
            self.primary = primary
            self.legacyFallback = legacyFallback
            self.scopeIdentity = scopeIdentity
            self.legacyFallbackIdentity = legacyFallbackIdentity
        }

        fileprivate init(primary: UInt64, legacyFallback: UInt64?, scope: NativePropertyScope, fallbackScope: NativePropertyScope? = nil) {
            self.init(primary: primary, legacyFallback: legacyFallback, scopeIdentity: scope.revisionIdentity,
                      legacyFallbackIdentity: fallbackScope?.revisionIdentity)
        }
    }

    struct Snapshot: Sendable {
        /// For a UUID record, absence means it may inherit the old V1 record;
        /// a malformed or wrongly-addressed V2 record deliberately does not.
        /// Treating those two states as the same would let an ordinary Apply
        /// erase an intact user's (but currently unreadable) per-display data.
        enum PrimaryStatus: Equatable, Sendable { case missing, valid, invalid(String) }
        let project: URL
        let identity: String
        let scope: NativePropertyScope
        /// The scoped V2/session bytes, or the original V1 bytes for default.
        /// This is the only payload restored by `restore`; fallback bytes are
        /// read-only input to effective value resolution.
        let data: Data?
        let fallbackData: Data?
        let revision: Revision
        let primaryStatus: PrimaryStatus

        init(project: URL) throws {
            try self.init(project: project, scope: NativePropertyScope(project: project))
        }

        init(project: URL, scope: NativePropertyScope) throws {
            guard scope.projectIdentity == SavedWorkshopStore.settingsIdentity(project) else {
                throw PropertyError.invalid("壁纸设置快照不匹配。")
            }
            self.project = project
            self.scope = scope
            identity = scope.projectIdentity
            let primary = revisions.snapshot(scope.revisionIdentity)
            data = try readStored(project: project, scope: scope)
            if let data, scope.storage == .persistentDisplay {
                do { try validateV2Envelope(data, project: project, scope: scope); primaryStatus = .valid }
                catch { primaryStatus = .invalid(error.localizedDescription) }
            } else {
                primaryStatus = data == nil ? .missing : .valid
            }
            if data == nil, !scope.usesLegacyRecord {
                let legacy = try NativePropertyScope(project: project)
                let fallback = revisions.snapshot(legacy.revisionIdentity)
                fallbackData = try readStored(project: project, scope: legacy)
                revision = .init(primary: primary, legacyFallback: fallback, scope: scope, fallbackScope: legacy)
            } else {
                fallbackData = nil
                revision = .init(primary: primary, legacyFallback: nil, scope: scope)
            }
        }
    }

    /// Prepare renderers with snapshots first. Restore the owned settings files
    /// only at the final presentation boundary, undoing partial writes on error.
    static func restore(_ snapshots: [Snapshot]) throws {
        try WallpaperMediaGrants.withTransaction {
            try validateRestoreSnapshots(snapshots)
            let ordered = snapshots.sorted { $0.scope.identity < $1.scope.identity }
            let previous = try ordered.map { try Snapshot(project: $0.project, scope: $0.scope) }
            var written = 0
            do {
                for snapshot in ordered { try writeStoredWithinTransaction(snapshot.data, project: snapshot.project, scope: snapshot.scope); written += 1 }
            } catch {
                let failure = error
                var recovery: Error?
                for snapshot in previous.prefix(written).reversed() {
                    do { try writeStoredWithinTransaction(snapshot.data, project: snapshot.project, scope: snapshot.scope) } catch { recovery = error }
                }
                if let recovery { throw PropertyError.invalid("恢复设置未完成：\(failure.localizedDescription)；回退写入失败：\(recovery.localizedDescription)") }
                throw failure
            }
        }
    }

    /// Reject ambiguous batches before even reading their current data.  In
    /// particular, two different snapshots for one scope would otherwise have
    /// an order-dependent final value and an order-dependent rollback path.
    private static func validateRestoreSnapshots(_ snapshots: [Snapshot]) throws {
        var identities = Set<String>()
        for snapshot in snapshots {
            let projectIdentity = SavedWorkshopStore.settingsIdentity(snapshot.project)
            guard snapshot.identity == projectIdentity, snapshot.scope.projectIdentity == projectIdentity else {
                throw PropertyError.invalid("壁纸设置快照不匹配。")
            }
            let target: NativeDisplayTarget = snapshot.scope.usesLegacyRecord ? .defaultWallpaper : .display(snapshot.scope.targetKey)
            let rebuilt = try NativePropertyScope(project: snapshot.project, target: target)
            guard rebuilt == snapshot.scope, identities.insert(rebuilt.identity).inserted else {
                throw PropertyError.invalid("恢复设置包含重复或无效的显示器目标。")
            }
        }
    }

    /// A V2 envelope is the persistent ownership proof for a UUID target.
    /// Validate it independently of the current author definitions: obsolete
    /// individual values are still allowed to be ignored/replaced, but a record
    /// that is structurally corrupt or belongs to another display is never
    /// silently replaced.
    private static func validateV2Envelope(_ data: Data, project: URL, scope: NativePropertyScope) throws {
        guard scope.storage == .persistentDisplay,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["version"] as? Int == 2,
              root["project"] as? String == SavedWorkshopStore.settingsIdentity(project),
              root["target"] as? String == scope.targetKey,
              root["values"] as? [String: Any] != nil else {
            throw PropertyError.invalid("显示器壁纸设置格式无效，原记录已保留。")
        }
    }

    private static func readFile(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try WebSourceFD.openAbsolute(file, directory: false).readSmall(maximum: 4 * 1024 * 1024)
    }

    private static let sessionLock = NSLock()
    private static var sessionData: [String: Data] = [:]

    private static func readStored(project: URL, scope: NativePropertyScope) throws -> Data? {
        switch scope.storage {
        case .legacyDefault, .persistentDisplay:
            return try readFile(url(for: project, scope: scope))
        case .sessionDisplay:
            sessionLock.lock(); defer { sessionLock.unlock() }
            return sessionData[scope.identity]
        }
    }

    /// Existence intentionally does not deserialize the record. If it cannot
    /// be read safely (for example it exceeds the bounded JSON size), callers
    /// must treat it as an owned scoped record rather than falsely falling back
    /// to V1 and later overwriting it.
    private static func storedRecordExists(project: URL, scope: NativePropertyScope) -> Bool {
        switch scope.storage {
        case .sessionDisplay:
            sessionLock.lock(); defer { sessionLock.unlock() }
            return sessionData[scope.identity] != nil
        case .legacyDefault, .persistentDisplay:
            guard let file = try? url(for: project, scope: scope) else { return true }
            return FileManager.default.fileExists(atPath: file.path)
        }
    }

    private static func writeStored(_ data: Data?, project: URL, scope: NativePropertyScope) throws {
        try WallpaperMediaGrants.withTransaction {
            try writeStoredWithinTransaction(data, project: project, scope: scope)
        }
    }
    /// Caller owns WallpaperMediaGrants' transaction lock. Keeping the actual
    /// write separate permits `restore` to cover its entire multi-scope
    /// prepare/write/rollback sequence without a reentrant NSLock.
    private static func writeStoredWithinTransaction(_ data: Data?, project: URL, scope: NativePropertyScope) throws {
        revisions.beginWrite(scope.revisionIdentity)
        defer { revisions.endWrite(scope.revisionIdentity) }
        switch scope.storage {
        case .sessionDisplay:
            sessionLock.lock(); defer { sessionLock.unlock() }
            if let data { sessionData[scope.identity] = data }
            else { sessionData.removeValue(forKey: scope.identity) }
        case .legacyDefault, .persistentDisplay:
            let file = try url(for: project, scope: scope)
            if let data {
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } else if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }
    // A read can overlap an atomic write on the I/O queue. Capture a revision
    // before reading and reject that prepared snapshot if a write has begun or
    // completed since then. The lock never covers filesystem operations.
    private final class RevisionClock: @unchecked Sendable {
        private struct State { var revision: UInt64 = 0; var writers = 0 }
        private let lock = NSLock()
        private var states: [String: State] = [:]
        func snapshot(_ identity: String) -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return states[identity]?.revision ?? 0
        }
        func isCurrent(_ revision: UInt64, identity: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let state = states[identity] ?? State()
            return state.writers == 0 && state.revision == revision
        }
        func beginWrite(_ identity: String) {
            lock.lock(); defer { lock.unlock() }
            var state = states[identity] ?? State()
            state.revision &+= 1; state.writers += 1; states[identity] = state
        }
        func endWrite(_ identity: String) {
            lock.lock(); defer { lock.unlock() }
            var state = states[identity] ?? State()
            state.revision &+= 1; state.writers -= 1; states[identity] = state
        }
    }
    private static let revisions = RevisionClock()
    /// Compatibility API for the original project-wide V1 record.
    static func revision(for project: URL) -> UInt64 {
        revisions.snapshot(SavedWorkshopStore.settingsIdentity(project))
    }

    static func isCurrent(_ revision: UInt64, for project: URL) -> Bool {
        revisions.isCurrent(revision, identity: SavedWorkshopStore.settingsIdentity(project))
    }

    static func revision(for project: URL, scope: NativePropertyScope) -> Revision {
        guard scope.projectIdentity == SavedWorkshopStore.settingsIdentity(project) else {
            return .unresolved
        }
        let primary = revisions.snapshot(scope.revisionIdentity)
        guard !scope.usesLegacyRecord else { return .init(primary: primary, legacyFallback: nil, scope: scope) }
        let hasScopedRecord = storedRecordExists(project: project, scope: scope)
        let legacy = try? NativePropertyScope(project: project)
        return .init(primary: primary, legacyFallback: hasScopedRecord ? nil : revisions.snapshot(scope.projectIdentity),
                     scope: scope, fallbackScope: hasScopedRecord ? nil : legacy)
    }

    static func isCurrent(_ revision: Revision, for scope: NativePropertyScope) -> Bool {
        guard revision.scopeIdentity == scope.revisionIdentity else { return false }
        guard revisions.isCurrent(revision.primary, identity: scope.revisionIdentity) else { return false }
        guard let fallback = revision.legacyFallback else { return true }
        guard revision.legacyFallbackIdentity == scope.projectIdentity else { return false }
        return revisions.isCurrent(fallback, identity: scope.projectIdentity)
    }

    static func url(for project: URL) throws -> URL {
        try url(for: project, scope: NativePropertyScope(project: project))
    }
    static func url(for project: URL, scope: NativePropertyScope) throws -> URL {
        guard scope.projectIdentity == SavedWorkshopStore.settingsIdentity(project) else { throw PropertyError.invalid("壁纸设置目标与项目不匹配。") }
        guard scope.storage != .sessionDisplay else { throw PropertyError.invalid("临时显示器设置不会写入磁盘。") }
        let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let identity = scope.usesLegacyRecord ? scope.projectIdentity : scope.identity
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return parent.appendingPathComponent("WallpaperEngineNative/Properties", isDirectory: true).appendingPathComponent(digest + ".json")
    }

    static func load(project: URL, definitions: [WallpaperProperty], mediaEnabled: Bool = false, snapshot: Snapshot? = nil) -> (payload: [String: Any], diagnostics: [String], issues: [WallpaperPropertyLoadIssue], revision: UInt64) {
        let scope = try! NativePropertyScope(project: project)
        let values = load(project: project, scope: scope, definitions: definitions, mediaEnabled: mediaEnabled, snapshot: snapshot)
        return (values.payload, values.diagnostics, values.issues, values.revision.primary)
    }

    static func load(project: URL, scope: NativePropertyScope, definitions: [WallpaperProperty], mediaEnabled: Bool = false, snapshot: Snapshot? = nil) -> (payload: [String: Any], diagnostics: [String], issues: [WallpaperPropertyLoadIssue], revision: Revision) {
        let saved: Snapshot
        do { saved = try snapshot ?? Snapshot(project: project, scope: scope) }
        catch { return (defaultPayload(definitions), ["使用作者默认设置：\(error.localizedDescription)"], [], revision(for: project, scope: scope)) }
        let values = loadValues(project: project, scope: scope, definitions: definitions, mediaEnabled: mediaEnabled, snapshot: saved)
        return (values.payload, values.diagnostics, values.issues, saved.revision)
    }
    private static func defaultPayload(_ definitions: [WallpaperProperty]) -> [String: Any] {
        var payload: [String: Any] = [:]
        for property in definitions { if let value = property.defaultValue { payload[property.key] = property.payload(value) } }
        return payload
    }
    private static func loadValues(project: URL, scope: NativePropertyScope, definitions: [WallpaperProperty], mediaEnabled: Bool, snapshot: Snapshot) -> (payload: [String: Any], diagnostics: [String], issues: [WallpaperPropertyLoadIssue]) {
        var payload = defaultPayload(definitions), diagnostics: [String] = [], issues: [WallpaperPropertyLoadIssue] = []
        var remainingHistoricalAuthorizationLookups = maximumHistoricalAuthorizationLookupsPerLoad
        do {
            guard snapshot.scope == scope, snapshot.identity == SavedWorkshopStore.settingsIdentity(project) else { throw PropertyError.invalid("壁纸设置快照不匹配。") }
            if case .invalid(let diagnostic) = snapshot.primaryStatus {
                throw PropertyError.invalid(diagnostic)
            }
            let data: Data
            let inherited: Bool
            if let scoped = snapshot.data { data = scoped; inherited = false }
            else if let fallback = snapshot.fallbackData { data = fallback; inherited = true }
            else { return (payload, diagnostics, issues) }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  root["project"] as? String == SavedWorkshopStore.settingsIdentity(project),
                  let values = root["values"] as? [String: Any] else { throw PropertyError.invalid("本地壁纸设置格式无效。") }
            if inherited || scope.usesLegacyRecord {
                guard root["version"] as? Int == 1 else { throw PropertyError.invalid("本地壁纸设置格式无效。") }
            } else {
                guard root["version"] as? Int == 2, root["target"] as? String == scope.targetKey else { throw PropertyError.invalid("显示器壁纸设置格式无效。") }
            }
            for property in definitions {
                guard let value = values[property.key] else { continue }
                do {
                    let normalized = try property.normalized(value)
                    if property.isMedia, let token = normalized as? String, !token.isEmpty {
                        guard mediaEnabled else { throw PropertyError.invalid("该项目类型尚不支持素材属性。") }
                        do {
                            _ = try WallpaperMediaGrants.read(token, project: project, property: property)
                        } catch {
                            // Keep the opaque token as a local-setting value so
                            // a later edit to an unrelated property cannot
                            // silently erase the user's explicit media choice.
                            // WebMediaWorkspace still fails closed below this
                            // layer and exposes no file to the wallpaper until
                            // the user makes a fresh selection.
                            payload[property.key] = property.payload(normalized)
                            let issue: WallpaperPropertyLoadIssue
                            let shouldInspectHistoricalProvenance = remainingHistoricalAuthorizationLookups > 0
                            if shouldInspectHistoricalProvenance { remainingHistoricalAuthorizationLookups -= 1 }
                            if shouldInspectHistoricalProvenance,
                               WallpaperMediaGrants.historicalAuthorizationProvenance(token: token, anchorProject: project, property: property) == .priorSavedVersion {
                                issue = .priorSavedVersionMediaAuthorization(propertyKey: property.key)
                            } else {
                                issue = .unavailableMediaAuthorization(propertyKey: property.key)
                            }
                            issues.append(issue)
                            diagnostics.append(issue.diagnostic)
                            continue
                        }
                    }
                    payload[property.key] = property.payload(normalized)
                }
                catch { diagnostics.append("已忽略不再适用的设置 \(property.key)：\(error.localizedDescription)") }
            }
        } catch { diagnostics.append("使用作者默认设置：\(error.localizedDescription)") }
        return (payload, diagnostics, issues)
    }

    static func save(project: URL, definitions: [WallpaperProperty], payload: [String: Any]) throws {
        try save(project: project, scope: NativePropertyScope(project: project), definitions: definitions, payload: payload)
    }

    static func save(project: URL, scope: NativePropertyScope, definitions: [WallpaperProperty], payload: [String: Any]) throws {
        guard scope.projectIdentity == SavedWorkshopStore.settingsIdentity(project) else { throw PropertyError.invalid("壁纸设置目标与项目不匹配。") }
        var overrides: [String: Any] = [:]
        for property in definitions where property.editable {
            guard let value = (payload[property.key] as? [String: Any])?["value"] else { continue }
            let validated = try property.normalized(value)
            if !WallpaperProperty.equal(validated, property.defaultValue) { overrides[property.key] = validated }
        }
        var root: [String: Any] = ["version": scope.usesLegacyRecord ? 1 : 2,
                                   "project": SavedWorkshopStore.settingsIdentity(project), "values": overrides]
        if !scope.usesLegacyRecord { root["target"] = scope.targetKey }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 4 * 1024 * 1024 else { throw PropertyError.invalid("本地壁纸设置超过 4 MiB。") }
        try WallpaperMediaGrants.withTransaction {
            // Do this before changing any persisted bytes. V1 retains its
            // original compatibility behavior; only a separately-addressed
            // UUID V2 record has enough ownership information to require this
            // safety check.
            if scope.storage == .persistentDisplay, let existing = try readStored(project: project, scope: scope) {
                try validateV2Envelope(existing, project: project, scope: scope)
            }
            try writeStoredWithinTransaction(data, project: project, scope: scope)
        }
    }

    /// An explicit user-confirmed repair hook. Normal Apply paths must never
    /// call this: it removes only a malformed UUID-target record, leaving the
    /// legacy/default record and every other target untouched. The next Apply
    /// can then create a fresh V2 record from the visible author/default state.
    static func resetInvalidPersistentScope(project: URL, scope: NativePropertyScope) throws {
        guard scope.storage == .persistentDisplay else { throw PropertyError.invalid("只有持久显示器可以重置独立设置。") }
        try WallpaperMediaGrants.withTransaction {
            let file = try url(for: project, scope: scope)
            guard FileManager.default.fileExists(atPath: file.path) else { return }
            let resources = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard resources.isRegularFile == true, let byteCount = resources.fileSize, byteCount >= 0 else {
                throw PropertyError.invalid("显示器壁纸设置无法安全重置。")
            }
            // `readFile` deliberately rejects this size. It is nevertheless a
            // known malformed V2 candidate that an explicit reset may remove;
            // do not apply the same deletion policy to permission or descriptor
            // I/O errors below.
            if byteCount > 4 * 1024 * 1024 {
                try writeStoredWithinTransaction(nil, project: project, scope: scope)
                _ = pruneUnreferencedMediaGrantsWithinTransaction(project: project)
                return
            }
            guard let existing = try readStored(project: project, scope: scope) else { return }
            do { try validateV2Envelope(existing, project: project, scope: scope) }
            catch {
                try writeStoredWithinTransaction(nil, project: project, scope: scope)
                _ = pruneUnreferencedMediaGrantsWithinTransaction(project: project)
                return
            }
            throw PropertyError.invalid("显示器壁纸设置仍有效，无需重置。")
        }
    }

    /// Session display values are intentionally process-local.  The caller can
    /// clear the override when a descriptor disappears without touching any
    /// durable UUID/default property record.
    static func clearSession(project: URL, target: NativeDisplayTarget) throws {
        let scope = try NativePropertyScope(project: project, target: target)
        guard scope.storage == .sessionDisplay else { throw PropertyError.invalid("只有临时显示器可以清除内存设置。") }
        try writeStored(nil, project: project, scope: scope)
    }

    /// A volatile display key is not a durable monitor identity.  Clear every
    /// process-local project record for a key as soon as its connection is
    /// observed missing; otherwise an old project's session override could be
    /// revived when macOS later assigns the same numeric key to another screen.
    ///
    /// Scope identities retain only the shared settings identity, not the
    /// concrete saved-project version that owns a media grant.  This operation
    /// therefore deliberately retains grants.  A caller that still knows a
    /// concrete project URL may separately use the normal complete-inventory
    /// prune path; guessing an old version here could revoke valid authority.
    @discardableResult
    static func discardDisconnectedSessionTargets(_ targets: Set<String>) -> Set<String> {
        let disconnected = Set(targets.filter {
            $0.hasPrefix("session:") && NativeDisplayLayout.validKey($0)
        })
        guard !disconnected.isEmpty else { return [] }
        return WallpaperMediaGrants.withTransaction {
            // Do not hold sessionLock while entering RevisionClock: readers
            // snapshot revisions before reading sessionData, so that inverse
            // lock order would deadlock a concurrent load.
            sessionLock.lock()
            let identities = sessionData.keys.filter { identity in
                guard let separator = identity.firstIndex(of: "\u{0}") else { return false }
                let target = String(identity[identity.index(after: separator)...])
                return disconnected.contains(target)
            }
            sessionLock.unlock()
            guard !identities.isEmpty else { return [] }

            identities.forEach { revisions.beginWrite($0) }
            sessionLock.lock()
            for identity in identities { sessionData.removeValue(forKey: identity) }
            sessionLock.unlock()
            identities.reversed().forEach { revisions.endWrite($0) }
            return Set(identities.compactMap { identity -> String? in
                guard let separator = identity.firstIndex(of: "\u{0}") else { return nil }
                let target = String(identity[identity.index(after: separator)...])
                return disconnected.contains(target) ? target : nil
            })
        }
    }

    /// The complete set of media-grant tokens named by this project across the
    /// legacy V1 record, every durable UUID record (including disconnected
    /// displays), and live process-only session records. `nil` is deliberate:
    /// an unreadable/unknown record could still refer to a token, so callers
    /// must skip cleanup rather than risk revoking its authorization.
    static func referencedMediaTokens(project: URL) -> Set<String>? {
        let projectIdentity = SavedWorkshopStore.settingsIdentity(project)
        let directory: URL
        do { directory = try url(for: project).deletingLastPathComponent() }
        catch { return nil }
        var tokens = Set<String>()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return sessionMediaTokens(projectIdentity: projectIdentity, into: &tokens) ? tokens : nil
        }
        guard isDirectory.boolValue,
              let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: []),
              children.count <= 4096 else { return nil }
        for child in children {
            guard child.pathExtension == "json",
                  let isRegular = try? child.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isRegular == true else { return nil }
            do {
                let record = try mediaTokens(in: readFile(child))
                guard record.version == 1 || record.target?.hasPrefix("uuid:") == true else { return nil }
                if record.project == projectIdentity { tokens.formUnion(record.tokens) }
            } catch { return nil }
        }
        return sessionMediaTokens(projectIdentity: projectIdentity, into: &tokens) ? tokens : nil
    }

    /// Prune only when `referencedMediaTokens` has a complete inventory. The
    /// grants layer then adds Browser-session Retention pins while it deletes,
    /// so a cancel snapshot cannot lose a token between property restore and
    /// the final cleanup.
    @discardableResult
    static func pruneUnreferencedMediaGrants(project: URL) -> Bool {
        WallpaperMediaGrants.withTransaction {
            pruneUnreferencedMediaGrantsWithinTransaction(project: project)
        }
    }

    /// Caller owns WallpaperMediaGrants' transaction lock. Keeping inventory
    /// and deletion together means an explicit invalid-record reset cannot
    /// leave a grant reachable only from bytes it just removed.
    private static func pruneUnreferencedMediaGrantsWithinTransaction(project: URL) -> Bool {
        guard let tokens = referencedMediaTokens(project: project) else { return false }
        WallpaperMediaGrants.pruneWithinTransaction(project: project, keeping: tokens)
        return true
    }

    private static func sessionMediaTokens(projectIdentity: String, into tokens: inout Set<String>) -> Bool {
        sessionLock.lock()
        let records = sessionData
        sessionLock.unlock()
        let prefix = projectIdentity + "\u{0}"
        for (identity, data) in records where identity.hasPrefix(prefix) {
            let target = String(identity.dropFirst(prefix.count))
            guard target.hasPrefix("session:"), NativeDisplayLayout.validKey(target) else { return false }
            do {
                let record = try mediaTokens(in: data)
                guard record.version == 2, record.project == projectIdentity, record.target == target else { return false }
                tokens.formUnion(record.tokens)
            } catch { return false }
        }
        return true
    }

    private static func mediaTokens(in data: Data?) throws -> (version: Int, project: String, target: String?, tokens: Set<String>) {
        guard let data,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int,
              let project = root["project"] as? String,
              !project.isEmpty,
              let values = root["values"] as? [String: Any] else {
            throw PropertyError.invalid("属性记录未知或无效，未清理素材授权。")
        }
        let target = root["target"] as? String
        switch version {
        case 1:
            guard target == nil else { throw PropertyError.invalid("属性记录未知或无效，未清理素材授权。") }
        case 2:
            guard let target, NativeDisplayLayout.validKey(target) else {
                throw PropertyError.invalid("属性记录未知或无效，未清理素材授权。")
            }
        default: throw PropertyError.invalid("属性记录未知或无效，未清理素材授权。")
        }
        return (version, project, target, Set(values.values.compactMap { $0 as? String }.filter(WallpaperMediaGrants.isToken)))
    }
}

@MainActor
private final class PropertyFormStackView: NSStackView {
    // A short document should remain at the top of its clip view when
    // conditional rows disappear, rather than following its lower edge.
    override var isFlipped: Bool { true }
}

@MainActor
private final class PropertyRowStackView: NSStackView {
    var grouped = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if grouped { NSColor.controlAccentColor.setFill(); NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill() }
    }
}

@MainActor
private final class PropertyRow: NSObject, NSTextFieldDelegate {
    let property: WallpaperProperty
    let view = PropertyRowStackView()
    private let field = NSTextField()
    private var slider: NSSlider?
    private var toggle: NSButton?
    private var combo: NSPopUpButton?
    private var color: NSColorWell?
    private var groupDisclosure: NSButton?
    private var original: Any?
    private var initialColorText = ""
    private var colorChanged = false
    private var preciseColor: NSColor?
    private let projectURL: URL
    private let canEdit: Bool
    private let inline: Bool
    private var mediaPanel: NSOpenPanel?
    private var inlineTitle: NSTextField?
    private var inlineLabelMaximum: NSLayoutConstraint?
    private var inlineSliderWidth: NSLayoutConstraint?
    private var inlineFieldWidth: NSLayoutConstraint?
    private var inlinePopupWidth: NSLayoutConstraint?
    private(set) var selectedMedia: URL?
    private var mediaAuthorizationIssue: WallpaperPropertyLoadIssue?
    private var unavailableMediaAuthorization: Bool { mediaAuthorizationIssue != nil }
    private var mediaAuthorizationNote: NSTextField?
    var onChange: (() -> Void)?
    var onGroupToggle: ((Bool) -> Void)?

    init(property: WallpaperProperty, value: Any?, projectURL: URL, mediaEnabled: Bool,
         mediaAuthorizationIssue: WallpaperPropertyLoadIssue? = nil, inline: Bool = false) {
        self.property = property
        self.projectURL = projectURL
        self.inline = inline
        self.mediaAuthorizationIssue = mediaAuthorizationIssue
        canEdit = property.editable && (!property.isMedia || mediaEnabled)
        super.init()
        view.orientation = .vertical; view.alignment = .leading; view.spacing = 6
        let title = NSTextField(wrappingLabelWithString: property.label)
        title.font = .systemFont(ofSize: inline ? 14 : 13, weight: inline ? .regular : .medium)
        title.toolTip = property.key
        if inline {
            inlineTitle = title
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        }
        if property.type == "group" {
            if inline {
                view.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
                view.heightAnchor.constraint(greaterThanOrEqualToConstant: 45).isActive = true
            }
            title.stringValue = property.label.isEmpty ? String(property.key.prefix(512)) : property.label
            title.font = .systemFont(ofSize: inline ? 18.2 : 14, weight: inline ? .regular : .semibold)
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            title.setContentCompressionResistancePriority(.required, for: .vertical)
            let disclosure = NSButton(title: "", target: self, action: #selector(groupChanged(_:)))
            disclosure.bezelStyle = .disclosure; disclosure.setButtonType(.onOff)
            disclosure.identifier = NSUserInterfaceItemIdentifier("wallpaper.property.group." + property.key)
            disclosure.setAccessibilityLabel(title.stringValue)
            disclosure.setAccessibilityHelp("展开或折叠此分组中的设置，已填写的参数会保留。")
            disclosure.state = .on
            disclosure.widthAnchor.constraint(equalToConstant: 24).isActive = true
            disclosure.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let header = NSStackView(views: inline ? [title, disclosure] : [disclosure, title])
            header.orientation = .horizontal; header.alignment = .centerY; header.spacing = inline ? 20 : 8
            view.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
            title.widthAnchor.constraint(equalTo: header.widthAnchor, constant: inline ? -44 : -32).isActive = true
            groupDisclosure = disclosure
            set(value)
            return
        }
        view.addArrangedSubview(title)
        if inline {
            view.orientation = .horizontal; view.alignment = .centerY; view.spacing = 10
            inlineLabelMaximum = title.widthAnchor.constraint(lessThanOrEqualToConstant: 130)
            inlineLabelMaximum?.isActive = true
            let space = NSView(); space.setContentHuggingPriority(.defaultLow, for: .horizontal)
            space.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
            view.addArrangedSubview(space)
        } else { title.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.required, for: .vertical)
        let controls = NSStackView(); controls.orientation = .horizontal; controls.spacing = 10
        view.addArrangedSubview(controls)
        if inline { controls.setContentHuggingPriority(.required, for: .horizontal); controls.spacing = 4 }
        else { controls.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true }
        field.delegate = self; field.target = self; field.action = #selector(fieldChanged(_:))
        field.setAccessibilityLabel(property.label)
        field.lineBreakMode = .byTruncatingTail
        if property.type == "divider" {
            title.isHidden = true
            let rule = NSBox(); rule.boxType = .separator
            if inline {
                for child in view.arrangedSubviews { view.removeArrangedSubview(child); child.removeFromSuperview() }
                view.orientation = .vertical; view.addArrangedSubview(rule)
            } else { controls.addArrangedSubview(rule) }
            rule.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
        } else if property.type == "text" {
            title.font = .systemFont(ofSize: 14, weight: inline ? .regular : .semibold)
            controls.isHidden = true
        } else if !canEdit {
            let note = NSTextField(wrappingLabelWithString: "暂不支持编辑此属性（\(property.type)）。")
            note.textColor = .secondaryLabelColor; controls.addArrangedSubview(note)
            note.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
        } else {
            switch property.type {
            case "file", "directory":
                field.isEditable = false; field.isSelectable = false
                field.placeholderString = "未选择，使用壁纸默认内容"
                controls.addArrangedSubview(field)
                if inline {
                    controls.orientation = .vertical; controls.alignment = .trailing
                    inlineFieldWidth = field.widthAnchor.constraint(equalToConstant: 190); inlineFieldWidth?.isActive = true
                } else { field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true }
                let choose = NSButton(title: property.type == "directory" ? "选择文件夹…" : "选择文件…", target: self, action: #selector(chooseMedia))
                choose.setAccessibilityLabel("\(property.label) · 选择")
                let clear = NSButton(title: "清除", target: self, action: #selector(clearMedia))
                clear.setAccessibilityLabel("\(property.label) · 清除")
                if inline {
                    choose.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil); choose.imagePosition = .imageOnly
                    clear.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil); clear.imagePosition = .imageOnly
                    choose.toolTip = property.type == "directory" ? "选择文件夹" : "选择文件"; clear.toolTip = "清除"
                    let actions = NSStackView(views: [choose, clear]); actions.spacing = 4
                    controls.addArrangedSubview(actions)
                } else { controls.addArrangedSubview(choose); controls.addArrangedSubview(clear) }
                let note = NSTextField(wrappingLabelWithString: property.type == "directory" ? "此壁纸可读取所选文件夹第一层的匹配素材，并跟随文件变化更新。" : "所选素材将提供给当前壁纸的网页脚本。")
                if !inline {
                    note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor; view.addArrangedSubview(note)
                    note.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
                }
                let authorization = NSTextField(wrappingLabelWithString: "本机素材授权不可用，请重新选择。")
                authorization.font = .systemFont(ofSize: inline ? 11 : 11)
                authorization.textColor = .systemOrange
                authorization.maximumNumberOfLines = 3
                authorization.setAccessibilityLabel("\(property.label)：本机素材授权不可用，请重新选择。")
                if inline {
                    controls.addArrangedSubview(authorization)
                    authorization.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
                } else {
                    view.addArrangedSubview(authorization)
                    authorization.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true
                }
                mediaAuthorizationNote = authorization
            case "bool":
                let button = NSButton(checkboxWithTitle: inline ? "" : "启用", target: self, action: #selector(selectionChanged))
                button.setAccessibilityLabel(property.label); controls.addArrangedSubview(button); toggle = button
                if inline { title.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(toggleFromLabel))) }
            case "slider":
                let range = property.sliderRange!
                let control = NSSlider(value: range.min, minValue: range.min, maxValue: range.max, target: self, action: #selector(sliderChanged(_:)))
                control.isContinuous = true; control.setAccessibilityLabel(property.label)
                controls.addArrangedSubview(control); controls.addArrangedSubview(field)
                if inline {
                    inlineFieldWidth = field.widthAnchor.constraint(equalToConstant: 40); inlineFieldWidth?.isActive = true
                    inlineSliderWidth = control.widthAnchor.constraint(equalToConstant: 101); inlineSliderWidth?.isActive = true
                    field.alignment = .right
                } else {
                    field.widthAnchor.constraint(equalToConstant: 95).isActive = true
                    control.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
                }
                slider = control
                let note = NSTextField(labelWithString: "范围 \(Self.format(range.min)) — \(Self.format(range.max)) · 步长 \(Self.format(range.step))")
                note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
                if !inline { view.addArrangedSubview(note) }
            case "color":
                let well = NSColorWell(); well.target = self; well.action = #selector(colorChanged(_:))
                well.setAccessibilityLabel(property.label)
                well.widthAnchor.constraint(equalToConstant: inline ? 32 : 48).isActive = true
                well.heightAnchor.constraint(equalToConstant: 26).isActive = true
                controls.addArrangedSubview(well); controls.addArrangedSubview(field)
                field.placeholderString = "#RRGGBB"; field.widthAnchor.constraint(equalToConstant: inline ? 76 : 120).isActive = true
                color = well
            case "combo":
                let popup = NSPopUpButton()
                popup.target = self; popup.action = #selector(selectionChanged)
                for option in property.options {
                    let title = String((option["label"] as? String ?? String(describing: option["value"] ?? "")).prefix(512))
                    // addItem(withTitle:) de-duplicates titles. Distinct author options may share a label.
                    popup.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
                }
                popup.setAccessibilityLabel(property.label); controls.addArrangedSubview(popup); combo = popup
                popup.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
                if inline { inlinePopupWidth = popup.widthAnchor.constraint(equalToConstant: 134); inlinePopupWidth?.isActive = true }
                popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                popup.cell?.lineBreakMode = .byTruncatingTail
            default:
                controls.addArrangedSubview(field); field.widthAnchor.constraint(equalTo: controls.widthAnchor).isActive = true
                if inline { inlineFieldWidth = field.widthAnchor.constraint(equalToConstant: 130); inlineFieldWidth?.isActive = true }
            }
        }
        set(value, mediaAuthorizationIssue: mediaAuthorizationIssue)
    }

    func updateInlineWidth(_ width: CGFloat) {
        guard inline, width > 0, property.type != "group" else { return }
        let small = width <= 200
        inlineTitle?.font = .systemFont(ofSize: small ? 11.9 : 14)
        field.font = .systemFont(ofSize: small ? 11.9 : 14); combo?.font = field.font
        inlineSliderWidth?.constant = small ? 60 : 101
        inlinePopupWidth?.constant = small ? 90 : 134
        if property.type == "slider" { inlineFieldWidth?.constant = small ? 26 : 40 }
        else if property.isMedia { inlineFieldWidth?.constant = small ? 90 : 190 }
        else { inlineFieldWidth?.constant = small ? 90 : 130 }
        let maximum: CGFloat
        if property.type == "slider" { maximum = small ? 70 : width >= 340 ? 200 : 130 }
        else if property.type == "combo" { maximum = small ? 70 : 130 }
        else { maximum = max(40, width - (property.isMedia ? (small ? 90 : 190) : property.type == "textinput" ? (small ? 90 : 130) : property.type == "color" ? 112 : property.type == "bool" ? 20 : 0) - 20) }
        inlineLabelMaximum?.constant = maximum
    }
    func setGroupMember() {
        guard inline else { return }
        view.grouped = true; view.edgeInsets = NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 0)
    }
    func acceptCommittedValue(_ value: Any?) {
        // Keep the caret and the user's current spelling while a text editor
        // is active; media grants need the committed token rather than a URL.
        if !property.isMedia, field.currentEditor() != nil { original = value }
        else { set(value, mediaAuthorizationIssue: nil) }
    }
    func cancelInteraction() { mediaPanel?.cancel(nil); mediaPanel = nil; color?.deactivate() }
    @objc private func toggleFromLabel() { toggle?.performClick(nil) }

    func set(_ value: Any?, mediaAuthorizationIssue: WallpaperPropertyLoadIssue? = nil) {
        original = value; colorChanged = false; preciseColor = nil
        selectedMedia = nil
        if property.isMedia {
            let token = value as? String ?? ""
            self.mediaAuthorizationIssue = token.isEmpty ? nil : mediaAuthorizationIssue
            let message = self.mediaAuthorizationIssue?.presentation
            field.stringValue = token.isEmpty ? "" : (self.mediaAuthorizationIssue?.fieldPresentation ?? ((try? WallpaperMediaGrants.read(token, project: projectURL, property: property).name) ?? "选择已失效，请重新选择"))
            mediaAuthorizationNote?.stringValue = message ?? ""
            mediaAuthorizationNote?.isHidden = message == nil
            mediaAuthorizationNote?.setAccessibilityLabel(message.map { "\(property.label)：\($0)" })
            field.toolTip = message
            field.setAccessibilityHelp(message)
        }
        toggle?.state = (value as? Bool == true) ? .on : .off
        if let slider, let number = WallpaperProperty.number(value) { slider.doubleValue = number; field.stringValue = Self.format(number) }
        if let combo, let index = property.options.firstIndex(where: { WallpaperProperty.equal($0["value"], value) }) { combo.selectItem(at: index) }
        if let color, let value = value as? String {
            let parts = value.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
            if parts.count == 3 {
                color.color = NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: 1)
                field.stringValue = Self.hex(color.color); initialColorText = field.stringValue
            }
        } else if property.type == "textinput" { field.stringValue = value as? String ?? "" }
    }

    func value() throws -> Any? {
        guard canEdit else { return original }
        if property.isMedia { return original ?? "" }
        if let toggle { return toggle.state == .on }
        if let combo {
            guard property.options.indices.contains(combo.indexOfSelectedItem), let value = property.options[combo.indexOfSelectedItem]["value"] else { throw PropertyError.invalid("\(property.label)：请选择一个选项。") }
            return try property.normalized(value)
        }
        if slider != nil {
            return try sliderFieldValue()
        }
        if color != nil {
            if !colorChanged, field.stringValue == initialColorText { return original }
            let chosen: NSColor
            if let preciseColor, field.stringValue == Self.hex(preciseColor) { chosen = preciseColor }
            else {
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
                guard digits.count == 6, digits.allSatisfy({ $0.isHexDigit }), let bits = UInt32(digits, radix: 16) else { throw PropertyError.invalid("\(property.label)：颜色格式应为 #RRGGBB。") }
                chosen = NSColor(srgbRed: Double((bits >> 16) & 255) / 255, green: Double((bits >> 8) & 255) / 255, blue: Double(bits & 255) / 255, alpha: 1)
            }
            let rgb = chosen.usingColorSpace(.sRGB) ?? chosen
            return try property.normalized([rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Self.format(Double(min(1, max(0, $0)))) }.joined(separator: " "))
        }
        return try property.normalized(field.stringValue)
    }

    func configureGroup(hasMembers: Bool, expanded: Bool) {
        groupDisclosure?.isEnabled = hasMembers
        setGroupExpanded(expanded)
    }
    func setGroupExpanded(_ expanded: Bool) { groupDisclosure?.state = expanded ? .on : .off }
    @objc private func groupChanged(_ sender: NSButton) { onGroupToggle?(sender.state == .on) }

    @objc private func chooseMedia() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        mediaPanel = panel
        panel.title = property.label; panel.prompt = "选择"
        panel.canChooseDirectories = property.type == "directory"; panel.canChooseFiles = property.type == "file"
        panel.allowsMultipleSelection = false; panel.resolvesAliases = true
        if property.type == "file" {
            panel.allowedContentTypes = WallpaperMediaGrants.extensions(for: property).sorted().compactMap { UTType(filenameExtension: $0) }
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            self?.mediaPanel = nil
            guard let self, response == .OK, let url = panel.url else { return }
            self.selectedMedia = url; self.field.stringValue = url.lastPathComponent
            self.onChange?()
        }
    }
    @objc private func clearMedia() { set(""); onChange?() }
    @objc private func selectionChanged() { onChange?() }

    @objc private func sliderChanged(_ sender: NSSlider) {
        if let number = try? (inline ? property.normalized(sender.doubleValue) as! Double : property.snappedSlider(sender.doubleValue)) {
            original = number; sender.doubleValue = number; field.stringValue = Self.format(number)
        }
        onChange?()
    }
    @objc private func colorChanged(_ sender: NSColorWell) {
        colorChanged = true; preciseColor = sender.color.usingColorSpace(.sRGB); field.stringValue = Self.hex(sender.color)
        onChange?()
    }
    @objc private func fieldChanged(_ sender: Any?) {
        if inline, slider != nil, let range = property.sliderRange,
           let number = Double(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), number.isFinite {
            // The official editable slider label clamps on blur/Enter, and
            // its enforceStep:false does not round typed values to a UI step.
            let clamped = min(range.max, max(range.min, number))
            if clamped != number { field.stringValue = Self.format(clamped) }
        }
        if let slider, let number = try? sliderFieldValue() {
            original = number; slider.doubleValue = number; field.stringValue = Self.format(number)
        }
        if let color, let text = try? value() as? String {
            let parts = text.split(separator: " ").compactMap { Double($0) }
            if parts.count == 3 { color.color = NSColor(srgbRed: parts[0], green: parts[1], blue: parts[2], alpha: 1) }
        }
        onChange?()
    }
    private func sliderFieldValue() throws -> Double {
        if !inline { return try property.sliderInput(field.stringValue, preserving: original) }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = WallpaperProperty.number(original), text == Self.format(value) { return try property.normalized(value) as! Double }
        guard let number = Double(text) else { throw PropertyError.invalid("\(property.label)：请输入数值") }
        return try property.normalized(number) as! Double
    }
    func controlTextDidChange(_ obj: Notification) { onChange?() }
    func controlTextDidEndEditing(_ obj: Notification) { fieldChanged(nil) }
    private static func format(_ value: Double) -> String { WallpaperProperty.formatNumber(value) }
    private static func hex(_ color: NSColor) -> String {
        let value = color.usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02X%02X%02X", Int((min(1, max(0, value.redComponent)) * 255).rounded()), Int((min(1, max(0, value.greenComponent)) * 255).rounded()), Int((min(1, max(0, value.blueComponent)) * 255).rounded()))
    }
}

@MainActor
final class WallpaperPropertiesController: NSWindowController, NSWindowDelegate {
    enum Presentation { case window, inspector }
    let projectURL: URL
    private let metadataData: Data
    private let propertyScopeIdentity: String
    private let presentation: Presentation
    private let inlineRoot = PropertyFormStackView()
    var inspectorView: NSView { inlineRoot }
    private static var pendingApplications: [UUID: Task<Void, Never>] = [:]
    private static var pendingConditions: [UUID: Task<Void, Never>] = [:]
    var onApply: (([String: Any], [String: URL]) async throws -> (count: Int, payload: [String: Any]))?
    private var rows: [PropertyRow] = []
    private var baseline: [String: Any]
    private var propertyIssues: [String: WallpaperPropertyLoadIssue]
    private var applyTask: Task<Void, Never>?
    private var dirtyKeys = Set<String>()
    private var applyingInlineKeys = Set<String>()
    private var editRevision: UInt64 = 0
    private let retryInlineButton = NSButton(title: "重试", target: nil, action: nil)
    private var conditionTask: Task<Void, Never>?
    private var conditionRevision: UInt64 = 0
    private var conditionUpdatesEnabled = true
    private var conditions: [String: String] = [:]
    private var conditionVisibility: [String: Bool] = [:]
    private var conditionErrors: [String: String] = [:]
    private var invalidDrafts = Set<String>()
    private var parentGroups: [String: String] = [:]
    private var groupMembers: [String: Set<String>] = [:]
    private var collapsedGroups: Set<String>
    private let groupPreferencesKey: String
    private let conditionNote = NSTextField(wrappingLabelWithString: "")
    private var suspendedControls: [(NSControl, Bool)] = []
    private let status = NSTextField(wrappingLabelWithString: "调整后点击“应用并保存”。设置仅保存于本机。")

    init(project: WallpaperProject, presentation: Presentation = .window) {
        self.presentation = presentation
        projectURL = project.projectURL; metadataData = project.metadataData; propertyScopeIdentity = project.propertyScope.identity
        baseline = project.userProperties
        propertyIssues = [:]
        for issue in project.propertyLoadIssues where propertyIssues[issue.propertyKey] == nil {
            propertyIssues[issue.propertyKey] = issue
        }
        let identity = SavedWorkshopStore.settingsIdentity(project.projectURL)
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        let preferencesKey = "wallpaperPropertyCollapsedGroups." + digest
        groupPreferencesKey = preferencesKey
        let groupKeys = Set(project.propertyDefinitions.prefix(256).filter { $0.type == "group" }.map(\.key))
        collapsedGroups = Set((UserDefaults.standard.stringArray(forKey: preferencesKey) ?? []).prefix(256)).intersection(groupKeys)
        let inline = presentation == .inspector
        let window = inline ? nil : NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 660), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window?.title = "壁纸设置 · \(project.title)"; window?.minSize = NSSize(width: 530, height: 400); window?.isReleasedWhenClosed = false
        super.init(window: window)
        window?.delegate = self
        let content = NSView(); window?.contentView = content
        let heading = NSTextField(labelWithString: project.title); heading.font = .systemFont(ofSize: 20, weight: .semibold); heading.lineBreakMode = .byTruncatingTail
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heading.toolTip = project.title
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let form = PropertyFormStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = inline ? 0 : 22; form.edgeInsets = inline ? NSEdgeInsets() : NSEdgeInsets(top: 10, left: 4, bottom: 20, right: 16)
        scroll.documentView = form; form.translatesAutoresizingMaskIntoConstraints = false
        conditionNote.font = .systemFont(ofSize: 12); conditionNote.textColor = .secondaryLabelColor
        conditionNote.isHidden = true; form.addArrangedSubview(conditionNote)
        conditionNote.widthAnchor.constraint(equalTo: form.widthAnchor, constant: inline ? 0 : -20).isActive = true
        var currentGroup: String?
        for property in project.propertyDefinitions.prefix(256) {
            let row = PropertyRow(property: property, value: (project.userProperties[property.key] as? [String: Any])?["value"], projectURL: project.projectURL, mediaEnabled: project.kind == .web && project.resourceURL.isFileURL,
                                  mediaAuthorizationIssue: propertyIssues[property.key], inline: inline)
            row.onChange = { [weak self] in self?.propertyChanged(property.key) }
            if property.type == "group" {
                currentGroup = property.key; groupMembers[property.key] = []
                row.onGroupToggle = { [weak self] expanded in self?.toggleGroup(property.key, expanded: expanded) }
            } else if let currentGroup {
                parentGroups[property.key] = currentGroup
                groupMembers[currentGroup, default: []].insert(property.key)
                row.setGroupMember()
            }
            if let condition = property.displayCondition { conditions[property.key] = condition }
            rows.append(row); form.addArrangedSubview(row.view)
            row.view.widthAnchor.constraint(equalTo: form.widthAnchor, constant: inline ? 0 : -20).isActive = true
        }
        for row in rows where row.property.type == "group" {
            row.configureGroup(hasMembers: groupMembers[row.property.key]?.isEmpty == false,
                               expanded: !collapsedGroups.contains(row.property.key))
        }
        if rows.isEmpty { form.addArrangedSubview(NSTextField(labelWithString: "作者未提供可调整的用户设置。")) }
        if project.propertyDefinitions.count > 256 { form.addArrangedSubview(NSTextField(wrappingLabelWithString: "当前界面最多显示 256 项设置，其余属性保留现值。")) }
        let defaults = NSButton(title: inline ? "重置" : "恢复作者默认值", target: self, action: #selector(resetDefaults))
        let done = NSButton(title: "关闭", target: self, action: #selector(closeEditor))
        let apply = NSButton(title: "应用并保存", target: self, action: #selector(applyChanges)); apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [defaults, done, apply]); buttons.spacing = 10
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3
        if inline {
            scroll.documentView = nil
            inlineRoot.orientation = .vertical; inlineRoot.alignment = .leading; inlineRoot.spacing = 10
            let label = NSTextField(labelWithString: "属性"); label.font = .systemFont(ofSize: 14, weight: .medium)
            let line = NSBox(); line.boxType = .separator
            let header = NSStackView(views: [label, line]); header.spacing = 10
            label.setContentHuggingPriority(.required, for: .horizontal)
            retryInlineButton.target = self; retryInlineButton.action = #selector(retryInlineChanges); retryInlineButton.isHidden = true
            status.stringValue = ""; status.isHidden = true
            for view in [header, form, status] {
                inlineRoot.addArrangedSubview(view); view.widthAnchor.constraint(equalTo: inlineRoot.widthAnchor).isActive = true
            }
            inlineRoot.addArrangedSubview(retryInlineButton); inlineRoot.addArrangedSubview(defaults)
        } else {
        for view in [heading, scroll, status, buttons] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 22), heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 16), scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            form.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), form.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), form.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.trailingAnchor.constraint(equalTo: heading.trailingAnchor), status.heightAnchor.constraint(equalToConstant: 42), status.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: heading.trailingAnchor), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window?.center()
        }
        refreshConditions()
    }
    required init?(coder: NSCoder) { nil }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func resetDefaults() {
        if presentation == .inspector {
            guard let window = inlineRoot.window, conditionUpdatesEnabled else { return }
            let alert = NSAlert(); alert.messageText = "重置预设"; alert.informativeText = "你想将这些预设重置为默认值吗？"
            alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn, self.conditionUpdatesEnabled else { return }
                self.applyInlineDefaults()
            }
            return
        }
        rows.forEach { $0.set($0.property.defaultValue) }
        refreshConditions()
        status.stringValue = "已填入作者默认值，点击“应用并保存”后生效。"; status.textColor = .secondaryLabelColor
    }
    @objc private func closeEditor() { conditionUpdatesEnabled = false; applyTask?.cancel(); conditionTask?.cancel(); close() }
    func windowWillClose(_ notification: Notification) { conditionUpdatesEnabled = false; applyTask?.cancel(); conditionTask?.cancel() }
    func cancelPendingApply() -> Task<Void, Never>? {
        let pending = applyTask
        conditionUpdatesEnabled = false
        pending?.cancel()
        conditionTask?.cancel()
        rows.forEach { $0.cancelInteraction() }
        close()
        return pending
    }
    static func cancelAllPendingApplications() -> [Task<Void, Never>] {
        let pending = Array(pendingApplications.values) + Array(pendingConditions.values)
        pending.forEach { $0.cancel() }
        return pending
    }
    func matches(_ project: WallpaperProject) -> Bool {
        projectURL == project.projectURL && metadataData == project.metadataData && propertyScopeIdentity == project.propertyScope.identity && conditionUpdatesEnabled
    }
    func updateInspectorWidth(_ width: CGFloat) {
        guard presentation == .inspector else { return }
        // Choose responsive control sizes from the space assigned by the
        // browser, before Auto Layout computes the controls' minimum width.
        rows.forEach { $0.updateInlineWidth(width) }
    }
    func synchronize(_ project: WallpaperProject) {
        guard presentation == .inspector, matches(project) else { return }
        baseline = project.userProperties
        propertyIssues.removeAll(keepingCapacity: true)
        for issue in project.propertyLoadIssues where propertyIssues[issue.propertyKey] == nil {
            propertyIssues[issue.propertyKey] = issue
        }
        for row in rows where !dirtyKeys.contains(row.property.key) && !applyingInlineKeys.contains(row.property.key) {
            row.set((baseline[row.property.key] as? [String: Any])?["value"], mediaAuthorizationIssue: propertyIssues[row.property.key])
        }
        refreshConditions()
    }
    func finishInlineApplications() -> Task<Void, Never>? {
        guard presentation == .inspector else { return nil }
        inlineRoot.window?.makeFirstResponder(nil)
        suspendEditing()
        startInlineApplication()
        return applyTask
    }
    var hasPendingApplication: Bool { applyTask != nil }
    private func propertyChanged(_ key: String) {
        guard conditionUpdatesEnabled else { return }
        if presentation == .inspector {
            editRevision &+= 1; dirtyKeys.insert(key)
            startInlineApplication()
        }
        refreshConditions()
    }
    private func applyInlineDefaults() {
        for row in rows where row.property.editable {
            row.set(row.property.defaultValue)
            editRevision &+= 1; dirtyKeys.insert(row.property.key)
        }
        refreshConditions(); startInlineApplication()
    }
    @objc private func retryInlineChanges() { startInlineApplication() }
    private func startInlineApplication() {
        guard presentation == .inspector, conditionUpdatesEnabled, applyTask == nil, !dirtyKeys.isEmpty else { return }
        let requestID = UUID()
        let task = Task { [weak self] in
            defer { Self.pendingApplications.removeValue(forKey: requestID) }
            guard let self else { return }
            defer { self.applyTask = nil; self.applyingInlineKeys.removeAll() }
            while self.conditionUpdatesEnabled && !Task.isCancelled && !self.dirtyKeys.isEmpty {
                do {
                    // Coalesce continuous slider/text events. Only one commit
                    // is in flight; edits made during it remain in dirtyKeys.
                    try await Task.sleep(nanoseconds: 20_000_000)
                    let revision = self.editRevision
                    var values: [String: Any] = [:], media: [String: URL] = [:], valid = Set<String>()
                    var invalidMessage: String?
                    for row in self.rows where self.dirtyKeys.contains(row.property.key) && row.property.editable {
                        do {
                            let key = row.property.key
                            if let selected = row.selectedMedia { media[key] = selected }
                            else if let value = try row.value(), !WallpaperProperty.equal(value, (self.baseline[key] as? [String: Any])?["value"]) { values[key] = value }
                            valid.insert(key)
                        } catch { if invalidMessage == nil { invalidMessage = error.localizedDescription } }
                    }
                    self.dirtyKeys.subtract(valid)
                    guard !values.isEmpty || !media.isEmpty else {
                        self.status.stringValue = invalidMessage ?? ""; self.status.isHidden = invalidMessage == nil
                        self.status.textColor = .systemRed; self.retryInlineButton.isHidden = true
                        break
                    }
                    let keys = Set(values.keys).union(media.keys)
                    self.applyingInlineKeys = keys
                    self.status.isHidden = true; self.retryInlineButton.isHidden = true
                    do {
                        guard let onApply = self.onApply else { throw PropertyError.invalid("当前壁纸已经关闭，请重新选择壁纸。") }
                        let result = try await onApply(values, media)
                        try Task.checkCancellation()
                        guard self.conditionUpdatesEnabled else { break }
                        self.baseline = result.payload
                        for row in self.rows where !self.dirtyKeys.contains(row.property.key) {
                            let value = (result.payload[row.property.key] as? [String: Any])?["value"]
                            if keys.contains(row.property.key) {
                                self.propertyIssues.removeValue(forKey: row.property.key)
                                row.acceptCommittedValue(value)
                            } else {
                                row.set(value, mediaAuthorizationIssue: self.propertyIssues[row.property.key])
                            }
                        }
                        self.status.stringValue = invalidMessage ?? ""; self.status.isHidden = invalidMessage == nil
                        self.status.textColor = .systemRed
                        self.applyingInlineKeys.removeAll()
                        self.refreshConditions()
                    } catch is CancellationError { break }
                    catch {
                        self.dirtyKeys.formUnion(keys); self.applyingInlineKeys.removeAll()
                        self.status.stringValue = error.localizedDescription; self.status.textColor = .systemRed
                        self.status.isHidden = false; self.retryInlineButton.isHidden = false
                        // Retry a newer edit, not the same failed request in a
                        // tight loop. Explicit retry also retains these drafts.
                        if self.editRevision == revision { break }
                    }
                } catch { break }
            }
        }
        applyTask = task; Self.pendingApplications[requestID] = task
    }
    @objc private func applyChanges() {
        guard applyTask == nil else { return }
        window?.makeFirstResponder(nil)
        do {
            var changes: [String: Any] = [:]
            var media: [String: URL] = [:]
            for row in rows where row.property.editable {
                if let selected = row.selectedMedia { media[row.property.key] = selected; continue }
                if let value = try row.value(), !WallpaperProperty.equal(value, (baseline[row.property.key] as? [String: Any])?["value"]) { changes[row.property.key] = value }
            }
            guard let onApply else { throw PropertyError.invalid("当前壁纸已经关闭，请重新打开设置。") }
            suspendEditing()
            status.textColor = .secondaryLabelColor; status.stringValue = "正在准备素材并保存设置…"
            let requestID = UUID()
            let task = Task { [weak self] in
                defer { Self.pendingApplications.removeValue(forKey: requestID) }
                guard let self else { return }
                defer { self.resumeEditing(); self.applyTask = nil }
                do {
                    let result = try await onApply(changes, media)
                    self.baseline = result.payload
                    let committedKeys = Set(changes.keys).union(media.keys)
                    for row in self.rows {
                        let value = (self.baseline[row.property.key] as? [String: Any])?["value"]
                        if committedKeys.contains(row.property.key) {
                            self.propertyIssues.removeValue(forKey: row.property.key)
                            row.acceptCommittedValue(value)
                        } else {
                            row.set(value, mediaAuthorizationIssue: self.propertyIssues[row.property.key])
                        }
                    }
                    self.refreshConditions()
                    self.status.textColor = .secondaryLabelColor
                    self.status.stringValue = result.count == 0 ? "设置未改变。" : "已保存并发送 \(result.count) 项更改。"
                } catch is CancellationError { }
                catch { self.status.textColor = .systemRed; self.status.stringValue = error.localizedDescription }
            }
            applyTask = task; Self.pendingApplications[requestID] = task
        } catch { status.textColor = .systemRed; status.stringValue = error.localizedDescription }
    }
    private func suspendEditing() {
        guard suspendedControls.isEmpty else { return }
        func visit(_ view: NSView) {
            if let control = view as? NSControl, (control as? NSButton)?.title != "关闭" {
                suspendedControls.append((control, control.isEnabled)); control.isEnabled = false
            }
            view.subviews.forEach(visit)
        }
        if let content = window?.contentView { visit(content) }
        else if presentation == .inspector { visit(inlineRoot) }
    }
    private func resumeEditing() {
        suspendedControls.forEach { $0.0.isEnabled = $0.1 }; suspendedControls.removeAll()
    }

    private func refreshConditions() {
        conditionRevision &+= 1
        conditionTask?.cancel(); conditionTask = nil
        guard conditionUpdatesEnabled, !Task.isCancelled else { return }
        let revision = conditionRevision, requestID = UUID()
        var values = baseline, invalid = Set<String>()
        for row in rows {
            do {
                if let value = try row.value() {
                    let draft: Any = row.selectedMedia.map { $0.path as Any } ?? value
                    values[row.property.key] = row.property.payload(draft)
                }
            } catch { invalid.insert(row.property.key) }
        }
        // Group folding and invalid-input recovery also work in projects that
        // have no authored JavaScript conditions.
        applyConditionVisibility(conditions.isEmpty ? [:] : conditionVisibility,
                                 errors: conditions.isEmpty ? [:] : conditionErrors, invalid: invalid)
        guard !conditions.isEmpty else { return }
        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("Tools/we-scene-script") else {
            applyConditionVisibility([:], errors: ["component": "显示条件组件缺失。"], invalid: invalid)
            return
        }
        let task = Task { [weak self] in
            defer {
                Self.pendingConditions.removeValue(forKey: requestID)
                if self?.conditionRevision == revision { self?.conditionTask = nil }
            }
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
                guard let self else { return }
                let result = try await NativePropertyConditions.evaluate(conditions: self.conditions, properties: values, executable: executable)
                guard !Task.isCancelled, self.conditionRevision == revision else { return }
                self.applyConditionVisibility(result.visible, errors: result.errors, invalid: invalid)
            } catch is CancellationError { }
            catch {
                guard let self, !Task.isCancelled, self.conditionRevision == revision else { return }
                self.applyConditionVisibility([:], errors: ["evaluation": error.localizedDescription], invalid: invalid)
            }
        }
        conditionTask = task; Self.pendingConditions[requestID] = task
    }

    private func applyConditionVisibility(_ visible: [String: Bool], errors: [String: String], invalid: Set<String>) {
        conditionVisibility = visible; conditionErrors = errors; invalidDrafts = invalid
        let correctionGroups = Set(invalid.compactMap { parentGroups[$0] })
        let before = collapsedGroups
        collapsedGroups.subtract(correctionGroups)
        if before != collapsedGroups { saveGroupPreferences() }
        for row in rows {
            // Hidden inputs retain their draft values. An invalid draft stays
            // reachable so a later Apply cannot fail on an inaccessible field.
            let key = row.property.key
            if row.property.type == "group" {
                row.setGroupExpanded(!collapsedGroups.contains(key))
                row.view.isHidden = visible[key] == false && !correctionGroups.contains(key)
            } else {
                let parentHidden = parentGroups[key].map { group in
                    collapsedGroups.contains(group) || (visible[group] == false && !correctionGroups.contains(group))
                } ?? false
                row.view.isHidden = !invalid.contains(key) && (visible[key] == false || parentHidden)
            }
        }
        conditionNote.isHidden = errors.isEmpty && invalid.isEmpty
        conditionNote.stringValue = errors.isEmpty
            ? "有未完成的输入，相关设置保持可见。"
            : "部分显示条件暂不可用，相关设置已保持显示。"
        conditionNote.toolTip = String(errors.keys.sorted().map { $0 + "：" + errors[$0]! }.joined(separator: "\n").prefix(2048))
    }

    private func toggleGroup(_ key: String, expanded: Bool) {
        guard groupMembers[key]?.isEmpty == false else { return }
        // Commit any active text editor before hiding its row. Invalid input
        // will immediately reopen the group through the shared visibility path.
        if !expanded { (window ?? inlineRoot.window)?.makeFirstResponder(nil) }
        if expanded { collapsedGroups.remove(key) } else { collapsedGroups.insert(key) }
        applyConditionVisibility(conditionVisibility, errors: conditionErrors, invalid: invalidDrafts)
        saveGroupPreferences()
    }

    private func saveGroupPreferences() {
        // This presentation state is separate from the wallpaper's values;
        // in particular a group label never becomes a boolean user property.
        if collapsedGroups.isEmpty { UserDefaults.standard.removeObject(forKey: groupPreferencesKey) }
        else { UserDefaults.standard.set(collapsedGroups.sorted(), forKey: groupPreferencesKey) }
    }
}
