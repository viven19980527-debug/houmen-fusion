import Foundation

@main
@MainActor
struct FusionLeadChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw LocalFailure.message("FAILED: " + label) }
            count += 1; print("PASS: " + label)
        }
        func mustFail(_ label: String, _ action: () throws -> Void) throws {
            var failed = false
            do { try action() } catch { failed = true }
            try check(failed, label)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Fusion-checks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stamp = FusionDates.string(Date().addingTimeInterval(-60))
        func fixture(_ commentID: String = "1001", source: String = "https://www.bilibili.com/video/BV1234567890", profile: String = "https://space.bilibili.com/12345", text: String = "请问这个多少钱？", publication: String? = nil) -> FusionLead {
            FusionLead(platform: "bilibili", sourceURL: source, profileURL: profile,
                       commentID: commentID, text: text, authorName: "测试公开作者", keyword: "音响",
                       sourceTitle: "纯本地fixture", publishedAt: publication, collectedAt: stamp,
                       region: "广东", origin: "fixture")
        }
        let one = fixture()
        try check(try one.validated() == one, "bounded public Bili fixture accepted")
        try check(one.id.count == 64 && one.id == fixture().id, "deterministic SHA256 identity")
        try check(one.id == fixture(source: "https://m.bilibili.com/video/BV1234567890/").id, "canonical Bili source aliases deduplicate")
        try check(one.id != fixture("1002").id, "different comment IDs do not merge")
        try check(fixture("", profile: "https://space.bilibili.com/1").id != fixture("", profile: "https://space.bilibili.com/2").id, "fallback never merges by nickname")
        try check(fixture("", text: "第一条").id != fixture("", text: "第二条").id, "missing IDs retain different literal comments")
        try check(one.isQuestion && one.assessment.hasClue, "question and conservative intent rules available")
        for url in ["http://www.bilibili.com/video/BV1234567890", "https://www.bilibili.com.evil.invalid/video/BV1234567890",
                    "https://attacker@www.bilibili.com/video/BV1234567890", "https://www.bilibili.com:444/video/BV1234567890",
                    "https://www.bilibili.com/video/BV1234567890#fragment", "https://www.bilibili.com/video/BV1234567890?token=secret",
                    "https://www.bilibili.com/%76ideo/BV1234567890", "https://127.0.0.1/video/BV1234567890", "javascript:alert(1)"] {
            try mustFail("reject unsafe or unrecognized source") { _ = try fixture(source: url).validated() }
        }
        try check(try fixture(profile: "").validated().profileURL.isEmpty, "stable-ID comment can retain unknown public profile without fabrication")
        try mustFail("missing profile and missing stable ID cannot merge by nickname") { _ = try fixture("", profile: "").validated() }
        try mustFail("reject wrong-platform profile") { _ = try fixture(profile: "https://www.douyin.com/user/public_user").validated() }
        try mustFail("reject empty original text") { _ = try fixture(text: " ").validated() }
        try mustFail("reject future publication") { _ = try fixture(publication: FusionDates.string(Date().addingTimeInterval(86400))).validated() }
        try mustFail("reject Unix epoch sentinel as a real publication") { _ = try fixture(publication: "1970-01-01T00:00:00Z").validated() }
        try check(FusionDates.parse("2026-01-02") == nil && FusionDates.parse("2026-01-02T00:00:00Z") != nil, "date requires explicit ISO timestamp and zone")

        for invalidDate in ["2026-01-02T00:00:00Z\n", "2026-02-31T00:00:00Z", "2026-01-01T24:00:00Z", "2026-01-01T00:60:00Z", "2026-01-01T00:00:00+15:00", "2026-01-01T00:00:00+14:01"] {
            try check(FusionDates.parse(invalidDate) == nil, "invalid literal calendar or zone rejected")
        }

        let original = CommentStore(directory: root)
        let originalRow: [String: Any] = ["commentId": "fixture-houmen", "sourceUrl": "https://www.douyin.com/video/1234567890123456789",
            "profileUrl": "https://www.douyin.com/user/test_user", "authorName": "原公开账号", "text": "这个报价多少", "sourceTitle": "原来源", "product": "设备"]
        try original.save([originalRow])
        try original.preference(id: original.comments[0].id, saved: true, note: "保留旧备注")
        let oldPath = root.appendingPathComponent("comments.json")
        let oldBytes = try Data(contentsOf: oldPath)
        let store = FusionLeadStore(directory: root)
        try check(store.loadError == nil, "fresh separate store")
        let projected = store.allLeads(comments: original.comments)
        try check(projected.count == 1 && projected[0].origin == "houmen_local", "original records projected without copying")
        try check(store.followup(for: projected[0]).note == "保留旧备注" && store.followup(for: projected[0]).favorite, "original note and saved used as defaults")
        try check(store.followup(for: projected[0]).status == .pending, "favorite is not inferred purchase intent")
        let addedOnce = try store.add([one])
        let addedAgain = try store.add([one])
        try check(addedOnce == 1 && addedAgain == 0, "add and exact reimport deduplicate")
        try check(store.allLeads(comments: original.comments).count == 2, "one workbench combines both origins")
        try store.update(id: projected[0].id, status: .contacted, note: "手工更新")
        try check(try Data(contentsOf: oldPath) == oldBytes, "followup never modifies original comments.json")
        try check(try store.remove(ids: [projected[0].id]) == 0, "delete operation cannot remove original Houmen records")
        let persisted = root.appendingPathComponent("fusion-leads-v1.json")
        let before = try Data(contentsOf: persisted)
        try mustFail("invalid mixed add is atomic") { _ = try store.add([fixture("new"), fixture(source: "https://evil.invalid/")]) }
        try check(try Data(contentsOf: persisted) == before && store.records.count == 1, "failed batch leaves disk and memory unchanged")

        try store.update(id: one.id, status: .interested, note: "人工确认，不是规则推断")
        let exported = try store.exportJSON(rows: store.allLeads(comments: original.comments))
        let restored = FusionLeadStore(directory: root.appendingPathComponent("restored"))
        try check(try restored.importJSON(data: exported) == 2, "own JSON roundtrip imports two rows")
        try check(restored.followup(for: one).status == .interested && restored.followup(for: projected[0]).note == "手工更新", "own JSON restores explicit statuses and notes")
        try restored.update(id: one.id, status: .closed, note: "更近的人工编辑")
        try check(try restored.importJSON(data: exported) == 0 && restored.followup(for: one).status == .closed, "reimport does not overwrite current followup edits")

        // Importing before the workbench's first render still preserves the original note/saved.
        var restoredObject = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        var statesObject = restoredObject["followups"] as! [String: Any]
        statesObject[projected[0].id] = ["status": "contacted", "note": "", "favorite": false]
        restoredObject["followups"] = statesObject
        let oldDefaults = FusionLeadStore(directory: root.appendingPathComponent("preserve-defaults"))
        _ = try oldDefaults.importJSON(data: JSONSerialization.data(withJSONObject: restoredObject), comments: original.comments)
        try check(oldDefaults.followup(for: projected[0]).note == "保留旧备注" && oldDefaults.followup(for: projected[0]).favorite, "first-render import cannot clear original note or favorite")
        try check(oldDefaults.followup(for: projected[0]).status == .contacted, "import can restore explicit status without inferring from favorite")
        try check(try Data(contentsOf: oldPath) == oldBytes, "JSON import leaves original store byte-for-byte unchanged")

        var legacy: [String: Any] = ["platform": "bilibili", "uid": "345", "name": "公开旧作者", "profileURL": "https://space.bilibili.com/345",
            "text": "请问价格", "postTitle": "老数据", "videoURL": "https://www.bilibili.com/video/BV1234567890", "createdAt": 0,
            "contact": "DO_NOT_PERSIST_CONTACT", "ocrContact": "DO_NOT_PERSIST_OCR", "avatar": "DO_NOT_PERSIST_AVATAR", "bio": "DO_NOT_PERSIST_BIO", "cookie": "DO_NOT_PERSIST_COOKIE", "score": 999]
        let legacyStore = FusionLeadStore(directory: root.appendingPathComponent("legacy"))
        let data = try JSONSerialization.data(withJSONObject: [legacy])
        try check(try legacyStore.importJSON(data: data) == 1, "legacy LeadRadar JSON imports allowlisted fields")
        try check(legacyStore.records[0].publishedAt == nil && !legacyStore.lastImportWarnings.isEmpty, "legacy zero time remains unknown with warning")
        let legacyJSON = try legacyStore.exportJSON(rows: legacyStore.records)
        try check(!String(decoding: legacyJSON, as: UTF8.self).contains("DO_NOT_PERSIST"), "contact biography avatar and cookie fields excluded")
        legacy["createdAt"] = Int(Date().timeIntervalSince1970) + 86400
        try mustFail("legacy future time rejected") { _ = try legacyStore.importJSON(data: JSONSerialization.data(withJSONObject: [legacy])) }
        legacy["createdAt"] = true
        try mustFail("legacy boolean timestamp rejected") { _ = try legacyStore.importJSON(data: JSONSerialization.data(withJSONObject: [legacy])) }
        legacy["createdAt"] = 0; legacy["videoURL"] = ""
        try mustFail("legacy missing provenance rejected") { _ = try legacyStore.importJSON(data: JSONSerialization.data(withJSONObject: [legacy])) }
        try mustFail("oversized JSON rejected before parse") { _ = try legacyStore.importJSON(data: Data(repeating: 32, count: FusionLeadStore.maximumImportBytes + 1)) }
        try mustFail("legacy record count rejected before row parsing") {
            _ = try legacyStore.importJSON(data: JSONSerialization.data(withJSONObject: Array(repeating: legacy, count: FusionLeadStore.maximumRecords + 1)))
        }

        let csvLead = fixture("formula", text: "=HYPERLINK(\"bad\")")
        let csv = store.exportCSV(rows: [csvLead])
        try check(csv.hasPrefix("\u{feff}") && csv.contains("\"'=HYPERLINK(\"\"bad\"\")\""), "CSV escapes formulas and quotes")
        try check(csv.contains("评论发布时间（未知留空）") && !csv.contains("DO_NOT_PERSIST"), "CSV labels unknown publication and preserves allowlist")
        let subset = try restored.exportJSON(rows: [one])
        let subsetObject = try JSONSerialization.jsonObject(with: subset) as! [String: Any]
        try check((subsetObject["records"] as? [Any])?.count == 1 && (subsetObject["followups"] as? [String: Any])?.count == 1, "filtered JSON excludes other rows and states")
        let removed = try store.remove(ids: [one.id])
        let originalAfterDelete = try Data(contentsOf: oldPath)
        try check(removed == 1 && originalAfterDelete == oldBytes, "removing imported record leaves original file unchanged")

        let damagedFolder = root.appendingPathComponent("damaged")
        try FileManager.default.createDirectory(at: damagedFolder, withIntermediateDirectories: true)
        let damagedFile = damagedFolder.appendingPathComponent("fusion-leads-v1.json")
        let damagedBytes = Data("not-json-keep-this".utf8)
        try damagedBytes.write(to: damagedFile)
        let damaged = FusionLeadStore(directory: damagedFolder)
        try check(damaged.loadError != nil, "corrupt store exposes read error")
        try mustFail("corrupt store refuses mutation") { _ = try damaged.add([one]) }
        try check(try Data(contentsOf: damagedFile) == damagedBytes, "corrupt original is preserved")
        let oversizedFolder = root.appendingPathComponent("oversized-store")
        try FileManager.default.createDirectory(at: oversizedFolder, withIntermediateDirectories: true)
        let oversizedFile = oversizedFolder.appendingPathComponent("fusion-leads-v1.json")
        try Data(repeating: 32, count: FusionLeadStore.maximumImportBytes + 1).write(to: oversizedFile)
        let oversized = FusionLeadStore(directory: oversizedFolder)
        try check(oversized.loadError != nil, "oversized on-disk store blocked before loading")
        try mustFail("oversized on-disk store refuses overwrite") { _ = try oversized.add([one]) }
        print("FusionLeadChecks: \(count) checks passed; synthetic local fixtures only, no network or real-user data.")
    }
}
