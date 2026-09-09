// Drawing on screen while recording: hold ⌥ to draw, let go and the mouse is the app's again.
//
// The tension: the annotation layer has to receive the mouse in order to draw, and while it does,
// the app being recorded cannot be operated. The answer is "hold to draw" rather than a mode toggle —
// fingers up is operating, fingers down is drawing, so there is nothing to remember mid-demo and no
// break in the train of thought.
//
// Ink fades after a few seconds by default (the fleeting "look here"); ink drawn with ⌥⇧ stays
// (for when you point at something and talk about it for a while).

import AppKit

/// The three pens for annotating a recording. Fast, not precise — hence only three.
enum LiveTool: Int, CaseIterable {
        case marker = 1   // highlighter: a translucent broad stroke that does not hide the text
    case arrow  = 2
    case ellipse = 3

    var title: String {
        switch self {
        case .marker:  L("live.marker", "Highlighter")
        case .arrow:   L("live.arrow", "Arrow")
        case .ellipse: L("live.ellipse", "Circle")
        }
    }
    var symbol: String {
        switch self {
        case .marker:  "highlighter"
        case .arrow:   "arrow.up.right"
        case .ellipse: "circle"
        }
    }
}

/// One stroke. `bornAt` decides when it starts to fade.
private struct Stroke {
    var tool: LiveTool
    var color: NSColor
    var width: CGFloat
    var points: [NSPoint] = []
    var a: NSPoint = .zero
    var b: NSPoint = .zero
    /// Sticky ink does not fade.
    var sticky: Bool
    var bornAt: Date = Date()
    var finished = false

    /// 0…1, where 1 is fully opaque. A stroke still being drawn stays at 1.
    func alpha(now: Date, life: TimeInterval, fade: TimeInterval) -> CGFloat {
        guard finished, !sticky else { return 1 }
        let age = now.timeIntervalSince(bornAt)
        if age <= life { return 1 }
        let t = (age - life) / fade
        return t >= 1 ? 0 : CGFloat(1 - t)
    }

    var isDead: Bool { finished && !sticky && Date().timeIntervalSince(bornAt) > 30 }
}

@MainActor
final class LiveAnnotationWindow: NSPanel {

    /// How long a finished stroke waits before it starts to fade.
    var life: TimeInterval = 3
    /// How long the fade takes.
    var fade: TimeInterval = 0.6

    private let canvas = LiveCanvas()
    private var monitors: [Any] = []
    private var drawing = false
    /// True while ⌥ is held — the window takes the mouse then, and gives it straight back on release.
    private var armed = false {
        didSet {
            guard armed != oldValue else { return }
            ignoresMouseEvents = !armed
            canvas.armed = armed
            onArmedChange?(armed)
            if armed { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            #if DEBUG
                        print("[live] \(armed ? "took the mouse (⌥ held)" : "gave it back")")
            #endif
        }
    }
    /// Continuous drawing mode: pressing the pen on the HUD means ⌥ no longer has to be held.
    private(set) var persistentMode = false

    /// The default is the **arrow**, not the highlighter.
    ///
    /// The highlighter is designed for running along a line of text, which is a stylus or finger
/// movement; dragging a broad highlight with a mouse comes out shaky and ugly. And what people
/// actually want while recording is "point at this" and "circle that" rather than highlighting
/// (Tim, 2026-09-05: with a mouse, a circle or an arrow feels like the natural default).
/// The keys follow: ⌥1 arrow / ⌥2 ellipse / ⌥3 highlighter, most used first.
    var tool: LiveTool = .arrow { didSet { canvas.needsDisplay = true } }
    var color: NSColor = AnnotationStyle.palette[0]
    var width: CGFloat = 6

    /// Tell the HUD to update its button state when the mode changes.
    var onModeChange: ((Bool) -> Void)?
    /// Tell the red frame to change appearance when the mouse is taken or given back — the cue has to
/// be drawn on a layer that is **not recorded**.
    var onArmedChange: ((Bool) -> Void)?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Must be below .screenSaver: ScreenCaptureKit's display filter does not reach that high a
        // layer, so it draws but never lands in the video (measured 2026-09-05: 0 frames).
        //
        // But it must **not** share a level with pins either. A pin window is `.floating` and can
        // become key, and every `open pin://…` (which is how an agent calls) activates Pin, at which
        // point AppKit brings the key window to the front of its level — so the annotation layer ends
        // up under a pin, and what is drawn is neither visible nor recorded.
        // Confirmed 2026-09-06 16:2x by reading the stacking order out of CGWindowList: after one
        // `open`, the pin jumped from last to first. One level up is enough (still far below
        // .screenSaver, so SCK still captures it).
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
                ignoresMouseEvents = true          // transparent to clicks by default
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        // ScreenCaptureKit has to be able to see these two layers; they belong in the video (the
        // recording frame and the HUD are the ones that get excluded).
        sharingType = .readOnly
        contentView = canvas
        canvas.owner = self
    }

