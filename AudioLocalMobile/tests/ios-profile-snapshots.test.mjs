import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {parseHTML} from 'linkedom';
const snapshot = fs.readFileSync(new URL('../ios/AudioLocal/ProfileSnapshotStore.swift', import.meta.url), 'utf8');
const home = fs.readFileSync(new URL('../ios/AudioLocal/HomeView.swift', import.meta.url), 'utf8');
const probe = snapshot.match(/static let headerProbe = #"""\n([\s\S]*?)\n"""#/)[1];
function run(html, options = {}) {
  const {window} = parseHTML(`<html><body>${html}</body></html>`), document = window.document;
  Object.defineProperty(document, 'readyState', {value: options.loading ? 'loading' : 'complete'});
  window.innerWidth = 1000; window.innerHeight = 800;
  for (const el of document.querySelectorAll('*')) {
    el.getBoundingClientRect = () => {
      const [x,y,w,h] = (el.getAttribute('data-rect') || '40,50,920,300').split(',').map(Number);
      return {x,y,left:x,top:y,width:w,height:h,right:x+w,bottom:y+h};
    };
  }
  document.elementFromPoint = () => options.occluded ? document.body : document.querySelector('[data-main]');
  const location = new URL(options.url || 'https://www.douyin.com/user/public_fixture');
  return vm.runInNewContext(probe, {document, window, location, URL,
    getComputedStyle: el => ({display:el.style.display || 'block',visibility:el.style.visibility || 'visible',opacity:el.style.opacity || '1'})});
}
const dy = '<section data-main data-e2e="user-info"><span data-e2e="user-info-name">公开作者</span><p>公开介绍</p></section>';
// Anonymous fixture of the actually observed public merchant header hierarchy.
const xhs = '<div class="user-profile"><section class="user"><div class="user-info"><div class="info-part"><div data-main class="info"><div class="basic-info"><div class="user-basic"><div class="user-nickname"><span class="user-name">公开商家</span></div></div></div><div class="user-desc">公开业务介绍</div><div class="user-tags">公开地区</div><div class="data-info">公开账号统计</div></div></div></div></section></div>';
test('profile probe recognizes only a bounded visible public header, never full page', () => {
  const result = run(dy);
  assert.equal(result.state,'ready'); assert.equal(result.selector,'[data-e2e="user-info"]');
  assert.equal(result.width,920); assert.equal(result.height,300);
  assert.ok(result.fingerprint); assert.equal(result.nickname,undefined);
  assert.equal(run(xhs,{url:'https://www.xiaohongshu.com/user/profile/0123456789abcdef01234567'}).state,'ready');
  assert.equal(run('<main data-main>Some account page</main>').state,'waiting');
});
test('visible login, verification and modal overlays block profile screenshots', () => {
  for (const gate of ['<aside role="dialog">登录</aside>','<div class="captcha-wrap">验证</div>',
                      '<input type="password">','<aside aria-modal="true">打开 App</aside>']) {
    assert.equal(run(dy+gate).state,'blocked');
  }
  assert.equal(run(dy+'<aside role="dialog" style="display:none">登录</aside>').state,'ready');
});
test('private accounts, error states and backends never become profile images', () => {
  for (const text of ['私密账号','私密帐号','该用户已设置隐私','用户主页仅好友可见']) {
    assert.equal(run(dy.replace('</section>', `<span>${text}</span></section>`)).state,'blocked');
  }
  for (const text of ['用户不存在','页面不存在','登录后查看','安全验证']) {
    assert.equal(run(dy+`<div class="error-page">${text}</div>`).state,'blocked');
  }
  assert.equal(run(dy.replace('</section>','<i aria-label="私密账号"></i></section>')).state,'blocked');
  for (const url of ['https://channels.weixin.qq.com/platform/','https://www.douyin.com/creator/',
                     'https://example.invalid/user/public_fixture','http://www.douyin.com/user/public_fixture',
                     'https://name@www.douyin.com/user/public_fixture']) {
    assert.equal(run(dy,{url}).state,'blocked');
  }
});
test('public XHS info remains capturable when only collection content is private', () => {
  const hiddenCollections = '<section class="collections"><div class="empty"><div class="empty-text">该用户已设置收藏内容不可见</div></div><i aria-label="私密收藏"></i><p>收藏仅自己可见</p></section>';
  const result = run(xhs+hiddenCollections,{url:'https://www.xiaohongshu.com/user/profile/0123456789abcdef01234567'});
  assert.equal(result.state,'ready');
  assert.equal(result.selector,'.user-profile .user-info .info-part > .info');
  assert.equal(result.selector.includes('collections'),false);
  assert.doesNotMatch(probe,/document\.body\?\.innerText/);
});
test('verified XHS narrow header wins over its nested broad fallback and rejects truly private account', () => {
  const url = 'https://www.xiaohongshu.com/user/profile/0123456789abcdef01234567';
  const result = run(xhs,{url});
  assert.equal(result.state,'ready');
  assert.equal(result.selector,'.user-profile .user-info .info-part > .info');
  assert.equal(run(xhs.replace('公开业务介绍','私密账号'),{url}).state,'blocked');
  assert.equal(run(xhs+'<div class="empty-text">该用户已设置隐私账号</div>',{url}).state,'blocked');
  // A private-content panel inside the proposed capture rectangle is never captured.
  assert.equal(run(xhs.replace('公开业务介绍','<div role="tabpanel"><div class="empty-text">收藏内容不可见</div></div>'),{url}).state,'waiting');
});
test('ambiguous, hidden, incomplete or occluded headers are not captured', () => {
  assert.equal(run(dy+dy).state,'waiting');
  assert.equal(run('<section data-main data-e2e="user-info"><p>No public name marker</p></section>').state,'waiting');
  assert.equal(run('<div style="opacity:0">'+dy+'</div>').state,'waiting');
  assert.equal(run(dy,{occluded:true}).state,'blocked');
  assert.equal(run(dy.replace('data-main','data-main data-rect="40,50,920,1000"')).state,'waiting');
  assert.equal(run(dy.replace('</section>','<div data-e2e="comment-list">Comment list</div></section>')).state,'waiting');
});
test('capture has a total eight-second deadline, identity checks on both sides, and no login automation', () => {
  assert.match(snapshot,/ProcessInfo\.processInfo\.systemUptime \+ 8/);
  assert.match(snapshot,/configuration\.rect = rect/);
  assert.match(snapshot,/configuration\.snapshotWidth/);
  assert.ok((snapshot.match(/try checkPage\(webView, identity: identity\)/g)||[]).length >= 3);
  assert.match(snapshot,/let after = try await inspect/);
  assert.match(snapshot,/ProcessInfo\.processInfo\.systemUptime < deadline else \{ throw ProfileSnapshotFailure\.timeout \}/);
  assert.match(snapshot,/guard remaining > 0 else/);
  assert.match(snapshot,/withTaskCancellationHandler/);
  assert.match(snapshot,/\.atomic, \.completeFileProtection/);
  assert.doesNotMatch(probe,/\.click\(|scrollIntoView|fetch\(|XMLHttpRequest|document\.cookie|localStorage/);
});
test('cache preserves older image on refresh failure, canonicalizes profiles, and prunes only explicitly', () => {
  const failure=snapshot.slice(snapshot.indexOf('func recordFailure('),snapshot.indexOf('func persistValidatedCapture('));
  assert.match(failure,/capturedAt: previous\?\.capturedAt/);
  assert.match(failure,/filename: previous\?\.filename/);
  assert.doesNotMatch(failure,/removeItem/);
  assert.match(snapshot,/CollectionPlatform\.profileIdentity/);
  assert.match(snapshot,/func prune\(keeping profileURLs: Set<String>\) throws/);
  assert.match(snapshot,/isExcludedFromBackup = true/);
  assert.match(home,/ProfileSnapshotStore\.shared\.prune\(keeping: Set\(store\.comments\.map\(\\\.profileUrl\)\)\)/);
});
test('cards open local screenshot sheets instead of automatically launching public-profile URLs', () => {
  const summary = home.slice(home.indexOf('private struct CompactLeadSummary:'),home.indexOf('private struct CommentDetails:'));
  assert.match(summary,/Label\("主页截图"/);
  assert.match(summary,/ProfileSnapshotSheet\(value: value\)/);
  assert.doesNotMatch(summary,/Link\(/);
  assert.match(home,/UIImage\(contentsOfFile:/);
  assert.match(home,/正在查看旧截图/);
  assert.match(home,/暂无可查看的主页截图/);
});
test('completion dismisses browser first and then automatically presents actual stored results', () => {
  assert.match(home,/\.sheet\(item: \$browser, onDismiss:/);
  assert.match(home,/pendingCompletion = nil; completedResults = result/);
  assert.match(home,/pendingCompletion = result\s+browser = nil/);
  assert.match(home,/\.onChange\(of: collector\.completion\?\.id\)/);
  assert.match(home,/collector\.completion = nil\s+onCompletion\(result\)/);
  assert.match(home,/\.sheet\(item: \$completedResults\)/);
  assert.match(home,/let ids = Set\(completion\.commentIDs\)/);
  assert.match(home,/store\.comments\.filter \{ ids\.contains\(\$0\.id\) && SourcePublicationGate\.sourceEligible/);
  assert.match(home,/没有结果不等于零评论/);
  assert.match(home,/ForEach\(Array\(completion\.outcomes\.enumerated\(\)\)/);
});

test('source priority labels come from the shared gate, not duplicate UI date arithmetic', () => {
  assert.match(home,/switch SourcePublicationGate\.sourceTier\(comment, now: now\)/);
  assert.match(home,/case 7: return "近7天"/);
  assert.match(home,/case 30: return "8–30天"/);
  assert.match(home,/case 90: return "31–90天"/);
  assert.match(home,/来源分档：近7天/);
  assert.match(home,/@State private var recency: CommentRecency = \.all/);
});
