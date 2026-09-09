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
    private let recorder = Recorder()
    private var recordingHUD: RecordingHUD?
    private var liveAnnotationBar: LiveAnnotationBar?
    private var recordingFrame: RecordingFrameWindow?
    private var liveAnnotation: LiveAnnotationWindow?
    private var clickRipple: ClickRippleWindow?
    private var reviewWindow: ReviewWindow?
    /// Set once a hotkey has fired successfully — the help entry in the menu hides on the strength of
    /// it.
    static let hotkeyWorkedKey = "hotkeyEverFired"
    /// For re-recording: remember which region was recorded last.
    private var lastRecordRect: (rect: NSRect, screen: NSScreen)?
    private var pendingURLs: [URL] = []
    private var ready = false
    private var autoStopTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.shared.migrateHotkeyDefaultsIfNeeded()
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
        statusItem.onLastRecording = { [weak self] in self?.reopenLastRecording() }
        statusItem.onSettings = { [weak self] in self?.openSettings() }
        statusItem.onHotkeyCheck = { WelcomeWindow.show() }
        statusItem.onStopRecording = { [weak self] in self?.stopRecording() }
        statusItem.pinCount = { [weak self] in self?.pins.count ?? 0 }
        statusItem.pinsHidden = { [weak self] in self?.pins.allHidden ?? false }
        statusItem.isRecording = { [weak self] in self?.recorder.isRecording ?? false }
        statusItem.hotkeyConfirmed = { UserDefaults.standard.bool(forKey: Self.hotkeyWorkedKey) }

        hotkeys = HotkeyManager { [weak self] event in self?.handle(event) }
        hotkeys.register()

        recorder.onInterrupted = { [weak self] error in
            #if DEBUG
                        print("[record] interrupted: \(error.localizedDescription)")
            #endif
            self?.stopRecording()
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
        guard recorder.isRecording || recorder.hasUnfinishedSession else { return .terminateNow }
        // Both the finishing path and the fallback answer, and whichever arrives first wins — replying
        // twice is undefined behaviour, so block it.
        func allowQuit() {
            guard !terminationReplied else { return }
            terminationReplied = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        autoStopTask?.cancel(); autoStopTask = nil
        Task { @MainActor in
            if let url = await recorder.stop() {
                Preferences.shared.lastRecording = url
                #if DEBUG
                                print("[record] finished on quit → \(url.lastPathComponent)")
                #endif
            }
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
            if recorder.isRecording { stopRecording(); return }
            beginCapture(.capture)
        case .record:
            if recorder.isRecording { return }
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
        switch outcome {
        case .cancelled:
            break
        case .openSettings:
            openSettings()
        case .copy(let r):
            Exporter.copy(r)
        case .save(let r):
            // Having saved, it has to say where — silent success and silent failure are the same thing
            // to the person at the keyboard.
            let requested = pendingSaveURL; pendingSaveURL = nil
            if let url = Exporter.save(r, to: requested) {
                Self.markDone(url, requested: requested != nil)
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
            if Preferences.shared.copyAfterCapture { Exporter.copy(r) }
        case .pin(let r):
            pins.pin(r)
            if Preferences.shared.copyAfterCapture { Exporter.copy(r) }
        case .record(let rect, let screen):
            startRecording(rect: rect, screen: screen)
        }
    }

    // MARK: - Recording

    /// The output path an agent gave through `pin://…&out=`. `open` returns immediately and yields no
    /// value, so the caller names the path — it knows the path it chose. A `.done` marker is dropped
    /// beside the file when the recording or save finishes, and polling for that marker beats guessing
    /// from "the file size has not changed for two seconds".
    private var pendingSaveURL: URL?
    private var recordingWasRequested = false

    /// Drop a completion marker beside the output (`demo.mp4` → `demo.mp4.done`), only when an agent
    /// named the path.
    /// What the region was recorded at, so a GIF width in points can be turned into pixels.
    /// The screen we recorded on when we still know it; otherwise the main screen — the same
    /// fallback `ReviewWindow` uses when it cannot be told the region's point size.
    private var recordingScale: CGFloat {
        lastRecordRect?.1.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    /// One sentence describing a finished GIF, and why it is not what was asked for when it is not.
    private func describe(_ o: GIFExporter.Outcome) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(o.bytes), countStyle: .file)
        let base = Lf("gif.made", "%@ · %@ fps · %@",
                      "\(o.width)×\(o.height)", String(format: "%.0f", o.fps), size)
        // The budget reducing the picture is not something the user asked for, so it never happens
        // quietly: a GIF smaller than the region they framed, with no explanation, reads as the app
        // being bad at its job.
        return o.reducedByBudget
            ? base + " · " + L("gif.reduced", "reduced to keep memory in hand")
            : base
    }

    private static func markDone(_ url: URL, requested: Bool) {
        guard requested else { return }
        try? Data().write(to: URL(fileURLWithPath: url.path + ".done"))
    }

    private func startRecording(rect: NSRect, screen: NSScreen, autoStopAfter seconds: Double? = nil,
                                output: URL? = nil) {
        guard !recorder.isRecording else { return }
        reviewWindow?.teardown(); reviewWindow?.close(); reviewWindow = nil
        lastRecordRect = (rect, screen)
        let frame = RecordingFrameWindow(rect: rect)
        let hud = RecordingHUD(near: rect, on: screen)
        // Two meters on the badge, so "the switch is on" and "sound is actually arriving" stop being
        // the same claim. See RecordingHUD.LevelBar.
        recorder.onAudioLevel = { [weak hud] system, mic in hud?.setLevels(system: system, mic: mic) }
        hud.onStop = { [weak self] in self?.stopRecording() }
        hud.onPause = { [weak self] paused in
            paused ? self?.recorder.pause() : self?.recorder.resume()
            // The dot in the menu bar pauses too — both are saying the same thing, and one saying
            // stopped while the other says recording is not acceptable
            self?.statusItem.setRecording(true, paused: paused)
        }
        // The switches on the HUD both mute this recording and write to preferences — what you see on
        // the HUD is what gets recorded, and it will still be that way next time.
        hud.onToggleSystemAudio = { [weak self] on in
            Preferences.shared.recordSystemAudio = on
            self?.recorder.setSystemAudioMuted(!on)
        }
        hud.onToggleMic = { [weak self] on in
            Preferences.shared.recordMicrophone = on
            self?.recorder.setMicMuted(!on)
            if on, Permissions.microphone != .authorized {
                Task { _ = await Permissions.requestMicrophone() }
            }
        }
        frame.orderFrontRegardless()
        recordingFrame = frame
        recordingHUD = hud

        // The annotation layer and the click ripples belong in the video, so they must **not** be
        // excluded; the red frame and the HUD are for the operator, so they are.
        let prefs = Preferences.shared
        if prefs.liveAnnotate {
            let live = LiveAnnotationWindow(frame: rect)
            live.life = prefs.liveAnnotateLife
            // The second row: tool / colour / width. **Only while a pen is in hand** (continuous
            // drawing mode), the same rule as the capture toolbar — the HUD is otherwise a single
            // pill, and someone who never draws never sees this row.
            let bar = LiveAnnotationBar(tool: live.tool, color: live.color, width: live.width)
            bar.onTool = { [weak live] in live?.tool = $0 }
            bar.onColor = { [weak live] in live?.color = $0 }
            bar.onWidth = { [weak live] in live?.width = $0 }
            live.onModeChange = { [weak hud, weak bar] on in
                hud?.setPenActive(on)
                guard let hud, let bar else { return }
                if on {
                    bar.place(under: hud)
                    bar.orderFrontRegardless()
                    hud.addChildWindow(bar, ordered: .above)
                } else {
                    hud.removeChildWindow(bar)
                    bar.orderOut(nil)
                }
            }
            liveAnnotationBar = bar
                        hud.companionBar = bar          // the hint bubble has to dodge it rather than overlap
            // The "drawing now" cue is painted on the red frame, not the annotation layer — the
            // annotation layer goes into the video
            live.onArmedChange = { [weak frame] on in frame?.setArmed(on) }
            live.begin()
            liveAnnotation = live
            hud.onTogglePen = { [weak live] in live?.togglePersistent() }
            hud.onClear = { [weak live] in live?.clear() }
            hud.setPenAvailable(Permissions.accessibility)
        } else {
            hud.setPenAvailable(false)
        }
        #if DEBUG
                print("[record] annotate=\(prefs.liveAnnotate) ripple=\(prefs.recordHighlightClicks) accessibility=\(Permissions.accessibility)")
        #endif
        if prefs.recordHighlightClicks {
            let ripple = ClickRippleWindow(frame: rect)
            ripple.begin()
            clickRipple = ripple
        }

        let url: URL
        if let output {
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            url = output
        } else {
            url = FileNaming.unique(in: prefs.ensureSaveDirectory(), base: "Pin \(Self.stamp())", ext: "mp4")
        }
        recordingWasRequested = output != nil
        let excluded = [CGWindowID(frame.windowNumber), CGWindowID(hud.windowNumber)]

        Task {
            do {
                try await recorder.start(rect: rect, screen: screen, excludingWindowIDs: excluded, output: url)
                hud.start()
                // The button state has to reflect **which tracks this recording actually has**, not
                // what preferences say — the preference can be on while the permission is missing, and
                // then the microphone track does not exist.
                hud.setAudioState(
                    system: (on: prefs.recordSystemAudio, live: recorder.hasSystemAudio),
                    mic: (on: prefs.recordMicrophone, live: recorder.hasMic))
                statusItem.setRecording(true)
                // Nobody discovers "hold ⌥ to draw" unless it is said — it lived only in the pen
                // button's tooltip, and nobody hovers during a recording. So it is shown when recording
                // starts, **for the first three times only**: repeating it after it has been learned is
                // just noise.
                if prefs.liveAnnotate, Permissions.accessibility, prefs.inkTipShown < 3 {
                    prefs.inkTipShown += 1
                    hud.showTip(Lf("hud.inkTip2", "Hold %@ and drag to circle things on screen — let go and the app underneath gets the mouse back", Preferences.shared.inkModifier.display))
                } else {
                    // Only when the ink tip did not take the bubble: one tip at a time, and the ink
                    // one is about a feature nobody would otherwise discover.
                    hud.warnAboutSpeakersIfNeeded()
                }
                if let seconds {
                    autoStopTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(seconds))
                        guard !Task.isCancelled else { return }
                        self?.stopRecording()
                    }
                }
            } catch {
                #if DEBUG
                                print("[record] failed to start \(error)")
                #endif
                frame.orderOut(nil); hud.orderOut(nil)
                liveAnnotation?.end(); liveAnnotation = nil
                clickRipple?.end(); clickRipple = nil
                recordingFrame = nil; recordingHUD = nil
                let alert = NSAlert()
                alert.messageText = L("record.cantStart", "Cannot start recording")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func stopRecording() {
        // After an interruption `isRecording` is already false — going by that alone leaves the HUD,
        // the menu bar dot, the recording frame and the on-screen annotation layer all sitting there,
        // and the file unfinished.
        guard recorder.isRecording || recorder.hasUnfinishedSession else { return }
        autoStopTask?.cancel(); autoStopTask = nil
        recordingFrame?.orderOut(nil)
        recordingFrame = nil
        liveAnnotation?.end(); liveAnnotation = nil
        clickRipple?.end(); clickRipple = nil
        statusItem.setRecording(false)
        let hud = recordingHUD
        recordingHUD = nil
        liveAnnotationBar?.orderOut(nil); liveAnnotationBar = nil
        hud?.showStatus(L("record.processing", "Working…"))

        Task {
            guard let mp4 = await recorder.stop() else {
                hud?.dismiss()
                return
            }
            var final = mp4
            if Preferences.shared.recordFormat == "gif" {
                hud?.showStatus(L("record.toGif", "Converting to GIF…"))
                let gif = mp4.deletingPathExtension().appendingPathExtension("gif")
                do {
                    let out = try await GIFExporter.export(
                        mp4: mp4, to: gif,
                        fps: Preferences.shared.gifFrameRate,
                        maxWidthPoints: Preferences.shared.gifMaxWidth,
                        scale: recordingScale)
                    try? FileManager.default.removeItem(at: mp4)
                    final = gif
                    hud?.showStatus(describe(out))
                } catch {
                    // Clear the half-finished file on failure: ImageIO writes nothing until Finalize,
                    // so an error partway through leaves a 0-byte .gif sitting in the save directory —
                    // an unopenable file the user takes for the result. The MP4 is fine, and it should
                    // be the only thing left.
                    try? FileManager.default.removeItem(at: gif)
                    #if DEBUG
                                        print("[record] GIF failed \(error), keeping the MP4")
                    #endif
                }
            }
            hud?.dismiss()
            #if DEBUG
                        print("[record] done → \(final.path)")
            #endif
            Self.markDone(final, requested: recordingWasRequested)
            showReview(for: final)
        }
    }

    /// Open the review window when recording stops: paused on the last frame, with a scrubber, playback
    /// speed and annotations you can add to the picture, and the action buttons bottom-right. The thing
    /// you most want to confirm the moment recording stops is whether it recorded, not where the file
    /// is.
    /// While the review window is open, Pin becomes an ordinary app (Dock icon, ⌘Tab) and goes back to
    /// the menu bar when it closes.
    ///
    /// A capture tool is a press-and-go, so a permanent Dock icon is wasted space and the app is
    /// normally `LSUIElement`. But a review window is something you sit with and work against, so
    /// **switching away and back is inevitable** — and a menu bar app is in neither ⌘Tab nor the Dock,
    /// so once you switch away the window sinks behind everything and cannot be reached again. It
    /// looks like it disappeared by itself (Tim's diagnosis on 2026-09-05 was right: not a misclick,
    /// but switching away with no way back).
    private func updateActivationPolicy() {
        let wantsRegular = reviewWindow != nil
        let now = NSApp.activationPolicy()
        guard wantsRegular != (now == .regular) else { return }
        NSApp.setActivationPolicy(wantsRegular ? .regular : .accessory)
        if wantsRegular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Reopen the review window for the most recent recording, from the menu bar.
    func reopenLastRecording() {
        if let win = reviewWindow { win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let url = Preferences.shared.lastRecording else { return }
        showReview(for: url)
    }

    private func showReview(for url: URL) {
        // Pass the point size of the original recorded region — the video stores **pixels** (twice the
        // points on Retina), and using that as the window's point size makes it twice as large before
        // being squeezed back, so it no longer matches the region that was framed.
        let win = ReviewWindow(url: url, regionSize: lastRecordRect?.rect.size)
        var target = url
        win.onBurned = { target = $0 }
        win.onAction = { [weak self, weak win] action in
            guard let self, let win else { return }
            Task { @MainActor in
                // With annotations, burn them into the video first and act on the new file — what gets
                // copied should be the annotated one
                if win.hasAnnotations, action != .delete, action != .redo {
                    // Burning takes a few seconds, and that stretch cannot be silent either — otherwise
                    // pressing "copy file" gives silence and then, out of nowhere, "copied", with those
                    // seconds in between unexplained.
                    win.begin(L("review.burning", "Burning your annotations into the video…"), on: action)
                    target = await win.burnIfNeeded { _ in }
                    // On failure `burnIfNeeded` returns the source file unchanged — which means the
                    // user is holding the version **without** the annotations, having just drawn them,
                    // and is unlikely to check frame by frame. Quietly losing a layer of content is far
                    // worse than reporting an error.
                    if target == url {
                        let r = win.frame
                        let screen = NSScreen.screens.first { $0.frame.intersects(r) } ?? Geometry.screenUnderMouse
                        Toast.show(L("err.burnFailed", "The annotations could not be burned in — this is the original recording"), near: r, on: screen)
                    }
                }
                self.handleResult(action, url: target, original: url, window: win)
            }
        }
        win.onClosed = { [weak self, weak win] in
            // Drop the reference once the window closes, or the next recording tears down a window that
            // is already gone
            if self?.reviewWindow === win { self?.reviewWindow = nil }
            self?.updateActivationPolicy()
        }
        reviewWindow = win
        Preferences.shared.lastRecording = url
        updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        win.showAll()
        // A capture goes to the clipboard automatically by default (`copyAfterCapture`), while stopping
        // a recording used to do nothing at all — two main paths in one tool treated differently, and
        // you had to know about ⏎ before you could send what you just recorded.
        // Saying so is not optional: a clipboard that changes without a word is its own small betrayal.
        if Preferences.shared.copyAfterRecord {
            let pb = NSPasteboard.general
            pb.clearContents(); pb.writeObjects([url as NSURL])
            win.markAutoCopied()
            win.say(L("review.autoCopied", "The file is on your clipboard — ⌘V to send it"), on: .copyFile, seconds: 5)
        }
    }

    private func handleResult(_ action: ReviewWindow.Action, url: URL, original: URL, window: ReviewWindow) {
        let pb = NSPasteboard.general
        func close() {
            window.teardown(); window.close(); reviewWindow = nil
        }
        // These take a while to run (converting to GIF, picking key frames), and a failure **has to be
        // reported** — pressing a button, waiting, and having nothing happen is worse than an error,
        // and leaves the user with no idea whether to press it again.
        func failed(_ what: String) {
            window.finish(what, on: action)
            let r = window.frame
            let screen = NSScreen.screens.first { $0.frame.intersects(r) } ?? Geometry.screenUnderMouse
            Toast.show(what, near: r, on: screen)
        }
        // Success has to speak too, and say **where it went**. These used to play a `Pop` and nothing
        // else, which is no feedback at all on a muted machine; and the contact sheet and the GIF each
        // drop a file beside the recording, which the user otherwise never learns about (Tim,
        // 2026-09-06).
        func done(_ what: String) {
            window.finish(what, on: action)
            NSSound(named: "Pop")?.play()
        }
        switch action {
        case .copyFile:
            pb.clearContents(); pb.writeObjects([url as NSURL])
            done(L("review.copiedFile", "File copied — ⌘V into Slack, Mail or Finder to send it"))
        case .copyPath:
            pb.clearContents(); pb.setString(url.path, forType: .string)
            done(Lf("review.copiedPath", "Path copied: %@", readablePath(url)))
        case .contactSheet:
            window.begin(L("review.sheeting", "Picking the key frames and laying them out…"), on: action)
            Task {
                guard let sheet = try? await ContactSheet.make(from: url),
                      let tiff = sheet.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    failed(L("err.exportFailed", "Export failed")); return
                }
                let out = url.deletingPathExtension().appendingPathExtension("frames.png")
                try? png.write(to: out, options: .atomic)
                pb.clearContents(); pb.setData(png, forType: .png)
                done(Lf("review.sheetDone", "Contact sheet copied, ⌘V it straight to an AI · also saved to %@", readablePath(out)))
            }
        case .gif:
            guard url.pathExtension.lowercased() != "gif" else {
                // The early return has to speak as well — otherwise it is the textbook "I pressed it and
                // nothing happened"
                window.say(L("review.alreadyGIF", "This is already a GIF"), on: action); return
            }
            window.begin(L("review.gifing", "Making the GIF — long clips take a moment…"), on: action)
            Task {
                let gif = url.deletingPathExtension().appendingPathExtension("gif")
                guard let out = try? await GIFExporter.export(
                    mp4: url, to: gif,
                    fps: Preferences.shared.gifFrameRate,
                    maxWidthPoints: Preferences.shared.gifMaxWidth,
                    scale: recordingScale) else {
                    // Clear the half-finished file: ImageIO writes nothing until the end, so a failure
                    // partway leaves an unopenable .gif lying beside the recording, and the user takes it
                    // for the result.
                    try? FileManager.default.removeItem(at: gif)
                    failed(L("err.exportFailed", "Export failed")); return
                }
                pb.clearContents(); pb.writeObjects([gif as NSURL])
                done(Lf("review.gifDone2", "GIF copied · %@ · saved to %@", describe(out), readablePath(gif)))
            }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
                        // Finder brings itself to the front, so there is nothing more to say here
        case .redo:
            close()
            // To the Trash, not deleted outright. "Re-record" and "delete" are adjacent buttons on the
            // action bar, and it used to be that "re-record" **deleted permanently** while "delete" went
            // to the Trash — the one that sounds harmless was the irreversible one. Botching a take is
            // routine, and so is hitting the wrong button; both should be recoverable.
            if (try? FileManager.default.trashItem(at: original, resultingItemURL: nil)) == nil {
                                try? FileManager.default.removeItem(at: original)   // fallback when there is no Trash
                                                                    // (an external volume)
            }
            if let (rect, screen) = lastRecordRect {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    self.startRecording(rect: rect, screen: screen)
                }
            }
        case .delete:
            // Note the window's position before closing it — the notice has to appear where it was
            let where_ = window.frame
            close()
            if (try? FileManager.default.trashItem(at: original, resultingItemURL: nil)) == nil {
                // Failing to delete and saying nothing is the worst case: the window closes, the file
                // stays where it was, and the user believes it is gone. Seeing it in the save directory
                // later, they assume they misremembered.
                let screen = NSScreen.screens.first { $0.frame.intersects(where_) } ?? Geometry.screenUnderMouse
                Toast.show(L("err.deleteFailed", "Could not move it to the Trash"),
                           detail: readablePath(original), near: where_, on: screen)
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
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
                Self.markDone(dst, requested: true)
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
            switch out(["png"]) {
            case .some(.success(let u)): pendingSaveURL = u
            case .some(.failure(let e)): reject(e.why); return
            case nil: pendingSaveURL = nil
            }
            let wantsSave = q["save"] == "1" || pendingSaveURL != nil
            let out: (CaptureResult) -> OverlayOutcome = { r in wantsSave ? .save(r) : .copy(r) }
            overlay.captureDirect(rectNS: rect, as: out) { [weak self] in self?.finish($0) }
        case "record":
            guard let x = num("x"), let y = num("y"), let w = extent("w"), let h = extent("h") else {
                                reject("needs x y w h as finite numbers, w and h above zero (CG coordinates, top-left origin)"); return
            }
                        if recorder.isRecording { reject("already recording — pin://stop first"); return }
            let rect = Geometry.nsRect(fromCG: CGRect(x: x, y: y, width: w, height: h))
            let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? Geometry.screenUnderMouse
            let dst: URL?
            switch out(["mp4", "mov"]) {
            case .some(.success(let u)): dst = u
            case .some(.failure(let e)): reject(e.why); return
            case nil: dst = nil
            }
            startRecording(rect: rect, screen: screen,
                           autoStopAfter: AgentRequest.positive(q["seconds"], limit: 86_400),
                           output: dst)
        // An agent's clicks never enter the system event stream, so Pin's ripple monitor cannot see
        // them — the agent reports the coordinates itself (in CG coordinates).
        case "ripple":
                        guard let x = num("x"), let y = num("y") else { reject("needs x and y (CG coordinates)"); return }
                        guard let ripple = clickRipple else { reject("not recording, or the click ripple is off"); return }
            if !ripple.ripple(atScreen: Geometry.nsPoint(fromCG: CGPoint(x: x, y: y))) {
                                reject("that point is outside the recorded region")
            }
        // Draw a stroke on the picture during a recording: x1 y1 x2 y2 are **0…1 relative to the
        // recorded region** (y counted downwards). tool=arrow|ellipse|marker, sticky=1 keeps it for the
        // whole clip. For an agent to circle this and point at that.
        case "ink":
            guard let live = liveAnnotation, let (rect, _) = lastRecordRect else {
                                reject("not recording, or drawing on screen while recording is off"); return
            }
            guard let fx = num("x1"), let fy = num("y1"), let tx = num("x2"), let ty = num("y2") else {
                                reject("needs x1 y1 x2 y2 (0…1 relative to the recorded region)"); return
            }
            let tool: LiveTool? = switch q["tool"] {
                case "arrow": .arrow; case "ellipse", "circle": .ellipse; case "marker": .marker; default: nil
            }
            let a = NSPoint(x: rect.width * fx, y: rect.height * (1 - fy))
            let b = NSPoint(x: rect.width * tx, y: rect.height * (1 - ty))
            live.stroke(from: a, to: b, tool: tool, sticky: q["sticky"] == "1")
        case "stop":
            stopRecording()
        #if DEBUG
        case "interrupt":
            // Simulate the system cutting the stream off, to check the finishing logic still runs
            recorder.debugSimulateInterruption()
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
            recordingHUD?.togglePause()
        // Picking up the pen (continuous drawing mode) gets one as well — whether the second row
        // follows should not be verified by guessing at click coordinates.
        case "pen":
            liveAnnotation?.togglePersistent()
        // The two audio buttons need an entry as well. **The bug that made this necessary**: tapping
        // the microphone put the explain-and-ask permission card in front of someone who had already
        // granted access, because the button read "this recording has no microphone track" as "no
        // permission" — invisible to every check, since nothing could press that button but a hand.
        case "mic":
            recordingHUD?.micTapped()
        case "speaker":
            recordingHUD?.speakerTapped()
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
                        guard let w = reviewWindow else { print("[review] no review window"); return }
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
