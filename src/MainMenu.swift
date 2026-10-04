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
        checkForUpdatesAction: Selector,
        newNoteAction: Selector,
        deleteNoteAction: Selector,
        globalSearchAction: Selector,
        moveNoteUpAction: Selector,
        moveNoteDownAction: Selector,
        nextNoteAction: Selector,
        previousNoteAction: Selector,
        toggleChromeAction: Selector,
        toggleChecklistAction: Selector,
        toggleHighlightAction: Selector,
        showHelpAction: Selector
    ) -> NSMenu {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem(
            target: target,
            preferencesAction: preferencesAction,
            checkForUpdatesAction: checkForUpdatesAction
        ))
        mainMenu.addItem(fileMenuItem(
            target: target,
            newNoteAction: newNoteAction,
            deleteNoteAction: deleteNoteAction,
            moveNoteUpAction: moveNoteUpAction,
            moveNoteDownAction: moveNoteDownAction,
            nextNoteAction: nextNoteAction,
            previousNoteAction: previousNoteAction
        ))
        mainMenu.addItem(editMenuItem(target: target, globalSearchAction: globalSearchAction))
        // Format before View: the order the HIG gives for the menu bar, and
        // the one every other Mac app has trained people to scan in.
        mainMenu.addItem(formatMenuItem(
            target: target,
            toggleChecklistAction: toggleChecklistAction,
            toggleHighlightAction: toggleHighlightAction
        ))
        mainMenu.addItem(viewMenuItem(target: target, toggleChromeAction: toggleChromeAction))
        mainMenu.addItem(windowMenuItem())
        mainMenu.addItem(helpMenuItem(target: target, showHelpAction: showHelpAction))
        return mainMenu
    }

    /// Hands AppKit the menus it manages itself: the Window menu gains the
    /// list of open windows, Services fills in from the system, and Help
    /// gets the search field. Found by title so this works on whatever
    /// `build` returned without the caller tracking the pieces.
    static func registerSystemMenus(of mainMenu: NSMenu, with app: NSApplication) {
        func submenu(_ title: String, in menu: NSMenu) -> NSMenu? {
            menu.items.first { $0.submenu?.title == title }?.submenu
        }
        app.windowsMenu = submenu("Window", in: mainMenu)
        app.helpMenu = submenu("Help", in: mainMenu)
        if let appMenu = mainMenu.items.first?.submenu {
            app.servicesMenu = submenu("Services", in: appMenu)
        }
    }

    // MARK: - State-dependent titles

    /// View › Show/Hide Header & Footer. Says what choosing it will do, the
    /// way the HIG asks every show/hide item to. Mirrors `toggleChrome` in
    /// ContentView: a mixed state (only reachable from Settings) counts as
    /// showing, so the item offers to hide, which is what pressing it does.
    static func chromeToggleTitle(showsHeader: Bool, showsFooter: Bool) -> String {
        showsHeader || showsFooter ? "Hide Header & Footer" : "Show Header & Footer"
    }

    /// The update item, wherever it appears (the app menu and the status
    /// item's menu), so the two can never disagree about what it says or
    /// whether it can be chosen.
    struct UpdateItemState: Equatable {
        enum Action: Equatable {
            case check
            case install
        }
        let title: String
        let isEnabled: Bool
        let action: Action
    }

    static func updateItemState(isUpdating: Bool, availableVersion: String?) -> UpdateItemState {
        if isUpdating {
            return UpdateItemState(title: "Updating…", isEnabled: false, action: .install)
        }
        if let availableVersion {
            return UpdateItemState(title: "Update Available (v\(availableVersion))…", isEnabled: true, action: .install)
        }
        return UpdateItemState(title: "Check for Updates…", isEnabled: true, action: .check)
    }

    private static func viewMenuItem(target: AnyObject, toggleChromeAction: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        // Retitled Show/Hide by `validateMenuItem` in AppDelegate, which can
        // read the settings; this initial title is what it says before the
        // menu first opens.
        let toggle = NSMenuItem(title: "Hide Header & Footer", action: toggleChromeAction, keyEquivalent: "/")
        toggle.target = target
        menu.addItem(toggle)

        menu.addItem(.separator())

        // nil target: the key panel answers `toggleFullScreen:` itself, and
        // NSWindow retitles this to Exit Full Screen while it is full screen.
        // FloatingPanel disables it in the modes whose window can't have a
        // Space of its own.
        let fullScreen = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreen)

        item.submenu = menu
        return item
    }

    /// Minimize and Zoom are here even though Jot has one window: the HIG
    /// asks for them so Full Keyboard Access can reach both. nil targets, so
    /// the key window validates them (FloatingPanel per display mode, the
    /// Settings window by its own style mask).
    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        item.submenu = menu
        return item
    }

    private static func helpMenuItem(target: AnyObject, showHelpAction: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")

        let help = NSMenuItem(title: "Jot Help", action: showHelpAction, keyEquivalent: "?")
        help.target = target
        menu.addItem(help)

        item.submenu = menu
        return item
    }

    private static func fileMenuItem(
        target: AnyObject,
        newNoteAction: Selector,
        deleteNoteAction: Selector,
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
            // Option-Cmd, the same family as Next/Previous Note above.
            move.keyEquivalentModifierMask = [.command, .option]
            move.target = target
            menu.addItem(move)
        }

        menu.addItem(.separator())

        // Shift-Cmd-Delete, not Cmd-Delete: a menu sees key equivalents before
        // the text view's key bindings do, and Cmd-Delete there is "delete to
        // the start of the line". Undoable, so no confirmation.
        let delete = NSMenuItem(
            title: "Delete Note",
            action: deleteNoteAction,
            keyEquivalent: String(Character(UnicodeScalar(NSBackspaceCharacter)!))
        )
        delete.keyEquivalentModifierMask = [.command, .shift]
        delete.target = target
        menu.addItem(delete)

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

    private static func appMenuItem(
        target: AnyObject,
        preferencesAction: Selector,
        checkForUpdatesAction: Selector
    ) -> NSMenuItem {
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

        // Same action as the status item's update row; AppDelegate's
        // `validateMenuItem` retitles it from `updateItemState`.
        let updates = NSMenuItem(title: "Check for Updates…", action: checkForUpdatesAction, keyEquivalent: "")
        updates.target = target
        menu.addItem(updates)

        let sync = NSMenuItem(
            title: "Sync to Apple Notes",
            action: Selector(("syncToAppleNotesNow:")),
            keyEquivalent: ""
        )
        sync.target = target
        menu.addItem(sync)

        menu.addItem(.separator())

        // Filled in by the system once registered as `NSApp.servicesMenu`.
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        menu.addItem(services)

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide Jot",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )

        menu.addItem(.separator())
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

        // nil target, like Extract Text below: these act on whichever note
        // editor is first responder, which matters in Screen Edge mode where
        // several are on screen. As with the two above, the text view's
        // `performKeyEquivalent` claims Cmd+B / Cmd+I itself, so the menu is
        // for discoverability and mouse use.
        menu.addItem(withTitle: "Bold", action: #selector(ChecklistTextView.toggleBold(_:)), keyEquivalent: "b")
        menu.addItem(withTitle: "Italic", action: #selector(ChecklistTextView.toggleItalic(_:)), keyEquivalent: "i")
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
