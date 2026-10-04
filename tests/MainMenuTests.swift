import AppKit

// The menu bar's shape, checked against the HIG's anatomy: which menus exist,
// in what order, what each standard item is wired to, and the state-dependent
// titles. Built from `MainMenu.build` itself, so this is the shipped menu.

final class MainMenuTestTarget: NSObject {
    @objc func noop() {}
    /// Menu items hold their target weakly; this keeps it alive.
    static let shared = MainMenuTestTarget()
}

/// One shared construction, so a new parameter on `MainMenu.build` is one
/// edit here rather than one per suite that needs a menu.
func makeTestMainMenu() -> NSMenu {
    MainMenu.build(
        target: MainMenuTestTarget.shared,
        preferencesAction: #selector(MainMenuTestTarget.noop),
        checkForUpdatesAction: #selector(MainMenuTestTarget.noop),
        newNoteAction: #selector(MainMenuTestTarget.noop),
        globalSearchAction: #selector(MainMenuTestTarget.noop),
        moveNoteUpAction: #selector(MainMenuTestTarget.noop),
        moveNoteDownAction: #selector(MainMenuTestTarget.noop),
        nextNoteAction: #selector(MainMenuTestTarget.noop),
        previousNoteAction: #selector(MainMenuTestTarget.noop),
        toggleChromeAction: #selector(MainMenuTestTarget.noop),
        toggleChecklistAction: #selector(MainMenuTestTarget.noop),
        toggleHighlightAction: #selector(MainMenuTestTarget.noop),
        showHelpAction: #selector(MainMenuTestTarget.noop)
    )
}

func submenu(_ title: String, of menu: NSMenu) -> NSMenu? {
    menu.items.first { $0.submenu?.title == title }?.submenu
}

func menuItem(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
    menu?.items.first { $0.title == title }
}

