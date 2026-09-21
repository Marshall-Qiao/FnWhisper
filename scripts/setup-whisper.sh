#!/bin/zsh

set -euo pipefail

MODEL_NAME="${1:-large-v3-turbo-q5_0}"
APP_SUPPORT_DIR="${FNWHISPER_APP_SUPPORT_DIR:-${HOME}/Library/Application Support/FnWhisper}"
MODEL_DIR="$APP_SUPPORT_DIR/Models"

case "$MODEL_NAME" in
    tiny)
        MODEL_SHA1="bd577a113a864445d4c299885e0cb97d4ba92b5f"
        ;;
    base)
        MODEL_SHA1="465707469ff3a37a2b9b8d8f89f2f99de7299dac"
        ;;
    small)
        MODEL_SHA1="55356645c2b361a969dfd0ef2c5a50d530afd8d5"
        ;;
    medium)
        MODEL_SHA1="fd9727b6e1217c2f614f9b698455c4ffd82463b4"
        ;;
    large-v3-q5_0)
        MODEL_SHA1="e6e2ed78495d403bef4b7cff42ef4aaadcfea8de"
        ;;
    large-v3-turbo-q5_0)
        MODEL_SHA1="e050f7970618a659205450ad97eb95a18d69c9ee"
        ;;
    *)
        print -u2 "不支持的模型：$MODEL_NAME"
        print -u2 "可选：tiny、base、small、medium、large-v3-q5_0、large-v3-turbo-q5_0"
        exit 2
        ;;
esac

if ! command -v brew >/dev/null 2>&1; then
    print -u2 "未找到 Homebrew。请先从 https://brew.sh 安装 Homebrew。"
    exit 1
fi

if ! command -v whisper-cli >/dev/null 2>&1 \
    || ! command -v whisper-server >/dev/null 2>&1; then
    if brew list --versions whisper-cpp >/dev/null 2>&1; then
        print "正在通过 Homebrew 升级 whisper.cpp，以提供 whisper-server…"
        brew upgrade whisper-cpp
    else
        print "正在通过 Homebrew 安装开源 whisper.cpp…"
        brew install whisper-cpp
    fi
fi

if ! command -v whisper-cli >/dev/null 2>&1; then
    print -u2 "whisper.cpp 安装后仍未找到 whisper-cli。"
    exit 1
fi
if ! command -v whisper-server >/dev/null 2>&1; then
    print -u2 "whisper.cpp 安装后仍未找到 whisper-server；无法启用常驻模型加速。"
    exit 1
fi

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/ggml-$MODEL_NAME.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL_NAME.bin"

if [[ -f "$MODEL_PATH" ]]; then
    EXISTING_SHA1="$(shasum -a 1 "$MODEL_PATH" | awk '{print $1}')"
    if [[ "$EXISTING_SHA1" == "$MODEL_SHA1" ]]; then
        print "Whisper 模型已存在并通过校验：$MODEL_PATH"
        exit 0
    fi
    print -u2 "已有模型校验不一致，将重新下载。"
fi

TEMP_MODEL_PATH="$MODEL_PATH.download"
trap 'rm -f "$TEMP_MODEL_PATH"' EXIT

print "正在下载 Whisper $MODEL_NAME 多语言模型…"
curl --fail --location --retry 3 --progress-bar \
    "$MODEL_URL" \
    --output "$TEMP_MODEL_PATH"

DOWNLOADED_SHA1="$(shasum -a 1 "$TEMP_MODEL_PATH" | awk '{print $1}')"
if [[ "$DOWNLOADED_SHA1" != "$MODEL_SHA1" ]]; then
    print -u2 "模型 SHA-1 校验失败。"
    print -u2 "期望：$MODEL_SHA1"
    print -u2 "实际：$DOWNLOADED_SHA1"
    exit 1
fi

mv "$TEMP_MODEL_PATH" "$MODEL_PATH"
trap - EXIT
print "Whisper 环境已准备完成：$MODEL_PATH"
