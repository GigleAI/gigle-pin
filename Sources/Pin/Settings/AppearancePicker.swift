// The controls for light/dark and for the palette.
//
// A pop-up would be heavy for three options — follow system / light / dark reads at a glance as a
// segmented control, and it can draw the sun and moon outright. Same for the palette: a real swatch
// is faster to judge than a name.

import AppKit

/// Light or dark: ☀︎ light · ☾ dark · ⚙︎ follow system
@MainActor
final class ThemeSegments: NSSegmentedControl {
    var onPick: ((AppTheme) -> Void)?

    private static let order: [AppTheme] = [.light, .dark, .system]

    init() {
        super.init(frame: .zero)
        segmentCount = Self.order.count
        segmentStyle = .texturedRounded
        trackingMode = .selectOne
        for (i, t) in Self.order.enumerated() {
            let sym: String
            switch t {
            case .light:  sym = "sun.max"
            case .dark:   sym = "moon"
            case .system: sym = "circle.lefthalf.filled"
            }
            setImage(NSImage(systemSymbolName: sym, accessibilityDescription: t.title), forSegment: i)
            setWidth(52, forSegment: i)
            setToolTip(t.title, forSegment: i)
        }
        selectedSegment = Self.order.firstIndex(of: Appearance.current) ?? 2
        target = self
        action = #selector(picked)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func picked() {
        guard selectedSegment >= 0 else { return }
        onPick?(Self.order[selectedSegment])
    }
}

/// Palette: a small swatch in the actual colours, plus the name. Seeing beats reading.
@MainActor
final class PaletteSegments: NSSegmentedControl {
    var onPick: ((AppPalette) -> Void)?

    init() {
        super.init(frame: .zero)
        segmentCount = AppPalette.allCases.count
        segmentStyle = .texturedRounded
        trackingMode = .selectOne
        for (i, p) in AppPalette.allCases.enumerated() {
            setImage(Self.swatch(p), forSegment: i)
            setLabel(p.title, forSegment: i)
            setWidth(96, forSegment: i)
        }
        selectedSegment = AppPalette.allCases.firstIndex(of: Appearance.palette) ?? 0
        target = self
        action = #selector(picked)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Two half-circles: background on the left, accent on the right — the character of the palette
    /// in one glance.
    private static func swatch(_ p: AppPalette) -> NSImage {
        let d: CGFloat = 13
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        let (bg, accent): (NSColor, NSColor) = p.colors.map { ($0.paper, $0.accent) }
            ?? (NSColor.textBackgroundColor, NSColor.controlAccentColor)
        let full = NSRect(x: 0, y: 0, width: d, height: d)
        bg.setFill(); NSBezierPath(ovalIn: full).fill()
        let right = NSBezierPath()
        right.appendArc(withCenter: NSPoint(x: d / 2, y: d / 2), radius: d / 2,
                        startAngle: -90, endAngle: 90)
        right.line(to: NSPoint(x: d / 2, y: d / 2))
        right.close()
        accent.setFill(); right.fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let ring = NSBezierPath(ovalIn: full.insetBy(dx: 0.5, dy: 0.5))
        ring.lineWidth = 1
        ring.stroke()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    @objc private func picked() {
        guard selectedSegment >= 0 else { return }
        onPick?(AppPalette.allCases[selectedSegment])
    }
}
