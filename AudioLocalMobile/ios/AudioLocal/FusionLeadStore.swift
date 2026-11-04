import Foundation
import CoreFoundation
import Combine

private struct FusionEnvelope: Codable {
    var format = "houmen-fusion"
    var version = 1
    var records: [FusionLead]
    var followups: [String: FusionFollowup]
}

/// Separate, atomic storage. This type never opens or writes comments.json.
@MainActor
final class FusionLeadStore: ObservableObject {
    static let maximumImportBytes = 5 * 1024 * 1024
    static let maximumRecords = 5000
    @Published private(set) var records: [FusionLead] = []
    @Published private(set) var followups: [String: FusionFollowup] = [:]
    @Published private(set) var loadError: String?
    @Published private(set) var lastImportWarnings: [String] = []
    private var projectedDefaults: [String: FusionFollowup] = [:]
    private let file: URL

    init(directory: URL? = nil) {
        let parent = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = directory ?? parent.appendingPathComponent("ShengxunLocal", isDirectory: true)
        file = folder.appendingPathComponent("fusion-leads-v1.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var flags = URLResourceValues(); flags.isExcludedFromBackup = true
            try folder.setResourceValues(flags)
            if FileManager.default.fileExists(atPath: file.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumImportBytes else {
                    throw LocalFailure.message("融合库超过文件大小限制")
                }
                let data = try Data(contentsOf: file)
                guard data.count <= Self.maximumImportBytes else { throw LocalFailure.message("融合库超过文件大小限制") }
                let envelope = try JSONDecoder().decode(FusionEnvelope.self, from: data)
                try Self.checkEnvelope(envelope)
                records = envelope.records; followups = envelope.followups
            }
        } catch { loadError = "融合数据读取失败，保留原文件并禁止覆盖：\(error.localizedDescription)" }
    }

