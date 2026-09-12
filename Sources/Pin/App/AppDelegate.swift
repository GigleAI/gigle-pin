// The conductor: hotkeys / menu / URLs → the overlay → copy, save, pin, record. Every window is
// opened from here.

import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController!
    private var hotkeys: HotkeyManager!
    private let overlay = OverlayController()
    private let pins = PinManager()
    private let recordings = RecordingCoordinator()
    /// Set once a hotkey has fired successfully — the help entry in the menu hides on the strength of
    /// it.
    static let hotkeyWorkedKey = "hotkeyEverFired"
    private var pendingURLs: [URL] = []
    private var ready = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.shared.migrateHotkeyDefaultsIfNeeded()
        UnsavedRecordings.sweep()
        MainMenu.install()
        NSApp.setActivationPolicy(.accessory)
        Appearance.apply()

        statusItem = StatusItemController()
        statusItem.onCapture = { [weak self] in self?.beginCapture(.capture) }
        statusItem.onRecord = { [weak self] in self?.beginCapture(.record) }
        statusItem.onPinClipboard = { [weak self] in self?.pins.pinClipboard() }
        statusItem.onToggleAllPins = { [weak self] in self?.pins.toggleAll() }
        statusItem.onRestorePins = { [weak self] in self?.pins.restoreInteraction() }
        statusItem.onCloseAllPins = { [weak self] in self?.pins.closeAll() }
        statusItem.onOpenFolder = { NSWorkspace.shared.open(Preferences.shared.ensureSaveDirectory()) }
        statusItem.hasLastRecording = { Preferences.shared.lastRecording != nil }
        statusItem.clickThroughCount = { [weak self] in self?.pins.clickThroughCount ?? 0 }
        statusItem.onLastRecording = { [weak self] in self?.recordings.reopenLastRecording() }
        statusItem.onSettings = { [weak self] in self?.openSettings() }
        statusItem.onHotkeyCheck = { WelcomeWindow.show() }
        statusItem.onStopRecording = { [weak self] in self?.recordings.stopRecording() }
        statusItem.pinCount = { [weak self] in self?.pins.count ?? 0 }
        statusItem.pinsHidden = { [weak self] in self?.pins.allHidden ?? false }
        statusItem.isRecording = { [weak self] in self?.recordings.isRecording ?? false }
        statusItem.hotkeyConfirmed = { UserDefaults.standard.bool(forKey: Self.hotkeyWorkedKey) }

        hotkeys = HotkeyManager { [weak self] event in self?.handle(event) }
        hotkeys.register()

        recordings.onStateChanged = { [weak self] recording, paused in
            self?.statusItem.setRecording(recording, paused: paused)
        }

        // First launch: have the user actually press the hotkey. It is the only way to discover that
        // the key belongs to someone else — RegisterEventHotKey does not report a conflict, so the
        // code cannot find out.
        if WelcomeWindow.shouldShow { WelcomeWindow.show() }

        ready = true
        let urls = pendingURLs
        pendingURLs = []
        urls.forEach(route)
        // On by default, applied exactly once. A tool whose only entrance is a global hotkey is
        // useless after a restart if it is not running, and the user gets no error to explain it.
        LaunchAtLogin.applyDefaultOnce()

        #if DEBUG
                print("[app] launched screenRecording=\(Permissions.screenCapture) accessibility=\(Permissions.accessibility)")
    #endif
    }

    /// **Finish the recording in progress before quitting.**
    ///
    /// Without `finishWriting`, the MP4 on disk is an unopenable shell — the file is there and not
    /// small, and double-clicking it says "unsupported format". A user who picks "Quit Pin" from the
    /// menu bar halfway through a recording ("quitting should stop it, surely"), or a logout or
    /// shutdown sending us a quit event, loses that recording without a word of warning.
    ///
    /// Finishing is asynchronous, so answer `.terminateLater` first and release once it is written.
    /// Record it as "the most recent recording" on the way past, so it can be found again from the
    /// menu bar next time.
    private var terminationReplied = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recordings.isBusy else { return .terminateNow }
        // Both the finishing path and the fallback answer, and whichever arrives first wins — replying
        // twice is undefined behaviour, so block it.
        func allowQuit() {
            guard !terminationReplied else { return }
            terminationReplied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await recordings.finishForTermination()
            allowQuit()
        }
        // Fallback: the system gives only a few seconds at shutdown. Even genuinely stuck, it has to
        // be allowed to quit — an app that "cannot be quit" is worse than a lost recording.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            allowQuit()
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregister()
    }

    // MARK: - Hotkeys

    private func handle(_ event: HotkeyEvent) {
        // Tick the matching field while the settings window is open — so the user can confirm the key
        // really reached us
        WelcomeWindow.current?.hotkeyWorked()
        UserDefaults.standard.set(true, forKey: Self.hotkeyWorkedKey)
        switch event {
        case .capture, .record: SettingsWindowController.shared.noteHotkeyFired(.capture)
        case .pinClipboard:     SettingsWindowController.shared.noteHotkeyFired(.pinClipboard)
        case .toggleAllPins:    SettingsWindowController.shared.noteHotkeyFired(.toggleAllPins)
        }
        switch event {
        case .capture:
            // Pressing the capture key while recording stops it.
            if recordings.isRecording { recordings.stopRecording(); return }
            beginCapture(.capture)
        case .record:
            if recordings.isRecording { return }
            beginCapture(.record)
        case .pinClipboard:
            pins.pinClipboard()
        case .toggleAllPins:
            pins.toggleAll()
        }
    }

    // MARK: - Capture

    private func beginCapture(_ mode: OverlayMode) {
        overlay.begin(mode: mode) { [weak self] outcome in self?.finish(outcome) }
    }

    private func finish(_ outcome: OverlayOutcome) {
        // Encoding happens off the main thread now (see `Exporter`), so delivery is asynchronous —
        // and the overlay's fade-out, which used to be held up behind a PNG encode, runs on time.
        Task { @MainActor in await deliver(outcome) }
    }

    private func deliver(_ outcome: OverlayOutcome) async {
        switch outcome {
        case .cancelled:
            break
        case .openSettings:
            openSettings()
        case .copy(let r):
            await Exporter.copy(r)
        case .save(let r, let requested):
            // Having saved, it has to say where — silent success and silent failure are the same thing
            // to the person at the keyboard.
            if let url = await Exporter.save(r, to: requested) {
                AgentRequest.markDone(url, requested: requested != nil)
                let screen = NSScreen.screens.first { $0.frame.intersects(r.screenRect) } ?? Geometry.screenUnderMouse
                // "Move to…" moves **a file that is already saved**, rather than choosing a location
                // before saving. The common case (the default directory) costs nothing, and the rare
                // case of wanting somewhere else gets full control in one click — the cost is charged
                // when it is genuinely needed instead of every single time (concluded with Tim,
                // 2026-09-05).
                Toast.show(L("toast.saved", "Saved"),
                           detail: readablePath(url),
                           near: r.screenRect, on: screen,
                           actions: [
                            (L("toast.reveal", "Show in Finder"), {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }),
                            (L("toast.moveTo", "Move to…"), {
                                Exporter.relocate(url)
                            }),
                           ])
            } else {
                let screen = Geometry.screenUnderMouse
                Toast.show(L("toast.saveFailed", "Could not save — check that the save location still exists"),
                           near: r.screenRect, on: screen)
            }
            if Preferences.shared.copyAfterCapture { await Exporter.copy(r) }
        case .pin(let r):
            pins.pin(r)
            if Preferences.shared.copyAfterCapture { await Exporter.copy(r) }
        case .record(let rect, let screen):
            recordings.startRecording(rect: rect, screen: screen)
        }
    }

    // MARK: - Settings

    @objc func openSettings() {
        SettingsWindowController.shared.show()
    }

    // MARK: - pin:// URL

    func application(_ application: NSApplication, open urls: [URL]) {
        // On a cold start the URL arrives before didFinishLaunching, so queue it.
        guard ready else { pendingURLs += urls; return }
        urls.forEach(route)
    }

    private func route(_ url: URL) {
        // Accept only the schemes declared in our own Info.plist — `pin` for the shipping build,
        // `pindirector` for the Director. With both copies running, this is what keeps their URLs apart.
        //
        // **`jay://` used to be accepted here too** and was registered in the bundle, kept "for
        // compatibility" with scripts written before the rename. There were none: the first public
        // release already spoke `pin://`, and neither the skill file nor the website ever mentioned
        // the old name. So it was a second, undocumented way into everything `pin://` can do —
        // unknown even to us (Tim, 2026-09-09: "我们没有 jay 了啊"), and therefore unaudited.
        // An input surface nobody remembers is one nobody checks. Removed 0.1.8.
        guard let scheme = url.scheme, PinRole.urlSchemes.contains(scheme) else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Bad arguments get **a beep and a line in the log**, never silence: an agent decides its next
        // step from the feedback, and a silent failure just makes it retry blindly.
        func reject(_ why: String) {
            NSSound.beep()
                        print("[url] rejected \(url.host ?? "") — \(why)")
        }
        // Everything past this point is untrusted input — see `AgentRequest`. Parsing used to build
        // the dictionary with `Dictionary(uniqueKeysWithValues:)`, which **traps** on a repeated
        // parameter, before the verb was even read: `pin://settings?tab=a&tab=b` from anywhere on the
        // machine killed the process, and any recording in progress with it.
        let q: [String: String]
        switch AgentRequest.query(comps?.queryItems) {
        case .success(let parsed): q = parsed
        case .failure(let e): reject(e.why); return
        }
        func num(_ k: String) -> CGFloat? { AgentRequest.number(q[k]).map { CGFloat($0) } }
        func extent(_ k: String) -> CGFloat? { AgentRequest.positive(q[k]).map { CGFloat($0) } }
        // Where this verb is allowed to write. `extensions` is what the verb actually produces, so a
        // screenshot cannot be dropped into someone's .txt.
        func out(_ extensions: [String]) -> Result<URL, AgentRequest.Refused>? {
            guard q["out"] != nil else { return nil }
            return AgentRequest.outputURL(q["out"], extensions: extensions,
                                          overwrite: q["overwrite"] == "1",
                                          saveDirectory: Preferences.shared.saveDirectory)
        }
        // Every verb this build answers to. `version` reports it, and an unknown verb names it in the
        // rejection, so an agent working from a newer copy of the instructions than the app it is
        // talking to finds out immediately instead of waiting for a .done that will never arrive.
        let verbs = ["version", "snip", "sniprect", "record", "ripple", "ink", "arrow",
                     "stop", "pause", "pen", "mic", "speaker", "cancel", "pin", "pins", "settings"]
        #if DEBUG
        print("[url] \(url.absoluteString)")
        #endif
        switch url.host {
        // What am I talking to? The instructions an agent reads can be newer than the app on this
        // machine — the website copy moves with releases, while the copy inside the bundle is
        // whatever the user installed. Without a way to ask, an agent has to guess, and guessing
        // wrong looks exactly like the app being broken.
        case "version":
            let info = Bundle.main.infoDictionary ?? [:]
            let payload: [String: Any] = [
                "app": info["CFBundleName"] as? String ?? "Gigle Pin",
                "version": info["CFBundleShortVersionString"] as? String ?? "?",
                "build": info["CFBundleVersion"] as? String ?? "?",
                "role": PinRole.raw,
                "schemes": PinRole.urlSchemes,
                "verbs": verbs.sorted(),
                "skill": Bundle.main.resourceURL?
                    .appendingPathComponent("pin-screen-recorder/SKILL.md").path ?? "",
                // Whether this copy starts with the machine. Reported because it is the difference
                // between "the hotkey does nothing" being a bug and being a copy that is not running.
                "loginItem": LaunchAtLogin.isEnabled ? "enabled"
                    : (LaunchAtLogin.needsApproval ? "requiresApproval" : "off"),
                "installed": LaunchAtLogin.isInstalled,
                // Transport/data-source of the current output, and whether we judged it a
                // loudspeaker — so a check can assert what the detection decided.
                "outputRoute": AudioRoute.describe(),
                // Which modifier draws on screen. Reported so a check can confirm the app is
                // reading the preference rather than the preference merely existing.
                "inkModifier": Preferences.shared.inkModifier.display,
            ]
            let dst: URL
            switch out(["json"]) {
            case .some(.success(let u)): dst = u
            case .some(.failure(let e)): reject(e.why); return
            case nil: reject("version needs out=<path to a .json>"); return
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                try? FileManager.default.createDirectory(at: dst.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? data.write(to: dst, options: .atomic)
                AgentRequest.markDone(dst, requested: true)
            } else {
                reject("could not write \(dst.path)")
            }
        case "snip":
            beginCapture(q["mode"] == "record" ? .record : .capture)
        case "sniprect":
            // Coordinates are CG (top-left origin) globals, matching `screencapture -R x,y,w,h`.
            guard let x = num("x"), let y = num("y"), let w = extent("w"), let h = extent("h") else {
                                reject("needs x y w h as finite numbers, w and h above zero (CG coordinates, top-left origin)"); return
            }
            let rect = Geometry.nsRect(fromCG: CGRect(x: x, y: y, width: w, height: h))
            // save=1 takes the saving path (to disk, with a toast); the default is clipboard only, and
            // naming out= implies saving
            let destination: URL?
            switch out(["png"]) {
            case .some(.success(let u)): destination = u
            case .some(.failure(let e)): reject(e.why); return
            case nil: destination = nil
            }
            let request = CaptureRequest(rect: rect, save: q["save"] == "1", output: destination)
            Task { await deliver(await request.capture()) }
        case "record":
            guard let x = num("x"), let y = num("y"), let w = extent("w"), let h = extent("h") else {
                                reject("needs x y w h as finite numbers, w and h above zero (CG coordinates, top-left origin)"); return
            }
                        if recordings.isBusy { reject("already recording — pin://stop first"); return }
            let rect = Geometry.nsRect(fromCG: CGRect(x: x, y: y, width: w, height: h))
            let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? Geometry.screenUnderMouse
            let dst: URL?
            switch out(["mp4", "mov"]) {
            case .some(.success(let u)): dst = u
            case .some(.failure(let e)): reject(e.why); return
            case nil: dst = nil
            }
            recordings.startRecording(rect: rect, screen: screen,
                           autoStopAfter: AgentRequest.positive(q["seconds"], limit: 86_400),
                           output: dst)
        // An agent's clicks never enter the system event stream, so Pin's ripple monitor cannot see
        // them — the agent reports the coordinates itself (in CG coordinates).
        case "ripple":
                        guard let x = num("x"), let y = num("y") else { reject("needs x and y (CG coordinates)"); return }
                        guard let ripple = recordings.clickRipple else { reject("not recording, or the click ripple is off"); return }
            if !ripple.ripple(atScreen: Geometry.nsPoint(fromCG: CGPoint(x: x, y: y))) {
                                reject("that point is outside the recorded region")
            }
        // Draw a stroke on the picture during a recording: x1 y1 x2 y2 are **0…1 relative to the
        // recorded region** (y counted downwards). tool=arrow|ellipse|marker, sticky=1 keeps it for the
        // whole clip. For an agent to circle this and point at that.
        case "ink":
            guard let live = recordings.liveAnnotation, let region = recordings.recordingRegion else {
                                reject("not recording, or drawing on screen while recording is off"); return
            }
            guard let fx = num("x1"), let fy = num("y1"), let tx = num("x2"), let ty = num("y2") else {
                                reject("needs x1 y1 x2 y2 (0…1 relative to the recorded region)"); return
            }
            let tool: LiveTool? = switch q["tool"] {
                case "arrow": .arrow; case "ellipse", "circle": .ellipse; case "marker": .marker; default: nil
            }
            let rect = region.rect
            let a = NSPoint(x: rect.width * fx, y: rect.height * (1 - fy))
            let b = NSPoint(x: rect.width * tx, y: rect.height * (1 - ty))
            live.stroke(from: a, to: b, tool: tool, sticky: q["sticky"] == "1")
        case "stop":
            recordings.stopRecording()
        #if DEBUG
        case "interrupt":
            // Simulate the system cutting the stream off, to check the finishing logic still runs
            recordings.debugSimulateInterruption()
        // Set the save directory **through the setter** — exactly the path taken when a user picks a
        // directory in the panel. The app itself has to create that bookmark: security-scoped bookmarks
        // are **scoped to the app**, so one made by an external helper cannot be resolved by Pin, and
        // testing with it only produces a run of false greens that fell back to the path key.
        // Draw a stroke while recording (window coordinates, normalized 0…1). Checks whether the ink
        // reaches the video.
        case "savedir":
            guard let path = q["path"] else { return }
            Preferences.shared.saveDirectory = URL(fileURLWithPath: path)
                        print("[prefs] save directory set to \(Preferences.shared.saveDirectory.path)")
        #endif
        // Pause needs a URL entry point too — without one there is no way to check automatically that
        // the paused stretch really is cut out of the timeline.
        case "pause":
            recordings.recordingHUD?.togglePause()
        // Picking up the pen (continuous drawing mode) gets one as well — whether the second row
        // follows should not be verified by guessing at click coordinates.
        case "pen":
            recordings.liveAnnotation?.togglePersistent()
        // The two audio buttons need an entry as well. **The bug that made this necessary**: tapping
        // the microphone put the explain-and-ask permission card in front of someone who had already
        // granted access, because the button read "this recording has no microphone track" as "no
        // permission" — invisible to every check, since nothing could press that button but a hand.
        case "mic":
            recordings.recordingHUD?.micTapped()
        case "speaker":
            recordings.recordingHUD?.speakerTapped()
        #if DEBUG
        // Turning the login item on and off, **DEBUG only**. Registering a login item is a change to
        // the user's system, and `pin://` cannot tell a test from a web page that navigated here — so
        // the shipping build offers no way to do it except the checkbox in Settings. The check needs
        // it to exercise the real mechanism and then put the state back exactly as it found it.
        #if DEBUG
        case "loginitem":
            guard let on = q["on"] else { reject("loginitem needs on=0 or on=1"); return }
            let want = on == "1"
            let took = LaunchAtLogin.set(want)
            print("[login] requested \(want ? "on" : "off") → took=\(took) state=" +
                  (LaunchAtLogin.isEnabled ? "enabled"
                   : (LaunchAtLogin.needsApproval ? "requiresApproval" : "off")))
        #endif
        // Entry points for the review window's annotation interactions; see ReviewWindow's debug*
        // methods.
        // pin://review?annotate=1&tool=arrow&stroke=0.3,0.3,0.7,0.6&seek=2.5&action=copyFile&dump=1
        case "review":
                        guard let w = recordings.reviewWindow else { print("[review] no review window"); return }
            if let v = q["annotate"] { w.debugAnnotate(on: v == "1") }
            if let t = q["tool"] { w.debugPick(tool: t) }
            if let sk = num("seek") { w.seek(to: Double(sk)) }
            if let st = q["stroke"] {
                let n = st.split(separator: ",").compactMap { Double($0) }
                if n.count == 4 { w.debugStroke(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3])) }
            }
            if let sk = num("seek2") { w.seek(to: Double(sk)) }
            if q["dump"] != nil { w.debugDump() }
            if let a = q["action"] { w.debugAction(a) }
        #endif
        case "cancel":
            overlay.cancel()
        case "pin":
            if let f = q["file"] { pins.pin(fileURL: URL(fileURLWithPath: f)) } else { pins.pinClipboard() }
        case "pins":
            if q["toggle"] != nil { pins.toggleAll() }
            if q["restore"] != nil { pins.restoreInteraction() }
            if q["close"] != nil { pins.closeAll() }
        #if DEBUG
        case "look":
            // Change light/dark and palette **inside the same process**, which is exactly the path the
            // settings interface takes (`Appearance.apply()`). Without that there is no way to check
            // whether switching back to native leaves anything behind — restarting and screenshotting
            // compares a brand-new process, where residue cannot appear at all.
            if let p = q["palette"] { Preferences.shared.palette = p }
            if let a = q["appearance"] { Preferences.shared.appearance = a }
            Appearance.apply()
                        print("[look] palette=\(Preferences.shared.palette) appearance=\(Preferences.shared.appearance)")
        case "rebind":
            // Rebinding had no automated coverage at all — and a hotkey that does not fire is, to the
            // user, a broken app. key/mods are Carbon's keyCode and modifiers (cmd=256 shift=512
            // opt=2048 ctrl=4096).
            guard let k = num("key") else { return }
            let act = HotkeyAction.allCases.first { "\($0)" == (q["action"] ?? "capture") } ?? .capture
            let hk = Hotkey(keyCode: UInt32(k), modifiers: UInt32(num("mods") ?? 0))
            let ok = HotkeyManager.current?.rebind(act, to: hk) ?? false
                        print("[hotkey] rebind \(act) → \(hk.display) \(ok ? "ok" : "refused"); "
                                    + "currently bound: \(HotkeyManager.current?.binding(for: act).display ?? "?")")
        case "mixdown":
            // Flattening two audio tracks into one normally happens only with system audio and the
            // microphone both on. Verifying that by actually opening the microphone would record the
            // room the test machine is in — so it does not. This entry point runs the mixdown against a
            // given file, with the material made by ffmpeg.
            guard let path = q["file"] else { return }
            Task { @MainActor in
                let out = await AudioMixdown.flattenIfNeeded(URL(fileURLWithPath: path))
                                print("[record] mixdown entry point finished → \(out.lastPathComponent)")
            }
        case "permprompt":
            PermissionPrompt.debugShow(q["which"] ?? "screen")
        case "welcome":
            WelcomeWindow.debugShow()
        #endif
        case "settings":
            #if DEBUG
            SettingsWindowController.shared.debugShow(tab: q["tab"])
            #else
            openSettings()
            #endif
        default:
            // Never silent. An agent that sends a verb this build does not have would otherwise get
            // nothing back at all, then wait out a timeout on a file that is never written, and
            // conclude Pin is broken. Naming what this build does support turns that into something
            // it can act on — usually by asking pin://version and adjusting.
            reject("no such command. This build answers to: " + verbs.sorted().joined(separator: ", "))
        }
    }
}
