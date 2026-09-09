#!/bin/zsh
# Install into /Applications properly (where Launchpad and Spotlight look for it), refresh the icon
# cache, and launch.
#   scripts/install.sh              build number 2, the project default
#   PIN_BUILD=26 scripts/install.sh   a build number of your own
#
# Give it a number whenever the copy is meant to be told apart from the released one: the version
# string alone cannot do it, because a test build carries the same 0.1.4 as the download does.
set -e
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
xcodebuild -project Pin.xcodeproj -scheme Pin -configuration Release -derivedDataPath build \
  ${PIN_BUILD:+CURRENT_PROJECT_VERSION="$PIN_BUILD"} build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u
APP="build/Build/Products/Release/Gigle Pin.app"
[ -d "$APP" ] || { echo "no build"; exit 1; }
osascript -e 'tell application "Gigle Pin" to quit' >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6; do pgrep -x "Gigle Pin" >/dev/null || break; sleep 0.5; done
pkill -x "Gigle Pin" 2>/dev/null || true
sleep 0.3
rm -rf "/Applications/Gigle Pin.app"
# A bundle under an older name is **never deleted automatically** — only reported. Leaving it in place
# can route pin:// to the old copy, so the warning says as much and the decision stays with a person.
for old in "/Applications/Pin.app" "/Applications/Gigle Jay.app" "/Applications/Jay.app"; do
    [ -d "$old" ] && echo "⚠︎ An older version is still here: $old — worth removing by hand, or pin:// links may be routed to it"
done
ditto "$APP" "/Applications/Gigle Pin.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Gigle Pin.app" >/dev/null
killall Dock 2>/dev/null || true   # refresh the icon cache
open -a "/Applications/Gigle Pin.app"
V=$(defaults read "/Applications/Gigle Pin.app/Contents/Info" CFBundleShortVersionString)
B=$(defaults read "/Applications/Gigle Pin.app/Contents/Info" CFBundleVersion)
echo "installed → /Applications/Gigle Pin.app   $V ($B)"
