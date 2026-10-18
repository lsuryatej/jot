import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    /// The glow: the icon alternates between outline and filled, tinted.
    /// Short at a distance (a notification already made a sound); long when
    /// you're together, where the glow *is* the signal.
    private var glowTimer: Timer?
    private var glowUntil: Date?
    private var glowOn = false
    /// A brief check mark after you send, so a hotkey press isn't silent.
    private var sentUntil: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.imagePosition = .imageLeading

        popover.contentViewController = makeMenu()
        popover.behavior = .transient
        popover.delegate = self

        model.onSignal = { [weak self] in self?.glow() }
        model.onSent = { [weak self] in self?.flashSent() }
        model.onOpenMenu = { [weak self] in self?.showPopover() }
        // objectWillChange fires before the change lands; hopping to the next
        // run loop pass reads the new state.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshStatusItem() }
            }
            .store(in: &cancellables)

        // The countdown and busy icon change with the clock, not just with
        // the model.
        _ = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStatusItem() }
        }

        model.start()
        refreshStatusItem()

        if model.pair == nil {
            // First launch: open the menu so setup is the first thing seen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.showPopover() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    /// `ember://pair?code=…` links from the other person.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "ember" }) else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Pair with this link?"
        alert.informativeText = model.pair == nil
            ? "Ember will connect to the person who sent it. Your name is what they'll see."
            : "This replaces your current pair with \(model.engine.partnerName)."
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        nameField.placeholderString = "Your name"
        nameField.stringValue = model.state.settings.myName
        alert.accessoryView = nameField
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty && name != model.state.settings.myName {
            var settings = model.state.settings
            settings.myName = name
            model.updateSettings(settings)
        }

        if model.join(code: url.absoluteString) {
            showPopover()
        } else {
            let failure = NSAlert()
            failure.messageText = "That link didn't work"
            failure.informativeText = "Ask them to copy it again from Ember's menu."
            failure.runModal()
        }
    }

    // MARK: - Popover

    private func makeMenu() -> NSViewController {
        let hosting = NSHostingController(rootView: MenuView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    /// A fresh view each time, so the menu always reopens on the home page
    /// rather than wherever it was left (half-edited settings included).
    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = makeMenu()
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        stopGlow()
        model.refreshNotificationPermission()
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - Status item

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let now = Date()
        let engine = model.engine

        let symbol: String
        if let sentUntil, sentUntil > now {
            symbol = "checkmark.circle.fill"
        } else if engine.busyUntil(at: now) != nil {
            symbol = "moon.zzz"
        } else if glowOn || engine.openPing(at: now) != nil {
            symbol = "flame.fill"
        } else {
            symbol = "flame"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ember")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = glowOn ? .systemOrange : nil

        switch engine.phase(at: now) {
        case .upcoming(let days): button.title = days == 1 ? " tmrw" : " \(days)d"
        case .together: button.title = " 🫶"
        case .comedown: button.title = " 💛"
        case .none: button.title = ""
        }
    }

    private func glow() {
        let together = model.engine.phase(at: Date()).isTogether
        let until = Date().addingTimeInterval(together ? 10 * 60 : 20)
        glowUntil = max(glowUntil ?? until, until)
        guard glowTimer == nil else { return }
        glowTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.glowStep() }
        }
    }

    private func glowStep() {
        guard let glowUntil, glowUntil > Date() else {
            stopGlow()
            return
        }
        glowOn.toggle()
        refreshStatusItem()
    }

    private func stopGlow() {
        glowTimer?.invalidate()
        glowTimer = nil
        glowUntil = nil
        glowOn = false
        refreshStatusItem()
    }

    private func flashSent() {
        sentUntil = Date().addingTimeInterval(1.5)
        refreshStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            MainActor.assumeIsolated { self?.refreshStatusItem() }
        }
    }
}
