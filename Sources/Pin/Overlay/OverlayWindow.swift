// The overlay for one display: full screen, above everything, showing that screen frozen.

import AppKit

final class OverlayWindow: NSWindow, CaptureChrome {
    let snapshot: DisplaySnapshot
    let overlay: OverlayView

    init(snapshot: DisplaySnapshot, detector: WindowDetector) {
        self.snapshot = snapshot
        overlay = OverlayView(snapshot: snapshot, detector: detector)
        super.init(contentRect: snapshot.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = overlay
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
