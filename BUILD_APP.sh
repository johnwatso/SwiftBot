#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_PATH="$ROOT_DIR/DiscordBotApp.xcodeproj"
SCHEME_NAME="DiscordBotApp"
CONFIGURATION="${1:-Debug}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Project not found at: $PROJECT_PATH" >&2
  exit 1
fi

echo "Building $SCHEME_NAME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  build > /tmp/discordbotapp-build.log

echo "Resolving build output paths..."
BUILD_SETTINGS="$(xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -showBuildSettings)"

TARGET_BUILD_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')"
FULL_PRODUCT_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F' = ' '/ FULL_PRODUCT_NAME = / { print $2; exit }')"

if [[ -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
  echo "Unable to resolve app build output path" >&2
  exit 1
fi

SOURCE_APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

if [[ ! -d "$SOURCE_APP_PATH" ]]; then
  echo "Built app not found: $SOURCE_APP_PATH" >&2
  exit 1
fi

APP_PATH="$ROOT_DIR/Dist/DiscordBotApp.app"
mkdir -p "$ROOT_DIR/Dist"
rm -rf "$APP_PATH"
cp -R "$SOURCE_APP_PATH" "$APP_PATH"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_PATH" >/dev/null 2>&1 || true
fi

echo "Done: $APP_PATH"
echo "Run: open \"$APP_PATH\""
