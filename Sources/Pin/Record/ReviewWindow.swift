// The review window: recording stops on the last frame, with a scrubber, playback speed,
// annotations you can add to the picture, and an export that burns them in.
//
// Placement and button order match the capture toolbar — the action buttons are bottom-right.

import AppKit
import AVFoundation
import AVKit

@MainActor
final class ReviewWindow: NSWindow, NSWindowDelegate {

    enum Action: String, CaseIterable {
        case save, copyFile, copyPath, contactSheet, gif, reveal, redo, delete

        /// Everything but discarding keeps the take: a copied path or a GIF beside a file that vanishes
        /// when the window closes is a broken promise.
        var keeps: Bool { self != .redo && self != .delete }

        var symbol: String {
            switch self {
            case .save: "square.and.arrow.down"
            case .copyFile: "doc.on.doc"; case .copyPath: "text.quote"
            case .contactSheet: "square.grid.3x3"; case .gif: "photo.stack"
            case .reveal: "folder"; case .redo: "arrow.clockwise"; case .delete: "trash"
            }
        }
        @MainActor var tip: String {
            switch self {
            case .save:         Lf("bar.keepTake", "Keep this take — save to %@   ·   S", readablePath(Preferences.shared.saveDirectory))
            case .copyFile:     L("bar.copyFile", "Copy the file — paste into Slack, Mail or Finder to send it   ·   ⏎")
            case .copyPath:     L("bar.copyPath", "Copy the path — paste into a terminal or Claude Code to reference it   ·   P")
            case .contactSheet: L("bar.sheet", "Contact sheet: one timestamped image, ⌘V it to an AI   ·   K")
            case .gif:          L("bar.gif", "Convert to GIF — bigger, but plays anywhere   ·   G")
            case .reveal:       L("bar.reveal", "Show this file in Finder   ·   F")
            case .redo:         L("bar.redo", "Discard this take and record the same region again   ·   R")
            case .delete:       L("bar.delete", "Move to Trash   ·   ⌫")
            }
        }
    }

    private(set) var url: URL
    /// With "keep every recording" off, the take is in the cache until kept (`UnsavedRecordings`).
    /// `startedPending` says the cache copy exists and has to go when the window closes; `kept` is
    /// where the file went once the user decided.
    let startedPending: Bool
    private(set) var isPending: Bool
    private(set) var kept: URL?
    /// The file to hand out: the kept one once there is one.
    var deliverable: URL { kept ?? url }
    /// Set by Trash / re-record before closing, so the close is not reported as "discarded" as well.
    var closesQuietly = false
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let canvas: ReviewCanvas
    private let scrubber = Scrubber()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let playButton = NSButton()
    private let ratePop = NSPopUpButton()
    private let zoomPop = NSPopUpButton()
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private var actionButtons: [Action: NSButton] = [:]
    private var actionByButton: [ObjectIdentifier: Action] = [:]
    private var timeObserver: Any?
    /// Every control lives in this separate floating bar; the window holds nothing but the picture.
    ///
    /// Why not inside the window: the review window has to be **exactly** the size of the region that
    /// was recorded, and the width the controls need is a different question (scrubber + speed + zoom +
    /// tools + actions comes to six or seven hundred points however it is arranged). With the controls
    /// inside, a recording of a narrow region gets stretched into a wide, empty window, and the picture
    /// is no longer at its original size.
    /// As a floating bar, "wider than the video is fine" (Tim, 2026-09-05), and the picture keeps its
    /// exact dimensions.
    private var bar: ReviewBar!
    /// The style row (colour / width / duration) appears only with a tool in hand — the same rule as
    /// the capture toolbar.
    private var styleRow: NSView!
    private var toolRow: NSView!
    private let annotateToggle = HoverButton()
    private var widthButtons: [NSButton] = []
    private let track = TimedAnnotationTrack()

    var onAction: ((Action) -> Void)?
    private var isClosed = false

    private var duration: Double = 0
    private var rate: Float = 1
    private var tool: AnnotationTool?
    private var style = AnnotationStyle.default
    /// How long a newly drawn stroke stays by default.
    private var inkDuration: Double = 2.5


    /// The video's size **in points**. `naturalSize` gives pixels — twice the points on Retina — so
    /// using it as the window size makes the window twice as large, then "no wider than the screen"
    /// squeezes it back, and it no longer matches the region that was recorded.
    /// (The capture path does not have this problem; it uses `screenRect.size` throughout, in points.)
    private let basePointSize: NSSize
    /// 1× / 2× / 3×, for when a small region is hard to see.
    private var zoom: CGFloat = 1

