// The first-run window.
//
// It exists for one specific failure: the capture key is held by another app and pressing it does
// nothing. Pin defaults to F1 — Snipaste's key — so for anyone with Snipaste installed that failure
// is close to certain. And `RegisterEventHotKey` **does not** fail on a conflict (measured
// 2026-09-05: two processes registered the same key and both were told it succeeded), so the code
// cannot detect it.
//
// The only reliable test is **having the user press it once**: a tick if it arrived, and an
// immediate way to rebind if it did not. It also settles the older problem with menu bar apps —
// that the user has no idea the software has an interface, or where the settings are.

import AppKit

@MainActor
/// The welcome window is ordinary interface too, so it follows light/dark and the palette — hence
/// `ThemedWindow`.
final class WelcomeWindow: NSWindow, ThemedWindow {

    private let statusDot = NSView()
    private let statusText = NSTextField(labelWithString: "")
    private let hotkeyField: HotkeyField
    private let doneButton = NSButton()
    private var confirmed = false

    static let shownKey = "welcomeShown"

    /// Opens **automatically** only while the hotkey has not been confirmed. Once it has, it stops
    /// interrupting — but the menu can bring it back at any time.
    static var shouldShow: Bool { !UserDefaults.standard.bool(forKey: shownKey) }

    /// Only ever one, reused by "Check Hotkey" in the menu.
    static var current: WelcomeWindow?

