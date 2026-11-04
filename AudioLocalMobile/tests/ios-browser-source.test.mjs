import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const file = new URL('../ios/AudioLocal/BrowserCollector.swift', import.meta.url);
const source = fs.readFileSync(file, 'utf8');
function body(start, end) {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `bounded section ${start}`);
  return source.slice(a, b);
}
test('iOS source pipeline statically requires prepared latest search and verified dates before queueing', () => {
  const discover = body('private func discoverSources()', 'func start(keyword:');
  assert.ok(discover.indexOf('waitFor("prepare_search")') < discover.indexOf('waitFor("search")'));
  assert.match(discover, /result\["latestOrderConfirmed"\] as\? Bool == true/);
  assert.match(discover, /for round in 0\.\.<5/);
  assert.match(discover, /candidates\.count < 40/);
  assert.match(discover, /unknownProbes >= 10/);
  assert.match(discover, /sourceProof\(for: target\)/);
  assert.match(discover, /return Self\.rankedSources\(verified, now: Date\(\)\)/);
  assert.doesNotMatch(discover, /waterfall_item_\s*\+|\/video\/"\s*\+/);
});
test('iOS search rejects malformed videos before treating search as exhausted', () => {
  const discover = body('private func discoverSources()', 'func start(keyword:');
  assert.match(discover, /let videos = try CollectionJob\.searchVideos\(from: result, sourceWindowDays: window\)/);
  assert.ok(discover.indexOf('try CollectionJob.searchVideos') < discover.indexOf('for item in videos'));
  assert.doesNotMatch(discover, /result\["videos"\][^\n]*\?\? \[\]/);
  const model = fs.readFileSync(new URL('../ios/AudioLocal/CollectionJob.swift', import.meta.url), 'utf8');
  assert.match(model, /let videos = result\["videos"\] as\? \[\[String: Any\]\] else \{ throw JobFailure\.invalidSearch \}/);
});
test('iOS v4 tasks require source policy; legacy tasks restart search without deleting comments', () => {
  const start = body('func start(keyword:', 'private static func commentTime');
  assert.match(start, /next\.schema = 4/);
  assert.match(start, /next\.sourcePolicy = SourcePublicationGate\.policy/);
  assert.match(start, /saved\.requiresFreshSourceSearch/);
  assert.match(start, /start\(keyword: saved\.keyword, recency: saved\.range, industry: saved\.industry, platform: saved\.platform\)/);
  assert.doesNotMatch(start, /store\.remove|removeItem/);
});
test('iOS waits understand skipped and source has bounded 12-second timeout', () => {
  const wait = body('private func waitFor(', 'private static func olderProof');
  assert.match(wait, /\["ready", "skipped"\]\.contains/);
  assert.match(wait, /if command == "source"/);
  assert.match(wait, /waitFor\("source"[\s\S]*timeout: 12\)/);
});
test('iOS comment scan buffers 200 before newest 50 selection, never stopping at first 50 popular rows', () => {
  const scan = body('private func scanComments(', 'private static func selectedComments(');
  assert.match(scan, /for round in 0\.\.<24/);
  assert.match(scan, /buffer\.count >= 200/);
  assert.match(scan, /stagnant >= 3/);
  assert.doesNotMatch(scan, /acceptedThisVideo >= 50|store\.save|persist\(|next\.seen/);
  assert.match(scan, /CollectionPlatform\.sourceIdentity\(row\["sourceUrl"\]/);
  const select = body('private static func selectedComments(', 'private func finishTarget(');
  assert.match(select, /guard let time = item\.time/);
  assert.ok(select.indexOf('.sorted') < select.indexOf('.prefix(50)'));
});
test('iOS commit uses native proof overwrite and strict store before advancing checkpoint', () => {
  const finish = body('private func finishTarget(', 'private func launch()');
  assert.match(finish, /row\.merge\(proof\.rowFields\) \{ _, verified in verified \}/);
  assert.ok(finish.indexOf('try next.validate()') < finish.indexOf('store.save(batch'));
  assert.match(finish, /store\.save\(batch, requireRecentSource: true/);
  assert.ok(finish.indexOf('store.save(batch') < finish.indexOf('try persist(next)'));
  assert.match(finish, /断点写入失败.*去重重扫/);
});
test('iOS launch persists no-source terminal and rechecks source before and after comment buffering', () => {
  const launch = body('private func launch()', 'func saveVisiblePage()');
  assert.match(launch, /next\.searchExhausted = targets\.isEmpty/);
  assert.match(launch, /不是零评论结果/);
  assert.ok(launch.indexOf('sourceProof(for: target)') < launch.indexOf('scanComments(for: target)'));
  assert.ok(launch.lastIndexOf('sourceProof(for: target)') > launch.indexOf('scanComments(for: target)'));
});
test('iOS manual save cannot bypass source gate or sort unknown dates into latest results', () => {
  const manual = body('func saveVisiblePage()', 'private func recordNavigation(');
  assert.equal((manual.match(/sourceProof\(for: target\)/g) || []).length, 2);
  assert.match(manual, /Self\.selectedComments\(buffer/);
  assert.match(manual, /row\.merge\(finalProof\.rowFields\) \{ _, verified in verified \}/);
  assert.match(manual, /store\.save\(manual, requireRecentSource: true\)/);
});


test('search scroll waits for ready and explicit empty results finish without pointless scrolling', () => {
  const discover=body('private func discoverSources()', 'func start(keyword:');
  assert.match(discover,/waitFor\("search_advance", timeout: 12\)/);
  assert.match(discover,/if result\["explicitEmpty"\] as\? Bool == true \|\|/);
  assert.doesNotMatch(discover,/evaluate\("search_advance"\)/);
});

test('source discovery expands 7 then 30 then 90 only when fewer than five sources are verified',()=>{
 const discover=body('private func discoverSources()', 'func start(keyword:');
 assert.match(discover,/for window in \[7, 30, 90\]/);
 assert.match(discover,/if verified\.count >= 5 \{ break \}/);
 assert.match(discover,/sourceWindowDays = window/);
 assert.match(discover,/eligible\(detail, now: Date\(\), windowDays: window\)/);
 assert.match(discover,/!inspected\.contains\(identity\)/);
 assert.match(source,/"sourceWindowDays": sourceWindowDays/);
});
