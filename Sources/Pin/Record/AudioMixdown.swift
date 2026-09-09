// Flatten two audio tracks into one.
//
// System audio comes through SCStream and the microphone through AVCaptureSession — two separate
// `AVAssetWriterInput`s — so with both enabled the mp4 carries **two AAC tracks** (measured
// 2026-09-05: stream 1 and stream 2). QuickTime plays the first as the default, and so do browsers,
// Discord and most upload sites. The user believes they recorded narration and system audio
// together, ships the file, and only one of them arrives — **with nothing anywhere saying so**.
//
// Mixing live would mean resampling and format matching (SCK gives 48k float planar, the mic gives
// whatever the device does) with plenty of ways to get it wrong. Flattening afterwards is far
// simpler, at the cost of one more pass of I/O: `AVAssetReaderAudioMixOutput` mixes the tracks down
// to a single PCM stream by itself, and the **video track passes through unencoded**
// (`outputSettings: nil`), so not a frame of quality is lost.

import AVFoundation

enum AudioMixdown {

    /// Returns the file untouched when there is one audio track or none; flattens and replaces it
    /// when there are two.
    static func flattenIfNeeded(_ url: URL) async -> URL {
        let asset = AVURLAsset(url: url)
        let audio = asset.tracks(withMediaType: .audio)
        guard audio.count > 1, let video = asset.tracks(withMediaType: .video).first else { return url }
        do {
            let tmp = url.deletingLastPathComponent()
                .appendingPathComponent("." + url.deletingPathExtension().lastPathComponent + ".mix.mp4")
            try? FileManager.default.removeItem(at: tmp)
            try await mix(asset: asset, audio: audio, video: video, to: tmp)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            #if DEBUG
                        print("[record] two audio tracks flattened into one")
            #endif
            return url
        } catch {
            #if DEBUG
                        print("[record] mixdown failed, keeping both tracks: \(error)")
            #endif
                        return url   // a failed mixdown must never cost the recording
        }
    }

    private static func mix(asset: AVURLAsset, audio: [AVAssetTrack], video: AVAssetTrack,
                            to out: URL) async throws {
        let reader = try AVAssetReader(asset: asset)
                let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: nil)   // no decoding
        let audioOut = AVAssetReaderAudioMixOutput(audioTracks: audio, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
        ])
        reader.add(videoOut)
        reader.add(audioOut)

        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                         // `as!` is guaranteed by the compiler here: writing it as
                                         // "conditional downcast to CoreFoundation type will always succeed"。
                                         sourceFormatHint: video.formatDescriptions.first as! CMFormatDescription?)
        videoIn.expectsMediaDataInRealTime = false
        let audioIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        audioIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        writer.add(audioIn)

        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)

        // A serial queue each, with `requestMediaDataWhenReady` handling backpressure; carry on once
        // both have drained. Not a TaskGroup — these AVFoundation objects are not Sendable.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let lock = NSLock()
            var left = 2
            let done = {
                lock.lock(); left -= 1; let all = left == 0; lock.unlock()
                if all { cont.resume() }
            }
            pump(videoIn, from: videoOut, label: "video", done: done)
            pump(audioIn, from: audioOut, label: "audio", done: done)
        }
        guard reader.status != .failed else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func pump(_ input: AVAssetWriterInput, from output: AVAssetReaderOutput,
                            label: String, done: @escaping () -> Void) {
        let q = DispatchQueue(label: "ai.gigle.pin.mixdown." + label)
        input.requestMediaDataWhenReady(on: q) {
            while input.isReadyForMoreMediaData {
                guard let sample = output.copyNextSampleBuffer() else {
                    input.markAsFinished()
                    done()
                    return
                }
                input.append(sample)
            }
        }
    }
}
