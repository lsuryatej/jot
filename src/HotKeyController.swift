import Foundation
import Carbon.HIToolbox

/// Owns the process-wide hot key.
///
/// Carbon's `RegisterEventHotKey` is used rather than an NSEvent global monitor
/// because it needs no Accessibility permission (which ad-hoc re-signing
/// invalidates on every rebuild) and because it consumes the keystroke, so the
/// shortcut does not also type into whatever app is in front.
final class HotKeyController {
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var registeredCombo: KeyCombo?

    private static let signature = OSType(0x53544B59) // 'STKY'

    init() {
        installHandler()
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    /// The Carbon handler is installed once and left in place; only the hot key
    /// registration itself changes when the user picks a new shortcut.
    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { controller.onFire?() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    /// Returns false when the combo is rejected, which in practice means another
    /// application already owns it.
    @discardableResult
    func register(_ combo: KeyCombo) -> Bool {
        unregister()

        guard combo.isValid else {
            NSLog("StickyNotes: refusing to register \(combo.displayString) with no modifiers")
            return false
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            NSLog("StickyNotes: could not register \(combo.displayString) (OSStatus \(status)); another app may own it")
            hotKeyRef = nil
            registeredCombo = nil
            return false
        }

        registeredCombo = combo
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        registeredCombo = nil
    }
}
