#!/bin/sh
# One-time setup, per Mac, for signing SwiftBot Debug builds with a stable local
# identity (see sign-debug-build.sh). Creates a self-signed code-signing
# certificate in your login keychain and trusts it for code signing. macOS asks
# for your password once, to approve the trust setting.
#
# The certificate only signs your own Debug builds on this Mac. It isn't an
# Apple identity and has nothing to do with the Developer ID that ShipHook
# signs releases with.
#
# Undo: delete "SwiftBot Local Development" (certificate and key) in Keychain Access.
set -eu

IDENTITY="SwiftBot Local Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "'$IDENTITY' is already set up."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $IDENTITY
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$IDENTITY" -out "$WORK/identity.p12" -passout "pass:$PASS"

# -T lets codesign use the key without a prompt on every build.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Approve the trust setting when macOS asks (your login password)…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
    echo "Done. Rebuild SwiftBot (Debug). macOS asks once more per secret: choose Always Allow, and it sticks from then on."
else
    echo "The certificate was imported but isn't valid for code signing yet; check it in Keychain Access." >&2
    exit 1
fi
