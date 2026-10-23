#!/bin/bash
# Puts the release certificate from XIWOBOARD_SIGNING_P12 (made by
# scripts/signing/make-certificate.sh) into a throwaway keychain and prints
# SIGN_IDENTITY= and SIGN_KEYCHAIN= lines for build-app.sh; CI appends them to
# $GITHUB_ENV. See docs/SIGNING.md.
set -euo pipefail

: "${XIWOBOARD_SIGNING_P12:?XIWOBOARD_SIGNING_P12 is not set}"
DIR="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN="$DIR/xiwoboard-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
P12="$DIR/xiwoboard-signing.p12"

printf '%s' "$XIWOBOARD_SIGNING_P12" | base64 --decode > "$P12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P xiwoboard -T /usr/bin/codesign >&2
rm -f "$P12"
# Lets codesign use the key without a keychain prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null

IDENTITY="$(security find-identity -p codesigning "$KEYCHAIN" | awk '/"XiwoBoard Release Signing"/ { print $2; exit }')"
[ -n "$IDENTITY" ] || { echo "No \"XiwoBoard Release Signing\" identity in XIWOBOARD_SIGNING_P12" >&2; exit 1; }
echo "SIGN_IDENTITY=$IDENTITY"
echo "SIGN_KEYCHAIN=$KEYCHAIN"
