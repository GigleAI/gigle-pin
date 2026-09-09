// Global hotkeys. The defaults (all rebindable in Settings → Hotkeys, each row with a ↺ to
// restore):
//
//   F1        = capture
//   F1 twice  = record (within 450ms)
//   ⇧F1       = pin the clipboard
//   ⌘⇧F1      = hide / show every pin
//
// **Why F1**: Pin is here to replace Snipaste, and F1 is Snipaste's capture key — taking it over
// means the user's muscle memory does not change for a single day (decided by Tim, 2026-09-05; an
// earlier version used F3 to coexist with Snipaste instead). The cost is that with both installed
// they fight: `RegisterEventHotKey` **reports success on a conflict**, F1 goes to whichever process
// started first, and neither can tell. So the hotkeys pane checks whether Snipaste is running and
// says so outright rather than leaving the user to guess.
// GigleMDD-Magpie, on the same machine, holds F2 / ⇧F2 and does not clash.
//
// A bare F1 on a MacBook is the brightness key and produces no key event at all, so anything
// reaching here is necessarily Fn+F1 (or the user turned on "standard function keys"). Most external
// keyboards send the plain F keys.
//
// Why recording is a double-tap rather than another modifier combination: on a MacBook the Fn key is
// already held, so a second tap is one extra press. But it **can** be given a key of its own — the
// recording row in Settings is itself recordable, showing "double-tap F1" by default, and pressing a
// combination into it makes it independent; ↺ puts it back to following.
//
import AppKit
import Carbon.HIToolbox

/// One key combination, in the form Carbon wants.
struct Hotkey: Equatable, Codable {
    var keyCode: UInt32
        var modifiers: UInt32   // Carbon modifier mask (cmdKey / shiftKey / ...)

    static let f1        = Hotkey(keyCode: UInt32(kVK_F1), modifiers: 0)
    static let shiftF1   = Hotkey(keyCode: UInt32(kVK_F1), modifiers: UInt32(shiftKey))
    static let cmdShiftF1 = Hotkey(keyCode: UInt32(kVK_F1), modifiers: UInt32(cmdKey | shiftKey))
    // Pin Director (the second copy, for an AI recording Pin itself) defaults to the F9 family, clear
    // of the shipping build's F1, so the two can run at once without fighting. **What is shown has to
    // be what is bound** — the Director once registered no hotkeys while its menu still displayed F1,
    // and Tim spotted it immediately (2026-09-06).
    static let f9        = Hotkey(keyCode: UInt32(kVK_F9), modifiers: 0)
    static let shiftF9   = Hotkey(keyCode: UInt32(kVK_F9), modifiers: UInt32(shiftKey))
    static let cmdShiftF9 = Hotkey(keyCode: UInt32(kVK_F9), modifiers: UInt32(cmdKey | shiftKey))

    /// "No key of its own; follows another." Only recording uses it — by default it is the second tap
    /// of the capture key.
    /// A sentinel rather than `Optional<Hotkey>`: this way it stores in preferences and restores with
    /// ↺ like anything else, and is simply skipped at `bind` time (`RegisterEventHotKey` given 0xFFFF
    /// would fail, and would mean nothing anyway).
    static let derived = Hotkey(keyCode: 0xFFFF, modifiers: 0)
    var isDerived: Bool { self == .derived }

    /// For display in the menu bar, e.g. "⇧F3".
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// The display name of a key. The settings field is "click once, then press any combination", so
    /// this **cannot cover only a few F keys** — one missing mapping and pressing ⌘K shows `⌘Key40`,
    /// which looks broken (found 2026-09-06 05:42: only F1–F6, Esc and Space were mapped, so F7 and
    /// above, letters, digits and arrows all came out as `Key<code>`).
    ///
    /// Letters and digits depend on the keyboard layout, so ask the system's `UCKeyTranslate` about
    /// the current one — that way pressing Z on a German QWERTZ shows Z and not Y.
    private static func keyName(_ code: UInt32) -> String {
        if let fixed = fixedNames[Int(code)] { return fixed }
        if let ch = layoutCharacter(for: code), !ch.isEmpty { return ch.uppercased() }
        return "Key\(code)"
    }

