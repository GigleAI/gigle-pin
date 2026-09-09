// Owns every pin: creating them, pinning the clipboard, hiding and showing all, making them
// clickable again.

import AppKit

@MainActor
final class PinManager {
    private(set) var pins: [PinWindow] = []
    private(set) var allHidden = false

    var count: Int { pins.count }
    /// How many pins currently pass clicks through — the menu entry for undoing that only makes
    /// sense when this is above zero.
    var clickThroughCount: Int { pins.filter(\.clickThrough).count }

    /// Pin a capture back where it came from on screen — as though that region had been peeled off.
    func pin(_ result: CaptureResult) {
        add(image: result.nsImage, at: result.screenRect)
    }

    /// Pin the clipboard image at the centre of whichever screen the mouse is on.
    func pinClipboard() {
        guard let image = Self.imageFromPasteboard() else {
            #if DEBUG
                        print("[pin] nothing on the clipboard")
            #endif
            NSSound.beep()
            return
        }
        let screen = Geometry.screenUnderMouse
        var size = image.size
        // Scale to 80% if it is larger than the screen
        let maxW = screen.visibleFrame.width * 0.8, maxH = screen.visibleFrame.height * 0.8
        let k = min(1, maxW / max(size.width, 1), maxH / max(size.height, 1))
        size = NSSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2)
        origin.x = max(screen.visibleFrame.minX, min(origin.x, screen.visibleFrame.maxX - size.width))
        origin.y = max(screen.visibleFrame.minY, min(origin.y, screen.visibleFrame.maxY - size.height))
        add(image: image, at: NSRect(origin: origin, size: size))
    }

    /// Pin from a file (pin://pin?file=).
    func pin(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else {
            // Beep and stop, same as "nothing on the clipboard". This path exists for Shortcuts and
            // Alfred: handing it an unreadable file and getting no reaction at all leaves the script
            // side guessing which step broke.
            NSSound.beep()
            #if DEBUG
                        print("[pin] cannot read \(fileURL.path)")
            #endif
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([image])
        pinClipboard()
    }

    private func add(image: NSImage, at rect: NSRect) {
        let w = PinWindow(image: image, at: rect)
        w.onClose = { [weak self] win in self?.pins.removeAll { $0 === win } }
        pins.append(w)
        if allHidden { allHidden = false; pins.forEach { $0.orderFrontRegardless() } }
        w.appear()
        #if DEBUG
        // A pin window is a transparent material window, so capturing it by window ID yields a
        // white slab — the store-screenshot script has to capture it by region.
        let pr = Geometry.cgRect(fromNS: rect)
                print("[pin] window CG=\(Int(pr.origin.x)),\(Int(pr.origin.y)),\(Int(pr.width)),\(Int(pr.height))")
        #endif
        w.makeKey()
    }

    func toggleAll() {
        guard !pins.isEmpty else { return }
        allHidden.toggle()
        if allHidden { pins.forEach { $0.orderOut(nil) } } else { pins.forEach { $0.orderFrontRegardless() } }
        #if DEBUG
                print("[pin] all \(allHidden ? "hidden" : "shown") (\(pins.count))")
    #endif
    }

    func closeAll() {
        pins.forEach { $0.closePin() }
    }

    /// Once click-through is on the window receives no mouse events at all, so this is the only way
    /// back.
    func restoreInteraction() {
        pins.forEach { $0.clickThrough = false }
    }

    private static func imageFromPasteboard() -> NSImage? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingContentsConformToTypes: ["public.image"]]) as? [URL],
           let u = urls.first, let img = NSImage(contentsOf: u) {
            return img
        }
        if let imgs = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage], let img = imgs.first {
            return img
        }
        return nil
    }
}
