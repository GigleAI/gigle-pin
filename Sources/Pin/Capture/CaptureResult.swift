// What a capture produced, and the ways out of here: clipboard, file, pin.

import AppKit
import UniformTypeIdentifiers

struct CaptureResult {
    /// The pixel image (twice the point size on Retina).
    let image: CGImage
    /// Where the selection sat on screen, in NS global coordinates (origin bottom-left). This is
    /// what lets a pin go back exactly where it came from.
    let screenRect: NSRect
    /// One encode, shared. "Save, then copy to the clipboard" is the default path, and it used to
    /// encode the same picture to PNG twice — on the main thread, before the overlay could go away.
    private let encoded = Encoded()

    init(image: CGImage, screenRect: NSRect) {
        self.image = image
        self.screenRect = screenRect
    }

    var nsImage: NSImage {
        NSImage(cgImage: image, size: screenRect.size)
    }

    /// PNG bytes, encoded once on a background thread and remembered for the next caller.
    /// Main-actor because every caller is, and because the memo is a plain class field.
    @MainActor func png() async -> Data? {
        if let task = encoded.png { return await task.value }
        let image = image, size = screenRect.size
        let task = Task.detached(priority: .userInitiated) { Self.encodePNG(image, size: size) }
        encoded.png = task
        return await task.value
    }

    /// The synchronous encode, for the one caller that already sits behind a modal panel.
    var pngData: Data? { Self.encodePNG(image, size: screenRect.size) }

    private static func encodePNG(_ image: CGImage, size: NSSize) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size   // write the DPI so "displayed size" equals the on-screen points
        return rep.representation(using: .png, properties: [:])
    }

    private final class Encoded { var png: Task<Data?, Never>? }
}
@MainActor
enum Exporter {

    /// Put both PNG and TIFF on the pasteboard — Finder and Preview take the PNG, older apps only
    /// understand TIFF — **as two representations of one item, never as two items.**
    ///
    /// This used to be `pb.setData(png, …)` followed by `pb.writeObjects([nsImage])`, and those are
    /// not the same kind of write: `setData` fills in the pasteboard's first item, while
    /// `writeObjects` *appends* one. The clipboard then held two items, PNG and TIFF, and how that
    /// looked depended entirely on how the receiving app reads a pasteboard. Anything that asks for
    /// the best single type — WeChat, Claude Code — showed one image and nothing seemed wrong.
    /// **WhatsApp reads every item, so one screenshot arrived as two copies of itself** (Tim,
    /// 2026-09-09). Measured before the fix: 2 items, and `readObjects(forClasses: [NSImage.self])`
    /// returned 2 images.
    ///
    /// One item carrying both types is what every app expects, and the order matters: PNG is added
    /// first because the first type added is the highest priority one.
    ///
    /// Both representations are produced off the main thread. A full-screen PNG takes on the order
    /// of 100–300 ms to encode, and it used to happen right here, on the main thread, between
    /// pressing Return and the overlay fading out — a pause at the end of every single capture.
    static func copy(_ result: CaptureResult) async {
        let png = await result.png()
        let cg = result.image, size = result.screenRect.size
        let tiff = await Task.detached(priority: .userInitiated) { NSImage(cgImage: cg, size: size).tiffRepresentation }.value
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        var ok = false
        if let png {
            ok = item.setData(png, forType: .png)
        }
        if let tiff {
            item.setData(tiff, forType: .tiff)
        }
        // Writing an item with no representations would silently empty the clipboard; the image
        // itself is the honest fallback.
        if item.types.isEmpty {
            pb.writeObjects([result.nsImage])
        } else {
            pb.writeObjects([item])
        }
        #if DEBUG
                print("[capture] copied \(Int(result.screenRect.width))×\(Int(result.screenRect.height)) png=\(ok) items=\(pb.pasteboardItems?.count ?? -1)")
    #endif
    }

    /// Save into the directory from preferences, with a timestamped name. Returns where it landed.
    @discardableResult
    static func save(_ result: CaptureResult, to requested: URL? = nil) async -> URL? {
        guard let png = await result.png() else { return nil }
        let url: URL
        if let requested {
            // A path the agent chose itself: it knows where the file is, so it never has to guess.
            // Create the directory if missing; **overwrite** a name collision — someone who names a
            // path wants that exact file.
            try? FileManager.default.createDirectory(at: requested.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            url = requested
        } else {
            let dir = Preferences.shared.ensureSaveDirectory()
            url = FileNaming.unique(in: dir, base: "Pin \(Self.stamp())", ext: "png")
        }
        // The write goes off the main thread too; the toast that says where it landed waits for it.
        let failure: Error? = await Task.detached(priority: .userInitiated) {
            do { try png.write(to: url, options: .atomic); return nil } catch { return error }
        }.value
        if let failure {
            #if DEBUG
                        print("[capture] save failed \(failure)")
            #endif
            return nil
        }
        #if DEBUG
                    print("[capture] saved \(url.path)")
        #endif
        return url
    }

    /// Move an already-saved file to somewhere the user picks.
    ///
    /// Why move afterwards instead of asking before saving: saving is frequent and the destination
    /// is almost always the same one, so a panel every time costs a focus grab and a Return every
    /// time. This path is taken only when the destination genuinely needs to change.
    static func relocate(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = url.lastPathComponent
        panel.directoryURL = url.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dst = panel.url, dst != url else { return }
                try? FileManager.default.removeItem(at: dst)   // the user already confirmed the overwrite
        do {
            try FileManager.default.moveItem(at: url, to: dst)
        } catch {
            // Fall back to copying if the move fails — **never end up with neither**
            try? FileManager.default.copyItem(at: url, to: dst)
        }
    }

    /// Let the user choose where to save.
    static func saveAs(_ result: CaptureResult) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Pin \(Self.stamp()).png"
        panel.directoryURL = Preferences.shared.ensureSaveDirectory()
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, let png = result.pngData else { return }
        try? png.write(to: url, options: .atomic)
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }
}
