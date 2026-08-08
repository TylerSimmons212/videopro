import AppKit
import Carbon.HIToolbox

/// A key + modifier pair, stored in Carbon's vocabulary because that's what
/// `RegisterEventHotKey` speaks. Everything that comes in from AppKit is
/// converted at the boundary (see `KeyCombo.init(event:)`) so the rest of the app
/// only ever deals in one representation.
struct KeyCombo: Equatable, Sendable {
    /// A virtual key code (`kVK_*`) — layout-independent, so this stays the same
    /// physical key whatever keyboard layout is active.
    var keyCode: UInt32
    /// Carbon modifier mask: `cmdKey | optionKey | controlKey | shiftKey`.
    var modifiers: UInt32

    /// ⌃⌥⌘D. Deliberately awkward: a global hotkey is stolen from *every* app, so
    /// anything comfortable is already spoken for. ⇧⌘G, which the in-app menu item
    /// uses, would shadow Finder's "Go to Folder" and Find-Previous everywhere.
    static let fallback = KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                                   modifiers: UInt32(controlKey | optionKey | cmdKey))

    /// Menu-style glyph string, e.g. "⌃⌥⌘D". Modifier order matches the one macOS
    /// uses in menus, which is not the order of the bit mask.
    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Builds a combo from a key-down event, or nil if the event isn't usable as a
    /// global shortcut.
    ///
    /// Rejects anything without ⌃, ⌥ or ⌘: a global hotkey is consumed before the
    /// front app sees it, so registering a bare "D" — or even ⇧D — would make that
    /// key unusable for typing everywhere on the system.
    init?(event: NSEvent) {
        let carbon = Self.carbonModifiers(event.modifierFlags)
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// AppKit and Carbon both have modifier bit masks and they share no values at
    /// all (`NSEvent.ModifierFlags.command` is 1 << 20, Carbon's `cmdKey` is 1 << 8),
    /// so the two can only be bridged flag by flag.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Virtual key code → the glyph macOS would print in a menu.
    ///
    /// Deliberately a static table rather than a `UCKeyTranslate` round-trip: the
    /// codes are layout-independent, and translating them would make the displayed
    /// shortcut drift with the input source while the key it fires on doesn't.
    static func keyName(_ code: UInt32) -> String {
        if let name = namedKeys[Int(code)] { return name }
        // Unmapped (numeric keypad oddities, ISO-only keys): show the raw code
        // rather than a blank chip, so the setting still reads as *something*.
        return "Key \(code)"
    }

    private static let namedKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",

        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",

        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",

        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",

        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",

        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]
}

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

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    var isRegistered: Bool { hotKeyRef != nil }

    /// Registers `combo` system-wide. Returns false when the OS refuses it —
    /// almost always because another app already owns the combination. The caller
    /// is expected to tell the user, since a silently unregistered hotkey is
    /// indistinguishable from a broken one.
    @discardableResult
    func register(_ combo: KeyCombo, action: @escaping () -> Void) -> Bool {
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
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("VideoPro: could not register %@ (status %d)", combo.displayString, status)
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func fire() { action?() }
}
