import AppKit

// The main menu is hidden in Floating, Dropdown and Screen Edge modes, so the
// key note commands are mirrored into the editor's context menu and the
// status item's menu (design review H3).

func runContextMenuTests() {
    MainActor.assumeIsolated { contextMenuSuites() }
}

@MainActor
private func contextMenuSuites() {

    func titles(_ items: [NSMenuItem]) -> [String] {
        items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    /// The editor's items, after whatever super's menu held.
    func appended(_ view: ChecklistTextView) -> [NSMenuItem] {
        let menu = NSMenu()
        menu.addItem(withTitle: "Cut", action: nil, keyEquivalent: "")
        EditorContextMenu.append(to: menu, for: view)
        return Array(menu.items.dropFirst())
    }

    suite("the editor's context menu adds formatting and note commands after super's") {
        EditorContextMenu.isAvailable = nil
        let view = makeTextView("hello")
        let items = appended(view)
        equal(titles(items), [
            "-", "Bold", "Italic", "Bigger", "Smaller",
            "-", "Move Note Up", "Move Note Down", "Delete Note",
        ], "two groups, Delete last")
        check(items.allSatisfy { $0.keyEquivalent.isEmpty }, "no shortcuts shown: those belong in the main menu")
        check(items.first { $0.title == "Bold" }?.target === view, "Bold acts on this editor")
        check(items.first { $0.title == "Italic" }?.action == #selector(ChecklistTextView.toggleItalic(_:)),
              "Italic is the editor's own toggle")
    }

    suite("unavailable commands are hidden, not dimmed, as the HIG asks of context menus") {
        let view = makeTextView("code\nlet x = 1")
        view.codeKeyword = "code"
        EditorContextMenu.isAvailable = { command, _ in command != .moveUp && command != .bigger }
        defer { EditorContextMenu.isAvailable = nil }
        equal(titles(appended(view)), [
            "-", "Smaller",
            "-", "Move Note Down", "Delete Note",
        ], "Bold and Italic go in a code note; Move Up and Bigger when they can't act")

        EditorContextMenu.isAvailable = { _, _ in false }
        equal(titles(appended(view)), [], "nothing at all, not even a stray separator")
    }

    suite("the availability check is asked about this editor's note") {
        let view = makeTextView("hello")
        let id = UUID()
        view.noteID = id
        var asked: Set<UUID?> = []
        EditorContextMenu.isAvailable = { _, noteID in asked.insert(noteID); return true }
        defer { EditorContextMenu.isAvailable = nil }
        _ = appended(view)
        equal(asked, [id], "a Screen Edge card's own note")
    }

    suite("choosing a note command posts it with this editor's note") {
        EditorContextMenu.isAvailable = nil
        let view = makeTextView("hello")
        let id = UUID()
        view.noteID = id
        var posted: [String] = []
        let names: [Notification.Name] = [.jotRequestMoveNoteUp, .jotRequestMoveNoteDown, .jotRequestDeleteNote, .jotRequestTextSize]
        let tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { note in
                let object = (note.object as? UUID).map { $0 == id ? "this note" : "other" } ?? (note.object as? String ?? "nil")
                posted.append("\(name.rawValue): \(object)")
            }
        }
        defer { tokens.forEach(NotificationCenter.default.removeObserver) }

        for item in appended(view) where !item.isSeparatorItem && item.target !== view {
            check(item.target === EditorContextMenu.shared, "\(item.title) goes through the shared handler")
            EditorContextMenu.shared.perform(item)
        }
        equal(posted, [
            "JotRequestTextSize: bigger",
            "JotRequestTextSize: smaller",
            "JotRequestMoveNoteUp: this note",
            "JotRequestMoveNoteDown: this note",
            "JotRequestDeleteNote: this note",
        ], "each item reaches AppDelegate with the card it was opened on")
    }

    suite("moving a given note, not just the current one") {
        let manager = makeManager(seed: ["A", "B", "C"])
        manager.currentIndex = 0
        manager.moveNote(at: 2, by: -1)
        equal(manager.texts, ["A", "C", "B"], "C moved up one")
        equal(manager.currentText, "A", "the note on screen stayed put")
        manager.moveNote(at: 0, by: +1)
        equal(manager.texts, ["C", "A", "B"], "A moved down one")
        manager.moveNote(at: 2, by: +1)
        equal(manager.texts, ["C", "A", "B"], "the last note can't go further down")
    }

    suite("the status item's menu carries the key commands") {
        let menu = MainMenu.buildStatusMenu(
            target: MainMenuTestTarget.shared,
            isInterfaceVisible: true,
            updateTitle: "Check for Updates…",
            toggleAction: #selector(MainMenuTestTarget.noop),
            newNoteAction: #selector(MainMenuTestTarget.noop),
            deleteNoteAction: #selector(MainMenuTestTarget.noop),
            updateAction: #selector(MainMenuTestTarget.noop),
            preferencesAction: #selector(MainMenuTestTarget.noop),
            quitAction: #selector(MainMenuTestTarget.noop)
        )
        equal(titles(menu.items), [
            "Hide Jot", "-",
            "New Note", "Delete Note", "-",
            "Check for Updates…", "Settings…", "-",
            "Quit Jot",
        ], "Show/Hide, note commands, app commands, Quit")
        check(menu.items.allSatisfy { $0.isSeparatorItem || $0.target === MainMenuTestTarget.shared },
              "every item targets the delegate, which validates them")

        let hidden = MainMenu.buildStatusMenu(
            target: MainMenuTestTarget.shared,
            isInterfaceVisible: false,
            updateTitle: "Update Available (v2.0)…",
            toggleAction: #selector(MainMenuTestTarget.noop),
            newNoteAction: #selector(MainMenuTestTarget.noop),
            deleteNoteAction: #selector(MainMenuTestTarget.noop),
            updateAction: #selector(MainMenuTestTarget.noop),
            preferencesAction: #selector(MainMenuTestTarget.noop),
            quitAction: #selector(MainMenuTestTarget.noop)
        )
        equal(hidden.items.first?.title, "Show Jot", "offers to show when hidden")
        check(hidden.items.contains { $0.title == "Update Available (v2.0)…" }, "the update row's title is passed through")
    }
}
