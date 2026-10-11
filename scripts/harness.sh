#!/usr/bin/env bash
# Run the app against a throwaway copy of ~/.allman with the fake CLI, so sends,
# reactions and reads can be exercised (and snapshotted) without touching
# LinkedIn or the real store. Extra env vars are passed to the app, e.g.
#
#   scripts/harness.sh ALLMAN_SNAPSHOT_DIR=/tmp/shots ALLMAN_SNAPSHOT_CONV=Jamie \
#       ALLMAN_SNAPSHOT_SEND="hello" FAKE_SEND_DELAY=3
#
# Uses build/Build/Products/Debug/Allman.app unless APP=... is given; the source
# store is $ALLMAN_STORE or ~/.allman; the copy lives under $TMPDIR.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${APP:-build/Build/Products/Debug/Allman.app}"
src="${ALLMAN_STORE:-$HOME/.allman}"
dst="${HARNESS_STORE:-${TMPDIR:-/tmp}/allman-harness-store}"
[[ -d "$app" ]] || { echo "harness: $app not built (scripts/run.sh or xcodebuild first)" >&2; exit 1; }
[[ -d "$src" ]] || { echo "harness: no store at $src" >&2; exit 1; }

rm -rf "$dst"; mkdir -p "$dst"
# Everything except git history, downloaded media and the session cookies.
rsync -a --exclude .git --exclude media --exclude COOKIES.json --exclude listen.log "$src/" "$dst/"
echo "harness: store copy at $dst ($(du -sh "$dst" | cut -f1))"

envs=(--env "ALLMAN_STORE=$dst" --env "ALLMAN_BIN=$PWD/scripts/fake-allman.sh")
for kv in "$@"; do envs+=(--env "$kv"); done
open "$app" "${envs[@]}"
echo "harness: launched $app"
