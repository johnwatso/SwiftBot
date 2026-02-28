#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_PATH="$ROOT_DIR/.swiftpm/xcode/package.xcworkspace"
SCHEME_NAME="DiscordBotApp"
CONFIGURATION="${1:-Debug}"

if [[ ! -d "$WORKSPACE_PATH" ]]; then
  echo "Workspace not found at: $WORKSPACE_PATH" >&2
  exit 1
fi

echo "Building $SCHEME_NAME ($CONFIGURATION)..."
xcodebuild \
  -workspace "$WORKSPACE_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  build > /tmp/discordbotapp-build.log

echo "Resolving build output paths..."
BUILD_SETTINGS="$(xcodebuild \
  -workspace "$WORKSPACE_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -showBuildSettings)"

BUILT_PRODUCTS_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/ BUILT_PRODUCTS_DIR = / { print $2; exit }')"

if [[ -z "$BUILT_PRODUCTS_DIR" ]]; then
  echo "Unable to resolve BUILT_PRODUCTS_DIR" >&2
  exit 1
fi

BIN_PATH="$BUILT_PRODUCTS_DIR/DiscordBotApp"
BUNDLE_PATH="$BUILT_PRODUCTS_DIR/DiscordBotApp_DiscordBotApp.bundle"

if [[ ! -f "$BIN_PATH" ]]; then
  echo "Built executable not found: $BIN_PATH" >&2
  exit 1
fi

if [[ ! -d "$BUNDLE_PATH" ]]; then
  echo "Resource bundle not found: $BUNDLE_PATH" >&2
  exit 1
fi

APP_PATH="$ROOT_DIR/Dist/DiscordBotApp.app"
mkdir -p "$ROOT_DIR/Dist"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

cp "$BIN_PATH" "$APP_PATH/Contents/MacOS/DiscordBotApp"
cp -R "$BUNDLE_PATH" "$APP_PATH/Contents/Resources/"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>DiscordBotApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.john.discordbotapp</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>DiscordBotApp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

chmod +x "$APP_PATH/Contents/MacOS/DiscordBotApp"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

echo "Done: $APP_PATH"
echo "Run: open \"$APP_PATH\""
