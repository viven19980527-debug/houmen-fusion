import Foundation

@main
struct FusionBiliChecks {
    enum Failure: Error { case assertion(String) }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try condition() == false { throw Failure.assertion(message) }
    }
    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure.assertion(message)
    }

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = Data("{\"code\":0,\"data\":{\"result\":[]}}".utf8)
        try require(try FusionBiliParsing.videos(FusionBiliParsing.envelope(data), now: now).isEmpty,
                    "valid empty search should remain empty")
        try rejects("malformed JSON must not look like a successful empty result") {
            _ = try FusionBiliParsing.envelope(Data("<html>blocked</html>".utf8))
        }
        try rejects("nonzero business codes must stop") {
            _ = try FusionBiliParsing.envelope(Data("{\"code\":-412,\"data\":{}}".utf8))
        }
        try rejects("missing business code must not imply success") {
            _ = try FusionBiliParsing.envelope(Data("{\"data\":{}}".utf8))
        }
        try rejects("boolean code false must not imply integer 0") {
            _ = try FusionBiliParsing.envelope(Data("{\"code\":false,\"data\":{}}".utf8))
        }
        try rejects("oversized input must stop before JSON decoding") {
            _ = try FusionBiliParsing.envelope(Data(repeating: 32, count: 2 * 1024 * 1024 + 1))
        }

        let key = try FusionBiliParsing.mixinKey(["wbi_img": [
            "img_url": "https://example.invalid/0123456789abcdef0123456789abcdef.png",
            "sub_url": "https://example.invalid/0123456789abcdef0123456789abcdef.png"
        ]])
        try require(key == "ef225870f2afa3d3bb5119a3dce7c69d", "fixture mixin must remain stable")
        let signed = try FusionBiliParsing.signedURL(path: "/x/web-interface/wbi/search/type",
            parameters: ["keyword": "空调 & Hi!'()*", "page": "1"], key: key, timestamp: 1_700_000_000)
        let query = URLComponents(url: signed, resolvingAgainstBaseURL: false)?.percentEncodedQuery ?? ""
        try require(query.hasPrefix("keyword=%E7%A9%BA%E8%B0%83%20%26%20Hi&page=1&wts=1700000000&w_rid="),
                    "the exact encoded query must also be the signed query")
        try require(query.hasSuffix("w_rid=15fdcc20166c55286d878835aaec5bc9"), "independently calculated MD5 fixture differs")
        try require(FusionBiliParsing.allows(signed), "valid signed endpoint allowed")
        for address in ["http://api.bilibili.com/x/web-interface/nav",
                        "https://api.bilibili.com.evil.invalid/x/web-interface/nav",
                        "https://api.bilibili.com:444/x/web-interface/nav",
                        "https://user:secret@api.bilibili.com/x/web-interface/nav",
                        "https://api.bilibili.com/unknown"] {
            try require(!FusionBiliParsing.allows(URL(string: address)!), "unexpected URL accepted")
        }
        let video = FusionBiliVideo(aid: "12", bvid: "BV1234567890", title: "公开内容示例",
                                   publishedAt: "2023-11-14T22:13:20Z")
        let fixture = Data("""
        {"code":0,"data":{"replies":[
          {"rpid":9007199254740993,"mid":42,"ctime":1700000000,
           "content":{"message":"预算有限，想了解方案？"},
           "member":{"mid":"42","uname":"示例昵称","sign":"BIO_MUST_NOT_BE_HARVESTED","avatar":"AVATAR_MUST_NOT_BE_FETCHED"},
           "replies":[{"rpid_str":"9007199254740994","ctime":0,"content":{"message":"有推荐吗？"},"member":{"uname":"示例二"}}]},
          {"rpid_str":"9007199254740993","content":{"message":"duplicate"}}
        ]}}
        """.utf8)
        let comments = try FusionBiliParsing.comments(FusionBiliParsing.envelope(fixture),
            video: video, keyword: "示例", now: now, limit: 100)
        try require(comments.count == 2, "comment-level IDs must deduplicate without author aggregation")
        try require(comments[0].commentID == "9007199254740993", "large numeric ID lost precision")
        try require(comments[0].publishedAt == "2023-11-14T22:13:20Z", "source comment time missing")
        try require(comments[1].publishedAt == nil, "zero/unknown comment time must remain unknown")
        try require(comments[0].sourcePublishedAt == video.publishedAt, "source and comment times must be separate")
        try require(comments[0].collectedAt != comments[0].publishedAt, "collection time must not replace publication time")
        try require(comments[0].profileURL == "https://space.bilibili.com/42", "profile link must be tied to observed numeric uid")
        try require(comments[1].profileURL.isEmpty, "missing uid must not synthesize an identity")
        let encoded = String(data: try JSONEncoder().encode(comments), encoding: .utf8) ?? ""
        try require(!encoded.contains("BIO_MUST_NOT") && !encoded.contains("AVATAR_MUST_NOT"), "private enrichment fields leaked")
        let capped = try FusionBiliParsing.comments(FusionBiliParsing.envelope(fixture), video: video,
            keyword: "示例", now: now, limit: 1)
        try require(capped.count == 1, "requested comment cap must be enforced")
        try rejects("missing replies is a schema failure, not end-of-comments") {
            _ = try FusionBiliParsing.comments([:], video: video, keyword: "示例", now: now, limit: 50)
        }
        try rejects("nonempty but malformed replies must not look like empty success") {
            _ = try FusionBiliParsing.comments(["replies": [["content": ["message": "no ID"]]]],
                video: video, keyword: "示例", now: now, limit: 50)
        }
        let unknownUID = try FusionBiliParsing.comments(["replies": [[
            "rpid_str": "123", "member": ["mid": "123456789012345678901"],
            "content": ["message": "公开评论"]
        ]]], video: video, keyword: "示例", now: now, limit: 50)
        try require(unknownUID[0].profileURL.isEmpty, "overlong UID must not create an unvalidated profile link")
        _ = try unknownUID[0].validated(now: now)
        _ = try comments[1].validated(now: now)
        try require(FusionBiliParsing.isoDate(now.timeIntervalSince1970 + 301, now: now) == nil,
                    "date tolerance must match FusionLead validation")
        try require(FusionBiliParsing.isoDate(nil, now: now) == nil, "missing date synthesized")
        try require(FusionBiliParsing.isoDate(0, now: now) == nil, "epoch 0 synthesized")
        try require(FusionBiliParsing.isoDate(9_999_999_999, now: now) == nil, "future date accepted")
        print("FusionBiliChecks: PASS (offline fixtures only; no live API validation)")
    }
}
