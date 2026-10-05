#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SWIFT_COMPILER="$(xcrun --find swift)"
TEST_FLAGS=(--package-path "$PROJECT_DIR/macos")
# Some Command Line Tools releases omit the Swift Testing plugin when AppKit overlays are loaded.
# Resolve the installed toolchain rather than embedding an Xcode or SDK path.
for TESTING_PLUGIN in \
    "$(dirname "$SWIFT_COMPILER")/../lib/swift/host/plugins/testing/libTestingMacros.dylib" \
    "$(dirname "$SWIFT_COMPILER")/../lib/swift/host/plugins/libTestingMacros.dylib"; do
    if [ -f "$TESTING_PLUGIN" ]; then
        TEST_FLAGS+=(-Xswiftc -load-plugin-library -Xswiftc "$TESTING_PLUGIN")
        break
    fi
done
swift test "${TEST_FLAGS[@]}" "$@"
