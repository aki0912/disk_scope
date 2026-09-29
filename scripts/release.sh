#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

# Use a certificate SHA-1 when multiple identities have the same display name.
: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to a Developer ID Application identity}"
notary_profile="${NOTARY_PROFILE:-DiskScope-notary}"
notary_options=(--keychain-profile "$notary_profile")
if [[ -n "${NOTARY_KEYCHAIN:-}" ]]; then
    notary_options+=(--keychain "$NOTARY_KEYCHAIN")
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Build the release on an Apple Silicon Mac." >&2
    exit 1
fi

./scripts/build.sh
app="build/DiskScope.app"
if [[ -n "${RELEASE_BUILD_NUMBER:-}" ]]; then
    [[ "$RELEASE_BUILD_NUMBER" == <1-> ]] || { echo "Invalid release build number" >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $RELEASE_BUILD_NUMBER" "$app/Contents/Info.plist"
fi
executable="$app/Contents/MacOS/DiskScope"
if [[ "$(lipo -archs "$executable")" != arm64 ]]; then
    echo "The release must contain only the arm64 architecture." >&2
    exit 1
fi
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
asset_version="${RELEASE_ASSET_VERSION:-$version}"
if [[ ! "$asset_version" =~ '^[0-9]+\.[0-9]+\.[0-9]+(-build\.[0-9]+)?$' ]]; then
    echo "Invalid release asset version" >&2
    exit 1
fi
mkdir -p build/releases
release_dir="$(mktemp -d "$PWD/build/releases/release.XXXXXX")"
echo "Release output: build/releases/${release_dir:t}"

codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$app"
codesign --verify --strict --verbose=2 "$app"
ditto -c -k --keepParent "$app" "$release_dir/DiskScope-notarization.zip"
xcrun notarytool submit "$release_dir/DiskScope-notarization.zip" \
    "${notary_options[@]}" --wait --timeout 15m --output-format plist > "$release_dir/app-notarization.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$release_dir/app-notarization.plist")" != Accepted ]]; then
    cat "$release_dir/app-notarization.plist"
    echo "App notarization failed. Use the submission ID with notarytool log." >&2
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

mkdir "$release_dir/staging"
ditto "$app" "$release_dir/staging/DiskScope.app"
ln -s /Applications "$release_dir/staging/Applications"
cp docs/INSTALL-ja.txt "$release_dir/staging/INSTALL-ja.txt"
dmg="$release_dir/DiskScope-${asset_version}-arm64.dmg"
hdiutil create -volname DiskScope -srcfolder "$release_dir/staging" \
    -format UDZO -fs HFS+ "$dmg"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" "${notary_options[@]}" \
    --wait --timeout 15m --output-format plist > "$release_dir/dmg-notarization.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :status' "$release_dir/dmg-notarization.plist")" != Accepted ]]; then
    cat "$release_dir/dmg-notarization.plist"
    echo "DMG notarization failed. Use the submission ID with notarytool log." >&2
    exit 1
fi
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
hdiutil verify "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(cd "$release_dir" && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
echo "Ready: build/releases/${release_dir:t}/${dmg:t}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'dmg=%s\nsha256=%s\n' "$dmg" "$dmg.sha256" >> "$GITHUB_OUTPUT"
fi
