#!/bin/zsh
set -euo pipefail
: "${RUNNER_TEMP:?Run this script on a GitHub-hosted runner}"
: "${SIGNING_CERTIFICATE_BASE64:?Missing certificate}"
: "${SIGNING_CERTIFICATE_PASSWORD:?Missing certificate password}"
: "${APPLE_ID:?Missing Apple ID}"
: "${APPLE_TEAM_ID:?Missing team ID}"
: "${APPLE_APP_PASSWORD:?Missing app-specific password}"
umask 077
certificate="$RUNNER_TEMP/diskscope-signing.p12"
keychain="$RUNNER_TEMP/diskscope-signing.keychain-db"
keychain_password="$(openssl rand -hex 32)"
echo "::add-mask::$keychain_password"
trap 'rm -f "$certificate"' EXIT
printf '%s' "$SIGNING_CERTIFICATE_BASE64" | base64 --decode > "$certificate"
security create-keychain -p "$keychain_password" "$keychain"
security set-keychain-settings -lut 3600 "$keychain"
security unlock-keychain -p "$keychain_password" "$keychain"
security import "$certificate" -P "$SIGNING_CERTIFICATE_PASSWORD" -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" > /dev/null
security list-keychains -d user -s "$keychain"
xcrun notarytool store-credentials DiskScope-ci --keychain "$keychain" \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD"
