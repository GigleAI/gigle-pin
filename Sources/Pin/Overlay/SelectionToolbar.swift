// The toolbar that sits beside the selection once it is made. Two rows:
//   first row:  annotation tools · undo/redo · cancel · pin/save/record/copy (copy on the far right,
//               matching Snipaste)
//   second row: line width · fill style · palette — shown only once a tool is selected
// Plain AppKit; the buttons fire closures and know nothing about the rest of the app.

import AppKit

@MainActor
final class SelectionToolbar: NSView {
    enum Action: Hashable {
        case tool(AnnotationTool)
        case undo, redo, settings
        case copy, save, pin, record, cancel

        var symbol: String {
            switch self {
            case .tool(let t): t.symbol
            case .undo:   "arrow.uturn.backward"
            case .redo:   "arrow.uturn.forward"
            case .settings: "gearshape"
            case .copy:   "doc.on.doc"
            case .save:   "square.and.arrow.down"
            case .pin:    "pin"
            case .record: "record.circle"
            case .cancel: "xmark"
            }
        }
        /// The sentence shown on the hint bar while hovering: what it does first, the key second.
        var tip: String {
            switch self {
            case .tool(let t): "\(t.title)：\(t.how)   ·   \(t.key)"
            case .undo:   L("bar.undo", "Undo the last annotation   ·   ⌘Z")
            case .redo:   L("bar.redo2", "Redo   ·   ⇧⌘Z")
            case .settings: L("bar.settings", "Settings: hotkeys, save location, recording quality   ·   ⌘,")
            case .copy:   L("bar.copy", "Copy to the clipboard, paste anywhere   ·   ⏎")
            // Do not hardcode the directory name — the sentence becomes a lie once the user changes
            // where captures are saved, and it once still carried the old product name
            // ("~/Pictures/Jay"). Whether "and copy it too" belongs there is decided by the setting;
            // saying it with the setting off makes the hint false, and this sentence is exactly what
            // the user reads to decide whether to press ⏎ again.
            case .save:   MainActor.assumeIsolated {
                let dir = readablePath(Preferences.shared.saveDirectory)
                return Preferences.shared.copyAfterCapture
                    ? Lf("bar.save", "Save a PNG to %@ and copy it too   ·   ⌘S", dir)
                    : Lf("bar.saveOnly", "Save a PNG to %@   ·   ⌘S", dir)
            }
            case .pin:    L("bar.pin", "Pin it on top of everything as a reference; zoom and drag it   ·   P")
            case .record: L("bar.record", "Switch to recording this region   ·   R")
            case .cancel: L("bar.cancel", "Discard this capture   ·   Esc")
            }
        }
    }

    var onAction: ((Action) -> Void)?
    var onStyle: ((AnnotationStyle) -> Void)?
    /// Reports the hovered button's explanation, which the overlay shows on the hint bar at the top —
    /// a tooltip takes a second to appear and is set in small type, neither of which suits a toolbar
    /// that gets scanned at a glance.
    var onHover: ((String?) -> Void)?
    private var hoveredTip: String?

    private let rows = NSStackView()
    private let mainRow = NSStackView()
    private let optionsRow = NSStackView()
    private var buttons: [Action: NSButton] = [:]
    private var actionsByButton: [ObjectIdentifier: Action] = [:]
    private var widthButtons: [NSButton] = []
    private var fillButtons: [NSButton] = []
    private var swatches: [NSButton] = []
    private var style = AnnotationStyle.default
    private var tool: AnnotationTool?

    private static let rowHeight: CGFloat = 36
    private static let optionsHeight: CGFloat = 40

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = BarStyle.surface.cgColor
        layer?.cornerRadius = BarStyle.cornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = BarStyle.fg(0.12).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        for (s, spacing) in [(mainRow, CGFloat(1)), (optionsRow, CGFloat(4))] {
            s.orientation = .horizontal
            s.spacing = spacing
            s.alignment = .centerY
            s.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        }
        rows.orientation = .vertical
        rows.spacing = 0
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(mainRow)
        rows.addArrangedSubview(optionsRow)
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        buildOptionsRow()
        optionsRow.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - First row

    func configure(mode: OverlayMode) {
        mainRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        let groups: [[Action]]
        switch mode {
        case .capture:
            groups = [
                AnnotationTool.allCases.map { .tool($0) },
                [.undo, .redo],
                [.settings],
                [.cancel],
                [.pin, .save, .record, .copy],
            ]
        case .record:
            groups = [[.record], [.settings], [.cancel]]
        }
        for (i, g) in groups.enumerated() {
            if i > 0 { mainRow.addArrangedSubview(separator(height: 18)) }
            for a in g {
                let b = button(for: a, size: 14)
                buttons[a] = b
                mainRow.addArrangedSubview(b)
            }
        }
        if mode == .record, let b = buttons[.record] {
            b.contentTintColor = .systemRed
            b.toolTip = L("bar.startRecord", "Start recording  ⏎")
        }
        layoutSubtreeIfNeeded()
    }

