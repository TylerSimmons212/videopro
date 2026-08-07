import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - Shortcut recorder

/// Click-to-record control for the global hotkey: shows the current combination,
/// and on click swallows the next keystroke and adopts it.
///
/// SwiftUI has no way to observe a raw key-down with its modifiers intact —
/// `onKeyPress` gives characters, not virtual key codes, and never sees ⌘ combos
/// at all because AppKit routes those down the key-equivalent path first. So the
/// capture itself is an NSView (see `KeyCaptureField`) and SwiftUI only paints
/// the chip on top of it.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo
    /// An NSView knows nothing about SwiftUI's `.disabled(…)`, so the enabled
    /// state has to be read out of the environment and handed down by hand.
    @Environment(\.isEnabled) private var isEnabled
    @State private var isRecording = false
    /// Briefly replaces the label when a modifier-less key was pressed, so the
    /// rejection reads as a rule rather than as the control ignoring the user.
    @State private var showRejection = false

    var body: some View {
        KeyCaptureField(
            isEnabled: isEnabled,
            isRecording: $isRecording,
            onCapture: { captured in
                combo = captured
                showRejection = false
            },
            onReject: {
                showRejection = true
                // Stay in recording mode: they're mid-attempt, not done.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showRejection = false }
            }
        )
        .frame(width: 132, height: 22)
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .fill(isRecording ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                      lineWidth: isRecording ? 2 : 1)
                }
                .overlay {
                    Text(label)
                        .font(.system(size: 12, weight: isRecording ? .regular : .medium))
                        .foregroundStyle(isEnabled ? (isRecording ? .secondary : .primary) : .tertiary)
                        .lineLimit(1)
                }
                // The NSView underneath owns the click and the keyboard.
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Global shortcut")
        .accessibilityValue(combo.displayString)
        .help(isRecording ? "Press a shortcut, or Escape to cancel" : "Click to record a new shortcut")
    }

    private var label: String {
        if showRejection { return "Add ⌃ ⌥ or ⌘" }
        return isRecording ? "Press keys…" : combo.displayString
    }
}

/// The AppKit escape hatch: a bare view that takes first responder while recording
/// and consumes exactly one usable keystroke.
private struct KeyCaptureField: NSViewRepresentable {
    var isEnabled: Bool
    @Binding var isRecording: Bool
    var onCapture: (KeyCombo) -> Void
    var onReject: () -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.owner = context.coordinator
        return v
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        context.coordinator.parent = self
        view.isEnabled = isEnabled
        view.isRecording = isRecording && isEnabled
        if view.isRecording, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: KeyCaptureField
        init(parent: KeyCaptureField) { self.parent = parent }

        /// Bindings mustn't be written during a SwiftUI update pass, and AppKit can
        /// call in from inside one (first-responder changes especially), so every
        /// state change hops to the next runloop turn.
        func setRecording(_ on: Bool) {
            DispatchQueue.main.async { [parent] in parent.isRecording = on }
        }
        func capture(_ combo: KeyCombo) {
            DispatchQueue.main.async { [parent] in
                parent.onCapture(combo)
                parent.isRecording = false
            }
        }
        func reject() {
            DispatchQueue.main.async { [parent] in parent.onReject() }
        }
    }

    final class CaptureView: NSView {
        var owner: Coordinator?
        var isRecording = false
        var isEnabled = true

        override var acceptsFirstResponder: Bool { isEnabled }
        /// Clicking straight into recording, without a first click just to focus.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            window?.makeFirstResponder(self)
            owner?.setRecording(!isRecording)
        }

        /// ⌘-bearing keystrokes are dispatched as key equivalents and never reach
        /// `keyDown`, so the capture has to sit here as well — and returning true
        /// is what stops the keystroke from also triggering a menu item.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            handle(event)
        }

        override func keyDown(with event: NSEvent) {
            if !handle(event) { super.keyDown(with: event) }
        }

        override func resignFirstResponder() -> Bool {
            owner?.setRecording(false)
            return true
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard isRecording else { return false }
            if event.keyCode == UInt16(kVK_Escape) {
                owner?.setRecording(false)
                return true
            }
            if let combo = KeyCombo(event: event) {
                owner?.capture(combo)
            } else {
                owner?.reject()
            }
            return true
        }

        override func drawFocusRingMask() { bounds.fill() }
        override var focusRingMaskBounds: NSRect { bounds }
    }
}
