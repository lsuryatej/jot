import AppKit
import Carbon.HIToolbox

// Format > Font > Bigger / Smaller / Actual Size (design review M10), and the
// size range widened from 11-24 to 11-32 so text can reach Apple's 200%
// guidance (13pt default, 26pt doubled, with headroom).

func runTextSizeTests() {

    suite("the size range is 11 to 32 everywhere it is enforced") {
        equal(SettingsManager.fontSizeRange, 11...32, "the slider's and the clamp's range")
        equal(SettingsManager.clampedFontSize(40), 32, "too large comes down to 32")
        equal(SettingsManager.clampedFontSize(28), 28, "28 is now allowed")
        equal(SettingsManager.clampedFontSize(8), 11, "too small comes up to 11")
        equal(SettingsManager.defaultFontSize, 13, "the default Actual Size returns to")
    }

    suite("Bigger and Smaller step a point at a time, within the range") {
        equal(TextSizeCommand.bigger.resized(nil, inherited: 13), 14, "a note with no size of its own grows from the inherited one")
        equal(TextSizeCommand.bigger.resized(20, inherited: 13), 21, "its own size grows")
        equal(TextSizeCommand.smaller.resized(20, inherited: 13), 19, "and shrinks")
        equal(TextSizeCommand.bigger.resized(32, inherited: 13), 32, "never past 32")
        equal(TextSizeCommand.smaller.resized(11, inherited: 13), 11, "never under 11")
        equal(TextSizeCommand.bigger.resized(13.6, inherited: 13), 15, "a fractional size lands on a whole point")
        equal(TextSizeCommand.actualSize.resized(20, inherited: 13), nil, "Actual Size drops the note's own size")
    }

    suite("each command is disabled where it would do nothing") {
        check(!TextSizeCommand.bigger.canApply(to: 32, inherited: 13), "Bigger at the top")
        check(TextSizeCommand.bigger.canApply(to: nil, inherited: 13), "Bigger from the inherited size")
        check(!TextSizeCommand.bigger.canApply(to: nil, inherited: 32), "not when the inherited size is already the top")
        check(!TextSizeCommand.smaller.canApply(to: 11, inherited: 13), "Smaller at the bottom")
        check(TextSizeCommand.smaller.canApply(to: 12, inherited: 13), "Smaller above it")
        check(!TextSizeCommand.actualSize.canApply(to: nil, inherited: 13), "Actual Size when already actual")
        check(TextSizeCommand.actualSize.canApply(to: 15, inherited: 13), "Actual Size with a size of its own")
    }

    suite("a per-note size from an old or hand-edited file is clamped on display") {
        let settings = makeTestSettings()
        equal(settings.resolvedFontSize(perNote: 90), 32, "too large comes down")
        equal(settings.resolvedFontSize(perNote: 4), 11, "too small comes up")
        equal(settings.resolvedFontSize(perNote: 28), 28, "in range passes through")
    }

    suite("a stored global size of 28 survives relaunch now") {
        let settings = makeTestSettings(seedSize: 28)
        equal(settings.noteFontSize, 28, "no longer clamped to 24 at load")
    }

    suite("the Format menu has Font > Bold, Italic, Bigger, Smaller, Actual Size") {
        let format = submenu("Format", of: makeTestMainMenu())
        let font = menuItem("Font", in: format)?.submenu
        check(font != nil, "Font is a submenu of Format")
        let visible = font?.items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        equal(visible, ["Bold", "Italic", "-", "Bigger", "Smaller", "Actual Size"], "standard Font items")
        let bigger = font?.items.filter { $0.title == "Bigger" } ?? []
        equal(Set(bigger.map(\.keyEquivalent)), ["+", "="], "Bigger answers Cmd-+ and Cmd-= (no Shift needed)")
        check(bigger.allSatisfy { $0.keyEquivalentModifierMask == [.command] }, "both with Command alone")
        check(bigger.contains { $0.isHidden && $0.allowsKeyEquivalentWhenHidden }, "the Cmd-= alias is hidden but live")
        equal(menuItem("Smaller", in: font)?.keyEquivalent, "-", "Smaller is Cmd--")
        equal(menuItem("Actual Size", in: font)?.keyEquivalent, "0", "Actual Size is Cmd-0")
    }

    suite("the editor claims the text-size chords, for modes without a menu") {
        let view = makeTextView("existing")
        var requests: [String] = []
        let token = NotificationCenter.default.addObserver(forName: .jotRequestTextSize, object: nil, queue: nil) { note in
            requests.append((note.object as? String) ?? "?")
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // On most layouts + is Shift-=, so it arrives with Shift held.
        let chords: [(String, NSEvent.ModifierFlags)] = [
            ("=", [.command]), ("+", [.command, .shift]), ("-", [.command]), ("0", [.command]),
        ]
        for (chars, modifiers) in chords {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: 0
            )!
            check(view.performKeyEquivalent(with: event), "Cmd-\(chars) is claimed")
        }
        equal(requests, [TextSizeCommand.bigger.rawValue, TextSizeCommand.bigger.rawValue,
                         TextSizeCommand.smaller.rawValue, TextSizeCommand.actualSize.rawValue],
              "Bigger twice, Smaller, Actual Size")
    }
}

/// Disposable defaults, so a test run never reads or writes the user's real
/// preferences.
func makeTestSettings(seedSize: Double? = nil) -> SettingsManager {
    let name = "JotTests.textsize-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    if let seedSize { defaults.set(seedSize, forKey: "noteFontSize") }
    return SettingsManager(defaults: defaults)
}
