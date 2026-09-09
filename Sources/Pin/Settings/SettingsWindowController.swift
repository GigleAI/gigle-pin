// The settings window. A toolbar at the top switches between five panes — thirty-odd controls in
// one column means scrolling for a while to find a single switch.
//
// The panes are divided by "one pane, one job" rather than "roughly grouped":
//   Hotkeys      where someone whose F1 does nothing goes first, so it has to stand alone and be easy
//                to find — hence first, and the default pane
//   Look         light/dark, palette and language: all three are "what it looks like"
//   Capture      where files go, plus the capture switches
//   Recording    the most options, and unreadable crowded in with anything else
//   Permissions  visited only when something is wrong, so it should not take up space otherwise
//
// "Save location" and "copy after capture" used to live in a "General" pane, which therefore covered
// appearance, language and file behaviour all at once — no arrangement of it looked anything but
// messy (Tim said so twice on 2026-09-05). Moving them into Capture made every pane fit on one
// screen, which in turn removed the need for group headings to force the sections apart.
//
// A top toolbar rather than a sidebar: at this number of settings a sidebar is too heavy (System
// Settings is the scale that earns one).

import AppKit
import IOKit.ps

@MainActor
/// The settings window follows light/dark and the palette, so it is marked `ThemedWindow`
/// (`Appearance.apply()` only paints windows that are).
final class SettingsWindow: NSWindow, ThemedWindow {}

