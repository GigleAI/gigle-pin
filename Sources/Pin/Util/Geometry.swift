import AppKit

/// macOS hands us two different coordinate spaces and mixing them up is the
/// single easiest way to draw a selection rectangle on the wrong monitor.
///
/// - `NS` space: origin at the **bottom-left** of the main display, y grows up.
///   This is what `NSScreen.frame` and every AppKit view reports.
/// - `CG` space: origin at the **top-left** of the main display, y grows down.
///   This is what `CGWindowListCopyWindowInfo`, `CGDisplayBounds` and
///   ScreenCaptureKit report.
enum Geometry {

    /// Height of the display whose bottom-left corner is the global origin.
    /// That is the pivot for every flip.
    ///
    /// Not `NSScreen.screens.first` — with several monitors the first entry is
    /// not always the origin display, and flipping against the wrong height
    /// shifts the whole screen (Magpie hit this, see its docs/lessons.md).
    /// Not `NSScreen.main` either, that one follows the key window.
    static var mainDisplayHeight: CGFloat {
        let origin = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
        return origin?.frame.height ?? 0
    }

    static func cgRect(fromNS rect: NSRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: mainDisplayHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    static func nsRect(fromCG rect: CGRect) -> NSRect {
        NSRect(x: rect.origin.x,
               y: mainDisplayHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    static func cgPoint(fromNS point: NSPoint) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    static func nsPoint(fromCG point: CGPoint) -> NSPoint {
        NSPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    /// Current mouse location in CG (top-left) space.
    static var mouseLocationCG: CGPoint {
        cgPoint(fromNS: NSEvent.mouseLocation)
    }

    /// The screen the cursor is currently on, falling back to the main display.
    static var screenUnderMouse: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    /// Rect spanned by two arbitrary corner points, normalised so width/height
    /// are always positive.
    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(a.x - b.x),
               height: abs(a.y - b.y))
    }
}

extension CGRect {
    /// Rounds to whole pixels so a 1-point selection never lands on a half
    /// pixel and blurs the exported image.
    var pixelAligned: CGRect {
        CGRect(x: origin.x.rounded(.down),
               y: origin.y.rounded(.down),
               width: width.rounded(),
               height: height.rounded())
    }

    func clamped(to bounds: CGRect) -> CGRect {
        intersection(bounds)
    }
}

extension NSScreen {
    /// The `CGDirectDisplayID` behind this screen, needed to match an
    /// `NSScreen` up with a ScreenCaptureKit `SCDisplay`.
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// Physical pixels per point. 2.0 on Retina, 1.0 on an external 1x panel.
    var pixelScale: CGFloat { backingScaleFactor }
}

extension NSColor {
    /// "#RRGGBB"，sRGB。
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// "0, 38, 47"，sRGB。
    var rgbString: String {
        guard let c = usingColorSpace(.sRGB) else { return "0, 0, 0" }
        return "\(Int((c.redComponent * 255).rounded())), \(Int((c.greenComponent * 255).rounded())), \(Int((c.blueComponent * 255).rounded()))"
    }

    /// Whether text on top of this colour should be black or white.
    var contrastingText: NSColor {
        guard let c = usingColorSpace(.sRGB) else { return .white }
        let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return l > 0.6 ? .black : .white
    }
}
