// The hint bubble that appears **immediately** below a button.
//
// It replaces two things:
//   - The system tooltip: a second of hover before it shows, small type, and a style that does not
//     match our bars.
//   - A line of explanation along the bottom of a bar: once the bar is wide (the review bar grows
//     with the video) that line is nowhere near the mouse, and it appearing and disappearing makes
//     the whole bar jump in height (both points from Tim, 2026-09-05).
//
// The bubble follows whichever button is hovered, so it is close to either group, and it takes no
// height inside the bar, so the bar does not jump.

import AppKit

@MainActor
final class HintBubble: NSPanel, CaptureChrome {

    private static var current: HintBubble?
    private static var owner: ObjectIdentifier?

    static func show(_ text: String, under view: NSView) {
        if pinned { return }
        guard let win = view.window else { return }
        let id = ObjectIdentifier(view)
        if owner == id, let b = current, b.isVisible { b.set(text); return }
        hide()
        let b = HintBubble(text: text)
        b.appearance = BarStyle.appearance
        let r = win.convertToScreen(view.convert(view.bounds, to: nil))
        // Horizontally centred on the button, vertically against the bottom of **the whole bar** —
        // not the bottom of the button. With a button on the first or second row, "directly below
        // the button" lands on the row underneath: pick up a pen on the review bar and the hint
        // covers the palette that just appeared, which is exactly what you were about to click
        // (photographed 2026-09-06 03:00).
        let barRect = win.frame
        var origin = NSPoint(x: r.midX - b.frame.width / 2, y: barRect.minY - b.frame.height - 6)
        if let vis = win.screen?.visibleFrame {
            if origin.y < vis.minY { origin.y = barRect.maxY + 6 }
            origin.x = min(max(origin.x, vis.minX + 6), vis.maxX - b.frame.width - 6)
        }
        b.setFrameOrigin(origin)
        #if DEBUG
                print("[hint] \(pinned ? "pinned" : "bubble") \(text)")
        #endif
        b.orderFrontRegardless()
        win.addChildWindow(b, ordered: .above)
        current = b; owner = id
    }

    /// One-off feedback ("stroke added…") that clears itself after a few seconds. Shares its place
    /// with the hover bubble; whichever comes last wins.
    private static var flashTimer: Timer?
    static func flash(_ text: String, under view: NSView, seconds: TimeInterval = 3) {
        show(text, under: view)
                owner = nil   // owned by no button, so the next hover displaces it
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { hide() }
        }
    }

    /// A pinned bubble, for something that runs for seconds (making a GIF, picking key frames).
    /// **Hover cannot displace it** — while waiting, the hand always leaves the button, and leaving
    /// would wipe out the only sign of progress, which is back to "I pressed it and nothing
    /// happened".
    private static var pinned = false

    static func pin(_ text: String, under view: NSView) {
                pinned = false            // release first, or show would be blocked by the previous pin
        flashTimer?.invalidate(); flashTimer = nil
        show(text, under: view)
        owner = nil
        pinned = true
        #if DEBUG
                print("[hint] ↑ pinned; hover cannot displace it")
    #endif
    }

    /// Release and clear. Usually followed straight away by a `flash` with the result.
    static func unpin() { pinned = false; hide() }

    static func hide() {
        if pinned { return }
        flashTimer?.invalidate(); flashTimer = nil
        if let b = current { b.parent?.removeChildWindow(b); b.close() }
        current = nil; owner = nil
    }

    private let label = NSTextField(labelWithString: "")

    private init(text: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isReleasedWhenClosed = false
                ignoresMouseEvents = true     // the bubble must not intercept the mouse, or moving onto it
                                      // would count as leaving the button
        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = BarStyle.surface.withAlphaComponent(0.98).cgColor
        bg.layer?.cornerRadius = 7
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = BarStyle.border.cgColor
        label.font = .systemFont(ofSize: 11)
        label.textColor = BarStyle.fg(0.92)
        label.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -5),
        ])
        contentView = bg
        set(text)
    }

    private func set(_ text: String) {
        label.stringValue = text
        label.sizeToFit()
        setContentSize(NSSize(width: label.frame.width + 18, height: label.frame.height + 10))
    }

    override var canBecomeKey: Bool { false }
}
