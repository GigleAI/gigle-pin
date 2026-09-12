import AppKit
import ScreenCaptureKit
import CoreImage

/// A frozen, full-resolution snapshot of one display, taken the instant the
/// user hits the capture hotkey.
///
/// Snipaste's trick is that it never lets you select against a *live* screen —
/// it slams a still image over the desktop first. That way the content cannot
/// shift under the crosshair while you are dragging, and the magnifier can
/// read exact pixels without another round trip to the window server.
/// `@unchecked Sendable`: every field is a `let`, the image is immutable, and `NSScreen` is only
/// read for its frame — the displays are captured on parallel tasks and the results cross back to
/// the main actor, which is the one place they are used.
struct DisplaySnapshot: @unchecked Sendable {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    /// Pixel-resolution image (on Retina this is 2x the point size).
    let image: CGImage
    /// The display's rect in NS (bottom-left origin) global space.
    let frame: NSRect

    var pixelScale: CGFloat {
        CGFloat(image.width) / frame.width
    }

    /// Crops out a sub-rect expressed in NS global points.
    func crop(toNS rect: NSRect) -> CGImage? {
        let local = NSRect(x: rect.origin.x - frame.origin.x,
                           y: rect.origin.y - frame.origin.y,
                           width: rect.width,
                           height: rect.height)
        let scale = pixelScale
        // CGImage is top-left origin, the NS rect is bottom-left: flip y.
        let pixelRect = CGRect(x: local.origin.x * scale,
                               y: (frame.height - local.origin.y - local.height) * scale,
                               width: local.width * scale,
                               height: local.height * scale).pixelAligned
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }

    /// Colour of a single point, in NS global coordinates. Used by the
    /// eyedropper readout under the magnifier.
    func color(atNS point: NSPoint) -> NSColor? {
        let scale = pixelScale
        let x = Int(((point.x - frame.origin.x) * scale).rounded(.down))
        let y = Int(((frame.maxY - point.y) * scale).rounded(.down))
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              image.bitsPerPixel == 32,
              let data = image.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let off = y * image.bytesPerRow + x * 4
        guard off + 3 < CFDataGetLength(data) else { return nil }
        let b0 = ptr[off], b1 = ptr[off + 1], b2 = ptr[off + 2], b3 = ptr[off + 3]

        // Do not assume the byte order — SCK hands over 32BGRA (little endian, alpha first), but
        // other sources (an NSImage, say) can be RGBA. Read bitmapInfo instead.
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let alphaFirst: Bool
        switch image.alphaInfo {
        case .premultipliedFirst, .first, .noneSkipFirst: alphaFirst = true
        default: alphaFirst = false
        }
        let r: UInt8, g: UInt8, b: UInt8
        switch (little, alphaFirst) {
        case (true, true):   (b, g, r) = (b0, b1, b2)   // B G R A
        case (false, true):  (r, g, b) = (b1, b2, b3)   // A R G B
        case (false, false): (r, g, b) = (b0, b1, b2)   // R G B A
        case (true, false):  (r, g, b) = (b3, b2, b1)   // A B G R
        }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// A (2r+1)² pixel square centred on a point, for the magnifier. Near the
    /// screen edge the missing pixels are padded with dark grey so the centre
    /// pixel stays in the centre of the loupe.
    func pixelSquare(centeredAtNS point: NSPoint, radius r: Int) -> CGImage? {
        let scale = pixelScale
        let cx = Int(((point.x - frame.origin.x) * scale).rounded(.down))
        let cy = Int(((frame.maxY - point.y) * scale).rounded(.down))
        let side = 2 * r + 1
        let want = CGRect(x: cx - r, y: cy - r, width: side, height: side)
        let have = want.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !have.isNull, have.width > 0, have.height > 0,
              let piece = image.cropping(to: have),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // CGContext has its origin bottom-left, CGImage top-left: flip the destination y.
        let dx = have.minX - want.minX
        let dyTop = have.minY - want.minY
        let dest = CGRect(x: dx, y: CGFloat(side) - dyTop - have.height, width: have.width, height: have.height)
        ctx.interpolationQuality = .none
        ctx.draw(piece, in: dest)
        return ctx.makeImage()
    }
}

enum CaptureError: Error, LocalizedError {
    case permissionDenied
    case noDisplays
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Pin needs Screen Recording permission. Open System Settings ▸ Privacy & Security ▸ Screen Recording and enable Pin."
        case .noDisplays:
            return L("err.noDisplays", "No displays available to capture.")
        case .captureFailed(let why):
            return Lf("err.captureFailed", "Screen capture failed: %@", why)
        }
    }
}

