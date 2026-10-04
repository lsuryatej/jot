import AppKit
import Carbon.HIToolbox
import Foundation
import SwiftUI

// Real Settings window, real toolbar, real SwiftUI. The bug classes the
// pure-logic suite structurally cannot see: a pane switch that does not land,
// a pane you cannot leave, a window title that does not follow the pane, a
// pane that is not restored, and a window whose height clips a pane or
// leaves it floating in empty space.
//
// The window is the app's own `SettingsWindowController`, not a stand-in, so
// these exercise the same toolbar, sizing, and key handling a person gets.

// MARK: - Fixtures

/// Throwaway store and defaults, so a run never touches the user's real notes
/// or real UserDefaults. Same injection points the fast suite uses.
@MainActor
func makeSettingsFixtures() -> (settings: SettingsManager, notes: NotesManager, directory: URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("jot-ui-tests-\(UUID().uuidString)")
    let store = NoteStore(fileURL: directory.appendingPathComponent("notes.json"),
                          allowsLegacyMigration: false)
    store.save([Note(text: "harness note")])
    let notes = NotesManager(store: store, saveDebounce: 0)
    let settings = SettingsManager(defaults: UserDefaults(suiteName: "uitest-\(UUID().uuidString)")!)
    return (settings, notes, directory)
}

/// A fresh defaults suite for the remembered pane, separate from the one
/// `SettingsManager` uses, so the pane a test leaves behind never leaks into
/// the next.
func makePaneDefaults() -> UserDefaults {
    UserDefaults(suiteName: "uitest-pane-\(UUID().uuidString)")!
}

/// Builds the Settings window exactly as the app does, brings it up, and waits
/// until it is key and its size has settled.
@MainActor
func openSettingsWindow(
    settings: SettingsManager,
    notes: NotesManager,
    defaults: UserDefaults = makePaneDefaults(),
    pane: SettingsCategory? = nil
) -> SettingsWindowController {
    let controller = SettingsWindowController(
        settings: settings, notesManager: notes, defaults: defaults, initialPane: pane
    )
    if let window = controller.window {
        bringUpAndWaitUntilKey(window)
    }
    return controller
}

// MARK: - Driving the toolbar

/// Selects `category` the way a click on its toolbar button does: the item's
/// own action, sent to its own target, through `NSApp.sendAction`.
@MainActor
func clickToolbarItem(_ category: SettingsCategory, in window: NSWindow) {
    reassertKey(window)
    guard let item = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == category.rawValue }),
          let action = item.action
    else {
        check(false, "toolbar has a button for \(category.title)")
        return
    }
    NSApp.sendAction(action, to: item.target, from: item)
    // Longer than the resize animation, then until the frame stops moving.
    pump(SettingsWindowLayout.resizeDuration + 0.1)
    waitForStableFrame(window)
}

@MainActor
private func sendSettingsKey(_ window: NSWindow, characters: String, keyCode: UInt16,
                             modifiers: NSEvent.ModifierFlags = []) {
    reassertKey(window)
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: keyCode
    ) else { return }
    NSApp.sendEvent(event)
    pump(0.2)
}

// MARK: - Measuring a pane

/// The scroll view a grouped `Form` lays its rows out in. Its document height
/// is the pane's real content height, measured independently of the ideal
/// size the window was sized from.
@MainActor
private func formScrollView(in view: NSView) -> NSScrollView? {
    if let scroll = view as? NSScrollView { return scroll }
    for subview in view.subviews {
        if let found = formScrollView(in: subview) { return found }
    }
    return nil
}

/// Content height and the pane's laid-out content height, for the size checks.
@MainActor
private func paneGeometry(_ controller: SettingsWindowController)
    -> (content: NSSize, document: NSSize, visible: NSSize)? {
    guard let window = controller.window,
          let paneView = controller.tabs.selectedPane?.view,
          let scroll = formScrollView(in: paneView),
          let document = scroll.documentView
    else { return nil }
    return (window.contentLayoutRect.size, document.frame.size, scroll.contentView.bounds.size)
}

// MARK: - Tests

