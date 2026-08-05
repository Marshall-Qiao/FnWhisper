#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if ! xcode-select -p >/dev/null 2>&1; then
    print -u2 "未安装 Apple Command Line Tools。"
    print -u2 "请先运行：xcode-select --install"
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    print -u2 "未找到 Homebrew。请先从 https://brew.sh 安装 Homebrew。"
    exit 1
fi

brew bundle --file "$PROJECT_DIR/Brewfile"
"$PROJECT_DIR/scripts/setup-whisper.sh" large-v3-q5_0
"$PROJECT_DIR/scripts/install.sh"

print "部署完成。请按 README 授予输入监听、辅助功能和麦克风权限。"
