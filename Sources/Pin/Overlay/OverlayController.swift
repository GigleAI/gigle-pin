// One session from "capture key pressed" to "selection finished": freeze every display, one overlay
// window per screen, collect the result, fade out.
//
// The first press calls begin(.capture); a second within 450ms does not reopen anything, it only
// calls switchToRecord().

import AppKit

/// Timeline marks for the hotkey → selectable path. Absolute uptime in ms, so marks from
/// different files line up without sharing state across actors; the analysis script diffs them.
@inline(__always) func tmark(_ stage: String) {
    #if DEBUG
    print("[t] \(stage) \(Int(ProcessInfo.processInfo.systemUptime * 1000))")
    #endif
}

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
    case save(CaptureResult, to: URL? = nil)
    case pin(CaptureResult)
    /// Record this region. NS global coordinates plus the screen it is on — the recording pipeline
    /// builds an SCStream per screen.
    case record(rect: NSRect, screen: NSScreen)
}

@MainActor
final class OverlayController {
    private var windows: [OverlayWindow] = []
    /// Windows built for every screen before any capture landed, each waiting for its picture.
    private var pending: [CGDirectDisplayID: OverlayWindow] = [:]
    /// Bumped by `finish`. A capture that lands after its session ended is dropped, not shown —
    /// the screens arrive one at a time now, and the user can cancel between them.
    private var session = 0
    private var preparing = false
    private var previousApp: NSRunningApplication?
    private var mouseMonitor: Any?
    private let detector = WindowDetector()
    private var completion: ((OverlayOutcome) -> Void)?
    private(set) var mode: OverlayMode = .capture

    var isActive: Bool { preparing || !windows.isEmpty }

    func begin(mode: OverlayMode, completion: @escaping (OverlayOutcome) -> Void) {
        guard !isActive else {
            // Already open: switch mode rather than reopen.
            if mode == .record { switchToRecord() }
            return
        }
        tmark("begin")
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
        preparing = true
        session += 1
        let mine = session
        Task { await start(session: mine) }
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

    // MARK: - Starting up

    private func start(session mine: Int) async {
        guard session == mine else { return }
        tmark("start")
        let t0 = Date()
        // Read the chrome list here, on the main actor, so the capture never has to hop back to it:
        // while the captures are in flight the main thread is busy building the windows below, and a
        // capture waiting on it would wait exactly as long as that takes.
        let chrome = CaptureChromeRegistry.windowIDs
        async let content = ScreenCapture.shareableContent()

        // Everything the capture is not needed for happens while it runs: the window list the
        // crosshair snaps to, and one window per screen, built empty. Measured 2026-09-11: the list
        // is ~20 ms and each window ~25 ms, and all of it used to queue up behind the capture.
        detector.refresh()
        tmark("windowlist")
        pending = [:]
        for screen in NSScreen.screens {
            pending[screen.displayID] = OverlayWindow(screen: screen, detector: detector)
        }
        tmark("windows")

        // The display under the cursor is captured first and alone. It is the one the user is
        // looking at, and it is the only one that has to be there before they can start; the
        // others follow as they land, a hundred milliseconds or so behind, which nobody can drag
        // to in that time. Alone matters: three captures at once contend for the window server
        // and took 80–250 ms each, against ~75 ms for one on its own (measured 2026-09-11).
        let mouse = NSEvent.mouseLocation
        let firstID = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]).displayID
        do {
            let sc = try await content
            guard session == mine else { return }
            let jobs = ScreenCapture.jobs(in: sc, excludingWindowIDs: chrome)
            guard let firstJob = jobs.first(where: { $0.displayID == firstID }) ?? jobs.first else {
                throw CaptureError.noDisplays
            }
            let first = try await firstJob.run()
            guard session == mine else { return }
            tmark("froze")
            show(first)
            preparing = false
            NSApp.activate(ignoringOtherApps: true)
            tmark("activate")
            focusWindowUnderMouse()
            installMouseRouting()
            tmark("ready")
            #if DEBUG
                        print("[overlay] ready, \(Int(Date().timeIntervalSince(t0) * 1000))ms from keypress to selectable")
            #endif

            let rest = jobs.filter { $0.displayID != firstJob.displayID }
            try await withThrowingTaskGroup(of: DisplaySnapshot.self) { group in
                for job in rest { group.addTask { try await job.run() } }
                for try await shot in group {
                    guard session == mine else { continue }
                    show(shot)
                    // The mouse may have crossed onto this screen while it was still on its way.
                    focusWindowUnderMouse()
                }
            }
            #if DEBUG
                        print("[overlay] froze \(windows.count) screens in \(Int(Date().timeIntervalSince(t0) * 1000))ms")
            #endif
        } catch {
            #if DEBUG
                        print("[overlay] freeze failed \(error)")
            #endif
            if session == mine { finish(.cancelled) }
        }
    }

    /// A capture landed: put it in its window and bring the window up.
    private func show(_ shot: DisplaySnapshot) {
        // A display that appeared between the two lists, or whose geometry changed, gets a window
        // built now — the slow path, but a correct one.
        let w: OverlayWindow
        if let ready = pending.removeValue(forKey: shot.displayID), ready.frame == shot.frame {
            w = ready
        } else {
            w = OverlayWindow(screen: shot.screen, detector: detector)
        }
        w.present(shot)
        tmark("present")
        w.overlay.mode = mode
        w.overlay.onOutcome = { [weak self] outcome in self?.finish(outcome) }
        w.overlay.onSelectionBegan = { [weak self, weak w] in
            guard let w else { return }
            self?.windows.filter { $0 !== w }.forEach { $0.overlay.clearSelection() }
        }
        windows.append(w)
        w.orderFrontRegardless()
        tmark("front")
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
        #if DEBUG
        if case .cancelled = outcome { print("[overlay] cancelled") }
        #endif
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        let ws = windows
        windows = []
        pending = [:]
        preparing = false
        session += 1
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ws.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: {
            Task { @MainActor in ws.forEach { $0.orderOut(nil) } }
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
