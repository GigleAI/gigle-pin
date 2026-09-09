// The small "done, and here is where it went" bar.
//
// Why it exists: saving a capture used to say **nothing at all** — the overlay closed and the user
// had no idea whether it saved, or where (Tim, 2026-09-05: "after a capture, if I hit save, I have
// no idea where it saved to"). Silent success and silent failure are the same experience: either
// way you go digging in Finder.
//
// Two rules:
//   - **Say where it went**, as a path a person can read (`Pictures/Pin/…`), not a long absolute one.
//   - **One click gets you there.** Naming the place but leaving the walking to the user is half a
//     job.

import AppKit

@MainActor
final class Toast: NSPanel, CaptureChrome {

    private static var current: Toast?

    /// - Parameters:
    ///   - near: the region to sit beside (usually the one just captured), placed by the same rules
    ///     as the toolbar and the recording HUD.
    ///   - onClick: what a click does. Pass nil for a plain notice.
    static func show(_ text: String, detail: String? = nil,
                     near rect: NSRect, on screen: NSScreen,
                     actions: [(title: String, run: () -> Void)] = []) {
        current?.close()
        let t = Toast(text: text, detail: detail, actions: actions)
        t.setFrameOrigin(RecordingHUD.place(size: t.frame.size, near: rect, on: screen))
        t.orderFrontRegardless()
        current = t
        t.autoDismiss()
    }

    private var timer: Timer?
    private var runners: [() -> Void] = []

    private init(text: String, detail: String?, actions: [(title: String, run: () -> Void)]) {
        runners = actions.map(\.run)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        appearance = BarStyle.appearance
        ignoresMouseEvents = false

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = BarStyle.surface.cgColor
        bg.layer?.cornerRadius = BarStyle.cornerRadius
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = BarStyle.border.cgColor
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = BarStyle.fg()
        let stack = NSStackView(views: [title])
        if let detail {
            let d = NSTextField(labelWithString: detail)
            d.font = .systemFont(ofSize: 11)
            d.textColor = BarStyle.secondary
            d.lineBreakMode = .byTruncatingMiddle
            d.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(d)
        }
        // Actions go on the line below the text. **Do not make the whole bar clickable** — with two
        // actions, clicking anywhere doing the same thing is no choice at all; and the user should
        // be able to finish reading without clicking, which a fully clickable bar makes easy to
        // trigger by accident.
        if !actions.isEmpty {
            let row = NSStackView()
            row.spacing = 8
            for (i, a) in actions.enumerated() {
                let b = NSButton(title: a.title, target: self, action: #selector(actionTapped(_:)))
                b.bezelStyle = i == 0 ? .accessoryBarAction : .accessoryBar
                b.tag = i
                b.font = .systemFont(ofSize: 11)
                row.addArrangedSubview(b)
            }
            stack.addArrangedSubview(row)
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: bg.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
        ])
        contentView = bg
        bg.layoutSubtreeIfNeeded()
        let w = min(max(stack.fittingSize.width + 28, 220), 460)
        setContentSize(NSSize(width: w, height: stack.fittingSize.height + 20))
    }

    private func autoDismiss() {
        timer = Timer.scheduledTimer(withTimeInterval: runners.isEmpty ? 3.5 : 8, repeats: false) { _ in
            Task { @MainActor in Toast.dismiss() }
        }
    }

    static func dismiss() {
        current?.timer?.invalidate()
        current?.close()
        current = nil
    }

    @objc private func actionTapped(_ sender: NSButton) {
        let run = runners[safe: sender.tag]
        Toast.dismiss()
        run?()
    }

    /// Leave time to read and decide when there are action buttons; a plain notice has no reason to
    /// hold the screen.
    override var canBecomeKey: Bool { true }

}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
