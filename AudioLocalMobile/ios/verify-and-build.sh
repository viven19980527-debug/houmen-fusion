#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/verification
exec > >(tee build/pipeline.log) 2>&1
plutil -lint AudioLocal/Info.plist AudioLocal/PrivacyInfo.xcprivacy AudioLocal.xcodeproj/project.pbxproj
xcodebuild -version | tee build/xcode-version.log
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  AudioLocal/CollectionPlatform.swift AudioLocal/CommentStore.swift AudioLocal/LeadAssessment.swift AudioLocal/CommentRecency.swift Verification/LeadAssessmentChecks.swift Verification/LocalStoreChecks.swift \
  -o build/verification/local-store-checks
build/verification/local-store-checks | tee build/store-checks.log
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  AudioLocal/NavigationPolicy.swift Verification/NavigationPolicyChecks.swift \
  -o build/verification/navigation-checks
build/verification/navigation-checks | tee build/navigation-checks.log
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  AudioLocal/NavigationLoadState.swift Verification/NavigationLoadChecks.swift \
  -o build/verification/navigation-load-checks
build/verification/navigation-load-checks | tee build/navigation-load-checks.log
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  AudioLocal/CollectionJob.swift AudioLocal/CommentRecency.swift AudioLocal/CollectionPlatform.swift AudioLocal/CommentStore.swift AudioLocal/LeadAssessment.swift Verification/CollectionJobChecks.swift \
  -o build/verification/job-checks
build/verification/job-checks | tee build/job-checks.log
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  AudioLocal/CommentRecency.swift AudioLocal/CollectionPlatform.swift AudioLocal/CommentStore.swift AudioLocal/LeadAssessment.swift Verification/RecencyChecks.swift \
  -o build/verification/recency-checks
build/verification/recency-checks | tee build/recency-checks.log
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  AudioLocal/CollectionPlatform.swift Verification/PlatformChecks.swift \
  -o build/verification/platform-checks
build/verification/platform-checks | tee build/platform-checks.log
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  AudioLocal/CollectionJob.swift AudioLocal/CommentRecency.swift AudioLocal/CollectionPlatform.swift AudioLocal/CommentStore.swift AudioLocal/LeadAssessment.swift Verification/CommentPollingChecks.swift \
  -o build/verification/comment-polling-checks
build/verification/comment-polling-checks | tee build/comment-polling-checks.log
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  AudioLocal/CollectionPlatform.swift AudioLocal/ProfileSnapshotStore.swift Verification/ProfileSnapshotChecks.swift \
  -o build/verification/profile-snapshot-checks
build/verification/profile-snapshot-checks | tee build/profile-snapshot-checks.log
xcodebuild -project AudioLocal.xcodeproj -scheme AudioLocal -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/device \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build 2>&1 | tee build/iphoneos-build.log
APP=build/device/Build/Products/Release-iphoneos/AudioLocal.app
test -f "$APP/AudioLocal"
test -f "$APP/collector-ios.js"
cmp AudioLocal/collector-ios.js "$APP/collector-ios.js"
cmp AudioLocal/collector-xhs.js "$APP/collector-xhs.js"
cmp AudioLocal/protocol-capture.js "$APP/protocol-capture.js"
file "$APP/AudioLocal" | tee build/binary-check.log
xcrun lipo "$APP/AudioLocal" -verify_arch arm64
plutil -lint "$APP/Info.plist"
xcodebuild -project AudioLocal.xcodeproj -scheme AudioLocal -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/simulator ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build 2>&1 | tee build/simulator-build.log
python3 Verification/simulator-smoke.py
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/AudioLocal.app
(cd build/package && /usr/bin/zip -qry ../ShengxunLocal-unsigned.ipa Payload)
python3 - <<'PY'
import hashlib,json,os,plistlib,subprocess
from pathlib import Path
root=Path.cwd()
ipa=root/'build/ShengxunLocal-unsigned.ipa'
app=root/'build/device/Build/Products/Release-iphoneos/AudioLocal.app'
info=plistlib.loads((app/'Info.plist').read_bytes())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
data={
 "app":"ShengxunLocal","bundle_id":info["CFBundleIdentifier"],
 "version":info["CFBundleShortVersionString"],"build":info["CFBundleVersion"],
 "minimum_ios":info["MinimumOSVersion"],
 "source_commit":subprocess.check_output(["git","rev-parse","HEAD"],text=True).strip(),
 "codemagic_build_id":os.environ.get("CM_BUILD_ID"),
 "xcode":subprocess.check_output(["xcodebuild","-version"],text=True).strip(),
 "iphoneos_sdk":subprocess.check_output(["xcrun","--sdk","iphoneos","--show-sdk-version"],text=True).strip(),
 "ipa_sha256":sha(ipa),"ipa_bytes":ipa.stat().st_size,
 "executable_sha256":sha(app/"AudioLocal"),
 "collector_sha256":sha(app/"collector-ios.js"),"collector_xhs_sha256":sha(app/"collector-xhs.js"),
 "protocol_capture_sha256":sha(app/"protocol-capture.js"),
 "signed":False,"distribution":"unsigned IPA; needs user-controlled signing",
 "checks":{"source_publication_gate":"passed_native_fixtures","latest_search":"passed_synthetic_dom_only","platform_links":"passed","xiaohongshu_live":"not_tested","channels_collection":"not_implemented","recency_filters":"passed","native_store":"passed","navigation_policy":"passed","navigation_load_state":"passed_native_fixtures","https_upgrade_budget":"passed_native_fixtures","job_checkpoint":"passed","iphoneos_release":"passed","simulator_build_only":"passed",
           "device_install":"not_tested","live_comments":"not_tested"},
 "source_files":{str(f.relative_to(root.parent)):sha(f)
                 for folder in [root/"AudioLocal"]
                 for f in sorted(folder.rglob("*")) if f.is_file()}
}
(root/'build/provenance.json').write_text(json.dumps(data,indent=2,ensure_ascii=False),encoding="utf8")
print(json.dumps({k:data[k] for k in ["source_commit","ipa_sha256","ipa_bytes","checks"]},indent=2))
PY
