import Foundation
import CoreFoundation
import CryptoKit
import Combine

struct AudioComment: Codable, Identifiable {
    let id: String
    let commentId: String
    let platform: String
    let product: String
    let text: String
    let authorName: String
    let authorId: String
    let profileUrl: String
    let publishedAt: String
    let sourceUrl: String
    let sourceTitle: String
    let collectedAt: String
    var saved: Bool
    var note: String
    var industry: String? = nil
    var publishedAtISO: String? = nil
    var publishedTimeQuality: String? = nil
    var sourcePublishedAt: String? = nil
    var sourcePublishedAtISO: String? = nil
    var sourcePublishedTimeQuality: String? = nil
    var sourceCheckedAt: String? = nil
    var sourceEarliestAtISO: String? = nil
    var sourcePolicy: String? = nil
    var region: String? = nil
    var regionSource: String? = nil
    var age: Int? = nil
    var demographicSource: String? = nil
    var profileVerifiedAt: String? = nil
    // Explicit public protocol metadata only; missing fields keep old stores decodable.
    var publicHandle: String? = nil
    var parentCommentId: String? = nil
    var isReply: Bool? = nil
    var ipLabel: String? = nil
    var likeCount: Int? = nil
    var replyCount: Int? = nil
    var acquisition: String? = nil
}

enum LocalFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

@MainActor
final class CommentStore: ObservableObject {
    @Published private(set) var comments: [AudioComment] = []
    @Published private(set) var loadError: String?
    private let file: URL

