#!/bin/bash
# User explicitly requested direct export without further tests.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
exec > >(tee build/pipeline.log) 2>&1
plutil -lint AudioLocal/Info.plist AudioLocal/PrivacyInfo.xcprivacy AudioLocal.xcodeproj/project.pbxproj
xcodebuild -version | tee build/xcode-version.log
xcodebuild -project AudioLocal.xcodeproj -scheme AudioLocal -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/device \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build 2>&1 | tee build/iphoneos-build.log
APP=build/device/Build/Products/Release-iphoneos/AudioLocal.app
test -f "$APP/AudioLocal"
for resource in collector-ios.js collector-xhs.js protocol-capture.js; do
  cmp "AudioLocal/$resource" "$APP/$resource"
done
file "$APP/AudioLocal" | tee build/binary-check.log
xcrun lipo "$APP/AudioLocal" -verify_arch arm64
plutil -lint "$APP/Info.plist"
mkdir -p build/package/Payload
ditto "$APP" build/package/Payload/AudioLocal.app
(cd build/package && /usr/bin/zip -qry ../ShengxunLocal-unsigned.ipa Payload)
python3 - <<'PY'
import hashlib,json,os,plistlib,subprocess
from pathlib import Path
root=Path.cwd();ipa=root/'build/ShengxunLocal-unsigned.ipa'
app=root/'build/device/Build/Products/Release-iphoneos/AudioLocal.app'
info=plistlib.loads((app/'Info.plist').read_bytes())
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
data={
 'app':'Houmen','bundle_id':info['CFBundleIdentifier'],
 'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion'],
 'minimum_ios':info['MinimumOSVersion'],
 'source_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'codemagic_build_id':os.environ.get('CM_BUILD_ID'),
 'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),
 'iphoneos_sdk':subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-version'],text=True).strip(),
 'ipa_sha256':sha(ipa),'ipa_bytes':ipa.stat().st_size,'executable_sha256':sha(app/'AudioLocal'),
 'collector_sha256':sha(app/'collector-ios.js'),'collector_xhs_sha256':sha(app/'collector-xhs.js'),
 'protocol_capture_sha256':sha(app/'protocol-capture.js'),
 'signed':False,'distribution':'unsigned IPA; needs user-controlled signing',
 'checks':{'iphoneos_release':'compiled','embedded_resources':'match_source',
 'native_tests':'skipped_user_requested_direct_export','regression_suite':'not_completed',
 'simulator_build':'skipped_user_requested_direct_export','device_install':'not_tested',
 'douyin_live':'not_tested','xiaohongshu_live':'not_tested'},
 'source_files':{str(p.relative_to(root.parent)):sha(p) for p in sorted((root/'AudioLocal').rglob('*')) if p.is_file()}
}
(root/'build/provenance.json').write_text(json.dumps(data,ensure_ascii=False,indent=2),encoding='utf8')
print(json.dumps({k:data[k] for k in ['version','build','ipa_sha256','ipa_bytes','checks']},indent=2))
PY
