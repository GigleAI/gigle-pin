// Pin 🐦 — Snip. Pin. Record.
// Plain AppKit entry point: a menu bar app (LSUIElement) that opens windows on demand.

import AppKit

// stdout is fully buffered when nohup redirects it to a file, so DEBUG logs would pile up until
// exit. Line buffering instead.
setlinebuf(stdout)

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
