import AppKit
import Carbon.HIToolbox

/// A system-wide hotkey for the fast path.
///
/// Carbon's `RegisterEventHotKey` rather than `NSEvent.addGlobalMonitorForEvents`:
/// the NSEvent route needs Accessibility permission — a far bigger ask than this
/// feature justifies, on top of the Automation grant we already need — and it
/// can't consume the event, so the keystroke would still reach whatever app is
/// in front. Carbon hot keys need no permission at all and remain the supported
/// mechanism on current macOS.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    /// ⌃⌥⌘D. Deliberately awkward: a global hotkey is stolen from *every* app, so
    /// anything comfortable is already spoken for. ⇧⌘G, which the in-app menu item
    /// uses, would shadow Finder's "Go to Folder" and Find-Previous everywhere.
    static let keyCode = UInt32(kVK_ANSI_D)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let displayName = "⌃⌥⌘D"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    var isRegistered: Bool { hotKeyRef != nil }

    func register(action: @escaping () -> Void) {
        unregister()
        self.action = action

        // Install the dispatcher once; re-registering the key later reuses it.
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                     eventKind: UInt32(kEventHotKeyPressed))
            // Must be a bare C function pointer, so this closure captures nothing
            // and reaches the instance through the shared singleton instead.
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
                MainActor.assumeIsolated { GlobalHotKey.shared.fire() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }

        let id = EventHotKeyID(signature: OSType(0x5650_524F), id: 1)   // 'VPRO'
        let status = RegisterEventHotKey(Self.keyCode, Self.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            // Almost always because another app already owns this combination.
            NSLog("VideoPro: could not register %@ (status %d)", Self.displayName, status)
            hotKeyRef = nil
        }
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func fire() { action?() }
}
