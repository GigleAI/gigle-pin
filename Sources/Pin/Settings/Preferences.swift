import AppKit
import Carbon.HIToolbox

/// Which modifier is held to draw on screen during a recording.
///
/// **A global event monitor observes; it does not consume.** Whatever is held therefore reaches the
/// application being recorded as well — and ⌥-drag duplicates an object in Figma, Sketch and
/// Illustrator, which is exactly the sort of app people record in order to show how it works.
/// Holding ⌥ to point at something quietly duplicated whatever was under the cursor
/// (Tim, 2026-09-08).
///
/// **Every alternative is a combination, except fn.** While the chosen modifier is held the ink
/// window stops ignoring mouse events, so the click and the drag land on Pin instead of on the app
/// underneath — whichever key is picked is a key that loses its mouse gestures inside the recorded
/// region for the length of the recording. That is affordable for ⌥ and it is not affordable for
/// either of the two obvious singles:
///   - **⌃ alone** would take right-click away. Control-click *is* right-click on macOS, and a
///     demonstration that cannot open a context menu is a broken demonstration.
///   - **⌘ alone** would take ⌘-click and ⌘-drag: multi-select in a list, open-in-new-tab in a
///     browser, dragging a background window without raising it, rearranging the menu bar.
///   - **⇧** is spoken for: holding it as well is how a stroke is made to last the whole clip.
///
/// Held in combination they are fine — a plain ⌘-click still reaches the app underneath, which is
/// the entire reason ⌃⌥, ⌘⌥ and ⌃⌘ are offered while ⌃ and ⌘ on their own are not.
///
/// None of this registers anything with the system: the modifier is read off events Pin already
/// watches, so adding choices cannot collide with anyone else's hotkeys.
enum InkModifier: String, CaseIterable {
    case option, controlOption, commandOption, controlCommand, function

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .option:        [.option]
        case .controlOption: [.control, .option]
        case .commandOption: [.command, .option]
        case .controlCommand: [.control, .command]
        case .function:      [.function]
        }
    }

    /// What to print wherever the interface mentions it. **Nothing may hard-code ⌥ again**: the
    /// moment someone picks the other one, every hard-coded glyph turns into a lie — the same rule
    /// the hotkey hints already follow.
    var display: String {
        switch self {
        case .option:        "⌥"
        case .controlOption: "⌃⌥"
        case .commandOption: "⌘⌥"
        case .controlCommand: "⌃⌘"
        case .function:      "fn"
        }
    }

    var title: String {
        switch self {
        case .option:        L("ink.modOption", "Option ⌥")
        case .controlOption: L("ink.modControlOption", "Control-Option ⌃⌥")
        case .commandOption: L("ink.modCommandOption", "Command-Option ⌘⌥")
        case .controlCommand: L("ink.modControlCommand", "Control-Command ⌃⌘")
        // The one key almost nothing else claims, which is the whole point of offering it.
        case .function:      L("ink.modFunction", "Fn")
        }
    }

    /// True when this modifier — and nothing more from the set that matters — is held.
    /// ⇧ is deliberately ignored: holding it too is how a stroke is made to stay for the whole clip,
    /// so it must not stop the modifier counting as held.
    func isHeld(_ f: NSEvent.ModifierFlags) -> Bool {
        f.intersection([.command, .option, .control, .function]) == flags
    }
}

