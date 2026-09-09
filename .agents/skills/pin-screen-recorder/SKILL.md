---
name: pin-screen-recorder
description: Record the screen, capture regions, and mark where you clicked with Gigle Pin on macOS. Use when asked to make a demo video, record a walkthrough of an app or website, take annotated screenshots, or show viewers where a click happened. Works without touching the user's mouse or focus.
---

# Gigle Pin — screen recording and capture for agents

Pin is a macOS menu-bar app. You drive it entirely through `pin://` URLs from
the shell. Every call returns immediately; results are files at paths **you**
choose. Nothing you do here moves the user's mouse or steals their focus.

Always use `open -g` (background). Plain `open` activates Pin and brings it
to the front, which interrupts the user.

## This file is English only, on purpose

It is an interface contract — command names, parameter names, coordinate
conventions. Translating it would mean several copies of that contract, and a
copy that has fallen behind reads exactly like a correct one while naming a
parameter that no longer exists. Pin's interface is localized in seven
languages; this file is not, and that is deliberate.

## Are you reading the right copy of this?

This file ships **inside the app bundle**, so the copy at

```
/Applications/Gigle Pin.app/Contents/Resources/pin-screen-recorder/SKILL.md
```

always describes the Pin that is actually installed. **Prefer it.** The copy on
gigle.ai moves with releases and can describe a newer Pin than the one on this
machine, which is how an agent ends up calling a command that does not exist.

If you are unsure what you are talking to, ask:

```bash
open -g "pin://version?out=/tmp/pin.json"   # writes /tmp/pin.json, then /tmp/pin.json.done
```

It reports the version, the URL schemes this copy answers to, every command it
supports, and the path to its own bundled copy of this file.

