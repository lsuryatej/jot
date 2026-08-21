import SwiftUI
import AppKit
import Carbon.HIToolbox

@main
struct StickyNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// Carbon's event handler is a C function pointer, so it cannot capture context.
// The delegate is passed through as userData and recovered here.
private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { delegate.togglePanel() }
    return noErr
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel!
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = FloatingPanel()
        registerGlobalHotKey()

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The App protocol requires a Scene, and this app is driven entirely from
        // the AppDelegate, so `Settings { EmptyView() }` stands in as a placeholder.
        // macOS materialises it as a blank 900x450 window, so hide it once SwiftUI
        // has finished building the scene graph.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for window in NSApp.windows where window !== self.panel {
                window.orderOut(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    /// Registers Option+A via Carbon's RegisterEventHotKey.
    ///
    /// This replaces NSEvent.addGlobalMonitorForEvents, which needed Accessibility
    /// permission (invalidated on every ad-hoc re-sign) and could not consume the
    /// keystroke — Option+A would toggle the panel *and* type "å" into the frontmost
    /// app. RegisterEventHotKey needs no permission and swallows the event.
    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x53544B59), id: 1) // 'STKY'
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog("StickyNotes: failed to register Option+A hot key (OSStatus \(status)). Another app may already own it.")
        }
    }

    func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
            styleMask: [.nonactivatingPanel, .titled, .resizable, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isFloatingPanel = true
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear // We'll handle background in SwiftUI
        self.hasShadow = true
        self.isOpaque = false
        self.center()

        let hostingView = NSHostingView(rootView: ContentView())
        self.contentView = hostingView
    }

    // Closing the panel must only hide it. The app is LSUIElement with no status
    // item, so a real close would leave it running and unreachable.
    override func close() {
        orderOut(nil)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
