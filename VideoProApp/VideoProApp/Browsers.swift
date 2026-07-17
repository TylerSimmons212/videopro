import AppKit

/// A browser we can install the VideoPro extension into.
struct BrowserTarget: Identifiable, Hashable {
    enum Kind { case chromium, safari }

    let id: String          // bundle identifier
    let name: String
    let kind: Kind
    let appURL: URL

    /// The page where this browser manages extensions. Chromium browsers accept
    /// their `chrome://` URLs on the command line (verified on Arc), so we can
    /// deep-link the user straight there instead of describing where to click.
    var extensionsPage: String { "chrome://extensions" }
}

enum BrowserScan {
    /// Chromium forks we know how to set up, plus Safari. Order = display order.
    ///
    /// Detection is by bundle identifier through LaunchServices — deliberately
    /// NOT by looking for `~/Library/Application Support/<Browser>`, because an
    /// uninstalled browser leaves its profile folder behind and would show up as
    /// a false positive.
    private static let known: [(id: String, name: String, kind: BrowserTarget.Kind)] = [
        ("com.google.Chrome",          "Chrome",   .chromium),
        ("company.thebrowser.Browser", "Arc",      .chromium),
        ("com.brave.Browser",          "Brave",    .chromium),
        ("com.microsoft.edgemac",      "Edge",     .chromium),
        ("org.chromium.Chromium",      "Chromium", .chromium),
        ("com.vivaldi.Vivaldi",        "Vivaldi",  .chromium),
        ("com.operasoftware.Opera",    "Opera",    .chromium),
        ("com.apple.Safari",           "Safari",   .safari),
    ]

    /// Every supported browser actually present on this Mac.
    static func installed() -> [BrowserTarget] {
        known.compactMap { entry in
            guard let url = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: entry.id) else { return nil }
            return BrowserTarget(id: entry.id, name: entry.name, kind: entry.kind, appURL: url)
        }
    }

    /// Chromium browsers only — the ones that take the unpacked-folder flow.
    static func chromiumInstalled() -> [BrowserTarget] {
        installed().filter { $0.kind == .chromium }
    }

    static func safariInstalled() -> BrowserTarget? {
        installed().first { $0.kind == .safari }
    }
}
