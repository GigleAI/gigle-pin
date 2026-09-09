// The annotation model, its rendering and the undo stack. Drawing on screen and compositing for
// export go through the same `render`, so what you see is what you get.
// Coordinates are all view coordinates (origin bottom-left, in points); the export applies a
// transform to move them to the selection's origin and scale them to pixels.

import AppKit

enum AnnotationTool: Int, CaseIterable {
    case rect = 1, ellipse, arrow, line, pencil, marker, mosaic, text, number
    case eraser = 0

    var symbol: String {
        switch self {
        case .rect:    "rectangle"
        case .ellipse: "circle"
        case .arrow:   "arrow.up.right"
        case .line:    "line.diagonal"
        case .pencil:  "pencil"
        case .marker:  "highlighter"
        case .mosaic:  "checkerboard.rectangle"
        // Not textformat or textbox — both of those symbols draw a **word**, and in a Chinese locale
        // the first one renders literally as 「格式」. text.cursor also follows the language, but it
        // draws **a single character**: A in English, 「字」 in Chinese, and both read as "this is the
        // text tool", so it stays (2026-09-06, cropping the review bar's third row was the first
        // time anyone saw what the Chinese version looked like).
        case .text:    "text.cursor"
        case .number:  "1.circle"
        case .eraser:  "eraser"
        }
    }

    var title: String {
        switch self {
        case .rect:    L("tool.rect", "Rectangle")
        case .ellipse: L("tool.ellipse", "Ellipse")
        case .arrow:   L("tool.arrow", "Arrow")
        case .line:    L("tool.line", "Line")
        case .pencil:  L("tool.pencil", "Pencil")
        case .marker:  L("tool.marker", "Highlighter")
        case .mosaic:  L("tool.mosaic", "Pixelate")
        case .text:    L("tool.text", "Text")
        case .number:  L("tool.number", "Step number")
        case .eraser:  L("tool.eraser", "Eraser")
        }
    }

    /// The number key for it.
    var key: String { rawValue == 0 ? "0" : String(rawValue) }

    /// How to use it — drag or click. A small difference, and an easy one to get wrong.
    var how: String {
        switch self {
        case .rect, .ellipse, .mosaic: L("how.drag", "drag inside the selection")
        case .arrow, .line:            L("how.line", "drag from start to end")
        case .pencil:                  L("how.pencil", "hold and draw freehand")
        case .marker:                  L("how.marker", "translucent broad nib, does not hide the text underneath")
        case .text:                    L("how.text", "click once for a text box, ⏎ to finish, ⌥⏎ for a new line")
        case .number:                  L("how.number", "click to drop one, numbering 1, 2, 3 as you go")
        case .eraser:                  L("how.eraser", "click an annotation to remove it")
        }
    }
}

struct AnnotationStyle {
    var color: NSColor
    var lineWidth: CGFloat
    /// Rectangle and ellipse: filled or hollow. Snipaste's second row has this switch too.
    var filled: Bool = false

    /// Two rows of eight. Dark on the first row, the same hues lightened on the second, matching
    /// Snipaste's arrangement. The first (red) is the default.
    static let palette: [NSColor] = [
        rgb(0xE03131), rgb(0x111111), rgb(0x495057), rgb(0x862E9C),
        rgb(0x1971C2), rgb(0x0CA678), rgb(0x2F9E44), rgb(0xF08C00),
        rgb(0xFF8787), rgb(0xFFFFFF), rgb(0xADB5BD), rgb(0xDA77F2),
        rgb(0x74C0FC), rgb(0x63E6BE), rgb(0x8CE99A), rgb(0xFFD43B),
    ]
    static let paletteColumns = 8
    static let widths: [CGFloat] = [2, 4, 7]
    static let `default` = AnnotationStyle(color: palette[0], lineWidth: widths[1])

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

struct AnnotationShape {
    let id = UUID()
    var tool: AnnotationTool
    var style: AnnotationStyle
    /// rect / ellipse / mosaic / text / number use `rect`; line / arrow use `a`→`b`; pencil / marker
    /// use `points`.
    var rect: NSRect = .zero
    var a: NSPoint = .zero
    var b: NSPoint = .zero
    var points: [NSPoint] = []
    var text: String = ""
    var number: Int = 0

