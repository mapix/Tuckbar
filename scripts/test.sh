#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests artifacts
swiftc -parse-as-library Ice/UI/IceBar/DrawerGeometry.swift Tests/GeometryTests.swift -o build/tests/geometry-tests
build/tests/geometry-tests | tee artifacts/geometry-tests.txt
swiftc -parse-as-library Ice/Bridging/CGWindowID+SafeInit.swift Tests/WindowIDTests.swift -o build/tests/window-id-tests
build/tests/window-id-tests | tee artifacts/window-id-tests.txt
fixture=build/tests/MenuYFixture.app
mkdir -p "$fixture/Contents/MacOS"
swiftc -parse-as-library Tests/MenuFixture.swift -o "$fixture/Contents/MacOS/MenuYFixture"
cat > "$fixture/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.novarock.MacMenuY.Fixture</string>
<key>CFBundleExecutable</key><string>MenuYFixture</string>
<key>CFBundleName</key><string>MenuY Fixture</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign 'Developer ID Application: Weifeng Luo (BDH2HLQA9V)' "$fixture"
