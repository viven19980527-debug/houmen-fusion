import Foundation
import CoreFoundation
import Combine
import CryptoKit

// Public-content adapter. WBI parameter mixing is adapted from the supplied
// LeadRadar source (ad74465, LDRadar.swift), not an authenticated platform SDK.
// Unlike that source, this adapter does not read profiles, extract contacts,
// use cookies, automate login, retry access denials, or merge people by identity.
// API compatibility has not been verified against the live service.

enum FusionBiliError: LocalizedError {
    case invalidKeyword
    case invalidURL
    case responseTooLarge
    case invalidResponse
    case invalidStoreCount
    case http(Int)
    case platform(String)

    var errorDescription: String? {
        switch self {
        case .invalidKeyword: return "请输入 1–100 个字符的关键词。"
        case .invalidURL: return "已停止：请求地址不在允许的 HTTPS 接口范围内。"
        case .responseTooLarge: return "已停止：接口响应超过 2 MiB 上限。"
        case .invalidResponse: return "已停止：接口格式与预期不符，未将它当作空结果。"
        case .invalidStoreCount: return "已停止：本机线索保存结果异常，请检查线索库。"
        case .http(let status):
            if [401, 403, 429].contains(status) {
                return "平台要求认证、拒绝访问或限流（HTTP \(status)）；已停止，不会自动重试或绕过。"
            }
            return "已停止：接口返回 HTTP \(status)。"
        case .platform(let code):
            return "平台拒绝本次请求（code=\(code)）；已停止。请改用官方页面查看，不会自动登录或绕过。"
        }
    }
}

struct FusionBiliVideo {
    let aid: String
    let bvid: String
    let title: String
    let publishedAt: String?

    var sourceURL: String { "https://www.bilibili.com/video/\(bvid)" }
}

enum FusionBiliParsing {
    static let maximumResponseBytes = 2 * 1024 * 1024
    static let allowedPaths: Set<String> = [
        "/x/web-interface/nav", "/x/web-interface/wbi/search/type", "/x/v2/reply/wbi/main"
    ]
    private static let mixinTable = [46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,
        27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,
        17,0,1,60,51,30,4,22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52]
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func allows(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "api.bilibili.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.fragment == nil && allowedPaths.contains(url.path)
    }

