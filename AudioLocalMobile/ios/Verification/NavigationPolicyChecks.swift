import Foundation

@main
struct NavigationPolicyChecks {
    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw CheckFailure(description: "FAILED: " + label) }
            checks += 1
            print("PASS: " + label)
        }
        func expect(_ raw: String?, _ main: Bool?, _ effect: NavigationPolicy.Effect,
                    _ label: String, current: String? = "https://www.douyin.com/search/audio") throws {
            let decision = NavigationPolicy.decideAction(
                url: raw.flatMap { URL(string: $0) }, targetIsMainFrame: main,
                currentMainURL: current.flatMap { URL(string: $0) })
            try check(decision.effect == effect, label)
            try check((decision.pauseMessage != nil) == (effect == .cancelAndPause), label + " pause semantics")
        }

        for url in ["https://douyin.com/", "https://www.douyin.com/search/audio",
                    "https://www.douyin.com:443/video/1234567890123456789",
                    "HTTPS://WWW.DOUYIN.COM/", "https://passport.douyin.com/login"] {
            try expect(url, true, .allow, "supported main HTTPS")
        }
        for url in ["https://douyin.com.evil.invalid/", "https://notdouyin.com/",
                    "https://www.douyin.com:444/", "https://user:secret@www.douyin.com/",
                    "http://www.douyin.com/", "http://example.invalid/",
                    "https://.douyin.com/", "https://bad..douyin.com/"] {
            try expect(url, true, .cancelAndPause, "unsupported main web destination")
        }
        for url in ["about:blank", "about:blank#fragment", "about:srcdoc"] {
            try expect(url, false, .allow, "blank subframe preserves main task")
        }
        for url in ["https://www.douyin.com/frame", "https://verification.example.invalid/frame"] {
            try expect(url, false, .allow, "HTTPS subframe remains available")
        }
        for url in ["snssdk1128://aweme/detail/fixture", "intent://fixture",
                    "javascript:alert(1)", "data:text/html,fixture", "file:///fixture",
                    "http://example.invalid/frame", "about:config", "about:blank?unexpected",
                    "https://user:password@example.invalid/frame"] {
            try expect(url, false, .cancel, "unsafe subframe blocked without task cancellation")
        }
        for url in ["snssdk1128://aweme/detail/fixture", "about:blank", "javascript:alert(1)",
                    "data:text/html,fixture", "file:///fixture"] {
            try expect(url, true, .cancel, "handoff blocked while supported document stays visible")
            try expect(url, true, .cancelAndPause, "handoff without supported document pauses", current: nil)
        }
        for url in ["https://www.douyin.com/", "https://example.invalid/",
                    "http://example.invalid/", "snssdk1128://fixture", "about:blank"] {
            try expect(url, nil, .cancel, "new window does not replace or cancel main task")
        }
        try expect(nil, nil, .cancel, "missing popup URL")
        try expect(nil, false, .cancel, "missing subframe URL")
        try expect(nil, true, .cancel, "missing request while supported document remains")
        try expect(nil, true, .cancelAndPause, "missing initial main request", current: nil)
        try check(NavigationPolicy.Frame(targetIsMainFrame: nil) == .newWindow, "nil target is separate window")

        let mainURL = URL(string: "https://www.douyin.com/video/1234567890123456789")!
        for status in [400, 401, 403, 404, 429, 451, 500] {
            let main = NavigationPolicy.decideResponse(url: mainURL, isMainFrame: true, httpStatus: status)
            let child = NavigationPolicy.decideResponse(url: mainURL, isMainFrame: false, httpStatus: status)
            try check(main.effect == .cancelAndPause, "main HTTP error still stops")
            try check(child.effect == .allow, "optional iframe HTTP error does not stop main task")
        }
        for status in [200, 204, 302] {
            try check(NavigationPolicy.decideResponse(url: mainURL, isMainFrame: true, httpStatus: status).effect == .allow,
                      "supported successful main response")
        }
        try check(NavigationPolicy.decideResponse(url: URL(string: "https://example.invalid/"),
                    isMainFrame: true, httpStatus: 200).effect == .cancelAndPause, "external main response blocked")
        try check(NavigationPolicy.decideResponse(url: nil,
                    isMainFrame: true, httpStatus: nil).effect == .cancelAndPause, "unknown main response blocked")

        func upgraded(_ raw: String?, method: String? = "GET", main: Bool? = true,
                      current: String? = "https://www.xiaohongshu.com/search_result?keyword=fixture") -> URL? {
            NavigationPolicy.upgradedMainRequestURL(url: raw.flatMap { URL(string: $0) }, method: method,
                targetIsMainFrame: main, currentMainURL: current.flatMap { URL(string: $0) })
        }
        let insecureXHS = "http://www.xiaohongshu.com/search_result?keyword=%E9%9F%B3%E5%93%8D&source=web_explore_feed"
        try check(upgraded(insecureXHS)?.absoluteString == insecureXHS.replacingOccurrences(of: "http://", with: "https://"),
                  "observed XHS main HTTP GET becomes same HTTPS destination")
        try check(upgraded("http://xiaohongshu.com:80/explore")?.absoluteString == "https://xiaohongshu.com/explore",
                  "root/www XHS alias upgrade removes HTTP port 80")
        let escaped = "http://www.xiaohongshu.com/search_result?keyword=%252F%2B%20&xsec_token=Ab%2fCD%3D%3D"
        let escapedResult = upgraded(escaped).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let escapedOriginal = URLComponents(string: escaped)!
        try check(escapedResult?.percentEncodedQuery == escapedOriginal.percentEncodedQuery, "upgrade preserves exact percent-encoded query")
        let escapedPath = "http://www.xiaohongshu.com/search_result/%E9%9F%B3%E5%93%8D?keyword=%252F"
        try check(upgraded(escapedPath).flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.percentEncodedPath ==
                  URLComponents(string: escapedPath)?.percentEncodedPath, "upgrade preserves percent-encoded path")
        try check(upgraded("http://www.douyin.com/search/fixture", current: "https://www.douyin.com/")?.absoluteString ==
                  "https://www.douyin.com/search/fixture", "same approved exact Douyin host upgrades")
        try check(upgraded("http://passport.douyin.com/login", current: "https://passport.douyin.com/login")?.scheme == "https",
                  "already approved exact Douyin subdomain remains same host")
        for method in ["HEAD", "POST", "PUT", "DELETE", "get", " GET", ""] {
            try check(upgraded(insecureXHS, method: method) == nil, "only explicit GET may be upgraded")
        }
        try check(upgraded(insecureXHS, method: nil) == nil, "missing method never assumed GET")
        try check(upgraded(insecureXHS, main: false) == nil, "HTTP subframe never upgraded by main rule")
        try check(upgraded(insecureXHS, main: nil) == nil, "HTTP popup never upgraded by main rule")
        for raw in ["http://www.xiaohongshu.com:443/explore", "http://www.xiaohongshu.com:8080/explore",
                    "http://user:secret@www.xiaohongshu.com/explore", "http://@www.xiaohongshu.com/explore",
                    "http://www.xiaohongshu.com.evil.invalid/explore", "http://other.invalid/explore",
                    "http://www.douyin.com/", "http://passport.xiaohongshu.com/login",
                    "https://www.xiaohongshu.com/explore", "xhsdiscover://explore", "about:blank",
                    "http://www.xiaohongshu.com/explore%0A", "http://www.xiaohongshu.com/explore?keyword=%0D",
                    "http://www.xiaohongshu.com/explore#%09", "http://www.xiaohongshu.com/explore%5Cfoo",
                    "http://www.xiaohongshu.com/explore?keyword=%5c", "http://%77ww.xiaohongshu.com/explore"] {
            try check(upgraded(raw) == nil, "unsafe, cross-site or non-HTTP request not upgraded")
        }
        try check(upgraded(nil) == nil, "missing upgrade URL rejected")
        for current in ["http://www.xiaohongshu.com/", "https://other.invalid/", "https://user:secret@www.xiaohongshu.com/",
                        "https://www.xiaohongshu.com:444/", "https://%77ww.xiaohongshu.com/"] {
            try check(upgraded(insecureXHS, current: current) == nil, "upgrade needs approved current HTTPS page")
        }
        try check(upgraded(insecureXHS, current: nil) == nil, "no current supported HTTPS page means no upgrade")
        try check(upgraded("http://passport.douyin.com/login", current: "https://www.douyin.com/") == nil,
                  "upgrade cannot change Douyin host")
        try check(upgraded("http://douyin.com/", current: "https://www.douyin.com/") == nil,
                  "Douyin upgrade requires exact current host, not root/www expansion")
        try expect(insecureXHS, true, .cancelAndPause, "HTTP remains denied by original navigation policy")

        func destination(_ requested: String, _ actual: String?, _ expected: Bool, _ label: String) throws {
            try check(NavigationPolicy.matchesDestination(requested: URL(string: requested)!,
                actual: actual.flatMap { URL(string: $0) }) == expected, label)
        }
        let dySource = "https://www.douyin.com/video/1234567890123456789"
        let xhsID = "6a112233445566778899aabb", xhsOther = "6a112233445566778899aabc"
        let xhsSource = "https://www.xiaohongshu.com/explore/" + xhsID
        try destination(dySource, nil, false, "missing actual document is not success")
        try destination(dySource, "https://douyin.com:443/video/1234567890123456789/", true, "Douyin canonical source root/www alias")
        try destination(dySource, dySource + "?tracking=fixture", true, "source identity ignores navigation query")
        try destination(dySource, "https://www.douyin.com/video/1234567890123456780", false, "another video is not success")
        try destination(dySource, "https://www.douyin.com/", false, "homepage is not requested video")
        try destination(dySource, "https://passport.douyin.com/video/1234567890123456789", false, "unrelated subdomain is not source alias")
        try destination(dySource, "https://www.douyin.com/video/%31234567890123456789", false, "encoded source id is not canonical identity")
        try destination("https://www.douyin.com/user/fixture-User_123", "https://douyin.com/user/fixture-User_123/", true, "Douyin profile canonical alias")
        try destination("https://www.douyin.com/user/fixture-User_123", "https://douyin.com/user/fixture-user_123", false, "Douyin profile id remains case sensitive")
        try destination(dySource, xhsSource, false, "cross-platform page is not success")
        for path in ["/explore/", "/search_result/", "/discovery/item/"] {
            try destination(xhsSource, "https://xiaohongshu.com" + path + xhsID.uppercased() + "/?xsec_token=fixture", true,
                            "XHS same source id across observed route aliases")
            try destination(xhsSource, "https://www.xiaohongshu.com" + path + xhsOther, false,
                            "XHS different note is not requested source")
        }
        try destination("https://www.xiaohongshu.com/user/profile/" + xhsID,
                        "https://xiaohongshu.com/user/profile/" + xhsID.uppercased() + "?xsec_source=fixture", true,
                        "XHS same public profile identity")
        try destination("https://www.xiaohongshu.com/user/profile/" + xhsID,
                        "https://xiaohongshu.com/user/profile/" + xhsOther, false, "XHS different public profile rejected")
        try destination(xhsSource, "https://www.xiaohongshu.com/user/profile/" + xhsID, false,
                        "profile and note with same id are distinct destinations")

        let xhsSearch = "https://www.xiaohongshu.com/search_result?keyword=%E9%9F%B3%E5%93%8D&source=web_explore_feed"
        try destination(xhsSearch, "https://xiaohongshu.com/search_result_ai?keyword=音响", true, "XHS AI search route keeps once-decoded keyword")
        try destination(xhsSearch, "https://www.xiaohongshu.com/search_result?keyword=话筒", false, "different keyword is not success")
        try destination(xhsSearch, "https://www.xiaohongshu.com/search_result_ai", false, "missing keyword is not success")
        try destination(xhsSearch, "https://www.xiaohongshu.com/search_result_ai/?keyword=音响", true, "search trailing slash still checks keyword")
        try destination("https://www.xiaohongshu.com/search_result_ai/", "https://www.xiaohongshu.com/search_result_ai/", false,
                        "search trailing slash cannot bypass missing keyword check")
        try destination("https://www.xiaohongshu.com/search_result_ai/?keyword=音响",
                        "https://www.xiaohongshu.com/search_result_ai/?keyword=话筒", false, "search trailing slash cannot bypass different keyword check")
        try destination("https://www.xiaohongshu.com/search_result_ai/unknown?keyword=音响",
                        "https://www.xiaohongshu.com/search_result_ai/unknown?keyword=话筒", false, "unrecognised search subroute fails closed")
        try destination(xhsSearch, "https://www.xiaohongshu.com/search_result?keyword=", false, "empty keyword is not success")
        try destination(xhsSearch, "https://www.xiaohongshu.com/search_result?keyword=音响&keyword=音响", false, "duplicate keyword is ambiguous")
        try destination(xhsSearch, "https://www.xiaohongshu.com/search_result?keyword=%25E9%259F%25B3%25E5%2593%258D", false,
                        "XHS double encoding cannot masquerade as same keyword")
        try destination("https://www.xiaohongshu.com/search_result?keyword=%252F",
                        "https://www.xiaohongshu.com/search_result_ai?keyword=%2F", false, "literal escape and decoded slash are different keywords")
        try destination("https://www.xiaohongshu.com/search_result?keyword=a%2Bb",
                        "https://www.xiaohongshu.com/search_result_ai?keyword=a+b", true, "URLComponents preserves literal plus, not form decoding")
        try destination("https://www.xiaohongshu.com/search_result?keyword=%20", "https://www.xiaohongshu.com/search_result?keyword=%20", false,
                        "blank keyword rejected even when URLs equal")
        try destination("https://www.douyin.com/search/%E9%9F%B3%E5%93%8D?type=video",
                        "https://douyin.com/search/音响", true, "Douyin once-decoded keyword matches")
        try destination("https://www.douyin.com/search/音响", "https://www.douyin.com/search/话筒", false, "Douyin different search rejected")
        try destination("https://www.douyin.com/search/音响", "https://www.douyin.com/search/%25E9%259F%25B3%25E5%2593%258D", false,
                        "Douyin search is not decoded twice")
        try destination("https://www.douyin.com/search/a%2Fb", "https://www.douyin.com/search/a/b", false, "literal slash is not encoded keyword segment")
        try destination("https://www.douyin.com/search/a%2Fb", "https://douyin.com/search/a%2fb", true, "encoded slash remains one decoded keyword")
        for missing in ["https://www.douyin.com/search", "https://www.douyin.com/search/"] {
            try destination(missing, missing, false, "missing Douyin keyword rejected even for equal URL")
        }
        for invalid in ["http://www.xiaohongshu.com/explore/" + xhsID,
                        "https://user:secret@www.xiaohongshu.com/explore/" + xhsID,
                        "https://www.xiaohongshu.com:444/explore/" + xhsID,
                        "https://www.xiaohongshu.com.evil.invalid/explore/" + xhsID] {
            try destination(xhsSource, invalid, false, "unsupported actual URL cannot match")
            try destination(invalid, xhsSource, false, "unsupported requested URL cannot match")
        }
        try destination("https://xiaohongshu.com/explore", "https://www.xiaohongshu.com/explore", true, "homepage root/www aliases and same path")
        try destination("https://www.xiaohongshu.com/explore", "https://www.xiaohongshu.com/login", false, "different homepage path rejected")
        try destination("https://www.douyin.com", "https://douyin.com/", true, "empty homepage path and slash canonicalise")
        try destination("https://passport.douyin.com/login", "https://passport.douyin.com/login", true, "other supported page must keep exact host and path")
        try destination("https://passport.douyin.com/login", "https://www.douyin.com/login", false, "passport is not www alias")

        let diagnostic = NavigationPolicy.decideAction(
            url: URL(string: "https://private-user:private-password@www.douyin.com/private-path?token=PRIVATE_TOKEN#PRIVATE_FRAGMENT"),
            targetIsMainFrame: true, currentMainURL: mainURL).diagnosticLine
        for value in ["private-user", "private-password", "private-path", "PRIVATE_TOKEN",
                      "PRIVATE_FRAGMENT", "token=", "@", "?", "#"] {
            try check(!diagnostic.contains(value), "diagnostic excludes sensitive URL components")
        }
        try check(diagnostic.contains("host=www.douyin.com") && diagnostic.contains("scheme=https"),
                  "diagnostic keeps only scheme/host/reason/frame")
        print("PASS: \(checks) native Swift navigation-policy checks; no WebKit/device/live-platform test performed")
    }
}
