import Foundation

/// Everything that arrives through `pin://` is **untrusted input**, and this is the one place that
/// says so out loud.
///
/// macOS hands a URL to the registered application with no way to ask who sent it: the user's own
/// agent, a Shortcut, a script, and a web page that navigated to `pin://…` all look identical by
/// the time `application(_:open:)` runs. So the boundary cannot be "authenticate the caller" — it
/// has to be **limit what any caller can reach**.
///
/// Three rules, and each one closes a class of damage rather than a single trick:
///
/// 1. **Duplicate parameters are refused, not merged.** `Dictionary(uniqueKeysWithValues:)` traps
///    on a repeated key, and the parse runs before the verb is even looked at — so
///    `pin://settings?tab=a&tab=b` used to take the whole process down, **and any recording in
///    progress with it**. Refusing is also the honest answer: `?x=1&x=2` is an ambiguous request,
///    and silently picking one hides a bug in whatever built the URL.
///
/// 2. **Numbers must be finite and sensible.** `Double("nan")` and `Double("inf")` both parse.
///    A NaN width reaches `CGRect` and from there ScreenCaptureKit, where the failure is neither
///    a crash nor a picture — it is undefined.
///
/// 3. **Output paths are confined, typed and non-clobbering.** See `outputURL`.
enum AgentRequest {

    /// Why a request was turned down, in the one sentence the agent gets back.
    struct Refused: Error { let why: String }

    // MARK: - Query

    /// Parse the query string, refusing a repeated parameter instead of trapping on it.
    static func query(_ items: [URLQueryItem]?) -> Result<[String: String], Refused> {
        var out: [String: String] = [:]
        for item in items ?? [] {
            guard let value = item.value else { continue }
            if out[item.name] != nil {
                return .failure(Refused(why: "\(item.name) given more than once — say it exactly once"))
            }
            out[item.name] = value
        }
        return .success(out)
    }

    /// A number that is safe to do geometry with: parseable, finite, and not absurd.
    ///
    /// `limit` is a sanity ceiling on the magnitude, not a screen bound — the caller checks the
    /// rectangle against the actual displays. It exists so a value like `1e300` cannot overflow
    /// into an infinity two multiplications later.
    static func number(_ raw: String?, limit: Double = 1_000_000) -> Double? {
        guard let raw, let v = Double(raw), v.isFinite, abs(v) <= limit else { return nil }
        return v
    }

    /// A positive, finite extent — a width, a height, or a duration.
    static func positive(_ raw: String?, limit: Double = 1_000_000) -> Double? {
        guard let v = number(raw, limit: limit), v > 0 else { return nil }
        return v
    }

    // MARK: - Output paths

    /// The directories an agent may write into.
    ///
    /// The list is the user's own media and hand-off folders plus the temporary directory — the
    /// places a screenshot or a recording legitimately belongs. What it deliberately excludes is
    /// everything a write could be turned into *execution* or *configuration*: `~/Library`
    /// (LaunchAgents, preferences, containers), any dotfile directory, and the whole system tree.
    ///
    /// The current save directory is included even when the user has pointed it somewhere unusual,
    /// because saving where the user chose to save is the app's normal behaviour.
    static func allowedRoots(saveDirectory: URL?) -> [URL] {
        let home = realHomeDirectory
        var roots = ["Pictures", "Movies", "Downloads", "Desktop", "Documents"]
            .map { home.appendingPathComponent($0) }
        roots.append(URL(fileURLWithPath: NSTemporaryDirectory()))
        roots.append(URL(fileURLWithPath: "/tmp"))
        if let saveDirectory { roots.append(saveDirectory) }
        // Resolve now: /tmp is a symlink to /private/tmp, and the candidate path will be resolved
        // too. Comparing an unresolved root against a resolved candidate never matches.
        return roots.map { $0.resolvingSymlinksInPath().standardizedFileURL }
    }

    /// Validate an `out=` parameter, or say in one sentence why it was refused.
    ///
    /// - `extensions`: what this verb writes. A verb that produces a PNG must not be able to put
    ///   PNG bytes into `notes.txt` — the extension is the file's contract with every other program
    ///   on the machine, and writing past it is how a "saved screenshot" becomes a corrupted
    ///   document.
    /// - `overwrite`: refusing to replace an existing file is an **anti-accident** measure, not a
    ///   security boundary — a hostile URL can pass `overwrite=1` as easily as it passes `out=`.
    ///   It is here because an agent that means to replace its own file can say so in four
    ///   characters, while an agent that got a path wrong finds out instead of destroying the file.
    ///   The boundary that actually holds is `allowedRoots` plus `extensions`.
    static func outputURL(_ raw: String?,
                          extensions: [String],
                          overwrite: Bool,
                          saveDirectory: URL?) -> Result<URL, Refused> {
        guard let raw, !raw.isEmpty else {
            return .failure(Refused(why: "out= is required, as a path ending in .\(extensions.joined(separator: " or ."))"))
        }

        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return .failure(Refused(why: "out= must be an absolute path, not \(raw)"))
        }
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL

        let ext = candidate.pathExtension.lowercased()
        guard extensions.contains(ext) else {
            return .failure(Refused(why: "out= must end in .\(extensions.joined(separator: " or ."))"))
        }

        // Resolve the **parent**, not the file: the file is usually about to be created, and
        // resolving a path that does not exist yet leaves `..` and symlinks in place. A directory
        // that is a symlink out of an allowed root is exactly the escape this is here to close.
        let parent = candidate.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let roots = allowedRoots(saveDirectory: saveDirectory)
        guard roots.contains(where: { contains(root: $0, path: parent) }) else {
            return .failure(Refused(why: "out= must be inside Pictures, Movies, Downloads, Desktop, Documents, "
                            + "the save folder, or a temporary directory"))
        }

        let resolved = parent.appendingPathComponent(candidate.lastPathComponent)
        if !overwrite, FileManager.default.fileExists(atPath: resolved.path) {
            return .failure(Refused(why: "\(resolved.lastPathComponent) already exists — "
                            + "pass overwrite=1 to replace it, or choose another name"))
        }
        return .success(resolved)
    }

    /// Is `path` inside `root`? Compared component by component, because a prefix match on the
    /// string would accept `/tmp/../etc` (already ruled out by resolving) and, worse, would let
    /// `~/Picturesque` pass as being inside `~/Pictures`.
    private static func contains(root: URL, path: URL) -> Bool {
        let r = root.pathComponents, p = path.pathComponents
        guard p.count >= r.count else { return false }
        return Array(p.prefix(r.count)) == r
    }
}
