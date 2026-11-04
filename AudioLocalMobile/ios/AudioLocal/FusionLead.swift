import Foundation
import CryptoKit

enum FusionStatus: String, CaseIterable, Codable, Identifiable {
    case pending, contacted, interested, closed, ignored
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pending: return "待确认"
        case .contacted: return "已人工联系"
        case .interested: return "已人工确认意向"
        case .closed: return "已结束"
        case .ignored: return "已忽略"
        }
    }
}

struct FusionFollowup: Codable, Equatable {
    var status: FusionStatus = .pending
    var note: String = ""
    var favorite: Bool = false
}

/// A provenance-bearing public comment, not a person or inferred contact profile.
/// Contact details, biographies, avatars and legacy scores are deliberately absent.
struct FusionLead: Codable, Identifiable, Equatable {
    let platform: String
    let sourceURL: String
    let profileURL: String
    let commentID: String
    let text: String
    let authorName: String
    let keyword: String
    let sourceTitle: String
    let publishedAt: String?
    let collectedAt: String
    var region: String? = nil
    var origin: String = "import"
    var sourcePublishedAt: String? = nil

    var id: String {
        let source = FusionLeadLinks.identity(platform: platform, value: sourceURL, profile: false) ?? sourceURL
        let profile = FusionLeadLinks.identity(platform: platform, value: profileURL, profile: true) ?? profileURL
        let fields = commentID.isEmpty ? [platform, source, "fallback", profile, text] : [platform, source, "id", commentID]
        let canonical = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var platformTitle: String { FusionLeadLinks.titles[platform] ?? platform }
    var sourceLink: URL? { FusionLeadLinks.checkedURL(platform: platform, value: sourceURL, profile: false) }
    var profileLink: URL? { FusionLeadLinks.checkedURL(platform: platform, value: profileURL, profile: true) }
    var assessment: LeadAssessment { LeadAssessment.assess(text, product: keyword, sourceTitle: sourceTitle) }
    /// A visible-text question marker, not a claim that the author is a buyer.
    var isQuestion: Bool {
        text.contains("?") || text.contains("？") || ["请问", "多少钱", "怎么", "如何", "能否", "可不可以", "有没有", "哪里买"].contains { text.contains($0) }
    }
    static func from(_ c: AudioComment) -> FusionLead {
        FusionLead(platform: c.platform, sourceURL: c.sourceUrl, profileURL: c.profileUrl,
                   commentID: c.commentId, text: c.text, authorName: c.authorName,
                   keyword: c.product, sourceTitle: c.sourceTitle, publishedAt: c.publishedAtISO,
                   collectedAt: c.collectedAt, region: c.ipLabel ?? c.region, origin: "houmen_local",
                   sourcePublishedAt: c.sourcePublishedAtISO)
    }

    func validated(now: Date = Date()) throws -> FusionLead {
        func bounded(_ value: String, max: Int, required: Bool = false, multiline: Bool = false) -> Bool {
            guard value.count <= max, !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            let forbidden = multiline ? CharacterSet.controlCharacters.subtracting(CharacterSet(charactersIn: "\n\r\t")) : .controlCharacters
            return value.rangeOfCharacter(from: forbidden) == nil
        }
        guard FusionLeadLinks.titles[platform] != nil,
              bounded(sourceURL, max: 1600, required: true), bounded(profileURL, max: 1600),
              sourceLink != nil, profileURL.isEmpty || profileLink != nil,
              !profileURL.isEmpty || !commentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bounded(commentID, max: 128), bounded(text, max: 6000, required: true, multiline: true),
              bounded(authorName, max: 100, required: true), bounded(keyword, max: 100),
              bounded(sourceTitle, max: 500), bounded(origin, max: 40, required: true),
              region.map({ bounded($0, max: 80) }) ?? true else {
            throw LocalFailure.message("线索字段、平台或公开来源链接无效；未导入此批次")
        }
        guard let observed = FusionDates.parse(collectedAt), observed.timeIntervalSince1970 >= 946684800,
              observed <= now.addingTimeInterval(300) else {
            throw LocalFailure.message("采集/导入时间无效；不会用当前时间替换伪造时间")
        }
        for (label, stamp) in [("评论", publishedAt), ("来源", sourcePublishedAt)] {
            if let stamp {
                guard let date = FusionDates.parse(stamp), date.timeIntervalSince1970 >= 946684800,
                      date <= observed.addingTimeInterval(300), date <= now.addingTimeInterval(300) else {
                    throw LocalFailure.message("\(label)发布时间无效；未知时间应留空，不可冒充当前时间")
                }
            }
        }
        return self
    }
}

enum FusionDates {
    static func parse(_ value: String) -> Date? {
        guard value.count <= 64,
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|[+-][0-9]{2}:[0-9]{2})\z"#, options: .regularExpression) != nil else { return nil }
        // ISO8601DateFormatter may normalize invalid calendar dates on some OS versions.
        // Check the literal components first, so 31 February cannot become a real date.
        let bytes = Array(value.utf8)
        func number(_ start: Int, _ length: Int) -> Int {
            Int(String(decoding: bytes[start..<(start + length)], as: UTF8.self)) ?? -1
        }
        let year = number(0, 4), month = number(5, 2), day = number(8, 2)
        let hour = number(11, 2), minute = number(14, 2), second = number(17, 2)
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let literal = calendar.date(from: components) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: literal)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second else { return nil }
        if bytes.last != 90 {
            let zoneHour = number(bytes.count - 5, 2), zoneMinute = number(bytes.count - 2, 2)
            guard zoneHour <= 14, zoneMinute <= 59, zoneHour < 14 || zoneMinute == 0 else { return nil }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

enum FusionLeadLinks {
    static let titles = ["douyin": "抖音", "xiaohongshu": "小红书", "bilibili": "B站", "kuaishou": "快手", "weibo": "微博"]
    static func checkedURL(platform: String, value: String, profile: Bool) -> URL? {
        guard value.utf8.count <= 1600, value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !value.contains("\\"), let c = URLComponents(string: value), c.scheme == "https",
              c.user == nil, c.password == nil, c.port == nil || c.port == 443, c.fragment == nil,
              c.percentEncodedHost?.lowercased() == c.host?.lowercased(), c.percentEncodedPath == c.path else { return nil }
        if platform == "douyin" || platform == "xiaohongshu" {
            let actual = profile ? CollectionPlatform.profilePlatform(value) : CollectionPlatform.sourcePlatform(value)
            return actual?.rawValue == platform ? c.url : nil
        }
        // New platforms accept canonical public paths only. Query/signature material is not imported.
        guard c.percentEncodedQuery == nil, let host = c.host?.lowercased() else { return nil }
        func path(_ pattern: String) -> Bool { c.path.range(of: pattern, options: .regularExpression) != nil }
        let valid: Bool
        switch platform {
        case "bilibili":
            valid = profile ? host == "space.bilibili.com" && path("^/[0-9]{1,20}/?$") :
                ["www.bilibili.com", "bilibili.com", "m.bilibili.com"].contains(host) && path("^/video/(?:BV[0-9A-Za-z]{10}|av[0-9]{1,20})/?$")
        case "kuaishou":
            valid = ["www.kuaishou.com", "kuaishou.com"].contains(host) &&
                path(profile ? "^/profile/[A-Za-z0-9_-]{4,100}/?$" : "^/short-video/[A-Za-z0-9_-]{4,100}/?$")
        case "weibo":
            valid = ["weibo.com", "www.weibo.com", "m.weibo.cn"].contains(host) &&
                path(profile ? "^/u/[0-9]{1,20}/?$" : "^/(?:detail/[0-9]{1,30}|status/[A-Za-z0-9]{5,30}|[0-9]{1,20}/[A-Za-z0-9]{5,30})/?$")
        default: valid = false
        }
        return valid ? c.url : nil
    }
    static func identity(platform: String, value: String, profile: Bool) -> String? {
        guard let url = checkedURL(platform: platform, value: value, profile: profile) else { return nil }
        if platform == "douyin" || platform == "xiaohongshu" {
            return profile ? CollectionPlatform.profileIdentity(value) : CollectionPlatform.sourceIdentity(value)
        }
        var host = url.host!.lowercased()
        if platform == "bilibili" && !profile { host = "www.bilibili.com" }
        if platform == "kuaishou" { host = "www.kuaishou.com" }
        let path = url.path.hasSuffix("/") ? String(url.path.dropLast()) : url.path
        return "https://" + host + path
    }
}
