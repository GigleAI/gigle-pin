// A pin: one image held above everything else on screen. Snipaste's defining feature.
//
//   drag = move     scroll = zoom     ⌥scroll / number keys 1-9,0 = opacity
//   double-click = back to 100%     ⌘C copy   ⌘S save   ⌘T click-through   Esc / ⌘W close
//   right-click = menu

import AppKit

@MainActor
final class PinWindow: NSPanel, NSWindowDelegate {
    let image: NSImage
    private let imageView = PinImageView()
    private(set) var scale: CGFloat = 1
    private var baseSize: NSSize
    /// The real basis for zooming: the rect **before rounding and before AppKit pushed it around**.
    /// The `frame` on screen is that rounded off, and working backwards from `frame` loses a little
    /// at every step.
    private var intended: NSRect
    var onClose: ((PinWindow) -> Void)?

    init(image: NSImage, at rect: NSRect) {
        self.image = image
        baseSize = rect.size
        intended = rect
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = Preferences.shared.pinShadow
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        alphaValue = Preferences.shared.pinOpacity

        imageView.image = image
        imageView.pin = self
        contentView = imageView
        contentView?.wantsLayer = true

        // After the user drags, the zoom basis has to follow — otherwise the next zoom snaps the
        // image back to where it was before the drag. Use the window's own delegate rather than
        // NotificationCenter: a block-based observer has to be removed by hand, and `deinit` is
        // nonisolated in Swift 6, so it cannot touch main-actor state. The window already has a
        // delegate slot; using it is both simpler and impossible to leak.
        delegate = self
    }

    func windowDidMove(_ notification: Notification) {
        intended.origin = frame.origin
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// **Do not push a pin back on screen.**
    ///
    /// AppKit clamps the result of `setFrame` into the screen by default. For a pin that is wrong,
    /// and wrong cumulatively: zooming is computed around the centre, so once an enlargement gets
    /// nudged, the next zoom takes the nudged position as its basis, and zooming in then out no
    /// longer returns to where it started — measured on a pin at the top edge of the screen, three
    /// ⌘= followed by three ⌘- moved it 66pt vertically (2026-09-06 08:5x). It looks like the image
    /// wandering off by itself.
    ///
    /// A pin is a reference image floating above everything, and making it bigger than the screen or
    /// letting it hang off the edge are both normal (especially when zooming in on detail). If one
    /// really does get lost, "Close All Pins" in the menu bar is the backstop.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: Zoom and opacity

    func zoom(by factor: CGFloat, around anchor: NSPoint? = nil) {
        setScale(scale * factor, around: anchor)
    }

    func setScale(_ s: CGFloat, around anchor: NSPoint? = nil) {
        let clamped = max(0.1, min(s, 8))
        guard clamped != scale else { return }
        // **The basis is the unrounded `intended`, not the frame on screen.**
        // Sizes have to be rounded or the render blurs on half pixels, but deriving the centre from
        // a rounded size loses half a point at every step: 600 at 1.331 is 798.6 → 799, moving the
        // centre from 300 to 299.5, and zooming back moves it again. A few round trips and the image
        // has walked away.
        let old = intended
        let newSize = NSSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
        // Zoom around an anchor (the window centre by default), keeping the anchor fixed on screen.
        let a = anchor ?? NSPoint(x: old.midX, y: old.midY)
        let fx = (a.x - old.minX) / old.width
        let fy = (a.y - old.minY) / old.height
        let origin = NSPoint(x: a.x - newSize.width * fx, y: a.y - newSize.height * fy)
        scale = clamped
        intended = NSRect(origin: origin, size: newSize)
        setFrame(NSRect(x: origin.x.rounded(), y: origin.y.rounded(),
                        width: newSize.width.rounded(), height: newSize.height.rounded()), display: true)
        imageView.needsDisplay = true
        #if DEBUG
                print("[pin] zoom \(String(format: "%.4f", clamped)) → \(Int(frame.width))×\(Int(frame.height)) @ \(Int(frame.minX)),\(Int(frame.minY))")
    #endif
    }

    func setOpacity(_ v: CGFloat) {
        alphaValue = max(0.1, min(v, 1))
    }

    var clickThrough: Bool {
        get { ignoresMouseEvents }
        set {
            ignoresMouseEvents = newValue
            imageView.needsDisplay = true
            #if DEBUG
                        print("[pin] click-through \(newValue ? "on" : "off")")
            #endif
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let ch = event.charactersIgnoringModifiers ?? ""
        switch (event.keyCode, ch, cmd) {
        case (53, _, _), (_, "w", true): closePin()
        case (_, "c", true): copyImage()
        case (_, "s", true): saveImage()
        case (_, "t", true): clickThrough.toggle()
        case (_, "0", false): setOpacity(1)
        case (_, "1"..."9", false):
            if let d = Int(ch) { setOpacity(CGFloat(d) / 10) }
        case (_, "=", true), (_, "+", true): zoom(by: 1.1)
        case (_, "-", true): zoom(by: 1 / 1.1)
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard dy != 0 else { return }
        let mouse = NSEvent.mouseLocation
        if event.modifierFlags.contains(.option) {
            setOpacity(alphaValue + (dy > 0 ? 0.05 : -0.05))
        } else {
            let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 + dy / 200 : (dy > 0 ? 1.08 : 1 / 1.08)
            zoom(by: max(0.5, min(step, 2)), around: mouse)
        }
    }

    // MARK: Actions

    @objc func copyImage() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        #if DEBUG
                print("[pin] copied")
    #endif
    }

    @objc func saveImage() {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Exporter.saveAs(CaptureResult(image: cg, screenRect: NSRect(origin: .zero, size: baseSize)))
    }

    @objc func closePin() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            animator().alphaValue = 0
        }, completionHandler: { [self] in
            orderOut(nil)
            onClose?(self)
        })
    }

    /// A small bounce on arrival, so it is visible that it landed where it came from.
    func appear() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = Preferences.shared.pinOpacity
        }
        #if DEBUG
                print("[pin] pinned \(Int(frame.width))×\(Int(frame.height)) @ \(Int(frame.minX)),\(Int(frame.minY))")
    #endif
    }
}

