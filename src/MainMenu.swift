import AppKit

/// Builds the application menu.
///
/// An AppKit app gets no menu for free, and without menu items carrying the key
/// equivalents there is no Cmd+C, Cmd+Z, or Cmd+F at all — NSTextView routes
/// those through the responder chain from the menu, not on its own. The Find
/// items are what give in-note search its native find bar.
enum MainMenu {
    static func build(
        target: AnyObject,
        preferencesAction: Selector,
        newNoteAction: Selector,
        globalSearchAction: Selector,
        moveNoteUpAction: Selector,
        moveNoteDownAction: Selector,
        nextNoteAction: Selector,
        previousNoteAction: Selector,
        toggleChromeAction: Selector,
        toggleChecklistAction: Selector,
        toggleHighlightAction: Selector
    ) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(target: target, preferencesAction: preferencesAction))
        mainMenu.addItem(fileMenuItem(
            target: target,
            newNoteAction: newNoteAction,
            moveNoteUpAction: moveNoteUpAction,
            moveNoteDownAction: moveNoteDownAction,
            nextNoteAction: nextNoteAction,
            previousNoteAction: previousNoteAction
        ))
        mainMenu.addItem(editMenuItem(target: target, globalSearchAction: globalSearchAction))
        mainMenu.addItem(viewMenuItem(target: target, toggleChromeAction: toggleChromeAction))
        mainMenu.addItem(formatMenuItem(
            target: target,
            toggleChecklistAction: toggleChecklistAction,
            toggleHighlightAction: toggleHighlightAction
        ))
        return mainMenu
    }

    private static func viewMenuItem(target: AnyObject, toggleChromeAction: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        let toggle = NSMenuItem(title: "Toggle Header & Footer", action: toggleChromeAction, keyEquivalent: "/")
        toggle.target = target
        menu.addItem(toggle)

        item.submenu = menu
        return item
    }

    private static func fileMenuItem(
        target: AnyObject,
        newNoteAction: Selector,
        moveNoteUpAction: Selector,
        moveNoteDownAction: Selector,
        nextNoteAction: Selector,
        previousNoteAction: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        let newNote = NSMenuItem(title: "New Note", action: newNoteAction, keyEquivalent: "n")
        newNote.target = target
        menu.addItem(newNote)

        menu.addItem(.separator())

        // Arrow-key equivalents are the function-key scalars AppKit expects.
        // The text view handles the same keystrokes directly too (see
        // PlainTextEditor.performKeyEquivalent), since the menu is not
        // reliably consulted outside Dock mode — both paths reach the same
        // NotesManager call.
        for (title, action, key) in [
            ("Next Note", nextNoteAction, NSRightArrowFunctionKey),
            ("Previous Note", previousNoteAction, NSLeftArrowFunctionKey),
        ] {
            let switchNote = NSMenuItem(title: title, action: action, keyEquivalent: String(UnicodeScalar(key)!))
            switchNote.keyEquivalentModifierMask = [.command, .option]
            switchNote.target = target
            menu.addItem(switchNote)
        }

        menu.addItem(.separator())

        for (title, action, key) in [
            ("Move Note Up", moveNoteUpAction, NSUpArrowFunctionKey),
            ("Move Note Down", moveNoteDownAction, NSDownArrowFunctionKey),
        ] {
            let move = NSMenuItem(title: title, action: action, keyEquivalent: String(UnicodeScalar(key)!))
            move.keyEquivalentModifierMask = [.command, .control]
            move.target = target
            menu.addItem(move)
        }

        menu.addItem(.separator())

        // nil target: walks the responder chain to whichever window is key.
        // The main panel already turns a real close into a hide (see
        // FloatingPanel.close()), so this closes Settings when it is key and
        // just hides the note otherwise — one shortcut, the right behaviour
        // in both places.
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        item.submenu = menu
        return item
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

    /// Explicit target posting a notification, rather than a nil target
    /// walking the responder chain to the text view directly — the same
    /// fix, and the same reason, as the header's Checklist/Highlight
    /// buttons (see the notifications' own doc comment in
    /// PreferencesView.swift). The key equivalents shown here (⌘L, ⇧⌘H)
    /// are cosmetic/discoverability only: `ChecklistTextView.
    /// performKeyEquivalent` already claims those keystrokes directly and
    /// never lets them reach the menu at all, so only an actual mouse click
    /// on these menu items goes through this path.
    private static func formatMenuItem(
        target: AnyObject,
        toggleChecklistAction: Selector,
        toggleHighlightAction: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Format")

        let checklist = NSMenuItem(title: "Toggle Checklist", action: toggleChecklistAction, keyEquivalent: "l")
        checklist.target = target
        menu.addItem(checklist)

        let highlight = NSMenuItem(title: "Toggle Highlight", action: toggleHighlightAction, keyEquivalent: "h")
        highlight.keyEquivalentModifierMask = [.command, .shift]
        highlight.target = target
        menu.addItem(highlight)
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

    private static func editMenuItem(target: AnyObject, globalSearchAction: Selector) -> NSMenuItem {
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
        menu.addItem(findMenuItem(target: target, globalSearchAction: globalSearchAction))

        item.submenu = menu
        return item
    }

    private static func findMenuItem(target: AnyObject, globalSearchAction: Selector) -> NSMenuItem {
        // Unlike a menu-bar-level item, a nested item does not inherit its
        // submenu's title automatically — without this the row was blank.
        let item = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
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

        menu.addItem(.separator())
        let globalSearch = NSMenuItem(title: "Search All Notes…", action: globalSearchAction, keyEquivalent: "f")
        globalSearch.keyEquivalentModifierMask = [.command, .shift]
        globalSearch.target = target
        menu.addItem(globalSearch)

        item.submenu = menu
        return item
    }
}
