// The look of the interface.
//
// This governs **ordinary interface** (the settings and welcome windows). The floating bars (capture
// toolbar, recording HUD, recording result bar, review bar) read the same two settings but resolve
// them to concrete colours through `BarStyle` — they draw straight into layers, and a dynamic
// NSColor's `.cgColor` is snapshotted, so it cannot follow the appearance.
//
// The one thing the bars cannot compromise on: **their appearance is nailed down and must not adapt
// to the desktop.** The `.hudWindow` material brightens and darkens with whatever is behind it, and
// over a light desktop the whole bar goes white and the icons disappear (photographed by Tim,
// 2026-09-05).
//
// The selection overlay itself stays black — dimming the screen is its job, and that has nothing to
// do with the theme.

import AppKit
import ObjectiveC

/// Light and dark. **Orthogonal** to the palette — folded into one pop-up they eventually fight,
/// and Ink has its own paper (day) and night values, so it should not be locked to either side.
enum AppTheme: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: L("theme.system", "Follow system")
        case .light:  L("theme.light", "Light")
        case .dark:   L("theme.dark", "Dark")
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light:  NSAppearance(named: .aqua)
        case .dark:   NSAppearance(named: .darkAqua)
        }
    }
}

/// The palette. "Native" by default — unremarkable, and a user who never chooses sees nothing else.
enum AppPalette: String, CaseIterable {
    case native, ink, amber

    var title: String {
        switch self {
        case .native:  L("palette.native", "Native")
        // Called Jade in the settings, paired with Amber as a material (one cool, one warm).
        // "Ink and cinnabar" is the name of the design language over in GigleMDD; the identifiers
        // `.ink` / `Ink` follow it, and the user never sees them.
        case .ink:     L("palette.ink2", "Ink")
        case .amber:   L("palette.amber", "Amber")
        }
    }

    /// The custom palette; native has none (everything is left to the system). Interface code reads
    /// this and never the case.
    var colors: Palette? {
        switch self {
        case .native:  nil
        case .ink:     Ink.palette
        case .amber:   Ink.amber
        }
    }
}

/// A window that follows `Appearance` (system controls, custom palette, serif body text).
///
/// Only **ordinary interface** should carry this: the settings and welcome windows. Floating layers
/// never do — they colour themselves through `BarStyle`.
protocol ThemedWindow: NSWindow {}

@MainActor
enum Appearance {
    static var current: AppTheme {
        AppTheme(rawValue: Preferences.shared.appearance) ?? .system
    }

    static var palette: AppPalette {
        AppPalette(rawValue: Preferences.shared.palette) ?? .native
    }

    /// Apply to every ordinary window. Takes effect immediately, no restart.
    static func apply() {
        NSApp.appearance = current.nsAppearance
        // **Only windows marked `ThemedWindow`**, not every window.
        //
        // Floating layers (overlay toolbar, recording HUD, review bar, pins, Toast…) colour
        // themselves through `BarStyle`, and those rules are nothing like the settings window's.
        // This used to be `for w in NSApp.windows`, so switching palette painted settings-window
        // rules onto the bars: the review bar's "1×" turned accent blue and the timecode was dimmed
        // as "secondary text" — not matching a bar that had opened in that palette to begin with
        // (three comparison shots, 2026-09-06 08:4x: native, switched, and Jade from the start).
        //
        // Defaulting to "do not paint" is the safer side: a new floating layer that forgets the mark
        // is left alone, and the only things that genuinely have to follow are the settings and
        // welcome windows, both of which carry it.
        //
        // The cost: changing palette while a review window is open leaves that bar on the old one
        // until the next recording — a bar's colours are written into its controls once, when it is
        // built, and there is no repaint entry point. Stopping at the old palette beats turning into
        // something half-and-half on the spot.
        for w in NSApp.windows where w is ThemedWindow { paint(w) }
    }

