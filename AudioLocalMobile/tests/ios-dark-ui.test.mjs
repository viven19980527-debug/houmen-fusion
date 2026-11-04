import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
const source = fs.readFileSync(new URL('../ios/AudioLocal/HomeView.swift', import.meta.url), 'utf8');
const app = fs.readFileSync(new URL('../ios/AudioLocal/AudioLocalApp.swift', import.meta.url), 'utf8');
const block = (start, end) => {
  const a = source.indexOf(start), b = source.indexOf(end, a + start.length);
  assert.ok(a >= 0 && b > a, `bounded section ${start}`);
  return source.slice(a, b);
};
test('dark UI uses guarded native iOS 26 glass and older-system material fallback', () => {
  const group = block('private struct NightGlassGroup', 'private struct NightSurface');
  assert.match(group, /if #available\(iOS 26\.0, \*\), !reduceTransparency/);
  assert.match(group, /GlassEffectContainer\(spacing: 8\)/);
  const surface = block('private struct NightSurface', 'private struct NightCard');
  assert.match(surface, /else if #available\(iOS 26\.0, \*\)/);
  assert.match(surface, /\.glassEffect\(\.regular\.tint/);
  assert.match(surface, /\.interactive\(interactive\)/);
  assert.match(surface, /\.background\(\.ultraThinMaterial/);
});
test('Reduce Transparency uses opaque surfaces before any material or glass', () => {
  for (const [start, end] of [['private struct NightSurface', 'private struct NightCard'],
                             ['private struct NightCard', 'private struct NightFormRow']]) {
    const surface = block(start, end);
    assert.ok(surface.indexOf('if reduceTransparency') < surface.indexOf('.ultraThinMaterial'));
    assert.match(surface, /content\.background\([^\n]*BackdoorTheme\.surface/);
  }
  const form = block('private struct NightFormRow', 'private struct NightPrimaryButtonStyle');
  assert.match(form, /if reduceTransparency \{ BackdoorTheme\.surface \}/);
  const backdrop = block('private struct NightBackdrop', 'private struct NightGlassGroup');
  assert.match(backdrop, /if !reduceTransparency/);
});
test('branding and every native presentation use one dark palette without changing persistence identifiers', () => {
  assert.match(source, /navigationTitle\("后门"\)/);
  assert.match(source, /后门-来源分档-评论/);
  assert.doesNotMatch(source, /声讯|audioTeal|\.background\(\.white/);
  assert.match(app, /struct AudioLocalApp: App/);
  assert.match(app, /@StateObject private var store = CommentStore\(\)/);
  assert.match(app, /\.preferredColorScheme\(\.dark\)/);
  assert.ok((source.match(/\.nightScreen\(\)/g) || []).length >= 6);
  assert.ok((source.match(/\.scrollContentBackground\(\.hidden\)/g) || []).length >= 3);
  assert.match(source, /\.toolbarColorScheme\(\.dark, for: \.navigationBar\)/);
});
test('home remains concise with one primary CTA and scalable accessible controls', () => {
  const controls = block('private var collectionControls:', 'private var actionsMenu:');
  assert.equal((controls.match(/NightPrimaryButtonStyle\(\)/g) || []).length, 1);
  assert.match(controls, /NightGlassGroup/);
  assert.match(controls, /近7天优先 · 最长90天/);
  assert.match(controls, /评论时间 · 来源最长90天/);
  assert.match(controls, /dynamicTypeSize\.isAccessibilitySize/);
  assert.match(controls, /DisclosureGroup\("关键词建议与最近搜索"/);
  assert.match(source, /accessibilityReduceMotion/);
  assert.match(source, /\.frame\(minWidth: 44, minHeight: 44\)/);
  assert.doesNotMatch(source, /minimumScaleFactor|\.font\(\.system\(size:/);
});
test('UI refactor preserves strict source gating and explicit historical backup semantics', () => {
  assert.match(source, /store\.comments\.filter \{ SourcePublicationGate\.sourceEligible\(\$0, now: sourceEligibilityNow\) \}/);
  assert.match(source, /historyBackup \? records : records\.filter \{ SourcePublicationGate\.sourceEligible\(\$0, now: now\) \}/);
  assert.match(source, /CommentRecency\.filteredAndSorted\(filteredBeforeTime, range: recency\)/);
  assert.match(source, /CommentRecency\.filterDemographics\(textMatches/);
  assert.match(source, /小红书尚未接通验收/);
  assert.match(source, /视频号未接通评论采集/);
});
test('dark native browser shell does not inject CSS or mutate platform page preferences', () => {
  const webView = block('private struct PlatformWebView:', '@MainActor\nprivate struct CollectorScreen');
  assert.match(webView, /func makeUIView\(context: Context\) -> WKWebView \{ webView \}/);
  assert.match(webView, /func updateUIView\(_ uiView: WKWebView, context: Context\) \{ \}/);
  assert.doesNotMatch(source, /evaluateJavaScript|WKUserScript|overrideUserInterfaceStyle|document\.body|style\.background/);
});
