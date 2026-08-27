#!/usr/bin/env bash
# validate_sparkle.sh - Validates Sparkle release pipeline integrity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

INFO_PLIST="$ROOT_DIR/Sources/SwiftBot/Info.plist"

# `.github/workflows/deploy-website.yml` rsyncs `docs/` over `Website/public/`
# before publishing, so `docs/appcast.xml` — the file ShipHook rewrites on every
# release — is the feed users' Sparkle actually fetches. Validating the
# `Website/public/` copy instead reports on a file that never ships, which is
# how a stale 1.22.10 enclosure once passed while 1.23 was live.
APPCAST_STABLE="$ROOT_DIR/Website/public/appcast.xml"
if [[ -f "$ROOT_DIR/docs/appcast.xml" ]]; then
    APPCAST_STABLE="$ROOT_DIR/docs/appcast.xml"
fi
APPCAST_BETA="$ROOT_DIR/Website/public/beta/appcast.xml"
if [[ -f "$ROOT_DIR/docs/beta/appcast.xml" ]]; then
    APPCAST_BETA="$ROOT_DIR/docs/beta/appcast.xml"
fi

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
if [[ ! -f "$APPCAST_STABLE" ]]; then
    echo "❌ Error: Stable appcast missing at $APPCAST_STABLE"
    exit 1
fi
echo "✅ Stable appcast (the file the deploy actually serves): ${APPCAST_STABLE#"$ROOT_DIR/"}"

# 3a. Compare the feed against the version this checkout would build. ShipHook
# rewrites the appcast at publish time, so lagging behind is expected during
# release prep — but matching an already-published build number means an update
# nobody can receive, since Sparkle compares sparkle:version for equality.
BUILD_VERSION=$(plutil -extract CFBundleVersion raw "$INFO_PLIST" 2>/dev/null || echo "")
if [[ -z "$BUILD_VERSION" || "$BUILD_VERSION" == "\$(CURRENT_PROJECT_VERSION)" ]]; then
    BUILD_VERSION=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$ROOT_DIR/project.yml" | tr -d ' "' | cut -d: -f2)
fi
MARKETING=$(grep -m1 'MARKETING_VERSION:' "$ROOT_DIR/project.yml" | tr -d ' "' | cut -d: -f2)
FEED_BUILD=$(grep -oE '<sparkle:version>[^<]+' "$APPCAST_STABLE" | head -n 1 | cut -d'>' -f2)
FEED_SHORT=$(grep -oE '<sparkle:shortVersionString>[^<]+' "$APPCAST_STABLE" | head -n 1 | cut -d'>' -f2)
echo "ℹ️  Checkout: $MARKETING ($BUILD_VERSION) — feed: ${FEED_SHORT:-?} (${FEED_BUILD:-?})"
if [[ -n "$FEED_BUILD" && "$FEED_BUILD" == "$BUILD_VERSION" ]]; then
    echo "❌ Error: this checkout's build number ($BUILD_VERSION) is already published in the feed."
    echo "   Sparkle would offer no update. Refresh CURRENT_PROJECT_VERSION before releasing."
    exit 1
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
    if curl --output /dev/null --silent --head --fail "$STABLE_URL"; then
        echo "✅ Stable enclosure is reachable"
    else
        echo "❌ Error: Stable enclosure is NOT reachable (HTTP 404 or other)"
        # Don't exit 1 here yet, might be a very fresh release not yet uploaded
    fi
fi

# 5. Validate Beta Appcast (if it exists)
if [[ -f "$APPCAST_BETA" ]]; then
    echo "✅ Beta appcast found"
    if ! grep -q "sparkle:edSignature" "$APPCAST_BETA"; then
        echo "⚠️  Warning: No edSignature found in beta appcast."
    fi
else
    echo "ℹ️  Beta appcast not found (optional)"
fi

echo "✨ Sparkle pipeline validation complete."
