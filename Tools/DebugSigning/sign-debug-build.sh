#!/bin/sh
# Scheme build post-action for SwiftBot (it must run after Xcode's own ad-hoc
# CodeSign step, which no build phase can). Re-signs Debug builds with a local,
# stable identity so the login Keychain recognises the app across rebuilds and
# "Always Allow" sticks (an ad-hoc signature changes every build, which means a
# password prompt per secret per build).
#
# Never touches Release: ShipHook archives and signs those with the Developer ID.
# Does nothing until Tools/DebugSigning/setup.sh has created the identity on
# this Mac, so a fresh checkout still builds exactly as before.
set -eu

[ "${CONFIGURATION:-}" = "Debug" ] || exit 0

IDENTITY="SwiftBot Local Development"
if ! security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "note: '$IDENTITY' isn't set up on this Mac; leaving the ad-hoc signature (run Tools/DebugSigning/setup.sh to stop Keychain prompts)."
    exit 0
fi

APP="${CODESIGNING_FOLDER_PATH:-$TARGET_BUILD_DIR/$WRAPPER_NAME}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
CERT_SHA1="$(security find-certificate -c "$IDENTITY" -Z | awk '/^SHA-1 hash:/ { print $3; exit }')"
if [ -z "$CERT_SHA1" ]; then
    echo "warning: couldn't read the '$IDENTITY' certificate hash; leaving the ad-hoc signature."
    exit 0
fi
# The Keychain trusts an app by its designated requirement. For a self-signed
# certificate codesign defaults to the cdhash, which changes every build, so
# pin it to the bundle ID and this certificate instead.
REQUIREMENT="designated => identifier \"$BUNDLE_ID\" and certificate leaf = H\"$CERT_SHA1\""
# --deep reaches the embedded frameworks and the debug dylib; the app itself
# is then re-signed with the pinned requirement. Entitlements are kept from
# Xcode's signature (get-task-allow, so the debugger can still attach). Clear
# hardened runtime flags explicitly: this local certificate has no Apple Team
# ID, so library validation would reject RecordingsKit even after re-signing
# both the app and framework. This also repairs older Debug build signatures.
codesign --force --deep --preserve-metadata=entitlements --options=0 --sign "$IDENTITY" --timestamp=none "$APP"
codesign --force --preserve-metadata=entitlements --options=0 --sign "$IDENTITY" --timestamp=none --requirements "=$REQUIREMENT" "$APP"
echo "Signed $(basename "$APP") with '$IDENTITY'."
