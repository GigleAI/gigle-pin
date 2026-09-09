// Path helpers. Deliberately free of other imports — the offscreen render scripts compile this
// file on its own.

import Foundation

/// The user's **real** home directory. In a sandbox both `NSHomeDirectory()` and
/// `homeDirectoryForCurrentUser` return `~/Library/Containers/ai.gigle.pin/Data`, so building
/// `Pictures/Pin` out of either files screenshots inside the container, where the user cannot find
/// them in Finder (measured in the sandbox, 2026-09-05). `getpwuid` is not redirected.
var realHomeDirectory: URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: dir))
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

/// A path a person can read: relative to home, so `~/Pictures/Pin/x.png` becomes
/// `Pictures/Pin/x.png`. An absolute path is long enough to get truncated in a toast or a toolbar
/// hint, which defeats the point of saying where the file went.
func readablePath(_ url: URL) -> String {
    let home = realHomeDirectory.path
    var p = url.path
    if p.hasPrefix(home) { p.removeFirst(home.count) }
    return p.hasPrefix("/") ? String(p.dropFirst()) : p
}
