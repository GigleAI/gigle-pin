// The main menu.
//
// Normally unused — Pin is an `LSUIElement`, so all you see is the bird in the menu bar. But while
// a review window is open the app switches to being an ordinary one (Dock icon, ⌘Tab; see
// `ReviewCoordinator.updateActivationPolicy`), and at that moment an empty `NSApp.mainMenu` means a menu
// bar with nothing in it — and ⌘W / ⌘Q / ⌘Z / ⌘C **all stop responding**, because they dispatch
// through menu item key equivalents rather than being built into the system.
//
// So it is installed at launch: hidden while the app is an accessory, there the instant it turns
// regular, and it lets the review and settings windows close with ⌘W at any time.

import AppKit

@MainActor
enum MainMenu {

    static func install() {
        let main = NSMenu()

        // The app menu: the system replaces the title with the process name
        let app = NSMenuItem()
        let appMenu = NSMenu()
        // The system's own panel: name, version, build and copyright, all read from Info.plist, so
        // there is nothing here to keep in step with anything. First item, where every Mac user
        // already looks — though for us it is only reachable while a review window is open, which is
        // why the menu bar menu and Settings answer the same question.
        appMenu.addItem(withTitle: L("mainmenu.about", "About Gigle Pin"),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("mainmenu.settings", "Settings…"),
                        action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("mainmenu.hide", "Hide Pin"),
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = NSMenuItem(title: L("mainmenu.hideOthers", "Hide Others"),
                                action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(others)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("mainmenu.quit", "Quit Pin"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu
        main.addItem(app)

        let file = NSMenuItem(title: L("mainmenu.file", "File"), action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: L("mainmenu.file", "File"))
        fileMenu.addItem(withTitle: L("mainmenu.close", "Close Window"),
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.submenu = fileMenu
        main.addItem(file)

        // The Edit menu is not decoration — ⌘Z in the review window and copy/paste in the text tool
        // both dispatch through it
        let edit = NSMenuItem(title: L("mainmenu.edit", "Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: L("mainmenu.edit", "Edit"))
        for (title, sel, key) in [
            (L("mainmenu.undo", "Undo"), Selector(("undo:")), "z"),
            (L("mainmenu.redo", "Redo"), Selector(("redo:")), "Z"),
        ] as [(String, Selector, String)] {
            editMenu.addItem(withTitle: title, action: sel, keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        for (title, sel, key) in [
            (L("mainmenu.cut", "Cut"), #selector(NSText.cut(_:)), "x"),
            (L("mainmenu.copy", "Copy"), #selector(NSText.copy(_:)), "c"),
            (L("mainmenu.paste", "Paste"), #selector(NSText.paste(_:)), "v"),
            (L("mainmenu.selectAll", "Select All"), #selector(NSText.selectAll(_:)), "a"),
        ] as [(String, Selector, String)] {
            editMenu.addItem(withTitle: title, action: sel, keyEquivalent: key)
        }
        edit.submenu = editMenu
        main.addItem(edit)

        let window = NSMenuItem(title: L("mainmenu.window", "Window"), action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: L("mainmenu.window", "Window"))
        windowMenu.addItem(withTitle: L("mainmenu.minimize", "Minimize"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.submenu = windowMenu
        main.addItem(window)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}