    /// `regionSize` is the point size of the region that was recorded; without it, convert from pixels
    /// using the screen's scale factor.
    init(url: URL, regionSize: NSSize? = nil, pending: Bool = false) {
        self.url = url
        startedPending = pending
        isPending = pending
        player = AVPlayer(url: url)
        canvas = ReviewCanvas()
        let asset = AVURLAsset(url: url)
        let natural = asset.tracks(withMediaType: .video).first
            .map { $0.naturalSize.applying($0.preferredTransform) } ?? CGSize(width: 960, height: 600)
        let screen = Geometry.screenUnderMouse
        let pts = regionSize ?? NSSize(width: abs(natural.width) / screen.backingScaleFactor,
                                       height: abs(natural.height) / screen.backingScaleFactor)
        basePointSize = pts
        // 1:1 by default — what you see in review should be the size of what you framed. Shrink only if
        // it does not fit.
        let maxW = min(pts.width, screen.visibleFrame.width * 0.9)
        let maxH = min(pts.height, screen.visibleFrame.height * 0.75)
        let k = min(maxW / max(pts.width, 1), maxH / max(pts.height, 1))
        let videoSize = NSSize(width: (pts.width * k).rounded(), height: (pts.height * k).rounded())
                // The real height of the two control rows plus the hint line below the picture. Measured: 92
        // underestimated it by 28 — pinned as a constant, so a change to the control layout has to be
        // reflected here (the picture in the review window has to match the region that was framed).
                let winSize = videoSize   // the controls are all in the bar, so the window is the picture

        // **No `.fullSizeContentView` with a transparent title bar.** That runs the picture right up to
        // the top edge, putting the red close button on top of the picture's top-left corner — and the
        // main thing you do in this window is draw on the picture. One slip closes it, and it looks as
        // though it vanished on its own (Tim, 2026-09-05: the review window seems to disappear easily,
        // I didn't notice what I did and it was gone).
        // With a normal title bar the close button lives outside the picture, and the whole picture is
        // safe to click on.
        super.init(contentRect: NSRect(origin: .zero, size: winSize),
                   styleMask: [.titled, .closable],
                   backing: .buffered, defer: false)
        title = pending ? L("review.titleUnsaved", "Review · not saved yet") : L("review.title", "Review · annotate")
        appearance = BarStyle.appearance
        backgroundColor = BarStyle.surface
        isReleasedWhenClosed = false
        center()

        delegate = self
        build(videoSize: videoSize)
        Task { await load(asset: asset) }
    }

    deinit { }

    // MARK: - Layout

