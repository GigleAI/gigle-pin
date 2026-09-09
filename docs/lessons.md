# What we got wrong first

Only the things that cost real time and would bite again: mechanisms that took a
while to understand, APIs that behave against intuition, and decisions that will
quietly regress if someone "cleans them up". Ordinary implementation detail is
in the code.

Every entry carries the measurement that settled it. **Before overturning one,
reproduce its experiment.**

---

## Recording

### Blurry video was a colour flag, not the bitrate

The obvious suspect is compression. It was not. Holding everything else fixed
and changing only `AVVideoAverageBitRateKey`:

| bits per pixel | PSNR |
| --- | --- |
| 0.12 | 29.55 dB |
| 0.5 | 29.58 dB |
| 1.0 | 29.61 dB |
| 2.0 | 29.63 dB |
| unbounded | 29.55 dB |
| HEVC instead of H.264 | 29.63 dB |

A ceiling at 29.6 dB that sixteen times the bitrate cannot move is not a
bitrate problem. The real cause was the colour range being expanded twice —
once by the capture pipeline and once by the encoder. Fix the flag and the
ceiling disappears.

Worth knowing anyway: ABR treats the target as a *limit*. Asking for 7 Mbps on
a still screen actually spends 748 kbps. Frugal, but not enough once the screen
moves, which is why the floor still went from 0.12 to 0.25 bpp.

### ScreenCaptureKit only emits a frame when the picture changes

A still screen produces nothing for seconds at a time. Write those frames
straight to an `AVAssetWriter` and three seconds of recording becomes a
three-frame video. You have to keep your own clock: tick at the target frame
rate, re-emit the most recent frame, round to the tick, make up dropped beats,
never go backwards. With that, a frozen screen gives 128 frames over 4.27 s at
30 fps instead of 3.

### Your own windows *are* captured

Using a display filter, SCK captures the windows of your own process too. We
filled a ripple canvas solid red and counted 299,587 red pixels in the video —
the same as on screen. `.borderless`, `.nonactivatingPanel`, a floating window
level, `collectionBehavior`: none of them exempt a window.

That is what makes "draw on the screen while recording" possible at all. The
annotation layer and the click ripples must *not* go into `excludingWindowIDs`;
the recording frame and the HUD must.

### Burning annotations into the export

`AVVideoCompositionCoreAnimationTool` renders each stroke as a `CALayer` placed
on the timeline with an animation's `beginTime` and `duration`, so AVFoundation
composites during export instead of you touching frames. Two traps:

- **Set the time on the animation only — never also on `layer.beginTime`.**
  `CALayer.beginTime` shifts the layer's own time base, so an animation
  attached to it gets displaced *twice*. A stroke meant for 1.6 s landed at
  3.2 s, past the end of a 3.07 s video, and vanished. It looks like a
  rendering bug; it is arithmetic.
- **`beginTime` needs `AVCoreAnimationBeginTimeAtZero`.** A literal `0` means
  "immediately", not "at second zero".

### Two audio tracks are not two audio tracks to the viewer

System audio and the microphone arrive as separate `AVAssetWriterInput`s, and
writing both produces a file with two AAC tracks. QuickTime plays the first
one. So do most browsers and upload sites. The user hears their narration, ships
the file, and the recipient gets only the system audio — with nothing anywhere
saying so. Flatten to a single track after `stop()`, and pass the video through
untouched (`outputSettings: nil`) so no frame is re-encoded.

### GIF export has no streaming path

`CGImageDestinationAddImage` accumulates every frame in memory and writes
nothing until `Finalize`. Sixty seconds at 15 fps and 800×533 peaks at **3.6 GB**.
`autoreleasepool` does not help — the memory belongs to ImageIO, not to your
loop. Budget by `frames × width × height` and degrade before you start: drop
the frame rate first, resolution second. Nobody watches a sixty-second GIF at
full rate anyway, but they do need to see what is in it.

## Hotkeys and input

### `RegisterEventHotKey` reports success when it fails

If another application already holds the key, registration returns `noErr` and
your handler simply never fires. There is no API that tells you. The only honest
approach is to ask the user to press the key once and report whether you
received it.

### Synthetic function keys cannot trigger Carbon hotkeys

A key event posted with `CGEvent` does not reach `RegisterEventHotKey` —
on hardware where the top row is media keys, the HID layer converts it first.
Global hotkeys can only be verified by a human pressing the key. Everything
else needs a URL scheme or equivalent as a test double.

## Text and symbols

### SF Symbols change shape with the system language

`textformat` renders as the two Chinese characters 「格式」 in a Chinese
locale — not as an icon. Several symbols ship localized variants
(`textformat`, `character`, `textformat.size` among them). A toolbar button
looked for weeks like it had a stale title; the symbol itself was drawing text.
Setting `title = ""` does not help, because it was never the title.

Pick symbols without localized variants for anything on a toolbar, and render
the toolbar once under each language you ship.

### `design: .serif` does nothing for CJK

`NSFontDescriptor.withDesign(.serif)` substitutes Latin glyphs only. Chinese,
Japanese and Korean fall back to the sans-serif system face, so a "serif theme"
is invisible in those languages. Attach a CJK serif family explicitly:

```swift
let d = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
let cjk = NSFontDescriptor(fontAttributes: [.family: "Songti SC"])
NSFont(descriptor: d.addingAttributes([.cascadeList: [cjk]]), size: size)
```

A family that does not exist fails silently in `cascadeList`, so check
`NSFontManager.shared.availableFontFamilies` first.

## Paths and coordinates

### In a sandbox, the home directory is not the home directory

`NSHomeDirectory()` and `homeDirectoryForCurrentUser` both return the app's
container. Build `~/Pictures/…` out of either and the files land somewhere the
user cannot find in Finder. `getpwuid(getuid())` is not redirected.

### Two coordinate spaces, one file

AppKit's origin is bottom-left, CoreGraphics' is top-left, and multi-monitor
bugs almost always come from mixing them. Every conversion in this codebase goes
through `Util/Geometry.swift`, and it stays that way.

## Measuring without fooling yourself

Four of the bugs above were prolonged by a test that could not fail. Some
specifics, all of them learned the expensive way:

- **Read the histogram, not just PSNR.** PSNR is a whole-frame average and gets
  dragged around by flat regions; a colour-range bug is obvious in a histogram
  and moves PSNR by about 1 dB.
- **Put the probe inside the region you are recording.** We concluded that SCK
  does not capture our own windows because a marker drawn 3 pt *outside* the
  recorded rectangle did not appear in the video. It was never in frame.
- **Look at one frame before writing a threshold.** A translucent warm ring over
  a dark background composites to `r = 158`; the assertion said `r > 170` and
  called a correct drawing a failure.
- **Wait longer than you think after synthesizing input.** Moving the cursor,
  starting a process and actually pressing takes ~400 ms; screenshotting sooner
  captures the state *before* the click.
- **Do not read a video that is still being written.** You get
  `moov atom not found`. Record N seconds, wait N+2.
- **Prove the test can fail.** Every check here was run once against code known
  to be broken. Four of them passed anyway, and were rewritten.
