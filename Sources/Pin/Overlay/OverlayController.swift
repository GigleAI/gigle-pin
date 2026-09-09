// One session from "capture key pressed" to "selection finished": freeze every display, one overlay
// window per screen, collect the result, fade out.
//
// The first press calls begin(.capture); a second within 450ms does not reopen anything, it only
// calls switchToRecord().

import AppKit

enum OverlayMode {
    case capture
    case record
}

/// Which way the user went when the selection ended.
enum OverlayOutcome {
    case cancelled
    /// The user hit the gear on the toolbar: close the overlay, open settings.
    case openSettings
    case copy(CaptureResult)
    case save(CaptureResult)
    case pin(CaptureResult)
    /// Record this region. NS global coordinates plus the screen it is on — the recording pipeline
    /// builds an SCStream per screen.
    case record(rect: NSRect, screen: NSScreen)
}

@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    private var previousApp: NSRunningApplication?
    private var mouseMonitor: Any?
    private let detector = WindowDetector()
    private var completion: ((OverlayOutcome) -> Void)?
    private(set) var mode: OverlayMode = .capture

    var isActive: Bool { !windows.isEmpty }

    func begin(mode: OverlayMode, completion: @escaping (OverlayOutcome) -> Void) {
        guard !isActive else {
            // Already open: switch mode rather than reopen.
            if mode == .record { switchToRecord() }
            return
        }
        self.mode = mode
        self.completion = completion

        guard Permissions.screenCapture else {
            #if DEBUG
                        print("[overlay] no screen recording permission")
            #endif
            // Calling `requestScreenCapture()` alone is not enough: **the system asks only once**, so
            // after a refusal, pressing F1 does nothing at all, forever — a blank screen with no hint
            // as to why. This is the single easiest place in the app to be written off as broken.
            PermissionPrompt.show(
                atMouse: L("perm.screenFeature", "Capture and recording"),
                why: L("perm.screenWhy",
                       "Pin has to read what is on screen before it can let you select, pin or record any of it.\nThat is the Screen Recording permission — every screenshot tool on macOS needs it, including for still shots; there is no lesser one.\nIt reads the screen only at the moment you press the hotkey."),
                grantTitle: L("perm.openSettings", "Open Settings")) {
                    // Never asked: let the system prompt. Already refused: the system will not ask
                    // again, so it has to be turned on in Settings.
                    Permissions.requestScreenCapture()
                    Permissions.openSystemSettings(.screenCapture)
                }
            finish(.cancelled)
            return
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        detector.refresh()
        Task { await start() }
    }

    /// Cancelled from outside (pin://cancel, or clearing the way before a recording starts).
    func cancel() {
        guard isActive else { return }
        finish(.cancelled)
    }

    func switchToRecord() {
        guard isActive, mode == .capture else { return }
        mode = .record
        windows.forEach { $0.overlay.mode = .record }
        #if DEBUG
                print("[overlay] switched to record mode")
    #endif
    }

    /// Skip the mouse and produce a result for a region directly (for pin://sniprect).
    /// Skips the drag and captures the given region. `outcome` decides what happens next (copy or
    /// save) — the save path had no URL entry point, which meant automation could never cover the
    /// "written to disk" half of it.
    func captureDirect(rectNS: NSRect, as outcome: @escaping (CaptureResult) -> OverlayOutcome = OverlayOutcome.copy,
                       completion: @escaping (OverlayOutcome) -> Void) {
        self.completion = completion
        guard Permissions.screenCapture else { finish(.cancelled); return }
        Task {
            do {
                let shots = try await ScreenCapture.snapshotAllDisplays()
                guard let shot = shots.first(where: { $0.frame.intersects(rectNS) }),
                      let img = shot.crop(toNS: rectNS.intersection(shot.frame))
                else { finish(.cancelled); return }
                finish(outcome(CaptureResult(image: img, screenRect: rectNS.intersection(shot.frame))))
            } catch {
                #if DEBUG
                                print("[overlay] direct capture failed \(error)")
                #endif
                finish(.cancelled)
            }
        }
    }

    // MARK: - Starting up

    private func start() async {
        let t0 = Date()
        do {
            let shots = try await ScreenCapture.snapshotAllDisplays()
            #if DEBUG
                        print("[overlay] froze \(shots.count) screens in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            #endif
            for shot in shots {
                let w = OverlayWindow(snapshot: shot, detector: detector)
                w.overlay.mode = mode
                w.overlay.onOutcome = { [weak self] outcome in self?.finish(outcome) }
                w.overlay.onSelectionBegan = { [weak self, weak w] in
                    guard let w else { return }
                    self?.windows.filter { $0 !== w }.forEach { $0.overlay.clearSelection() }
                }
                windows.append(w)
                w.orderFrontRegardless()
            }
            NSApp.activate(ignoringOtherApps: true)
            focusWindowUnderMouse()
            installMouseRouting()
            #if DEBUG
                        print("[overlay] ready, \(Int(Date().timeIntervalSince(t0) * 1000))ms from keypress to selectable")
            #endif
        } catch {
            #if DEBUG
                        print("[overlay] freeze failed \(error)")
            #endif
            finish(.cancelled)
        }
    }

    /// Multiple displays: whichever screen the mouse crosses onto, that overlay becomes the key
    /// window — otherwise mouseMoved and keyDown keep going to the screen it started on.
    private func installMouseRouting() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.focusWindowUnderMouse()
            return event
        }
    }

    private func focusWindowUnderMouse() {
        let mouse = NSEvent.mouseLocation
        guard let target = windows.first(where: { $0.frame.contains(mouse) }) ?? windows.first,
              !target.isKeyWindow else { return }
        target.makeKeyAndOrderFront(nil)
        target.overlay.syncMouse()
    }

    // MARK: - Finishing

    private func finish(_ outcome: OverlayOutcome) {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        let ws = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ws.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            ws.forEach { $0.orderOut(nil) }
        })
        // Recording and pinning do not need the foreground handed back (the HUD and pin windows
        // float on their own); everything else does.
        switch outcome {
        case .record, .pin, .openSettings: break
        default: previousApp?.activate()
        }
        let c = completion
        completion = nil
        c?(outcome)
    }
}