    /// The system appearance only governs how controls light and darken; it cannot reach a custom
    /// palette or the fonts — Ink's paper ground, ink-coloured text, cinnabar accent and serif body
    /// all have to be painted on.
    /// The current custom palette; nil = native.
    static var colors: Palette? { palette.colors }

    static func paint(_ window: NSWindow) {
        guard let root = window.contentView else { return }
        let c = colors
        window.backgroundColor = c?.paper
        // The title bar paints a system ground of its own by default — a paper or sand-coloured body
        // under a pure white title bar leaves a white seam across the window, and the whole thing
        // looks half-painted. Made transparent, the title bar shows window.backgroundColor: the same
        // sheet of paper. It has to go back to false under the native palette, or "native" is not.
        window.titlebarAppearsTransparent = c != nil
        paint(view: root, colors: c)
    }

    /// Colour the controls recursively. Outside Ink, hand the colours back to nil or the system
    /// colour, so switching to "light" or "dark" is genuinely the plain system look with nothing left
    /// behind.
    /// Two constraints on the fonts:
    /// 1. **Body text only, never the chrome.** Notes below 11pt and button titles are the interface's
    ///    skeleton; setting the whole page in a serif turns it into a greeting card rather than a
    ///    macOS settings window.
    /// 2. **It has to be reversible.** Switching back to native has to be genuinely native, so the
    ///    original font is stashed on the control (an associated object) before the first change and
    ///    put back on the way out.
    private static var originalFontKey: UInt8 = 0
    /// The original text colour. **It has to be stored**, not guessed from "is this a system colour
    /// right now" — after one pass of Jade the original is already overwritten, and coming back there
    /// is no telling whether a line started as `.secondaryLabelColor` or `.tertiaryLabelColor`. So
    /// tertiary notes were restored as secondary and a whole block came back visibly darker
    /// (measured 2026-09-06 06:20: 182 → 124). The fonts had done this correctly all along; the
    /// colours were the ones that missed it.
    private static var originalColorKey: UInt8 = 0

    private static func applyFont(_ f: NSTextField, serif: Bool, secondary: Bool) {
        let saved = objc_getAssociatedObject(f, &originalFontKey) as? NSFont
        if serif {
            guard !secondary, let base = saved ?? f.font else { return }
            if saved == nil {
                objc_setAssociatedObject(f, &originalFontKey, base, .OBJC_ASSOCIATION_RETAIN)
            }
            let w: NSFont.Weight = base.fontDescriptor.symbolicTraits.contains(.bold)
                ? .semibold : .regular
            f.font = Ink.serif(base.pointSize, w)
        } else if let saved {
            f.font = saved
            objc_setAssociatedObject(f, &originalFontKey, nil, .OBJC_ASSOCIATION_RETAIN)
        }
    }

    private static func paint(view: NSView, colors c: Palette?) {
        switch view {
        case let f as NSTextField where !f.isEditable:
            let savedColor = objc_getAssociatedObject(f, &originalColorKey) as? NSColor
            let original = savedColor ?? f.textColor
            // Keep secondary notes secondary; do not paint the whole page one shade of ink
            let secondary = original == .secondaryLabelColor
                || original == .tertiaryLabelColor
                || f.font?.pointSize ?? 13 < 12
            applyFont(f, serif: c?.serifBody ?? false, secondary: secondary)
            if let c {
                if savedColor == nil, let original {
                    objc_setAssociatedObject(f, &originalColorKey, original, .OBJC_ASSOCIATION_RETAIN)
                }
                f.textColor = secondary ? c.text.withAlphaComponent(0.55) : c.text
            } else if let savedColor {
                // Put it back exactly — never guess at something that cannot be derived
                f.textColor = savedColor
                objc_setAssociatedObject(f, &originalColorKey, nil, .OBJC_ASSOCIATION_RETAIN)
            }
        case let b as NSButton where b.image == nil && !b.title.isEmpty:
            // Checkboxes and plain buttons: change the text colour only, leave the shape to the system
            b.contentTintColor = c?.accent2
        default:
            break
        }
        view.subviews.forEach { paint(view: $0, colors: c) }
    }
}
