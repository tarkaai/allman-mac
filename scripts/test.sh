#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check-rules.sh
xcodegen generate --quiet
xcodebuild -project Allman.xcodeproj -scheme Allman -configuration Debug \
  -derivedDataPath build -destination 'platform=macOS' test \
  CODE_SIGN_IDENTITY="-" 2>&1 | grep -E "Test Case|error:|Executed|TEST (SUCCEEDED|FAILED)|BUILD FAILED" || true
