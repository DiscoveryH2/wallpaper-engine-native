import Foundation

/// Choice values follow the official public Workshop schema; labels are checked
/// against the locally owned Simplified Chinese GUI of public build 26168761.
enum NativeWorkshopFilterCatalog {
    struct Choice { let tag: String; let title: String }
    static let types: [Choice] = [
        Choice(tag: "Scene", title: "场景"),
        Choice(tag: "Video", title: "视频"),
        Choice(tag: "Web", title: "网页"),
        Choice(tag: "Application", title: "应用程序"),
    ]
    static let categories: [Choice] = [
        Choice(tag: "Wallpaper", title: "常规壁纸"),
        Choice(tag: "Preset", title: "预设"),
    ]
    static let ages: [Choice] = [
        Choice(tag: "Everyone", title: "大众级（G）"),
        Choice(tag: "Questionable", title: "家长指导级（PG-13）"),
        Choice(tag: "Mature", title: "限制级/成人级（R-18）"),
    ]
    static let resolutions: [Choice] = [
        Choice(tag: "Standard Definition", title: "标清"),
        Choice(tag: "1280 x 720", title: "1280 x 720"),
        Choice(tag: "1366 x 768", title: "1366 x 768"),
        Choice(tag: "1920 x 1080", title: "1920 x 1080 - 全高清"),
        Choice(tag: "2560 x 1440", title: "2560 x 1440"),
        Choice(tag: "3840 x 2160", title: "3840 x 2160 - 4K"),
        Choice(tag: "Ultrawide Standard Definition", title: "超宽（标准）"),
        Choice(tag: "Ultrawide 2560 x 1080", title: "2560 x 1080"),
        Choice(tag: "Ultrawide 3440 x 1440", title: "3440 x 1440"),
        Choice(tag: "Dual Standard Definition", title: "双显示器（标准）"),
        Choice(tag: "Dual 3840 x 1080", title: "3840 x 1080"),
        Choice(tag: "Dual 5120 x 1440", title: "5120 x 1440"),
        Choice(tag: "Dual 7680 x 2160", title: "7680 x 2160"),
        Choice(tag: "Triple Standard Definition", title: "三显示器（标准）"),
        Choice(tag: "Triple 4096 x 768", title: "4096 x 768"),
        Choice(tag: "Triple 5760 x 1080", title: "5760 x 1080"),
        Choice(tag: "Triple 7680 x 1440", title: "7680 x 1440"),
        Choice(tag: "Triple 11520 x 2160", title: "11520 x 2160"),
        Choice(tag: "Portrait Standard Definition", title: "纵向（标准）"),
        Choice(tag: "Portrait 720 x 1280", title: "720 x 1280"),
        Choice(tag: "Portrait 1080 x 1920", title: "1080 x 1920"),
        Choice(tag: "Portrait 1440 x 2560", title: "1440 x 2560"),
        Choice(tag: "Portrait 2160 x 3840", title: "2160 x 3840"),
        Choice(tag: "Other resolution", title: "其他分辨率"),
        Choice(tag: "Dynamic resolution", title: "动态分辨率"),
    ]
    static let genres: [Choice] = [
        Choice(tag: "Abstract", title: "抽象"),
        Choice(tag: "Animal", title: "动物"),
        Choice(tag: "Anime", title: "动漫"),
        Choice(tag: "Cartoon", title: "卡通"),
        Choice(tag: "CGI", title: "CGI"),
        Choice(tag: "Cyberpunk", title: "网络朋克"),
        Choice(tag: "Fantasy", title: "幻想"),
        Choice(tag: "Game", title: "游戏"),
        Choice(tag: "Girls", title: "女性"),
        Choice(tag: "Guys", title: "男性"),
        Choice(tag: "Landscape", title: "风景"),
        Choice(tag: "Medieval", title: "中世纪"),
        Choice(tag: "Memes", title: "网红事物"),
        Choice(tag: "MMD", title: "MMD（Miku-Miku Dance）"),
        Choice(tag: "Music", title: "音乐"),
        Choice(tag: "Nature", title: "自然"),
        Choice(tag: "Pixel art", title: "像素艺术"),
        Choice(tag: "Relaxing", title: "放松"),
        Choice(tag: "Retro", title: "复古"),
        Choice(tag: "Sci-Fi", title: "科幻"),
        Choice(tag: "Sports", title: "运动"),
        Choice(tag: "Technology", title: "科技"),
        Choice(tag: "Television", title: "电视节目"),
        Choice(tag: "Vehicle", title: "汽车"),
        Choice(tag: "Unspecified", title: "未指定样式"),
    ]
    static let features: [Choice] = [
        Choice(tag: "Approved", title: "广受好评"),
        Choice(tag: "Audio responsive", title: "音频响应"),
        Choice(tag: "Customizable", title: "可自定义的"),
    ]
    static func choices(for group: NativeWorkshopFilterState.Group) -> [Choice] {
        switch group {
        case .type: return types
        case .category: return categories
        case .age: return ages
        case .resolution: return resolutions
        case .genre: return genres
        }
    }
    static let resetTitle = "重置过滤器"
    static let showOnlyTitle = "仅显示："
    static let mobileTitle = "兼容的移动设备"
    static let typeTitle = "类型"
    static let ageTitle = "年龄分级"
    static let resolutionTitle = "分辨率"
    static let genreTitle = "标签"
    static let allTitle = "所有"
    static let noneTitle = "无"
    static let resolutionSections: [(title: String, range: Range<Int>)] = [
        ("宽屏", 0..<6),
        ("超宽屏", 6..<9),
        ("双显示器", 9..<13),
        ("三显示器", 13..<18),
        ("纵向监视器/手机", 18..<23),
    ]
}
