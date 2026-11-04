import Foundation

/// Isolated fixtures; no browser/account data. Compile with CommentStore, LeadAssessment, CommentRecency.
@main
@MainActor
struct RecencyChecks {
    struct Failure: Error { let message: String }
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw Failure(message: "FAILED: " + label) }
            checks += 1; print("PASS: " + label)
        }
        func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
        let now = date("2026-10-25T12:30:00+08:00")
        func parses(_ raw: String, _ expected: String, quality: String? = nil, anchor: Date? = nil) throws {
            let parsed = CommentRecency.parse(raw, observedAt: anchor ?? now)
            try check(parsed?.date == date(expected), "parse: " + raw)
            if let quality { try check(parsed?.quality == quality, "quality: " + raw) }
        }
        try parses("3天前·广东", "2026-10-22T12:30:00+08:00", quality: "relative")
        try parses("三天前", "2026-10-22T12:30:00+08:00")
        try parses("二十三分钟前", "2026-10-25T12:07:00+08:00")
        try parses("十天前", "2026-10-15T12:30:00+08:00")
        try parses("5秒前", "2026-10-25T12:29:55+08:00")
        try parses("2分钟前", "2026-10-25T12:28:00+08:00")
        try parses("2小时前", "2026-10-25T10:30:00+08:00")
        try parses("1周前", "2026-10-18T12:30:00+08:00")
        try parses("两星期前", "2026-10-11T12:30:00+08:00")
        try parses("1个月前", "2026-09-25T12:30:00+08:00")
        try parses("1年前", "2025-10-25T12:30:00+08:00")
        try parses("昨天", "2026-10-24T00:00:00+08:00")
        try parses("前天", "2026-10-23T00:00:00+08:00")
        try parses("今天", "2026-10-25T00:00:00+08:00")
        try parses("刚刚", "2026-10-25T12:30:00+08:00")
        try parses("昨天 23:59", "2026-10-24T23:59:00+08:00")
        try parses("今天 10:20:30", "2026-10-25T10:20:30+08:00")
        try parses("2025-10-24", "2025-10-24T00:00:00+08:00", quality: "day")
        try parses("2026-10-24 10:05:06", "2026-10-24T10:05:06+08:00", quality: "exact")
        try parses("2026年10月24日", "2026-10-24T00:00:00+08:00")
        try parses("2026/10/24", "2026-10-24T00:00:00+08:00")
        try parses("10-24", "2026-10-24T00:00:00+08:00", quality: "inferredYear")
        try parses("10月24日·浙江", "2026-10-24T00:00:00+08:00")
        try parses("发布于 10-24 IP属地：广东", "2026-10-24T00:00:00+08:00")
        try parses("１０－２４", "2026-10-24T00:00:00+08:00")
        try parses("12-31", "2026-12-31T00:00:00+08:00", anchor: date("2027-01-02T01:00:00+08:00"))
        try parses("昨天", "2026-12-31T00:00:00+08:00", anchor: date("2027-01-01T00:15:00+08:00"))
        try parses("1个月前", "2026-02-28T12:30:00+08:00", anchor: date("2026-03-31T12:30:00+08:00"))
        try parses("1年前", "2023-02-28T12:30:00+08:00", anchor: date("2024-02-29T12:30:00+08:00"))
        try parses("2024-02-29", "2024-02-29T00:00:00+08:00")
        try parses("2-29", "2024-02-29T00:00:00+08:00", quality: "inferredYear")
        try parses("2-29", "2096-02-29T00:00:00+08:00", anchor: date("2103-03-01T12:30:00+08:00"))
        for raw in ["", "未知", "加载中", "2025-02-29", "2026-04-31", "2026-13-01", "2026-00-01", "2026-10-00",
                    "2026-10-26", "2026-10-25 24:00", "今天 23:59", "10-25 23:59", "昨天 12:99",
                    "编辑于10-24", "编辑于 3天前·广东", "3天前（编辑）", "上午10:00", "周一", "13800000000", "十十天前"] {
            try check(CommentRecency.parse(raw, observedAt: now) == nil, "unknown/invalid/edit date stays unknown: " + raw)
        }
        func fixture(_ id: String, raw: String = "未知", observed: String = "2026-10-25T04:30:00Z", iso: String? = nil, quality: String? = nil,
                     region: String? = nil, age: Int? = nil) -> AudioComment {
            var value = AudioComment(id: id, commentId: id, platform: "douyin", product: "线阵音响", text: "请问多少钱",
                authorName: "合成测试用户", authorId: "fixture", profileUrl: "https://www.douyin.com/user/fixture_user",
                publishedAt: raw, sourceUrl: "https://www.douyin.com/video/1234567890123456789", sourceTitle: "合成视频",
                collectedAt: observed, saved: false, note: "")
            value.publishedAtISO = iso; value.publishedTimeQuality = quality; value.region = region; value.age = age
            return value
        }
        let old = fixture("old", raw: "3天前")
        try check(CommentRecency.publicationDate(old) == date("2026-10-22T12:30:00+08:00"), "legacy relative date anchored to collectedAt")
        try check(CommentRecency.filteredAndSorted([old], range: .last7Days, now: date("2026-11-05T12:30:00+08:00")).isEmpty, "legacy date does not advance with current clock")
        let badAnchor = fixture("bad-anchor", raw: "刚刚", observed: "invalid")
        try check(CommentRecency.publicationDate(badAnchor) == nil, "bad collection anchor never falls back to now")
        let stableISO = "2026-10-22T04:30:00Z"
        let stable = fixture("stable", raw: "3天前", observed: "2026-11-01T04:30:00Z", iso: stableISO, quality: "relative")
        try check(CommentRecency.publicationDate(stable) == date(stableISO), "saved publication survives repeated collection without drifting")
        try check(CommentRecency.displayTime(stable).hasPrefix("约 "), "estimated persisted time retains approximate label")
        try check(CommentRecency.displayTime(badAnchor) == "时间未知", "unknown display never claims latest")
        try check(CommentRecency.displayTime(fixture("short", raw: "10-24")).hasPrefix("约 "), "inferred year is explicitly approximate")
        try check(CommentRecency.resolved(raw: "未知", iso: "2026-02-30T00:00:00Z", observedAt: now) == nil, "invalid persisted ISO is not normalized")
        try check(CommentRecency.resolved(raw: "未知", iso: "2027-01-01T00:00:00Z", observedAt: now) == nil, "future persisted ISO rejected against observation")
        try check(CommentRecency.resolved(raw: "未知", iso: "2026-10-22T04:30:00.000Z", observedAt: now)?.date == date(stableISO), "fractional ISO supported")
        try check(CommentRecency.publicationDate(fixture("trusted", observed: "invalid", iso: stableISO)) == date(stableISO), "trusted stored ISO does not need an invented collection anchor")
        let lower30 = date("2026-09-26T00:00:00+08:00"), lower7 = date("2026-10-19T00:00:00+08:00")
        func stamp(_ d: Date) -> PublicationTime { PublicationTime(date: d, quality: "exact") }
        try check(CommentRecency.accepts(stamp(lower30), range: .last30Days, now: now), "30 day lower bound inclusive")
        try check(!CommentRecency.accepts(stamp(lower30.addingTimeInterval(-1)), range: .last30Days, now: now), "before 30 day lower bound excluded")
        try check(CommentRecency.accepts(stamp(lower7), range: .last7Days, now: now), "7 day lower bound inclusive")
        try check(!CommentRecency.accepts(stamp(lower7.addingTimeInterval(-1)), range: .last7Days, now: now), "before 7 day lower bound excluded")
        try check(CommentRecency.accepts(stamp(now), range: .last7Days, now: now), "current instant inclusive")
        try check(!CommentRecency.accepts(stamp(now.addingTimeInterval(1)), range: .last30Days, now: now), "future instants excluded")
        try check(!CommentRecency.accepts(nil, range: .last30Days, now: now) && CommentRecency.accepts(nil, range: .all, now: now), "unknown only in all-time view")
        let unknown = fixture("unknown"), recent = fixture("recent", raw: "今天"), older = fixture("older", raw: "2025-10-24")
        try check(CommentRecency.filteredAndSorted([unknown,older,recent,old], range: .all, now: now).map(\.id) == ["recent","old","older","unknown"], "publication sorting independent of collection order; unknown last")
        try check(CommentRecency.filteredAndSorted([unknown,older,recent,old], range: .last30Days, now: now).map(\.id) == ["recent","old"], "recent default excludes old and unknown records without deleting them")
        try check(CommentRecency.filteredAndSorted([fixture("tie1", raw:"今天"),fixture("tie2", raw:"今天")], range: .all, now: now).map(\.id) == ["tie1","tie2"], "equal dates preserve input order")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        for key in ["publishedAtISO","publishedTimeQuality","region","regionSource","age","demographicSource"] { legacy.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(AudioComment.self, from: JSONSerialization.data(withJSONObject: legacy))
        try check(decoded.publishedAtISO == nil && decoded.age == nil && decoded.region == nil, "new optional fields decode missing legacy keys")
        try check(CommentRecency.publicationDate(decoded) == CommentRecency.publicationDate(old), "legacy JSON preserves relative normalization")

        let a = fixture("a", region:" 广东省 ", age:20), b = fixture("b", region:"广东", age:30)
        let c = fixture("c", region:"浙江", age:40), u = fixture("u", region:"广东", age:nil)
        let absent = fixture("absent", region:nil, age:25), invalidAge = fixture("invalid", region:"广东", age:121)
        let people = [b,u,c,a,absent,invalidAge]
        try check(CommentRecency.filterDemographics(people, region:" 广东 ", minimumAge:20, maximumAge:30, includeUnknownAge:false).map(\.id) == ["b","a"], "region/age inclusive filter keeps source order")
        try check(CommentRecency.filterDemographics(people, region:"广东", minimumAge:20, maximumAge:30, includeUnknownAge:true).map(\.id) == ["b","u","a","invalid"], "unknown and invalid age obey explicit include switch")
        try check(CommentRecency.filterDemographics([absent], region:"广东", minimumAge:nil, maximumAge:nil, includeUnknownAge:true).isEmpty, "missing region does not match requested region")
        try check(CommentRecency.filterDemographics(people, region:"", minimumAge:nil, maximumAge:nil, includeUnknownAge:true).count == people.count, "empty demographic restrictions retain all with unknown option")
        try check(CommentRecency.filterDemographics(people, region:"", minimumAge:nil, maximumAge:nil, includeUnknownAge:false).map(\.id) == ["b","c","a","absent"], "unknown age hidden when switch off even without numeric limits")
        try check(CommentRecency.filterDemographics(people, region:"", minimumAge:31, maximumAge:20, includeUnknownAge:true).isEmpty, "reversed age range never silently returns all")
        try check(CommentRecency.filterDemographics(people, region:"", minimumAge:0, maximumAge:nil, includeUnknownAge:true).isEmpty, "lower age out of domain rejected")
        try check(CommentRecency.filterDemographics(people, region:"", minimumAge:nil, maximumAge:121, includeUnknownAge:true).isEmpty, "upper age out of domain rejected")
        try check(CommentRecency.filterDemographics([fixture("one", age:1),fixture("oldest", age:120)], region:"", minimumAge:1, maximumAge:120, includeUnknownAge:false).count == 2, "valid age boundaries inclusive")
        try check(CommentRecency.filterDemographics([fixture("literal-number", raw:"30年前", age:nil)], region:"", minimumAge:20, maximumAge:40, includeUnknownAge:false).isEmpty, "no inferred age from date text or comment")
        try check(a.region == " 广东省 ", "region normalization does not mutate source field")

        // Source-video gate is independent from comment recency and never treats an edit as publication.
        func source(_ raw: String, iso: String? = nil, anchor: Date? = nil) -> SourcePublicationEvidence? {
            SourcePublicationGate.evidence(raw: raw, iso: iso, observedAt: anchor ?? now)
        }
        func within7(_ evidence: SourcePublicationEvidence?, now: Date) -> Bool {
            SourcePublicationGate.eligible(evidence, now: now, windowDays: 7)
        }
        let sourceToday = source("发布时间：2026-10-25 10:00")!
        try check(within7(sourceToday, now: now), "source exact original publication is eligible")
        try check(within7(source("2026-10-19"), now: now), "source seven Shanghai calendar days lower bound inclusive")
        try check(!within7(source("2026-10-18 23:59:59"), now: now), "source before seventh-day midnight excluded")
        try check(!within7(nil, now: now), "unknown source is not eligible even when comments are recent")
        for raw in ["未知", "2026-10-26", "10-25", "10月24日", "编辑于2026-10-25", "更新于2026-10-25", "2026-10-25（编辑）", "修改于昨天", "置顶 2026-10-25", "2026-02-30"] {
            try check(source(raw) == nil, "source unknown/future/edit/inferred year rejected: " + raw)
        }
        try check(source("更新于2026-10-25", iso:"2026-10-25T01:00:00Z") == nil, "explicit ISO cannot rescue an update timestamp")
        try check(source("2026-10-24", iso:"2026-10-25T01:00:00Z") == nil, "source raw date and datetime must agree")
        try check(source("2026-10-25", iso:"2027-01-01T01:00:00Z") == nil, "source future ISO never falls back to plausible label")
        try check(source("2026-10-25", iso:"invalid") == nil, "invalid source datetime never falls back silently")
        try check(source("10-25", iso:"2026-10-25T01:00:00Z")?.quality == "exact", "trusted original datetime supplies missing display year")

        try check(source("昨天", iso:"2026-10-24T04:00:45Z")?.quality == "exact", "calendar yesterday plus trusted same-day datetime is accepted")
        try check(source("今天", iso:"2026-10-25T02:00:45Z")?.quality == "exact", "calendar today plus trusted datetime is accepted")
        try check(source("前天", iso:"2026-10-23T04:00:45Z")?.quality == "exact", "calendar day-before-yesterday plus trusted datetime is accepted")
        try check(source("昨天", iso:"2026-10-25T02:00:45Z") == nil, "calendar-relative source cannot match another day")
        try check(source("2026-10-25 10:00", iso:"2026-10-25T02:00:45Z")?.quality == "exact", "minute display permits trusted datetime seconds within same minute")
        try check(source("2026-10-25 10:00", iso:"2026-10-25T02:01:00Z") == nil, "minute display rejects next-minute datetime")
        try check(source("2026-10-25 10:00", iso:"2026-10-25T01:59:59Z") == nil, "minute display rejects previous-minute datetime")
        try check(source("昨天 10:00", iso:"2026-10-24T02:00:45Z")?.quality == "exact", "calendar-relative minute allows exact seconds")
        try check(source("昨天 10:00", iso:"2026-10-24T02:01:00Z") == nil, "calendar-relative minute rejects next minute")
        try check(source("10-25 10:00", iso:"2026-10-25T02:00:45Z")?.quality == "exact", "trusted datetime disambiguates month-day minute label")
        try check(source("10-25 10:00", iso:"2026-10-25T03:00:45Z") == nil, "month-day label clock must still agree")
        try check(source("2026-10-25 10:00:45", iso:"2026-10-25T02:00:45.900Z")?.quality == "exact", "second display accepts same-second fractional datetime")
        try check(source("2026-10-25 10:00:45", iso:"2026-10-25T02:00:44.900Z") == nil, "second display rejects previous-second fractional datetime")
        try check(source("昨天 10:00:45", iso:"2026-10-24T02:00:46Z") == nil, "calendar-relative second display rejects other second")
        let relativeRegion = source("2小时前 · 广东")!
        try check(relativeRegion.publishedAtISO == source("2小时前")?.publishedAtISO &&
                  relativeRegion.earliestAtISO == source("2小时前")?.earliestAtISO,
                  "source relative date strips only explicit middle-dot region suffix")
        try check(SourcePublicationGate.valid(relativeRegion) && within7(relativeRegion, now: now),
                  "source relative region-suffix evidence survives persistence and gate")
        try check(source("2小时前 • 上海")?.publishedAtISO == relativeRegion.publishedAtISO,
                  "source bullet region delimiter matches comment normalization")
        try check(source("2小时前 IP属地：广东")?.publishedAtISO == relativeRegion.publishedAtISO,
                  "source explicit IP location suffix matches comment normalization")
        let calendarRegion = source("昨天 · 上海", iso:"2026-10-24T04:00:45Z")!
        try check(calendarRegion.quality == "exact" && SourcePublicationGate.valid(calendarRegion),
                  "source calendar-relative label with region permits same-day trusted datetime")
        try check(source("昨天 • IP属地：上海", iso:"2026-10-24T04:00:45Z")?.quality == "exact",
                  "source calendar-relative bullet plus IP suffix stays consistent with datetime")
        try check(source("昨天 IP属地：上海", iso:"2026-10-25T02:00:45Z") == nil,
                  "stripping explicit location cannot hide a conflicting publication day")
        try check(source("发布时间：2小时前 · 广东")?.publishedAtISO == relativeRegion.publishedAtISO,
                  "source publication prefix and explicit suffix normalize together")
        try check(source("2小时前 广东") == nil && source("昨天 上海", iso:"2026-10-24T04:00:45Z") == nil,
                  "source does not guess undelimited trailing location text")
        for suffix in ["编辑", "更新", "修改", "置顶"] {
            try check(source("2小时前 · 广东（" + suffix + "）") == nil,
                      "source inspects entire field before dropping suffix marker: " + suffix)
        }
        try check(source("昨天 · " + String(repeating:"广", count:201), iso:"2026-10-24T04:00:45Z") == nil,
                  "source overlong suffix rejected before date extraction")
        try check(source(String(repeating:" ", count:201) + "昨天") == nil,
                  "source overlong original field rejected before trimming")

        let preciseCalendar = source("昨天", iso:"2026-10-24T04:00:45Z")!
        try check(SourcePublicationGate.valid(preciseCalendar), "calendar-relative display with datetime remains valid after persistence")

        try check(within7(source("昨天"), now: now), "source calendar-relative yesterday is inside seven days")
        try check(within7(source("5天前"), now: now), "safe rounded relative source is inside cutoff")
        try check(!within7(source("6天前"), now: now), "rounded six-day source uncertainty crosses strict cutoff")
        try check(!within7(source("7天前"), now: now), "seven days ago is outside today plus previous six")
        try check(within7(source("6天前", iso:"2026-10-19T02:00:00Z"), now: now), "trusted exact datetime resolves a rounded boundary label")
        let stableSource = source("3天前")!
        try check(!within7(stableSource, now: date("2026-11-05T12:00:00+08:00")), "source relative publication never rejuvenates after observation")
        try check(!within7(sourceToday, now: date("2026-10-25T01:00:00+08:00")), "future source observation rejected")
        let midnight = date("2026-10-25T16:00:00Z") // Shanghai Oct 26 midnight, not UTC midnight.
        try check(!within7(source("2026-10-19"), now: midnight), "source eligibility expires at Shanghai midnight")
        try check(within7(source("2026-10-20"), now: midnight), "new Shanghai seven-day boundary inclusive")
        let forged = SourcePublicationEvidence(raw: stableSource.raw, publishedAtISO: sourceToday.publishedAtISO,
            quality: "relative", checkedAt: stableSource.checkedAt, earliestAtISO: sourceToday.earliestAtISO)
        try check(!SourcePublicationGate.valid(forged), "persisted relative evidence is re-derived, not trusted blindly")
        var sourceRow = sourceToday.rowFields
        try check(SourcePublicationGate.rowEvidence(sourceRow) == sourceToday, "native row evidence round trip")
        sourceRow["sourcePolicy"] = "latest_claim_only"
        try check(SourcePublicationGate.rowEvidence(sourceRow) == nil, "unsupported source policy rejected")
        var sourceComment = fixture("source-test", raw:"今天")
        try check(!CommentRecency.sourceEligible(sourceComment, now: now), "legacy recent comment does not manufacture source evidence")
        sourceComment.sourcePublishedAt = sourceToday.raw; sourceComment.sourcePublishedAtISO = sourceToday.publishedAtISO
        sourceComment.sourcePublishedTimeQuality = sourceToday.quality; sourceComment.sourceCheckedAt = sourceToday.checkedAt
        sourceComment.sourceEarliestAtISO = sourceToday.earliestAtISO; sourceComment.sourcePolicy = SourcePublicationGate.policy
        try check(CommentRecency.sourceEligible(sourceComment, now: now), "source-eligible comment is allowed before demographic filters")
        try check(SourcePublicationGate.displayTime(sourceComment).contains("2026-10-25"), "display uses source publication not comment or collection date")
        let encodedSource = try JSONEncoder().encode(sourceComment)
        let decodedSource = try JSONDecoder().decode(AudioComment.self, from: encodedSource)
        try check(CommentRecency.sourceEligible(decodedSource, now: now), "source evidence survives persisted JSON")
        try check(decoded.sourcePublishedAtISO == nil && !CommentRecency.sourceEligible(decoded, now: now), "legacy JSON source fields stay unknown without deleting record")


        // New source policy: the comment time filter remains independent and unchanged.
        try check(SourcePublicationGate.windows == [7,30,90], "source discovery windows are fixed and ordered")
        let tiers: [(String, Int)] = [("2026-10-25",7),("2026-10-19",7),("2026-10-18",30),
            ("2026-09-26",30),("2026-09-25",90),("2026-07-28",90)]
        for (raw, tier) in tiers {
            try check(SourcePublicationGate.tier(source(raw), now: now) == tier,
                      "source calendar tier includes its lower boundary: " + raw)
            try check(SourcePublicationGate.eligible(source(raw), now: now), "90-day absolute gate retains eligible source: " + raw)
        }
        try check(!SourcePublicationGate.eligible(source("2026-07-27 23:59:59"), now: now), "source before 90th Shanghai day is excluded")
        try check(!SourcePublicationGate.eligible(source("2026-09-25 23:59:59"), now: now, windowDays: 30), "30-day window rejects previous second")
        try check(SourcePublicationGate.tier(source("6天前"), now: now) == 30 &&
                  SourcePublicationGate.tier(source("29天前"), now: now) == 90,
                  "relative boundary uncertainty lowers priority rather than pretending newer precision")
        try check(SourcePublicationGate.tier(source("89天前"), now: now) == nil &&
                  SourcePublicationGate.eligible(source("88天前"), now: now), "90-day rounded uncertainty is conservative")
        for invalidWindow in [-1,0,8,31,91,365] {
            try check(!SourcePublicationGate.eligible(sourceToday, now: now, windowDays: invalidWindow), "unknown discovery window cannot relax maximum")
        }
        try check(SourcePublicationGate.tier(source("2026-07-28"), now: midnight) == nil &&
                  SourcePublicationGate.tier(source("2026-07-29"), now: midnight) == 90,
                  "90-day boundary advances at Shanghai midnight, not UTC midnight")
        try check(SourcePublicationGate.tier(source("1个月前"), now: now) == 90,
                  "rounded month label uses conservative lower bound and is not newest-tier proof")
        try check(SourcePublicationGate.tier(source("3个月前"), now: now) == nil,
                  "rounded three-month label cannot guarantee within 90 days")
        try check(SourcePublicationGate.tier(nil, now: now) == nil &&
                  SourcePublicationGate.tier(source("更新于2026-10-25"), now: now) == nil,
                  "unknown or edit-only source never receives a tier")
        let afterSeven = date("2026-11-05T12:00:00+08:00")
        var legacyPolicyComment = sourceComment
        legacyPolicyComment.sourcePolicy = SourcePublicationGate.legacyPolicy
        try check(SourcePublicationGate.sourceEligible(legacyPolicyComment, now: afterSeven) &&
                  SourcePublicationGate.sourceTier(legacyPolicyComment, now: afterSeven) == 30,
                  "existing valid old-seven-day records remain visible in the wider new source policy")
        var legacyRow = sourceToday.rowFields; legacyRow["sourcePolicy"] = SourcePublicationGate.legacyPolicy
        try check(SourcePublicationGate.rowEvidence(legacyRow) == sourceToday, "legacy-seven-day row evidence remains readable")
        legacyRow = source("2026-09-26")!.rowFields; legacyRow["sourcePolicy"] = SourcePublicationGate.legacyPolicy
        try check(SourcePublicationGate.rowEvidence(legacyRow) == nil, "old policy cannot falsely label originally out-of-seven-day evidence")
        try check(!SourcePublicationGate.eligible(stableSource, now: date("2027-02-01T00:00:00+08:00")),
                  "90-day gate never rejuvenates persisted relative dates")

        print("PASS: \(checks) native Swift recency/demographic checks; fixtures only, no platform/device verification")
    }
}
