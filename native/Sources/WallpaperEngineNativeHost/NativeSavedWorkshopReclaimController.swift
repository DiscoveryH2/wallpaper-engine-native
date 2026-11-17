import AppKit

/// Backs 状态栏菜单 →「清理未订阅的壁纸副本…」.
///
/// The flow is deliberately four-eyed: scan, ask Steam, plan, then show exactly
/// what would be deleted and wait for a confirmation. An unreachable
/// subscription list ends in an alert and no plan at all, because "Steam did not
/// answer" must never be mistaken for "nothing is subscribed".
final class NativeSavedWorkshopReclaimController {
    private var running = false

    func present() {
        guard !running else { return }
        running = true
        let helper = Bundle.main.url(forResource: "we-workshop", withExtension: nil, subdirectory: "Tools")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome: Result<SavedWorkshopReclaim.Plan?, Error>
            do {
                guard let helper else {
                    throw SavedWorkshopReclaim.Failure.subscriptionsUnavailable("应用内没有 we-workshop")
                }
                let copies = try SavedWorkshopReclaim.scan()
                let subscribed = try SavedWorkshopReclaim.subscribedIDs(helper: helper)
                let state = SavedWorkshopReclaim.preferenceState(defaults: .standard)
                let references = SavedWorkshopReclaim.references(inState: state, copies: copies)
                outcome = .success(SavedWorkshopReclaim.plan(copies: copies, subscribed: subscribed, references: references))
            } catch {
                outcome = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.present(outcome)
            }
        }
    }

    private func present(_ outcome: Result<SavedWorkshopReclaim.Plan?, Error>) {
        NSApp.activate(ignoringOtherApps: true)
        switch outcome {
        case .failure(let error):
            alert(style: .warning,
                  message: "清理失败",
                  informative: "\(error)\n\n没有删除任何文件。")
        case .success(.none):
            alert(style: .warning,
                  message: "无法确认订阅状态",
                  informative: "Steam 这次没有给出订阅列表，为避免误删，本地副本一份都没动。确认 Steam 在运行后重试。")
        case .success(.some(let plan)) where plan.isEmpty:
            alert(style: .informational,
                  message: "没有可清理的副本",
                  informative: "Steam 仍在订阅 \(plan.keptSubscribed) 份，另有 \(plan.keptReferenced) 份被当前播放状态引用。两种都不会删。")
        case .success(.some(let plan)):
            confirm(plan)
        }
    }

    private func confirm(_ plan: SavedWorkshopReclaim.Plan) {
        let names = plan.candidates.prefix(6).map { candidate in
            let title = NativeSavedWorkshopReclaimController.title(of: candidate) ?? candidate.id
            return "· \(title)"
        }
        var informative = "将删除 \(plan.candidates.count) 项，释放 \(NativeSavedWorkshopReclaimController.bytes(plan.bytes))：\n\n"
        informative += names.joined(separator: "\n")
        if plan.candidates.count > names.count { informative += "\n… 另有 \(plan.candidates.count - names.count) 项" }
        informative += "\n\n这些壁纸 Steam 已报告为未订阅，也没有显示器分配、配置、播放列表或应用规则引用它们。以后想要回来在创意工坊重新订阅即可，需要重新下载。"
        let response = alert(style: .warning,
                             message: "清理未订阅的壁纸副本？",
                             informative: informative,
                             buttons: ["删除这些副本", "取消"])
        guard response == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var freed: Int64 = 0
            var removed = 0
            var failures: [String] = []
            for candidate in plan.candidates {
                do {
                    freed += try SavedWorkshopReclaim.remove(candidate)
                    removed += 1
                } catch {
                    failures.append(candidate.id + "：" + String(describing: error))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                var text = "删除了 \(removed) 项，释放 \(NativeSavedWorkshopReclaimController.bytes(freed))。"
                if !failures.isEmpty {
                    text += "\n\n有 \(failures.count) 项没能删掉：\n" + failures.prefix(4).joined(separator: "\n")
                }
                self.alert(style: failures.isEmpty ? .informational : .warning, message: "清理完成", informative: text)
            }
        }
    }

    @discardableResult
    private func alert(style: NSAlert.Style, message: String, informative: String, buttons: [String] = ["好"]) -> NSApplication.ModalResponse {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = informative
        for title in buttons { alert.addButton(withTitle: title) }
        return alert.runModal()
    }

    static func title(of copy: SavedWorkshopCopy) -> String? {
        guard let data = try? Data(contentsOf: copy.project, options: .mappedIfSafe), data.count <= 1 << 20,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root["title"] as? String
    }

    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}
