import Foundation

/// Navigation gating only; does not fetch content or bypass platform login/CAPTCHA.
/// A rejected auxiliary request must never cancel the collection of the visible main document.
enum NavigationPolicy {
    enum Effect: String { case allow, cancel, cancelAndPause }
    enum Frame: String {
        case main, subframe, newWindow
        init(targetIsMainFrame: Bool?) {
            if let targetIsMainFrame {
                self = targetIsMainFrame ? .main : .subframe
            } else {
                self = .newWindow
            }
        }
    }

    struct Decision: Equatable {
        let effect: Effect
        let frame: Frame
        let reason: String
        let scheme: String
        let host: String
        let pauseMessage: String?

        /// Deliberately excludes path, user/password, query, fragment and the original URL.
        var diagnosticLine: String {
            "frame=\(frame.rawValue) effect=\(effect.rawValue) scheme=\(scheme) host=\(host) reason=\(reason)"
        }
    }

    static func isSupportedMainURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), !host.isEmpty else { return false }
        guard host == "douyin.com" || host.hasSuffix(".douyin.com") || ["xiaohongshu.com", "www.xiaohongshu.com"].contains(host) else { return false }
        // Reject empty labels, misleading suffixes, encoded separators and malformed hosts.
        return host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.allSatisfy { character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            }
        }
    }

    /// Replace an observed same-site top-level HTTP GET with HTTPS; never permit the HTTP
    /// request itself. The caller owns a bounded retry budget and cancels the original action.
    static func upgradedMainRequestURL(url: URL?, method: String?, targetIsMainFrame: Bool?,
                                       currentMainURL: URL?) -> URL? {
        guard targetIsMainFrame == true, method == "GET", let url, let currentMainURL,
              isSupportedMainURL(currentMainURL), url.scheme?.lowercased() == "http",
              url.user == nil, url.password == nil, url.port == nil || url.port == 80,
              let host = url.host?.lowercased(), let currentHost = currentMainURL.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let current = URLComponents(url: currentMainURL, resolvingAgainstBaseURL: false),
              components.percentEncodedHost?.lowercased() == host,
              current.percentEncodedHost?.lowercased() == currentHost else { return nil }
        // Disallow encoded control characters/backslashes as well as their literal forms.
        let inspected = [url.absoluteString, components.path, components.query ?? "", components.fragment ?? ""]
        guard inspected.allSatisfy({ !$0.contains("\\") && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else { return nil }
        let xhsHosts = ["xiaohongshu.com", "www.xiaohongshu.com"]
        let sameXHS = xhsHosts.contains(host) && xhsHosts.contains(currentHost)
        let sameDouyin = host == currentHost && (host == "douyin.com" || host.hasSuffix(".douyin.com"))
        guard sameXHS || sameDouyin else { return nil }
        let path = components.percentEncodedPath, query = components.percentEncodedQuery
        components.scheme = "https"
        components.port = nil // HTTPS default (443), never carry HTTP port 80 into HTTPS.
        guard components.percentEncodedPath == path, components.percentEncodedQuery == query,
              let upgraded = components.url, isSupportedMainURL(upgraded) else { return nil }
        return upgraded
    }

    /// A permitted host is not proof that the requested document was loaded. Compare the
    /// platform-specific destination, retaining only identity (not expiring navigation tokens).
    static func matchesDestination(requested: URL, actual: URL?) -> Bool {
        guard isSupportedMainURL(requested), isSupportedMainURL(actual), let actual,
              let requestedComponents = URLComponents(url: requested, resolvingAgainstBaseURL: false),
              let actualComponents = URLComponents(url: actual, resolvingAgainstBaseURL: false),
              let requestedHost = requested.host?.lowercased(), let actualHost = actual.host?.lowercased()
        else { return false }
        func platform(_ host: String) -> String {
            host == "douyin.com" || host.hasSuffix(".douyin.com") ? "douyin.com" : "xiaohongshu.com"
        }
        let requestedPlatform = platform(requestedHost)
        guard requestedPlatform == platform(actualHost) else { return false }
        func canonicalHost(_ host: String) -> String {
            host == "www." + requestedPlatform ? requestedPlatform : host
        }
        // Only the root/www pair is an alias; a passport or other subdomain is not the target.
        guard canonicalHost(requestedHost) == canonicalHost(actualHost),
              let expected = destination(requestedComponents, platform: requestedPlatform),
              let received = destination(actualComponents, platform: requestedPlatform) else { return false }
        return expected == received
    }

    private enum Destination: Equatable {
        case source(String), profile(String), search(String), page(String)
    }

    private static func destination(_ components: URLComponents, platform: String) -> Destination? {
        let path = components.path
        func matches(_ pattern: String) -> Bool {
            path.range(of: pattern, options: .regularExpression) != nil
        }
        func validKeyword(_ word: String) -> Bool {
            !word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                word.rangeOfCharacter(from: .controlCharacters) == nil
        }
        if platform == "douyin.com" {
            if path == "/search" || path.hasPrefix("/search/") {
                // Check the encoded shape first: an encoded slash may be part of one keyword,
                // while an extra literal path segment must never be treated as that keyword.
                let encoded = components.percentEncodedPath
                guard encoded.hasPrefix("/search/") else { return nil }
                let tail = String(encoded.dropFirst("/search/".count))
                guard !tail.isEmpty, !tail.contains("/") else { return nil }
                let word = String(path.dropFirst("/search/".count)) // URLComponents decoded once.
                return validKeyword(word) ? .search(word) : nil
            }
            if matches("^/video/[0-9]{10,30}/?$") && components.percentEncodedPath == path {
                return .source(String(path.split(separator: "/").last!))
            }
            if matches("^/user/[A-Za-z0-9_.-]{4,200}/?$") && components.percentEncodedPath == path {
                return .profile(String(path.split(separator: "/").last!))
            }
        } else {
            if ["/search_result", "/search_result/", "/search_result_ai", "/search_result_ai/"].contains(path) {
                guard components.percentEncodedPath == path else { return nil }
                let items = components.queryItems?.filter { $0.name == "keyword" } ?? []
                guard items.count == 1, let word = items[0].value, validKeyword(word) else { return nil }
                return .search(word) // queryItems decodes once; never removingPercentEncoding again.
            }
            if matches("^/(?:explore|search_result|discovery/item)/[0-9a-fA-F]{24}/?$") && components.percentEncodedPath == path {
                return .source(String(path.split(separator: "/").last!).lowercased())
            }
            if matches("^/user/profile/[0-9a-fA-F]{24}/?$") && components.percentEncodedPath == path {
                return .profile(String(path.split(separator: "/").last!).lowercased())
            }
        }
        if platform == "xiaohongshu.com" &&
            (path.hasPrefix("/search_result/") || path.hasPrefix("/search_result_ai/")) { return nil }
        // Unrecognised pages (including the homepage) are never aliases for search/source/profile.
        // Preserve the encoded path so that encoded separators do not gain another decoding pass.
        return .page(components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
    }

    static func decideAction(url: URL?, targetIsMainFrame: Bool?, currentMainURL: URL?) -> Decision {
        let frame = Frame(targetIsMainFrame: targetIsMainFrame)
        // nil targetFrame denotes a separate window, not the current main document.
        if frame == .newWindow {
            return make(.cancel, frame, url, "new_window_blocked")
        }
        guard let url else {
            return frame == .main && !isSupportedMainURL(currentMainURL)
                ? make(.cancelAndPause, frame, nil, "missing_main_url",
                       "网页导航地址无效，采集已暂停。")
                : make(.cancel, frame, nil, "missing_auxiliary_url")
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if frame == .subframe {
            if scheme == "https", url.user == nil, url.password == nil,
               let host = url.host, !host.isEmpty {
                // Login/verification frames may be cross-origin. Native collection still reads
                // only the supported main document, with no native bridge exposed to frames.
                return make(.allow, frame, url, "https_subframe")
            }
            let blankURL = url.absoluteString.lowercased().split(separator: "#", maxSplits: 1).first.map(String.init)
            if blankURL == "about:blank" || blankURL == "about:srcdoc" {
                return make(.allow, frame, url, "blank_subframe")
            }
            return make(.cancel, frame, url, "auxiliary_scheme_blocked")
        }
        if isSupportedMainURL(url) {
            return make(.allow, frame, url, "supported_main_document")
        }
        if scheme == "http" || scheme == "https" {
            return make(.cancelAndPause, frame, url, "unsupported_main_web_destination",
                        "主页面超出支持的平台HTTPS范围，已停止；未绕过平台限制。")
        }
        // A site may probe an App URL scheme while a valid HTTPS document remains visible.
        // Block the handoff, never open another App, and leave that document's task alone.
        if isSupportedMainURL(currentMainURL) {
            return make(.cancel, frame, url, "non_web_handoff_blocked")
        }
        return make(.cancelAndPause, frame, url, "no_supported_main_document",
                    "未打开受支持的平台HTTPS网页，采集已暂停。")
    }

    static func decideResponse(url: URL?, isMainFrame: Bool, httpStatus: Int?) -> Decision {
        let frame: Frame = isMainFrame ? .main : .subframe
        guard isMainFrame else {
            // A failed optional iframe is not a failed main document.
            return make(.allow, frame, url, "auxiliary_response")
        }
        guard isSupportedMainURL(url) else {
            return make(.cancelAndPause, frame, url, "unsupported_main_response",
                        "主页面响应超出支持范围，采集已停止。")
        }
        if let httpStatus, httpStatus >= 400 {
            return make(.cancelAndPause, frame, url, "main_http_\(httpStatus)",
                        "平台返回HTTP \(httpStatus)，任务停止，没有绕过访问限制。")
        }
        return make(.allow, frame, url, "supported_main_response")
    }

    private static func make(_ effect: Effect, _ frame: Frame, _ url: URL?,
                             _ reason: String, _ message: String? = nil) -> Decision {
        Decision(effect: effect, frame: frame, reason: reason,
                 scheme: clean(url?.scheme, limit: 40), host: clean(url?.host, limit: 255),
                 pauseMessage: message)
    }

    private static func clean(_ value: String?, limit: Int) -> String {
        guard let value, !value.isEmpty else { return "-" }
        return String(value.lowercased().filter { character in
            character.isASCII && (character.isLetter || character.isNumber ||
                                  character == "." || character == "-" || character == ":")
        }.prefix(limit))
    }
}
