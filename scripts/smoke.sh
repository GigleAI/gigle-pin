#!/usr/bin/env bash
# Smoke test: no key presses, no mouse — drive the main path through pin:// alone, and assert that
# the process is alive and the log contains the lines it should.
#
#   scripts/smoke.sh            # tests the Debug bundle in build/ (has logs, so it can assert)
#   scripts/smoke.sh --release  # tests the release bundle in /Applications (asserts only that it lives)
#
# A non-zero exit means something did not pass. It really does write an mp4 into ~/Pictures/Pin, and
# deletes it afterwards.

set -uo pipefail
cd "$(dirname "$0")/.."
DEBUG=1
APP="$PWD/build/Build/Products/Debug/Gigle Pin.app"   # open -a only accepts an absolute path
[[ "${1:-}" == "--release" ]] && { DEBUG=0; APP="/Applications/Gigle Pin.app"; }
BIN="$APP/Contents/MacOS/Gigle Pin"
LOG="$(mktemp -t pin-smoke).log"
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
alive() { pgrep -x "Gigle Pin" >/dev/null 2>&1; }
has()   { [[ $DEBUG -eq 0 ]] || grep -q -- "$1" "$LOG"; }

[[ -x "$BIN" ]] || { echo "no executable at $BIN (run scripts/build.sh first)"; exit 2; }
echo "smoke test → $APP"
pkill -x "Gigle Pin" 2>/dev/null; sleep 0.5

# 1. A URL arriving at a cold start (historically the easiest place to crash: the URL beats
#    didFinishLaunching)
open -a "$APP" "pin://settings" >/dev/null 2>&1
sleep 3
alive && ok "survives a URL at cold start" || { bad "died at cold start"; exit 1; }
pkill -x "Gigle Pin"; sleep 0.5

# 2. Warm: launch with logging
nohup "$BIN" > "$LOG" 2>&1 &
disown
sleep 2
alive && ok "launches" || { bad "will not start"; exit 1; }
# The key is rebindable, so assert only that the capture key registered, never which key it is.
# Note that this proves only that RegisterEventHotKey returned success — it returns success on a
# conflict too, so "registered" is not "pressing it does something"; only a person can verify that.
# Match the enum name capture rather than a title: switching the interface language changes titles,
# and never changes the enum name.
has "registered capture .* → ok" && ok "capture hotkey registered" || bad "capture hotkey did not register"
has "screenRecording=true"   && ok "screen recording permission" || bad "no screen recording permission — everything below will fail"

# 3. Capture a region straight to the clipboard
open -a "$APP" "pin://sniprect?x=100&y=100&w=300&h=200"; sleep 2
has "copied 300×200" && ok "sniprect → clipboard" || bad "sniprect produced nothing"
alive || { bad "crashed after sniprect"; exit 1; }

# 4. Open the overlay and close it
open -a "$APP" "pin://snip"; sleep 1.5
has "ready," && ok "overlay came up" || bad "overlay did not come up"
open -a "$APP" "pin://cancel"; sleep 0.8
alive || { bad "crashed after the overlay"; exit 1; }

# 5. Record for 2 seconds
# **Ask the app where it put the file; do not assume ~/Pictures/Pin.** The save directory is a
# preference, and it resolves a security-scoped bookmark before the path key — so a directory left
# behind by another check (or chosen by the user) makes a perfectly good recording look like no
# recording at all. The log line is the product telling us what it did, which is what every other
# assertion here reads.
open -a "$APP" "pin://record?x=100&y=100&w=480&h=300&seconds=2"; sleep 7
F=$(grep -a '\[record\] done → ' "$LOG" | tail -1 | sed 's/.*\[record\] done → //')
if [[ -n "$F" && -f "$F" ]]; then
    # **The video stream has to be selected explicitly.** With system audio on by default the mp4 has
  # two tracks, and without selecting one ffprobe prints two lines, so the numeric comparison blows up
  # (hit on 2026-09-05, and reported by the smoke test on the spot).
  N=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$F" 2>/dev/null | head -1)
  A=$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$F" 2>/dev/null | head -1)
    [[ "${N:-0}" -ge 40 ]] && ok "2 s recording → ${N} frames (constant frame rate)" || bad "only ${N} frames recorded"
    [[ -n "$A" ]] && ok "system audio recorded by default (${A})" || bad "no system audio recorded by default"
  # The HUD's level meters need a reading per buffer, and the plumbing for that can break without
  # anything else noticing: audio still records, the file is still fine, and only the two little bars
  # stop moving. It broke on the first attempt — the buffer list call wants to be asked its size
  # first, and every reading came back nil (2026-09-08). Levels of zero are expected here; a still
  # screen makes no sound. What matters is that readings are arriving at all.
  has "\[audio\] level" && ok "audio levels reported for the HUD meters" \
                        || bad "no [audio] level lines — the meters would sit dead"
  rm -f "$F"
else
    bad "recording produced no file"
fi
alive || { bad "crashed after recording"; exit 1; }

# 6. Pin an image, then close them all
screencapture -x -R 0,0,200,120 "$LOG.png" 2>/dev/null
open -a "$APP" "pin://pin?file=$LOG.png"; sleep 1
has "\[pin\] pinned" && ok "pinning" || bad "nothing was pinned"
open -a "$APP" "pin://pins?close=1"; sleep 0.8
alive || { bad "crashed after pinning"; exit 1; }

pkill -x "Gigle Pin" 2>/dev/null
rm -f "$LOG.png"
echo
echo "passed ${PASS} · failed ${FAIL}   (log: ${LOG})"
[[ $FAIL -eq 0 ]]
