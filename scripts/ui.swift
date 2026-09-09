// Input driver for tests: post mouse and keyboard events into the system. Coordinates are CG
// globals (top-left origin).
//   swift scripts/ui.swift move 500 400
//   swift scripts/ui.swift click 500 400
//   swift scripts/ui.swift drag 300 300 700 550
//   swift scripts/ui.swift optdrag 300 300 700 550   # drag with ⌥ held (drawing while recording)
//   swift scripts/ui.swift key 53          # Esc
//   swift scripts/ui.swift key 36 cmd      # ⌘⏎
import Cocoa

let args = CommandLine.arguments.dropFirst().map { $0 }
func pt(_ i: Int) -> CGPoint { CGPoint(x: Double(args[i])!, y: Double(args[i + 1])!) }
func post(_ type: CGEventType, _ p: CGPoint, flags: CGEventFlags = []) {
    let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!
    e.flags = flags
    e.post(tap: .cghidEventTap)
    usleep(30_000)
}
switch args.first {
case "move":
    post(.mouseMoved, pt(1))
case "click":
    post(.mouseMoved, pt(1)); usleep(120_000)
    post(.leftMouseDown, pt(1)); post(.leftMouseUp, pt(1))
case "rightclick":
    // A pin window's context menu only opens on a right click, and that menu is one of the easiest
// places for a missing translation to hide.
    post(.mouseMoved, pt(1)); usleep(120_000)
    post(.rightMouseDown, pt(1)); post(.rightMouseUp, pt(1))
case "drag":
    let a = pt(1), b = pt(3)
    post(.mouseMoved, a); usleep(120_000)
    post(.leftMouseDown, a)
    let n = 12
    for i in 1...n {
        let t = Double(i) / Double(n)
        post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
    }
    post(.leftMouseUp, b)
case "optmove":
    // Move once with ⌥ held. Taking the mouse works by turning off the window's ignoresMouseEvents,
// and the window server only re-decides who an event belongs to after a mouse movement — so move
// first, and the mouseDown after it actually lands on the annotation layer.
    let m = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: true)!
    m.type = .flagsChanged; m.flags = .maskAlternate; m.post(tap: .cghidEventTap)
    usleep(120_000)
    post(.mouseMoved, pt(1), flags: .maskAlternate)
    usleep(120_000)
case "optdrag":
    // Drag with ⌥ held — this is how annotating during a recording works.
// **Setting maskAlternate on the mouse events is not enough**: the takeover logic decides whether
// ⌥ is down from flagsChanged, so with only the flag set it believes ⌥ was never pressed and keeps
// giving the mouse back to the app underneath. So do it in the real order: ⌥ down → drag with the
// flag → ⌥ up.
    let a = pt(1), b = pt(3)
    func flags(_ f: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: !f.isEmpty)!  // 58 = ⌥
        e.type = .flagsChanged
        e.flags = f
        e.post(tap: .cghidEventTap)
        usleep(80_000)
    }
    // **After the takeover, move a few more times before pressing.**
// With `ignoresMouseEvents` off, the window server waits for a mouse movement before re-deciding
// who a press belongs to, and moving once then pressing 150ms later often still passes through to
// the app below — so nothing is drawn, and nothing reports an error. A person holding ⌥ has their
// hand in motion throughout and never hits this; only a script does.
    flags(.maskAlternate)
    for i in 0..<6 {
        post(.mouseMoved, CGPoint(x: a.x - Double(5 - i), y: a.y), flags: .maskAlternate)
        usleep(60_000)
    }
    usleep(200_000)
    post(.leftMouseDown, a, flags: .maskAlternate)
    let steps = 14
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged,
             CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
             flags: .maskAlternate)
    }
    post(.leftMouseUp, b, flags: .maskAlternate)
    flags([])
case "key":
    let code = CGKeyCode(UInt16(args[1])!)
    var flags: CGEventFlags = []
    if args.contains("cmd") { flags.insert(.maskCommand) }
    if args.contains("shift") { flags.insert(.maskShift) }
    if args.contains("opt") { flags.insert(.maskAlternate) }
    let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!; d.flags = flags; d.post(tap: .cghidEventTap)
    usleep(40_000)
    let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!; u.flags = flags; u.post(tap: .cghidEventTap)
default:
    print("usage: move|click|rightclick|drag|key")
}
