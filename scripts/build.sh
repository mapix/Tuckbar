#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
menuy_build_dir="${MENUY_DERIVED_DATA:-build/DerivedData}"
case "$menuy_build_dir" in /*) ;; *) menuy_build_dir="$PWD/$menuy_build_dir";; esac
xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Release \
  -derivedDataPath "$menuy_build_dir" -clonedSourcePackagesDirPath build/Packages \
  DEVELOPMENT_TEAM="${MENUY_TEAM:-BDH2HLQA9V}" CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="${MENUY_SIGN_IDENTITY:-Developer ID Application: Weifeng Luo (BDH2HLQA9V)}" \
  ENABLE_USER_SCRIPT_SANDBOXING=NO SWIFT_ACTIVE_COMPILATION_CONDITIONS="${MENUY_SWIFT_FLAGS:-}" build > artifacts/build.log 2>&1 || {
    tail -70 artifacts/build.log; exit 1;
  }
codesign --verify --deep --strict "$menuy_build_dir/Build/Products/Release/MacMenuY.app"
printf '%s\n' "$menuy_build_dir/Build/Products/Release/MacMenuY.app"
