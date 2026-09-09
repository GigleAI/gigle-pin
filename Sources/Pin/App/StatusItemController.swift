// The bird in the menu bar.

import AppKit

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let recordingBadge = RecordingBadgeView(frame: .zero)
    var onCapture: (() -> Void)?
    var onRecord: (() -> Void)?
    var onPinClipboard: (() -> Void)?
    var onToggleAllPins: (() -> Void)?
    var onRestorePins: (() -> Void)?
    var onCloseAllPins: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onLastRecording: (() -> Void)?
    var hasLastRecording: (() -> Bool)?
    var clickThroughCount: (() -> Int)?
    var onSettings: (() -> Void)?
    var onHotkeyCheck: (() -> Void)?
    var pinCount: () -> Int = { 0 }
    var pinsHidden: () -> Bool = { false }
    var isRecording: () -> Bool = { false }
    /// Whether the hotkey has fired successfully at least once — if it has not, the menu carries a
    /// way to get help.
    var hotkeyConfirmed: () -> Bool = { true }
    var onStopRecording: (() -> Void)?

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = item.button {
            // The Director's bird is **mirrored**: with two birds side by side in the menu bar there
            // is otherwise no telling them apart (Tim, 2026-09-06). Still a template image, so it
            // follows the menu bar's light and dark.
            let bird = NSImage(systemSymbolName: "bird", accessibilityDescription: PinRole.isDirector ? "Pin Director" : "Pin")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            button.image = PinRole.isDirector ? bird.map(Self.mirrored) : bird
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            // The red dot is overlaid separately, so the bird stays a template image and adapts to a
            // light or dark menu bar on its own.
            recordingBadge.translatesAutoresizingMaskIntoConstraints = false
            recordingBadge.isHidden = true
            recordingBadge.setAccessibilityElement(false)
            button.addSubview(recordingBadge)
            NSLayoutConstraint.activate([
                recordingBadge.widthAnchor.constraint(equalToConstant: 7),
                recordingBadge.heightAnchor.constraint(equalToConstant: 7),
                recordingBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                // 7pt, its bottom roughly level with the bird's tail (Tim, 2026-09-06: a touch
                // bigger, a touch lower)
                recordingBadge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -2),
            ])
            // Hardcoding "F3" becomes a lie the moment the user rebinds, so always read the actual
            // binding.
            // The key has to be a literal: scripts/i18n-scan.sh extracts it by reading the source, so
            // a key built from a conditional never reaches the .strings files at all. It used to be
            // one call with `isDirector ? … : …` in the key position, which meant the tooltip fell
            // back to the hardcoded literal in every language, Chinese included.
            let cap = Preferences.shared.hotkey(for: .capture).display
            let pin = Preferences.shared.hotkey(for: .pinClipboard).display
            button.toolTip = PinRole.isDirector
                ? Lf("menu.tooltipDirector", "Pin Director — %@ capture · %@ pin", cap, pin)
                : Lf("menu.tooltip", "Pin — %@ capture · %@ pin", cap, pin)
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    /// Keep the plain monochrome bird while recording and only overlay a status dot; the app icon
    /// does not change.
    ///
    /// When `paused`, the dot is drawn hollow — the same vocabulary as the dot on the recording HUD.
    /// With only on and off, pressing pause would leave a solid red dot in the menu bar, which says
    /// "still recording" and contradicts it.
    func setRecording(_ on: Bool, paused: Bool = false) {
        guard let button = item.button else { return }
        recordingBadge.isHidden = !on
        recordingBadge.paused = paused
        let cap = Preferences.shared.hotkey(for: .capture).display
        let pinKey = Preferences.shared.hotkey(for: .pinClipboard).display
        let idleTip = PinRole.isDirector
            ? Lf("menu.tooltipDirector", "Pin Director — %@ capture · %@ pin", cap, pinKey)
            : Lf("menu.tooltip", "Pin — %@ capture · %@ pin", cap, pinKey)
        let state = paused ? L("menu.recordingPaused", "Paused") : L("menu.recording", "Recording")
        button.toolTip = on ? "Pin — \(state)" : idleTip
        let me = PinRole.isDirector ? "Pin Director" : "Pin"
        button.setAccessibilityLabel(on ? "\(me) — \(state)" : me)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if isRecording() {
            // Stopping a recording uses the **capture key** (AppDelegate: pressing the capture key
            // again while recording stops it); there is no ⌘⇧R. The string hardcoded here named a
            // combination that does not exist, so a user following it would get no response at all —
            // while the comment above says to always read the actual binding.
            menu.addItem(make(L("menu.stopRecording", "Stop Recording"),
                              hint: Preferences.shared.hotkey(for: .capture).display,
                              #selector(stopRecording)))
            menu.addItem(.separator())
        }
        // For a user whose hotkey does nothing, this bird is the only thing they will click. Give
        // them the way out first.
        // The Director has no hotkeys, so neither this nor the key hints below are shown — showing
        // F1 would suggest F1 reaches it.
        if !hotkeyConfirmed() {
            let warn = make(L("menu.hotkeyTrouble", "⚠︎ Hotkey not working? Change it here"), hint: "", #selector(hotkeyCheck))
            warn.attributedTitle = NSAttributedString(
                string: L("menu.hotkeyTrouble", "⚠︎ Hotkey not working? Change it here"),
                attributes: [.font: NSFont.menuFont(ofSize: 0),
                             .foregroundColor: NSColor.systemOrange])
            menu.addItem(warn)
            menu.addItem(.separator())
        }
        menu.addItem(make(L("menu.capture", "Capture"), hint: key(.capture), #selector(capture)))
        menu.addItem(make(L("menu.record", "Record"), hint: recordHint(), #selector(record)))
        menu.addItem(.separator())
        menu.addItem(make(L("menu.pin", "Pin Clipboard"), hint: key(.pinClipboard), #selector(pinClipboard)))
        let n = pinCount()
        if n > 0 {
            menu.addItem(make(pinsHidden() ? Lf("menu.showAllPins", "Show All Pins (%d)", n) : Lf("menu.hideAllPins", "Hide All Pins (%d)", n), hint: key(.toggleAllPins), #selector(toggleAllPins)))
            // A click-through pin cannot be clicked or right-clicked, so this is the only way to get
            // them back. But show it only when there actually are click-through pins — a permanent
            // "make all pins clickable again" entry means nothing to anyone (Tim, 2026-09-05: "what
            // is this thing?").
            if let k = clickThroughCount?(), k > 0 {
                // The explanation goes in the hint (the grey text after the item), not the title —
                // a title has to be short enough to scan, and "why is this here at all" is the part
                // that needs explaining.
                menu.addItem(make(Lf("menu.restorePins", "Make Pins Clickable Again (%d)", k),
                                  hint: L("menu.restorePinsHint", "clicks pass through them right now"),
                                  #selector(restorePins)))
            }
            menu.addItem(make(L("menu.closeAllPins", "Close All Pins"), hint: "", #selector(closeAllPins)))
        }
        menu.addItem(.separator())
        // The way back once the review window is closed. A menu bar app has no Dock icon, so closing
        // the window removes every entrance — while the film is still sitting on disk.
        if hasLastRecording?() == true {
            menu.addItem(make(L("menu.lastRecording", "Last Recording…"), hint: "", #selector(lastRecording)))
        }
        menu.addItem(make(L("menu.openFolder", "Open Save Folder"), hint: "", #selector(openFolder)))
        menu.addItem(make(L("menu.hotkeyCheck", "Check Hotkey…"), hint: "", #selector(hotkeyCheck)))
        menu.addItem(make(L("menu.settings", "Settings…"), hint: "⌘,", #selector(settings)))
        menu.addItem(.separator())
        // **Which version is this?** A menu bar app has no Dock icon and no app menu of its own most
        // of the time, so there was nowhere at all to find out — the only way was Get Info in Finder
        // (Tim, 2026-09-07, after twice mistaking an old build for a new one). Disabled, at the
        // bottom, out of the way of anything anyone presses.
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let name = PinRole.isDirector ? "Gigle Pin Director" : "Gigle Pin"
        let stamp = NSMenuItem(title: "\(name) \(version) (\(build))", action: nil, keyEquivalent: "")
        stamp.isEnabled = false
        menu.addItem(stamp)
        menu.addItem(NSMenuItem(title: L("menu.quit", "Quit Pin"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func key(_ a: HotkeyAction) -> String { Preferences.shared.hotkey(for: a).display }

    /// Recording has no key of its own by default, so it shows as "F1 F1" (double-tap); once the
    /// user gives it one, that is what appears.
    private func recordHint() -> String {
        let hk = Preferences.shared.hotkey(for: .record)
        return hk.isDerived ? "\(key(.capture)) \(key(.capture))" : hk.display
    }

    /// Mirror an image left to right (for the Director's bird).
    private static func mirrored(_ img: NSImage) -> NSImage {
        let out = NSImage(size: img.size, flipped: false) { rect in
            let t = NSAffineTransform()
            t.translateX(by: rect.width, yBy: 0); t.scaleX(by: -1, yBy: 1); t.concat()
            img.draw(in: rect)
            return true
        }
        out.isTemplate = true
        return out
    }

    private func make(_ title: String, hint: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        if !hint.isEmpty {
            let s = NSMutableAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
            s.append(NSAttributedString(string: "    \(hint)", attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            it.attributedTitle = s
        }
        return it
    }

    @objc private func capture() { onCapture?() }
    @objc private func record() { onRecord?() }
    @objc private func pinClipboard() { onPinClipboard?() }
    @objc private func toggleAllPins() { onToggleAllPins?() }
    @objc private func restorePins() { onRestorePins?() }
    @objc private func closeAllPins() { onCloseAllPins?() }
    @objc private func openFolder() { onOpenFolder?() }
    @objc private func lastRecording() { onLastRecording?() }
    @objc private func settings() { onSettings?() }
    @objc private func hotkeyCheck() { onHotkeyCheck?() }
    @objc private func stopRecording() { onStopRecording?() }
}

/// The decorative status dot does not intercept clicks; the menu bar button still opens the menu.
@MainActor
private final class RecordingBadgeView: NSView {
    /// Drawn hollow while paused, matching the dot on the recording HUD.
    var paused = false { didSet { if paused != oldValue { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        if paused {
            // Hollow: only the red outline. At menu bar size a hollow circle is easier to tell apart
            // than a dimmed solid one.
            NSColor.systemRed.setStroke()
            circle.lineWidth = 2
            circle.stroke()
        } else {
            NSColor.systemRed.setFill()
            circle.fill()
            NSColor.controlBackgroundColor.setStroke()
            circle.lineWidth = 1
            circle.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