func runSettingsWindowTests() {
    MainActor.assumeIsolated {
        let fixtures = makeSettingsFixtures()
        defer { try? FileManager.default.removeItem(at: fixtures.directory) }

        let controller = openSettingsWindow(settings: fixtures.settings, notes: fixtures.notes)
        guard let window = controller.window, let content = window.contentView else {
            check(false, "settings window has a content view")
            return
        }
        defer { window.close() }

        check(window.isKeyWindow, "settings window becomes key in a swiftc-built binary")

        // MARK: Standard settings-window chrome

        suite("it is a standard settings window") {
            check(window.toolbar != nil, "panes are a toolbar")
            equal(window.toolbar?.allowsUserCustomization, false, "the toolbar cannot be customised")
            equal(window.toolbar?.items.map(\.label), SettingsCategory.allCases.map(\.title),
                  "one toolbar button per pane, in order")
            check(!window.styleMask.contains(.resizable), "the window cannot be resized by hand")
            equal(window.standardWindowButton(.miniaturizeButton)?.isEnabled, false, "minimize is dimmed")
            equal(window.standardWindowButton(.zoomButton)?.isEnabled, false, "zoom is dimmed")
            equal(controller.selectedCategory, .general, "a first ever open lands on General")
            equal(window.title, "General", "the title names the visible pane, not the app")
        }

        // MARK: A — every toolbar button switches the pane

        var hashes: [String] = []
        suite("toolbar buttons switch panes") {
            for category in SettingsCategory.allCases {
                clickToolbarItem(category, in: window)
                equal(controller.selectedCategory, category, "\(category.title) is selected")
                equal(window.toolbar?.selectedItemIdentifier?.rawValue, category.rawValue,
                      "the \(category.title) button shows as the active one")
                equal(window.title, category.title, "the window title reads \(category.title)")
                let hash = renderHash(content)
                if hashes.contains(hash) {
                    let path = saveRender(content, named: "pane-\(category.rawValue)")
                    print("         rendering unchanged; artifact: \(path ?? "unavailable")")
                }
                hashes.append(hash)
            }
            equal(Set(hashes).count, SettingsCategory.allCases.count,
                  "all six panes render differently — a switch that never lands leaves the rendering identical")
        }

        suite("returning to a visited pane reproduces its rendering") {
            // Walks backwards, so each hop is from some other pane back to
            // one already seen.
            for (index, category) in SettingsCategory.allCases.enumerated().reversed() {
                clickToolbarItem(category, in: window)
                let actual = renderHash(content)
                if actual != hashes[index] {
                    let path = saveRender(content, named: "revisit-\(category.rawValue)")
                    print("         artifact: \(path ?? "unavailable")")
                }
                equal(actual, hashes[index], "switching back to \(category.title) reproduces its earlier rendering")
            }
        }

        // MARK: B — every pane can be left

        suite("every pane can be left") {
            // A fresh window per pane, so a pane that traps the window is
            // attributed to itself rather than to whichever ran before it.
            for category in SettingsCategory.allCases {
                let paneFixtures = makeSettingsFixtures()
                defer { try? FileManager.default.removeItem(at: paneFixtures.directory) }
                let paneController = openSettingsWindow(
                    settings: paneFixtures.settings, notes: paneFixtures.notes, pane: category
                )
                guard let paneWindow = paneController.window, let paneContent = paneWindow.contentView else {
                    check(false, "settings window has a content view on the \(category.title) pass")
                    continue
                }
                defer { paneWindow.close() }

                equal(paneController.selectedCategory, category, "opened straight onto \(category.title)")
                check(paneWindow.toolbar?.isVisible == true, "the toolbar is still showing on \(category.title)")

                let target: SettingsCategory = category == .general ? .privacy : .general
                clickToolbarItem(target, in: paneWindow)
                let escaped = paneController.selectedCategory == target && paneWindow.title == target.title
                if !escaped {
                    let path = saveRender(paneContent, named: "stuck-on-\(category.rawValue)")
                    print("         could not leave \(category.title); artifact: \(path ?? "unavailable")")
                }
                check(escaped, "\(target.title) is reachable from \(category.title)")
            }
        }

        // MARK: C — the window fits each pane

        suite("the window fits each pane, with no clipping and no slack") {
            let geometryFixtures = makeSettingsFixtures()
            defer { try? FileManager.default.removeItem(at: geometryFixtures.directory) }
            let sized = openSettingsWindow(settings: geometryFixtures.settings, notes: geometryFixtures.notes)
            guard let sizedWindow = sized.window else {
                check(false, "settings window exists")
                return
            }
            defer { sizedWindow.close() }

            let top = sizedWindow.frame.maxY
            let left = sizedWindow.frame.minX
            for category in SettingsCategory.allCases {
                clickToolbarItem(category, in: sizedWindow)
                guard let geometry = paneGeometry(sized) else {
                    check(false, "\(category.title)'s form is measurable")
                    continue
                }
                let expectedHeight = SettingsWindowLayout.contentHeight(
                    forIdealHeight: geometry.document.height,
                    screenLimit: sizedWindow.screen.map {
                        $0.visibleFrame.height - (sizedWindow.frame.height - sizedWindow.contentLayoutRect.height)
                            - 2 * SettingsWindowLayout.screenMargin
                    }
                )
                equal(geometry.content.width, SettingsWindowLayout.paneWidth, "\(category.title): the width never changes")
                equal(geometry.document.width, SettingsWindowLayout.paneWidth,
                      "\(category.title): the form lays out at the window's width, with nothing overflowing it")
                // A point of tolerance: the ideal height is fractional for a
                // pane with wrapped text, and the window rounds it up.
                check(abs(geometry.content.height - expectedHeight) <= 1,
                      "\(category.title): content is \(geometry.content.height)pt for a \(geometry.document.height)pt form")
                if geometry.document.height <= SettingsWindowLayout.maxPaneHeight {
                    check(geometry.visible.height + 1 >= geometry.document.height,
                          "\(category.title): the whole form is visible without scrolling")
                } else {
                    check(geometry.visible.height < geometry.document.height,
                          "\(category.title): taller than the cap, so it scrolls inside the window")
                }
                equal(sizedWindow.frame.maxY, top, "\(category.title): the top edge stays put")
                equal(sizedWindow.frame.minX, left, "\(category.title): the left edge stays put")
            }

            // A change inside a pane resizes too: an edge mode adds the Edge
            // and Width rows to General.
            clickToolbarItem(.general, in: sizedWindow)
            let before = sizedWindow.contentLayoutRect.height
            geometryFixtures.settings.displayMode = DisplayMode.allCases.first { $0.isEdgeDocked } ?? .floating
            pump(SettingsWindowLayout.resizeDuration + 0.2)
            waitForStableFrame(sizedWindow)
            if let geometry = paneGeometry(sized) {
                check(geometry.content.height > before, "General grows when an edge mode adds rows")
                check(abs(geometry.content.height - geometry.document.height.rounded(.up)) <= 1,
                      "and fits them exactly (\(geometry.content.height) for \(geometry.document.height))")
            } else {
                check(false, "General's form is measurable after the mode change")
            }
        }

        // MARK: D — the last pane is restored

        suite("the most recently viewed pane is restored") {
            let restoreFixtures = makeSettingsFixtures()
            defer { try? FileManager.default.removeItem(at: restoreFixtures.directory) }
            let defaults = makePaneDefaults()

            let first = openSettingsWindow(settings: restoreFixtures.settings, notes: restoreFixtures.notes, defaults: defaults)
            if let firstWindow = first.window {
                clickToolbarItem(.typography, in: firstWindow)
                firstWindow.close()
            }

            let second = openSettingsWindow(settings: restoreFixtures.settings, notes: restoreFixtures.notes, defaults: defaults)
            defer { second.window?.close() }
            equal(second.selectedCategory, .typography, "a new window opens on Typography, where the last one was left")
            equal(second.window?.title, "Typography", "and is titled for it")
            equal(second.window?.toolbar?.selectedItemIdentifier?.rawValue, SettingsCategory.typography.rawValue,
                  "with its toolbar button active")
        }

        // MARK: E — keyboard

        suite("⌘W and Escape close the window") {
            for (name, characters, keyCode, modifiers) in [
                ("⌘W", "w", UInt16(kVK_ANSI_W), NSEvent.ModifierFlags.command),
                ("Escape", "\u{1b}", UInt16(kVK_Escape), NSEvent.ModifierFlags())
            ] {
                let keyFixtures = makeSettingsFixtures()
                defer { try? FileManager.default.removeItem(at: keyFixtures.directory) }
                let keyed = openSettingsWindow(settings: keyFixtures.settings, notes: keyFixtures.notes)
                guard let keyedWindow = keyed.window else { continue }
                check(keyedWindow.isVisible, "the window is up before \(name)")
                sendSettingsKey(keyedWindow, characters: characters, keyCode: keyCode, modifiers: modifiers)
                check(!keyedWindow.isVisible, "\(name) closes it")
                keyedWindow.close()
            }
        }
    }
}
