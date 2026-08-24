#!/bin/zsh

set -euo pipefail

APP_SUPPORT_DIR="${FNWHISPER_APP_SUPPORT_DIR:-${HOME}/Library/Application Support/FnWhisper}"
MODEL_NAME="sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
MODEL_DIR="$APP_SUPPORT_DIR/Models/$MODEL_NAME"
MODEL_PATH="$MODEL_DIR/model.int8.onnx"
ARCHIVE_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/punctuation-models/$MODEL_NAME.tar.bz2"
ARCHIVE_SHA256="c0d5aa5f8eeb686032345e180bedf39319dc2e0556781c6264bcadba8328a6e1"
MODEL_SHA256="65a3fb9f5ad7bfb96bf69e0dc4481df97f6ee60513c1d94ce981ba6effd524b1"

if [[ -f "$MODEL_PATH" ]]; then
    EXISTING_SHA256="$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')"
    if [[ "$EXISTING_SHA256" == "$MODEL_SHA256" ]]; then
        print "CT-Punc INT8 模型已存在并通过校验：$MODEL_PATH"
        exit 0
    fi
    print -u2 "已有 CT-Punc 模型校验不一致，将重新下载。"
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/FnWhisper-punctuation.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
ARCHIVE_PATH="$TEMP_DIR/$MODEL_NAME.tar.bz2"

print "正在下载 sherpa-onnx CT-Punc INT8 中英文标点模型…"
curl --fail --location --retry 3 --progress-bar \
    "$ARCHIVE_URL" \
    --output "$ARCHIVE_PATH"

DOWNLOADED_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
if [[ "$DOWNLOADED_SHA256" != "$ARCHIVE_SHA256" ]]; then
    print -u2 "CT-Punc 模型压缩包 SHA-256 校验失败。"
    print -u2 "期望：$ARCHIVE_SHA256"
    print -u2 "实际：$DOWNLOADED_SHA256"
    exit 1
fi

tar -xjf "$ARCHIVE_PATH" -C "$TEMP_DIR"
EXTRACTED_MODEL="$TEMP_DIR/$MODEL_NAME/model.int8.onnx"
if [[ ! -f "$EXTRACTED_MODEL" ]]; then
    print -u2 "CT-Punc 模型压缩包中没有 model.int8.onnx。"
    exit 1
fi

EXTRACTED_SHA256="$(shasum -a 256 "$EXTRACTED_MODEL" | awk '{print $1}')"
if [[ "$EXTRACTED_SHA256" != "$MODEL_SHA256" ]]; then
    print -u2 "CT-Punc model.int8.onnx SHA-256 校验失败。"
    print -u2 "期望：$MODEL_SHA256"
    print -u2 "实际：$EXTRACTED_SHA256"
    exit 1
fi

mkdir -p "$MODEL_DIR"
TEMP_MODEL_PATH="$MODEL_PATH.download"
cp "$EXTRACTED_MODEL" "$TEMP_MODEL_PATH"
mv "$TEMP_MODEL_PATH" "$MODEL_PATH"

print "CT-Punc INT8 模型已准备完成：$MODEL_PATH"
