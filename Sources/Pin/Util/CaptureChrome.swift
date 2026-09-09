// "This window is the capture tool's own interface and does not belong in the picture."
//
// It used to exclude the **whole Pin app** while freezing the screen (`excludingApplications:`),
// which meant none of Pin's windows could be captured — the settings window included (Tim,
// 2026-09-05: "so our own settings window is the one thing we cannot screenshot?"). Writing docs,
// demos all need to capture our own interface, so that limit made no sense.
//
// Now only the **session chrome** is excluded: the selection overlay, the toolbars, the recording
// HUD, hint bubbles and permission cards. The settings window, the welcome window, the review
// window and pins are real things on the screen, so **what you see is what you get**.
//
// Why pins in particular belong in the picture: parking a reference image beside your work and
// then capturing the whole area is a common way to use this. Whatever is on screen should be in
// the shot.

import AppKit

/// A window carrying this marker is left out of captures and recordings.
protocol CaptureChrome: NSWindow {}

@MainActor
enum CaptureChromeRegistry {
    /// Every window number that currently needs excluding.
    static var windowIDs: [CGWindowID] {
        NSApp.windows.compactMap { w in
            guard w is CaptureChrome, w.isVisible else { return nil }
            return CGWindowID(w.windowNumber)
        }
    }
}
