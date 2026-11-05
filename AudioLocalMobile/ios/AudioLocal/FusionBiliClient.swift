import Foundation
import SwiftUI
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

    /// 浏览器 UA（B站对自定义 UA 直接 -101）
    private static let browserUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// 匿名访客 cookie（buvid3/buvid4），仅存内存
    private var guestCookie = ""

    private func bootstrapGuestCookie(_ session: URLSession) async {
        guard guestCookie.isEmpty else { return }
        if let url = URL(string: "https://api.bilibili.com/x/frontend/finger/spi") {
            var req = URLRequest(url: url)
            req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
            req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
            if let (data, _) = try? await session.data(for: req),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = root["data"] as? [String: Any] {
                let b3 = (d["b_3"] as? String) ?? ""
                let b4 = (d["b_4"] as? String) ?? ""
                var parts: [String] = []
                if !b3.isEmpty { parts.append("buvid3=" + b3) }
                if !b4.isEmpty { parts.append("buvid4=" + b4) }
                guestCookie = parts.joined(separator: "; ")
            }
        }
        // 兜底：直接访问首页抓 Set-Cookie
        if guestCookie.isEmpty, let home = URL(string: "https://www.bilibili.com/") {
            var req = URLRequest(url: home)
            req.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
            if let (_, resp) = try? await session.data(for: req),
               let http = resp as? HTTPURLResponse {
                let fields = http.allHeaderFields
                var parts: [String] = []
                for (k, v) in fields {
                    let key = String(describing: k)
                    if key.lowercased() == "set-cookie" {
                        let line = String(describing: v)
                        let first = line.components(separatedBy: ";").first ?? line
                        if first.hasPrefix("buvid3=") || first.hasPrefix("buvid4=") {
                            parts.append(first)
                        }
                    }
                }
                guestCookie = parts.joined(separator: "; ")
            }
        }
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
                // 匿名访客 cookie 由本机首次请求获取，仅用于通过 B站访客风控（-101）
                request.httpShouldHandleCookies = false
                request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
                request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
                request.setValue(Self.browserUA, forHTTPHeaderField: "User-Agent")
                request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
                request.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
                let cookie = BiliAuth.isLoggedIn ? BiliAuth.cookieHeader : guestCookie
                if !cookie.isEmpty {
                    request.setValue(cookie, forHTTPHeaderField: "Cookie")
                }
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
            // 已登录用登录 cookie；否则引导访客标识（B站 无 cookie 会返回 -101）
            if !BiliAuth.isLoggedIn {
                await bootstrapGuestCookie(session)
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


// MARK: - B站登录态（本机保存，仅用于公开接口的访客身份）

import WebKit

enum BiliAuth {

    private static let keySESSDATA = "bili.SESSDATA"
    private static let keyBiliJct  = "bili.bili_jct"
    private static let keyBuvid3   = "bili.buvid3"
    private static let keyBuvid4   = "bili.buvid4"
    private static let keyDedeUID  = "bili.DedeUserID"
    private static let keySavedAt  = "bili.savedAt"

    static var sessdata: String { UserDefaults.standard.string(forKey: keySESSDATA) ?? "" }
    static var isLoggedIn: Bool { !sessdata.isEmpty }

    static var savedAt: Date? {
        let t = UserDefaults.standard.double(forKey: keySavedAt)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// 组装 Cookie 头：登录态优先，没有就只带访客标识
    static var cookieHeader: String {
        var parts: [String] = []
        let ud = UserDefaults.standard
        if let v = ud.string(forKey: keySESSDATA), !v.isEmpty { parts.append("SESSDATA=" + v) }
        if let v = ud.string(forKey: keyBiliJct),  !v.isEmpty { parts.append("bili_jct=" + v) }
        if let v = ud.string(forKey: keyDedeUID),  !v.isEmpty { parts.append("DedeUserID=" + v) }
        if let v = ud.string(forKey: keyBuvid3),   !v.isEmpty { parts.append("buvid3=" + v) }
        if let v = ud.string(forKey: keyBuvid4),   !v.isEmpty { parts.append("buvid4=" + v) }
        return parts.joined(separator: "; ")
    }

    /// 从 WKWebView cookie 仓库同步（回调版，避免并发捕获问题）
    static func syncFromWebKit(_ done: @escaping (Bool) -> Void) {
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            var found: [String: String] = [:]
            for c in cookies where c.domain.contains("bilibili.com") {
                found[c.name] = c.value
            }
            let ud = UserDefaults.standard
            if let v = found["SESSDATA"], !v.isEmpty { ud.set(v, forKey: keySESSDATA) }
            if let v = found["bili_jct"] { ud.set(v, forKey: keyBiliJct) }
            if let v = found["DedeUserID"] { ud.set(v, forKey: keyDedeUID) }
            if let v = found["buvid3"] { ud.set(v, forKey: keyBuvid3) }
            if let v = found["buvid4"] { ud.set(v, forKey: keyBuvid4) }
            let ok = !sessdata.isEmpty
            if ok { ud.set(Date().timeIntervalSince1970, forKey: keySavedAt) }
            DispatchQueue.main.async { done(ok) }
        }
    }

    static func signOut() {
        let ud = UserDefaults.standard
        for k in [keySESSDATA, keyBiliJct, keyBuvid3, keyBuvid4, keyDedeUID, keySavedAt] {
            ud.removeObject(forKey: k)
        }
    }
}

// MARK: - B站登录页

struct BiliLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var done = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(done ? "已识别登录态，点右上角「完成」"
                          : "在下方登录 B站（扫码或账号密码），登录成功会自动识别")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(done ? Color.green.opacity(0.15) : Color.blue.opacity(0.12))
                BiliLoginWeb(onLoggedIn: { done = true })
            }
            .navigationTitle("B站登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }.bold()
                }
            }
        }
    }
}

