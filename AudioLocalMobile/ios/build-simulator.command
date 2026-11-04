#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodebuild >/dev/null; then
  echo "需要 macOS 上的完整 Xcode。此脚本不会绕过签名、注册设备或接受开发者协议。"
  exit 1
fi
xcodebuild -project AudioLocal.xcodeproj -scheme AudioLocal \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
echo "这只是模拟器构建，不是可分发安装的 IPA。真机签名请在 Xcode 中选择自己的 Team。"
