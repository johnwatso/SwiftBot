#!/usr/bin/env bash
# validate_sparkle.sh - Validates Sparkle release pipeline integrity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INFO_PLIST="$ROOT_DIR/Sources/SwiftBot/Info.plist"
PROJECT_YML="$ROOT_DIR/project.yml"

# Resolve a published site path the same way deployment does.
# .github/workflows/deploy-website.yml runs `rsync -a docs/ Website/public/`
# before uploading Website/public as the Pages artifact, so a file present in
# docs/ overwrites its Website/public/ counterpart. Check docs/ first so this
# script reads the bytes users actually fetch.
resolve_published() {
    local relative_path="$1"
    if [[ -f "$ROOT_DIR/docs/$relative_path" ]]; then
        echo "$ROOT_DIR/docs/$relative_path"
    elif [[ -f "$ROOT_DIR/Website/public/$relative_path" ]]; then
        echo "$ROOT_DIR/Website/public/$relative_path"
    fi
}

# Reads the first <item>'s value for a given Sparkle tag.
first_item_value() {
    local appcast="$1" tag="$2"
    grep -oE "<$tag>[^<]*</$tag>" "$appcast" | head -n 1 | sed -E "s|</?$tag>||g"
}

APPCAST_STABLE="$(resolve_published "appcast.xml")"
APPCAST_BETA="$(resolve_published "beta/appcast.xml")"

echo "🔍 Validating Sparkle Release Pipeline..."

# 1. Validate Info.plist exists
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "❌ Error: Info.plist not found at $INFO_PLIST"
    exit 1
fi

# 2. Extract keys from Info.plist
FEED_URL=$(plutil -extract SUFeedURL raw "$INFO_PLIST" || echo "")
PUBLIC_KEY=$(plutil -extract SUPublicEDKey raw "$INFO_PLIST" || echo "")

if [[ -z "$FEED_URL" ]]; then
    echo "❌ Error: SUFeedURL missing in Info.plist"
    exit 1
fi
echo "✅ SUFeedURL: $FEED_URL"

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "❌ Error: SUPublicEDKey missing in Info.plist"
    exit 1
fi
echo "✅ SUPublicEDKey: $PUBLIC_KEY"

# 3. Validate Stable Appcast
if [[ -z "$APPCAST_STABLE" ]]; then
    echo "❌ Error: Stable appcast missing at docs/appcast.xml and Website/public/appcast.xml"
    exit 1
fi
echo "✅ Stable appcast: ${APPCAST_STABLE#"$ROOT_DIR"/}"

# Report the version this feed actually advertises, so a stale feed is visible
# rather than silently passing the checks below.
STABLE_VERSION=$(first_item_value "$APPCAST_STABLE" "sparkle:shortVersionString")
STABLE_BUILD=$(first_item_value "$APPCAST_STABLE" "sparkle:version")
if [[ -z "$STABLE_VERSION" ]]; then
    echo "❌ Error: No sparkle:shortVersionString found in stable appcast"
    exit 1
fi
echo "✅ Stable appcast advertises $STABLE_VERSION (build ${STABLE_BUILD:-unknown})"

# Cross-check against project.yml. These legitimately differ between a version
# bump and the publish that follows it, so this warns rather than fails.
if [[ -f "$PROJECT_YML" ]]; then
    MARKETING_VERSION=$(grep -E '^\s*MARKETING_VERSION:' "$PROJECT_YML" | head -n 1 | sed -E 's|.*:[[:space:]]*"?([^"]*)"?[[:space:]]*$|\1|')
    if [[ -n "$MARKETING_VERSION" && "$MARKETING_VERSION" != "$STABLE_VERSION" ]]; then
        echo "⚠️  Warning: MARKETING_VERSION is $MARKETING_VERSION but stable appcast advertises $STABLE_VERSION"
    fi
fi

# Check if stable appcast contains the public key (as a comment or in signatures)
# Note: Sparkle's generate_appcast includes signatures, we just check they exist.
if ! grep -q "sparkle:edSignature" "$APPCAST_STABLE"; then
    echo "⚠️  Warning: No edSignature found in stable appcast. Updates may fail validation."
else
    echo "✅ edSignature present in stable appcast"
fi

# 4. Check Enclosure Reachability (Stable)
STABLE_URL=$(grep -oE 'url="https://github.com/[^"]+"' "$APPCAST_STABLE" | head -n 1 | cut -d'"' -f2)
if [[ -n "$STABLE_URL" ]]; then
    echo "📡 Checking stable enclosure reachability: $STABLE_URL"
    if curl --output /dev/null --silent --location --head --fail "$STABLE_URL"; then
        echo "✅ Stable enclosure is reachable"
    else
        # Non-fatal: a freshly cut release may not have its asset uploaded yet.
        echo "⚠️  Warning: Stable enclosure is NOT reachable (HTTP 404 or other)"
    fi
fi

# 5. Validate Beta Appcast (if it exists)
# The app derives the beta feed from SUFeedURL (see AppUpdater.betaFeedURL), so
# this file is served at <feed dir>/beta/appcast.xml whenever it is present.
if [[ -n "$APPCAST_BETA" ]]; then
    echo "✅ Beta appcast: ${APPCAST_BETA#"$ROOT_DIR"/}"
    if ! grep -q "<item>" "$APPCAST_BETA"; then
        echo "ℹ️  Beta channel is empty (no beta releases published)"
    else
        BETA_VERSION=$(first_item_value "$APPCAST_BETA" "sparkle:shortVersionString")
        echo "✅ Beta appcast advertises ${BETA_VERSION:-unknown}"
        if ! grep -q "sparkle:edSignature" "$APPCAST_BETA"; then
            echo "⚠️  Warning: No edSignature found in beta appcast."
        fi
    fi
else
    echo "ℹ️  Beta appcast not found (optional)"
fi

echo "✨ Sparkle pipeline validation complete."
