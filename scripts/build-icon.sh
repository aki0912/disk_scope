#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
iconset="build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" > /dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" Assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$iconset" -o build/AppIcon.icns
