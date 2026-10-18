import Foundation
import Carbon.HIToolbox

extension HotKeyChoice {
    var keyCode: UInt32? {
        self == .off ? nil : UInt32(kVK_ANSI_E)
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionE: UInt32(controlKey | optionKey)
        case .controlOptionCommandE: UInt32(controlKey | optionKey | cmdKey)
        case .optionShiftE: UInt32(optionKey | shiftKey)
        }
    }
}

/// Owns the process-wide hot key, the same way Jot does.
///
/// Carbon's `RegisterEventHotKey` rather than an NSEvent global monitor: it
/// needs no Accessibility permission (which ad-hoc re-signing invalidates on
/// every rebuild), and it consumes the keystroke so it doesn't also type into
/// whatever app is in front.
final class HotKeyController {
    var onFire: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let signature = OSType(0x454D4252) // 'EMBR'

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
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

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Returns false when another app already owns the combo.
    @discardableResult
    func register(_ choice: HotKeyChoice) -> Bool {
        unregister()
        guard let keyCode = choice.keyCode else { return true }

        let status = RegisterEventHotKey(
            keyCode,
            choice.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            NSLog("Ember: could not register \(choice.display) (OSStatus \(status)); another app may own it")
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
