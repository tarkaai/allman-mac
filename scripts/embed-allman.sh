#!/usr/bin/env bash
# Xcode post-build phase: copy a real `allman` CLI binary into the app bundle
# at Contents/Resources/allman so the app is self-contained, mirroring how
# allman-tui embeds the CLI. Resolution: $ALLMAN_BIN, then `allman` on PATH,
# then ~/.local/bin/allman. Skips with a warning when none is found — the app
# still runs and falls back to a system-installed allman at runtime.
set -euo pipefail

dest_dir="${BUILT_PRODUCTS_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
dest="${dest_dir}/allman"

candidates=()
[[ -n "${ALLMAN_BIN:-}" ]] && candidates+=("$ALLMAN_BIN")
if command -v allman >/dev/null 2>&1; then candidates+=("$(command -v allman)"); fi
candidates+=("$HOME/.local/bin/allman" "/usr/local/bin/allman" "/opt/homebrew/bin/allman")

src=""
for c in "${candidates[@]}"; do
  if [[ -x "$c" && ! -d "$c" ]]; then src="$c"; break; fi
done

if [[ -z "$src" ]]; then
  echo "warning: no allman binary found to embed (set ALLMAN_BIN); app will look for allman on PATH at runtime"
  exit 0
fi

mkdir -p "$dest_dir"
if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
  echo "allman already embedded (unchanged): $src"
  exit 0
fi
cp -f "$src" "$dest"
chmod 755 "$dest"
echo "embedded allman from $src → $dest"
