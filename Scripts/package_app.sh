#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="MeetingScribe"
APP_DIR="${APP_DIR:-$ROOT_DIR/.build/$APP_NAME.app}"
ASSET_OUTPUT="$(mktemp -d /private/tmp/meetingscribe-assets.XXXXXX)"

if [[ ! -d "$ROOT_DIR/Resources/Assets.xcassets" ]]; then
    print -u2 "Missing Resources/Assets.xcassets. Add the app icon asset catalog before packaging."
    exit 1
fi

swift build --configuration "$CONFIGURATION"
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_DIR/Contents/Info.plist"

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
codesign --force --deep --sign - "$APP_DIR" >/dev/null

print "Packaged: $APP_DIR"
