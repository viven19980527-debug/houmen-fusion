import Foundation

/// Pure async polling tests with a virtual monotonic clock: no real sleep, WebKit,
/// network, account data, simulator or phone. Compile this @main separately.
@main
struct CommentPollingChecks {
    struct CheckFailure: Error, CustomStringConvertible { let description: String }
    enum FixtureError: Error { case script, sleeping }
    final class Clock {
        var now: TimeInterval
        var sleeps: [TimeInterval] = []
        init(_ now: TimeInterval = 0) { self.now = now }
        func advance(_ seconds: TimeInterval) { now += seconds }
        func sleep(_ seconds: TimeInterval) { sleeps.append(seconds); advance(seconds) }
    }
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw CheckFailure(description: "FAILED: " + label) }
            checks += 1; print("PASS: " + label)
        }
        try check(CommentPolling.timeout == 12 && CommentPolling.deadline(now: 100) == 112,
                  "comment budget is one monotonic twelve-second deadline")
        do {
            let clock = Clock(), deadline = CommentPolling.deadline(now: 0)
            var budgets: [TimeInterval] = [], messages: [String] = []
            let result = try await CommentPolling.wait(until: deadline, clock: { clock.now }, evaluate: { remaining in
                budgets.append(remaining)
                return ["state": "waiting", "message": "No loaded comment DOM"]
            }, waiting: { message, remaining in
                messages.append(message)
            }, sleep: { seconds in
                guard seconds > 0, seconds <= 1.5, clock.now + seconds <= deadline else {
                    throw CheckFailure(description: "sleep exceeded remaining comment budget")
                }
                clock.sleep(seconds)
            })
            try check(result == nil && clock.now == 12, "missing DOM ends at twelve seconds as unknown, never explicit zero")
            try check(budgets.count == 8 && budgets.first == 12 && budgets.last == 1.5,
                      "all evaluations receive only their remaining budget")
            try check(messages.count == 8 && clock.sleeps.reduce(0, +) == 12,
                      "waiting reports progress without restarting its deadline")
        }
        do {
            let clock = Clock(); var calls = 0
            let result = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                calls += 1; clock.advance(0.25)
                return calls < 3 ? ["state": "waiting"] : ["state": "ready", "comments": [["commentId": "synthetic-ready"]]]
            }, sleep: { clock.sleep($0) })
            try check(result?["state"] as? String == "ready" && calls == 3 && clock.now == 3.75,
                      "delayed ready preserves data before the deadline")
            try check((result?["comments"] as? [[String: String]])?.first?["commentId"] == "synthetic-ready",
                      "polling passes through the received sample, not a fabricated empty result")
        }
        do {
            let clock = Clock(); var calls = 0
            let result = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                calls += 1
                return calls == 1 ? ["state": "waiting", "explicitZero": false] :
                    ["state": "ready", "explicitZero": true, "comments": [[String: Any]]()]
            }, sleep: { clock.sleep($0) })
            try check(calls == 2 && clock.now == 1.5 && result?["explicitZero"] as? Bool == true,
                      "zero confirmation waits for adapter ready instead of treating waiting as zero")
        }
        do {
            let clock = Clock(100), deadline = CommentPolling.deadline(now: 100)
            let opened = try await CommentPolling.wait(until: deadline, clock: { clock.now }, evaluate: { _ in
                clock.advance(9); return ["state": "ready"]
            }, sleep: { clock.sleep($0) })
            var readBudgets: [TimeInterval] = []
            let read = try await CommentPolling.wait(until: deadline, clock: { clock.now }, evaluate: { remaining in
                readBudgets.append(remaining); clock.advance(0.5); return ["state": "waiting"]
            }, sleep: { seconds in
                guard clock.now + seconds <= deadline else { throw CheckFailure(description: "read reset the open deadline") }
                clock.sleep(seconds)
            })
            try check(opened?["state"] as? String == "ready" && read == nil,
                      "open and initial read share one budget rather than two timeouts")
            try check(readBudgets == [3, 1] && clock.now == 112,
                      "slow open leaves only its actual remaining seconds for the initial read")
        }
        do {
            let clock = Clock(12); var evaluated = false
            let result = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                evaluated = true; return ["state": "ready"]
            }, sleep: { clock.sleep($0) })
            try check(result == nil && !evaluated && clock.sleeps.isEmpty,
                      "already expired deadline does not start an evaluation")
        }
        do {
            let clock = Clock(); var invalidBudget = false, readings = 0
            let result = try await CommentPolling.wait(until: 12, clock: {
                readings += 1
                clock.now = readings == 1 ? 11.9 : 12.1
                return clock.now
            }, evaluate: { remaining in
                invalidBudget = remaining <= 0; return ["state": "ready"]
            }, sleep: { clock.sleep($0) })
            try check(result == nil && !invalidBudget,
                      "clock crossing the deadline between checks never passes nonpositive budget to JavaScript")
        }
        do {
            let clock = Clock()
            let result = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                ["state": "waiting"]
            }, waiting: { _, _ in clock.advance(12) }, sleep: { clock.sleep($0) })
            try check(result == nil && clock.now == 12 && clock.sleeps.isEmpty,
                      "waiting callback consuming the last budget does not trigger a stale extra sleep")
        }
        for arrival in [12.0, 12.01] {
            let clock = Clock()
            let result = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                clock.now = arrival
                return ["state": "ready", "comments": [["commentId": "late-synthetic"]]]
            }, sleep: { clock.sleep($0) })
            try check(result == nil, "ready arriving at or after deadline is not accepted")
        }
        do {
            let clock = Clock()
            let result = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                ["state": "skipped", "code": "source_unavailable", "message": "Synthetic deleted source"]
            }, sleep: { clock.sleep($0) })
            try check(result?["state"] as? String == "skipped" && result?["code"] as? String == "source_unavailable" &&
                      result?["explicitZero"] == nil && clock.sleeps.isEmpty,
                      "unavailable source skip is returned intact, not converted to zero or a timeout")
        }
        for late in [false, true] {
            let clock = Clock(); var caught = false
            do {
                _ = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                    if late { clock.now = 13 }
                    return ["state": "blocked", "message": "Synthetic login required"]
                }, sleep: { clock.sleep($0) })
            } catch is LocalFailure { caught = true }
            try check(caught, "authentication remains an error even when returned at deadline")
        }
        let invalid: [[String: Any]] = [[:], ["state": 7], ["state": NSNull()], ["state": "not-a-state"]]
        for reply in invalid {
            let clock = Clock(); var caught = false
            do {
                _ = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in reply },
                                                  sleep: { clock.sleep($0) })
            } catch is LocalFailure { caught = true }
            try check(caught && clock.sleeps.isEmpty, "missing, wrong-type and unknown state is a failure, never unknown/zero")
        }
        do {
            let clock = Clock(); var caught = false
            do {
                _ = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in throw FixtureError.script },
                                                  sleep: { clock.sleep($0) })
            } catch FixtureError.script { caught = true }
            try check(caught && clock.sleeps.isEmpty, "JavaScript exception propagates instead of advancing the checkpoint")
        }
        do {
            let clock = Clock(); var caught = false
            do {
                _ = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in ["state": "waiting"] },
                                                  sleep: { _ in throw FixtureError.sleeping })
            } catch FixtureError.sleeping { caught = true }
            try check(caught, "sleep failure is not swallowed as comment timeout")
        }
        let preCancelled = Task { () -> Bool in
            let clock = Clock(); var evaluated = false
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                    evaluated = true; return ["state": "ready"]
                }, sleep: { clock.sleep($0) })
                return false
            } catch is CancellationError { return !evaluated }
              catch { return false }
        }
        try check(await preCancelled.value, "pre-cancelled polling throws before JavaScript runs")
        let cancelledDuringEvaluation = Task { () -> Bool in
            let clock = Clock()
            do {
                _ = try await CommentPolling.wait(until: 12, clock: { clock.now }, evaluate: { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return ["state": "ready", "explicitZero": true]
                }, sleep: { clock.sleep($0) })
                return false
            } catch is CancellationError { return true }
              catch { return false }
        }
        try check(await cancelledDuringEvaluation.value, "cancellation after evaluation rejects even a ready zero result")
        print("PASS: \(checks) native async comment-polling checks with a virtual clock; no WebKit/device test performed")
    }
}
