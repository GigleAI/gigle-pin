#!/usr/bin/env bash
# Record a region with Gigle Pin while a command runs, then wait for the file.
#
#   pin-record.sh OUT.mp4 X Y W H [-- command args…]
#
# Coordinates are screen points, origin top-left (same as `screencapture -R`).
# Uses `open -g` throughout: Pin is never activated, the user's mouse and
# focus are untouched. While your command runs, call
#   open -g "pin://ripple?x=…&y=…"   after each click you make
#   open -g "pin://ink?x1=&y1=&x2=&y2=&tool=arrow|ellipse|marker"   to point at things
set -euo pipefail
# With more than one copy of Pin installed, LaunchServices decides which one a bare
# `open pin://…` reaches. Set PIN_APP=/path/to/Gigle\ Pin.app to pin it down. With a
# single copy in /Applications — the normal case — you can ignore this.
pin() { open -g ${PIN_APP:+-a "$PIN_APP"} "$1"; }
OUT="${1:?OUT.mp4}"; X="${2:?x}"; Y="${3:?y}"; W="${4:?w}"; H="${5:?h}"; shift 5
[ "${1:-}" = "--" ] && shift
rm -f "$OUT" "$OUT.done"
pin "pin://record?x=$X&y=$Y&w=$W&h=$H&out=$OUT"
sleep 1.5                                  # let the stream start before the action begins
if [ $# -gt 0 ]; then "$@" || true; fi
pin "pin://stop"
for _ in $(seq 1 120); do [ -f "$OUT.done" ] && break; sleep 0.5; done
[ -f "$OUT.done" ] || { echo "pin-record: no $OUT.done after 60 s — is Pin running with Screen Recording permission?" >&2; exit 1; }
echo "$OUT"
