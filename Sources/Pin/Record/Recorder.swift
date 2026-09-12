// Recording: SCStream from ScreenCaptureKit emits frames, AVAssetWriter writes an H.264 MP4.
// System audio comes through SCStream's audio output (no extra permission); the microphone comes
// through AVCaptureSession (microphone permission).
//
// Frame callbacks arrive on a background queue, all writer state is touched only on `queue`, and
// the main thread does nothing but start and stop.

import AppKit
import AVFoundation
import ScreenCaptureKit

enum RecorderError: Error, LocalizedError {
    case displayNotFound
    case writerFailed(String)
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .displayNotFound: L("err.noDisplay", "Cannot find the display to record.")
        case .writerFailed(let why): Lf("err.writerFailed", "Could not write the video: %@", why)
        case .alreadyRecording: L("err.alreadyRecording", "Already recording.")
        }
    }
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {

    // RecordingSession creates one of these per take. Do not reuse paused time, mute state or
    // delayed media callbacks for another recording. The lifecycle joins start before stop.
    @MainActor private var hasStarted = false

    private let queue = DispatchQueue(label: "ai.gigle.pin.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    /// SCK only emits a frame when the picture changes, so a still screen goes seconds without one.
    /// Producing a constant frame rate means keeping our own beat and writing the most recent frame
    /// again and again.
    private var latestFrame: CVPixelBuffer?
    private var ticker: DispatchSourceTimer?
    private var clockStart: CMTime = .invalid
    private var fps: Int = 30
    private var lastWrittenTick = -1
    /// Total time spent paused. The video timeline **has to have the paused stretches cut out** —
    /// record 10 seconds, stop for 30, and the film should be 10 seconds long, not 40 with 30 of them
    /// frozen.
    private var pausedTotal: CMTime = .zero
    private var pausedAt: CMTime = .invalid
    /// Muting during a recording. **This is not "do not create the track"** — the tracks are fixed at
    /// the moment recording starts and cannot be added later; muting just stops writing samples, so
    /// the result is a silent passage rather than a missing track.
    private var systemAudioMuted = false
    private var micMuted = false
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var micSession: AVCaptureSession?
    private var sessionStarted = false
    private var frameCount = 0
    private(set) var outputURL: URL?
    private(set) var startedAt: Date?

    /// Read on the main thread.
    var isRecording: Bool { queue.sync { stream != nil } }
    /// The stream may already have been cut off by the system (display unplugged, permission
    /// revoked) while **the writing session is still open** and the file unfinished. `isRecording` is
    /// already false by then, so the finishing logic cannot hang off it.
    var hasUnfinishedSession: Bool { queue.sync { writer != nil } }
    var isPaused: Bool { queue.sync { pausedAt.isValid } }

    /// Whether this recording actually has that audio track — the HUD uses it to decide between
    /// "mute" and "turn it on".
    var hasSystemAudio: Bool { queue.sync { systemAudioInput != nil } }
    var hasMic: Bool { queue.sync { micInput != nil } }

    func setSystemAudioMuted(_ m: Bool) { queue.async { self.systemAudioMuted = m } }
    func setMicMuted(_ m: Bool) { queue.async { self.micMuted = m } }

    /// Pause and resume. A demo often means switching window or finding a file, and without a pause
    /// the only option is stopping and starting over — which throws away everything recorded so far.
    func pause() {
        queue.async {
            guard self.pausedAt.isValid == false, self.sessionStarted else { return }
            self.pausedAt = CMClockGetTime(CMClockGetHostTimeClock())
        }
    }

    func resume() {
        queue.async {
            guard self.pausedAt.isValid else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            self.pausedTotal = CMTimeAdd(self.pausedTotal, CMTimeSubtract(now, self.pausedAt))
            self.pausedAt = .invalid
        }
    }

    /// Called on the main thread when a recording is interrupted (display unplugged, permission
    /// revoked).
    var onInterrupted: ((Error) -> Void)?

    // MARK: - Starting

    /// `rect` is in NS global coordinates; `excludingWindowIDs` are our own HUD and frame windows,
    /// which must not be recorded.
    @MainActor
    func start(rect: NSRect, screen: NSScreen, excludingWindowIDs: [CGWindowID], output: URL) async throws {
        guard !hasStarted else { throw RecorderError.alreadyRecording }
        hasStarted = true
        let prefs = Preferences.shared
        let fps = max(10, min(prefs.recordFrameRate, 60))
        let wantsSystemAudio = prefs.recordSystemAudio
        let wantsMic = prefs.recordMicrophone
        let showCursor = prefs.recordShowCursor

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else {
            throw RecorderError.displayNotFound
        }
        let excluded = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        // Selection → coordinates local to this display (top-left origin, in points).
        let cg = Geometry.cgRect(fromNS: rect)
        let displayBounds = CGDisplayBounds(screen.displayID)
        let local = CGRect(x: cg.minX - displayBounds.minX, y: cg.minY - displayBounds.minY,
                           width: cg.width, height: cg.height)
        let scale = screen.backingScaleFactor
        // H.264 needs even dimensions.
        let pw = Int(local.width * scale) & ~1
        let ph = Int(local.height * scale) & ~1
        guard pw >= 16, ph >= 16 else { throw RecorderError.writerFailed(L("err.regionTooSmall", "the region is too small")) }

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = local
        cfg.width = pw
        cfg.height = ph
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.showsCursor = showCursor
        // Let SCK do RGB→YUV itself: it knows the screen's colour space and produces standard
        // video-range YUV. We used to hand it BGRA and let VideoToolbox convert, and it wrote
        // full-range data tagged as tv — so the player expanded the range a second time, crushing
        // the shadows and clipping the highlights. What that looks like is "blurry".
        // Measured: the BGRA path gave 29.6dB PSNR; this path, see docs. The theoretical ceiling for
        // 4:2:0 is around 46dB.
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 6
        cfg.capturesAudio = wantsSystemAudio
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        // Screen content is text and thin lines, with far more high-frequency detail than a camera
        // picture. At 0.12 bpp a measured 1080p keyframe got only ~150KB (the same picture as PNG is
        // 350KB), and anything moving broke into blocks.
        let bitrate = max(4_000_000, Int(Double(pw * ph) * Double(fps) * 0.25))
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pw,
            AVVideoHeightKey: ph,
            // Tag it explicitly, or all four colour fields in the file read unknown and the player
            // has to guess.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.writerFailed(L("err.noVideoInput", "could not add a video track")) }
        writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: pw,
            kCVPixelBufferHeightKey as String: ph,
        ])

        var sysAudio: AVAssetWriterInput?
        if wantsSystemAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) { writer.add(a); sysAudio = a }
        }
        var mic: AVAssetWriterInput?
        var micSession: AVCaptureSession?
        if wantsMic, Permissions.microphone == .authorized,
           let device = AVCaptureDevice.default(for: .audio),
           let input = try? AVCaptureDeviceInput(device: device) {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.aacSettings)
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a); mic = a
                let s = AVCaptureSession()
                if s.canAddInput(input) { s.addInput(input) }
                let out = AVCaptureAudioDataOutput()
                out.setSampleBufferDelegate(self, queue: queue)
                if s.canAddOutput(out) { s.addOutput(out) }
                micSession = s
            }
        }

        guard writer.startWriting() else {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? L("err.startWriting", "the writer could not start"))
        }

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if wantsSystemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }

        queue.sync {
            self.writer = writer
            self.videoInput = videoInput
            self.pixelAdaptor = adaptor
            self.latestFrame = nil
            self.fps = fps
            self.lastWrittenTick = -1
            self.clockStart = .invalid
            self.systemAudioInput = sysAudio
            self.micInput = mic
            self.micSession = micSession
            self.sessionStarted = false
            self.frameCount = 0
            self.outputURL = output
            self.startedAt = Date()
        }
        micSession?.startRunning()
        try await stream.startCapture()
        queue.sync { self.stream = stream }
        #if DEBUG
                print("[record] start \(pw)×\(ph)@\(fps)fps sysAudio=\(wantsSystemAudio) mic=\(mic != nil) → \(output.lastPathComponent)")
    #endif
    }

    private static var aacSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ] }

    // MARK: - Stopping

    /// Returns the MP4 on disk. With no frames captured it deletes the empty file and returns nil.
    @MainActor
    func stop() async -> URL? {
        let stream: SCStream? = queue.sync { let s = self.stream; self.stream = nil; return s }
        if let stream { try? await stream.stopCapture() }
        // When the system cuts the stream off, `didStopWithError` has already cleared it. This used
        // to return early there, and so: the file was never finalised (an unplayable MP4), the beat
        // timer kept pushing frames in at the frame rate, and the microphone session was never
        // closed. The condition is now "is there still a writer".
        let hasWriter = queue.sync { self.writer != nil }
        guard hasWriter else { return nil }
        let (url, frames): (URL?, Int) = await withCheckedContinuation { cont in
            queue.async {
                self.ticker?.cancel()
                self.ticker = nil
                self.micSession?.stopRunning()
                self.micSession = nil
                let url = self.outputURL
                let frames = self.frameCount
                guard let writer = self.writer, self.sessionStarted else {
                    self.writer = nil
                    if let url { try? FileManager.default.removeItem(at: url) }
                    cont.resume(returning: (nil, frames)); return
                }
                self.videoInput?.markAsFinished()
                self.systemAudioInput?.markAsFinished()
                self.micInput?.markAsFinished()
                writer.finishWriting {
                    self.queue.async {
                        let ok = writer.status == .completed
                        #if DEBUG
                                                print("[record] finished \(frames) frames status=\(writer.status.rawValue) \(writer.error.map { "\($0)" } ?? "")")
                        #endif
                        self.writer = nil
                        self.videoInput = nil
                        self.pixelAdaptor = nil
                        self.latestFrame = nil
                        self.systemAudioInput = nil
                        self.micInput = nil
                        cont.resume(returning: (ok ? url : nil, frames))
                    }
                }
            }
        }
        _ = frames
        // System audio and the microphone are two writer inputs, and with both on the file gets two
        // audio tracks. Most players play only the first, so the other one was recorded for nothing —
        // flatten to one before handing the file over.
        guard let url else { return nil }
        return await AudioMixdown.flattenIfNeeded(url)
    }

    /// Shift a sample's timestamp back by `pausedTotal` — the video timeline has the paused stretches
    /// cut out, and audio that does not move with it drifts further off with every pause.
    private func shifted(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
        guard CMTimeCompare(pausedTotal, .zero) > 0 else { return sample }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil,
                                               entriesNeededOut: &count)
        guard count > 0 else { return sample }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings,
                                               entriesNeededOut: nil)
        for i in 0..<count {
            timings[i].presentationTimeStamp =
                CMTimeSubtract(timings[i].presentationTimeStamp, pausedTotal)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeSubtract(timings[i].decodeTimeStamp, pausedTotal)
            }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timings,
                                              sampleBufferOut: &out)
        return out
    }

    // MARK: - Constant-frame-rate writing (on queue)

    private func startTicker() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / Double(fps)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        ticker = t
    }

    private func tick() {
        guard let writer, writer.status == .writing, sessionStarted, !pausedAt.isValid,
              let adaptor = pixelAdaptor, let input = videoInput, let frame = latestFrame else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // Subtract the accumulated pause so the beat lines up — otherwise one pause makes tickIndex
        // jump a long way, those frame numbers are never filled, and a player reads it as dropped
        // frames.
        let elapsed = CMTimeGetSeconds(CMTimeSubtract(CMTimeSubtract(now, clockStart), pausedTotal))
        // Round to the beat, fill a missed one (writing the same frame twice), never go backwards.
        let tickIndex = Int((elapsed * Double(fps)).rounded(.down))
        guard tickIndex > lastWrittenTick, input.isReadyForMoreMediaData else { return }
        let pts = CMTimeAdd(clockStart, CMTime(value: CMTimeValue(tickIndex), timescale: CMTimeScale(fps)))
        if adaptor.append(frame, withPresentationTime: pts) {
            lastWrittenTick = tickIndex
            frameCount += 1
        }
    }

    // MARK: - SCStreamOutput (on queue)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let writer, writer.status == .writing, sample.isValid else { return }
        switch type {
        case .screen:
            // SCK emits empty "nothing changed" frames; take only complete ones.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: statusRaw), status == .complete,
                  let pb = CMSampleBufferGetImageBuffer(sample)
            else { return }
            latestFrame = pb
            if !sessionStarted {
                // The timeline starts at the first frame and runs on the system clock, which is also
                // where the audio PTS lives.
                clockStart = CMClockGetTime(CMClockGetHostTimeClock())
                writer.startSession(atSourceTime: clockStart)
                sessionStarted = true
                startTicker()
            }
        case .audio:
            guard sessionStarted, !pausedAt.isValid, !systemAudioMuted,
                  let a = systemAudioInput, a.isReadyForMoreMediaData else { return }
            // Audio PTS runs on the system clock while the video side has the pauses cut out;
            // without subtracting the same amount here the two drift apart.
            if let p = Self.peak(of: sample) { note(level: p, system: true) }
            a.append(shifted(sample) ?? sample)
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        #if DEBUG
                print("[record] stream interrupted \(error)")
        #endif
        queue.async {
            self.stream = nil
            // No more frames, so leaving the beat timer running would push the last one into the
            // file forever.
            self.ticker?.cancel(); self.ticker = nil
        }
        DispatchQueue.main.async { self.onInterrupted?(error) }
    }

    #if DEBUG
    /// Test entry point: pretend the system cut the stream. The real events (unplugging a display,
    /// revoking Screen Recording) cannot be produced from a script.
    func debugSimulateInterruption() {
        let s = queue.sync { self.stream }
        guard let s else { return }
        self.stream(s, didStopWithError: RecorderError.displayNotFound)
    }
    #endif

    // MARK: - Microphone (on queue)

    /// The loudest sample in a buffer, 0…1, or nil when the format is not one we can read.
    ///
    /// Two sources, two formats: ScreenCaptureKit hands over 48k float planar, the microphone
    /// whatever the device natively speaks. Rather than convert, read the description and handle the
    /// two that actually turn up — 32-bit float and 16-bit signed integer. Anything else returns nil
    /// and the meter simply does not move, which is honest; a made-up number would say the
    /// microphone is working when nobody knows whether it is.
    static func peak(of sample: CMSampleBuffer) -> Float? {
        guard let fd = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee else { return nil }
        // **Ask how big the list needs to be, then allocate exactly that.** Guessing a generous size
        // and passing it does not work: the call comes back `ArrayTooSmall` (-12737) even when the
        // buffer handed in is larger than the size it reports needing. The documented shape is two
        // calls, and the first one — with a null list — is the one that answers the question.
        var sizeOut = 0
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, bufferListSizeNeededOut: &sizeOut, bufferListOut: nil,
                bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: nil) == noErr, sizeOut > 0 else { return nil }
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: sizeOut, alignment: 16)
        defer { listPtr.deallocate() }
        let list = listPtr.assumingMemoryBound(to: AudioBufferList.self)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sample, bufferListSizeNeededOut: nil, bufferListOut: list,
                bufferListSize: sizeOut, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer) == noErr else { return nil }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = asbd.mBitsPerChannel
        var loudest: Float = 0
        for buf in UnsafeMutableAudioBufferListPointer(list) {
            guard let raw = buf.mData else { continue }
            if isFloat && bits == 32 {
                let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let p = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<n { loudest = max(loudest, abs(p[i])) }
            } else if !isFloat && bits == 16 {
                let n = Int(buf.mDataByteSize) / MemoryLayout<Int16>.size
                let p = raw.assumingMemoryBound(to: Int16.self)
                for i in 0..<n { loudest = max(loudest, abs(Float(p[i])) / 32768) }
            } else {
                return nil
            }
        }
        return min(1, loudest)
    }

    /// Report the two levels for the HUD's meters. Called on the main actor, at most `levelHz` times
    /// a second — a meter redrawn on every buffer is both wasteful and unreadable.
    nonisolated(unsafe) var onAudioLevel: (@MainActor (_ system: Float, _ mic: Float) -> Void)?
    private static let levelHz = 15.0

    /// Levels decay rather than snapping to zero between buffers: a bar that blinks off in the gaps
    /// reads as "not working", which is the exact opposite of what this is for.
    private func note(level: Float, system: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if system { self.systemLevel = max(level, self.systemLevel) }
            else { self.micLevel = max(level, self.micLevel) }
            let now = CACurrentMediaTime()
            guard now - self.lastLevelSent >= 1 / Self.levelHz else { return }
            self.lastLevelSent = now
            let s = self.systemLevel, m = self.micLevel
            self.systemLevel *= 0.55; self.micLevel *= 0.55
            #if DEBUG
            print(String(format: "[audio] level sys=%.3f mic=%.3f", s, m))
            #endif
            Task { @MainActor [weak self] in self?.onAudioLevel?(s, m) }
        }
    }
    private var systemLevel: Float = 0
    private var micLevel: Float = 0
    private var lastLevelSent: CFTimeInterval = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sessionStarted, !pausedAt.isValid, !micMuted,
              let m = micInput, m.isReadyForMoreMediaData else { return }
        if let p = Self.peak(of: sample) { note(level: p, system: false) }
        m.append(shifted(sample) ?? sample)
    }
}
