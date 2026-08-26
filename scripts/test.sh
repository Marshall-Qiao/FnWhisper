#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/.build/core-tests"
TARGET_ARCHITECTURE="$(uname -m)"

mkdir -p "$TEST_BUILD_DIR/module-cache"
swiftc \
    -target "$TARGET_ARCHITECTURE-apple-macosx13.0" \
    -module-cache-path "$TEST_BUILD_DIR/module-cache" \
    "$PROJECT_DIR/Sources/FnWhisper/FnPressStateMachine.swift" \
    "$PROJECT_DIR/Sources/FnWhisper/AppConfiguration.swift" \
    "$PROJECT_DIR/Sources/FnWhisper/AudioRecorder.swift" \
    "$PROJECT_DIR/Sources/FnWhisper/WhisperTranscriber.swift" \
    "$PROJECT_DIR/Sources/FnWhisper/WhisperRuntime.swift" \
    "$PROJECT_DIR/Sources/FnWhisper/TextSpokenNumberNormalizer.swift" \
    "$PROJECT_DIR/Sources/FnWhisper/TextRefinement.swift" \
    "$PROJECT_DIR/Sources/FnWhisper/DictationProcessingRoute.swift" \
    "$PROJECT_DIR/Sources/FnWhisper/QwenTextRefiner.swift" \
    "$PROJECT_DIR/Tests/CoreTests/main.swift" \
    -framework AVFoundation \
    -o "$TEST_BUILD_DIR/FnWhisperCoreTests"

"$TEST_BUILD_DIR/FnWhisperCoreTests"
