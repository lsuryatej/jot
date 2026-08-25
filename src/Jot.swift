import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let settings = SettingsManager.shared

    /// One model shared by every container. The panel and the popover are
    /// separate hosting views, so a per-view @StateObject would give each its
    /// own note list and let the two drift apart.
    private let notesManager = NotesManager()

    private let hotKey = HotKeyController()
    private let appleNotes = AppleNotesSync()
    /// Sync is coalesced: AppleScript round trips take tens of milliseconds
    /// each, so following every debounced save would be far too chatty.
    private var pendingSync: DispatchWorkItem?

    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var settingsCloseMonitor: Any?
    private var edgeTrigger: EdgeTriggerWindow?
    private var edgeAutoHideTimer: Timer?
    /// Guards against re-applying a mode that is already in effect. The
    /// @Published sink fires once on subscribe, which would otherwise tear the
    /// interface down and rebuild it immediately after launch.
    private var appliedMode: DisplayMode?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        CurrencyRates.bootstrap(fetchesLive: settings.fetchesLiveCurrencyRates)
        UpdateChecker.check(enabled: settings.checksForUpdates)
        notesManager.timerKeyword = settings.effectiveTimerKeyword
        notesManager.pomodoroKeyword = settings.effectivePomodoroKeyword
        notesManager.onPersist = { [weak self] notes in
            self?.scheduleAppleNotesSync(notes)
        }

        NSApp.mainMenu = MainMenu.build(
            target: self,
            preferencesAction: #selector(showPreferences),
            newNoteAction: #selector(newNoteFromMenu),
            globalSearchAction: #selector(requestGlobalSearch),
            moveNoteUpAction: #selector(moveNoteUp(_:)),
            moveNoteDownAction: #selector(moveNoteDown(_:)),
            nextNoteAction: #selector(nextNote(_:)),
            previousNoteAction: #selector(previousNote(_:)),
            toggleChromeAction: #selector(toggleChromeFromMenu),
            toggleChecklistAction: #selector(toggleChecklistFromMenu),
            toggleHighlightAction: #selector(toggleHighlightFromMenu)
        )

        panel = FloatingPanel(rootView: contentView())
        panel.delegate = self
        if let saved = settings.windowedFrame {
            panel.setFrame(saved, display: false)
        }
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
            // Reveal-on-demand modes open when you ask for them, not on launch.
            let mode = self.settings.displayMode
            guard !mode.anchorsToStatusItem, !mode.isEdgeDocked else { return }
            self.showInterface()
        }
    }

    func windowDidResize(_ notification: Notification) {
        rememberWindowedFrame()
    }

    func windowDidMove(_ notification: Notification) {
        rememberWindowedFrame()
    }

    private func rememberWindowedFrame() {
        // Only windowed modes have a size worth keeping; the docked frame is
        // derived from the screen.
        guard !settings.displayMode.isEdgeDocked, panel?.isVisible == true else { return }
        settings.windowedFrame = panel.frame
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
        // Flushed here rather than through a notification a SwiftUI view has to
        // be alive to receive: the delegate owns the model, so this cannot be
        // missed because a window happened to be closed.
        notesManager.flushForTermination()
    }

    /// In Dock mode, clicking the Dock icon should bring the note back.
    func applicationDidBecomeActive(_ notification: Notification) {
        // A copy left running across midnight should not be stuck on
        // yesterday's exchange rates until the next relaunch.
        CurrencyRates.refreshIfNeeded(fetchesLive: settings.fetchesLiveCurrencyRates)
        UpdateChecker.check(enabled: settings.checksForUpdates)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showInterface()
        return true
    }

    private func contentView() -> ContentView {
        ContentView(notesManager: notesManager, settings: settings)
    }

    // MARK: - Apple Notes

    private func scheduleAppleNotesSync(_ notes: [Note]) {
        guard settings.syncsToAppleNotes else { return }
        pendingSync?.cancel()
        let work = DispatchWorkItem {
            Task { await self.appleNotes.sync(notes) }
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    @objc func syncToAppleNotesNow(_ sender: Any?) {
        let notes = notesManager.notes
        Task {
            let result = await appleNotes.sync(notes)
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = result.failed == 0
                    ? "Synced to Apple Notes"
                    : "Synced with problems"
                alert.informativeText = "\(result.created) created, \(result.updated) updated"
                    + (result.failed > 0 ? ", \(result.failed) failed. Check that Jot is allowed to control Notes in System Settings › Privacy & Security › Automation." : ".")
                alert.runModal()
            }
        }
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
        NotificationCenter.default.publisher(for: .jotBeginHotKeyRecording)
            .sink { [weak self] _ in self?.hotKey.unregister() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .jotEndHotKeyRecording)
            .sink { [weak self] _ in
                guard let self else { return }
                self.hotKey.register(self.settings.hotKey)
            }
            .store(in: &cancellables)

        settings.$screenEdge
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.settings.displayMode.isEdgeDocked else { return }
                self.installEdgeTrigger()
            }
            .store(in: &cancellables)

        settings.$fetchesLiveCurrencyRates
            .receive(on: RunLoop.main)
            .sink { fetchesLive in
                // Turning it on should fetch right away, not wait for
                // tomorrow's scheduled check.
                CurrencyRates.refreshIfNeeded(fetchesLive: fetchesLive)
            }
            .store(in: &cancellables)

        settings.$timerKeyword
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.notesManager.timerKeywordDidChange(to: self.settings.effectiveTimerKeyword)
            }
            .store(in: &cancellables)

        settings.$pomodoroKeyword
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.notesManager.pomodoroKeywordDidChange(to: self.settings.effectivePomodoroKeyword)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .jotRequestNewNote)
            .sink { [weak self] _ in self?.newNoteFromMenu() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .jotRequestMoveNoteUp)
            .sink { [weak self] _ in self?.moveCurrentNoteIfVisible(by: -1) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .jotRequestMoveNoteDown)
            .sink { [weak self] _ in self?.moveCurrentNoteIfVisible(by: +1) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .jotRequestNextNote)
            .sink { [weak self] _ in self?.switchNoteIfVisible(by: +1) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .jotRequestPreviousNote)
            .sink { [weak self] _ in self?.switchNoteIfVisible(by: -1) }
            .store(in: &cancellables)

        // Theme notes: the appearance is derived from the note stack itself,
        // so every edit re-derives it. Debounced because each keystroke in a
        // theme note republishes the notes array; applying at typing speed
        // re-resolves fonts and colours mid-word for no visible benefit.
        notesManager.$notes
            .map { ThemeNote.active(in: $0) }
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .receive(on: RunLoop.main)
            .sink { [weak self] theme in self?.settings.themeOverride = theme }
            .store(in: &cancellables)
    }

    // MARK: - Reordering

    @objc func moveNoteUp(_ sender: Any?) {
        moveCurrentNoteIfVisible(by: -1)
    }

    @objc func moveNoteDown(_ sender: Any?) {
        moveCurrentNoteIfVisible(by: +1)
    }

    /// A move aimed at a note nobody can see would read as the shortcut doing
    /// nothing at best, and as cards shuffling in the dark at worst.
    private func moveCurrentNoteIfVisible(by delta: Int) {
        guard isInterfaceVisible else { return }
        notesManager.moveCurrentNote(by: delta)
    }

    // MARK: - Switching

    @objc func nextNote(_ sender: Any?) {
        switchNoteIfVisible(by: +1)
    }

    @objc func previousNote(_ sender: Any?) {
        switchNoteIfVisible(by: -1)
    }

    /// Same visibility guard as `moveCurrentNoteIfVisible`, and the same
    /// bounds `NotesManager.nextNote`/`previousNote` already enforce — this
    /// just picks which one to call.
    private func switchNoteIfVisible(by delta: Int) {
        guard isInterfaceVisible else { return }
        delta > 0 ? notesManager.nextNote() : notesManager.previousNote()
    }

    /// The View menu's item posts the same notification Cmd+/ does in the
    /// text view; ContentView owns `showsHeader`/`showsFooter` and is the
    /// only thing observing it.
    @objc private func toggleChromeFromMenu() {
        NotificationCenter.default.post(name: .jotRequestToggleChrome, object: nil)
    }

    /// The Format menu's items post the same notifications the header's
    /// Checklist/Highlight buttons do; the text view observes and applies
    /// them to itself directly.
    @objc private func toggleChecklistFromMenu() {
        NotificationCenter.default.post(name: .jotRequestToggleChecklistFromHeader, object: nil)
    }

    @objc private func toggleHighlightFromMenu() {
        NotificationCenter.default.post(name: .jotRequestToggleHighlightFromHeader, object: nil)
    }

    /// Greys out the move items at the ends of the list, or whenever the panel
    /// is hidden, instead of letting them click into nothing. Every other item
    /// targeted here was always enabled and stays that way.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(moveNoteUp(_:)):
            return isInterfaceVisible && notesManager.currentIndex > 0
        case #selector(moveNoteDown(_:)):
            return isInterfaceVisible && notesManager.currentIndex < notesManager.notes.count - 1
        case #selector(previousNote(_:)):
            return isInterfaceVisible && notesManager.currentIndex > 0
        case #selector(nextNote(_:)):
            return isInterfaceVisible && notesManager.currentIndex < notesManager.notes.count - 1
        default:
            return true
        }
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

        if mode.isEdgeDocked {
            installEdgeTrigger()
        } else {
            edgeTrigger?.orderOut(nil)
            edgeTrigger = nil
            restoreWindowedFrame()
        }

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
        if settings.displayMode.isEdgeDocked {
            // Reached here from the hot key or the menu bar, both deliberate.
            revealFromEdge(activating: true)
            return
        }
        if settings.displayMode.anchorsToStatusItem {
            anchorPanelToStatusItem()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.focusEditor()
    }

    // MARK: - Screen edge

    private func installEdgeTrigger() {
        if edgeTrigger == nil {
            edgeTrigger = EdgeTriggerWindow { [weak self] activating in
                guard let self else { return }
                if self.panel.isVisible {
                    // Already out: a click on the bar should still hand it focus.
                    if activating { self.focusPanel() }
                    return
                }
                self.revealFromEdge(activating: activating)
            }
        }
        edgeTrigger?.position(on: settings.screenEdge, screen: NSScreen.main)
        // orderFrontRegardless: the strip has to appear without activating the
        // app, or pushing the cursor at the edge would steal focus from
        // whatever the user is actually working in.
        edgeTrigger?.orderFrontRegardless()
    }

    /// Docks the note full-height against the chosen edge and slides it in.
    ///
    /// `activating` is false when the hot side triggered this. Revealing on
    /// hover must never take the keyboard: the pointer reaching a screen edge
    /// is usually incidental, and stealing focus there sends the user's next
    /// keystrokes into this note instead of the app they were working in.
    private func revealFromEdge(activating: Bool) {
        guard let visible = (NSScreen.main?.visibleFrame) else { return }

        let width = CGFloat(settings.edgeWidth)
        let onScreenX = settings.screenEdge == .right ? visible.maxX - width : visible.minX
        let offScreenX = settings.screenEdge == .right ? visible.maxX : visible.minX - width
        let docked = NSRect(x: onScreenX, y: visible.minY, width: width, height: visible.height)

        panel.setFrame(
            NSRect(x: offScreenX, y: visible.minY, width: width, height: visible.height),
            display: false
        )
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(docked, display: true)
        } completionHandler: { [weak self] in
            // NSAnimationContext's completion handler always fires on the
            // main thread, but its type is not statically @MainActor.
            MainActor.assumeIsolated {
                guard let self else { return }
                if activating { self.focusPanel() }
                self.startEdgeAutoHide()
            }
        }
    }

    /// Puts the note back to the size it had before it was docked.
    ///
    /// Docking rewrites the frame to the full height of the screen. Without
    /// this, switching away from edge mode — or just pressing the shortcut
    /// afterwards — left a full-height window.
    private func restoreWindowedFrame() {
        let target = settings.windowedFrame ?? NSRect(x: 0, y: 0, width: 400, height: 420)
        guard panel.frame.size != target.size || panel.frame.origin != target.origin else { return }
        panel.setFrame(target, display: false)
        if settings.windowedFrame == nil {
            panel.center()
        }
    }

    private func focusPanel() {
        panel.makeKeyAndOrderFront(nil)
        panel.focusEditor()
    }

    /// Hides the edge note once the pointer leaves it.
    ///
    /// Polled rather than driven by tracking areas: the content is an
    /// NSHostingView, and threading a tracking area through SwiftUI to get one
    /// mouseExited is more machinery than five checks a second.
    private func startEdgeAutoHide() {
        edgeAutoHideTimer?.invalidate()
        // Timer's closure type is not statically known to run on the main
        // actor even though `scheduledTimer` always fires on the run loop
        // that scheduled it — main, here. `assumeIsolated` states that fact
        // to the compiler rather than hopping queues for no reason.
        edgeAutoHideTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.settings.displayMode.isEdgeDocked else { return }
                guard self.panel.isVisible else {
                    self.stopEdgeAutoHide()
                    return
                }
                // While it holds the keyboard the user is typing in it, so leave it.
                guard !self.panel.isKeyWindow else { return }

                let pointer = NSEvent.mouseLocation
                let generous = self.panel.frame.insetBy(dx: -12, dy: -12)
                guard !generous.contains(pointer) else { return }

                self.stopEdgeAutoHide()
                self.hideInterface()
            }
        }
    }

    private func stopEdgeAutoHide() {
        edgeAutoHideTimer?.invalidate()
        edgeAutoHideTimer = nil
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
        stopEdgeAutoHide()
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
            accessibilityDescription: "Jot"
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
            title: isInterfaceVisible ? "Hide Jot" : "Show Jot",
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

        if let version = UpdateChecker.shared.availableVersion {
            let update = NSMenuItem(
                title: "Update Available (v\(version))…",
                action: #selector(performUpdate),
                keyEquivalent: ""
            )
            update.target = self
            menu.addItem(update)
        } else {
            let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesNow), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Jot", action: #selector(quit), keyEquivalent: "q")
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

    @objc private func performUpdate() {
        UpdateChecker.shared.performUpdate()
    }

    @objc private func checkForUpdatesNow() {
        Task {
            await UpdateChecker.shared.forceCheck()
            if UpdateChecker.shared.availableVersion == nil {
                let alert = NSAlert()
                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                alert.messageText = "You're up to date"
                alert.informativeText = "Jot \(version) is the latest version."
                alert.runModal()
            }
        }
    }

    // MARK: - Preferences

    /// Cmd+N. Unconditional, like the edge sidebar's own + button: always
    /// appends a fresh note and switches to it, regardless of whether the
    /// current note is blank.
    @objc private func newNoteFromMenu() {
        notesManager.appendNote()
        if isInterfaceVisible {
            if !settings.displayMode.isEdgeDocked { panel.focusEditor() }
        } else {
            showInterface()
        }
    }

    /// Cmd+Shift+F, from the menu. The text view handles the same shortcut
    /// directly too (see PlainTextEditor.performKeyEquivalent), since the
    /// menu isn't reliably consulted for key equivalents outside Dock mode.
    /// Both paths post the same notification; ContentView owns the overlay.
    @objc private func requestGlobalSearch() {
        if !isInterfaceVisible {
            showInterface()
        }
        NotificationCenter.default.post(name: .jotRequestGlobalSearch, object: nil)
    }

    @objc func showPreferences() {
        if let window = preferencesWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Jot Settings"
        // Wide enough for the sidebar plus a comfortable content column; each
        // pane scrolls internally rather than the window needing to grow to
        // fit the tallest one.
        window.minSize = NSSize(width: 560, height: 380)
        window.contentViewController = NSHostingController(rootView: PreferencesView(settings: settings, notesManager: notesManager))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Belt and suspenders: the app menu's Close item (Cmd+W) should reach
        // this window through the normal responder chain since opening
        // Settings genuinely activates the app, unlike the main panel's
        // .nonactivatingPanel. A local monitor guarantees it regardless —
        // cheap, and matches the direct-handling pattern Cmd+L and
        // Shift-Cmd-V needed for the same class of menu-routing doubt.
        settingsCloseMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard window?.isKeyWindow == true,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w"
            else { return event }
            window?.performClose(nil)
            return nil
        }

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

        // A panel docked flush against the screen edge has nothing to close,
        // minimise, or zoom, and the traffic lights read as a stray window.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = mode.isEdgeDocked
        }
        // Borderless while docked: the sidebar is a surface, not a window.
        if mode.isEdgeDocked {
            titlebarAppearsTransparent = true
        }

        if mode.wantsFloatingLevel {
            level = .floating
            isFloatingPanel = true
            collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            // Dropdown mode needs to take focus so you can type into it, and to
            // dismiss itself the moment focus moves elsewhere. Floating mode
            // stays out of the way of whatever you are typing in.
            if mode.isEdgeDocked || !mode.hidesOnDeactivate {
                styleMask.insert(.nonactivatingPanel)
            } else {
                styleMask.remove(.nonactivatingPanel)
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