    private func build(videoSize: NSSize) {
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        contentView = root

        playerView.player = player
                playerView.controlsStyle = .none      // our own controls, so the style stays consistent
        playerView.videoGravity = .resizeAspect
        playerView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(playerView)

        canvas.owner = self
        canvas.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(canvas)

        scrubber.onSeek = { [weak self] t in self?.seek(to: t) }
        scrubber.onScrubStart = { [weak self] in self?.pause() }

        playButton.isBordered = false
        playButton.bezelStyle = .accessoryBarAction
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L("review.play2", "Play"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        playButton.contentTintColor = BarStyle.fg()
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.toolTip = L("review.play", "Play / pause  Space")

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        timeLabel.textColor = BarStyle.fg(0.7)

        // Speed and zoom are two compact pop-ups rather than a row of buttons.
        //
        // Spread out they are 7 buttons and 2 labels, turning the row into noise — the capture toolbar
        // is clean precisely because its first row is icons only (Tim, 2026-09-05: the capture bar is
        // fine and simple; why does the one after recording feel cluttered?). And both are **rarely**
        // used: nine playbacks out of ten are at 1×, so there is no case for either occupying a
        // permanent row.
        // 0.2× rather than 0.25×: one character shorter, so the pop-up is a notch narrower, and slow
        // motion is for lining up a moment, where 0.2 and 0.25 are interchangeable.
        style(ratePop, items: ["0.2×", "0.5×", "1×", "2×"], select: 2,
              action: #selector(pickRate(_:)),
              tip: L("review.rate", "Playback speed — slow it down to line a mark up with the moment"))
        style(zoomPop, items: ["1×", "2×", "3×"], select: 0,
              action: #selector(pickZoom(_:)),
              tip: L("review.zoom", "Enlarge the picture — for when the region you recorded is small"))

        // Annotation tools (only the four most used — review annotation has to be quick)
        let toolStack = NSStackView()
        toolStack.spacing = 1
        // Order = how often they are reached for. Arrow and ellipse first: what a mouse is good at is
        // "point at this" and "circle that". The highlighter is designed for running along a line of
        // text — a stylus movement — and dragging one with a mouse comes out shaky and ugly.
        for t in [AnnotationTool.arrow, .ellipse, .rect, .marker, .text] {
            let b = HoverButton()
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            // An icon button's VoiceOver name can only come from here — the title is empty, and a
            // toolTip is "help" rather than a name in accessibility, so it would announce a bare
            // "button".
            b.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            // Without clearing the title, a symbol that fails to load exposes the button's default
            // title (the text tool showed up as 「格式」)
            b.title = ""
            b.imagePosition = .imageOnly
            b.contentTintColor = BarStyle.fg()
            b.hint = "\(t.title) · \(t.how)"
            b.onHover = { [weak self] in self?.showHint($1, under: $0) }
            b.target = self
            b.action = #selector(pickTool(_:))
            b.tag = t.rawValue
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            toolButtons[t] = b
            toolStack.addArrangedSubview(b)
        }
        // The style row: colour, width and how long it stays. Shown only with a tool in hand — "decide
        // what to draw, then how it looks" — and without one the whole row is noise.
        let styleStack = NSStackView()
        styleStack.spacing = 4
        styleStack.addArrangedSubview(caption(L("review.colorLabel", "Color")))
        for (i, c) in AnnotationStyle.palette.prefix(8).enumerated() {
            let b = NSButton()
            BarStyle.styleSwatch(b, color: c, selected: i == 0)
            b.target = self; b.action = #selector(pickColor(_:)); b.tag = i
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: BarStyle.swatchSize).isActive = true
            b.heightAnchor.constraint(equalToConstant: BarStyle.swatchSize).isActive = true
            swatchButtons.append(b)
            styleStack.addArrangedSubview(b)
        }
        styleStack.addArrangedSubview(divider())
        styleStack.addArrangedSubview(caption(L("review.widthLabel", "Width")))
        for (i, w) in AnnotationStyle.widths.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(pickWidth(_:)))
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 4
            b.image = dotImage(diameter: 4 + w)
            b.imagePosition = .imageOnly
            b.contentTintColor = BarStyle.fg()
            b.tag = i
            b.toolTip = L("review.width", "Line width")
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            widthButtons.append(b)
            styleStack.addArrangedSubview(b)
        }
        styleStack.addArrangedSubview(divider())
        styleStack.addArrangedSubview(caption(L("review.lifeLabel", "Stays")))
        // **Same `style()` as speed and zoom.** This one was written inline, so it kept the system aqua
        // white rounded frame, the default type size and the default tint — three pop-ups on one bar,
        // two of them borderless icon-style and this one a `<select>` from a web form.
        // (What Tim said about that white frame on 2026-09-05 was 「好丑啊，好丑啊」 — it's ugly, it's
        //  ugly. That round fixed speed and zoom and missed this one; and the third row had never been
        //  captured, so nobody saw it.)
        let lifePop = NSPopUpButton()
        style(lifePop, items: ["1.0s", "2.5s", "5.0s", L("review.lifeForever", "Whole clip")],
              select: 1, action: #selector(pickInkLife(_:)),
              tip: L("review.life", "How long a new stroke stays on screen"))
        styleStack.addArrangedSubview(lifePop)
        styleRow = styleStack

        let actionStack = NSStackView()
        actionStack.spacing = 1
        for a in Action.allCases {
            if a == .redo {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = BarStyle.fg(0.15).cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.widthAnchor.constraint(equalToConstant: 1).isActive = true
                sep.heightAnchor.constraint(equalToConstant: 16).isActive = true
                actionStack.addArrangedSubview(sep)
            }
            let b = HoverButton()
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            b.wantsLayer = true
            b.layer?.cornerRadius = 5
            b.image = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.tip)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            b.title = ""
            b.imagePosition = .imageOnly
            b.contentTintColor = a == .delete ? BarStyle.danger : BarStyle.fg()
            b.hint = a.tip
            b.onHover = { [weak self] in self?.showHint($1, under: $0) }
            b.target = self; b.action = #selector(actionTapped(_:))
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            actionButtons[a] = b
            actionByButton[ObjectIdentifier(b)] = a
            // Nothing to save when every take is kept as it stops — the stack closes the gap.
            if a == .save { b.isHidden = !isPending }
            actionStack.addArrangedSubview(b)
        }

        // ---- Four rows in one bar ----
        // 1  ▶ ──scrubber── time      the scrubber takes the full width and shares with nothing
        // 2  speed zoom tools ‖ actions   "how to watch and draw" left, "what to do with it" right
        // 3  colour width duration    only with a tool in hand
        // 4  hint                     replaces the default line while hovering a button
        // The way into annotation is a pen. Pressing it opens the tool row — exactly the capture
        // toolbar's rule: the first row is actions, and styles and tools appear on demand (Tim,
        // 2026-09-05: one row by default, please).
        annotateToggle.isBordered = false
        annotateToggle.bezelStyle = .accessoryBarAction
        annotateToggle.wantsLayer = true
        annotateToggle.layer?.cornerRadius = 5
        annotateToggle.image = NSImage(systemSymbolName: "pencil.tip.crop.circle",
                                       accessibilityDescription: L("review.annotate2", "Annotate"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        annotateToggle.title = ""
        annotateToggle.imagePosition = .imageOnly
        annotateToggle.contentTintColor = BarStyle.fg()
        annotateToggle.hint = L("review.annotate", "Annotate — opens the pens and colors")
        annotateToggle.onHover = { [weak self] in self?.showHint($1, under: $0) }
        annotateToggle.target = self
        annotateToggle.action = #selector(toggleAnnotate)
        annotateToggle.translatesAutoresizingMaskIntoConstraints = false
        annotateToggle.widthAnchor.constraint(equalToConstant: 28).isActive = true
        annotateToggle.heightAnchor.constraint(equalToConstant: 24).isActive = true

        scrubber.setContentHuggingPriority(.init(1), for: .horizontal)
        scrubber.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        // The scrubber **has the top row to itself** and takes the bar's full width — it is the only
        // control that gets better the longer it is, and squeezed in with a row of icons it is reduced
        // to a stub. But it stays in **the same** bar: two floating windows would mean two borders, two
        // shadows and a strip of desktop showing between them, and since they operate on the same thing,
        // splitting them into two floating objects suggests they are unrelated (Tim asked, 2026-09-05).
        let row1 = NSStackView(views: [playButton, scrubber, timeLabel])
        row1.spacing = 8

        // The second row is icons only: speed and zoom │ the pen ‖ actions. The action group is pinned
        // right and never moves.
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        gap.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let speedIcon = icon("gauge.with.needle")
        let zoomIcon = icon("plus.magnifyingglass")
        // The gear: the capture toolbar has one and this bar had been missing it (spotted by Tim,
        // 2026-09-05). Placed beside the pen and outside the action group — it is an app-level setting,
        // not something done to this file.
        let gear = HoverButton()
        gear.isBordered = false
        gear.bezelStyle = .accessoryBarAction
        gear.wantsLayer = true
        gear.layer?.cornerRadius = 5
        gear.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L("menu.settings", "Settings…"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        gear.title = ""
        gear.imagePosition = .imageOnly
        gear.contentTintColor = BarStyle.fg()
        gear.hint = L("review.settings", "Settings — save location, frame rate, hotkeys  ⌘,")
        gear.onHover = { [weak self] in self?.showHint($1, under: $0) }
        gear.target = self
        gear.action = #selector(openSettings)
        gear.translatesAutoresizingMaskIntoConstraints = false
        gear.widthAnchor.constraint(equalToConstant: 28).isActive = true
        gear.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let row2 = NSStackView(views: [
            speedIcon, ratePop, zoomIcon, zoomPop,
            divider(), annotateToggle, gear, gap, actionStack,
        ])
        row2.spacing = 10
        // An icon sits tight against its own pop-up, with space only between groups — spaced evenly,
        // "⏱ and 1×" looks as close as "1× and 🔍", and they stop reading as two groups.
        row2.setCustomSpacing(3, after: speedIcon)
        row2.setCustomSpacing(3, after: zoomIcon)

        // Tools and styles on one row, shown only with a pen in hand
        let row3 = NSStackView(views: [toolStack, divider(), styleRow])
        row3.spacing = 10
        toolRow = row3
        toolRow.isHidden = true
        // Explanations go through HintBubble (a bubble under the button); the bar no longer has that row

        bar = ReviewBar(rows: [row1, row2, row3])

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: root.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            canvas.topAnchor.constraint(equalTo: playerView.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: playerView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: playerView.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: playerView.bottomAnchor),
        ])
        applyZoom()
    }
    private var swatchButtons: [NSButton] = []

    /// The small icon in front of a pop-up. **Its size and shade have to match the tool and action
    /// icons** — one second icon style anywhere on the bar and the whole thing falls apart.
    private func icon(_ name: String) -> NSImageView {
        let v = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? NSImage())
        v.contentTintColor = BarStyle.fg(0.55)
        // Purely decorative; the pop-up beside it is the control — without marking it, VoiceOver
        // announces an extra unnamed "image"
        v.setAccessibilityElement(false)
        return v
    }

    /// The speed and zoom pop-ups. **The border has to go**: the system aqua white rounded frame is the
    /// loudest thing on a dark bar of monochrome icons, and reads as a select in a web form (Tim,
    /// 2026-09-05: it's ugly). Borderless, it is just a piece of text the same colour as everything
    /// else, and pressing it opens the menu.
    private func style(_ pop: NSPopUpButton, items: [String], select: Int,
                       action: Selector, tip: String) {
        pop.addItems(withTitles: items)
        pop.selectItem(at: select)
        pop.target = self; pop.action = action
        pop.isBordered = false
        pop.font = .systemFont(ofSize: 12, weight: .medium)
        pop.contentTintColor = BarStyle.fg()
        pop.toolTip = tip
        // **Do not pin the width**: pinned, the arrow sits against the right edge with the number on the
        // left and a gap in between. Let it fit the widest item, and the width then stops jumping with
        // the selection.
        pop.sizeToFit()
    }

    private func caption(_ t: String) -> NSTextField {
        let l = NSTextField(labelWithString: t)
        l.font = .systemFont(ofSize: 10)
        l.textColor = BarStyle.secondary
        return l
    }

    /// Two groups of numbers (speed and zoom) side by side are easy to confuse; a rule separates them.
    private func divider() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = BarStyle.fg(0.15).cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return v
    }

    // MARK: - Playback

    private func load(asset: AVURLAsset) async {
        let end = (try? await asset.load(.duration)) ?? .zero
        guard !isClosed else { return }
        let d = CMTimeGetSeconds(end)
        duration = d.isFinite ? d : 0
        scrubber.duration = duration
        // Stop on the last frame — of what you just recorded, the last frame is the result
        player.seek(to: end, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
        scrubber.current = duration
        updateTimeLabel(duration)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 30, preferredTimescale: 600), queue: .main) { [weak self] t in
                Task { @MainActor in self?.tick(CMTimeGetSeconds(t)) }
            }
    }

    private func tick(_ t: Double) {
        guard !isClosed else { return }
        scrubber.current = t
        canvas.time = t
        updateTimeLabel(t)
        if player.rate == 0 {
            playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L("review.play2", "Play"))?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        }
    }

    private func updateTimeLabel(_ t: Double) {
        timeLabel.stringValue = "\(fmt(t)) / \(fmt(duration))"
    }
    private func fmt(_ s: Double) -> String {
        let v = max(0, s)
        return String(format: "%d:%04.1f", Int(v) / 60, v.truncatingRemainder(dividingBy: 60))
    }

    @objc private func togglePlay() {
        if player.rate == 0 {
            if scrubber.current >= duration - 0.05 { seek(to: 0) }
            player.rate = rate
            playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: L("review.pause", "Pause"))?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        } else {
            pause()
        }
    }

    private func pause() {
        player.rate = 0
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: L("review.play2", "Play"))?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    }

    func seek(to t: Double) {
        let clamped = max(0, min(t, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        scrubber.current = clamped
        canvas.time = clamped
        updateTimeLabel(clamped)
    }

    @objc private func pickZoom(_ sender: NSPopUpButton) {
        zoom = CGFloat(sender.indexOfSelectedItem + 1)
        applyZoom()
    }

    private func applyZoom() {
        guard let screen = self.screen ?? NSScreen.main else { return }
        let want = NSSize(width: basePointSize.width * zoom, height: basePointSize.height * zoom)
        // Clamp when zooming past the screen — better to show it incompletely than to throw the window
        // out of the visible area. Leave room in the height for the bar below, or zooming pushes the bar
        // off screen.
        let k = min(1, min(screen.visibleFrame.width * 0.94 / max(want.width, 1),
                           (screen.visibleFrame.height - ReviewBar.reserve) / max(want.height, 1)))
        let vs = NSSize(width: (want.width * k).rounded(), height: (want.height * k).rounded())
        let f = frame
        var r = frameRect(forContentRect: NSRect(origin: .zero, size: vs))
        r.origin = NSPoint(x: f.midX - r.width / 2, y: f.maxY - r.height)
        setFrame(r, display: true, animate: true)
        placeBar()
    }

    @objc private func pickRate(_ sender: NSPopUpButton) {
        rate = [0.2, 0.5, 1, 2][sender.indexOfSelectedItem]
        if player.rate != 0 { player.rate = rate }
    }

    // MARK: - Annotation

    @objc private func openSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func toggleAnnotate() {
        let on = toolRow.isHidden
        toolRow.isHidden = !on
        annotateToggle.layer?.backgroundColor = on ? BarStyle.fg(0.2).cgColor : nil
        if !on, tool != nil { tool = nil; canvas.tool = nil; refreshToolButtons() }
        placeBar()
    }

    /// The hint bubble sits directly under the hovered button. Not the row inside the bar any more:
    /// once the bar widens with the video, a line pinned bottom-left is nowhere near the buttons on the
    /// right, and that row appearing and disappearing makes the bar jump in height.
    private func showHint(_ text: String?, under button: NSView) {
        if let text { HintBubble.show(text, under: button) } else { HintBubble.hide() }
    }

    private func refreshToolButtons() {
        for (k, b) in toolButtons {
            b.layer?.backgroundColor = k == tool ? BarStyle.fg(0.2).cgColor : nil
            b.contentTintColor = k == tool ? style.color : BarStyle.fg()
        }
    }

    @objc private func pickTool(_ sender: NSButton) {
        let t = AnnotationTool(rawValue: sender.tag)
        tool = (tool == t) ? nil : t
        for (k, b) in toolButtons {
            b.layer?.backgroundColor = k == tool ? BarStyle.fg(0.2).cgColor : nil
            b.contentTintColor = k == tool ? style.color : BarStyle.fg()
        }
        canvas.tool = tool
        if let t = tool {
            HintBubble.flash(Lf("review.toolHint", "%@: draw on the frame; this mark shows from %@ for %.1f seconds",
                                t.title, fmt(scrubber.current), inkDuration), under: annotateToggle)
        } else {
            HintBubble.hide()
        }
    }

    @objc private func pickColor(_ sender: NSButton) {
        style.color = AnnotationStyle.palette[sender.tag]
        canvas.style = style
        for (i, b) in swatchButtons.enumerated() {
            BarStyle.styleSwatch(b, color: AnnotationStyle.palette[i], selected: i == sender.tag)
        }
        if let t = tool { toolButtons[t]?.contentTintColor = style.color }
    }

    @objc private func pickWidth(_ sender: NSButton) {
        style.lineWidth = AnnotationStyle.widths[sender.tag]
        canvas.style = style
        for (i, b) in widthButtons.enumerated() {
            b.layer?.backgroundColor = i == sender.tag
                ? BarStyle.fg(0.2).cgColor : nil
        }
    }

    @objc private func pickInkLife(_ sender: NSPopUpButton) {
        inkDuration = [1.0, 2.5, 5.0, 9999.0][sender.indexOfSelectedItem]
    }

    /// The filled dots on the width buttons — showing the width beats writing "2 / 4 / 7".
    private func dotImage(diameter d: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        BarStyle.fg().setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard let a = actionByButton[ObjectIdentifier(sender)] else { return }
        onAction?(a)
    }

    // ── Pressing something has to produce feedback (triggered from `ReviewCoordinator.handleResult`, which
    //    is what knows whether it worked and where the file went) ──
    // These actions used to play a `Pop` and nothing else: on a muted machine that is no feedback at
    // all, and converting to GIF or picking key frames runs for seconds with nothing moving on screen,
    // so the natural move is to press again (Tim, 2026-09-06: 「有些按下去没反馈，用户会很闷」 — some
    // of these give no feedback, which leaves the user stuck).
    // Success has to speak too — failure had a Toast and success was silent, and to the user those are
    // the same thing.

    /// An instant action (copying): one sentence and done.
    func say(_ text: String, on a: Action, seconds: TimeInterval = 3) {
        guard !isClosed, let b = actionButtons[a] else { return }
        HintBubble.flash(text, under: b, seconds: seconds)
    }

    /// A slow action starting: grey the button out (against double presses) and pin a bubble that hover
    /// cannot displace.
    func begin(_ text: String, on a: Action) {
        guard !isClosed, let b = actionButtons[a] else { return }
        b.isEnabled = false
        HintBubble.pin(text, under: b)
    }

    /// Finished (called on success and failure alike): restore the button and say what happened.
    func finish(_ text: String, on a: Action, seconds: TimeInterval = 5) {
        guard !isClosed, let b = actionButtons[a] else { return }
        b.isEnabled = true
        HintBubble.unpin()
        HintBubble.flash(text, under: b, seconds: seconds)
    }

    /// The take is now in the save directory: drop the Save button and the "not saved" title.
    func markKept(at dst: URL) {
        kept = dst
        isPending = false
        actionButtons[.save]?.isHidden = true
        title = L("review.title", "Review · annotate")
        placeBar()
    }

    /// The canvas finished a stroke; store it on the track with the current time.
    fileprivate func commit(_ stroke: TimedStroke) {
        var s = stroke
        s.start = scrubber.current
        s.duration = inkDuration
        s.number = track.nextNumber
        track.add(s)
        canvas.strokes = track.strokes
        scrubber.marks = track.timeline
        #if DEBUG
                print("[review] stroke added \(s.tool) start=\(String(format: "%.2f", s.start)) dur=\(s.duration), \(track.strokes.count) total")
        #endif
        // The automatic copy when recording stopped took a version **without** annotations. Without a
        // reminder the user draws and then hits ⌘V, sending the version with no ink — and having just
        // drawn it, they are unlikely to check.
        let stale = autoCopied ? L("review.staleClipboard", " · the copy on your clipboard has no annotations; ⏎ to copy again") : ""
        HintBubble.flash(Lf("review.added", "Added — shows from %@ for %.1f seconds · ⌘Z undoes · burned in on export",
                            fmt(s.start), s.duration) + stale, under: annotateToggle)
    }

    fileprivate var currentTime: Double { scrubber.current }
    fileprivate var currentStyle: AnnotationStyle { style }
    fileprivate var currentTool: AnnotationTool? { tool }

    var hasAnnotations: Bool { !track.isEmpty }

    /// A copy was already made for the user when recording stopped (the one without annotations). Used
    /// to warn that the clipboard is stale once they start drawing.
    private var autoCopied = false
    func markAutoCopied() { autoCopied = true }


    /// Export a new file with the annotations burned in; without annotations, return the original.
    func burnIfNeeded(progress: @escaping @Sendable (Double) -> Void) async -> URL {
        guard !track.isEmpty else { return url }
        // Beside the kept file, not the cache copy, so it is still there after the window closes
        let out = deliverable.deletingPathExtension().appendingPathExtension("annotated.mp4")
        do {
            try await AnnotationBurner.burn(source: url, track: track.strokes, to: out, progress: progress)
            #if DEBUG
                        print("[review] burn-in finished → \(out.lastPathComponent)")
            #endif
            return out
        } catch {
            #if DEBUG
                        print("[review] burn-in failed \(error)")
            #endif
            return url
        }
    }

    // MARK: - Keyboard

    override var canBecomeKey: Bool { true }

    /// The bar is docked to the bottom edge of the picture and horizontally centred, following the
    /// window as it moves and zooms.
    /// **It may be wider than the picture** — the width of the controls and the width of the recorded
    /// region are unrelated, and crowding the controls to accommodate a narrow region only makes both
    /// look bad.
    private func placeBar() {
        let want = bar.naturalSize
        let w = max(want.width, frame.width)
        let size = NSSize(width: w, height: want.height)
        let gap: CGFloat = 8
        var origin = NSPoint(x: frame.midX - w / 2, y: frame.minY - gap - size.height)
        if let vis = (screen ?? NSScreen.main)?.visibleFrame {
            // No room below: flip above the picture; still no room: against the bottom of the screen
            if origin.y < vis.minY { origin.y = min(frame.maxY + gap, vis.maxY - size.height) }
            origin.x = min(max(origin.x, vis.minX + 4), vis.maxX - w - 4)
        }
        bar.setContentSize(size)
        bar.setFrameOrigin(origin)
    }

    override func setFrame(_ f: NSRect, display: Bool) {
        super.setFrame(f, display: display)
        placeBar()
    }

    /// The action keys have to be caught before `AVPlayerView` sees them.
    ///
    /// The player claims the J/K/L transport shortcuts, so `K` never reaches the window's `keyDown` —
    /// P, G, F and ⏎ from the same batch all arrive, and only K goes quietly missing, doing nothing and
    /// reporting nothing.
    /// (2026-09-06 09:1x: only visible after adding a log line to keyDown — code=40 never appeared.)
    ///
    /// So these keys go through `sendEvent` and are handled before the event reaches the responder
    /// chain. Not while typing in a text field, though — there, K should be a letter.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           !(firstResponder is NSText),
           !event.modifierFlags.contains(.command),
           let a = Self.actionKey(event) {
            onAction?(a)
            return
        }
        super.sendEvent(event)
    }

    private static func actionKey(_ e: NSEvent) -> Action? {
        switch (e.keyCode, e.charactersIgnoringModifiers?.lowercased() ?? "") {
                case (36, _), (76, _): .copyFile        // ⏎ / keypad ⏎
        case (51, _):          .delete          // ⌫
        case (_, "s"):         .save
        case (_, "p"):         .copyPath
        case (_, "k"):         .contactSheet
        case (_, "g"):         .gif
        case (_, "f"):         .reveal
        case (_, "r"):         .redo
        default: nil
        }
    }

    override func keyDown(with e: NSEvent) {
        let cmd = e.modifierFlags.contains(.command)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (e.keyCode, ch, cmd) {
                case (49, _, _): togglePlay()                         // space
                case (123, _, _): seek(to: scrubber.current - 1.0 / 30)  // ←  frame by frame
        case (124, _, _): seek(to: scrubber.current + 1.0 / 30)
        case (_, "z", true):
            track.undo(); canvas.strokes = track.strokes; scrubber.marks = track.timeline
        case (53, _, _): pause()
        default: super.keyDown(with: e)
        }
    }

    #if DEBUG
    // MARK: - Test entry points (DEBUG only)
    //
    // The review window's annotation interactions cannot be automated with a real mouse: the window may
    // be on another Space, and a synthesised system-level mouse event lands on whatever is on the user's
    // current screen (2026-09-06, very nearly clicking into someone else's window). So NSEvents are
    // built **inside the window** and fed straight to the canvas's mouseDown/Dragged/Up — the same code
    // path, without ever touching the user's screen.
    // Coordinates are normalized 0…1 with y downwards (the way a person reads a picture; the canvas
    // does not flip).
    func debugAnnotate(on: Bool) { if toolRow.isHidden == on { toggleAnnotate() } }
    func debugPick(tool name: String) {
        let map: [String: AnnotationTool] = ["arrow": .arrow, "ellipse": .ellipse, "rect": .rect, "marker": .marker, "text": .text]
        guard let t = map[name], let b = toolButtons[t] else { return }
        if tool != t { pickTool(b) }
    }
    func debugStroke(from a: CGPoint, to b: CGPoint) {
        let f = canvas.frame
        func win(_ p: CGPoint) -> NSPoint { NSPoint(x: f.minX + p.x * f.width, y: f.minY + (1 - p.y) * f.height) }
        func ev(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: win(p), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: ev(.leftMouseDown, a))
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        canvas.mouseDragged(with: ev(.leftMouseDragged, mid))
        canvas.mouseDragged(with: ev(.leftMouseDragged, b))
        canvas.mouseUp(with: ev(.leftMouseUp, b))
    }
    func debugAction(_ name: String) {
        if name == "close" { close(); return }
        guard let a = Action.allCases.first(where: { "\($0)" == name }) else { return }
        onAction?(a)
    }
    func debugDump() {
        // Another app's always-on-top window can sit over the review window, and the capture then looks
        // as though we only drew half of it (on 2026-09-06 03:29 this was misdiagnosed as "the frosted
        // mask is not stretching", and a revision was wasted on it). The review window is at an ordinary
        // level and cannot outrank `.floating`, so tests raise it temporarily.
        // **Only in DEBUG** — the shipping review window should be an ordinary window, and being
        // coverable is correct.
        NSApp.activate(ignoringOtherApps: true)
        level = .popUpMenu
        bar.level = .popUpMenu
        showAll()
        bar.orderFront(nil)
        let t = scrubber.current
        let visible = track.strokes.filter { t >= $0.start && t <= $0.start + $0.duration }.count
        print("[review] dump t=\(String(format: "%.2f", t)) strokes=\(track.strokes.count) visible=\(visible) tool=\(tool.map { "\($0)" } ?? "none") toolRowHidden=\(toolRow.isHidden)")
        // The bar is its own window, and tests capture it by region (a material window captured by
        // window ID comes out a white slab).
        let wr = Geometry.cgRect(fromNS: frame), br = Geometry.cgRect(fromNS: bar.frame)
                print("[review] window CG=\(Int(wr.origin.x)),\(Int(wr.origin.y)),\(Int(wr.width)),\(Int(wr.height)) bar CG=\(Int(br.origin.x)),\(Int(br.origin.y)),\(Int(br.width)),\(Int(br.height))")
    }
    #endif

    func showAll() {
        makeKeyAndOrderFront(nil)
        bar.orderFront(nil)
        addChildWindow(bar, ordered: .above)
        placeBar()
    }

    /// There are several ways to close this window (the red dot, ⌘W, a button on the action bar), so
    /// cleanup has to hang off **the window actually closing** rather than living in one of those paths
    /// — closing with the red dot never ran `teardown()`, and the player's time observer stayed
    /// attached.
    func windowWillClose(_ notification: Notification) {
        teardown()
        let closed = onClosed
        onClosed = nil
        closed?()
    }

    var onClosed: (() -> Void)?

    func teardown() {
        guard !isClosed else { return }
        isClosed = true
        onAction = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        // A pinned bubble ignores hide(), and left on screen after the window closes it is an orphan
        HintBubble.unpin()
        removeChildWindow(bar)
        bar.orderOut(nil)
    }
}

