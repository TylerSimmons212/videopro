import SwiftUI
import AppKit

@main
struct VideoProApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 520, minHeight: 420)
                .onAppear { state.start() }
                .onOpenURL { _ in
                    // videopro:// — the extension opens this to launch/focus us so
                    // its POST to the local server can land. Just come to the front.
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentMinSize)
    }
}