    static func show() {
        let w = current ?? WelcomeWindow()
        current = w
        w.reopen()
        Appearance.paint(w)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    #if DEBUG
    /// Test entry point: open the window and print its position in CG (top-left origin) coordinates
    /// so a script can capture it by region. It is an ordinary window, but like the settings window
    /// it has to be given time to come to the front.
    static func debugShow() {
        show()
        guard let w = current else { return }
        let r = Geometry.cgRect(fromNS: w.frame)
                print("[welcome] window CG=\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))")
    }
    #endif

    /// Reset the status light when reopened, so the user presses the key again to verify.
    func reopen() {
        confirmed = false
        statusDot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        statusText.stringValue = L("welcome.waiting", "Nothing yet — give it a press")
        statusText.textColor = .secondaryLabelColor
        hotkeyField.needsDisplay = true
        doneButton.title = L("welcome.later", "Later")
    }

    init() {
        hotkeyField = HotkeyField(action: .capture)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = L("welcome.title", "Pin is installed")
        isReleasedWhenClosed = false
        center()
        build()
    }

    /// The content column: the window's 480 less 26pt of padding on each side. The separator was
    /// already drawn to that width, but the wrapping body text had no width constraint — and
    /// NSStackView does not stretch its children under `.leading` alignment, so a wrapping label laid
    /// itself out at whatever width it computed, running all the way to the right edge: 26pt of
    /// margin on the left, 5pt on the right, and the buttons ending at 75pt. Three edges, three
    /// different answers (photographed 2026-09-06 03:04).
    private static let column: CGFloat = 428

    private func wrapping(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: size)
        f.textColor = color
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: Self.column).isActive = true
        return f
    }

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 22, left: 26, bottom: 22, right: 26)

        let h = NSTextField(labelWithString: L("welcome.headline", "Try the capture hotkey first"))
        h.font = .systemFont(ofSize: 17, weight: .semibold)
        root.addArrangedSubview(h)

        let capKey = Preferences.shared.hotkey(for: .capture).display
        let why = wrapping(Lf("welcome.why", "Press Fn+%@ now (on most external keyboards, just %@).\nThe screen dims and a crosshair appears if the key belongs to Pin — press Esc to close it and come back.", capKey, capKey), size: 12, color: .secondaryLabelColor)
        root.addArrangedSubview(why)

        // Status light: grey until the key arrives, then green
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 5
        statusDot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        statusText.stringValue = L("welcome.waiting", "Nothing yet — give it a press")
        statusText.font = .systemFont(ofSize: 12, weight: .medium)
        statusText.textColor = .secondaryLabelColor
        row.addArrangedSubview(statusDot)
        row.addArrangedSubview(statusText)
        root.addArrangedSubview(row)

        let sep = NSBox(); sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.widthAnchor.constraint(equalToConstant: Self.column).isActive = true
        root.addArrangedSubview(sep)

        // The conflict warning names names — Pin defaults to Snipaste's F1, so anyone with Snipaste
        // installed will most likely hit it on the first try, and a vague "something may have taken
        // it" is no help.
        let rival = HotkeyConflict.rivalRunning(for: Preferences.shared.hotkey(for: .capture))
        // This window does exactly one thing: confirm the hotkey is ours. So there is one sentence of
        // explanation — naming the rival if we found one, and otherwise just "no response? change the
        // key". Permissions are **not** covered here: at the moment one is needed, PermissionPrompt
        // explains before asking, and repeating it here is the same sentence twice (decided while
        // reviewing this on 2026-09-05).
        let conflict = wrapping(rival.map {
            Lf("welcome.conflictNamed2", "No response? %@ is running and also uses %@ — the key goes to whichever started first. Free it in %@, or click the box below to pick another.",
               $0, capKey, $0)
        } ?? L("welcome.conflict2", "No response? Click the box below and press a new combination."),
            size: 12, color: .secondaryLabelColor)
        root.addArrangedSubview(conflict)

        hotkeyField.onChange = { [weak self] hk in
            _ = HotkeyManager.current?.rebind(.capture, to: hk)
            self?.hotkeyField.needsDisplay = true
            self?.reset()
        }
        root.addArrangedSubview(labeledRow(L("welcome.captureKey", "Capture hotkey"), hotkeyField))

        let tail = wrapping(Lf("welcome.tail2",
            // No 🐦 here — that emoji is a different bird (pale blue) and does not match the
            // monochrome one in our menu bar; at 11pt in grey it also turns to mush, which reads as
            // less icon-like, not more. Words point more accurately.
            "Record = press %@ twice, pin = %@. Keys and other settings live under the bird in the menu bar; any permission Pin needs is explained the first time it comes up.\nWant an AI to record for you? Tell it: “I have Gigle Pin installed; use it to record ___. See https://gigle.ai/pin/skill/”. Settings → AI has the sentence to copy.",
            capKey, Preferences.shared.hotkey(for: .pinClipboard).display),
            size: 11, color: .tertiaryLabelColor)
        root.addArrangedSubview(tail)

        doneButton.title = L("welcome.later", "Later")
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(finish)
        doneButton.keyEquivalent = "\r"
        let btnRow = NSStackView()
        btnRow.orientation = .horizontal
        btnRow.alignment = .centerY
        // The buttons align with the right edge of the body text. A hardcoded 300pt spacer makes
        // that edge drift with the language — button widths differ between English and Chinese, so
        // the trailing space does too.
        let spacer = NSView()
        btnRow.addArrangedSubview(spacer)
        btnRow.addArrangedSubview(doneButton)
        btnRow.translatesAutoresizingMaskIntoConstraints = false
        btnRow.widthAnchor.constraint(equalToConstant: Self.column).isActive = true
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        root.addArrangedSubview(btnRow)

        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        contentView = container
    }

    private func labeledRow(_ t: String, _ v: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 12)
        row.addArrangedSubview(l)
        row.addArrangedSubview(v)
        return row
    }

    /// The hotkey genuinely arrived — the only reliable evidence that it belongs to us.
    func hotkeyWorked() {
        guard !confirmed else { return }
        confirmed = true
        statusDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        statusText.stringValue = L("welcome.ok", "Got it ✓  this key belongs to Pin")
        statusText.textColor = .systemGreen
        hotkeyField.noteFired()
        doneButton.title = L("welcome.done", "Start using it")
        doneButton.keyEquivalent = "\r"
    }

    private func reset() {
        confirmed = false
        statusDot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        statusText.stringValue = L("welcome.waitingNew", "Changed — try the new key")
        statusText.textColor = .secondaryLabelColor
        doneButton.title = L("welcome.later", "Later")
    }

    @objc private func finish() { close() }

    /// **However it gets closed, it counts as seen.**
    ///
    /// The window is `.closable`, so besides that button the user can hit the red dot or ⌘W. Only
    /// the button path used to write `welcomeShown`, so anyone who closed it with the red dot got it
    /// again on the next launch, and the one after, like something that will not go away. (A
    /// reviewer will almost certainly use the red dot.) Writing it in `close()` covers all three
    /// routes; "Check Hotkey" in the menu still reopens it.
    override func close() {
        UserDefaults.standard.set(true, forKey: Self.shownKey)
        super.close()
    }

    override var canBecomeKey: Bool { true }
}
