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

    /// Best rectangle to snap to for a cursor position in NS global space,
    /// or `nil` when the cursor is over bare desktop.
    func target(at point: NSPoint) -> SnapTarget? {
        if let element = Self.accessibilityElement(at: point) {
            return element
        }
        // Windows are ordered front-to-back, so the first hit is the topmost.
        return windows.first { $0.frame.contains(point) }
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
                              depth: index)
        }
    }

    // MARK: - Accessibility (optional precision pass)

    /// True once the user has ticked Jay under Privacy ▸ Accessibility.
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

    private static func accessibilityElement(at point: NSPoint) -> SnapTarget? {
        guard accessibilityGranted else { return nil }

        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let cg = Geometry.cgPoint(fromNS: point)
        guard AXUIElementCopyElementAtPosition(system, Float(cg.x), Float(cg.y), &element) == .success,
              let element else { return nil }

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

        // Label: prefer the element's own title or description, then fall back to a readable role.
        let title = (attr(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (attr(element, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? role.map(humanRole)
        return SnapTarget(frame: Geometry.nsRect(fromCG: rect), title: title, depth: -1)
    }

    private static func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
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
