import AppKit

/// Builds the application menu.
///
/// An AppKit app gets no menu for free, and without menu items carrying the key
/// equivalents there is no Cmd+C, Cmd+Z, or Cmd+F at all — NSTextView routes
/// those through the responder chain from the menu, not on its own. The Find
/// items are what give in-note search its native find bar.
enum MainMenu {
    static func build(target: AnyObject, preferencesAction: Selector) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(target: target, preferencesAction: preferencesAction))
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(formatMenuItem())
        return mainMenu
    }

    private static func appMenuItem(target: AnyObject, preferencesAction: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Jot")

        menu.addItem(
            withTitle: "About Jot",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: preferencesAction, keyEquivalent: ",")
        settings.target = target
        menu.addItem(settings)

        let sync = NSMenuItem(
            title: "Sync to Apple Notes",
            action: Selector(("syncToAppleNotesNow:")),
            keyEquivalent: ""
        )
        sync.target = target
        menu.addItem(sync)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide Jot",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        menu.addItem(
            withTitle: "Quit Jot",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        item.submenu = menu
        return item
    }

    /// nil target: the key equivalent walks the responder chain to the text
    /// view, so Cmd+L works whether or not the panel is the key window's focus.
    private static func formatMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Format")
        menu.addItem(
            withTitle: "Toggle Checklist",
            action: #selector(ChecklistTextView.toggleChecklist(_:)),
            keyEquivalent: "l"
        )
        menu.addItem(.separator())

        // Cmd+V keeps a pasted image; this reads it instead.
        let extract = NSMenuItem(
            title: "Extract Text from Image",
            action: #selector(ChecklistTextView.extractTextFromClipboardImage(_:)),
            keyEquivalent: "v"
        )
        extract.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(extract)
        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        // nil target means "walk the responder chain", which lands on the text view.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")

        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        menu.addItem(.separator())
        menu.addItem(findMenuItem())

        item.submenu = menu
        return item
    }

    private static func findMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Find")

        // NSTextView reads the action off the menu item's tag.
        func finderItem(_ title: String, _ action: NSTextFinder.Action, _ key: String,
                        _ mask: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(
                title: title,
                action: #selector(NSTextView.performTextFinderAction(_:)),
                keyEquivalent: key
            )
            item.tag = action.rawValue
            item.keyEquivalentModifierMask = mask
            return item
        }

        menu.addItem(finderItem("Find…", .showFindInterface, "f"))
        menu.addItem(finderItem("Find Next", .nextMatch, "g"))
        menu.addItem(finderItem("Find Previous", .previousMatch, "g", [.command, .shift]))
        menu.addItem(finderItem("Use Selection for Find", .setSearchString, "e"))

        item.submenu = menu
        return item
    }
}
