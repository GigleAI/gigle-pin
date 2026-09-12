import AppKit

/// Owns one review and every file action requested from it. A closed review may finish its export,
/// but cannot clear or retarget the coordinator of a newer review.
@MainActor
final class ReviewCoordinator {
    private(set) var reviewWindow: ReviewWindow?
    private let region: RecordingRegion?
    private let actions = ReviewActions()
    var onClosed: (() -> Void)?
    var onRedo: ((RecordingRegion) -> Void)?

    init(region: RecordingRegion?) { self.region = region }

    func close() { reviewWindow?.close() }

    /// Open the review window when recording stops: paused on the last frame, with a scrubber, playback
    /// speed and annotations you can add to the picture, and the action buttons bottom-right. The thing
    /// you most want to confirm the moment recording stops is whether it recorded, not where the file
    /// is.
    /// While the review window is open, Pin becomes an ordinary app (Dock icon, ⌘Tab) and goes back to
    /// the menu bar when it closes.
    ///
    /// A capture tool is a press-and-go, so a permanent Dock icon is wasted space and the app is
    /// normally `LSUIElement`. But a review window is something you sit with and work against, so
    /// **switching away and back is inevitable** — and a menu bar app is in neither ⌘Tab nor the Dock,
    /// so once you switch away the window sinks behind everything and cannot be reached again. It
    /// looks like it disappeared by itself (Tim's diagnosis on 2026-09-05 was right: not a misclick,
    /// but switching away with no way back).
    private func updateActivationPolicy() {
        let wantsRegular = reviewWindow != nil
        let now = NSApp.activationPolicy()
        guard wantsRegular != (now == .regular) else { return }
        NSApp.setActivationPolicy(wantsRegular ? .regular : .accessory)
        if wantsRegular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Reopen the review window for the most recent recording, from the menu bar.
    func show(for url: URL, pending: Bool = false) {
        // Pass the point size of the original recorded region — the video stores **pixels** (twice the
        // points on Retina), and using that as the window's point size makes it twice as large before
        // being squeezed back, so it no longer matches the region that was framed.
        let win = ReviewWindow(url: url, regionSize: region?.rect.size, pending: pending)
        win.onAction = { [weak self, weak win] action in
            guard let self, let win else { return }
            self.actions.run {
                var target = win.deliverable
                // An unsaved take is kept **before** anything else happens to it — the burned-in copy
                // and the GIF land beside the kept file, and a copied path points at something that
                // is still there tomorrow.
                if win.isPending, action.keeps {
                    do {
                        let dst = try UnsavedRecordings.keep(url)
                        win.markKept(at: dst)
                        Preferences.shared.lastRecording = dst
                        #if DEBUG
                        print("[record] kept → \(dst.path)")
                        #endif
                    } catch {
                        let what = L("toast.saveFailed", "Could not save — check that the save location still exists")
                        win.finish(what, on: action)
                        let r = win.frame
                        Toast.show(what, near: r, on: NSScreen.screens.first { $0.frame.intersects(r) } ?? Geometry.screenUnderMouse)
                        return
                    }
                }
                // With annotations, burn them into the video first and act on the new file — what gets
                // copied should be the annotated one
                if win.hasAnnotations, action != .delete, action != .redo {
                    // Burning takes a few seconds, and that stretch cannot be silent either — otherwise
                    // pressing "copy file" gives silence and then, out of nowhere, "copied", with those
                    // seconds in between unexplained.
                    win.begin(L("review.burning", "Burning your annotations into the video…"), on: action)
                    target = await win.burnIfNeeded { _ in }
                    // On failure `burnIfNeeded` returns the source file unchanged — which means the
                    // user is holding the version **without** the annotations, having just drawn them,
                    // and is unlikely to check frame by frame. Quietly losing a layer of content is far
                    // worse than reporting an error.
                    if target == url {
                        let r = win.frame
                        let screen = NSScreen.screens.first { $0.frame.intersects(r) } ?? Geometry.screenUnderMouse
                        Toast.show(L("err.burnFailed", "The annotations could not be burned in — this is the original recording"), near: r, on: screen)
                    }
                }
                await self.handleResult(action, url: target == url ? win.deliverable : target, original: url, window: win)
            }
        }
        win.onClosed = { [weak self, weak win] in
            guard let self, let win else { return }
            self.reviewWindow = nil
            self.updateActivationPolicy()
            self.onClosed?()
            self.actions.close {
                guard win.startedPending else { return }
                try? FileManager.default.removeItem(at: url)
                if win.kept == nil, !win.closesQuietly {
                    #if DEBUG
                    print("[record] discarded (not saved) \(url.lastPathComponent)")
                    #endif
                    let r = win.frame
                    Toast.show(L("review.discarded", "Not saved — that take is gone"),
                               detail: L("review.discardedHow", "Settings ▸ Recording can keep every take automatically"),
                               near: r, on: NSScreen.screens.first { $0.frame.intersects(r) } ?? Geometry.screenUnderMouse)
                }
            }
        }
        reviewWindow = win
        if !pending { Preferences.shared.lastRecording = url }
        updateActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        win.showAll()
        // A capture goes to the clipboard automatically by default (`copyAfterCapture`), while stopping
        // a recording used to do nothing at all — two main paths in one tool treated differently, and
        // you had to know about ⏎ before you could send what you just recorded.
        // Saying so is not optional: a clipboard that changes without a word is its own small betrayal.
        if pending {
            // No automatic copy of a file that is about to vanish; ⏎ keeps it and then copies it
            win.say(L("review.unsavedHint", "Not saved yet — S keeps it, and so does anything that sends it out"), on: .save, seconds: 6)
        } else if Preferences.shared.copyAfterRecord {
            let pb = NSPasteboard.general
            pb.clearContents(); pb.writeObjects([url as NSURL])
            win.markAutoCopied()
            win.say(L("review.autoCopied", "The file is on your clipboard — ⌘V to send it"), on: .copyFile, seconds: 5)
        }
    }

    private func handleResult(_ action: ReviewWindow.Action, url: URL, original: URL, window: ReviewWindow) async {
        let pb = NSPasteboard.general
        func close() {
            window.close()
        }
        // These take a while to run (converting to GIF, picking key frames), and a failure **has to be
        // reported** — pressing a button, waiting, and having nothing happen is worse than an error,
        // and leaves the user with no idea whether to press it again.
        func failed(_ what: String) {
            window.finish(what, on: action)
            let r = window.frame
            let screen = NSScreen.screens.first { $0.frame.intersects(r) } ?? Geometry.screenUnderMouse
            Toast.show(what, near: r, on: screen)
        }
        // Success has to speak too, and say **where it went**. These used to play a `Pop` and nothing
        // else, which is no feedback at all on a muted machine; and the contact sheet and the GIF each
        // drop a file beside the recording, which the user otherwise never learns about (Tim,
        // 2026-09-06).
        func done(_ what: String) {
            #if DEBUG
            print("[review] done \(action)")
            #endif
            window.finish(what, on: action)
            NSSound(named: "Pop")?.play()
        }
        switch action {
        case .save:
            // The keeping itself happened in `onAction`; this is the receipt
            done(Lf("review.kept", "Saved to %@", readablePath(url)))
        case .copyFile:
            pb.clearContents(); pb.writeObjects([url as NSURL])
            done(L("review.copiedFile", "File copied — ⌘V into Slack, Mail or Finder to send it"))
        case .copyPath:
            pb.clearContents(); pb.setString(url.path, forType: .string)
            done(Lf("review.copiedPath", "Path copied: %@", readablePath(url)))
        case .contactSheet:
            window.begin(L("review.sheeting", "Picking the key frames and laying them out…"), on: action)
            do {
                guard let sheet = try? await ContactSheet.make(from: url),
                      let tiff = sheet.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    failed(L("err.exportFailed", "Export failed")); return
                }
                let out = url.deletingPathExtension().appendingPathExtension("frames.png")
                do { try png.write(to: out, options: .atomic) }
                catch { failed(L("err.exportFailed", "Export failed")); return }
                pb.clearContents(); pb.setData(png, forType: .png)
                done(Lf("review.sheetDone", "Contact sheet copied, ⌘V it straight to an AI · also saved to %@", readablePath(out)))
            }
        case .gif:
            guard url.pathExtension.lowercased() != "gif" else {
                // The early return has to speak as well — otherwise it is the textbook "I pressed it and
                // nothing happened"
                window.say(L("review.alreadyGIF", "This is already a GIF"), on: action); return
            }
            window.begin(L("review.gifing", "Making the GIF — long clips take a moment…"), on: action)
            do {
                let gif = url.deletingPathExtension().appendingPathExtension("gif")
                guard let out = try? await GIFExporter.export(
                    mp4: url, to: gif,
                    fps: Preferences.shared.gifFrameRate,
                    maxWidthPoints: Preferences.shared.gifMaxWidth,
                    scale: region?.scale ?? NSScreen.main?.backingScaleFactor ?? 2) else {
                    // Clear the half-finished file: ImageIO writes nothing until the end, so a failure
                    // partway leaves an unopenable .gif lying beside the recording, and the user takes it
                    // for the result.
                    try? FileManager.default.removeItem(at: gif)
                    failed(L("err.exportFailed", "Export failed")); return
                }
                pb.clearContents(); pb.writeObjects([gif as NSURL])
                done(Lf("review.gifDone2", "GIF copied · %@ · saved to %@", GIFExporter.describe(out), readablePath(gif)))
            }
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([url])
                        // Finder brings itself to the front, so there is nothing more to say here
        case .redo:
            window.closesQuietly = true
            close()
            // To the Trash, not deleted outright. "Re-record" and "delete" are adjacent buttons on the
            // action bar, and it used to be that "re-record" **deleted permanently** while "delete" went
            // to the Trash — the one that sounds harmless was the irreversible one. Botching a take is
            // routine, and so is hitting the wrong button; both should be recoverable.
            // An unsaved take has nothing in the Trash's sense to recover: its cache copy is removed
            // by the close, and only a kept link is worth trashing.
            let victim = window.startedPending ? window.kept : original
            if let victim, (try? FileManager.default.trashItem(at: victim, resultingItemURL: nil)) == nil {
                try? FileManager.default.removeItem(at: victim)   // fallback when there is no Trash
                                                                  // (an external volume)
            }
            if let region {
                try? await Task.sleep(for: .milliseconds(250))
                onRedo?(region)
            }
        case .delete:
            // Note the window's position before closing it — the notice has to appear where it was
            let where_ = window.frame
            window.closesQuietly = true
            close()
            // Unsaved and never kept: the close removed the cache copy, and there is nothing to trash
            guard let victim = window.startedPending ? window.kept : original else { return }
            if (try? FileManager.default.trashItem(at: victim, resultingItemURL: nil)) == nil {
                // Failing to delete and saying nothing is the worst case: the window closes, the file
                // stays where it was, and the user believes it is gone. Seeing it in the save directory
                // later, they assume they misremembered.
                let screen = NSScreen.screens.first { $0.frame.intersects(where_) } ?? Geometry.screenUnderMouse
                Toast.show(L("err.deleteFailed", "Could not move it to the Trash"),
                           detail: readablePath(victim), near: where_, on: screen)
            }
        }
    }

}
