import AppKit

/// A button that reports when the mouse moves over it.
///
/// A tooltip takes a second to appear and is set in small type, neither of which suits a toolbar that
/// gets scanned at a glance; explanations all appear on the bar's bottom line, on hover.
@MainActor
final class HoverButton: NSButton {
    /// Setting a hint **clears the tooltip automatically**. Keeping both shows the same sentence twice —
    /// the hint line appears on hover, and the system tooltip adds an identical one a second later
    /// (photographed by Tim, 2026-09-05: why does the same text appear twice?).
    /// Toolbars always use the hint line: a tooltip is too slow and too small for somewhere scanned at
    /// a glance.
    var hint: String? { didSet { if hint != nil { toolTip = nil } } }
    var onHover: ((HoverButton, String?) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(self, hint) }
    override func mouseExited(with event: NSEvent) { onHover?(self, nil) }
}

