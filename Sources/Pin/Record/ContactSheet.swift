// The contact sheet: a recording flattened into one PNG, laid out in order with a timestamp on
// each cell.
//
// Why it exists: when a recording is for an AI to look at, most models understand pictures far
// better than video, and there is no guarantee they sample the frame that mattered. A contact sheet
// is legible to every model, pastes straight into a conversation with ⌘V, and the timestamps let it
// describe the sequence ("clicked here at 3 s, the error appeared at 6 s").
//
// Frames are not sampled evenly — a screen recording is still for long stretches, and even sampling
// returns a pile of identical pictures. This picks by difference from the last chosen frame, so
// motionless stretches are skipped automatically.

import AVFoundation
import AppKit

enum ContactSheet {

    struct Options {
        var maxFrames = 9
        var columns = 3
        var cellWidth: CGFloat = 420
        /// How different from the last chosen frame counts as "something happened" (0…1).
        var changeThreshold = 0.006
    }

    /// Runs on a background thread. Returns the assembled image.
    static func make(from url: URL, options: Options = Options()) async throws -> NSImage {
        try await Task.detached(priority: .userInitiated) {
            try makeSync(url: url, o: options)
        }.value
    }

    private static func makeSync(url: URL, o: Options) throws -> NSImage {
        let asset = AVURLAsset(url: url)
        let duration = CMTimeGetSeconds(asset.duration)
        guard duration > 0 else { throw RecorderError.writerFailed(L("err.zeroLength", "the video is zero seconds long")) }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        gen.maximumSize = CGSize(width: o.cellWidth * 2, height: o.cellWidth * 2)

        // Sample densely first (at most 60), then keep the ones where something changed
        let probes = min(60, max(o.maxFrames, Int(duration * 3)))
        var candidates: [(Double, CGImage)] = []
        for i in 0..<probes {
            let t = duration * Double(i) / Double(max(1, probes - 1))
            let time = CMTime(seconds: t, preferredTimescale: 600)
            if let img = try? gen.copyCGImage(at: time, actualTime: nil) {
                candidates.append((t, img))
            }
        }
        guard !candidates.isEmpty else { throw RecorderError.writerFailed(L("err.noFrames", "no frames could be read")) }

        let picked = pick(candidates, o: o)
        #if DEBUG
                // The chosen times have to cover the **whole** clip — stride+prefix used to cut the tail off
        // entirely (an 8.1-second video stopped at 5.6). Printing them is what makes that checkable.
                print("[sheet] \(picked.count) frames, \(String(format: "%.1f", duration))s, at "
              + picked.map { String(format: "%.1f", $0.0) }.joined(separator: ","))
        #endif
        return compose(picked, duration: duration, o: o)
    }

    /// Choosing frames: always the first, then any frame different enough from the last chosen one,
    /// and always the last.
    /// Falls back to even sampling if too few qualify — a recording of a motionless screen still has
    /// to produce something.
    private static func pick(_ all: [(Double, CGImage)], o: Options) -> [(Double, CGImage)] {
        var out: [(Double, CGImage)] = [all[0]]
        var lastThumb = downsample(all[0].1)
        for c in all.dropFirst() {
            guard out.count < o.maxFrames else { break }
            let thumb = downsample(c.1)
            if diff(lastThumb, thumb) > o.changeThreshold {
                out.append(c)
                lastThumb = thumb
            }
        }
        if let last = all.last, out.last?.0 != last.0, out.count < o.maxFrames {
            out.append(last)
        }
        // Too little change (a recording of a still screen) falls back to even sampling, which has
        // to cover the **whole** duration — stride+prefix used to cut the tail off entirely (an
        // 8.1-second video stopped at 5.6).
        if out.count < min(4, all.count) {
            let n = min(o.maxFrames, all.count)
            out = (0..<n).map { all[$0 * (all.count - 1) / max(1, n - 1)] }
        }
        return out
    }

    /// Shrunk to 32×32 greyscale for comparing — pixel-by-pixel on the full image is slow and
    /// unnecessary.
    private static func downsample(_ img: CGImage) -> [UInt8] {
        let n = 32
        var buf = [UInt8](repeating: 0, count: n * n)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .low
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        }
        return buf
    }

    private static func diff(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0
        for i in 0..<a.count { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count * 255)
    }

    // MARK: - Layout

    private static func compose(_ frames: [(Double, CGImage)], duration: Double, o: Options) -> NSImage {
        let cols = min(o.columns, max(1, frames.count))
        let rows = Int(ceil(Double(frames.count) / Double(cols)))
        let first = frames[0].1
        let ratio = CGFloat(first.height) / CGFloat(first.width)
        let cw = o.cellWidth, ch = (cw * ratio).rounded()
        let pad: CGFloat = 10, header: CGFloat = 34
        let W = CGFloat(cols) * cw + CGFloat(cols + 1) * pad
        let H = CGFloat(rows) * ch + CGFloat(rows + 1) * pad + header

        let img = NSImage(size: NSSize(width: W, height: H))
        img.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: W, height: H).fill()

        // Header: total duration and frame count, so the reader knows this is a sampled video and
        // not a handful of unrelated screenshots
        let title = Lf("sheet.title", "Recording %@ · %d key frames, in order — stretches where nothing moved are skipped", fmt(duration), frames.count)
        NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(white: 0.85, alpha: 1),
        ]).draw(at: NSPoint(x: pad + 2, y: H - header + 9))

        for (i, f) in frames.enumerated() {
            let c = i % cols, r = i / cols
            let x = pad + CGFloat(c) * (cw + pad)
            let y = H - header - pad - CGFloat(r + 1) * ch - CGFloat(r) * pad
            let cell = NSRect(x: x, y: y, width: cw, height: ch)
            NSGraphicsContext.current?.cgContext.draw(f.1, in: cell)
            NSColor.white.withAlphaComponent(0.18).setStroke()
            NSBezierPath(rect: cell).stroke()

            // Timestamp in the top-left over a backing plate, so it reads against any picture
            let stamp = fmt(f.0)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let ts = NSAttributedString(string: stamp, attributes: attrs)
            let size = ts.size()
            let box = NSRect(x: cell.minX + 6, y: cell.maxY - size.height - 10,
                             width: size.width + 14, height: size.height + 6)
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
            ts.draw(at: NSPoint(x: box.minX + 7, y: box.minY + 3))
        }
        img.unlockFocus()
        return img
    }

    private static func fmt(_ s: Double) -> String {
        s >= 60 ? String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
                : String(format: "%.1fs", s)
    }
}
