// One look for the floating bars: corners and colour.
//
// "Floating bars" means four things: the capture toolbar, the recording HUD, the recording result
// bar and the review bar.
//
// ## Corners
//
// They were once 8 on the capture toolbar, 12 on the review bar and 17 on the recording HUD — three
// shapes side by side (spotted by Tim, 2026-09-05). Two rules:
//   - **Multi-row toolbars** always use `cornerRadius`.
//   - **A single-row status pill** (the recording HUD) uses `pill(height:)` = half its height, a
//     capsule on purpose — it is a status badge, of a kind with the system's own recording
//     indicator, not a toolbar.
//
// ## Colour
//
// The bars **follow the light/dark and palette settings** (Tim asked about it on 2026-09-05; before
// that they were hardcoded dark).
//
// One thing that cannot give, though: **the appearance is nailed down and must not adapt to the
// desktop.** The original was `NSVisualEffectView(material: .hudWindow)` with no appearance set, and
// that material brightens and darkens with **whatever is behind it** — over a light desktop the
// whole bar goes white and the white icons disappear (confirmed in a photograph). So now the
// setting is resolved to a definite light or dark, `NSAppearance` is pinned on the window, and the
// colours are **resolved to concrete values under that appearance** before reaching a layer.
//
// Why resolve them there and then: `layer.backgroundColor = someDynamicColor.cgColor` is a
// **snapshot** taken in whatever drawing context is current at assignment, and it does not follow
// the window's appearance afterwards. So everything returned here is a fixed colour, not a dynamic
// NSColor. The bars are rebuilt on every use, so snapshotting is fine.

import AppKit

@MainActor
enum BarStyle {

    // MARK: Shape

    static let cornerRadius: CGFloat = 12
    static func pill(height: CGFloat) -> CGFloat { height / 2 }

    /// The rounded mask for an `NSVisualEffectView`.
    ///
    /// **`layer.cornerRadius` does not work on frosted glass.** It rounds the scrim layer while the
    /// material backing stays square, so a square dark block sits outside the rounded corner — which
    /// reads as "the corners are not round enough" (Tim said twice on 2026-09-05 that the review
    /// bar's corners did not match the capture toolbar's; this was why). The capture toolbar never
    /// had the problem because it is an ordinary layer-backed view with no frosted glass at all.
    ///
    /// `NSVisualEffectView.maskImage` is the supported way: a stretchable rounded image, with
    /// `capInsets` keeping the four corners undistorted as it stretches.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let d = radius * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }

    // MARK: Light and dark

    /// For offscreen rendering only: render all four combinations without touching the user's
    /// preferences. The toolbar render script used to write to `Preferences` directly and left
    /// whatever the user had chosen set to the last combination it rendered — a verification tool
    /// that changes the user's settings is not acceptable.
    nonisolated(unsafe) static var override: (theme: AppTheme, palette: AppPalette)?

    static var isDark: Bool {
        switch override?.theme ?? Appearance.current {
        case .light:  false
        case .dark:   true
        case .system: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
    }

    /// The appearance pinned on a bar's window. **Do not skip this** — without it the frosted glass
    /// follows the desktop.
    static var appearance: NSAppearance {
        NSAppearance(named: isDark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    /// The current custom palette (nil = native). The render scripts switch it with `override`.
    private static var custom: Palette? { (override?.palette ?? Appearance.palette).colors }

    /// Resolve a dynamic colour under **the bar's own appearance**.
    private static func resolve(_ c: NSColor) -> NSColor {
        var out = c
        appearance.performAsCurrentDrawingAppearance {
            out = c.usingColorSpace(.sRGB) ?? c
        }
        return out
    }

    // MARK: Swatches

    /// How every swatch button is drawn: **the colour fills only the centre dot, the selection ring
    /// is drawn outside it, and the ground shows through the gap between.**
    ///
    /// It used to set a border on the swatch's layer — and a CALayer's border is drawn **inside**,
    /// which eats into the swatch: the red block shrinks and gets a dark rim, reading as "this colour
    /// has gone dirty" rather than "this one is selected" (Tim, 2026-09-05: it isn't clear which one
    /// is selected). Swatch → gap → ring is how colour pickers do it, and it works whatever colour
    /// the swatch happens to be.
    static let swatchSize: CGFloat = 20
    static let swatchDot: CGFloat = 13

    static func styleSwatch(_ b: NSButton, color: NSColor, selected: Bool) {
        b.isBordered = false
        b.title = ""
        b.imagePosition = .imageOnly
        b.wantsLayer = true
        b.layer?.backgroundColor = nil
        b.layer?.cornerRadius = swatchSize / 2
        b.layer?.borderWidth = selected ? 2 : 0
        b.layer?.borderColor = fg().cgColor
        // The image name has to carry "light or dark": hairline colour follows the theme, and with a
        // constant name a switch would fetch the cached image and leave the line in the old palette.
        let key = "swatch-\(isDark ? "d" : "l")"
        if b.image == nil || b.image?.name() != key {
            let img = NSImage(size: NSSize(width: swatchSize, height: swatchSize), flipped: false) { rect in
                let dot = NSBezierPath(ovalIn: rect.insetBy(dx: (swatchSize - swatchDot) / 2,
                                                            dy: (swatchSize - swatchDot) / 2))
                color.setFill()
                dot.fill()
                // Every swatch gets a hairline outline, **or the ones close to the ground disappear**:
                // black and dark grey swatches are nearly invisible on a dark bar, so the user is
                // choosing blind (only seen on 2026-09-06 when the review bar's third row was cropped
                // out — that row had never been captured before). The outline is the foreground colour
                // at low alpha, so it traces a light swatch on a light ground and a dark one on a dark
                // ground: one line, correct both ways.
                fg(0.22).setStroke()
                dot.lineWidth = 1
                dot.stroke()
                return true
            }
            img.setName(key)
            b.image = img
        }
    }

    // MARK: Colours

    /// The bar's ground. Laid over the frosted glass so contrast does not depend on the picture
    /// behind it.
    static var surface: NSColor {
        if let c = custom { return resolve(c.surface).withAlphaComponent(0.92) }
        return isDark ? NSColor(white: 0.11, alpha: 0.90) : NSColor(white: 0.97, alpha: 0.92)
    }

    /// Foreground: icons, text, separators, and the ground of a selected state. `alpha` gives the
    /// hierarchy.
    static func fg(_ alpha: CGFloat = 1) -> NSColor {
        let base = custom.map { resolve($0.text) } ?? (isDark ? NSColor.white : NSColor.black)
        return base.withAlphaComponent(alpha)
    }

    /// Secondary text (the hint line, the note beside a timecode).
    static var secondary: NSColor { fg(isDark ? 0.62 : 0.55) }

    static var border: NSColor { fg(isDark ? 0.16 : 0.10) }

    /// The ground of a selected state.
    static var selected: NSColor { fg(isDark ? 0.20 : 0.12) }

    /// The accent: cinnabar under Ink, the system accent otherwise.
    static var accent: NSColor {
        resolve(custom?.accent ?? .controlAccentColor)
    }

    /// A destructive action (delete).
    static var danger: NSColor {
        resolve(custom?.bad ?? .systemRed)
    }
}
