#!/usr/bin/env bash
# Build a Debug app and launch it (kills a running instance first).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=Debug scripts/build.sh
pkill -x Allman 2>/dev/null || true
open dist/Allman.app
