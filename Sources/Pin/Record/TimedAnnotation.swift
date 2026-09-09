// Review annotations: strokes carry a time, and appear only while the video is at that point.
//
// Drawing during a recording and drawing during playback are different moments, and both belong:
//   during recording  the hand has to operate and draw at once, and a mistake is in the file —
//                      good for a live walkthrough you ship straight away
//   during playback    slow to 0.2× to line something up exactly, undo a bad stroke, nudge the
//                      timing repeatedly — good for a tutorial
//
// The export does not composite frames by hand: each stroke becomes a CALayer placed on the
// timeline with beginTime + duration, and AVVideoCompositionCoreAnimationTool burns it in. That is
// Apple's own path for subtitles and watermarks.

import AppKit
import AVFoundation

struct TimedStroke: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var style: AnnotationStyle
    /// When it appears in the video (seconds) and how long it lasts.
    var start: Double
    var duration: Double
    /// Normalized coordinates (0…1), independent of the video's resolution — the playback window and
    /// the export are different sizes.
    var rect: CGRect = .zero
    var a: CGPoint = .zero
    var b: CGPoint = .zero
    var points: [CGPoint] = []
    var text: String = ""
    var number: Int = 0

    var end: Double { start + duration }
    func visible(at t: Double) -> Bool { t >= start && t < end }

    /// Normalized coordinates → real ones at a given size.
    func denormalized(in size: CGSize) -> AnnotationShape {
        var s = AnnotationShape(tool: tool, style: style)
        func p(_ q: CGPoint) -> NSPoint { NSPoint(x: q.x * size.width, y: q.y * size.height) }
        s.rect = NSRect(x: rect.minX * size.width, y: rect.minY * size.height,
                        width: rect.width * size.width, height: rect.height * size.height)
        s.a = p(a); s.b = p(b); s.points = points.map(p)
        s.text = text; s.number = number
        // Line width has to scale too, or a stroke is invisibly thin on a 1600-wide export
        s.style.lineWidth = style.lineWidth * size.width / 800
        return s
    }
}

@MainActor
final class TimedAnnotationTrack {
    private(set) var strokes: [TimedStroke] = []
    private var undone: [TimedStroke] = []
    private(set) var nextNumber = 1

    var isEmpty: Bool { strokes.isEmpty }
    var canUndo: Bool { !strokes.isEmpty }
    var canRedo: Bool { !undone.isEmpty }

    func add(_ s: TimedStroke) {
        strokes.append(s)
        undone.removeAll()
        if s.tool == .number { nextNumber = s.number + 1 }
    }
    func undo() {
        guard let s = strokes.popLast() else { return }
        undone.append(s)
        if s.tool == .number { nextNumber = max(1, nextNumber - 1) }
    }
    func redo() {
        guard let s = undone.popLast() else { return }
        strokes.append(s)
        if s.tool == .number { nextNumber = s.number + 1 }
    }
    func remove(id: UUID) { strokes.removeAll { $0.id == id } }
    func clear() { strokes.removeAll(); undone.removeAll(); nextNumber = 1 }

    func visible(at t: Double) -> [TimedStroke] { strokes.filter { $0.visible(at: t) } }

    /// One stroke's bar, drawn on the scrubber so the spread of annotations is visible.
    var timeline: [(start: Double, end: Double, color: NSColor)] {
        strokes.map { ($0.start, $0.end, $0.style.color) }
    }
}

// MARK: - Export: burning the annotations into the video

@MainActor
enum AnnotationBurner {

    /// Burn `track` into `source` and write `output`. `progress` comes back on the main thread.
    static func burn(source: URL, track: [TimedStroke], to output: URL,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let asset = AVURLAsset(url: source)
        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            throw RecorderError.writerFailed(L("err.noVideoTrack", "The video has no video track"))
        }
        let size = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
        let renderSize = CGSize(width: abs(size.width), height: abs(size.height))

        let videoEnd = CMTimeGetSeconds(asset.duration)

        let comp = AVMutableVideoComposition(propertiesOf: asset)
        comp.renderSize = renderSize

        // Video layer plus annotation layer, with the parent handed to AVFoundation to render
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let overlay = CALayer()
        overlay.frame = CGRect(origin: .zero, size: renderSize)
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.addSublayer(videoLayer)
        parent.addSublayer(overlay)

