// The card that explains why a feature needs a permission.
//
// It replaces two approaches, both bad:
//
//   1. **Greying the button out.** The user sees a dead control with no reason given and nowhere to
//      click, and most people read that as "broken" or "not built yet" (Tim asked exactly that on
//      2026-09-05: 「为什么有两个按钮是灰的？功能还没做？」 — why are two buttons grey, is the
//      feature unfinished?).
//   2. **Going straight to the system prompt.** The system only says "Pin would like to access the
//      microphone", never what the feature is for. Being asked to hand over a permission without
//      knowing what it buys makes "Don't Allow" an entirely reasonable answer — and once denied,
//      turning it on later means hunting through System Settings.
//
// So the order here is: **the feature first, then why it needs this, and only then the buttons.**
// "Not now" is a first-class answer — declining is a legitimate choice, and the app should keep
// working without that one thing.

import AppKit

@MainActor
final class PermissionPrompt: NSPanel, CaptureChrome {

    private static var current: PermissionPrompt?

    /// - Parameters:
    ///   - anchor: what the card appears beside, usually the button just clicked.
    ///   - feature: what this feature is called, in the user's words rather than the permission's.
    ///   - why: one line on why the permission is needed, and **what happens without it**.
    ///   - onGrant: what "Open Settings" does (usually jump to System Settings or trigger the
    ///     system request).
    static func show(anchor: NSView, feature: String, why: String,
                     grantTitle: String, onGrant: @escaping () -> Void) {
        current?.close()
        #if DEBUG
        // A check cannot see a window; it can see this. Whether the card appeared at all is the
        // whole assertion for "we asked someone who had already said yes".
        print("[perm] card shown — \(feature)")
        #endif
        let p = PermissionPrompt(feature: feature, why: why, grantTitle: grantTitle, onGrant: onGrant)
        p.place(near: anchor)
        p.orderFrontRegardless()
        current = p
    }

    /// With no button to attach to (a hotkey press where the overlay never opened), appear by the
    /// mouse.
    static func show(atMouse feature: String, why: String,
                     grantTitle: String, onGrant: @escaping () -> Void) {
        current?.close()
        let p = PermissionPrompt(feature: feature, why: why, grantTitle: grantTitle, onGrant: onGrant)
        p.placeAtMouse()
        p.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        current = p
    }

    static func dismiss() { current?.close(); current = nil }

    #if DEBUG
    /// Test entry point: these three cards only appear when a permission is **missing**, and on a
    /// development machine all three are granted — without a hook nobody ever sees what they look
    /// like. The three bodies were once truncated to a single sentence by the scanner and nobody
    /// noticed, for exactly that reason.
    static func debugShow(_ which: String) {
        let (feature, why): (String, String)
        switch which {
        case "mic":
            feature = L("perm.micFeature", "Record narration")
            why = L("perm.micWhy2",
                    "Records your voice along with the screen, only while recording.\nThe screen and computer audio record fine without it.")
        case "draw":
            feature = L("perm.drawFeature", "Draw on screen while recording")
            why = Lf("perm.drawWhy2",
                    "Hold %@ to circle things and draw arrows over what you are recording, then let go and the mouse goes back to the app you are demonstrating.\nThat means watching keys and drags across the whole screen, which needs Accessibility.\nRecording works fine without it — you just lose this.\n(Ticked already and still not working? That grant belongs to an older build — restart Pin.)", Preferences.shared.inkModifier.display)
        default:
            feature = L("perm.screenFeature", "Capture and recording")
            why = L("perm.screenWhy",
                    "Pin has to read what is on screen before it can let you select, pin or record any of it.\nThat is the Screen Recording permission — every screenshot tool on macOS needs it, including for still shots; there is no lesser one.\nIt reads the screen only at the moment you press the hotkey.")
        }
        show(atMouse: feature, why: why, grantTitle: L("perm.openSettings", "Open Settings")) {}
        if let c = current {
            let r = Geometry.cgRect(fromNS: c.frame)
                        print("[perm] window CG=\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))")
        }
    }
    #endif

    private init(feature: String, why: String, grantTitle: String, onGrant: @escaping () -> Void) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
                level = .popUpMenu          // must sit above the recording HUD (a layer below .screenSaver)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        appearance = BarStyle.appearance

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = BarStyle.surface.cgColor
        bg.layer?.cornerRadius = BarStyle.cornerRadius
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = BarStyle.border.cgColor

        let title = NSTextField(labelWithString: feature)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = BarStyle.fg()

        let body = NSTextField(wrappingLabelWithString: why)
        body.font = .systemFont(ofSize: 11)
        body.textColor = BarStyle.secondary
        body.preferredMaxLayoutWidth = 268

        // "Not now" goes on the left and is not the default button, but it is just as visible —
        // declining a permission is a legitimate choice and should not be designed against.
        let later = NSButton(title: L("perm.later", "Not now"), target: self, action: #selector(dismissTapped))
        later.bezelStyle = .accessoryBar
        let grant = NSButton(title: grantTitle, target: self, action: #selector(grantTapped))
        grant.bezelStyle = .accessoryBarAction
        grant.keyEquivalent = "\r"
        self.onGrant = onGrant

        let buttons = NSStackView(views: [later, grant])
        buttons.spacing = 8
        let stack = NSStackView(views: [title, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: bg.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -12),
        ])
        contentView = bg
        stack.layoutSubtreeIfNeeded()
        setContentSize(NSSize(width: 300, height: stack.fittingSize.height + 24))
    }

    private var onGrant: (() -> Void)?

    @objc private func grantTapped() { onGrant?(); Self.dismiss() }
    @objc private func dismissTapped() { Self.dismiss() }

    /// Appear against the button: above it by preference, below if it does not fit, then clamped
    /// back on screen.
    private func place(near anchor: NSView) {
        guard let win = anchor.window, let screen = win.screen ?? NSScreen.main else { return }
        let inScreen = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        var origin = NSPoint(x: inScreen.midX - frame.width / 2, y: inScreen.maxY + 10)
        let vis = screen.visibleFrame
        if origin.y + frame.height > vis.maxY { origin.y = inScreen.minY - frame.height - 10 }
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - frame.width - 8)
        origin.y = max(origin.y, vis.minY + 8)
        setFrameOrigin(origin)
    }

    private func placeAtMouse() {
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(m) }) ?? NSScreen.main else { return }
        let vis = screen.visibleFrame
        var origin = NSPoint(x: m.x - frame.width / 2, y: m.y - frame.height - 16)
        if origin.y < vis.minY { origin.y = m.y + 16 }
        origin.x = min(max(origin.x, vis.minX + 8), vis.maxX - frame.width - 8)
        setFrameOrigin(origin)
    }

    override var canBecomeKey: Bool { true }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { Self.dismiss() } else { super.keyDown(with: e) }
    }
}