    init(directory: URL? = nil) {
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = directory ?? parent.appendingPathComponent("ShengxunLocal", isDirectory: true)
        file = folder.appendingPathComponent("comments.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            if FileManager.default.fileExists(atPath: file.path) {
                comments = try JSONDecoder().decode([AudioComment].self, from: Data(contentsOf: file))
            }
        } catch { loadError = "本机数据读取失败，未覆盖旧数据：\(error.localizedDescription)" }
    }

    static func validLink(_ value: String, profile: Bool) -> Bool {
        profile ? CollectionPlatform.profilePlatform(value) != nil : CollectionPlatform.sourcePlatform(value) != nil
    }

    private static func publicCount(_ raw: Any?) -> Int? {
        if let text = raw as? String {
            guard !text.isEmpty, text.count <= 16,
                  text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text),
                  value >= 0, value <= 9_007_199_254_740_991 else { return nil }
            return value
        }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value >= 0, value <= 9_007_199_254_740_991,
              value.rounded(.towardZero) == value else { return nil }
        return Int(value)
    }

    private func commit(_ next: [AudioComment]) throws {
        if let error = loadError { throw LocalFailure.message(error) }
        let data = try JSONEncoder().encode(next)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: [.atomic])
        #endif
        comments = next
    }

    @discardableResult
    func save(_ rows: [[String: Any]], requireRecentSource: Bool = false, now: Date = Date()) throws -> Int {
        guard rows.count <= 250 else { throw LocalFailure.message("单批评论超过250条，请分批保存；没有截断数据") }
        var next = comments
        var added = 0
        for raw in rows {
            func value(_ key: String, _ max: Int = 200) -> String {
                String((raw[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
            }
            let source = value("sourceUrl", 1600), profile = value("profileUrl", 500)
            let content = value("text", 6000), name = value("authorName", 100), commentID = value("commentId", 100)
            guard Self.validLink(source, profile: false), Self.validLink(profile, profile: true),
                  let actualPlatform = CollectionPlatform.sourcePlatform(source),
                  CollectionPlatform.profilePlatform(profile) == actualPlatform,
                  value("platform").isEmpty || value("platform") == actualPlatform.rawValue,
                  !content.isEmpty, !name.isEmpty else { throw LocalFailure.message("评论或来源字段无效，未保存此批次") }
            let fields = CommentIdentity.fields(sourceURL: source, profileURL: profile, commentID: commentID, text: content)
            let identity = try JSONSerialization.data(withJSONObject: fields)
            // Old releases hashed raw URL/concatenated fields. Match their stored semantic tuple
            // and retain their id/user edits instead of appending a second copy after an upgrade.
            let oldIndex = next.firstIndex {
                $0.platform == actualPlatform.rawValue &&
                    CommentIdentity.fields(sourceURL: $0.sourceUrl, profileURL: $0.profileUrl,
                                           commentID: $0.commentId, text: $0.text) == fields
            }
            let old = oldIndex.map { next[$0] }
            let id = old?.id ?? SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
            let incomingSource = SourcePublicationGate.rowEvidence(raw)
            if requireRecentSource && !SourcePublicationGate.eligible(incomingSource, now: now) {
                throw LocalFailure.message("原视频发布时间未知、不在90天内或证据无效，未保存此批次")
            }
            // Repeated observations of one source must never rejuvenate its original publication.
            let sourceKey = CollectionPlatform.sourceIdentity(source)
            let earlierSource = next.filter { CollectionPlatform.sourceIdentity($0.sourceUrl) == sourceKey }
                .compactMap(SourcePublicationGate.publication).min { $0.publishedAtISO < $1.publishedAtISO }
            let sourceEvidence: SourcePublicationEvidence?
            if let previous = earlierSource, let incoming = incomingSource {
                sourceEvidence = previous.publishedAtISO <= incoming.publishedAtISO ? previous : incoming
            } else { sourceEvidence = earlierSource ?? incomingSource }
            if requireRecentSource && !SourcePublicationGate.eligible(sourceEvidence, now: now) {
                throw LocalFailure.message("原视频已有更早发布时间；不会以重新采集时间恢复为90天内")
            }
            let oldObservation = old.flatMap { ISO8601DateFormatter().date(from: $0.collectedAt) }
            // Resolve legacy relative labels at their ORIGINAL observation, never at a new crawl.
            let oldTime = old.flatMap { item -> PublicationTime? in
                guard let date = CommentRecency.publicationDate(item), date <= now else { return nil }
                let quality = item.publishedTimeQuality ?? oldObservation.flatMap {
                    CommentRecency.parse(item.publishedAt, observedAt: $0)?.quality
                } ?? "stored"
                return PublicationTime(date: date, quality: quality)
            }
            let newTime = CommentRecency.resolved(raw: value("publishedAt"), iso: value("publishedAtISO", 80), observedAt: now)
            let time = oldTime ?? newTime
            var record = AudioComment(id: id, commentId: commentID, platform: actualPlatform.rawValue, product: value("product", 60),
                text: content, authorName: name, authorId: value("authorId"), profileUrl: profile,
                publishedAt: oldTime != nil ? (old?.publishedAt ?? value("publishedAt")) : value("publishedAt"), sourceUrl: source, sourceTitle: value("sourceTitle", 300),
                collectedAt: oldTime != nil ? (old?.collectedAt ?? ISO8601DateFormatter().string(from: now)) : ISO8601DateFormatter().string(from: now), saved: old?.saved ?? false, note: old?.note ?? "")
            let handle = value("publicHandle", 100), parentID = value("parentCommentId", 100)
            record.publicHandle = handle.isEmpty ? old?.publicHandle : handle
            record.parentCommentId = parentID.isEmpty ? old?.parentCommentId : parentID
            record.isReply = record.parentCommentId != nil ? true : (raw["isReply"] as? Bool ?? old?.isReply)
            record.ipLabel = Self.publicIPRegion(value("ipLabel", 80)) ?? old?.ipLabel
            record.likeCount = Self.publicCount(raw["likeCount"]) ?? old?.likeCount
            record.replyCount = Self.publicCount(raw["replyCount"]) ?? old?.replyCount
            let acquisition = value("acquisition", 40)
            record.acquisition = ["local_protocol_response", "protocol_capture", "public_dom", "browser_node"].contains(acquisition) ? acquisition : old?.acquisition
            let commentRegion = record.ipLabel ?? (old?.regionSource == "comment_ip" ? old?.region : nil)
                ?? Self.commentIPRegion(value("publishedAt"))
            record.publishedAtISO = time.map { ISO8601DateFormatter().string(from: $0.date) }
            let protocolExact = acquisition == "local_protocol_response" && value("publishedTimeQuality") == "exact" &&
                time != nil && CommentRecency.isoDate(value("publishedAtISO", 80)) == time?.date
            record.publishedTimeQuality = old?.publishedTimeQuality ?? (protocolExact ? "exact" : time?.quality)
            record.sourcePublishedAt = sourceEvidence?.raw
            record.sourcePublishedAtISO = sourceEvidence?.publishedAtISO
            record.sourcePublishedTimeQuality = sourceEvidence?.quality
            record.sourceCheckedAt = sourceEvidence?.checkedAt
            record.sourceEarliestAtISO = sourceEvidence?.earliestAtISO
            record.sourcePolicy = sourceEvidence == nil ? nil : SourcePublicationGate.policy
            record.industry = IndustryProfile(rawValue: value("industry", 30))?.rawValue ?? old?.industry ?? IndustryProfile.general.rawValue
            let profileKey = LeadGrouping.profileKey(platform: actualPlatform.rawValue, profileURL: profile, fallbackID: id)
            // A new comment from the SAME public profile inherits the latest verified fields, including clears.
            // Never copy another comment's IP location, and never merge by nickname.
            let verified = next.filter {
                LeadGrouping.key(for: $0) == profileKey && $0.profileVerifiedAt != nil
            }.max { ($0.profileVerifiedAt ?? "") < ($1.profileVerifiedAt ?? "") }
            if let verified {
                record.region = verified.regionSource == "manual_public_profile" ? verified.region :
                    commentRegion
                record.regionSource = verified.regionSource == "manual_public_profile" ? "manual_public_profile" :
                    (record.region == nil ? nil : "comment_ip")
                record.age = verified.age
                record.demographicSource = verified.demographicSource
                record.profileVerifiedAt = verified.profileVerifiedAt
            } else {
                record.region = old?.regionSource == "manual_public_profile" ? old?.region : commentRegion
                record.regionSource = old?.regionSource ?? (record.region == nil ? nil : "comment_ip")
                record.age = old?.age; record.demographicSource = old?.demographicSource
                record.profileVerifiedAt = old?.profileVerifiedAt
            }
            // A newly established EARLIER original date corrects all saved comments on that exact source.
            // Without this, another comment could retain a newer estimate and outlive the source gate.
            if let sourceEvidence {
                for index in next.indices where CollectionPlatform.sourceIdentity(next[index].sourceUrl) == sourceKey {
                    next[index].sourcePublishedAt = sourceEvidence.raw
                    next[index].sourcePublishedAtISO = sourceEvidence.publishedAtISO
                    next[index].sourcePublishedTimeQuality = sourceEvidence.quality
                    next[index].sourceCheckedAt = sourceEvidence.checkedAt
                    next[index].sourceEarliestAtISO = sourceEvidence.earliestAtISO
                    next[index].sourcePolicy = SourcePublicationGate.policy
                }
            }
            if let index = oldIndex { next[index] = record } else { next.append(record); added += 1 }
        }
        guard next.count <= 2000 else { throw LocalFailure.message("本机已达2000条上限，请先导出和整理；没有丢弃旧数据") }
        try commit(next)
        return added
    }

    func preference(id: String, saved: Bool? = nil, note: String? = nil) throws {
        guard let index = comments.firstIndex(where: { $0.id == id }) else { return }
        var next = comments
        if let saved { next[index].saved = saved }
        if let note { next[index].note = String(note.prefix(1000)) }
        try commit(next)
    }

    /// Only a location explicitly displayed beside comment time, never inferred from comment text.
    static func commentIPRegion(_ raw: String) -> String? {
        let parts = raw.components(separatedBy: CharacterSet(charactersIn: "·•"))
        guard parts.count == 2 else { return nil }
        return publicIPRegion(parts[1])
    }

    /// Explicit platform IP label is a province-level observation, never a residence inference.
    static func publicIPRegion(_ raw: String) -> String? {
        let provinces = ["北京","天津","上海","重庆","河北","山西","辽宁","吉林","黑龙江","江苏","浙江","安徽",
                         "福建","江西","山东","河南","湖北","湖南","广东","海南","四川","贵州","云南","陕西",
                         "甘肃","青海","内蒙古","广西","西藏","宁夏","新疆","香港","澳门","台湾"]
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["IP属地：", "IP属地:"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        return provinces.contains(value) ? value : nil
    }

    /// User-verified PUBLIC profile fields only. Never infer these from an avatar or comment.
    func publicProfile(id: String, region: String, age: Int?) throws {
        let value = region.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 40, age == nil || (1...120).contains(age!) else {
            throw LocalFailure.message("地区最多40字；年龄请填写1至120或留空")
        }
        guard let person = comments.first(where: { $0.id == id }) else { return }
        guard Self.validLink(person.profileUrl, profile: true) else { throw LocalFailure.message("用户主页无效，未更新资料") }
        let canonical = URLComponents(string: person.profileUrl).map { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        var next = comments
        for index in next.indices {
            let address = URLComponents(string: next[index].profileUrl).map { $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            guard next[index].platform == person.platform, address == canonical else { continue }
            next[index].region = value.isEmpty ? (next[index].ipLabel.flatMap(Self.publicIPRegion) ?? Self.commentIPRegion(next[index].publishedAt)) : value
            next[index].regionSource = value.isEmpty ? (next[index].region == nil ? nil : "comment_ip") : "manual_public_profile"
            next[index].age = age
            next[index].demographicSource = (age != nil || !value.isEmpty) ? "manual_public_profile" : nil
            next[index].profileVerifiedAt = ISO8601DateFormatter().string(from: Date())
        }
        try commit(next)
    }

    static func csvCell(_ raw: String) -> String {
        let startsFormula = raw.range(of: "^\\s*[=+@-]", options: .regularExpression) != nil
        let value = (startsFormula ? "'" : "") + raw
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    @discardableResult
    func remove(ids: Set<String>) throws -> Int {
        let next = comments.filter { !ids.contains($0.id) }
        let removed = comments.count - next.count
        if removed > 0 { try commit(next) }
        return removed
    }

    func csv() -> String { csv(records: comments) }

    /// An export is a snapshot of the selected comments, never an invented contact list.
    func csv(records: [AudioComment]) -> String {
        let header = ["平台", "行业", "采集关键词", "昵称", "公开账号标识", "用户主页", "评论", "规则标签（待人工确认）",
                      "命中依据", "确认状态", "平台时间", "规范化发布时间", "时间精度", "地区", "地区来源", "公开年龄", "资料来源", "资料核实时间", "原视频标题", "原视频", "原视频发布时间", "原视频时间精度", "原视频核验时间", "来源策略", "采集时间", "收藏", "备注", "公开号", "父评论标识", "是否回复", "评论IP属地（非居住地）", "点赞数", "回复数", "采集方式"]
        let rows = records.map { c -> [String] in
            let assessment = c.assessment
            return [(CollectionPlatform(rawValue: c.platform)?.title ?? c.platform), (c.industry.flatMap(IndustryProfile.init(rawValue:)) ?? .general).title, c.product, c.authorName, c.authorId,
                    c.profileUrl, c.text, assessment.labels, assessment.explanation,
                    assessment.hasClue ? "待人工确认" : "未命中规则，不代表没有需求",
                    c.publishedAt, c.publishedAtISO ?? "", c.publishedTimeQuality ?? "",
                    c.region ?? "", c.regionSource == "comment_ip" ? "评论IP属地（非居住地）" : (c.regionSource == nil ? "" : "人工核实主页公开"),
                    c.age.map(String.init) ?? "", c.demographicSource == nil ? "" : "人工核实主页公开",
                    c.profileVerifiedAt ?? "", c.sourceTitle, c.sourceUrl, c.sourcePublishedAtISO ?? "", c.sourcePublishedTimeQuality ?? "", c.sourceCheckedAt ?? "", c.sourcePolicy ?? "", c.collectedAt, c.saved ? "是" : "否", c.note,
                    c.publicHandle ?? "", c.parentCommentId ?? "", c.isReply.map { $0 ? "是" : "否" } ?? "",
                    c.ipLabel ?? "", c.likeCount.map { String($0) } ?? "", c.replyCount.map { String($0) } ?? "", c.acquisition ?? ""]
        }
        return "\u{feff}" + ([header] + rows).map { $0.map(Self.csvCell).joined(separator: ",") }.joined(separator: "\r\n")
    }
}