        for stroke in track {
            let layer = strokeLayer(stroke, renderSize: renderSize)
            // Set the time on the animation only — **do not** also set layer.beginTime. CALayer's
            // beginTime shifts the layer's own time base, so an animation attached to it is
            // displaced twice. Measured: a second stroke at 1.6s landed at 3.2s, past the end of a
            // 3.07-second video, and vanished entirely.
            //
            // During export, CoreAnimation's timeline starts at AVCoreAnimationBeginTimeAtZero;
            // a literal 0 means "immediately" rather than "at second zero".
            layer.opacity = 0
            let show = CABasicAnimation(keyPath: "opacity")
            show.fromValue = 0; show.toValue = 1
            show.duration = 0.12
            show.beginTime = AVCoreAnimationBeginTimeAtZero + stroke.start
            show.fillMode = .forwards
            show.isRemovedOnCompletion = false
            let hide = CABasicAnimation(keyPath: "opacity")
            hide.fromValue = 1; hide.toValue = 0
            hide.duration = 0.25
            hide.beginTime = AVCoreAnimationBeginTimeAtZero + stroke.end
            hide.fillMode = .forwards
            hide.isRemovedOnCompletion = false
            layer.add(show, forKey: "in")
            layer.add(hide, forKey: "out")
            // Draw it on, rather than having it appear.
            let shape = stroke.denormalized(in: renderSize)
            if let vector = layer as? CAShapeLayer, let final = vector.path,
               let growFor = clampDraw(growDuration(shape, renderSize: renderSize),
                                       stroke: stroke, videoEnd: videoEnd) {
                // Pulled open from the corner it was dragged from — see `vectorLayer`.
                let seed = seedPath(shape)
                let grow = CABasicAnimation(keyPath: "path")
                grow.fromValue = seed; grow.toValue = final
                grow.duration = growFor
                grow.beginTime = AVCoreAnimationBeginTimeAtZero + stroke.start
                grow.timingFunction = CAMediaTimingFunction(name: .easeOut)
                grow.fillMode = .forwards
                grow.isRemovedOnCompletion = false
                vector.path = seed
                vector.add(grow, forKey: "grow")
            } else if let (mask, wanted) = drawOnMask(shape, renderSize: renderSize),
                      let drawFor = clampDraw(wanted, stroke: stroke, videoEnd: videoEnd) {
                layer.mask = mask
                let reveal = CABasicAnimation(keyPath: "strokeEnd")
                reveal.fromValue = 0; reveal.toValue = 1
                reveal.duration = drawFor
                reveal.beginTime = AVCoreAnimationBeginTimeAtZero + stroke.start
                reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
                reveal.fillMode = .forwards
                reveal.isRemovedOnCompletion = false
                mask.strokeEnd = 0
                mask.add(reveal, forKey: "draw")
            }
            overlay.addSublayer(layer)
        }

