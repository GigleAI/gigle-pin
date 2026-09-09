// The two floating windows during a recording: a red frame marking the region being recorded, and
// a small capsule with the elapsed time and a stop button.
// Neither may appear in the video — their windowNumbers are handed to Recorder to exclude.

import AppKit

/// The red frame around the recorded region, transparent to clicks.
@MainActor
final class RecordingFrameWindow: NSWindow, CaptureChrome {
    init(rect: NSRect) {
        let pad: CGFloat = 3
        super.init(contentRect: rect.insetBy(dx: -pad, dy: -pad), styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        contentView = FrameView()
    }

    /// While ⌥ is held and the mouse is taken over, the frame turns amber — "you are drawing now,
    /// not clicking".
    ///
    /// This cue used to be drawn on the annotation layer, and the annotation layer **is recorded**, so
    /// every stroke made the whole picture flash a frame at the viewer. The red frame is already
    /// excluded from the recording, which makes it the right place for it.
    func setArmed(_ on: Bool) {
        (contentView as? FrameView)?.armed = on
    }

    private final class FrameView: NSView {
        var armed = false { didSet { if armed != oldValue { needsDisplay = true } } }
        override func draw(_ dirtyRect: NSRect) {
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            p.lineWidth = 3
            (armed ? NSColor(srgbRed: 1, green: 0.72, blue: 0.2, alpha: 0.95)
                   : NSColor.systemRed.withAlphaComponent(0.9)).setStroke()
            p.stroke()
        }
    }
}

/// Elapsed time and stop. Does not activate the app, so clicking it does not take the foreground.
@MainActor
final class RecordingHUD: NSPanel, CaptureChrome {
    private let label = NSTextField(labelWithString: "00:00")
    private let dot = NSView()
    private let stopButton = NSButton()
    private let penButton = NSButton()
    var onTogglePen: (() -> Void)?
    var onClear: (() -> Void)?
    private let clearButton = NSButton()
    private let pauseButton = NSButton()
    private let speakerButton = NSButton()
    private let micButton = NSButton()
    /// A meter under each of the two audio buttons.
    ///
    /// The most common regret after a demo is finding out the sound was not being picked up, and
    /// until now the HUD could only say the switch was **on** — not that anything was **arriving**
    /// (Tim, 2026-09-08: I want to know whether it is working). An icon cannot show that; a level can.
    ///
    /// Under the icons rather than beside them, so the badge stays exactly as wide as it was — it is
    /// a capsule, and a capsule that changes width while recording is its own distraction. Two
    /// colours as well as two positions: the position says which source, the colour says it again
    /// for anyone glancing rather than reading.
    private let systemLevelBar = LevelBar(warm: false)
    private let micLevelBar = LevelBar(warm: true)

    final class LevelBar: NSView {
        private let fill = CALayer()
        private let warm: Bool
        private var level: CGFloat = 0
        init(warm: Bool) {
            self.warm = warm
            super.init(frame: .zero)
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            layer?.addSublayer(fill)
            layer?.cornerRadius = 1
        }
        required init?(coder: NSCoder) { fatalError() }

        /// **Decibels, not amplitude.** A linear bar makes ordinary sound look like almost nothing:
        /// a system alert peaks around 0.3 of full scale, which draws a third of a bar and reads as
        /// "barely working". On a −60…0 dB scale the same sound fills four fifths of it, which is
        /// what it sounds like. Meters are logarithmic everywhere for this reason.
        func set(_ v: CGFloat) {
            let amp = min(1, max(0, v))
            level = amp <= 0.0001 ? 0 : min(1, max(0, (20 * log10(amp) + 60) / 60))
            needsLayout = true
        }

