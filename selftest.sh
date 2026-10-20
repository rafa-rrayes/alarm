#!/bin/bash
# Builds and runs the self-test against the real modules (everything except the
# SwiftUI layer). Briefly blocks input for ~1s and nudges the system volume,
# restoring both. Run it from a terminal that has Accessibility permission.
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc -parse-as-library \
    -target "$(uname -m)-apple-macos14.0" \
    -o build/selftest \
    Sources/AlarmSettings.swift \
    Sources/SystemVolume.swift \
    Sources/SleepBlocker.swift \
    Sources/InputBlocker.swift \
    Sources/OverlayWindow.swift \
    Sources/AudioEngine.swift \
    Tools/SelfTest.swift

exec build/selftest