/// Everything one display's capture needs, bundled so it can be handed to a task as one value.
/// `@unchecked` because `SCDisplay`, `SCWindow` and `NSScreen` are not Sendable, and are only read.
struct CaptureJob: @unchecked Sendable {
    let index: Int
    let display: SCDisplay
    let screen: NSScreen
    let excluded: [SCWindow]

    var displayID: CGDirectDisplayID { display.displayID }

    func run() async throws -> DisplaySnapshot {
        tmark("cap\(index)-start")
        defer { tmark("cap\(index)-end") }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * screen.pixelScale)
        config.height = Int(CGFloat(display.height) * screen.pixelScale)
        config.showsCursor = false
        config.captureResolution = .best
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: config)
            return DisplaySnapshot(screen: screen, displayID: display.displayID,
                                   image: image, frame: screen.frame)
        } catch {
            throw CaptureError.captureFailed(error.localizedDescription)
        }
    }
}

/// Thin wrapper over ScreenCaptureKit for one-shot stills.
enum ScreenCapture {

    /// Everything on screen right now, as ScreenCaptureKit sees it. ~45 ms; the one part of a
    /// capture that cannot be split up or skipped, so callers start it first and do other work
    /// while it runs.
    static func shareableContent() async throws -> SCShareableContent {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            tmark("content")
            guard !content.displays.isEmpty else { throw CaptureError.noDisplays }
            return content
        } catch let e as CaptureError {
            throw e
        } catch {
            // SCK reports a missing TCC grant as a generic failure, so treat
            // any failure to enumerate content as "not allowed yet".
            throw CaptureError.permissionDenied
        }
    }

    /// One capture job per display, in ScreenCaptureKit's order. Each is a single Sendable value
    /// that can be handed to a task; run them however the caller likes.
    ///
    /// Exclude only the capture session's own chrome (overlay, toolbars, HUD, hint bubbles,
    /// permission cards), not the whole Pin app — that would make our own settings window
    /// uncapturable, and writing docs, filing bugs and recording demos all need it (Tim,
    /// 2026-09-05). The settings window, the welcome window and pins are real things on the
    /// screen, so what you see is what you get.
    ///
    /// `excludingWindowIDs` is passed in rather than read here so that nothing in the capture path
    /// touches the main actor: the caller reads the chrome registry once, and the main thread is
    /// then free to build the overlay windows while the captures are in flight.
    static func jobs(in content: SCShareableContent, excludingWindowIDs chrome: [CGWindowID]) -> [CaptureJob] {
        let chromeSet = Set(chrome)
        let excluded = content.windows.filter { chromeSet.contains($0.windowID) }
        return content.displays.enumerated().compactMap { index, display in
            NSScreen.screens.first { $0.displayID == display.displayID }
                .map { CaptureJob(index: index, display: display, screen: $0, excluded: excluded) }
        }
    }

    /// Grabs every attached display at once, concurrently, in display order. We freeze all of them
    /// so dragging a selection across a monitor boundary keeps working.
    static func snapshotAllDisplays(excludingWindowIDs chrome: [CGWindowID]) async throws -> [DisplaySnapshot] {
        let content = try await shareableContent()
        let jobs = jobs(in: content, excludingWindowIDs: chrome)
        guard !jobs.isEmpty else { throw CaptureError.noDisplays }
        let snapshots: [DisplaySnapshot] = try await withThrowingTaskGroup(of: (Int, DisplaySnapshot).self) { group in
            for job in jobs {
                group.addTask { try await (job.index, job.run()) }
            }
            // Keep the display order stable whatever order the captures finish in.
            var ordered = [DisplaySnapshot?](repeating: nil, count: jobs.count)
            for try await (index, shot) in group { ordered[index] = shot }
            return ordered.compactMap { $0 }
        }
        guard !snapshots.isEmpty else { throw CaptureError.noDisplays }
        return snapshots
    }

    /// Asks the system for Screen Recording permission, returning whether we
    /// already have it. The first call triggers the system prompt.
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}
