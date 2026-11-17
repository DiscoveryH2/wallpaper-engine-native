import Foundation

/// Filesystem-level checks for SavedWorkshopReclaim.
///
/// Builds a throwaway SavedWorkshop tree under TMPDIR and exercises scanning,
/// policy and deletion. Nothing here touches the real library, Steam, or the
/// user's preferences: `--no-state`-style isolation is the default because the
/// policy takes plain values.
///
///   zsh synchronizer/Tests/run_saved_workshop_reclaim_checks.sh
@main
struct SavedWorkshopReclaimChecks {
    static var checks = 0
    static var failures: [String] = []

    static func check(_ condition: Bool, _ label: String) {
        checks += 1
        if !condition { failures.append(label) }
    }

    static func main() {
        let root: URL
        do { root = try makeTree() }
        catch {
            print("{\"checks\":0,\"passed\":0,\"suite\":\"saved-workshop-reclaim-checks\",\"error\":\"fixture: \(error)\"}")
            exit(1)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        do { try runChecks(root: root) }
        catch { failures.append("threw: \(error)") }

        let passed = checks - failures.count
        let payload: [String: Any] = [
            "suite": "saved-workshop-reclaim-checks",
            "checks": checks,
            "passed": passed,
            "failures": failures,
            "fakeSteamLibrary": true,
            "realSteamAccountUsed": false,
            "userSteamDataWritten": false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        print(String(data: data, encoding: .utf8) ?? "{}")
        exit(passed == checks ? 0 : 1)
    }

    static func runChecks(root: URL) throws {
        // MARK: scan
        let copies = try SavedWorkshopReclaim.scan(root: root)
        let ids = Set(copies.map(\.id))
        check(ids == ["111", "222", "333", "444"], "scan keeps only canonical ids, got \(ids.sorted())")
        check(copies.count == 5, "scan counts each saved version, got \(copies.count)")
        check(!ids.contains(".lock"), "hidden lock file is not an item")
        check(copies.filter { $0.id == "444" }.count == 2, "both versions of 444 are seen")
        check(copies.allSatisfy { $0.bytes > 0 }, "every copy reports allocated bytes")

        // MARK: policy - unknown subscriptions fail closed
        check(SavedWorkshopReclaim.plan(copies: copies, subscribed: nil, references: []) == nil,
              "unknown subscription list yields no plan")

        // MARK: references
        let state: [Any] = [
            "file:///x/SavedWorkshop/222/v1/Content/project.json",
            Data("{\"displays\":{}}".utf8),
        ]
        let references = SavedWorkshopReclaim.references(inState: state, copies: copies)
        check(references == ["222"], "state blob referencing 222 is detected, got \(references.sorted())")
        check(SavedWorkshopReclaim.references(inState: [], copies: copies).isEmpty,
              "empty state references nothing")

        // MARK: policy - subscription and references win
        let plan = try unwrap(SavedWorkshopReclaim.plan(copies: copies, subscribed: ["111"], references: references),
                             "plan exists when subscriptions are known")
        check(plan.candidates.map(\.id) == ["333", "444"], "candidates are unsubscribed and unreferenced, got \(plan.candidates.map(\.id))")
        check(plan.keptSubscribed == 1, "111 is kept as subscribed, got \(plan.keptSubscribed)")
        check(plan.keptReferenced == 1, "222 is kept as referenced, got \(plan.keptReferenced)")
        let four = plan.candidates.first { $0.id == "444" }
        check(four.map { $0.bytes > 0 } == true, "444 reports combined bytes")
        check(plan.candidates.count == Set(plan.candidates.map(\.id)).count, "one candidate row per item id")
        check(plan.bytes == plan.candidates.reduce(0) { $0 + $1.bytes }, "plan total matches its rows")

        // MARK: empty plan
        let none = try unwrap(SavedWorkshopReclaim.plan(copies: copies, subscribed: ["111", "222", "333", "444"], references: []),
                              "plan exists when everything is subscribed")
        check(none.isEmpty && none.bytes == 0, "subscribed items produce an empty plan")

        // MARK: deletion refuses anything it did not describe
        let outside = URL(fileURLWithPath: root.deletingLastPathComponent().appendingPathComponent("not-the-library").path)
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        var escaped = SavedWorkshopCopy(id: "333", version: copies[0].version, bytes: 0,
                                        itemDirectory: outside.appendingPathComponent("333"),
                                        project: outside.appendingPathComponent("333/project.json"))
        check((try? SavedWorkshopReclaim.remove(escaped, root: root)) == nil, "a directory outside the root is refused")

        let symlinked = root.appendingPathComponent("999")
        try? FileManager.default.removeItem(at: symlinked)
        try FileManager.default.createSymbolicLink(at: symlinked, withDestinationURL: outside)
        escaped = SavedWorkshopCopy(id: "999", version: copies[0].version, bytes: 0,
                                    itemDirectory: symlinked, project: symlinked.appendingPathComponent("project.json"))
        check((try? SavedWorkshopReclaim.remove(escaped, root: root)) == nil, "a symlinked item directory is refused")
        check(FileManager.default.fileExists(atPath: symlinked.path), "the refused symlink is untouched")
        try? FileManager.default.removeItem(at: symlinked)

        // MARK: deletion removes exactly one item directory
        let three = try unwrap(plan.candidates.first { $0.id == "333" }, "333 is a candidate")
        let freed = try SavedWorkshopReclaim.remove(three, root: root)
        check(freed > 0, "deletion reports freed bytes, got \(freed)")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("333").path), "333 is gone")
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent("444/0f8fad5b-d9cb-469f-a165-70867728950e/Content/project.json").path),
              "neighbouring item 444 survives")
        check(FileManager.default.fileExists(atPath: root.appendingPathComponent(".lock").path), "the lock file survives")

        let after = try SavedWorkshopReclaim.scan(root: root)
        check(!after.contains { $0.id == "333" }, "rescan no longer lists 333")
        check(after.count == 4, "rescan sees the four remaining copies, got \(after.count)")
    }

    // MARK: - Fixture

    static func makeTree() throws -> URL {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("we-reclaim-checks-\(UUID().uuidString)/SavedWorkshop", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("lock".utf8).write(to: root.appendingPathComponent(".lock"))

        func copy(id: String, version: String, bytes: Int32) throws {
            let directory = root.appendingPathComponent(id).appendingPathComponent(version).appendingPathComponent("Content")
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            let project: [String: Any] = ["title": "fixture-\(id)", "type": "video", "file": "x.mp4"]
            try JSONSerialization.data(withJSONObject: project).write(to: directory.appendingPathComponent("project.json"))
            FileManager.default.createFile(atPath: directory.appendingPathComponent("payload.bin").path, contents: nil)
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("payload.bin"))
            try handle.truncate(atOffset: UInt64(bytes))
            try handle.close()
        }

        let uuid1 = "0f8fad5b-d9cb-469f-a165-70867728950e"
        let uuid2 = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
        try copy(id: "111", version: uuid1, bytes: 4096)
        try copy(id: "222", version: uuid1, bytes: 4096)
        try copy(id: "333", version: uuid1, bytes: 8192)
        try copy(id: "444", version: uuid1, bytes: 4096)
        try copy(id: "444", version: uuid2, bytes: 8192)

        // Shapes that must never become items: non-canonical id, upper-case
        // version, a version without Content/project.json, and a plain file.
        try copy(id: "5x5", version: uuid1, bytes: 512)
        try copy(id: "666", version: uuid1.uppercased(), bytes: 512)
        let versionless = root.appendingPathComponent("777").appendingPathComponent(uuid1)
        try manager.createDirectory(at: versionless, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("888"))
        return root
    }

    static func unwrap<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw CheckError.missing(label) }
        return value
    }

    enum CheckError: Error { case missing(String) }
}
