#!/bin/zsh

set -euo pipefail

APP_SUPPORT_DIR="${FNWHISPER_APP_SUPPORT_DIR:-${HOME}/Library/Application Support/FnWhisper}"
MODEL_FILENAME="Qwen3.5-4B-Q4_K_M.gguf"
MODEL_PATH="$APP_SUPPORT_DIR/Models/$MODEL_FILENAME"
MODEL_URL="https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf?download=true"
MODEL_SHA256="00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"

LLAMA_SERVER_PATH="${FNWHISPER_LLAMA_SERVER:-}"
if [[ -z "$LLAMA_SERVER_PATH" ]]; then
    if command -v llama-server >/dev/null 2>&1; then
        LLAMA_SERVER_PATH="$(command -v llama-server)"
    elif [[ -x /opt/homebrew/bin/llama-server ]]; then
        LLAMA_SERVER_PATH="/opt/homebrew/bin/llama-server"
    elif [[ -x /usr/local/bin/llama-server ]]; then
        LLAMA_SERVER_PATH="/usr/local/bin/llama-server"
    fi
fi
if [[ -z "$LLAMA_SERVER_PATH" || ! -x "$LLAMA_SERVER_PATH" ]]; then
    print -u2 "未找到可执行的 llama-server。请先运行 brew bundle，或设置 FNWHISPER_LLAMA_SERVER。"
    exit 1
fi

if ! LLAMA_SERVER_HELP="$("$LLAMA_SERVER_PATH" --help 2>&1)"; then
    print -u2 "无法读取 llama-server 参数：$LLAMA_SERVER_PATH"
    exit 1
fi
for REQUIRED_FLAG in \
    --offline \
    --n-gpu-layers \
    --reasoning \
    --reasoning-budget \
    --chat-template-kwargs \
    --no-ui
do
    if [[ "$LLAMA_SERVER_HELP" != *"$REQUIRED_FLAG"* ]]; then
        print -u2 "当前 llama-server 不支持 FnWhisper 所需参数：$REQUIRED_FLAG"
        print -u2 "请通过 brew upgrade llama.cpp 更新后重试。"
        exit 1
    fi
done

if [[ -f "$MODEL_PATH" ]]; then
    EXISTING_SHA256="$(shasum -a 256 "$MODEL_PATH" | awk '{print $1}')"
    if [[ "$EXISTING_SHA256" == "$MODEL_SHA256" ]]; then
        print "Qwen3.5-4B Q4_K_M 模型已存在并通过校验：$MODEL_PATH"
        exit 0
    fi
    print -u2 "已有 Qwen 模型校验不一致，将重新下载。"
fi

mkdir -p "$(dirname "$MODEL_PATH")"
DOWNLOADED_MODEL="$MODEL_PATH.download"
trap 'rm -f "$DOWNLOADED_MODEL"' EXIT

print "正在下载 Qwen3.5-4B Q4_K_M（约 2.74 GB）…"
curl --fail --location --retry 3 --progress-bar \
    "$MODEL_URL" \
    --output "$DOWNLOADED_MODEL"

DOWNLOADED_SHA256="$(shasum -a 256 "$DOWNLOADED_MODEL" | awk '{print $1}')"
if [[ "$DOWNLOADED_SHA256" != "$MODEL_SHA256" ]]; then
    print -u2 "Qwen 模型 SHA-256 校验失败。"
    print -u2 "期望：$MODEL_SHA256"
    print -u2 "实际：$DOWNLOADED_SHA256"
    exit 1
fi

mv "$DOWNLOADED_MODEL" "$MODEL_PATH"
trap - EXIT

print "Qwen3.5-4B Q4_K_M 模型已准备完成：$MODEL_PATH"