final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    static let shared = SettingsWindowController()

    private let prefs = Preferences.shared
    private var dirLabel: NSTextField!
    private var hotkeyFields: [HotkeyAction: HotkeyField] = [:]
    private let hotkeyNote = NSTextField(wrappingLabelWithString: "")
    private let langNote = NSTextField(labelWithString: "")
    private var screenStatus: NSTextField!
    private var axStatus: NSTextField!
    private var micStatus: NSTextField!
    private var checkHandlers: [ObjectIdentifier: (Bool) -> Void] = [:]
    private var resetHandlers: [ObjectIdentifier: () -> Void] = [:]

    /// The order is the order of importance: Hotkeys first, and the default pane — it is where anyone
    /// whose key does nothing goes straight to, and the only setting that makes the whole app unusable
    /// if it is wrong. Look (language, appearance, save location) second.
    private enum Tab: String, CaseIterable {
        case hotkeys, look, capture, record, permissions, ai
        var title: String {
            switch self {
            case .hotkeys:     L("tab.hotkeys", "Hotkeys")
            case .look:        L("tab.look", "Look")
            case .capture:     L("tab.capture", "Capture")
            case .record:      L("tab.record", "Recording")
            case .permissions: L("tab.permissions", "Permissions")
            case .ai:          L("tab.ai", "AI")
            }
        }
        var symbol: String {
            switch self {
            case .hotkeys:     "keyboard"
            case .look:        "paintpalette"
            case .capture:     "camera.viewfinder"
            case .record:      "record.circle"
            case .permissions: "lock.shield"
            case .ai:          "sparkles"
            }
        }
        var itemID: NSToolbarItem.Identifier { .init("tab." + rawValue) }
    }

    /// Which build this is, at the bottom of every pane.
    ///
    /// The standard place on macOS is About, and `orderFrontStandardAboutPanel` now provides it —
    /// but Pin is an `LSUIElement`, so the app menu that holds About only exists while a review
    /// window happens to be open. Settings is always reachable, so the answer lives here too.
    /// Selectable, because the reason anyone reads a version number is to put it in a bug report.
    private lazy var versionFooter: NSView = {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = PinRole.isDirector ? "Gigle Pin Director" : "Gigle Pin"
        let label = NSTextField(labelWithString:
            "\(name) \(info["CFBundleShortVersionString"] as? String ?? "?") "
            + "(\(info["CFBundleVersion"] as? String ?? "?"))")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.isSelectable = true

        // No rule above it. A separator here would have to span the pane, and the first attempt
        // bound its width to the stack — which sizes to the label — so it came out a half-width
        // rule floating in the middle. The grey already separates this from the pane; a line would
        // only be more furniture.
        let box = NSStackView(views: [label])
        box.orientation = .vertical
        box.alignment = .centerX
        box.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 14, right: 0)
        return box
    }()

    private var loginPermRow: NSView?
    private var loginStatus: NSTextField!
    private var launchAtLoginBox: NSButton?
    private var launchAtLoginNote: NSTextField?
    private var panes: [Tab: NSView] = [:]
    private var current: Tab = .hotkeys

    private init() {
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        super.init(window: w)

        for t in Tab.allCases { panes[t] = buildPane(t) }

        let tb = NSToolbar(identifier: "settings")
        tb.delegate = self
        tb.displayMode = .iconAndLabel
        tb.allowsUserCustomization = false
        tb.selectedItemIdentifier = Tab.hotkeys.itemID
        w.toolbar = tb
        w.toolbarStyle = .preference
        show(.hotkeys)
        w.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        Appearance.apply()
        refreshPermissions()
        refreshHotkeys()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The hotkeys pane has to **re-check the current state** every time it opens.
    ///
    /// The panes are built once in `init` and reused, so whatever the last visit left behind is still
    /// there: "Changed. Press it to try" stays on screen and is still there next time; so does the red
    /// text from trying an illegal combination. And the ↺ buttons' enabled state was only updated when
    /// a key was rebound **in this window** — it knew nothing about a key changed from the welcome
    /// window or from "Check Hotkey" in the menu, so the button sat greyed out and unclickable while
    /// the value was no longer the default.
    ///
    /// The key fields look after themselves: they read `Preferences` in `draw`, so one redraw is
    /// enough.
    private func refreshHotkeys() {
        for (a, b) in resetButtons { b.isEnabled = prefs.hotkey(for: a) != a.defaultHotkey }
        for f in hotkeyFields.values { f.needsDisplay = true }
        let fn = Self.isLaptop
            ? Lf("hotkey.noteFn", " (on a MacBook, press Fn+%@)", prefs.hotkey(for: .capture).display) : ""
        hotkeyNote.stringValue = Lf("hotkey.note3", "Click a box and press a new key. A ✓ after pressing the hotkey means Pin received it.%@", fn)
        hotkeyNote.textColor = .secondaryLabelColor
    }

    #if DEBUG
    /// Test entry point: switch to a given pane and print the window's position in CG (top-left
    /// origin) coordinates, so a script can capture it precisely by region — the settings window is a
    /// material window, and capturing it by window ID produces a white slab.
    func debugShow(tab name: String?) {
        show()
        if let name, let t = Tab(rawValue: name) { show(t) }
        guard let w = window else { return }
        let r = Geometry.cgRect(fromNS: w.frame)
                print("[settings] pane=\(current.rawValue) window CG=\(Int(r.origin.x)),\(Int(r.origin.y)),\(Int(r.width)),\(Int(r.height))")
    }
    #endif

    /// Tick the matching field when a hotkey genuinely fires — the only proof a user has that the key
    /// is ours.
    func noteHotkeyFired(_ action: HotkeyAction) {
        hotkeyFields[action]?.noteFired()
    }

    // MARK: - Switching panes

    private func show(_ tab: Tab) {
        guard let window, let pane = panes[tab] else { return }
        current = tab
        window.title = tab.title
        // AppKit sets the selected item itself when the user clicks the toolbar, but not when the pane
        // is switched programmatically — without this line the highlight stays on the previous pane and
        // stops matching the content.
        window.toolbar?.selectedItemIdentifier = tab.itemID
        // The pane goes inside a shell so the version line sits under **every** pane rather than
        // being a row in one of them — a row would break "one pane, one job", and whichever pane got
        // it would be the wrong one for whoever was looking.
        let shell = NSStackView(views: [pane, versionFooter])
        shell.orientation = .vertical
        shell.spacing = 0
        shell.alignment = .centerX
        let size = shell.fittingSize
        window.contentView = shell
        Appearance.paint(window)
        // The height follows the content — three rows in Permissions and a dozen in Recording should
        // not be the same height
        var f = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        f.origin = window.frame.origin
                f.origin.y += window.frame.height - f.height     // keep the top edge; grow downwards
        window.setFrame(f, display: true, animate: window.isVisible)
        if tab == .permissions { refreshPermissions() }
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.itemID)
    }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.itemID)
    }
    func toolbarSelectableItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.itemID)
    }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab.allCases.first(where: { $0.itemID == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(pickTab(_:))
        return item
    }

    @objc private func pickTab(_ sender: NSToolbarItem) {
        guard let tab = Tab.allCases.first(where: { $0.itemID == sender.itemIdentifier }) else { return }
        show(tab)
    }

    // MARK: - Pane contents

    private func buildPane(_ tab: Tab) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 18, right: 22)

        switch tab {
        case .hotkeys:
            for a in HotkeyAction.allCases {
                let f = HotkeyField(action: a)
                // A ↺ at the end of each row: one click back to the key we recommend, with nothing to
                // remember. Greyed out when it already is the default — a greyed button is itself the
                // answer to "am I on the default right now?"
                let reset = NSButton()
                reset.bezelStyle = .accessoryBar
                // An icon-only button's accessibility name can only come from the image's
                // accessibilityDescription — a toolTip is "help" to VoiceOver, not a name, so with only
                // a tooltip the screen reader announces a bare "button".
                let resetTip = Lf("hotkey.resetTip", "Reset to %@", a.defaultHotkey.display)
                reset.image = NSImage(systemSymbolName: "arrow.counterclockwise",
                                      accessibilityDescription: resetTip)
                reset.imagePosition = .imageOnly
                reset.toolTip = resetTip
                reset.isEnabled = prefs.hotkey(for: a) != a.defaultHotkey
                resetButtons[a] = reset
                reset.translatesAutoresizingMaskIntoConstraints = false
                reset.widthAnchor.constraint(equalToConstant: 28).isActive = true

                let apply: (Hotkey) -> Void = { [weak self] hk in
                    guard let self else { return }
                    // Say **why** it will not work — a flat "no" leaves people trying the same key over
                    // and over.
                    let why = HotkeyManager.current?.rejection(for: hk, action: a)
                    let ok = HotkeyManager.current?.rebind(a, to: hk) ?? false
                    let reason: String
                    switch why {
                    case .taken(let who):
                        reason = Lf("hotkey.taken", "That key already belongs to %@. Change that one first.", who.title)
                    case .needsModifier:
                        reason = L("hotkey.needsModifier", "A bare character key would be taken system-wide — add ⌘, ⌥, ⌃ or ⇧, or use a function key.")
                    case nil:
                        reason = L("hotkey.rejected", "That combination is taken by the system. Try another.")
                    }
                    hotkeyNote.stringValue = ok
                        ? L("hotkey.changed", "Changed. Press it — a ✓ on the right means the key is ours.")
                        : reason
                    hotkeyNote.textColor = ok ? .secondaryLabelColor : .systemRed
                    reset.isEnabled = prefs.hotkey(for: a) != a.defaultHotkey
                    f.needsDisplay = true
                    // When the capture key changes, the "record = double-tap X" line has to change with
                    // it
                    if a == .capture { self.hotkeyFields[.record]?.needsDisplay = true }
                }
                f.onChange = apply
                resetHandlers[ObjectIdentifier(reset)] = { apply(a.defaultHotkey) }
                reset.target = self
                reset.action = #selector(resetHotkey(_:))

                hotkeyFields[a] = f
                let row = NSStackView()
                row.orientation = .horizontal
                row.spacing = 6
                row.addArrangedSubview(f)
                row.addArrangedSubview(reset)
                stack.addArrangedSubview(field(a.title, row))

            }
            stack.addArrangedSubview(spacer(2))
            hotkeyNote.font = .systemFont(ofSize: 11)
            hotkeyNote.textColor = .secondaryLabelColor
            // One sentence of explanation, and no more. It used to be two paragraphs over four lines,
            // and most people skipped them at a glance — the more explanation, the less of it is read.
            // The Fn half only appears on a laptop: most keyboards attached to a desktop send plain F
            // keys, and that sentence is noise to those users.
            let fn = Self.isLaptop
                ? Lf("hotkey.noteFn", " (on a MacBook, press Fn+%@)", prefs.hotkey(for: .capture).display) : ""
            hotkeyNote.stringValue = Lf("hotkey.note3", "Click a box and press a new key. A ✓ after pressing the hotkey means Pin received it.%@", fn)
            hotkeyNote.lineBreakMode = .byWordWrapping
            hotkeyNote.maximumNumberOfLines = 2
            hotkeyNote.preferredMaxLayoutWidth = 430
            stack.addArrangedSubview(indent(hotkeyNote))

            // The two keys that matter most during a capture, as read-only rows aligned like the ones
            // above (no ↺, one shade dimmer). Only these two: every other key is explained when the
            // user hovers the matching button, and piling them up here just makes a block of text
            // nobody reads (Tim, 2026-09-06: just mention Return and Esc).
            stack.addArrangedSubview(spacer(8))
            for (title, key) in [
                (L("hotkey.fixedCopy", "Copy"), "⏎"),
                (L("hotkey.fixedCancel", "Cancel"), "Esc"),
            ] {
                stack.addArrangedSubview(field(title, fixedKey(key)))
            }
            stack.addArrangedSubview(indent(note2(L("hotkey.fixedNote", "Fixed keys while capturing; not rebindable."))))

            // A hotkey only works while Pin is running, so this row belongs in the pane people come
            // to when the key does nothing — not buried under a general "behaviour" heading.
            stack.addArrangedSubview(spacer(8))
            let loginNote = note2("")
            let loginBox = check(L("settings.launchAtLogin", "Start Pin when I log in"),
                                 LaunchAtLogin.isEnabled) { [weak self] wanted in
                // **The checkbox follows the system, not the click.** Registration fails for a copy
                // of Pin that is not somewhere macOS will launch from, and a box that ticks itself
                // while nothing was registered promises a hotkey that will not be there after the
                // restart.
                LaunchAtLogin.set(wanted)
                self?.refreshLaunchAtLogin()
            }
            launchAtLoginBox = loginBox
            launchAtLoginNote = loginNote
            stack.addArrangedSubview(indent(loginBox))
            stack.addArrangedSubview(indent(loginNote))
            refreshLaunchAtLogin()

        case .look:
            let theme = ThemeSegments()
            theme.onPick = { [weak self] t in
                self?.prefs.appearance = t.rawValue; Appearance.apply()
            }
            stack.addArrangedSubview(field(L("settings.appearance", "Light / dark"), theme))
            let pal = PaletteSegments()
            pal.onPick = { [weak self] p in
                self?.prefs.palette = p.rawValue; Appearance.apply()
            }
            stack.addArrangedSubview(field(L("settings.palette", "Palette"), pal))
            let lang = NSPopUpButton()
            for l in AppLanguage.allCases { lang.addItem(withTitle: l.title) }
            lang.selectItem(at: AppLanguage.allCases.firstIndex(of: AppLanguage.current) ?? 0)
            lang.target = self; lang.action = #selector(languageChanged(_:))
            lang.translatesAutoresizingMaskIntoConstraints = false
            lang.widthAnchor.constraint(equalToConstant: 224).isActive = true
            stack.addArrangedSubview(field(L("settings.language", "Language"), lang))
            stack.addArrangedSubview(spacer(2))
            langNote.font = .systemFont(ofSize: 11)
            langNote.textColor = .tertiaryLabelColor
            langNote.stringValue = L("settings.lookNote3",
                "Light/dark and the palette also apply to the capture toolbar, recording HUD and review bar; the selection overlay always dims. Changing the language needs a restart.")
            langNote.lineBreakMode = .byWordWrapping
            langNote.maximumNumberOfLines = 4
            langNote.preferredMaxLayoutWidth = 430
            stack.addArrangedSubview(indent(langNote))

        case .capture:
            // Show Pictures/Pin rather than /Users/someone/Pictures/Pin — shorter, does not expose the
            // user name, and safe to have in a screenshot.
            dirLabel = NSTextField(labelWithString: readablePath(prefs.saveDirectory))
            dirLabel.lineBreakMode = .byTruncatingMiddle
            dirLabel.textColor = .secondaryLabelColor
            dirLabel.font = .systemFont(ofSize: 11)
            dirLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let pick = NSButton(title: L("settings.chooseDir", "Choose…"), target: self, action: #selector(chooseDir))
            pick.translatesAutoresizingMaskIntoConstraints = false
            // **The minimum is not a fixed number**: 「选择…」 is 71pt in Chinese while "Choose…" needs
            // 91pt, and pinning it at 76 truncates the English button to "Cho…". The minimum exists so
            // the button does not shrink to a sliver in Chinese; a longer title should be as wide as it
            // needs (measured with an offscreen NSButton on 2026-09-06 08:2x — invisible from a Chinese
            // interface).
            pick.widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true
            let dirRow = NSStackView()
            dirRow.orientation = .horizontal
            dirRow.spacing = 8
            dirRow.addArrangedSubview(pick)
            dirRow.addArrangedSubview(dirLabel)
            stack.addArrangedSubview(field(L("settings.saveTo", "Save to"), dirRow))
            stack.addArrangedSubview(spacer(2))
            for (t, on, h) in [
                (L("settings.copyAfter", "Also copy to the clipboard after capture"), prefs.copyAfterCapture, { (v: Bool) in self.prefs.copyAfterCapture = v }),
                (L("settings.magnifier", "Show the magnifier"), prefs.showMagnifier, { (v: Bool) in self.prefs.showMagnifier = v }),
                (L("settings.autoDetect", "Detect window edges automatically"), prefs.autoDetectWindows, { (v: Bool) in self.prefs.autoDetectWindows = v }),
                (L("settings.pinShadow", "Pins cast a shadow"), prefs.pinShadow, { (v: Bool) in self.prefs.pinShadow = v }),
            ] {
                stack.addArrangedSubview(indent(check(t, on, h)))
            }

        case .record:
            let fmt = NSPopUpButton()
            // The pop-up items need translating too. An item hardcoded as "3 秒" is an untranslated
            // line of Chinese in an English interface (seen as "Ink stays for: 3 秒" in an English
            // screenshot, 2026-09-06).
            fmt.addItems(withTitles: [L("settings.fmtMP4", "MP4（H.264）"), "GIF"])
            fmt.selectItem(at: prefs.recordFormat == "gif" ? 1 : 0)
            fmt.target = self; fmt.action = #selector(formatChanged(_:))
            stack.addArrangedSubview(field(L("settings.format", "Format"), fmt))
            let fps = NSPopUpButton()
            fps.addItems(withTitles: ["15 fps", "30 fps", "60 fps"])
            fps.selectItem(at: [15, 30, 60].firstIndex(of: prefs.recordFrameRate) ?? 1)
            fps.target = self; fps.action = #selector(fpsChanged(_:))
            stack.addArrangedSubview(field(L("settings.fps", "Frame rate"), fps))
            let gifW = NSPopUpButton()
            gifW.addItems(withTitles: ["480 px", "640 px", "800 px", "1080 px", L("settings.gifOriginal", "Original size")])
            gifW.selectItem(at: [480, 640, 800, 1080, 100_000].firstIndex(of: prefs.gifMaxWidth) ?? 2)
            gifW.target = self; gifW.action = #selector(gifWidthChanged(_:))
            stack.addArrangedSubview(field(L("settings.gifWidth", "Max GIF width"), gifW))
            let life = NSPopUpButton()
            life.addItems(withTitles: [Lf("settings.sec", "%@ s", "1"), Lf("settings.sec", "%@ s", "2"),
                                       Lf("settings.sec", "%@ s", "3"), Lf("settings.sec", "%@ s", "5"),
                                       L("settings.inkForever", "Keep it")])
            life.selectItem(at: [1.0, 2.0, 3.0, 5.0, 9999.0].firstIndex(of: prefs.liveAnnotateLife) ?? 2)
            life.target = self; life.action = #selector(lifeChanged(_:))
            stack.addArrangedSubview(field(L("settings.inkLife", "Ink stays for"), life))
            // Which modifier draws on screen. Here rather than in Hotkeys because it belongs to the
            // recording feature it turns on, and the checkbox below names it in its own text.
            let inkMod = NSPopUpButton()
            inkMod.addItems(withTitles: InkModifier.allCases.map(\.title))
            inkMod.selectItem(at: InkModifier.allCases.firstIndex(of: prefs.inkModifier) ?? 0)
            inkMod.target = self; inkMod.action = #selector(inkModifierChanged(_:))
            stack.addArrangedSubview(field(L("settings.inkKey", "Draw with"), inkMod))
            stack.addArrangedSubview(spacer(2))
            for (t, on, h) in [
                (L("settings.copyAfterRecord", "Copy the file to the clipboard when recording stops"), prefs.copyAfterRecord, { (v: Bool) in self.prefs.copyAfterRecord = v }),
                (L("settings.cursor", "Record the cursor"), prefs.recordShowCursor, { (v: Bool) in self.prefs.recordShowCursor = v }),
                (L("settings.ripple2", "Ripple on click, so viewers see where you clicked"), prefs.recordHighlightClicks, { (v: Bool) in self.prefs.recordHighlightClicks = v }),
                (Lf("settings.liveAnnotate2", "Draw on screen while recording (hold %@ and drag)", prefs.inkModifier.display), prefs.liveAnnotate, { (v: Bool) in self.prefs.liveAnnotate = v }),
                (L("settings.sysAudio", "Record system audio"), prefs.recordSystemAudio, { (v: Bool) in self.prefs.recordSystemAudio = v }),
                (L("settings.mic", "Record the microphone"), prefs.recordMicrophone, { (v: Bool) in
                    self.prefs.recordMicrophone = v
                    if v, Permissions.microphone != .authorized {
                        Task { _ = await Permissions.requestMicrophone(); self.refreshPermissions() }
                    }
                }),
            ] {
                stack.addArrangedSubview(indent(check(t, on, h)))
            }

        case .ai:
            // For AI. Three things, none of them intrusive: (1) the instructions ship in the bundle
            // (Resources/pin-screen-recorder/SKILL.md), (2) the sentence to tell an AI, (3) a button —
            // for anyone who would rather skip that sentence — that installs into Codex's or Claude
            // Code's directory.
            // **No `indent()` in this pane.** Every other pane indents to clear a right-aligned label
            // column; this one has no labels, so indenting only pushes the text off the left edge and
            // leaves a wide empty gutter on the right. One measure, full width, for everything here.
            stack.spacing = 10
            stack.addArrangedSubview(paneText(
                // Say what it does for the user and the one thing that makes it unusual — that it
                // runs without taking the mouse. `pin://` was in here; it is how, not what, and the
                // person reading this pane never types one.
                L("ai.intro2", "Codex, Claude Code and other agents can drive Pin — record a region, take shots, mark where they clicked — without touching your mouse or taking focus."),
                size: 12, color: .secondaryLabelColor))

            // The sentence is the one thing on this page the user takes away, so it gets a container
            // and the button that copies it — **inside the card, under the text**. It used to be a
            // wrapping label beside a button in a horizontal stack with no width constraint, which
            // AppKit measures wrong: the sentence was cut off mid-path ("…/Contents/") and the bad
            // height left a hole under it (Tim, 2026-09-07: this is a mess).
            stack.addArrangedSubview(spacer(2))
            stack.addArrangedSubview(eyebrow(L("ai.sayThis2", "Tell your agent this")))
            stack.addArrangedSubview(sentenceCard())

            stack.addArrangedSubview(spacer(8))
            stack.addArrangedSubview(paneText(
                L("ai.installWhy2", "Pin's instructions ship inside the app, where an agent will find them. This puts a copy in the agent's own folder so it knows Pin without being told — written only when you press it, and removable."),
                // Same weight as the intro: both are explanation, and only the list of paths
                // underneath is detail. Three greys for two kinds of text is what made this pane
                // read as soup.
                size: 12, color: .secondaryLabelColor))
            skillButton = NSButton(title: "", target: self, action: #selector(toggleSkill))
            let btnRow = NSStackView(views: [skillButton])
            btnRow.orientation = .horizontal
            btnRow.alignment = .centerY
            stack.addArrangedSubview(btnRow)
            skillNote = NSTextField(wrappingLabelWithString: "")
            skillNote.font = .systemFont(ofSize: 11)
            skillNote.textColor = .tertiaryLabelColor
            skillNote.maximumNumberOfLines = 0
            skillNote.translatesAutoresizingMaskIntoConstraints = false
            skillNote.widthAnchor.constraint(equalToConstant: Self.paneWidth).isActive = true
            stack.addArrangedSubview(skillNote)
            refreshSkill()

        case .permissions:
            screenStatus = NSTextField(labelWithString: "")
            axStatus = NSTextField(labelWithString: "")
            micStatus = NSTextField(labelWithString: "")
            // Every row has to say **what it buys and what happens without it**. Naming the permission
            // alone says nothing — a user is under no obligation to know what "Accessibility" gets them
            // in this particular app (Tim, 2026-09-05: what is this, and what difference does it make?).
            permButtons = [#selector(openScreenPerm), #selector(openAXPerm), #selector(openMicPerm)].map {
                NSButton(title: L("settings.openSysPrefs", "Open System Settings"), target: self, action: $0)
            }
            stack.spacing = 14
            stack.addArrangedSubview(permRow(
                L("settings.permScreen", "Screen Recording"),
                L("settings.permScreenWhy2", "Required. Capture, pinning and recording all depend on it; nothing works without it."),
                screenStatus, permButtons[0]))
            stack.addArrangedSubview(permRow(
                L("settings.permAX", "Accessibility"),
                // Do not write "snapping" or "controls" — those are developer words (Tim, 2026-09-05:
                // I don't think I understood that). Say what the user sees: without it a capture can
                // only frame a whole window; with it, a single button or panel inside one.
                Lf("settings.permAXWhy4", "Optional. Lets a capture snap to a single button or panel inside a window instead of only the whole window; and lets you hold %@ to draw on screen while recording.", prefs.inkModifier.display),
                axStatus, permButtons[1]))
            stack.addArrangedSubview(permRow(
                L("settings.permMic", "Microphone"),
                L("settings.permMicWhy2", "Optional. Used only for narration; computer audio records either way."),
                micStatus, permButtons[2]))

            // Starting at login is a preference, not a permission — it lives in the Hotkeys pane and
            // does not belong here as a permanent row. **Except in one state**: when macOS has taken
            // the registration and is holding it until the user allows it in Login Items. Then the
            // user has switched it on, believes it is on, and it is not — which is exactly the shape
            // this pane exists for. So the row appears only then, and disappears again once it is
            // sorted or switched off.
            loginStatus = NSTextField(labelWithString: "")
            let loginButton = NSButton(title: L("settings.openSysPrefs", "Open System Settings"),
                                       target: self, action: #selector(openLoginItemsPerm))
            let row = permRow(
                L("settings.permLogin", "Starting at login"),
                L("settings.permLoginWhy", "You switched this on, but macOS is holding it until you allow Pin under Login Items. Until then the hotkey will not work after a restart."),
                loginStatus, loginButton)
            row.isHidden = true
            loginPermRow = row
            stack.addArrangedSubview(row)
            stack.addArrangedSubview(spacer(2))
        }

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 520),
        ])
        return container
    }

    /// A read-only key field: the size and corner radius match `HotkeyField`, one shade paler, so it
    /// reads immediately as "this one cannot be changed".
    /// The text is centred vertically with constraints — stretching the label to 26pt directly puts it
    /// against the top edge.
    private func fixedKey(_ key: String) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        let l = NSTextField(labelWithString: key)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            // The same width as an editable key field. The two kinds sit one above the other, and a
            // difference in width is obvious (2026-09-06 07:22: after the editable ones were widened to
            // 190, these were still at 150).
            box.widthAnchor.constraint(equalToConstant: HotkeyField.boxWidth),
            box.heightAnchor.constraint(equalToConstant: 26),
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            l.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        return box
    }

    /// Whether this is a laptop — decided by **whether there is an internal battery**, not by a model
    /// string.
    /// Used only to decide whether to mention Fn, so being wrong costs one sentence either way and
    /// affects nothing else.
    ///
    /// `hw.model` on Apple Silicon reads `Mac14,5`, `Mac15,3` and so on, and **contains no "MacBook"**
    /// (this machine is `Mac14,5`, a 14-inch MacBook Pro). So the old `.contains("MacBook")` returned
    /// false on every Apple-silicon laptop — while what it guarded was precisely the sentence "press
    /// Fn+F1 on a MacBook". A bare F1 on a laptop is the brightness key and produces no key event at
    /// all, so a new user pressing it gets nothing, needs that sentence most, and it had never once
    /// been shown on a new machine.
    private static let isLaptop: Bool = {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return list.contains { ps in
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any]
            else { return false }
            return d[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType
        }
    }()

    @objc private func resetHotkey(_ sender: NSButton) {
        resetHandlers[ObjectIdentifier(sender)]?()
    }

    private func note2(_ t: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.preferredMaxLayoutWidth = 430
        return l
    }

    // MARK: - Components

    private func spacer(_ h: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: h).isActive = true
        return v
    }

    /// A group heading: small, semibold, secondary, uppercase and letterspaced — grouping rests on it
    /// rather than on stretched spacing.
    private func groupTitle(_ t: String) -> NSView {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// One "label + control" row, with a fixed label width so the controls' left edges line up.
    private func field(_ t: String, _ control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        let l = NSTextField(labelWithString: t)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: Self.labelColumnWidth).isActive = true
        row.addArrangedSubview(l)
        row.addArrangedSubview(control)
        return row
    }

    /// The width of the label column, measured in the language actually running.
    ///
    /// It used to be a hardcoded 96 — the width the longest Chinese label needs. Fine for the two
    /// languages we look at while working, and wrong for the ones we do not: Spanish needs 156pt for
    /// "Fotogramas por segundo", French 127 for "Largeur max. du GIF", German 99 for
    /// "Max. GIF-Breite". All three would have shipped truncated, and none of them would have been
    /// visible from a Chinese or English screen (found by the offscreen fit check, once it was taught
    /// to measure every shipped language rather than the two we look at while working).
    ///
    /// Shortening each translation to fit would work today and break again with the next language.
    /// Measuring does not: the column is as wide as this language needs, with 96 as the floor so
    /// Chinese and English keep exactly the layout they have now, and a ceiling so one runaway string
    /// cannot squeeze the controls off the right edge.
    private static let labelColumnWidth: CGFloat = {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let widest = fieldLabels.map { label -> CGFloat in
            (label as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return min(max(96, ceil(widest) + 2), 168)
    }()

    /// Every string that goes through `field(_:_:)`. Kept beside the width so adding a row means
    /// adding it here too — a label missing from this list would be the one that gets truncated.
    private static var fieldLabels: [String] {
        [L("settings.appearance", "Light / dark"), L("settings.palette", "Palette"),
         L("settings.language", "Language"), L("settings.saveTo", "Save to"),
         L("settings.format", "Format"), L("settings.fps", "Frame rate"),
         L("settings.gifWidth", "Max GIF width"), L("settings.inkLife", "Ink stays for")]
    }

    /// An indent container aligned with the controls' left edge, used by notes and checkboxes alike.
    private func indent(_ v: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        let pad = NSView()
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.widthAnchor.constraint(equalToConstant: 106).isActive = true
        row.addArrangedSubview(pad)
        row.addArrangedSubview(v)
        return row
    }

    /// The one text measure on a pane without a label column.
    ///
    /// **520 minus the stack's two 22pt insets.** Set to 496 first, which pushed the text to within
    /// 4pt of the right edge while everything else kept its 22 — the right margin has to match the
    /// left or the pane looks like it is sliding off (Tim, 2026-09-07).
    static let paneWidth: CGFloat = 520 - 22 * 2

    /// Body text that fills the pane, wraps properly, and does not get measured wrong inside a stack.
    /// A wrapping label needs **both** an explicit width and no line limit — with only
    /// `preferredMaxLayoutWidth` a horizontal stack can still squeeze it and clip the last lines.
    private func paneText(_ t: String, size: CGFloat, color: NSColor) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: size)
        l.textColor = color
        l.maximumNumberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: Self.paneWidth).isActive = true
        return l
    }

    /// A small caption that names the thing under it. Semibold and uppercase-weight rather than a
    /// heading: it labels one block, and a real heading here would compete with the toolbar tabs.
    private func eyebrow(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    /// A plain layer-backed card that repaints itself when the appearance changes.
    ///
    /// **Not `NSBox`**: setting its `contentView` to a view laid out with constraints leaves the box
    /// unable to work out its own height, and the first attempt drew the sentence straight over the
    /// paragraph above it (2026-09-07). A view that owns its subviews is the simpler thing here, and
    /// the colours are resolved inside `updateLayer` against the appearance in force, so light and
    /// dark both come out right instead of freezing at whatever they were when it was built.
    private final class CardView: NSView {
        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.cornerRadius = 8
                layer?.borderWidth = 1
                layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
                layer?.borderColor = NSColor.separatorColor.cgColor
            }
        }
    }

    /// The sentence to hand an agent, in a card with its Copy button.
    ///
    /// The button lives **inside the card, under the text**. It used to sit beside a wrapping label
    /// in a horizontal stack with no width constraint: AppKit measured that wrong, cut the sentence
    /// off mid-path, and left the button stranded most of a pane away from the thing it copies.
    private func sentenceCard() -> NSView {
        let card = CardView()
        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextField(wrappingLabelWithString: AgentSkill.sentence)
        text.font = .systemFont(ofSize: 12)
        text.textColor = .labelColor
        text.isSelectable = true
        text.maximumNumberOfLines = 0
        text.translatesAutoresizingMaskIntoConstraints = false

        let copyBtn = NSButton(title: L("ai.copy", "Copy this sentence"),
                               target: self, action: #selector(copyAISentence))
        copyBtn.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(text); card.addSubview(copyBtn)
        let pad: CGFloat = 14
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: Self.paneWidth),
            text.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: pad),
            text.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            text.topAnchor.constraint(equalTo: card.topAnchor, constant: pad),
            copyBtn.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 10),
            copyBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -pad),
            copyBtn.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -pad),
        ])
        return card
    }

    private func note(_ t: String) -> NSView {
        let l = NSTextField(wrappingLabelWithString: t)
        l.font = .systemFont(ofSize: 11)
        l.textColor = .tertiaryLabelColor
        l.preferredMaxLayoutWidth = 360
        return indent(l)
    }


    /// Redraw the login-item row from what the system actually reports.
    ///
    /// macOS owns this switch too — System Settings ▸ General ▸ Login Items can turn it off behind
    /// our back — so the row is rebuilt from `SMAppService` rather than from anything we stored.
    private func refreshLaunchAtLogin() {
        guard let box = launchAtLoginBox else { return }
        box.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginNote?.stringValue = LaunchAtLogin.needsApproval
            ? L("settings.launchNeedsApproval",
                "macOS is holding this until you allow it in System Settings ▸ General ▸ Login Items.")
            : L("settings.launchWhy",
                "The hotkey only works while Pin is running, so after a restart it does nothing until Pin opens.")
    }

    private func check(_ t: String, _ on: Bool, _ handler: @escaping (Bool) -> Void) -> NSButton {
        let b = NSButton(checkboxWithTitle: t, target: self, action: #selector(checkChanged(_:)))
        b.state = on ? .on : .off
        checkHandlers[ObjectIdentifier(b)] = handler
        return b
    }

    /// One permission = two rows: "name ………… status column" above, one line of explanation below.
    ///
    /// The right side is **one column, fixed width, one thing per row**: a line of small text when
    /// granted, a "Grant…" button when not, in exactly the same place. The status text and the button
    /// used to sit side by side, so a row with a button pushed its status text into the middle, giving
    /// three rows three different right edges (Tim, 2026-09-05: the text here is a bit of a mess).
    /// The name and its explanation are **one unit in one typeface**: the explanation was raised to
    /// 12pt and is no longer treated as "interface skeleton" and switched to a sans.
    private func permRow(_ name: String, _ detail: String,
                         _ status: NSTextField, _ button: NSButton) -> NSView {
        let l = NSTextField(labelWithString: name)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        gap.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // The status column: status and button share one cell, and setPerm decides which shows
        status.font = .systemFont(ofSize: 12)
        status.alignment = .right
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.title = L("settings.grant", "Grant…")
        let slot = NSView()
        slot.translatesAutoresizingMaskIntoConstraints = false
        slot.widthAnchor.constraint(equalToConstant: 88).isActive = true
        for v in [status, button] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(v)
            v.trailingAnchor.constraint(equalTo: slot.trailingAnchor).isActive = true
            v.centerYAnchor.constraint(equalTo: slot.centerYAnchor).isActive = true
        }
        slot.heightAnchor.constraint(equalTo: button.heightAnchor).isActive = true

        let head = NSStackView(views: [l, gap, slot])
        head.orientation = .horizontal
        head.spacing = 10

        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 12)
        d.textColor = .secondaryLabelColor
        d.preferredMaxLayoutWidth = 446

        let col = NSStackView(views: [head, d])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3
        col.translatesAutoresizingMaskIntoConstraints = false
        col.widthAnchor.constraint(equalToConstant: 446).isActive = true
        head.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    private var resetButtons: [HotkeyAction: NSButton] = [:]
    private var permButtons: [NSButton] = []
    private var skillButton = NSButton()
    private var skillNote = NSTextField(labelWithString: "")

    private func refreshSkill() {
        let on = AgentSkill.isInstalled
        skillButton.title = on ? L("ai.remove", "Remove from agent folders") : L("ai.install", "Install into Codex / Claude Code folders")
        let paths = AgentSkill.targets.map { "~/" + $0.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path + "/", with: "") }
        skillNote.stringValue = (on ? L("ai.installed", "Installed at:") : L("ai.willInstall", "Will write to:")) + "\n" + paths.joined(separator: "\n")
    }

    @objc private func toggleSkill() {
        if AgentSkill.isInstalled { AgentSkill.remove() } else { AgentSkill.install() }
        refreshSkill()
    }

    @objc private func copyAISentence() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentSkill.sentence, forType: .string)
    }

    /// Status text and whether the button shows, decided in one place.
    private func setPerm(_ status: NSTextField, _ button: NSButton, granted: Bool, stale: Bool = false) {
        // Granted: a line of text. Not granted: a button. One cell, one of the two — so the right edge
        // always lines up.
        status.stringValue = L("settings.granted", "Granted")
        status.textColor = .secondaryLabelColor
        status.isHidden = !granted
        button.isHidden = granted
        // "Ticked but not taking effect" is too long for the status column, so it hangs off the
        // button's tooltip
        button.toolTip = stale
            ? L("settings.axStale", "Ticked but not taking effect? Remove Pin from the list with − and add it back")
            : nil
    }

    private func refreshPermissions() {
        guard screenStatus != nil, permButtons.count == 3 else { return }
        setPerm(screenStatus, permButtons[0], granted: Permissions.screenCapture)
        // Still "not granted" here after ticking it in System Settings usually means the grant is
        // recorded against an older build — the only reliable fix found in testing is − then + in the
        // list (confirmed with Tim, 2026-09-05).
        setPerm(axStatus, permButtons[1], granted: Permissions.accessibility, stale: true)
        setPerm(micStatus, permButtons[2], granted: Permissions.microphone == .authorized)
        // Only while macOS is holding it — see the comment where this row is built.
        loginPermRow?.isHidden = !LaunchAtLogin.needsApproval
        loginStatus?.stringValue = L("settings.permLoginHeld", "Waiting for you")
        loginStatus?.textColor = .systemOrange
    }

    // MARK: - Actions

    @objc private func checkChanged(_ sender: NSButton) {
        checkHandlers[ObjectIdentifier(sender)]?(sender.state == .on)
    }

    @objc private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.saveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prefs.saveDirectory = url
        dirLabel.stringValue = readablePath(url)
    }

    @objc private func languageChanged(_ s: NSPopUpButton) {
        AppLanguage.allCases[s.indexOfSelectedItem].apply()
        langNote.stringValue = L("settings.langChanged", "Changed — restart Pin to see it.")
        langNote.textColor = .systemOrange
    }

    @objc private func themeChanged(_ s: NSPopUpButton) {
        prefs.appearance = AppTheme.allCases[s.indexOfSelectedItem].rawValue
        Appearance.apply()
    }

    @objc private func paletteChanged(_ s: NSPopUpButton) {
        prefs.palette = AppPalette.allCases[s.indexOfSelectedItem].rawValue
        Appearance.apply()
    }

    @objc private func lifeChanged(_ s: NSPopUpButton) { prefs.liveAnnotateLife = [1.0, 2.0, 3.0, 5.0, 9999.0][s.indexOfSelectedItem] }
    /// Changing it rebuilds this pane: the checkbox below names the modifier in its own text, and a
    /// checkbox still reading "hold ⌥" after someone picked ⌃⌥ is exactly the stale label the
    /// hotkey rows already avoid by reading their binding every time they are drawn.
    @objc private func inkModifierChanged(_ s: NSPopUpButton) {
        let all = InkModifier.allCases
        guard s.indexOfSelectedItem >= 0, s.indexOfSelectedItem < all.count else { return }
        guard all[s.indexOfSelectedItem] != prefs.inkModifier else { return }
        prefs.inkModifier = all[s.indexOfSelectedItem]
        // **Teach the new key.** The tip that says which modifier draws is shown on the first three
        // recordings and then stops, on the grounds that it has been learned. Change the key and
        // what was learned is now wrong, so the count goes back to zero and it teaches again.
        prefs.inkTipShown = 0
        panes[.record] = buildPane(.record)
        if current == .record { show(.record) }
    }
    @objc private func formatChanged(_ s: NSPopUpButton) { prefs.recordFormat = s.indexOfSelectedItem == 1 ? "gif" : "mp4" }
    @objc private func fpsChanged(_ s: NSPopUpButton) { prefs.recordFrameRate = [15, 30, 60][s.indexOfSelectedItem] }
    @objc private func gifWidthChanged(_ s: NSPopUpButton) { prefs.gifMaxWidth = [480, 640, 800, 1080, 100_000][s.indexOfSelectedItem] }
    @objc private func openScreenPerm() { Permissions.requestScreenCapture(); Permissions.openSystemSettings(.screenCapture) }
    @objc private func openAXPerm() { Permissions.requestAccessibility(); Permissions.openSystemSettings(.accessibility) }
    /// **Ask first, and only fall back to System Settings.**
    ///
    /// macOS lists an application under Privacy ▸ Microphone only once it has actually asked for it.
    /// Pin never asks on its own — the microphone is off by default and used only for narration — so
    /// this button used to open a pane that does not contain Gigle Pin at all, which is a dead end
    /// dressed as an instruction (Tim, 2026-09-08). The other two permission buttons have always
    /// requested first; this one was the odd one out.
    ///
    /// Never asked: the request puts up the system prompt and one click is the whole job — System
    /// Settings never has to be opened. Already refused: the prompt will not come back, but by then
    /// Pin is in the list, so opening it is the right move.
    @objc private func openMicPerm() {
        guard Permissions.microphone == .notDetermined else {
            Permissions.openSystemSettings(.microphone); return
        }
        Task { @MainActor in
            _ = await Permissions.requestMicrophone()
            refreshPermissions()
        }
    }
    @objc private func openLoginItemsPerm() { Permissions.openLoginItems() }
}
