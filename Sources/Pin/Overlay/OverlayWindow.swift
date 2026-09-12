// The overlay for one display: full screen, above everything, showing that screen frozen.

import AppKit

final class OverlayWindow: NSWindow, CaptureChrome {
    let overlay: OverlayView
    /// Holds the frozen screen as layer contents. The image is handed to the compositor once, when
    /// the capture lands, and drawn by the GPU from then on; `OverlayView` above it is transparent
    /// and paints only what changes — the dimming, the frame, the loupe, the annotations.
    private let backdrop = NSView()

    /// Built for a screen, not for a picture: the window exists before the capture finishes, so
    /// its construction overlaps the capture instead of following it.
    init(screen: NSScreen, detector: WindowDetector) {
        overlay = OverlayView(screen: screen, detector: detector)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        backdrop.wantsLayer = true
        backdrop.layerContentsRedrawPolicy = .never
        backdrop.frame = NSRect(origin: .zero, size: screen.frame.size)
        backdrop.autoresizingMask = [.width, .height]
        overlay.frame = backdrop.bounds
        overlay.autoresizingMask = [.width, .height]
        backdrop.addSubview(overlay)
        contentView = backdrop
    }

    /// The capture landed: show it. Until this is called the window is built but never ordered in.
    func present(_ snapshot: DisplaySnapshot) {
        backdrop.layer?.contentsGravity = .resize
        backdrop.layer?.contentsScale = snapshot.pixelScale
        backdrop.layer?.contents = snapshot.image
        overlay.snapshot = snapshot
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
