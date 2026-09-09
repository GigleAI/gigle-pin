import Foundation

/// Which copy of Pin this is. The shipping build is `capture`; the one that
/// `scripts/build-director.sh` produces is `director` — same code, different bundle ID and URL
/// scheme, built so an AI can record **Pin itself** (Pin leaves its own overlay and toolbars out
/// of a recording, so filming a Pin demo takes a second process). The Director defaults to the F9
/// family (F9 / ⇧F9 / ⌘⇧F9), clear of the shipping build's F1, so both can run at once.

enum PinRole {
    static let raw = Bundle.main.object(forInfoDictionaryKey: "PinRole") as? String ?? "capture"
    static let isDirector = raw == "director"
    /// The URL scheme this copy declares (pin for the shipping build, pindirector for the Director).
    static let urlSchemes: [String] = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    }()
}
