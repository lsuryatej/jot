import AppKit
import Foundation
import SwiftUI

// Real Settings window, real clicks, real SwiftUI. These are the three bug
// classes that shipped and that the pure-logic suite structurally cannot see:
// a sidebar whose rows do not register clicks, a sidebar that stops being
// reachable once a particular pane is showing, and a window that changes size
// when the pane changes.

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

// MARK: - Geometry

/// Mirrors `AppDelegate.showPreferences()` in src/Jot.swift, including the
/// requested content size and the minimum, so the test exercises the real
/// NSHostingController path rather than a convenient stand-in.
enum SettingsWindowGeometry {
    static let requestedContentSize = NSSize(width: 680, height: 480)
    static let minimumSize = NSSize(width: 560, height: 380)

    /// The floor `PreferencesView` itself declares, in src/PreferencesView.swift.
    /// NSHostingController sizes the window from the SwiftUI content's ideal
    /// size, and this floor is what that ideal resolves to — which is why the
    /// window does not come up at `requestedContentSize`.
    static let declaredContentFloor = NSSize(width: 620, height: 420)

    /// Sidebar geometry, from `PreferencesView.sidebar`: `.frame(width: 172)`,
    /// `.padding(.vertical, 10)` / `.padding(.horizontal, 8)`, rows spaced 2pt
    /// apart, each row 6pt of vertical padding around a single line of text.
    static let sidebarWidth: CGFloat = 172
    static let sidebarTopInset: CGFloat = 8
    static let rowPitch: CGFloat = 32

    /// Row order, matching `SettingsCategory.allCases`. That enum is private to
    /// PreferencesView, so the titles are restated here purely as labels.
    static let categoryTitles = ["General", "Appearance", "Typography", "Notes & Timers", "Shortcuts", "Privacy & Sync"]

    /// Distance from the top of the content view to the centre of row `index`.
    /// Measured centres are 24, 56, 88, 120, 152, 184.
    static func rowCentreFromTop(_ index: Int) -> CGFloat {
        sidebarTopInset + rowPitch / 2 + CGFloat(index) * rowPitch
    }

    static var clickX: CGFloat { sidebarWidth / 2 }
}

/// Builds the Settings window exactly as the app does, brings it up, and waits
/// until it is key.
@MainActor
func openSettingsWindow(settings: SettingsManager, notes: NotesManager) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: SettingsWindowGeometry.requestedContentSize),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.title = "Jot Settings"
    window.minSize = SettingsWindowGeometry.minimumSize
    window.contentViewController = NSHostingController(rootView: PreferencesView(settings: settings, notesManager: notes))
    window.isReleasedWhenClosed = false
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    pump(1.0)
    return window
}

/// Clicks sidebar row `index`, converting the measured top-down centre into
/// window coordinates (bottom-left origin).
@MainActor
func clickSidebarRow(_ index: Int, in window: NSWindow) {
    guard let content = window.contentView else { return }
    let y = content.bounds.height - SettingsWindowGeometry.rowCentreFromTop(index)
    click(window, at: NSPoint(x: SettingsWindowGeometry.clickX, y: y))
}

// MARK: - Tests

