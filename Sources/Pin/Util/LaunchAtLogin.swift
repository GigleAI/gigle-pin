import Foundation
import ServiceManagement

/// Start with the machine, so the hotkey still works after a reboot.
///
/// Without this the product's whole promise — press F1 — quietly stops being true the first time
/// the user restarts, with no error and nothing on screen to explain it. That is the same silent
/// failure the hotkey conflict list exists to prevent, arriving through a more common door: the
/// process simply is not running.
///
/// **The state lives in `SMAppService`, not in our preferences.** macOS shows the login item in
/// System Settings ▸ General ▸ Login Items and lets the user switch it off there. A mirrored
/// `Bool` of our own would then be a lie — our checkbox would read "on" for something the system
/// has already turned off — and we would have no way to notice. So the checkbox reads
/// `SMAppService.mainApp.status` every time it is drawn.
///
/// The one thing worth remembering is whether we have *ever* applied the default, so that a user
/// who turns it off does not find it back on after the next launch.
enum LaunchAtLogin {

    private static let defaultAppliedKey = "launchAtLoginDefaultApplied"

    /// What the system says right now. `.requiresApproval` means macOS is holding the item pending
    /// the user's approval in System Settings — reported as off, because it is off, and saying
    /// otherwise would leave someone waiting for a hotkey that never comes.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True when macOS wants the user to approve the item in System Settings before it will run.
    /// Worth telling the user about: the switch looks like it should be enough, and it is not.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Turn it on or off. Returns whether the system agreed — **the caller must not assume it did**.
    /// Registration fails for a build that is not where macOS expects an app to be (running the
    /// Debug binary straight out of `build/`, most often), and a checkbox that ticks itself while
    /// nothing was registered is worse than one that refuses.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        // The Director is a build we make to film Pin with; it is not something anyone installs,
        // and it must never put itself into a person's login items.
        guard !PinRole.isDirector else { return false }
        do {
            if on {
                // Registering an already-registered app throws rather than being a no-op.
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                // Symmetric with register: unregistering something that was never registered throws
                // "Operation not permitted", which reads like a real failure in the log and is not.
                guard SMAppService.mainApp.status != .notRegistered else { return true }
                try SMAppService.mainApp.unregister()
            }
            print("[login] \(on ? "registered" : "unregistered") → \(describe(SMAppService.mainApp.status))")
            return isEnabled == on
        } catch {
            print("[login] could not \(on ? "register" : "unregister"): \(error.localizedDescription)")
            return false
        }
    }

    /// Switch it on the first time this copy of Pin runs, and never again.
    ///
    /// On by default is the honest choice for a tool whose only entrance is a global hotkey: off
    /// fails invisibly — the user presses the key, nothing happens, and there is nowhere to look —
    /// while on costs one more icon in the menu bar and is one switch away in System Settings,
    /// where macOS lists it whether we mention it or not.
    static func applyDefaultOnce() {
        guard !PinRole.isDirector, isInstalled else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultAppliedKey) else { return }
        defaults.set(true, forKey: defaultAppliedKey)
        set(true)
    }

    /// Is this the copy a person installed, rather than one we are running out of a build folder or
    /// straight off a mounted disk image?
    ///
    /// **Only an installed copy may switch itself on.** `register()` records the path it was called
    /// from, so a test run would put `build/Build/Products/Debug/Gigle Pin.app` into the user's
    /// login items — a path that is deleted and rebuilt all day, leaving them with a login item that
    /// points at nothing. The checkbox still works wherever you are: that is the user asking for it,
    /// which is a different thing from us deciding for them.
    static var isInstalled: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path.hasPrefix("/Applications/")
    }

    private static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .enabled:          "enabled"
        case .requiresApproval: "requiresApproval"
        case .notRegistered:    "notRegistered"
        case .notFound:         "notFound"
        @unknown default:       "unknown(\(s.rawValue))"
        }
    }
}