    override var canBecomeKey: Bool { armed }
    override var canBecomeMain: Bool { false }

    // MARK: - Lifecycle

    func begin() {
        orderFrontRegardless()
        canvas.startTicking()
        installMonitors()
    }

    func end() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        canvas.stopTicking()
        orderOut(nil)
    }

    func togglePersistent() {
        persistentMode.toggle()
        armed = persistentMode
        onModeChange?(persistentMode)
    }

    func undo() { canvas.undo() }
    func clear() { canvas.clear() }

    // MARK: - Global monitors
    //
    // A click-through window receives no events at all, so ⌥ going down and up, and the dragging while
    // it is held, all come from global monitors. That needs Accessibility; without it the only way in
    // is the pen button on the HUD.

    private func installMonitors() {
        // Modifiers: ⌥ down takes the mouse, ⌥ up gives it back
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            Task { @MainActor in self?.handleFlags(e) }
        }) { monitors.append(m) }
        // Use a local monitor while we are the key window, or the events never arrive
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] e in
            Task { @MainActor in self?.handleFlags(e) }
            return e
        }) { monitors.append(m) }

        // The mouse while ⌥ is held: a global monitor supplies what the window cannot receive
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] e in
            Task { @MainActor in self?.handleMouse(e) }
        }) { monitors.append(m) }

        // ⌥ + a digit switches tool, ⌥ + Z undoes
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            Task { @MainActor in self?.handleKey(e) }
        }) { monitors.append(m) }
    }

    private func handleFlags(_ e: NSEvent) {
        guard !persistentMode else { return }
        // Whatever the user chose, not always ⌥ — see `InkModifier`.
        let held = Preferences.shared.inkModifier.isHeld(e.modifierFlags)
        #if DEBUG
        if held != armed {
            print("[ink] armed=\(held) mod=\(Preferences.shared.inkModifier.display) flags=\(e.modifierFlags.rawValue)")
        }
        #endif
        if !held, drawing { finishStroke() }
        armed = held
    }

    private func handleKey(_ e: NSEvent) {
        guard Preferences.shared.inkModifier.isHeld(e.modifierFlags) else { return }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "1": tool = .arrow
        case "2": tool = .ellipse
        case "3": tool = .marker
        case "z": undo()
        case "c": clear()
        default: break
        }
    }

    private func handleMouse(_ e: NSEvent) {
        guard armed else { return }
        let p = canvas.convert(convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        switch e.type {
        case .leftMouseDown:  startStroke(at: p, sticky: e.modifierFlags.contains(.shift))
        case .leftMouseDragged: extendStroke(to: p)
        case .leftMouseUp:    finishStroke()
        default: break
        }
    }

    // MARK: - Strokes (the window-takes-the-mouse path; the global monitors above end up here too)

    /// Draw a stroke in **window coordinates**, without going through system mouse events.
    ///
    /// Two callers use it: tests (synthesised mouse events cannot reach this layer — see below), and
    /// **agents** — when something like Codex wants to circle this and point at that, Pin cannot see
    /// its cursor movements, so the agent says and Pin draws. With `sticky`, the stroke lasts the whole
    /// clip (the equivalent of drawing with ⌥⇧ held).
    ///
    /// Why tests go through here as well: taking the mouse works by turning the window's
    /// `ignoresMouseEvents` off, and there is no guarantee about when the window server re-decides who
    /// a press belongs to — with synthesised events the first press often still passes through to the
    /// app below, so nothing is drawn and nothing reports an error. A person holding ⌥ has their hand
    /// in motion throughout and never hits it.
    func stroke(from a: NSPoint, to b: NSPoint, tool: LiveTool? = nil, sticky: Bool = false) {
        let saved = self.tool
        if let tool { self.tool = tool }
        let p0 = canvas.convert(a, from: nil), p1 = canvas.convert(b, from: nil)
        startStroke(at: p0, sticky: sticky)
        extendStroke(to: NSPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2))
        extendStroke(to: p1)
        finishStroke()
        self.tool = saved
        #if DEBUG
                print("[live] test stroke \(Int(p0.x)),\(Int(p0.y)) → \(Int(p1.x)),\(Int(p1.y))")
    #endif
    }


    fileprivate func startStroke(at p: NSPoint, sticky: Bool) {
        canvas.begin(tool: tool, color: color, width: width, at: p, sticky: sticky)
        drawing = true
    }
    fileprivate func extendStroke(to p: NSPoint) {
        guard drawing else { return }
        canvas.extend(to: p)
    }
    fileprivate func finishStroke() {
        guard drawing else { return }
        drawing = false
        canvas.finish()
    }
}

