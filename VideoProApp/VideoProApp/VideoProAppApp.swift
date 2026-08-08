import SwiftUI
import AppKit

/// Receives `videopro://` URLs.
///
/// SwiftUI's `.onOpenURL` proved unreliable here — the `kAEGetURL` Apple Event
/// timed out (`-1712`) and never reached the view. Registering an explicit
/// handler is the documented, dependable path, and it MUST happen in
/// `applicationWillFinishLaunching`: register any later and the event that
/// launched the app has already been dropped.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once AppState is ready. Until then URLs are held, not lost.
    static var onURL: ((URL) -> Void)? {
        didSet { if onURL != nil { drain() } }
    }
    private static var pending: [URL] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor,
                                    reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        Self.deliver(url)
    }

    /// Modern AppKit path — belt and braces alongside the Apple Event handler.
    /// AppState.add() de-dupes, so a double delivery is harmless.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(Self.deliver)
    }

    private static func deliver(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        if let onURL { onURL(url) } else { pending.append(url) }
    }

    private static func drain() {
        let queued = pending
        pending.removeAll()
        queued.forEach { onURL?($0) }
    }
}

@main
struct VideoProApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState()
    @StateObject private var updater = UpdaterModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(updater)
                .frame(minWidth: 720, minHeight: 460)
                .onAppear {
                    state.start()
                    // Hand the delegate a route into our state; this also flushes
                    // any URL that arrived while we were still launching.
                    AppDelegate.onURL = { [weak state] url in
                        state?.handleURL(url)
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Right under "About VideoPro" — where every Mac app puts it.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            CommandGroup(after: .newItem) {
                Button("Grab Front Tab") { state.grabFrontTab() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        // One window per video, opened with `openWindow(value:)` from the library.
        //
        // Restoration is off deliberately. `WindowGroup(for:)` persists its value
        // across launches, which would reopen a player pointing at whatever URL it
        // had — and for a stream that's a signed CDN link that has since expired.
        // VideoItem takes the same position on purpose (see `playURL`: "Deliberately
        // NOT persisted … a stale one from a previous launch would 403"); restoring
        // here would quietly reintroduce exactly that, as a blank player rather than
        // an error. Playback is cheap to restart from the library.
        WindowGroup(for: PlayerContext.self) { $context in
            PlayerWindowView(context: context)
        }
        .defaultSize(width: 900, height: 560)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)

        // ⌘, — preferences belong in a window, not in a toolbar popover.
        Settings {
            SettingsView()
                .environmentObject(state)
        }

        // The one-off path: grab a video without ever opening the window.
        MenuBarExtra("VideoPro", systemImage: "arrow.down.circle") {
            MenuBarContent().environmentObject(state)
        }
    }
}

/// Menu bar contents. Deliberately tiny — this surface exists to make a one-off
/// grab take one click, not to be a second copy of the app.
struct MenuBarContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        // Menus are rebuilt each time they open, so reading this directly picks up
        // a browser change without needing to observe anything.
        let frontTab = FrontTab.shared
        // Naming the browser makes the action predictable — otherwise "Grab Front
        // Tab" is a coin flip when several browsers are open.
        Button(frontTab.target.map { "Grab Front Tab from \($0.name)" } ?? "No browser open") {
            state.grabFrontTab()
        }
        .disabled(frontTab.target == nil)

        Button("Paste URL and Download") {
            let pasted = NSPasteboard.general.string(forType: .string) ?? ""
            if let item = state.addURL(pasted) { state.download(item) }
        }

        if state.jobs.activeCount + state.jobs.queuedCount > 0 {
            Divider()
            Text("\(state.jobs.activeCount) running, \(state.jobs.queuedCount) queued")
        }

        Divider()
        Button("Open VideoPro") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
        Button("Quit VideoPro") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
