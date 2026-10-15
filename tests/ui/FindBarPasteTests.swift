import AppKit
import Carbon.HIToolbox
import Foundation

// Issue #18: Cmd+V while typing in the Cmd+F find bar pasted into the note.
// The note's text view claims a handful of shortcuts in
// `performKeyEquivalent` so they work in display modes with no main menu.
// AppKit offers key equivalents to every view in the window, focused or not,
// so an unguarded claim reached over whatever field actually had the
// keyboard. Driven here with a real key window and a real text field as the
// first responder, which a windowless test cannot create.

@MainActor
private func makeEditorWithField(_ text: String) -> (window: NSWindow, view: ChecklistTextView, field: NSTextField) {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
    let field = NSTextField(frame: NSRect(x: 10, y: 285, width: 300, height: 24))
    let view = ChecklistTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 270))
    view.baseFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    view.textStorage?.delegate = view
    view.string = text
    view.applyChecklistStyling()
    container.addSubview(view)
    container.addSubview(field)
    window.contentView = container
    window.center()
    _ = bringUpAndWaitUntilKey(window)
    return (window, view, field)
}

@MainActor
private func keyEquivalent(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: Int, in window: NSWindow) -> NSEvent? {
    NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: UInt16(keyCode)
    )
}

func runFindBarPasteTests() {
    MainActor.assumeIsolated {
        suite("Cmd+V in another field pastes there, not into the note (#18)") {
            let note = "my note"
            let (window, view, field) = makeEditorWithField(note)
            defer { window.close() }

            let pasteboard = NSPasteboard.general
            let saved = pasteboard.string(forType: .string)
            defer {
                pasteboard.clearContents()
                if let saved { pasteboard.setString(saved, forType: .string) }
            }
            pasteboard.clearContents()
            pasteboard.setString("needle", forType: .string)

            window.makeFirstResponder(field)
            pump(0.1)
            check(field.currentEditor() != nil, "the field is being edited")

            if let event = keyEquivalent("v", .command, keyCode: kVK_ANSI_V, in: window) {
                _ = window.contentView?.performKeyEquivalent(with: event)
            }
            pump(0.1)
            equal(view.string, note, "the note is untouched")
            equal(field.stringValue, "needle", "the text went into the focused field")
        }

        suite("Cmd+V in the note still pastes into the note") {
            let (window, view, _) = makeEditorWithField("a")
            defer { window.close() }
            let pasteboard = NSPasteboard.general
            let saved = pasteboard.string(forType: .string)
            defer {
                pasteboard.clearContents()
                if let saved { pasteboard.setString(saved, forType: .string) }
            }
            pasteboard.clearContents()
            pasteboard.setString("b", forType: .string)
            window.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: 1, length: 0))
            pump(0.1)
            if let event = keyEquivalent("v", .command, keyCode: kVK_ANSI_V, in: window) {
                _ = window.contentView?.performKeyEquivalent(with: event)
            }
            pump(0.1)
            equal(view.string, "ab", "pasted at the caret")
        }

        suite("Cmd+L and Shift-Cmd-H leave the note alone while another field has focus") {
            let note = "buy milk"
            let (window, view, field) = makeEditorWithField(note)
            defer { window.close() }
            window.makeFirstResponder(field)
            pump(0.1)
            if let event = keyEquivalent("l", .command, keyCode: kVK_ANSI_L, in: window) {
                _ = window.contentView?.performKeyEquivalent(with: event)
            }
            if let event = keyEquivalent("h", [.command, .shift], keyCode: kVK_ANSI_H, in: window) {
                _ = window.contentView?.performKeyEquivalent(with: event)
            }
            pump(0.1)
            equal(view.string, note, "no checklist marker or highlight added")
        }
    }
}
