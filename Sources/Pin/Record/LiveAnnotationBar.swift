// The second row while recording: tool, colour, width.
//
// Same rule as the capture toolbar: **the first row is actions only, and the second appears when
// you pick up a pen** (Tim, 2026-09-05). The recording HUD is a small pill most of the time, and
// this row shows up only when you actually mean to draw — someone who never draws never sees it.
//
// It is a separate panel hanging below the HUD rather than a second row inside it: the HUD is a
// capsule-shaped status badge, two rows stop it being a badge, and a HUD that changes size during a
// recording is distracting.

import AppKit

@MainActor
final class LiveAnnotationBar: NSPanel, CaptureChrome {

    var onTool: ((LiveTool) -> Void)?
    var onColor: ((NSColor) -> Void)?
    var onWidth: ((CGFloat) -> Void)?

    private var toolButtons: [LiveTool: NSButton] = [:]
    private var swatches: [NSButton] = []
    private var widthButtons: [NSButton] = []

    /// Only the handful of colours people actually reach for. Picking a colour mid-recording is
    /// done against the live picture, and more options make that slower — the 16 on the capture
    /// toolbar are for a situation where you have time.
    private static let colors: [NSColor] = Array(AnnotationStyle.palette.prefix(5))
    private static let widths: [CGFloat] = [4, 6, 10]

    init(tool: LiveTool, color: NSColor, width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
                level = .screenSaver          // same layer as the HUD, so it does not end up underneath
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        appearance = BarStyle.appearance

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = BarStyle.cornerRadius
        bg.layer?.masksToBounds = true
        bg.maskImage = BarStyle.roundedMask(radius: BarStyle.cornerRadius)
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = BarStyle.border.cgColor
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = BarStyle.surface.cgColor
        scrim.layer?.cornerRadius = BarStyle.cornerRadius
        scrim.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(scrim)

        let tools = NSStackView()
        tools.spacing = 2
        for t in [LiveTool.arrow, .ellipse, .marker] {
            let b = NSButton()
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            b.title = ""
            b.imagePosition = .imageOnly
            b.toolTip = t.title
            b.target = self
            b.action = #selector(toolTapped(_:))
            b.tag = t.rawValue
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            toolButtons[t] = b
            tools.addArrangedSubview(b)
        }

        let colorRow = NSStackView()
        colorRow.spacing = 2
        for (i, c) in Self.colors.enumerated() {
            let b = NSButton()
            BarStyle.styleSwatch(b, color: c, selected: false)
            b.target = self; b.action = #selector(colorTapped(_:)); b.tag = i
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: BarStyle.swatchSize).isActive = true
            b.heightAnchor.constraint(equalToConstant: BarStyle.swatchSize).isActive = true
            swatches.append(b)
            colorRow.addArrangedSubview(b)
        }

        let widthRow = NSStackView()
        widthRow.spacing = 2
        for (i, w) in Self.widths.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(widthTapped(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.image = Self.dot(diameter: 3 + w * 0.7)
            b.imagePosition = .imageOnly
            b.contentTintColor = BarStyle.fg()
            b.tag = i
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            widthButtons.append(b)
            widthRow.addArrangedSubview(b)
        }

        let row = NSStackView(views: [tools, divider(), colorRow, divider(), widthRow])
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(row)
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: bg.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        contentView = bg
        row.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: row.fittingSize.width + 24, height: 38))

        select(tool: tool); select(color: color); select(width: width)
    }

    override var canBecomeKey: Bool { false }

    /// Docked directly under the HUD and left-aligned with it — they are one group, so centring
    /// each separately would look wrong.
    func place(under hud: NSWindow) {
        setFrameOrigin(NSPoint(x: hud.frame.minX, y: hud.frame.minY - frame.height - 6))
        #if DEBUG
        let br = Geometry.cgRect(fromNS: frame)
                print("[livebar] window CG=\(Int(br.origin.x)),\(Int(br.origin.y)),\(Int(br.width)),\(Int(br.height))")
    #endif
    }

    private func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = BarStyle.fg(0.15).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    private static func dot(diameter d: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    private func select(tool: LiveTool) {
        for (t, b) in toolButtons {
            b.layer?.backgroundColor = t == tool ? BarStyle.selected.cgColor : nil
            b.contentTintColor = t == tool ? BarStyle.accent : BarStyle.fg()
        }
    }
    private func select(color: NSColor) {
        for (i, b) in swatches.enumerated() {
            BarStyle.styleSwatch(b, color: Self.colors[i], selected: Self.colors[i] == color)
        }
    }
    private func select(width: CGFloat) {
        for (i, b) in widthButtons.enumerated() {
            b.layer?.backgroundColor = Self.widths[i] == width ? BarStyle.selected.cgColor : nil
        }
    }

    @objc private func toolTapped(_ s: NSButton) {
        guard let t = LiveTool(rawValue: s.tag) else { return }
        select(tool: t); onTool?(t)
    }
    @objc private func colorTapped(_ s: NSButton) {
        let c = Self.colors[s.tag]; select(color: c); onColor?(c)
    }
    @objc private func widthTapped(_ s: NSButton) {
        let w = Self.widths[s.tag]; select(width: w); onWidth?(w)
    }
}
