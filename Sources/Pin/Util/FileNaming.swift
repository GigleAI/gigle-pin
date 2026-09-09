import Foundation

/// One place that decides what a saved file is called.
///
/// The timestamp is only accurate to the second, so saving twice within one second collides — and
/// `Data.write(options: .atomic)` overwrites **silently** on a collision, losing the earlier image.
/// Pressing ⌘S twice in a second is hard by hand, but `pin://sniprect` exists for Shortcuts and
/// Alfred, and a script capturing several regions lands in the same second easily.
///
/// Matches macOS's own screenshots by counting up with `(2)`, `(3)`, so it is obvious which one
/// is which.
enum FileNaming {

    /// Find a name in `dir` that `base.ext` has not already taken.
    static func unique(in dir: URL, base: String, ext: String) -> URL {
        let fm = FileManager.default
        var url = dir.appendingPathComponent("\(base).\(ext)")
        guard fm.fileExists(atPath: url.path) else { return url }
        // The ceiling is only a guard: genuinely hitting 999 means something else is wrong, and at
        // that point overwriting beats stalling the user.
        for n in 2...999 {
            url = dir.appendingPathComponent("\(base) (\(n)).\(ext)")
            if !fm.fileExists(atPath: url.path) { return url }
        }
        return url
    }
}