    /// The keys with no character — asking the layout would return nothing.
    private static let fixedNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
        kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        kVK_Escape: "⎋", kVK_Space: "Space", kVK_Tab: "⇥", kVK_Return: "⏎",
        kVK_ANSI_KeypadEnter: "⌤", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_Help: "?⃝", kVK_ANSI_KeypadClear: "⌧",
    ]

    /// Ask the current keyboard layout what character this key code produces.
    private static func layoutCharacter(for code: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { buf -> OSStatus in
            guard let layout = buf.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}

/// The actions that appear in the settings interface. Recording is not registered with the system by
/// default (it is the second tap of the capture key), but the user can give it a key of its own, and
/// then it registers like the rest.
enum HotkeyAction: UInt32, CaseIterable {
    case capture       = 1   // F1
        case record        = 4   // no key of its own by default: F1 twice
    case pinClipboard  = 2   // ⇧F1
    case toggleAllPins = 3   // ⌘⇧F1

    /// The order here is the order in the settings interface, which is also the order of importance.
    /// Capture and record are the main actions and go at the top (Tim, 2026-09-05: F1 and pressing F1
    /// twice are the most important settings).
    static var allCases: [HotkeyAction] { [.capture, .record, .pinClipboard, .toggleAllPins] }

    var defaultHotkey: Hotkey {
        switch self {
        case .capture:       PinRole.isDirector ? .f9 : .f1
                case .record:        .derived      // = the capture key, twice
        case .pinClipboard:  PinRole.isDirector ? .shiftF9 : .shiftF1
        case .toggleAllPins: PinRole.isDirector ? .cmdShiftF9 : .cmdShiftF1
        }
    }

    var title: String {
        switch self {
        case .capture:       L("hotkey.capture", "Capture")
        case .record:        L("hotkey.record", "Record")
        case .pinClipboard:  L("hotkey.pin", "Pin image")
        case .toggleAllPins: L("hotkey.togglePins2", "Show/hide pins")
        }
    }
}

/// The semantic event dispatched to the app. `record` is synthesised from the second `capture`.
enum HotkeyEvent {
    /// The first capture press: open the overlay immediately.
    case capture
    /// The second capture press (within 450ms): switch the already-open overlay into record mode.
    ///
    /// Note the order — the first press **does not wait**; it opens the overlay straight away. Adding
    /// 450ms of delay to the main action in order to watch for a double-tap is not acceptable, so this
    /// is "open, then switch" rather than "wait, then open".
    case record
    case pinClipboard
    case toggleAllPins
}

@MainActor
final class HotkeyManager {

    /// The double-tap window. Matched to Magpie's, so the muscle memory carries over.
    static let doubleTapWindow: TimeInterval = 0.45

    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var bindings: [HotkeyAction: Hotkey] = [:]
    private var handlerRef: EventHandlerRef?
    private let onEvent: (HotkeyEvent) -> Void

    /// When the capture key was last pressed, for detecting the double tap.
    private var lastCaptureAt: Date?

    private static let signature: OSType = "GJay".utf8.reduce(0) { ($0 << 8) | OSType($1) }

    var isRegistered: Bool { !refs.isEmpty }

    /// The settings interface needs to rebind keys, but HotkeyManager is an instance owned by
    /// AppDelegate. A weak reference for the UI, rather than introducing a singleton.
    static weak var current: HotkeyManager?

    init(onEvent: @escaping (HotkeyEvent) -> Void) {
        self.onEvent = onEvent
        installHandler()
        Self.current = self
    }

    // MARK: - Registration

    func register() {
        for action in HotkeyAction.allCases where refs[action] == nil {
            bind(action, to: Preferences.shared.hotkey(for: action))
        }
    }

    func unregister() {
        for (_, ref) in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        bindings.removeAll()
    }

    /// Rebind one action, leaving the rest alone. Returning false means the combination is taken by
    /// the system or another app — the caller should show that to the user rather than failing
    /// silently.
    @discardableResult
    func rebind(_ action: HotkeyAction, to hotkey: Hotkey) -> Bool {
        // Reject an unusable combination first — **before unregistering the old key**, or by the time
        // the problem is found the old one is already gone.
        if let why = rejection(for: hotkey, action: action) {
            #if DEBUG
            switch why {
                        case .taken(let who):  print("[hotkey] rebind refused: \(hotkey.display) already belongs to \(who)")
                        case .needsModifier:   print("[hotkey] rebind refused: \(hotkey.display) is a bare typing key")
            }
            #endif
            return false
        }
        let previous = bindings[action]
        if let existing = refs[action] {
            UnregisterEventHotKey(existing)
            refs[action] = nil
        }
        if bind(action, to: hotkey) {
            Preferences.shared.setHotkey(hotkey, for: action)
            return true
        }
        // The new combination would not register (usually taken by the system, ⌘Space say). The old
        // key has already been unregistered by this point — without putting it back, the user merely
        // "tried a key" and **lost the one they had**, while the settings still show the old one
        // (`setHotkey` writes only on success), making the label a lie.
        if let previous {
            _ = bind(action, to: previous)
            #if DEBUG
                        print("[hotkey] rebind failed, restored \(previous.display)")
            #endif
        }
        return false
    }

    /// For labelling the settings interface.
    static func shared_display(_ action: HotkeyAction) -> String {
        Preferences.shared.hotkey(for: action).display
    }

    func binding(for action: HotkeyAction) -> Hotkey {
        bindings[action] ?? action.defaultHotkey
    }

    /// Why this combination cannot be used. `nil` = it can.
    enum Rejection {
        /// Already assigned to another action.
        case taken(HotkeyAction)
        /// A bare typing key. Binding one means that character can no longer be typed anywhere in the
        /// system, and the user has no way of knowing who did it.
        case needsModifier
    }

    /// Asked before rebinding. The settings interface uses it to say **why** — a flat "no" leaves
    /// people trying the same key again and again.
    func rejection(for hotkey: Hotkey, action: HotkeyAction) -> Rejection? {
        guard !hotkey.isDerived else { return nil }
        if let taken = actionHolding(hotkey, excluding: action) { return .taken(taken) }
        if hotkey.modifiers == 0, !Self.safeBare.contains(Int(hotkey.keyCode)) {
            return .needsModifier
        }
        return nil
    }

    /// Keys that are safe to claim without a modifier: the function row. A bare F1 is our own default,
    /// while binding a bare letter, digit or punctuation mark means the user can never type that
    /// character again.
    private static let safeBare: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
        kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
        kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Whether this combination already belongs to another action.
    ///
    /// Conflicts at the system level cannot be detected (`RegisterEventHotKey` returns noErr on a
    /// conflict — measured: setting the capture key to ⌘Space also "succeeded"), but **two of our own
    /// actions colliding can be**. Without the check, setting the pin key to F1 as well would also
    /// "succeed", one of them would silently stop working, and the settings interface would show the
    /// same key on two rows with no way to tell which is alive.
    func actionHolding(_ hotkey: Hotkey, excluding action: HotkeyAction) -> HotkeyAction? {
        guard !hotkey.isDerived else { return nil }
        return bindings.first { other, bound in
            other != action && !bound.isDerived
                && bound.keyCode == hotkey.keyCode && bound.modifiers == hotkey.modifiers
        }?.key
    }

    @discardableResult
    private func bind(_ action: HotkeyAction, to hotkey: Hotkey) -> Bool {
        // An action that follows another has no key to register, but still belongs in bindings —
        // dispatch uses it to decide whether a second tap counts as recording.
        if hotkey.isDerived {
            bindings[action] = hotkey
            return true
        }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
        let st = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id,
                                     GetApplicationEventTarget(), 0, &ref)
        #if DEBUG
                // Log the enum name and not the localized title — the smoke test greps for it, and switching
        // the interface to English would stop it matching (2026-09-05: with the interface in English,
        // smoke.sh reported "hotkey not registered" while registration was working perfectly).
                print("[hotkey] registered \(action) \(hotkey.display) → \(st == noErr ? "ok" : "failed(\(st))")")
        #endif
        guard st == noErr, let ref else { return false }
        refs[action] = ref
        bindings[action] = hotkey
        return true
    }

    // MARK: - Carbon callback

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Only our own signature — other libraries in the same process may register Carbon hotkeys
            // too.
            guard id.signature == HotkeyManager.signature,
                  let action = HotkeyAction(rawValue: id.id) else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in manager.dispatch(action) }
            return noErr
        }, 1, &spec, userData, &handlerRef)
    }

    private func dispatch(_ action: HotkeyAction) {
        switch action {
        case .capture:
            // Once the user gives recording a key of its own, the second tap should simply take
            // another screenshot rather than quietly starting a recording — otherwise that independent
            // key comes with an invisible side effect.
            let doubleTapRecords = binding(for: .record).isDerived
            let now = Date()
            let isSecondTap = doubleTapRecords
                && (lastCaptureAt.map { now.timeIntervalSince($0) < Self.doubleTapWindow } ?? false)
                        lastCaptureAt = isSecondTap ? nil : now   // a third press starts over, never a triple
            #if DEBUG
                        print("[hotkey] fired \(isSecondTap ? "record (second capture tap)" : "capture")")
            #endif
            onEvent(isSecondTap ? .record : .capture)

        case .record:
            #if DEBUG
                        print("[hotkey] fired record (own key)")
            #endif
            onEvent(.record)

        case .pinClipboard:
            #if DEBUG
                        print("[hotkey] fired pin")
            #endif
            onEvent(.pinClipboard)

        case .toggleAllPins:
            #if DEBUG
                        print("[hotkey] fired hide/show all pins")
            #endif
            onEvent(.toggleAllPins)
        }
    }
}

/// Frontmost app changed → decide whether to yield the hotkey (some apps treat the key as their own).
@MainActor
final class FrontAppWatcher {
    var onChange: ((NSRunningApplication?) -> Void)?
    private var token: Any?

    init() {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.onChange?(app) }
        }
    }
}