/// Everything the user can tweak, backed by `UserDefaults`.
@MainActor
final class Preferences {

    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Keys.copyAfterCapture: true,
            Keys.copyAfterRecord: true,
            Keys.playShutterSound: false,
            Keys.showMagnifier: true,
            Keys.autoDetectWindows: true,
            // Build the path from the real home directory rather than `urls(for: .picturesDirectory)`
            // — in a sandbox the latter returns Pictures inside the container, and captures land
            // somewhere the user cannot find. With assets.pictures.read-write, the real ~/Pictures is
            // writable.
            Keys.saveDirectory: realHomeDirectory
                .appendingPathComponent("Pictures/Pin").path,
            Keys.recordShowCursor: true,
            Keys.recordHighlightClicks: true,
            Keys.recordFrameRate: 30,
            Keys.recordMicrophone: false,
            // System audio defaults to **on**: a demo recorded without sound is usually a reshoot.
            // The microphone defaults to off — it needs a permission, and recording narration is a
            // deliberate choice.
            Keys.recordSystemAudio: true,
            Keys.recordFormat: "mp4",
            Keys.appearance: "system",
            Keys.palette: "native",
            Keys.language: "system",
            Keys.liveAnnotate: true,
            Keys.liveAnnotateLife: 3.0,
            Keys.gifFrameRate: 15,
            Keys.gifMaxWidth: 800,
            Keys.pinOpacity: 1.0,
            Keys.pinShadow: true,
        ])
    }

    enum Keys {
        static let inkModifier          = "inkModifier"
        static let copyAfterCapture     = "copyAfterCapture"
        static let copyAfterRecord      = "copyAfterRecord"
        static let playShutterSound     = "playShutterSound"
        static let showMagnifier        = "showMagnifier"
        static let autoDetectWindows    = "autoDetectWindows"
        static let saveDirectory        = "saveDirectory"
        static let saveDirectoryBookmark = "saveDirectoryBookmark"
        static let recordShowCursor     = "recordShowCursor"
        static let recordHighlightClicks = "recordHighlightClicks"
        static let recordFrameRate      = "recordFrameRate"
        static let recordMicrophone     = "recordMicrophone"
        static let recordSystemAudio    = "recordSystemAudio"
        static let recordFormat         = "recordFormat"
        static let appearance           = "appearance"
        static let palette              = "palette"
        static let language             = "language"
        static let liveAnnotate         = "liveAnnotate"
        static let liveAnnotateLife     = "liveAnnotateLife"
        static let gifFrameRate         = "gifFrameRate"
        static let gifMaxWidth          = "gifMaxWidth"
        static let pinOpacity           = "pinOpacity"
        static let pinShadow            = "pinShadow"
        static func hotkey(_ action: HotkeyAction) -> String { "hotkey.\(action.rawValue)" }
    }

    // MARK: - Capture

    var copyAfterCapture: Bool {
        get { defaults.bool(forKey: Keys.copyAfterCapture) }
        set { defaults.set(newValue, forKey: Keys.copyAfterCapture) }
    }

    /// Put the file on the clipboard when a recording stops, so ⌘V sends it.
    /// The capture side (`copyAfterCapture`) has always defaulted to on while stopping a recording
    /// did nothing at all — two main paths in one tool with different defaults, which just reads as
    /// recording being short of something (Tim, 2026-09-06: 「我们截图有 return 进剪贴板，怎么录屏
    /// 没有啊？」).
    var copyAfterRecord: Bool {
        get { defaults.bool(forKey: Keys.copyAfterRecord) }
        set { defaults.set(newValue, forKey: Keys.copyAfterRecord) }
    }

    var showMagnifier: Bool {
        get { defaults.bool(forKey: Keys.showMagnifier) }
        set { defaults.set(newValue, forKey: Keys.showMagnifier) }
    }

    var autoDetectWindows: Bool {
        get { defaults.bool(forKey: Keys.autoDetectWindows) }
        set { defaults.set(newValue, forKey: Keys.autoDetectWindows) }
    }

    /// Where files are saved.
    ///
    /// Sandbox rule: access to a directory the user picked in a panel **dies with the process**, and
    /// only a security-scoped bookmark survives a restart. So the setter stores a bookmark alongside
    /// the path, and the getter resolves the bookmark first and calls
    /// `startAccessingSecurityScopedResource`. Outside a sandbox this all still works (the bookmark
    /// is created, and start is a no-op), so the direct build and the store build share one code
    /// path.
    var saveDirectory: URL {
        get {
            if let data = defaults.data(forKey: Keys.saveDirectoryBookmark) {
                var stale = false
                let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                        relativeTo: nil, bookmarkDataIsStale: &stale)
                // If it resolves into the Trash, **throw the bookmark away** rather than keeping it
                // to be resolved and fall back to the path key on every single save — that leaves a
                // bookmark pointing at the Trash sitting in preferences, and the day it becomes
                // "valid" again (the user drags the folder out of the Trash, to somewhere else) it
                // is harder still to explain.
                if let resolved, Self.isInTrash(resolved) {
                    defaults.removeObject(forKey: Keys.saveDirectoryBookmark)
                }
                if let url = resolved, !Self.isInTrash(url) {
                    Self.beginAccess(url)
                    if stale {
                        // The bookmark follows the folder — if the user renames or moves it in
                        // Finder, carrying on saving into that folder is right. But **the path key
                        // has to be updated too**, or the settings window and the toolbar keep
                        // showing the old path, and the day the bookmark fails to resolve everything
                        // jumps back to a place that stopped existing long ago.
                        defaults.set(url.path, forKey: Keys.saveDirectory)
                        if let fresh = try? url.bookmarkData(options: .withSecurityScope) {
                            defaults.set(fresh, forKey: Keys.saveDirectoryBookmark)
                        }
                    }
                    return url
                }
            }
            let path = defaults.string(forKey: Keys.saveDirectory) ?? ""
            return URL(fileURLWithPath: path)
        }
        set {
            defaults.set(newValue.path, forKey: Keys.saveDirectory)
            // If the bookmark cannot be made (a path that does not exist, say), store the path alone
            // rather than failing the setting
            if let data = try? newValue.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(data, forKey: Keys.saveDirectoryBookmark)
            } else {
                defaults.removeObject(forKey: Keys.saveDirectoryBookmark)
            }
            Self.beginAccess(newValue)
        }
    }

    /// Directories already started, to avoid starting twice. (Every start needs a matching stop; for
    /// the save directory we **start and never stop** — it is in use for as long as the process
    /// lives.)
    nonisolated(unsafe) private static var accessing = Set<String>()
    private static func beginAccess(_ url: URL) {
        guard !accessing.contains(url.path) else { return }
        if url.startAccessingSecurityScopedResource() { accessing.insert(url.path) }
    }

    // MARK: - Recording

    var recordShowCursor: Bool {
        get { defaults.bool(forKey: Keys.recordShowCursor) }
        set { defaults.set(newValue, forKey: Keys.recordShowCursor) }
    }

    var recordHighlightClicks: Bool {
        get { defaults.bool(forKey: Keys.recordHighlightClicks) }
        set { defaults.set(newValue, forKey: Keys.recordHighlightClicks) }
    }

    var recordFrameRate: Int {
        get { defaults.integer(forKey: Keys.recordFrameRate) }
        set { defaults.set(newValue, forKey: Keys.recordFrameRate) }
    }

    var recordMicrophone: Bool {
        get { defaults.bool(forKey: Keys.recordMicrophone) }
        set { defaults.set(newValue, forKey: Keys.recordMicrophone) }
    }

    var recordSystemAudio: Bool {
        get { defaults.bool(forKey: Keys.recordSystemAudio) }
        set { defaults.set(newValue, forKey: Keys.recordSystemAudio) }
    }

    /// Palette: "native" for the system look, "ink" for Ink. Orthogonal to light/dark — Ink carries
    /// its own paper (day) and night values.
    var palette: String {
        get { defaults.string(forKey: Keys.palette) ?? "native" }
        set { defaults.set(newValue, forKey: Keys.palette) }
    }

    /// Interface light/dark: "system", "light" or "dark".
    /// Applies to ordinary interface such as the settings and welcome windows — the overlay, the
    /// toolbars and the recording HUD are always dark, because they float over the picture being
    /// captured and anything lighter competes with it.
    var appearance: String {
        get { defaults.string(forKey: Keys.appearance) ?? "system" }
        set { defaults.set(newValue, forKey: Keys.appearance) }
    }

    /// Interface language: "system", or a specific code (zh-Hans / en / ja / ko …).
    var language: String {
        get { defaults.string(forKey: Keys.language) ?? "system" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }

    /// Whether holding ⌥ draws on screen during a recording.
    var liveAnnotate: Bool {
        get { defaults.bool(forKey: Keys.liveAnnotate) }
        set { defaults.set(newValue, forKey: Keys.liveAnnotate) }
    }

    /// How long a finished stroke stays before it starts fading (seconds).
    var liveAnnotateLife: Double {
        get { defaults.double(forKey: Keys.liveAnnotateLife) }
        set { defaults.set(newValue, forKey: Keys.liveAnnotateLife) }
    }

    /// "mp4" or "gif". A GIF is recorded as MP4 first and converted, deleting the MP4 afterwards.
    var recordFormat: String {
        get { defaults.string(forKey: Keys.recordFormat) ?? "mp4" }
        set { defaults.set(newValue, forKey: Keys.recordFormat) }
    }

    // MARK: - GIF export

    var gifFrameRate: Int {
        get { defaults.integer(forKey: Keys.gifFrameRate) }
        set { defaults.set(newValue, forKey: Keys.gifFrameRate) }
    }

    var gifMaxWidth: Int {
        get { defaults.integer(forKey: Keys.gifMaxWidth) }
        set { defaults.set(newValue, forKey: Keys.gifMaxWidth) }
    }

    // MARK: - Pins

    var pinOpacity: Double {
        get { defaults.double(forKey: Keys.pinOpacity) }
        set { defaults.set(newValue, forKey: Keys.pinOpacity) }
    }

    /// Which modifier draws on screen while recording. See `InkModifier`.
    var inkModifier: InkModifier {
        get { InkModifier(rawValue: defaults.string(forKey: Keys.inkModifier) ?? "") ?? .option }
        set { defaults.set(newValue.rawValue, forKey: Keys.inkModifier) }
    }

    var pinShadow: Bool {
        get { defaults.bool(forKey: Keys.pinShadow) }
        set { defaults.set(newValue, forKey: Keys.pinShadow) }
    }

    /// The most recent recording. It is the way back once the review window is closed — a menu bar
    /// app has no Dock icon, so closing the window removes every entrance.
    var lastRecording: URL? {
        get {
            guard let p = defaults.string(forKey: "lastRecording"),
                  FileManager.default.fileExists(atPath: p) else { return nil }
            return URL(fileURLWithPath: p)
        }
        set { defaults.set(newValue?.path, forKey: "lastRecording") }
    }

    /// The "hold ⌥ to draw" hint has already been shown a few times. Once it is learned, stop saying
    /// it — the same sentence on every recording becomes noise after a few passes, and the user
    /// starts ignoring everything the HUD says.
    /// How many times we have said that speakers make the microphone record the computer twice.
    /// Same three-and-stop rule as the ink tip: it is a fact about the room, and someone who has
    /// heard it three times either has headphones or has decided they do not care.
    var echoTipShown: Int {
        get { defaults.integer(forKey: "echoTipShown") }
        set { defaults.set(newValue, forKey: "echoTipShown") }
    }

    var inkTipShown: Int {
        get { defaults.integer(forKey: "inkTipShown") }
        set { defaults.set(newValue, forKey: "inkTipShown") }
    }

    // MARK: - Hotkeys

    func hotkey(for action: HotkeyAction) -> Hotkey {
        guard let data = defaults.data(forKey: Keys.hotkey(action)),
              let hotkey = try? JSONDecoder().decode(Hotkey.self, from: data)
        else { return action.defaultHotkey }
        return hotkey
    }

    /// The default keys moved from the F3 family to the F1 family (to replace Snipaste). A machine
    /// that ran the older build has F3 in its preferences, and without migration the new default
    /// simply does not exist for an existing user. Only the ones the user **never touched** are
    /// moved (those still holding the old default); anything rebound is left alone.
    func migrateHotkeyDefaultsIfNeeded() {
        let key = "hotkeyDefaults.version"
        guard defaults.integer(forKey: key) < 2 else { return }
        let old: [HotkeyAction: Hotkey] = [
            .capture:       Hotkey(keyCode: UInt32(kVK_F3), modifiers: 0),
            .pinClipboard:  Hotkey(keyCode: UInt32(kVK_F3), modifiers: UInt32(shiftKey)),
            .toggleAllPins: Hotkey(keyCode: UInt32(kVK_F3), modifiers: UInt32(cmdKey | shiftKey)),
        ]
        for (action, oldDefault) in old where defaults.data(forKey: Keys.hotkey(action)) != nil {
            if hotkey(for: action) == oldDefault { setHotkey(action.defaultHotkey, for: action) }
        }
        defaults.set(2, forKey: key)
    }

    func setHotkey(_ hotkey: Hotkey, for action: HotkeyAction) {
        guard let data = try? JSONEncoder().encode(hotkey) else { return }
        defaults.set(data, forKey: Keys.hotkey(action))
    }

    /// A bookmark that resolves into the Trash **is not usable**.
    ///
    /// A security-scoped bookmark tracks the file itself, not the path — so if the user drags the
    /// save directory to the Trash, the bookmark still resolves happily, just to `~/.Trash/Pin`.
    /// Captures then go on "saving successfully" into the Trash, and the day it is emptied they all
    /// go with it, without the app having said a word (measured with a standalone probe 2026-09-06
    /// 08:1x: renaming and moving to the Trash both resolved, and `stale` was true for both).
    ///
    /// Follow a rename or a move; do not follow into the Trash — fall back to the path key there,
    /// and `ensureSaveDirectory()` recreates the folder where it was.
    private static func isInTrash(_ url: URL) -> Bool {
        // The user's Trash is ~/.Trash; on an external volume it is /Volumes/X/.Trashes/<uid>
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Creates the save directory on first use so writes never fail on a
    /// missing folder.
    func ensureSaveDirectory() -> URL {
        let dir = saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
