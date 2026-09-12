// MP4 → GIF. AVAssetReader pulls frames at the target rate and scales to a maximum width;
// ImageIO writes the GIF. No ffmpeg — zero third-party dependencies is the rule.

import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage

enum GIFExporter {

    /// What actually came out, so the caller can say so. A GIF export silently smaller than the
    /// thing the user framed is the complaint this type exists to answer.
    struct Outcome: Sendable {
        let width: Int, height: Int      // pixels
        let fps: Double
        let frames: Int
        let bytes: Int
        /// The budget had to step in — the user did not ask for this reduction and must be told.
        let reducedByBudget: Bool
    }

    /// Runs on a background thread; `progress` 0…1 comes back on the main thread.
    ///
    /// **`maxWidthPoints` is in points, not pixels.** Every other size the user sees is: the label on
    /// the selection, the review window that is deliberately 1:1. Comparing this number against the
    /// video's pixel width made "800" mean 400 points on a Retina display — a GIF **half the width of
    /// the region the user framed**, with nothing to explain it (reported 2026-09-07).
    static func export(mp4: URL, to gif: URL, fps: Int, maxWidthPoints: Int, scale: CGFloat,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> Outcome {
        try await Task.detached(priority: .userInitiated) {
            try exportSync(mp4: mp4, to: gif, fps: fps, maxWidthPoints: maxWidthPoints,
                           scale: scale, progress: progress)
        }.value
    }

    /// How many pixels we may hold at once, as a peak in bytes.
    ///
    /// `CGImageDestinationAddImage` keeps every frame in memory until `Finalize` — ImageIO has no
    /// streaming GIF writer — so this is a real ceiling, not a guess. It used to be **hard-coded at
    /// about 1 GB**, which is a reasonable share of an 8 GB machine and 1/96th of a 96 GB one: on the
    /// larger machine every width setting collapsed to the same small, slow result, and "1080" and
    /// "Original size" produced byte-identical files (measured 2026-09-07).
    ///
    /// A share of physical memory keeps the old behaviour on a small Mac and stops throwing away
    /// resolution on a large one. Physical rather than free memory on purpose: free memory moves
    /// while the export runs, and an export whose quality depends on what else was open is not
    /// something anyone can reason about.
    private static var pixelBudget: Double {
        let bytes = Double(ProcessInfo.processInfo.physicalMemory) / 8
        let peak = min(max(bytes, 1_073_741_824), 6_442_450_944)   // 1 GB … 6 GB
        return peak / 11                                            // measured ~11 bytes per pixel
    }

    private static func exportSync(mp4: URL, to gif: URL, fps: Int, maxWidthPoints: Int,
                                   scale: CGFloat, progress: (@Sendable (Double) -> Void)?) throws -> Outcome {
        let asset = AVURLAsset(url: mp4)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw RecorderError.writerFailed(L("err.noVideoTrack", "The video has no video track"))
        }
        let duration = CMTimeGetSeconds(asset.duration)
        let natural = track.naturalSize.applying(track.preferredTransform)
        let srcW = abs(natural.width), srcH = abs(natural.height)
        // The cap is in points; the video is in pixels. `scale` is what the region was recorded at.
        let maxWidthPixels = CGFloat(maxWidthPoints) * max(scale, 1)
        let k = min(1, maxWidthPixels / max(srcW, 1))
        let outW = Int((srcW * k).rounded()), outH = Int((srcH * k).rounded())

                // **The budget has to be in total pixels, not just a frame count.**
        //
                // `CGImageDestinationAddImage` accumulates every frame in memory and writes nothing until
        // `Finalize` — ImageIO has no streaming GIF writer. Measured 2026-09-06, 60 s @15fps,
        // 800×533:
        //   uncapped   904 frames → peak 3733 MB
        //   capped 450 frames    → peak 2122 MB   (halving frames halves memory, so this is it)
        // autoreleasepool does not help: the memory belongs to ImageIO's buffers, not to temporaries
        // in the loop.
        //
                // So budget `frames × width × height` and **drop the frame rate first, resolution second** —
        // a GIF is a format for short clips, nobody watches a 60-second one to the end, and 7fps
        // still makes the point. Resolution dropped far enough stops being legible, so the frame
        // rate gives way first.
        let budget = pixelBudget
        let minFPS = 5.0
        var effFPS = Double(fps)
        var w = outW, h = outH
        var reduced = false
        if duration > 0 {
            func frames(_ f: Double) -> Double { max(1, (f * duration).rounded(.down)) }
            // Frame rate first
            if frames(effFPS) * Double(w * h) > budget {
                effFPS = max(minFPS, budget / (duration * Double(w * h)))
                reduced = true
            }
            // Still over budget: scale the picture down
            let over = frames(effFPS) * Double(w * h) / budget
            if over > 1 {
                let shrink = (1 / over).squareRoot()
                w = max(160, Int(Double(w) * shrink)); h = max(120, Int(Double(h) * shrink))
                reduced = true
            }
        }
        let frameDelay = 1.0 / effFPS

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw RecorderError.writerFailed(reader.error?.localizedDescription ?? L("err.readFailed", "could not read the video"))
        }

        guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 0, nil) else {
            throw RecorderError.writerFailed(L("err.gifCreate", "could not create the GIF"))
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)


        let frameProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay,
            ],
        ] as CFDictionary

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        var nextTime = 0.0
        var written = 0
        // **One autoreleasepool per frame, without exception.** Without it the sample buffers,
        // CIImages and CGImages all pile up until the loop ends: 60 seconds at 30fps is 1800
        // full-size buffers, and the measured peak was 3.6 GB (caught while stress-testing
        // 2026-09-06). With it, the same clip peaks around 300 MB.
        var reading = true
        while reading {
            autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { reading = false; return }
                let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                guard t + 1e-6 >= nextTime, let pb = CMSampleBufferGetImageBuffer(sample) else { return }
                nextTime += frameDelay
                let ci = CIImage(cvPixelBuffer: pb)
                guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
                CGImageDestinationAddImage(dest, cg, frameProps)
                written += 1
                if duration > 0 { progress?(min(1, t / duration)) }
            }
        }
        guard CGImageDestinationFinalize(dest) else {
            throw RecorderError.writerFailed(L("err.gifWrite", "could not write the GIF"))
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: gif.path)[.size] as? Int) ?? 0
        #if DEBUG
                print("[record] GIF \(written) frames @\(String(format: "%.1f", effFPS))fps \(w)×\(h) " +
              "\(bytes / 1024)KB reduced=\(reduced) → \(gif.lastPathComponent)")
    #endif
        return Outcome(width: w, height: h, fps: effFPS, frames: written,
                       bytes: bytes ?? 0, reducedByBudget: reduced)
    }
}

extension GIFExporter {
    /// One sentence describing a finished GIF, and why it is not what was asked for when it is not.
    @MainActor static func describe(_ o: GIFExporter.Outcome) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(o.bytes), countStyle: .file)
        let base = Lf("gif.made", "%@ · %@ fps · %@",
                      "\(o.width)×\(o.height)", String(format: "%.0f", o.fps), size)
        // The budget reducing the picture is not something the user asked for, so it never happens
        // quietly: a GIF smaller than the region they framed, with no explanation, reads as the app
        // being bad at its job.
        return o.reducedByBudget
            ? base + " · " + L("gif.reduced", "reduced to keep memory in hand")
            : base
    }

}
