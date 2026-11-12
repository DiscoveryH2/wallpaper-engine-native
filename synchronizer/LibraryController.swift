import AppKit
import Foundation

private final class LibraryInspectorClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class LibraryBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // Resolve the dynamic color when drawing, including appearance changes.
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// User selection of a supported, installed wallpaper requests playback. List
/// rebuilding and current-project restoration only update the browser selection.
@MainActor
final class LibraryController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    enum Purpose { case defaultWallpaper, displaySelection }
    private let purpose: Purpose
    var onChooseProject: ((URL, String) -> Void)?
    var onFinish: ((Bool) async throws -> Void)?
    var onSelect: ((URL) -> Void)?
    var onDownload: (() -> Void)?
    var onBrowse: ((WorkshopBrowseRequest, @escaping (WorkshopBrowsePage?, String?) -> Void) -> Void)?
    var onSyncSubscriptions: (() -> Void)?
    var onDownloadSubscription: ((String) -> Void)?
    /// Explicit account mutation from an online browser item.  The host must
    /// invoke completion on the main thread exactly once after Steam confirms
    /// or rejects the requested state.
    var onSubscriptionChange: ((String, Bool, @escaping (WorkshopSubscriptionChangeResult) -> Void) -> Void)?
    /// Explicit account favorite mutation from an online browser item. The
    /// host confirms it only after a fresh same-account favorite snapshot.
    var onFavoriteChange: ((String, Bool, @escaping (WorkshopFavoriteChangeResult) -> Void) -> Void)?
    /// Account-scoped personal vote reads and writes are passed through only
    /// for an already-selected online Workshop item. Their generation token is
    /// opaque to LibraryController and must reach the coordinator unchanged.
    var onUserVoteRefresh: ((String, UInt64, @escaping (WorkshopUserVoteReadResult) -> Void) -> Void)?
    var onUserVoteChange: ((String, WorkshopUserVoteDirection, UInt64, @escaping (WorkshopUserVoteChangeResult) -> Void) -> Void)?
    var onShowTransfers: (() -> Void)?
    var onCreate: (() -> Void)?
    var onEdit: ((URL) -> Void)?
    var onPreview: ((URL) -> Void)?
    var onCancelPreview: (() -> Void)?
    var onCancelProjectLoad: (() -> Void)?
    var onRetryProjectLoad: (() -> Void)?
    var onOpenLocal: (() -> Void)?
    var onOpenStatic: (() -> Void)?
    var onOpenURL: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    var onProperties: (() -> Void)?
    var onApplyProperties: ((URL, [String: Any], [String: URL]) async throws -> (count: Int, payload: [String: Any]))?
    /// Target-aware property application.  Keep the original callback for
    /// hosts that only implement the historical default-desktop behaviour.
    var onApplyPropertiesForTarget: ((URL, NativeDisplayTarget, [String: Any], [String: URL]) async throws -> (count: Int, payload: [String: Any]))?
    var onDisplays: (() -> Void)?
    var onPlaybackSettings: (() -> Void)?
    var onCompatibility: (() -> Void)?
    /// The legacy default-desktop callbacks remain available to existing
    /// hosts. New hosts receive the exact default/UUID/session target key.
    var onSelectForTarget: ((URL, String) -> Void)?
    var onPlaylistChange: ((NativePlaylist) throws -> Void)?
    var onPlaylistChangeForTarget: ((NativePlaylist, String) throws -> Void)?
    var onPlaylistSelect: ((NativePlaylistEntry) -> Void)?
    var onPlaylistSelectForTarget: ((NativePlaylistEntry, String) -> Void)?
    var onDisplaysForTarget: ((String) -> Void)?
    private let playlistPanel = NativePlaylistPanel()
    private var playlistHeight: NSLayoutConstraint?
    private var playlist = NativePlaylist()
    private var playlistError: String?
    private var displayTarget: NativeDisplayTarget = .defaultWallpaper
    private var displayTargetTitle: String?
    private var displayContextGeneration = 0
    private var playlistSettings: NativePlaylistSettingsController?
    private var playlistCollections: NativePlaylistCollectionsController?
    private var hotkeyAssignment: NativeAssignHotkeyController?
    private let navigation = NativeLibraryNavigation()
    private var browserHeader: NativeLibraryBrowserHeader?
    private var browserFooter: NativeLibraryFooter?
    private var finishTask: Task<Void, Never>?
    private var closeAccepted = false
    private let finishBlocker = NativeLibraryFinishBlocker()
    private var browserHeaderHeight: NSLayoutConstraint?
    private var browserHeaderTrailing: NSLayoutConstraint?
    private var installedControlsTop: NSLayoutConstraint?
    private var installedInspectorWidth: NSLayoutConstraint?
    private var installedPreviewHeight: NSLayoutConstraint?
    private var installedSortWidth: NSLayoutConstraint?
    private let pageHost = NSView()
    private let installedContent = NSView()
    private var browserPages: [NativeLibraryNavigation.Page: WorkshopBrowserController] = [:]
    private let table = NativeLibraryTable()
    private let scroll = NSScrollView()
    private let gallery = NativeLibraryGallery()
    private let galleryScroll = NSScrollView()
    private var thumbnailSize = NativeLibraryThumbnailSize.stored()
    private let viewMode = NSSegmentedControl(labels: ["缩略图", "列表"], trackingMode: .selectOne, target: nil, action: nil)
    private var selection = NativeLibrarySelection()
    private var selectionDisplacedByPlayback = false
    private var selectedIdentity: String? {
        get { selection.primary }
        set { selection.primary = newValue }
    }
    private let dragOwner = UUID()
    private let dragSource = NativeLibraryDragSource()
    private var activeDrag: UUID?
    private var dropHighlight: String?
    private var shouldRestoreCurrentSelection = true
    private var shouldRevealImportedSelection = false
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 40 * 1024 * 1024; cache.countLimit = 100
        return cache
    }()
    private let thumbnailQueue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "io.wallpaper-engine-native.library-thumbnails"
        queue.qualityOfService = .utility; queue.maxConcurrentOperationCount = 2
        return queue
    }()
    private var thumbnailGeneration = 0
    private var thumbnailOperations: [String: BlockOperation] = [:]
    private let search = NSSearchField()
    private let kindFilter = NSPopUpButton()
    private let sourceFilter = NSPopUpButton()
    private let sortOrder = NSPopUpButton()
    private let sortDirection = NSButton(title: "▲", target: nil, action: nil)
    private let createFolderButton = NSButton(title: "创建文件夹", target: nil, action: nil)
    private let folderNavigationRow = NSStackView()
    private let folderPath = NSPathControl()
    private var folders = NativeLibraryFolders()
    private var foldersLoadError: String?
    private var currentFolderID: String?
    private let installedFilterButton = NSButton(title: "筛选结果", target: nil, action: nil)
    private var installedFilterState = NativeInstalledFilterState.stored()
    private var installedFiltersView: NativeInstalledFiltersView?
    private var installedListLeading: NSLayoutConstraint?
    private var installedFiltersVisible = UserDefaults.standard.bool(forKey: "libraryInstalledFiltersVisible")
    private let counts = NSTextField(labelWithString: "正在读取壁纸库…")
    private let currentLabel = NSTextField(labelWithString: "尚未打开壁纸")
    private let revealButton = NSButton(title: "定位默认项目", target: nil, action: nil)
    private let preview = NSImageView()
    private let previewStatus = NSTextField(wrappingLabelWithString: "选择壁纸查看预览")
    private let selectedTitle = NSTextField(wrappingLabelWithString: "选择一张壁纸")
    private let detail = NSTextField(wrappingLabelWithString: "单击已安装的壁纸即可切换桌面。")
    private let propertyContainer = NSStackView()
    private var propertyProject: WallpaperProject?
    private var inlineProperties: WallpaperPropertiesController?
    private var propertyContentWidth: NSLayoutConstraint?
    private let steamStatus = NSTextField(labelWithString: "Steam：正在检查连接…")
    private let operationStatus = NSTextField(labelWithString: "")
    private let operationRow = NSStackView()
    private let applyButton = NSButton(title: "设为默认壁纸", target: nil, action: nil)
    private let cancelLoadButton = NSButton(title: "取消加载", target: nil, action: nil)
    private let failurePanel = NSStackView()
    private let failureLabel = NSTextField(wrappingLabelWithString: "")
    private let retryLoadButton = NSButton(title: "重试加载", target: nil, action: nil)
    private var projectLoading = false
    private var loadFailureRetryable = false
    private let editButton = NSButton(title: "编辑我的作品…", target: nil, action: nil)
    private let livePreviewButton = NSButton(title: "动态预览", target: nil, action: nil)
    private let cancelPreviewButton = NSButton(title: "取消预览", target: nil, action: nil)
    private let livePreviewHint = NSTextField(wrappingLabelWithString: "在独立窗口中播放，桌面保持当前壁纸。Scene 与 Video 预览静音。")
    private let playbackButton = NSButton(title: "暂停桌面", target: nil, action: nil)
    private let propertiesButton = NSButton(title: "壁纸设置…", target: nil, action: nil)
    private let compatibilityButton = NSButton(title: "兼容情况…", target: nil, action: nil)
    private let playbackLabel = NSTextField(labelWithString: "尚未打开壁纸")
    private var previewLoading = false
    private var applyTitle: String { purpose == .displaySelection ? "使用此壁纸" : "设为默认壁纸" }
    private var selectionHint: String { purpose == .displaySelection ? "选择后返回显示器设置，点击应用后生效。" : "单击已安装壁纸即可切换默认桌面；独立屏幕保持自己的选择。" }

    private struct Item: Equatable {
        let project: URL?
        let title: String
        let type: String
        let id: String
        let library: URL?
        let isInstalling: Bool
        let subscription: SteamSubscription?
        let saved: SavedWorkshopStore.Record?
        var created: NativeCreationStore.Record? = nil
        var bundled: NativeBundledWallpapers.Record? = nil
        var filterMetadata = NativeInstalledFilterMetadata(object: [:])
        var folder: NativeLibraryFolders.Folder? = nil
        var isFavorite: Bool? = nil
        var folderKey: String {
            if !id.isEmpty { return id }
            if let created { return "created:" + created.id.uuidString }
            if let bundled { return "bundled:" + bundled.id }
            if let project, let local = NativeLocalWallpapers.identity(for: project) { return local }
            return project?.standardizedFileURL.path ?? identity
        }
        var filterEntry: NativeInstalledFilterState.Entry {
            var entry = filterMetadata.entry(title: title, type: type, workshop: !id.isEmpty,
                publishedTags: subscription?.publishedTags, publishedMobilePermission: subscription?.allowMobileUpload)
            entry.favorite = isFavorite ?? subscription?.favorite ?? false; return entry
        }
        var sortEntry: NativeInstalledSort.Entry {
            .init(title: title, rating: subscription?.score ?? 0, favorite: isFavorite ?? subscription?.favorite ?? false,
                filesize: subscription?.sizeBytes.map(Double.init) ?? saved.map { Double($0.bytes) } ?? 0,
                subscriptiondate: subscription?.subscribedAt.map(Double.init) ?? 0,
                updatedate: subscription?.updatedAt.map(Double.init) ?? created?.savedAt.timeIntervalSince1970 ?? filterMetadata.modifiedAt)
        }
        var identity: String { folder.map { "folder:" + $0.id } ?? project?.path ?? "subscription:" + id }
        var supported: Bool { ["web", "video", "scene", "image"].contains(type.lowercased()) }
        var typeTitle: String {
            switch type.lowercased() {
            case "scene": return "场景"; case "web": return "网页"; case "video": return "视频"; case "image": return "静态图片"
            case "application": return "应用程序"; case "folder": return "文件夹"; default: return type.isEmpty ? "待确认" : type
            }
        }
        var canApply: Bool { !isInstalling && (project != nil ? supported : subscription?.available == true && subscription?.enabled == true) }
        static func == (a: Self, b: Self) -> Bool {
            a.identity == b.identity && a.title == b.title && a.type == b.type && a.id == b.id && a.library == b.library && a.isInstalling == b.isInstalling
                && a.saved?.version == b.saved?.version && a.saved?.bytes == b.saved?.bytes && a.saved?.savedAt == b.saved?.savedAt
                && a.created?.version == b.created?.version && a.created?.savedAt == b.created?.savedAt
                && a.bundled == b.bundled
                && a.subscription?.id == b.subscription?.id && a.subscription?.enabled == b.subscription?.enabled
                && a.subscription?.available == b.subscription?.available && a.subscription?.needsDownload == b.subscription?.needsDownload
                && a.subscription?.state == b.subscription?.state
                && a.subscription?.publishedTags == b.subscription?.publishedTags
                && a.subscription?.allowMobileUpload == b.subscription?.allowMobileUpload
                && a.subscription?.favorite == b.subscription?.favorite && a.subscription?.score == b.subscription?.score
                && a.subscription?.subscribedAt == b.subscription?.subscribedAt && a.subscription?.updatedAt == b.subscription?.updatedAt
                && a.subscription?.sizeBytes == b.subscription?.sizeBytes && a.filterMetadata == b.filterMetadata && a.folder == b.folder && a.isFavorite == b.isFavorite
        }
    }
    private enum Kind: String, CaseIterable {
        case all, scene, web, video, other
        var title: String {
            switch self { case .all: return "全部类型"; case .scene: return "场景"; case .web: return "网页"; case .video: return "视频"; case .other: return "其他 / 待确认" }
        }
    }
    private enum Source: String, CaseIterable {
        case all, saved, steam, subscribed, remote, local, created, bundled
        var title: String {
            switch self { case .all: return "全部来源"; case .saved: return "本机已保存"; case .steam: return "Steam 本地"; case .subscribed: return "我的订阅"; case .remote: return "待下载"; case .local: return "本地文件"; case .created: return "我的作品"; case .bundled: return "内置壁纸" }
        }
    }
    private var kind: Kind = Kind(rawValue: UserDefaults.standard.string(forKey: "libraryKindFilter") ?? "") ?? .all
    private var source: Source = Source(rawValue: UserDefaults.standard.string(forKey: "librarySourceFilter") ?? "") ?? .all
    private var order = NativeInstalledSort.stored()
    private var items: [Item] = []
    private var visibleItems: [Item] = []
    private var currentItem: Item?
    private var subscriptions: [SteamSubscription]?
    private var favoriteIDs: Set<String>?
    private var scanInFlight = false
    private var scanAgain = false
    private var forcePreviewPending = false
    private var rebuilding = false
    private var warnings: [String] = []
    private var previewGeneration = 0
    private var previewIdentity: String?
    private var previewOperation: BlockOperation?
    private let discoveryQueue = DispatchQueue(label: "io.wallpaper-engine-native.library-discovery", qos: .utility)
    private let previewQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.wallpaper-engine-native.library-preview"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var selectedItem: Item? { visibleItems.first { $0.identity == selectedIdentity } }

    init(purpose: Purpose = .defaultWallpaper) {
        self.purpose = purpose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Wallpaper Engine Native · 壁纸库"
        window.minSize = NSSize(width: 900, height: 680)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        if purpose == .displaySelection {
            kind = .all; source = .all; order = .init(); installedFilterState = .init(); installedFiltersVisible = false
            window.title = "Wallpaper Engine Native · 为显示器选择壁纸"
        }
        if purpose == .defaultWallpaper {
            do { playlist = try NativePlaylistStore.active().lists["default"] ?? NativePlaylist() }
            catch { playlistError = error.localizedDescription }
            if let data = UserDefaults.standard.data(forKey: NativeLibraryFolders.preferenceKey) {
                do { folders = try NativeLibraryFolders(data: data) } catch { foldersLoadError = error.localizedDescription }
            }
            if let stored = UserDefaults.standard.string(forKey: "libraryCurrentFolderV1"), folders.folder(stored) != nil { currentFolderID = stored }
        }
        window.delegate = self
        let root = NativeLibraryBrowserSurface(); window.contentView = root
        let content = installedContent
        pageHost.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(pageHost)
        content.translatesAutoresizingMaskIntoConstraints = false; pageHost.addSubview(content)
        NSLayoutConstraint.activate([
            pageHost.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: purpose == .defaultWallpaper ? 19 : 0),
            pageHost.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: purpose == .defaultWallpaper ? -19 : 0),
            pageHost.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: purpose == .defaultWallpaper ? -63 : 0),
            pageHost.topAnchor.constraint(equalTo: root.topAnchor, constant: purpose == .defaultWallpaper ? 1 : 0),
            content.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            content.topAnchor.constraint(equalTo: pageHost.topAnchor),
            content.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)
        ])
        navigation.onSelect = { [weak self] page in self?.showPage(page) }
        let heading = NSTextField(labelWithString: "选择壁纸")
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        let create = NSButton(title: "壁纸编辑器", target: self, action: #selector(createProject))
        let openLocal = NSButton(title: "打开壁纸", target: self, action: #selector(openLocalProject))
        openLocal.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "打开壁纸菜单")
        openLocal.imagePosition = .imageTrailing
        create.identifier = NSUserInterfaceItemIdentifier("browserEditor")
        openLocal.identifier = NSUserInterfaceItemIdentifier("browserOpenWallpaper")
        create.font = NativeLibraryBrowserStyle.font(14)
        openLocal.font = NativeLibraryBrowserStyle.font(14)
        let subtitle = NSTextField(wrappingLabelWithString: selectionHint)
        subtitle.textColor = .secondaryLabelColor
        if purpose == .defaultWallpaper {
            let actions = NativeLibraryFooter(target: self, editorAction: #selector(createProject), openAction: #selector(openLocalProject),
                confirmAction: #selector(confirmBrowser), cancelAction: #selector(cancelBrowser))
            browserFooter = actions
            let header = NativeLibraryBrowserHeader(navigation: navigation, target: self,
                displaysAction: #selector(showDisplays), settingsAction: #selector(showPlaybackSettings))
            header.identifier = NSUserInterfaceItemIdentifier("browserHeader")
            browserHeader = header
            browserHeaderHeight = header.heightAnchor.constraint(equalToConstant: 38)
            browserHeaderTrailing = header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -339)
            for view in [header, actions] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                header.topAnchor.constraint(equalTo: pageHost.topAnchor),
                browserHeaderHeight!, browserHeaderTrailing!,
                actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 19),
                actions.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -19),
                actions.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -19),
                actions.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
        search.placeholderString = "搜索"
        search.toolTip = "搜索名称或创意工坊 ID"
        search.setAccessibilityLabel("搜索本机壁纸库")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.maximumRecents = 0
        for (control, titles) in [(kindFilter, Kind.allCases.map(\.title)), (sourceFilter, Source.allCases.map(\.title))] {
            control.addItems(withTitles: titles)
            control.target = self; control.action = #selector(filtersChanged)
        }
        kindFilter.selectItem(at: Kind.allCases.firstIndex(of: kind) ?? 0)
        sourceFilter.selectItem(at: Source.allCases.firstIndex(of: source) ?? 0)
        sortOrder.addItems(withTitles: NativeInstalledSort.Criterion.allCases.map(\.title))
        sortOrder.selectItem(at: NativeInstalledSort.Criterion.allCases.firstIndex(of: order.criterion) ?? 0)
        sortOrder.target = self; sortOrder.action = #selector(sortChanged)
        sortOrder.identifier = NSUserInterfaceItemIdentifier("installedSortOrder")
        sortOrder.menu?.autoenablesItems = false
        sortOrder.item(at: NativeInstalledSort.Criterion.allCases.firstIndex(of: .favorite)!)?.isEnabled = false
        sortDirection.target = self; sortDirection.action = #selector(reverseSort)
        sortDirection.identifier = NSUserInterfaceItemIdentifier("installedSortDirection")
        sortDirection.setAccessibilityLabel("切换排序方向")
        sortDirection.title = order.descending ? "▼" : "▲"; sortDirection.bezelStyle = .rounded
        sortDirection.widthAnchor.constraint(equalToConstant: purpose == .defaultWallpaper ? 14 : 28).isActive = true
        if purpose == .defaultWallpaper { sortDirection.isBordered = false; sortDirection.font = NativeLibraryBrowserStyle.font(14) }
        kindFilter.setAccessibilityLabel("壁纸类型")
        sourceFilter.setAccessibilityLabel("壁纸来源")
        sortOrder.setAccessibilityLabel("壁纸排序")
        let reset = NSButton(title: "清除筛选", target: self, action: #selector(resetFilters))
        viewMode.target = self; viewMode.action = #selector(changeViewMode)
        viewMode.selectedSegment = UserDefaults.standard.string(forKey: "libraryViewMode") == "list" ? 1 : 0
        viewMode.setAccessibilityLabel("壁纸展示方式")
        let filters: NSStackView
        if purpose == .defaultWallpaper {
            installedFilterButton.target = self; installedFilterButton.action = #selector(toggleInstalledFilters)
            installedFilterButton.setButtonType(.pushOnPushOff); installedFilterButton.bezelStyle = .rounded
            installedFilterButton.identifier = NSUserInterfaceItemIdentifier("toggleInstalledFilters")
            installedFilterButton.state = installedFiltersVisible ? .on : .off
            let queryRow = NSStackView(views: [search, installedFilterButton, NSView(), sortDirection, sortOrder]); queryRow.spacing = 8
            // The official filter is 70 px and the direction glyph is 14 px.
            // Native button chrome plus an extra spacer gap otherwise forces
            // a 951-point window to grow to 978 when the detail panel expands.
            installedFilterButton.widthAnchor.constraint(equalToConstant: 70).isActive = true
            queryRow.setCustomSpacing(0, after: installedFilterButton)
            createFolderButton.target = self; createFolderButton.action = #selector(createFolder)
            createFolderButton.identifier = NSUserInterfaceItemIdentifier("createLibraryFolder")
            createFolderButton.isEnabled = foldersLoadError == nil; createFolderButton.toolTip = foldersLoadError
            folderNavigationRow.orientation = .horizontal; folderNavigationRow.spacing = 4
            folderNavigationRow.identifier = NSUserInterfaceItemIdentifier("libraryFolderNavigation")
            let up = NSButton(title: "↑", target: self, action: #selector(folderUp))
            up.identifier = NSUserInterfaceItemIdentifier("libraryFolderUp"); up.setAccessibilityLabel("上一级文件夹")
            folderPath.pathStyle = .standard; folderPath.isEditable = false
            folderPath.target = self; folderPath.action = #selector(folderPathChanged); folderPath.doubleAction = #selector(folderPathChanged)
            folderPath.identifier = NSUserInterfaceItemIdentifier("libraryFolderPath")
            folderNavigationRow.addArrangedSubview(up); folderNavigationRow.addArrangedSubview(folderPath)
            // The official browser has one query row. Native source filters and
            // the optional table view remain available in the context menu.
            queryRow.identifier = NSUserInterfaceItemIdentifier("installedQueryRow")
            filters = NSStackView(views: [queryRow, folderNavigationRow]); filters.orientation = .vertical
            filters.alignment = .leading; filters.spacing = 6
            filters.detachesHiddenViews = true
            queryRow.widthAnchor.constraint(equalTo: filters.widthAnchor).isActive = true
            folderNavigationRow.widthAnchor.constraint(equalTo: filters.widthAnchor).isActive = true
            search.widthAnchor.constraint(equalToConstant: 260).isActive = true
            for control in [search, installedFilterButton, sortOrder] {
                control.font = NativeLibraryBrowserStyle.font(14)
                control.heightAnchor.constraint(equalToConstant: 34).isActive = true
            }
            installedSortWidth = sortOrder.widthAnchor.constraint(equalToConstant: 220)
            installedSortWidth?.isActive = true
        } else {
            filters = NSStackView(views: [search, kindFilter, sourceFilter, sortDirection, sortOrder, reset, viewMode])
            filters.orientation = .horizontal; filters.spacing = 8
        }
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        for control in [kindFilter, sourceFilter] { control.widthAnchor.constraint(equalToConstant: 112).isActive = true }
        if purpose == .displaySelection { sortOrder.widthAnchor.constraint(equalToConstant: 112).isActive = true }
        counts.font = .systemFont(ofSize: 12); counts.textColor = .secondaryLabelColor
        counts.lineBreakMode = .byTruncatingTail
        currentLabel.font = .systemFont(ofSize: 14, weight: .semibold); currentLabel.lineBreakMode = .byTruncatingTail
        currentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        revealButton.target = self; revealButton.action = #selector(revealCurrent)
        revealButton.isEnabled = false
        playbackButton.target = self; playbackButton.action = #selector(togglePlayback)
        propertiesButton.target = self; propertiesButton.action = #selector(showProperties)
        compatibilityButton.target = self; compatibilityButton.action = #selector(showCompatibility)
        for button in [playbackButton, propertiesButton, compatibilityButton] { button.isEnabled = false }
        playbackLabel.font = .systemFont(ofSize: 12); playbackLabel.textColor = .secondaryLabelColor
        playbackLabel.lineBreakMode = .byTruncatingTail
        playbackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let currentPanel = NSView() // Zero-height spacer in the separate display picker.
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        table.delegate = self; table.dataSource = self
        table.rowHeight = 42; table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = purpose == .defaultWallpaper
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (name, title, width, minimum) in [("title", "名称", 285.0, 180.0), ("type", "类型", 62.0, 58.0), ("state", "状态", 210.0, 155.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = title; column.width = width; column.minWidth = minimum
            table.addTableColumn(column)
        }
        table.target = self; table.doubleAction = #selector(acceptSelected)
        scroll.documentView = table
        let galleryLayout = NativeLibraryGalleryLayout()
        galleryLayout.configure(size: thumbnailSize, viewportWidth: 1100)
        gallery.collectionViewLayout = galleryLayout
        gallery.isSelectable = true; gallery.allowsMultipleSelection = purpose == .defaultWallpaper
        gallery.backgroundColors = [.clear]
        gallery.dataSource = self; gallery.delegate = self
        gallery.register(NativeLibraryGalleryItem.self, forItemWithIdentifier: NativeLibraryGalleryItem.reuseIdentifier)
        gallery.setAccessibilityLabel("壁纸缩略图")
        gallery.onChoose = { [weak self] index in self?.selectItem(at: index, userInitiated: true) }
        gallery.onModifiedChoose = { [weak self] index,flags in self?.selectGesture(at:index,flags:flags) }
        gallery.onActivate = { [weak self] in self?.acceptSelected() }
        gallery.canActivate = { [weak self] index in self?.visibleItems.indices.contains(index) == true && self?.visibleItems[index].folder == nil }
        gallery.onSelectAll = { [weak self] in self?.selectAllLibraryItems() }
        gallery.onNavigate = { [weak self] key in self?.navigateLibrarySelection(key,grid:true) }
        if purpose == .defaultWallpaper { gallery.onRectangle = { [weak self] indexes,flags in self?.selectRectangle(indexes,flags:flags) } }
        gallery.onContextMenu = { [weak self] index in self?.libraryContextMenu(at: index) }
        table.onContextMenu = { [weak self] index in self?.libraryContextMenu(at: index) }
        table.onChoose = { [weak self] index,flags in self?.selectGesture(at:index,flags:flags) }
        table.onActivate = { [weak self] in self?.acceptSelected() }
        table.canActivate = gallery.canActivate
        table.onSelectAll = gallery.onSelectAll
        table.onNavigate = { [weak self] key in self?.navigateLibrarySelection(key,grid:false) }
        if purpose == .defaultWallpaper {
            let type = NSPasteboard.PasteboardType(NativeLibraryDragPayload.pasteboardType)
            gallery.registerForDraggedTypes([type]); table.registerForDraggedTypes([type])
            gallery.onBeginDrag = { [weak self] index,event in guard let self else { return false }; return self.beginLibraryDrag(at:index,event:event,view:self.gallery) }
            table.onBeginDrag = { [weak self] index,event in guard let self else { return false }; return self.beginLibraryDrag(at:index,event:event,view:self.table) }
            gallery.onDragUpdate = { [weak self] info in self?.validateLibraryDrop(info,grid:true) ?? [] }
            table.onDragUpdate = { [weak self] info in self?.validateLibraryDrop(info,grid:false) ?? [] }
            gallery.onDragAutoscrollValid = { [weak self] info in self?.validLibraryDragPayload(info) != nil }
            table.onDragAutoscrollValid = gallery.onDragAutoscrollValid
            gallery.onDrop = { [weak self] info in self?.acceptLibraryDrop(info,grid:true) ?? false }
            table.onDrop = { [weak self] info in self?.acceptLibraryDrop(info,grid:false) ?? false }
            gallery.onDragLeave = { [weak self] in self?.highlightDrop(nil) }
            table.onDragLeave = gallery.onDragLeave
            dragSource.onEnded = { [weak self] in
                self?.stopLibraryDragAutoscroll(); self?.activeDrag = nil; self?.highlightDrop(nil)
            }
        }
        galleryScroll.hasVerticalScroller = true; galleryScroll.borderType = .noBorder
        galleryScroll.drawsBackground = false; galleryScroll.documentView = gallery
        gallery.configureDragAutoscroll(in: galleryScroll)
        table.configureDragAutoscroll(in: scroll)
        scroll.isHidden = viewMode.selectedSegment == 0
        galleryScroll.isHidden = !scroll.isHidden
        preview.imageScaling = .scaleProportionallyUpOrDown
        let previewBackground = LibraryBackgroundView()
        previewBackground.wantsLayer = true
        preview.translatesAutoresizingMaskIntoConstraints = false
        previewBackground.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: previewBackground.leadingAnchor, constant: purpose == .defaultWallpaper ? 10 : 0),
            preview.trailingAnchor.constraint(equalTo: previewBackground.trailingAnchor, constant: purpose == .defaultWallpaper ? -10 : 0),
            preview.topAnchor.constraint(equalTo: previewBackground.topAnchor),
            preview.bottomAnchor.constraint(equalTo: previewBackground.bottomAnchor)
        ])
        preview.setAccessibilityLabel("所选壁纸的项目预览图")
        previewStatus.font = .systemFont(ofSize: 11); previewStatus.textColor = .secondaryLabelColor
        selectedTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        selectedTitle.maximumNumberOfLines = 3
        if purpose == .defaultWallpaper { selectedTitle.alignment = .center }
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        editButton.target = self; editButton.action = #selector(editSelected)
        editButton.bezelStyle = .rounded; editButton.isEnabled = false
        editButton.isHidden = purpose == .displaySelection
        livePreviewButton.target = self; livePreviewButton.action = #selector(previewSelected)
        livePreviewButton.bezelStyle = .rounded; livePreviewButton.isEnabled = false
        cancelPreviewButton.target = self; cancelPreviewButton.action = #selector(cancelPreview)
        cancelPreviewButton.identifier = NSUserInterfaceItemIdentifier("cancelWallpaperPreview")
        cancelPreviewButton.bezelStyle = .rounded; cancelPreviewButton.isHidden = true; cancelPreviewButton.isEnabled = false
        livePreviewHint.font = .systemFont(ofSize: 11); livePreviewHint.textColor = .secondaryLabelColor
        livePreviewButton.isHidden = purpose == .displaySelection; livePreviewHint.isHidden = purpose == .displaySelection
        let previewActions = NSStackView(views: [livePreviewButton, cancelPreviewButton])
        previewActions.orientation = .horizontal; previewActions.spacing = 8
        propertyContainer.orientation = .vertical; propertyContainer.alignment = .leading; propertyContainer.isHidden = true
        let inspector = NSStackView(views: [previewBackground, previewStatus, selectedTitle, previewActions, livePreviewHint, detail, propertyContainer, editButton])
        inspector.orientation = .vertical; inspector.alignment = .leading; inspector.spacing = 12
        inspector.edgeInsets = NSEdgeInsets(top: 0, left: purpose == .defaultWallpaper ? 20 : 0, bottom: 0, right: 0)
        inspector.translatesAutoresizingMaskIntoConstraints = false
        let inspectorScroll = NSScrollView()
        inspectorScroll.contentView = LibraryInspectorClipView()
        inspectorScroll.hasVerticalScroller = true; inspectorScroll.drawsBackground = false
        inspectorScroll.documentView = inspector
        for view in [previewBackground, previewStatus, selectedTitle, livePreviewHint, detail, propertyContainer] {
            view.widthAnchor.constraint(equalTo: inspector.widthAnchor, constant: purpose == .defaultWallpaper ? -20 : 0).isActive = true
        }
        installedPreviewHeight = previewBackground.heightAnchor.constraint(equalToConstant: purpose == .defaultWallpaper ? 260 : 142)
        installedPreviewHeight?.isActive = true
        for label in [steamStatus, operationStatus] {
            label.font = .systemFont(ofSize: 11); label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        applyButton.target = self; applyButton.action = #selector(applySelected)
        applyButton.bezelStyle = .rounded; applyButton.isEnabled = false
        cancelLoadButton.target = self; cancelLoadButton.action = #selector(cancelProjectLoad)
        cancelLoadButton.identifier = NSUserInterfaceItemIdentifier("cancelWallpaperLoad")
        cancelLoadButton.bezelStyle = .rounded; cancelLoadButton.isHidden = true; cancelLoadButton.isEnabled = false
        let download = NSButton(title: "从创意工坊链接下载…", target: self, action: #selector(downloadItem))
        let sync = NSButton(title: "同步我的订阅", target: self, action: #selector(syncSubscriptions))
        let reload = NSButton(title: "刷新列表", target: self, action: #selector(reloadLibrary))
        let transfers = NSButton(title: "下载与更新…", target: self, action: #selector(showTransfers))
        let buttons = NSStackView()
        if purpose == .displaySelection {
            for button in [download, sync, reload, transfers, applyButton, cancelLoadButton] { buttons.addArrangedSubview(button) }
            buttons.orientation = .horizontal; buttons.spacing = 10
        }
        if purpose == .displaySelection {
            download.isHidden = true; sync.isHidden = true; transfers.isHidden = true
            create.isHidden = true
            openLocal.isHidden = true; currentPanel.isHidden = true
            steamStatus.stringValue = "选择本机已有项目；需要新内容时，请从主壁纸库获取。"
            currentLabel.isHidden = true; revealButton.isHidden = true
        }
        failureLabel.font = .systemFont(ofSize: 12); failureLabel.textColor = .systemRed
        failureLabel.maximumNumberOfLines = 3; failureLabel.lineBreakMode = .byTruncatingTail
        failureLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        retryLoadButton.target = self; retryLoadButton.action = #selector(retryProjectLoad)
        retryLoadButton.bezelStyle = .rounded; retryLoadButton.isEnabled = false
        retryLoadButton.toolTip = "再次尝试加载这张壁纸；准备成功前保留当前壁纸。"
        retryLoadButton.setContentHuggingPriority(.required, for: .horizontal)
        retryLoadButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        failurePanel.orientation = .horizontal; failurePanel.alignment = .centerY; failurePanel.spacing = 12
        failurePanel.addArrangedSubview(failureLabel); failurePanel.addArrangedSubview(retryLoadButton)
        failurePanel.isHidden = true
        operationRow.orientation = .horizontal; operationRow.spacing = 8
        operationRow.identifier = NSUserInterfaceItemIdentifier("libraryOperationRow")
        operationRow.detachesHiddenViews = true
        let activeHeader = NSStackView()
        if purpose == .defaultWallpaper {
            operationRow.addArrangedSubview(operationStatus); operationRow.addArrangedSubview(cancelLoadButton)
            operationRow.isHidden = true
            operationStatus.setContentHuggingPriority(.defaultLow, for: .horizontal)
            operationStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cancelLoadButton.setContentCompressionResistancePriority(.required, for: .horizontal)
            for view in [failurePanel, operationRow, steamStatus] { activeHeader.addArrangedSubview(view) }
        } else {
            activeHeader.addArrangedSubview(currentPanel); activeHeader.addArrangedSubview(failurePanel)
        }
        activeHeader.identifier = NSUserInterfaceItemIdentifier("libraryActivityStatus")
        activeHeader.orientation = .vertical; activeHeader.alignment = .leading; activeHeader.spacing = purpose == .defaultWallpaper ? 6 : 12
        activeHeader.detachesHiddenViews = true
        for view in activeHeader.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: activeHeader.widthAnchor).isActive = true
        }
        var contentViews: [NSView] = [activeHeader, filters, scroll, galleryScroll, inspectorScroll]
        if purpose == .defaultWallpaper { contentViews.append(playlistPanel) }
        if purpose == .displaySelection { contentViews += [counts, steamStatus, operationStatus, buttons] }
        for view in contentViews {
            view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view)
        }
        if purpose == .displaySelection {
            for view in [heading, subtitle] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
            NSLayoutConstraint.activate([
                heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 8),
                subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
                subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                filters.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14)
            ])
        } else {
            installedControlsTop = filters.topAnchor.constraint(equalTo: content.topAnchor, constant: 38)
            installedControlsTop?.isActive = true
        }
        installedInspectorWidth = inspectorScroll.widthAnchor.constraint(equalToConstant: purpose == .defaultWallpaper ? 320 : 280)
        installedListLeading = scroll.leadingAnchor.constraint(equalTo: filters.leadingAnchor, constant: installedFiltersVisible ? 230 : 0)
        if purpose == .defaultWallpaper {
            playlistHeight = playlistPanel.heightAnchor.constraint(equalToConstant: playlistPanel.requiredHeight)
            NSLayoutConstraint.activate([
                playlistPanel.leadingAnchor.constraint(equalTo: filters.leadingAnchor),
                playlistPanel.trailingAnchor.constraint(equalTo: filters.trailingAnchor),
                playlistPanel.bottomAnchor.constraint(equalTo: activeHeader.topAnchor, constant: -8),
                playlistHeight!,
                activeHeader.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 6),
                steamStatus.heightAnchor.constraint(equalToConstant: 16),
                operationStatus.heightAnchor.constraint(equalToConstant: 16)
            ])
        } else {
            NSLayoutConstraint.activate([
                activeHeader.bottomAnchor.constraint(equalTo: steamStatus.topAnchor, constant: -12),
                currentPanel.heightAnchor.constraint(equalToConstant: 0),
                counts.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: 8),
                counts.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
                counts.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: counts.bottomAnchor, constant: 8),
                steamStatus.leadingAnchor.constraint(equalTo: filters.leadingAnchor),
                steamStatus.trailingAnchor.constraint(equalTo: filters.trailingAnchor),
                steamStatus.heightAnchor.constraint(equalToConstant: 16),
                steamStatus.bottomAnchor.constraint(equalTo: operationStatus.topAnchor, constant: -4),
                operationStatus.leadingAnchor.constraint(equalTo: filters.leadingAnchor),
                operationStatus.trailingAnchor.constraint(equalTo: filters.trailingAnchor),
                operationStatus.heightAnchor.constraint(equalToConstant: 16),
                operationStatus.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -8),
                buttons.trailingAnchor.constraint(equalTo: filters.trailingAnchor),
                buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
            ])
        }
        NSLayoutConstraint.activate([
            activeHeader.leadingAnchor.constraint(equalTo: filters.leadingAnchor),
            activeHeader.trailingAnchor.constraint(equalTo: filters.trailingAnchor),
            filters.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: purpose == .defaultWallpaper ? 0 : 16),
            filters.trailingAnchor.constraint(equalTo: purpose == .defaultWallpaper ? inspectorScroll.leadingAnchor : content.trailingAnchor,
                                              constant: purpose == .defaultWallpaper ? 0 : -16),
            installedListLeading!,
            scroll.bottomAnchor.constraint(equalTo: purpose == .defaultWallpaper ? playlistPanel.topAnchor : activeHeader.topAnchor, constant: purpose == .defaultWallpaper ? 0 : -12),
            galleryScroll.topAnchor.constraint(equalTo: scroll.topAnchor),
            galleryScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            galleryScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            galleryScroll.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            inspectorScroll.topAnchor.constraint(equalTo: purpose == .defaultWallpaper ? content.topAnchor : scroll.topAnchor),
            inspectorScroll.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: purpose == .defaultWallpaper ? 0 : 16),
            inspectorScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: purpose == .defaultWallpaper ? 0 : -16),
            installedInspectorWidth!,
            inspectorScroll.bottomAnchor.constraint(equalTo: purpose == .defaultWallpaper ? content.bottomAnchor : scroll.bottomAnchor),
            inspector.leadingAnchor.constraint(equalTo: inspectorScroll.contentView.leadingAnchor),
            inspector.trailingAnchor.constraint(equalTo: inspectorScroll.contentView.trailingAnchor),
            inspector.topAnchor.constraint(equalTo: inspectorScroll.contentView.topAnchor)
        ])
        if purpose == .defaultWallpaper {
            let sidebar = NativeInstalledFiltersView(state: installedFilterState)
            sidebar.translatesAutoresizingMaskIntoConstraints = false; sidebar.isHidden = !installedFiltersVisible
            content.addSubview(sidebar); installedFiltersView = sidebar
            NSLayoutConstraint.activate([
                sidebar.leadingAnchor.constraint(equalTo: filters.leadingAnchor),
                sidebar.topAnchor.constraint(equalTo: scroll.topAnchor),
                sidebar.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
                sidebar.widthAnchor.constraint(equalToConstant: 230)
            ])
            sidebar.onChange = { [weak self] value in
                guard let self else { return }
                self.shouldRestoreCurrentSelection = false
                self.installedFilterState = value; self.saveFilters(); self.applyFilters()
            }
            sidebar.onReset = { [weak self] in self?.resetFilters() }
        }
        root.onWidthChanged = { [weak self] width in self?.updateBrowserGeometry(width) }
        if purpose == .defaultWallpaper { configurePlaylistActions(); updatePlaylistPanel() }
        updateFolderNavigation()
        updateBrowserGeometry(root.bounds.width)
        window.center()
    }

    /// The current per-screen content target. `default` preserves the legacy
    /// library behaviour; a UUID or session key is always passed through to a
    /// target-aware host rather than silently becoming the default desktop.
    var displayTargetKey: String { displayTarget.key }

    /// Switch the library's content context after the host/monitor selector
    /// has selected one concrete target. This is intentionally synchronous:
    /// it invalidates every old-target sheet before the visible list changes,
    /// while actual project preparation remains the host callback's task.
    /// `title` is the monitor-label suffix (for example `2 · 左侧屏幕`);
    /// the header itself owns the localized `显示器 ` prefix.
    func setDisplayTarget(_ target: NativeDisplayTarget, title: String? = nil) throws {
        guard purpose == .defaultWallpaper else { return }
        let target = try target.validated()
        let next = try NativePlaylistStore.active().lists[target.key] ?? NativePlaylist()
        guard target != displayTarget || title != displayTargetTitle else { return }
        displayContextGeneration &+= 1
        // A collection conflict response may arrive after an AX sheet has
        // closed. Each controller owns a generation guard; closing here also
        // invalidates its recorder before this new target is rendered.
        playlistSettings?.close(); playlistSettings = nil
        playlistCollections?.invalidateContext(); playlistCollections = nil
        hotkeyAssignment?.close(); hotkeyAssignment = nil
        displayTarget = target; displayTargetTitle = title
        playlist = next; playlistError = nil
        browserHeader?.setDisplayContext(title: title)
        updatePlaylistPanel()
    }

    func reloadPlaylist() {
        guard purpose == .defaultWallpaper else { return }
        do { playlist = try NativePlaylistStore.active().lists[displayTarget.key] ?? NativePlaylist(); playlistError = nil }
        catch { playlistError = error.localizedDescription }
        updatePlaylistPanel()
    }
    private func playlistWallpaper(_ item: Item) -> NativePlaylistWallpaper? {
        guard item.folder == nil, !item.isInstalling, item.supported, let project = item.project else { return nil }
        return .init(key: item.folderKey, projectPath: project.standardizedFileURL.path, title: item.title,
                     type: item.type.lowercased(), workshopID: item.id.isEmpty ? nil : item.id,
                     creationID: item.created?.id, bundledID: item.bundled?.id)
    }
    private func updatePlaylistPanel() {
        guard purpose == .defaultWallpaper else { return }
        playlistPanel.update(list: playlist, selectedKey: selectedItem?.folderKey,
                             canToggle: selectedItem.flatMap(playlistWallpaper) != nil, error: playlistError)
        playlistHeight?.constant = playlistPanel.requiredHeight
    }
    private func contextMatches(_ target: NativeDisplayTarget, generation: Int) -> Bool {
        displayTarget == target && displayContextGeneration == generation
    }
    private func applyPlaylist(_ value: NativePlaylist, expectedTarget: NativeDisplayTarget? = nil,
                               expectedGeneration: Int? = nil) throws {
        var value = value; value.normalize(); _ = try value.validated()
        guard playlistError == nil else { throw NativePlaylistError.invalid(playlistError!) }
        let target = expectedTarget ?? displayTarget
        let generation = expectedGeneration ?? displayContextGeneration
        guard contextMatches(target, generation: generation) else { throw CancellationError() }
        if let onPlaylistChangeForTarget { try onPlaylistChangeForTarget(value, target.key) }
        else if target.key == "default", let onPlaylistChange { try onPlaylistChange(value) }
        else if target.persistent { try NativePlaylistStore.setActive(value, target: target.key) }
        else { throw NativePlaylistError.invalid("临时显示器内容需要由运行时确认，未写入默认桌面。") }
        guard contextMatches(target, generation: generation) else { throw CancellationError() }
        playlist = value; updatePlaylistPanel()
    }

    private func selectProject(_ project: URL) {
        let target = displayTarget
        if let onSelectForTarget { onSelectForTarget(project, target.key) }
        else if target.key == "default" { onSelect?(project) }
        else { updateStatus("当前显示器需要目标感知的运行时处理，未更改默认桌面。") }
    }
    private func togglePlaylist(clicked item: Item) {
        do {
            var next = playlist
            let targets = managementTargets(clicked: item).compactMap(playlistWallpaper)
            let limited = try next.toggle(targets)
            try applyPlaylist(next)
            if limited { updateStatus("星期播放列表不支持超过 7 张壁纸。") }
        } catch { updateStatus(error.localizedDescription) }
    }
    private func configurePlaylistActions() {
        playlistPanel.onToggle = { [weak self] in guard let self, let item = selectedItem else { return }; togglePlaylist(clicked: item) }
        playlistPanel.onClear = { [weak self] in
            guard let self else { return }; do { var next = playlist; next.entries = []; try applyPlaylist(next) } catch { updateStatus(error.localizedDescription) }
        }
        playlistPanel.onRemove = { [weak self] id in
            guard let self else { return }; do { var next = playlist; next.remove(id); try applyPlaylist(next) } catch { updateStatus(error.localizedDescription) }
        }
        playlistPanel.onMove = { [weak self] id, before in
            guard let self else { return }; do { var next = playlist; next.move(id, before: before); try applyPlaylist(next) } catch { updateStatus(error.localizedDescription) }
        }
        playlistPanel.onTime = { [weak self] id, end in
            guard let self, let index = playlist.entries.firstIndex(where: { $0.id == id }), index < playlist.entries.count - 1 else { return }
            do { var next = playlist; next.entries[index].daytimeEnd = end; try applyPlaylist(next) } catch { updateStatus(error.localizedDescription) }
        }
        playlistPanel.onSelect = { [weak self] entry in
            guard let self else { return }
            if let item = visibleItems.first(where: { $0.folderKey == entry.wallpaper.key }) { selection.choose(item.identity); syncSelectionViews(); updateDetails() }
            if let onPlaylistSelectForTarget { onPlaylistSelectForTarget(entry, displayTarget.key) }
            else if displayTarget.key == "default", let onPlaylistSelect { onPlaylistSelect(entry) }
            else {
                do { selectProject(try NativePlaylistLibrary.resolve(entry.wallpaper)) }
                catch { updateStatus(error.localizedDescription) }
            }
        }
        playlistPanel.onLoad = { [weak self] in self?.showPlaylistCollections(saving: false) }
        playlistPanel.onSave = { [weak self] in self?.showPlaylistCollections(saving: true) }
        playlistPanel.onConfigure = { [weak self] in
            guard let self, let window, window.attachedSheet == nil else { return }
            let target = displayTarget, generation = displayContextGeneration
            let settings = NativePlaylistSettingsController(list: playlist)
            settings.onApply = { [weak self] value in try self?.applyPlaylist(value, expectedTarget: target, expectedGeneration: generation) }
            playlistSettings = settings; settings.present(on: window)
        }
    }
    private func showPlaylistCollections(saving: Bool) {
        guard let window, window.attachedSheet == nil else { return }
        let target = displayTarget, generation = displayContextGeneration
        let dialog = NativePlaylistCollectionsController(saving: saving, name: playlist.name, target: target,
            isContextCurrent: { [weak self] in self?.contextMatches(target, generation: generation) == true })
        dialog.onLoad = { [weak self] value in try self?.applyPlaylist(value, expectedTarget: target, expectedGeneration: generation) }
        dialog.onSave = { [weak self] name, hotkey in
            guard let self else { return }
            let before = playlist
            do {
                try Self.saveNamedPlaylist(playlist, name: name, hotkey: hotkey, target: target) { [weak self] next in
                    try self?.applyPlaylist(next, expectedTarget: target, expectedGeneration: generation)
                }
            } catch {
                // The persistence helper has restored its three raw settings
                // keys. Keep this controller's visible active-list state in
                // lockstep if an injected active-list callback failed too.
                // A target switch invalidates this sheet, so its stale error
                // must never overwrite the newly selected display's panel.
                if self.contextMatches(target, generation: generation) {
                    self.playlist = before; self.updatePlaylistPanel()
                }
                throw error
            }
        }
        playlistCollections = dialog; dialog.present(on: window)
    }

    /// A collection Save writes the named catalog, its dynamic V2 binding,
    /// and the active list as one local transaction.  In particular, reserve
    /// the Carbon chord before touching the catalog: a macOS rejection cannot
    /// make the dialog report failure after changing the saved collection.
    ///
    /// `snapshots` deliberately begins after the recorder has accepted an
    /// overwrite. Therefore rollback preserves the reference behavior in
    /// which the former (possibly V1) owner stays removed if this Save is
    /// later cancelled or otherwise fails.
    static func saveNamedPlaylist(_ list: NativePlaylist, name rawName: String,
                                  hotkey: NativeHotkey?,
                                  target: NativeDisplayTarget = .defaultWallpaper,
                                  hotkeyService suppliedService: NativeProfileHotkeyService? = nil,
                                  apply: (NativePlaylist) throws -> Void) throws {
        let hotkeyService = suppliedService ?? NativeProfileHotkeyService.shared
        let target = try target.validated()
        guard target.persistent || hotkey == nil else {
            throw NativePlaylistError.invalid("临时显示器不能保存全局播放列表热键。")
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw NativePlaylistError.invalid("请输入播放列表名称。") }
        var proposed = list; proposed.name = name
        _ = try proposed.validated()
        guard proposed.entries.count >= 2 else { throw NativePlaylistError.invalid("至少添加两张壁纸后才能保存播放列表。") }
        let catalog = try NativePlaylistStore.saved()
        guard catalog.lists.contains(where: { $0.name == name }) || catalog.lists.count < 1_000 else {
            throw NativePlaylistError.invalid("保存的播放列表已达到大小上限。")
        }
        // Validate the whole V2 payload before a reservation and before the
        // catalog can be written. A session target is deliberately excluded:
        // it must never create, clear or inherit a persisted global binding.
        if target.persistent { _ = try NativeHotkeyBindingStore.snapshot() }
        let hotkeyTarget = NativeHotkeyTarget.playlist(name: name, location: target.hotkeyLocation)
        let keys = [NativePlaylistStore.savedKey, NativePlaylistStore.activeKey] + (target.persistent ? [NativeHotkeyBindingStore.key] : [])
        let snapshots = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        func restoreSnapshots() {
            for (key, value) in snapshots {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        var reservation: NativeProfileHotkeyReservation?
        do {
            // The following store replacement reuses and commits this exact
            // reservation. It has no post-reservation OS registration step.
            if let hotkey { reservation = try hotkeyService.reserveAvailable(hotkey, for: hotkeyTarget) }
            try NativePlaylistStore.saveNamed(proposed, name: name)
            if target.persistent {
                if let hotkey { try NativeHotkeyBindingStore.replace(hotkeyTarget, hotkey: hotkey, hotkeyService: hotkeyService) }
                else { try NativeHotkeyBindingStore.removeBinding(hotkeyTarget, hotkeyService: hotkeyService) }
            }
            try apply(proposed)
        } catch {
            reservation?.cancel()
            restoreSnapshots()
            // A successful reservation may already have been committed before
            // a later active-list write fails. Restore the registrar to the
            // restored preferences; preserve the original failure for the UI.
            try? hotkeyService.sync(force: true)
            throw error
        }
    }

    /// The path is the stable wallpaper identity. The displayed library title
    /// is descriptive only; no remote subscription, folder, installing item,
    /// or missing local project can be turned into an assignment target.
    private func wallpaperHotkeyTarget(_ item: Item) -> NativeHotkeyTarget? {
        guard displayTarget.persistent,
              item.folder == nil, !item.isInstalling, item.supported,
              let project = item.project, FileManager.default.fileExists(atPath: project.path) else { return nil }
        return .wallpaper(.init(projectPath: project.standardizedFileURL.path, title: item.title,
                                location: displayTarget.hotkeyLocation))
    }

    private func showWallpaperHotkeyAssignment(_ target: NativeHotkeyTarget) {
        guard let window else { return }
        do {
            guard try NativeHotkeyBindingStore.binding(for: target)?.hotkey == nil else {
                updateStatus("该壁纸已有热键，请使用“删除热键”。"); return
            }
            let dialog = try NativeAssignHotkeyController(target: target)
            hotkeyAssignment = dialog; dialog.present(on: window)
        } catch { updateStatus("无法分配热键，原设置已保留：" + error.localizedDescription) }
    }

    private func removeWallpaperHotkey(_ target: NativeHotkeyTarget) {
        do {
            guard try NativeHotkeyBindingStore.binding(for: target)?.hotkey != nil else {
                updateStatus("未找到该壁纸的热键，未更改设置。"); return
            }
            try NativeHotkeyBindingStore.removeBinding(target)
            updateStatus("已删除该壁纸的热键。")
        } catch { updateStatus("无法删除热键，原设置已保留：" + error.localizedDescription) }
    }

    private func updateBrowserGeometry(_ width: CGFloat) {
        guard width > 0 else { return }
        gallery.updateThumbnailPresentation(size: thumbnailSize, viewportWidth: width)
        guard purpose == .defaultWallpaper else { return }
        let geometry = NativeLibraryBrowserGeometry(viewportWidth: width)
        browserHeader?.updateGeometry(geometry)
        browserFooter?.updateGeometry(viewportWidth: width)
        playlistPanel.updateGeometry(viewportWidth: width)
        browserHeaderHeight?.constant = geometry.headerHeight
        browserHeaderTrailing?.constant = -19 - geometry.detailWidth
        installedControlsTop?.constant = geometry.headerHeight
        installedInspectorWidth?.constant = geometry.detailWidth
        installedPreviewHeight?.constant = geometry.previewHeight
        installedSortWidth?.constant = width <= 950 ? 180 : 220
        propertyContentWidth?.constant = width >= 1900 ? -30 : -10
        inlineProperties?.updateInspectorWidth(geometry.detailWidth - 20 + (propertyContentWidth?.constant ?? -10))
        browserPages.values.forEach { $0.updateBrowserGeometry(viewportWidth: width) }
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        if closeAccepted, purpose == .defaultWallpaper {
            // A new official browser starts with the active wallpaper. Keeping
            // the cancelled selection would suppress its next single click.
            selection.choose(nil)
            selectionDisplacedByPlayback = false
            shouldRestoreCurrentSelection = currentItem == nil
            if let currentItem, !items.contains(where: isCurrent) { items.append(currentItem) }
            applyFilters(preferred: currentItem)
        }
        closeAccepted = false
        refreshLibrary(forcePreview: true)
        showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        browserPages[navigation.selected]?.setActive(true)
    }
    func showWorkshop() { showPage(.workshop) }
    /// Seasonal theme prompts route to the same public Discover collection
    /// page as the Windows stable browser's "浏览收藏" action.
    func showDiscover() { showPage(.discover) }
    private func showPage(_ page: NativeLibraryNavigation.Page) {
        guard purpose == .defaultWallpaper else { return }
        let previous = navigation.selected
        navigation.setSelected(page)
        installedContent.isHidden = page != .installed
        for (key, browser) in browserPages {
            browser.view.isHidden = key != page
            if key != page { browser.setActive(false) }
        }
        if page == .installed {
            if previous != .installed { reloadGallery(clearCache: false); updateDetails(forcePreview: true) }
            window?.makeFirstResponder(search)
            return
        }
        previewGeneration += 1; previewOperation?.cancel(); previewOperation = nil; previewIdentity = nil
        thumbnailGeneration += 1; thumbnailQueue.cancelAllOperations(); thumbnailOperations.removeAll()
        let browser: WorkshopBrowserController
        if let existing = browserPages[page] { browser = existing }
        else {
            browser = WorkshopBrowserController(mode: page == .discover ? .discover : .workshop)
            browser.onBrowse = { [weak self] request, completion in
                guard let callback = self?.onBrowse else { completion(nil, "Steam 查询服务不可用。"); return }
                callback(request, completion)
            }
            browser.onDownload = { [weak self] id in self?.onDownloadSubscription?(id) }
            browser.onSubscriptionChange = { [weak self] id, subscribed, completion in
                guard let callback = self?.onSubscriptionChange else {
                    completion(.unconfirmed("steam-subscription-service-unavailable"))
                    return
                }
                callback(id, subscribed, completion)
            }
            browser.onFavoriteChange = { [weak self] id, favorited, completion in
                guard let callback = self?.onFavoriteChange else {
                    completion(.unconfirmed("steam-favorite-service-unavailable"))
                    return
                }
                callback(id, favorited, completion)
            }
            browser.onUserVoteRefresh = { [weak self] id, selectionGeneration, completion in
                guard let callback = self?.onUserVoteRefresh else {
                    completion(.unconfirmed("steam-user-vote-service-unavailable"))
                    return
                }
                callback(id, selectionGeneration, completion)
            }
            browser.onUserVoteChange = { [weak self] id, direction, selectionGeneration, completion in
                guard let callback = self?.onUserVoteChange else {
                    completion(.unconfirmed("steam-user-vote-service-unavailable"))
                    return
                }
                callback(id, direction, selectionGeneration, completion)
            }
            browser.onThumbnailSizeChanged = { [weak self] size in self?.changeThumbnailSize(size) }
            browser.updateThumbnailSize(thumbnailSize)
            browser.updateSubscribedIDs(subscriptions.map { Set($0.filter { $0.enabled }.map(\.id)) })
            browser.updateFavoriteIDs(favoriteIDs)
            browserPages[page] = browser
            let view = browser.view; view.translatesAutoresizingMaskIntoConstraints = false; pageHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: pageHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)
            ])
        }
        browser.updateOperationStatus(operationStatus.stringValue)
        browser.updateBrowserGeometry(viewportWidth: window?.contentView?.bounds.width ?? 1100)
        browser.view.isHidden = false; browser.setActive(true)
        window?.makeFirstResponder(nil)
    }
    func updateSteamConnection(_ text: String) { steamStatus.stringValue = text; steamStatus.toolTip = text }
    func updateStatus(_ text: String) {
        operationStatus.stringValue = text; operationStatus.toolTip = text
        updateOperationRow()
        browserPages.values.forEach { $0.updateOperationStatus(text) }
    }
    func updateProjectLoading(_ loading: Bool) {
        projectLoading = loading
        cancelLoadButton.isHidden = !loading || purpose == .displaySelection
        cancelLoadButton.isEnabled = loading && purpose == .defaultWallpaper
        retryLoadButton.isEnabled = !loading && loadFailureRetryable && purpose == .defaultWallpaper
        updateOperationRow()
        updatePropertyPanel()
    }
    private func updateOperationRow() {
        operationRow.isHidden = !projectLoading && operationStatus.stringValue.isEmpty
    }
    func updateLoadFailure(_ message: String?, retryable: Bool) {
        failureLabel.stringValue = message ?? ""; failureLabel.toolTip = message
        loadFailureRetryable = message != nil && retryable
        failurePanel.isHidden = message == nil || purpose == .displaySelection
        retryLoadButton.isHidden = !loadFailureRetryable
        retryLoadButton.isEnabled = loadFailureRetryable && !projectLoading && purpose == .defaultWallpaper
    }
    func updateSubscriptions(_ items: [SteamSubscription]?) {
        subscriptions = items
        let enabledIDs = items.map { Set($0.filter { $0.enabled }.map(\.id)) }
        browserPages.values.forEach { $0.updateSubscribedIDs(enabledIDs) }
        if items == nil { updateFavorites(nil) }
        refreshLibrary()
    }
    func updateFavorites(_ ids: Set<String>?) {
        favoriteIDs = ids
        browserPages.values.forEach { $0.updateFavoriteIDs(ids) }
        installedFiltersView?.setFavoritesAvailable(ids != nil)
        sortOrder.item(at: NativeInstalledSort.Criterion.allCases.firstIndex(of: .favorite)!)?.isEnabled = ids != nil
        applyFilters()
    }
    /// A hard account/session invalidation supplied by the coordinator. This
    /// differs from an in-flight vote write: the browser's own pending fence
    /// prevents that write from presenting optimistic state, while this call
    /// makes every personal-vote read unknown until its next trusted GET.
    func updateUserVotesInvalidated() {
        browserPages.values.forEach { $0.invalidateUserVotes() }
    }
    func updatePlayback(available: Bool, paused: Bool, status: String) {
        playbackButton.isEnabled = available
        playbackButton.title = paused ? "继续桌面" : "暂停桌面"
        propertiesButton.isEnabled = available; compatibilityButton.isEnabled = available
        playbackLabel.stringValue = status; playbackLabel.toolTip = status
    }
    func updateLivePreview(loading: Bool, message: String) {
        previewLoading = loading
        cancelPreviewButton.isHidden = !loading || purpose == .displaySelection
        cancelPreviewButton.isEnabled = loading && purpose == .defaultWallpaper
        livePreviewHint.stringValue = message
        livePreviewButton.title = loading ? "正在准备预览…" : "动态预览"
        updateDetails()
    }

    func setPropertyProject(_ project: WallpaperProject?, target expectedTarget: NativeDisplayTarget? = nil) {
        let target = expectedTarget ?? displayTarget
        // A late controller callback must not repopulate the newly-selected
        // monitor with the prior monitor's editor.  Also refuse a host project
        // whose loaded property scope does not match this library context.
        guard target == displayTarget,
              project?.propertyTarget == nil || project?.propertyTarget == target else { return }
        if propertyProject?.propertyScope != project?.propertyScope {
            cancelInlinePropertyEditing()
        }
        propertyProject = project
        updatePropertyPanel()
    }
    @discardableResult func cancelInlinePropertyEditing() -> Task<Void, Never>? {
        let pending = inlineProperties?.cancelPendingApply(); inlineProperties = nil
        propertyContentWidth = nil
        for view in propertyContainer.arrangedSubviews { propertyContainer.removeArrangedSubview(view); view.removeFromSuperview() }
        propertyContainer.isHidden = true
        return pending
    }
    func finishInlinePropertyEditing() -> Task<Void, Never>? { inlineProperties?.finishInlineApplications() }
    private func updatePropertyPanel() {
        guard purpose == .defaultWallpaper, !projectLoading,
              let selectedItem, selectedItem.canApply, selectedItem.project != nil, isCurrent(selectedItem),
              let project = propertyProject, project.projectURL == currentItem?.project,
              project.propertyTarget == displayTarget,
              !project.propertyDefinitions.isEmpty else {
            cancelInlinePropertyEditing(); return
        }
        if let existing = inlineProperties, existing.matches(project), propertyProject?.propertyScope == project.propertyScope {
            existing.synchronize(project); return
        }
        cancelInlinePropertyEditing()
        let properties = WallpaperPropertiesController(project: project, presentation: .inspector)
        let url = project.projectURL, target = displayTarget, generation = displayContextGeneration, scope = project.propertyScope
        properties.onApply = { [weak self, weak properties] values, media in
            guard let self, let properties, self.inlineProperties === properties,
                  !self.projectLoading, self.contextMatches(target, generation: generation),
                  self.propertyProject?.projectURL == url, self.propertyProject?.propertyScope == scope,
                  let selected = self.selectedItem, self.isCurrent(selected) else {
                throw PropertyError.invalid("壁纸已切换，请在当前壁纸的属性中调整。")
            }
            let result: (count: Int, payload: [String: Any])
            if let apply = self.onApplyPropertiesForTarget {
                result = try await apply(url, target, values, media)
            } else if let apply = self.onApplyProperties {
                // Legacy hosts own only the default record.  A non-default
                // library target must never fall through into that record.
                guard target == .defaultWallpaper else { throw PropertyError.invalid("当前显示器需要目标感知的壁纸设置处理。") }
                result = try await apply(url, values, media)
            } else {
                throw PropertyError.invalid("壁纸设置当前不可用。")
            }
            guard self.contextMatches(target, generation: generation),
                  self.propertyProject?.propertyScope == scope else { throw CancellationError() }
            return result
        }
        inlineProperties = properties
        let view = properties.inspectorView
        propertyContainer.addArrangedSubview(view)
        propertyContentWidth = view.widthAnchor.constraint(equalTo: propertyContainer.widthAnchor, constant: (window?.contentView?.bounds.width ?? 1100) >= 1900 ? -30 : -10)
        propertyContentWidth?.isActive = true
        propertyContainer.isHidden = false
        updateBrowserGeometry(window?.contentView?.bounds.width ?? 1100)
    }

    /// Called only after a controller has successfully committed a project.
    /// This says which project is active, not whether its renderer is paused.
    func setCurrentProject(_ url: URL?, title: String?, type: String?, desktop: Bool) {
        let previousProject = currentItem?.project?.standardizedFileURL
        if let url {
            let saved = SavedWorkshopStore.recordForProject(url)
            let library = SteamLibraryIndex.location(for: url)
            let id = saved?.id ?? (library == nil ? "" : url.deletingLastPathComponent().lastPathComponent)
            currentItem = Item(project: url, title: title ?? url.deletingLastPathComponent().lastPathComponent, type: type ?? "", id: id, library: library?.root, isInstalling: false, subscription: nil, saved: saved)
            currentItem?.created = NativeCreationStore.record(for: url)
            currentItem?.bundled = NativeBundledWallpapers.record(for: url)
            if let project = propertyProject, project.projectURL == url,
               let object = try? JSONSerialization.jsonObject(with: project.metadataData) as? [String: Any] {
                currentItem?.filterMetadata = .init(object: object)
            }
            currentLabel.stringValue = (desktop ? "默认桌面项目：" : "窗口预览：") + (currentItem?.title ?? "")
            currentLabel.toolTip = url.path
        } else {
            currentItem = nil; currentLabel.stringValue = "尚未打开壁纸"; currentLabel.toolTip = nil
        }
        revealButton.isEnabled = currentItem != nil
        if purpose == .defaultWallpaper, shouldRestoreCurrentSelection, let currentItem {
            // The official browser initially selects the monitor's current
            // wallpaper without asking the engine to apply it again. Restore
            // once; subsequent commits must not steal a newer user selection.
            shouldRestoreCurrentSelection = false
            if !items.contains(where: isCurrent) { items.append(currentItem) }
            applyFilters(preferred: currentItem)
            selectionDisplacedByPlayback = false
            if shouldRevealImportedSelection {
                shouldRevealImportedSelection = false
                window?.contentView?.layoutSubtreeIfNeeded()
                if !gallery.selectionIndexPaths.isEmpty { gallery.scrollToItems(at: gallery.selectionIndexPaths, scrollPosition: .nearestHorizontalEdge) }
                if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
            }
        }
        if previousProject != currentItem?.project?.standardizedFileURL {
            // Automatic playback preserves the user's browsing selection.
            // That selection becomes actionable when another wallpaper commits,
            // without restarting repeated clicks while a request is pending.
            selectionDisplacedByPlayback = selectedItem.map { !isCurrent($0) } ?? false
        }
        if !visibleItems.isEmpty { table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<visibleItems.count), columnIndexes: IndexSet(integer: 2)) }
        reloadGallery(clearCache: false)
        refreshLibrary()
    }

    @objc func reloadLibrary() { refreshLibrary(forcePreview: true) }
    func importedProjectDidCommit(_ project: URL) {
        guard purpose == .defaultWallpaper, let key = NativeLocalWallpapers.identity(for: project) else { return }
        if folders.owner(of: key) != currentFolderID {
            _ = commitFolders { try $0.move(items: [key], to: currentFolderID) }
        }
        shouldRestoreCurrentSelection = true
        shouldRevealImportedSelection = true
    }
    func refreshLibrary(forcePreview: Bool = false) {
        forcePreviewPending = forcePreviewPending || forcePreview
        guard !scanInFlight else { scanAgain = true; return }
        scanInFlight = true
        let currentProject = currentItem?.project
        discoveryQueue.async { [weak self] in
            let snapshot = SteamLibraryIndex.projects()
            let saved = SavedWorkshopStore.records()
            let created = NativeCreationStore.records()
            let bundled = NativeBundledWallpapers.records()
            let local = NativeLocalWallpapers.records()
            let urls = Set(snapshot.projects.map(\.url) + saved.items.map(\.project) + created.items.map(\.project) + bundled.items.map(\.project) + local.items.map(\.project) + (currentProject.map { [$0] } ?? []))
            let metadata = Dictionary(uniqueKeysWithValues: urls.map { ($0, NativeInstalledFilterMetadata.read($0)) })
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanInFlight = false
                let selection = self.selectedItem
                // Duplicate or stale remote entries must not crash the library.
                let subscriptions = Dictionary((self.subscriptions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let savedIDs = Set(saved.items.map(\.id))
                self.items = snapshot.projects.filter { !savedIDs.contains($0.id) }.map {
                    Item(project: $0.url, title: $0.title, type: $0.type, id: $0.id, library: $0.library.root, isInstalling: $0.isInstalling, subscription: subscriptions[$0.id], saved: nil)
                }
                self.items += saved.items.map {
                    Item(project: $0.project, title: $0.title, type: $0.type, id: $0.id, library: nil, isInstalling: false, subscription: subscriptions[$0.id], saved: $0)
                }
                self.items += created.items.map {
                    Item(project: $0.project, title: $0.title, type: "scene", id: "", library: nil, isInstalling: false, subscription: nil, saved: nil, created: $0)
                }
                self.items += bundled.items.map {
                    Item(project: $0.project, title: $0.title, type: $0.type, id: "", library: nil, isInstalling: false, subscription: nil, saved: nil, bundled: $0)
                }
                self.items += local.items.map {
                    Item(project: $0.project, title: $0.record.title, type: $0.record.type, id: "", library: nil, isInstalling: false, subscription: nil, saved: nil)
                }
                let localIDs = Set(snapshot.projects.map(\.id)).union(savedIDs)
                self.items += subscriptions.values.filter { self.purpose == .defaultWallpaper && !localIDs.contains($0.id) }.map {
                    Item(project: nil, title: $0.title, type: "", id: $0.id, library: nil, isInstalling: $0.state & (16 | 32) != 0, subscription: $0, saved: nil)
                }
                if let current = self.currentItem, !self.items.contains(where: self.isCurrent),
                   current.created == nil || !self.items.contains(where: { $0.created?.id == current.created?.id }) { self.items.append(current) }
                for index in self.items.indices {
                    if let url = self.items[index].project, let value = metadata[url] { self.items[index].filterMetadata = value }
                }
                if let url = self.currentItem?.project, let value = metadata[url] { self.currentItem?.filterMetadata = value }
                self.warnings = snapshot.warnings + (saved.warning.map { [$0] } ?? []) + (created.warning.map { [$0] } ?? []) + bundled.warnings + (local.warning.map { [$0] } ?? [])
                let preview = self.forcePreviewPending; self.forcePreviewPending = false
                self.applyFilters(preferred: selection, refreshPreview: preview)
                if self.scanAgain { self.scanAgain = false; self.refreshLibrary() }
            }
        }
    }

    private func isCurrent(_ item: Item) -> Bool {
        guard let currentItem else { return false }
        return item.identity == currentItem.identity || (!currentItem.id.isEmpty && item.id == currentItem.id)
    }
    private func isOlderBundledVersion(_ item: Item) -> Bool {
        guard let bundled = item.bundled, isCurrent(item) else { return false }
        return items.contains { $0.bundled?.id == bundled.id && $0.bundled?.revision != bundled.revision }
    }
    private func saveFilters() {
        guard purpose == .defaultWallpaper else { return }
        UserDefaults.standard.set(kind.rawValue, forKey: "libraryKindFilter")
        UserDefaults.standard.set(source.rawValue, forKey: "librarySourceFilter")
        installedFilterState.save()
    }
    @objc private func toggleInstalledFilters() {
        guard purpose == .defaultWallpaper else { return }
        installedFiltersVisible.toggle()
        installedFiltersView?.isHidden = !installedFiltersVisible
        installedListLeading?.constant = installedFiltersVisible ? 230 : 0
        installedFilterButton.state = installedFiltersVisible ? .on : .off
        if installedFiltersVisible { UserDefaults.standard.set(true, forKey: "libraryInstalledFiltersVisible") }
        else { UserDefaults.standard.removeObject(forKey: "libraryInstalledFiltersVisible") }
        window?.contentView?.layoutSubtreeIfNeeded(); gallery.collectionViewLayout?.invalidateLayout()
    }
    @objc private func filtersChanged() {
        shouldRestoreCurrentSelection = false
        kind = Kind.allCases[max(0, kindFilter.indexOfSelectedItem)]
        source = Source.allCases[max(0, sourceFilter.indexOfSelectedItem)]
        saveFilters(); applyFilters()
    }
    @objc private func sortChanged() {
        shouldRestoreCurrentSelection = false
        order.criterion = NativeInstalledSort.Criterion.allCases[max(0, sortOrder.indexOfSelectedItem)]
        if purpose == .defaultWallpaper { order.save() }
        applyFilters()
    }
    @objc private func reverseSort() {
        order.descending.toggle(); sortDirection.title = order.descending ? "▼" : "▲"
        if purpose == .defaultWallpaper { order.save() }
        applyFilters()
    }
    func controlTextDidChange(_ notification: Notification) { shouldRestoreCurrentSelection = false; applyFilters() }
    @objc private func resetFilters() {
        shouldRestoreCurrentSelection = false
        search.stringValue = ""; kind = .all; source = .all
        installedFilterState = .init(); installedFiltersView?.setState(installedFilterState)
        kindFilter.selectItem(at: 0); sourceFilter.selectItem(at: 0)
        saveFilters(); applyFilters()
    }
    @objc private func revealCurrent() {
        guard let currentItem else { return }
        if purpose == .defaultWallpaper { navigateFolder(folders.owner(of: currentItem.folderKey)) }
        resetFilters()
        if !items.contains(where: isCurrent) { items.append(currentItem) }
        applyFilters(preferred: currentItem)
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
        // AppKit names the physical edge: top/bottom are horizontal edges.
        if !gallery.selectionIndexPaths.isEmpty { gallery.scrollToItems(at: gallery.selectionIndexPaths, scrollPosition: .nearestHorizontalEdge) }
    }
    @objc private func changeViewMode() {
        // Never retain a repeating edge-scroll timer in the view that is
        // about to be hidden. The drag itself remains uncommitted.
        stopLibraryDragAutoscroll()
        scroll.isHidden = viewMode.selectedSegment == 0
        galleryScroll.isHidden = !scroll.isHidden
        if purpose == .defaultWallpaper {
            UserDefaults.standard.set(scroll.isHidden ? "grid" : "list", forKey: "libraryViewMode")
        }
        if scroll.isHidden {
            gallery.collectionViewLayout?.invalidateLayout()
            if !gallery.selectionIndexPaths.isEmpty { gallery.scrollToItems(at: gallery.selectionIndexPaths, scrollPosition: .nearestHorizontalEdge) }
        } else if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }
    private func changeThumbnailSize(_ size: NativeLibraryThumbnailSize) {
        thumbnailSize = size
        if purpose == .defaultWallpaper { size.save() }
        gallery.updateThumbnailPresentation(size: size, viewportWidth: window?.contentView?.bounds.width ?? 1100)
        browserPages.values.forEach { $0.updateThumbnailSize(size) }
    }
    private func selectItem(at index: Int?, refreshPreview: Bool = false, userInitiated: Bool = false) {
        let previous = selectedIdentity
        if let index, visibleItems.indices.contains(index) {
            selection.choose(visibleItems[index].identity)
        } else {
            selection.choose(nil)
        }
        syncSelectionViews()
        if !rebuilding { updateDetails(forcePreview: refreshPreview) }
        guard userInitiated, !rebuilding else { return }
        shouldRestoreCurrentSelection = false
        if let folder = selectedItem?.folder { navigateFolder(folder.id); return }
        guard purpose == .defaultWallpaper, selectedIdentity != previous || selectionDisplacedByPlayback,
              let item = selectedItem, item.canApply, let project = item.project else { return }
        // Remote, still-downloading and unsupported items remain selectable.
        // Their selection never starts a download or launches an application.
        selectionDisplacedByPlayback = false
        selectProject(project)
    }
    private func syncSelectionViews() {
        let wasRebuilding = rebuilding; rebuilding = true
        let selected = selection.selected
        let indexes = IndexSet(visibleItems.indices.filter { selected.contains(visibleItems[$0].identity) })
        table.selectRowIndexes(indexes,byExtendingSelection:false)
        gallery.selectionIndexPaths = Set(indexes.map { IndexPath(item:$0,section:0) })
        rebuilding = wasRebuilding
    }
    private func selectGesture(at index: Int, flags: NSEvent.ModifierFlags) {
        guard visibleItems.indices.contains(index) else { return }
        guard purpose == .defaultWallpaper, !flags.intersection([.command,.shift]).isEmpty else {
            selectItem(at:index,userInitiated:true); return
        }
        shouldRestoreCurrentSelection = false
        if flags.contains(.command) { selection.toggle(visibleItems[index].identity) }
        else { selection.range(to:visibleItems[index].identity,order:visibleItems.map(\.identity)) }
        syncSelectionViews(); updateDetails()
    }
    private func selectAllLibraryItems() {
        guard purpose == .defaultWallpaper else { return }
        shouldRestoreCurrentSelection = false
        selection.add(visibleItems.filter { $0.folder == nil }.map(\.identity))
        selection.add(visibleItems.filter { $0.folder != nil }.map(\.identity))
        syncSelectionViews(); updateDetails()
    }
    private func selectRectangle(_ indexes: [Int], flags: NSEvent.ModifierFlags) {
        guard purpose == .defaultWallpaper else { return }
        shouldRestoreCurrentSelection = false
        selection.rectangle(indexes.filter { visibleItems.indices.contains($0) }.map { visibleItems[$0].identity },
                            command:flags.contains(.command),shift:flags.contains(.shift))
        syncSelectionViews(); updateDetails()
    }
    private func navigateLibrarySelection(_ key: UInt16, grid: Bool) {
        let candidates = visibleItems.indices.filter { visibleItems[$0].folder == nil }
        let current = candidates.firstIndex { visibleItems[$0].identity == selectedIdentity } ?? -1
        var columns = 1
        if grid, let layout = gallery.collectionViewLayout as? NativeLibraryGalleryLayout {
            columns = layout.columnCount
        }
        let offset = key == 123 ? -1 : key == 124 ? 1 : key == 125 ? columns : -columns
        guard candidates.indices.contains(current+offset) else { return }
        let index = candidates[current+offset]; selectItem(at:index,userInitiated:true)
        if grid { gallery.scrollToItems(at:[IndexPath(item:index,section:0)],scrollPosition:.nearestHorizontalEdge) }
        else { table.scrollRowToVisible(index) }
    }
    private func reloadGallery(clearCache: Bool) {
        // A reflow can invalidate all destination frames while a drag is in
        // flight. Stop its repeating viewport movement before rebuilding.
        stopLibraryDragAutoscroll()
        thumbnailGeneration += 1; thumbnailQueue.cancelAllOperations(); thumbnailOperations.removeAll()
        if clearCache { thumbnailCache.removeAllObjects() }
        let wasRebuilding = rebuilding; rebuilding = true
        gallery.reloadData()
        syncSelectionViews()
        rebuilding = wasRebuilding
    }
    private func applyFilters(preferred: Item? = nil, refreshPreview: Bool = false) {
        // Filtering, folder changes and async metadata refreshes may replace
        // the target list. A stale internal drag must not keep scrolling it.
        stopLibraryDragAutoscroll()
        let previous = preferred ?? selectedItem
        for index in items.indices {
            let id = items[index].id
            items[index].isFavorite = favoriteIDs.map { $0.contains(id) }
        }
        let query = search.stringValue
        let scoped = items.filter { purpose == .displaySelection || folders.contains($0.folderKey, in: currentFolderID) }
        var next = scoped.filter { item in
            // Keep the native numeric Workshop-ID shortcut alongside the
            // official installed-title search and tag-keyword semantics.
            let idQuery = !query.isEmpty && SteamLibraryIndex.validID(query) && item.id.contains(query)
            let matchesQuery = installedFilterState.matches(item.filterEntry, query: idQuery ? "" : query)
            let matchesKind = kind == .all || (kind == .other ? !item.supported : (item.type.lowercased() == "image" ? "scene" : item.type.lowercased()) == kind.rawValue)
            let matchesSource: Bool
            switch source {
            case .all: matchesSource = true
            case .saved: matchesSource = item.saved != nil
            case .steam: matchesSource = item.library != nil
            case .subscribed: matchesSource = item.subscription != nil
            case .remote: matchesSource = item.project == nil
            case .local: matchesSource = item.project != nil && item.library == nil && item.saved == nil && item.bundled == nil
            case .created: matchesSource = item.created != nil
            case .bundled: matchesSource = item.bundled != nil
            }
            return matchesQuery && matchesKind && matchesSource
        }
        next.sort { order.precedes($0.sortEntry, $1.sortEntry) }
        let wallpaperCount = next.count
        if purpose == .defaultWallpaper {
            let names = NativeInstalledSort(descending: order.descending)
            let children = folders.children(of: currentFolderID).sorted { names.precedes(.init(title: $0.title), .init(title: $1.title)) }
            next = children.map { Item(project: nil, title: $0.title, type: "folder", id: "", library: nil, isInstalling: false, subscription: nil, saved: nil, folder: $0) } + next
        }
        let selectedRow = previous.flatMap { value in
            if let exact = next.firstIndex(where: { $0.identity == value.identity }) { return exact }
            // A creation keeps its identity when saving a new immutable version.
            // Its project path remains version-specific for playback and previews.
            if let id = value.created?.id { return next.firstIndex(where: { $0.created?.id == id }) }
            return value.id.isEmpty ? nil : next.firstIndex(where: { $0.id == value.id })
        }
        rebuilding = true
        if next != visibleItems {
            let origin = scroll.contentView.bounds.origin
            visibleItems = next
            table.reloadData()
            reloadGallery(clearCache: refreshPreview)
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, max(0, table.bounds.height - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if refreshPreview { reloadGallery(clearCache: true) }
        selectItem(at: selectedRow)
        rebuilding = false
        counts.stringValue = "显示 \(wallpaperCount) / \(scoped.count) 项" + (folders.folders.isEmpty ? "" : " · 文件夹 \(next.count - wallpaperCount) 项") + " · 内置 \(items.filter { $0.bundled != nil }.count) 项 · 本机已保存 \(items.filter { $0.saved != nil }.count) 项 · 我的作品 \(items.filter { $0.created != nil }.count) 项" + (warnings.isEmpty ? "" : " · 部分位置未确认")
        counts.toolTip = ([foldersLoadError].compactMap { $0 } + warnings + [counts.stringValue]).joined(separator: "\n")
        let filtered = !installedFilterState.isDefault || kind != .all || source != .all || !search.stringValue.isEmpty
        installedFilterButton.contentTintColor = filtered ? .controlAccentColor : nil
        installedFilterButton.toolTip = [filtered ? "筛选已生效；清除筛选可显示全部项目。" : "显示或隐藏筛选结果", kind.title, source.title, counts.toolTip ?? counts.stringValue].joined(separator: "\n")
        updateDetails(forcePreview: refreshPreview)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }
    private func statusText(for item: Item) -> String {
        if let folder = item.folder { return "\(folder.items.count) 张壁纸 · \(folders.children(of: folder.id).count) 个子文件夹" }
        let state = item.isInstalling ? "下载中" : item.project == nil ? (item.subscription?.available == true ? "待下载" : "访问未确认") : item.type.lowercased() == "scene" ? "部分兼容" : item.supported ? "可打开" : "暂不支持"
        let origin = item.bundled != nil ? (isOlderBundledVersion(item) ? "内置（旧版）" : "内置") : item.created != nil ? "我的作品" : item.saved != nil ? "已保存" : item.subscription != nil ? "已订阅" : item.library != nil ? "Steam" : "本地"
        return (isCurrent(item) ? "默认 · " : "") + origin + " · " + state
    }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { visibleItems.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: NativeLibraryGalleryItem.reuseIdentifier, for: indexPath) as! NativeLibraryGalleryItem
        let item = visibleItems[indexPath.item]
        let badges = NativeLibraryThumbnailBadge.known(tags: Set((item.filterEntry.tags ?? "").split(separator: ",").map(String.init)),
            favorite: item.filterEntry.favorite)
        cell.configure(identity: item.identity, title: item.title, type: item.folder != nil ? "文件夹" : item.project == nil ? "待下载" : item.typeTitle,
                       state: statusText(for: item), current: isCurrent(item), available: item.canApply || item.folder != nil,
                       folder: item.folder != nil, badges: badges, folderIcon: item.folder?.icon, folderColor: item.folder?.color,
                       size: thumbnailSize) { [weak self] in
            guard let self, let index = self.visibleItems.firstIndex(where: { $0.identity == item.identity }) else { return }
            self.selectItem(at: index, userInitiated: true)
        }
        if let image = thumbnailCache.object(forKey: item.identity as NSString) { cell.setThumbnail(image) }
        else { requestThumbnail(for: item) }
        cell.setDropTarget(item.identity == dropHighlight)
        return cell
    }
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        if !rebuilding { selectItem(at: collectionView.selectionIndexPaths.first?.item, userInitiated: true) }
    }
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if !rebuilding { selectItem(at: collectionView.selectionIndexPaths.first?.item, userInitiated: true) }
    }
    private func requestThumbnail(for item: Item) {
        guard let project = item.project, !item.isInstalling, thumbnailOperations[item.identity] == nil else { return }
        let generation = thumbnailGeneration
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = NativeLibraryPreview.load(project: project)
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, operation?.isCancelled == false, generation == self.thumbnailGeneration else { return }
                self.thumbnailOperations.removeValue(forKey: item.identity)
                guard let image = result.image else { return }
                let thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                self.thumbnailCache.setObject(thumbnail, forKey: item.identity as NSString, cost: image.bytesPerRow * image.height)
                // Use stable project identity, never the row captured before an async read.
                for case let cell as NativeLibraryGalleryItem in self.gallery.visibleItems() where cell.representedIdentity == item.identity {
                    cell.setThumbnail(thumbnail)
                }
            }
        }
        thumbnailOperations[item.identity] = operation; thumbnailQueue.addOperation(operation)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleItems.indices.contains(row) else { return nil }
        let item = visibleItems[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "title": value = item.title
        case "type": value = item.folder != nil ? "文件夹" : item.project == nil ? "待确认" : item.typeTitle
        default: value = statusText(for: item)
        }
        let label = NSTextField(labelWithString: value)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = value + "\n" + (item.project?.path ?? "Workshop " + item.id)
        if !item.canApply { label.textColor = .secondaryLabelColor }
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { if !rebuilding { selectItem(at: table.selectedRow, userInitiated: true) } }
    private func updateDetails(forcePreview: Bool = false) {
        defer { updatePropertyPanel(); updatePlaylistPanel() }
        guard let item = selectedItem else {
            livePreviewButton.isEnabled = false
            editButton.isEnabled = false
            applyButton.isEnabled = false; applyButton.title = applyTitle
            selectedTitle.stringValue = visibleItems.isEmpty ? "没有符合条件的壁纸" : "请选择一个壁纸"
            selectedTitle.toolTip = nil
            detail.stringValue = items.isEmpty ? "可点击“壁纸编辑器”创建作品、“打开壁纸”导入文件，或进入“创意工坊”获取壁纸。" : visibleItems.isEmpty ? "更换关键词，或点击“清除筛选”查看全部项目。当前壁纸继续保持。" : (purpose == .displaySelection ? "选择一张壁纸后，返回显示器设置应用。" : "单击已安装且支持的壁纸即可切换桌面。尚未下载的项目需先下载。")
            updatePreview(nil, force: forcePreview); return
        }
        selectedTitle.stringValue = item.title; selectedTitle.toolTip = item.title
        if let folder = item.folder {
            editButton.isEnabled = false; livePreviewButton.isEnabled = false; applyButton.isEnabled = false
            detail.stringValue = "\(folder.items.count) 张壁纸，\(folders.children(of: folder.id).count) 个子文件夹。"
            updatePreview(nil, force: forcePreview); return
        }
        editButton.isEnabled = item.created != nil
        livePreviewButton.isEnabled = item.project != nil && item.canApply && !previewLoading
        if !previewLoading { livePreviewButton.title = item.filterMetadata.remoteWeb ? "动态预览（静音）" : item.type.lowercased() == "web" ? "动态预览（含声音）" : "动态预览" }
        applyButton.isEnabled = item.canApply
        applyButton.title = item.project == nil ? "下载并设为默认" : applyTitle
        var lines = item.id.isEmpty ? ["本地项目"] : ["创意工坊 ID：\(item.id)"]
        if let created = item.created {
            lines = ["我的原生作品", "保存于 " + DateFormatter.localizedString(from: created.savedAt, dateStyle: .short, timeStyle: .short), "编辑时打开最新保存版本；保存后可在壁纸库中选用。"]
        }
        if item.bundled != nil {
            lines = ["内置原创壁纸 · 无需下载", "已保存在本机；移动应用位置后仍可继续使用。"]
            if isOlderBundledVersion(item) { lines.append("当前桌面保留这张壁纸的旧版。同名新版已在库中，可选择应用。") }
        }
        if item.project == nil {
            lines.append(item.subscription?.enabled == false ? "已在 Steam 中停用。" : "下载通过官方 Steam 完成，格式兼容情况在下载后确认。")
            if item.subscription?.available != true { lines.append("当前访问权限尚未确认。") }
        } else if item.isInstalling { lines.append("Steam 仍在下载，完成后可打开。") }
        else if item.bundled != nil { lines.append("\(item.type.capitalized) · 可在“壁纸设置”中查看这张壁纸提供的选项。") }
        else if item.type.lowercased() == "scene" { lines.append("Scene · 部分兼容。打开后可在“查看兼容情况”了解缺失和近似效果。") }
        else if item.supported { lines.append("\(item.type.capitalized) · 可尝试打开，实际兼容性取决于项目使用的功能。") }
        else { lines.append("此类型尚未支持运行。") }
        if item.filterMetadata.remoteWeb { lines.append("网址预览静音；设为桌面后可播放网页声音。") }
        else if item.type.lowercased() == "web" { lines.append("Web 预览保留作品自己的声音；关闭预览窗口即可结束。") }
        if let saved = item.saved {
            lines.append("本机已保存 \(ByteCountFormatter.string(fromByteCount: saved.bytes, countStyle: .file))，Steam 清理缓存后仍保留。")
            lines.append("保存于 " + DateFormatter.localizedString(from: saved.savedAt, dateStyle: .short, timeStyle: .short))
        } else if item.library != nil { lines.append("选用时保存到本机壁纸库。") }
        if isCurrent(item) { lines.append("这是默认项目；各屏幕实际显示内容可在“显示器”中查看。") }
        detail.stringValue = lines.joined(separator: "\n\n")
        detail.toolTip = item.project?.path
        updatePreview(item, force: forcePreview)
    }
    private func updatePreview(_ item: Item?, force: Bool) {
        let identity = item.map { $0.identity + ($0.isInstalling ? ":installing" : "") }
        guard force || previewIdentity != identity else { return }
        previewIdentity = identity; previewGeneration += 1
        let generation = previewGeneration
        previewOperation?.cancel(); previewOperation = nil
        preview.image = nil
        guard window?.isVisible == true, !installedContent.isHidden else { previewIdentity = nil; return }
        guard let item else { previewStatus.stringValue = "选择壁纸查看预览"; return }
        guard let project = item.project else { previewStatus.stringValue = "下载完成后可读取本机预览图"; return }
        guard !item.isInstalling else { previewStatus.stringValue = "下载完成后显示预览"; return }
        previewStatus.stringValue = "正在读取本机预览图…"
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = NativeLibraryPreview.load(project: project)
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self, weak operation] in
                guard let self, operation?.isCancelled == false, self.previewGeneration == generation else { return }
                self.preview.image = result.image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                self.previewStatus.stringValue = result.message
                self.previewOperation = nil
            }
        }
        previewOperation = operation; previewQueue.addOperation(operation)
    }
    func windowWillClose(_ notification: Notification) {
        stopLibraryDragAutoscroll(); activeDrag = nil; highlightDrop(nil)
        browserPages.values.forEach { $0.setActive(false) }
        previewOperation?.cancel(); previewOperation = nil; previewIdentity = nil; previewGeneration += 1
        thumbnailGeneration += 1; thumbnailQueue.cancelAllOperations(); thumbnailOperations.removeAll()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if purpose == .displaySelection || closeAccepted { return true }
        finishBrowser(accepted: false)
        return false
    }
    @objc private func confirmBrowser() { finishBrowser(accepted: true) }
    @objc private func cancelBrowser() { finishBrowser(accepted: false) }
    private func finishBrowser(accepted: Bool) {
        guard finishTask == nil else { return }
        guard let onFinish else { closeAccepted = true; window?.close(); return }
        window?.makeFirstResponder(nil)
        if let root = window?.contentView {
            finishBlocker.frame = root.bounds; finishBlocker.autoresizingMask = [.width, .height]
            root.addSubview(finishBlocker); window?.makeFirstResponder(finishBlocker)
        }
        browserFooter?.confirm.isEnabled = false; browserFooter?.cancel.isEnabled = false
        finishTask = Task { [weak self] in
            guard let self else { return }
            defer {
                finishTask = nil; finishBlocker.removeFromSuperview()
                browserFooter?.confirm.isEnabled = true; browserFooter?.cancel.isEnabled = true
            }
            do {
                try await onFinish(accepted)
                try Task.checkCancellation()
                closeAccepted = true; window?.close()
            } catch is CancellationError { }
            catch {
                updateLoadFailure("无法恢复打开壁纸库时的配置，当前桌面已保留。\n" + error.localizedDescription, retryable: false)
                updatePropertyPanel()
            }
        }
    }
    func cancelFinishing() -> Task<Void, Never>? { finishTask?.cancel(); return finishTask }
    @objc private func applySelected() {
        guard let item = selectedItem, item.canApply else { return }
        if purpose == .displaySelection {
            if let project = item.project { onChooseProject?(project, item.title) }
            return
        }
        if let project = item.project { selectProject(project) } else { onDownloadSubscription?(item.id) }
    }
    @objc private func acceptSelected() {
        guard let item = selectedItem, item.canApply else { return }
        if purpose == .displaySelection || item.project == nil {
            applySelected(); return
        }
        // A double click's first click already requested the wallpaper. Accept
        // the browser without restarting its load, clock or media playback.
        guard failurePanel.isHidden else { return }
        confirmBrowser()
    }
    @objc private func downloadItem() { onDownload?() }
    @objc private func syncSubscriptions() { onSyncSubscriptions?() }
    @objc private func showTransfers() { onShowTransfers?() }
    @objc private func editSelected() { if let item = selectedItem, item.created != nil, let project = item.project { onEdit?(project) } }
    @objc private func createProject() { onCreate?() }
    @objc private func previewSelected() { if let item = selectedItem, let project = item.project, item.canApply, !previewLoading { onPreview?(project) } }
    @objc private func cancelPreview() { if previewLoading { onCancelPreview?() } }
    @objc private func cancelProjectLoad() { if cancelLoadButton.isEnabled { onCancelProjectLoad?() } }
    @objc private func retryProjectLoad() { if retryLoadButton.isEnabled { onRetryProjectLoad?() } }
    private func openWallpaperMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let actions: [(String, String, () -> Void)] = [
            ("创建新的壁纸（动态且可共享）", "openWallpaperCreate", { [weak self] in self?.onCreate?() }),
            ("打开离线壁纸（动态）", "openWallpaperOffline", { [weak self] in self?.onOpenLocal?() }),
            ("打开背景图片（静态）", "openWallpaperStatic", { [weak self] in self?.onOpenStatic?() }),
            ("从 URL 打开", "openWallpaperFromURL", { [weak self] in self?.onOpenURL?() })]
        for (title, identifier, action) in actions {
            let item = LibraryActionMenuItem(title: title, action: action)
            item.identifier = .init(identifier); menu.addItem(item)
        }
        return menu
    }
    @objc private func openLocalProject(_ sender: NSButton) {
        let menu = openWallpaperMenu()
        let y = sender.isFlipped ? sender.bounds.minY - menu.size.height - 3 : sender.bounds.maxY + menu.size.height + 3
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: sender)
    }
    @objc private func togglePlayback() { onTogglePlayback?() }
    @objc private func showProperties() { onProperties?() }
    @objc private func showDisplays() {
        if let onDisplaysForTarget { onDisplaysForTarget(displayTarget.key) }
        else { onDisplays?() }
    }
    @objc private func showPlaybackSettings() { onPlaybackSettings?() }
    @objc private func showCompatibility() { onCompatibility?() }

    private func updateFolderNavigation() {
        folderNavigationRow.isHidden = purpose != .defaultWallpaper || currentFolderID == nil
        let root = NSPathControlItem(); root.title = "主页"
        folderPath.pathItems = [root] + folders.path(to: currentFolderID).map {
            let item = NSPathControlItem(); item.title = $0.title; return item
        }
    }
    private func navigateFolder(_ id: String?) {
        guard purpose == .defaultWallpaper, id == nil || folders.folder(id) != nil else { return }
        currentFolderID = id; shouldRestoreCurrentSelection = false
        selection.clearAdditional(); stopLibraryDragAutoscroll(); activeDrag = nil; highlightDrop(nil)
        if let id { UserDefaults.standard.set(id, forKey: "libraryCurrentFolderV1") }
        else { UserDefaults.standard.removeObject(forKey: "libraryCurrentFolderV1") }
        updateFolderNavigation(); applyFilters()
        galleryScroll.contentView.scroll(to: .zero); scroll.contentView.scroll(to: .zero)
    }
    @objc private func folderUp() { navigateFolder(folders.folder(currentFolderID)?.parent) }
    @objc private func folderPathChanged() {
        guard let clicked = folderPath.clickedPathItem,
              let index = folderPath.pathItems.firstIndex(where: { $0 === clicked }) else { return }
        let path = folders.path(to: currentFolderID)
        guard index <= path.count else { return }
        navigateFolder(index == 0 ? nil : path[index - 1].id)
    }
    @discardableResult
    private func commitFolders(_ mutation: (inout NativeLibraryFolders) throws -> Void) -> Bool {
        guard purpose == .defaultWallpaper, foldersLoadError == nil else { return false }
        do {
            var candidate = folders; try mutation(&candidate); try candidate.save()
            folders = candidate
            if currentFolderID != nil && folders.folder(currentFolderID) == nil {
                currentFolderID = nil; UserDefaults.standard.removeObject(forKey: "libraryCurrentFolderV1")
            }
            updateFolderNavigation(); applyFilters(); return true
        } catch { updateStatus("文件夹未更改：" + error.localizedDescription); return false }
    }
    @objc private func createFolder() {
        guard foldersLoadError == nil else { return }
        let parent = currentFolderID
        promptFolderName(title: "创建文件夹", value: "新文件夹") { [weak self] name in
            self?.commitFolders { _ = try $0.create(title: name, parent: parent) }
        }
    }
    private func renameFolder(_ folder: NativeLibraryFolders.Folder) {
        promptFolderName(title: "重命名", value: folder.title) { [weak self] name in
            self?.commitFolders { try $0.rename(folder.id, to: name) }
        }
    }
    private func promptFolderName(title: String, value: String, accept: @escaping (String) -> Void) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.identifier = NSUserInterfaceItemIdentifier("libraryFolderName"); field.setAccessibilityLabel("文件夹名称")
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { accept(field.stringValue) } }
        alert.window.makeFirstResponder(field); field.selectText(nil)
    }
    private func removeFolder(_ folder: NativeLibraryFolders.Folder) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "删除文件夹“\(folder.title)”"
        alert.informativeText = "确定删除这个文件夹及其子文件夹吗？其中的壁纸会回到主页。"
        alert.addButton(withTitle: "删除文件夹"); alert.addButton(withTitle: "取消")
        // Folder removal is complete locally. Account unsubscription and file
        // deletion are separate operations and are not simulated by this UI.
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.commitFolders { try $0.remove(folder.id) } }
        }
    }
    /// Folder decoration is library metadata only.  It must not be confused
    /// with moving/deleting the wallpapers referenced by the folder.
    private func setFolderDecoration(_ folder: NativeLibraryFolders.Folder,
                                     icon: NativeLibraryFolders.FolderIcon?, color: NativeLibraryFolders.FolderColor?) {
        _ = commitFolders { try $0.setDecoration(folder.id, icon: icon, color: color) }
    }
    private func folderIconMenu(_ folder: NativeLibraryFolders.Folder) -> NSMenuItem {
        let root = NSMenuItem(title: "更改图标", action: nil, keyEquivalent: "")
        root.identifier = NSUserInterfaceItemIdentifier("libraryFolderChangeIconMenu")
        root.isEnabled = foldersLoadError == nil
        let menu = NSMenu(); menu.autoenablesItems = false; root.submenu = menu
        func add(_ title: String, id: String, icon: NativeLibraryFolders.FolderIcon?) {
            let entry = LibraryActionMenuItem(title: title) { [weak self] in
                self?.setFolderDecoration(folder, icon: icon, color: folder.color)
            }
            entry.identifier = NSUserInterfaceItemIdentifier(id)
            entry.state = folder.icon == icon ? .on : .off
            entry.image = NativeLibraryFolderPresentation.image(icon: icon, color: folder.color, fallback: .controlAccentColor)
            entry.image?.isTemplate = false
            menu.addItem(entry)
        }
        add("默认", id: "libraryFolderIcon_default", icon: nil)
        for icon in NativeLibraryFolders.FolderIcon.allCases {
            add(icon.title, id: "libraryFolderIcon_" + icon.rawValue, icon: icon)
        }
        return root
    }
    private func folderColorMenu(_ folder: NativeLibraryFolders.Folder) -> NSMenuItem {
        let root = NSMenuItem(title: "更改颜色", action: nil, keyEquivalent: "")
        root.identifier = NSUserInterfaceItemIdentifier("libraryFolderChangeColorMenu")
        root.isEnabled = foldersLoadError == nil
        let menu = NSMenu(); menu.autoenablesItems = false; root.submenu = menu
        func add(_ title: String, id: String, color: NativeLibraryFolders.FolderColor?) {
            let entry = LibraryActionMenuItem(title: title) { [weak self] in
                self?.setFolderDecoration(folder, icon: folder.icon, color: color)
            }
            entry.identifier = NSUserInterfaceItemIdentifier(id)
            entry.state = folder.color == color ? .on : .off
            entry.image = NativeLibraryFolderPresentation.image(icon: folder.icon, color: color, fallback: .controlAccentColor)
            entry.image?.isTemplate = false
            menu.addItem(entry)
        }
        add("默认", id: "libraryFolderColor_default", color: nil)
        for color in NativeLibraryFolders.FolderColor.allCases {
            add(color.title, id: "libraryFolderColor_" + color.rawValue, color: color)
        }
        return root
    }
    private func managementTargets(clicked item: Item) -> [Item] {
        let eligible = Set(visibleItems.filter { $0.folder == nil && ($0.project != nil || $0.isInstalling) }.map(\.identity))
        return selection.targets(clicked:item.identity,eligible:eligible).compactMap { id in visibleItems.first { $0.identity == id } }
    }
    private func movableItems(_ identities: [String], from sourceFolder: String?, to target: String?) -> [Item]? {
        guard purpose == .defaultWallpaper,foldersLoadError == nil,currentFolderID == sourceFolder,
              !identities.isEmpty,identities.count <= 10_000,Set(identities).count == identities.count,
              target == nil || folders.folder(target) != nil else { return nil }
        let values = identities.compactMap { id in visibleItems.first { $0.identity == id } }
        guard values.count == identities.count,values.allSatisfy({ $0.folder != nil || $0.project != nil || $0.isInstalling }),
              !values.contains(where: { item in item.folder.map { moving in folders.path(to:target).contains { $0.id == moving.id } } ?? false }) else { return nil }
        return values
    }
    @discardableResult
    private func moveLibraryItems(_ identities: [String], from sourceFolder: String?, to target: String?) -> Bool {
        guard let values = movableItems(identities,from:sourceFolder,to:target) else { return false }
        let success = commitFolders { state in
            try state.move(items:Set(values.filter { $0.folder == nil }.map(\.folderKey)),to:target)
            for item in values { if let folder = item.folder { try state.move(folder:folder.id,to:target) } }
        }
        if success { selection.clearAdditional(); syncSelectionViews(); updateDetails() }
        return success
    }
    private func libraryDragPayload(at index: Int) -> NativeLibraryDragPayload? {
        guard purpose == .defaultWallpaper,foldersLoadError == nil,visibleItems.indices.contains(index) else { return nil }
        let item = visibleItems[index]
        guard item.folder != nil || item.project != nil || item.isInstalling else { return nil }
        let identities = managementTargets(clicked:item).map(\.identity)
        let payload = NativeLibraryDragPayload(owner:dragOwner,session:UUID(),sourceFolder:currentFolderID,identities:identities)
        guard payload.encoded() != nil else { return nil }
        return payload
    }
    private func beginLibraryDrag(at index: Int, event: NSEvent, view: NSView) -> Bool {
        guard let payload = libraryDragPayload(at:index),let data = payload.encoded() else { return false }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(data,forType:NSPasteboard.PasteboardType(NativeLibraryDragPayload.pasteboardType))
        let drag = NSDraggingItem(pasteboardWriter:pasteboardItem)
        let frame: NSRect
        if view === gallery {
            guard let layout = gallery.collectionViewLayout?.layoutAttributesForItem(at:IndexPath(item:index,section:0)) else { return false }
            frame = layout.frame
        } else { frame = table.rect(ofRow:index) }
        let size = NSSize(width:min(220,max(120,frame.width)),height:64)
        let title = payload.identities.count == 1 ? visibleItems[index].title : "\(payload.identities.count) 项壁纸"
        let image = NSImage(size:size,flipped:false) { bounds in
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill(); NSBezierPath(roundedRect:bounds,xRadius:8,yRadius:8).fill()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in:bounds.insetBy(dx:12,dy:18),withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
            return true
        }
        drag.setDraggingFrame(NSRect(origin:frame.origin,size:size),contents:image)
        activeDrag = payload.session
        let session = view.beginDraggingSession(with:[drag],event:event,source:dragSource)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }
    private func validLibraryDragPayload(_ sender: NSDraggingInfo) -> NativeLibraryDragPayload? {
        guard let source = sender.draggingSource as? NativeLibraryDragSource,source === dragSource,
              sender.draggingSourceOperationMask.contains(.move),
              let data = sender.draggingPasteboard.data(forType:NSPasteboard.PasteboardType(NativeLibraryDragPayload.pasteboardType)),
              let payload = NativeLibraryDragPayload(data:data),payload.owner == dragOwner,payload.session == activeDrag,
              payload.sourceFolder == currentFolderID,
              // Autoscroll over blank space is allowed only while every item
              // remains movable in the current folder. A stale payload never
              // gets a timer merely because its nonce once matched.
              movableItems(payload.identities, from: payload.sourceFolder, to: nil) != nil else { return nil }
        return payload
    }
    private func dropContext(_ sender: NSDraggingInfo, grid: Bool) -> (NativeLibraryDragPayload,String)? {
        guard let payload = validLibraryDragPayload(sender) else { return nil }
        let index: Int?
        if grid { index = gallery.indexPathForItem(at:gallery.convert(sender.draggingLocation,from:nil))?.item }
        else { let row = table.row(at:table.convert(sender.draggingLocation,from:nil)); index = row >= 0 ? row : nil }
        guard let index,visibleItems.indices.contains(index),let target = visibleItems[index].folder,
              movableItems(payload.identities,from:payload.sourceFolder,to:target.id) != nil else { return nil }
        return (payload,target.id)
    }
    private func validateLibraryDrop(_ sender: NSDraggingInfo, grid: Bool) -> NSDragOperation {
        guard let (_,target) = dropContext(sender,grid:grid) else { highlightDrop(nil); return [] }
        highlightDrop("folder:"+target); return .move
    }
    private func acceptLibraryDrop(_ sender: NSDraggingInfo, grid: Bool) -> Bool {
        defer { stopLibraryDragAutoscroll() }
        guard let (payload,target) = dropContext(sender,grid:grid) else { return false }
        let result = moveLibraryItems(payload.identities,from:payload.sourceFolder,to:target)
        if result { activeDrag = nil }
        return result
    }
    private func highlightDrop(_ identity: String?) {
        dropHighlight = identity
        for case let cell as NativeLibraryGalleryItem in gallery.visibleItems() { cell.setDropTarget(cell.representedIdentity == identity && identity != nil) }
        if let identity,let row = visibleItems.firstIndex(where: { $0.identity == identity }) { table.setDropRow(row,dropOperation:.on) }
        else { table.setDropRow(-1,dropOperation:.on) }
    }
    private func stopLibraryDragAutoscroll() {
        gallery.cancelDragAutoscroll(); table.cancelDragAutoscroll()
    }
    private func libraryContextMenu(at index: Int?) -> NSMenu? {
        guard purpose == .defaultWallpaper else { return nil }
        let item = index.flatMap { visibleItems.indices.contains($0) ? visibleItems[$0] : nil }
        let moveItems = item.map { managementTargets(clicked:$0) } ?? []
        let sourceFolder = currentFolderID
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, id: String, enabled: Bool = true, action: @escaping () -> Void) {
            let entry = LibraryActionMenuItem(title: title, action: action)
            entry.identifier = NSUserInterfaceItemIdentifier(id); entry.isEnabled = enabled; menu.addItem(entry)
        }
        if let item, item.folder == nil {
            add(item.project == nil ? "下载并应用" : applyTitle, id: "libraryApplyItem", enabled: item.canApply) { [weak self] in
                if let project = item.project { self?.selectProject(project) }
                else { self?.onDownloadSubscription?(item.id) }
            }
            if playlistWallpaper(item) != nil {
                let member = playlist.entries.contains { $0.wallpaper.key == item.folderKey }
                add(member ? "从播放列表中删除" : "加入播放列表", id: "libraryTogglePlaylist", enabled: playlistError == nil) { [weak self] in self?.togglePlaylist(clicked: item) }
            }
            if let target = wallpaperHotkeyTarget(item) {
                do {
                    if try NativeHotkeyBindingStore.binding(for: target)?.hotkey != nil {
                        add("删除热键", id: "libraryRemoveHotkey") { [weak self] in self?.removeWallpaperHotkey(target) }
                    } else {
                        add("分配热键", id: "libraryAssignHotkey") { [weak self] in self?.showWallpaperHotkeyAssignment(target) }
                    }
                } catch {
                    // A malformed global pool must not be interpreted as an
                    // unbound wallpaper and silently replaced.
                    add("分配热键", id: "libraryAssignHotkey", enabled: false) { }
                    updateStatus("无法读取热键设置，未更改分配：" + error.localizedDescription)
                }
            }
        }
        if let item, item.folder != nil || item.project != nil || item.isInstalling {
            let destinations = NSMenu(); destinations.autoenablesItems = false
            func destination(_ title: String, id: String?) {
                let entry = LibraryActionMenuItem(title: title) { [weak self] in
                    self?.moveLibraryItems(moveItems.map(\.identity),from:sourceFolder,to:id)
                }
                entry.identifier = NSUserInterfaceItemIdentifier("libraryMoveTo_" + (id ?? "root")); destinations.addItem(entry)
            }
            if currentFolderID != nil { destination("主页", id: nil) }
            for target in folders.folders.sorted(by: { $0.title.localizedCompare($1.title) == .orderedAscending }) {
                guard target.id != currentFolderID else { continue }
                if moveItems.contains(where: { item in item.folder.map { moving in folders.path(to:target.id).contains { $0.id == moving.id } } ?? false }) { continue }
                destination(folders.path(to: target.id).map(\.title).joined(separator: " / "), id: target.id)
            }
            if !destinations.items.isEmpty {
                let entry = NSMenuItem(title: "移动到", action: nil, keyEquivalent: ""); entry.submenu = destinations
                entry.identifier = NSUserInterfaceItemIdentifier("libraryMoveMenu"); entry.isEnabled = foldersLoadError == nil && !moveItems.isEmpty; menu.addItem(entry)
            }
            if let folder = item.folder {
                add("重命名", id: "libraryRenameFolder", enabled: foldersLoadError == nil) { [weak self] in self?.renameFolder(folder) }
                add("删除文件夹", id: "libraryRemoveFolder", enabled: foldersLoadError == nil) { [weak self] in self?.removeFolder(folder) }
                menu.addItem(folderIconMenu(folder))
                menu.addItem(folderColorMenu(folder))
            } else if let project = item.project {
                add("在访达中显示", id: "libraryRevealFile") { NSWorkspace.shared.activateFileViewerSelecting([project]) }
                add("动态预览", id: "libraryPreviewItem", enabled: item.canApply && !previewLoading) { [weak self] in self?.onPreview?(project) }
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
        }
        add("创建文件夹", id: "libraryCreateFolder", enabled: foldersLoadError == nil) { [weak self] in self?.createFolder() }
        menu.addItem(.separator())
        let view = NativeLibraryThumbnailMenu.item(selected: thumbnailSize) { [weak self] size in
            guard let self else { return }
            self.changeThumbnailSize(size)
            if self.viewMode.selectedSegment != 0 { self.viewMode.selectedSegment = 0; self.changeViewMode() }
        }
        menu.addItem(view)
        menu.addItem(nativeLibraryOptionsMenu())
        return menu
    }

    /// Mac-specific library controls live off the main query row. Build menus
    /// from the current state so checkmarks and playback availability stay live.
    private func nativeLibraryOptionsMenu() -> NSMenuItem {
        let root = NSMenuItem(title: "本机库选项", action: nil, keyEquivalent: "")
        root.identifier = NSUserInterfaceItemIdentifier("nativeLibraryOptions")
        let menu = NSMenu(); menu.autoenablesItems = false; root.submenu = menu
        func add(_ title: String, id: String, enabled: Bool = true, action: @escaping () -> Void) {
            let entry = LibraryActionMenuItem(title: title, action: action)
            entry.identifier = NSUserInterfaceItemIdentifier(id); entry.isEnabled = enabled; menu.addItem(entry)
        }
        func filter(_ title: String, id: String, titles: [String], selected: Int, change: @escaping (Int) -> Void) {
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.identifier = NSUserInterfaceItemIdentifier(id)
            let children = NSMenu(); children.autoenablesItems = false; parent.submenu = children
            for (index, title) in titles.enumerated() {
                let entry = LibraryActionMenuItem(title: title) { change(index) }
                entry.identifier = NSUserInterfaceItemIdentifier(id + "_\(index)")
                entry.state = selected == index ? .on : .off; children.addItem(entry)
            }
            menu.addItem(parent)
        }
        add(counts.stringValue, id: "nativeLibraryCounts", enabled: false) {}
        filter("壁纸类型", id: "nativeLibraryKind", titles: Kind.allCases.map(\.title), selected: kindFilter.indexOfSelectedItem) { [weak self] index in
            self?.kindFilter.selectItem(at: index); self?.filtersChanged()
        }
        filter("壁纸来源", id: "nativeLibrarySource", titles: Source.allCases.map(\.title), selected: sourceFilter.indexOfSelectedItem) { [weak self] index in
            self?.sourceFilter.selectItem(at: index); self?.filtersChanged()
        }
        filter("展示方式", id: "nativeLibraryViewMode", titles: ["缩略图", "列表"], selected: viewMode.selectedSegment) { [weak self] index in
            self?.viewMode.selectedSegment = index; self?.changeViewMode()
        }
        add("清除筛选", id: "nativeLibraryResetFilters") { [weak self] in self?.resetFilters() }
        add("刷新列表", id: "nativeLibraryReload") { [weak self] in self?.reloadLibrary() }
        add("下载与更新…", id: "nativeLibraryTransfers") { [weak self] in self?.onShowTransfers?() }
        add("同步我的订阅", id: "nativeLibrarySync") { [weak self] in self?.onSyncSubscriptions?() }
        add("从创意工坊链接下载…", id: "nativeLibraryDownload") { [weak self] in self?.onDownload?() }
        menu.addItem(.separator())
        add(currentLabel.stringValue, id: "nativeCurrentWallpaper", enabled: false) {}
        add(playbackButton.title, id: "nativePlayback", enabled: playbackButton.isEnabled) { [weak self] in self?.onTogglePlayback?() }
        add("壁纸设置…", id: "nativeWallpaperProperties", enabled: propertiesButton.isEnabled) { [weak self] in self?.onProperties?() }
        add("定位默认项目", id: "nativeRevealCurrent", enabled: revealButton.isEnabled) { [weak self] in self?.revealCurrent() }
        add("兼容情况…", id: "nativeCompatibility", enabled: compatibilityButton.isEnabled) { [weak self] in self?.onCompatibility?() }
        return root
    }
}

private final class NativeLibraryFinishBlocker: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { }
    override func mouseDown(with event: NSEvent) { }
    override func scrollWheel(with event: NSEvent) { }
}

@MainActor
final class LibraryActionMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action; super.init(title: title, action: nil, keyEquivalent: "")
        target = self; self.action = #selector(invoke)
    }
    required init(coder: NSCoder) { fatalError("Not archived") }
    @objc private func invoke() { handler() }
}
