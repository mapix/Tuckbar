#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/settings-tests artifacts
swiftc -target arm64-apple-macosx14.0 -parse-as-library \
  Ice/UI/IceBar/MenuYSettingsCore.swift Tests/MenuYSettingsTests.swift \
  -o build/settings-tests/core-tests
build/settings-tests/core-tests | tee artifacts/settings-core-tests.txt
swiftc -target arm64-apple-macosx14.0 -parse-as-library \
  Ice/UI/IceBar/MenuYSettingsCore.swift Ice/UI/IceBar/MenuYPreferences.swift \
  Tests/MenuYPreferencesRuntimeTests.swift -o build/settings-tests/preferences-tests
build/settings-tests/preferences-tests | tee artifacts/settings-preferences-tests.txt
