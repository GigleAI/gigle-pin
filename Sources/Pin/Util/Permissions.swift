// Three system permissions: Screen Recording (captures and video, required), Accessibility
// (snapping to controls inside a window, optional) and the microphone (narration, optional).

import AppKit
import ApplicationServices
import AVFoundation

enum Permissions {
    static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// The first call shows the system prompt; later ones only report the current state.
    @discardableResult
    static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Watch for Accessibility being granted and call back on the main thread once it is.
    ///
    /// Why poll: **nothing notifies us** when the user ticks the box in System Settings. Without
    /// polling the button keeps looking unauthorised, so the user ticks it, comes back, finds
    /// nothing has changed, and concludes the app is broken — when all that was missing was
    /// another check.
    ///
    /// Also: ticking it often does not take effect for an **already running** process (long-standing
    /// TCC behaviour). So the polling has a timeout, and on timeout we say "restart Pin" rather than
    /// leaving the user waiting.
    @MainActor
    @discardableResult
    static func watchAccessibility(timeout: TimeInterval = 90,
                                   onResult: @escaping @MainActor (Bool) -> Void) -> Timer {
        let deadline = Date().addingTimeInterval(timeout)
        // Do not capture the timer in its own closure (Swift 6 reads that as sending across an
        // isolation boundary); a box holds it and invalidates it instead.
        let box = TimerBox()
        box.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                if AXIsProcessTrusted() {
                    box.stop(); onResult(true)
                } else if Date() > deadline {
                    box.stop(); onResult(false)
                }
            }
        }
        return box.timer!
    }

    @MainActor
    private final class TimerBox {
        var timer: Timer?
        func stop() { timer?.invalidate(); timer = nil }
    }

    static func requestAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    enum Pane: String {
        case screenCapture = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"
    }

    static func openSystemSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Login Items lives outside Privacy & Security, so it needs its own identifier rather than the
    /// `preference.security?pane` shape above. Verified 2026-09-07: opens "Login Items & Extensions".
    static func openLoginItems() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