    /// Used for eraser hit-testing and for dirty rects.
    var bounds: NSRect {
        switch tool {
        case .rect, .ellipse, .mosaic, .text, .number:
            return rect
        case .line, .arrow:
            return Geometry.rect(from: a, to: b)
        case .pencil, .marker:
            guard let f = points.first else { return NSRect.zero }
            return points.reduce(NSRect(origin: f, size: .zero)) { $0.union(NSRect(origin: $1, size: .zero)) }
        case .eraser:
            return NSRect.zero
        }
    }

    func hit(_ p: NSPoint, tolerance t: CGFloat) -> Bool {
        switch tool {
        case .rect, .ellipse, .mosaic, .text, .number:
                        return rect.insetBy(dx: -t, dy: -t).contains(p)   // hollow hits as a whole block too, so
                                                             // it is easy to hit
        case .line, .arrow:
            return Self.distance(p, toSegment: a, b) <= t + style.lineWidth
        case .pencil, .marker:
            guard points.count > 1 else { return false }
            for i in 1..<points.count where Self.distance(p, toSegment: points[i - 1], points[i]) <= t + style.lineWidth {
                return true
            }
            return false
        case .eraser:
            return false
        }
    }

    static func distance(_ p: NSPoint, toSegment a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}

/// Every annotation in one capture, with undo and redo.
@MainActor
final class AnnotationLayer {
    private(set) var shapes: [AnnotationShape] = []
    private var undone: [AnnotationShape] = []
    /// The next number for the step-number tool.
    private(set) var nextNumber = 1

