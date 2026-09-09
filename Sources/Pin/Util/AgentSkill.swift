import Foundation

/// The instructions for AI agents (SKILL.md) ship inside the app bundle; **installing them into a
/// user directory happens only when the user presses the button**.
///
/// Why not automatically: Pin's promise is that it does not go online, reads the screen only at the
/// moment you press the hotkey, and does nothing you did not ask for. A screenshot tool quietly
/// dropping files into ~/.codex or ~/.claude contradicts that — even a Markdown file. Apple's own
/// AppleScript dictionaries sit in the app bundle waiting to be read; no serious app pushes files
/// into another tool's directory. Removal deletes only **what we put there** (identified by a
/// marker file) and never touches anything the user placed by hand.
enum AgentSkill {
    static let name = "pin-screen-recorder"
    static let marker = ".installed-by-gigle-pin"

    /// The copy inside the bundle.
    static var bundled: URL? {
        Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true)
    }

    /// The three places an agent looks: the generic `.agents`, plus Codex's and Claude Code's own.
    static let targets: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".agents/skills", ".codex/skills", ".claude/skills"].map {
            home.appendingPathComponent($0, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        }
    }()

    /// Installed if any one of the three holds a copy we placed.
    static var isInstalled: Bool {
        targets.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(marker).path) }
    }

    @discardableResult
    static func install() -> [URL] {
        guard let src = bundled else { return [] }
        let fm = FileManager.default
        var done: [URL] = []
        for dst in targets {
            do {
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst.path) {
                    // Something is already there and it is not ours: do not overwrite it
                    guard fm.fileExists(atPath: dst.appendingPathComponent(marker).path) else { continue }
                    try fm.removeItem(at: dst)
                }
                try fm.copyItem(at: src, to: dst)
                try Data().write(to: dst.appendingPathComponent(marker))
                done.append(dst)
            } catch {
                #if DEBUG
                                print("[skill] failed to install into \(dst.path): \(error)")
                #endif
            }
        }
        return done
    }

    static func remove() {
        let fm = FileManager.default
        for dst in targets where fm.fileExists(atPath: dst.appendingPathComponent(marker).path) {
            try? fm.removeItem(at: dst)
        }
    }

    /// The sentence to tell an AI.
    static var sentence: String {
        // 本地路径放在前面、网址放在后面。包内那份跟安装的版本必然一致，而且不依赖网络、
        // 不受官网改版或爬虫拦截影响 —— 2026-09-07 实测：`Claude-User` 抓 gigle.ai 直接 403，
        // 那时这句话里唯一的入口就是死的。网址留着，是给读不了文件的 agent（网页版）用的。
        L("ai.sentence", "I have Gigle Pin installed on this Mac; it can record the screen automatically. Use it to record how ___ works. The instructions are in the app at /Applications/Gigle Pin.app/Contents/Resources/pin-screen-recorder/SKILL.md — or at https://gigle.ai/pin/skill/ if you cannot read files.")
    }
}