func runMainMenuTests() {

    suite("the menu bar has the HIG's menus in the HIG's order") {
        let menu = makeTestMainMenu()
        equal(menu.items.compactMap { $0.submenu?.title },
              ["Jot", "File", "Edit", "Format", "View", "Window", "Help"],
              "app, File, Edit, Format, View, Window, Help")
    }

    suite("the app menu carries Services, Hide Others, Show All and updates") {
        let app = submenu("Jot", of: makeTestMainMenu())
        let titles = app?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        equal(titles, [
            "About Jot", "-",
            "Settings…", "Check for Updates…", "Sync to Apple Notes", "-",
            "Services", "-",
            "Hide Jot", "Hide Others", "Show All", "-",
            "Quit Jot",
        ], "standard order, About alone in its group")
        check(menuItem("Services", in: app)?.submenu != nil, "Services is a submenu for the system to fill")
        let hideOthers = menuItem("Hide Others", in: app)
        equal(hideOthers?.keyEquivalent, "h", "Hide Others is Option-Cmd-H")
        equal(hideOthers?.keyEquivalentModifierMask, [.command, .option], "with Option")
        check(hideOthers?.action == #selector(NSApplication.hideOtherApplications(_:)), "Hide Others reaches NSApp")
        check(menuItem("Show All", in: app)?.action == #selector(NSApplication.unhideAllApplications(_:)),
              "Show All reaches NSApp")
        check(menuItem("Check for Updates…", in: app)?.target != nil,
              "Check for Updates has an explicit target, like the status item's row")
    }

    suite("the Window menu has Minimize, Zoom and Bring All to Front") {
        let window = submenu("Window", of: makeTestMainMenu())
        let titles = window?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        equal(titles, ["Minimize", "Zoom", "-", "Bring All to Front"], "standard items, standard order")
        let minimize = menuItem("Minimize", in: window)
        equal(minimize?.keyEquivalent, "m", "Minimize is Cmd-M")
        check(minimize?.action == #selector(NSWindow.performMiniaturize(_:)), "Minimize reaches the key window")
        check(minimize?.target == nil, "through the responder chain")
        check(menuItem("Zoom", in: window)?.action == #selector(NSWindow.performZoom(_:)), "Zoom reaches the key window")
        check(menuItem("Bring All to Front", in: window)?.action == #selector(NSApplication.arrangeInFront(_:)),
              "Bring All to Front reaches NSApp")
    }

    suite("the View menu offers full screen") {
        let view = submenu("View", of: makeTestMainMenu())
        let fullScreen = menuItem("Enter Full Screen", in: view)
        check(fullScreen?.action == #selector(NSWindow.toggleFullScreen(_:)), "toggleFullScreen, so AppKit retitles it")
        check(fullScreen?.target == nil, "sent to the key window")
        equal(fullScreen?.keyEquivalent, "f", "Ctrl-Cmd-F")
        equal(fullScreen?.keyEquivalentModifierMask, [.command, .control], "with Control")
    }

    suite("the Help menu opens the manual") {
        let help = submenu("Help", of: makeTestMainMenu())
        let item = menuItem("Jot Help", in: help)
        check(item != nil, "Jot Help is there")
        equal(item?.keyEquivalent, "?", "Cmd-? like every Mac app")
        equal(UpdateChecker.helpPage.absoluteString, "https://github.com/lsuryatej/jot#readme", "the README on GitHub")
    }

    suite("the system menus are registered with NSApp") {
        let menu = makeTestMainMenu()
        let app = NSApplication.shared
        MainMenu.registerSystemMenus(of: menu, with: app)
        check(app.windowsMenu === submenu("Window", of: menu), "windowsMenu is the Window menu")
        check(app.helpMenu === submenu("Help", of: menu), "helpMenu is the Help menu")
        check(app.servicesMenu === menuItem("Services", in: submenu("Jot", of: menu))?.submenu,
              "servicesMenu is the app menu's Services submenu")
    }

    suite("Show/Hide Header & Footer says what choosing it will do") {
        equal(MainMenu.chromeToggleTitle(showsHeader: true, showsFooter: true), "Hide Header & Footer", "both showing")
        equal(MainMenu.chromeToggleTitle(showsHeader: false, showsFooter: false), "Show Header & Footer", "both hidden")
        equal(MainMenu.chromeToggleTitle(showsHeader: true, showsFooter: false), "Hide Header & Footer",
              "mixed counts as showing, matching what the toggle does")
        equal(MainMenu.chromeToggleTitle(showsHeader: false, showsFooter: true), "Hide Header & Footer", "either way round")
        let view = submenu("View", of: makeTestMainMenu())
        check(view?.items.contains { $0.title.hasPrefix("Toggle") } == false, "no item says Toggle")
    }

    suite("the update item follows the checker's state") {
        equal(MainMenu.updateItemState(isUpdating: false, availableVersion: nil),
              .init(title: "Check for Updates…", isEnabled: true, action: .check), "nothing known: check")
        equal(MainMenu.updateItemState(isUpdating: false, availableVersion: "1.6.0"),
              .init(title: "Update Available (v1.6.0)…", isEnabled: true, action: .install), "found: install")
        equal(MainMenu.updateItemState(isUpdating: true, availableVersion: "1.6.0").isEnabled, false,
              "disabled while an update runs, so a second can't start")
    }

    suite("window commands apply only where the mode has a real window") {
        for mode in DisplayMode.allCases {
            equal(mode.allowsFullScreen, mode == .dock || mode == .menuBar, "\(mode.title): full screen")
            equal(mode.allowsZoom, mode != .edge && mode != .dropdown, "\(mode.title): zoom")
            equal(mode.allowsMinimize, mode == .dock, "\(mode.title): minimize")
        }
    }

    suite("no two items in the menu bar share a key equivalent") {
        var seen: [String: String] = [:]
        var clashes: [String] = []
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { walk(sub) }
                guard !item.keyEquivalent.isEmpty else { continue }
                let key = "\(item.keyEquivalentModifierMask.rawValue)-\(item.keyEquivalent)"
                if let other = seen[key] { clashes.append("\(other) / \(item.title)") }
                seen[key] = item.title
            }
        }
        walk(makeTestMainMenu())
        equal(clashes, [], "every chord is unique")
    }
}
