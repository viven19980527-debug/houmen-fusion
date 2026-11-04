import Foundation

/// Lifecycle of one bounded main-document request. The caller registers only navigation
/// objects belonging to this operation; callbacks alone must not register unknown tokens.
/// Times are monotonic ProcessInfo.systemUptime values, never wall-clock dates.
struct NavigationLoadState {
    enum Outcome: Equatable {
        case pending
        case succeeded
        case failed(Failure)
    }

    struct Failure: Equatable {
        enum Kind: String {
            case network, policyInterruption, invalidDocument, policyRejected, timedOut
        }
        let kind: Kind
        let domain: String
        let code: Int
        let reason: String

        var diagnosticLine: String {
            "load=failed kind=\(kind.rawValue) domain=\(domain) code=\(code) reason=\(reason)"
        }
        var userMessage: String {
            switch kind {
            case .network:
                return "网页加载失败（\(domain) / \(code)），已保留断点；请检查网络或平台登录。"
            case .policyInterruption:
                return "网页跳转被中断（WebKitErrorDomain / 102），未确认目标页面；已保留断点。"
            case .invalidDocument:
                return "未确认本次目标网页已加载，未读取旧页面或空白页；已保留断点。"
            case .policyRejected:
                return "主网页导航被安全检查拒绝，未重试或绕过平台限制。"
            case .timedOut:
                return "网页导航限时内未完成，已保留断点；没有把空白页记为成功。"
            }
        }

        static func network(_ error: NSError) -> Failure {
            let allowedDomains = [NSURLErrorDomain, "WebKitErrorDomain", "WKErrorDomain"]
            return Failure(kind: .network, domain: allowedDomains.contains(error.domain) ? error.domain : "other",
                           code: error.code, reason: "main_navigation_failure")
        }
    }

    private enum Interruption: Equatable {
        case cancellation(at: TimeInterval)
        case policy(at: TimeInterval)
        var at: TimeInterval {
            switch self {
            case .cancellation(let at), .policy(let at): return at
            }
        }
    }

    let id = UUID()
    let requestedURL: URL
    let deadline: TimeInterval
    private(set) var activeToken: UUID?
    private(set) var outcome: Outcome = .pending
    private(set) var retryCount = 0
    private var retiredTokens = Set<UUID>()
    private var committedToken: UUID?
    private var interruption: Interruption?
    private var benignMainCancellationAt: TimeInterval?

    init(requestedURL: URL, startedAt: TimeInterval, timeout: TimeInterval) {
        self.requestedURL = requestedURL
        // Invalid time inputs fail closed rather than creating an unbounded wait.
        let duration = timeout.isFinite ? min(120, max(0, timeout)) : 0
        let end = startedAt + duration
        deadline = startedAt.isFinite && end.isFinite ? end : 0
    }

    /// Registers the initial request or a verified same-operation successor.
    /// Repeated/retired navigation objects cannot reset state or extend the deadline.
    @discardableResult
    mutating func begin(token: UUID, at: TimeInterval) -> Bool {
        expire(at: at)
        guard outcome == .pending, activeToken != token, !retiredTokens.contains(token) else { return false }
        if let activeToken { retiredTokens.insert(activeToken) }
        activeToken = token
        committedToken = nil
        interruption = nil
        benignMainCancellationAt = nil
        return true
    }

    mutating func commit(token: UUID, at: TimeInterval) {
        expire(at: at)
        guard outcome == .pending, activeToken == token, interruption == nil else { return }
        committedToken = token
    }

    /// validDocument is supplied only after validating the current document against the
    /// requested search keyword, note/video id, or profile id. A host match is insufficient.
    mutating func finish(token: UUID, validDocument: Bool, at: TimeInterval) {
        expire(at: at)
        guard outcome == .pending, activeToken == token, interruption == nil else { return }
        guard committedToken == token, validDocument else {
            outcome = .failed(Failure(kind: .invalidDocument, domain: "navigation", code: 0,
                                      reason: "requested_document_not_confirmed"))
            return
        }
        outcome = .succeeded
    }