private struct BiliLoginWeb: UIViewRepresentable {
    let onLoggedIn: () -> Void

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        if let u = URL(string: "https://passport.bilibili.com/login") {
            wv.load(URLRequest(url: u))
        }
        context.coordinator.startPolling()
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate {
        let parent: BiliLoginWeb
        private var timer: Timer?
        private var finished = false
        init(_ p: BiliLoginWeb) { parent = p }

        func startPolling() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self, !self.finished else { return }
                BiliAuth.syncFromWebKit { ok in
                    guard ok, !self.finished else { return }
                    self.finished = true
                    self.timer?.invalidate()
                    self.timer = nil
                    self.parent.onLoggedIn()
                }
            }
        }

        deinit { timer?.invalidate() }
    }
}


// MARK: - 统一登录（B站 / 抖音 / 小红书 同一套机制）

enum AuthPlatform: String, CaseIterable, Identifiable {
    case bilibili, douyin, xhs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bilibili: return "B站"
        case .douyin:   return "抖音"
        case .xhs:      return "小红书"
        }
    }
    var loginURL: String {
        switch self {
        case .bilibili: return "https://passport.bilibili.com/login"
        case .douyin:   return "https://www.douyin.com/hot"
        case .xhs:      return "https://www.xiaohongshu.com/login"
        }
    }
    /// SwiftUI 用：该平台是否已登录
    var isLoggedIn: Bool { PlatformAuth.isLoggedIn(self) }

    /// 判定"已登录"的 cookie 键（任一存在即可）
    var sessionKeys: [String] {
        switch self {
        case .bilibili: return ["SESSDATA"]
        case .douyin:   return ["sessionid", "sessionid_ss", "sid_tt", "passport_csrf_token"]
        case .xhs:      return ["web_session", "a1"]
        }
    }
    var cookieDomainHint: String {
        switch self {
        case .bilibili: return "bilibili.com"
        case .douyin:   return "douyin.com"
        case .xhs:      return "xiaohongshu.com"
        }
    }
}

