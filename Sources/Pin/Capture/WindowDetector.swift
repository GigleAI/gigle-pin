import AppKit
import ApplicationServices

/// A rectangle the crosshair can snap to — either a whole window or, when
/// Accessibility is granted, an individual control inside one.
struct SnapTarget {
    /// Frame in NS (bottom-left origin) global space.
    let frame: NSRect
    let title: String?
    /// Smaller number means closer to the front / deeper in the hierarchy.
    let depth: Int
    /// The process that owns the window, when this came from the window list. It is who the
    /// control-level question is put to.
    var pid: pid_t? = nil
}

/// Reproduces Snipaste's "hover a window and it lights up" behaviour.
///
/// Two sources, in order of precision:
///  1. `CGWindowListCopyWindowInfo` — every on-screen window, no permission
///     needed. Always available, gives window-level rectangles.
///  2. The Accessibility API — walks *inside* the frontmost window to find the
///     specific button/toolbar/text field under the cursor. Needs the user to
///     grant Accessibility, so it is strictly an upgrade, never a requirement.
@MainActor
final class WindowDetector {

    private var windows: [SnapTarget] = []

    /// Re-reads the window list. Call once when the overlay appears — the list
    /// is frozen for the same reason the screenshot is.
    func refresh() {
        windows = Self.onScreenWindows()
    }

    /// The window-level answer, at once and without leaving the process: the frontmost on-screen
    /// window under the point, from the list read when the overlay opened.
    ///
    /// The control-level answer is a separate, asynchronous question — see `refine(at:_:)`. It used
    /// to be asked right here, synchronously: `AXUIElementCopyElementAtPosition` is a round trip
    /// into whichever process owns the pixels under the cursor, and it ran on the main thread on
    /// every mouse move. Median 7 ms, 36 ms seen, and unbounded when that app was busy — the overlay
    /// simply stopped following the mouse until Chrome or Xcode got round to answering (measured
    /// 2026-09-11). That was the "sometimes it sticks" the user felt.
    func target(at point: NSPoint) -> SnapTarget? {
        // Windows are ordered front-to-back, so the first hit is the topmost.
        windows.first { $0.frame.contains(point) }
    }

    // MARK: - CGWindowList

    private static func onScreenWindows() -> [SnapTarget] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier

        return raw.enumerated().compactMap { index, info -> SnapTarget? in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }

            // Only ordinary windows (layer 0). The Dock has a transparent full-screen window, and
            // the menu bar and status items have layers of their own — any of them will swallow the
            // whole screen as a single candidate.
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { return nil }
            // Skip fully transparent shell windows.
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > 0.05, bounds.width > 24, bounds.height > 24 else { return nil }

