#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
source scripts/build-env.sh
cargo build --release --manifest-path rust/Cargo.toml
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="build/DiskScope.app"
./scripts/build-icon.sh
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/DiskScope" "$app/Contents/MacOS/DiskScope"
cp Info.plist "$app/Contents/Info.plist"
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
# Notify Finder that the bundle and its icon metadata have changed.
touch "$app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" ]]; then
    if ! "$lsregister" -f "$PWD/$app"; then
        echo "Warning: macOS app registration could not be refreshed." >&2
    fi
fi
echo "Built build/DiskScope.app"
