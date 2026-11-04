import Foundation

/// Platform boundaries for the on-device browser, not access to another app's sandbox.
/// Xiaohongshu is an experimental DOM adapter; Channels has no verified collection route.
enum CollectionPlatform: String, CaseIterable, Codable, Identifiable {
    case douyin
    case xiaohongshu
    case channels

    var id: String { rawValue }
    var title: String {
        switch self {
        case .douyin: return "抖音"
        case .xiaohongshu: return "小红书"
        case .channels: return "微信视频号"
        }
    }
    var entryLabel: String {
        switch self {
        case .douyin: return "抖音"
        case .xiaohongshu: return "小红书·测试"
        case .channels: return "视频号·未接通"
        }
    }
    var canCollect: Bool { self != .channels }
    var homeURL: URL {
        switch self {
        case .douyin: return URL(string: "https://www.douyin.com/")!
        case .xiaohongshu: return URL(string: "https://www.xiaohongshu.com/explore")!
        // Official CREATOR backend only, never treated as a consumer search/collection API.
        case .channels: return URL(string: "https://channels.weixin.qq.com/")!
        }
    }

    func searchURL(keyword: String) -> URL? {
        guard canCollect else { return nil }
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.count <= 100,
              word.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        var c = URLComponents()
        c.scheme = "https"
        switch self {
        case .douyin:
            c.host = "www.douyin.com"
            // Encode one path segment; a user-entered slash/query must not become navigation.
            guard let encoded = word.addingPercentEncoding(withAllowedCharacters:
                CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) else { return nil }
            c.percentEncodedPath = "/search/" + encoded
            c.queryItems = [URLQueryItem(name: "type", value: "video")]
        case .xiaohongshu:
            c.host = "www.xiaohongshu.com"
            c.path = "/search_result"
            c.queryItems = [URLQueryItem(name: "keyword", value: word),
                            URLQueryItem(name: "source", value: "web_explore_feed")]
        case .channels: return nil
        }
        return c.url
    }

    static func sourcePlatform(_ value: String) -> CollectionPlatform? {
        guard let c = safeComponents(value) else { return nil }
        switch hostPlatform(c.host) {
        case .douyin:
            guard c.percentEncodedQuery == nil,
                  matches(c.path, "^/video/[0-9]{10,30}/?$") else { return nil }
            return .douyin
        case .xiaohongshu:
            guard validXHSQuery(c, allowNoteSource: true),
                  matches(c.path, "^/(?:explore|search_result|discovery/item)/[0-9a-fA-F]{24}/?$") else { return nil }
            return .xiaohongshu
        default: return nil
        }
    }

    static func profilePlatform(_ value: String) -> CollectionPlatform? {
        guard let c = safeComponents(value) else { return nil }
        switch hostPlatform(c.host) {
        case .douyin:
            guard c.percentEncodedQuery == nil,
                  matches(c.path, "^/user/[A-Za-z0-9_.-]{4,200}/?$") else { return nil }
            return .douyin
        case .xiaohongshu:
            guard validXHSQuery(c),
                  matches(c.path, "^/user/profile/[0-9a-fA-F]{24}/?$") else { return nil }
            return .xiaohongshu
        default: return nil
        }
    }

    /// Hash/grouping identity only. Keep the original validated source URL for navigation:
    /// its existing XHS xsec fields may be required by the public page, and are not generated here.
    static func sourceIdentity(_ value: String) -> String? {
        guard let platform = sourcePlatform(value), let c = safeComponents(value),
              let last = c.path.split(separator: "/").last else { return nil }
        switch platform {
        case .douyin: return "https://www.douyin.com/video/" + String(last)
        case .xiaohongshu: return "https://www.xiaohongshu.com/explore/" + last.lowercased()
        case .channels: return nil
        }
    }

    /// New profile links use strict validation; callers may separately retain a legacy grouping
    /// fallback for old stored Douyin links. No nickname-based or cross-platform merging.
    static func profileIdentity(_ value: String) -> String? {
        guard let platform = profilePlatform(value), let c = safeComponents(value),
              let last = c.path.split(separator: "/").last else { return nil }
        switch platform {
        case .douyin: return "https://www.douyin.com/user/" + String(last)
        case .xiaohongshu: return "https://www.xiaohongshu.com/user/profile/" + last.lowercased()
        case .channels: return nil
        }
    }

    private static func hostPlatform(_ host: String?) -> CollectionPlatform? {
        switch host?.lowercased() {
        case "douyin.com", "www.douyin.com": return .douyin
        case "xiaohongshu.com", "www.xiaohongshu.com": return .xiaohongshu
        default: return nil
        }
    }

    private static func safeComponents(_ value: String) -> URLComponents? {
        guard !value.isEmpty, value.utf8.count <= 1600,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !value.contains("\\"), validPercentEscapes(value),
              value.range(of: "^https://(?:www\\.)?(?:douyin\\.com|xiaohongshu\\.com)(?::443)?/",
                          options: [.regularExpression, .caseInsensitive]) != nil,
              let c = URLComponents(string: value), c.url != nil,
              c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              c.port == nil || c.port == 443, c.fragment == nil,
              hostPlatform(c.host) != nil,
              // Reject encoded hosts/paths and ambiguous aliases rather than decoding them into trust.
              c.percentEncodedHost?.lowercased() == c.host?.lowercased(),
              c.percentEncodedPath == c.path else { return nil }
        return c
    }

    private static func validXHSQuery(_ c: URLComponents, allowNoteSource: Bool = false) -> Bool {
        guard c.percentEncodedQuery != nil else { return true }
        guard let items = c.queryItems, !items.isEmpty, items.count <= (allowNoteSource ? 3 : 2) else { return false }
        var seen = Set<String>()
        for item in items {
            guard seen.insert(item.name).inserted,
                  let value = item.value,
                  value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return false }
            switch item.name {
            case "xsec_token": guard !value.isEmpty, value.count <= 1024 else { return false }
            case "xsec_source": guard value.count <= 80 else { return false }
            case "source": guard allowNoteSource && ["web_explore_feed", "web_user_page"].contains(value) else { return false }
            default: return false
            }
        }
        return true
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func validPercentEscapes(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func isHex(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
        var i = 0
        while i < bytes.count {
            if bytes[i] == 37 {
                guard i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) else { return false }
                i += 3
            } else { i += 1 }
        }
        return true
    }
}
/// One canonical tuple for saved comments and resumable scan deduplication.
/// Validation remains the caller's responsibility; invalid URLs are never made trusted here.
/// Original navigation URLs stay in records; only identity drops validated aliases/tokens.
enum CommentIdentity {
    static func fields(sourceURL: String, profileURL: String, commentID: String, text: String) -> [String] {
        func bounded(_ value: String, _ limit: Int) -> String {
            String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
        }
        let rawSource = bounded(sourceURL, 1600), rawProfile = bounded(profileURL, 500)
        let source = CollectionPlatform.sourceIdentity(rawSource) ?? rawSource
        let id = bounded(commentID, 100)
        // With no stable platform id, pair the exact text with a canonical public profile.
        // Names and inferred identity must never merge different people.
        return id.isEmpty ? [source, "fallback", CollectionPlatform.profileIdentity(rawProfile) ?? rawProfile,
                             bounded(text, 6000)] : [source, "id", id]
    }
}
