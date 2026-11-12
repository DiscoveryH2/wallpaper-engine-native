import AppKit
import Foundation

/// Bounded invalidation hints. A full hint covers unknown callback layouts and
/// overflow; neither a hint nor its IDs are treated as installation proof.
private struct SavedWorkshopInvalidations {
    private(set) var ids = Set<String>()
    private(set) var full = false
    mutating func merge(ids next: Set<String>, full all: Bool) {
        guard !full else { return }
        if all { full = true; ids.removeAll(); return }
        ids.formUnion(next)
        if ids.count > 2000 { full = true; ids.removeAll() }
    }
    mutating func merge(_ other: Self) { merge(ids: other.ids, full: other.full) }
}

/// Serializes Steam requests while metadata polling covers the downloaded library.
@MainActor
final class WorkshopCoordinator: NSObject {
    var onProjectReady: ((URL) -> Void)?
    var onProjectUpdated: ((URL) -> Void)?
    var onStatus: ((String) -> Void)?
    var onConnectionChanged: ((String) -> Void)?
    var connectionDescription: String { eventMonitor.description }
    var onLibraryChanged: (() -> Void)?
    var onSubscriptionsChanged: (([SteamSubscription]?) -> Void)?
    var onFavoritesChanged: ((Set<String>?) -> Void)?
    /// The browser owns the selected-detail presentation.  It uses this
    /// signal to clear a previously read personal vote whenever the account
    /// envelope becomes unsafe; the coordinator never republishes an old vote
    /// optimistically.
    var onUserVotesInvalidated: (() -> Void)?
    var onTransfersChanged: ((WorkshopTransferSnapshot) -> Void)?
    var onTransferRequested: ((UUID) -> Void)?
    private(set) var subscriptions: [SteamSubscription]?
    private(set) var favoriteIDs: Set<String>?
    /// The canonical SteamID64 bound to `subscriptions`.  A list without this
    /// envelope is presentation-unknown, not a safe account-write source.
    private var subscriptionAccount: WorkshopSubscriptionAccount?
    /// The exact session/authorization tuple that produced the visible full
    /// subscription snapshot. It distinguishes a superseded queued mutation
    /// from a newer snapshot that is already safe for a later user action.
    private var subscriptionSnapshotConnectionEpoch: UInt64?
    private var subscriptionSnapshotAuthorizationGeneration: UInt64?
    /// Favorites have their own freshness lease even though the payload is
    /// transported with the subscriptions response. A non-cached list is the
    /// only favorite source permitted to authorize an account write.
    private var favoriteSnapshotConnectionEpoch: UInt64?
    private var favoriteSnapshotAuthorizationGeneration: UInt64?
    /// `vote-get` is intentionally a read-only helper action, but it still
    /// needs to be tied to a known account session.  These work items are
    /// deferred behind the global account-mutation fence so an old selection
    /// cannot read concurrently with a SetUserItemVote/write-confirmation
    /// sequence for the same Steam account.
    private struct UserVoteReadWork {
        let token: UUID
        let request: WorkshopUserVoteReadRequest
        let account: WorkshopSubscriptionAccount
        let connectionEpoch: UInt64
        let authorizationGeneration: UInt64
        let completion: (WorkshopUserVoteReadResult) -> Void
    }
    private var pendingUserVoteReads: [UserVoteReadWork] = []
    private var activeUserVoteRead: UserVoteReadWork?
    /// Explicit user account mutations. This is intentionally distinct from
    /// the transfer queue: it never downloads, saves, opens, or retries a
    /// Workshop item.
    /// A single account-write fence covers subscription and favorite changes,
    /// including the post-write snapshot.  Steam can complete either API call
    /// asynchronously, so two independent queues could otherwise certify a
    /// stale account view between their callbacks.
    private let accountMutations = WorkshopAccountMutationQueue()
    private var libraryWatcher: SteamLibraryWatcher?
    private var connectionEpoch: UInt64 = 0
    /// A subscription-list change is not an installation receipt, but it does
    /// make every previously queued automatic refresh authorization-stale.
    /// The generation is advanced before the fresh snapshot starts so an
    /// in-flight helper cannot slip a saved-copy pointer through the gap.
    private var automaticAuthorizationGeneration: UInt64 = 0
    /// IDs whose automatic work was invalidated by a 3418 list-change frame.
    /// This stays separate from filesystem/full invalidations: 3418 has no
    /// item ID and must not make one subscription edit refresh every saved
    /// copy. The automatic queue is capped at 1,000, plus one active save.
    private var automaticRetryIDsAwaitingSnapshot = Set<String>()
    private static let maximumAutomaticAuthorizationRetries = 1_001
    private var reconcileTask: DispatchWorkItem?
    private var lastReconcile: TimeInterval = 0
    private lazy var eventMonitor: SteamEventMonitor = {
        let monitor = SteamEventMonitor()
        monitor.onState = { [weak self] text, _ in self?.onConnectionChanged?(text); self?.notifyTransfers(); self?.pump() }
        monitor.onSessionInvalidated = { [weak self] in
            guard let self else { return }
            self.cancelSavingPermits()
            self.connectionEpoch += 1
            self.automaticAuthorizationGeneration &+= 1
            self.automaticRetryIDsAwaitingSnapshot.removeAll()
            self.subscriptions = nil
            self.subscriptionAccount = nil
            self.subscriptionSnapshotConnectionEpoch = nil
            self.subscriptionSnapshotAuthorizationGeneration = nil
            self.favoriteSnapshotConnectionEpoch = nil
            self.favoriteSnapshotAuthorizationGeneration = nil
            self.favoriteIDs = nil; self.onFavoritesChanged?(nil)
            self.invalidateUserVotePresentation(reason: "steam-session-invalidated: Steam 会话已变化；个人投票显示已失效。")
            self.removeAutomaticTasks(reason: "Steam 会话已变化，自动任务等待重新确认。")
            self.subscriptionCheckPending = false
            self.savedCheckPending = false
            self.unconfirmedSavedInvalidations = SavedWorkshopInvalidations()
            self.confirmedSavedInvalidations = SavedWorkshopInvalidations()
            self.readySavedIDs.removeAll()
            self.lastSavedCheck = -900
            self.onSubscriptionsChanged?(nil)
            self.accountMutations.cancelAll(with: .unconfirmed("steam-session-invalidated: Steam 会话已变化；账号请求结果未确认，请刷新订阅状态后再决定是否重试。"))
        }
        monitor.onContentInvalidated = { [weak self] event in self?.receiveSteamContentInvalidation(event) }
        return monitor
    }()
    private var timer: Timer?
    private var process: Process?
    private var itemID: String?
    private var selectedProject: URL?
    private var knownManifests: [String: String] = [:]
    private var automatic = UserDefaults.standard.object(forKey: "automaticallyUpdateLibrary") as? Bool ?? true
    private var busy = false
    private var stopped = false
    private var selectionGeneration = 0
    private var libraryCheckPending = false
    private var subscriptionCheckPending = false
    private var savedCheckPending = false
    private var lastSavedCheck: TimeInterval = -900
    private var unconfirmedSavedInvalidations = SavedWorkshopInvalidations()
    private var confirmedSavedInvalidations = SavedWorkshopInvalidations()
    private var readySavedIDs = Set<String>()
    private var savingPermits: [UUID: SavedWorkshopCommitPermit] = [:]
    /// Captures the authorization class at the save boundary. `activeTransfer`
    /// can later be promoted by an explicit manual retry, so its mutable
    /// request record cannot decide whether a live pointer permit is automatic.
    private var automaticSavingPermitItems: [UUID: String] = [:]
    private var pending: [DownloadRequest] = []
    private var activeTransfer: DownloadRequest?
    private var transferEntries: [UUID: WorkshopTransferEntry] = [:]
    private var transferRequests: [UUID: DownloadRequest] = [:]
    private var suppressedAutomatic = Set<String>()
    private var transfersPaused = UserDefaults.standard.bool(forKey: "workshopTransfersPaused")
    private var transferNotificationQueued = false
    private let transferJournalURL: URL
    private var transferPersistenceDirty = false
    private var transferJournalBlocked = false
    private var transferPersistenceIssue: String?
    private var transferRecoveryNotice = ""
    private var helperActivity = ""
    private var pendingBrowse: BrowseRequest?
    private struct BrowseRequest {
        let request: WorkshopBrowseRequest
        let completion: (WorkshopBrowsePage?, String?) -> Void
    }
    private enum SubscriptionSnapshotOutcome {
        case confirmed(items: [SteamSubscription], account: WorkshopSubscriptionAccount,
                       favorites: Set<String>?, connectionEpoch: UInt64, authorizationGeneration: UInt64)
        case unconfirmed(String)
    }
    private struct DownloadRequest {
        var token = UUID()
        let id: String
        let project: URL?
        let apply: Bool
        let generation: Int
        let knownOutdated: Bool
        let automatic: Bool
        var retainCopy = false
        var restored = false
        /// `nil` is only valid before `queueRequest` normalizes an automatic
        /// request. Manual requests deliberately have no subscription lease.
        var automaticAuthorizationGeneration: UInt64? = nil
        var key: String { id + "|" + (project?.path ?? "any-library") }
    }
    private(set) lazy var automaticMenu = NSMenuItem(title: "自动同步订阅和已保存壁纸", action: #selector(toggleAutomatic), keyEquivalent: "")

    init(transferJournalURL: URL = WorkshopTransferJournal.url) {
        self.transferJournalURL = transferJournalURL
        super.init()
        restoreTransfers()
    }

    private static func validID(_ text: String) -> Bool { SteamLibraryIndex.validID(text) }
    /// Do not accept JSON numeric 0/1 as a protocol Boolean. Foundation
    /// bridges `NSNumber(1)` to `Bool`, which is unsafe at an account-state
    /// confirmation boundary.
    private static func exactJSONBoolean(_ value: Any?, equals expected: Bool) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
        return number.boolValue == expected
    }
    private static func exactJSONBooleanValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func exactJSONInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw.rounded(.towardZero) == raw,
              let integer = Int(exactly: raw) else { return nil }
        return integer
    }
    /// Steam helper JSON has to be canonical before its IDs may be used for a
    /// snapshot membership decision. This also rejects numeric pseudo-bools
    /// for the fields that authorize automatic work.
    private static func normalizedSubscription(_ object: [String: Any]) -> [String: Any]? {
        guard let rawID = object["workshop_id"] as? String,
              let id = WorkshopSubscriptionChangeRequest(workshopID: rawID, subscribed: true)?.workshopID,
              let enabled = exactJSONBooleanValue(object["enabled"]),
              let needsDownload = exactJSONBooleanValue(object["needs_download"]),
              let state = exactJSONInteger(object["state"]), (0...Int(UInt32.max)).contains(state),
              let consumerAppID = exactJSONInteger(object["consumer_app_id"]), (0...Int(UInt32.max)).contains(consumerAppID),
              let result = exactJSONInteger(object["result"]) else { return nil }
        var normalized = object
        normalized["workshop_id"] = id
        normalized["enabled"] = enabled
        normalized["needs_download"] = needsDownload
        normalized["state"] = UInt32(state)
        normalized["consumer_app_id"] = UInt32(consumerAppID)
        normalized["result"] = result
        return normalized
    }

    /// Drop presentation state without deleting a saved copy or changing the
    /// selected desktop. `invalidateAutomatic` is only used when a confirmed
    /// account write or account identity failure makes active automatic work
    /// unsafe; it preserves postreview's bounded retry set.
    private func invalidateSubscriptionPresentation(_ reason: String, invalidateAutomatic: Bool) {
        if invalidateAutomatic { invalidateAutomaticAuthorization() }
        subscriptionAccount = nil
        subscriptionSnapshotConnectionEpoch = nil
        subscriptionSnapshotAuthorizationGeneration = nil
        favoriteSnapshotConnectionEpoch = nil
        favoriteSnapshotAuthorizationGeneration = nil
        subscriptions = nil; onSubscriptionsChanged?(nil)
        favoriteIDs = nil; onFavoritesChanged?(nil)
        invalidateUserVotePresentation(reason: reason)
        removeAutomaticTasks(reason: reason)
    }

    /// Retire personal-vote presentation independently from any public browse
    /// metadata.  Pending reads are settled exactly once as unconfirmed; a
    /// late helper completion sees no active token and becomes inert.  This is
    /// deliberately not used for an ordinary selection change: changing the
    /// page must not cancel a user-authorized remote `vote-set`.
    private func invalidateUserVotePresentation(reason: String) {
        let active = activeUserVoteRead
        let pending = pendingUserVoteReads
        activeUserVoteRead = nil
        pendingUserVoteReads.removeAll()
        if let active { active.completion(.unconfirmed(reason)) }
        pending.forEach { $0.completion(.unconfirmed(reason)) }
        onUserVotesInvalidated?()
    }
    private static func approvedProject(_ path: String, id: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard SteamLibraryIndex.location(for: url, id: id) != nil else { return nil }
        return url.resolvingSymlinksInPath()
    }
    private static func restoredProject(_ path: String, id: String) -> URL? {
        let url = URL(fileURLWithPath: path)
        if let record = SavedWorkshopStore.recordForProject(url), record.id == id { return record.project }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return approvedProject(path, id: id)
    }
    private func restoreTransfers() {
        do {
            guard let saved = try WorkshopTransferJournal.load(from: transferJournalURL) else { return }
            for record in saved.records {
                var entry = record.entry
                let source = record.sourcePath.flatMap { Self.restoredProject($0, id: record.workshopID) }
                let result = record.resultPath.flatMap { Self.restoredProject($0, id: record.workshopID) }
                entry.project = nil
                if !entry.phase.terminal {
                    if entry.automatic {
                        entry.phase = .interrupted
                        entry.detail = "上次自动检查已中断；连接 Steam 后会重新确认订阅与版本，并生成当前需要的任务。"
                    } else if record.sourcePath != nil && source == nil {
                        entry.phase = .failed
                        entry.detail = "上次使用的项目位置已不可用。可重试按工坊 ID 获取，当前壁纸保持不变。"
                    } else {
                        entry.phase = .queued
                        entry.detail = "从上次任务恢复，将重新确认 Steam 版本；完成后可主动设为默认壁纸。"
                    }
                } else if entry.phase == .completed {
                    if let result { entry.project = result }
                    else {
                        entry.phase = .failed
                        entry.detail = "历史获取曾完成，但本机项目位置已不可用；可重新获取。"
                    }
                }
                transferEntries[entry.id] = entry
                transferRequests[entry.id] = DownloadRequest(token: entry.id, id: entry.workshopID, project: source,
                    apply: false, generation: -1, knownOutdated: false, automatic: entry.automatic,
                    retainCopy: record.retainCopy, restored: true)
            }
            pending = saved.queue.compactMap { token in
                guard transferEntries[token]?.phase == .queued, let request = transferRequests[token], !request.automatic else { return nil }
                return request
            }
            pruneFinishedTransfers()
            transferRecoveryNotice = "已恢复 \(pending.count) 个手动任务和 \(transferEntries.count - pending.count) 条处理记录；恢复任务会重新确认版本，不会自动改选壁纸。"
        } catch {
            transferJournalBlocked = true
            transferPersistenceIssue = "旧任务记录无法读取，未覆盖原记录。本次任务仍可处理；点“重试保存记录”将保存当前列表。"
        }
    }
    private func pruneFinishedTransfers() {
        let terminal = transferEntries.values.filter { $0.phase.terminal && $0.id != activeTransfer?.token }.sorted { $0.updatedAt > $1.updatedAt }
        for item in terminal.dropFirst(100) { transferEntries[item.id] = nil; transferRequests[item.id] = nil }
    }
    private func persistTransfers() {
        transferPersistenceDirty = false
        guard !transferJournalBlocked else { return }
        pruneFinishedTransfers()
        let records = transferEntries.values.sorted { $0.id.uuidString < $1.id.uuidString }.map { entry in
            let request = transferRequests[entry.id]
            return WorkshopTransferJournal.Record(entry: entry, sourceProject: request?.project,
                retainCopy: request?.apply == true || request?.retainCopy == true)
        }
        var order = pending.map(\.token)
        if let active = activeTransfer, transferEntries[active.token]?.phase.terminal == false { order.insert(active.token, at: 0) }
        do {
            try WorkshopTransferJournal.save(.init(records: records, queue: order), to: transferJournalURL)
            transferPersistenceIssue = nil
        } catch {
            transferPersistenceIssue = "任务记录暂未保存，退出后可能无法恢复最新操作。当前队列仍可处理；可重试保存记录。"
        }
    }
    func retrySavingTransfers() {
        guard !stopped else { return }
        transferJournalBlocked = false
        persistTransfers()
        notifyTransfers(persist: false)
    }

    var transferSnapshot: WorkshopTransferSnapshot {
        let positions = Dictionary(pending.enumerated().map { ($0.element.token, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let entries = transferEntries.values.sorted { a, b in
            if a.id == activeTransfer?.token { return b.id != a.id }
            if b.id == activeTransfer?.token { return false }
            if let pa = positions[a.id], let pb = positions[b.id] { return pa < pb }
            if positions[a.id] != nil { return true }
            if positions[b.id] != nil { return false }
            return a.updatedAt > b.updatedAt
        }
        return WorkshopTransferSnapshot(entries: entries, paused: transfersPaused, activity: helperActivity, connection: connectionDescription,
            recoveryNotice: transferRecoveryNotice, persistenceIssue: transferPersistenceIssue)
    }
    private func notifyTransfers(persist: Bool = true) {
        guard !stopped else { return }
        if persist { transferPersistenceDirty = true }
        guard !transferNotificationQueued else { return }
        transferNotificationQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.transferNotificationQueued = false
            guard !self.stopped else { return }
            self.pruneFinishedTransfers()
            if self.transferPersistenceDirty { self.persistTransfers() }
            self.onTransfersChanged?(self.transferSnapshot)
        }
    }
    @discardableResult private func queueRequest(_ proposed: DownloadRequest) -> Bool {
        guard !stopped, !(proposed.automatic && suppressedAutomatic.contains(proposed.id)) else { return false }
        var request = proposed
        if request.automatic, request.automaticAuthorizationGeneration == nil {
            request.automaticAuthorizationGeneration = automaticAuthorizationGeneration
        }
        if let active = activeTransfer, active.key == request.key, transferEntries[active.token]?.phase.terminal == false {
            guard !request.automatic else { return false }
            if !active.apply || request.apply {
                request.token = active.token; activeTransfer = request; transferRequests[request.token] = request
                transferEntries[request.token]?.automatic = false
            }
            notifyTransfers(); return true
        }
        if let index = pending.firstIndex(where: { $0.key == request.key }) {
            guard !request.automatic else { return false }
            if !pending[index].apply || request.apply {
                request.token = pending[index].token; pending[index] = request; transferRequests[request.token] = request
                transferEntries[request.token]?.automatic = false
            }
            notifyTransfers(); return true
        }
        guard pending.count < 1000 else { return false }
        let title = subscriptions?.first(where: { $0.id == request.id })?.title ?? SavedWorkshopStore.current(request.id)?.title ?? "工坊壁纸"
        transferEntries[request.token] = WorkshopTransferEntry(id: request.token, workshopID: request.id, title: String(title.prefix(500)), automatic: request.automatic)
        transferRequests[request.token] = request
        if request.automatic { pending.append(request) }
        else { pending.insert(request, at: pending.firstIndex(where: \.automatic) ?? pending.count); suppressedAutomatic.remove(request.id) }
        notifyTransfers(); return true
    }
    private func removeAutomaticTasks(reason: String, matching: (DownloadRequest) -> Bool = { _ in true }) {
        let removed = pending.filter { $0.automatic && matching($0) }
        let ids = Set(removed.map(\.token)); pending.removeAll { ids.contains($0.token) }
        for request in removed { finishTransfer(request.token, phase: .cancelled, detail: reason) }
    }

    /// Manual requests are explicitly initiated by the user and do not borrow
    /// a subscription lease. Automatic work must still match the latest known
    /// enabled/available snapshot and must not predate a 3418 list change.
    private func automaticRequestAuthorized(_ request: DownloadRequest) -> Bool {
        guard request.automatic else { return true }
        guard automatic, eventMonitor.isConnected,
              request.automaticAuthorizationGeneration == automaticAuthorizationGeneration,
              let subscriptions else { return false }
        return subscriptions.contains { $0.id == request.id && $0.enabled && $0.available }
    }

    /// 3418 is the one callback that establishes that the subscription list
    /// itself may have changed. Retire automatic work immediately, rather than
    /// waiting for a serialized `subscriptions` helper request to finish.
    /// A permit already at the pointer boundary is cancelled under the same
    /// lock as the pointer publication; a completed pointer is kept immutable
    /// but later UI/player publication is rejected by the generation checks.
    private func invalidateAutomaticAuthorization() {
        // Capture exactly the automatic work that existed when Steam said its
        // subscription list changed. A later consistent snapshot decides which
        // of these may retry; unrelated saved copies are never swept in.
        var affected = Array(pending.lazy.filter(\.automatic).map(\.id))
        if let active = activeTransfer, active.automatic { affected.append(active.id) }
        affected.append(contentsOf: automaticSavingPermitItems.values)
        for id in affected where automaticRetryIDsAwaitingSnapshot.count < Self.maximumAutomaticAuthorizationRetries {
            automaticRetryIDsAwaitingSnapshot.insert(id)
        }
        automaticAuthorizationGeneration &+= 1
        for (token, permit) in savingPermits where automaticSavingPermitItems[token] != nil {
            permit.cancel()
        }
    }
    private func updateTransfer(_ token: UUID, phase: WorkshopTransferEntry.Phase, detail: String) {
        guard var entry = transferEntries[token], !entry.phase.terminal else { return }
        entry.phase = phase; entry.detail = String(detail.prefix(1400)); entry.updatedAt = Date()
        if phase != .downloading { entry.downloaded = nil; entry.total = nil }
        transferEntries[token] = entry; notifyTransfers()
    }
    private func finishTransfer(_ token: UUID, phase: WorkshopTransferEntry.Phase, detail: String, project: URL? = nil, title: String? = nil) {
        updateTransfer(token, phase: phase, detail: detail)
        if transferEntries[token]?.phase == .completed {
            transferEntries[token]?.project = project
            if let title { transferEntries[token]?.title = String(title.prefix(500)) }
        }
        if activeTransfer?.token == token { activeTransfer = nil }
        notifyTransfers()
    }
    private func receiveProgress(_ event: SteamDownloadProgress, token: UUID) {
        guard activeTransfer?.token == token, var entry = transferEntries[token], !entry.phase.terminal else { return }
        let previousPhase = entry.phase
        switch event.phase {
        case .checking: entry.phase = .checking; entry.detail = "正在确认可访问内容和远程版本。"
        case .downloading: entry.phase = .downloading; entry.detail = "通过官方 Steam 下载，字节进度不代表已确认安装。"
        case .confirming: entry.phase = .confirming; entry.detail = "Steam 已返回下载结果，正在核对本机安装记录。"
        }
        entry.downloaded = event.downloaded; entry.total = event.total; entry.updatedAt = Date()
        transferEntries[token] = entry; notifyTransfers(persist: previousPhase != entry.phase)
    }
    func toggleTransferPause() {
        transfersPaused.toggle(); UserDefaults.standard.set(transfersPaused, forKey: "workshopTransfersPaused")
        notifyTransfers(); pump()
    }
    func stopTransfer(_ token: UUID) {
        guard let request = transferRequests[token], let entry = transferEntries[token], !entry.phase.terminal, entry.phase != .saving else { return }
        suppressedAutomatic.insert(request.id)
        if let index = pending.firstIndex(where: { $0.token == token }) {
            pending.remove(at: index)
            finishTransfer(token, phase: .cancelled, detail: "已从队列移除。本次运行不再自动排入同一壁纸；可主动重试。")
        } else if activeTransfer?.token == token {
            updateTransfer(token, phase: .cancelled, detail: "已停止本次处理和自动打开。Steam 客户端可能继续下载；已经完成的本机副本会保留。")
            if let process, process.isRunning { process.terminate() }
        }
        removeAutomaticTasks(reason: "本次运行已停止此壁纸的自动任务；可主动重试。") { $0.id == request.id }
        notifyTransfers(); pump()
    }
    func retryTransfer(_ token: UUID) {
        guard let previous = transferRequests[token], let entry = transferEntries[token], [.failed, .cancelled, .interrupted].contains(entry.phase) else { return }
        // Retrying an older request never selects a different wallpaper.
        enqueue(id: previous.id, project: previous.project, apply: false, knownOutdated: false, automatic: false, retainCopy: previous.retainCopy)
    }
    func openTransfer(_ token: UUID) {
        guard let entry = transferEntries[token], entry.phase == .completed, let project = entry.project else { return }
        beginSelection(); onProjectReady?(project)
    }
    func clearFinishedTransfers() {
        let ids = transferEntries.values.filter { $0.phase.terminal && $0.id != activeTransfer?.token }.map(\.id)
        for id in ids { transferEntries[id] = nil; transferRequests[id] = nil }
        notifyTransfers()
    }

    func menuItems() -> [NSMenuItem] {
        let download = NSMenuItem(title: "从创意工坊链接下载…", action: #selector(enterItem), keyEquivalent: "d")
        let refresh = NSMenuItem(title: "检查默认壁纸更新", action: #selector(refreshCurrent), keyEquivalent: "")
        let library = NSMenuItem(title: "检查本地壁纸库更新", action: #selector(requestLibraryCheck), keyEquivalent: "")
        let subscriptions = NSMenuItem(title: "同步我的 Steam 订阅", action: #selector(requestSubscriptionCheck), keyEquivalent: "")
        for item in [download, refresh, library, subscriptions, automaticMenu] { item.target = self }
        automaticMenu.state = automatic ? .on : .off
        if libraryWatcher == nil {
            let watcher = SteamLibraryWatcher { [weak self] hint in
                guard let self else { return }
                self.onLibraryChanged?()
                self.localInstallationChanged(hint)
            }
            libraryWatcher = watcher
            watcher.start()
        }
        eventMonitor.configure(automatic: automatic)
        schedule()
        pump()
        return [download, refresh, library, subscriptions, automaticMenu]
    }

    func track(project: URL) {
        let candidate = project.deletingLastPathComponent().lastPathComponent
        let canonical = project.standardizedFileURL.resolvingSymlinksInPath()
        let selected = SavedWorkshopStore.recordForProject(project)?.id
            ?? (SteamLibraryIndex.location(for: project, id: candidate) != nil ? candidate : nil)
        if itemID != selected || selectedProject != canonical { selectionGeneration += 1 }
        selectedProject = canonical
        itemID = selected
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard !stopped else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.libraryWatcher?.refreshLocations()
                self?.onLibraryChanged?()
                self?.scheduleReconcile()
                self?.pump()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func toggleAutomatic() {
        automatic.toggle()
        UserDefaults.standard.set(automatic, forKey: "automaticallyUpdateLibrary")
        automaticMenu.state = automatic ? .on : .off
        if !automatic {
            libraryCheckPending = false
            subscriptionCheckPending = false
            savedCheckPending = false
            removeAutomaticTasks(reason: "自动同步已关闭，尚未开始的自动任务已移除。")
        }
        else { suppressedAutomatic.removeAll() }
        reconcileTask?.cancel(); reconcileTask = nil
        eventMonitor.configure(automatic: automatic)
        schedule()
    }

    /// A 3418 list-change callback revokes account-authorized UI state even
    /// when automatic download monitoring is disabled. The callback has no
    /// item identity and does not prove installation, but it does prove that
    /// the full subscription/favorite snapshot used by visible controls can
    /// no longer authorize a write. Keep local wallpapers untouched; only
    /// drop account presentation and settle queued account mutations.
    private func receiveSteamContentInvalidation(_ event: SteamEvent?) {
        if let event, event.kind == "invalidated", event.callbacks.contains(3418) {
            invalidateAutomaticAuthorization()
            invalidateSubscriptionPresentation("Steam 订阅列表已变化，账号状态等待重新确认。", invalidateAutomatic: false)
            accountMutations.cancelAll(with: .unconfirmed("steam-subscription-state-unconfirmed: Steam 订阅列表已变化；账号请求结果未确认，请刷新订阅状态后再决定是否重试。"))
            onStatus?("Steam 订阅列表已变化，请同步以确认账号状态。")
        }
        scheduleReconcile(event)
    }

    /// All asynchronous notices pass this barrier. Queries precede automatic
    /// downloads, and notices during a query schedule another confirmation pass.
    private func scheduleReconcile(_ event: SteamEvent? = nil) {
        guard !stopped, automatic, eventMonitor.isConnected else { return }
        if let event, event.kind == "invalidated" {
            if event.callbacks.contains(where: { $0 == 3405 || $0 == 3406 }) {
                unconfirmedSavedInvalidations.merge(ids: Set(event.item_ids), full: event.full_reconcile)
            }
        }
        guard reconcileTask == nil else { return }
        let delay = max(0.5, 5 - (ProcessInfo.processInfo.systemUptime - lastReconcile))
        let task = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileTask = nil
                guard !self.stopped, self.automatic, self.eventMonitor.isConnected else { return }
                self.lastReconcile = ProcessInfo.processInfo.systemUptime
                self.subscriptionCheckPending = true; self.libraryCheckPending = true
                if ProcessInfo.processInfo.systemUptime - self.lastSavedCheck >= 900 { self.savedCheckPending = true }
                self.pump()
            }
        }
        reconcileTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    /// FSEvents do not establish that Steam finished writing a project.  Keep
    /// their bounded item/full indication alongside event-monitor hints until a
    /// fresh, internally consistent subscription snapshot arrives.  `pump()`
    /// subsequently uses the existing `refresh` receipt and saved-store
    /// expected-manifest transaction before a new immutable copy can publish.
    private func localInstallationChanged(_ hint: SteamLibraryChangeHint) {
        guard !stopped else { return }
        unconfirmedSavedInvalidations.merge(ids: hint.itemIDs, full: hint.fullReconcile)
        scheduleReconcile()
    }

    /// A session loss may leave a safely copied immutable directory, but cannot
    /// be allowed to race the small `current.json` publication transaction.
    private func cancelSavingPermits() {
        for permit in savingPermits.values { permit.cancel() }
        savingPermits.removeAll()
        automaticSavingPermitItems.removeAll()
        automaticRetryIDsAwaitingSnapshot.removeAll()
    }

    @objc func enterItem() {
        let alert = NSAlert()
        alert.messageText = "下载创意工坊壁纸"
        alert.informativeText = "粘贴 Wallpaper Engine 创意工坊链接或条目 ID。下载通过你已登录的 Steam 完成；当前原生引擎支持的格式会直接打开。"
        alert.addButton(withTitle: "下载"); alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 440, height: 25))
        field.placeholderString = "https://steamcommunity.com/sharedfiles/filedetails/?id=…"
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let input = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: String?
        if Self.validID(input) { id = input }
        else if let components = URLComponents(string: input), components.host?.lowercased() == "steamcommunity.com", ["https", "http"].contains(components.scheme?.lowercased() ?? "") {
            id = components.queryItems?.first(where: { $0.name == "id" })?.value
        } else { id = nil }
        guard let id, Self.validID(id) else { onStatus?("请输入有效的 Steam 创意工坊链接或数字 ID"); return }
        beginSelection()
        enqueue(id: id, apply: true, knownOutdated: false, automatic: false)
    }

    @objc private func refreshCurrent() {
        guard let itemID else { onStatus?("当前项目没有可更新的创意工坊 ID"); return }
        enqueue(id: itemID, project: selectedProject, apply: false, knownOutdated: false, automatic: false)
    }

    @objc private func requestLibraryCheck() {
        guard !stopped else { return }
        libraryCheckPending = true
        savedCheckPending = true
        pump()
    }

    @objc func requestSubscriptionCheck() {
        guard !stopped else { return }
        subscriptionCheckPending = true
        pump()
    }

    /// Called only by the injected browser action. This creates no transfer
    /// request and never infers account state from a public browse row. The
    /// completion is deliberately held until a post-write, same-account full
    /// snapshot converges.
    func requestSubscriptionChange(id: String, subscribed: Bool,
                                   completion: @escaping (WorkshopSubscriptionChangeResult) -> Void) {
        guard !stopped else {
            completion(.unconfirmed("steam-subscription-stopped: 应用正在退出；订阅请求结果未确认，请刷新订阅状态后再决定是否重试。"))
            return
        }
        guard let request = WorkshopSubscriptionChangeRequest(workshopID: id, subscribed: subscribed) else {
            completion(.failed("steam-subscription-invalid-id: 创意工坊条目 ID 无效。"))
            return
        }
        // The action is tied to one complete canonical snapshot, never to a
        // browse response, a cached card flag, or a callback handle.
        guard subscriptions != nil, let account = subscriptionAccount,
              subscriptionSnapshotConnectionEpoch == connectionEpoch,
              subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration else {
            completion(.unconfirmed("steam-subscription-state-unconfirmed: 当前 Steam 订阅状态未确认，请先同步订阅后再操作。"))
            return
        }
        switch accountMutations.enqueue(.subscription(request), account: account, connectionEpoch: connectionEpoch,
                                        authorizationGeneration: automaticAuthorizationGeneration,
                                        completion: { resolution in
            switch resolution {
            case .confirmed: completion(.confirmed)
            case .confirmedUserVote:
                completion(.unconfirmed("steam-subscription-state-unconfirmed: 收到不属于订阅请求的账号确认回执。"))
            case .failed(let reason): completion(.failed(reason))
            case .unconfirmed(let reason): completion(.unconfirmed(reason))
            }
        }) {
        case .enqueued:
            pump()
        case .duplicate:
            completion(.failed("steam-subscription-change-pending: 此创意工坊条目的订阅操作正在等待 Steam 确认。"))
        }
    }

    /// Called only by an explicit favorite/unfavorite click in the injected
    /// browser. A complete, fresh favorites snapshot is required before the
    /// helper can write: public card metadata and a cached favorites result
    /// never authorize an account mutation.
    func requestFavoriteChange(id: String, favorited: Bool,
                               completion: @escaping (WorkshopFavoriteChangeResult) -> Void) {
        guard !stopped else {
            completion(.unconfirmed("steam-favorite-stopped: 应用正在退出；收藏请求结果未确认，请刷新订阅状态后再决定是否重试。"))
            return
        }
        guard let request = WorkshopFavoriteChangeRequest(workshopID: id, favorited: favorited) else {
            completion(.failed("steam-favorite-invalid-id: 创意工坊条目 ID 无效。"))
            return
        }
        guard subscriptions != nil, favoriteIDs != nil, let account = subscriptionAccount,
              subscriptionSnapshotConnectionEpoch == connectionEpoch,
              subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration,
              favoriteSnapshotConnectionEpoch == connectionEpoch,
              favoriteSnapshotAuthorizationGeneration == automaticAuthorizationGeneration else {
            completion(.unconfirmed("steam-favorite-state-unconfirmed: 当前 Steam 收藏状态未确认，请先同步订阅后再操作。"))
            return
        }
        switch accountMutations.enqueue(.favorite(request), account: account, connectionEpoch: connectionEpoch,
                                        authorizationGeneration: automaticAuthorizationGeneration,
                                        completion: { resolution in
            switch resolution {
            case .confirmed: completion(.confirmed)
            case .confirmedUserVote:
                completion(.unconfirmed("steam-favorite-state-unconfirmed: 收到不属于收藏请求的账号确认回执。"))
            case .failed(let reason): completion(.failed(reason))
            case .unconfirmed(let reason): completion(.unconfirmed(reason))
            }
        }) {
        case .enqueued:
            pump()
        case .duplicate:
            completion(.failed("steam-favorite-change-pending: 此创意工坊条目的账号操作正在等待 Steam 确认。"))
        }
    }

    /// Fetches the current account's personal vote for the browser's current
    /// detail selection.  This is read-only: it neither creates a mutation
    /// queue entry nor infers anything from public aggregate vote counts.
    /// The opaque `selectionGeneration` is echoed to the caller and must be
    /// compared by the browser before it changes a selected-detail control.
    func requestUserVoteRefresh(id: String, selectionGeneration: UInt64,
                                completion: @escaping (WorkshopUserVoteReadResult) -> Void) {
        guard !stopped else {
            completion(.unconfirmed("steam-vote-get-stopped: 应用正在退出；个人投票读取未确认。"))
            return
        }
        guard let request = WorkshopUserVoteReadRequest(workshopID: id, selectionGeneration: selectionGeneration) else {
            completion(.failed("steam-vote-get-invalid-id: 创意工坊条目 ID 无效。"))
            return
        }
        guard subscriptions != nil, let account = subscriptionAccount,
              subscriptionSnapshotConnectionEpoch == connectionEpoch,
              subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration else {
            completion(.unconfirmed("steam-vote-get-state-unconfirmed: 当前 Steam 账号状态未确认，请先同步订阅后再读取个人投票。"))
            return
        }
        // A queued read for an older selected detail must not later contact
        // Steam merely because the page has already moved on. An in-flight
        // helper cannot safely be killed here; its echoed generation makes its
        // eventual UI completion inert instead.
        let obsolete = pendingUserVoteReads.filter { $0.request.selectionGeneration < selectionGeneration }
        pendingUserVoteReads.removeAll { $0.request.selectionGeneration < selectionGeneration }
        obsolete.forEach { $0.completion(.unconfirmed("steam-vote-get-selection-superseded: 创意工坊选择已变化；旧个人投票读取未采用。")) }
        pendingUserVoteReads.append(UserVoteReadWork(token: UUID(), request: request, account: account,
                                                     connectionEpoch: connectionEpoch,
                                                     authorizationGeneration: automaticAuthorizationGeneration,
                                                     completion: completion))
        pump()
    }

    /// Starts only after an explicit up/down click. It uses the same global
    /// FIFO and canonical-ID reservation as subscribe/unsubscribe/favorite.
    /// There is no optimistic presentation: success is delivered only after
    /// the exact SetUserItemVote callback and a fresh same-account vote-get
    /// reports the requested up/down state.
    func requestUserVoteChange(id: String, direction: WorkshopUserVoteDirection, selectionGeneration: UInt64,
                               completion: @escaping (WorkshopUserVoteChangeResult) -> Void) {
        guard !stopped else {
            completion(.unconfirmed("steam-vote-set-stopped: 应用正在退出；个人投票请求结果未确认，不会自动重试。"))
            return
        }
        guard let request = WorkshopUserVoteChangeRequest(workshopID: id, direction: direction) else {
            completion(.failed("steam-vote-set-invalid-id: 创意工坊条目 ID 无效。"))
            return
        }
        // A vote is an account mutation. Use the complete fresh subscription
        // and favorites envelopes shared by the existing account writes; a
        // browser card or an old vote read never supplies write authority.
        guard subscriptions != nil, favoriteIDs != nil, let account = subscriptionAccount,
              subscriptionSnapshotConnectionEpoch == connectionEpoch,
              subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration,
              favoriteSnapshotConnectionEpoch == connectionEpoch,
              favoriteSnapshotAuthorizationGeneration == automaticAuthorizationGeneration else {
            completion(.unconfirmed("steam-vote-set-state-unconfirmed: 当前 Steam 收藏/订阅状态未确认，请先同步订阅后再操作。"))
            return
        }
        switch accountMutations.enqueue(.userVote(request), account: account, connectionEpoch: connectionEpoch,
                                        authorizationGeneration: automaticAuthorizationGeneration,
                                        selectionGeneration: selectionGeneration,
                                        completion: { resolution in
            switch resolution {
            case .confirmedUserVote(let receipt): completion(.confirmed(receipt))
            case .confirmed:
                completion(.unconfirmed("steam-vote-set-unconfirmed: 个人投票确认缺少读取回执。"))
            case .failed(let reason): completion(.failed(reason))
            case .unconfirmed(let reason): completion(.unconfirmed(reason))
            }
        }) {
        case .enqueued:
            // Keep the previously confirmed display while its controls are
            // disabled.  Broadcasting the session-invalidating callback here
            // would clear the Browser's pending token and incorrectly make
            // this explicit write completion inert. No local vote value is
            // changed; only the fresh post-write read may change it.
            pump()
        case .duplicate:
            completion(.failed("steam-vote-set-pending: 此创意工坊条目的账号操作正在等待 Steam 确认。"))
        }
    }

    func downloadAndOpen(_ id: String) {
        guard Self.validID(id), !stopped else { return }
        beginSelection()
        enqueue(id: id, apply: true, knownOutdated: false, automatic: false)
    }

    /// Invalidate a pending apply as soon as a newer user selection starts.
    func beginSelection() { selectionGeneration += 1 }

    func browse(_ request: WorkshopBrowseRequest, completion: @escaping (WorkshopBrowsePage?, String?) -> Void) {
        guard !stopped else { completion(nil, "应用正在退出"); return }
        pendingBrowse?.completion(nil, "已被新的搜索替换")
        pendingBrowse = BrowseRequest(request: request, completion: completion)
        pump()
    }

    private func enqueue(id: String, project: URL? = nil, apply: Bool, knownOutdated: Bool, automatic: Bool, retainCopy: Bool = false) {
        guard Self.validID(id), !stopped else { return }
        let request = DownloadRequest(id: id, project: project, apply: apply, generation: selectionGeneration, knownOutdated: knownOutdated, automatic: automatic, retainCopy: retainCopy || apply)
        guard queueRequest(request) else { onStatus?("本次请求未加入队列，请检查已有任务或稍后重试"); return }
        if !automatic {
            let token = activeTransfer.flatMap { $0.key == request.key && transferEntries[$0.token]?.phase.terminal == false ? $0.token : nil }
                ?? pending.first(where: { $0.key == request.key })?.token
            if let token { onTransferRequested?(token) }
        }
        if busy && apply { onStatus?("下载已加入队列，将在当前 Steam 请求结束后开始") }
        pump()
    }

    /// Starts the one helper invocation for an already fenced explicit write.
    /// The work remains active through the nested subscriptions snapshot; no
    /// later mutation can begin while Steam's resulting account state is
    /// still unknown.
    private func performSubscriptionChange(_ work: WorkshopAccountMutationQueue.Work) {
        guard case .subscription(let request) = work.request else { return }
        let replacementSnapshotTrusted = subscriptions != nil
            && subscriptionAccount == work.account
            && subscriptionSnapshotConnectionEpoch == connectionEpoch
            && subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration
        guard accountMutations.active?.token == work.token,
              work.connectionEpoch == connectionEpoch,
              work.authorizationGeneration == automaticAuthorizationGeneration,
              replacementSnapshotTrusted,
              eventMonitor.clientPID != nil else {
            // An older queued request may be stale while a later complete
            // same-account snapshot has already arrived. Preserve that newer
            // snapshot for the next fenced action; otherwise fail closed.
            if !replacementSnapshotTrusted {
                invalidateSubscriptionPresentation("Steam 订阅状态已变化，订阅操作未发送。", invalidateAutomatic: false)
                // The source snapshot has become unknown, so no queued
                // account write retains authorization. Settle the active and
                // every pending UI request exactly once without invoking a
                // second helper/FFI call; `pump` below may only continue
                // unrelated browse/transfer reconciliation.
                accountMutations.cancelAll(with: .unconfirmed("steam-subscription-state-unconfirmed: 写入前的 Steam 订阅快照、会话或授权代次已变化；请求未执行，请刷新订阅状态后再决定是否重试。"))
                DispatchQueue.main.async { [weak self] in self?.pump() }
                return
            }
            accountMutations.finish(work.token, with: .unconfirmed("steam-subscription-state-unconfirmed: 写入前的 Steam 订阅快照、会话或授权代次已变化；请求未执行，请刷新订阅状态后再决定是否重试。"))
            // `performSubscriptionChange` was entered by `pump()`, which
            // returns after this method. Drive the next fenced user action on
            // the following main-queue turn so a stale first work item cannot
            // strand later pending work or recurse through the completion.
            DispatchQueue.main.async { [weak self] in self?.pump() }
            return
        }
        onStatus?(request.desiredSubscribed ? "正在请求订阅 Steam 创意工坊条目…" : "正在请求取消订阅 Steam 创意工坊条目…")
        runHelper(request.helperArguments(expectedAccount: work.account), onDiscard: { [weak self] in
            guard let self else { return }
            self.invalidateSubscriptionPresentation("Steam 会话已变化，订阅状态等待重新确认。", invalidateAutomatic: false)
            self.accountMutations.finish(work.token, with: .unconfirmed("steam-session-invalidated: Steam 会话在订阅请求期间变化；结果未确认，请刷新订阅状态后再决定是否重试。"))
        }) { [weak self] result, success in
            guard let self, self.accountMutations.active?.token == work.token else { return }
            guard self.connectionEpoch == work.connectionEpoch,
                  self.automaticAuthorizationGeneration == work.authorizationGeneration,
                  self.subscriptionAccount == work.account else {
                self.invalidateSubscriptionPresentation("Steam 订阅状态已变化，订阅请求结果未采用。", invalidateAutomatic: false)
                self.accountMutations.finish(work.token, with: .unconfirmed("steam-subscription-state-unconfirmed: Steam 会话或订阅授权在请求期间变化；结果未确认，请刷新订阅状态后再决定是否重试。"))
                return
            }
            switch WorkshopSubscriptionChangeProtocol.parse(result, processExitedSuccessfully: success,
                                                            request: request, account: work.account) {
            case .failed(let reason):
                self.accountMutations.finish(work.token, with: .failed(reason))
            case .unconfirmed(let reason):
                // A timeout, malformed envelope, or A/B helper mismatch can
                // leave the remote state changed. Retire automatic leases and
                // visible membership; never resend this account write.
                self.invalidateSubscriptionPresentation("Steam 订阅请求结果未确认，自动任务等待新快照。", invalidateAutomatic: true)
                self.accountMutations.finish(work.token, with: .unconfirmed(reason))
            case .confirmed:
                // Steam confirmed the exact write, but that receipt is not a
                // subscription list. Treat current membership as stale and
                // take a new snapshot under a fresh authorization generation.
                self.invalidateAutomaticAuthorization()
                let postWriteGeneration = self.automaticAuthorizationGeneration
                self.invalidateSubscriptionPresentation("Steam 已确认订阅请求，正在重新确认订阅状态。", invalidateAutomatic: false)
                self.syncSubscriptions(expectedAccount: work.account,
                                       expectedConnectionEpoch: work.connectionEpoch,
                                       expectedAuthorizationGeneration: postWriteGeneration) { outcome in
                    guard self.accountMutations.active?.token == work.token else { return }
                    switch outcome {
                    case .confirmed(let items, let account, _, let epoch, let generation):
                        let all = Set(items.map(\.id))
                        let enabled = Set(items.filter(\.enabled).map(\.id))
                        guard epoch == work.connectionEpoch,
                              generation == postWriteGeneration,
                              generation == self.automaticAuthorizationGeneration,
                              account == work.account,
                              WorkshopSubscriptionChangeProtocol.snapshotConverged(allSubscriptionIDs: all,
                                                                                    enabledSubscriptionIDs: enabled,
                                                                                    accountID: account.id,
                                                                                    expectedAccount: work.account,
                                                                                    request: request) else {
                            self.accountMutations.finish(work.token, with: .unconfirmed("steam-subscription-state-unconfirmed: Steam 未在同一账号的完整订阅快照中确认请求目标；不会自动重试，请先同步订阅再决定是否重试。"))
                            return
                        }
                        self.accountMutations.finish(work.token, with: .confirmed)
                    case .unconfirmed(let reason):
                        self.accountMutations.finish(work.token, with: .unconfirmed(reason))
                    }
                }
            }
        }
    }

    /// Starts a fenced explicit add/remove favorite request. It intentionally
    /// shares `accountMutations` with subscriptions, and retains its active
    /// slot through the fresh post-write list check. This prevents a second
    /// Steam-account write from observing an in-between favorite state.
    private func performFavoriteChange(_ work: WorkshopAccountMutationQueue.Work) {
        guard case .favorite(let request) = work.request else { return }
        let replacementSnapshotTrusted = subscriptions != nil
            && favoriteIDs != nil
            && subscriptionAccount == work.account
            && subscriptionSnapshotConnectionEpoch == connectionEpoch
            && subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration
            && favoriteSnapshotConnectionEpoch == connectionEpoch
            && favoriteSnapshotAuthorizationGeneration == automaticAuthorizationGeneration
        guard accountMutations.active?.token == work.token,
              work.connectionEpoch == connectionEpoch,
              work.authorizationGeneration == automaticAuthorizationGeneration,
              replacementSnapshotTrusted,
              eventMonitor.clientPID != nil else {
            if !replacementSnapshotTrusted {
                invalidateSubscriptionPresentation("Steam 收藏状态已变化，收藏操作未发送。", invalidateAutomatic: false)
                accountMutations.cancelAll(with: .unconfirmed("steam-favorite-state-unconfirmed: 写入前的 Steam 收藏快照、会话或授权代次已变化；请求未执行，请刷新订阅状态后再决定是否重试。"))
                DispatchQueue.main.async { [weak self] in self?.pump() }
                return
            }
            accountMutations.finish(work.token, with: .unconfirmed("steam-favorite-state-unconfirmed: 写入前的 Steam 收藏快照、会话或授权代次已变化；请求未执行，请刷新订阅状态后再决定是否重试。"))
            DispatchQueue.main.async { [weak self] in self?.pump() }
            return
        }
        onStatus?(request.desiredFavorited ? "正在请求收藏 Steam 创意工坊条目…" : "正在请求取消收藏 Steam 创意工坊条目…")
        runHelper(request.helperArguments(expectedAccount: work.account), onDiscard: { [weak self] in
            guard let self else { return }
            self.invalidateSubscriptionPresentation("Steam 会话已变化，收藏状态等待重新确认。", invalidateAutomatic: false)
            self.accountMutations.finish(work.token, with: .unconfirmed("steam-session-invalidated: Steam 会话在收藏请求期间变化；结果未确认，请刷新订阅状态后再决定是否重试。"))
        }) { [weak self] result, success in
            guard let self, self.accountMutations.active?.token == work.token else { return }
            guard self.connectionEpoch == work.connectionEpoch,
                  self.automaticAuthorizationGeneration == work.authorizationGeneration,
                  self.subscriptionAccount == work.account else {
                self.invalidateSubscriptionPresentation("Steam 收藏状态已变化，收藏请求结果未采用。", invalidateAutomatic: false)
                self.accountMutations.finish(work.token, with: .unconfirmed("steam-favorite-state-unconfirmed: Steam 会话或收藏授权在请求期间变化；结果未确认，请刷新订阅状态后再决定是否重试。"))
                return
            }
            switch WorkshopFavoriteChangeProtocol.parse(result, processExitedSuccessfully: success,
                                                        request: request, account: work.account) {
            case .failed(let reason):
                self.accountMutations.finish(work.token, with: .failed(reason))
            case .unconfirmed(let reason):
                self.invalidateSubscriptionPresentation("Steam 收藏请求结果未确认，自动任务等待新快照。", invalidateAutomatic: true)
                self.accountMutations.finish(work.token, with: .unconfirmed(reason))
            case .confirmed:
                // The exact 3407 callback proves the account write only. A
                // query can still serve an old cached favorite set, so require
                // a newly fetched, non-cached complete list before confirming.
                self.invalidateAutomaticAuthorization()
                let postWriteGeneration = self.automaticAuthorizationGeneration
                self.invalidateSubscriptionPresentation("Steam 已确认收藏请求，正在重新确认收藏状态。", invalidateAutomatic: false)
                self.syncSubscriptions(expectedAccount: work.account,
                                       expectedConnectionEpoch: work.connectionEpoch,
                                       expectedAuthorizationGeneration: postWriteGeneration,
                                       deferFavoritePublication: true) { outcome in
                    guard self.accountMutations.active?.token == work.token else { return }
                    switch outcome {
                    case .confirmed(_, let account, let favorites, let epoch, let generation):
                        guard epoch == work.connectionEpoch,
                              generation == postWriteGeneration,
                              generation == self.automaticAuthorizationGeneration,
                              account == work.account,
                              WorkshopFavoriteChangeProtocol.snapshotConverged(favoriteIDs: favorites,
                                                                               accountID: account.id,
                                                                               expectedAccount: work.account,
                                                                               request: request) else {
                            // This deferred path has kept favorites hidden.
                            // Also clear subscriptions so no stale account
                            // envelope remains usable after an ambiguous
                            // remote favorite write.
                            self.invalidateSubscriptionPresentation("Steam 未在同一账号的新鲜收藏快照中确认请求目标。", invalidateAutomatic: false)
                            self.accountMutations.finish(work.token, with: .unconfirmed("steam-favorite-state-unconfirmed: Steam 未在同一账号的非缓存完整收藏快照中确认请求目标；不会自动重试，请先同步订阅再决定是否重试。"))
                            return
                        }
                        self.favoriteIDs = favorites
                        self.favoriteSnapshotConnectionEpoch = epoch
                        self.favoriteSnapshotAuthorizationGeneration = generation
                        self.onFavoritesChanged?(favorites)
                        self.accountMutations.finish(work.token, with: .confirmed)
                    case .unconfirmed(let reason):
                        self.accountMutations.finish(work.token, with: .unconfirmed(reason))
                    }
                }
            }
        }
    }

    /// Runs an explicit SetUserItemVote under the shared account FIFO.  The
    /// queue's active slot intentionally remains held through the nested
    /// `vote-get` below; another subscription/favorite/vote write must never
    /// observe the interval between the callback receipt and its fresh read.
    private func performUserVoteChange(_ work: WorkshopAccountMutationQueue.Work) {
        guard case .userVote(let request) = work.request,
              let selectionGeneration = work.selectionGeneration else {
            accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-unconfirmed: 个人投票请求缺少选择代次。"))
            DispatchQueue.main.async { [weak self] in self?.pump() }
            return
        }
        let trustedSource = subscriptions != nil
            && favoriteIDs != nil
            && subscriptionAccount == work.account
            && subscriptionSnapshotConnectionEpoch == connectionEpoch
            && subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration
            && favoriteSnapshotConnectionEpoch == connectionEpoch
            && favoriteSnapshotAuthorizationGeneration == automaticAuthorizationGeneration
        guard accountMutations.active?.token == work.token,
              work.connectionEpoch == connectionEpoch,
              work.authorizationGeneration == automaticAuthorizationGeneration,
              trustedSource,
              eventMonitor.clientPID != nil else {
            if !trustedSource {
                // Retire this completion before the hard UI invalidation so
                // the explicit click receives exactly one meaningful result.
                accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-state-unconfirmed: 写入前的 Steam 收藏/订阅快照、会话或授权代次已变化；请求未执行，不会自动重试。"))
                invalidateSubscriptionPresentation("Steam 账号状态已变化，个人投票未发送。", invalidateAutomatic: false)
            } else {
                accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-state-unconfirmed: 写入前的 Steam 会话或授权代次已变化；请求未执行，不会自动重试。"))
            }
            DispatchQueue.main.async { [weak self] in self?.pump() }
            return
        }
        onStatus?(request.direction == .up ? "正在请求给 Steam 创意工坊条目好评…" : "正在请求给 Steam 创意工坊条目点踩…")
        runHelper(request.helperArguments(expectedAccount: work.account), onDiscard: { [weak self] in
            guard let self else { return }
            guard self.accountMutations.active?.token == work.token else { return }
            self.accountMutations.finish(work.token, with: .unconfirmed("steam-session-invalidated: Steam 会话在个人投票请求期间变化；结果未确认，不会自动重试。"))
            self.invalidateSubscriptionPresentation("Steam 会话已变化，个人投票显示等待重新确认。", invalidateAutomatic: false)
        }) { [weak self] result, success in
            guard let self, self.accountMutations.active?.token == work.token else { return }
            guard self.connectionEpoch == work.connectionEpoch,
                  self.automaticAuthorizationGeneration == work.authorizationGeneration,
                  self.subscriptionAccount == work.account,
                  self.subscriptions != nil,
                  self.favoriteIDs != nil,
                  self.subscriptionSnapshotConnectionEpoch == self.connectionEpoch,
                  self.subscriptionSnapshotAuthorizationGeneration == self.automaticAuthorizationGeneration,
                  self.favoriteSnapshotConnectionEpoch == self.connectionEpoch,
                  self.favoriteSnapshotAuthorizationGeneration == self.automaticAuthorizationGeneration else {
                self.accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-state-unconfirmed: Steam 会话或账号授权在个人投票请求期间变化；结果未确认，不会自动重试。"))
                self.invalidateSubscriptionPresentation("Steam 账号状态已变化，个人投票结果未采用。", invalidateAutomatic: false)
                return
            }
            switch WorkshopUserVoteChangeProtocol.parse(result, processExitedSuccessfully: success,
                                                        request: request, account: work.account) {
            case .failed(let reason):
                self.accountMutations.finish(work.token, with: .failed(reason))
            case .unconfirmed(let reason):
                // The remote mutation may have reached Steam. Keep no local
                // substitute state, never resend it, and invalidate only the
                // personal-vote presentation after delivering the result.
                self.accountMutations.finish(work.token, with: .unconfirmed(reason))
                self.invalidateUserVotePresentation(reason: "steam-vote-set-unconfirmed: Steam 未确认个人投票写入结果。")
            case .callbackConfirmed:
                self.confirmUserVoteChange(request: request, work: work,
                                           selectionGeneration: selectionGeneration)
            }
        }
    }

    /// Read-after-write confirmation.  This is intentionally not routed
    /// through the ordinary selected-detail read queue: the account mutation
    /// remains active so no independently queued read or write can interleave.
    private func confirmUserVoteChange(request: WorkshopUserVoteChangeRequest,
                                       work: WorkshopAccountMutationQueue.Work,
                                       selectionGeneration: UInt64) {
        guard accountMutations.active?.token == work.token,
              work.connectionEpoch == connectionEpoch,
              work.authorizationGeneration == automaticAuthorizationGeneration,
              subscriptionAccount == work.account,
              subscriptions != nil, favoriteIDs != nil,
              subscriptionSnapshotConnectionEpoch == connectionEpoch,
              subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration,
              favoriteSnapshotConnectionEpoch == connectionEpoch,
              favoriteSnapshotAuthorizationGeneration == automaticAuthorizationGeneration,
              eventMonitor.clientPID != nil,
              let readRequest = WorkshopUserVoteReadRequest(workshopID: request.workshopID,
                                                            selectionGeneration: selectionGeneration) else {
            accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-unconfirmed: 写入回执后的 Steam 账号状态已变化；无法确认个人投票，不会自动重试。"))
            invalidateUserVotePresentation(reason: "steam-vote-set-unconfirmed: 个人投票确认读取未启动。")
            return
        }
        onStatus?("正在重新确认 Steam 个人评分状态…")
        runHelper(readRequest.helperArguments(expectedAccount: work.account), onDiscard: { [weak self] in
            guard let self, self.accountMutations.active?.token == work.token else { return }
            self.accountMutations.finish(work.token, with: .unconfirmed("steam-session-invalidated: Steam 会话在个人投票确认读取期间变化；结果未确认，不会自动重试。"))
            self.invalidateSubscriptionPresentation("Steam 会话已变化，个人投票显示等待重新确认。", invalidateAutomatic: false)
        }) { [weak self] result, success in
            guard let self, self.accountMutations.active?.token == work.token else { return }
            guard self.connectionEpoch == work.connectionEpoch,
                  self.automaticAuthorizationGeneration == work.authorizationGeneration,
                  self.subscriptionAccount == work.account,
                  self.subscriptions != nil, self.favoriteIDs != nil,
                  self.subscriptionSnapshotConnectionEpoch == self.connectionEpoch,
                  self.subscriptionSnapshotAuthorizationGeneration == self.automaticAuthorizationGeneration,
                  self.favoriteSnapshotConnectionEpoch == self.connectionEpoch,
                  self.favoriteSnapshotAuthorizationGeneration == self.automaticAuthorizationGeneration else {
                self.accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-unconfirmed: Steam 账号状态在个人投票确认读取期间变化；结果未确认，不会自动重试。"))
                self.invalidateSubscriptionPresentation("Steam 账号状态已变化，个人投票确认结果未采用。", invalidateAutomatic: false)
                return
            }
            switch WorkshopUserVoteReadProtocol.parse(result, processExitedSuccessfully: success,
                                                      request: readRequest, account: work.account) {
            case .confirmed(let vote):
                guard vote == request.direction.vote else {
                    self.accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-unconfirmed: Steam 未在同一账号的新鲜个人投票读取中确认请求目标；不会自动重试。"))
                    self.invalidateUserVotePresentation(reason: "steam-vote-set-unconfirmed: 个人投票目标未在新鲜读取中确认。")
                    return
                }
                let receipt = WorkshopUserVoteReceipt(workshopID: request.workshopID, vote: vote,
                                                      selectionGeneration: selectionGeneration,
                                                      connectionEpoch: work.connectionEpoch,
                                                      authorizationGeneration: work.authorizationGeneration)
                self.accountMutations.finish(work.token, with: .confirmedUserVote(receipt))
            case .failed(let reason):
                // A fresh read failure after a completed write does not prove
                // the old state survived, therefore it must not be surfaced as
                // a definite failed write.
                self.accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-unconfirmed: 写入后的个人投票读取失败（\(reason)）；结果未确认，不会自动重试。"))
                self.invalidateUserVotePresentation(reason: "steam-vote-set-unconfirmed: 写入后的个人投票读取失败。")
            case .unconfirmed(let reason):
                self.accountMutations.finish(work.token, with: .unconfirmed("steam-vote-set-unconfirmed: 写入后的个人投票读取未确认（\(reason)）；不会自动重试。"))
                self.invalidateUserVotePresentation(reason: "steam-vote-set-unconfirmed: 写入后的个人投票读取未确认。")
            }
        }
    }

    /// Runs one selected-detail vote-get once account mutations are fully
    /// idle.  All account fields are rechecked immediately before dispatch and
    /// after the callback; an old page receives an echoed selection generation
    /// but never establishes a presentation state by itself.
    private func beginNextUserVoteRead() -> Bool {
        guard accountMutations.isEmpty, activeUserVoteRead == nil,
              !pendingUserVoteReads.isEmpty else { return false }
        let work = pendingUserVoteReads.removeFirst()
        activeUserVoteRead = work
        let trusted = subscriptions != nil
            && subscriptionAccount == work.account
            && subscriptionSnapshotConnectionEpoch == connectionEpoch
            && subscriptionSnapshotAuthorizationGeneration == automaticAuthorizationGeneration
            && work.connectionEpoch == connectionEpoch
            && work.authorizationGeneration == automaticAuthorizationGeneration
            && eventMonitor.clientPID != nil
        guard trusted else {
            finishUserVoteRead(work.token, with: .unconfirmed("steam-vote-get-state-unconfirmed: Steam 账号快照、会话或授权代次已变化；个人投票读取未发送。"))
            DispatchQueue.main.async { [weak self] in self?.pump() }
            return true
        }
        runHelper(work.request.helperArguments(expectedAccount: work.account), onDiscard: { [weak self] in
            guard let self, self.activeUserVoteRead?.token == work.token else { return }
            self.invalidateSubscriptionPresentation("Steam 会话已变化，个人投票读取结果未采用。", invalidateAutomatic: false)
        }) { [weak self] result, success in
            guard let self, self.activeUserVoteRead?.token == work.token else { return }
            guard self.connectionEpoch == work.connectionEpoch,
                  self.automaticAuthorizationGeneration == work.authorizationGeneration,
                  self.subscriptionAccount == work.account,
                  self.subscriptions != nil,
                  self.subscriptionSnapshotConnectionEpoch == self.connectionEpoch,
                  self.subscriptionSnapshotAuthorizationGeneration == self.automaticAuthorizationGeneration else {
                self.invalidateSubscriptionPresentation("Steam 账号状态已变化，个人投票读取结果未采用。", invalidateAutomatic: false)
                return
            }
            switch WorkshopUserVoteReadProtocol.parse(result, processExitedSuccessfully: success,
                                                      request: work.request, account: work.account) {
            case .confirmed(let vote):
                let receipt = WorkshopUserVoteReceipt(workshopID: work.request.workshopID, vote: vote,
                                                      selectionGeneration: work.request.selectionGeneration,
                                                      connectionEpoch: work.connectionEpoch,
                                                      authorizationGeneration: work.authorizationGeneration)
                self.finishUserVoteRead(work.token, with: .confirmed(receipt))
            case .failed(let reason): self.finishUserVoteRead(work.token, with: .failed(reason))
            case .unconfirmed(let reason): self.finishUserVoteRead(work.token, with: .unconfirmed(reason))
            }
        }
        return true
    }

    private func finishUserVoteRead(_ token: UUID, with result: WorkshopUserVoteReadResult) {
        guard let active = activeUserVoteRead, active.token == token else { return }
        activeUserVoteRead = nil
        active.completion(result)
        // A completion can itself select a new item and enqueue the next read.
        // Drive that queued work after the callback unwinds; otherwise a
        // selection B queued behind an in-flight A read can remain stranded
        // until unrelated coordinator activity happens to call `pump()`.
        DispatchQueue.main.async { [weak self] in self?.pump() }
    }

    private func pump() {
        guard !busy, !stopped else { return }
        // Reads and account mutations share the one helper/session boundary in
        // both directions.  `busy` normally implies this already, but retain
        // the explicit guard for immediate completion/invalidation paths.
        guard activeUserVoteRead == nil else { return }
        if let work = accountMutations.beginNext() {
            switch work.request {
            case .subscription:
                performSubscriptionChange(work)
            case .favorite:
                performFavoriteChange(work)
            case .userVote:
                performUserVoteChange(work)
            }
            return
        }
        // `beginNext()` returns nil while an existing mutation is still
        // active. Its Set callback plus post-write confirmation read own the
        // global account fence, so no independent vote-get may pass it.
        guard accountMutations.isEmpty else { return }
        if beginNextUserVoteRead() { return }
        if !transfersPaused, let manual = pending.firstIndex(where: { !$0.automatic }),
           !pending[manual].restored || eventMonitor.clientPID != nil { download(pending.remove(at: manual)); return }
        if let browse = pendingBrowse {
            pendingBrowse = nil
            let request = browse.request
            runHelper(["browse", "--query", request.query, "--sort", request.sort.rawValue, "--cursor", request.cursor,
                       "--filters-json", request.filters.json],
                      onDiscard: { browse.completion(nil, "Steam 连接已变化，请重试") }) { result, success in
                guard success, let result, let page = WorkshopBrowsePage(result, request: request) else {
                    browse.completion(nil, "创意工坊查询未完成，请确认 Steam 已连接后重试")
                    return
                }
                browse.completion(page, nil)
            }
            return
        }
        if subscriptionCheckPending {
            if eventMonitor.clientPID != nil { syncSubscriptions(); return }
            subscriptionCheckPending = false
            onStatus?("请先打开官方 Steam 客户端；当前本地壁纸可继续播放")
        }
        if automatic, eventMonitor.isConnected, let subscriptions,
           savedCheckPending || confirmedSavedInvalidations.full || !confirmedSavedInvalidations.ids.isEmpty || !readySavedIDs.isEmpty {
            let saved = SavedWorkshopStore.records().items
            let full = savedCheckPending || confirmedSavedInvalidations.full
            if full {
                readySavedIDs.formUnion(saved.map(\.id))
                lastSavedCheck = ProcessInfo.processInfo.systemUptime
            } else {
                readySavedIDs.formUnion(saved.lazy.filter { self.confirmedSavedInvalidations.ids.contains($0.id) }.map(\.id))
            }
            savedCheckPending = false
            confirmedSavedInvalidations = SavedWorkshopInvalidations()
            let byID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in readySavedIDs.sorted() {
                guard let item = byID[id], !suppressedAutomatic.contains(id) else {
                    readySavedIDs.remove(id); continue
                }
                guard let subscription = subscriptions.first(where: { $0.id == id }) else {
                    readySavedIDs.remove(id); continue
                }
                // A filesystem hint is not a complete-install receipt.  Keep
                // it queued while Steam still reports the item unavailable or
                // downloading; a subsequent confirmed snapshot can retry it.
                guard subscription.enabled else { readySavedIDs.remove(id); continue }
                guard subscription.available, !subscription.needsDownload else { continue }
                let request = DownloadRequest(id: item.id, project: item.project, apply: false, generation: selectionGeneration, knownOutdated: false, automatic: true)
                if pending.contains(where: { $0.key == request.key }) { readySavedIDs.remove(id); continue }
                // An active check may have started before the event; keep this
                // hint until it ends and a fresh check can run.
                if activeTransfer?.key == request.key { continue }
                guard pending.count < 1000 else { break }
                if queueRequest(request) { readySavedIDs.remove(id) }
            }
        }
        guard libraryCheckPending else {
            if !transfersPaused, automatic, eventMonitor.isConnected, subscriptions != nil, reconcileTask == nil {
                while !pending.isEmpty {
                    let request = pending.removeFirst()
                    guard automaticRequestAuthorized(request) else {
                        finishTransfer(request.token, phase: .cancelled, detail: "Steam 订阅或访问状态已变化，自动任务未开始。")
                        continue
                    }
                    download(request)
                    return
                }
            }
            return
        }
        libraryCheckPending = false
        onStatus?("正在检查本地壁纸库版本…")
        runHelper(["check-updates"]) { [weak self] result, success in
            guard let self else { return }
            guard success, result?["status"] as? String == "checked", let items = result?["items"] as? [[String: Any]], items.count <= 1000 else {
                self.onStatus?("壁纸库版本尚未确认，请检查网络或 Steam 条目访问权限")
                return
            }
            var outdated: [(id: String, project: URL)] = []
            var invalidItems = 0
            for item in items {
                guard let id = item["workshop_id"] as? String, Self.validID(id), let path = item["project"] as? String,
                      let project = Self.approvedProject(path, id: id) else { invalidItems += 1; continue }
                let status = item["status"] as? String
                if status == "current", let manifest = item["manifest"] as? String {
                    let previous = self.knownManifests[project.path]
                    if previous != nil, previous != manifest, project == self.selectedProject {
                        // A changed selected copy still passes refresh --project
                        // before it can be applied; this query alone never loads it.
                        outdated.append((id, project))
                    } else { self.knownManifests[project.path] = manifest }
                }
                if status == "outdated" { outdated.append((id, project)) }
            }
            let unconfirmed = (result?["unconfirmed_count"] as? Int ?? 0) + invalidItems
            let truncated = result?["truncated"] as? Bool == true
            let discoveryIncomplete = !(result?["discovery_warnings"] as? [String] ?? []).isEmpty
            if outdated.isEmpty {
                self.onStatus?(unconfirmed > 0 || truncated || discoveryIncomplete ? "壁纸库已检查，部分库或项目尚未确认" : "本地壁纸库 \(items.count) 项版本已确认")
            } else if !self.automatic {
                self.onStatus?("发现 \(outdated.count) 项更新；自动更新已关闭，可选择壁纸后手动更新")
            } else {
                var queued = 0
                for item in outdated {
                    guard SavedWorkshopStore.current(item.id) == nil, self.eventMonitor.isConnected,
                          self.subscriptions?.contains(where: { $0.id == item.id && $0.enabled && $0.available }) == true else { continue }
                    let request = DownloadRequest(id: item.id, project: item.project, apply: false, generation: self.selectionGeneration, knownOutdated: true, automatic: true)
                    guard !self.pending.contains(where: { $0.key == request.key }), self.pending.count < 1000 else { continue }
                    if self.queueRequest(request) { queued += 1 }
                }
                self.onStatus?("发现 \(outdated.count) 项更新，已确认订阅中加入队列 \(queued) 项")
            }
        }
    }

    private func rejectSubscriptionSnapshot(_ captured: SavedWorkshopInvalidations, reason: String,
                                            status: String, reschedule: Bool, invalidateAutomatic: Bool,
                                            completion: ((SubscriptionSnapshotOutcome) -> Void)?) {
        unconfirmedSavedInvalidations.merge(captured)
        savedCheckPending = true
        if invalidateAutomatic { invalidateAutomaticAuthorization() }
        invalidateSubscriptionPresentation(reason, invalidateAutomatic: false)
        if reschedule { subscriptionCheckPending = true }
        onStatus?(status)
        completion?(.unconfirmed(reason))
    }

    private func syncSubscriptions(expectedAccount: WorkshopSubscriptionAccount? = nil,
                                   expectedConnectionEpoch: UInt64? = nil,
                                   expectedAuthorizationGeneration: UInt64? = nil,
                                   deferFavoritePublication: Bool = false,
                                   completion: ((SubscriptionSnapshotOutcome) -> Void)? = nil) {
        subscriptionCheckPending = false
        // A 3418 can arrive while this helper request owns the serialized
        // worker. Its older, internally consistent response is nevertheless
        // no longer an authorization snapshot for automatic work.
        let snapshotEpoch = connectionEpoch
        let authorizationGeneration = automaticAuthorizationGeneration
        guard (expectedConnectionEpoch == nil || expectedConnectionEpoch == snapshotEpoch),
              (expectedAuthorizationGeneration == nil || expectedAuthorizationGeneration == authorizationGeneration) else {
            invalidateSubscriptionPresentation("Steam 订阅快照已变化，订阅操作未发送。", invalidateAutomatic: false)
            completion?(.unconfirmed("steam-subscription-state-unconfirmed: 写入后的 Steam 订阅快照代次已变化；不会自动重试，请先同步订阅再决定是否重试。"))
            return
        }
        // Events received while another query runs belong to the next query.
        // A pending debounce likewise requires a later, fresh snapshot.
        let captured: SavedWorkshopInvalidations
        if reconcileTask == nil {
            captured = unconfirmedSavedInvalidations
            unconfirmedSavedInvalidations = SavedWorkshopInvalidations()
        } else { captured = SavedWorkshopInvalidations() }
        onStatus?("正在读取 Steam 账号订阅…")
        runHelper(["subscriptions"], onDiscard: { [weak self] in
            guard let self else { return }
            self.rejectSubscriptionSnapshot(captured,
                                            reason: "steam-session-invalidated: Steam 会话在读取订阅期间变化；订阅状态未确认，请刷新后再决定是否重试。",
                                            status: "Steam 会话已变化，订阅状态等待重新确认。",
                                            reschedule: false, invalidateAutomatic: false, completion: completion)
        }) { [weak self] result, success in
            guard let self else { return }
            guard self.connectionEpoch == snapshotEpoch,
                  self.automaticAuthorizationGeneration == authorizationGeneration,
                  expectedConnectionEpoch == nil || expectedConnectionEpoch == self.connectionEpoch,
                  expectedAuthorizationGeneration == nil || expectedAuthorizationGeneration == self.automaticAuthorizationGeneration else {
                // Do not publish, attach a new automatic lease to, or retain
                // visible account state from a snapshot that predates 3418.
                // The outer helper completion calls pump(), which immediately
                // starts the pending fresh query on the same live Steam PID.
                self.rejectSubscriptionSnapshot(captured,
                                                reason: "steam-subscription-state-unconfirmed: Steam 订阅快照在读取期间过期；不会自动重试，请先同步订阅再决定是否重试。",
                                                status: "Steam 订阅在读取期间发生变化；正在重新确认。",
                                                reschedule: true, invalidateAutomatic: false, completion: completion)
                return
            }
            guard success, result?["status"] as? String == "subscriptions",
                  Self.exactJSONBoolean(result?["snapshot_consistent"], equals: true),
                  let raw = result?["items"] as? [[String: Any]], raw.count <= 10_000,
                  Self.exactJSONInteger(result?["subscription_count"]) == raw.count else {
                self.rejectSubscriptionSnapshot(captured,
                                                reason: "steam-subscription-state-unconfirmed: Steam 未返回完整且可验证的订阅快照。",
                                                status: "Steam 订阅尚未确认；请检查 Steam 登录和连接。已保留本地壁纸。",
                                                reschedule: false, invalidateAutomatic: false, completion: completion)
                return
            }
            guard let accountText = result?["account_id"] as? String,
                  let account = WorkshopSubscriptionAccount(accountText),
                  expectedAccount == nil || account == expectedAccount,
                  expectedAccount != nil || self.subscriptionAccount == nil || self.subscriptionAccount == account else {
                self.rejectSubscriptionSnapshot(captured,
                                                reason: "steam-account-mismatch: Steam 账号在订阅快照期间变化；当前订阅状态已失效，请先同步后再操作。",
                                                status: "Steam 账号已变化，订阅状态等待重新确认。",
                                                reschedule: false, invalidateAutomatic: true, completion: completion)
                return
            }
            let normalized = raw.compactMap(Self.normalizedSubscription)
            let items = normalized.compactMap(SteamSubscription.init)
            guard normalized.count == raw.count, items.count == raw.count, Set(items.map(\.id)).count == items.count else {
                self.rejectSubscriptionSnapshot(captured,
                                                reason: "steam-subscription-state-unconfirmed: Steam 订阅条目数据不完整。",
                                                status: "Steam 订阅数据不完整，尚未开始同步",
                                                reschedule: false, invalidateAutomatic: false, completion: completion)
                return
            }
            self.confirmedSavedInvalidations.merge(captured)
            self.subscriptionAccount = account
            self.subscriptionSnapshotConnectionEpoch = snapshotEpoch
            self.subscriptionSnapshotAuthorizationGeneration = authorizationGeneration
            self.subscriptions = items; self.onSubscriptionsChanged?(items)
            // A cached favorites list is useful only as Steam transport
            // metadata; it is never safe to present as an account-mutation
            // source or as a post-write convergence receipt. Publish `nil`
            // for it so the browser disables favorite controls until a fresh
            // full snapshot arrives.
            let freshFavoriteIDs: Set<String>?
            if Self.exactJSONBoolean(result?["favorites_confirmed"], equals: true),
               Self.exactJSONBoolean(result?["favorites_query_cached"], equals: false),
               let ids = result?["favorite_ids"] as? [String],
               ids.count <= 100_000,
               let canonicalFavorites = Optional(ids.compactMap { WorkshopSubscriptionChangeRequest(workshopID: $0, subscribed: true)?.workshopID }),
               canonicalFavorites.count == ids.count, Set(canonicalFavorites).count == canonicalFavorites.count {
                freshFavoriteIDs = Set(canonicalFavorites)
            } else { freshFavoriteIDs = nil }
            // The favorite mutation path has already published `nil` before
            // this helper starts. Keep it hidden until the caller checks the
            // requested membership, so a cached or wrong-target list can
            // never flash a stale heart in the browser.
            if !deferFavoritePublication {
                self.favoriteIDs = freshFavoriteIDs
                self.favoriteSnapshotConnectionEpoch = freshFavoriteIDs == nil ? nil : snapshotEpoch
                self.favoriteSnapshotAuthorizationGeneration = freshFavoriteIDs == nil ? nil : authorizationGeneration
                self.onFavoritesChanged?(self.favoriteIDs)
            }
            self.onLibraryChanged?()
            let waiting = items.filter { $0.available && $0.enabled && $0.needsDownload }
            var queued = 0
            let enabledIDs = Set(items.filter { $0.enabled && $0.available }.map(\.id))
            // A retained immutable copy preserves local playback, not an
            // automatic-refresh authorization. Remove queued work for a
            // removed, disabled or unavailable item even when it has a saved
            // current.json; execution rechecks the same condition too.
            // The authorization generation changes as soon as 3418 arrives,
            // before this serialized snapshot completes. Remove those stale
            // queued leases too, so only the bounded captured retry IDs can
            // be rebuilt against this exact membership view.
            self.removeAutomaticTasks(reason: "订阅或访问状态已变化，自动任务未开始。") {
                !enabledIDs.contains($0.id) || $0.automaticAuthorizationGeneration != self.automaticAuthorizationGeneration
            }
            let retries = self.automaticRetryIDsAwaitingSnapshot.filter(enabledIDs.contains)
            self.automaticRetryIDsAwaitingSnapshot.removeAll()
            self.readySavedIDs.formUnion(retries)
            if self.automatic, self.eventMonitor.isConnected {
                for item in waiting {
                    if let saved = SavedWorkshopStore.current(item.id) {
                        let request = DownloadRequest(id: item.id, project: saved.project, apply: false, generation: self.selectionGeneration, knownOutdated: true, automatic: true)
                        if self.queueRequest(request) { queued += 1 }
                        continue
                    }
                    let localPaths = normalized.first(where: { $0["workshop_id"] as? String == item.id })?["local_projects"] as? [String] ?? []
                    let copies: [URL?] = localPaths.isEmpty ? [nil] : Array(Set(localPaths)).compactMap { Self.approvedProject($0, id: item.id) }.map { Optional($0) }
                    for project in copies {
                        let request = DownloadRequest(id: item.id, project: project, apply: false, generation: self.selectionGeneration, knownOutdated: true, automatic: true)
                        guard !self.pending.contains(where: { $0.key == request.key }), self.pending.count < 1000 else { continue }
                        if self.queueRequest(request) { queued += 1 }
                    }
                }
            }
            let unavailable = items.filter { !$0.available }.count
            let suffix = unavailable > 0 ? "，\(unavailable) 项访问尚未确认" : ""
            let cached = Self.exactJSONBoolean(result?["query_cached"], equals: true) ? "（Steam 缓存）" : ""
            self.onStatus?("Steam 订阅已读取 \(items.count) 项\(cached)，待下载或更新 \(waiting.count) 项，已排队 \(queued) 项" + suffix)
            completion?(.confirmed(items: items, account: account, favorites: freshFavoriteIDs, connectionEpoch: snapshotEpoch,
                                  authorizationGeneration: authorizationGeneration))
        }
    }

    private func download(_ request: DownloadRequest) {
        guard automaticRequestAuthorized(request) else {
            finishTransfer(request.token, phase: .cancelled, detail: "Steam 订阅或访问状态已变化，自动任务未开始。")
            return
        }
        activeTransfer = request
        updateTransfer(request.token, phase: .checking, detail: "正在确认 Steam 版本，需要时下载。")
        onStatus?(request.apply ? "正在确认 Steam 版本，需要时下载…" : "正在检查壁纸 \(request.id)…")
        var arguments = ["refresh", request.id, "--timeout", "1800", "--progress-json"]
        let saved = request.project.flatMap { SavedWorkshopStore.recordForProject($0) }
        let source: URL? = saved.flatMap {
            let url = URL(fileURLWithPath: $0.sourceProject)
            return SteamLibraryIndex.location(for: url, id: request.id) != nil && FileManager.default.fileExists(atPath: url.path) ? url : nil
        } ?? (saved == nil ? request.project : nil)
        if let source { arguments += ["--project", source.path] }
        runHelper(arguments, progressID: request.id, onProgress: { [weak self] event in
            self?.receiveProgress(event, token: request.token)
        }, onDiscard: { [weak self] in
            self?.finishTransfer(request.token, phase: .failed, detail: "Steam 连接已变化，本次结果未应用。连接恢复后可重试。")
        }) { [weak self] parsed, success in
            guard let self, self.activeTransfer?.token == request.token else { return }
            if self.transferEntries[request.token]?.phase == .cancelled {
                self.activeTransfer = nil; self.notifyTransfers(); return
            }
            guard success, parsed?["status"] as? String == "installed", let path = parsed?["project"] as? String,
                  let manifest = parsed?["manifest"] as? String,
                  let projectURL = Self.approvedProject(path, id: request.id),
                  source == nil || source == projectURL else {
                let reason = Self.helperFailure(parsed)
                self.finishTransfer(request.token, phase: .failed, detail: "Steam 安装尚未确认，已保留当前壁纸。" + reason)
                self.onStatus?("\(request.id) 的 Steam 安装尚未确认；可在下载与更新中重试")
                return
            }
            let intent = self.activeTransfer ?? request
            guard self.automaticRequestAuthorized(intent) else {
                self.finishTransfer(request.token, phase: .cancelled, detail: "Steam 订阅或访问状态已变化，本次自动结果未保存。")
                self.onStatus?("Steam 订阅或访问状态已变化，未替换本机壁纸")
                return
            }
            let changed = self.knownManifests[projectURL.path] != nil && self.knownManifests[projectURL.path] != manifest
            self.knownManifests[projectURL.path] = manifest
            let alreadyCurrent = parsed?["already_current"] as? Bool == true
            let shouldSave = intent.apply || intent.retainCopy || saved != nil || SavedWorkshopStore.current(request.id) != nil
            if !shouldSave {
                self.onLibraryChanged?()
                let activeUpdated = intent.generation == self.selectionGeneration && projectURL == self.selectedProject && (changed || request.knownOutdated)
                self.finishTransfer(request.token, phase: .completed, detail: alreadyCurrent ? "Steam 本地版本已确认，无需下载。可选择设为默认壁纸。" : "Steam 安装已确认。可选择设为默认壁纸，选用后保存本机副本。", project: projectURL)
                self.onStatus?(alreadyCurrent ? "Steam 本地版本已是最新" : "壁纸 \(request.id) 已更新")
                if activeUpdated { self.onProjectUpdated?(projectURL) }
                return
            }
            self.busy = true
            let epoch = self.connectionEpoch
            let permit = SavedWorkshopCommitPermit()
            self.savingPermits[request.token] = permit
            if intent.automatic { self.automaticSavingPermitItems[request.token] = request.id }
            self.updateTransfer(request.token, phase: .saving, detail: "安装已确认，正在提交独立本机副本；此阶段暂时不能停止。")
            self.onStatus?("正在保存壁纸 \(request.id) 到本机…")
            Task { [weak self] in
                guard let self else { return }
                defer {
                    self.savingPermits[request.token] = nil
                    self.automaticSavingPermitItems[request.token] = nil
                    self.busy = false; self.notifyTransfers(); if !self.stopped { self.pump() }
                }
                do {
                    // A 3418 can arrive after the helper receipt but before
                    // this task reaches SavedWorkshopStore. Do not start a
                    // copy under a stale automatic authorization lease.
                    guard self.automaticRequestAuthorized(intent) else {
                        self.finishTransfer(request.token, phase: .cancelled, detail: "Steam 订阅或访问状态已变化，本次自动结果未保存。")
                        self.onStatus?("Steam 订阅或访问状态已变化，未替换本机壁纸")
                        return
                    }
                    let retained = try await SavedWorkshopStore.perform {
                        try SavedWorkshopStore.save(project: projectURL, id: request.id, expectedManifest: manifest, commitPermit: permit)
                    }
                    guard !self.stopped else { return }
                    guard self.connectionEpoch == epoch else {
                        self.finishTransfer(request.token, phase: .failed, detail: "本机副本可能已提交，但 Steam 会话已变化；未更新桌面或播放。")
                        return
                    }
                    guard self.automaticRequestAuthorized(intent) else {
                        self.finishTransfer(request.token, phase: .cancelled, detail: "Steam 订阅或访问状态已变化；本机副本如已提交，也不会更新桌面或播放器。")
                        self.onStatus?("Steam 订阅或访问状态已变化，未更新桌面壁纸")
                        return
                    }
                    if self.transferEntries[request.token]?.phase == .cancelled {
                        self.activeTransfer = nil; return
                    }
                    self.onLibraryChanged?()
                    let intent = self.activeTransfer ?? request
                    let explicit = intent.apply && intent.generation == self.selectionGeneration
                    let active = intent.generation == self.selectionGeneration && self.itemID == request.id && self.selectedProject != retained.project
                    let detail = alreadyCurrent ? "Steam 版本已确认，本机副本已保存，无需下载。" : "Steam 下载和本机副本保存已确认。"
                    self.finishTransfer(request.token, phase: .completed, detail: detail + (explicit || active ? "已交给播放器处理，实际播放状态见显示器面板。" : "当前选择保持，可主动设为默认壁纸。"), project: retained.project, title: retained.title)
                    self.onStatus?("壁纸 \(request.id) 已保存到本机" + (alreadyCurrent ? "，Steam 版本已确认" : "，下载完成"))
                    if explicit { self.onProjectReady?(retained.project) }
                    else if active { self.onProjectUpdated?(retained.project) }
                } catch {
                    if !self.stopped {
                        self.finishTransfer(request.token, phase: .failed, detail: "本机保存未完成，已保留当前壁纸：" + error.localizedDescription)
                        self.onStatus?("本机保存未完成，可在下载与更新中重试")
                    }
                }
            }
        }
    }

    private static func helperFailure(_ parsed: [String: Any]?) -> String {
        guard let error = parsed?["error"] as? String else { return "未收到有效的完成记录，请确认 Steam 连接后重试。" }
        return String(error.prefix(1000)).replacingOccurrences(of: #"\b7656\d{13}\b"#, with: "<redacted-steam-id>", options: .regularExpression)
    }

    /// The bounded result and optional progress pipe are drained concurrently.
    /// Progress cannot change the selected project or establish completion.
    private func runHelper(_ arguments: [String], progressID: String? = nil,
                           onProgress: ((SteamDownloadProgress) -> Void)? = nil, onDiscard: (() -> Void)? = nil,
                           completion: @escaping ([String: Any]?, Bool) -> Void) {
        guard let helper = Bundle.main.url(forResource: "we-workshop", withExtension: nil, subdirectory: "Tools") else {
            onStatus?("下载工具尚未包含在应用中"); completion(nil, false)
            DispatchQueue.main.async { [weak self] in self?.pump() }; return
        }
        busy = true
        let labels = ["browse": "正在查询创意工坊", "subscriptions": "正在确认 Steam 订阅", "check-updates": "正在检查本地壁纸库版本", "refresh": "正在处理壁纸获取 / 更新"]
        helperActivity = labels[arguments.first ?? ""] ?? "正在处理 Steam 请求"; notifyTransfers()
        let epoch = connectionEpoch
        let worker = Process(), pipe = Pipe()
        let progressPipe = progressID == nil ? nil : Pipe()
        worker.executableURL = helper; worker.arguments = arguments
        worker.standardOutput = pipe
        if let progressPipe { worker.standardError = progressPipe } else { worker.standardError = FileHandle.nullDevice }
        process = worker
        do { try worker.run() }
        catch {
            busy = false; process = nil; helperActivity = ""; notifyTransfers()
            onStatus?("无法启动 Steam 请求：" + error.localizedDescription)
            completion(["error": error.localizedDescription], false)
            DispatchQueue.main.async { [weak self] in self?.pump() }; return
        }
        try? pipe.fileHandleForWriting.close()
        try? progressPipe?.fileHandleForWriting.close()
        let progressGroup = DispatchGroup()
        if let progressPipe, let progressID {
            progressGroup.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                SteamHelperOutput.readProgress(progressPipe.fileHandleForReading, id: progressID) { event in
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            guard let self, !self.stopped, self.process === worker, self.connectionEpoch == epoch else { return }
                            onProgress?(event)
                        }
                    }
                }
                progressGroup.leave()
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = SteamHelperOutput.readResult(pipe.fileHandleForReading)
            worker.waitUntilExit(); progressGroup.wait()
            let parsed = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
            let success = worker.terminationStatus == 0
            if !success || parsed == nil {
                let message = String((parsed?["error"] as? String ?? "Helper did not return a JSON result").prefix(500))
                    .replacingOccurrences(of: #"\b7656\d{13}\b"#, with: "<redacted-steam-id>", options: .regularExpression)
                fputs("Steam helper \(arguments.first ?? "unknown") failed (exit \(worker.terminationStatus)): \(message)\n", stderr)
            }
            DispatchQueue.main.async {
                guard let self, !self.stopped, self.process === worker else { return }
                self.busy = false; self.process = nil; self.helperActivity = ""; self.notifyTransfers()
                guard self.connectionEpoch == epoch else {
                    fputs("Steam helper result discarded after connection epoch changed: \(arguments.first ?? "unknown")\n", stderr)
                    onDiscard?()
                    self.pump(); return
                }
                completion(parsed, success)
                self.pump()
            }
        }
    }

    func stop() {
        guard !stopped else { return }
        persistTransfers()
        // `runHelper` deliberately discards late process output after
        // `stopped` flips. Settle an active or queued read first so a selected
        // detail never remains indefinitely in a loading/disabled state when
        // the host exits. Account writes use their separate shared queue below
        // and are not duplicated by this read-only invalidation.
        invalidateUserVotePresentation(reason: "steam-vote-get-stopped: 应用正在退出；个人投票读取未确认。")
        accountMutations.cancelAll(with: .unconfirmed("steam-account-mutation-stopped: 应用正在退出；账号请求结果未确认，请刷新订阅状态后再决定是否重试。"))
        stopped = true
        cancelSavingPermits()
        timer?.invalidate(); timer = nil
        reconcileTask?.cancel(); reconcileTask = nil
        eventMonitor.stop()
        libraryWatcher?.stop(); libraryWatcher = nil
        pending.removeAll(); libraryCheckPending = false
        pendingBrowse = nil
        subscriptionCheckPending = false
        subscriptionAccount = nil
        subscriptionSnapshotConnectionEpoch = nil
        subscriptionSnapshotAuthorizationGeneration = nil
        favoriteSnapshotConnectionEpoch = nil
        favoriteSnapshotAuthorizationGeneration = nil
        subscriptions = nil; onSubscriptionsChanged?(nil)
        favoriteIDs = nil; onFavoritesChanged?(nil)
        savedCheckPending = false
        unconfirmedSavedInvalidations = SavedWorkshopInvalidations()
        confirmedSavedInvalidations = SavedWorkshopInvalidations()
        readySavedIDs.removeAll()
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
