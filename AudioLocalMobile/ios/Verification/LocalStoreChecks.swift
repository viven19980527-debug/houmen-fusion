import Foundation
import CryptoKit

@main
@MainActor
struct LocalStoreChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw LocalFailure.message("FAILED: " + label) }
            checks += 1
            print("PASS: " + label)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioLocal-checks-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CommentStore(directory: folder)
        try check(store.loadError == nil && store.comments.isEmpty, "empty isolated store")
        try check(CommentStore.validLink("https://www.douyin.com/video/1234567890123456789", profile: false), "video link")
        try check(CommentStore.validLink("https://www.douyin.com/user/test_user", profile: true), "profile link")
        for url in ["http://www.douyin.com/video/1234567890123",
                    "https://www.douyin.com.evil.invalid/video/1234567890123",
                    "https://x@www.douyin.com/video/1234567890123",
                    "https://www.douyin.com:444/video/1234567890123",
                    "javascript:alert(1)"] {
            try check(!CommentStore.validLink(url, profile: false), "reject unsafe link")
        }
        var row: [String: Any] = [
            "commentId": "fixture-1", "sourceUrl": "https://www.douyin.com/video/1234567890123456789",
            "profileUrl": "https://www.douyin.com/user/test_user", "authorName": "Test speaker shop",
            "text": "=1+1", "product": "Audio", "sourceTitle": "Fixture only",
            "privateToken": "MUST_NOT_PERSIST"
        ]
        try check(try store.save([row]) == 1, "persist comment")
        try check(store.comments.first?.id.count == 64, "SHA256 identity")
        let id = store.comments[0].id
        try store.preference(id: id, saved: true, note: "Follow up")
        row["text"] = "Updated fixture comment"
        try check(try store.save([row]) == 0, "deduplicate stable comment id")
        try check(store.comments.count == 1 && store.comments[0].saved && store.comments[0].note == "Follow up", "preserve user fields")
        let restored = CommentStore(directory: folder)
        try check(restored.loadError == nil && restored.comments.count == 1 && restored.comments[0].note == "Follow up", "disk reload")
        let file = folder.appendingPathComponent("comments.json")
        let before = try Data(contentsOf: file)
        let text = String(decoding: before, as: UTF8.self)
        try check(!text.contains("MUST_NOT_PERSIST") && !text.contains("privateToken"), "only allowlisted fields")
        var invalid = row
        invalid["sourceUrl"] = "https://example.invalid/video/1234567890123456789"
        var newRow = row
        newRow["commentId"] = "must-not-commit"
        newRow["text"] = "New record before invalid item"
        do { try store.save([newRow, invalid]); throw LocalFailure.message("Invalid batch accepted") }
        catch LocalFailure.message(let message) {
            guard message != "Invalid batch accepted" else { throw LocalFailure.message(message) }
        }
        try check(try Data(contentsOf: file) == before && store.comments.count == 1 && store.comments[0].id == id && store.comments[0].text == "Updated fixture comment" && store.comments[0].note == "Follow up", "invalid batch is atomic")
        try check(CommentStore.csvCell("=1+1") == "\"'=1+1\"", "CSV formula escaping")
        try check(CommentStore.csvCell("a\"b") == "\"a\"\"b\"", "CSV quote escaping")
        try check(store.csv().hasPrefix("\u{feff}") && store.csv().contains("Updated fixture comment"), "CSV UTF8 content")
        var second = row
        second["commentId"] = "fixture-2"
        second["profileUrl"] = "https://www.douyin.com/user/second_user"
        second["text"] = "请问多少钱"
        try check(try store.save([second]) == 1, "save a second lead")
        let secondID = store.comments.first { $0.commentId == "fixture-2" }!.id
        let subset = store.csv(records: store.comments.filter { $0.id == secondID })
        try check(subset.contains("请问多少钱") && !subset.contains("Updated fixture comment"), "filtered export excludes unselected records")
        try check(subset.contains("待人工确认") && subset.contains("询价"), "export labels include human review caveat")
        try check(try store.remove(ids: ["missing-record"]) == 0, "unknown cleanup selection is a no-op")
        try check(try store.remove(ids: [secondID]) == 1, "selected cleanup removes exactly one record")
        let afterCleanup = CommentStore(directory: folder)
        try check(afterCleanup.comments.count == 1 && afterCleanup.comments[0].id == id &&
                  afterCleanup.comments[0].saved && afterCleanup.comments[0].note == "Follow up", "cleanup persists and retains unselected user fields")
        try check(try store.remove(ids: Set(store.comments.map(\.id))) == 1, "clear confirmed snapshot")
        try check(CommentStore(directory: folder).comments.isEmpty, "clear persists across reload")

        let batchStore = CommentStore(directory: folder.appendingPathComponent("batches", isDirectory: true))
        let fifty: [[String: Any]] = (0..<50).map { index in
            var item = row
            item["commentId"] = "batch-" + String(index)
            return item
        }
        try check(try batchStore.save(fifty) == 50 && batchStore.comments.count == 50, "50 comments are not silently truncated")
        let tooMany = (0..<251).map { index -> [String: Any] in
            var item = row
            item["commentId"] = "oversize-" + String(index)
            return item
        }
        do { try batchStore.save(tooMany); throw LocalFailure.message("Oversized batch accepted") }
        catch LocalFailure.message(let message) {
            guard message != "Oversized batch accepted" else { throw LocalFailure.message(message) }
        }
        try check(batchStore.comments.count == 50 && CommentStore(directory: folder.appendingPathComponent("batches")).comments.count == 50,
                  "oversized batch fails without data loss")
        let datedFolder = folder.appendingPathComponent("dated")
        let datedStore = CommentStore(directory: datedFolder)
        var dated = row
        dated["commentId"] = "dated-1"; dated["publishedAt"] = "2026-01-02·广东"
        try datedStore.save([dated])
        let originalDate = datedStore.comments[0].publishedAtISO
        let originalObservation = datedStore.comments[0].collectedAt
        try check(originalDate != nil && datedStore.comments[0].region == "广东" &&
                  datedStore.comments[0].regionSource == "comment_ip", "store timestamp and label IP region")
        dated["publishedAt"] = "刚刚·北京"
        dated["age"] = 88
        try datedStore.save([dated])
        try check(datedStore.comments[0].publishedAtISO == originalDate &&
                  datedStore.comments[0].collectedAt == originalObservation, "duplicate recrawl does not rejuvenate old comment")
        try check(datedStore.comments[0].age == nil, "unverified raw age is never imported")
        var peer = dated; peer["commentId"] = "dated-2"
        try datedStore.save([peer])
        try datedStore.publicProfile(id: datedStore.comments[0].id, region: "上海", age: 32)
        try check(datedStore.comments.allSatisfy { $0.region == "上海" && $0.age == 32 &&
                  $0.regionSource == "manual_public_profile" }, "explicit verified profile edits update same public profile")
        let reopened = CommentStore(directory: datedFolder)
        try check(reopened.comments.allSatisfy { $0.age == 32 && $0.demographicSource == "manual_public_profile" },
                  "verified public profile survives reload")
        do { try datedStore.publicProfile(id: datedStore.comments[0].id, region: "上海", age: 121)
             throw LocalFailure.message("Invalid age accepted") }
        catch LocalFailure.message(let message) { guard message != "Invalid age accepted" else { throw LocalFailure.message(message) } }
        try check(datedStore.comments.allSatisfy { $0.age == 32 }, "invalid age preserves records")
        try datedStore.publicProfile(id: datedStore.comments[0].id, region: "", age: nil)
        try check(datedStore.comments.allSatisfy { $0.age == nil && $0.regionSource == "comment_ip" },
                  "clear manual fields restores original comment IP provenance")
        try check(CommentStore.commentIPRegion("昨天·未知") == nil &&
                  CommentStore.commentIPRegion("昨天·广东·其他") == nil, "ambiguous region is not inferred")
        var unknown = dated
        unknown["commentId"] = "previous-unknown"; unknown["publishedAt"] = ""
        try datedStore.save([unknown])
        unknown["publishedAt"] = "昨天"
        try datedStore.save([unknown])
        try check(datedStore.comments.first(where: { $0.commentId == "previous-unknown" }).flatMap(CommentRecency.publicationDate) != nil,
                  "a newly available date resolves after an unknown observation")
        try datedStore.remove(ids: Set(datedStore.comments.filter { $0.commentId == "previous-unknown" }.map(\.id)))
        let legacyFile = datedFolder.appendingPathComponent("comments.json")
        var legacyJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: legacyFile)) as! [[String: Any]]
        for index in legacyJSON.indices {
            for key in ["publishedAtISO","publishedTimeQuality","region","regionSource","age","demographicSource","profileVerifiedAt"] {
                legacyJSON[index].removeValue(forKey: key)
            }
        }
        try JSONSerialization.data(withJSONObject: legacyJSON).write(to: legacyFile, options: .atomic)
        let legacyStore = CommentStore(directory: datedFolder)
        try check(legacyStore.loadError == nil && legacyStore.comments.count == 2 && legacyStore.comments[0].age == nil,
                  "v011 records decode without new optional fields")

        let profileStore = CommentStore(directory: folder.appendingPathComponent("public-profile"))
        var firstProfile = row
        firstProfile["commentId"] = "person-first"; firstProfile["industry"] = "home"
        firstProfile["publishedAt"] = "昨天·浙江"
        try profileStore.save([firstProfile])
        try profileStore.publicProfile(id: profileStore.comments[0].id, region: "上海", age: 35)
        var samePerson = firstProfile
        samePerson["commentId"] = "person-next"; samePerson["sourceUrl"] = "https://www.douyin.com/video/1234567890123456790"
        samePerson["profileUrl"] = "https://douyin.com/user/test_user/"
        samePerson["publishedAt"] = "昨天·北京"
        try profileStore.save([samePerson])
        try check(profileStore.comments[1].age == 35 && profileStore.comments[1].region == "上海" &&
                  profileStore.comments[1].regionSource == "manual_public_profile", "new comments inherit verified same-profile data")
        try check(profileStore.comments[1].industry == "home" && profileStore.csv().contains("家居家装"),
                  "chosen industry is stored and exported")
        try profileStore.publicProfile(id: profileStore.comments[0].id, region: "", age: nil)
        samePerson["commentId"] = "person-after-clear"; samePerson["publishedAt"] = "昨天·广东"
        try profileStore.save([samePerson])
        try check(profileStore.comments[2].age == nil && profileStore.comments[2].region == "广东" &&
                  profileStore.comments[2].regionSource == "comment_ip", "cleared profile stays clear and IP is comment-local")
        var otherPerson = samePerson
        otherPerson["commentId"] = "other-person"; otherPerson["profileUrl"] = "https://www.douyin.com/user/other_person"
        try profileStore.save([otherPerson])
        try check(profileStore.comments[3].age == nil && profileStore.comments[3].demographicSource == nil,
                  "same nickname cannot inherit another public profile")

        let xhsStore = CommentStore(directory: folder.appendingPathComponent("xiaohongshu"))
        var xhs: [String: Any] = ["platform": "xiaohongshu", "industry": "home", "product": "窗帘定制",
            "sourceUrl": "https://www.xiaohongshu.com/explore/0123456789abcdef01234567?xsec_token=fixture-a&xsec_source=pc_search",
            "profileUrl": "https://www.xiaohongshu.com/user/profile/abcdef0123456789abcdef01",
            "commentId": "abcdef0123456789abcdef02", "authorName": "合成主页", "text": "怎么收费",
            "publishedAt": "昨天·广东"]
        try check(try xhsStore.save([xhs]) == 1 && xhsStore.comments[0].platform == "xiaohongshu",
                  "XHS public comment keeps platform boundary")
        xhs["sourceUrl"] = "https://www.xiaohongshu.com/search_result/0123456789abcdef01234567?xsec_token=fixture-b"
        try check(try xhsStore.save([xhs]) == 0 && xhsStore.comments.count == 1,
                  "XHS public-page parameter changes do not duplicate a comment")
        try check(xhsStore.csv().contains("小红书") && xhsStore.csv().contains("家居家装"),
                  "XHS CSV retains platform and industry")
        var mismatched = xhs
        mismatched["profileUrl"] = "https://www.douyin.com/user/test_user"
        do { try xhsStore.save([mismatched]); throw LocalFailure.message("Cross-platform author accepted") }
        catch LocalFailure.message(let message) { guard message != "Cross-platform author accepted" else { throw LocalFailure.message(message) } }
        try check(xhsStore.comments.count == 1, "source and author must belong to the same platform")
        try check(LeadGrouping.groups([xhsStore.comments[0], profileStore.comments[0]]).count == 2,
                  "same nickname cannot group across XHS and Douyin")


        let sourceNow = ISO8601DateFormatter().date(from:"2026-10-25T04:30:00Z")!
        let strictFolder = folder.appendingPathComponent("strict-source")
        let strictStore = CommentStore(directory:strictFolder)
        let currentProof = SourcePublicationGate.evidence(raw:"2026-10-24 10:00", observedAt:sourceNow)!
        var strictRow = row
        strictRow["commentId"] = "source-verified-1"
        strictRow.merge(currentProof.rowFields) { _, new in new }
        try check(try strictStore.save([strictRow], requireRecentSource:true, now:sourceNow) == 1, "strict source mode saves recent proven source")
        try check(strictStore.comments[0].sourcePublishedAtISO == currentProof.publishedAtISO &&
                  SourcePublicationGate.sourceEligible(strictStore.comments[0], now:sourceNow), "store persists independent source-publication evidence")
        let sourceReopened = CommentStore(directory:strictFolder)
        try check(SourcePublicationGate.sourceEligible(sourceReopened.comments[0], now:sourceNow), "source evidence survives store reopen")
        try check(strictStore.csv().contains("原视频发布时间") && strictStore.csv().contains(SourcePublicationGate.policy), "CSV exposes source publication and policy separately")
        let sourceFile = strictFolder.appendingPathComponent("comments.json")
        let priorStrictBytes = try Data(contentsOf:sourceFile)
        func rejectSource(_ rows: [[String:Any]], _ label: String, now:Date? = nil) throws {
            var rejected = false
            do { _ = try strictStore.save(rows, requireRecentSource:true, now:now ?? sourceNow) } catch { rejected = true }
            try check(rejected && (try Data(contentsOf:sourceFile)) == priorStrictBytes, label)
        }
        var missingSource = row; missingSource["commentId"] = "missing-source"
        try rejectSource([missingSource], "strict mode rejects missing source evidence without replacing old data")
        var oldSourceRow = strictRow; oldSourceRow["commentId"] = "old-source"
        oldSourceRow.merge(SourcePublicationGate.evidence(raw:"2026-07-27", observedAt:sourceNow)!.rowFields) { _, new in new }
        try rejectSource([oldSourceRow], "strict mode rejects old video even if comment itself is new")
        var forgedSource = strictRow; forgedSource["sourcePublishedAt"] = "更新于2026-10-25"
        try rejectSource([forgedSource], "strict mode rejects edit/update timestamp with plausible ISO")
        forgedSource = strictRow; forgedSource["sourceCheckedAt"] = "2026-10-26T04:30:00Z"
        try rejectSource([forgedSource], "strict mode rejects future source verification")
        var secondStrict = strictRow; secondStrict["commentId"] = "source-verified-2"
        try rejectSource([secondStrict, missingSource], "strict batch rejection is atomic even after a valid first row")
        let laterNow = ISO8601DateFormatter().date(from:"2027-02-05T04:30:00Z")!
        var rejuvenated = strictRow
        rejuvenated.merge(SourcePublicationGate.evidence(raw:"今天", observedAt:laterNow)!.rowFields) { _, new in new }
        try rejectSource([rejuvenated], "recrawling same source cannot rejuvenate original publication", now:laterNow)
        rejuvenated["commentId"] = "same-source-new-comment"
        try rejectSource([rejuvenated], "another comment cannot rejuvenate already-known source", now:laterNow)
        try check(try strictStore.save([secondStrict], requireRecentSource:true, now:sourceNow) == 1,
                  "another comment on same eligible source retains valid original time")
        try check(strictStore.comments.allSatisfy { $0.sourcePublishedAtISO == currentProof.publishedAtISO }, "source publication is stable across same-video comments")
        var correctedSource = strictRow; correctedSource["commentId"] = "correct-earlier-source"
        let earlierProof = SourcePublicationGate.evidence(raw:"2026-10-20 10:00", observedAt:sourceNow)!
        correctedSource.merge(earlierProof.rowFields) { _, new in new }
        try strictStore.save([correctedSource], requireRecentSource:true, now:sourceNow)
        try check(strictStore.comments.allSatisfy { $0.sourcePublishedAtISO == earlierProof.publishedAtISO },
                  "earlier verified source date corrects all comments on exactly that source")
        let laterBoundary = ISO8601DateFormatter().date(from:"2027-01-18T00:00:00+08:00")!
        try check(strictStore.comments.allSatisfy { !SourcePublicationGate.sourceEligible($0, now:laterBoundary) },
                  "corrected earlier source makes all its comments expire together")
        let legacySourceStore = CommentStore(directory:folder.appendingPathComponent("legacy-source"))
        try legacySourceStore.save([row], now:sourceNow)
        try check(legacySourceStore.comments.count == 1 && !SourcePublicationGate.sourceEligible(legacySourceStore.comments[0], now:sourceNow),
                  "compatible old import remains stored but is excluded by source gate")



        let tieredStore = CommentStore(directory:folder.appendingPathComponent("tiered-source"))
        for (offset, raw) in ["2026-10-10","2026-08-20"].enumerated() {
            var tieredRow = row; tieredRow["commentId"] = "tiered-" + String(offset)
            tieredRow["sourceUrl"] = "https://www.douyin.com/video/" + String(1234567890123456700 + offset)
            tieredRow.merge(SourcePublicationGate.evidence(raw:raw, observedAt:sourceNow)!.rowFields) { _, new in new }
            try check(try tieredStore.save([tieredRow], requireRecentSource:true, now:sourceNow) == 1,
                      "store accepts independent original source evidence in wider tier: " + raw)
        }
        try check(Set(tieredStore.comments.compactMap { SourcePublicationGate.sourceTier($0, now:sourceNow) }) == Set([30,90]),
                  "saved source tier derives from its publication, not newest comment")

        // Upgrade fixture uses the actual legacy raw-URL/concatenation hash, not a new-store id.
        let identityFolder = folder.appendingPathComponent("identity-upgrade")
        try FileManager.default.createDirectory(at: identityFolder, withIntermediateDirectories: true)
        let legacySource = "https://douyin.com/video/1234567890123456789/"
        let legacyProfile = "https://douyin.com/user/test_user/"
        func legacyRecord(commentID: String, text: String, note: String) -> AudioComment {
            let identity = legacySource + "|" + (commentID.isEmpty ? legacyProfile + "|" + text : commentID)
            let oldID = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return AudioComment(id: oldID, commentId: commentID, platform: "douyin", product: "Audio",
                text: text, authorName: "Same public name", authorId: "test_user", profileUrl: legacyProfile,
                publishedAt: "2026-10-24 10:00", sourceUrl: legacySource, sourceTitle: "Legacy fixture",
                collectedAt: "2026-10-25T04:30:00Z", saved: true, note: note)
        }
        let oldIdentified = legacyRecord(commentID: "legacy-fixed", text: "Old text", note: "Keep stable-id note")
        let oldFallback = legacyRecord(commentID: "", text: "Fallback fixture", note: "Keep fallback note")
        let identityFile = identityFolder.appendingPathComponent("comments.json")
        try JSONEncoder().encode([oldIdentified, oldFallback]).write(to: identityFile, options: .atomic)
        let identityStore = CommentStore(directory: identityFolder)
        var identityRow = row
        identityRow["commentId"] = "legacy-fixed"; identityRow["text"] = "Edited by same comment"
        identityRow["sourceUrl"] = "https://www.douyin.com/video/1234567890123456789"
        identityRow["profileUrl"] = "https://www.douyin.com/user/test_user"
        try check(try identityStore.save([identityRow], now: sourceNow) == 0 && identityStore.comments.count == 2,
                  "legacy Douyin raw-url hash is matched without creating another record")
        let migratedIdentified = identityStore.comments.first { $0.commentId == "legacy-fixed" }!
        try check(migratedIdentified.id == oldIdentified.id && migratedIdentified.saved &&
                  migratedIdentified.note == oldIdentified.note && migratedIdentified.collectedAt == oldIdentified.collectedAt,
                  "canonical recrawl retains legacy id, favorite, note and date anchor")
        identityRow["commentId"] = ""; identityRow["text"] = "Fallback fixture"
        identityRow["sourceUrl"] = "https://www.douyin.com:443/video/1234567890123456789/"
        identityRow["profileUrl"] = "https://www.douyin.com:443/user/test_user/"
        try check(try identityStore.save([identityRow], now: sourceNow) == 0 && identityStore.comments.count == 2,
                  "legacy fallback pairs canonical source and profile instead of duplicating")
        let migratedFallback = identityStore.comments.first { $0.commentId.isEmpty }!
        try check(migratedFallback.id == oldFallback.id && migratedFallback.saved && migratedFallback.note == oldFallback.note,
                  "fallback upgrade retains legacy user fields")
        identityRow["profileUrl"] = "https://www.douyin.com/user/another_user"
        try check(try identityStore.save([identityRow], now: sourceNow) == 1,
                  "same fallback text and nickname from another profile remain distinct")
        identityRow["profileUrl"] = "https://www.douyin.com/user/test_user"
        identityRow["commentId"] = "legacy-fixed"
        identityRow["sourceUrl"] = "https://www.douyin.com/video/1234567890123456790"
        try check(try identityStore.save([identityRow], now: sourceNow) == 1, "same platform id on another source remains distinct")
        identityRow["sourceUrl"] = legacySource; identityRow["profileUrl"] = legacyProfile
        identityRow["commentId"] = legacyProfile + "|Fallback fixture"
        try check(try identityStore.save([identityRow], now: sourceNow) == 1,
                  "old delimiter-hash collision cannot merge id and fallback namespaces")
        let collisionRecord = identityStore.comments.last!
        try check(collisionRecord.id != oldFallback.id && !collisionRecord.saved && collisionRecord.note.isEmpty,
                  "distinct namespace never inherits a different legacy record's preferences")
        let identityRestored = CommentStore(directory: identityFolder)
        try check(identityRestored.comments.count == 5 && identityRestored.comments.contains { $0.id == oldFallback.id && $0.note == oldFallback.note },
                  "upgrade deduplication and old ids survive disk reload")
        var freshRow = row; freshRow["commentId"] = "fresh-canonical"
        try check(try identityStore.save([freshRow], now: sourceNow) == 1, "new canonical id is inserted once")
        let freshID = identityStore.comments.last!.id
        freshRow["sourceUrl"] = legacySource; freshRow["profileUrl"] = legacyProfile
        try check(try identityStore.save([freshRow], now: sourceNow) == 0 && identityStore.comments.last!.id == freshID,
                  "new canonical records are stable across root-host and trailing-slash aliases")
        let expectedFields = CommentIdentity.fields(sourceURL: legacySource, profileURL: legacyProfile,
                                                   commentID: "fresh-canonical", text: "ignored when id is present")
        let expectedID = SHA256.hash(data: try JSONSerialization.data(withJSONObject: expectedFields))
            .map { String(format: "%02x", $0) }.joined()
        try check(freshID == expectedID, "new-store hash uses the shared checkpoint tuple encoding")

        // Protocol fixtures are synthetic. These exercise the actual Swift store, not a JS model.
        let protocolFolder = folder.appendingPathComponent("protocol-metadata")
        let protocolStore = CommentStore(directory: protocolFolder)
        var protocolRow: [String: Any] = [
            "platform": "xiaohongshu", "sourceUrl": "https://www.xiaohongshu.com/explore/0123456789abcdef01234567",
            "profileUrl": "https://www.xiaohongshu.com/user/profile/abcdef0123456789abcdef01",
            "commentId": "abcdef0123456789abcdef02", "authorName": "协议合成用户", "authorId": "abcdef0123456789abcdef01",
            "text": "请问多少钱", "publishedAt": "", "publishedAtISO": "2026-10-24T04:30:00Z",
            "publicHandle": "fixture_public", "parentCommentId": "abcdef0123456789abcdef03", "isReply": true,
            "ipLabel": "IP属地：广东", "likeCount": "12", "replyCount": 0, "acquisition": "local_protocol_response", "publishedTimeQuality": "exact",
            "age": 88, "region": "北京", "rawBody": "RAW_BODY_MUST_NOT_PERSIST",
            "Cookie": "COOKIE_MUST_NOT_PERSIST", "headers": ["x-s": "SIGNATURE_MUST_NOT_PERSIST"]
        ]
        let protocolProof = SourcePublicationGate.evidence(raw: "", iso: "2026-10-23T04:30:00Z", observedAt: sourceNow)!
        protocolRow.merge(protocolProof.rowFields) { _, evidence in evidence }
        try check(try protocolStore.save([protocolRow], requireRecentSource: true, now: sourceNow) == 1,
                  "protocol row and second-precision source evidence pass native storage")
        let protocolRecord = protocolStore.comments[0]
        try check(protocolRecord.publicHandle == "fixture_public" && protocolRecord.parentCommentId == "abcdef0123456789abcdef03" &&
                  protocolRecord.isReply == true && protocolRecord.acquisition == "local_protocol_response", "protocol public handle and reply metadata retained")
        try check(protocolRecord.likeCount == 12 && protocolRecord.replyCount == 0, "protocol counts include explicit zero")
        try check(protocolRecord.ipLabel == "广东" && protocolRecord.region == "广东" && protocolRecord.regionSource == "comment_ip",
                  "explicit protocol IP province is stored without inferring residence")
        try check(protocolRecord.publishedAt.isEmpty && protocolRecord.publishedAtISO == "2026-10-24T04:30:00Z" && protocolRecord.age == nil,
                  "protocol ISO does not forge visible date text or import unverified age")
        try check(protocolRecord.publishedTimeQuality == "exact", "native protocol ISO preserves exact time quality")
        let protocolFile = protocolFolder.appendingPathComponent("comments.json")
        let protocolBytes = String(decoding: try Data(contentsOf: protocolFile), as: UTF8.self)
        try check(!protocolBytes.contains("MUST_NOT_PERSIST") && !protocolBytes.contains("rawBody") && !protocolBytes.contains("Cookie"),
                  "raw responses credentials headers and arbitrary fields are never persisted")
        let protocolReloaded = CommentStore(directory: protocolFolder)
        try check(protocolReloaded.loadError == nil && protocolReloaded.comments[0].parentCommentId == protocolRecord.parentCommentId &&
                  protocolReloaded.comments[0].likeCount == 12 && protocolReloaded.comments[0].ipLabel == "广东", "protocol metadata survives disk reload")
        let protocolCSV = protocolStore.csv()
        try check(protocolCSV.contains("父评论标识") && protocolCSV.contains("点赞数") && protocolCSV.contains("fixture_public") &&
                  protocolCSV.contains("local_protocol_response"), "protocol metadata is explicitly exported in appended CSV columns")
        var sparseProtocolRow = protocolRow
        for key in ["publicHandle", "parentCommentId", "isReply", "ipLabel", "likeCount", "replyCount", "acquisition"] {
            sparseProtocolRow.removeValue(forKey: key)
        }
        try protocolStore.save([sparseProtocolRow], requireRecentSource: true, now: sourceNow)
        try check(protocolStore.comments[0].publicHandle == "fixture_public" && protocolStore.comments[0].parentCommentId == protocolRecord.parentCommentId &&
                  protocolStore.comments[0].isReply == true && protocolStore.comments[0].likeCount == 12 && protocolStore.comments[0].ipLabel == "广东",
                  "sparse duplicate observation preserves previous public protocol metadata")
        var invalidMetadata = sparseProtocolRow
        invalidMetadata["likeCount"] = true; invalidMetadata["replyCount"] = -1
        invalidMetadata["ipLabel"] = "北京·其他"; invalidMetadata["acquisition"] = "arbitrary-secret"
        try protocolStore.save([invalidMetadata], requireRecentSource: true, now: sourceNow)
        try check(protocolStore.comments[0].likeCount == 12 && protocolStore.comments[0].replyCount == 0 &&
                  protocolStore.comments[0].ipLabel == "广东" && protocolStore.comments[0].acquisition == "local_protocol_response",
                  "invalid metadata never replaces accepted counts province or acquisition")
        var zeroMetadata = sparseProtocolRow; zeroMetadata["likeCount"] = 0
        try protocolStore.save([zeroMetadata], requireRecentSource: true, now: sourceNow)
        try check(protocolStore.comments[0].likeCount == 0, "updated explicit zero count replaces prior nonzero value")
        try protocolStore.publicProfile(id: protocolRecord.id, region: "上海", age: 32)
        try protocolStore.save([protocolRow], requireRecentSource: true, now: sourceNow)
        try check(protocolStore.comments[0].region == "上海" && protocolStore.comments[0].regionSource == "manual_public_profile" &&
                  protocolStore.comments[0].age == 32 && protocolStore.comments[0].ipLabel == "广东", "manual public profile data takes priority over protocol IP")
        var sameProtocolPerson = protocolRow; sameProtocolPerson["commentId"] = "abcdef0123456789abcdef04"; sameProtocolPerson["ipLabel"] = "浙江"
        try protocolStore.save([sameProtocolPerson], requireRecentSource: true, now: sourceNow)
        try check(protocolStore.comments[1].region == "上海" && protocolStore.comments[1].ipLabel == "浙江" && protocolStore.comments[1].age == 32,
                  "same public profile retains manual region while each comment keeps its own IP")
        try protocolStore.publicProfile(id: protocolRecord.id, region: "", age: nil)
        try check(protocolStore.comments[0].region == "广东" && protocolStore.comments[1].region == "浙江" &&
                  protocolStore.comments.allSatisfy { $0.age == nil && $0.regionSource == "comment_ip" }, "clearing manual profile restores each explicit protocol IP")
        try check(CommentStore.publicIPRegion("IP属地: 北京") == "北京" && CommentStore.publicIPRegion("北京市") == nil &&
                  CommentStore.publicIPRegion("日本") == nil && CommentStore.publicIPRegion("北京·广东") == nil,
                  "only exact supported province labels are used without guessing")
        var oldProtocolJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: protocolFile)) as! [[String: Any]]
        for index in oldProtocolJSON.indices {
            for key in ["publicHandle", "parentCommentId", "isReply", "ipLabel", "likeCount", "replyCount", "acquisition"] {
                oldProtocolJSON[index].removeValue(forKey: key)
            }
        }
        try JSONSerialization.data(withJSONObject: oldProtocolJSON).write(to: protocolFile, options: .atomic)
        let oldProtocolStore = CommentStore(directory: protocolFolder)
        try check(oldProtocolStore.loadError == nil && oldProtocolStore.comments.count == 2 &&
                  oldProtocolStore.comments.allSatisfy { $0.publicHandle == nil && $0.parentCommentId == nil && $0.isReply == nil &&
                    $0.ipLabel == nil && $0.likeCount == nil && $0.replyCount == nil && $0.acquisition == nil },
                  "old comment JSON without new optional protocol fields remains decodable")

        checks += try LeadAssessmentChecks.run()
        try Data("not JSON".utf8).write(to: file, options: .atomic)
        let broken = CommentStore(directory: folder)
        try check(broken.loadError != nil, "corrupt store reported")
        do { try broken.save([row]); throw LocalFailure.message("Corrupt data overwritten") }
        catch LocalFailure.message(let message) {
            guard message != "Corrupt data overwritten" else { throw LocalFailure.message(message) }
        }
        try check(try String(contentsOf: file, encoding: .utf8) == "not JSON", "corrupt store preserved")
        print("PASS: \(checks) native Swift storage checks; no live-platform/device test performed")
    }
}