    // A single canonical percent-encoded query is used for both hashing and
    // transport. Hashing unescaped Chinese text and sending escaped text differs.
    static func canonicalQuery(_ parameters: [String: String]) -> String {
        parameters.keys.sorted().map { key in
            let value = parameters[key, default: ""].filter { !"!'()*".contains($0) }
            let k = key.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            let v = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    static func signedURL(path: String, parameters: [String: String],
                          key: String, timestamp: Int) throws -> URL {
        guard key.count == 32, timestamp > 0, allowedPaths.contains(path) else {
            throw FusionBiliError.invalidURL
        }
        var params = parameters
        params["wts"] = String(timestamp)
        let query = canonicalQuery(params)
        let digest = Insecure.MD5.hash(data: Data((query + key).utf8))
            .map { String(format: "%02x", $0) }.joined()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.bilibili.com"
        components.path = path
        components.percentEncodedQuery = query + "&w_rid=" + digest
        guard let url = components.url, allows(url) else { throw FusionBiliError.invalidURL }
        return url
    }

    static func envelope(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes else { throw FusionBiliError.responseTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = root["code"] as? NSNumber,
              CFGetTypeID(code) != CFBooleanGetTypeID() else { throw FusionBiliError.invalidResponse }
        guard code.stringValue == "0" else { throw FusionBiliError.platform(code.stringValue) }
        guard let payload = root["data"] as? [String: Any] else { throw FusionBiliError.invalidResponse }
        return payload
    }

    static func mixinKey(_ payload: [String: Any]) throws -> String {
        guard let image = payload["wbi_img"] as? [String: Any],
              let img = image["img_url"] as? String, let sub = image["sub_url"] as? String,
              let imgURL = URL(string: img), let subURL = URL(string: sub) else {
            throw FusionBiliError.invalidResponse
        }
        // Only parse the filenames; these response-supplied URLs are never fetched.
        let raw = imgURL.deletingPathExtension().lastPathComponent
            + subURL.deletingPathExtension().lastPathComponent
        guard raw.count == 64,
              raw.range(of: "^[A-Za-z0-9]{64}$", options: .regularExpression) != nil else {
            throw FusionBiliError.invalidResponse
        }
        let letters = Array(raw)
        return String(mixinTable.prefix(32).map { letters[$0] })
    }

    static func decimalID(_ value: Any?) -> String? {
        let result: String
        if let text = value as? String { result = text }
        else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            result = number.stringValue
        } else { return nil }
        guard result.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil,
              result.contains(where: { $0 != "0" }) else { return nil }
        return result
    }

    static func isoDate(_ value: Any?, now: Date) -> String? {
        let seconds: TimeInterval?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            seconds = number.doubleValue
        } else if let string = value as? String { seconds = TimeInterval(string) }
        else { seconds = nil }
        guard let seconds, seconds.isFinite, seconds >= 946_684_800,
              seconds <= now.timeIntervalSince1970 + 300 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    static func videos(_ payload: [String: Any], now: Date) throws -> [FusionBiliVideo] {
        guard let raw = payload["result"] as? [Any] else { throw FusionBiliError.invalidResponse }
        var result: [FusionBiliVideo] = []
        var seen = Set<String>()
        for row in raw.prefix(20) {
            guard let item = row as? [String: Any], let aid = decimalID(item["aid"]),
                  let bvid = item["bvid"] as? String,
                  bvid.range(of: "^BV[A-Za-z0-9]{10}$", options: .regularExpression) != nil,
                  let title = item["title"] as? String, seen.insert(bvid).inserted else { continue }
            let plain = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            result.append(FusionBiliVideo(aid: aid, bvid: bvid, title: plain,
                publishedAt: isoDate(item["pubdate"], now: now)))
            if result.count == 10 { break }
        }
        if !raw.isEmpty && result.isEmpty { throw FusionBiliError.invalidResponse }
        return result
    }

    static func comments(_ payload: [String: Any], video: FusionBiliVideo,
                         keyword: String, now: Date, limit: Int) throws -> [FusionLead] {
        guard payload.keys.contains("replies") else { throw FusionBiliError.invalidResponse }
        if payload["replies"] is NSNull { return [] }
        guard let roots = payload["replies"] as? [[String: Any]] else {
            throw FusionBiliError.invalidResponse
        }
        let cap = min(100, max(0, limit))
        guard cap > 0 else { return [] }
        var queue = roots.prefix(100).map { ($0, 0) }
        var index = 0
        var result: [FusionLead] = []
        var seen = Set<String>()
        let observedAt = ISO8601DateFormatter().string(from: now)
        while index < queue.count && index < 200 && result.count < cap {
            let (item, depth) = queue[index]; index += 1
            if depth < 1, let replies = item["replies"] as? [[String: Any]] {
                queue.append(contentsOf: replies.prefix(max(0, 200 - queue.count)).map { ($0, depth + 1) })
            }
            guard let id = decimalID(item["rpid_str"] ?? item["rpid"]),
                  let content = item["content"] as? [String: Any],
                  let text = content["message"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(id).inserted else { continue }
            let member = item["member"] as? [String: Any] ?? [:]
            let author = member["uname"] as? String ?? "未署名"
            let observedUID = decimalID(member["mid"] ?? item["mid"])
            let uid = observedUID.flatMap { $0.count <= 20 ? $0 : nil }
            let profile = uid.map { "https://space.bilibili.com/\($0)" } ?? ""
            result.append(FusionLead(platform: "bilibili", sourceURL: video.sourceURL,
                profileURL: profile, commentID: id, text: text, authorName: author,
                keyword: keyword, sourceTitle: video.title,
                publishedAt: isoDate(item["ctime"], now: now), collectedAt: observedAt,
                region: nil, origin: "bilibili_public", sourcePublishedAt: video.publishedAt))
        }
        if !roots.isEmpty && result.isEmpty { throw FusionBiliError.invalidResponse }
        return result
    }
}

// Redirects are all rejected (including same-host redirects). A 3xx response
// becomes a visible error instead of silently forwarding to a different host.
private final class FusionBiliRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class FusionBiliClient: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var progress = ""
    @Published private(set) var errorText = ""
    private var worker: Task<Void, Never>?
    private var activeSession: URLSession?

    func cancel() {
        worker?.cancel()
        activeSession?.invalidateAndCancel()
    }

    func search(keyword: String, limit: Int = 50, onBatch: @escaping ([FusionLead]) throws -> Int) async {
        guard !running else { return }
        let term = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 100 else {
            errorText = FusionBiliError.invalidKeyword.localizedDescription
            return
        }
        running = true; errorText = ""; progress = "准备公开接口请求…"
        let task = Task { [weak self] in
            guard let self else { return }
            await self.perform(keyword: term, limit: min(100, max(1, limit)), onBatch: onBatch)
        }
        worker = task
        await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
        worker = nil
        running = false
    }

    private func perform(keyword: String, limit: Int, onBatch: ([FusionLead]) throws -> Int) async {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: FusionBiliRedirectPolicy(), delegateQueue: nil)
        activeSession = session
        defer { session.invalidateAndCancel(); activeSession = nil }
        var requestCount = 0
        var received = 0
        var stored = 0
        do {
            func get(_ url: URL) async throws -> [String: Any] {
                guard FusionBiliParsing.allows(url) else { throw FusionBiliError.invalidURL }
                try Task.checkCancellation()
                if requestCount > 0 { try await Task.sleep(nanoseconds: 700_000_000) }
                requestCount += 1
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.httpShouldHandleCookies = false
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("HoumenFusion/0.2 PublicContentReader", forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse, let finalURL = http.url,
                      FusionBiliParsing.allows(finalURL) else { throw FusionBiliError.invalidResponse }
                guard (200...299).contains(http.statusCode) else { throw FusionBiliError.http(http.statusCode) }
                guard http.expectedContentLength <= Int64(FusionBiliParsing.maximumResponseBytes) else {
                    throw FusionBiliError.responseTooLarge
                }
                var data = Data()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < FusionBiliParsing.maximumResponseBytes else {
                        throw FusionBiliError.responseTooLarge
                    }
                    data.append(byte)
                }
                return try FusionBiliParsing.envelope(data)
            }
            guard let nav = URL(string: "https://api.bilibili.com/x/web-interface/nav") else {
                throw FusionBiliError.invalidURL
            }
            let key = try FusionBiliParsing.mixinKey(try await get(nav))
            let searchURL = try FusionBiliParsing.signedURL(path: "/x/web-interface/wbi/search/type",
                parameters: ["search_type": "video", "keyword": keyword, "page": "1", "page_size": "20", "order": "pubdate"],
                key: key, timestamp: Int(Date().timeIntervalSince1970))
            progress = "读取公开搜索结果（最多 10 个视频）…"
            let videos = try FusionBiliParsing.videos(try await get(searchURL), now: Date())
            for (index, video) in videos.enumerated() {
                try Task.checkCancellation()
                guard received < limit else { break }
                progress = "读取公开评论 \(index + 1)/\(videos.count)，已收到 \(received) 条，新增 \(stored) 条"
                let url = try FusionBiliParsing.signedURL(path: "/x/v2/reply/wbi/main",
                    parameters: ["oid": video.aid, "type": "1", "mode": "3", "pagination_str": "{\"offset\":\"\"}", "plat": "1"],
                    key: key, timestamp: Int(Date().timeIntervalSince1970))
                let rows = try FusionBiliParsing.comments(try await get(url), video: video,
                    keyword: keyword, now: Date(), limit: limit - received)
                try Task.checkCancellation()
                if !rows.isEmpty {
                    received += rows.count
                    let added = try onBatch(rows)
                    guard (0...rows.count).contains(added) else { throw FusionBiliError.invalidStoreCount }
                    stored += added
                }
            }
            try Task.checkCancellation()
            progress = "本轮公开请求结束：收到 \(received) 条，新增 \(stored) 条。仅读取有限结果，不代表全部评论。"
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                progress = "已停止：收到 \(received) 条，成功新增 \(stored) 条；已有线索未清空。"
            } else {
                errorText = error.localizedDescription
                progress = "请求已中止：收到 \(received) 条，成功新增 \(stored) 条；已有线索未清空，不代表采集完成。"
            }
        }
    }
}
