import Foundation

/// Where a take lives while "keep every recording" is off: in the cache, until the user presses Save in
/// the review window or hands the file out (copy, path, GIF, contact sheet, Finder). Closing the
/// window without doing any of that discards it.
///
/// Keeping is a **hard link**, not a move. The player in the review window is still reading the cache
/// file, and renaming under an open AVPlayer is a bet on how AVFoundation reopens on seek. A link
/// costs no space and no time on the same volume; a save directory on another volume gets a copy.
/// The cache copy goes when the window closes; the link in the save directory stays.
@MainActor
enum UnsavedRecordings {
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "ai.gigle.pin", isDirectory: true)
            .appendingPathComponent("Unsaved", isDirectory: true)
    }

    static func next(base: String, ext: String) -> URL {
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return FileNaming.unique(in: dir, base: base, ext: ext)
    }

    /// Put `url` in the save directory under its own name; returns where it went.
    static func keep(_ url: URL) throws -> URL {
        let dst = FileNaming.unique(in: Preferences.shared.ensureSaveDirectory(),
                                    base: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension)
        do { try FileManager.default.linkItem(at: url, to: dst) }
        catch { try FileManager.default.copyItem(at: url, to: dst) }
        return dst
    }

    /// Cache files nobody is reviewing any more. A take survives a crash for a day — long enough to go
    /// and fetch it, short enough that the cache cannot quietly become the thing this setting exists
    /// to avoid.
    static func sweep(olderThan age: TimeInterval = 86_400) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for f in items {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if m < cutoff { try? fm.removeItem(at: f) }
        }
    }
}