// MARK: - Scrubber

@MainActor
private final class Scrubber: NSView {
    var duration: Double = 0 { didSet { needsDisplay = true } }
    var current: Double = 0 { didSet { needsDisplay = true } }
    /// Where the annotations fall in time, drawn as small bars on the scrubber.
    var marks: [(start: Double, end: Double, color: NSColor)] = [] { didSet { needsDisplay = true } }
    var onSeek: ((Double) -> Void)?
    var onScrubStart: (() -> Void)?

    override func mouseDown(with e: NSEvent) { onScrubStart?(); scrub(e) }
    override func mouseDragged(with e: NSEvent) { scrub(e) }
    private func scrub(_ e: NSEvent) {
        let x = convert(e.locationInWindow, from: nil).x
        onSeek?(Double(x / max(bounds.width, 1)) * duration)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        // Thin, plain, with space around it. It used to be a full-width **system blue** bar 5pt high —
        // on a dark bar of monochrome icons that is the loudest thing present, and it made the whole bar
        // read as a web form (Tim, 2026-09-05: it's ugly). The scrubber is a readout of where playback
        // has got to, not the main event, and the same grey as the icons is enough.
        let h: CGFloat = 3
        let track = NSRect(x: 0, y: bounds.midY - h / 2, width: bounds.width, height: h)
        BarStyle.fg(0.14).setFill()
        NSBezierPath(roundedRect: track, xRadius: h / 2, yRadius: h / 2).fill()

        // Annotation spread: which stretches carry marks, at a glance
        for m in marks where duration > 0 {
            let x0 = CGFloat(m.start / duration) * bounds.width
            let x1 = CGFloat(min(m.end, duration) / duration) * bounds.width
            m.color.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: NSRect(x: x0, y: bounds.midY + 3.5, width: max(2, x1 - x0), height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        guard duration > 0 else { return }
        let p = CGFloat(max(0, min(current / duration, 1)))
        BarStyle.fg(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: track.minY, width: p * bounds.width, height: h),
                     xRadius: h / 2, yRadius: h / 2).fill()
        let knob = NSRect(x: min(max(p * bounds.width - 5, 0), bounds.width - 10),
                          y: bounds.midY - 5, width: 10, height: 10)
        BarStyle.fg().setFill()
        NSBezierPath(ovalIn: knob).fill()
    }
}

// MARK: - Canvas: drawing on the video, shown and hidden by time

@MainActor
private final class ReviewCanvas: NSView {
    weak var owner: ReviewWindow?
    var tool: AnnotationTool? { didSet { needsDisplay = true } }
    var style = AnnotationStyle.default
    var strokes: [TimedStroke] = [] { didSet { needsDisplay = true } }
    var time: Double = 0 { didSet { needsDisplay = true } }

