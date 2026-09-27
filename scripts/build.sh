#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
cargo build --release --manifest-path rust/Cargo.toml
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="build/DiskScope.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin_dir/DiskScope" "$app/Contents/MacOS/DiskScope"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "Built build/DiskScope.app"
