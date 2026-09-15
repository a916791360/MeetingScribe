#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="MeetingScribe"
APP_DIR="${APP_DIR:-$ROOT_DIR/.build/$APP_NAME.app}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
ASSET_OUTPUT="$(mktemp -d /private/tmp/meetingscribe-assets.XXXXXX)"
# whisper.cpp 的位置。三种给法，优先级从高到低：
#   1. 环境变量：WHISPER_ROOT=/path/to/whisper.cpp ./Scripts/package_app.sh
#   2. Scripts/local.env（本机私有，不进仓库）：WHISPER_ROOT="/path/to/whisper.cpp"
#   3. 默认 ~/whisper.cpp —— README 里推荐的安装位置
# 刻意不预置任何人的私人目录：这个脚本是公开的，写死路径等于把开发机的
# 目录结构随仓库发出去。
if [[ -f "$ROOT_DIR/Scripts/local.env" ]]; then
    source "$ROOT_DIR/Scripts/local.env"
fi
WHISPER_ROOT="${WHISPER_ROOT:-$HOME/whisper.cpp}"
WHISPER_BIN_DIR="$WHISPER_ROOT/build/bin"
WHISPER_MODEL="$WHISPER_ROOT/models/ggml-small.bin"

if [[ ! -d "$ROOT_DIR/Resources/Assets.xcassets" ]]; then
    print -u2 "Missing Resources/Assets.xcassets. Add the app icon asset catalog before packaging."
    exit 1
fi

if [[ ! -x "$WHISPER_BIN_DIR/whisper-cli" ]]; then
    print -u2 "Missing whisper-cli at $WHISPER_BIN_DIR/whisper-cli"
    exit 1
fi

if [[ ! -f "$WHISPER_MODEL" ]]; then
    print -u2 "Missing whisper model at $WHISPER_MODEL"
    exit 1
fi

if swift build --configuration "$CONFIGURATION" --disable-sandbox; then
    BIN_DIR="$(swift build --configuration "$CONFIGURATION" --disable-sandbox --show-bin-path)"
else
    print -u2 "SwiftPM 构建不可用，改用本机 Xcode Swift 编译器继续打包。"
    FALLBACK_BIN_DIR="$ROOT_DIR/.build/$CONFIGURATION"
    mkdir -p "$FALLBACK_BIN_DIR"
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
    SWIFTC_PATH="$(xcrun --find swiftc)"
    OPTIMIZATION=(-Onone)
    if [[ "$CONFIGURATION" == "release" ]]; then
        OPTIMIZATION=(-O)
    fi

    # 源文件清单**从仓库根目录现取**，不再手写。
    #
    # 为什么：这份清单原来是一串写死的文件名，于是它与 `Package.swift` 的 sources
    # **悄悄漂移**了 —— 2D 加进来的 `Glossary.swift` 一直不在里面，谁新增一个 .swift
    # 都只会在**打包时**炸（`swift test` 全绿，看不出任何问题）。
    # 排除 `Package.swift` 自己：它是 manifest，带进来会撞上 `-parse-as-library`。
    SOURCE_FILES=()
    for source in "$ROOT_DIR"/*.swift; do
        [[ "$(basename "$source")" == "Package.swift" ]] && continue
        SOURCE_FILES+=("$source")
    done

    "$SWIFTC_PATH" "${OPTIMIZATION[@]}" \
        -parse-as-library \
        -target arm64-apple-macosx15.0 \
        -sdk "$SDK_PATH" \
        -module-cache-path "$ROOT_DIR/.build/module-cache" \
        -framework SwiftUI \
        -framework AppKit \
        -framework AVFoundation \
        -framework ScreenCaptureKit \
        -framework CoreGraphics \
        -framework Security \
        -framework UniformTypeIdentifiers \
        -o "$FALLBACK_BIN_DIR/$APP_NAME" \
        "${SOURCE_FILES[@]}"
    BIN_DIR="$FALLBACK_BIN_DIR"
fi

BUILD_TRASH_DIR="$ROOT_DIR/.build/app-trash"
mkdir -p "$BUILD_TRASH_DIR"
if [[ -e "$APP_DIR" ]]; then
    TRASHED_APP="$BUILD_TRASH_DIR/$APP_NAME.$(date +%Y%m%d%H%M%S).app"
    mv "$APP_DIR" "$TRASHED_APP"
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

RUNTIME_DIR="$APP_DIR/Contents/Resources/whisper"
mkdir -p "$RUNTIME_DIR/bin" "$RUNTIME_DIR/models"
ditto "$WHISPER_BIN_DIR/whisper-cli" "$RUNTIME_DIR/bin/whisper-cli"
for library in "$WHISPER_BIN_DIR"/*.dylib; do
    [[ -e "$library" ]] || continue
    ditto "$library" "$RUNTIME_DIR/bin/$(basename "$library")"
done
ditto "$WHISPER_MODEL" "$RUNTIME_DIR/models/ggml-small.bin"

xcrun actool \
    --compile "$ASSET_OUTPUT" \
    --platform macosx \
    --minimum-deployment-target 15.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_OUTPUT/partial-info.plist" \
    --errors \
    --warnings \
    "$ROOT_DIR/Resources/Assets.xcassets" >/dev/null

cp "$ASSET_OUTPUT/Assets.car" "$APP_DIR/Contents/Resources/Assets.car"
cp "$ASSET_OUTPUT/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

chmod 755 "$APP_DIR/Contents/MacOS/$APP_NAME"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    if security find-identity -v -p codesigning | grep -Fq '"PM Studio Signing"'; then
        SIGNING_IDENTITY="PM Studio Signing"
    else
        SIGNING_IDENTITY="-"
    fi
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR" >/dev/null

print "Packaged: $APP_DIR"
print "Signed with: $SIGNING_IDENTITY"

# 这道审计放在签名之后 —— 扫的就是最终要发出去的那一份。
"$ROOT_DIR/Scripts/audit_release.sh" "$APP_DIR"
