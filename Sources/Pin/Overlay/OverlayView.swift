// The selection view. One per screen, carrying the whole interaction state machine:
//
//   detecting ──click──▶ selected ◀──release── dragging
//       │                 │  ▲                ▲
//       └──hold and drag ≥4pt────┘  └──drag a handle or the inside── adjusting
//                           │
//                           └── tool chosen ──▶ drawing (annotating inside the selection)
//
// "Guess first, and let them do it by hand when the guess is wrong": the window under the cursor is
// highlighted on arrival, a click accepts it, and a drag draws your own instead.
// A click and a drag are the same button, told apart by distance (4pt).

import AppKit

@MainActor
final class OverlayView: NSView {

    // MARK: State

    private enum Phase {
        case detecting
                case pendingDown(NSPoint)              // pressed, not yet a click or a drag
        case dragging(start: NSPoint)
        case selected
        case adjusting(Adjust)
        case drawing(AnnotationShape)
    }

    private enum Adjust {
        case move(offset: NSPoint)
                case handle(Int, anchor: NSRect)       // 0..7, see handlePoints
    }

    /// The screen this overlay covers. Known at construction; the frozen picture is not.
    let display: NSScreen
    /// The frozen screen, set by the window once the capture lands. The overlay is built **before**
    /// the capture finishes — that is what hides its construction behind the capture — so for a few
    /// dozen milliseconds it exists without one. Nothing is drawn until it arrives.
    var snapshot: DisplaySnapshot? { didSet { needsDisplay = true } }
    private let detector: WindowDetector
    private var phase: Phase = .detecting
    private var mouse: NSPoint = .zero
    private var dragCurrent: NSPoint = .zero
    private var candidate: SnapTarget?
    private var selection: NSRect?
    private let toolbar = SelectionToolbar()
    private var done = false

    private let annotations = AnnotationLayer()
    private var tool: AnnotationTool?
    private var style = AnnotationStyle.default
    private var textEntry: TextEntry?

    var mode: OverlayMode = .capture {
        didSet { toolbar.configure(mode: mode); refreshToolbar(); layoutToolbar(); needsDisplay = true }
    }
    var onOutcome: ((OverlayOutcome) -> Void)?
    var onSelectionBegan: (() -> Void)?

    private let accent = NSColor(srgbRed: 0.28, green: 0.62, blue: 1.0, alpha: 1)
    private static let clickThreshold: CGFloat = 4
    private static let handleHitRadius: CGFloat = 8

    // MARK: Lifecycle