        comp.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer, in: parent)

        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecorderError.writerFailed(L("err.noExporter", "Could not create the export session"))
        }
        export.outputURL = output
        export.outputFileType = .mp4
        export.videoComposition = comp

        // AVAssetExportSession is not Sendable, so progress polling stays on the main actor.
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                progress?(Double(export.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        await export.export()
        ticker.cancel()
        if export.status != .completed {
            throw RecorderError.writerFailed(export.error?.localizedDescription ?? L("err.exportFailed", "Export failed"))
        }
    }

    /// One stroke, one CALayer. CALayer's origin is bottom-left, matching our annotation
    /// coordinates, so nothing is flipped.
    /// A mask that uncovers a stroke along the path it was drawn, and how long to take over it.
    ///
    /// **The bitmap is left exactly as it is.** Each stroke is rendered once by the same code the
    /// screen uses, and its appearance is checked pixel by pixel — rebuilding every tool's geometry
    /// as a `CAShapeLayer` to animate `strokeEnd` directly would put that at risk for an entrance
    /// animation. So the drawing stays a bitmap and a shape layer over it decides how much of it can
    /// be seen yet. Nothing is revealed where nothing was drawn, so the mask can be as generous as
    /// it needs to be.
    ///
    /// `nil` for everything without a trajectory to follow — text, a step number, pixelation, and
    /// filled shapes, where stroking the outline would never uncover the middle. Those keep the
    /// fade they already had.
    private static func drawOnMask(_ s: AnnotationShape, renderSize: CGSize) -> (CAShapeLayer, Double)? {
        let lw = s.style.lineWidth
        let path = CGMutablePath()
        var cover = lw                      // how wide the mask has to be to uncover the drawing
        switch s.tool {
        case .pencil, .marker:
            guard s.points.count > 1 else { return nil }
            path.move(to: s.points[0])
            for p in s.points.dropFirst() { path.addLine(to: p) }
            // The highlighter is stroked at 3.5× with square caps (see AnnotationLayer.draw).
            cover = s.tool == .marker ? lw * 3.5 : lw
        case .arrow, .line:
            path.move(to: s.a); path.addLine(to: s.b)
            if s.tool == .arrow {
                // The head is a filled triangle wider than the line: headLen = max(12, lw*4) and
                // half-width headLen*0.55, so the mask has to be at least the head's full width or
                // the point of the arrow stays hidden after the line has arrived.
                let headLen = max(12, lw * 4)
                cover = max(lw, headLen * 1.1)
            }
        case .ellipse where !s.style.filled:
            path.addEllipse(in: s.rect)
        case .rect where !s.style.filled:
            path.addRect(s.rect)
        default:
            return nil
        }

        let mask = CAShapeLayer()
        mask.frame = CGRect(origin: .zero, size: renderSize)
        mask.path = path
        mask.fillColor = nil
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = cover + 4          // a little slack so antialiased edges are not clipped
        mask.lineCap = .round
        mask.lineJoin = .round

        // **Constant speed, not constant duration.** A flick and a stroke across the whole frame
        // taking the same time is the tell that it is an animation rather than a hand — the long one
        // crawls and the short one snaps. Clamped at both ends so a tiny mark is still visible going
        // on, and a very long one does not outlast the point being made.
        let speed = renderSize.width * 2.2  // a full-width stroke takes a bit under half a second
        let drawFor = min(max(pathLength(path) / speed, 0.12), maxDraw)
        return (mask, Double(drawFor))
    }

    /// The same constant speed the drawn-on strokes use, measured along the drag rather than around
    /// the outline — the gesture is the diagonal, not the perimeter.
    private static func growDuration(_ s: AnnotationShape, renderSize: CGSize) -> Double {
        let diagonal = hypot(s.rect.width, s.rect.height)
        return Double(min(max(diagonal / (renderSize.width * 2.2), 0.12), maxDraw))
    }

    /// The longest a mark may take to arrive.
    ///
    /// The bubble shown while drawing says the mark "shows **from** 0:04.2 for 2.5 seconds", so the
    /// playhead is where it starts existing — which leaves the frame the user actually scrubbed to
    /// showing a mark that has not finished arriving. Short enough and that stops mattering: at a
    /// third of a second the mark is essentially there on the frame that was chosen, and the
    /// question of whether the playhead means the start or the end of the animation never has to be
    /// put to anyone (Tim asked whether it should be a control on the bar, 2026-09-07 — it should
    /// not; it would ask the user to decide something this small every single time).
    private static let maxDraw: CGFloat = 0.35

    /// Trim the arrival so it cannot outstay its welcome or run off the end of the clip.
    ///
    /// Three ways it could, none of which were guarded:
    ///  - **The mark's own life.** At the shortest setting, one second, a long stroke spent 0.7s
    ///    arriving and 0.3s at full size before fading — barely there at all. It now gets at most a
    ///    third of its life to arrive.
    ///  - **The end of the clip.** A mark added near the end grew past the last frame, so it was
    ///    never seen whole. It now gets at most half of whatever time is left.
    ///  - **Nothing left at all.** A mark on the final frames animates not at all rather than
    ///    flickering; it simply fades in as marks used to.
    private static func clampDraw(_ wanted: Double, stroke: TimedStroke, videoEnd: Double) -> Double? {
        let left = max(0, videoEnd - stroke.start)
        let capped = min(wanted, stroke.duration / 3, left / 2)
        return capped >= 0.06 ? capped : nil
    }

    private static func pathLength(_ path: CGPath) -> CGFloat {
        var total: CGFloat = 0, last: CGPoint?, first: CGPoint?
        path.applyWithBlock { e in
            let p = e.pointee
            switch p.type {
            case .moveToPoint:    last = p.points[0]; first = p.points[0]
            case .addLineToPoint:
                if let l = last { total += hypot(p.points[0].x - l.x, p.points[0].y - l.y) }
                last = p.points[0]
            case .addQuadCurveToPoint:
                if let l = last { total += hypot(p.points[1].x - l.x, p.points[1].y - l.y) }
                last = p.points[1]
            case .addCurveToPoint:
                if let l = last { total += hypot(p.points[2].x - l.x, p.points[2].y - l.y) }
                last = p.points[2]
            case .closeSubpath:
                if let l = last, let f = first { total += hypot(f.x - l.x, f.y - l.y) }
                last = first
            @unknown default: break
            }
        }
        return total
    }

    /// A hollow rectangle or ellipse as a real path, so it can **grow the way it was dragged**.
    ///
    /// These two cannot be animated by uncovering the finished drawing. Dragging one out shows a
    /// smaller *complete* shape at every moment, and those pixels are nowhere in the final bitmap —
    /// a mask can only ever reveal part of the final outline, which is a pen tracing a circle, not a
    /// circle being pulled open (Tim, 2026-09-07). So these are drawn as a `CAShapeLayer` and the
    /// path itself is animated, which also keeps the line the same weight throughout, exactly as it
    /// is under the cursor. Scaling a layer would have thinned it at the start.
    ///
    /// The geometry matches `AnnotationLayer.draw` exactly: inset by half the line width, round
    /// caps and joins.
    private static func vectorLayer(_ s: AnnotationShape, renderSize: CGSize) -> CAShapeLayer? {
        guard !s.style.filled, s.tool == .rect || s.tool == .ellipse else { return nil }
        let lw = s.style.lineWidth
        let box = s.rect.insetBy(dx: lw / 2, dy: lw / 2)
        guard box.width > 0, box.height > 0 else { return nil }
        let layer = CAShapeLayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)
        layer.path = s.tool == .rect ? CGPath(rect: box, transform: nil)
                                     : CGPath(ellipseIn: box, transform: nil)
        layer.fillColor = nil
        layer.strokeColor = s.style.color.cgColor
        layer.lineWidth = lw
        layer.lineCap = .round
        layer.lineJoin = .round
        return layer
    }

    /// Where the drag started, as a rectangle of almost no size — the shape at the instant the mouse
    /// went down. `a` is the anchor and `b` the corner that followed the cursor
    /// (`ReviewWindow.mouseDragged`), so growing from `a` reproduces the gesture rather than
    /// inventing a symmetrical one from the middle.
    private static func seedPath(_ s: AnnotationShape) -> CGPath {
        let corners = [CGPoint(x: s.rect.minX, y: s.rect.minY), CGPoint(x: s.rect.maxX, y: s.rect.minY),
                       CGPoint(x: s.rect.minX, y: s.rect.maxY), CGPoint(x: s.rect.maxX, y: s.rect.maxY)]
        // Fall back to the nearest corner when the anchor was never recorded, and to the centre when
        // the rectangle is degenerate — never to a point outside the shape, which would make it
        // sweep in from somewhere it was never drawn.
        let anchor = corners.min { hypot($0.x - s.a.x, $0.y - s.a.y) < hypot($1.x - s.a.x, $1.y - s.a.y) }
            ?? CGPoint(x: s.rect.midX, y: s.rect.midY)
        let seed = CGRect(x: anchor.x - 0.5, y: anchor.y - 0.5, width: 1, height: 1)
        return s.tool == .rect ? CGPath(rect: seed, transform: nil)
                               : CGPath(ellipseIn: seed, transform: nil)
    }

    private static func strokeLayer(_ s: TimedStroke, renderSize: CGSize) -> CALayer {
        let shape = s.denormalized(in: renderSize)
        if let vector = vectorLayer(shape, renderSize: renderSize) { return vector }
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: renderSize)
        layer.contentsScale = 1

        // Open the bitmap at 1× by hand. `NSImage(size:)` + lockFocus sizes the backing store by the
        // main screen's scale, which is 2× on Retina: a 1002×562 point recording already has a
        // renderSize of 2004×1124 pixels, and doubling again is 36 MB per stroke. A dozen strokes is
        // hundreds of megabytes, and these layers live until the export finishes.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(renderSize.width), pixelsHigh: Int(renderSize.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return layer
        }
        rep.size = renderSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        if let ctx = NSGraphicsContext.current?.cgContext {
            AnnotationLayer.draw(shape, in: ctx, mosaicSource: { _ in nil })
        }
        NSGraphicsContext.restoreGraphicsState()
        layer.contents = rep.cgImage
        return layer
    }
}
