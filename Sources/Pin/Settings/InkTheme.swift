// The custom palettes: Ink (brought over from GigleMDD-Wombat / GigleMDD-Magpie) and Amber (Pin's
// own).
//
// A note on the name: in the original project this is called **ink and cinnabar**, not "chrysanthemum
// and ink". There is no chrysanthemum anywhere in the GigleMDD tree, and no yellow or autumn hue in
// the system that would answer to it (the closest, #ECB84A, is reserved for the logo).
//
// The rule, in the original project's words: **never a system grey**. Light is warm paper-white,
// dark is a blue-black ink night, not a neutral black. The texture is **solid paper, hairlines and a
// soft shadow** — deliberately not frosted glass, which happens to suit Pin exactly (the
// `.hudWindow` material goes white along with the desktop).

import AppKit

/// One palette. **Every custom palette uses the same semantic slots**, so interface code names a
/// slot rather than a colour and adding a third or fourth needs no if/else anywhere (this replaced
/// the hardcoded Ink checks when Celadon was tried on 2026-09-05).
///
/// Every colour is a dynamic NSColor carrying its own day and night values — light/dark and palette
/// stay orthogonal.
struct Palette: Sendable {
        // Surfaces
        let paper: NSColor      // app background
        let surface: NSColor    // card face, one step lighter than the paper
        let well: NSColor       // wells: fields and pills, one step darker than the paper
        let hairline: NSColor   // hairlines: the only colour borders and separators use
    let text: NSColor
        // Accents (two, with distinct meanings)
        let accent: NSColor     // doing / the primary action — recording, danger
        let accent2: NSColor    // listening / choosing / standard — selection, current item
    let accentSoft: NSColor
    let accent2Soft: NSColor
    /// Text on top of a solid accent. **In dark mode this is usually dark, not white** — the dark
    /// accent has been lightened.
    let onAccent: NSColor
    // States
    let good: NSColor
    let mid: NSColor
    let bad: NSColor
    /// Whether body text is set in a serif (Songti plus New York). Both custom palettes do; native
    /// does not.
    let serifBody: Bool
}

enum Ink {

    // MARK: Ink

    /// Paper #F6F4EF / ink night #0E131B; cinnabar for actions, ink blue for selection.
    static let palette = Palette(
        paper:       dyn(light: (0.965, 0.957, 0.937), dark: (0.055, 0.075, 0.106)),
        surface:     dyn(light: (0.996, 0.992, 0.984), dark: (0.098, 0.125, 0.169)),
        well:        dyn(light: (0.937, 0.925, 0.898), dark: (0.137, 0.169, 0.220)),
        hairline:    dyn(light: (0.110, 0.141, 0.184), dark: (0.914, 0.902, 0.871), alpha: 0.13),
        text:        dyn(light: (0.125, 0.157, 0.204), dark: (0.933, 0.918, 0.886)),
                accent:      dyn(light: (0.843, 0.278, 0.271), dark: (0.910, 0.376, 0.357)),   // cinnabar
                accent2:     dyn(light: (0.188, 0.337, 0.525), dark: (0.451, 0.631, 0.863)),   // ink blue
        accentSoft:  dyn(light: (1.0, 0.910, 0.894),   dark: (0.243, 0.118, 0.110)),
        accent2Soft: dyn(light: (0.882, 0.941, 1.0),   dark: (0.106, 0.165, 0.235)),
        onAccent:    dyn(light: (1.0, 1.0, 1.0),       dark: (0.055, 0.075, 0.106)),
        good:        dyn(light: (0.239, 0.545, 0.306), dark: (0.384, 0.741, 0.463)),
        mid:         dyn(light: (0.780, 0.525, 0.055), dark: (0.878, 0.659, 0.243)),
        bad:         dyn(light: (0.753, 0.227, 0.220), dark: (0.878, 0.384, 0.345)),
        serifBody:   true)

    // Old names kept as aliases; other code still uses them.
    static var paper: NSColor { palette.paper }
    static var surface: NSColor { palette.surface }
    static var well: NSColor { palette.well }
    static var hairline: NSColor { palette.hairline }
    static var text: NSColor { palette.text }
    static var cinnabar: NSColor { palette.accent }
    static var inkBlue: NSColor { palette.accent2 }
    static var good: NSColor { palette.good }
    static var bad: NSColor { palette.bad }

