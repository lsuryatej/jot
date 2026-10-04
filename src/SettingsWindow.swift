import AppKit
import SwiftUI
import Carbon.HIToolbox

// The Settings window, built the way a standard macOS settings window is
// (HIG, Settings › macOS): a noncustomizable toolbar of panes, the window
// titled after the visible pane, the last pane restored on the next open,
// minimize and zoom dimmed, and a fixed width with the height following the
// pane.
//
// The sizing is the part with history. Each pane is SwiftUI in its own
// `NSHostingController` with `sizingOptions = [.preferredContentSize]`, which
// makes SwiftUI report the pane's ideal size, and for a grouped `Form` that
// is exactly the height of its rows. But the hosting controller reports it as
// a layout constraint on its view at priority 501, one above the window's
// "stay put" priority, so left alone AppKit snaps the window to each new
// height with no animation. `SettingsTabViewController` therefore pins its
// own view's size at 999, which outranks that constraint, reads the ideal
// height itself, and animates the pin. The window follows the pin through
// Auto Layout with its top edge fixed.

// MARK: - Remembered pane

extension SettingsCategory {
    static let lastPaneDefaultsKey = "settingsLastPane"

    /// The pane the window last showed, or General on a first open or when
    /// the stored value names a pane that no longer exists.
    static func lastViewed(in defaults: UserDefaults) -> SettingsCategory {
        defaults.string(forKey: lastPaneDefaultsKey).flatMap(SettingsCategory.init(rawValue:)) ?? .general
    }

    func remember(in defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.lastPaneDefaultsKey)
    }
}

// MARK: - Geometry

enum SettingsWindowLayout {
    /// Every pane's width. Fixed, so switching panes only ever changes the
    /// height and the toolbar never shifts sideways.
    static let paneWidth: CGFloat = 540

    /// Above this, a pane scrolls inside its Form rather than the window
    /// growing further. Only Shortcuts (about 1280pt) reaches it; Notes &
    /// Timers, the next tallest at about 660pt, fits whole.
    static let maxPaneHeight: CGFloat = 680

    /// A floor so a very short pane still reads as a window, not a strip.
    static let minPaneHeight: CGFloat = 160

    /// Matches the pace of AppKit's own window resizes.
    static let resizeDuration: TimeInterval = 0.2

    /// Room left above and below the window when a pane is taller than the
    /// screen can show.
    static let screenMargin: CGFloat = 40

    /// The content height for a pane whose SwiftUI ideal height is
    /// `idealHeight`. Rounded up to a whole point, since a fractional height
    /// would put the bottom edge on a half pixel and could clip the last row
    /// by a hair. `screenLimit` is the most the current screen can show.
    static func contentHeight(forIdealHeight idealHeight: CGFloat, screenLimit: CGFloat? = nil) -> CGFloat {
        var height = idealHeight.rounded(.up)
        height = min(height, maxPaneHeight)
        if let screenLimit { height = min(height, screenLimit.rounded(.down)) }
        return max(height, minPaneHeight)
    }
}

// MARK: - Window

/// The Settings window itself. Its only job beyond `NSWindow` is closing on
/// the two keys people expect a settings window to close on.
final class SettingsWindow: NSWindow {
    /// The modifiers that make a chord distinct. Caps Lock, the numeric pad
    /// and the function key are left out, so Caps Lock never stops ⌘W.
    private static let chordModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Whether a key-down is ⌘W. Plain ⌘ only: ⌥⌘W conventionally means
    /// "close all" and ⇧⌘W "close window group", neither of which applies.
    static func isCloseChord(characters: String?, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        modifierFlags.intersection(chordModifiers) == .command
            && characters?.lowercased() == "w"
    }

    static func isEscape(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        keyCode == UInt16(kVK_Escape) && modifierFlags.intersection(chordModifiers).isEmpty
    }