enum PlatformAuth {

    private static func flagKey(_ p: AuthPlatform) -> String { "auth.logged.\(p.rawValue)" }

    static func isLoggedIn(_ p: AuthPlatform) -> Bool {
        if p == .bilibili { return BiliAuth.isLoggedIn }
        return UserDefaults.standard.bool(forKey: flagKey(p))
    }

    static func checkWebKit(_ p: AuthPlatform, _ done: @escaping (Bool) -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            var names = Set<String>()
            for c in cookies where c.domain.contains(p.cookieDomainHint) {
                names.insert(c.name)
            }
            let ok = p.sessionKeys.contains { names.contains($0) }
            if ok { UserDefaults.standard.set(true, forKey: flagKey(p)) }
            DispatchQueue.main.async { done(ok) }
        }
    }

    static func signOut(_ p: AuthPlatform) {
        UserDefaults.standard.set(false, forKey: flagKey(p))
        if p == .bilibili { BiliAuth.signOut() }
    }
}

// MARK: - 统一登录页（三个平台共用）

struct PlatformLoginView: View {
    let platform: AuthPlatform
    @Environment(\.dismiss) private var dismiss

    @State private var done = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(done ? "已识别 \(platform.title) 登录态，点「完成」返回"
                          : "在下方登录 \(platform.title)（扫码或账号密码），成功后自动识别")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(done ? Color.green.opacity(0.15) : Color.blue.opacity(0.12))
                PlatformLoginWeb(platform: platform, onLoggedIn: { done = true })
            }
            .navigationTitle("\(platform.title) 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }.bold()
                }
            }
        }
    }
}

private struct PlatformLoginWeb: UIViewRepresentable {
    let platform: AuthPlatform
    let onLoggedIn: () -> Void

    func makeCoordinator() -> Coord { Coord(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()          // 与采集 WebView 共用同一 cookie 仓库

        // 关键：和 BrowserCollector 一致用桌面模式。
        // 手机模式访问 douyin.com 会拿到"抖音电脑版/抖音精选"推广页，没有登录入口；
        // 桌面模式才是带「登录」按钮的正式站点。
        cfg.defaultWebpagePreferences.preferredContentMode = .desktop
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        if platform != .bilibili {
            let clickLogin = """
            (function(){
              var texts = ['登录','立即登录','注册/登录','登录/注册','扫码登录','Log in','Sign in'];
              var tries = 0;
              var t = setInterval(function(){
                if (++tries > 25) { clearInterval(t); return; }
                var nodes = document.querySelectorAll('button, a, div[role=button], span, li');
                for (var i=0;i<nodes.length;i++){
                  var s = (nodes[i].innerText||'').trim();
                  if (texts.indexOf(s) >= 0 && nodes[i].getBoundingClientRect().width > 0) {
                    nodes[i].click(); clearInterval(t); return;
                  }
                }
              }, 700);
            })();
            """
            cfg.userContentController.addUserScript(
                WKUserScript(source: clickLogin, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        wv.navigationDelegate = context.coordinator
        if let u = URL(string: platform.loginURL) { wv.load(URLRequest(url: u)) }
        context.coordinator.start()
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coord: NSObject, WKNavigationDelegate {
        let parent: PlatformLoginWeb
        private var timer: Timer?
        private var finished = false

        init(_ p: PlatformLoginWeb) { parent = p }

        func start() {
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self, !self.finished else { return }
                PlatformAuth.checkWebKit(self.parent.platform) { ok in
                    guard ok, !self.finished else { return }
                    // B站 额外把 cookie 落进 UserDefaults 供原生请求使用
                    if self.parent.platform == .bilibili {
                        BiliAuth.syncFromWebKit { _ in }
                    }
                    self.finished = true
                    self.timer?.invalidate()
                    self.timer = nil
                    self.parent.onLoggedIn()
                }
            }
        }

        deinit { timer?.invalidate() }
    }
}
