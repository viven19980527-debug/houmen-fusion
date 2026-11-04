import Foundation

/// Standalone: swiftc CollectionPlatform.swift PlatformChecks.swift -o platform-checks
/// Fixtures exercise URL boundaries only, not an authenticated browser or live-platform access.
@main
struct PlatformChecks {
    struct CheckFailure: Error, CustomStringConvertible { let description: String }
    static func main() throws {
        var count = 0
        func check(_ success: Bool, _ label: String) throws {
            guard success else { throw CheckFailure(description: "FAILED: " + label) }
            count += 1
            print("PASS: " + label)
        }
        let note = "68abcdef0123456789abcdef"
        let upperNote = note.uppercased()
        let dy = "https://www.douyin.com/video/1234567890123456789"
        let xhs = "https://www.xiaohongshu.com/explore/" + note
        let xhsProfile = "https://www.xiaohongshu.com/user/profile/" + note
        let dyProfile = "https://www.douyin.com/user/Ab_cd-123.X"

        try check(CollectionPlatform.allCases.count == 3, "exactly three platforms")
        for p in CollectionPlatform.allCases {
            try check(p.id == p.rawValue, "stable platform identifier")
            try check(!p.title.isEmpty && !p.entryLabel.isEmpty, "human platform labels")
            let roundTrip = try JSONDecoder().decode(CollectionPlatform.self, from: JSONEncoder().encode(p))
            try check(roundTrip == p, "Codable round trip")
            try check(p.homeURL.scheme == "https", "official home uses HTTPS")
        }
        try check(CollectionPlatform.douyin.canCollect, "Douyin adapter selectable")
        try check(CollectionPlatform.xiaohongshu.canCollect, "XHS experimental adapter selectable")
        try check(!CollectionPlatform.channels.canCollect, "Channels collection unavailable")
        try check(CollectionPlatform.xiaohongshu.entryLabel == "小红书·测试", "XHS explicitly experimental")
        try check(CollectionPlatform.channels.entryLabel == "视频号·未接通", "Channels explicitly not connected")
        try check(CollectionPlatform.channels.searchURL(keyword: "线阵音响") == nil, "Channels cannot start keyword collection")
        try check(CollectionPlatform.douyin.homeURL.host == "www.douyin.com", "Douyin home host")
        try check(CollectionPlatform.xiaohongshu.homeURL.path == "/explore", "XHS consumer home not creator backend")
        try check(CollectionPlatform.channels.homeURL.host == "channels.weixin.qq.com", "Channels explanatory official entry only")
        for p in [CollectionPlatform.douyin, .xiaohongshu] {
            try check(p.searchURL(keyword: "  ") == nil, "empty keyword rejected")
            try check(p.searchURL(keyword: String(repeating: "a", count: 101)) == nil, "oversize keyword rejected")
            try check(p.searchURL(keyword: "音\n响") == nil, "embedded control keyword rejected")
        }
        let searchDy = CollectionPlatform.douyin.searchURL(keyword: "  线阵/音响?#&=  ")!
        let searchXHS = CollectionPlatform.xiaohongshu.searchURL(keyword: "线阵/音响?#&=")!
        let dySearchParts = URLComponents(url: searchDy, resolvingAgainstBaseURL: false)!
        let xhsSearchParts = URLComponents(url: searchXHS, resolvingAgainstBaseURL: false)!
        try check(dySearchParts.host == "www.douyin.com" && dySearchParts.queryItems == [URLQueryItem(name: "type", value: "video")] && dySearchParts.fragment == nil,
                  "Douyin keyword cannot inject host/query/fragment")
        try check(dySearchParts.percentEncodedPath.contains("%2F") && dySearchParts.percentEncodedPath.contains("%3F"),
                  "Douyin keyword encoded as a single path segment")
        try check(xhsSearchParts.path == "/search_result" && xhsSearchParts.fragment == nil,
                  "XHS keyword stays in search route")
        try check(xhsSearchParts.queryItems?.count == 2 && xhsSearchParts.queryItems?.first?.value == "线阵/音响?#&=",
                  "XHS keyword round trip without query injection")
        try check(xhsSearchParts.queryItems?.last?.value == "web_explore_feed", "XHS official browser source parameter")
        try check(CollectionPlatform.sourcePlatform(searchDy.absoluteString) == nil &&
                  CollectionPlatform.sourcePlatform(searchXHS.absoluteString) == nil, "search pages are not comment sources")

        for u in [dy, dy + "/", "https://douyin.com/video/1234567890123456789",
                  "HTTPS://WWW.DOUYIN.COM:443/video/1234567890123456789"] {
            try check(CollectionPlatform.sourcePlatform(u) == .douyin, "valid Douyin video")
            try check(CollectionPlatform.sourceIdentity(u) == dy, "canonical Douyin preserves existing hash path")
        }
        try check(CollectionPlatform.sourcePlatform("https://www.douyin.com/video/1234567890") == .douyin, "minimum Douyin ID length")
        try check(CollectionPlatform.sourcePlatform("https://www.douyin.com/video/" + String(repeating: "9", count: 30)) == .douyin,
                  "maximum Douyin ID length")
        for route in ["explore", "search_result", "discovery/item"] {
            for u in ["https://www.xiaohongshu.com/\(route)/\(note)",
                      "https://xiaohongshu.com:443/\(route)/\(upperNote)/?xsec_token=fixture-_%2F%3D&xsec_source=pc_comment"] {
                try check(CollectionPlatform.sourcePlatform(u) == .xiaohongshu, "valid XHS note route")
                try check(CollectionPlatform.sourceIdentity(u) == xhs, "XHS route/token/case deduplicate to note identity")
            }
        }
        try check(CollectionPlatform.sourceIdentity(xhs + "?xsec_token=old") ==
                  CollectionPlatform.sourceIdentity(xhs + "?xsec_token=new&xsec_source=pc_search"), "rotating existing tokens never alter note identity")
        try check(CollectionPlatform.sourcePlatform(xhs + "?xsec_token=" + String(repeating: "a", count: 1024)) == .xiaohongshu,
                  "token maximum length accepted")
        try check(CollectionPlatform.sourcePlatform(xhs + "?xsec_source=" + String(repeating: "a", count: 80)) == .xiaohongshu,
                  "source maximum length accepted")
        try check(CollectionPlatform.sourcePlatform(xhs + "?xsec_token=%E9%9F%B3%E5%93%8D%2B%2F%3D") == .xiaohongshu,
                  "valid encoded non-whitespace token text preserved")

        try check(CollectionPlatform.sourcePlatform(xhs + "?xsec_token=fixture&xsec_source=") == .xiaohongshu,
                  "live observed empty optional xsec_source is retained")
        try check(CollectionPlatform.sourcePlatform(xhs + "?xsec_token=fixture&xsec_source=pc_search&source=web_explore_feed") == .xiaohongshu, "observed note redirect source accepted")
        try check(CollectionPlatform.sourceIdentity(xhs + "?source=web_explore_feed") == xhs, "source parameter does not change identity")
        try check(CollectionPlatform.sourcePlatform(xhs + "?xsec_token=fixture&xsec_source=pc_user&source=web_user_page") == .xiaohongshu,
                  "observed public user page note redirect source accepted")
        try check(CollectionPlatform.sourceIdentity(xhs + "?xsec_token=fixture&xsec_source=pc_user&source=web_user_page") == xhs,
                  "user-page note source and navigation fields preserve canonical identity")
        let unsafeSources = [
            xhs + "?source=other", xhs + "?source=", xhs + "?source=web_explore_feed&source=web_explore_feed",
            xhs + "?source=web_user_page_extra", xhs + "?source=web_user_page&source=web_user_page",
            xhs + "?source=web_explore_feed&source=web_user_page",
            "http://www.douyin.com/video/1234567890123456789",
            "https://www.douyin.com.evil.invalid/video/1234567890123456789",
            "https://notdouyin.com/video/1234567890123456789",
            "https://www.douyin.com./video/1234567890123456789",
            "https://www.douyin.com:444/video/1234567890123456789",
            "https://www.douyin.com:/video/1234567890123456789",
            "https://user:secret@www.douyin.com/video/1234567890123456789",
            "https://www.%64ouyin.com/video/1234567890123456789",
            "https://www.douyin.com/video/%311234567890123456789",
            "https://www.douyin.com/video/123456789", "https://www.douyin.com/video/" + String(repeating: "1", count: 31),
            "https://www.douyin.com/video/123456789a", dy + "?from=video", dy + "?", dy + "#", dy + "#comments",
            "https://www.douyin.com/video/1234567890123456789/../1234567890123456789",
            "https://www.douyin.com\\@evil.invalid/video/1234567890123456789",
            " " + dy, dy + "\n", dy + "\u{0000}",
            "https://xiaohongshu.com.evil.invalid/explore/" + note,
            "https://www.xiaohongshu.com:4430/explore/" + note,
            "https://user@www.xiaohongshu.com/explore/" + note,
            "https://www.xiaohongshu.com/video/" + note,
            "https://www.douyin.com/explore/" + note,
            "https://www.xiaohongshu.com/explore/" + String(note.dropLast()),
            "https://www.xiaohongshu.com/explore/" + note + "f",
            "https://www.xiaohongshu.com/explore/" + String(repeating: "g", count: 24),
            xhs + "?foo=bar", xhs + "?keyword=audio", xhs + "?xsec_token=", xhs + "?xsec_token",
            xhs + "?", xhs + "#comments", xhs + "#",
            xhs + "?xsec_token=one&xsec_token=two", xhs + "?xsec_source=a&xsec_source=b",
            xhs + "?xsec_token=a&xsec%5ftoken=b", xhs + "?xsec_token=a&xsec_source=b&extra=c",
            xhs + "?xsec_token=a%20b", xhs + "?xsec_token=a%0Ab", xhs + "?xsec_token=a%00b",
            xhs + "?xsec_token=a%7Fb", xhs + "?xsec_token=a%E3%80%80b",
            xhs + "?xsec_token=%", xhs + "?xsec_token=%ZZ", xhs + "?xsec_token=%2",
            xhs + "?xsec_token=" + String(repeating: "a", count: 1025),
            xhs + "?xsec_source=" + String(repeating: "a", count: 81),
            // Only 600 decoded characters, but the full URL exceeds the hard 1,600-byte boundary.
            xhs + "?xsec_token=" + String(repeating: "%41", count: 600),
            "https://channels.weixin.qq.com/video/1234567890123456789", "weixin://channels",
            "file:///video/1234567890123456789", "javascript:alert(1)"
        ]
        for u in unsafeSources {
            try check(CollectionPlatform.sourcePlatform(u) == nil, "unsafe source rejected: " + String(u.prefix(90)))
            try check(CollectionPlatform.sourceIdentity(u) == nil, "unsafe source has no identity")
        }

        for u in [dyProfile, "https://douyin.com:443/user/Ab_cd-123.X/"] {
            try check(CollectionPlatform.profilePlatform(u) == .douyin, "valid Douyin profile")
            try check(CollectionPlatform.profileIdentity(u) == dyProfile, "Douyin profile case remains significant")
        }
        for u in [xhsProfile, "https://xiaohongshu.com/user/profile/" + upperNote + "/?xsec_token=existing&xsec_source=pc_comment"] {
            try check(CollectionPlatform.profilePlatform(u) == .xiaohongshu, "safe XHS profile query accepted")
            try check(CollectionPlatform.profileIdentity(u) == xhsProfile, "canonical profile strips existing token")
        }
        for u in [dy, xhs, dyProfile + "?from=video", dyProfile + "#fragment",
                  "https://www.douyin.com/user/abc", "https://www.douyin.com/user/" + String(repeating: "a", count: 201),
                  "https://www.douyin.com/user/%41b_cd-123.X", "https://www.douyin.com.evil.invalid/user/Ab_cd-123.X",
                  "https://user:secret@www.xiaohongshu.com/user/profile/" + note,
                  "https://www.xiaohongshu.com/user/profile/" + String(repeating: "g", count: 24),
                  xhsProfile + "?source=web_explore_feed", xhsProfile + "?source=web_user_page", xhsProfile + "?unknown=1", xhsProfile + "#", xhsProfile + "?xsec_token=a&xsec_token=b",
                  xhsProfile + "?xsec_token=%0D", "https://channels.weixin.qq.com/user/profile/" + note] {
            try check(CollectionPlatform.profilePlatform(u) == nil, "unsafe/non-profile rejected")
            try check(CollectionPlatform.profileIdentity(u) == nil, "unsafe profile has no identity")
        }
        try check(CollectionPlatform.sourcePlatform(dy) != CollectionPlatform.profilePlatform(xhsProfile),
                  "platform pairing detects cross-platform author/source")
        try check(CollectionPlatform.sourcePlatform(xhs) == CollectionPlatform.profilePlatform(xhsProfile),
                  "same-platform author/source pairing")
        print("PASS: \(count) Foundation platform URL checks; no live browser/device test performed")
    }
}