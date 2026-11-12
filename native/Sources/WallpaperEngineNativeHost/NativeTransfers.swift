import AppKit
import Foundation

struct WorkshopTransferEntry: Identifiable, Sendable, Equatable {
    enum Phase: String, Sendable, Codable {
        case queued, checking, downloading, confirming, saving, completed, failed, cancelled, interrupted
        var terminal: Bool { [.completed, .failed, .cancelled, .interrupted].contains(self) }
        var title: String {
            switch self {
            case .queued: return "排队中"
            case .checking: return "检查版本"
            case .downloading: return "等待 Steam 下载"
            case .confirming: return "确认安装"
            case .saving: return "保存到本机"
            case .completed: return "获取完成"
            case .failed: return "未完成"
            case .cancelled: return "已停止处理"
            case .interrupted: return "上次处理已中断"
            }
        }
    }
    let id: UUID
    let workshopID: String
    var title: String
    var automatic: Bool
    var phase: Phase = .queued
    var detail = "等待处理"
    var downloaded: UInt64?
    var total: UInt64?
    var project: URL?
    var createdAt = Date()
    var updatedAt = Date()
    var progressText: String {
        guard phase == .downloading, let downloaded, let total, total > 0 else { return phase == .downloading ? "Steam 尚未提供字节进度" : "" }
        let amount = ByteCountFormatter.string(fromByteCount: Int64(downloaded), countStyle: .file)
        let size = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
        // Even 100% is only a byte count, never an installation receipt.
        return String(format: "%.1f%%", Double(downloaded) / Double(total) * 100) + " · " + amount + " / " + size
    }
}

struct WorkshopTransferSnapshot {
    let entries: [WorkshopTransferEntry]
    let paused: Bool
    let activity: String
    let connection: String
    var recoveryNotice = ""
    var persistenceIssue: String?
}

