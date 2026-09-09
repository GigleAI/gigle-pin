#!/usr/bin/env bash
# Generate the project and build Debug. Prints errors and the result, nothing else.
#   scripts/build.sh          # Debug
#   scripts/build.sh release  # Release
set -uo pipefail
cd "$(dirname "$0")/.."
CFG=Debug; [[ "${1:-}" == "release" ]] && CFG=Release
# Sync the localization tables first: editing the string in an L() call and forgetting to run the
# scan means the bundle ships the old table, and the interface still shows the old text — or an
# untranslated string (a round of debugging was wasted on exactly this, 2026-09-06).
scripts/i18n-scan.sh | grep -E "placeholder|untranslated [1-9]|❌" || true
xcodegen generate >/dev/null || exit 1
xcodebuild -project Pin.xcodeproj -scheme Pin -configuration "$CFG" -derivedDataPath build build 2>&1 \
  | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" | sort -u
echo "→ build/Build/Products/$CFG/Gigle Pin.app"
