import Foundation
import CryptoKit

/// Run as a separate macOS command-line executable with CollectionJob.swift.
/// Uses isolated temporary files and synthetic rows only; no WebKit/network/device test.
@main
struct CollectionJobChecks {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw CheckFailure(description: "FAILED: " + label) }
            checks += 1
            print("PASS: " + label)
        }
        func hash(_ value: String) -> String {
            SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        func rejects(_ job: CollectionJob, _ label: String) throws {
            var rejected = false
            do { try job.validate() } catch { rejected = true }
            try check(rejected, label)
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioLocal-job-checks-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = CollectionJobStore(directory: folder)
        try check(try store.load() == nil, "missing checkpoint is empty")

        var initial = CollectionJob(keyword: "Audio fixture")
        try initial.validate()
        try check(!initial.finished, "unsearched job is not completed")
        try store.save(initial)
        let initialBytes = try Data(contentsOf: store.file)
        let restoredInitial = try store.load()
        try check(restoredInitial?.keyword == initial.keyword && restoredInitial?.videos.isEmpty == true,
                  "initial checkpoint round trip")

        let videos = (0..<5).map { index in
            VideoTarget(url: "https://www.douyin.com/video/1234567890\(index)", title: "Fixture \(index)")
        }
        var partial = CollectionJob(keyword: "Audio fixture")
        partial.videos = videos
        partial.nextIndex = 1
        partial.seen = (0..<5).map { hash("seen-\($0)") }
        partial.currentVideoKeys = Array(partial.seen.suffix(2))
        partial.added = 4
        partial.outcomes = ["First video reached visible end; non-exhaustive"]
        try partial.validate()
        try store.save(partial)
        guard let restored = try store.load() else { throw CheckFailure(description: "Missing restored checkpoint") }
        try check(restored.keyword == partial.keyword && restored.videos == partial.videos &&
                  restored.nextIndex == partial.nextIndex && restored.seen == partial.seen &&
                  restored.currentVideoKeys == partial.currentVideoKeys && restored.added == partial.added &&
                  restored.outcomes == partial.outcomes && restored.createdAt == partial.createdAt,
                  "partial checkpoint restores exact progress")
        try check(!restored.finished, "partial checkpoint remains resumable")

        var complete = partial
        complete.nextIndex = 5
        complete.seen = (0..<250).map { hash("max-\($0)") }
        complete.currentVideoKeys = []
        complete.added = 250
        complete.outcomes = Array(repeating: "50 comments; non-exhaustive", count: 5)
        try complete.validate()
        try store.save(complete)
        try check(try store.load()?.finished == true, "250-row five-video boundary completes")
        var lastBatch = complete
        lastBatch.nextIndex = 4
        lastBatch.outcomes.removeLast()
        lastBatch.currentVideoKeys = Array(lastBatch.seen.suffix(50))
        try lastBatch.validate()
        try check(!lastBatch.finished, "last batch is not complete until video checkpoint advances")

        var candidate = partial
        candidate.schema = 2; try rejects(candidate, "reject unknown schema")
        for keyword in ["", " \n\t ", String(repeating: "a", count: 61)] {
            candidate = CollectionJob(keyword: keyword); try rejects(candidate, "reject invalid keyword")
        }
        candidate = partial; candidate.nextIndex = -1; try rejects(candidate, "reject negative index")
        candidate = complete; candidate.nextIndex = 6; try rejects(candidate, "reject index beyond video count")
        candidate = partial; candidate.videos.append(VideoTarget(url: "https://www.douyin.com/video/98765432100", title: "sixth"))
        try rejects(candidate, "reject more than five videos")
        candidate = partial; candidate.videos[1] = candidate.videos[0]
        try rejects(candidate, "reject duplicate video targets")
        for address in [
            "http://www.douyin.com/video/12345678900",
            "https://www.douyin.com.evil.invalid/video/12345678900",
            "https://other.douyin.com/video/12345678900",
            "https://user:password@www.douyin.com/video/12345678900",
            "https://www.douyin.com:444/video/12345678900",
            "https://www.douyin.com/video/12345678900?token=fixture",
            "https://www.douyin.com/video/12345678900#fixture",
            "https://www.douyin.com/user/fixture_user",
            "https://www.douyin.com/video/123456789",
            "https://www.douyin.com/video/" + String(repeating: "1", count: 31),
            "javascript:alert(1)", "file:///fixture", "not a URL"
        ] {
            candidate = partial
            candidate.videos[0] = VideoTarget(url: address, title: "invalid")
            try rejects(candidate, "reject unsafe or malformed video URL")
        }
        candidate = partial
        candidate.videos[0] = VideoTarget(url: videos[0].url, title: String(repeating: "x", count: 301))
        try rejects(candidate, "reject oversized video title")
        candidate = complete; candidate.seen.append(hash("extra")); try rejects(candidate, "reject more than 250 hashes")
        candidate = lastBatch; candidate.currentVideoKeys = Array(candidate.seen.suffix(51))
        try rejects(candidate, "reject more than 50 current-video hashes")
        candidate = partial; candidate.seen.append(candidate.seen[0]); try rejects(candidate, "reject duplicate seen hash")
        candidate = partial; candidate.currentVideoKeys.append(candidate.currentVideoKeys[0])
        try rejects(candidate, "reject duplicate current-video hash")
        candidate = partial; candidate.currentVideoKeys = [hash("not-seen")]
        try rejects(candidate, "current-video hashes must belong to seen")
        for invalidHash in ["", "abc", String(repeating: "A", count: 64),
                            String(repeating: "g", count: 64), String(repeating: "0", count: 65)] {
            candidate = partial; candidate.seen[0] = invalidHash
            try rejects(candidate, "reject malformed SHA256 identity")
        }
        for count in [-1, 251] {
            candidate = partial; candidate.added = count; try rejects(candidate, "reject invalid added count")
        }
        candidate = partial; candidate.outcomes = []; try rejects(candidate, "outcomes must match completed index")
        candidate = partial; candidate.outcomes = [String(repeating: "x", count: 301)]
        try rejects(candidate, "reject oversized outcome")

        // Regression cases: internally impossible checkpoints must never be presented as completed.
        candidate = partial; candidate.added = candidate.seen.count + 1
        try rejects(candidate, "added cannot exceed unique seen count")
        candidate = complete; candidate.currentVideoKeys = [candidate.seen[0]]
        try rejects(candidate, "completed job cannot have unfinished current-video keys")
        candidate = CollectionJob(keyword: "Audio fixture"); candidate.seen = [hash("orphan")]
        try rejects(candidate, "unsearched job cannot contain orphan progress")
        candidate = partial; candidate.nextIndex = 0; candidate.outcomes = []
        try rejects(candidate, "seen progress must fit completed and current-video bounds")
        for date in ["", "not-a-timestamp", String(repeating: "x", count: 100_001)] {
            candidate = partial; candidate.createdAt = date
            try rejects(candidate, "reject invalid or oversized creation timestamp")
        }

        var recent = CollectionJob(keyword: "recent fixture")
        recent.schema = 2; recent.recencyRaw = "last30Days"
        recent.currentAccepted = 0; recent.skippedOld = 0; recent.skippedUnknown = 0
        try recent.validate()
        try check(recent.scanLimit == 200 && recent.range == .last30Days, "v2 remembers selected recency")
        recent.videos = videos
        recent.seen = (0..<200).map { hash("recent-\($0)") }
        recent.currentVideoKeys = recent.seen
        recent.currentAccepted = 50; recent.added = 50; recent.skippedOld = 100; recent.skippedUnknown = 50
        try recent.validate()
        try store.save(recent)
        try check(try store.load()?.currentAccepted == 50, "v2 scans 200 and accepts at most 50")
        candidate = recent; candidate.currentAccepted = 51; try rejects(candidate, "reject v2 accepted over 50")
        candidate = recent; candidate.skippedOld = 201; try rejects(candidate, "reject skip counts beyond examined")
        candidate = recent; candidate.recencyRaw = "unsupported"; try rejects(candidate, "reject unknown recency")
        candidate = recent; candidate.currentAccepted = nil; try rejects(candidate, "v2 requires explicit counts")
        candidate = recent; candidate.skippedOld = Int.max; candidate.skippedUnknown = Int.max
        try rejects(candidate, "Int.max skip counts reject without overflow")
        candidate = recent; candidate.skippedOld = 200; candidate.skippedUnknown = 0
        try rejects(candidate, "skipped and saved counters cannot overlap")
        candidate = recent; candidate.skippedUnknown = -1; try rejects(candidate, "reject negative unknown count")
        candidate = recent; candidate.currentVideoKeys.append(hash("overflow")); candidate.seen = candidate.currentVideoKeys
        try rejects(candidate, "reject v2 scan beyond 200 per video")
        recent.nextIndex = 1; recent.currentVideoKeys = []; recent.currentAccepted = 0
        recent.outcomes = ["200 inspected"]
        try recent.validate()
        try check(recent.acceptedThisVideo == 0, "advance v2 clears accepted count")
        candidate = recent; candidate.currentAccepted = 1; try rejects(candidate, "accepted must fit current scan")
        var legacy = CollectionJob(keyword: "legacy")
        try check(legacy.range == .all && legacy.scanLimit == 50, "legacy checkpoint semantics preserved")
        legacy.recencyRaw = "last30Days"; try rejects(legacy, "legacy cannot mix v2 fields")

        var sector = CollectionJob(keyword: "custom fixture")
        sector.schema = 2; sector.recencyRaw = "last30Days"; sector.industryRaw = "home"
        sector.currentAccepted = 0; sector.skippedOld = 0; sector.skippedUnknown = 0
        try sector.validate(); try store.save(sector)
        try check(try store.load()?.industry == .home, "industry persists in resumable task")
        sector.industryRaw = nil
        try check(sector.industry == .general, "old tasks without industry retain general context")
        sector.industryRaw = "unsupported"
        try rejects(sector, "unknown industry never silently changes a task")

        var xhsJob = CollectionJob(keyword: "窗帘定制")
        xhsJob.schema = 2; xhsJob.platformRaw = "xiaohongshu"; xhsJob.industryRaw = "home"
        xhsJob.recencyRaw = "last30Days"; xhsJob.currentAccepted = 0; xhsJob.skippedOld = 0; xhsJob.skippedUnknown = 0
        xhsJob.videos = [VideoTarget(url: "https://www.xiaohongshu.com/explore/0123456789abcdef01234567?xsec_token=fixture-a", title: "Fixture")]
        try xhsJob.validate(); try store.save(xhsJob)
        try check(try store.load()?.platform == .xiaohongshu, "XHS checkpoint preserves platform")
        candidate = xhsJob; candidate.platformRaw = "channels"; try rejects(candidate, "Channels cannot create false collection checkpoint")
        candidate = xhsJob; candidate.platformRaw = "douyin"; try rejects(candidate, "checkpoint platform must match source")
        candidate = xhsJob; candidate.videos.append(VideoTarget(url: "https://www.xiaohongshu.com/search_result/0123456789abcdef01234567?xsec_token=fixture-b", title: "Same note"))
        try rejects(candidate, "same XHS note via another token is not another target")
        let xhsRowA: [String: Any] = ["sourceUrl": xhsJob.videos[0].url, "commentId": "fixture-comment"]
        let xhsRowB: [String: Any] = ["sourceUrl": "https://www.xiaohongshu.com/search_result/0123456789abcdef01234567?xsec_token=fixture-b", "commentId": "fixture-comment"]
        try check(CollectionJob.rowKey(xhsRowA) == CollectionJob.rowKey(xhsRowB), "XHS checkpoint identity excludes mutable public-page parameters")

        let originalRow: [String: Any] = [
            "sourceUrl": videos[0].url, "commentId": "fixture-comment-1",
            "profileUrl": "https://www.douyin.com/user/seller_1", "text": "Need audio"
        ]
        let key = CollectionJob.rowKey(originalRow)
        try check(key.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  "row identity is lowercase SHA256")
        var changed = originalRow; changed["text"] = "Edited text"; changed["product"] = "Other category"
        try check(CollectionJob.rowKey(changed) == key, "stable platform comment id deduplicates edits")
        changed = originalRow; changed["sourceUrl"] = videos[1].url
        try check(CollectionJob.rowKey(changed) != key, "same id in another source stays distinct")
        changed = originalRow; changed["commentId"] = "fixture-comment-2"
        try check(CollectionJob.rowKey(changed) != key, "distinct comment ids stay distinct")
        var fallback = originalRow; fallback["commentId"] = ""
        let fallbackKey = CollectionJob.rowKey(fallback)
        try check(fallbackKey == CollectionJob.rowKey(fallback), "fallback identity is deterministic")
        changed = fallback; changed["text"] = "Other text"
        try check(CollectionJob.rowKey(changed) != fallbackKey, "fallback distinguishes text")
        changed = fallback; changed["profileUrl"] = "https://www.douyin.com/user/seller_2"
        try check(CollectionJob.rowKey(changed) != fallbackKey, "fallback distinguishes author")
        changed = fallback; changed["commentId"] = "https://www.douyin.com/user/seller_1|Need audio"
        try check(CollectionJob.rowKey(changed) != fallbackKey, "id and fallback identity namespaces cannot collide")
        changed = originalRow; changed["privateToken"] = "SYNTHETIC_SHOULD_NOT_PERSIST"
        try check(CollectionJob.rowKey(changed) == key, "unrelated private fields do not affect identity")



        for source in ["https://douyin.com/video/1234567890123456789/",
                       "https://www.douyin.com:443/video/1234567890123456789/"] {
            var canonicalRow = originalRow
            canonicalRow["sourceUrl"] = "https://www.douyin.com/video/1234567890123456789"
            var alias = canonicalRow; alias["sourceUrl"] = source
            try check(CollectionJob.rowKey(alias) == CollectionJob.rowKey(canonicalRow),
                      "Douyin source URL aliases share a checkpoint identity")
        }
        changed = fallback; changed["sourceUrl"] = "https://douyin.com" + URL(string: videos[0].url)!.path + "/"
        changed["profileUrl"] = "https://douyin.com:443/user/seller_1/"
        try check(CollectionJob.rowKey(changed) == fallbackKey, "fallback pairs canonical source and profile aliases")
        changed = originalRow; changed["commentId"] = "  fixture-comment-1\n"; changed["text"] = "Other text"
        try check(CollectionJob.rowKey(changed) == key, "job identity normalizes fields exactly as storage does")
        var bounded = originalRow; bounded["commentId"] = String(repeating: "a", count: 101)
        changed = bounded; changed["commentId"] = String(repeating: "a", count: 100)
        try check(CollectionJob.rowKey(changed) == CollectionJob.rowKey(bounded), "job and store share comment-id bounds")
        var xhsFallbackA = xhsRowA; xhsFallbackA["commentId"] = ""; xhsFallbackA["text"] = "Same text"
        xhsFallbackA["profileUrl"] = "https://www.xiaohongshu.com/user/profile/abcdef0123456789abcdef01?xsec_token=fixture-a"
        var xhsFallbackB = xhsFallbackA
        xhsFallbackB["sourceUrl"] = xhsRowB["sourceUrl"]
        xhsFallbackB["profileUrl"] = "https://xiaohongshu.com/user/profile/ABCDEF0123456789ABCDEF01/?xsec_token=fixture-b"
        try check(CollectionJob.rowKey(xhsFallbackA) == CollectionJob.rowKey(xhsFallbackB), "XHS fallback uses canonical source and profile, not token")
        let searchReady: [String: Any] = ["state": "ready", "latestOrderConfirmed": true, "videos": [[String: Any]]()]
        try check(try CollectionJob.searchVideos(from: searchReady).isEmpty, "explicit valid empty source list remains a real empty search")
        var validSearch = searchReady; validSearch["videos"] = [["url": videos[0].url, "title": "Fixture"]]
        try check(try CollectionJob.searchVideos(from: validSearch).count == 1, "valid source envelope is decoded")
        let malformedVideoValues: [Any] = [NSNull(), "not an array", ["url": videos[0].url],
                                          [1, 2], [["url": videos[0].url], "invalid member"] as [Any]]
        for malformed in malformedVideoValues {
            var envelope = searchReady; envelope["videos"] = malformed
            var rejected = false
            do { _ = try CollectionJob.searchVideos(from: envelope) } catch { rejected = true }
            try check(rejected, "malformed videos never become empty-source completion")
        }
        for removedKey in ["videos", "state", "latestOrderConfirmed"] {
            var envelope = searchReady; envelope.removeValue(forKey: removedKey)
            var rejected = false
            do { _ = try CollectionJob.searchVideos(from: envelope) } catch { rejected = true }
            try check(rejected, "incomplete search envelope is rejected: " + removedKey)
        }
        var unconfirmedSearch = searchReady; unconfirmedSearch["latestOrderConfirmed"] = false
        var unconfirmedRejected = false
        do { _ = try CollectionJob.searchVideos(from: unconfirmedSearch) } catch { unconfirmedRejected = true }
        try check(unconfirmedRejected, "unconfirmed sort cannot yield a valid empty search")

        let sourceNow = ISO8601DateFormatter().date(from:"2026-10-25T04:30:00Z")!
        let proof = SourcePublicationGate.evidence(raw:"2026-10-25 10:00", observedAt: sourceNow)!
        var newest = CollectionJob(keyword:"new source fixture")
        newest.schema = 4; newest.sourcePolicy = SourcePublicationGate.policy
        newest.recencyRaw = "all"; newest.platformRaw = "douyin"; newest.industryRaw = "home"
        newest.currentAccepted = 0; newest.skippedOld = 0; newest.skippedUnknown = 0
        try newest.validate()
        try check(!newest.requiresFreshSourceSearch && newest.scanLimit == 200, "v4 tiered source-policy job supports bounded scan")
        newest.sourceOrderConfirmedAt = proof.checkedAt
        newest.videos = [VideoTarget(url:videos[0].url, title:"Recent original source", publication:proof)]
        try newest.validate(); try store.save(newest)
        let restoredNewest = try store.load()!
        try check(restoredNewest.sourcePolicy == SourcePublicationGate.policy && restoredNewest.videos[0].publication == proof,
                  "latest-source policy and publication evidence survive exact checkpoint round trip")
        try check(partial.requiresFreshSourceSearch && recent.requiresFreshSourceSearch, "legacy v1/v2 queue requires fresh source search")
        candidate = newest; candidate.sourcePolicy = nil; try rejects(candidate, "v4 missing strict source policy rejected")
        candidate = newest; candidate.sourcePolicy = "popular"; try rejects(candidate, "v4 cannot silently resume popular order")
        candidate = newest; candidate.sourceOrderConfirmedAt = nil; try rejects(candidate, "v4 selected targets require sorting confirmation")
        candidate = newest; candidate.sourceOrderConfirmedAt = "invalid"; try rejects(candidate, "v4 invalid sorting timestamp rejected")
        candidate = newest; candidate.videos[0].publication = nil; try rejects(candidate, "v4 target without publication evidence rejected")
        let oldProof = SourcePublicationGate.evidence(raw:"2026-07-27", observedAt:sourceNow)!
        candidate = newest; candidate.videos[0].publication = oldProof; try rejects(candidate, "v4 cannot enqueue source already outside 90-day window")
        let approximate = SourcePublicationGate.evidence(raw:"89天前", observedAt:sourceNow)!
        candidate = newest; candidate.videos[0].publication = approximate; try rejects(candidate, "v4 rejects relative boundary uncertainty")
        candidate = partial; candidate.sourcePolicy = SourcePublicationGate.policy; try rejects(candidate, "legacy cannot forge new source-policy semantics")
        candidate = recent; candidate.videos[0].publication = proof; try rejects(candidate, "v2 cannot mix v4 target evidence")
        candidate = newest; candidate.schema = 5; try rejects(candidate, "unknown future schema rejected")
        var noSources = CollectionJob(keyword:"no recent sources")
        noSources.schema = 4; noSources.sourcePolicy = SourcePublicationGate.policy; noSources.searchExhausted = true
        noSources.recencyRaw = "all"; noSources.currentAccepted = 0; noSources.skippedOld = 0; noSources.skippedUnknown = 0
        try noSources.validate(); try store.save(noSources)
        try check(try store.load()?.finished == true, "zero eligible sources persist a terminal state, not endless resume")
        candidate = noSources; candidate.videos = newest.videos; try rejects(candidate, "source-exhausted terminal cannot contain a target")
        candidate = noSources; candidate.seen = [hash("orphan-source-terminal")]; try rejects(candidate, "source-exhausted terminal cannot have comment progress")
        candidate = partial; candidate.searchExhausted = false; try rejects(candidate, "legacy cannot mix new source-exhaustion semantics")


        var legacyV3 = newest; legacyV3.schema = 3; legacyV3.sourcePolicy = SourcePublicationGate.legacyPolicy
        try legacyV3.validate(); try store.save(legacyV3)
        let legacyV3Bytes = try Data(contentsOf: store.file)
        let loadedLegacyV3 = try store.load()!
        try check(loadedLegacyV3.schema == 3 && loadedLegacyV3.requiresFreshSourceSearch &&
                  loadedLegacyV3.videos == legacyV3.videos && (try Data(contentsOf: store.file)) == legacyV3Bytes,
                  "schema3 old policy stays readable without rewriting/deleting data but requires fresh tiered search")
        candidate = legacyV3; candidate.sourcePolicy = SourcePublicationGate.policy
        try rejects(candidate, "schema3 cannot claim the new tiered policy")
        candidate = newest; candidate.sourcePolicy = SourcePublicationGate.legacyPolicy
        try rejects(candidate, "schema4 cannot silently run the old seven-day policy")
        candidate = legacyV3; candidate.videos[0].publication = SourcePublicationGate.evidence(raw:"2026-10-18", observedAt:sourceNow)!
        try rejects(candidate, "legacy schema3 evidence retains original seven-day validation at its observation")
        for (raw,tier) in [("2026-10-24",7),("2026-10-10",30),("2026-08-20",90)] {
            candidate = newest; candidate.videos[0].publication = SourcePublicationGate.evidence(raw:raw, observedAt:sourceNow)!
            try candidate.validate()
            try check(SourcePublicationGate.tier(candidate.videos[0].publication, now:sourceNow) == tier,
                      "schema4 accepts a verified source in tier " + String(tier))
        }
        let tierFixtures = [
            VideoTarget(url:videos[0].url, title:"tier90", publication:SourcePublicationGate.evidence(raw:"2026-08-20", observedAt:sourceNow)),
            VideoTarget(url:videos[1].url, title:"tier7older", publication:SourcePublicationGate.evidence(raw:"2026-10-20", observedAt:sourceNow)),
            VideoTarget(url:videos[0].url, title:"tier30", publication:SourcePublicationGate.evidence(raw:"2026-10-10", observedAt:sourceNow)),
            VideoTarget(url:videos[1].url, title:"tier7newer", publication:proof),
            VideoTarget(url:videos[0].url, title:"unknown"),
            VideoTarget(url:videos[0].url, title:"old", publication:oldProof)]
        try check(CollectionJob.prioritizedTargets(tierFixtures, now:sourceNow).map(\.title) == ["tier7newer","tier7older","tier30","tier90"],
                  "verified targets are sorted by tier then source date, not comment or discovery order")
        let uncertainTier = VideoTarget(url:videos[0].url, title:"rounded30", publication:SourcePublicationGate.evidence(raw:"6天前", observedAt:sourceNow))
        let exactTier = VideoTarget(url:videos[1].url, title:"precise7", publication:SourcePublicationGate.evidence(raw:"2026-10-19 00:00", observedAt:sourceNow))
        try check(CollectionJob.prioritizedTargets([uncertainTier,exactTier], now:sourceNow).map(\.title) == ["precise7","rounded30"],
                  "precisely established newest tier outranks a nominally newer but uncertain rounded label")
        for days in SourcePublicationGate.windows {
            var envelope = searchReady; envelope["sourceWindowDays"] = days
            envelope["timeFilterApplied"] = days == 7 ? "一周内" : "不限"
            try check(try CollectionJob.searchVideos(from:envelope, sourceWindowDays:days).isEmpty,
                      "window-scoped search proof accepts exact requested tier")
            envelope["sourceWindowDays"] = days == 7 ? 30 : 7
            var mismatchRejected = false
            do { _ = try CollectionJob.searchVideos(from:envelope, sourceWindowDays:days) } catch { mismatchRejected = true }
            try check(mismatchRejected, "previous search-tier proof cannot be reused for another window")
        }

        // Persistence-only regression: these transitions model the checkpoint produced after a
        // comment timeout or a confirmed empty source. They do not execute WebKit or its poller.
        let secondProof = SourcePublicationGate.evidence(raw: "2026-10-24 10:00", observedAt: sourceNow)!
        try check(SourcePublicationGate.eligible(proof, now: sourceNow) &&
                  SourcePublicationGate.eligible(secondProof, now: sourceNow),
                  "two-source checkpoint fixture uses original publications inside seven days")
        let secondTarget = VideoTarget(url: videos[1].url, title: "Second recent source", publication: secondProof)
        let emptySourceOutcomes = [
            ("comment timeout", "Comment wait timed out; comment availability unconfirmed, not zero"),
            ("explicit zero", "Platform explicitly confirmed zero comments")
        ]
        for (label, firstOutcome) in emptySourceOutcomes {
            var twoSources = newest
            twoSources.videos = [newest.videos[0], secondTarget]
            twoSources.nextIndex = 1
            twoSources.outcomes = [firstOutcome]
            try twoSources.validate()
            try store.save(twoSources)
            guard var resumed = try store.load() else {
                throw CheckFailure(description: "Missing two-source checkpoint after " + label)
            }
            try check(resumed.nextIndex == 1 && !resumed.finished &&
                      resumed.videos[resumed.nextIndex] == secondTarget,
                      label + " checkpoint resumes at second source, not the empty first source")
            try check(resumed.seen.isEmpty && resumed.currentVideoKeys.isEmpty &&
                      resumed.acceptedThisVideo == 0 && resumed.added == 0,
                      label + " checkpoint never invents examined keys or saved comments")
            try check(resumed.outcomes == [firstOutcome] && resumed.searchExhausted != true &&
                      !resumed.requiresFreshSourceSearch,
                      label + " preserves its distinct outcome without finishing or restarting search")

            // Model successful completion of the remaining source with one synthetic saved key.
            resumed.seen = [hash("second-source-after-" + label)]
            resumed.added = 1
            resumed.nextIndex = resumed.videos.count
            resumed.outcomes.append("Second source checked; one synthetic comment saved")
            try resumed.validate()
            try store.save(resumed)
            guard let finishedSources = try store.load() else {
                throw CheckFailure(description: "Missing finished two-source checkpoint after " + label)
            }
            try check(finishedSources.finished && finishedSources.nextIndex == 2 &&
                      finishedSources.outcomes.count == 2 && finishedSources.outcomes[0] == firstOutcome,
                      label + " checkpoint finishes only after the final target advances")
            try check(finishedSources.seen == resumed.seen && finishedSources.added == 1 &&
                      finishedSources.currentVideoKeys.isEmpty && finishedSources.acceptedThisVideo == 0,
                      label + " final checkpoint retains only the second source's completed progress")
        }

        // Validated historical checkpoints remain readable; the runtime rechecks eligibility at resume/save.
        try check(!SourcePublicationGate.eligible(restoredNewest.videos[0].publication,
                  now:ISO8601DateFormatter().date(from:"2027-02-05T04:30:00Z")!), "source proof expires without corrupting readable historical checkpoint")

        // Invalid writes are rejected before replacing a valid on-disk checkpoint.
        try store.save(partial)
        let beforeInvalidWrite = try Data(contentsOf: store.file)
        candidate = partial; candidate.schema = 2
        var writeRejected = false
        do { try store.save(candidate) } catch { writeRejected = true }
        try check(writeRejected && (try Data(contentsOf: store.file)) == beforeInvalidWrite,
                  "invalid save preserves original checkpoint bytes")

        func expectBadDisk(_ bytes: Data, _ label: String) throws {
            try bytes.write(to: store.file, options: .atomic)
            var rejected = false
            do { _ = try store.load() } catch { rejected = true }
            try check(rejected && (try Data(contentsOf: store.file)) == bytes,
                      label + " is rejected without rewriting original")
        }
        try expectBadDisk(Data("not JSON".utf8), "corrupt checkpoint")
        try expectBadDisk(Data(repeating: 0x20, count: 100_001), "oversized checkpoint")
        var dictionary = try JSONSerialization.jsonObject(with: initialBytes) as! [String: Any]
        dictionary["nextIndex"] = "not an integer"
        try expectBadDisk(try JSONSerialization.data(withJSONObject: dictionary), "wrong-type checkpoint field")
        dictionary = try JSONSerialization.jsonObject(with: initialBytes) as! [String: Any]
        dictionary.removeValue(forKey: "keyword")
        try expectBadDisk(try JSONSerialization.data(withJSONObject: dictionary), "missing required checkpoint field")

        // Starting a new task is an explicit replacement; loading corrupt data never does that.
        try store.save(initial)
        try check(try store.load()?.keyword == initial.keyword, "explicit new task can replace corrupt checkpoint")
        dictionary = try JSONSerialization.jsonObject(with: initialBytes) as! [String: Any]
        dictionary["privateToken"] = "SYNTHETIC_SHOULD_NOT_PERSIST"
        dictionary["comments"] = [["text": "SYNTHETIC_FULL_COMMENT"]]
        try JSONSerialization.data(withJSONObject: dictionary).write(to: store.file, options: .atomic)
        guard let knownFields = try store.load() else { throw CheckFailure(description: "Missing typed checkpoint") }
        try store.save(knownFields)
        let savedText = try String(contentsOf: store.file, encoding: .utf8)
        try check(!savedText.contains("SYNTHETIC_SHOULD_NOT_PERSIST") &&
                  !savedText.contains("SYNTHETIC_FULL_COMMENT") && !savedText.contains("privateToken"),
                  "typed checkpoint serialization excludes unknown credential and comment fields")

        print("PASS: \(checks) native Swift collection-job checks; no WebKit/device/live-platform test performed")
    }
}
