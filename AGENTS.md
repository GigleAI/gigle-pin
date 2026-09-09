# Working on this codebase

Gigle Pin is a macOS screenshot, pin and screen-recording tool written in Swift 6
and AppKit. This file is the short version of what a person — or an agent — needs
to know before changing it. The expensive surprises are in
[`docs/lessons.md`](docs/lessons.md); read that before touching recording,
annotation burn-in, or anything that draws over the screen.

## Non-negotiables

**No third-party dependencies.** System frameworks only. This is why the bundle
is under 3 MB and why it launches instantly. Reaching for a package to save
thirty lines trades away the one thing the project is built on.

**`project.yml` is the truth; `Pin.xcodeproj` is generated.** Add a file, run
`xcodegen generate`. The project file is deliberately untracked, so editing it
in Xcode loses the change on the next regeneration.

**All coordinate conversion goes through `Util/Geometry.swift`.** AppKit's origin
is bottom-left, CoreGraphics' is top-left, and essentially every multi-monitor
bug traces back to mixing them. Do not do the arithmetic inline "just this once".

**The annotation layer and click ripples must stay out of `excludingWindowIDs`.**
They are supposed to be in the video. The recording frame and the HUD are the
ones to exclude. See `docs/lessons.md` — we got this backwards for a while.

**Hotkey conflicts are undetectable.** `RegisterEventHotKey` returns `noErr`
whether or not another app already owns the key. That is why first launch asks
the user to press it once. Do not replace that with a check; there isn't one.

**If you ship a fork, change the bundle identifier.** macOS routes `pin://`,
records TCC permissions and separates preference domains by bundle ID. Two
builds claiming `ai.gigle.pin` on one machine fight over all three, and the
symptoms are baffling: URLs reaching the wrong process, Screen Recording
permission that appears granted but is not, settings that reset. Change
`PRODUCT_BUNDLE_IDENTIFIER`, the URL scheme in `project.yml`, and the product
name together.

## Layout

```
Sources/Pin/
├── App/         menu bar, lifecycle, onboarding, pin:// routing
├── Hotkey/      Carbon RegisterEventHotKey — global keys, no Accessibility needed
├── Capture/     ScreenCaptureKit stills, window and UI-element detection
├── Overlay/     the frozen-screen selection layer
├── Annotate/    drawing tools and the undo stack
├── Pin/         always-on-top image windows
├── Record/      SCStream → AVAssetWriter (MP4), ImageIO (GIF), the review window
├── Settings/    UserDefaults-backed preferences
└── Util/        coordinate spaces, geometry, paths
```

## Build and check

```bash
scripts/build.sh          # xcodegen + a Debug build; prints errors only
scripts/smoke.sh          # drives the app through pin:// URLs and asserts on its log
scripts/install.sh        # Release build into /Applications
scripts/i18n-scan.sh      # after adding any L("key", "…") string
scripts/skill-sync.sh     # after editing .agents/skills/pin-screen-recorder/SKILL.md
```

`smoke.sh` briefly takes over the screen — it opens the capture overlay and
records a small region. Do not run it on someone else's machine without asking.

## Testing this app is unusual, and the traps are real

Mouse drags and global hotkeys cannot be automated, so every surface has a URL
entry point instead (`pin://snip`, `pin://record?…`, `pin://review?…`). Assert on
the app's own log lines and on the files it produces — not on screenshots, unless
a human needs to judge how something looks.

Two rules that came out of losing time to tests that could not fail:

- **A synthetic key event cannot trigger a Carbon hotkey.** Verify hotkeys by
  hand; use the URL scheme as the stand-in everywhere else.
- **Prove a new check can fail** before trusting it green. Break the code on
  purpose and watch it go red. Four of ours passed against code that was
  provably broken.

## Localization

User-facing strings go through `L("key", "中文原文")` (or `Lf` with arguments),
with the Chinese written at the call site so reading the code tells you what
appears on screen. `scripts/i18n-scan.sh` syncs both `.strings` files and never
overwrites an existing translation.

## Design decisions that look like bugs

Some behaviour here is deliberate and will regress if it gets tidied up.
`docs/lessons.md` explains the reasoning; the short list:

- The first hotkey press of the day is ~200 ms slower. Pre-warming the capture
  API would fix it, but that means reading the screen at launch, and the privacy
  policy says we only read it when you press the key.
- The colour readout is sRGB and will not match a Display P3 screen pixel for
  pixel on saturated colours. That is the correct value to hand to CSS.
- Recording happens at physical pixels, not points. Zoom belongs in the review
  window, not in the capture resolution.
