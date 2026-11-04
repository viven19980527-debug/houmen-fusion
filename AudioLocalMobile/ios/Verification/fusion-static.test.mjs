// Static integration guards only. These do not compile or execute Swift/iOS code.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
const ios = new URL('../', import.meta.url);
const read = path => readFileSync(new URL(path, ios), 'utf8');
const project = read('AudioLocal.xcodeproj/project.pbxproj');
const script = read('verify-fusion.sh');
const source = file => read(`AudioLocal/${file}.swift`);

test('static fusion release metadata agrees on 0.2.0 build 10 and preserves identity', () => {
  assert.equal(JSON.parse(read('../package.json')).version, '0.2.0');
  const lock = JSON.parse(read('../package-lock.json'));
  assert.equal(lock.version, '0.2.0');
  assert.equal(lock.packages[''].version, '0.2.0');
  const info = read('AudioLocal/Info.plist');
  assert.match(info, /<key>CFBundleShortVersionString<\/key><string>0\.2\.0<\/string>/);
  assert.match(info, /<key>CFBundleVersion<\/key><string>10<\/string>/);
  assert.match(info, /<key>CFBundleIdentifier<\/key><string>\$\(PRODUCT_BUNDLE_IDENTIFIER\)<\/string>/);
  assert.equal([...project.matchAll(/PRODUCT_BUNDLE_IDENTIFIER = cn\.shengxun\.local;/g)].length, 2);
  assert.equal([...project.matchAll(/CURRENT_PROJECT_VERSION = 10;/g)].length, 2);
  assert.equal([...project.matchAll(/MARKETING_VERSION = 0\.2\.0;/g)].length, 2);
});

test('static fusion Xcode source references link every new Swift file exactly once', () => {
  const files = ['FusionLead', 'FusionLeadStore', 'FusionBiliClient', 'FusionWorkspaceView', 'FusionLeadDetailView', 'FusionRadarView'];
  const phase = project.match(/isa = PBXSourcesBuildPhase;[^}]*files = \(([^)]*)\)/)?.[1];
  const group = project.match(/isa = PBXGroup; children = \(([^)]*)\); path = AudioLocal;/)?.[1];
  assert.ok(phase && group);
  for (const name of files) {
    assert.ok(existsSync(new URL(`AudioLocal/${name}.swift`, ios)), name);
    const refs = [...project.matchAll(new RegExp(`([A-F0-9]{24}) = \\{isa = PBXFileReference;[^}]*path = ${name}\\.swift;`, 'g'))];
    assert.equal(refs.length, 1, name);
    const id = refs[0][1];
    const builds = [...project.matchAll(new RegExp(`([A-F0-9]{24}) = \\{isa = PBXBuildFile; fileRef = ${id};`, 'g'))];
    assert.equal(builds.length, 1, name);
    assert.equal(group.split(',').filter(x => x === id).length, 1, name);
    assert.equal(phase.split(',').filter(x => x === builds[0][1]).length, 1, name);
  }
});

test('static fusion entry preserves original store and wires three app tabs', () => {
  const app = source('AudioLocalApp');
  assert.match(app, /@StateObject private var store = CommentStore\(\)/);
  assert.match(app, /@StateObject private var fusion = FusionLeadStore\(\)/);
  assert.match(app, /HomeView\(\)\.environmentObject\(store\)/);
  assert.match(app, /FusionRadarView\(\)\.environmentObject\(fusion\)/);
  assert.match(app, /FusionWorkspaceView\(\)\.environmentObject\(store\)\.environmentObject\(fusion\)/);
  assert.equal([...app.matchAll(/\.tabItem\b/g)].length, 3);
});

test('static fusion import/export wiring retains scoped access and bounded import', () => {
  const view = source('FusionWorkspaceView');
  assert.match(view, /allowedContentTypes: \[\.json\]/);
  assert.match(view, /startAccessingSecurityScopedResource\(\)/);
  assert.match(view, /defer \{ if access \{ url\.stopAccessingSecurityScopedResource\(\) \} \}/);
  assert.match(view, /guard size <= FusionLeadStore\.maximumImportBytes/);
  assert.match(view, /read\(upToCount: FusionLeadStore\.maximumImportBytes \+ 1\)/);
  assert.match(view, /fusion\.importJSON\(data:/);
  assert.match(view, /fusion\.exportCSV\(rows: rows\)/);
  assert.match(view, /fusion\.exportJSON\(rows: rows\)/);
});

test('static fusion detail uses validated links rather than raw imported URL strings', () => {
  const view = source('FusionLeadDetailView');
  assert.match(view, /if let url = lead\.sourceLink/);
  assert.match(view, /if let url = lead\.profileLink/);
  assert.doesNotMatch(view, /URL\(string: lead\./);
  assert.match(view, /fusion\.update\(id: lead\.id, status: status, note: note\)/);
});

test('static fusion radar cancels on disappearance and propagates store errors', () => {
  const view = source('FusionRadarView');
  const client = source('FusionBiliClient');
  assert.match(view, /\.onDisappear\(perform: stop\)/);
  assert.match(view, /searchTask\?\.cancel\(\); client\.cancel\(\)/);
  assert.match(view, /try fusion\.add\(rows\)/);
  assert.match(client, /onBatch: @escaping \(\[FusionLead\]\) throws -> Int/);
  assert.match(client, /withTaskCancellationHandler/);
  assert.match(client, /activeSession\?\.invalidateAndCancel\(\)/);
});

test('static fusion workflow calls real tests and has failure propagation guards', () => {
  const workflow = read('../../codemagic.yaml');
  assert.match(workflow, /bash AudioLocalMobile\/ios\/verify-fusion\.sh/);
  assert.doesNotMatch(workflow, /skipped|skip.tests|export-ipa-only|verify-and-build/);
  assert.match(script, /set -Eeuo pipefail/);
  assert.match(script, /PIPESTATUS\[@\]/);
  assert.match(script, /return "\$rc"/);
  assert.match(script, /ci --ignore-scripts --no-audit --no-fund/);
  assert.match(script, /run node-tests npm .* test/);
  assert.match(script, /run embedded-identity python3/);
  assert.match(script, /run iphoneos-build xcodebuild/);
  assert.match(script, /'simulator_ui':'not_run'/);
  assert.match(script, /'device_install':'not_tested'/);
  assert.match(script, /published=any\(e\['check'\]=='publish-ipa'/);
  assert.match(script, /'source_tree_sha256':tree/);
  assert.doesNotMatch(script, /\r/);
});

test('static fusion native fixture inputs exist and both fusion checks are wired', () => {
  assert.match(script, /native_check fusion-leads .*Verification\/FusionLeadChecks\.swift/);
  assert.match(script, /native_check fusion-bili .*Verification\/FusionBiliChecks\.swift/);
  const files = new Set([...script.matchAll(/(?:AudioLocal|Verification)\/[A-Za-z0-9]+\.swift/g)].map(x => x[0]));
  assert.ok(files.size > 20);
  for (const file of files) assert.ok(existsSync(new URL(file, ios)), file);
  for (const file of ['FusionLeadChecks', 'FusionBiliChecks']) {
    const check = read(`Verification/${file}.swift`);
    assert.match(check, /@main/);
    assert.match(check, /static func main\(\) throws/);
  }
});