            let name = info[kCGWindowName as String] as? String
            let owner = info[kCGWindowOwnerName as String] as? String
            return SnapTarget(frame: Geometry.nsRect(fromCG: bounds),
                              title: name?.isEmpty == false ? name : owner,
                              depth: index, pid: pid)
        }
    }

    // MARK: - Accessibility (optional precision pass, off the main thread)

    private static let axQueue = DispatchQueue(label: "ai.gigle.pin.ax", qos: .userInteractive)
    private var axBusy = false
    private var axPending: (point: NSPoint, pid: pid_t, deliver: @MainActor @Sendable (NSPoint, SnapTarget?) -> Void)?

    /// Ask the app that owns the window under the cursor which control is there, and deliver the
    /// answer later, with the point it was asked for so the caller can drop it if the mouse has
    /// moved on.
    ///
    /// **The question goes to that one application, never to the system-wide element.** A
    /// system-wide lookup resolves whatever is topmost at the point — which, with the overlay up, is
    /// our own window — and HIServices serves a lookup into the calling process *on the calling
    /// thread*: it walked `NSApplication.accessibilityHitTest` into `OverlayView.isFlipped` on the
    /// AX queue and the main-actor executor check trapped (crash report 2026-09-11 15:16:08).
    /// Addressing the owning process is also simply the better question: it cannot be answered by
    /// some other floating panel that happens to sit above the window.
    ///
    /// Only the latest question is kept: while one is in flight, newer points replace each other
    /// and the last one is asked when the answer comes back. Asking every one would let a busy app
    /// build a queue of stale questions behind it.
    func refine(at point: NSPoint, app pid: pid_t,
                _ deliver: @escaping @MainActor @Sendable (NSPoint, SnapTarget?) -> Void) {
        guard Self.accessibilityGranted else { return }
        axPending = (point, pid, deliver)
        pumpAX()
    }

    private func pumpAX() {
        guard !axBusy, let pending = axPending else { return }
        axPending = nil
        axBusy = true
        let point = pending.point, pid = pending.pid, deliver = pending.deliver
        let cg = Geometry.cgPoint(fromNS: point)
        Self.axQueue.async {
            let probe = Self.axProbe(at: cg, app: pid)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.axBusy = false
                let target = probe.map { p in
                    SnapTarget(frame: Geometry.nsRect(fromCG: p.rect),
                               title: p.title ?? p.role.map { Self.humanRole($0) },
                               depth: -1)
                }
                deliver(point, target)
                self.pumpAX()
            }
        }
    }

    /// True once the user has ticked Pin under Privacy ▸ Accessibility.
    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility. Only ever called from Settings, never
    /// silently — an unexpected permission dialog is exactly the kind of thing
    /// that makes people quit an app.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// The raw accessibility lookup. Runs on `axQueue`; touches nothing of ours, so it needs no
    /// actor. Returns CG geometry and strings — the conversion to our types happens on the main
    /// actor, where `Geometry` and localisation live.
    nonisolated private static func axProbe(at cg: CGPoint, app pid: pid_t) -> (rect: CGRect, title: String?, role: String?)? {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            if ms > 4 { print("[ax] \(ms)ms") }
        }
        #endif
        let app = AXUIElementCreateApplication(pid)
        // A cap on how long a hung application may keep us waiting. Off the main thread this only
        // delays the control-level frame; without it an unresponsive app could hold the queue
        // indefinitely.
        _ = AXUIElementSetMessagingTimeout(app, 0.2)
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(cg.x), Float(cg.y), &element) == .success,
              let element else { return nil }
        _ = AXUIElementSetMessagingTimeout(element, 0.2)

        // Ignore the AX result when it resolves to the whole window or the whole app — the
        // CGWindowList path carries the window title, while AX only offers "AXWindow".
        let role = attr(element, kAXRoleAttribute) as? String
        if role == kAXWindowRole as String || role == kAXApplicationRole as String { return nil }

        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue,
              CFGetTypeID(posValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        let rect = CGRect(origin: origin, size: size)
        guard rect.width > 8, rect.height > 8, rect.contains(cg) else { return nil }

        // Label: prefer the element's own title or description; the role is mapped to words later.
        let title = (attr(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (attr(element, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (rect, title, role)
    }

    nonisolated private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }

    /// These names appear on the overlay ("clicking here selects this button"), so they follow the
    /// interface language.
    private static func humanRole(_ role: String) -> String {
        switch role {
        case kAXButtonRole as String:      L("role.button", "button")
        case kAXTextFieldRole as String:   L("role.textField", "text field")
        case kAXTextAreaRole as String:    L("role.textArea", "text area")
        case kAXStaticTextRole as String:  L("role.text", "text")
        case kAXImageRole as String:       L("role.image", "image")
        case kAXGroupRole as String:       L("role.group", "group")
        case kAXToolbarRole as String:     L("role.toolbar", "toolbar")
        case kAXScrollAreaRole as String:  L("role.scrollArea", "scroll area")
        case kAXTableRole as String:       L("role.table", "table")
        case kAXListRole as String:        L("role.list", "list")
        case kAXMenuBarRole as String:     L("role.menuBar", "menu bar")
        case "AXWebArea":                  L("role.webArea", "web page")
        default:                           role.replacingOccurrences(of: "AX", with: "")
        }
    }
}
