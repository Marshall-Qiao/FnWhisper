#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "用法：$0 /absolute/path/to/audio.wav"
    exit 2
fi

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD_DIR="$PROJECT_DIR/.build/whisper-smoke-test"
TARGET_ARCHITECTURE="$(uname -m)"
WHISPER_CLI="${FNWHISPER_WHISPER_CLI:-$(command -v whisper-cli || true)}"
MODEL_PATH="${FNWHISPER_MODEL:-${HOME}/Library/Application Support/FnWhisper/Models/ggml-large-v3-q5_0.bin}"
AUDIO_PATH="$1"

if [[ -z "$WHISPER_CLI" || ! -x "$WHISPER_CLI" ]]; then
    print -u2 "未找到 whisper-cli。"
    exit 1
fi
if [[ ! -f "$MODEL_PATH" ]]; then
    print -u2 "未找到模型：$MODEL_PATH"
    exit 1
fi
if [[ ! -f "$AUDIO_PATH" ]]; then
    print -u2 "未找到音频：$AUDIO_PATH"
    exit 1
fi

mkdir -p "$TEST_BUILD_DIR/module-cache"
swiftc \
    -target "$TARGET_ARCHITECTURE-apple-macosx13.0" \
    -module-cache-path "$TEST_BUILD_DIR/module-cache" \
    "$PROJECT_DIR/Sources/FnWhisper/WhisperTranscriber.swift" \
    "$PROJECT_DIR/Tests/WhisperCLISmoke/main.swift" \
    -o "$TEST_BUILD_DIR/FnWhisperCLISmoke"

"$TEST_BUILD_DIR/FnWhisperCLISmoke" \
    "$WHISPER_CLI" \
    "$MODEL_PATH" \
    "$AUDIO_PATH"