A command this build does not have is **rejected out loud** (a beep and a line
in Pin's log naming what it does support) rather than ignored — but your process
cannot see that, so if a call produces no output file, check `pin://version`
before concluding Pin is broken.

## Coordinates

- `x y w h` are **screen points with the origin at the top-left**, the same
  as `screencapture -R x,y,w,h` and the same as what accessibility APIs report.
- `ink` uses **0…1 relative to the recording region**, y downward.
- Multiple displays: keep a region inside one display.

## Record a demo of an app or website

Pin records a **screen region**, so whatever is on screen there is what gets
recorded. Before you start, bring the target window to the front and place it
yourself — e.g. `osascript -e 'tell application "Safari" to activate'` and set
its window bounds — then record exactly that rectangle. Do not ask the user to
arrange windows for you; do it, then record.

```bash
open -g "pin://record?x=100&y=80&w=1200&h=800&out=/tmp/demo.mp4"
# … drive the app now …
open -g "pin://stop"
until [ -f /tmp/demo.mp4.done ]; do sleep 0.5; done   # file is final
```

**Every time you click inside the region, tell Pin where** — your clicks are
invisible to the recorder, and viewers cannot see what you did otherwise:

```bash
open -g "pin://ripple?x=640&y=420"      # draws a click ripple at that point
```

To point at something or circle it (shows for ~3 s; add `&sticky=1` to keep it
for the whole recording):

```bash
open -g "pin://ink?x1=0.2&y1=0.3&x2=0.6&y2=0.5&tool=arrow"     # arrow from → to
open -g "pin://ink?x1=0.3&y1=0.3&x2=0.7&y2=0.6&tool=ellipse"   # ellipse in that box
open -g "pin://ink?x1=0.1&y1=0.5&x2=0.9&y2=0.5&tool=marker"    # highlighter stroke
```

Or use the wrapper in `scripts/pin-record.sh`, which starts, runs your
command, stops, and waits:

```bash
scripts/pin-record.sh /tmp/demo.mp4 100 80 1200 800 -- ./drive-the-app.sh
```

Other recording controls: `pin://pause` (toggle), `pin://record?…&seconds=10`
(auto-stop). Pin records at a constant frame rate with computer audio on by
default; the microphone is off unless the user enabled it.

## Screenshot a region

```bash
open -g "pin://sniprect?x=100&y=80&w=800&h=600&out=/tmp/shot.png"
until [ -f /tmp/shot.png.done ]; do sleep 0.2; done
```

Without `out=` the image goes to the clipboard only.

## Rules for `out=`

Pin cannot tell your request apart from one a web page made — macOS hands over a
URL with no sender. So `out=` is checked rather than trusted, and a refusal is
printed to Pin's log rather than acted on:

- **Absolute path**, with `~` allowed.
- **Inside** `~/Pictures`, `~/Movies`, `~/Downloads`, `~/Desktop`, `~/Documents`,
  the user's save folder, or a temporary directory. Symlinks and `..` are
  resolved before the check, so neither gets you out.
- **The extension must match what the verb writes**: `.json` for `version`,
  `.png` for `sniprect`, `.mp4` or `.mov` for `record`.
- **An existing file is not replaced.** Add `overwrite=1` when you mean to
  replace your own file — re-recording the same take, for instance.

```bash
open -g "pin://record?x=0&y=0&w=800&h=600&out=/tmp/demo.mp4&overwrite=1"
```

If `.done` never appears, the request was refused. Pick a path that satisfies
the rules above rather than retrying the same one.

## Pin an image on top of everything

```bash
open -g "pin://pin?file=/tmp/reference.png"   # floats above all windows
open -g "pin://pins?toggle=1"                  # hide / show all pins
open -g "pin://pins?close=1"                   # close all pins
```

## Recording Pin itself (a demo of Pin)

Pin leaves its own overlay, toolbar and HUD out of its recordings, so a
recording *by* Pin never shows Pin. To film Pin, use a second copy called
**Gigle Pin Director** — same app, different bundle ID and URL scheme, hotkeys on the F9 family instead of F1.
If it is not installed, build it from the source repo:

```bash
scripts/build-director.sh --install      # installs /Applications/Gigle Pin Director.app
```

There are now **three roles on screen** — keep them straight:

1. **Gigle Pin Director** (`pindirector://`) — the camera. It does the recording and
   its own overlay/HUD stay out of the video.
2. **Pin** (`pin://`) — the subject. This is the app you are demonstrating.
3. **The user's real windows and mouse** — untouched.

So to demo Pin's region capture, from inside a Director recording:

```bash
open -g "pindirector://record?x=0&y=0&w=1440&h=900&out=/tmp/pin-demo.mp4"
open -g "pin://snip"                       # Pin's capture overlay appears
# drag out a selection so viewers see the interaction. You cannot press F1 —
# synthetic key events do not trigger Pin's global hotkey — so either drag
# with your own cursor, or skip straight to the result:
open -g "pin://sniprect?x=200&y=200&w=600&h=400"   # captures without the drag
open -g "pindirector://ripple?x=500&y=400"          # mark where you 'clicked'
open -g "pindirector://stop"
until [ -f /tmp/pin-demo.mp4.done ]; do sleep 0.5; done
```

Note the ripple/ink go to **`pindirector://`** (the camera draws them into its
own video), while the capture happens in **`pin://`** (the subject). The two
never interfere. The Director needs the Screen Recording permission once —
the user must click Allow.

### Picture-in-picture: filming Pin recording a third app

The most useful demo of Pin shows Pin *at work* on something else. Frame it
as one big rectangle inside another:

```bash
# Camera: Director records a large, clean area (nothing private inside it).
open -g "pindirector://record?x=0&y=0&w=1280&h=800&out=/tmp/pin-showcase.mp4"
# Subject: Pin records (or captures) a smaller region of a third app inside
# that area. Pin's red frame, toolbar and magnifier are a different process,
# so they DO appear in the Director's video — that is the point.
open -g "pin://record?x=120&y=140&w=900&h=520&out=/tmp/inner.mp4&seconds=6"
# … let the third app do something …
open -g "pindirector://ink?x1=0.1&y1=0.1&x2=0.4&y2=0.2&tool=arrow"   # point at Pin's frame
open -g "pindirector://stop"
until [ -f /tmp/pin-showcase.mp4.done ]; do sleep 0.5; done
```

On screen you will see two red frames — the Director's outer one and Pin's
inner one. The Director excludes only its own frame, so its video shows just
Pin's inner frame sitting on the content: Pin, visibly working.

## Rules

- **One recording at a time.** A second `record` is refused until you `stop`.
- **Wait for `.done`**, not for the file to appear — the file exists before it
  is finished.
- **Do not send F1 / ⇧F1 / ⌘⇧F1** — those are the user's hotkeys. Use the URLs.
- **Do not open the interactive overlay** (`pin://snip`) — it waits for a
  human to drag. Use `sniprect` / `record` with explicit coordinates.
- If a call does nothing, it was refused: Pin beeps and logs one line saying
  why (bad coordinates, not recording, point outside the region). Fix the
  call rather than retrying it.
- Pin needs the **Screen Recording** permission (granted once by the user).
  If recording never produces a file, that is the reason — tell the user.
