import AppKit
import Foundation

/// Steam's confirmation of an explicit subscription mutation.  A confirmed
/// request is still distinct from a fresh subscription snapshot or downloaded
/// Workshop content, so the UI may only re-query its current page afterwards.
enum WorkshopSubscriptionChangeResult {
    case confirmed
    case failed(String)
    case unconfirmed(String)
}

/// An embedded page of the main browser. Browsing itself never installs or
/// changes subscriptions; an explicit, injected user action may do so.
@MainActor
final class WorkshopBrowserController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    enum Mode { case discover, workshop }
    var onBrowse: ((WorkshopBrowseRequest, @escaping (WorkshopBrowsePage?, String?) -> Void) -> Void)?
    var onDownload: ((String) -> Void)?
    /// The completion is invoked exactly once on the main thread by the host
    /// bridge. Only `.confirmed` means Steam confirmed the request rather than
    /// merely accepting IPC; `.unconfirmed` must remain non-destructive.
    var onSubscriptionChange: ((String, Bool, @escaping (WorkshopSubscriptionChangeResult) -> Void) -> Void)?
    /// Favorites are a separate Steam account mutation. As with subscriptions,
    /// `.confirmed` means the coordinator has observed a fresh, complete
    /// same-account favorite snapshot after Steam's exact callback.
    var onFavoriteChange: ((String, Bool, @escaping (WorkshopFavoriteChangeResult) -> Void) -> Void)?
    /// The authenticated personal Workshop vote is intentionally queried
    /// separately from a public page's aggregate score.  A read result may be
    /// shown only for the matching canonical item, browser selection, and
    /// account session; see `requestCurrentUserVoteRefresh()`.
    var onUserVoteRefresh: ((String, UInt64, @escaping (WorkshopUserVoteReadResult) -> Void) -> Void)?
    /// Steam stable's star-rating template sends only explicit `up` or `down`
    /// requests.  It has no cancel operation, and this UI never invents one.
    var onUserVoteChange: ((String, WorkshopUserVoteDirection, UInt64, @escaping (WorkshopUserVoteChangeResult) -> Void) -> Void)?
    var onThumbnailSizeChanged: ((NativeLibraryThumbnailSize) -> Void)?
    private var thumbnailSize: NativeLibraryThumbnailSize = .medium
    private var viewportWidth: CGFloat = 1100
    private let mode: Mode
    private let searchField = NSSearchField()
    private let sortPopup = NSPopUpButton()
    private let filtersView = NativeWorkshopFiltersView()
    private let filterButton = NSButton(title: "筛选结果", target: nil, action: nil)
    private var galleryLeading: NSLayoutConstraint!
    private var controlsTop: NSLayoutConstraint!
    private var inspectorWidth: NSLayoutConstraint!
    private var inspectorPreviewHeight: NSLayoutConstraint!
    private let discoveryOrder = NSSegmentedControl(labels: ["热门", "最新发布", "最近更新"], trackingMode: .selectOne, target: nil, action: nil)
    private let gallery = NativeLibraryGallery()
    private let galleryScroll = NSScrollView()
    private let previewImage = NSImageView()
    private let previewContainer = NSView()
    private let emptySelection = NSTextField(wrappingLabelWithString: "请选择一个壁纸")
    private var inspectorContent: NSStackView!
    private let previewStatus = NSTextField(wrappingLabelWithString: "选择一项查看预览。")
    private let previewRetry = NSButton(title: "重试预览", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "准备查询 Steam 创意工坊。")
    private let selectedTitle = NSTextField(wrappingLabelWithString: "选择一张壁纸")
    private let detail = NSTextField(wrappingLabelWithString: "从 Steam 创意工坊选择壁纸查看详情。")
    private let operation = NSTextField(labelWithString: "")
    private let previous = NSButton(title: "上一页", target: nil, action: nil)
    private let next = NSButton(title: "下一页", target: nil, action: nil)
    private let subscriptionAction = NSButton(title: "订阅", target: nil, action: nil)
    private let favoriteAction = NSButton(title: "添加到收藏", target: nil, action: nil)
    /// Build 26168761's `workshopratingstars.html` is a compact rating row:
    /// static stars become the two vote controls on hover, while its heart is
    /// held at the right edge. Keep this as a lazy property because the heart
    /// is the same explicit favorite action used by the old detail surface.
    private lazy var workshopRating = WorkshopRatingView(favoriteAction: favoriteAction) { [weak self] direction in
        self?.requestSelectedUserVote(direction)
    }
    private let apply = NSButton(title: "下载并设为桌面壁纸", target: nil, action: nil)
    // These effects are injected in isolated GUI checks, so tests never open
    // an external application or write to the user's real pasteboard.
    private let workshopComment = NSButton(title: "评论", target: nil, action: nil)
    private let copyWorkshopURL = NSButton(title: "复制 URL", target: nil, action: nil)
    private let workshopActions = NSStackView()
    private var openExternalWorkshopURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    private var copyWorkshopURLToPasteboard: (String) -> Bool = { value in
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
    private let thumbnails: NativeWorkshopThumbnails
    private var page: WorkshopBrowsePage?
    private var selectedID: String?
    private var history = ["*"]
    private var index = 0
    private var activeQuery = ""
    private var activeSort = WorkshopBrowseRequest.Sort.trend
    private var activeFilters = WorkshopBrowseFilters.empty
    private var generation = 0
    private var loading = false
    private var requested = false
    private var active = false
    private var rebuilding = false
    /// A confirmation is deliberately injectable so isolated GUI checks never
    /// present a sheet, while production still requires an affirmative choice.
    private var confirmUnsubscribe: ((WorkshopBrowsePage.Item, @escaping (Bool) -> Void) -> Void)?
    /// All account-scoped keys use a UInt64 identity. The UI may retain a
    /// legal raw spelling (for example `000201`) for its share URL, but it
    /// must never make a second account mutation for the same Steam item.
    private var pendingSubscriptionIDs = Set<UInt64>()
    /// Match the official favorite operation to a numeric Steam identity so
    /// legal raw aliases such as `000201` and `201` cannot race two writes.
    private var pendingFavoriteIDs = Set<UInt64>()
    /// A personal-vote write shares the account-mutation fence with the
    /// subscription and favorite controls.  In particular, raw aliases such
    /// as `000201` and `201` must never expose competing account writes.
    private var pendingUserVoteIDs = Set<UInt64>()
    /// Nil is intentionally different from an empty snapshot: it means the
    /// account/session has not supplied a complete, current subscription list.
    /// Browse-row flags then remain presentation metadata, never authorization
    /// to mutate this account.
    private var subscribedIDs: Set<UInt64>?
    /// Nil means the current Steam account has not supplied an authoritative
    /// full favorite list. Public browse metadata must never authorize a write.
    private var favoriteIDs: Set<UInt64>?
    /// A nil subscription snapshot means the account/session changed or is
    /// unconfirmed. Bump only for that invalidation edge so an old callback
    /// cannot re-enable or refresh a later account's browser state.
    private var subscriptionSessionGeneration = 0
    /// Increment only when the favorite snapshot loses its account authority;
    /// an old completion can then neither refresh nor re-enable a new session.
    private var favoriteSessionGeneration = 0
    /// The Browser owns presentation freshness.  The coordinator echoes this
    /// monotonically increasing token in a receipt; callbacks for an earlier
    /// selection, result page, or invalidated account must be ignored.
    private var userVoteSelectionGeneration: UInt64 = 0
    private var userVoteSessionGeneration: UInt64 = 0
    private var userVoteSelectionIdentity: UInt64?
    private var userVoteSelectionPageGeneration: Int?
    private var displayedUserVote: WorkshopUserVote?
    private var displayedUserVoteIdentity: UInt64?
    private var displayedUserVotePageGeneration: Int?
    private var userVoteReadSelectionGeneration: UInt64?
    private var userVoteReadSessionGeneration: UInt64?
    private var pendingSearch: (request: WorkshopBrowseRequest, index: Int, history: [String])?
    private let sortValues: [WorkshopBrowseRequest.Sort] = [.trend, .relevant, .published, .updated]
    private let discoverySortValues: [WorkshopBrowseRequest.Sort] = [.trend, .published, .updated]
    private var selectedItem: WorkshopBrowsePage.Item? { page?.items.first { $0.id == selectedID } }

    init(mode: Mode, thumbnails: NativeWorkshopThumbnails? = nil) {
        self.mode = mode; self.thumbnails = thumbnails ?? NativeWorkshopThumbnails()
        super.init(nibName: nil, bundle: nil)
        let content = NSView(); view = content
        searchField.placeholderString = "搜索"
        searchField.setAccessibilityLabel("搜索 Steam 创意工坊")
        searchField.target = self; searchField.action = #selector(search)
        searchField.maximumRecents = 0
        sortPopup.addItems(withTitles: ["热门", "相关性", "最新发布", "最近更新"])
        sortPopup.setAccessibilityLabel("创意工坊排序")
        sortPopup.target = self; sortPopup.action = #selector(search)
        discoveryOrder.selectedSegment = 0
        discoveryOrder.target = self; discoveryOrder.action = #selector(search)
        discoveryOrder.setAccessibilityLabel("发现壁纸")
        let searchButton = NSButton(title: mode == .discover ? "刷新" : "搜索", target: self, action: #selector(search))
        filterButton.setButtonType(.pushOnPushOff)
        filterButton.target = self; filterButton.action = #selector(toggleFilters)
        filterButton.identifier = NSUserInterfaceItemIdentifier("toggleWorkshopFilters")
        filterButton.toolTip = "显示或隐藏筛选条件；收起面板会保留筛选。"
        filtersView.isHidden = true
        filtersView.onChange = { [weak self] _ in
            guard let self else { return }
            self.filterButton.title = self.filtersView.isDefault ? "筛选结果" : "筛选结果（已筛选）"
            self.search()
        }
        let controls = NSStackView(views: mode == .discover ? [discoveryOrder, filterButton, NSView(), searchButton] : [searchField, filterButton, NSView(), sortPopup, searchButton])
        controls.orientation = .horizontal; controls.spacing = 8
        searchField.widthAnchor.constraint(equalToConstant: 260).isActive = true
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sortPopup.setContentHuggingPriority(.required, for: .horizontal)
        let layout = NativeLibraryGalleryLayout()
        gallery.collectionViewLayout = layout
        gallery.isSelectable = true; gallery.allowsMultipleSelection = false
        gallery.backgroundColors = [.clear]; gallery.dataSource = self; gallery.delegate = self
        gallery.register(NativeLibraryGalleryItem.self, forItemWithIdentifier: NativeLibraryGalleryItem.reuseIdentifier)
        gallery.setAccessibilityLabel(mode == .discover ? "发现壁纸缩略图" : "创意工坊搜索结果")
        gallery.onChoose = { [weak self] index in self?.selectItem(at: index) }
        gallery.onActivate = { [weak self] in self?.downloadSelected() }
        gallery.onContextMenu = { [weak self] index in self?.thumbnailContextMenu(at: index) }
        galleryScroll.hasVerticalScroller = true; galleryScroll.borderType = .noBorder
        galleryScroll.drawsBackground = false; galleryScroll.documentView = gallery
        previewImage.imageScaling = .scaleProportionallyUpOrDown
        previewImage.setAccessibilityLabel("Steam 创意工坊壁纸预览")
        previewStatus.font = .systemFont(ofSize: 11); previewStatus.textColor = .secondaryLabelColor
        previewStatus.maximumNumberOfLines = 3
        previewRetry.target = self; previewRetry.action = #selector(retryPreview); previewRetry.isHidden = true
        selectedTitle.font = .systemFont(ofSize: 17, weight: .semibold); selectedTitle.maximumNumberOfLines = 3
        selectedTitle.alignment = .center
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        previewImage.translatesAutoresizingMaskIntoConstraints = false
        previewContainer.addSubview(previewImage)
        NSLayoutConstraint.activate([
            previewImage.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor, constant: 10),
            previewImage.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor, constant: -10),
            previewImage.topAnchor.constraint(equalTo: previewContainer.topAnchor),
            previewImage.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor)
        ])
        emptySelection.font = NativeLibraryBrowserStyle.font(16.8)
        emptySelection.textColor = NSColor(white: 0.6, alpha: 1); emptySelection.alignment = .center
        let inspector = NSStackView(views: [emptySelection, previewContainer, previewStatus, previewRetry, selectedTitle, workshopRating, detail, subscriptionAction, apply, workshopActions])
        inspectorContent = inspector
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 12
        inspector.detachesHiddenViews = true
        inspector.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        for child in [emptySelection, previewContainer, previewStatus, selectedTitle, workshopRating, detail] {
            child.widthAnchor.constraint(equalTo: inspector.widthAnchor, constant: -20).isActive = true
        }
        inspectorPreviewHeight = previewContainer.heightAnchor.constraint(equalToConstant: 260)
        inspectorPreviewHeight.isActive = true
        let inspectorScroll = NSScrollView()
        inspectorScroll.hasVerticalScroller = true; inspectorScroll.drawsBackground = false
        inspectorScroll.contentView = WorkshopInspectorClipView(); inspectorScroll.documentView = inspector
        inspectorScroll.contentView.drawsBackground = false
        inspector.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        operation.font = .systemFont(ofSize: 11); operation.textColor = .secondaryLabelColor
        operation.lineBreakMode = .byTruncatingTail
        previous.target = self; previous.action = #selector(previousPage)
        next.target = self; next.action = #selector(nextPage)
        subscriptionAction.target = self; subscriptionAction.action = #selector(changeSelectedSubscription)
        subscriptionAction.identifier = NSUserInterfaceItemIdentifier("workshopSubscriptionAction")
        subscriptionAction.setAccessibilityLabel("更改 Steam 创意工坊订阅状态")
        favoriteAction.target = self; favoriteAction.action = #selector(changeSelectedFavorite)
        favoriteAction.identifier = NSUserInterfaceItemIdentifier("workshopFavoriteAction")
        favoriteAction.setAccessibilityLabel("更改 Steam 创意工坊收藏状态")
        // Stable Steam's rating row presents a heart-only favorite control at
        // the far right. The descriptive Chinese verb remains in the
        // accessibility label and tooltip, not beside the glyph.
        favoriteAction.title = ""
        favoriteAction.imagePosition = .imageOnly
        apply.target = self; apply.action = #selector(downloadSelected)
        workshopComment.target = self; workshopComment.action = #selector(openSelectedWorkshop)
        workshopComment.identifier = NSUserInterfaceItemIdentifier("workshopComment")
        workshopComment.toolTip = "在创意工坊中打开"
        workshopComment.setAccessibilityLabel("在 Steam 创意工坊中打开并查看评论")
        copyWorkshopURL.target = self; copyWorkshopURL.action = #selector(copySelectedWorkshopURL)
        copyWorkshopURL.identifier = NSUserInterfaceItemIdentifier("workshopCopyURL")
        copyWorkshopURL.toolTip = "复制 URL"
        copyWorkshopURL.setAccessibilityLabel("复制创意工坊 URL")
        workshopActions.orientation = .horizontal; workshopActions.spacing = 8
        workshopActions.alignment = .centerY
        workshopActions.addArrangedSubview(workshopComment)
        workshopActions.addArrangedSubview(copyWorkshopURL)
        workshopActions.setAccessibilityLabel("创意工坊链接操作")
        let buttons = NSStackView(views: [previous, next]); buttons.orientation = .horizontal; buttons.spacing = 8
        buttons.setContentHuggingPriority(.required, for: .horizontal)
        operation.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for child in [controls, filtersView, galleryScroll, inspectorScroll, status, operation, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(child)
        }
        galleryLeading = galleryScroll.leadingAnchor.constraint(equalTo: controls.leadingAnchor)
        controlsTop = controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 38)
        inspectorWidth = inspectorScroll.widthAnchor.constraint(equalToConstant: 320)
        NSLayoutConstraint.activate([
            controlsTop,
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: inspectorScroll.leadingAnchor),
            status.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: 18),
            galleryScroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 8),
            galleryLeading,
            filtersView.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            filtersView.widthAnchor.constraint(equalToConstant: 230),
            filtersView.topAnchor.constraint(equalTo: galleryScroll.topAnchor),
            filtersView.bottomAnchor.constraint(equalTo: galleryScroll.bottomAnchor),
            galleryScroll.trailingAnchor.constraint(equalTo: inspectorScroll.leadingAnchor),
            galleryScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            inspectorScroll.topAnchor.constraint(equalTo: content.topAnchor),
            inspectorScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            inspectorWidth,
            inspectorScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            inspector.leadingAnchor.constraint(equalTo: inspectorScroll.contentView.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: inspectorScroll.contentView.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: inspectorScroll.contentView.topAnchor),
            operation.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            operation.trailingAnchor.constraint(equalTo: buttons.leadingAnchor, constant: -12),
            operation.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
            buttons.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        updateSelection()
    }
    required init?(coder: NSCoder) { nil }

    func updateBrowserGeometry(viewportWidth: CGFloat) {
        self.viewportWidth = viewportWidth
        gallery.updateThumbnailPresentation(size: thumbnailSize, viewportWidth: viewportWidth)
        let geometry = NativeLibraryBrowserGeometry(viewportWidth: viewportWidth)
        controlsTop.constant = geometry.headerHeight
        inspectorWidth.constant = geometry.detailWidth
        inspectorPreviewHeight.constant = geometry.previewHeight
    }
    func updateThumbnailSize(_ size: NativeLibraryThumbnailSize) {
        thumbnailSize = size
        gallery.updateThumbnailPresentation(size: size, viewportWidth: viewportWidth)
    }
    func updateSubscribedIDs(_ ids: Set<String>?) {
        let canonical: Set<UInt64>?
        if let ids {
            var values = Set<UInt64>()
            for raw in ids {
                guard let identity = Self.subscriptionIdentity(for: raw) else {
                    // A purportedly complete snapshot with an invalid ID is
                    // not usable for account mutations; fail closed.
                    canonical = nil
                    subscribedIDs = nil
                    subscriptionSessionGeneration &+= 1
                    pendingSubscriptionIDs.removeAll()
                    invalidateUserVotes()
                    reloadGallery(); updateSelection()
                    return
                }
                values.insert(identity)
            }
            canonical = values
        } else {
            canonical = nil
            subscriptionSessionGeneration &+= 1
            if !pendingSubscriptionIDs.isEmpty {
                pendingSubscriptionIDs.removeAll()
                updateOperationStatus("Steam 订阅状态已变化；未确认的订阅请求已取消。")
            }
            invalidateUserVotes()
        }
        guard subscribedIDs != canonical else { return }
        subscribedIDs = canonical
        reloadGallery(); updateSelection()
    }
    /// The coordinator only supplies this list after it has verified a complete
    /// favorite snapshot for the account that owns the visible subscription
    /// session. A nil or malformed list therefore revokes write authority
    /// rather than treating cards as "not favorited".
    func updateFavoriteIDs(_ ids: Set<String>?) {
        let canonical: Set<UInt64>?
        if let ids {
            var values = Set<UInt64>()
            for raw in ids {
                guard let identity = Self.subscriptionIdentity(for: raw), values.insert(identity).inserted else {
                    favoriteIDs = nil
                    favoriteSessionGeneration &+= 1
                    if !pendingFavoriteIDs.isEmpty {
                        pendingFavoriteIDs.removeAll()
                        updateOperationStatus("Steam 收藏状态已变化；未确认的收藏请求已取消。")
                    }
                    invalidateUserVotes()
                    reloadGallery(); updateSelection()
                    return
                }
            }
            canonical = values
        } else {
            canonical = nil
            favoriteSessionGeneration &+= 1
            if !pendingFavoriteIDs.isEmpty {
                pendingFavoriteIDs.removeAll()
                updateOperationStatus("Steam 收藏状态已变化；未确认的收藏请求已取消。")
            }
            invalidateUserVotes()
        }
        guard favoriteIDs != canonical else { return }
        favoriteIDs = canonical
        reloadGallery(); updateSelection()
    }
    /// Revoke the displayed personal vote whenever the host tells us the
    /// Steam account, authorization, or trusted vote read has expired.  A
    /// remote SET cannot be cancelled, but its late completion has no right
    /// to restore this now-unknown presentation or re-enable another session.
    func invalidateUserVotes() {
        userVoteSessionGeneration &+= 1
        userVoteSelectionGeneration &+= 1
        userVoteSelectionIdentity = nil
        userVoteSelectionPageGeneration = nil
        displayedUserVote = nil
        displayedUserVoteIdentity = nil
        displayedUserVotePageGeneration = nil
        userVoteReadSelectionGeneration = nil
        userVoteReadSessionGeneration = nil
        pendingUserVoteIDs.removeAll()
        updateControls()
        updateWorkshopRating()
    }
    private func thumbnailContextMenu(at index: Int?) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        menu.addItem(NativeLibraryThumbnailMenu.item(selected: thumbnailSize) { [weak self] size in
            guard let self else { return }
            if let onThumbnailSizeChanged = self.onThumbnailSizeChanged { onThumbnailSizeChanged(size) }
            else { self.updateThumbnailSize(size) }
        })
        // Public Build 26168761's grid context menu operates on the item
        // under the pointer rather than changing the current detail selection.
        // Capture the page generation too, so a stale menu cannot act after a
        // newer Steam query has replaced its results.
        guard active, !loading, let index, let page, page.items.indices.contains(index) else { return menu }
        let item = page.items[index], expectedGeneration = generation
        guard Self.workshopURL(for: item.id) != nil else { return menu }
        menu.addItem(.separator())
        let open = WorkshopSourceActionMenuItem(title: "在创意工坊中打开") { [weak self] in
            self?.openWorkshop(item, expectedGeneration: expectedGeneration)
        }
        open.identifier = NSUserInterfaceItemIdentifier("workshopContextOpen")
        menu.addItem(open)
        let targetFavorited = !isFavorited(item)
        let favorite = WorkshopSourceActionMenuItem(title: favoriteActionTitle(for: item)) { [weak self] in
            self?.requestFavoriteChange(item, favorited: targetFavorited, expectedGeneration: expectedGeneration)
        }
        favorite.identifier = NSUserInterfaceItemIdentifier("workshopContextFavorite")
        favorite.isEnabled = favoriteIDs != nil && onFavoriteChange != nil
            && Self.subscriptionIdentity(for: item.id).map { !accountMutationPending($0) } == true
        menu.addItem(favorite)
        let targetSubscribed = !isSubscribed(item)
        let subscribe = WorkshopSourceActionMenuItem(title: subscriptionActionTitle(for: item)) { [weak self] in
            self?.requestSubscriptionChange(item, subscribed: targetSubscribed, expectedGeneration: expectedGeneration)
        }
        subscribe.identifier = NSUserInterfaceItemIdentifier("workshopContextSubscription")
        subscribe.isEnabled = subscribedIDs != nil && onSubscriptionChange != nil
            && Self.subscriptionIdentity(for: item.id).map { !accountMutationPending($0) } == true
        menu.addItem(subscribe)
        return menu
    }

    @objc private func toggleFilters() {
        filtersView.isHidden = filterButton.state != .on
        galleryLeading.constant = filtersView.isHidden ? 0 : 230
        view.layoutSubtreeIfNeeded()
        if !gallery.selectionIndexPaths.isEmpty { gallery.scrollToItems(at: gallery.selectionIndexPaths, scrollPosition: .nearestHorizontalEdge) }
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        if !value {
            generation += 1; loading = false; thumbnails.cancelAll()
            updateControls(); return
        }
        if let pendingSearch { load(pendingSearch.request, targetIndex: pendingSearch.index, newHistory: pendingSearch.history) }
        else if !requested { search() }
        else { reloadGallery(); updateSelection() }
    }
    func updateOperationStatus(_ text: String) { operation.stringValue = text; operation.toolTip = text }

    @objc private func search() {
        guard active else { return }
        let values = mode == .discover ? discoverySortValues : sortValues
        let choice = mode == .discover ? discoveryOrder.selectedSegment : sortPopup.indexOfSelectedItem
        let sort = values[max(0, min(values.count - 1, choice))]
        do {
            let request = try WorkshopBrowseRequest(query: mode == .discover ? "" : searchField.stringValue, sort: sort.rawValue, cursor: "*", filters: filtersView.filters)
            load(request, targetIndex: 0, newHistory: ["*"])
        } catch { setStatus("搜索词过长或包含不支持的控制字符。") }
    }
    @objc private func previousPage() {
        guard active, !loading, index > 0 else { return }
        let target = index - 1
        guard let request = try? WorkshopBrowseRequest(query: activeQuery, sort: activeSort.rawValue, cursor: history[target], filters: activeFilters) else { return }
        load(request, targetIndex: target, newHistory: history)
    }
    @objc private func nextPage() {
        guard active, !loading, let cursor = page?.nextCursor else { return }
        guard let request = try? WorkshopBrowseRequest(query: activeQuery, sort: activeSort.rawValue, cursor: cursor, filters: activeFilters) else { return }
        load(request, targetIndex: index + 1, newHistory: Array(history.prefix(index + 1)) + [cursor])
    }
    private func load(_ request: WorkshopBrowseRequest, targetIndex: Int, newHistory: [String], preserving selectionID: String? = nil) {
        guard active, let onBrowse else { setStatus("Steam 查询服务不可用。"); return }
        generation += 1; let expected = generation
        // The old card can remain visible during pagination/loading, but its
        // account-scoped read belongs to the old page epoch. Do not carry a
        // personal vote across that boundary.
        prepareUserVoteSelection(for: selectedItem)
        updateWorkshopRating()
        thumbnails.cancelAll()
        pendingSearch = (request, targetIndex, newHistory)
        requested = true; loading = true; updateControls()
        setStatus("正在查询 Steam 创意工坊…")
        onBrowse(request) { [weak self] result, error in
            guard let self, self.active, self.generation == expected else { return }
            self.loading = false; self.pendingSearch = nil
            guard let result else {
                self.setStatus((error ?? "查询未完成，请重试。") + (self.page == nil ? "" : " 仍显示上次查询结果。"))
                self.reloadGallery(); self.updateSelection(); return
            }
            self.page = result; self.history = newHistory; self.index = targetIndex
            self.activeQuery = request.query; self.activeSort = request.sort
            self.selectedID = selectionID.flatMap { candidate in result.items.contains(where: { $0.id == candidate }) ? candidate : nil }
            self.activeFilters = request.filters
            self.reloadGallery(); self.updateSelection()
            self.galleryScroll.contentView.scroll(to: .zero)
            let cached = result.cached ? " · Steam 缓存结果" : ""
            let unavailable = result.unavailable > 0 ? " · \(result.unavailable) 项访问未确认" : ""
            self.setStatus("第 \(targetIndex + 1) 页 · 返回 \(result.items.count) 项 · 约 \(result.total) 项匹配\(cached)\(unavailable)")
            if result.items.isEmpty { self.detail.stringValue = targetIndex == 0 ? "没有匹配结果。" : "没有更多结果。" }
        }
    }
    private func setStatus(_ text: String) { status.stringValue = text; status.toolTip = text }
    private func updateControls() {
        previous.isEnabled = active && !loading && index > 0
        next.isEnabled = active && !loading && page?.nextCursor != nil
        let itemActionsEnabled = active && !loading && selectedItem.flatMap { Self.workshopURL(for: $0.id) } != nil
        apply.isEnabled = itemActionsEnabled
        let subscriptionEnabled = itemActionsEnabled && subscribedIDs != nil && onSubscriptionChange != nil
            && selectedItem.flatMap { Self.subscriptionIdentity(for: $0.id) }.map { !accountMutationPending($0) } == true
        subscriptionAction.isEnabled = subscriptionEnabled
        let favoriteEnabled = itemActionsEnabled && favoriteIDs != nil && onFavoriteChange != nil
            && selectedItem.flatMap { Self.subscriptionIdentity(for: $0.id) }.map { !accountMutationPending($0) } == true
        favoriteAction.isEnabled = favoriteEnabled
        let userVoteEnabled = itemActionsEnabled && onUserVoteChange != nil
            && selectedItem.flatMap { Self.subscriptionIdentity(for: $0.id) }.map { identity in
                displayedUserVote != nil
                    && displayedUserVoteIdentity == identity
                    && displayedUserVotePageGeneration == generation
                    && userVoteSelectionIdentity == identity
                    && userVoteSelectionPageGeneration == generation
                    && !accountMutationPending(identity)
            } == true
        workshopRating.setVoteActionsEnabled(userVoteEnabled)
        workshopComment.isEnabled = itemActionsEnabled
        copyWorkshopURL.isEnabled = itemActionsEnabled
    }
    /// Render the native counterpart of stable Steam's `workshop-rating`
    /// directive. Public aggregate votes decide only its stars; the small
    /// up/down state can originate solely in a fresh account-scoped GET.
    private func updateWorkshopRating() {
        guard let item = selectedItem else {
            workshopRating.update(positiveRate: nil, hasConfirmedVotes: false, userVote: nil,
                                  favorite: false, favoriteAvailable: false)
            return
        }
        let identity = Self.subscriptionIdentity(for: item.id)
        let trustedVote: WorkshopUserVote?
        if let identity,
           displayedUserVoteIdentity == identity,
           displayedUserVotePageGeneration == generation,
           userVoteSelectionIdentity == identity,
           userVoteSelectionPageGeneration == generation {
            trustedVote = displayedUserVote
        } else {
            trustedVote = nil
        }
        workshopRating.update(positiveRate: item.positiveRate, hasConfirmedVotes: item.hasConfirmedVotes,
                              userVote: trustedVote, favorite: isFavorited(item),
                              favoriteAvailable: favoriteIDs != nil)
    }
    /// The confirmed account snapshot, rather than stale public browse-row
    /// flags, decides whether this account is subscribed. `SteamSubscription`
    /// excludes locally-disabled (state 64) items before it reaches this set.
    private func isSubscribed(_ item: WorkshopBrowsePage.Item) -> Bool {
        guard let identity = Self.subscriptionIdentity(for: item.id) else { return false }
        return subscribedIDs?.contains(identity) == true
    }
    private static func subscriptionIdentity(for raw: String) -> UInt64? {
        guard SteamLibraryIndex.validID(raw), let identity = UInt64(raw), identity > 0 else { return nil }
        return identity
    }
    /// The coordinator retains a shared account-mutation reservation through
    /// each post-write snapshot. Mirror that reservation in the UI: a
    /// subscription and favorite for the same canonical Steam item cannot both
    /// appear clickable merely because their per-feature callbacks differ.
    private func accountMutationPending(_ identity: UInt64) -> Bool {
        pendingSubscriptionIDs.contains(identity) || pendingFavoriteIDs.contains(identity) || pendingUserVoteIDs.contains(identity)
    }
    private func subscriptionActionTitle(for item: WorkshopBrowsePage.Item) -> String {
        guard subscribedIDs != nil else { return "订阅状态未确认" }
        return isSubscribed(item) ? "取消订阅" : "订阅"
    }
    /// Unlike the public Browse API's optional row `favorite` decoration,
    /// only the authenticated full-account snapshot above decides this value.
    private func isFavorited(_ item: WorkshopBrowsePage.Item) -> Bool {
        guard let identity = Self.subscriptionIdentity(for: item.id) else { return false }
        return favoriteIDs?.contains(identity) == true
    }
    /// These are the public stable-build Simplified Chinese context labels.
    /// The detail control uses the same verb so its accessible state does not
    /// disagree with a card's right-click menu.
    private func favoriteActionTitle(for item: WorkshopBrowsePage.Item) -> String {
        guard favoriteIDs != nil else { return "收藏状态未确认" }
        return isFavorited(item) ? "从收藏中移除" : "添加到收藏"
    }
    /// Begin a fresh presentation epoch when the selected raw card (or the
    /// page containing it) changes. `UInt64` identity deliberately unifies
    /// legal visual aliases such as `000201` and `201`, while `selectedID`
    /// retains the raw spelling for Steam's share URL.
    private func prepareUserVoteSelection(for item: WorkshopBrowsePage.Item?) {
        let identity = item.flatMap { Self.subscriptionIdentity(for: $0.id) }
        guard identity != userVoteSelectionIdentity || userVoteSelectionPageGeneration != generation else { return }
        userVoteSelectionGeneration &+= 1
        userVoteSelectionIdentity = identity
        userVoteSelectionPageGeneration = identity == nil ? nil : generation
        displayedUserVote = nil
        displayedUserVoteIdentity = nil
        displayedUserVotePageGeneration = nil
        userVoteReadSelectionGeneration = nil
        userVoteReadSessionGeneration = nil
    }
    private func requestCurrentUserVoteRefresh() {
        guard active, !loading,
              let item = selectedItem,
              let identity = Self.subscriptionIdentity(for: item.id),
              userVoteSelectionIdentity == identity,
              userVoteSelectionPageGeneration == generation,
              displayedUserVote == nil,
              userVoteReadSelectionGeneration != userVoteSelectionGeneration,
              let onUserVoteRefresh else { return }
        let selectionGeneration = userVoteSelectionGeneration
        let sessionGeneration = userVoteSessionGeneration
        let pageGeneration = generation
        userVoteReadSelectionGeneration = selectionGeneration
        userVoteReadSessionGeneration = sessionGeneration
        // Account reads, like writes, receive only the canonical decimal
        // spelling. Keep the raw ID out of this bridge and on the share URL.
        onUserVoteRefresh(String(identity), selectionGeneration) { [weak self] result in
            guard let self,
                  self.userVoteSessionGeneration == sessionGeneration,
                  self.userVoteSelectionGeneration == selectionGeneration,
                  self.userVoteReadSelectionGeneration == selectionGeneration,
                  self.userVoteReadSessionGeneration == sessionGeneration,
                  self.generation == pageGeneration,
                  self.userVoteSelectionIdentity == identity,
                  self.userVoteSelectionPageGeneration == pageGeneration,
                  self.selectedItem.flatMap({ Self.subscriptionIdentity(for: $0.id) }) == identity else { return }
            self.userVoteReadSelectionGeneration = nil
            self.userVoteReadSessionGeneration = nil
            switch result {
            case .confirmed(let receipt):
                // A coordinator receipt must still be verified at the view
                // edge: a valid response for another alias/account epoch may
                // never colour this selection's controls.
                guard receipt.workshopID == String(identity),
                      receipt.selectionGeneration == selectionGeneration else {
                    self.displayedUserVote = nil
                    self.displayedUserVoteIdentity = nil
                    self.displayedUserVotePageGeneration = nil
                    self.updateControls(); self.updateWorkshopRating()
                    return
                }
                self.displayedUserVote = receipt.vote
                self.displayedUserVoteIdentity = identity
                self.displayedUserVotePageGeneration = pageGeneration
                self.updateControls(); self.updateWorkshopRating()
            case .failed, .unconfirmed:
                // No aggregate score or historical UI state is evidence of a
                // personal vote. Leave both buttons disabled until a later,
                // independently fresh selection read succeeds.
                self.displayedUserVote = nil
                self.displayedUserVoteIdentity = nil
                self.displayedUserVotePageGeneration = nil
                self.updateControls(); self.updateWorkshopRating()
            }
        }
    }
    private func requestSelectedUserVote(_ direction: WorkshopUserVoteDirection) {
        guard active, !loading,
              let item = selectedItem,
              let identity = Self.subscriptionIdentity(for: item.id),
              userVoteSelectionIdentity == identity,
              userVoteSelectionPageGeneration == generation,
              displayedUserVote != nil,
              !accountMutationPending(identity),
              let onUserVoteChange else { return }
        let selectionGeneration = userVoteSelectionGeneration
        let sessionGeneration = userVoteSessionGeneration
        let pageGeneration = generation
        pendingUserVoteIDs.insert(identity)
        updateControls(); updateWorkshopRating()
        let action: String
        switch direction {
        case .up: action = "好评"
        case .down: action = "点踩"
        }
        updateOperationStatus("正在请求\(action) \(item.title)…")
        onUserVoteChange(String(identity), direction, selectionGeneration) { [weak self] result in
            guard let self,
                  self.userVoteSessionGeneration == sessionGeneration,
                  self.pendingUserVoteIDs.contains(identity) else { return }
            self.pendingUserVoteIDs.remove(identity)
            // Releasing an old item's reservation is legitimate, but no
            // status or visual state below may reach a newer selection.
            self.updateControls()
            guard self.userVoteSelectionGeneration == selectionGeneration,
                  self.generation == pageGeneration,
                  self.userVoteSelectionIdentity == identity,
                  self.userVoteSelectionPageGeneration == pageGeneration,
                  self.selectedItem.flatMap({ Self.subscriptionIdentity(for: $0.id) }) == identity else { return }
            switch result {
            case .confirmed(let receipt):
                let receiptMatchesDirection: Bool
                switch (direction, receipt.vote) {
                case (.up, .up), (.down, .down): receiptMatchesDirection = true
                default: receiptMatchesDirection = false
                }
                guard receipt.workshopID == String(identity),
                      receipt.selectionGeneration == selectionGeneration,
                      receiptMatchesDirection else {
                    self.displayedUserVote = nil
                    self.displayedUserVoteIdentity = nil
                    self.displayedUserVotePageGeneration = nil
                    self.updateOperationStatus("Steam 个人评分结果未确认；请重新选择壁纸后再试。")
                    self.updateControls(); self.updateWorkshopRating()
                    return
                }
                // The coordinator has already performed the exact Steam SET
                // and a same-account fresh GET. Only that returned GET state,
                // never a local click, is allowed to highlight this row.
                self.displayedUserVote = receipt.vote
                self.displayedUserVoteIdentity = identity
                self.displayedUserVotePageGeneration = pageGeneration
                self.updateOperationStatus("Steam 已同步\(action)状态。")
            case .failed(let reason):
                self.displayedUserVote = nil
                self.displayedUserVoteIdentity = nil
                self.displayedUserVotePageGeneration = nil
                self.updateOperationStatus("Steam 未能\(action)；个人评分状态未确认（\(reason)）。")
            case .unconfirmed(let reason):
                self.displayedUserVote = nil
                self.displayedUserVoteIdentity = nil
                self.displayedUserVotePageGeneration = nil
                self.updateOperationStatus("Steam 个人评分结果未确认；不会自动重试（\(reason)）。")
            }
            self.updateControls(); self.updateWorkshopRating()
        }
    }
    @objc private func changeSelectedSubscription() {
        guard let item = selectedItem else { return }
        requestSubscriptionChange(item, subscribed: !isSubscribed(item), expectedGeneration: generation)
    }
    @objc private func changeSelectedFavorite() {
        guard let item = selectedItem else { return }
        requestFavoriteChange(item, favorited: !isFavorited(item), expectedGeneration: generation)
    }
    private func requestFavoriteChange(_ item: WorkshopBrowsePage.Item, favorited: Bool, expectedGeneration: Int) {
        guard let identity = Self.subscriptionIdentity(for: item.id),
              sourceActionIsCurrent(item, expectedGeneration: expectedGeneration),
              favoriteIDs != nil,
              isFavorited(item) != favorited,
              !accountMutationPending(identity) else { return }
        guard let onFavoriteChange else {
            updateOperationStatus("Steam 收藏服务当前不可用。")
            return
        }
        let sessionGeneration = favoriteSessionGeneration
        pendingFavoriteIDs.insert(identity); updateControls()
        let action = favorited ? "添加到收藏" : "从收藏中移除"
        updateOperationStatus("正在请求\(action) \(item.title)…")
        // Account writes always receive the canonical numeric Steam ID. The
        // raw spelling remains only for UI presentation and share URLs.
        onFavoriteChange(String(identity), favorited) { [weak self] result in
            guard let self else { return }
            guard self.favoriteSessionGeneration == sessionGeneration,
                  self.pendingFavoriteIDs.contains(identity) else { return }
            self.pendingFavoriteIDs.remove(identity)
            self.updateControls()
            switch result {
            case .failed(let reason):
                self.updateOperationStatus("Steam 未能\(action)；本机副本与当前桌面未改变（\(reason)）。")
                return
            case .unconfirmed(let reason):
                self.updateOperationStatus("收藏请求结果未确认；本机副本与当前桌面未改变。请刷新收藏状态后再决定是否重试（\(reason)）。")
                return
            case .confirmed:
                break
            }
            // The coordinator emitted the same-account post-write snapshot
            // before this completion. Do not flip a local state optimistically.
            self.updateOperationStatus("Steam 已确认\(action)请求，正在同步状态…")
            guard self.selectedID == item.id,
                  self.sourceActionIsCurrent(item, expectedGeneration: expectedGeneration) else { return }
            self.refreshCurrentPage(preserving: item.id)
        }
    }
    private func requestSubscriptionChange(_ item: WorkshopBrowsePage.Item, subscribed: Bool, expectedGeneration: Int) {
        guard let identity = Self.subscriptionIdentity(for: item.id),
              sourceActionIsCurrent(item, expectedGeneration: expectedGeneration),
              subscribedIDs != nil,
              isSubscribed(item) != subscribed,
              !accountMutationPending(identity) else { return }
        guard onSubscriptionChange != nil else {
            updateOperationStatus("Steam 订阅服务当前不可用。")
            return
        }
        if subscribed {
            beginSubscriptionChange(item, subscribed: true, expectedGeneration: expectedGeneration)
        } else {
            confirmUnsubscribeChange(for: item) { [weak self] confirmed in
                guard let self, confirmed else { return }
                self.beginSubscriptionChange(item, subscribed: false, expectedGeneration: expectedGeneration)
            }
        }
    }
    private func confirmUnsubscribeChange(for item: WorkshopBrowsePage.Item, completion: @escaping (Bool) -> Void) {
        if let confirmUnsubscribe {
            confirmUnsubscribe(item, completion)
            return
        }
        guard let window = view.window else {
            updateOperationStatus("无法确认取消订阅，请在主窗口中重试。")
            return
        }
        let alert = NSAlert()
        alert.messageText = "取消订阅"
        alert.informativeText = "您确定要取消来自“\(item.title)”的订阅吗？\n\n这会向 Steam 请求取消订阅。Steam 可能在壁纸浏览窗口关闭后才删除其创意工坊文件。已保存到本机的独立副本和当前桌面不会自动删除或切换。"
        alert.addButton(withTitle: "取消订阅")
        alert.addButton(withTitle: "保留订阅")
        alert.beginSheetModal(for: window) { response in completion(response == .alertFirstButtonReturn) }
    }
    private func beginSubscriptionChange(_ item: WorkshopBrowsePage.Item, subscribed: Bool, expectedGeneration: Int) {
        guard let identity = Self.subscriptionIdentity(for: item.id),
              sourceActionIsCurrent(item, expectedGeneration: expectedGeneration),
              subscribedIDs != nil,
              isSubscribed(item) != subscribed,
              !accountMutationPending(identity),
              let onSubscriptionChange else { return }
        let sessionGeneration = subscriptionSessionGeneration
        pendingSubscriptionIDs.insert(identity); updateControls()
        let action = subscribed ? "订阅" : "取消订阅"
        updateOperationStatus("正在请求\(action) \(item.title)…")
        // Steam account actions always use the canonical numeric spelling.
        // The raw card ID remains exclusively for display and share URLs.
        onSubscriptionChange(String(identity), subscribed) { [weak self] result in
            guard let self else { return }
            guard self.subscriptionSessionGeneration == sessionGeneration,
                  self.pendingSubscriptionIDs.contains(identity) else { return }
            self.pendingSubscriptionIDs.remove(identity)
            self.updateControls()
            switch result {
            case .failed(let reason):
                self.updateOperationStatus("Steam 未能\(action)；本机副本与当前桌面未改变（\(reason)）。")
                return
            case .unconfirmed(let reason):
                self.updateOperationStatus("订阅请求结果未确认；本机副本与当前桌面未改变。请刷新订阅状态后再决定是否重试（\(reason)）。")
                return
            case .confirmed:
                break
            }
            self.updateOperationStatus("Steam 已确认\(action)请求，正在同步状态…")
            // A successful Steam callback does not imply that every visible
            // card still belongs to this request. Refresh only the unchanged
            // current selection; otherwise leave the user's new page/choice
            // untouched and let its next normal query provide fresh state.
            guard self.selectedID == item.id,
                  self.sourceActionIsCurrent(item, expectedGeneration: expectedGeneration) else { return }
            self.refreshCurrentPage(preserving: item.id)
        }
    }
    private func refreshCurrentPage(preserving selectionID: String) {
        guard active, !loading,
              let request = try? WorkshopBrowseRequest(query: activeQuery, sort: activeSort.rawValue,
                                                       cursor: history[index], filters: activeFilters) else { return }
        load(request, targetIndex: index, newHistory: history, preserving: selectionID)
    }
    private func reloadGallery() {
        rebuilding = true; gallery.reloadData()
        if let index = page?.items.firstIndex(where: { $0.id == selectedID }) {
            gallery.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        } else { gallery.selectionIndexPaths = [] }
        rebuilding = false
    }
    private func selectItem(at index: Int?) {
        guard active else { return }
        selectedID = index.flatMap { row in page.flatMap { $0.items.indices.contains(row) ? $0.items[row].id : nil } }
        rebuilding = true
        gallery.selectionIndexPaths = selectedID == nil ? [] : [IndexPath(item: index!, section: 0)]
        rebuilding = false; updateSelection()
    }
    private func updateSelection() {
        prepareUserVoteSelection(for: selectedItem)
        updateControls(); previewImage.image = nil; previewRetry.isHidden = true
        let empty = selectedItem == nil
        let hasWorkshopURL = selectedItem.flatMap { Self.workshopURL(for: $0.id) } != nil
        emptySelection.isHidden = !empty
        for child in [previewContainer, previewStatus, selectedTitle, workshopRating, detail, subscriptionAction, apply] { child.isHidden = empty }
        workshopActions.isHidden = !hasWorkshopURL
        inspectorContent.edgeInsets = NSEdgeInsets(top: empty ? 100 : 0, left: 20, bottom: 0, right: 0)
        guard let item = selectedItem else {
            selectedTitle.stringValue = "选择一张壁纸"; detail.stringValue = "从 Steam 创意工坊选择壁纸查看详情。"
            previewStatus.stringValue = "选择一项查看预览。"
            updateWorkshopRating()
            return
        }
        selectedTitle.stringValue = item.title
        let type: String
        switch item.wallpaperTypeTag {
        case "Scene": type = "场景"
        case "Video": type = "视频"
        case "Web": type = "网页"
        case "Application": type = "应用程序"
        default: type = "Steam 未标注"
        }
        let size = item.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Steam 未提供"
        // The official rate UI is a positive-vote percentage. Steam's
        // separately returned calculated score remains in the model but is
        // deliberately not relabelled as a percentage here.
        let rating: String
        if let positiveRate = item.positiveRate { rating = String(format: "%.1f%%", positiveRate * 100) }
        else { rating = item.hasConfirmedVotes ? "暂无评分" : "Steam 未提供" }
        let updated = WorkshopBrowsePage.Item.localizedUpdatedDate(item.updatedAt) ?? "Steam 未提供"
        let subscribed = isSubscribed(item)
        let favorited = isFavorited(item)
        subscriptionAction.title = subscriptionActionTitle(for: item)
        subscriptionAction.toolTip = subscribedIDs == nil ? "等待 Steam 确认当前账号的订阅状态" : subscribed ? "取消此 Steam 创意工坊订阅" : "订阅此 Steam 创意工坊壁纸"
        subscriptionAction.setAccessibilityLabel(subscriptionAction.title)
        let favoriteVerb = favoriteActionTitle(for: item)
        favoriteAction.title = ""
        favoriteAction.image = NSImage(systemSymbolName: favorited ? "heart.fill" : "heart",
                                       accessibilityDescription: favoriteVerb)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        // AppKit can restore its default image placement when a button gets a
        // fresh image after construction. Reassert the stable Steam detail
        // row's heart-only presentation for every selected-item update.
        favoriteAction.imagePosition = .imageOnly
        favoriteAction.toolTip = favoriteIDs == nil ? "等待 Steam 确认当前账号的收藏状态" : favorited ? "从 Steam 创意工坊收藏中移除" : "添加到 Steam 创意工坊收藏"
        favoriteAction.setAccessibilityLabel(favoriteVerb)
        let retention = SavedWorkshopStore.current(item.id) != nil ? "已保存到本机" : subscribedIDs == nil ? "Steam 订阅状态未确认" : subscribed ? "已订阅；选用时保存到本机" : "未订阅；下载后保存到本机"
        let favoriteStatus = favoriteIDs == nil ? "Steam 收藏状态未确认" : favorited ? "已收藏" : "未收藏"
        detail.stringValue = "创意工坊 ID：\(item.id)\n类型：\(type)\n文件大小：\(size)\n好评率：\(rating)\n最近更新：\(updated)\n\(retention) · \(favoriteStatus)\n下载并设为桌面壁纸不会自动订阅。兼容情况在下载后确认。"
        if !item.tags.isEmpty { detail.stringValue += "\n标签：" + item.tags.joined(separator: " · ") }
        updateWorkshopRating()
        requestCurrentUserVoteRefresh()
        previewStatus.stringValue = item.previewURL == nil ? "此条目的预览暂不可用。" : "正在读取 Steam 预览…"
        loadImage(item)
    }
    private func loadImage(_ item: WorkshopBrowsePage.Item, retry: Bool = false) {
        guard active, let url = item.previewURL,
              page?.items.contains(where: { $0.id == item.id && $0.previewURL == url }) == true else { return }
        let expected = generation
        thumbnails.load(url, retry: retry) { [weak self] image in
            guard let self, self.active, self.generation == expected else { return }
            if let row = self.page?.items.firstIndex(where: { $0.id == item.id }),
               let cell = self.gallery.item(at: IndexPath(item: row, section: 0)) as? NativeLibraryGalleryItem,
               cell.representedIdentity == item.id { cell.setThumbnail(image) }
            if self.selectedID == item.id {
                self.previewImage.image = image
                self.previewStatus.stringValue = image == nil ? "预览暂不可用，可继续选择或下载壁纸。" : "Steam 创意工坊预览"
                self.previewRetry.isHidden = image != nil
            }
        }
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { page?.items.count ?? 0 }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: NativeLibraryGalleryItem.reuseIdentifier, for: indexPath) as! NativeLibraryGalleryItem
        guard let page, page.items.indices.contains(indexPath.item) else { return cell }
        let item = page.items[indexPath.item]
        let accountState = subscribedIDs == nil ? "订阅状态未确认" : isSubscribed(item) ? "已订阅" : "创意工坊"
        cell.configure(identity: item.id, title: item.title, type: accountState,
                       state: item.state & 4 != 0 ? "Steam 已安装" : "可下载", current: false, available: true,
                       badges: NativeLibraryThumbnailBadge.known(tags: Set(item.tags), installed: item.state & 4 != 0), size: thumbnailSize) { [weak self] in
            guard let self else { return }
            self.selectItem(at: self.page?.items.firstIndex { $0.id == item.id })
        }
        cell.setThumbnail(item.previewURL.flatMap { thumbnails.image(for: $0) })
        // makeItem precedes collectionView.item(at:); defer until it is attached.
        DispatchQueue.main.async { [weak self, weak cell] in
            guard let self, cell?.representedIdentity == item.id else { return }
            self.loadImage(item)
        }
        return cell
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if !rebuilding { selectItem(at: collectionView.selectionIndexPaths.first?.item) }
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if !rebuilding { selectItem(at: collectionView.selectionIndexPaths.first?.item) }
    }
    @objc private func retryPreview() { if let selectedItem { loadImage(selectedItem, retry: true) } }
    @objc private func downloadSelected() {
        guard active, !loading, let item = selectedItem else { return }
        updateOperationStatus("已请求下载 \(item.title)…"); onDownload?(item.id)
    }
    @objc private func openSelectedWorkshop() {
        guard let item = selectedItem else { return }
        openWorkshop(item, expectedGeneration: generation)
    }
    @objc private func copySelectedWorkshopURL() {
        guard let item = selectedItem else { return }
        copyWorkshopURL(item, expectedGeneration: generation)
    }
    private static func workshopURL(for id: String) -> URL? {
        // Keep the stable client’s raw-ID URL rendering, but do not surface
        // actions for malformed, zero, or out-of-range Steam identifiers.
        // UInt64 accepts legal leading zeroes, so it is validation only; the
        // original validated string is deliberately retained below.
        guard SteamLibraryIndex.validID(id), let numericID = UInt64(id), numericID > 0 else { return nil }
        // This is the exact stable-build getWorkshopUrl() endpoint. The
        // parser's ASCII-decimal validation makes this interpolation safe.
        // Retain the original Workshop ID string just like Steam's own
        // helper, including any legal leading zeroes.
        return URL(string: "https://steamcommunity.com/sharedfiles/filedetails/?id=\(id)")
    }
    private func sourceActionIsCurrent(_ item: WorkshopBrowsePage.Item, expectedGeneration: Int) -> Bool {
        active && !loading && generation == expectedGeneration && page?.items.contains(where: { $0.id == item.id }) == true
    }
    private func openWorkshop(_ item: WorkshopBrowsePage.Item, expectedGeneration: Int) {
        guard sourceActionIsCurrent(item, expectedGeneration: expectedGeneration),
              let url = Self.workshopURL(for: item.id) else { return }
        guard openExternalWorkshopURL(url) else {
            updateOperationStatus("无法打开 \(item.title) 的创意工坊页面。")
            return
        }
        updateOperationStatus("已打开 \(item.title) 的创意工坊页面。")
    }
    private func copyWorkshopURL(_ item: WorkshopBrowsePage.Item, expectedGeneration: Int) {
        guard sourceActionIsCurrent(item, expectedGeneration: expectedGeneration),
              let url = Self.workshopURL(for: item.id) else { return }
        guard copyWorkshopURLToPasteboard(url.absoluteString) else {
            updateOperationStatus("无法复制创意工坊 URL。")
            return
        }
        updateOperationStatus("已复制 URL。")
    }
}

