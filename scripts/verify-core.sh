#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests artifacts
bash scripts/test-settings.sh
swiftc -parse-as-library Ice/UI/IceBar/MenuYBarGeometry.swift Tests/MenuYBarGeometryTests.swift -o build/tests/bar-geometry-tests
build/tests/bar-geometry-tests | tee artifacts/bar-geometry-tests.txt
swiftc -parse-as-library Ice/UI/IceBar/MenuYBackplate.swift Tests/MenuYBackplateTests.swift -o build/tests/backplate-tests
build/tests/backplate-tests | tee artifacts/backplate-tests.txt
swiftc -parse-as-library Ice/UI/IceBar/MenuYHoverPolicy.swift Tests/MenuYHoverTests.swift -o build/tests/hover-tests
build/tests/hover-tests | tee artifacts/hover-tests.txt
swiftc -parse-as-library Ice/Bridging/CGWindowID+SafeInit.swift Tests/WindowIDTests.swift -o build/tests/window-id-tests
build/tests/window-id-tests | tee artifacts/window-id-tests.txt
swiftc -parse-as-library Ice/MenuBar/MenuBarItems/NativeInteractionPolicy.swift Tests/NativeInteractionPolicyTests.swift -o build/tests/native-policy-tests
build/tests/native-policy-tests | tee artifacts/native-policy-tests.txt
swiftc -parse-as-library Ice/MenuBar/MenuBarItems/NativeInteractionLifecycle.swift Ice/MenuBar/MenuBarItems/MenuBarStableIdentity.swift Ice/MenuBar/MenuBarItems/NativeInteractionPolicy.swift Tests/NativeLifecycleIdentityTests.swift -o build/tests/native-lifecycle-tests
build/tests/native-lifecycle-tests | tee artifacts/native-lifecycle-tests.txt

swiftc -parse-as-library Ice/MenuBar/MenuBarItems/NativeReturnEvidence.swift Tests/NativeReturnEvidenceTests.swift -o build/tests/native-return-tests
build/tests/native-return-tests | tee artifacts/native-return-tests.txt
swiftc -parse-as-library Ice/MenuBar/MenuBarItems/NativeEventCompletion.swift Tests/NativeEventCompletionTests.swift -o build/tests/native-event-tests
build/tests/native-event-tests | tee artifacts/native-event-tests.txt

swiftc -parse-as-library Ice/MenuBar/MenuBarItems/NativeRestorationJournal.swift Ice/MenuBar/MenuBarItems/NativeInteractionLifecycle.swift Tests/NativeRestorationJournalTests.swift -o build/tests/restoration-journal-tests
build/tests/restoration-journal-tests | tee artifacts/restoration-journal-tests.txt