    // MARK: - Second row

    private func buildOptionsRow() {
        // Line width: three filled dots, small to large
        for (i, w) in AnnotationStyle.widths.enumerated() {
            let b = NSButton()
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.title = ""
            b.image = Self.dotImage(diameter: 4 + CGFloat(i) * 4)
            b.imagePosition = .imageOnly
            b.target = self
            b.action = #selector(pickWidth(_:))
            b.tag = i
            b.toolTip = Lf("bar.width", "Line width %d   ·   [ ] also switches", Int(w))
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            widthButtons.append(b)
            optionsRow.addArrangedSubview(b)
        }
        optionsRow.addArrangedSubview(separator(height: 18))

        // Fill style: hollow or solid
        for (i, sym) in ["square", "square.fill"].enumerated() {
            let b = NSButton()
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.image = NSImage(systemSymbolName: sym,
                              accessibilityDescription: i == 0 ? L("bar.hollow", "Hollow: outline only")
                                                               : L("bar.filled", "Filled: solid color"))?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            b.imagePosition = .imageOnly
            b.contentTintColor = BarStyle.fg()
            b.target = self
            b.action = #selector(pickFill(_:))
            b.tag = i
            b.toolTip = i == 0 ? L("bar.hollow", "Hollow: outline only") : L("bar.filled", "Filled: solid color")
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 26).isActive = true
            b.heightAnchor.constraint(equalToConstant: 26).isActive = true
            fillButtons.append(b)
            optionsRow.addArrangedSubview(b)
        }
        optionsRow.addArrangedSubview(separator(height: 18))

