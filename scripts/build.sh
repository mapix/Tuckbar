#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
menuy_build_dir="${MENUY_DERIVED_DATA:-build/DerivedData}"
case "$menuy_build_dir" in /*) ;; *) menuy_build_dir="$PWD/$menuy_build_dir";; esac
SIGN_ID="${MENUY_SIGN_IDENTITY:-Developer ID Application: Weifeng Luo (BDH2HLQA9V)}"
xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Release \
  -derivedDataPath "$menuy_build_dir" -clonedSourcePackagesDirPath build/Packages \
  DEVELOPMENT_TEAM="${MENUY_TEAM:-BDH2HLQA9V}" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_USER_SCRIPT_SANDBOXING=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS="${MENUY_SWIFT_FLAGS:-}" build > artifacts/build.log 2>&1 || {
    tail -70 artifacts/build.log; exit 1;
  }

APP="$menuy_build_dir/Build/Products/Release/MacMenuY.app"
sign_nested() {
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements,requirements,flags --sign "$SIGN_ID" "$@"
}
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
if [ -d "$SP" ]; then
  [ -d "$SP/XPCServices/Installer.xpc" ] && sign_nested "$SP/XPCServices/Installer.xpc"
  [ -d "$SP/XPCServices/Downloader.xpc" ] && sign_nested "$SP/XPCServices/Downloader.xpc"
  [ -f "$SP/Autoupdate" ] && sign_nested "$SP/Autoupdate"
  [ -d "$SP/Updater.app" ] && sign_nested "$SP/Updater.app"
  sign_nested "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --options runtime --timestamp --entitlements Ice/Ice.entitlements --sign "$SIGN_ID" "$APP"
codesign --verify --deep --strict "$APP"
printf '%s\n' "$APP"
