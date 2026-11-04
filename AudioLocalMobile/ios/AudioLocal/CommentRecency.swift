import Foundation

/// A normalized observation, not a claim that the platform supplied second-level precision.
struct PublicationTime: Equatable {
    let date: Date
    let quality: String
}

enum CommentRecency: String, CaseIterable, Codable, Identifiable {
    case last7Days, last30Days, all
    var id: String { rawValue }
    var title: String {
        switch self { case .last7Days: return "近7天"; case .last30Days: return "近30天"; case .all: return "全部时间" }
    }
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private static func groups(_ pattern: String, _ value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.range.length == (value as NSString).length else { return nil }
        return (1..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : (value as NSString).substring(with: range)
        }
    }
    /// Calendar.date(from:) can normalize impossible dates. Round-trip every requested component.
    private static func strictDate(_ year: Int, _ month: Int, _ day: Int,
                                   _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date? {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        let fields = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: fields) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second else { return nil }
        return date
    }
    /// ISO is accepted only through the explicitly trusted persisted/DOM datetime field.
    static func isoDate(_ raw: String?) -> Date? {
        guard let raw, let p = groups(#"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#, raw),
              let year = Int(p[0]), let month = Int(p[1]), let day = Int(p[2]),
              let hour = Int(p[3]), let minute = Int(p[4]), let second = Int(p[5]),
              strictDate(year, month, day) != nil, (0...23).contains(hour),
              (0...59).contains(minute), (0...59).contains(second) else { return nil }
        if p[7] != "Z" {
            let offset = p[7].dropFirst().split(separator: ":")
            guard offset.count == 2, let hours = Int(offset[0]), let minutes = Int(offset[1]),
                  hours <= 14, minutes <= 59, hours < 14 || minutes == 0 else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = p[6].isEmpty ? [.withInternetDateTime] : [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)
    }
    private static func number(_ text: String) -> Int? {
        if let value = Int(text), value >= 0, value <= 9999 { return value }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        let units: [Character: Int] = ["十":10,"百":100,"千":1000]
        if text.allSatisfy({ digits[$0] != nil }) {
            let value = text.reduce(0) { $0 * 10 + (digits[$1] ?? 0) }
            return value <= 9999 ? value : nil
        }
        var sum = 0, pending: Int?, lastUnit = 10000
        for c in text {
            if let digit = digits[c] { if pending != nil && pending != 0 { return nil }; pending = digit }
            else if let unit = units[c], unit < lastUnit {
                let multiplier = pending ?? 1
                guard multiplier > 0 else { return nil }
                sum += multiplier * unit; pending = nil; lastUnit = unit
            } else { return nil }
        }
        let value = sum + (pending ?? 0)
        return value <= 9999 ? value : nil
    }
    private static func monthsBefore(_ amount: Int, observedAt: Date) -> Date? {
        let c = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second], from: observedAt)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        let total = year * 12 + month - 1 - amount
        guard total >= 12 else { return nil }
        let targetYear = total / 12, targetMonth = total % 12 + 1
        guard let first = strictDate(targetYear, targetMonth, 1),
              let days = calendar.range(of: .day, in: .month, for: first) else { return nil }
        return strictDate(targetYear, targetMonth, min(day, days.count), c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
    static func parse(_ raw: String, observedAt: Date) -> PublicationTime? {
        guard observedAt.timeIntervalSince1970.isFinite else { return nil }
        var value = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200 else { return nil }
        // An edit timestamp is not the original publication timestamp.
        guard !value.contains("编辑") else { return nil }
        value = value.components(separatedBy: CharacterSet(charactersIn: "·•")).first ?? value
        if let location = value.range(of: "IP属地") { value = String(value[..<location.lowerBound]) }
        if value.hasPrefix("发布于") { value = String(value.dropFirst(3)) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        func result(_ date: Date?, _ quality: String) -> PublicationTime? {
            guard let date, date <= observedAt, (1...9999).contains(calendar.component(.year, from: date)) else { return nil }
            return PublicationTime(date: date, quality: quality)
        }
        if value == "刚刚" { return result(observedAt, "relative") }
        if let p = groups(#"^(今天|昨天|前天)(?:\s*(\d{1,2}):(\d{2})(?::(\d{2}))?)?$"#, value) {
            let offset = p[0] == "今天" ? 0 : p[0] == "昨天" ? 1 : 2
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: observedAt)) else { return nil }
            if p[1].isEmpty { return result(day, "relative") }
            let parts = calendar.dateComponents([.year,.month,.day], from: day)
            return result(strictDate(parts.year!, parts.month!, parts.day!, Int(p[1]) ?? -1, Int(p[2]) ?? -1, Int(p[3]) ?? 0), "relative")
        }
        if let p = groups(#"^([0-9零〇一二两三四五六七八九十百千]{1,8})\s*(秒钟|秒|分钟|分|个小时|小时|钟头|天|周|个星期|星期|个月|月|年)前$"#, value), let count = number(p[0]) {
            let date: Date?
            switch p[1] {
            case "秒钟", "秒": date = observedAt.addingTimeInterval(-Double(count))
            case "分钟", "分": date = observedAt.addingTimeInterval(-Double(count) * 60)
            case "个小时", "小时", "钟头": date = observedAt.addingTimeInterval(-Double(count) * 3600)
            case "天": date = calendar.date(byAdding: .day, value: -count, to: observedAt)
            case "周", "个星期", "星期": date = calendar.date(byAdding: .day, value: -count * 7, to: observedAt)
            case "个月", "月": date = monthsBefore(count, observedAt: observedAt)
            default: date = monthsBefore(count * 12, observedAt: observedAt)
            }
            return result(date, "relative")
        }
        let datePattern = #"^(\d{4})[-/.年](\d{1,2})[-/.月](\d{1,2})日?(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$"#
        if let p = groups(datePattern, value), let year = Int(p[0]), let month = Int(p[1]), let day = Int(p[2]) {
            return result(strictDate(year, month, day, Int(p[3]) ?? 0, Int(p[4]) ?? 0, Int(p[5]) ?? 0), p[3].isEmpty ? "day" : "exact")
        }
        if let p = groups(#"^(\d{1,2})[-/.月](\d{1,2})日?(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$"#, value),
           let month = Int(p[0]), let day = Int(p[1]) {
            let year = calendar.component(.year, from: observedAt)
            let observedParts = calendar.dateComponents([.month, .day], from: observedAt)
            // Infer the most recent valid past occurrence. Eight years covers a Gregorian century leap gap.
            // A same-day future clock is invalid, not a reason to silently reinterpret the date as last year.
            for offset in 0...8 {
                if let candidate = strictDate(year - offset, month, day, Int(p[2]) ?? 0, Int(p[3]) ?? 0, Int(p[4]) ?? 0) {
                    if candidate <= observedAt { return result(candidate, "inferredYear") }
                    if offset == 0 && month == observedParts.month && day == observedParts.day { return nil }
                }
            }
            return nil
        }
        return nil
    }
    static func resolved(raw: String, iso: String?, observedAt: Date) -> PublicationTime? {
        if let date = isoDate(iso), date <= observedAt {
            return PublicationTime(date: date, quality: parse(raw, observedAt: observedAt)?.quality ?? "stored")
        }
        return parse(raw, observedAt: observedAt)
    }
    private static func publication(_ comment: AudioComment) -> PublicationTime? {
        let parsed: PublicationTime?
        if let observed = isoDate(comment.collectedAt) {
            parsed = resolved(raw: comment.publishedAt, iso: comment.publishedAtISO, observedAt: observed)
        } else if let stored = isoDate(comment.publishedAtISO) {
            parsed = PublicationTime(date: stored, quality: "stored")
        } else { parsed = nil }
        guard let parsed else { return nil }
        let allowed = ["exact", "day", "relative", "inferredYear", "stored"]
        let quality = comment.publishedTimeQuality.flatMap { allowed.contains($0) ? $0 : nil } ?? parsed.quality
        return PublicationTime(date: parsed.date, quality: quality)
    }
    static func publicationDate(_ comment: AudioComment) -> Date? { publication(comment)?.date }
    static func displayTime(_ comment: AudioComment) -> String {
        guard let time = publication(comment) else { return "时间未知" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = time.quality == "exact" ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        let approximate = ["relative", "inferredYear", "stored"].contains(time.quality)
        return (approximate ? "约 " : "") + formatter.string(from: time.date)
    }
    /// Near N days includes today plus N-1 previous Shanghai calendar days, never future dates.
    static func accepts(_ time: PublicationTime?, range: CommentRecency, now: Date) -> Bool {
        if range == .all { return true }
        guard let time, time.date <= now else { return false }
        let days = range == .last7Days ? 7 : 30
        guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now)) else { return false }
        return time.date >= start
    }
    static func filteredAndSorted(_ comments: [AudioComment], range: CommentRecency, now: Date = Date()) -> [AudioComment] {
        let dated = comments.enumerated().map { index, comment -> (Int, AudioComment, PublicationTime?) in
            let value = publication(comment)
            return (index, comment, value.flatMap { $0.date <= now ? $0 : nil })
        }.filter { accepts($0.2, range: range, now: now) }
        return dated.sorted { lhs, rhs in
            if let a = lhs.2, let b = rhs.2, a.date != b.date { return a.date > b.date }
            if lhs.2 != nil && rhs.2 == nil { return true }
            if lhs.2 == nil && rhs.2 != nil { return false }
            return lhs.0 < rhs.0
        }.map { $0.1 }
    }
    /// Filters explicit saved demographic fields only; no inference from text, photos, names or numbers.
    static func filterDemographics(_ comments: [AudioComment], region: String, minimumAge: Int?, maximumAge: Int?, includeUnknownAge: Bool) -> [AudioComment] {
        if let minimumAge, !(1...120).contains(minimumAge) { return [] }
        if let maximumAge, !(1...120).contains(maximumAge) { return [] }
        if let minimumAge, let maximumAge, minimumAge > maximumAge { return [] }
        func normalize(_ value: String) -> String { value.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let wanted = normalize(region)
        return comments.filter { comment in
            let actual = normalize(comment.region ?? "")
            if !wanted.isEmpty && (actual.isEmpty || !actual.contains(wanted)) { return false }
            guard let age = comment.age, (1...120).contains(age) else { return includeUnknownAge }
            return (minimumAge == nil || age >= minimumAge!) && (maximumAge == nil || age <= maximumAge!)
        }
    }
}


/// Original video/note publication evidence, separate from comment publication and observation.
/// The DOM adapter must only supply a field explicitly belonging to the source's publication UI.
struct SourcePublicationEvidence: Codable, Equatable {
    let raw: String
    let publishedAtISO: String
    let quality: String
    let checkedAt: String
    let earliestAtISO: String

    var rowFields: [String: Any] {
        ["sourcePublishedAt": raw, "sourcePublishedAtISO": publishedAtISO,
         "sourcePublishedTimeQuality": quality, "sourceCheckedAt": checkedAt,
         "sourceEarliestAtISO": earliestAtISO, "sourcePolicy": SourcePublicationGate.policy]
    }
}

enum SourcePublicationGate {
    static let policy = "published_tiered_7_30_90_latest"
    static let legacyPolicy = "published_last7_latest"
    static let windows = [7, 30, 90]
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func clean(_ raw: String) -> String? {
        guard raw.count <= 200 else { return nil }
        var value = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        // Inspect the WHOLE field first: a trailing edit/update marker must not disappear with a region suffix.
        guard value.count <= 200, !value.contains("编辑"), !value.contains("更新"), !value.contains("修改"),
              !value.contains("置顶"), value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        value = value.components(separatedBy: CharacterSet(charactersIn: "·•")).first ?? value
        if let location = value.range(of: "IP属地") { value = String(value[..<location.lowerBound]) }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["发布时间：", "发布时间:", "发布时间", "发布于", "发布：", "发布:"] {
            if value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines); break }
        }
        return value
    }
    /// Earliest plausible instant for a rounded relative label. Uncertainty may move a
    /// source into an older tier; it must never promote an old source into the newest tier.
    private static func earliest(_ parsed: PublicationTime, raw: String) -> Date? {
        guard parsed.quality == "relative" else { return parsed.date }
        if raw.hasPrefix("今天") || raw.hasPrefix("昨天") || raw.hasPrefix("前天") { return parsed.date }
        if raw == "刚刚" { return parsed.date.addingTimeInterval(-60) }
        let seconds: TimeInterval
        if raw.hasSuffix("秒前") || raw.hasSuffix("秒钟前") { seconds = 1 }
        else if raw.hasSuffix("分钟前") || raw.hasSuffix("分前") { seconds = 60 }
        else if raw.hasSuffix("小时前") || raw.hasSuffix("钟头前") { seconds = 3600 }
        else if raw.hasSuffix("天前") { seconds = 86400 }
        else if raw.hasSuffix("周前") || raw.hasSuffix("星期前") { seconds = 7 * 86400 }
        else if raw.hasSuffix("个月前") || raw.hasSuffix("月前") {
            // A displayed N months ago may be almost N+1 calendar months old.
            // Subtracting from the clamped parsed date is conservative at month ends.
            return calendar.date(byAdding: .month, value: -1, to: parsed.date)
        }
        else { return nil } // Year-scale labels cannot establish the maximum 90-day window.
        return parsed.date.addingTimeInterval(-seconds)
    }
    /// Unknown, future, edit/update-only and year-inferred dates cannot establish source eligibility.
    /// A visible trusted original-publication datetime can disambiguate an abbreviated display label.
    static func evidence(raw: String, iso: String? = nil, observedAt: Date) -> SourcePublicationEvidence? {
        guard observedAt.timeIntervalSince1970.isFinite, let cleaned = clean(raw),
              let anchor = CommentRecency.isoDate(stamp(observedAt)) else { return nil }
        let parsed = cleaned.isEmpty ? nil : CommentRecency.parse(cleaned, observedAt: anchor)
        let normalizedISO = iso?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !normalizedISO.isEmpty {
            guard normalizedISO.count <= 80, let date = CommentRecency.isoDate(normalizedISO), date <= anchor else { return nil }
            if !cleaned.isEmpty {
                guard let parsed else { return nil }
                let hasClock = cleaned.range(of: #"\d{1,2}:\d{2}(?::\d{2})?$"#, options: .regularExpression) != nil
                let hasSeconds = cleaned.range(of: #"\d{1,2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil
                let calendarRelative = cleaned.range(of: #"^(今天|昨天|前天)(?:\s*\d{1,2}:\d{2}(?::\d{2})?)?$"#,
                                                     options: .regularExpression) != nil
                if calendarRelative && !hasClock {
                    // 'Yesterday' describes the whole Shanghai calendar day, not only midnight.
                    guard calendar.isDate(parsed.date, inSameDayAs: date) else { return nil }
                } else if parsed.quality == "exact" || (calendarRelative && hasClock) {
                    // A HH:mm display need not include the seconds supplied by its own datetime.
                    let width: TimeInterval = hasSeconds ? 1 : 60
                    guard date >= parsed.date, date < parsed.date.addingTimeInterval(width) else { return nil }
                } else if parsed.quality == "relative" {
                    guard let lower = earliest(parsed, raw: cleaned), date >= lower, date <= parsed.date else { return nil }
                } else if hasClock {
                    // Month-day clock labels still require the same date/year given by trusted ISO.
                    let width: TimeInterval = hasSeconds ? 1 : 60
                    guard date >= parsed.date, date < parsed.date.addingTimeInterval(width) else { return nil }
                } else {
                    guard calendar.isDate(parsed.date, inSameDayAs: date) else { return nil }
                }
            }
            return SourcePublicationEvidence(raw: raw, publishedAtISO: stamp(date), quality: "exact",
                                             checkedAt: stamp(anchor), earliestAtISO: stamp(date))
        }
        guard let parsed, ["exact", "day", "relative"].contains(parsed.quality), let lower = earliest(parsed, raw: cleaned) else { return nil }
        return SourcePublicationEvidence(raw: raw, publishedAtISO: stamp(parsed.date), quality: parsed.quality,
                                         checkedAt: stamp(anchor), earliestAtISO: stamp(lower))
    }
    /// Persisted evidence is checked structurally and re-derived using its ORIGINAL observation,
    /// never reinterpreted relative to today's clock. This permits old checkpoints to be inspected.
    static func valid(_ evidence: SourcePublicationEvidence) -> Bool {
        guard evidence.raw.count <= 200, evidence.publishedAtISO.count <= 80,
              evidence.checkedAt.count <= 80, evidence.earliestAtISO.count <= 80,
              ["exact", "day", "relative"].contains(evidence.quality),
              let checked = CommentRecency.isoDate(evidence.checkedAt),
              let rebuilt = self.evidence(raw: evidence.raw,
                    iso: evidence.quality == "exact" ? evidence.publishedAtISO : nil, observedAt: checked) else { return false }
        return rebuilt == evidence
    }
    /// Today plus N-1 Shanghai calendar days. The absolute save/view limit is 90 days;
    /// discovery requests 7, then 30, then 90 only when the preceding tier is insufficient.
    static func eligible(_ evidence: SourcePublicationEvidence?, now: Date = Date(), windowDays: Int = 90) -> Bool {
        guard windows.contains(windowDays), now.timeIntervalSince1970.isFinite, let evidence, valid(evidence),
              let checked = CommentRecency.isoDate(evidence.checkedAt), checked <= now,
              let date = CommentRecency.isoDate(evidence.publishedAtISO), date <= now,
              let lower = CommentRecency.isoDate(evidence.earliestAtISO), lower <= date,
              let cutoff = calendar.date(byAdding: .day, value: -(windowDays - 1), to: calendar.startOfDay(for: now)) else { return false }
        return lower >= cutoff
    }
    /// The most recent tier the source can prove, not an estimate from its newest comment.
    static func tier(_ evidence: SourcePublicationEvidence?, now: Date = Date()) -> Int? {
        windows.first { eligible(evidence, now: now, windowDays: $0) }
    }
    private static func compatible(_ evidence: SourcePublicationEvidence, policy storedPolicy: String?) -> Bool {
        guard valid(evidence) else { return false }
        if storedPolicy == policy { return true }
        guard storedPolicy == legacyPolicy, let checked = CommentRecency.isoDate(evidence.checkedAt) else { return false }
        return eligible(evidence, now: checked, windowDays: 7)
    }
    static func rowEvidence(_ row: [String: Any]) -> SourcePublicationEvidence? {
        guard let storedPolicy = row["sourcePolicy"] as? String, [policy, legacyPolicy].contains(storedPolicy),
              let raw = row["sourcePublishedAt"] as? String, let iso = row["sourcePublishedAtISO"] as? String,
              let quality = row["sourcePublishedTimeQuality"] as? String,
              let checked = row["sourceCheckedAt"] as? String, let earliest = row["sourceEarliestAtISO"] as? String else { return nil }
        let value = SourcePublicationEvidence(raw: raw, publishedAtISO: iso, quality: quality, checkedAt: checked, earliestAtISO: earliest)
        return compatible(value, policy: storedPolicy) ? value : nil
    }
    static func publication(_ comment: AudioComment) -> SourcePublicationEvidence? {
        guard [policy, legacyPolicy].contains(comment.sourcePolicy ?? ""), let raw = comment.sourcePublishedAt,
              let iso = comment.sourcePublishedAtISO, let quality = comment.sourcePublishedTimeQuality,
              let checked = comment.sourceCheckedAt, let earliest = comment.sourceEarliestAtISO else { return nil }
        let value = SourcePublicationEvidence(raw: raw, publishedAtISO: iso, quality: quality, checkedAt: checked, earliestAtISO: earliest)
        return compatible(value, policy: comment.sourcePolicy) ? value : nil
    }
    static func sourceTier(_ comment: AudioComment, now: Date = Date()) -> Int? {
        guard CollectionPlatform.sourcePlatform(comment.sourceUrl)?.rawValue == comment.platform else { return nil }
        return tier(publication(comment), now: now)
    }
    static func sourceEligible(_ comment: AudioComment, now: Date = Date()) -> Bool {
        guard CollectionPlatform.sourcePlatform(comment.sourceUrl)?.rawValue == comment.platform else { return false }
        return eligible(publication(comment), now: now)
    }
    static func displayTime(_ comment: AudioComment) -> String {
        guard let evidence = publication(comment), let date = CommentRecency.isoDate(evidence.publishedAtISO) else { return "来源发布时间未知" }
        let format = DateFormatter(); format.calendar = calendar; format.timeZone = calendar.timeZone
        format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = evidence.quality == "exact" ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
        return (evidence.quality == "relative" ? "约 " : "") + format.string(from: date)
    }
}

extension CommentRecency {
    static func sourceEligible(_ comment: AudioComment, now: Date = Date()) -> Bool {
        SourcePublicationGate.sourceEligible(comment, now: now)
    }
}
