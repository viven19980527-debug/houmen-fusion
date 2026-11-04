import Foundation

@main
@MainActor
struct ProfileSnapshotChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw ProfileSnapshotFailure.message("FAILED: " + label) }
            checks += 1; print("PASS: " + label)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProfileSnapshot-fixtures-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ProfileSnapshotStore(directory: folder)
        let profile = "https://www.douyin.com/user/public_fixture"
        let alias = "https://douyin.com/user/public_fixture/"
        let other = "https://www.douyin.com/user/other_fixture"
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl4t2cAAAAASUVORK5CYII=")!
        try check(store.loadError == nil && store.entry(for: profile) == nil && store.imageURL(for: profile) == nil, "empty screenshot cache has no fabricated image")
        try store.recordFailure(profileURL: alias, reason: "尚未显示主页信息区")
        try check(store.entry(for: profile)?.status == "failed" && store.imageURL(for: profile) == nil, "failure metadata is paired by canonical profile only")
        let captured = ISO8601DateFormatter().date(from: "2026-10-25T04:30:00Z")!
        try store.persistValidatedCapture(png, profileURL: profile, capturedAt: captured)
        let firstEntry = store.entry(for: profile)!, firstImage = store.imageURL(for: profile)!
        try check(firstEntry.status == "ready" && firstEntry.capturedAt == "2026-10-25T04:30:00Z", "successful capture has explicit timestamp")
        try check(try Data(contentsOf: firstImage) == png, "cached image bytes are actual committed fixture bytes")
        try check(store.imageURL(for: alias) == firstImage && store.entry(for: other) == nil, "aliases match but different profiles never mix by nickname")
        try store.recordFailure(profileURL: profile, reason: "刷新超时")
        let failed = store.entry(for: profile)!
        try check(failed.status == "failed" && failed.filename == firstEntry.filename && failed.capturedAt == firstEntry.capturedAt,
                  "refresh failure preserves the earlier successful file and capture time")
        try check(store.imageURL(for: profile) == firstImage && (try Data(contentsOf: firstImage)) == png,
                  "old screenshot remains viewable with failure metadata")
        let restored = ProfileSnapshotStore(directory: folder)
        try check(restored.entry(for: profile) == failed && restored.imageURL(for: alias) == firstImage, "cache and failure state survive restart")
        let revision = store.revision
        try store.persistValidatedCapture(png, profileURL: alias)
        try check(store.revision > revision && store.entry(for: profile)?.failureReason == nil, "new verified capture clears old failure")
        try check(store.imageURL(for: profile) != firstImage && !FileManager.default.fileExists(atPath: firstImage.path),
                  "only committed replacement retires the previous image")
        let index = folder.appendingPathComponent("index.json"), before = try Data(contentsOf: index)
        for badURL in ["https://example.invalid/user/public_fixture", "https://www.douyin.com/user/public_fixture?token=bad", "https://channels.weixin.qq.com/platform/"] {
            var rejected = false
            do { try store.persistValidatedCapture(png, profileURL: badURL) } catch { rejected = true }
            try check(rejected && (try Data(contentsOf: index)) == before, "unsafe profile rejects capture without altering cache")
        }
        var invalidData = false
        do { try store.persistValidatedCapture(Data("not PNG".utf8), profileURL: other) } catch { invalidData = true }
        try check(invalidData && store.entry(for: other) == nil, "invalid screenshot is not fabricated into cache")
        var tooLarge = false
        do { try store.persistValidatedCapture(Data(repeating: 0, count: 3 * 1024 * 1024 + 1), profileURL: other) } catch { tooLarge = true }
        try check(tooLarge && (try Data(contentsOf: index)) == before, "oversize capture preserves original metadata")
        let xhs = "https://www.xiaohongshu.com/user/profile/0123456789abcdef01234567?xsec_token=SYNTHETIC_TOKEN"
        try store.persistValidatedCapture(png, profileURL: xhs)
        try store.recordFailure(profileURL: xhs, reason: "失败 https://example.invalid/?token=SYNTHETIC_TOKEN token=SYNTHETIC_TOKEN")
        let indexText = try String(contentsOf: index, encoding: .utf8)
        try check(!indexText.contains("SYNTHETIC_TOKEN") && !indexText.contains("xsec_token"), "navigation tokens and failure URLs never persist")
        let xhsImage = store.imageURL(for: xhs)!
        try store.prune(keeping: [alias])
        try check(store.imageURL(for: profile) != nil && store.entry(for: xhs) == nil && !FileManager.default.fileExists(atPath: xhsImage.path),
                  "explicit pruning keeps canonical retained profile and removes only deleted-profile cache")
        let keptImage = store.imageURL(for: profile)!
        try FileManager.default.removeItem(at: keptImage)
        try check(store.imageURL(for: profile) == nil && store.entry(for: profile)?.filename != nil, "missing file is honestly unavailable, never a fake replacement")

        let corruptFolder = folder.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        let corruptFile = corruptFolder.appendingPathComponent("index.json")
        try Data("not JSON".utf8).write(to: corruptFile)
        let corrupt = ProfileSnapshotStore(directory: corruptFolder)
        var corruptRejected = false
        do { try corrupt.recordFailure(profileURL: profile, reason: "retry") } catch { corruptRejected = true }
        try check(corrupt.loadError != nil && corruptRejected && (try String(contentsOf: corruptFile, encoding: .utf8)) == "not JSON", "corrupt index is preserved, not overwritten")

        let badPathFolder = folder.appendingPathComponent("bad-path")
        try FileManager.default.createDirectory(at: badPathFolder, withIntermediateDirectories: true)
        let forged: [String: Any] = ["schema": 1, "entries": [profile: ["profileIdentity": profile, "status": "ready",
            "checkedAt": "2026-10-25T04:30:00Z", "capturedAt": "2026-10-25T04:30:00Z", "filename": "../../outside.png"]]]
        try JSONSerialization.data(withJSONObject: forged).write(to: badPathFolder.appendingPathComponent("index.json"))
        let badPath = ProfileSnapshotStore(directory: badPathFolder)
        try check(badPath.loadError != nil && badPath.imageURL(for: profile) == nil, "index filenames cannot escape the private cache")

        let failedWriteFolder = folder.appendingPathComponent("failed-write")
        let failedWrite = ProfileSnapshotStore(directory: failedWriteFolder)
        try FileManager.default.createDirectory(at: failedWriteFolder.appendingPathComponent("index.json"), withIntermediateDirectories: false)
        var failedWriteRejected = false
        do { try failedWrite.persistValidatedCapture(png, profileURL: profile) } catch { failedWriteRejected = true }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: failedWriteFolder.path).filter { $0.hasSuffix(".png") }
        try check(failedWriteRejected && failedWrite.entry(for: profile) == nil && leftovers.isEmpty, "metadata commit failure rolls back only the new uncommitted image")
        print("PASS: \(checks) native snapshot-cache checks; DOM selectors and iPhone capture are not live-tested")
    }
}
