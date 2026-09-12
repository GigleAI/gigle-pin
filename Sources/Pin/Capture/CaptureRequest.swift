import AppKit

/// A direct capture owns its destination through every suspension. It never borrows the
/// interactive overlay's completion or ends another capture session.
struct CaptureRequest {
    let rect: NSRect
    let save: Bool
    let output: URL?

    @MainActor func capture() async -> OverlayOutcome {
        guard Permissions.screenCapture else { return .cancelled }
        do {
            let shots = try await ScreenCapture.snapshotAllDisplays(
                excludingWindowIDs: CaptureChromeRegistry.windowIDs)
            guard let shot = shots.first(where: { $0.frame.intersects(rect) }),
                  let image = shot.crop(toNS: rect.intersection(shot.frame)) else { return .cancelled }
            let result = CaptureResult(image: image, screenRect: rect.intersection(shot.frame))
            return save || output != nil ? .save(result, to: output) : .copy(result)
        } catch {
            #if DEBUG
            print("[overlay] direct capture failed \(error)")
            #endif
            return .cancelled
        }
    }
}