    func allLeads(comments: [AudioComment]) -> [FusionLead] {
        var byID: [String: FusionLead] = [:]
        var defaults: [String: FusionFollowup] = [:]
        for comment in comments {
            let lead = FusionLead.from(comment)
            byID[lead.id] = lead
            defaults[lead.id] = FusionFollowup(status: .pending, note: comment.note, favorite: comment.saved)
        }
        // Original Houmen observations take precedence without copying or overwriting their file.
        for lead in records where byID[lead.id] == nil { byID[lead.id] = lead }
        projectedDefaults = defaults
        struct Entry { let id: String; let lead: FusionLead; let date: Date }
        var entries: [Entry] = []
        entries.reserveCapacity(byID.count)
        for (id, lead) in byID {
            let parsed: Date = FusionDates.parse(lead.collectedAt) ?? Date.distantPast
            entries.append(Entry(id: id, lead: lead, date: parsed))
        }
        let sorted = entries.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id < rhs.id }
            return lhs.date > rhs.date
        }
        return sorted.map { $0.lead }
    }

    func followup(for lead: FusionLead) -> FusionFollowup {
        followups[lead.id] ?? projectedDefaults[lead.id] ?? FusionFollowup()
    }

    private static func checkEnvelope(_ value: FusionEnvelope) throws {
        guard value.format == "houmen-fusion", value.version == 1,
              value.records.count <= maximumRecords, value.followups.count <= maximumRecords * 2,
              Set(value.records.map(\.id)).count == value.records.count else {
            throw LocalFailure.message("不支持的融合格式、重复记录或记录数超限")
        }
        for lead in value.records { _ = try lead.validated() }
        for (id, state) in value.followups {
            guard id.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil,
                  state.note.count <= 1000, !state.note.contains("\0") else {
                throw LocalFailure.message("跟进记录字段无效")
            }
        }
    }

    private func commit(records next: [FusionLead], followups states: [String: FusionFollowup]) throws {
        if let loadError { throw LocalFailure.message(loadError) }
        let value = FusionEnvelope(records: next, followups: states)
        try Self.checkEnvelope(value)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumImportBytes else { throw LocalFailure.message("融合库容量已满，请先导出整理；没有删除旧数据") }
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        records = next; followups = states
    }

    @discardableResult
    func add(_ rows: [FusionLead]) throws -> Int {
        guard rows.count <= Self.maximumRecords else { throw LocalFailure.message("单批线索超过5000条；未截断数据") }
        var next = records
        var indexes = Dictionary(uniqueKeysWithValues: next.enumerated().map { ($0.element.id, $0.offset) })
        var added = 0
        for raw in rows {
            let lead = try raw.validated()
            if let index = indexes[lead.id] {
                // Never rejuvenate a publication timestamp or lose provenance on a repeated import.
                if next[index].publishedAt == nil && lead.publishedAt != nil { next[index] = lead }
            } else {
                indexes[lead.id] = next.count; next.append(lead); added += 1
            }
        }
        try commit(records: next, followups: followups)
        return added
    }

    func update(id: String, status: FusionStatus, note: String) throws {
        guard id.range(of: "^[a-f0-9]{64}\\z", options: .regularExpression) != nil,
              note.count <= 1000, !note.contains("\0") else { throw LocalFailure.message("跟进备注最多1000字，标识必须有效") }
        var states = followups
        let old = states[id] ?? projectedDefaults[id] ?? FusionFollowup()
        states[id] = FusionFollowup(status: status, note: note, favorite: old.favorite)
        try commit(records: records, followups: states)
    }

    /// Only removes independent Fusion records. Original Houmen comments remain untouched.
    @discardableResult
    func remove(ids: Set<String>) throws -> Int {
        let removedIDs = Set(records.filter { ids.contains($0.id) }.map(\.id))
        guard !removedIDs.isEmpty else { return 0 }
        var states = followups
        for id in removedIDs where projectedDefaults[id] == nil { states.removeValue(forKey: id) }
        try commit(records: records.filter { !removedIDs.contains($0.id) }, followups: states)
        return removedIDs.count
    }

    @discardableResult
    func importJSON(data: Data, comments: [AudioComment]? = nil) throws -> Int {
        // The caller can supply the current read-only projection before the first UI render.
        if let comments { _ = allLeads(comments: comments) }
        guard data.count <= Self.maximumImportBytes else { throw LocalFailure.message("JSON不得超过5 MiB") }
        let raw = try JSONSerialization.jsonObject(with: data)
        var importedStates: [String: FusionFollowup] = [:]
        var warnings: [String] = []
        let incoming: [FusionLead]
        if let object = raw as? [String: Any], object["format"] as? String == "houmen-fusion" {
            let envelope = try JSONDecoder().decode(FusionEnvelope.self, from: data)
            try Self.checkEnvelope(envelope)
            let ids = Set(envelope.records.map(\.id))
            guard Set(envelope.followups.keys).isSubset(of: ids) else { throw LocalFailure.message("导入跟进状态引用了文件外的线索") }
            incoming = envelope.records; importedStates = envelope.followups
        } else if let array = raw as? [[String: Any]] {
            guard array.count <= Self.maximumRecords else { throw LocalFailure.message("JSON线索超过5000条") }
            let now = Date()
            incoming = try array.enumerated().map { index, row in
                do { return try Self.legacy(row, now: now, warnings: &warnings) }
                catch { throw LocalFailure.message("第\(index + 1)条：\(error.localizedDescription)") }
            }
        } else { throw LocalFailure.message("需要LeadRadar线索JSON数组或后门融合版JSON；未读取其他格式") }
        // Validate and construct the whole transaction before one atomic write.
        var next = records
        var ids = Set(next.map(\.id)); var added = 0
        for item in incoming {
            let lead = try item.validated()
            if ids.insert(lead.id).inserted { next.append(lead); added += 1 }
        }
        var states = followups
        for (id, imported) in importedStates where states[id] == nil {
            var state = imported
            if let original = projectedDefaults[id] {
                // Restoring a Fusion backup must not silently clear pre-existing Houmen edits.
                if !original.note.isEmpty { state.note = original.note }
                state.favorite = state.favorite || original.favorite
            }
            states[id] = state
        }
        try commit(records: next, followups: states)
        lastImportWarnings = Array(Set(warnings)).sorted()
        return added
    }

    private static func legacy(_ row: [String: Any], now: Date, warnings: inout [String]) throws -> FusionLead {
        func str(_ key: String) -> String { row[key] as? String ?? "" }
        let aliases = ["B站": "bilibili", "b站": "bilibili", "抖音": "douyin", "小红书": "xiaohongshu", "快手": "kuaishou", "微博": "weibo"]
        let rawPlatform = str("platform")
        let platform = aliases[rawPlatform] ?? rawPlatform.lowercased()
        var publication: String?
        if let rawTime = row["createdAt"] {
            guard let number = rawTime as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
                throw LocalFailure.message("createdAt必须是秒级整数或0（未知）")
            }
            let seconds = number.doubleValue
            guard seconds.isFinite, seconds.rounded(.towardZero) == seconds else { throw LocalFailure.message("createdAt不是有效秒级整数") }
            if seconds == 0 { warnings.append("旧文件createdAt=0：评论发布时间标记为未知；导入时间仅代表本次导入。") }
            else {
                guard seconds >= 946684800, seconds <= now.timeIntervalSince1970 + 300 else { throw LocalFailure.message("createdAt越界或在未来；未替换为当前时间") }
                publication = FusionDates.string(Date(timeIntervalSince1970: seconds))
            }
        } else { warnings.append("旧文件缺少评论发布时间：保留未知，不以导入时间代替。") }
        if ["contact", "ocrContact", "avatar", "bio"].contains(where: { row[$0] != nil }) {
            warnings.append("仅导入公开评论与来源；旧联系方式、头像、简介、OCR和评分字段未导入。")
        }
        let lead = FusionLead(platform: platform, sourceURL: str("videoURL"), profileURL: str("profileURL"),
                              commentID: str("commentID"), text: str("text"), authorName: str("name"),
                              keyword: str("keyword"), sourceTitle: str("postTitle"), publishedAt: publication,
                              collectedAt: FusionDates.string(now), region: nil, origin: "leadradar_json")
        return try lead.validated(now: now)
    }

    func exportCSV(rows: [FusionLead]) -> String {
        let header = ["平台", "昵称", "评论", "原始来源", "公开主页", "关键词", "来源标题", "评论发布时间（未知留空）", "来源发布时间（未知留空）", "采集或导入时间", "原始地区标签（非居住地）", "原始记录来源", "提问标记", "规则标签（待人工确认）", "规则依据", "人工跟进状态", "人工备注", "原收藏"]
        let values = rows.map { lead -> [String] in
            let follow = followup(for: lead)
            return [lead.platformTitle, lead.authorName, lead.text, lead.sourceURL, lead.profileURL, lead.keyword,
                    lead.sourceTitle, lead.publishedAt ?? "", lead.sourcePublishedAt ?? "", lead.collectedAt,
                    lead.region ?? "", lead.origin, lead.isQuestion ? "是" : "否", lead.assessment.labels,
                    lead.assessment.explanation, follow.status.title, follow.note, follow.favorite ? "是" : "否"]
        }
        return "\u{feff}" + ([header] + values).map { $0.map(CommentStore.csvCell).joined(separator: ",") }.joined(separator: "\r\n")
    }

    func exportJSON(rows: [FusionLead]) throws -> Data {
        let states = Dictionary(rows.map { ($0.id, followup(for: $0)) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        let unique = rows.filter { seen.insert($0.id).inserted }
        let envelope = FusionEnvelope(records: unique, followups: states)
        try Self.checkEnvelope(envelope)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumImportBytes else { throw LocalFailure.message("导出超过5 MiB，请缩小筛选范围") }
        return data
    }
}