func runSettingsWindowTests() {
    MainActor.assumeIsolated {
        let fixtures = makeSettingsFixtures()
        defer { try? FileManager.default.removeItem(at: fixtures.directory) }

        let window = openSettingsWindow(settings: fixtures.settings, notes: fixtures.notes)
        defer { window.close() }
        guard let content = window.contentView else {
            check(false, "settings window has a content view")
            return
        }

        check(window.isKeyWindow, "settings window becomes key in a swiftc-built binary")

        // MARK: A — every sidebar row registers its click

        var hashes: [String] = []
        suite("sidebar rows register clicks") {
            for (index, title) in SettingsWindowGeometry.categoryTitles.enumerated() {
                clickSidebarRow(index, in: window)
                let hash = renderHash(content)
                hashes.append(hash)
                if hashes.dropLast().contains(hash) {
                    let path = saveRender(content, named: "pane-\(index)-\(title.replacingOccurrences(of: " ", with: "-"))")
                    print("         rendering unchanged; artifact: \(path ?? "unavailable")")
                }
            }
            equal(Set(hashes).count, SettingsWindowGeometry.categoryTitles.count,
                  "all six panes render differently — a row whose click never lands leaves the rendering identical")
        }

        suite("returning to a visited row reproduces its rendering") {
            // Deliberately walks backwards, so each hop is a click from some
            // other pane back to one already seen.
            for index in stride(from: SettingsWindowGeometry.categoryTitles.count - 1, through: 0, by: -1) {
                clickSidebarRow(index, in: window)
                let title = SettingsWindowGeometry.categoryTitles[index]
                let actual = renderHash(content)
                if actual != hashes[index] {
                    let path = saveRender(content, named: "revisit-\(index)-\(title.replacingOccurrences(of: " ", with: "-"))")
                    print("         artifact: \(path ?? "unavailable")")
                }
                equal(actual, hashes[index], "clicking back to \(title) reproduces its earlier rendering")
            }
        }

        // MARK: B — the sidebar survives every pane

        suite("sidebar survives every pane") {
            // A fresh window per category, so a pane that traps the window is
            // attributed to itself rather than to whichever pane happens to run
            // after it in the loop.
            for (index, title) in SettingsWindowGeometry.categoryTitles.enumerated() {
                let paneFixtures = makeSettingsFixtures()
                defer { try? FileManager.default.removeItem(at: paneFixtures.directory) }
                let paneWindow = openSettingsWindow(settings: paneFixtures.settings, notes: paneFixtures.notes)
                defer { paneWindow.close() }
                guard let paneContent = paneWindow.contentView else {
                    check(false, "settings window has a content view on the \(title) pass")
                    continue
                }
                let generalHash = renderHash(paneContent)

                clickSidebarRow(index, in: paneWindow)

                // Scanline below the last row, where only the two backgrounds
                // and the divider between them are on screen.
                let probeY = SettingsWindowGeometry.rowCentreFromTop(SettingsWindowGeometry.categoryTitles.count) + 40
                if let width = measuredSidebarWidth(paneContent, yFromTop: probeY) {
                    let intact = abs(width - SettingsWindowGeometry.sidebarWidth) <= 2
                    if !intact {
                        let path = saveRender(paneContent, named: "sidebar-width-\(index)")
                        print("         measured sidebar width \(width)pt on the \(title) pane; artifact: \(path ?? "unavailable")")
                    }
                    check(intact, "sidebar is still \(Int(SettingsWindowGeometry.sidebarWidth))pt wide on the \(title) pane")
                } else {
                    check(false, "sidebar edge is measurable on the \(title) pane")
                }

                // The real user-facing consequence: can you get out of here.
                clickSidebarRow(0, in: paneWindow)
                let escaped = renderHash(paneContent) == generalHash
                if !escaped {
                    let path = saveRender(paneContent, named: "stuck-on-\(index)")
                    print("         could not return to General; artifact: \(path ?? "unavailable")")
                }
                check(escaped, "General is reachable again after visiting \(title)")
            }
        }

        // MARK: C — the window never resizes on a pane switch

        suite("window geometry is stable across pane switches") {
            // Fresh window, so this measures a window that has not already been
            // pushed around by the suites above.
            let geometryFixtures = makeSettingsFixtures()
            defer { try? FileManager.default.removeItem(at: geometryFixtures.directory) }
            let window = openSettingsWindow(settings: geometryFixtures.settings, notes: geometryFixtures.notes)
            defer { window.close() }
            guard let content = window.contentView else {
                check(false, "settings window has a content view")
                return
            }

            // Documents the ACTUAL size the window comes up at, which is not
            // the 680x480 content rect it is created with. NSHostingController
            // sizes the window from the SwiftUI content's ideal size, and
            // PreferencesView carries `.frame(minWidth: 620, minHeight: 420)`,
            // so the window resolves to that floor instead. Arguably intended,
            // unlike the sidebar failures above — captured here so a change
            // either way is visible rather than silent.
            let expectedFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: SettingsWindowGeometry.declaredContentFloor)).size
            equal(content.bounds.size, SettingsWindowGeometry.declaredContentFloor,
                  "content comes up at PreferencesView's declared floor, not the 680x480 contentRect it was created with")
            equal(window.frame.size, expectedFrame, "window frame matches that floor plus the titlebar")

            let baseline = window.frame
            for (index, title) in SettingsWindowGeometry.categoryTitles.enumerated() {
                clickSidebarRow(index, in: window)
                equal(window.frame, baseline, "window frame is unchanged after switching to \(title)")
                _ = index
            }
        }
    }
}