    private var drawing: TimedStroke?
    private var start: NSPoint = .zero

    override var isFlipped: Bool { false }
    override func hitTest(_ p: NSPoint) -> NSView? { tool == nil ? nil : super.hitTest(p) }
    override func resetCursorRects() {
        if tool != nil { addCursorRect(bounds, cursor: .crosshair) }
    }

    private func norm(_ p: NSPoint) -> CGPoint {
        CGPoint(x: p.x / max(bounds.width, 1), y: p.y / max(bounds.height, 1))
    }

    override func mouseDown(with e: NSEvent) {
        guard let tool, let owner else { return }
        start = convert(e.locationInWindow, from: nil)
        var s = TimedStroke(tool: tool, style: owner.currentStyle, start: owner.currentTime, duration: 2.5)
        let n = norm(start)
        s.a = n; s.b = n; s.points = [n]
        drawing = s
    }

    override func mouseDragged(with e: NSEvent) {
        guard var s = drawing else { return }
        let p = convert(e.locationInWindow, from: nil)
        let n = norm(p)
        switch s.tool {
        case .marker, .pencil:
            if let last = s.points.last, hypot(n.x - last.x, n.y - last.y) > 0.002 { s.points.append(n) }
        case .rect, .ellipse, .mosaic:
            s.b = n
            s.rect = CGRect(x: min(s.a.x, n.x), y: min(s.a.y, n.y),
                            width: abs(s.a.x - n.x), height: abs(s.a.y - n.y))
        default: s.b = n
        }
        drawing = s
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        guard let s = drawing else { return }
        drawing = nil
        let big = s.tool == .marker ? s.points.count > 2
            : hypot(s.b.x - s.a.x, s.b.y - s.a.y) > 0.01
        if big { owner?.commit(s) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let size = bounds.size
        for s in strokes where s.visible(at: time) {
            AnnotationLayer.draw(s.denormalized(in: size), in: ctx, mosaicSource: { _ in nil })
        }
        if let d = drawing {
            AnnotationLayer.draw(d.denormalized(in: size), in: ctx, mosaicSource: { _ in nil })
        }
    }
}


/// The review bar: progress / speed, zoom and tools / styles / hints — **four rows in one bar**,
/// docked to the bottom edge of the picture.
///
/// It used to be two (a bottom bar inside the window and an action bar floating bottom-right). The
/// trouble with two was that the picture got squeezed to something other than its original size, and
/// the two bars aligned by different rules, which looked a mess (Tim, 2026-09-05: merge these two
/// bars).
/// Merged: the window is the picture, the bar is separate, and it can be as wide as it likes.
@MainActor
final class ReviewBar: NSPanel {
    /// For applyZoom: leave room for the bar when working out how tall the picture can be.
    static let reserve: CGFloat = 150

