// The click ripple during a recording: every mouse-down blooms a ring at that spot.
// Walking someone through a sequence of steps, the viewer can see where you actually clicked — the
// cursor alone is too small to show a press at all in a video.
//
// Like the annotation layer, this window must **not** be added to the recording's exclusion list,
// or it never reaches the video.

import AppKit

@MainActor
final class ClickRippleWindow: NSPanel {
    private let canvas = RippleCanvas()
    private var monitor: Any?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        // Must sit below .screenSaver: ScreenCaptureKit's display filter does not reach that high a
        // layer, so the ripple draws but never lands in the video (measured 2026-09-05: 0 frames).
        // .floating is already above the app being recorded. Raised one level for the same reason as
        // the annotation layer: activating a pin window brings it to the front of .floating, and a
        // ripple behind it is a ripple nobody sees (see the note in LiveAnnotation).
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
                ignoresMouseEvents = true      // always transparent to clicks — it only watches
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        animationBehavior = .none
        // ScreenCaptureKit has to be able to see these two layers; they belong in the video (the
        // recording frame and the HUD are the ones that get excluded).
        sharingType = .readOnly
        contentView = canvas
    }

    override var canBecomeKey: Bool { false }

    func begin() {
        orderFrontRegardless()
        canvas.startTicking()
        #if DEBUG
                print("[ripple] started, covering \(Int(frame.width))×\(Int(frame.height)) @ \(Int(frame.minX)),\(Int(frame.minY))")
        #endif
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let p = self.canvas.convert(self.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
                let inside = self.canvas.bounds.contains(p)
                #if DEBUG
                                print("[ripple] click screen \(Int(NSEvent.mouseLocation.x)),\(Int(NSEvent.mouseLocation.y)) → view \(Int(p.x)),\(Int(p.y)) inside=\(inside)")
                #endif
                if inside { self.canvas.ping(at: p) }
            }
        }
    }

    /// Draw a ripple at a point in **screen coordinates** (NS, origin bottom-left).
    ///
    /// For agents: tools like Codex post clicks straight into the target process rather than through
    /// the system event stream, so the global monitor above sees none of them — a hundred clicks,
    /// zero ripples in the video. So the agent reports the coordinates and Pin draws. Outside the
    /// recorded region nothing is drawn, same rule as a real click.
    @discardableResult
    func ripple(atScreen point: NSPoint) -> Bool {
        let p = canvas.convert(convertPoint(fromScreen: point), from: nil)
        let inside = canvas.bounds.contains(p)
        #if DEBUG
                print("[ripple] agent reported screen \(Int(point.x)),\(Int(point.y)) → view \(Int(p.x)),\(Int(p.y)) inside=\(inside)")
        #endif
        guard inside else { return false }
        canvas.ping(at: p)
        return true
    }

    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        canvas.stopTicking()
        orderOut(nil)
    }
}

@MainActor
private final class RippleCanvas: NSView {
    private struct Ping { let at: NSPoint; let born: Date }
    private var pings: [Ping] = []
    private var timer: Timer?
    private static let duration: TimeInterval = 0.6
    private static let maxRadius: CGFloat = 44

    override var isFlipped: Bool { false }

    func ping(at p: NSPoint) {
        pings.append(Ping(at: p, born: Date()))
        needsDisplay = true
    }

    func startTicking() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.pings.isEmpty else { return }
                let now = Date()
                self.pings.removeAll { now.timeIntervalSince($0.born) > Self.duration }
                self.needsDisplay = true
            }
        }
        timer.map { RunLoop.main.add($0, forMode: .common) }
    }
    func stopTicking() { timer?.invalidate(); timer = nil }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        for ping in pings {
            let t = min(1, now.timeIntervalSince(ping.born) / Self.duration)
            // Spread quickly while fading: ease-out
            let e = 1 - pow(1 - t, 3)
            let r = Self.maxRadius * CGFloat(e)
            let a = CGFloat(1 - t)
            let rect = NSRect(x: ping.at.x - r, y: ping.at.y - r, width: r * 2, height: r * 2)
            NSColor(srgbRed: 1, green: 0.82, blue: 0.15, alpha: 0.30 * a).setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor(srgbRed: 1, green: 0.72, blue: 0.15, alpha: 0.9 * a).setStroke()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = 3.5
            ring.stroke()
        }
    }
}
