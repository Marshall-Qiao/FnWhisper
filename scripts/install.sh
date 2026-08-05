#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/.build/FnWhisper.app"
INSTALL_ROOT="${FNWHISPER_INSTALL_DIR:-${HOME}/Applications}"
INSTALLED_APP="$INSTALL_ROOT/FnWhisper.app"

"$PROJECT_DIR/scripts/build-app.sh"
mkdir -p "$INSTALL_ROOT"

if pgrep -x FnWhisper >/dev/null 2>&1; then
    pkill -x FnWhisper
    for _ in {1..20}; do
        if ! pgrep -x FnWhisper >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done
fi

if [[ -e "$INSTALLED_APP" ]]; then
    BACKUP_APP="$INSTALL_ROOT/FnWhisper.app.backup-$(date +%Y%m%d-%H%M%S)"
    mv "$INSTALLED_APP" "$BACKUP_APP"
    print "旧版本已备份到：$BACKUP_APP"
fi

cp -R "$SOURCE_APP" "$INSTALLED_APP"
codesign --verify --deep --strict "$INSTALLED_APP"
open "$INSTALLED_APP"
print "FnWhisper 已安装并启动：$INSTALLED_APP"
