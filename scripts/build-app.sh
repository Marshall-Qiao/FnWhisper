#!/bin/zsh

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/.build/FnWhisper.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
LICENSES_DIR="$RESOURCES_DIR/ThirdPartyLicenses"
MODULE_CACHE_DIR="$PROJECT_DIR/.build/module-cache"
BUNDLE_IDENTIFIER="com.marshall.fnwhisper"
SIGN_IDENTITY="${FNWHISPER_SIGN_IDENTITY:--}"

cd "$PROJECT_DIR"
mkdir -p "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

swift build --disable-sandbox --configuration release
SWIFT_BIN_DIR="$(swift build --disable-sandbox --configuration release --show-bin-path)"

rm -rf -- "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$LICENSES_DIR"
cp "$SWIFT_BIN_DIR/FnWhisper" "$MACOS_DIR/FnWhisper"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
cp \
    "$PROJECT_DIR/Resources/ThirdPartyLicenses/sherpa-onnx-LICENSE.txt" \
    "$PROJECT_DIR/Resources/ThirdPartyLicenses/onnxruntime-LICENSE.txt" \
    "$PROJECT_DIR/Resources/ThirdPartyLicenses/onnxruntime-ThirdPartyNotices.txt" \
    "$LICENSES_DIR/"
chmod +x "$MACOS_DIR/FnWhisper"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    LOCAL_REQUIREMENT="=designated => identifier \"$BUNDLE_IDENTIFIER\""
    codesign \
        --force \
        --deep \
        --sign - \
        --requirements "$LOCAL_REQUIREMENT" \
        "$APP_DIR"
    print "提示：未配置 FNWHISPER_SIGN_IDENTITY，使用稳定的本地开发签名要求。"
else
    codesign \
        --force \
        --deep \
        --sign "$SIGN_IDENTITY" \
        --timestamp=none \
        "$APP_DIR"
fi

codesign --verify --deep --strict "$APP_DIR"
print "App 构建完成：$APP_DIR"
