#!/bin/zsh

set -euo pipefail

# Snapshot a Homebrew llama.cpp installation with the GGML ABI it was linked
# against. Do not relink/upgrade global Homebrew libraries used by Whisper.
CONTENTS_DIR="$1"
LLAMA_PATH="${FNWHISPER_LLAMA_SERVER:-$(command -v llama-server || true)}"
[[ -n "$LLAMA_PATH" && -x "$LLAMA_PATH" ]] || exit 0
LINK_ENTRY="$(otool -L "$LLAMA_PATH" | sed -nE 's@^[[:space:]]*(/[^ ]*/opt/ggml/lib/libggml\.0\.dylib).*current version ([0-9.]+).*@\1 \2@p' | head -1)"
# Custom/static executables can still be selected via FNWHISPER_LLAMA_SERVER.
[[ -n "$LINK_ENTRY" ]] || exit 0
GGML_LINK="${LINK_ENTRY% *}"
GGML_VERSION="${LINK_ENTRY##* }"
GGML_OPT_ROOT="${GGML_LINK:h:h}"
BREW_ROOT="${GGML_OPT_ROOT:h:h}"
GGML_ROOT=""
for CANDIDATE in "$GGML_OPT_ROOT" "$BREW_ROOT/Cellar/ggml"/*(N/); do
    [[ -f "$CANDIDATE/lib/libggml.0.dylib" ]] || continue
    CANDIDATE_VERSION="$(otool -L "$CANDIDATE/lib/libggml.0.dylib" | sed -nE 's@.*libggml\.0\.dylib.*current version ([0-9.]+).*@\1@p' | head -1)"
    if [[ "$CANDIDATE_VERSION" == "$GGML_VERSION" ]]; then
        GGML_ROOT="$(cd "$CANDIDATE" && pwd -P)"
        break
    fi
done
if [[ -z "$GGML_ROOT" || ! -d "$GGML_ROOT/libexec" ]]; then
    print -u2 "llama-server 需要匹配的 ggml $GGML_VERSION，但未找到完整运行库。"
    print -u2 "请重新安装匹配版本的 llama.cpp/ggml 后重试；安装器不会替换旧 App。"
    exit 1
fi
while [[ -L "$LLAMA_PATH" ]]; do
    LINK_TARGET="$(readlink "$LLAMA_PATH")"
    if [[ "$LINK_TARGET" == /* ]]; then
        LLAMA_PATH="$LINK_TARGET"
    else
        LLAMA_PATH="${LLAMA_PATH:h}/$LINK_TARGET"
    fi
done
LLAMA_ROOT="$(cd "${LLAMA_PATH:h}/.." && pwd -P)"
RUNTIME_DIR="$CONTENTS_DIR/Frameworks/LocalInference"
mkdir -p "$RUNTIME_DIR/backends" "$CONTENTS_DIR/Resources/bin" "$CONTENTS_DIR/Resources/ThirdPartyLicenses"
cp "$LLAMA_PATH" "$CONTENTS_DIR/Resources/bin/llama-server"
cp -P "$LLAMA_ROOT"/lib/*.dylib "$GGML_ROOT"/lib/*.dylib "$RUNTIME_DIR/"
cp -P "$GGML_ROOT"/libexec/*.so "$RUNTIME_DIR/backends/"
cp "$LLAMA_ROOT/LICENSE" "$CONTENTS_DIR/Resources/ThirdPartyLicenses/llama.cpp-LICENSE.txt"
cp "$GGML_ROOT/LICENSE" "$CONTENTS_DIR/Resources/ThirdPartyLicenses/ggml-LICENSE.txt"
chmod -R u+w "$RUNTIME_DIR" "$CONTENTS_DIR/Resources/bin"
print "已打包 llama.cpp 运行时及匹配的 ggml $GGML_VERSION。"
