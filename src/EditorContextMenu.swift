import AppKit

/// A note command offered from the editor's context menu.
enum EditorCommand: String {
    case bigger
    case smaller
    case moveUp
    case moveDown
    case deleteNote
}

/// The editor's context-menu additions.
///
/// The main menu isn't shown in Floating, Dropdown and Screen Edge modes, so
/// without these the commands it holds would have no mouse route at all
/// there. Kept out of PlainTextEditor.swift: `ChecklistTextView.menu(for:)`
/// only hands its menu here.
///
/// Context-menu rules from the HIG: no shortcuts shown (they belong to the
/// main menu), unavailable items hidden rather than dimmed, few groups, and
/// the destructive item last.
@MainActor
final class EditorContextMenu: NSObject {
    static let shared = EditorContextMenu()

    /// Whether a command can act right now, for the editor showing `noteID`
    /// (nil: the single-note editor, i.e. the current note). Set by
    /// AppDelegate, which owns the notes and the display mode. Nil offers
    /// everything.
    static var isAvailable: ((EditorCommand, UUID?) -> Bool)?

    static func append(to menu: NSMenu, for view: ChecklistTextView) {
        func available(_ command: EditorCommand) -> Bool {
            isAvailable?(command, view.noteID) ?? true
        }

        var formatting: [NSMenuItem] = []
        // Markers are literal inside a code block, as the main menu says by
        // disabling these; a context menu says it by leaving them out.
        if !view.isCodeMode {
            for (title, action) in [
                ("Bold", #selector(ChecklistTextView.toggleBold(_:))),
                ("Italic", #selector(ChecklistTextView.toggleItalic(_:))),
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = view
                formatting.append(item)
            }
        }
        for (title, command) in [("Bigger", EditorCommand.bigger), ("Smaller", .smaller)] where available(command) {
            formatting.append(item(title, command, view))
        }

        var note: [NSMenuItem] = []
        for (title, command) in [
            ("Move Note Up", EditorCommand.moveUp),
            ("Move Note Down", .moveDown),
            ("Delete Note", .deleteNote),
        ] where available(command) {
            note.append(item(title, command, view))
        }

        for group in [formatting, note] where !group.isEmpty {
            menu.addItem(.separator())
            group.forEach(menu.addItem)
        }
    }

    private struct Payload {
        let command: EditorCommand
        let noteID: UUID?
    }

    private static func item(_ title: String, _ command: EditorCommand, _ view: ChecklistTextView) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(perform(_:)), keyEquivalent: "")
        item.target = shared
        item.representedObject = Payload(command: command, noteID: view.noteID)
        return item
    }

    /// Posts the same requests the keyboard shortcuts do, carrying the note
    /// the menu was opened on so a Screen Edge card acts on itself.
    @objc func perform(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? Payload else { return }
        let center = NotificationCenter.default
        switch payload.command {
        case .bigger: center.post(name: .jotRequestTextSize, object: TextSizeCommand.bigger.rawValue)
        case .smaller: center.post(name: .jotRequestTextSize, object: TextSizeCommand.smaller.rawValue)
        case .moveUp: center.post(name: .jotRequestMoveNoteUp, object: payload.noteID)
        case .moveDown: center.post(name: .jotRequestMoveNoteDown, object: payload.noteID)
        case .deleteNote: center.post(name: .jotRequestDeleteNote, object: payload.noteID)
        }
    }
}