/// The canvas: drawing and fading only, no interaction.
@MainActor
private final class LiveCanvas: NSView {
    weak var owner: LiveAnnotationWindow?
    var armed = false { didSet { needsDisplay = true } }
    private var strokes: [Stroke] = []
    private var timer: Timer?

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { armed }

    // Events arrive here directly while the window has the mouse
    override func mouseDown(with e: NSEvent) {
        owner?.startStroke(at: convert(e.locationInWindow, from: nil),
                           sticky: e.modifierFlags.contains(.shift))
    }
    override func mouseDragged(with e: NSEvent) {
        owner?.extendStroke(to: convert(e.locationInWindow, from: nil))
    }
    override func mouseUp(with e: NSEvent) { owner?.finishStroke() }

    func begin(tool: LiveTool, color: NSColor, width: CGFloat, at p: NSPoint, sticky: Bool) {
        var s = Stroke(tool: tool, color: color, width: width, sticky: sticky)
        s.a = p; s.b = p; s.points = [p]
        strokes.append(s)
        needsDisplay = true
    }

    func extend(to p: NSPoint) {
        guard var s = strokes.last else { return }
        s.b = p
        if s.tool == .marker, let last = s.points.last,
           hypot(p.x - last.x, p.y - last.y) >= 1.5 { s.points.append(p) }
                s.bornAt = Date()          // still drawing, so keep it alive
        strokes[strokes.count - 1] = s
        needsDisplay = true
    }

    func finish() {
        guard var s = strokes.last else { return }
        s.finished = true
        s.bornAt = Date()
        // Too small a dot: treat it as a slip and discard it
        let tiny = s.tool == .marker ? s.points.count < 3
                                     : hypot(s.b.x - s.a.x, s.b.y - s.a.y) < 8
        if tiny { strokes.removeLast() } else { strokes[strokes.count - 1] = s }
        needsDisplay = true
    }

    func undo() { if !strokes.isEmpty { strokes.removeLast(); needsDisplay = true } }
    func clear() { strokes.removeAll(); needsDisplay = true }

    /// Fading needs continuous redraws, so a lightweight timer runs — and idles when there is no ink.
    func startTicking() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.strokes.isEmpty else { return }
                self.strokes.removeAll { $0.isDead }
                self.needsDisplay = true
            }
        }
        timer.map { RunLoop.main.add($0, forMode: .common) }
    }
    func stopTicking() { timer?.invalidate(); timer = nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        let life = owner?.life ?? 3
        let fade = owner?.fade ?? 0.6

        for s in strokes {
            let a = s.alpha(now: now, life: life, fade: fade)
            guard a > 0.01 else { continue }
            ctx.saveGState()
            let c = s.color.withAlphaComponent(s.tool == .marker ? 0.42 * a : 0.95 * a)
            ctx.setStrokeColor(c.cgColor)
            ctx.setFillColor(c.cgColor)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            switch s.tool {
            case .marker:
                ctx.setLineWidth(s.width * 3)
                ctx.setBlendMode(.multiply)
                guard s.points.count > 1 else { break }
                ctx.move(to: s.points[0])
                for p in s.points.dropFirst() { ctx.addLine(to: p) }
                ctx.strokePath()
            case .arrow:
                ctx.setLineWidth(s.width)
                let ang = atan2(s.b.y - s.a.y, s.b.x - s.a.x)
                let head = max(16, s.width * 4)
                let root = NSPoint(x: s.b.x - cos(ang) * head * 0.8, y: s.b.y - sin(ang) * head * 0.8)
                ctx.move(to: s.a); ctx.addLine(to: root); ctx.strokePath()
                let hw = head * 0.55
                ctx.move(to: s.b)
                ctx.addLine(to: NSPoint(x: s.b.x - cos(ang) * head + sin(ang) * hw,
                                        y: s.b.y - sin(ang) * head - cos(ang) * hw))
                ctx.addLine(to: NSPoint(x: s.b.x - cos(ang) * head - sin(ang) * hw,
                                        y: s.b.y - sin(ang) * head + cos(ang) * hw))
                ctx.closePath(); ctx.fillPath()
            case .ellipse:
                ctx.setLineWidth(s.width)
                ctx.strokeEllipse(in: Geometry.rect(from: s.a, to: s.b))
            }
            ctx.restoreGState()
        }

                // The "drawing now" ring is **not drawn on this layer**.
    //
                // This layer goes into the video (it is how the ink gets into the film), so drawing the ring
    // here burns a cue meant only for the operator into the viewer's copy: every time ⌥ goes down,
    // the audience sees the whole picture flash inside an amber frame. The HUD, the red frame and
    // the annotation bar — all operator interface — are excluded from the recording, and only this
    // one leaked in, which is inconsistent.
    // The cue is drawn by the frame window instead (`RecordingFrameWindow.setArmed`), which is
    // already outside the recording.
    }
}