    private let stack = NSStackView()

    init(rows: [NSView]) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 100),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        // Fixed dark: `.hudWindow` adapts to the desktop, so over a light one the whole bar goes white
        // and the white icons with it
        appearance = BarStyle.appearance

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        let radius = BarStyle.cornerRadius
        bg.layer?.cornerRadius = radius
        // Frosted glass ignores cornerRadius and needs its own mask, or a square dark block is left
        // outside the rounded corner
        bg.maskImage = BarStyle.roundedMask(radius: radius)
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = BarStyle.fg(0.16).cgColor
        let scrim = NSView()
        scrim.wantsLayer = true
        scrim.layer?.backgroundColor = BarStyle.surface.cgColor
        // The scrim needs the same corner radius. Setting it only on the frosted layer leaves this one
        // square, which flattens the corners straight back out — the recording HUD sets both, which is
        // why it has always been round and this bar was not.
        scrim.layer?.cornerRadius = radius
        scrim.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(scrim)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        for r in rows {
            r.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(r)
            // Every row fills the width, so the right-aligned group really is on the right
            r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: bg.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: bg.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -10),
        ])
        contentView = bg
    }

    override var canBecomeKey: Bool { false }

    var naturalSize: NSSize {
        stack.layoutSubtreeIfNeeded()
        let f = stack.fittingSize
        return NSSize(width: max(640, f.width + 24), height: f.height + 20)
    }
}
