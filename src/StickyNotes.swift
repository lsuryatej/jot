import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsManager.shared

    /// One model shared by every container. The panel and the popover are
    /// separate hosting views, so a per-view @StateObject would give each its
    /// own note list and let the two drift apart.
    private let notesManager = NotesManager()

    private let hotKey = HotKeyController()

    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    /// Guards against re-applying a mode that is already in effect. The
    /// @Published sink fires once on subscribe, which would otherwise tear the
    /// interface down and rebuild it immediately after launch.
    private var appliedMode: DisplayMode?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        notesManager.timerKeyword = settings.effectiveTimerKeyword

        NSApp.mainMenu = MainMenu.build(target: self, preferencesAction: #selector(showPreferences))

        panel = FloatingPanel(rootView: contentView())
        installStatusItem()

        hotKey.onFire = { [weak self] in self?.toggleVisibility() }
        hotKey.register(settings.hotKey)

        observeSettings()
        applyDisplayMode(settings.displayMode)

        // Deferred: setting the activation policy reorders windows
        // asynchronously, so showing in the same turn leaves the window behind
        // everything or not on screen at all.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // A menu bar dropdown opens when you ask for it, not on launch.
            guard !self.settings.displayMode.anchorsToStatusItem else { return }
            self.showInterface()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
        // Flushed here rather than through a notification a SwiftUI view has to
        // be alive to receive: the delegate owns the model, so this cannot be
        // missed because a window happened to be closed.
        notesManager.flushForTermination()
    }

    /// In Dock mode, clicking the Dock icon should bring the note back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showInterface()
        return true
    }

    private func contentView() -> ContentView {
        ContentView(notesManager: notesManager, settings: settings)
    }

    // MARK: - Settings

    private func observeSettings() {
        settings.$displayMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in self?.applyDisplayMode(mode) }
            .store(in: &cancellables)

        settings.$hotKey
            .receive(on: RunLoop.main)
            .sink { [weak self] combo in self?.hotKey.register(combo) }
            .store(in: &cancellables)

        // Release the shortcut while the recorder listens, or the currently
        // registered combo can never be pressed to re-record it.
        NotificationCenter.default.publisher(for: .stickyNotesBeginHotKeyRecording)
            .sink { [weak self] _ in self?.hotKey.unregister() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .stickyNotesEndHotKeyRecording)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hotKey.register(self.settings.hotKey)
            }
            .store(in: &cancellables)

        settings.$timerKeyword
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.notesManager.timerKeywordDidChange(to: self.settings.effectiveTimerKeyword)
            }
            .store(in: &cancellables)
    }

    // MARK: - Display modes

    private func applyDisplayMode(_ mode: DisplayMode) {
        guard appliedMode != mode else { return }

        let wasVisible = isInterfaceVisible
        hideInterface()
        appliedMode = mode

        let desiredPolicy: NSApplication.ActivationPolicy =
            mode.wantsRegularActivationPolicy ? .regular : .accessory
        let policyChanged = NSApp.activationPolicy() != desiredPolicy
        if policyChanged {
            NSApp.setActivationPolicy(desiredPolicy)
        }

        panel.apply(mode: mode)

        guard wasVisible else { return }

        if policyChanged {
            // AppKit reorders windows on the next turn after a policy change;
            // showing synchronously here loses the window.
            DispatchQueue.main.async { [weak self] in self?.showInterface() }
        } else {
            showInterface()
        }
    }

    // MARK: - Visibility

    private var isInterfaceVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggleVisibility() {
        isInterfaceVisible ? hideInterface() : showInterface()
    }

    private func showInterface() {
        if settings.displayMode.anchorsToStatusItem {
            anchorPanelToStatusItem()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.focusEditor()
    }

    /// Positions the note directly under the menu bar icon, clamped so it never
    /// hangs off the edge of the screen it is anchored to.
    private func anchorPanelToStatusItem() {
        guard let buttonWindow = statusItem?.button?.window else { return }

        // Status items are laid out asynchronously. Before that lands the frame
        // is empty, which would pin the note to the bottom-left corner.
        guard buttonWindow.frame.height > 0 else { return }

        // The status item's own window frame is already in screen coordinates.
        // Converting through the button gave a rect from the wrong space, which
        // put the note in the middle of the screen instead of under the icon.
        let buttonRect = buttonWindow.frame
        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        let size = panel.frame.size

        var x = buttonRect.midX - size.width / 2
        if let visible = screen?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: buttonRect.minY - size.height - 6))
    }

    private func hideInterface() {
        panel?.orderOut(nil)
    }

    // MARK: - Status item

    /// A menu bar icon, so the app is reachable when the hot key is unavailable.
    ///
    /// This is LSUIElement with no Dock icon outside Dock mode; without this, a
    /// hot key claimed by another app left the running process unreachable
    /// short of `pkill`.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "note.text",
            accessibilityDescription: "StickyNotes"
        )
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            toggleVisibility()
            return
        }

        // Left click toggles; right click opens the menu. Assigning
        // NSStatusItem.menu outright would make left click open the menu too,
        // costing the one-click toggle that is the point of the icon.
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showStatusMenu()
        } else {
            toggleVisibility()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: isInterfaceVisible ? "Hide StickyNotes" : "Show StickyNotes",
            action: #selector(toggleFromMenu),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit StickyNotes", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Detach immediately so the next left click toggles instead of
        // reopening this menu.
        statusItem?.menu = nil
    }

    @objc private func toggleFromMenu() {
        toggleVisibility()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Preferences

    @objc func showPreferences() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 470),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "StickyNotes Settings"
        window.contentViewController = NSHostingController(rootView: PreferencesView(settings: settings))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        preferencesWindow = window
    }
}

final class FloatingPanel: NSPanel {
    init(rootView: ContentView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        backgroundColor = .clear // handled in SwiftUI
        hasShadow = true
        isOpaque = false
        center()

        contentView = NSHostingView(rootView: rootView)
    }

    /// Window level, Spaces behaviour, and focus-stealing all differ per mode.
    func apply(mode: DisplayMode) {
        hidesOnDeactivate = mode.hidesOnDeactivate

        if mode.wantsFloatingLevel {
            level = .floating
            isFloatingPanel = true
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Dropdown mode needs to take focus so you can type into it, and to
            // dismiss itself the moment focus moves elsewhere. Floating mode
            // stays out of the way of whatever you are typing in.
            if mode.hidesOnDeactivate {
                styleMask.remove(.nonactivatingPanel)
            } else {
                styleMask.insert(.nonactivatingPanel)
            }
        } else {
            level = .normal
            isFloatingPanel = false
            collectionBehavior = [.fullScreenPrimary]
            // Dock and Menu Bar modes are ordinary windows; a non-activating
            // panel there would refuse to take focus when clicked.
            styleMask.remove(.nonactivatingPanel)
        }
    }

    /// A scratchpad you have to click before typing in is a scratchpad that
    /// costs you the thought you opened it to capture.
    func focusEditor() {
        guard let contentView, let textView = Self.firstTextView(in: contentView) else { return }
        makeFirstResponder(textView)
    }

    static func firstTextView(in view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView { return textView }
        for subview in view.subviews {
            if let found = firstTextView(in: subview) { return found }
        }
        return nil
    }

    // Closing must only hide. Outside Dock mode there is no Dock icon, so a real
    // close would leave the app running and reachable only by hot key.
    override func close() {
        orderOut(nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
