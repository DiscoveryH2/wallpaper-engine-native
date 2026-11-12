import AppKit

@MainActor
final class NativeCreationHistoryEditor: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let history: NativeCreationStore.History
    private let table = NSTableView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "载入编辑器", target: nil, action: nil)
    private var result: NativeCreationStore.Record?
    private let formatter: DateFormatter = {
        let value = DateFormatter(); value.dateStyle = .medium; value.timeStyle = .medium; return value
    }()

    init(history: NativeCreationStore.History) {
        self.history = history
        let panel = NSPanel(contentRect: NSRect(x: 0,y: 0,width: 760,height: 480),styleMask: [.titled],backing: .buffered,defer: false)
        panel.title = "作品历史版本"; panel.isReleasedWhenClosed = false
        super.init(window: panel)
        guard let content = panel.contentView else { return }
        let heading = NSTextField(labelWithString: "找回之前的作品内容")
        heading.frame = NSRect(x: 24,y: 435,width: 712,height: 25); heading.font = .systemFont(ofSize: 18,weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "选择旧版本并载入编辑器，可先预览和修改。点击“保存作品”后会生成一个新版本，已有版本继续保留。")
        explanation.frame = NSRect(x: 24,y: 380,width: 712,height: 44); explanation.font = .systemFont(ofSize: 12); explanation.textColor = .secondaryLabelColor
        content.addSubview(heading); content.addSubview(explanation)
        for (id,title,width) in [("time","保存时间",210.0),("title","作品名称",360.0),("version","版本",110.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.headerView = nil; table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnResizing = false; table.allowsColumnReordering = false
        for (title,x,width) in [("保存时间",32.0,202.0),("作品名称",245.0,352.0),("版本",608.0,120.0)] {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: x,y: 350,width: width,height: 18)
            label.font = .systemFont(ofSize: 11,weight: .semibold); label.textColor = .secondaryLabelColor
            content.addSubview(label)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 32
        table.allowsEmptySelection = false; table.allowsMultipleSelection = false
        table.setAccessibilityLabel("作品历史版本列表")
        let scroll = NSScrollView(frame: NSRect(x: 24,y: 122,width: 712,height: 222))
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        content.addSubview(scroll)
        note.frame = NSRect(x: 24,y: 62,width: 712,height: 48); note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        content.addSubview(note)
        let cancel = NSButton(title: "取消",target: self,action: #selector(cancelHistory))
        cancel.frame = NSRect(x: 498,y: 20,width: 100,height: 30); cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        openButton.frame = NSRect(x: 610,y: 20,width: 126,height: 30); openButton.bezelStyle = .rounded
        openButton.target = self; openButton.action = #selector(openHistory); openButton.keyEquivalent = "\r"
        openButton.toolTip = "载入后先预览；保存时另建版本。"
        content.addSubview(cancel); content.addSubview(openButton)
        table.nextKeyView = cancel; cancel.nextKeyView = openButton; openButton.nextKeyView = table
        panel.initialFirstResponder = table
        table.reloadData()
        if !history.items.isEmpty {
            table.selectRowIndexes(IndexSet(integer: history.items.firstIndex { $0.version != history.current.version } ?? 0),byExtendingSelection: false)
        }
        refreshSelection()
    }
    required init?(coder: NSCoder) { nil }

    func present(on parent: NSWindow, completion: @escaping (NativeCreationStore.Record?) -> Void) {
        guard let window else { completion(nil); return }
        parent.beginSheet(window) { [weak self] _ in completion(self?.result) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { history.items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard history.items.indices.contains(row) else { return nil }
        let record = history.items[row], text: String
        switch tableColumn?.identifier.rawValue {
        case "time": text = formatter.string(from: record.savedAt)
        case "title": text = record.title
        default: text = record.version == history.current.version ? "当前版本" : String(record.version.uuidString.prefix(8))
        }
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingMiddle
        field.font = .systemFont(ofSize: 12); field.textColor = .labelColor
        field.toolTip = record.title + "\n" + formatter.string(from: record.savedAt) + "\n" + record.version.uuidString
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshSelection() }
    private func refreshSelection() {
        let selected = history.items.indices.contains(table.selectedRow) ? history.items[table.selectedRow] : nil
        openButton.isEnabled = selected != nil && selected?.version != history.current.version
        let skipped = history.skipped > 0 ? " · \(history.skipped) 个不完整或不可读的版本已略过" : ""
        note.stringValue = "\(history.items.count) 个可读取版本\(skipped)。\n" + (openButton.isEnabled ? "载入成功后会标记为未保存；放弃修改后重新打开作品可返回最新版。" : "当前已保存版本无需恢复。请选择一个旧版本。")
    }
    @objc private func cancelHistory() {
        guard let window, let parent = window.sheetParent else { return }
        result = nil; parent.endSheet(window)
    }
    @objc private func openHistory() {
        guard openButton.isEnabled, history.items.indices.contains(table.selectedRow), let window, let parent = window.sheetParent else { return }
        result = history.items[table.selectedRow]; parent.endSheet(window)
    }
}
