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
        }
    }
}
