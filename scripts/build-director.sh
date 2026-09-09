#!/usr/bin/env bash
# Build a copy called "Gigle Pin Director": the same code with bundle ID ai.gigle.pin.director, the
# pindirector:// URL scheme, and hotkeys defaulting to the F9 family (clear of the shipping build's
# F1). **Local use only, never released** — its one purpose is letting an AI record Pin itself (Pin
# leaves its own overlay and toolbars out of a recording, so filming a Pin demo takes a second
# process).
#
#   scripts/build-director.sh            # build only; the result is in build-director/…/Gigle Pin Director.app
#   scripts/build-director.sh --install  # install to /Applications/Gigle Pin Director.app and launch it
#
# How an AI uses it: open -g "pindirector://record?x=&y=&w=&h=&out=/tmp/pin-demo.mp4"
# The Pin being filmed carries on with pin:// or F1. Each copy receives its own URLs, and they do not
# interfere.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Pin.xcodeproj -scheme Pin -configuration Release -derivedDataPath build-director \
  PRODUCT_BUNDLE_IDENTIFIER=ai.gigle.pin.director PRODUCT_NAME="Gigle Pin Director" \
  PIN_URL_SCHEME=pindirector PIN_ROLE=director build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP="build-director/Build/Products/Release/Gigle Pin Director.app"
[ -d "$APP" ] || { echo "no build"; exit 1; }
echo "  $(defaults read "$PWD/$APP/Contents/Info" CFBundleIdentifier)  scheme=$(defaults read "$PWD/$APP/Contents/Info" CFBundleURLTypes | grep -o 'pindirector')  role=$(defaults read "$PWD/$APP/Contents/Info" PinRole)"
if [ "${1:-}" = "--install" ]; then
  osascript -e 'tell application "Gigle Pin Director" to quit' >/dev/null 2>&1 || true; sleep 0.5
  rm -rf "/Applications/Gigle Pin Director.app"; ditto "$APP" "/Applications/Gigle Pin Director.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Gigle Pin Director.app" >/dev/null
  open -a "/Applications/Gigle Pin Director.app"; echo "installed → /Applications/Gigle Pin Director.app"
fi
