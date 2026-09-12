import AppKit

struct RecordingRegion {
    let rect: NSRect
    let screen: NSScreen
    var scale: CGFloat { screen.backingScaleFactor }
}

/// The geometry, file policy, media writer and chrome all belong to this take. Nothing is reused
/// by the next recording: paused time, muted tracks and delayed callbacks cannot cross takes.
@MainActor
final class RecordingSession {
    let region: RecordingRegion
    let output: URL
    let requested: Bool
    let pending: Bool
    let recorder = Recorder()
    let lifecycle = RecordingLifecycle()
    let frame: RecordingFrameWindow
    let hud: RecordingHUD
    var annotationBar: LiveAnnotationBar?
    var annotation: LiveAnnotationWindow?
    var ripple: ClickRippleWindow?
    var autoStop: Task<Void, Never>?

    init(region: RecordingRegion, output: URL, requested: Bool, pending: Bool = false) {
        self.region = region
        self.output = output
        self.requested = requested
        self.pending = pending
        frame = RecordingFrameWindow(rect: region.rect)
        hud = RecordingHUD(near: region.rect, on: region.screen)
    }

    func endInteraction() {
        autoStop?.cancel(); autoStop = nil
        frame.orderOut(nil)
        annotation?.end(); annotation = nil
        ripple?.end(); ripple = nil
        annotationBar?.orderOut(nil); annotationBar = nil
    }
}
