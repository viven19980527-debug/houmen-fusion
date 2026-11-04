#!/bin/bash
# Reproducible fusion checks and unsigned device build. Never launches live collection.
set -Eeuo pipefail
cd "$(dirname "$0")"
IOS_ROOT="$PWD"
mkdir -p build
RUN_DIR="$(mktemp -d "$IOS_ROOT/build/fusion-XXXXXX")"
export IOS_ROOT RUN_DIR
export FUSION_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EVENTS="$RUN_DIR/checks.jsonl"
export EVENTS
: > "$EVENTS"
exec > >(tee "$RUN_DIR/pipeline.log") 2>&1

record() {
  python3 - "$1" "$2" <<'PY'
import datetime,json,os,sys
with open(os.environ['EVENTS'],'a',encoding='utf8') as stream:
    stream.write(json.dumps({'check':sys.argv[1],'exit_code':int(sys.argv[2]),
        'status':'passed' if sys.argv[2]=='0' else 'failed',
        'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat()})+'\n')
PY
}

run() {
  local name="$1"; shift
  echo "=== $name ==="
  set +e
  "$@" 2>&1 | tee "$RUN_DIR/$name.log"
  local statuses=("${PIPESTATUS[@]}")
  set -e
  local rc="${statuses[0]}"
  if [ "$rc" -eq 0 ] && [ "${statuses[1]}" -ne 0 ]; then rc="${statuses[1]}"; fi
  record "$name" "$rc"
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
}

finish() {
  local rc=$?
  trap - EXIT
  set +e
  python3 - "$rc" <<'PY'
import datetime,hashlib,json,os,plistlib,re,shutil,subprocess,sys
from pathlib import Path
ios=Path(os.environ['IOS_ROOT']); run=Path(os.environ['RUN_DIR']); root=ios.parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
events=[json.loads(line) for line in Path(os.environ['EVENTS']).read_text().splitlines() if line]
files={}
for folder in [ios/'AudioLocal',ios/'AudioLocal.xcodeproj',ios/'Verification',root/'tests',root/'vendor',root/'tools']:
    for file in sorted(folder.rglob('*')):
        if file.is_file(): files[str(file.relative_to(root)).replace('\\','/')]=sha(file)
for file in [root/'package.json',root/'package-lock.json',root.parent/'codemagic.yaml',ios/'verify-fusion.sh']:
    if file.is_file():files[str(file.relative_to(root.parent)).replace('\\','/')]=sha(file)
tree=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest()
# A ZIP checkout need not be a Git repository. Never mislabel an ancestor repo as this source.
commit=None
for candidate in [root,root.parent]:
    if (candidate/'.git').exists():
        result=subprocess.run(['git','-C',str(candidate),'rev-parse','HEAD'],capture_output=True,text=True)
        if result.returncode==0:commit=result.stdout.strip()
        break
info=plistlib.loads((ios/'AudioLocal/Info.plist').read_bytes())
bundle_ids=set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*"?([^";\s]+)"?\s*;', (ios/'AudioLocal.xcodeproj/project.pbxproj').read_text()))
resolved_bundle_id=next(iter(bundle_ids)) if len(bundle_ids)==1 else None
ipa=ios/'build/HoumenFusion-unsigned.ipa'
published=any(e['check']=='publish-ipa' and e['status']=='passed' for e in events)
meta={'app':'Houmen Fusion','bundle_id':resolved_bundle_id,
 'source_bundle_id_template':info['CFBundleIdentifier'],
 'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
 'started_at':os.environ['FUSION_STARTED_AT'],'finished_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),
 'exit_code':int(sys.argv[1]),'status':'passed' if sys.argv[1]=='0' else 'failed',
 'source_commit':commit,'source_tree_sha256':tree,'source_files':files,
 'source_manifest_sha256':sha(root.parent/'source-manifest.json') if (root.parent/'source-manifest.json').is_file() else None,
 'codemagic_build_id':os.environ.get('CM_BUILD_ID'),'signed':False,
 'checks':events,'device_install':'not_tested','live_platform_collection':'not_tested',
 'simulator_ui':'not_run','simulator_build':'passed' if any(e['check']=='simulator-build' and e['status']=='passed' for e in events) else 'not_run',
 'ipa_sha256':sha(ipa) if published else None,'ipa_bytes':ipa.stat().st_size if published else None,
 'limitations':['Node tests include synthetic DOM and static source assertions, not device behavior.',
 'Foundation fixture execution and Xcode compilation are separate measured checks.',
 'Unsigned IPA requires user-controlled signing; no live account, platform or device verification is implied.',
 'Inherited verification/cloud files are historical only; this record describes only this invocation.']}
payload=json.dumps(meta,ensure_ascii=False,indent=2)
(run/'provenance.json').write_text(payload,encoding='utf8')
dest=ios/'build/fusion-provenance.json'
if dest.exists():shutil.copy2(dest,run/'previous-provenance.json')
temp=dest.with_suffix('.json.tmp');temp.write_text(payload,encoding='utf8');os.replace(temp,dest)
print(json.dumps({'status':meta['status'],'exit_code':meta['exit_code'],'checks':len(events),
 'source_tree_sha256':tree,'ipa_sha256':meta['ipa_sha256']},ensure_ascii=False))
PY
  local report_rc=$?
  if [ "$rc" -eq 0 ] && [ "$report_rc" -ne 0 ]; then rc="$report_rc"; fi
  exit "$rc"
}
trap finish EXIT

run metadata-lint plutil -lint AudioLocal/Info.plist AudioLocal/PrivacyInfo.xcprivacy AudioLocal.xcodeproj/project.pbxproj
run release-identity python3 - <<'PY'
import json,plistlib,subprocess
p=plistlib.load(open('AudioLocal/Info.plist','rb'))
assert p['CFBundleShortVersionString']=='0.2.0'
assert p['CFBundleVersion']=='10'
assert p['CFBundleIdentifier']=='$(PRODUCT_BUNDLE_IDENTIFIER)'
project=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-','AudioLocal.xcodeproj/project.pbxproj']))
configs=[obj for obj in project['objects'].values() if obj.get('isa')=='XCBuildConfiguration'
         and 'PRODUCT_BUNDLE_IDENTIFIER' in obj.get('buildSettings',{})]
assert len(configs)==2 and {obj['name'] for obj in configs}=={'Debug','Release'}
for obj in configs:
    values=obj['buildSettings']
    assert values['PRODUCT_BUNDLE_IDENTIFIER']=='cn.shengxun.local'
    assert str(values['CURRENT_PROJECT_VERSION'])=='10'
    assert values['MARKETING_VERSION']=='0.2.0'
print('Houmen Fusion 0.2.0 (10), preserved Debug/Release storage identity')
PY
run xcode-version xcodebuild -version
run node-dependencies npm --prefix "$IOS_ROOT/.." ci --ignore-scripts --no-audit --no-fund
run protocol-bundle node ../tools/build-ios-protocol.mjs --check
run node-tests npm --prefix "$IOS_ROOT/.." test

COMMON=(AudioLocal/CollectionPlatform.swift AudioLocal/CommentStore.swift AudioLocal/LeadAssessment.swift AudioLocal/CommentRecency.swift)
native_check() {
  local name="$1"; shift
  run "compile-$name" xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library "$@" -o "$RUN_DIR/$name"
  run "$name" "$RUN_DIR/$name"
}
native_check local-store "${COMMON[@]}" Verification/LeadAssessmentChecks.swift Verification/LocalStoreChecks.swift
native_check navigation AudioLocal/NavigationPolicy.swift Verification/NavigationPolicyChecks.swift
native_check navigation-load AudioLocal/NavigationLoadState.swift Verification/NavigationLoadChecks.swift
native_check collection-job "${COMMON[@]}" AudioLocal/CollectionJob.swift Verification/CollectionJobChecks.swift
native_check recency "${COMMON[@]}" Verification/RecencyChecks.swift
native_check platforms AudioLocal/CollectionPlatform.swift Verification/PlatformChecks.swift
native_check comment-polling "${COMMON[@]}" AudioLocal/CollectionJob.swift Verification/CommentPollingChecks.swift
native_check profile-snapshots AudioLocal/CollectionPlatform.swift AudioLocal/ProfileSnapshotStore.swift Verification/ProfileSnapshotChecks.swift
native_check fusion-leads "${COMMON[@]}" AudioLocal/FusionLead.swift AudioLocal/FusionLeadStore.swift Verification/FusionLeadChecks.swift
native_check fusion-bili "${COMMON[@]}" AudioLocal/FusionLead.swift AudioLocal/FusionBiliClient.swift Verification/FusionBiliChecks.swift

run iphoneos-build xcodebuild -project AudioLocal.xcodeproj -scheme AudioLocal -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$RUN_DIR/device" \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
APP="$RUN_DIR/device/Build/Products/Release-iphoneos/AudioLocal.app"
run binary-architecture xcrun lipo "$APP/AudioLocal" -verify_arch arm64
run embedded-metadata plutil -lint "$APP/Info.plist"
run embedded-identity python3 - "$APP/Info.plist" <<'PY'
import plistlib,sys
p=plistlib.load(open(sys.argv[1],'rb'))
assert p['CFBundleIdentifier']=='cn.shengxun.local'
assert p['CFBundleShortVersionString']=='0.2.0'
assert p['CFBundleVersion']=='10'
print('Compiled app has expected resolved bundle/version/build')
PY
for resource in collector-ios.js collector-xhs.js protocol-capture.js; do
  run "resource-$resource" cmp "AudioLocal/$resource" "$APP/$resource"
done
if [ "${FUSION_BUILD_SIMULATOR:-0}" = 1 ]; then
  run simulator-build xcodebuild -project AudioLocal.xcodeproj -scheme AudioLocal -configuration Debug \
    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath "$RUN_DIR/simulator" \
    ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build
fi
# Only package the exact successfully compiled app. No old archive reuse.
mkdir -p "$RUN_DIR/package/Payload"
run package-copy ditto "$APP" "$RUN_DIR/package/Payload/AudioLocal.app"
run package-zip bash -c 'cd "$1/package" && /usr/bin/zip -qry "$1/HoumenFusion-unsigned.ipa" Payload' _ "$RUN_DIR"
run publish-ipa python3 - <<'PY'
from pathlib import Path
import os,shutil,zipfile
ios=Path(os.environ['IOS_ROOT']);run=Path(os.environ['RUN_DIR'])
source=run/'HoumenFusion-unsigned.ipa';dest=ios/'build/HoumenFusion-unsigned.ipa'
with zipfile.ZipFile(source) as z:
    assert z.testzip() is None
    assert 'Payload/AudioLocal.app/AudioLocal' in z.namelist()
if dest.exists():shutil.copy2(dest,run/'previous-unsigned.ipa')
temp=dest.with_suffix('.ipa.tmp');shutil.copy2(source,temp);os.replace(temp,dest)
print('Published unsigned fusion IPA')
PY