/// An atomic, bounded queue journal. Byte counts, account data and selection
/// generations are deliberately absent: a saved task is not an install receipt.
enum WorkshopTransferJournal {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/WallpaperEngineNative/Transfers-v1.json")
    }
    static let maximumBytes = 8 * 1024 * 1024
    struct Record: Codable {
        let token: UUID
        let workshopID: String
        let title: String
        let automatic: Bool
        let phase: WorkshopTransferEntry.Phase
        let detail: String
        let sourcePath: String?
        let resultPath: String?
        let retainCopy: Bool
        let createdAt: Date
        let updatedAt: Date

        init(entry: WorkshopTransferEntry, sourceProject: URL?, retainCopy: Bool) {
            token = entry.id; workshopID = entry.workshopID; title = entry.title
            automatic = entry.automatic; phase = entry.phase; detail = entry.detail
            sourcePath = sourceProject?.path; resultPath = entry.project?.path
            self.retainCopy = retainCopy; createdAt = entry.createdAt; updatedAt = entry.updatedAt
        }
        var entry: WorkshopTransferEntry {
            var entry = WorkshopTransferEntry(id: token, workshopID: workshopID, title: title, automatic: automatic)
            entry.phase = phase; entry.detail = detail; entry.createdAt = createdAt; entry.updatedAt = updatedAt
            entry.project = resultPath.map { URL(fileURLWithPath: $0) }
            return entry
        }
    }
    struct Snapshot: Codable {
        var version = 1
        let records: [Record]
        let queue: [UUID]
    }
    enum Failure: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "任务记录的格式、大小或内容无效。"
            case .unavailable: return "任务记录的位置不可读写。"
            }
        }
    }
    static func validate(_ value: Snapshot) throws {
        guard value.version == 1, value.records.count <= 1101, value.queue.count <= 1001,
              Set(value.records.map(\.token)).count == value.records.count,
              Set(value.queue).count == value.queue.count else { throw Failure.invalid }
        let queued = Set(value.queue)
        guard queued == Set(value.records.filter { !$0.phase.terminal }.map(\.token)) else { throw Failure.invalid }
        for record in value.records {
            guard SteamLibraryIndex.validID(record.workshopID), record.title.count <= 500, record.title.utf8.count <= 4096,
                  record.detail.count <= 1400, record.detail.utf8.count <= 12000,
                  [record.createdAt, record.updatedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite && abs($0.timeIntervalSince1970) < 100_000_000_000 }) else { throw Failure.invalid }
            for path in [record.sourcePath, record.resultPath].compactMap({ $0 }) {
                guard path.hasPrefix("/"), path.hasSuffix("/project.json"), !path.contains("\0"), path.utf8.count <= 4096,
                      URL(fileURLWithPath: path).standardizedFileURL.path == path else { throw Failure.invalid }
            }
        }
    }
    static func load(from url: URL) throws -> Snapshot? {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= Int64(maximumBytes) else { throw Failure.invalid }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw Failure.invalid }
        let value = try JSONDecoder().decode(Snapshot.self, from: data)
        try validate(value)
        return value
    }
    static func save(_ value: Snapshot, to url: URL) throws {
        try validate(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw Failure.invalid }
        let manager = FileManager.default, parent = url.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let permissions = attributes[.posixPermissions] as? NSNumber, permissions.intValue & 0o022 == 0 else { throw Failure.unavailable }
        if let existing = try? manager.attributesOfItem(atPath: url.path), existing[.type] as? FileAttributeType != .typeRegular { throw Failure.unavailable }
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
final class NativeTransferController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    var onPauseQueue: (() -> Void)?
    var onRetry: ((UUID) -> Void)?
    var onStop: ((UUID) -> Void)?
    var onOpen: ((UUID) -> Void)?
    var onClear: (() -> Void)?
    var onDownload: (() -> Void)?
    var onRetrySaving: (() -> Void)?
    private let table = NSTableView()
    private let summary = NSTextField(wrappingLabelWithString: "当前没有下载任务")
    private let connection = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let retrySaving = NSButton(title: "重试保存记录", target: nil, action: nil)
    private let detail = NSTextField(wrappingLabelWithString: "选择一项查看处理结果。")
    private let progress = NSProgressIndicator()
    private let pause = NSButton(title: "暂停后续获取", target: nil, action: nil)
    private let retry = NSButton(title: "重试获取", target: nil, action: nil)
    private let stop = NSButton(title: "从队列移除", target: nil, action: nil)
    private let open = NSButton(title: "设为默认壁纸", target: nil, action: nil)
    private let clear = NSButton(title: "清除已结束记录", target: nil, action: nil)
    private var entries: [WorkshopTransferEntry] = []
    private var rebuilding = false
    private var selected: WorkshopTransferEntry? { entries.indices.contains(table.selectedRow) ? entries[table.selectedRow] : nil }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 930, height: 730), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wallpaper Engine Native · 下载与更新"
        window.minSize = NSSize(width: 850, height: 700); window.isReleasedWhenClosed = false
        super.init(window: window)
        let heading = NSTextField(labelWithString: "下载与更新")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString: "手动队列和处理记录在重开后恢复，自动更新重新确认订阅。暂停只延后排队项；停止处理后 Steam 可能继续下载，本机副本会保留。")
        note.textColor = .secondaryLabelColor
        pause.target = self; pause.action = #selector(toggleQueue)
        clear.target = self; clear.action = #selector(clearFinished)
        let header = NSStackView(views: [heading, NSView(), pause, clear]); header.spacing = 12
        summary.font = .systemFont(ofSize: 12); summary.maximumNumberOfLines = 2
        connection.font = .systemFont(ofSize: 11); connection.textColor = .secondaryLabelColor
        connection.lineBreakMode = .byTruncatingTail
        notice.font = .systemFont(ofSize: 12); notice.maximumNumberOfLines = 3
        retrySaving.target = self; retrySaving.action = #selector(retrySave)
        let recovery = NSStackView(views: [notice, retrySaving]); recovery.spacing = 12
        notice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table.dataSource = self; table.delegate = self; table.rowHeight = 42
        table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("下载与更新任务及历史记录")
        for (name, title, width) in [("title", "壁纸", 330.0), ("phase", "状态", 130.0), ("progress", "进度", 335.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name)); column.title = title
            column.width = width; column.minWidth = name == "phase" ? 110 : 190; table.addTableColumn(column)
        }
        scroll.documentView = table
        detail.font = .systemFont(ofSize: 12); detail.maximumNumberOfLines = 6
        detail.textColor = .secondaryLabelColor
        progress.style = .bar; progress.minValue = 0; progress.maxValue = 100
        progress.isDisplayedWhenStopped = true; progress.setAccessibilityLabel("所选下载任务进度")
        retry.target = self; retry.action = #selector(retrySelected)
        stop.target = self; stop.action = #selector(stopSelected)
        open.target = self; open.action = #selector(openSelected)
        let add = NSButton(title: "从链接获取…", target: self, action: #selector(addDownload))
        let buttons = NSStackView(views: [add, NSView(), stop, retry, open]); buttons.spacing = 12
        let stack = NSStackView(views: [header, note, summary, connection, recovery, scroll, detail, progress, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 22), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
                scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 230), detail.heightAnchor.constraint(equalToConstant: 105)
            ])
        }
        for view in [header, note, summary, connection, recovery, scroll, detail, progress, buttons] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        notice.isHidden = true; retrySaving.isHidden = true
        refreshSelection(); window.center()
    }
    required init?(coder: NSCoder) { nil }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func selectTransfer(_ id: UUID) {
        guard let row = entries.firstIndex(where: { $0.id == id }) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row); refreshSelection()
    }
    func update(_ snapshot: WorkshopTransferSnapshot) {
        let identity = selected?.id
        let previous = entries
        let scroll = table.enclosingScrollView
        let origin = scroll?.contentView.bounds.origin
        entries = snapshot.entries
        rebuilding = true
        if previous.map(\.id) != entries.map(\.id) { table.reloadData() }
        else {
            for index in entries.indices where entries[index] != previous[index] {
                let old = previous[index], next = entries[index]
                var columns = IndexSet()
                if old.title != next.title || old.workshopID != next.workshopID { columns.insert(0) }
                if old.phase != next.phase { columns.insert(1) }
                if old.progressText != next.progressText || old.automatic != next.automatic { columns.insert(2) }
                if !columns.isEmpty { table.reloadData(forRowIndexes: IndexSet(integer: index), columnIndexes: columns) }
            }
        }
        if let identity, let row = entries.firstIndex(where: { $0.id == identity }) {
            if table.selectedRow != row { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else if table.selectedRow >= 0 { table.deselectAll(nil) }
        if let scroll, let origin {
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, max(0, table.bounds.height - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        rebuilding = false
        let waiting = entries.filter { $0.phase == .queued }.count
        let active = entries.filter { !$0.phase.terminal && $0.phase != .queued }.count
        let failed = entries.filter { $0.phase == .failed }.count
        summary.stringValue = "等待 \(waiting) · 正在处理 \(active) · 未完成 \(failed)" + (snapshot.paused ? " · 获取队列已暂停" : "") + (snapshot.activity.isEmpty ? "" : "\n" + snapshot.activity)
        connection.stringValue = snapshot.connection; connection.toolTip = snapshot.connection
        notice.stringValue = snapshot.persistenceIssue ?? snapshot.recoveryNotice
        notice.toolTip = notice.stringValue; notice.isHidden = notice.stringValue.isEmpty
        notice.textColor = snapshot.persistenceIssue == nil ? .secondaryLabelColor : .systemOrange
        retrySaving.isHidden = snapshot.persistenceIssue == nil
        pause.title = snapshot.paused ? "继续处理队列" : "暂停后续获取"
        clear.isEnabled = entries.contains { $0.phase.terminal }
        refreshSelection()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let item = entries[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "title": value = item.title + " · " + item.workshopID
        case "phase": value = item.phase.title
        default: value = item.progressText.isEmpty ? (item.automatic ? "自动检查 / 更新" : "主动获取 / 更新") : item.progressText
        }
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingTail; label.toolTip = value
        if item.phase == .failed { label.textColor = .systemOrange }
        else if item.phase == .cancelled { label.textColor = .secondaryLabelColor }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !rebuilding { refreshSelection() } }
    private func refreshSelection() {
        progress.stopAnimation(nil); progress.isHidden = true
        guard let selected else {
            detail.stringValue = entries.isEmpty ? "暂无任务。从创意工坊、链接或更新菜单获取壁纸后，处理结果会显示在这里。" : "选择一项查看进度、结果或重试。已完成只表示获取结果，播放兼容情况在打开后确认。"
            retry.isEnabled = false; stop.isEnabled = false; open.isEnabled = false; return
        }
        let time = DateFormatter.localizedString(from: selected.updatedAt, dateStyle: .none, timeStyle: .medium)
        detail.stringValue = selected.title + "\n" + selected.phase.title + " · " + time + "\n" + selected.detail
        detail.toolTip = detail.stringValue
        retry.isEnabled = [.failed, .cancelled, .interrupted].contains(selected.phase)
        stop.isEnabled = !selected.phase.terminal && selected.phase != .saving
        stop.title = selected.phase == .queued ? "从队列移除" : "停止本次处理"
        open.isEnabled = selected.phase == .completed && selected.project != nil
        if !selected.phase.terminal && selected.phase != .queued {
            progress.isHidden = false
            if selected.phase == .downloading, let downloaded = selected.downloaded, let total = selected.total, total > 0 {
                progress.isIndeterminate = false; progress.doubleValue = Double(downloaded) / Double(total) * 100
            } else { progress.isIndeterminate = true; progress.startAnimation(nil) }
        }
    }
    @objc private func toggleQueue() { onPauseQueue?() }
    @objc private func clearFinished() { onClear?() }
    @objc private func retrySelected() { if let selected, retry.isEnabled { onRetry?(selected.id) } }
    @objc private func stopSelected() { if let selected, stop.isEnabled { onStop?(selected.id) } }
    @objc private func openSelected() { if let selected, open.isEnabled { onOpen?(selected.id) } }
    @objc private func addDownload() { onDownload?() }
    @objc private func retrySave() { if !retrySaving.isHidden { onRetrySaving?() } }
}