        // Palette: two rows of eight. An NSGridView inside an NSStackView gets stretched out of
        // shape, so this lays the swatches out itself.
        let palette = PaletteView()
        for (i, c) in AnnotationStyle.palette.enumerated() {
            let b = swatch(color: c, index: i)
            swatches.append(b)
            palette.addSubview(b)
        }
        palette.translatesAutoresizingMaskIntoConstraints = false
        palette.widthAnchor.constraint(equalToConstant: PaletteView.size.width).isActive = true
        palette.heightAnchor.constraint(equalToConstant: PaletteView.size.height).isActive = true
        optionsRow.addArrangedSubview(palette)
    }

    private func swatch(color: NSColor, index: Int) -> NSButton {
        let b = NSButton()
        BarStyle.styleSwatch(b, color: color, selected: false)
        b.target = self
        b.action = #selector(pickColor(_:))
        b.tag = index
        b.toolTip = Lf("bar.color", "Color %@   ·   Tab cycles", color.hexString)
        return b
    }

    /// A fixed-size palette container: two rows of eight, positioning its own subviews.
    final class PaletteView: NSView {
                static let cell: CGFloat = BarStyle.swatchSize   // 20pt cell, 13pt dot, the rest for the ring
        static let gap: CGFloat = 2
        static var size: NSSize {
            let cols = CGFloat(AnnotationStyle.paletteColumns)
            let rows: CGFloat = 2
            return NSSize(width: cols * cell + (cols - 1) * gap,
                          height: rows * cell + (rows - 1) * gap)
        }

        override func layout() {
            super.layout()
            let cols = AnnotationStyle.paletteColumns
            for (i, v) in subviews.enumerated() {
                let r = i / cols, c = i % cols
                v.frame = NSRect(x: CGFloat(c) * (Self.cell + Self.gap),
                                 // first row on top
                                 y: bounds.height - CGFloat(r + 1) * Self.cell - CGFloat(r) * Self.gap,
                                 width: Self.cell, height: Self.cell)
            }
        }
    }

    private static func dotImage(diameter: CGFloat) -> NSImage {
        let side: CGFloat = 18
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        BarStyle.fg().setFill()
        NSBezierPath(ovalIn: NSRect(x: (side - diameter) / 2, y: (side - diameter) / 2,
                                    width: diameter, height: diameter)).fill()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: - Keeping the state in sync

    /// Highlight the current tool, width, fill and colour; enable or disable undo/redo; show or hide
    /// the second row.
    func update(tool: AnnotationTool?, style: AnnotationStyle, canUndo: Bool, canRedo: Bool) {
        self.tool = tool
        self.style = style
        for t in AnnotationTool.allCases {
            guard let b = buttons[.tool(t)] else { continue }
            let on = t == tool
            b.layer?.backgroundColor = on ? BarStyle.fg(0.18).cgColor : nil
            b.contentTintColor = on ? style.color : BarStyle.fg()
        }
        buttons[.undo]?.isEnabled = canUndo
        buttons[.redo]?.isEnabled = canRedo
        buttons[.undo]?.alphaValue = canUndo ? 1 : 0.35
        buttons[.redo]?.alphaValue = canRedo ? 1 : 0.35

        let widthIdx = AnnotationStyle.widths.firstIndex(of: style.lineWidth) ?? 1
        for (i, b) in widthButtons.enumerated() {
            b.layer?.backgroundColor = i == widthIdx ? BarStyle.fg(0.18).cgColor : nil
        }
        // Only the rectangle and the ellipse take a fill
        let fillApplies = tool == .rect || tool == .ellipse
        for (i, b) in fillButtons.enumerated() {
            b.isEnabled = fillApplies
            b.alphaValue = fillApplies ? 1 : 0.3
            let on = fillApplies && (i == 1) == style.filled
            b.layer?.backgroundColor = on ? BarStyle.fg(0.18).cgColor : nil
        }
        for (i, b) in swatches.enumerated() {
            BarStyle.styleSwatch(b, color: AnnotationStyle.palette[i],
                                 selected: AnnotationStyle.palette[i] == style.color)
        }
        // The second row appears once a tool is in hand — without one it is just clutter
        let show = tool != nil
        if optionsRow.isHidden != !show {
            optionsRow.isHidden = !show
            layoutSubtreeIfNeeded()
        }
    }

    var naturalSize: NSSize {
        layoutSubtreeIfNeeded()
        let h = Self.rowHeight + (optionsRow.isHidden ? 0 : Self.optionsHeight)
        return NSSize(width: max(mainRow.fittingSize.width,
                                optionsRow.isHidden ? 0 : optionsRow.fittingSize.width), height: h)
    }

    // MARK: - Components

    private func button(for action: Action, size: CGFloat) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 5
        b.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.tip)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium))
        b.imagePosition = .imageOnly
        b.contentTintColor = BarStyle.fg()
        b.toolTip = action.tip
        b.target = self
        b.action = #selector(tapped(_:))
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        actionsByButton[ObjectIdentifier(b)] = action
        return b
    }

    private func separator(height: CGFloat) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = BarStyle.fg(0.15).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    @objc private func tapped(_ sender: NSButton) {
        guard let action = actionsByButton[ObjectIdentifier(sender)] else { return }
        onAction?(action)
    }

    @objc private func pickWidth(_ sender: NSButton) {
        style.lineWidth = AnnotationStyle.widths[sender.tag]
        onStyle?(style)
    }

    @objc private func pickFill(_ sender: NSButton) {
        style.filled = sender.tag == 1
        onStyle?(style)
    }

    @objc private func pickColor(_ sender: NSButton) {
        style.color = AnnotationStyle.palette[sender.tag]
        onStyle?(style)
    }

    // Mouse events on the toolbar must not leak through to the selection view underneath.
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.arrow.set()
        let p = convert(event.locationInWindow, from: nil)
        let tip = tipAt(p)
        if tip != hoveredTip { hoveredTip = tip; onHover?(tip) }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredTip != nil { hoveredTip = nil; onHover?(nil) }
    }

    /// Report the explanation for whichever button is under the cursor; widths, fills and swatches
    /// each have one too.
    private func tipAt(_ p: NSPoint) -> String? {
        for (b, a) in buttons.map({ ($0.value, $0.key) }) where b.superview != nil {
            if b.convert(b.bounds, to: self).contains(p) { return a.tip }
        }
        for (i, b) in widthButtons.enumerated() where b.convert(b.bounds, to: self).contains(p) {
            return Lf("bar.width", "Line width %d   ·   [ ] also switches", Int(AnnotationStyle.widths[i]))
        }
        for (i, b) in fillButtons.enumerated() where b.convert(b.bounds, to: self).contains(p) {
            return (i == 0 ? L("bar.hollow", "Hollow: outline only") : L("bar.filled", "Filled: solid color")) + L("bar.fillNote", "   ·   F toggles   ·   rectangle and ellipse only")
        }
        for (i, b) in swatches.enumerated() where b.convert(b.bounds, to: self).contains(p) {
            return Lf("bar.color", "Color %@   ·   Tab cycles", AnnotationStyle.palette[i].hexString)
        }
        return nil
    }
}