        override func layout() {
            super.layout()
            // No implicit animation: the level is already smoothed on the way in, and letting Core
            // Animation interpolate on top of that lags the meter behind the sound.
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer?.backgroundColor = BarStyle.fg(0.12).cgColor
            fill.backgroundColor = (warm ? BarStyle.accent : BarStyle.secondary).cgColor
            fill.cornerRadius = 1
            fill.frame = CGRect(x: 0, y: 0, width: bounds.width * level, height: bounds.height)
            CATransaction.commit()
        }
    }
    /// "Does this recording have that audio track?" When it does not, the button is not disabled — it
    /// becomes a way to turn it on. The tracks are fixed the moment recording starts and cannot be
    /// added midway, so it can only take effect next time, and that has to be said out loud.
    private var hasSystemAudio = false
    private var hasMic = false
    /// Once per badge, so switching the microphone off and on again does not re-teach it. A new
    /// recording gets a new badge, which is the reset the user would expect.
    private var speakerWarningShown = false
    private var systemMuted = false
    private var micMuted = false
    var onToggleSystemAudio: ((Bool) -> Void)?
    var onToggleMic: ((Bool) -> Void)?
    /// While paused the seconds do not advance and the dot does not blink — the readout has to match
    /// the length of the video.
    private var paused = false
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?
    var onPause: ((Bool) -> Void)?
    private var timer: Timer?
    private var startedAt = Date()
    var onStop: (() -> Void)?

