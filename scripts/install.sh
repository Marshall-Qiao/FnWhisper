#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="$PROJECT_DIR/.build/FnWhisper.app"
INSTALL_ROOT="${FNWHISPER_INSTALL_DIR:-${HOME}/Applications}"
INSTALLED_APP="$INSTALL_ROOT/FnWhisper.app"

"$PROJECT_DIR/scripts/build-app.sh"
if ! "$SOURCE_APP/Contents/MacOS/FnWhisper" --check-runtime; then
    print -u2 "运行依赖或模型未就绪，旧版本保持不变。新机器请先运行 scripts/bootstrap-machine.sh。"
    exit 1
fi
mkdir -p "$INSTALL_ROOT"

typeset -a APP_PIDS=()
typeset -a HELPER_PIDS=()

process_basename() {
    local PROCESS_PATH
    PROCESS_PATH="$(ps -ww -p "$1" -o comm= 2>/dev/null || true)"
    PROCESS_PATH="${PROCESS_PATH//[[:space:]]/}"
    print -r -- "${PROCESS_PATH:t}"
}

capture_helper_descendants() {
    local PARENT_PID="$1"
    local HELPER_PID
    local HELPER_NAME

    while IFS= read -r HELPER_PID; do
        [[ -n "$HELPER_PID" ]] || continue
        capture_helper_descendants "$HELPER_PID"
        HELPER_NAME="$(process_basename "$HELPER_PID")"
        if [[ "$HELPER_NAME" == "whisper-server" \
            || "$HELPER_NAME" == "llama-server" ]]; then
            HELPER_PIDS+=("$HELPER_PID")
        fi
    done < <(pgrep -P "$PARENT_PID" 2>/dev/null || true)
}

while IFS= read -r APP_PID; do
    [[ -n "$APP_PID" ]] || continue
    [[ "$(process_basename "$APP_PID")" == "FnWhisper" ]] || continue
    APP_PIDS+=("$APP_PID")
    capture_helper_descendants "$APP_PID"
done < <(pgrep -x FnWhisper 2>/dev/null || true)

if (( ${#APP_PIDS[@]} > 0 )); then
    for APP_PID in "${APP_PIDS[@]}"; do
        if [[ "$(process_basename "$APP_PID")" == "FnWhisper" ]]; then
            kill "$APP_PID" 2>/dev/null || true
        fi
    done
    for _ in {1..20}; do
        APP_STILL_RUNNING=false
        for APP_PID in "${APP_PIDS[@]}"; do
            if [[ "$(process_basename "$APP_PID")" == "FnWhisper" ]]; then
                APP_STILL_RUNNING=true
                break
            fi
        done
        if [[ "$APP_STILL_RUNNING" == false ]]; then
            break
        fi
        sleep 0.1
    done
    for APP_PID in "${APP_PIDS[@]}"; do
        if [[ "$(process_basename "$APP_PID")" == "FnWhisper" ]]; then
            kill -KILL "$APP_PID" 2>/dev/null || true
        fi
    done
    for _ in {1..10}; do
        APP_STILL_RUNNING=false
        for APP_PID in "${APP_PIDS[@]}"; do
            if [[ "$(process_basename "$APP_PID")" == "FnWhisper" ]]; then
                APP_STILL_RUNNING=true
                break
            fi
        done
        if [[ "$APP_STILL_RUNNING" == false ]]; then
            break
        fi
        sleep 0.1
    done
    if [[ "$APP_STILL_RUNNING" == true ]]; then
        print -u2 "无法停止旧版 FnWhisper，已取消安装。"
        exit 1
    fi
fi

for HELPER_PID in "${HELPER_PIDS[@]}"; do
    HELPER_NAME="$(process_basename "$HELPER_PID")"
    if [[ "$HELPER_NAME" == "whisper-server" \
        || "$HELPER_NAME" == "llama-server" ]]; then
        kill "$HELPER_PID" 2>/dev/null || true
    fi
done
for _ in {1..20}; do
    HELPER_STILL_RUNNING=false
    for HELPER_PID in "${HELPER_PIDS[@]}"; do
        HELPER_NAME="$(process_basename "$HELPER_PID")"
        if [[ "$HELPER_NAME" == "whisper-server" \
            || "$HELPER_NAME" == "llama-server" ]]; then
            HELPER_STILL_RUNNING=true
            break
        fi
    done
    if [[ "$HELPER_STILL_RUNNING" == false ]]; then
        break
    fi
    sleep 0.1
done
for HELPER_PID in "${HELPER_PIDS[@]}"; do
    HELPER_NAME="$(process_basename "$HELPER_PID")"
    if [[ "$HELPER_NAME" == "whisper-server" \
        || "$HELPER_NAME" == "llama-server" ]]; then
        kill -KILL "$HELPER_PID" 2>/dev/null || true
    fi
done
for _ in {1..10}; do
    HELPER_STILL_RUNNING=false
    for HELPER_PID in "${HELPER_PIDS[@]}"; do
        HELPER_NAME="$(process_basename "$HELPER_PID")"
        if [[ "$HELPER_NAME" == "whisper-server" \
            || "$HELPER_NAME" == "llama-server" ]]; then
            HELPER_STILL_RUNNING=true
            break
        fi
    done
    if [[ "$HELPER_STILL_RUNNING" == false ]]; then
        break
    fi
    sleep 0.1
done
if [[ "$HELPER_STILL_RUNNING" == true ]]; then
    print -u2 "无法停止旧版 FnWhisper helper，已取消安装。"
    exit 1
fi

if (( ${#HELPER_PIDS[@]} > 0 )); then
    print "已停止旧版 FnWhisper helper：${(j:, :)HELPER_PIDS}"
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
