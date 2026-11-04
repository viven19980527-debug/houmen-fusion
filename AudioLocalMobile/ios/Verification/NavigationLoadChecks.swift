import Foundation

@main
struct NavigationLoadChecks {
    struct CheckFailure: Error, CustomStringConvertible { let description: String }
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw CheckFailure(description: "FAILED: " + label) }
            checks += 1
            print("PASS: " + label)
        }
        let original = URL(string: "https://www.xiaohongshu.com/search_result?keyword=fixture")!
        let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        let policy = NSError(domain: "WebKitErrorDomain", code: 102)
        func make(timeout: TimeInterval = 20) -> NavigationLoadState {
            NavigationLoadState(requestedURL: original, startedAt: 100, timeout: timeout)
        }
        func kind(_ state: NavigationLoadState) -> NavigationLoadState.Failure.Kind? {
            if case .failed(let failure) = state.outcome { return failure.kind }
            return nil
        }

        // A URL/isLoading value is never completion proof; it needs this attempt's commit.
        do {
            var state = make(); let a = UUID(), other = UUID()
            state.commit(token: other, at: 100.1)
            state.finish(token: other, validDocument: true, at: 100.2)
            state.fail(token: other, error: policy, at: 100.3)
            try check(state.outcome == .pending, "unknown callbacks do not create navigation")
            try check(state.begin(token: a, at: 100.4), "initial navigation registered")
            state.finish(token: a, validDocument: true, at: 100.5)
            try check(kind(state) == .invalidDocument, "finish without commit fails closed")
            try check(!state.begin(token: UUID(), at: 100.6), "invalid document failure cannot restart itself")
        }
        do {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1); state.commit(token: a, at: 100.2)
            state.finish(token: a, validDocument: false, at: 100.3)
            try check(kind(state) == .invalidDocument, "wrong keyword/id or blank document is not accepted")
        }
        do {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1); state.commit(token: a, at: 100.2)
            try check(!state.begin(token: a, at: 100.3), "duplicate start cannot reset commit")
            state.finish(token: a, validDocument: true, at: 100.4)
            try check(state.outcome == .succeeded, "committed matching document finishes")
            state.fail(token: a, error: policy, at: 100.5)
            state.fail(token: a, error: cancellation, at: 100.6)
            state.rejectPolicy(reason: "unsupported_main_response", at: 100.7)
            state.expire(at: 200)
            try check(state.outcome == .succeeded, "late handoff callbacks cannot destroy completed document")
        }

        // Replaced navigations cannot poison the active successor, regardless of error type.
        for error in [policy, cancellation, NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)] {
            var state = make(); let a = UUID(), b = UUID()
            state.begin(token: a, at: 100.1); state.begin(token: b, at: 100.2)
            state.fail(token: a, error: error, at: 100.3)
            state.commit(token: a, at: 100.4); state.finish(token: a, validDocument: false, at: 100.5)
            try check(state.activeToken == b && state.outcome == .pending, "superseded failure/finish does not poison successor")
            try check(!state.begin(token: a, at: 100.6), "retired navigation cannot become active again")
            state.commit(token: b, at: 100.7); state.finish(token: b, validDocument: true, at: 100.8)
            try check(state.outcome == .succeeded, "verified successor finishes independently")
        }

        // -999 is pending, never success or a reload license. Only a successor can recover.
        do {
            var state = make(); let a = UUID(), b = UUID()
            state.begin(token: a, at: 100.1); state.commit(token: a, at: 100.2)
            state.fail(token: a, error: cancellation, at: 100.3)
            state.commit(token: a, at: 100.4); state.finish(token: a, validDocument: true, at: 100.5)
            try check(state.outcome == .pending, "same interrupted attempt cannot report success")
            try check(state.takeRetry(at: 102) == nil && state.retryCount == 0, "plain cancellation never retries")
            state.begin(token: b, at: 102.1); state.commit(token: b, at: 102.2)
            state.finish(token: b, validDocument: true, at: 102.3)
            try check(state.outcome == .succeeded, "cancellation recovers only with committed successor")
        }
        do {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1); state.fail(token: a, error: cancellation, at: 100.2)
            state.expire(at: 120)
            try check(kind(state) == .timedOut, "cancellation without successor expires rather than waiting forever")
        }

        // Policy 102 needs exact current-token, recent main-handoff correlation.
        do {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1); state.fail(token: a, error: policy, at: 100.2)
            try check(kind(state) == .policyInterruption, "uncorrelated 102 is a real failure")
            try check(state.takeRetry(at: 102) == nil, "uncorrelated 102 cannot reload")
        }
        do {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1)
            state.recordBenignMainCancellation(token: UUID(), at: 100.2)
            state.fail(token: a, error: policy, at: 100.3)
            try check(kind(state) == .policyInterruption, "unrelated token cannot authorize policy recovery")
        }
        do {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1)
            state.recordBenignMainCancellation(token: a, at: 100.2)
            state.fail(token: a, error: policy, at: 105.3)
            try check(kind(state) == .policyInterruption, "stale cancellation does not explain later 102")
        }
        do {
            var state = make(); let a = UUID(), b = UUID()
            state.begin(token: a, at: 100.1)
            state.recordBenignMainCancellation(token: a, at: 100.2)
            state.fail(token: a, error: policy, at: 100.3)
            try check(state.outcome == .pending, "correlated policy interruption allows bounded successor wait")
            try check(state.takeRetry(at: 101.29) == nil, "one-second successor grace prevents premature reload")
            state.begin(token: b, at: 101.3)
            try check(state.takeRetry(at: 101.4) == nil && state.retryCount == 0, "registered successor cancels retry opportunity")
            state.commit(token: b, at: 101.5); state.finish(token: b, validDocument: true, at: 101.6)
            try check(state.outcome == .succeeded, "policy interruption accepts verified successor")
        }
        do {
            var state = make(); let a = UUID(), b = UUID()
            state.begin(token: a, at: 100.1)
            state.recordBenignMainCancellation(token: a, at: 100.2)
            state.fail(token: a, error: policy, at: 100.3)
            let retry = state.takeRetry(at: 101.3)
            try check(retry == original, "retry returns exact original target, no invented URL")
            try check(state.retryCount == 1 && state.activeToken == nil && state.deadline == 120, "retry bounded to one and preserves overall deadline")
            try check(state.takeRetry(at: 101.4) == nil, "retry reservation cannot be consumed twice")
            try check(!state.begin(token: a, at: 101.5), "reloaded attempt must use a new token")
            state.begin(token: b, at: 101.6)
            state.recordBenignMainCancellation(token: b, at: 101.7)
            state.fail(token: b, error: policy, at: 101.8)
            try check(state.takeRetry(at: 102.79) == nil && state.outcome == .pending, "second interruption still allows successor grace")
            try check(state.takeRetry(at: 102.8) == nil && kind(state) == .policyInterruption, "second interruption fails instead of retry loop")
            try check(state.retryCount == 1, "retry count never exceeds one")
        }
        for raw in ["http://www.xiaohongshu.com/", "file:///fixture", "https://user:secret@www.xiaohongshu.com/", "https://www.xiaohongshu.com:444/"] {
            var state = NavigationLoadState(requestedURL: URL(string: raw)!, startedAt: 100, timeout: 20)
            let a = UUID(); state.begin(token: a, at: 100.1)
            state.recordBenignMainCancellation(token: a, at: 100.2)
            state.fail(token: a, error: policy, at: 100.3)
            try check(state.takeRetry(at: 102) == nil && kind(state) == .policyInterruption, "unsafe original destination cannot retry")
        }

        // True errors, TLS problems and policy rejection cannot be hidden by cancellation.
        for error in [NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed),
                      NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
                      NSError(domain: "OtherDomain", code: -999),
                      NSError(domain: NSURLErrorDomain, code: 102),
                      NSError(domain: "WKErrorDomain", code: 102)] {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1)
            state.recordBenignMainCancellation(token: a, at: 100.2)
            state.fail(token: a, error: error, at: 100.3)
            try check(kind(state) == .network, "domain-plus-code classification keeps actual failures")
            state.fail(token: a, error: policy, at: 100.4)
            try check(kind(state) == .network && state.takeRetry(at: 102) == nil, "late 102 cannot erase network failure")
            try check(!state.begin(token: UUID(), at: 102.1), "terminal real failure rejects successor recovery")
        }
        for reason in ["main_http_403", "main_http_429", "unsupported_main_response", "unsupported_main_web_destination"] {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1)
            state.recordBenignMainCancellation(token: a, at: 100.2)
            state.rejectPolicy(reason: reason, at: 100.3)
            let preserved = state.outcome
            state.fail(token: a, error: policy, at: 100.4)
            state.fail(token: a, error: cancellation, at: 100.5)
            state.finish(token: a, validDocument: true, at: 100.6)
            try check(state.outcome == preserved && kind(state) == .policyRejected, "policy stop retains original category after callbacks")
            try check(state.takeRetry(at: 102) == nil && !state.begin(token: UUID(), at: 102.1), "HTTP/policy rejection never retries or restarts")
        }
        do {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1); state.fail(token: a, error: cancellation, at: 100.2)
            state.fail(token: a, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed), at: 100.3)
            try check(kind(state) == .network, "real error after interruption is not swallowed")
        }

        // Deadlines are inclusive and remain unchanged across redirects/retries.
        do {
            var state = make(timeout: 2); let a = UUID(), b = UUID()
            state.begin(token: a, at: 100.1); state.begin(token: b, at: 101.8)
            state.commit(token: b, at: 101.9); state.finish(token: b, validDocument: true, at: 102)
            try check(kind(state) == .timedOut && state.deadline == 102, "finish at deadline is too late even after redirect")
        }
        do {
            var state = make(timeout: 1); let a = UUID()
            state.begin(token: a, at: 100.1)
            state.recordBenignMainCancellation(token: a, at: 100.2)
            state.fail(token: a, error: policy, at: 100.3)
            try check(state.takeRetry(at: 101.3) == nil && kind(state) == .timedOut, "deadline prevents retry past total budget")
        }
        for timeout in [TimeInterval.nan, TimeInterval.infinity, -1, 0] {
            var state = make(timeout: timeout)
            try check(!state.begin(token: UUID(), at: 100) && kind(state) == .timedOut, "invalid time budget fails closed")
        }
        do {
            var state = make(); state.expire(at: .nan)
            try check(kind(state) == .timedOut, "nonfinite clock value does not create infinite wait")
        }

        // Neither arbitrary NSError strings nor policy input can leak into diagnostics/UI.
        let privateMarker = "PRIVATE_PATH_TOKEN_COOKIE_SECRET"
        do {
            var state = make(); let a = UUID()
            state.begin(token: a, at: 100.1)
            state.fail(token: a, error: NSError(domain: privateMarker, code: 777,
                userInfo: [NSLocalizedDescriptionKey: privateMarker,
                           NSURLErrorFailingURLStringErrorKey: "https://example.invalid/" + privateMarker]), at: 100.2)
            if case .failed(let failure) = state.outcome {
                try check(failure.domain == "other" && failure.code == 777, "unknown NSError domain becomes fixed other category")
                try check(!failure.diagnosticLine.contains(privateMarker) && !failure.userMessage.contains(privateMarker), "error details cannot leak URL/userInfo/localized text")
            } else { try check(false, "network failure required") }
        }
        do {
            var state = make(); state.rejectPolicy(reason: privateMarker, at: 100.1)
            if case .failed(let failure) = state.outcome {
                try check(failure.reason == "main_policy_rejected" && !failure.diagnosticLine.contains(privateMarker), "policy reason uses allowlisted labels")
            } else { try check(false, "policy failure required") }
        }
        // Exercise the exact budget used by BrowserCollector, not a test-only counter.
        do {
            var budget = HTTPSUpgradeBudget()
            try check(budget.count == 0, "new HTTPS upgrade operation starts with zero consumption")
            try check(budget.consume() && budget.count == 1, "first HTTPS upgrade is allowed")
            try check(budget.consume() && budget.count == 2, "second HTTPS upgrade is allowed")
            try check(!budget.consume() && budget.count == 2, "third HTTPS upgrade is rejected without increasing count")
            for _ in 0..<4 {
                try check(!budget.consume() && budget.count == 2, "later upgrades remain rejected in the same operation")
            }
            budget.reset()
            try check(budget.count == 0, "explicit new operation resets HTTPS upgrade budget")
            try check(budget.consume() && budget.count == 1, "reset operation can perform its first upgrade")
        }
        do {
            var budget = HTTPSUpgradeBudget()
            var state = make(); let a = UUID(), b = UUID(), c = UUID()
            state.begin(token: a, at: 100.1)
            try check(budget.consume() && budget.count == 1, "initial main navigation consumes first HTTPS upgrade")
            state.begin(token: b, at: 100.2)
            try check(budget.count == 1, "same operation successor retains already consumed upgrade")
            try check(budget.consume() && budget.count == 2, "successor consumes the remaining upgrade")
            state.begin(token: c, at: 100.3)
            try check(budget.count == 2 && !budget.consume(), "another successor cannot reset the exhausted budget")
            state.rejectPolicy(reason: "https_upgrade_loop", at: 100.4)
            let rejected = state.outcome
            if case .failed(let failure) = rejected {
                try check(failure.kind == .policyRejected && failure.reason == "https_upgrade_loop",
                          "third-upgrade rejection preserves the precise loop reason")
            } else { try check(false, "third upgrade must fail the navigation") }
            state.fail(token: c, error: policy, at: 100.5)
            state.fail(token: c, error: cancellation, at: 100.6)
            try check(state.outcome == rejected, "102 and cancellation cannot overwrite exhausted upgrade failure")
            try check(!state.begin(token: UUID(), at: 100.7) && state.outcome == rejected,
                      "new navigation token cannot recover an exhausted upgrade operation")
            try check(state.takeRetry(at: 102) == nil && budget.count == 2,
                      "policy retry cannot evade the exhausted HTTPS upgrade budget")
        }
        print("PASS: \(checks) native Swift navigation-load checks; synthetic lifecycle fixtures, not iPhone/platform acceptance")
    }
}
