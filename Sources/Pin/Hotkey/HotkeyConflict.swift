// Warning about a hotkey conflict before it bites.
//
// Why this file exists: `RegisterEventHotKey` **returns noErr on a conflict** (measured 2026-09-05:
// two processes registered the same key and both were told it succeeded). So the code can never
// find out that a key was taken, and the user pressing it gets no response and no explanation —
// the single easiest place in this app to give up on it.
//
// There are only two things to do about it, and we do both:
//   1. Afterwards: pressing the key in the settings field lights a ✓; no ✓ means it is not ours
//      (HotkeyField).
//   2. Beforehand: we know which common apps claim which keys by default, so if one of them is
//      running we say so outright — that is this file.
//
// The list only records **default** bindings. We have no way to know whether the user changed them
// in that other app, which is why the wording says "may".

import AppKit
import Carbon.HIToolbox

@MainActor
enum HotkeyConflict {

    /// A known rival: while it is running, the keys it claims by default.
    private struct Rival {
        let bundleID: String
        let name: String
        let keys: [Hotkey]
    }

    private static let rivals: [Rival] = [
        // Snipaste's capture key is F1 — we chose the same one deliberately (we are replacing it),
        // so this entry will almost always match.
        Rival(bundleID: "com.Snipaste", name: "Snipaste", keys: [
            .f1,
            Hotkey(keyCode: UInt32(kVK_F1), modifiers: UInt32(optionKey)),
            Hotkey(keyCode: UInt32(kVK_F3), modifiers: UInt32(optionKey)),
        ]),
        // Magpie, from the same shop, holds F2 / ⇧F2. Listed so a user rebinding a key does not
        // collide with our own software.
        Rival(bundleID: "ai.giggle.mdd.magpie", name: "Magpie", keys: [
            Hotkey(keyCode: UInt32(kVK_F2), modifiers: 0),
            Hotkey(keyCode: UInt32(kVK_F2), modifiers: UInt32(shiftKey)),
        ]),
    ]

    /// The name of a running app that claims `hotkey` by default, or nil.
    static func rivalRunning(for hotkey: Hotkey) -> String? {
        guard !hotkey.isDerived else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return rivals.first { running.contains($0.bundleID) && $0.keys.contains(hotkey) }?.name
    }

    /// The one warning worth showing for the current set of bindings, ready for the settings window.
    static func warning() -> String? {
        for a in HotkeyAction.allCases {
            let hk = Preferences.shared.hotkey(for: a)
            if let rival = rivalRunning(for: hk) {
                return Lf("hotkey.rival",
                          "%@ is running and claims %@ by default. macOS reports no error when two apps register the same key — it goes to whichever started first. If pressing it shows no ✓, free the key in %@ or pick another one here.",
                          rival, hk.display, rival)
            }
        }
        return nil
    }
}