    init(screen: NSScreen, detector: WindowDetector) {
        self.display = screen
        self.detector = detector
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        toolbar.configure(mode: mode)
        toolbar.isHidden = true
        toolbar.onAction = { [weak self] in self?.perform($0) }
        toolbar.onHover = { [weak self] tip in
            guard let self else { return }
            hoverHint = tip
            needsDisplay = true
        }
        toolbar.onStyle = { [weak self] newStyle in
            guard let self else { return }
            style = newStyle
            refreshToolbar()
                        layoutToolbar()          // showing or hiding the second row changes the height
            needsDisplay = true
        }
        addSubview(toolbar)
        refreshToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        syncMouse()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    /// Read the mouse position from the system once and refresh the candidate — for when the overlay
    /// window has just appeared, or the mouse has crossed in from another screen.
    func syncMouse() {
        guard let window else { return }
        mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        refreshCandidate()
        needsDisplay = true
    }

    func clearSelection() {
        commitTextEntry(cancel: true)
        selection = nil
        tool = nil
        phase = .detecting
        toolbar.isHidden = true
        needsDisplay = true
    }

    // MARK: Coordinates

    private var windowOrigin: NSPoint { window?.frame.origin ?? .zero }

    private func toGlobal(_ p: NSPoint) -> NSPoint { NSPoint(x: p.x + windowOrigin.x, y: p.y + windowOrigin.y) }
    private func toGlobal(_ r: NSRect) -> NSRect { r.offsetBy(dx: windowOrigin.x, dy: windowOrigin.y) }
    private func toLocal(_ r: NSRect) -> NSRect { r.offsetBy(dx: -windowOrigin.x, dy: -windowOrigin.y) }

    private func refreshCandidate() {
        guard Preferences.shared.autoDetectWindows else { candidate = nil; return }
        let point = toGlobal(mouse)
        // The window-level answer now — from the list read when the overlay opened, no IPC.
        let hit = detector.target(at: point)
        setCandidate(hit)
        // The control-level answer a few milliseconds later, from the app that owns that window,
        // applied only if the mouse is still where the question was asked. See `WindowDetector.refine`.
        guard let pid = hit?.pid else { return }
        detector.refine(at: point, app: pid) { [weak self] asked, target in
            guard let self, let target else { return }
            switch self.phase {
            case .detecting, .pendingDown: break
            default: return
            }
            let now = self.toGlobal(self.mouse)
            guard hypot(asked.x - now.x, asked.y - now.y) < 1 else { return }
            self.setCandidate(target)
            self.needsDisplay = true
        }
    }

    private func setCandidate(_ t: SnapTarget?) {
        #if DEBUG
        let before = candidate?.frame
        #endif
        if let t {
            let local = toLocal(t.frame).intersection(bounds)
            candidate = local.isEmpty ? nil : SnapTarget(frame: local, title: t.title, depth: t.depth)
        } else {
            candidate = nil
        }
        #if DEBUG
        // "Whatever window the mouse is over is the one framed" is the first sentence of the
        // description, but which region it actually snapped to cannot be told from a screenshot —
        // printing the global coordinates is what makes it checkable. Only on change, or it floods.
        if before != candidate?.frame, let c = candidate {
            let g = Geometry.cgRect(fromNS: toGlobal(c.frame))
                        print("[overlay] snapped \(Int(g.origin.x)),\(Int(g.origin.y)),\(Int(g.width)),\(Int(g.height)) depth=\(c.depth)")
        }
    #endif
    }

    private func clampToSelection(_ p: NSPoint) -> NSPoint {
        guard let s = selection else { return p }
        return NSPoint(x: max(s.minX, min(p.x, s.maxX)), y: max(s.minY, min(p.y, s.maxY)))
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        switch phase {
        case .detecting:
            refreshCandidate()
            NSCursor.crosshair.set()
        case .selected:
            updateCursorForSelected()
        default: break
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        #if DEBUG
        print("[overlay] mouseDown \(Int(p.x)),\(Int(p.y)) phase=\(phase) key=\(window?.isKeyWindow ?? false)")
        #endif
        commitTextEntry(cancel: false)
        switch phase {
        case .selected:
            guard let s = selection else { phase = .pendingDown(p); return }
            if let h = hitHandle(p, in: s) {
                phase = .adjusting(.handle(h, anchor: s))
                toolbar.isHidden = true
            } else if let tool {
                beginDrawing(tool, at: clampToSelection(p))
            } else if s.contains(p) {
                phase = .adjusting(.move(offset: NSPoint(x: p.x - s.minX, y: p.y - s.minY)))
                toolbar.isHidden = true
            } else {
                // Clicked outside the selection: drop it and start over — one click switches target
                // window.
                selection = nil
                refreshCandidate()
                phase = .pendingDown(p)
                toolbar.isHidden = true
            }
        default:
            phase = .pendingDown(p)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        switch phase {
        case .pendingDown(let start):
            if hypot(p.x - start.x, p.y - start.y) >= Self.clickThreshold {
                phase = .dragging(start: start)
                dragCurrent = p
                onSelectionBegan?()
            }
        case .dragging:
            dragCurrent = p
        case .adjusting(let a):
            apply(a, at: p)
        case .drawing(var shape):
            updateDrawing(&shape, at: clampToSelection(p))
            phase = .drawing(shape)
        default: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        lastMouseUpAt = Date()
        #if DEBUG
        print("[overlay] mouseUp \(Int(p.x)),\(Int(p.y)) phase=\(phase)")
        #endif
        switch phase {
        case .pendingDown:
            // No drag: accept the candidate window.
            if let c = candidate {
                onSelectionBegan?()
                select(c.frame)
            } else {
                phase = .detecting
            }
        case .dragging(let start):
            let r = Geometry.rect(from: start, to: p).intersection(bounds)
            if r.width >= 2, r.height >= 2 { select(r) } else { phase = .detecting }
        case .adjusting:
            phase = .selected
            layoutToolbar()
            toolbar.isHidden = false
        case .drawing(var shape):
            updateDrawing(&shape, at: clampToSelection(p))
            finishDrawing(shape)
        default: break
        }
        needsDisplay = true
    }

    private func select(_ r: NSRect) {
        selection = r.pixelAligned
        phase = .selected
        layoutToolbar()
        toolbar.isHidden = false
        updateCursorForSelected()
        #if DEBUG
                print("[overlay] selection \(Int(r.width))×\(Int(r.height)) @ \(Int(r.minX)),\(Int(r.minY))")
    #endif
    }

    private func apply(_ a: Adjust, at p: NSPoint) {
        guard let s = selection else { return }
        switch a {
        case .move(let off):
            var r = s
            r.origin = NSPoint(x: p.x - off.x, y: p.y - off.y)
            r.origin.x = max(bounds.minX, min(r.origin.x, bounds.maxX - r.width))
            r.origin.y = max(bounds.minY, min(r.origin.y, bounds.maxY - r.height))
            selection = r.pixelAligned
        case .handle(let i, let anchor):
            // 0 1 2 / 3 · 4 / 5 6 7, counted by row from the bottom-left.
            let col = i % 3 == 0 ? 0 : (i == 1 || i == 6 ? 1 : 2)
            let row = i < 3 ? 0 : (i < 5 ? 1 : 2)
            var minX = anchor.minX, maxX = anchor.maxX, minY = anchor.minY, maxY = anchor.maxY
            let q = NSPoint(x: max(bounds.minX, min(p.x, bounds.maxX)), y: max(bounds.minY, min(p.y, bounds.maxY)))
            if col == 0 { minX = q.x } else if col == 2 { maxX = q.x }
            if row == 0 { minY = q.y } else if row == 2 { maxY = q.y }
            selection = Geometry.rect(from: NSPoint(x: minX, y: minY), to: NSPoint(x: maxX, y: maxY)).pixelAligned
        }
    }

    private func hitHandle(_ p: NSPoint, in r: NSRect) -> Int? {
        for (i, h) in handlePoints(r).enumerated() where hypot(p.x - h.x, p.y - h.y) <= Self.handleHitRadius {
            return i
        }
        return nil
    }

    private func updateCursorForSelected() {
        guard let s = selection else { NSCursor.crosshair.set(); return }
        if toolbar.frame.contains(mouse) { NSCursor.arrow.set(); return }
        if let h = hitHandle(mouse, in: s) {
            switch h {
            case 1, 6: NSCursor.resizeUpDown.set()
            case 3, 4: NSCursor.resizeLeftRight.set()
            default:   NSCursor.crosshair.set()
            }
        } else if tool != nil {
            (tool == .text ? NSCursor.iBeam : NSCursor.crosshair).set()
        } else if s.contains(mouse) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    // MARK: Annotation

    private func setTool(_ t: AnnotationTool?) {
        commitTextEntry(cancel: false)
                tool = (tool == t) ? nil : t     // pressing the same tool again puts it down
        refreshToolbar()
                layoutToolbar()                  // expanding or collapsing the second row changes the height
        // What the overlay draws itself (the hint bar, the size readout) has to be redrawn too — every
        // other action remembered this and only here it was missed. The result: after picking up a
        // tool the hint bar still read "⏎ copy ⌘S save…" from before, while the toolbar had just grown
        // a row and covered that stale hint, leaving only its tail showing.
        needsDisplay = true
        updateCursorForSelected()
        #if DEBUG
                print("[overlay] tool \(tool.map { $0.title } ?? "none")")
    #endif
    }

    private func refreshToolbar() {
        toolbar.update(tool: tool, style: style, canUndo: annotations.canUndo, canRedo: annotations.canRedo)
    }

    private func beginDrawing(_ t: AnnotationTool, at p: NSPoint) {
        toolbar.isHidden = true
        switch t {
        case .eraser:
            if let hit = annotations.topmost(at: p) { annotations.remove(id: hit.id) }
            phase = .selected
            toolbar.isHidden = false
            refreshToolbar()
        case .text:
            phase = .selected
            toolbar.isHidden = false
            showTextEntry(at: p)
        case .number:
            let d = AnnotationLayer.numberDiameter(for: style)
            var s = AnnotationShape(tool: .number, style: style)
            s.rect = NSRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            s.number = annotations.nextNumber
            annotations.add(s)
            phase = .selected
            toolbar.isHidden = false
            refreshToolbar()
        case .pencil, .marker:
            var s = AnnotationShape(tool: t, style: style)
            s.points = [p]
            phase = .drawing(s)
        case .rect, .ellipse, .mosaic:
            var s = AnnotationShape(tool: t, style: style)
            s.a = p; s.b = p; s.rect = NSRect(origin: p, size: .zero)
            phase = .drawing(s)
        case .line, .arrow:
            var s = AnnotationShape(tool: t, style: style)
            s.a = p; s.b = p
            phase = .drawing(s)
        }
    }

    private func updateDrawing(_ s: inout AnnotationShape, at p: NSPoint) {
        switch s.tool {
        case .pencil, .marker:
            if let last = s.points.last, hypot(p.x - last.x, p.y - last.y) < 1.5 { return }
            s.points.append(p)
        case .rect, .ellipse, .mosaic:
            s.b = p
            s.rect = Geometry.rect(from: s.a, to: s.b)
        case .line, .arrow:
            s.b = p
        default: break
        }
    }

    private func finishDrawing(_ s: AnnotationShape) {
        phase = .selected
        toolbar.isHidden = false
        let big = s.bounds.width >= 3 || s.bounds.height >= 3 || s.points.count > 2
        if big { annotations.add(s) }
        refreshToolbar()
        #if DEBUG
                if big { print("[overlay] annotation \(s.tool.title) \(Int(s.bounds.width))×\(Int(s.bounds.height))") }
    #endif
    }

    private func showTextEntry(at p: NSPoint) {
        guard let s = selection else { return }
        let entry = TextEntry(at: p, style: style, maxWidth: max(60, s.maxX - p.x - 6))
        entry.onCommit = { [weak self] text in self?.commitTextEntry(cancel: false, text: text) }
        entry.onCancel = { [weak self] in self?.commitTextEntry(cancel: true) }
        addSubview(entry)
        textEntry = entry
        window?.makeFirstResponder(entry)
    }

    private func commitTextEntry(cancel: Bool, text: String? = nil) {
        guard let entry = textEntry else { return }
        let value = text ?? entry.stringValue
        let frame = entry.frame
        entry.removeFromSuperview()
        textEntry = nil
        window?.makeFirstResponder(self)
        if !cancel, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var shape = AnnotationShape(tool: .text, style: style)
            shape.text = value
            shape.rect = frame
            annotations.add(shape)
            refreshToolbar()
            #if DEBUG
                        print("[overlay] annotation text \(value)")
            #endif
        }
        needsDisplay = true
    }

    /// The pixels the mosaic works from: a view rect → that part of the screen.
    private func mosaicSource(_ r: NSRect) -> CGImage? {
        snapshot?.crop(toNS: toGlobal(r))
    }

    /// The selection and its annotations composited into one pixel image.
    private func composeResult(_ globalRect: NSRect) -> CGImage? {
        guard let snapshot, let base = snapshot.crop(toNS: globalRect), let s = selection else { return nil }
        guard !annotations.isEmpty else { return base }
        let scale = snapshot.pixelScale
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return base }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
        // View coordinates → pixel coordinates inside the selection: move to the selection's origin,
        // then scale up to pixels. Both have their origin bottom-left.
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -s.minX, y: -s.minY)
        annotations.render(in: ctx, mosaicSource: { [weak self] r in self?.mosaicSource(r) })
        return ctx.makeImage()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        #if DEBUG
        print("[overlay] keyDown code=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") mods=\(event.modifierFlags.rawValue)")
        #endif
        if isSyntheticCopyFromAnotherProcess(event) {
            #if DEBUG
                        print("[overlay] ignoring a synthetic ⌘C from another process (pid \(event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? 0))")
            #endif
            return
        }
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let opt = event.modifierFlags.contains(.option)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
                case 53: // Esc: put a tool down first; then fall back from a selection to detecting; a third
                 // press cancels the capture
            if tool != nil { setTool(nil) }
            else if selection != nil { clearSelection(); refreshCandidate() }
            else { cancel() }
        case 36, 76: // Return / Enter
            primaryAction()
        case 123, 124, 125, 126:
            nudge(keyCode: event.keyCode, step: shift ? 10 : 1, resize: opt)
        default:
            switch (chars, cmd, shift) {
            case ("z", true, false): annotations.undo(); refreshToolbar(); needsDisplay = true
            case ("z", true, true):  annotations.redo(); refreshToolbar(); needsDisplay = true
            case ("c", true, _):  perform(.copy)
            case ("s", true, _):  perform(.save)
            case ("a", true, _):  select(bounds)
            case (",", true, _):  perform(.settings)
            case ("c", false, _): copyColorUnderCursor()
            case ("p", false, _): perform(.pin)
            case ("r", false, _): perform(.record)
            case ("[", false, _): cycleWidth(-1)
            case ("]", false, _): cycleWidth(+1)
            case ("f", false, _): toggleFill()
            case ("\t", false, _): cycleColor()
            default:
                if selection != nil, !cmd, chars.count == 1, let d = Int(chars), let t = AnnotationTool(rawValue: d) {
                    setTool(t)
                } else {
                    super.keyDown(with: event)
                }
            }
        }
    }

    override func cancelOperation(_ sender: Any?) { cancel() }

    private func nudge(keyCode: UInt16, step: CGFloat, resize: Bool) {
        guard var r = selection else { return }
        let dx: CGFloat = keyCode == 123 ? -step : (keyCode == 124 ? step : 0)
        let dy: CGFloat = keyCode == 125 ? -step : (keyCode == 126 ? step : 0)
        // **Stop at the boundary; do not clip with `intersection`.**
        //
        // Clipping narrows a selection against the left edge of the screen by one point on every ←:
        // the outward column gets cut off. Ten presses is ten points narrower, and ten presses of →
        // does not grow it back — the frame looks fine on screen, and only the saved image shows what
        // is missing. Arrow keys exist for "the frame is two points off, nudge it back", and the user
        // assumes they move it without changing its size.
        let lim = bounds
        if resize {
            // ⌥ resizes: bigger or smaller, but never past the overlay's edge
            r.size.width = max(2, min(r.width + dx, lim.maxX - r.minX))
            r.size.height = max(2, min(r.height + dy, lim.maxY - r.minY))
        } else {
            r.origin.x = max(lim.minX, min(r.minX + dx, lim.maxX - r.width))
            r.origin.y = max(lim.minY, min(r.minY + dy, lim.maxY - r.height))
        }
        selection = r.pixelAligned
        layoutToolbar()
        needsDisplay = true
    }

    private func cycleColor() {
        let p = AnnotationStyle.palette
        let i = p.firstIndex { $0 == style.color } ?? 0
        style.color = p[(i + 1) % p.count]
        refreshToolbar()
    }

    private func cycleWidth(_ dir: Int) {
        let w = AnnotationStyle.widths
        let i = w.firstIndex(of: style.lineWidth) ?? 1
        style.lineWidth = w[max(0, min(w.count - 1, i + dir))]
        refreshToolbar()
    }

    /// Only the rectangle and the ellipse take a fill.
    private func toggleFill() {
        guard tool == .rect || tool == .ellipse else { return }
        style.filled.toggle()
        refreshToolbar()
    }

    private func copyColorUnderCursor() {
        guard let c = snapshot?.color(atNS: toGlobal(mouse)) else { return }
        let text = colorAsRGB ? c.rgbString : c.hexString
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        #if DEBUG
                print("[overlay] copied colour \(text)")
        #endif
        flashHint = Lf("hint.colorCopied", "Copied %@", text)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.flashHint = nil
            self?.needsDisplay = true
        }
    }
    private var flashHint: String?
    /// While the mouse rests on a toolbar button, the hint bar at the top shows that button's
    /// explanation.
    private var hoverHint: String?
    private var lastMouseUpAt: Date?
    /// Whether the loupe reads out RGB or hex, toggled with ⇧ (Snipaste's convention).
    private var colorAsRGB = false
    private var shiftWasDown = false