    // MARK: Amber
    //
    // The first attempt at a third palette was Celadon: pale green #EEF3EF over pine night #0F1816.
    // It makes sense on a swatch card and **is indistinguishable from Ink on screen** — both light
    // values are "close to white" and both dark ones "close to black", separated by a hue nudge (Tim,
    // 2026-09-05: 「感觉没什么变化啊」 — it doesn't look any different). The lesson: **a third palette
    // has to separate in lightness and saturation, not only hue.**
    //
    // Amber: warm cream paper #F4E9D8 over a deep charcoal-brown night #1A1512, dark amber text and
    // an amber-gold accent — the leather and brass of an old camera, which suits a capture tool's
    // sense of being an object. Deep indigo as the complementary selection colour.
    // Body text is **sans-serif**: the first two palettes are bookish, this one is object-like, and
    // the type should say so too.

    static let amber = Palette(
                paper:       dyn(light: (0.957, 0.914, 0.847), dark: (0.102, 0.082, 0.071)),   // cream / charcoal
        surface:     dyn(light: (0.980, 0.953, 0.906), dark: (0.145, 0.118, 0.098)),
        well:        dyn(light: (0.914, 0.855, 0.769), dark: (0.192, 0.157, 0.129)),
        hairline:    dyn(light: (0.227, 0.165, 0.078), dark: (0.941, 0.816, 0.596), alpha: 0.16),
        text:        dyn(light: (0.227, 0.165, 0.078), dark: (0.965, 0.906, 0.800)),
                accent:      dyn(light: (0.784, 0.478, 0.106), dark: (0.941, 0.627, 0.208)),   // amber gold
                accent2:     dyn(light: (0.184, 0.290, 0.471), dark: (0.529, 0.682, 0.898)),   // deep indigo
        accentSoft:  dyn(light: (0.980, 0.906, 0.776), dark: (0.290, 0.212, 0.110)),
        accent2Soft: dyn(light: (0.859, 0.898, 0.945), dark: (0.129, 0.176, 0.251)),
                onAccent:    dyn(light: (0.102, 0.082, 0.071), dark: (0.102, 0.082, 0.071)),   // dark on gold, both ways
        good:        dyn(light: (0.239, 0.545, 0.306), dark: (0.384, 0.741, 0.463)),
        mid:         dyn(light: (0.780, 0.525, 0.055), dark: (0.878, 0.659, 0.243)),
        bad:         dyn(light: (0.753, 0.227, 0.220), dark: (0.878, 0.384, 0.345)),
        serifBody:   false)

    // MARK: Spacing and radii
    //
    // Not an 8pt grid — the series is 4/8/12/16/22/32. Corners are always continuous (squircles).

    enum Space {
        static let xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12
        static let l: CGFloat = 16, xl: CGFloat = 22, xxl: CGFloat = 32
    }
    enum Radius {
        static let chip: CGFloat = 8, field: CGFloat = 12
        static let card: CGFloat = 20, stage: CGFloat = 26
    }

    // MARK: Type
    //
    // The division of roles is the heart of this language: **content in a serif, interface chrome in
    // a sans, and figures in a monospace.**
    //
    // The trap: `design: .serif` only swaps **Latin** glyphs for New York, and Chinese falls straight
    // back to PingFang (a sans) — so on a Chinese interface the whole idea of "ink" simply did not
    // happen (Tim, 2026-09-05: 「字体什么的都没变化？」 — nothing about the type changed?). The CJK
    // serif has to be attached explicitly through cascadeList: New York for Latin, Songti SC for
    // Chinese, so both sides are serif.

    static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let d = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        let cjk = NSFontDescriptor(fontAttributes: [.family: cjkSerifFamily])
        return NSFont(descriptor: d.addingAttributes([.cascadeList: [cjk]]), size: size) ?? base
    }

    /// The system's own CJK serif. Songti is the printed, bookish one, closest to what Ink wants.
    /// Falls back to an empty string if it is missing — a family that does not exist in cascadeList
    /// raises no error, it simply has no effect.
    static let cjkSerifFamily: String = {
        let available = Set(NSFontManager.shared.availableFontFamilies)
        return ["Songti SC", "Songti TC", "STSong", "Times New Roman"]
            .first(where: available.contains) ?? ""
    }()
    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
    /// A section eyebrow: small, semibold, uppercase, letterspaced, in the secondary colour.
    static var eyebrow: NSFont { .systemFont(ofSize: 11, weight: .semibold) }

    // MARK: Shadow
    /// "The soft shadow of paper" — the only one in the whole system.
    static func paperShadow() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.06)
        s.shadowBlurRadius = 14
        s.shadowOffset = NSSize(width: 0, height: -5)
        return s
    }

}

fileprivate func dyn(light: (CGFloat, CGFloat, CGFloat),
                        dark: (CGFloat, CGFloat, CGFloat),
                        alpha: CGFloat = 1) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let (r, g, b) = isDark ? dark : light
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