/// Draws the image, plus a hairline border on hover so it reads as something you can act on.
@MainActor
final class PinImageView: NSView {
    var image: NSImage?
    weak var pin: PinWindow?
    private var hovering = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if event.clickCount == 2 { pin?.setScale(1); return }
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let pin else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: L("pin.copy", "Copy  ⌘C"), action: #selector(PinWindow.copyImage), keyEquivalent: "").target = pin
        menu.addItem(withTitle: L("pin.save", "Save…  ⌘S"), action: #selector(PinWindow.saveImage), keyEquivalent: "").target = pin
        menu.addItem(.separator())
        let zoom = NSMenuItem(title: L("pin.zoom", "Zoom"), action: nil, keyEquivalent: "")
        let zm = NSMenu()
        for (t, s) in [("50%", 0.5), ("100%", 1.0), ("150%", 1.5), ("200%", 2.0)] {
            let it = NSMenuItem(title: t, action: #selector(pickScale(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = s
            it.state = abs(pin.scale - s) < 0.01 ? .on : .off
            zm.addItem(it)
        }
        zoom.submenu = zm
        menu.addItem(zoom)
        let opacity = NSMenuItem(title: L("pin.opacity", "Opacity"), action: nil, keyEquivalent: "")
        let om = NSMenu()
        for v in [1.0, 0.8, 0.6, 0.4, 0.2] {
            let it = NSMenuItem(title: "\(Int(v * 100))%", action: #selector(pickOpacity(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = v
            it.state = abs(pin.alphaValue - v) < 0.01 ? .on : .off
            om.addItem(it)
        }
        opacity.submenu = om
        menu.addItem(opacity)
        menu.addItem(withTitle: L("pin.clickThrough", "Click through  ⌘T"), action: #selector(toggleClickThrough), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("pin.close", "Close  Esc"), action: #selector(PinWindow.closePin), keyEquivalent: "").target = pin
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func pickScale(_ s: NSMenuItem) { if let v = s.representedObject as? Double { pin?.setScale(v) } }
    @objc private func pickOpacity(_ s: NSMenuItem) { if let v = s.representedObject as? Double { pin?.setOpacity(v) } }
    @objc private func toggleClickThrough() { pin?.clickThrough.toggle() }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        if hovering || (window?.isKeyWindow ?? false) {
            NSColor(srgbRed: 0.28, green: 0.62, blue: 1.0, alpha: 0.9).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
    }
}
