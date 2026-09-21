#!/bin/zsh

set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    print -u2 "FnWhisper 的构建和安装仅支持 macOS。"
    exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    print -u2 "未找到 Apple Command Line Tools / Swift。请先运行：xcode-select --install"
    exit 1
fi
SWIFT_VERSION="$(swift --version)"
SWIFT_COMPONENTS="$(print -r -- "$SWIFT_VERSION" | sed -nE 's/.*Swift version ([0-9]+)\.([0-9]+).*/\1 \2/p' | head -1)"
if [[ -z "$SWIFT_COMPONENTS" ]]; then
    print -u2 "无法识别 Swift 版本：$SWIFT_VERSION"
    exit 1
fi
SWIFT_MAJOR="${SWIFT_COMPONENTS%% *}"
SWIFT_MINOR="${SWIFT_COMPONENTS##* }"
if (( SWIFT_MAJOR < 6 || (SWIFT_MAJOR == 6 && SWIFT_MINOR < 1) )); then
    print -u2 "FnWhisper 源码构建需要 Swift 6.1 或更高版本，当前为 $SWIFT_MAJOR.$SWIFT_MINOR。"
    print -u2 "请更新与你的 macOS 兼容的 Command Line Tools / Xcode 后重试。"
    exit 1
fi
if [[ -n "${FNWHISPER_APP_SUPPORT_DIR:-}" && "$FNWHISPER_APP_SUPPORT_DIR" != /* ]]; then
    print -u2 "FNWHISPER_APP_SUPPORT_DIR 必须是绝对路径。"
    exit 1
fi
print "构建工具检查通过：Swift $SWIFT_MAJOR.$SWIFT_MINOR"