    var isEmpty: Bool { shapes.isEmpty }
    var canUndo: Bool { !shapes.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    func add(_ s: AnnotationShape) {
        shapes.append(s)
        undone.removeAll()
        if s.tool == .number { nextNumber = s.number + 1 }
    }

    func remove(id: UUID) {
        guard let i = shapes.firstIndex(where: { $0.id == id }) else { return }
        let s = shapes.remove(at: i)
        undone.append(s)
    }

    func undo() {
        guard let s = shapes.popLast() else { return }
        undone.append(s)
        if s.tool == .number { nextNumber = max(1, nextNumber - 1) }
    }

    func redo() {
        guard let s = undone.popLast() else { return }
        shapes.append(s)
        if s.tool == .number { nextNumber = s.number + 1 }
    }

    func topmost(at p: NSPoint) -> AnnotationShape? {
        shapes.last { $0.hit(p, tolerance: 6) }
    }

    // MARK: - Rendering

    /// `mosaicSource` supplies the pixels the mosaic works from: given a rect in view coordinates,
    /// return the image of that area.
    func render(in ctx: CGContext, extra: AnnotationShape? = nil,
                mosaicSource: (NSRect) -> CGImage?) {
        for s in shapes { Self.draw(s, in: ctx, mosaicSource: mosaicSource) }
        if let extra { Self.draw(extra, in: ctx, mosaicSource: mosaicSource) }
    }

    static func draw(_ s: AnnotationShape, in ctx: CGContext, mosaicSource: (NSRect) -> CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let color = s.style.color.cgColor
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(s.style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch s.tool {
        case .rect:
            if s.style.filled { ctx.fill(s.rect) }
            else { ctx.stroke(s.rect.insetBy(dx: s.style.lineWidth / 2, dy: s.style.lineWidth / 2)) }
        case .ellipse:
            if s.style.filled { ctx.fillEllipse(in: s.rect) }
            else { ctx.strokeEllipse(in: s.rect.insetBy(dx: s.style.lineWidth / 2, dy: s.style.lineWidth / 2)) }
        case .line:
            ctx.move(to: s.a); ctx.addLine(to: s.b); ctx.strokePath()
        case .arrow:
            drawArrow(from: s.a, to: s.b, width: s.style.lineWidth, in: ctx)
        case .pencil:
            guard s.points.count > 1 else { break }
            ctx.move(to: s.points[0])
            for p in s.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .marker:
            guard s.points.count > 1 else { break }
            ctx.setStrokeColor(s.style.color.withAlphaComponent(0.4).cgColor)
            ctx.setLineWidth(s.style.lineWidth * 3.5)
            ctx.setLineCap(.square)
            ctx.setBlendMode(.multiply)
            ctx.move(to: s.points[0])
            for p in s.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
        case .mosaic:
            guard s.rect.width >= 2, s.rect.height >= 2, let img = mosaicSource(s.rect) else { break }
            // **Err coarse, never fine.** Block size = width × 6, so the default width of 4 gives 24
            // device pixels (12pt on Retina).
            //
            // It used to be × 3 (12 device pixels by default). Put three samples side by side and it
            // is obvious: at that setting the letterforms of a 26pt heading, "Three things in March",
            // survive, and a person can read it back from the outlines — a machine cannot (Vision
            // found 0 lines), but **a person can**, and mosaic exists to cover chat logs, keys and ID
            // numbers, so the stricter reading is the only one that counts.
            // At × 6 only word lengths remain; the letter shapes are gone.
            //
            // The floor went from 6 to 12 as well: even the finest setting needs today's default
            // strength. Anyone who wants finer can press `[`, but **the default has to stand on the
            // "covered" side** — the time the default is wrong is the time the user never finds out.
            // Samples are in the internal notes.
            let block = max(12, Int(s.style.lineWidth * 6))
            if let small = downsample(img, by: block) {
                ctx.interpolationQuality = .none
                ctx.draw(small, in: s.rect)
            }
        case .text:
            let font = NSFont.systemFont(ofSize: fontSize(for: s.style), weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: s.style.color,
                .strokeColor: s.style.color.contrastingText.withAlphaComponent(0.6), .strokeWidth: -2.5,
            ]
            withNSContext(ctx) {
                NSAttributedString(string: s.text, attributes: attrs).draw(in: s.rect)
            }
        case .number:
            let r = s.rect
            ctx.fillEllipse(in: r)
            let font = NSFont.systemFont(ofSize: r.height * 0.58, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: s.style.color.contrastingText]
            let str = NSAttributedString(string: "\(s.number)", attributes: attrs)
            let size = str.size()
            withNSContext(ctx) {
                str.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2))
            }
        case .eraser:
            break
        }
    }

    static func fontSize(for style: AnnotationStyle) -> CGFloat { 10 + style.lineWidth * 3 }
    static func numberDiameter(for style: AnnotationStyle) -> CGFloat { 16 + style.lineWidth * 3 }

    private static func drawArrow(from a: NSPoint, to b: NSPoint, width: CGFloat, in ctx: CGContext) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let headLen = max(12, width * 4)
        let headW = headLen * 0.55
        // Draw the line only to the base of the head, so no stub pokes out of the triangle
        let root = NSPoint(x: b.x - cos(angle) * headLen * 0.8, y: b.y - sin(angle) * headLen * 0.8)
        ctx.move(to: a); ctx.addLine(to: root); ctx.strokePath()
        let left = NSPoint(x: b.x - cos(angle) * headLen + sin(angle) * headW, y: b.y - sin(angle) * headLen - cos(angle) * headW)
        let right = NSPoint(x: b.x - cos(angle) * headLen - sin(angle) * headW, y: b.y - sin(angle) * headLen + cos(angle) * headW)
        ctx.move(to: b); ctx.addLine(to: left); ctx.addLine(to: right); ctx.closePath(); ctx.fillPath()
    }

    private static func downsample(_ img: CGImage, by block: Int) -> CGImage? {
        let w = max(1, img.width / block), h = max(1, img.height / block)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// NSAttributedString.draw needs a current NSGraphicsContext.
    private static func withNSContext(_ cg: CGContext, _ body: () -> Void) {
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        body()
        NSGraphicsContext.current = prev
    }
}
