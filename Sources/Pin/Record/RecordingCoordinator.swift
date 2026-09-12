import AppKit

/// Coordinates takes and review windows. All per-take state lives in RecordingSession; the app
/// delegate only connects commands and the menu-bar recording indicator.
@MainActor
final class RecordingCoordinator {
    private var active: RecordingSession?
    private var review: ReviewCoordinator?
    private var lastRegion: RecordingRegion?
    private var quitting = false
    var onStateChanged: ((_ recording: Bool, _ paused: Bool) -> Void)?

    var isBusy: Bool { active != nil }
    var isRecording: Bool {
        guard let active else { return false }
        return active.lifecycle.phase == .starting || active.lifecycle.phase == .recording
    }
    var recordingHUD: RecordingHUD? { isRecording ? active?.hud : nil }
    var liveAnnotation: LiveAnnotationWindow? { active?.annotation }
    var clickRipple: ClickRippleWindow? { active?.ripple }
    var recordingRegion: RecordingRegion? { active?.region }
    var reviewWindow: ReviewWindow? { review?.reviewWindow }

    func reopenLastRecording() {
        if let win = reviewWindow { win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let url = Preferences.shared.lastRecording else { return }
        showReview(for: url, region: lastRegion)
    }

    private func showReview(for url: URL, region: RecordingRegion?, pending: Bool = false) {
        review?.close()
        let owner = ReviewCoordinator(region: region)
        owner.onClosed = { [weak self, weak owner] in
            if self?.review === owner { self?.review = nil }
        }
        owner.onRedo = { [weak self] region in
            self?.startRecording(rect: region.rect, screen: region.screen)
        }
        review = owner
        owner.show(for: url, pending: pending)
    }

    func startRecording(rect: NSRect, screen: NSScreen, autoStopAfter seconds: Double? = nil,
                        output: URL? = nil) {
        guard active == nil, !quitting else { return }
        review?.close()
        let region = RecordingRegion(rect: rect, screen: screen)
        lastRegion = region
        let take: RecordingSession
        let prefs = Preferences.shared
        if let output {
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            take = RecordingSession(region: region, output: output, requested: true)
        } else {
            let pending = !prefs.keepRecordings
            let base = "Pin \(Self.stamp())"
            let url = pending ? UnsavedRecordings.next(base: base, ext: "mp4")
                : FileNaming.unique(in: prefs.ensureSaveDirectory(), base: base, ext: "mp4")
            take = RecordingSession(region: region, output: url, requested: false, pending: pending)
        }
        active = take
        let recorder = take.recorder, frame = take.frame, hud = take.hud
        recorder.onInterrupted = { [weak self, weak take] error in
            guard let self, let take, self.active === take else { return }
            #if DEBUG
            print("[record] interrupted: \(error.localizedDescription)")
            #endif
            self.stopRecording()
        }
        // Two meters on the badge, so "the switch is on" and "sound is actually arriving" stop being
        // the same claim. See RecordingHUD.LevelBar.
        recorder.onAudioLevel = { [weak hud] system, mic in hud?.setLevels(system: system, mic: mic) }
        hud.onStop = { [weak self] in self?.stopRecording() }
        hud.onPause = { [weak self] paused in
            paused ? recorder.pause() : recorder.resume()
            // The dot in the menu bar pauses too — both are saying the same thing, and one saying
            // stopped while the other says recording is not acceptable
            self?.onStateChanged?(true, paused)
        }
        // The switches on the HUD both mute this recording and write to preferences — what you see on
        // the HUD is what gets recorded, and it will still be that way next time.
        hud.onToggleSystemAudio = { on in
            Preferences.shared.recordSystemAudio = on
            recorder.setSystemAudioMuted(!on)
        }
        hud.onToggleMic = { on in
            Preferences.shared.recordMicrophone = on
            recorder.setMicMuted(!on)
            if on, Permissions.microphone != .authorized {
                Task { _ = await Permissions.requestMicrophone() }
            }
        }
        frame.orderFrontRegardless()

        // The annotation layer and the click ripples belong in the video, so they must **not** be
        // excluded; the red frame and the HUD are for the operator, so they are.
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
            take.annotationBar = bar
            hud.companionBar = bar          // the hint bubble has to dodge it rather than overlap
            // The "drawing now" cue is painted on the red frame, not the annotation layer — the
            // annotation layer goes into the video
            live.onArmedChange = { [weak frame] on in frame?.setArmed(on) }
            live.begin()
            take.annotation = live
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
            take.ripple = ripple
        }


        let excluded = [CGWindowID(frame.windowNumber), CGWindowID(hud.windowNumber)]
        let startup = take.lifecycle.start {
            try await recorder.start(rect: rect, screen: screen, excludingWindowIDs: excluded, output: take.output)
            // Stop can arrive while ScreenCaptureKit is still starting. Do not resurrect its HUD.
            guard take.lifecycle.phase == .starting else { return }
            hud.start()
            hud.setAudioState(system: (on: prefs.recordSystemAudio, live: recorder.hasSystemAudio),
                              mic: (on: prefs.recordMicrophone, live: recorder.hasMic))
            self.onStateChanged?(true, false)
            if prefs.liveAnnotate, Permissions.accessibility, prefs.inkTipShown < 3 {
                prefs.inkTipShown += 1
                hud.showTip(Lf("hud.inkTip2", "Hold %@ and drag to circle things on screen — let go and the app underneath gets the mouse back", Preferences.shared.inkModifier.display))
            } else {
                hud.warnAboutSpeakersIfNeeded()
            }
            if let seconds {
                take.autoStop = Task { [weak self, weak take] in
                    try? await Task.sleep(for: .seconds(seconds))
                    guard !Task.isCancelled, let take, self?.active === take else { return }
                    self?.stopRecording()
                }
            }
        }
        Task {
            do { try await startup.value }
            catch {
                #if DEBUG
                print("[record] failed to start \(error)")
                #endif
                if active === take { stopRecording() }
                guard !quitting else { return }
                let alert = NSAlert()
                alert.messageText = L("record.cantStart", "Cannot start recording")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @discardableResult
    func stopRecording() -> Task<URL?, Never>? {
        guard let take = active else { return nil }
        let firstStop = take.lifecycle.phase != .stopping
        if firstStop {
            take.endInteraction()
            onStateChanged?(false, false)
            take.hud.showStatus(L("record.processing", "Working…"))
        }
        return take.lifecycle.stop {
            defer {
                take.hud.dismiss()
                if self.active === take { self.active = nil }
            }
            guard let mp4 = await take.recorder.stop() else { return nil }
            var final = mp4
            // Quitting historically keeps the MP4 immediately. A GIF already in progress is joined.
            if !self.quitting, Preferences.shared.recordFormat == "gif" {
                take.hud.showStatus(L("record.toGif", "Converting to GIF…"))
                let gif = mp4.deletingPathExtension().appendingPathExtension("gif")
                do {
                    let out = try await GIFExporter.export(mp4: mp4, to: gif,
                        fps: Preferences.shared.gifFrameRate,
                        maxWidthPoints: Preferences.shared.gifMaxWidth, scale: take.region.scale)
                    try? FileManager.default.removeItem(at: mp4)
                    final = gif
                    take.hud.showStatus(GIFExporter.describe(out))
                } catch {
                    try? FileManager.default.removeItem(at: gif)
                    #if DEBUG
                    print("[record] GIF failed \(error), keeping the MP4")
                    #endif
                }
            }
            AgentRequest.markDone(final, requested: take.requested)
            if self.quitting {
                Preferences.shared.lastRecording = take.pending ? ((try? UnsavedRecordings.keep(final)) ?? final) : final
                #if DEBUG
                print("[record] finished on quit → \(final.lastPathComponent)")
                #endif
            } else {
                #if DEBUG
                print("[record] done → \(final.path)")
                #endif
                self.showReview(for: final, region: take.region, pending: take.pending)
            }
            return final
        }
    }

    func finishForTermination() async {
        quitting = true
        _ = await stopRecording()?.value
    }

    #if DEBUG
    func debugSimulateInterruption() { active?.recorder.debugSimulateInterruption() }
    #endif

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
