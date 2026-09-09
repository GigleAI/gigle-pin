// The text tool's field: click to place it, ⏎ commits, Esc discards. Transparent and borderless,
// so it reads as typing directly onto the picture.

import AppKit

@MainActor
final class TextEntry: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    /// Start narrow and grow with the content rather than claiming the remaining width up front —
    /// that pushes the field off the picture almost immediately.
    private let maxWidth: CGFloat
    private static let startWidth: CGFloat = 150

    init(at origin: NSPoint, style: AnnotationStyle, maxWidth: CGFloat) {
        self.maxWidth = max(Self.startWidth, maxWidth)
        super.init(frame: NSRect(x: origin.x, y: origin.y, width: min(Self.startWidth, self.maxWidth), height: 10))
        isBordered = false
        drawsBackground = true
        backgroundColor = NSColor.black.withAlphaComponent(0.25)
        focusRingType = .none
        font = NSFont.systemFont(ofSize: AnnotationLayer.fontSize(for: style), weight: .semibold)
        textColor = style.color
        placeholderString = L("text.placeholder", "Type, ⏎ when done")
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        delegate = self
        fit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Width follows the text up to the space available, and only then wraps. Height follows.
    private func fit() {
        let top = frame.maxY
        let ideal = (cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 10_000)).width ?? 0) + 12
        let w = max(Self.startWidth, min(ideal, maxWidth))
        let h = max(cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: w, height: 10_000)).height ?? 24, 24)
        frame = NSRect(x: frame.minX, y: top - h, width: w, height: h)
    }

    func controlTextDidChange(_ obj: Notification) {
        fit()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?(stringValue); return true
        case #selector(NSResponder.cancelOperation(_:)):
            onCancel?(); return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                        textView.insertNewlineIgnoringFieldEditor(nil); return true   // ⌥⏎ inserts a line break
        default:
            return false
        }
    }
}
