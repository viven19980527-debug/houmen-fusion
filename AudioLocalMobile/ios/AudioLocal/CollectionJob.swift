import Foundation
import CryptoKit

struct VideoTarget: Codable, Equatable {
    let url: String
    let title: String
    var publication: SourcePublicationEvidence? = nil
}

struct CollectionJob: Codable {
    static let currentSchema = 4
    var schema = 1
    var sourcePolicy: String? = nil
    var searchExhausted: Bool? = nil
    var sourceOrderConfirmedAt: String? = nil
    let keyword: String
    var platformRaw: String? = nil
    var industryRaw: String? = nil
    var recencyRaw: String? = nil
    var currentAccepted: Int? = nil
    var skippedOld: Int? = nil
    var skippedUnknown: Int? = nil
    var videos: [VideoTarget] = []
    var nextIndex = 0
    var seen: [String] = []
    var currentVideoKeys: [String] = []
    var added = 0
    var outcomes: [String] = []
    var createdAt = ISO8601DateFormatter().string(from: Date())
    var finished: Bool { (schema >= 3 && searchExhausted == true) || (!videos.isEmpty && nextIndex == videos.count) }

    var scanLimit: Int { schema >= 2 ? 200 : 50 }
    var requiresFreshSourceSearch: Bool { schema < Self.currentSchema || sourcePolicy != SourcePublicationGate.policy }
    var acceptedThisVideo: Int { currentAccepted ?? currentVideoKeys.count }
    var platform: CollectionPlatform { platformRaw.flatMap(CollectionPlatform.init(rawValue:)) ?? .douyin }
    var industry: IndustryProfile { industryRaw.flatMap(IndustryProfile.init(rawValue:)) ?? .general }
    var range: CommentRecency { recencyRaw.flatMap(CommentRecency.init(rawValue:)) ?? .all }

    func validate() throws {
        guard [1, 2, 3, Self.currentSchema].contains(schema),
              schema >= 3 || searchExhausted == nil,
              searchExhausted != true || (videos.isEmpty && seen.isEmpty && currentVideoKeys.isEmpty &&
                  added == 0 && nextIndex == 0 && outcomes.isEmpty && acceptedThisVideo == 0 &&
                  (skippedOld ?? 0) == 0 && (skippedUnknown ?? 0) == 0),
              schema >= 3 ? sourcePolicy == (schema == 3 ? SourcePublicationGate.legacyPolicy : SourcePublicationGate.policy) : sourcePolicy == nil,
              schema >= 3 || sourceOrderConfirmedAt == nil,
              sourceOrderConfirmedAt == nil || CommentRecency.isoDate(sourceOrderConfirmedAt) != nil,
              schema < 3 || videos.isEmpty || sourceOrderConfirmedAt != nil,
              schema < 3 || videos.allSatisfy({ target in
                  guard let publication = target.publication else { return false }
                  return SourcePublicationGate.valid(publication) &&
                      CommentRecency.isoDate(publication.checkedAt).map { SourcePublicationGate.eligible(publication, now: $0, windowDays: schema == 3 ? 7 : 90) } == true
              }),
              schema >= 3 || videos.allSatisfy({ $0.publication == nil }),
              platformRaw == nil || (CollectionPlatform(rawValue: platformRaw!)?.canCollect == true),
              schema != 1 || platformRaw == nil,
              industryRaw == nil || IndustryProfile(rawValue: industryRaw!) != nil,
              schema != 1 || industryRaw == nil,
              schema == 1 || (recencyRaw.flatMap(CommentRecency.init(rawValue:)) != nil && currentAccepted != nil && skippedOld != nil && skippedUnknown != nil),
              schema >= 2 || (recencyRaw == nil && currentAccepted == nil && skippedOld == nil && skippedUnknown == nil),
              acceptedThisVideo >= 0, acceptedThisVideo <= 50, acceptedThisVideo <= currentVideoKeys.count,
              (skippedOld ?? 0) >= 0, (skippedUnknown ?? 0) >= 0,
              (skippedOld ?? 0) <= seen.count,
              (skippedUnknown ?? 0) <= seen.count - (skippedOld ?? 0),
              added <= seen.count - (skippedOld ?? 0) - (skippedUnknown ?? 0),
              acceptedThisVideo <= seen.count - (skippedOld ?? 0) - (skippedUnknown ?? 0),
              !finished || acceptedThisVideo == 0, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              keyword.count <= 60, videos.count <= 5, nextIndex >= 0, nextIndex <= videos.count,
              seen.count <= 5 * scanLimit, currentVideoKeys.count <= scanLimit, added >= 0, added <= 250,
              createdAt.count <= 64, ISO8601DateFormatter().date(from: createdAt) != nil,
              added <= seen.count, seen.count <= nextIndex * scanLimit + currentVideoKeys.count,
              !videos.isEmpty || (seen.isEmpty && currentVideoKeys.isEmpty && added == 0),
              !finished || currentVideoKeys.isEmpty,
              Set(seen).count == seen.count, Set(currentVideoKeys).count == currentVideoKeys.count,
              currentVideoKeys.allSatisfy({ seen.contains($0) }), outcomes.count == nextIndex,
              outcomes.allSatisfy({ $0.count <= 300 }), Set(videos.compactMap { CollectionPlatform.sourceIdentity($0.url) }).count == videos.count,
              seen.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
              videos.allSatisfy({ v in
                  return CollectionPlatform.sourcePlatform(v.url) == platform && v.title.count <= 300

              }) else { throw JobFailure.invalid }
    }

