import AppKit
import Carbon.HIToolbox
import Foundation

// Design review M5: shortcut matching compared the event's flags after
// `.deviceIndependentFlagsMask`, which keeps Caps Lock, `.numericPad` and
// `.function`. With Caps Lock on every exact-match shortcut failed, and the
// arrow keys (which AppKit always tags with `.numericPad` and `.function`)
// could never match a real event at all. These synthesize events carrying
// exactly those extra flags.

private func shortcut(_ view: ChecklistTextView, _ chars: String, _ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> Bool {
    let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: keyCode
    )!
    return view.performKeyEquivalent(with: event)
}

/// The flags a real arrow key-down carries on top of the chord.
private let arrowExtras: NSEvent.ModifierFlags = [.numericPad, .function]

private func firesNotification(_ name: Notification.Name, _ body: () -> Bool) -> (handled: Bool, fired: Bool) {
    var fired = false
    let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in fired = true }
    defer { NotificationCenter.default.removeObserver(token) }
    let handled = body()
    return (handled, fired)
}

func runModifierMaskTests() {

    suite("shortcutModifiers keeps only command, option, control and shift") {
        let all: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .capsLock, .numericPad, .function, .help]
        equal(all.shortcutModifiers, [.command, .option, .control, .shift], "the four chord keys survive, nothing else")
        equal(NSEvent.ModifierFlags([.command, .capsLock]).shortcutModifiers, [.command], "Caps Lock is dropped")
        equal(NSEvent.ModifierFlags([.numericPad, .function]).shortcutModifiers, [], "a bare arrow has no chord")
    }

    suite("Cmd+L toggles the checklist with Caps Lock on") {
        let view = makeTextView("- [ ] task")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        check(shortcut(view, "l", [.command, .capsLock]), "handled")
        equal(view.string, "- [x] task", "the line toggled")
    }

    suite("Cmd+L with Caps Lock on still toggles when the character arrives uppercase") {
        let view = makeTextView("- [ ] task")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        check(shortcut(view, "L", [.command, .capsLock]), "handled")
        equal(view.string, "- [x] task", "the line toggled")
    }

    suite("Cmd+B and Cmd+I wrap with Caps Lock on") {
        let view = makeTextView("make this bold")
        view.setSelectedRange(NSRange(location: 10, length: 4))
        check(shortcut(view, "b", [.command, .capsLock]), "Cmd+B handled")
        equal(view.string, "make this **bold**", "bold applied")

        let italic = makeTextView("make this lean")
        italic.setSelectedRange(NSRange(location: 10, length: 4))
        check(shortcut(italic, "i", [.command, .capsLock]), "Cmd+I handled")
        equal(italic.string, "make this *lean*", "italic applied")
    }

    suite("Cmd+N and Cmd+/ post their notifications with Caps Lock on") {
        let view = makeTextView("existing")
        let newNote = firesNotification(.jotRequestNewNote) { shortcut(view, "n", [.command, .capsLock]) }
        check(newNote.handled && newNote.fired, "Cmd+N")
        let chrome = firesNotification(.jotRequestToggleChrome) { shortcut(view, "/", [.command, .capsLock]) }
        check(chrome.handled && chrome.fired, "Cmd+/")
        let search = firesNotification(.jotRequestGlobalSearch) { shortcut(view, "f", [.command, .shift, .capsLock]) }
        check(search.handled && search.fired, "Shift-Cmd-F")
        equal(view.string, "existing", "nothing typed into the note")
    }

    suite("Shift-Cmd-H highlights with Caps Lock on") {
        let view = makeTextView("remember this")
        view.setSelectedRange(NSRange(location: 9, length: 4))
        check(shortcut(view, "h", [.command, .shift, .capsLock]), "handled")
        equal(view.string, "remember ==this==", "highlight applied")
    }

    suite("arrow chords match a real arrow event's numericPad and function flags") {
        let view = makeTextView("plain text, not a list")
        let next = firesNotification(.jotRequestNextNote) {
            shortcut(view, "", NSEvent.ModifierFlags([.command, .option]).union(arrowExtras), keyCode: UInt16(kVK_RightArrow))
        }
        check(next.handled && next.fired, "Cmd-Option-Right switches note")
        let previous = firesNotification(.jotRequestPreviousNote) {
            shortcut(view, "", NSEvent.ModifierFlags([.command, .option]).union(arrowExtras), keyCode: UInt16(kVK_LeftArrow))
        }
        check(previous.handled && previous.fired, "Cmd-Option-Left switches note")
        let previousCaps = firesNotification(.jotRequestPreviousNote) {
            shortcut(view, "", NSEvent.ModifierFlags([.command, .option, .capsLock]).union(arrowExtras), keyCode: UInt16(kVK_LeftArrow))
        }
        check(previousCaps.handled && previousCaps.fired, "Cmd-Option-Left with Caps Lock on")
        let up = firesNotification(.jotRequestMoveNoteUp) {
            shortcut(view, "", NSEvent.ModifierFlags([.command, .control]).union(arrowExtras), keyCode: UInt16(kVK_UpArrow))
        }
        check(up.handled && up.fired, "Ctrl-Cmd-Up outside a list still moves the note")
    }

    suite("a bare arrow with numericPad/function is still not a shortcut") {
        let view = makeTextView("existing")
        check(!shortcut(view, "", arrowExtras, keyCode: UInt16(kVK_RightArrow)), "falls through to caret movement")
        check(!shortcut(view, "", arrowExtras.union(.capsLock), keyCode: UInt16(kVK_RightArrow)), "Caps Lock alone adds no chord")
    }

    suite("Caps Lock plus an extra chord key is not mistaken for the shortcut") {
        let view = makeTextView("- [ ] task")
        view.setSelectedRange(NSRange(location: 3, length: 0))
        check(!shortcut(view, "l", [.command, .option, .capsLock]), "Option-Cmd-L is a different chord")
        equal(view.string, "- [ ] task", "unchanged")
    }
}
