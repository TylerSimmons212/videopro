import SwiftUI
import Combine
import Sparkle

/// In-app auto-update via Sparkle.
///
/// VideoPro ships as a DMG outside the App Store, so nothing updates it for us.
/// Sparkle polls an appcast feed, verifies each update against our EdDSA public
/// key (SUPublicEDKey in Info.plist) *and* the code signature, then installs and
/// relaunches.
///
/// Two things are load-bearing and easy to get wrong:
///  • Releases must be Developer ID signed + notarized. An ad-hoc signed update
///    will download and then fail to launch past Gatekeeper.
///  • The appcast's `sparkle:edSignature` must be produced by Sparkle's
///    `sign_update` with the private key that matches SUPublicEDKey, or Sparkle
///    silently rejects the update. See scripts/appcast.sh.
@MainActor
final class UpdaterModel: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirrors the updater so SwiftUI can disable the menu item while a check is
    /// already in flight.
    @Published var canCheck = true

    init() {
        // startingUpdater: true — begin the scheduled background check on launch.
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheck)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// Shown in Settings so users can see the app is actually looking.
    var lastCheckDescription: String {
        guard let date = controller.updater.lastUpdateCheckDate else {
            return "Not checked yet"
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last checked \(f.localizedString(for: date, relativeTo: Date()))"
    }
}

/// "Check for Updates…" — belongs in the app menu, where Mac users look for it.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}
