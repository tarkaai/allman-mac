#!/usr/bin/env bash
# Render the app icon set from icon.svg (same mark as allman.sh's favicon).
# Uses only tools that ship with macOS: qlmanage renders the SVG, sips resizes.
set -euo pipefail
cd "$(dirname "$0")/.."
svg="Sources/Allman/Resources/icon.svg"
out="Sources/Allman/Resources/Assets.xcassets/AppIcon.appiconset"
tmp="$(mktemp -d)"
qlmanage -t -s 1024 -o "$tmp" "$svg" >/dev/null 2>&1
src="$tmp/icon.svg.png"
[[ -f "$src" ]] || { echo "qlmanage failed to render $svg" >&2; exit 1; }
mkdir -p "$out"
for spec in 16:1 16:2 32:1 32:2 128:1 128:2 256:1 256:2 512:1 512:2; do
  pt="${spec%%:*}"; scale="${spec##*:}"; px=$((pt * scale))
  sips -z "$px" "$px" "$src" --out "$out/icon_${pt}x${pt}@${scale}x.png" >/dev/null
done
cat > "$out/Contents.json" <<JSON
{
  "images" : [
    { "filename" : "icon_16x16@1x.png",  "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32@1x.png",  "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512@1x.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
rm -rf "$tmp"
echo "→ $out"
