import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const root = new URL('../ios/', import.meta.url);
const browser = fs.readFileSync(new URL('AudioLocal/BrowserCollector.swift', root), 'utf8');
const policy = fs.readFileSync(new URL('AudioLocal/NavigationPolicy.swift', root), 'utf8');
const state = fs.readFileSync(new URL('AudioLocal/NavigationLoadState.swift', root), 'utf8');
function section(a,b) {
  const start=browser.indexOf(a), end=browser.indexOf(b,start+a.length);
  assert.ok(start>=0 && end>start); return browser.slice(start,end);
}
test('observed same-site HTTP request is cancelled before HTTPS replacement and upgrade loops are bounded',()=>{
 const action=section('func webView(_ webView: WKWebView, decidePolicyFor action:', 'func webView(_ webView: WKWebView, decidePolicyFor response:');
 assert.match(action,/upgradedMainRequestURL/);
 assert.match(action,/guard secureUpgradeBudget\.consume\(\) else/);
 assert.ok(action.indexOf('secureUpgradeBudget.consume()')<action.indexOf('registerNavigation(webView.load'));
 assert.ok(action.indexOf('prepareSuccessorIfCompleted(upgraded)')<action.indexOf('registerNavigation(webView.load'));
 assert.ok(action.indexOf('decisionHandler(.cancel)\n            registerNavigation')>0);
 assert.match(policy,/targetIsMainFrame == true, method == "GET"/);
 assert.match(policy,/components.scheme = "https"/);
 assert.match(policy,/components.percentEncodedQuery == query/);
 assert.doesNotMatch(fs.readFileSync(new URL('AudioLocal/Info.plist',root),'utf8'), /NSAllowsArbitraryLoads|NSExceptionAllowsInsecureHTTPLoads/);
});
test('native navigation awaits commit/finish outcome rather than isLoading=false or a stale platform URL',()=>{
 const navigate=section('private func navigate(', 'private func waitForVisibleNavigation(');
 assert.match(navigate,/case \.succeeded\?: return/);
 assert.match(navigate,/navigationLoad\?\.expire/);
 assert.doesNotMatch(navigate,/while webView.isLoading/);
 assert.match(browser,/NavigationPolicy.matchesDestination\(requested: target, actual: webView.url\)/);
 assert.match(state,/committedToken == token, validDocument/);
});
test('HTTP policy failure survives 102 and exact NSError domain is checked',()=>{
 const failed=section('private func failedNavigation(', 'func webView(_ webView: WKWebView, didFailProvisionalNavigation');
 assert.doesNotMatch(failed,/stop\(|localizedDescription|userInfo/);
 assert.match(failed,/guard current, let token else/);
 assert.match(state,/error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled/);
 assert.match(state,/error.domain == "WebKitErrorDomain" && error.code == 102/);
 const reject=section('private func rejectNavigation(', 'func webView(_ webView: WKWebView, decidePolicyFor action:');
 assert.match(reject,/guard trackingNavigation else/);
 assert.match(reject,/if policyFailureMessage == nil/);
});
test('successor navigation preserves awaited target/deadline and DOM evaluation waits for it',()=>{
 const successor=section('private func prepareSuccessorIfCompleted(', 'private func navigate(');
 assert.match(successor,/awaitingNavigation == navigationOperation/);
 assert.match(successor,/requestedURL: previous.requestedURL/);
 assert.match(successor,/previous.deadline - uptime/);
 assert.ok(successor.indexOf('secureUpgradeBudget.reset()')>successor.indexOf('} else {'));
 const evaluate=section('private func evaluate(', 'private func waitFor(');
 assert.ok(evaluate.indexOf('waitForVisibleNavigation')<evaluate.indexOf('webView.evaluateJavaScript'));
 assert.match(evaluate,/remainingScriptTimeout/);
 assert.match(browser,/guard let target = pendingMainNavigationURL, allowed\(target\)/);
});
test('recovery opens HTTPS home and does not clear data or silently start a fresh collection',()=>{
 const recover=section('func reopenPlatform()', 'func stop(');
 assert.match(recover,/navigate\(self.selectedPlatform.homeURL\)/);
 assert.doesNotMatch(recover,/removeData|removeItem|checkpoint.save|start\(keyword/);
 assert.match(browser,/domain=\\\(safe.domain\) code=\\\(safe.code\)/);
 const project=fs.readFileSync(new URL('AudioLocal.xcodeproj/project.pbxproj',root),'utf8');
 assert.match(project,/NavigationLoadState.swift/);
 assert.match(fs.readFileSync(new URL('verify-and-build.sh',root),'utf8'),/NavigationLoadChecks.swift/);
});