    init(near rect: NSRect, on screen: NSScreen) {
        let size = NSSize(width: 308, height: 34)
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        // Fixed dark: the .hudWindow material adapts to the desktop behind it, so over a light
        // desktop the whole bar goes white and the white icons blur into it (photographed by Tim,
        // 2026-09-05). The recording HUD has to be legible against any background.
        appearance = BarStyle.appearance
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = BarStyle.pill(height: size.height)
        // Frosted glass ignores cornerRadius and needs its own mask, or a square dark block is left
        // outside the rounded corner
        bg.maskImage = BarStyle.roundedMask(radius: BarStyle.pill(height: size.height))
        bg.layer?.masksToBounds = true
        // A dark scrim over the material, so contrast does not depend on the picture behind it
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = BarStyle.surface.cgColor
        scrim.layer?.cornerRadius = BarStyle.pill(height: size.height)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(scrim)
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: bg.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = BarStyle.fg(0.16).cgColor
        contentView = bg

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = BarStyle.fg()
        label.translatesAutoresizingMaskIntoConstraints = false

        stopButton.bezelStyle = .accessoryBarAction
        stopButton.isBordered = false
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: L("menu.stopRecording", "Stop Recording"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .bold))
        stopButton.contentTintColor = BarStyle.fg()
        stopButton.toolTip = Lf("hud.stop", "Stop recording  %@", Preferences.shared.hotkey(for: .capture).display)
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        for (b, sym, tip, sel) in [
            (penButton, "highlighter", Lf("hud.pen2", "Draw on screen (or just hold %@)", Preferences.shared.inkModifier.display), #selector(penTapped)),
            (clearButton, "eraser", Lf("hud.clear2", "Clear ink  %@C", Preferences.shared.inkModifier.display), #selector(clearTapped)),
            // Pause rather than only stop: switching window or finding a file mid-demo is routine,
            // and without a pause the only option is stopping and losing everything recorded so far.
            (speakerButton, "speaker.wave.2.fill", L("hud.sysAudio", "Computer audio"), #selector(speakerTapped)),
            (micButton, "mic.fill", L("hud.mic", "Microphone (narration)"), #selector(micTapped)),
            (pauseButton, "pause.fill", L("hud.pause", "Pause recording (click again to resume)"), #selector(togglePause)),
        ] as [(NSButton, String, String, Selector)] {
            b.bezelStyle = .accessoryBarAction
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.image = NSImage(systemSymbolName: sym, accessibilityDescription: tip)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            b.contentTintColor = BarStyle.fg()
            b.toolTip = tip
            b.target = self
            b.action = sel
            b.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(b)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 28),
                b.heightAnchor.constraint(equalToConstant: 28),
                b.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            ])
        }
        bg.addSubview(dot); bg.addSubview(label); bg.addSubview(stopButton)
        bg.addSubview(systemLevelBar); bg.addSubview(micLevelBar)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10), dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 14),
            dot.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            // Three groups: audio · pen · transport. Tight within a group, spaced between them.
            speakerButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            micButton.leadingAnchor.constraint(equalTo: speakerButton.trailingAnchor, constant: 2),
            // Hugging the icon above it, inset a little so it reads as belonging to that button
            // rather than underlining the whole group.
            systemLevelBar.leadingAnchor.constraint(equalTo: speakerButton.leadingAnchor, constant: 5),
            systemLevelBar.trailingAnchor.constraint(equalTo: speakerButton.trailingAnchor, constant: -5),
            systemLevelBar.topAnchor.constraint(equalTo: speakerButton.bottomAnchor, constant: -4),
            systemLevelBar.heightAnchor.constraint(equalToConstant: 2),
            micLevelBar.leadingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: 5),
            micLevelBar.trailingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: -5),
            micLevelBar.topAnchor.constraint(equalTo: micButton.bottomAnchor, constant: -4),
            micLevelBar.heightAnchor.constraint(equalToConstant: 2),
            penButton.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 10),
            clearButton.leadingAnchor.constraint(equalTo: penButton.trailingAnchor, constant: 2),
            pauseButton.leadingAnchor.constraint(equalTo: clearButton.trailingAnchor, constant: 10),
            stopButton.leadingAnchor.constraint(equalTo: pauseButton.trailingAnchor, constant: 2),
            stopButton.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            // This line used to be missing — pen and clear got centerY from the loop, and the stop
            // button, built separately, did not. So it sat on the floor of the bar, half a step
            // shorter than its neighbours (Tim, 2026-09-05: is the stop button's height a bit off?).
            stopButton.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 28), stopButton.heightAnchor.constraint(equalToConstant: 28),
        ])

        // Positioned by the same rules as the capture toolbar: **below the selection, right-aligned.**
        // It used to sit above and centred, which was a second set of rules; and above is where the
        // title bar, tabs and menu bar live — the densest part of the screen, and the easiest place
        // to cover something that matters.
        setFrameOrigin(Self.place(size: size, near: rect, on: screen))
    }

    override var canBecomeKey: Bool { true }

    /// Below the selection and right-aligned; flipped above if it does not fit; and if it still does
    /// not, tucked into the bottom-right corner inside the selection.
    /// Shared with the post-recording action bar, so both appear in the same place and the muscle
    /// memory holds.
    static func place(size: NSSize, near rect: NSRect, on screen: NSScreen) -> NSPoint {
        let vf = screen.visibleFrame
        let gap: CGFloat = 10
        var origin = NSPoint(x: rect.maxX - size.width, y: rect.minY - gap - size.height)
        if origin.y < vf.minY + 4 {
            origin.y = rect.maxY + gap
            if origin.y + size.height > vf.maxY - 4 {
                origin.y = rect.minY + gap
                origin.x = rect.maxX - size.width - gap
            }
        }
        origin.x = max(vf.minX + 8, min(origin.x, vf.maxX - size.width - 8))
        // Clamp y into the visible area as well as x.
        //
        // The third fallback is "inside the selection, bottom-right" — and when recording the whole
        // screen, the selection is the whole screen, so that position lands exactly on the Dock (41pt
        // on this machine). The bar's level is above the Dock so nothing covers it, but it **covers
        // the icons at the right end of the Dock** — and someone recording a full-screen demo is
        // precisely the person about to click them. Lifting it to the top of the Dock costs nothing.
        origin.y = max(vf.minY + 8, min(origin.y, vf.maxY - size.height - 8))
        return origin
    }

    func start() {
        startedAt = Date()
        orderFrontRegardless()
        #if DEBUG
        // The HUD and its hint bubble are material windows, and capturing them by window ID produces
        // a white slab — tests have to capture by region, so print the CG (top-left origin)
        // coordinates.
        let hr = Geometry.cgRect(fromNS: frame)
                print("[hud] window CG=\(Int(hr.origin.x)),\(Int(hr.origin.y)),\(Int(hr.width)),\(Int(hr.height))")
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        blink()
    }

    private func tick() {
        // The readout has to match the video's length, so subtract the accumulated pause — the
        // recorder cuts the same stretches out of its timeline.
        let held = pausedTotal + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0)
        let s = Int(Date().timeIntervalSince(startedAt) - held)
        label.stringValue = String(format: "%02d:%02d", max(0, s) / 60, max(0, s) % 60)
    }

    private func blink() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1; a.toValue = 0.25
        a.duration = 0.7; a.autoreverses = true; a.repeatCount = .infinity
        dot.layer?.add(a, forKey: "blink")
    }

    /// A short status shown after stopping ("converting to GIF", "saved").
    /// A short hint **during** a recording: a bubble under the HUD that clears itself after a few
    /// seconds.
    ///
    /// **Do not use `showStatus` for this** — that one is for the finished state, and it stops the
    /// timer and hides the stop button. Calling it mid-recording means the stop button disappears
    /// (written that way by mistake once, 2026-09-05).
    func showTip(_ text: String) {
        tipPanel?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = level
        panel.collectionBehavior = collectionBehavior
        panel.isReleasedWhenClosed = false
        panel.appearance = BarStyle.appearance

        let bg = NSView()
        bg.wantsLayer = true
        bg.layer?.backgroundColor = BarStyle.surface.cgColor
        bg.layer?.cornerRadius = BarStyle.cornerRadius
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = BarStyle.border.cgColor
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: 12)
        l.textColor = BarStyle.fg(0.9)
        l.preferredMaxLayoutWidth = 300
        l.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(l)
        NSLayoutConstraint.activate([
            l.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            l.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            l.topAnchor.constraint(equalTo: bg.topAnchor, constant: 9),
            l.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -9),
        ])
        panel.contentView = bg
        bg.layoutSubtreeIfNeeded()
        let size = NSSize(width: l.fittingSize.width + 24, height: l.fittingSize.height + 18)
        panel.setContentSize(size)
        // With the annotation bar showing, the bubble has to fall below it rather than crowd it
        let bottom = (companionBar?.isVisible == true) ? min(frame.minY, companionBar!.frame.minY) : frame.minY
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: bottom - size.height - 8))
        panel.orderFrontRegardless()
        addChildWindow(panel, ordered: .above)
        tipPanel = panel

        tipTimer?.invalidate()
        tipTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hideTip() }
        }
    }

    private func hideTip() {
        tipTimer?.invalidate(); tipTimer = nil
        guard let p = tipPanel else { return }
        removeChildWindow(p); p.close(); tipPanel = nil
    }

    private var tipPanel: NSPanel?
    private var tipTimer: Timer?

    /// The on-screen annotation bar. It competes for the same space as the hint bubble — both sit
    /// directly under the HUD, so the moment a pen is picked up, "hold ⌥ and drag to draw on screen"
    /// is covered by the annotation bar (only noticed while producing store screenshots on 2026-09-06
    /// 04:36, where a squashed line of text shows in the final image).
    weak var companionBar: NSWindow?

    func showStatus(_ text: String) {
        timer?.invalidate(); timer = nil
        dot.layer?.removeAllAnimations()
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        label.stringValue = text
        stopButton.isHidden = true
        penButton.isHidden = true
        clearButton.isHidden = true
    }

    func dismiss() {
        axWatcher?.invalidate(); axWatcher = nil
        hideTip()
        timer?.invalidate(); timer = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [self] in orderOut(nil) })
    }

    @objc private func stopTapped() { onStop?() }

    /// Toggling audio during a recording means **mute and unmute**, not adding or removing a track.
    /// When this recording has no such track, pressing it turns the track on for the next one and
    /// says so on the spot — without that, the user assumes the press did nothing.
    /// 0…1 for each source. Nothing arriving means nothing drawn — a bar frozen at some value
    /// would be the same lie the switch alone used to tell.
    func setLevels(system: Float, mic: Float) {
        systemLevelBar.set(CGFloat(system))
        micLevelBar.set(CGFloat(mic))
    }

    func setAudioState(system: (on: Bool, live: Bool), mic: (on: Bool, live: Bool)) {
        hasSystemAudio = system.live
        hasMic = mic.live
        // A meter under a muted source, or under a microphone that is not there, would be a strip of
        // furniture that never moves — and a thing that never moves stops being read at all.
        systemLevelBar.isHidden = !system.on
        micLevelBar.isHidden = !mic.on || !mic.live
        if !system.on { systemLevelBar.set(0) }
        if !mic.on || !mic.live { micLevelBar.set(0) }
        systemMuted = !system.on
        micMuted = !mic.on
        refreshAudioButtons()
    }

    private func refreshAudioButtons() {
        for (b, on, live, symOn, symOff) in [
            (speakerButton, !systemMuted, hasSystemAudio, "speaker.wave.2.fill", "speaker.slash.fill"),
            (micButton, !micMuted, hasMic, "mic.fill", "mic.slash.fill"),
        ] as [(NSButton, Bool, Bool, String, String)] {
            // **Changing the icon has to change the accessibility name with it.** It was set once when
            // the button was built, but this refresh replaces the whole image and passes nil for
            // accessibilityDescription, taking the name with it — so the first time a user hits mute,
            // both buttons go mute to VoiceOver as well.
            b.image = NSImage(systemSymbolName: on && live ? symOn : symOff,
                              accessibilityDescription: b.toolTip)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            b.alphaValue = live ? 1 : 0.45
            b.contentTintColor = on && live ? BarStyle.fg() : BarStyle.fg(0.75)
        }
    }

    @objc func speakerTapped() {
        guard hasSystemAudio else {
            onToggleSystemAudio?(true)
            showTip(L("hud.audioNextTime", "Computer audio on — applies to the next recording (a track cannot be added midway)"))
            return
        }
        systemMuted.toggle()
        onToggleSystemAudio?(!systemMuted)
        refreshAudioButtons()
    }

    /// Say — once — that the microphone is about to record the computer's sound a second time.
    ///
    /// **It says, it does not decide.** Turning the computer's audio off on the user's behalf would
    /// be the worse failure of the two: a doubled track sounds hollow but everything is still there,
    /// while a track we silently switched off is missing, and missing is only discovered after the
    /// recording is over. They pressed "microphone"; they did not press "no computer audio".
    ///
    /// Silent unless both sources are on **and** the sound is really coming out of a speaker in the
    /// room — see `AudioRoute`, which stays quiet whenever it cannot tell.
    func warnAboutSpeakersIfNeeded() {
        guard !speakerWarningShown else { return }
        guard !systemMuted, !micMuted else { return }
        guard Preferences.shared.echoTipShown < 3 else { return }
        guard AudioRoute.isLoudspeakerAudible else { return }
        speakerWarningShown = true
        Preferences.shared.echoTipShown += 1
        #if DEBUG
        print("[audio] speaker warning — \(AudioRoute.describe())")
        #endif
        showTip(L("hud.echoTip",
                  "On speakers the microphone records the computer's sound a second time, which comes out hollow — headphones keep the two apart"))
    }

    @objc func micTapped() {
        guard hasMic else {
            // **Permission granted already? Then there is nothing to ask.** `hasMic` says whether
            // *this* recording has a microphone track, which is false whenever the preference was
            // off when it started — including for someone who granted access weeks ago. Reading it
            // as "no permission" put the explain-and-ask card in front of a person who had already
            // said yes, and the card's only button asks for something they had already given
            // (Tim, 2026-09-08). Switch it on for the next recording and say so.
            if Permissions.microphone == .authorized {
                onToggleMic?(true)
                micMuted = false
                showTip(L("hud.micNextTime", "Microphone on — applies to the next recording (a track cannot be added midway)"))
                // The warning is about the *next* recording here, so it must wait for that one —
                // two bubbles at once would collide, and the second would replace the first.
                return
            }
            // Never asked: explain first, then ask. Already refused: the system will not prompt again,
            // so point them at Settings.
            if Permissions.microphone == .denied || Permissions.microphone == .restricted {
                PermissionPrompt.show(
                    anchor: micButton,
                    feature: L("perm.micFeature", "Record narration"),
                    why: L("perm.micDeniedWhy2",
                           "Records your voice along with the screen, only while recording.\nIt was declined once, so macOS will not ask again — switch it on in Settings.\nThe screen and computer audio record fine without it."),
                    grantTitle: L("perm.openSettings", "Open Settings")) {
                        Permissions.openSystemSettings(.microphone)
                    }
                return
            }
            PermissionPrompt.show(
                anchor: micButton,
                feature: L("perm.micFeature", "Record narration"),
                why: L("perm.micWhy2",
                       "Records your voice along with the screen, only while recording.\nThe screen and computer audio record fine without it."),
                grantTitle: L("perm.allowMic", "Allow microphone")) { [weak self] in
                    self?.onToggleMic?(true)
                    self?.showTip(L("hud.micNextTime", "Microphone on — applies to the next recording (a track cannot be added midway)"))
                }
            return
        }
        micMuted.toggle()
        onToggleMic?(!micMuted)
        refreshAudioButtons()
        warnAboutSpeakersIfNeeded()
    }

    @objc func togglePause() {
        paused.toggle()
        if paused {
            pausedAt = Date()
        } else if let at = pausedAt {
            pausedTotal += Date().timeIntervalSince(at)
            pausedAt = nil
        }
        let pauseTip = paused ? L("hud.resume", "Resume recording") : L("hud.pause", "Pause recording (click again to resume)")
        pauseButton.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                                    accessibilityDescription: pauseTip)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        pauseButton.toolTip = pauseTip
        // The dot goes hollow while paused — "not recording right now" at a glance, faster than
        // reading the button icon
        dot.layer?.backgroundColor = paused ? NSColor.clear.cgColor : NSColor.systemRed.cgColor
        dot.layer?.borderWidth = paused ? 2 : 0
        dot.layer?.borderColor = NSColor.systemRed.cgColor
        tick()
        onPause?(paused)
    }
    @objc private func penTapped() {
        if penNeedsAX { explainMissingAX(); return }
        onTogglePen?()
    }
    @objc private func clearTapped() {
        if penNeedsAX { explainMissingAX(); return }
        onClear?()
    }

    /// With continuous drawing on, the pen is marked amber, so it is clear that clicking the screen
    /// now draws rather than operates.
    func setPenActive(_ on: Bool) {
        penButton.contentTintColor = on ? NSColor.systemYellow : BarStyle.fg()
        penButton.layer?.backgroundColor = on ? BarStyle.fg(0.18).cgColor : nil
    }

    /// Without Accessibility, holding ⌥ does not work and the pen button is the only way in.
    /// When the pen and eraser are unavailable they **stay clickable**, and a press jumps straight to
    /// the Accessibility pane in System Settings.
    ///
    /// It used to be `isEnabled = false` — a greyed-out button, no response to a click, and the
    /// explanation only in a tooltip (which takes a second of hover, and nobody hovers mid-recording).
    /// The user sees two grey buttons with no idea why and nowhere to click (Tim, 2026-09-05:
    /// 「为什么有两个按钮是灰的？功能还没做？」 — why are two buttons grey, is the feature
    /// unfinished?). A dead end is worse than a missing feature: a missing feature is at least
    /// visible as missing, while a dead end reads as broken.
    func setPenAvailable(_ available: Bool) {
        penNeedsAX = !available
        // Stay enabled and just draw it faintly — it is still something you can press
        penButton.alphaValue = available ? 1 : 0.45
        clearButton.alphaValue = available ? 1 : 0.45
        let tip = L("hud.penNeedsAX", "Draw on screen while recording — needs Accessibility; click to open it")
        penButton.toolTip = available ? Lf("hud.pen2", "Draw on screen (or just hold %@)", Preferences.shared.inkModifier.display) : tip
        clearButton.toolTip = available ? Lf("hud.clear2", "Clear ink  %@C", Preferences.shared.inkModifier.display) : tip
    }

    private var penNeedsAX = false

    /// Pressing the pen without the permission: **explain what the feature is and why it needs this,
    /// then let them choose.**
    /// Not a jump straight to System Settings — dropping someone into a settings pane without their
    /// knowing what they get out of it only adds confusion, and "Not now" has to be a real option.
    private func explainMissingAX() {
        PermissionPrompt.show(
            anchor: penButton,
            feature: L("perm.drawFeature", "Draw on screen while recording"),
            why: Lf("perm.drawWhy2",
                   "Hold %@ to circle things and draw arrows over what you are recording, then let go and the mouse goes back to the app you are demonstrating.\nThat means watching keys and drags across the whole screen, which needs Accessibility.\nRecording works fine without it — you just lose this.\n(Ticked already and still not working? That grant belongs to an older build — restart Pin.)", Preferences.shared.inkModifier.display),
            grantTitle: L("perm.openSettings", "Open Settings")) { [weak self] in
                Permissions.openSystemSettings(.accessibility)
                // Nothing notifies us once the box is ticked, so it has to be watched — without
                // watching, the user ticks it, comes back to a still-grey button, and concludes it
                // did not work.
                self?.axWatcher?.invalidate()
                self?.axWatcher = Permissions.watchAccessibility { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        setPenAvailable(true)
                        showTip(Lf("hud.axOK2", "Accessibility is on — hold %@ to draw on screen now", Preferences.shared.inkModifier.display))
                    } else {
                        showTip(L("hud.axNeedsRestart",
                                  "Already ticked but still not working? That grant belongs to an older build — restart Pin after this recording"))
                    }
                }
            }
    }

    private var axWatcher: Timer?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onStop?() } else { super.keyDown(with: event) }
    }
}
