import AppKit
import Carbon.HIToolbox

// The Settings window's decisions that don't need a window: which pane it
// reopens on, how tall a pane may make it, which keys close it, and that each
// pane has a toolbar icon. The window itself is exercised for real by
// tests/ui/SettingsWindowTests.swift.

func runSettingsWindowLogicTests() {

    suite("Settings: the last pane is remembered") {
        let defaults = UserDefaults(suiteName: "settings-pane-\(UUID().uuidString)")!
        equal(SettingsCategory.lastViewed(in: defaults), .general, "a first open lands on General")

        for category in SettingsCategory.allCases {
            category.remember(in: defaults)
            equal(SettingsCategory.lastViewed(in: defaults), category, "\(category.title) round-trips")
        }

        defaults.set("a pane from some other version", forKey: SettingsCategory.lastPaneDefaultsKey)
        equal(SettingsCategory.lastViewed(in: defaults), .general, "an unknown stored pane falls back to General")
    }

    suite("Settings: pane height follows the content, within limits") {
        typealias L = SettingsWindowLayout
        equal(L.contentHeight(forIdealHeight: 374), 374, "a pane that fits is shown whole")
        equal(L.contentHeight(forIdealHeight: 658.6), 659, "a fractional ideal height rounds up, never clipping the last row")
        equal(L.contentHeight(forIdealHeight: 1278), L.maxPaneHeight, "a very tall pane is capped and scrolls")
        equal(L.contentHeight(forIdealHeight: 20), L.minPaneHeight, "a tiny pane still gets the floor")
        equal(L.contentHeight(forIdealHeight: 600, screenLimit: 500.4), 500, "a short screen caps it further")
        equal(L.contentHeight(forIdealHeight: 300, screenLimit: 500), 300, "the screen limit leaves a pane that fits alone")
        check(L.maxPaneHeight >= 660, "Notes & Timers, about 660pt tall, fits without scrolling")
    }

    suite("Settings: ⌘W and Escape close the window") {
        check(SettingsWindow.isCloseChord(characters: "w", modifierFlags: .command), "⌘W closes")
        check(SettingsWindow.isCloseChord(characters: "w", modifierFlags: [.command, .capsLock]),
              "⌘W closes with Caps Lock on")
        check(!SettingsWindow.isCloseChord(characters: "w", modifierFlags: [.command, .option]), "⌥⌘W does not")
        check(!SettingsWindow.isCloseChord(characters: "w", modifierFlags: [.command, .shift]), "⇧⌘W does not")
        check(!SettingsWindow.isCloseChord(characters: "w", modifierFlags: []), "a bare w does not")
        check(!SettingsWindow.isCloseChord(characters: "q", modifierFlags: .command), "⌘Q is not mistaken for it")

        let escape = UInt16(kVK_Escape)
        check(SettingsWindow.isEscape(keyCode: escape, modifierFlags: []), "Escape closes")
        check(SettingsWindow.isEscape(keyCode: escape, modifierFlags: .capsLock), "Escape closes with Caps Lock on")
        check(!SettingsWindow.isEscape(keyCode: escape, modifierFlags: .option), "⌥Escape is left alone")
        check(!SettingsWindow.isEscape(keyCode: UInt16(kVK_ANSI_W), modifierFlags: []), "another key is not Escape")
    }

    suite("Settings: every pane has a toolbar icon and a name") {
        for category in SettingsCategory.allCases {
            check(NSImage(systemSymbolName: category.icon, accessibilityDescription: nil) != nil,
                  "\(category.title)'s symbol \(category.icon) exists")
            check(!category.title.isEmpty, "\(category.rawValue) has a title for the toolbar and window")
        }
        equal(Set(SettingsCategory.allCases.map(\.title)).count, SettingsCategory.allCases.count,
              "pane titles are distinct, so the window title always says which pane is showing")
    }
}
