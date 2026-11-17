import Foundation

/// Reports (and with --apply, removes) locally saved Workshop copies that Steam
/// no longer lists as subscribed and that no persisted playback state points at.
///
/// Dry run is the default. Nothing is deleted unless the subscription list came
/// back from the helper successfully.
///
///   xcrun swiftc -O native/Sources/WallpaperEngineNativeHost/SavedWorkshopReclaim.swift \
///                tools/reclaim_saved_workshop.swift -o /tmp/we-reclaim
///   /tmp/we-reclaim --helper synchronizer/build/we-workshop
///   /tmp/we-reclaim --helper synchronizer/build/we-workshop --apply
///
/// The app's 状态栏菜单 →「清理未订阅的壁纸副本…」 runs the same policy in-process.
@main
struct ReclaimTool {
    static func main() {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let copies = try SavedWorkshopReclaim.scan(root: options.root)
            let subscribed = try SavedWorkshopReclaim.subscribedIDs(helper: options.helper)
            let state = options.stateDomain.flatMap(UserDefaults.init(suiteName:)).map(SavedWorkshopReclaim.preferenceState(defaults:)) ?? []
            let references = SavedWorkshopReclaim.references(inState: state, copies: copies)
            guard let plan = SavedWorkshopReclaim.plan(copies: copies, subscribed: subscribed, references: references) else {
                FileHandle.standardError.write(Data("无法确认订阅状态，未做任何改动。\n".utf8))
                exit(2)
            }

            if options.json {
                print(jsonReport(plan: plan, copies: copies, apply: options.apply))
            } else {
                print(textReport(plan: plan, copies: copies))
            }

            guard options.apply, !plan.isEmpty else { return }
            var freed: Int64 = 0
            var removed = 0
            for candidate in plan.candidates {
                do {
                    freed += try SavedWorkshopReclaim.remove(candidate, root: options.root)
                    removed += 1
                } catch {
                    FileHandle.standardError.write(Data("跳过 \(candidate.id)：\(error)\n".utf8))
                }
            }
            print(options.json ? "{\"removed\":\(removed),\"freedBytes\":\(freed)}" : "已删除 \(removed) 项，释放 \(formatBytes(freed))")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }

    struct Options {
        var root = SavedWorkshopReclaim.root
        var helper: URL
        var apply = false
        var json = false
        var stateDomain: String? = "io.wallpaper-engine-native.host"

        init(arguments: [String]) throws {
            var helperPath: String?
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                func value() throws -> String {
                    guard index + 1 < arguments.count else { throw UsageError("\(argument) 需要一个值") }
                    index += 1
                    return arguments[index]
                }
                switch argument {
                case "--apply": apply = true
                case "--dry-run": apply = false
                case "--json": json = true
                case "--root": root = URL(fileURLWithPath: try value())
                case "--helper": helperPath = try value()
                case "--no-state": stateDomain = nil
                case "--state-domain": stateDomain = try value()
                case "-h", "--help": print(Options.usage); exit(0)
                default: throw UsageError("未知参数 " + argument)
                }
                index += 1
            }
            helper = URL(fileURLWithPath: helperPath ?? Options.defaultHelper())
        }

        static let usage = """
        用法: we-reclaim [--dry-run | --apply] [--json] [--root <SavedWorkshop>] [--helper <we-workshop>] [--no-state]

        默认试运行：只报告会删什么。--apply 才真的删。
        订阅状态问 --helper（默认找 app 包内或仓库里的 we-workshop），拿不到就什么都不做。
        """

        /// Prefer a bundled helper, then the repo's build output.
        static func defaultHelper() -> String {
            let candidates = [
                Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Tools/we-workshop").path,
                FileManager.default.currentDirectoryPath + "/synchronizer/build/we-workshop",
            ]
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
        }
    }

    struct UsageError: Error, CustomStringConvertible {
        let text: String
        init(_ text: String) { self.text = text }
        var description: String { text }
    }

    static func textReport(plan: SavedWorkshopReclaim.Plan, copies: [SavedWorkshopCopy]) -> String {
        var lines: [String] = []
        lines.append("壁纸副本：\(copies.count) 份，\(formatBytes(copies.reduce(0) { $0 + $1.bytes }))")
        lines.append("Steam 仍在订阅：\(plan.keptSubscribed) 份；被播放状态引用：\(plan.keptReferenced) 份")
        guard !plan.isEmpty else {
            lines.append("没有可清理的副本。")
            return lines.joined(separator: "\n")
        }
        lines.append("可清理：\(plan.candidates.count) 项，共 \(formatBytes(plan.bytes))")
        for candidate in plan.candidates {
            lines.append("  \(candidate.id)  \(formatBytes(candidate.bytes))  \(projectTitle(candidate) ?? "（无标题）")")
        }
        return lines.joined(separator: "\n")
    }

    static func jsonReport(plan: SavedWorkshopReclaim.Plan, copies: [SavedWorkshopCopy], apply: Bool) -> String {
        let items = plan.candidates.map { ["workshopID": $0.id, "bytes": $0.bytes, "title": projectTitle($0) ?? ""] as [String: Any] }
        let payload: [String: Any] = [
            "savedCopies": copies.count,
            "savedBytes": copies.reduce(0) { $0 + $1.bytes },
            "keptSubscribed": plan.keptSubscribed,
            "keptReferenced": plan.keptReferenced,
            "candidates": items,
            "candidateBytes": plan.bytes,
            "apply": apply,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func projectTitle(_ copy: SavedWorkshopCopy) -> String? {
        guard let data = try? Data(contentsOf: copy.project, options: .mappedIfSafe), data.count <= 1 << 20,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root["title"] as? String
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