    /// ⌘W, handled on the window rather than left to the main menu: outside
    /// Dock mode Jot is an accessory app and the menu is not reliably
    /// consulted, which is why this used to be a local event monitor (one
    /// that was never removed). The key window is asked first either way.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           Self.isCloseChord(characters: event.charactersIgnoringModifiers,
                             modifierFlags: event.modifierFlags) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Escape (and ⌘.) reach here once nothing in the pane wanted them. The
    /// hot-key recorder takes Escape earlier, in its own event monitor, to
    /// abandon a recording; a text field being edited takes it too, as
    /// AppKit's field editor answers `cancelOperation:` itself. Everywhere
    /// else it closes the window, the way it closes a sheet.
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    /// Backstop for an Escape that arrives as a plain key-down rather than as
    /// `cancelOperation:`.
    override func keyDown(with event: NSEvent) {
        if Self.isEscape(keyCode: event.keyCode, modifierFlags: event.modifierFlags) {
            cancelOperation(nil)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Pane hosting

/// One pane's hosting controller. Exists only to say when SwiftUI's ideal
/// size may have changed, which happens without a pane switch: choosing an
/// edge display mode adds the Edge and Width rows to General, a theme note
/// adds a line to Appearance.
///
/// SwiftUI updates the size constraint it keeps on this controller's view
/// when the ideal size changes, which runs `updateViewConstraints()`.
/// Reading `preferredContentSize` from inside that pass dirties layout and
/// AppKit throws, so the read is deferred to the next turn of the run loop.
final class SettingsPaneHostingController: NSHostingController<AnyView> {
    let category: SettingsCategory
    var idealSizeMayHaveChanged: (() -> Void)?
    private var notifyScheduled = false

    init(category: SettingsCategory, settings: SettingsManager, notesManager: NotesManager) {
        self.category = category
        super.init(rootView: AnyView(
            SettingsPaneView(category: category, settings: settings, notesManager: notesManager)
                .frame(width: SettingsWindowLayout.paneWidth)
        ))
        sizingOptions = [.preferredContentSize]
        title = category.title
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func updateViewConstraints() {
        super.updateViewConstraints()
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.idealSizeMayHaveChanged?()
        }
    }
}

// MARK: - Tabs

final class SettingsTabViewController: NSTabViewController {
    private let defaults: UserDefaults
    private let initialPane: SettingsCategory
    private var heightPin: NSLayoutConstraint?
    private var widthPin: NSLayoutConstraint?
    /// Off until the window is fully set up. NSTabViewController reports a
    /// selection of the first tab while it loads, which would otherwise
    /// overwrite the remembered pane with General before it is restored.
    private var remembersSelection = false

    /// Called after every pane switch, with the pane now showing.
    var paneDidChange: ((SettingsCategory) -> Void)?

    init(settings: SettingsManager, notesManager: NotesManager,
         defaults: UserDefaults, initialPane: SettingsCategory) {
        self.defaults = defaults
        self.initialPane = initialPane
        super.init(nibName: nil, bundle: nil)

        tabStyle = .toolbar
        // No crossfade: the incoming pane is drawn at once, top-aligned, and
        // the window then eases to its height. A crossfade on top of the
        // resize shows two panes at once mid-move.
        transitionOptions = [.allowUserInteraction]
        canPropagateSelectedChildViewControllerTitle = true

        for category in SettingsCategory.allCases {
            let pane = SettingsPaneHostingController(
                category: category, settings: settings, notesManager: notesManager
            )
            pane.idealSizeMayHaveChanged = { [weak self, weak pane] in
                guard let self, let pane, pane === self.selectedPane else { return }
                self.fitToSelectedPane(animated: true)
            }
            let item = NSTabViewItem(viewController: pane)
            item.identifier = category.rawValue
            item.label = category.title
            item.image = NSImage(systemSymbolName: category.icon, accessibilityDescription: category.title)
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let width = view.widthAnchor.constraint(equalToConstant: SettingsWindowLayout.paneWidth)
        let height = view.heightAnchor.constraint(equalToConstant: SettingsWindowLayout.minPaneHeight)
        // Above the hosting controllers' 501, below required, so nothing a
        // pane reports can move the window except through `fitToSelectedPane`.
        width.priority = NSLayoutConstraint.Priority(999)
        height.priority = NSLayoutConstraint.Priority(999)
        NSLayoutConstraint.activate([width, height])
        widthPin = width
        heightPin = height
        selectedTabViewItemIndex = SettingsCategory.allCases.firstIndex(of: initialPane) ?? 0
    }

    var selectedPane: SettingsPaneHostingController? {
        guard selectedTabViewItemIndex >= 0, selectedTabViewItemIndex < tabViewItems.count else { return nil }
        return tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPaneHostingController
    }

    var selectedCategory: SettingsCategory {
        selectedPane?.category ?? initialPane
    }

    func select(_ category: SettingsCategory) {
        guard let index = SettingsCategory.allCases.firstIndex(of: category) else { return }
        selectedTabViewItemIndex = index
    }

    /// Called by the window controller once the window exists and has its
    /// first size, so selections from here on are the person's own.
    func finishSetup() {
        remembersSelection = true
        selectedCategory.remember(in: defaults)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        let category = selectedCategory
        title = category.title
        view.window?.title = category.title
        if remembersSelection { category.remember(in: defaults) }
        fitToSelectedPane(animated: view.window?.isVisible == true)
        paneDidChange?(category)
    }

    /// The content height the selected pane wants, capped by the screen.
    func targetContentHeight() -> CGFloat? {
        guard let pane = selectedPane else { return nil }
        let ideal = pane.preferredContentSize.height
        guard ideal > 0 else { return nil }
        var screenLimit: CGFloat?
        if let window = view.window, let screen = window.screen ?? NSScreen.main {
            let chrome = window.frame.height - window.contentLayoutRect.height
            screenLimit = screen.visibleFrame.height - chrome - 2 * SettingsWindowLayout.screenMargin
        }
        return SettingsWindowLayout.contentHeight(forIdealHeight: ideal, screenLimit: screenLimit)
    }

    /// Sizes the window to the selected pane. Animated only while the window
    /// is on screen and Reduce Motion is off; a retarget mid-animation
    /// continues from wherever the window currently is.
    func fitToSelectedPane(animated: Bool) {
        guard isViewLoaded, let heightPin, let target = targetContentHeight() else { return }
        guard abs(heightPin.constant - target) >= 0.5 else { return }

        if animated, !ReduceMotion.isEnabled {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = SettingsWindowLayout.resizeDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                heightPin.animator().constant = target
            }
        } else {
            heightPin.constant = target
            view.window?.layoutIfNeeded()
        }
    }
}

// MARK: - Controller

/// Owns the one Settings window. AppDelegate keeps a single instance and
/// calls `show(pane:)` for ⌘, and for the in-note hints that open a
/// specific pane.
final class SettingsWindowController: NSWindowController {
    let tabs: SettingsTabViewController

    init(settings: SettingsManager, notesManager: NotesManager,
         defaults: UserDefaults = .standard, initialPane: SettingsCategory? = nil) {
        let pane = initialPane ?? SettingsCategory.lastViewed(in: defaults)
        tabs = SettingsTabViewController(
            settings: settings, notesManager: notesManager, defaults: defaults, initialPane: pane
        )

        // Titled and closable only. Leaving out .miniaturizable and
        // .resizable is what dims the minimize and zoom buttons, as the HIG
        // asks of a settings window.
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: SettingsWindowLayout.paneWidth,
                                height: SettingsWindowLayout.minPaneHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.autorecalculatesKeyViewLoop = true
        window.contentViewController = tabs
        window.title = pane.title
        // Noncustomizable, and showing which pane is active. NSTabViewController
        // builds the toolbar this way already; stated here so it stays so.
        window.toolbar?.allowsUserCustomization = false
        window.toolbar?.displayMode = .iconAndLabel

        super.init(window: window)

        // The ideal height is only accurate once the pane is in a window, so
        // measure after attaching and before the window is ever shown: the
        // first frame on screen is already the right size.
        window.layoutIfNeeded()
        tabs.fitToSelectedPane(animated: false)
        tabs.finishSetup()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    var selectedCategory: SettingsCategory { tabs.selectedCategory }

    /// Brings the window forward. With a pane, switches to it first (the
    /// currency hint opens Privacy & Sync); without one, it stays on
    /// whichever pane it last showed.
    func show(pane: SettingsCategory? = nil) {
        if let pane { tabs.select(pane) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
