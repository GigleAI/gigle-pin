// The hotkey recorder: click to start, press a combination to change it.
//
// Why this has to exist: `RegisterEventHotKey` **does not** fail when another app already holds the
// key (measured 2026-09-05: two processes registered the same key, both told it worked). So we have
// no way to know it was taken, and a user pressing F1 to nothing gets no explanation — the only way
// out is letting them pick a different key themselves.

import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyField: NSView {

    /// Width of the key field. **The two "fixed keys" rows use it too** — the two kinds of field sit
    /// one above the other, and a difference in width is obvious.
    static let boxWidth: CGFloat = 190
    private let action: HotkeyAction
    private var monitor: Any?
    private var recording = false { didSet { needsDisplay = true } }
    /// When this hotkey last actually fired — used for the "✓ it just worked" mark.
    private(set) var lastFired: Date?

    var onChange: ((Hotkey) -> Void)?

    init(action: HotkeyAction) {
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 26))
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        // 190 and not 150: the recording prompt has to fit "Esc cancels" alongside it. English runs
        // much longer than Chinese, and 150pt showed only "Press a combination…  E" — cutting off
        // precisely the one exit from recording mode (photographed 2026-09-06 07:18). The hotkeys
        // pane has width to spare, and widening is more dignified than shrinking the type.
        widthAnchor.constraint(equalToConstant: Self.boxWidth).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        toolTip = action == .record
            ? L("hotkey.recordTip", "Follows the capture key by default (double-tap it). Click and press a combo to give recording its own key.")
            : L("hotkey.clickToRecord", "Click, then press the combination you want")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func noteFired() { lastFired = Date(); needsDisplay = true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
        // Swallow keys while recording so they do not leak elsewhere
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
            guard let self, recording else { return e }
            if e.type == .keyDown { capture(e); return nil }
            return e
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func capture(_ e: NSEvent) {
        if e.keyCode == UInt16(kVK_Escape) { stopRecording(); return }
        var mods: UInt32 = 0
        if e.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if e.modifierFlags.contains(.shift) { mods |= UInt32(shiftKey) }
        if e.modifierFlags.contains(.option) { mods |= UInt32(optionKey) }
        if e.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        let hk = Hotkey(keyCode: UInt32(e.keyCode), modifiers: mods)
        stopRecording()
        onChange?(hk)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Appearance.colors
        let accent = c?.accent2 ?? NSColor.controlAccentColor
        let bg = recording ? accent.withAlphaComponent(0.18)
                           : (c?.well ?? NSColor.textBackgroundColor)
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        (recording ? accent : (c?.hairline ?? NSColor.separatorColor)).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        border.lineWidth = recording ? 2 : 1
        border.stroke()

        let hk = Preferences.shared.hotkey(for: action)
        // The "follows the capture key" row must not render blank or as Key65535 — the user has to
        // be able to see that recording is "double-tap F1", or they conclude the feature does not
        // exist (Tim asked exactly that on 2026-09-05).
        let text = recording ? L("hotkey.pressNow", "Press keys…  Esc cancels")
                             : (hk.isDerived
                                ? Lf("hotkey.doubleTap", "Double-tap %@",
                                     Preferences.shared.hotkey(for: .capture).display)
                                : hk.display)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12,
                                     weight: recording || hk.isDerived ? .regular : .medium),
            .foregroundColor: recording
                ? (c?.text.withAlphaComponent(0.55) ?? NSColor.secondaryLabelColor)
                : (hk.isDerived
                   ? (c?.text.withAlphaComponent(0.7) ?? NSColor.secondaryLabelColor)
                   : (c?.text ?? NSColor.labelColor)),
        ]
        // Fallback: if a future language runs longer still, shrink the type rather than cut the
        // sentence in half.
        var s = NSAttributedString(string: text, attributes: attrs)
        let room = bounds.width - 20
        if s.size().width > room {
            var shrink = attrs
            for pt in [11.0, 10.0] as [CGFloat] {
                shrink[.font] = NSFont.systemFont(ofSize: pt,
                                                  weight: recording || hk.isDerived ? .regular : .medium)
                s = NSAttributedString(string: text, attributes: shrink)
                if s.size().width <= room { break }
            }
        }
        let sz = s.size()
        s.draw(at: NSPoint(x: 10, y: bounds.midY - sz.height / 2))

        // The "it just worked" tick on the right — the only proof a user has that the key is ours
        if let lastFired, Date().timeIntervalSince(lastFired) < 6 {
            let ok = NSAttributedString(string: "✓", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: c?.good ?? NSColor.systemGreen,
            ])
            ok.draw(at: NSPoint(x: bounds.maxX - 20, y: bounds.midY - 8))
        }
    }
}
