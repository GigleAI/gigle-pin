// Every icon is generated in code: a jay-blue gradient rounded square, a white bird, and a red
// recording dot bottom-right.
// Laid out on the macOS icon grid (a 1024 canvas with an 824 rounded square centred), rendered to an
// iconset, then packed into an icns with iconutil.
//   xcrun swift scripts/make-icons.swift        → Resources/AppIcon.icns
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first!).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // The rounded square: 824, centred, corner radius 22.37%
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = NSBezierPath(roundedRect: rect, xRadius: 184, yRadius: 184)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    NSColor(srgbRed: 0.16, green: 0.36, blue: 0.86, alpha: 1).setFill()
    path.fill()
    ctx.restoreGState()

    ctx.saveGState()
    path.addClip()
    let grad = NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.14, green: 0.32, blue: 0.82, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.18, blue: 0.55, alpha: 1),
    ])!
    grad.draw(in: rect, angle: -70)
    // A highlight across the top
    let hl = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    hl.draw(in: CGRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    ctx.restoreGState()

    // The approved variant: starting from the raised-dot version, the bird and dot move together 6px
// left and 4px up (on a 256px canvas). On a 1024 canvas that is (-24, +16). The background does not
// move, and the menu bar icon is not affected by this script.
    ctx.saveGState()
    ctx.translateBy(x: -24, y: 16)
    // The bird: the SF Symbol "bird", white, with a slight shadow
    let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)
    if let bird = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: bird.size, flipped: false) { r in
            bird.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let bw = tinted.size.width, bh = tinted.size.height
        let k = min(560 / bw, 560 / bh)
        let dw = bw * k, dh = bh * k
        let at = CGRect(x: 512 - dw / 2, y: 512 - dh / 2 + 10, width: dw, height: dh)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.35))
        tinted.draw(in: at)
        ctx.restoreGState()
    }

    // Bottom-right: the red recording dot, with a white rim
    let dot = CGRect(x: 640, y: 202, width: 150, height: 150)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: dot.insetBy(dx: -18, dy: -18)).fill()
    NSColor(srgbRed: 0.93, green: 0.23, blue: 0.23, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func write(_ img: NSImage, px: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

for (pt, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let px = pt * scale
    write(render(px), px: px, name: "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png")
}
// A preview for the README while we are here
write(render(256), px: 256, name: "../icon-preview.png")
// The docs and the static site use the same render, so regenerating cannot leave an old version
// behind.
let previewData = try! Data(contentsOf: root.appendingPathComponent("build/icon-preview.png"))
// The second target (the website) only exists in the internal repo — the open-source copy has no
// such directory. Skip a target that is not there rather than crashing on `try!`: one script has to
// run in both repos.
for relativePath in ["docs/icon.png", "site/icon.png"] {
    let out = root.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path) else { continue }
    try! previewData.write(to: out)
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "→ \(icns.path)" : "iconutil failed")