    /// Called only for a known benign current-main cancellation: a blocked App handoff,
    /// or an explicitly queued same-site HTTP-to-HTTPS replacement. This never permits
    /// HTTP navigation. Popup/subframe/HTTP response errors must not call this method.
    mutating func recordBenignMainCancellation(token: UUID, at: TimeInterval) {
        expire(at: at)
        guard outcome == .pending, activeToken == token, interruption == nil else { return }
        benignMainCancellationAt = at
    }

    mutating func fail(token: UUID, error: NSError, at: TimeInterval) {
        expire(at: at)
        guard outcome == .pending, activeToken == token else { return }
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            if interruption == nil { interruption = .cancellation(at: at) }
            committedToken = nil
            return
        }
        if error.domain == "WebKitErrorDomain" && error.code == 102 {
            // Do not treat unrelated WebKit 102 failures as benign. Correlate the event
            // with this exact attempt's recent, explicit main-frame handoff rejection.
            if let cancellationAt = benignMainCancellationAt,
               at >= cancellationAt, at - cancellationAt <= 5 {
                if interruption == nil { interruption = .policy(at: at) }
                committedToken = nil
                benignMainCancellationAt = nil
                return
            }
            // Duplicate callbacks for an already-correlated policy failure do not replace it.
            if case .policy? = interruption { return }
            outcome = .failed(Failure(kind: .policyInterruption, domain: "WebKitErrorDomain", code: 102,
                                      reason: "uncorrelated_policy_interruption"))
            return
        }
        outcome = .failed(Failure.network(error))
    }

    /// Terminal policy failure: a later 102/-999 or replacement navigation may not erase it.
    mutating func rejectPolicy(reason: String, at: TimeInterval) {
        expire(at: at)
        guard outcome == .pending else { return }
        let reasons: Set<String> = ["missing_main_url", "unsupported_main_web_destination",
            "no_supported_main_document", "unsupported_main_response", "platform_mismatch", "https_upgrade_loop"]
        let safeReason: String
        if reasons.contains(reason) { safeReason = reason }
        else if reason.utf8.count == 13,
                reason.range(of: "^main_http_[45][0-9]{2}$", options: .regularExpression) != nil {
            safeReason = reason
        } else { safeReason = "main_policy_rejected" }
        outcome = .failed(Failure(kind: .policyRejected, domain: "navigation", code: 0, reason: safeReason))
    }

    /// Wait one second for an already-pending replacement before retrying. Returns only
    /// the original HTTPS target, once, without resetting the overall deadline. A plain
    /// -999 never authorizes a reload. Caller must use begin for the new navigation object.
    mutating func takeRetry(at: TimeInterval) -> URL? {
        expire(at: at)
        guard outcome == .pending, case .policy(let interruptedAt)? = interruption,
              at >= interruptedAt + 1 else { return nil }
        guard retryCount == 0, requestedURL.scheme?.lowercased() == "https",
              requestedURL.user == nil, requestedURL.password == nil,
              requestedURL.port == nil || requestedURL.port == 443,
              requestedURL.host?.isEmpty == false else {
            outcome = .failed(Failure(kind: .policyInterruption, domain: "WebKitErrorDomain", code: 102,
                                      reason: "policy_interruption_retry_unavailable"))
            return nil
        }
        retryCount += 1
        if let activeToken { retiredTokens.insert(activeToken) }
        activeToken = nil
        committedToken = nil
        interruption = nil
        benignMainCancellationAt = nil
        return requestedURL
    }

    mutating func expire(at: TimeInterval) {
        guard outcome == .pending else { return }
        guard at.isFinite, at < deadline else {
            outcome = .failed(Failure(kind: .timedOut, domain: "navigation", code: 0,
                                      reason: "overall_deadline_exceeded"))
            return
        }
    }
}

/// Budget for one logical main-document navigation. A successor navigation shares this
/// value; only the owner starting an explicit new operation may call reset().
/// Keep this Foundation-only so production and native behavior checks use the same code.
struct HTTPSUpgradeBudget {
    private(set) var count = 0

    mutating func consume() -> Bool {
        guard count < 2 else { return false }
        count += 1
        return true
    }

    mutating func reset() { count = 0 }
}
