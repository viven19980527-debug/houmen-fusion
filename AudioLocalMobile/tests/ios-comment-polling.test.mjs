import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const browser=fs.readFileSync(new URL('../ios/AudioLocal/BrowserCollector.swift',import.meta.url),'utf8');
const model=fs.readFileSync(new URL('../ios/AudioLocal/CollectionJob.swift',import.meta.url),'utf8');
function section(start,end){const a=browser.indexOf(start),b=browser.indexOf(end,a+start.length);assert.ok(a>=0&&b>a,`section ${start}`);return browser.slice(a,b);}
// Static wiring guards only. The independently compiled Swift executable exercises the poller.
test('comment open and first read use a single twelve-second monotonic deadline, never default sixty-second waits',()=>{
 const scan=section('private func scanComments(', 'private static func selectedComments(');
 assert.match(scan,/let initialDeadline = CommentPolling\.deadline\(\)/);
 assert.match(scan,/waitForComments\("open", target: target, until: initialDeadline\)/);
 assert.match(scan,/waitForComments\("read", target: target, until: initialDeadline\)/);
 assert.doesNotMatch(scan,/waitFor\("(?:open|read)"/);
 for(const call of browser.matchAll(/\bwaitFor\("(?:open|read)"([^)]*)\)/g))assert.match(call[1],/timeout\s*:/,'remaining manual read must use an explicit timeout');
 assert.match(model,/static let timeout: TimeInterval = 12/);
 assert.match(model,/clock: \(\) -> TimeInterval = \{ ProcessInfo\.processInfo\.systemUptime \}/);
 assert.match(model,/evaluate: \(TimeInterval\) async throws -> \[String: Any\]/);
 assert.match(model,/sleep: \(TimeInterval\) async throws -> Void/);
});
test('empty-comment timeouts remain unknown and return a non-source-failure scan, preserving later buffers',()=>{
 const scan=section('private func scanComments(', 'private static func selectedComments(');
 assert.match(scan,/guard let opened =[\s\S]*?else \{\s*return CommentScan\(comments: \[\], outcome: "[^"\n]*不代表零评论", sourceUnavailable: false\)/);
 assert.match(scan,/guard var result =[\s\S]*?else \{\s*return CommentScan\(comments: \[\], outcome: "[^"\n]*不代表零评论", sourceUnavailable: false\)/);
 assert.match(scan,/guard let nextRead = try await waitForComments\("read", target: target, until: CommentPolling\.deadline\(\)\) else \{/);
 assert.match(scan,/后续评论等待12秒超时，保留此前样本/);
 assert.match(scan,/return CommentScan\(comments: buffer, outcome: outcome, sourceUnavailable: false\)/);
 assert.match(scan,/stagnant >= 3/);
 assert.match(scan,/buffer\.isEmpty \? "平台稳定显示零评论" : "后续列表变空/);
 assert.doesNotMatch(scan,/nextIndex|store\.save|persist\(/);
});
test('polling wrapper only downgrades an exhausted watchdog budget, never authentication, cancellation or early script faults',()=>{
 const wait=section('private func waitForComments(', 'private func sourceSkipped(');
 assert.match(wait,/CommentPolling\.wait\(until: deadline/);
 assert.match(wait,/scriptTimeout: max\(0\.01, remaining\)/);
 assert.match(wait,/catch BrowserScriptFailure\.timeout/);
 assert.match(wait,/if ProcessInfo\.processInfo\.systemUptime >= deadline \{ return \["state": "waiting"\] \}/);
 assert.match(wait,/throw BrowserScriptFailure\.timeout/);
 assert.doesNotMatch(wait,/catch\s*\{[^}]*return nil/);
 const poll=model.slice(model.indexOf('enum CommentPolling'));
 assert.match(poll,/state == "blocked".*throw LocalFailure/);
 assert.match(poll,/\["ready", "skipped", "waiting"\]\.contains\(state\)/);
 assert.ok((poll.match(/Task\.checkCancellation\(\)/g)||[]).length>=2);
 assert.match(poll,/guard deadline > clock\(\) else \{ return nil \}/);
});
test('timeout samples still require a final source proof and normal atomic checkpoint progression',()=>{
 const launch=section('private func launch()', 'func saveVisiblePage()');
 const scanAt=launch.indexOf('scanComments(for: target)'),finalAt=launch.indexOf('sourceProof(for: target)',scanAt);
 assert.ok(scanAt>=0&&finalAt>scanAt);
 assert.ok(launch.indexOf('finishTarget(target, scan: scan, proof: finalProof)',finalAt)>finalAt);
 assert.match(launch,/SourcePublicationGate\.eligible\(finalProof, now: Date\(\)\)/);
 const commit=section('private func finishTarget(', 'private func collectedCommentsForJob(');
 assert.match(commit,/next\.outcomes\.append/);
 assert.match(commit,/next\.nextIndex \+= 1/);
 assert.match(commit,/try persist\(next\)/);
 assert.ok(commit.indexOf('store.save(batch')<commit.indexOf('try persist(next)'));
});
test('profile snapshots happen only after source completion and result presentation follows bounded snapshot preparation',()=>{
 const launch=section('private func launch()', 'func saveVisiblePage()');
 const finished=launch.indexOf('guard self.job?.finished == true'),snapshot=launch.indexOf('await self.prepareProfileSnapshots()');
 assert.ok(finished>=0&&snapshot>finished);
 assert.ok(launch.indexOf('self.presentCompletion()',snapshot)>snapshot);
 const snapshots=section('private func prepareProfileSnapshots()', 'private func launch()');
 assert.match(snapshots,/profiles\.prefix\(10\)/);
 assert.match(snapshots,/Task\.isCancelled/);
 assert.match(snapshots,/cache\.capture\(in: webView, profileURL: comment\.profileUrl\)/);
});

test('comment polling rechecks both evaluation and post-status sleep budgets against the monotonic clock',()=>{
 const poll=model.slice(model.indexOf('enum CommentPolling'));
 const evalBudget=poll.indexOf('let budget = deadline - clock()');
 assert.ok(evalBudget>=0&&poll.indexOf('guard budget > 0',evalBudget)>evalBudget);
 assert.ok(poll.indexOf('evaluate(budget)',evalBudget)>poll.indexOf('guard budget > 0',evalBudget));
 const status=poll.indexOf('waiting(result["message"]');
 const sleepBudget=poll.indexOf('let sleepBudget = max(0, deadline - clock())',status);
 assert.ok(status>=0&&sleepBudget>status);
 assert.ok(poll.indexOf('guard sleepBudget > 0',sleepBudget)>sleepBudget);
 assert.match(poll,/sleep\(min\(1\.5, sleepBudget\)\)/);
});
test('source discovery expands seven thirty ninety day windows only when fewer than five verified targets remain',()=>{
 const discover=section('private func discoverSources()', 'func start(keyword:');
 assert.match(discover,/for window in \[7, 30, 90\]/);
 assert.match(discover,/if verified\.count >= 5 \{ break \}/);
 assert.match(discover,/sourceWindowDays = window/);
 assert.match(discover,/CollectionJob\.searchVideos\(from: result, sourceWindowDays: window\)/);
 assert.ok((discover.match(/windowDays: window/g)||[]).length>=2,'both card and verified detail use the selected window');
 assert.match(discover,/verified = Self\.rankedSources\(verified, now: Date\(\)\)/);
 const ranked=section('private static func rankedSources(', 'private func discoverSources()');
 assert.match(ranked,/CollectionJob\.prioritizedTargets\(targets, now: now\)\.prefix\(5\)/);
 const start=section('func start(keyword:', 'func resume()');
 assert.match(start,/next\.schema = 4/);
 assert.match(start,/next\.sourcePolicy = SourcePublicationGate\.policy/);
});
test('optional screenshot navigation failure does not cancel the completed collection or hide its result',()=>{
 const snapshots=section('private func prepareProfileSnapshots()', 'private func launch()');
 assert.match(snapshots,/preparingSnapshots = true/);
 assert.match(snapshots,/defer \{ preparingSnapshots = false; snapshotNavigationFailure = nil \}/);
 assert.match(snapshots,/navigate\(url, timeout: 8\)/);
 assert.match(snapshots,/catch is CancellationError \{ return \}/);
 assert.match(snapshots,/cache\.recordFailure\(profileURL: comment\.profileUrl, reason: error\.localizedDescription\)/);
 const navigation=section('private func rejectNavigation(', 'func webView(_ webView: WKWebView, decidePolicyFor action:');
 assert.match(navigation,/if preparingSnapshots \{ snapshotNavigationFailure = policyFailureMessage \}/);
 assert.match(navigation,/else \{ stop\(policyFailureMessage\) \}/);
 const monitor=section('private func monitorNavigation()', 'private func prepareSuccessorIfCompleted(');
 assert.match(monitor,/if self\.awaitingNavigation != operation/);
 assert.match(monitor,/if self\.preparingSnapshots \{ self\.snapshotNavigationFailure = message \}/);
 const navigate=section('private func navigate(', 'private func evaluate(');
 assert.match(navigate,/case \.failed\(let failure\)\?:/);
 assert.match(navigate,/throw LocalFailure\.message\(policyFailureMessage \?\? failure\.userMessage\)/);
 assert.doesNotMatch(navigate,/stop\(/);
});

test('completion and automatic snapshots cannot restore skipped old or undated stored records through job.seen',()=>{
 const collected=section('private func collectedCommentsForJob()', 'private func presentCompletion()');
 assert.match(collected,/guard let date = CommentRecency\.publicationDate\(comment\), date <= Date\(\)/);
 assert.match(collected,/CommentRecency\.accepts\(PublicationTime\(date: date, quality: "stored"\), range: job\.range, now: Date\(\)\)/);
 assert.match(collected,/keys\.contains\(CollectionJob\.rowKey\(row\)\)/);
 assert.match(collected,/SourcePublicationGate\.eligible\(SourcePublicationGate\.publication\(comment\), now: Date\(\)\)/);
 assert.match(collected,/CollectionPlatform\.sourceIdentity\(comment\.sourceUrl\)/);
 assert.match(collected,/guard count < 50 else \{ return false \}/);
 const completion=section('private func presentCompletion()', 'private func prepareProfileSnapshots()');
 assert.match(completion,/commentIDs: collectedCommentsForJob\(\)\.map\(\\\.id\)/);
 const snapshots=section('private func prepareProfileSnapshots()', 'private func launch()');
 assert.match(snapshots,/let profiles = collectedCommentsForJob\(\)\.filter/);
});
