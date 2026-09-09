// The pixel loupe that follows the cursor, with a colour and coordinate readout. Pure drawing, no
// state.

import AppKit

enum Magnifier {
        static let radiusPx = 7          // samples 15×15 pixels
        static let zoom: CGFloat = 8     // each pixel drawn 8pt across
    static var side: CGFloat { CGFloat(2 * radiusPx + 1) * zoom }   // 120pt

    /// Drawn in view coordinates. `mouse` is in view coordinates; `bounds` decides which way to
    /// dodge.
    static func draw(in ctx: CGContext, snapshot: DisplaySnapshot, mouse: NSPoint,
                     bounds: NSRect, windowOrigin: NSPoint, accent: NSColor, rgb: Bool = false) {
        let global = NSPoint(x: mouse.x + windowOrigin.x, y: mouse.y + windowOrigin.y)
        guard let square = snapshot.pixelSquare(centeredAtNS: global, radius: radiusPx) else { return }
        let color = snapshot.color(atNS: global)

        // Three lines of readout: colour / coordinates / hint. It used to be two, with the hint
        // pushed in from the right by a **hardcoded 74pt** — and the Chinese 「C 复制 · ⇧ 切换」 is
        // wider than that, so it sat on top of the colour value (photographed 2026-09-06 07:13).
        // Switching to an RGB readout ("255, 249, 246") is longer still and collides harder. A
        // hardcoded width does not survive a change of language or of format.
        let labelH: CGFloat = 56
        let boxW = side
        let boxH = side + labelH
        let gap: CGFloat = 18
        var origin = NSPoint(x: mouse.x + gap, y: mouse.y - gap - boxH)
        if origin.x + boxW > bounds.maxX { origin.x = mouse.x - gap - boxW }
        if origin.y < bounds.minY { origin.y = mouse.y + gap }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - boxW))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - boxH))
        let box = NSRect(origin: origin, size: NSSize(width: boxW, height: boxH))

        ctx.saveGState()
        defer { ctx.restoreGState() }

        // Frame and shadow
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 10, color: CGColor(gray: 0, alpha: 0.5))
        NSColor(white: 0.1, alpha: 0.96).setFill()
        path.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)

        // The pixels
        let pixRect = NSRect(x: box.minX, y: box.minY + labelH, width: side, height: side)
        ctx.saveGState()
        NSBezierPath(roundedRect: NSRect(x: pixRect.minX, y: pixRect.minY, width: side, height: side),
                     xRadius: 0, yRadius: 0).addClip()
        ctx.interpolationQuality = .none
        ctx.draw(square, in: pixRect)

        // Grid (very faint)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 1
        var t = pixRect.minX + zoom
        while t < pixRect.maxX {
            grid.move(to: NSPoint(x: t + 0.5, y: pixRect.minY)); grid.line(to: NSPoint(x: t + 0.5, y: pixRect.maxY))
            t += zoom
        }
        t = pixRect.minY + zoom
        while t < pixRect.maxY {
            grid.move(to: NSPoint(x: pixRect.minX, y: t + 0.5)); grid.line(to: NSPoint(x: pixRect.maxX, y: t + 0.5))
            t += zoom
        }
        grid.stroke()

        // Centre pixel highlight and crosshair
        let c = NSRect(x: pixRect.minX + CGFloat(radiusPx) * zoom, y: pixRect.minY + CGFloat(radiusPx) * zoom,
                       width: zoom, height: zoom)
        accent.setStroke()
        let cp = NSBezierPath(rect: c.insetBy(dx: 0.5, dy: 0.5)); cp.lineWidth = 1; cp.stroke()
        accent.withAlphaComponent(0.35).setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 1
        cross.move(to: NSPoint(x: c.midX, y: pixRect.minY)); cross.line(to: NSPoint(x: c.midX, y: c.minY))
        cross.move(to: NSPoint(x: c.midX, y: c.maxY)); cross.line(to: NSPoint(x: c.midX, y: pixRect.maxY))
        cross.move(to: NSPoint(x: pixRect.minX, y: c.midY)); cross.line(to: NSPoint(x: c.minX, y: c.midY))
        cross.move(to: NSPoint(x: c.maxX, y: c.midY)); cross.line(to: NSPoint(x: pixRect.maxX, y: c.midY))
        cross.stroke()
        ctx.restoreGState()

        // Readout: swatch and hex, coordinates on the second line
        let hex = color.map { rgb ? $0.rgbString : $0.hexString } ?? "—"
        let swatch = NSRect(x: box.minX + 8, y: box.minY + labelH - 18, width: 12, height: 12)
        (color ?? .clear).setFill()
        NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).fill()
        NSColor.white.withAlphaComponent(0.25).setStroke()
        NSBezierPath(roundedRect: swatch, xRadius: 2, yRadius: 2).stroke()

        let mono = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let white: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.white]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
        NSAttributedString(string: hex, attributes: white).draw(at: NSPoint(x: swatch.maxX + 6, y: box.minY + labelH - 20))

        let px = Int((global.x - snapshot.frame.minX).rounded(.down))
        let py = Int((snapshot.frame.maxY - global.y).rounded(.down))
        NSAttributedString(string: "\(px), \(py)", attributes: white).draw(at: NSPoint(x: box.minX + 8, y: box.minY + labelH - 37))

        // The hint gets a line of its own. Measure the width for real and step the size down if it
        // does not fit — the English "C copies · ⇧ switches" is 108pt at 10pt, 4pt wider than the
        // 104pt available, and a blunt "skip it if it does not fit" would hide the hint from every
        // English user.
        let text = L("magnifier.pick", "C copies · ⇧ switches")
        let room = box.width - 16
        for pt in [10.0, 9.0, 8.0] as [CGFloat] {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: pt),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.55)]
            let hint = NSAttributedString(string: text, attributes: attrs)
            if hint.size().width <= room || pt == 8.0 {
                hint.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4))
                break
            }
        }
    }
}