    override func flagsChanged(with event: NSEvent) {
        let down = event.modifierFlags.contains(.shift)
        if down, !shiftWasDown { colorAsRGB.toggle(); needsDisplay = true }
        shiftWasDown = down
        super.flagsChanged(with: event)
    }

    /// GigleMDD-Magpie, on the same machine, simulates a ⌘C and restores the clipboard when it sees a
    /// drag gesture but AX reports no selection (its Chromium fallback). That ⌘C landing on our
    /// overlay becomes "copy and close", and then gets restored — leaving the user with nothing. Three
    /// conditions together: ⌘C, from another process, and within 400ms of the mouse being released.
    /// A person cannot hit that.
    private func isSyntheticCopyFromAnotherProcess(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              event.charactersIgnoringModifiers?.lowercased() == "c",
              let up = lastMouseUpAt, Date().timeIntervalSince(up) < 0.4,
              let cg = event.cgEvent else { return false }
        let pid = cg.getIntegerValueField(.eventSourceUnixProcessID)
        return pid != 0 && pid != Int64(ProcessInfo.processInfo.processIdentifier)
    }

    // MARK: Actions

    private func primaryAction() {
        switch mode {
        case .capture: perform(.copy)
        case .record:  perform(.record)
        }
    }

    private func perform(_ action: SelectionToolbar.Action) {
        #if DEBUG
        print("[overlay] perform \(action)")
        #endif
        guard !done else { return }
        switch action {
        case .tool(let t): setTool(t); return
        case .undo: annotations.undo(); refreshToolbar(); needsDisplay = true; return
        case .redo: annotations.redo(); refreshToolbar(); needsDisplay = true; return
        case .cancel: cancel(); return
        case .settings:
            guard !done else { return }
            done = true
            onOutcome?(.openSettings)
            return
        default: break
        }
        commitTextEntry(cancel: false)
        // Return with no selection: treat the candidate window as the selection.
        if selection == nil, let c = candidate { select(c.frame) }
        guard let s = selection else { return }
        let globalRect = toGlobal(s)

        if action == .record {
            done = true
            onOutcome?(.record(rect: globalRect, screen: display))
            return
        }
        guard let img = composeResult(globalRect) else { return }
        let result = CaptureResult(image: img, screenRect: globalRect)
        done = true
        switch action {
        case .copy: onOutcome?(.copy(result))
        case .save: onOutcome?(.save(result))
        case .pin:  onOutcome?(.pin(result))
        default: break
        }
    }

