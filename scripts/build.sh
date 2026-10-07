#!/usr/bin/env bash
# Build dist/Allman.app (Release). Requires Xcode and xcodegen (brew install xcodegen).
#   ALLMAN_BIN=/path/to/allman scripts/build.sh     # choose which CLI to embed
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-Release}"
xcodegen generate --quiet
xcodebuild \
  -project Allman.xcodeproj \
  -scheme Allman \
  -configuration "$CONFIG" \
  -derivedDataPath build \
  -destination 'platform=macOS' \
  build \
  CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}" \
  | grep -E "error:|warning: no allman|embedded allman|BUILD (SUCCEEDED|FAILED)" || true

app="build/Build/Products/${CONFIG}/Allman.app"
[[ -d "$app" ]] || { echo "build failed: $app not found" >&2; exit 1; }
rm -rf dist/Allman.app && mkdir -p dist && cp -R "$app" dist/Allman.app
echo "→ dist/Allman.app"