    /// A malformed adapter envelope is a failure, not proof that the search has no sources.
    static func searchVideos(from result: [String: Any], sourceWindowDays: Int? = nil) throws -> [[String: Any]] {
        guard result["state"] as? String == "ready", result["latestOrderConfirmed"] as? Bool == true,
              let videos = result["videos"] as? [[String: Any]] else { throw JobFailure.invalidSearch }
        if let sourceWindowDays {
            guard SourcePublicationGate.windows.contains(sourceWindowDays),
                  result["sourceWindowDays"] as? Int == sourceWindowDays,
                  result["timeFilterApplied"] as? String == (sourceWindowDays == 7 ? "一周内" : "不限") else { throw JobFailure.invalidSearch }
        }
        return videos
    }

    /// Only already-verified candidates participate. Tier priority precedes date so a rounded
    /// boundary label cannot outrank a source whose recent tier was established precisely.
    static func prioritizedTargets(_ targets: [VideoTarget], now: Date = Date()) -> [VideoTarget] {
        targets.enumerated().compactMap { index, target -> (Int, VideoTarget, Int, Date)? in
            guard CollectionPlatform.sourcePlatform(target.url)?.canCollect == true,
                  let tier = SourcePublicationGate.tier(target.publication, now: now),
                  let iso = target.publication?.publishedAtISO, let date = CommentRecency.isoDate(iso) else { return nil }
            return (index, target, tier, date)
        }.sorted { lhs, rhs in
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            if lhs.3 != rhs.3 { return lhs.3 > rhs.3 }
            return lhs.0 < rhs.0
        }.map { $0.1 }
    }

    static func rowKey(_ row: [String: Any]) -> String {
        let fields = CommentIdentity.fields(sourceURL: row["sourceUrl"] as? String ?? "",
            profileURL: row["profileUrl"] as? String ?? "", commentID: row["commentId"] as? String ?? "",
            text: row["text"] as? String ?? "")
        let identity = (try? JSONSerialization.data(withJSONObject: fields)) ?? Data()
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}

enum JobFailure: LocalizedError {
    case invalid
    case invalidSearch
    var errorDescription: String? {
        switch self {
        case .invalid: return "上次任务记录无效，未覆盖文件；可重新开始新的任务。"
        case .invalidSearch: return "搜索结果结构异常，已暂停；未把异常记作没有近期来源。"
        }
    }
}

/// Local-only checkpoint. Contains video references and hashes, never credentials or full comments.
struct CollectionJobStore {
    let file: URL
    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShengxunLocal", isDirectory: true)
        file = base.appendingPathComponent("collection-job.json")
    }
    func load() throws -> CollectionJob? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 100_000 else { throw JobFailure.invalid }
        let job = try JSONDecoder().decode(CollectionJob.self, from: Data(contentsOf: file))
        try job.validate()
        return job
    }
    func save(_ job: CollectionJob) throws {
        try job.validate()
        var folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        let data = try JSONEncoder().encode(job)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
    }
}

/// Bounded DOM polling with an injectable monotonic clock. Unknown never means zero.
enum CommentPolling {
    static let timeout: TimeInterval = 12
    static func deadline(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval { now + timeout }
    static func wait(until deadline: TimeInterval,
                     clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                     evaluate: (TimeInterval) async throws -> [String: Any],
                     waiting: (String, TimeInterval) -> Void = { _, _ in },
                     sleep: (TimeInterval) async throws -> Void = { seconds in
                         try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                     }) async throws -> [String: Any]? {
        while deadline > clock() {
            try Task.checkCancellation()
            let budget = deadline - clock()
            guard budget > 0 else { return nil }
            let result = try await evaluate(budget)
            try Task.checkCancellation()
            guard let state = result["state"] as? String else { throw LocalFailure.message("评论返回结构无效，已暂停") }
            // Authentication and malformed replies are errors, not empty results or automatic skips.
            if state == "blocked" { throw LocalFailure.message(result["message"] as? String ?? "平台要求验证，已暂停") }
            guard ["ready", "skipped", "waiting"].contains(state) else { throw LocalFailure.message("未知评论状态，已暂停") }
            guard deadline > clock() else { return nil }
            if state == "ready" || state == "skipped" { return result }
            let remaining = max(0, deadline - clock())
            waiting(result["message"] as? String ?? "等待评论加载", remaining)
            let sleepBudget = max(0, deadline - clock())
            guard sleepBudget > 0 else { return nil }
            try await sleep(min(1.5, sleepBudget))
        }
        try Task.checkCancellation()
        return nil
    }
}