    private func cancel() {
        guard !done else { return }
        done = true
        onOutcome?(.cancelled)
    }

    // MARK: Toolbar placement

    private func layoutToolbar() {
        guard let s = selection else { toolbar.isHidden = true; return }
        let size = toolbar.naturalSize
        let gap: CGFloat = 8
        var origin = NSPoint(x: s.maxX - size.width, y: s.minY - gap - size.height)
                if origin.y < bounds.minY + 4 {                       // no room below → above
            origin.y = s.maxY + gap
                        if origin.y + size.height > bounds.maxY - 4 {     // no room above either → inside,
                                                              // bottom-right
                origin.y = s.minY + gap
                origin.x = s.maxX - size.width - gap
            }
        }
        origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - size.width - 4))
        toolbar.frame = NSRect(origin: origin, size: size)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // The frozen screen is not drawn here. It sits in the window's backdrop layer underneath this
        // view, handed to the compositor once when the capture landed; this view paints only what
        // changes. It used to blit the full-resolution screenshot through Core Graphics on every mouse
        // move — twice, once under the dimming and once again inside the selection — which cost
        // ~34 ms for the first frame of each screen and a colour-space conversion of every pixel on
        // every frame after (measured 2026-09-11).
        guard let snapshot, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let isKey = window?.isKeyWindow ?? false
        let focus: NSRect?
        let showHandles: Bool
        // The window title shows only while **a window was detected automatically** — there it is
        // saying "clicking selects this window". Dragging your own frame or adjusting a selection has
        // nothing to do with a window, and carrying the last hovered title over is just confusing.
        let focusTitle: String?
        switch phase {
        case .detecting, .pendingDown:
            focus = isKey ? candidate?.frame : nil
            showHandles = false
            focusTitle = isKey ? candidate?.title : nil
        case .dragging(let start):
            focus = Geometry.rect(from: start, to: dragCurrent).intersection(bounds)
            showHandles = false
            focusTitle = nil
        case .selected, .adjusting, .drawing:
            focus = selection
            showHandles = true
            focusTitle = nil
        }

        // Dim everything except the focus. Punching the hole with an even-odd fill gives the same
        // picture as dimming the whole screen and painting the undimmed screenshot back inside it.
        let hole: NSRect? = focus.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let dim = NSBezierPath(rect: bounds)
        if let hole { dim.appendRect(hole) }
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        if let f = hole {
            // Annotations are drawn only inside the selection
            if showHandles {
                ctx.saveGState()
                ctx.clip(to: f)
                var inProgress: AnnotationShape?
                if case .drawing(let s) = phase { inProgress = s }
                annotations.render(in: ctx, extra: inProgress, mosaicSource: { [weak self] r in self?.mosaicSource(r) })
                ctx.restoreGState()
            }

            let border = NSBezierPath(rect: f.insetBy(dx: -1, dy: -1))
            border.lineWidth = showHandles ? 2 : 1.5
            (showHandles ? accent : accent.withAlphaComponent(0.9)).setStroke()
            border.stroke()

            if showHandles {
                for p in handlePoints(f) {
                    let r = NSRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)
                    let dot = NSBezierPath(ovalIn: r)
                    NSColor.white.setFill(); dot.fill()
                    accent.setStroke(); dot.lineWidth = 1.5; dot.stroke()
                }
            }
            drawSizeLabel(for: f, title: focusTitle)
        }

        // The loupe: always during detecting and dragging; and after selecting, with no tool in hand
        // and the mouse inside the selection (Snipaste's convention, handy for picking colours).
        if isKey {
            var magnify = false
            switch phase {
            case .detecting, .pendingDown, .dragging:
                drawCrosshair()
                magnify = true
            case .selected:
                magnify = tool == nil && (selection?.contains(mouse) ?? false) && !toolbar.frame.contains(mouse)
            default: break
            }
            if magnify, Preferences.shared.showMagnifier {
                Magnifier.draw(in: ctx, snapshot: snapshot, mouse: mouse, bounds: bounds,
                               windowOrigin: windowOrigin, accent: accent, rgb: colorAsRGB)
            }
            drawHint()
        }
    }

    private func drawCrosshair() {
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let p = NSBezierPath()
        p.lineWidth = 1
        p.move(to: NSPoint(x: bounds.minX, y: mouse.y + 0.5)); p.line(to: NSPoint(x: bounds.maxX, y: mouse.y + 0.5))
        p.move(to: NSPoint(x: mouse.x + 0.5, y: bounds.minY)); p.line(to: NSPoint(x: mouse.x + 0.5, y: bounds.maxY))
        p.stroke()
    }

    private func drawSizeLabel(for r: NSRect, title: String?) {
        var text = "\(Int(r.width)) × \(Int(r.height))"
        let scale = snapshot?.pixelScale ?? display.backingScaleFactor
        if scale != 1 { text += "  @\(Int(scale))x" }
        if let title = title.map(Self.shortTitle), !title.isEmpty {
            text = "\(title)   ·   \(text)"
        }
        var at = NSPoint(x: r.minX, y: r.maxY + 6)
        if at.y + 24 > bounds.maxY { at = NSPoint(x: r.minX, y: r.minY - 28) }
        if at.y < bounds.minY { at = NSPoint(x: r.minX + 6, y: r.maxY - 28) }
        drawPill(text, at: at, size: 11, weight: .medium)
    }

    private func drawHint() {
        let text: String
        if let flashHint {
            text = flashHint
        } else if let hoverHint {
            text = hoverHint
        } else if let tool {
            let fill = (tool == .rect || tool == .ellipse) ? L("hint.fill", "   F hollow/filled") : ""
            let how = (tool == .text || tool == .number) ? L("hint.click", "click inside the selection") : L("hint.drag", "drag inside the selection")
            text = Lf("hint.tool", "%@: %@   ·   Tab color   [ ] width%@   ⌘Z undo   ·   Esc puts the tool down", tool.title, how, fill)
        } else {
            switch (phase, mode) {
            case (.selected, .capture), (.adjusting, .capture), (.drawing, .capture):
                text = L("hint.selected", "⏎ copy   ⌘S save   P pin   R record   1-9 tools   arrows nudge   Esc reselect")
            case (.selected, .record), (.adjusting, .record), (.drawing, .record):
                text = L("hint.selectedRecord", "⏎ start recording   arrows nudge   Esc reselect")
            case (_, .record):
                text = L("hint.recordMode", "🔴 Record: click a window, or drag out a region   ·   Esc cancels")
            default:
                text = L("hint.detecting", "Click a window   ·   drag out a region   ·   C copies the color   ·   Esc cancels")
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
        let ts = NSAttributedString(string: text, attributes: attrs).size()
        let w = ts.width + 24, h = ts.height + 12

        // Where the hint goes depends on where the user's attention is (rule set by Tim, 2026-09-05):
        //   - before selecting: top centre. Following the mouse fights the loupe, which already
        //     follows it; two moving boxes is noise.
        //   - after selecting: attached to **the toolbar**. Directly below it when the toolbar is below
        //     the selection, above it when it flips, right edges aligned. By then the hand and the eye
        //     are both on the toolbar, so hover explanations and flashes like "copied" land there
        //     rather than making someone look up from a button at the bottom of the screen to text at
        //     the top.
        //   - toolbar not visible (dragging or adjusting): back to top centre.
        var origin = NSPoint(x: bounds.midX - w / 2, y: bounds.maxY - 64)
        if !toolbar.isHidden, let s = selection {
            let tf = toolbar.frame
            let toolbarBelow = tf.midY < s.midY
            origin = NSPoint(x: tf.maxX - w, y: toolbarBelow ? tf.minY - 6 - h : tf.maxY + 6)
                        if origin.y < bounds.minY + 4 { origin.y = tf.maxY + 6 }                 // no room below → flip up
                        if origin.y + h > bounds.maxY - 4 { origin.y = tf.minY - 6 - h }         // none above either → back down, clamped
            origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - w - 4))
            origin.y = max(bounds.minY + 4, min(origin.y, bounds.maxY - h - 4))
        }
        drawPill(text, at: origin, size: 13, weight: .medium)
    }

    /// Both the hint bar and the size readout go through here. **The colours come from the same place
    /// as the toolbar's** — this used to be hardcoded black-on-white, and after switching to Amber the
    /// toolbar was cream while the hint bar stayed pure black: two design languages in one picture
    /// (spotted on 2026-09-06 03:31 while producing store screenshots).
    private func drawPill(_ text: String, at origin: NSPoint, size: CGFloat, weight: NSFont.Weight) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: BarStyle.fg(0.92)]
        let str = NSAttributedString(string: text, attributes: attrs)
        let ts = str.size()
        let padX: CGFloat = 12, padY: CGFloat = 6
        let rect = NSRect(x: origin.x, y: origin.y, width: ts.width + padX * 2, height: ts.height + padY * 2)
        let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        BarStyle.surface.setFill()
        pill.fill()
        BarStyle.border.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        str.draw(at: NSPoint(x: rect.minX + padX, y: rect.minY + padY))
    }

    /// A window title can be long, can contain line breaks, and can be a document name or the person
    /// you are chatting with — none of which should linger in a screenshot. Flattened to one line and
    /// cut at 28 characters.
    private static func shortTitle(_ raw: String) -> String {
        let one = raw.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return one.count <= 28 ? one : String(one.prefix(27)) + "…"
    }

    private func handlePoints(_ s: NSRect) -> [NSPoint] {
        [
            NSPoint(x: s.minX, y: s.minY), NSPoint(x: s.midX, y: s.minY), NSPoint(x: s.maxX, y: s.minY),
            NSPoint(x: s.minX, y: s.midY), NSPoint(x: s.maxX, y: s.midY),
            NSPoint(x: s.minX, y: s.maxY), NSPoint(x: s.midX, y: s.maxY), NSPoint(x: s.maxX, y: s.maxY),
        ]
    }
}