@MainActor
private final class WorkshopSourceActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler; super.init(title: title, action: nil, keyEquivalent: "")
        target = self; action = #selector(invoke)
    }
    required init(coder: NSCoder) { fatalError("Not archived") }
    @objc private func invoke() { handler() }
}

/// Native AppKit rendition of Steam stable Build 26168761's
/// `workshopratingstars.html`. Its normal state is five aggregate-rating
/// stars; hovering temporarily exposes only explicit down/up controls, with
/// the favorite heart fixed at the trailing edge.
@MainActor
private final class WorkshopRatingView: NSView {
    private static let steamBlue = NSColor(srgbRed: 41.0 / 255.0, green: 115.0 / 255.0, blue: 243.0 / 255.0, alpha: 1)
    private static let steamPink = NSColor(srgbRed: 1, green: 54.0 / 255.0, blue: 210.0 / 255.0, alpha: 1)
    private let favoriteAction: NSButton
    private let onVote: (WorkshopUserVoteDirection) -> Void
    private let starRow = NSStackView()
    private let voteActions = NSStackView()
    private let downVote = NSButton(title: "", target: nil, action: nil)
    private let upVote = NSButton(title: "好评", target: nil, action: nil)
    private var stars: [NSImageView] = []
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var voteActionsEnabled = false
    private var currentVote: WorkshopUserVote?

    init(favoriteAction: NSButton, onVote: @escaping (WorkshopUserVoteDirection) -> Void) {
        self.favoriteAction = favoriteAction
        self.onVote = onVote
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel("Steam 创意工坊评分")

        starRow.orientation = .horizontal
        starRow.identifier = NSUserInterfaceItemIdentifier("workshopRatingStars")
        starRow.alignment = .centerY
        starRow.spacing = 1
        starRow.detachesHiddenViews = true
        for _ in 0..<5 {
            let star = NSImageView()
            star.imageScaling = .scaleProportionallyUpOrDown
            star.setContentHuggingPriority(.required, for: .horizontal)
            star.widthAnchor.constraint(equalToConstant: 15).isActive = true
            star.heightAnchor.constraint(equalToConstant: 16).isActive = true
            star.setAccessibilityElement(false)
            stars.append(star)
            starRow.addArrangedSubview(star)
        }

        for button in [downVote, upVote] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        downVote.action = #selector(requestDownVote)
        downVote.identifier = NSUserInterfaceItemIdentifier("workshopVoteDown")
        downVote.image = NSImage(systemSymbolName: "hand.thumbsdown", accessibilityDescription: "点踩")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        downVote.imagePosition = .imageOnly
        downVote.toolTip = "点踩"
        downVote.setAccessibilityLabel("点踩")
        upVote.action = #selector(requestUpVote)
        upVote.identifier = NSUserInterfaceItemIdentifier("workshopVoteUp")
        upVote.image = NSImage(systemSymbolName: "hand.thumbsup", accessibilityDescription: "好评")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        upVote.imagePosition = .imageLeading
        upVote.toolTip = "好评"
        upVote.setAccessibilityLabel("好评")
        voteActions.orientation = .horizontal
        voteActions.identifier = NSUserInterfaceItemIdentifier("workshopRatingVoteActions")
        voteActions.alignment = .centerY
        voteActions.spacing = 4
        voteActions.detachesHiddenViews = true
        voteActions.addArrangedSubview(downVote)
        voteActions.addArrangedSubview(upVote)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 4
        row.detachesHiddenViews = true
        row.addArrangedSubview(starRow)
        row.addArrangedSubview(voteActions)
        let spring = NSView()
        spring.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spring.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spring)
        row.addArrangedSubview(favoriteAction)
        addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 24)
        ])
        updateHoveredPresentation()
        update(positiveRate: nil, hasConfirmedVotes: false, userVote: nil, favorite: false, favoriteAvailable: false)
    }
    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateHoveredPresentation()
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateHoveredPresentation()
    }
    /// Used only by the isolated AppKit harness appended to this source. It
    /// does not synthesize a click or contact Steam; it checks the same hover
    /// transition that the tracking area above invokes in a visible window.
    fileprivate func setHoveredForTesting(_ value: Bool) {
        hovered = value
        updateHoveredPresentation()
    }
    func setVoteActionsEnabled(_ enabled: Bool) {
        voteActionsEnabled = enabled
        downVote.isEnabled = enabled
        upVote.isEnabled = enabled
        let stateSuffix = enabled ? "" : "（等待 Steam 确认个人评分状态）"
        downVote.toolTip = "点踩" + stateSuffix
        upVote.toolTip = "好评" + stateSuffix
    }
    func update(positiveRate: Double?, hasConfirmedVotes: Bool, userVote: WorkshopUserVote?,
                favorite: Bool, favoriteAvailable: Bool) {
        currentVote = userVote
        let rounded: Int
        if let positiveRate, hasConfirmedVotes {
            rounded = min(5, max(0, Int((positiveRate * 5).rounded())))
        } else {
            rounded = 0
        }
        let tint = rounded > 0 ? Self.steamBlue : .secondaryLabelColor
        for (index, star) in stars.enumerated() {
            let name = index < rounded ? "star.fill" : "star"
            star.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            star.contentTintColor = tint
        }
        let aggregate: String
        if let positiveRate, hasConfirmedVotes {
            aggregate = String(format: "评分：%.1f%%", positiveRate * 100)
        } else if hasConfirmedVotes {
            aggregate = "评分：暂无评分"
        } else {
            aggregate = "评分：Steam 未提供"
        }
        let personal: String
        switch userVote {
        case .up?: personal = "已好评"
        case .down?: personal = "已点踩"
        case .none?: personal = "尚未评分"
        case .skipped?: personal = "已跳过评分"
        case nil: personal = "个人评分状态未确认"
        }
        toolTip = aggregate + " · " + personal
        setAccessibilityLabel(aggregate + "，" + personal)
        starRow.setAccessibilityLabel(aggregate)
        let isUp: Bool
        let isDown: Bool
        switch userVote {
        case .up?: isUp = true; isDown = false
        case .down?: isUp = false; isDown = true
        default: isUp = false; isDown = false
        }
        upVote.state = isUp ? .on : .off
        downVote.state = isDown ? .on : .off
        upVote.contentTintColor = isUp ? Self.steamBlue : nil
        downVote.contentTintColor = isDown ? Self.steamBlue : nil
        favoriteAction.contentTintColor = favorite && favoriteAvailable ? Self.steamPink : nil
        setVoteActionsEnabled(voteActionsEnabled)
    }
    @objc private func requestDownVote() { onVote(.down) }
    @objc private func requestUpVote() { onVote(.up) }
    private func updateHoveredPresentation() {
        // The stable client toggles visibility rather than presenting a
        // second rating mode. Keep that interaction even when an account
        // state is unknown; buttons then remain visibly disabled.
        starRow.isHidden = hovered
        voteActions.isHidden = !hovered
    }
}

private final class WorkshopInspectorClipView: NSClipView {
    override var isFlipped: Bool { true }
}
