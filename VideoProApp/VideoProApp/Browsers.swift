import AppKit

/// A browser VideoPro can read the current tab from, and borrow sign-in
/// cookies from for yt-dlp.
struct BrowserTarget: Identifiable, Hashable {
    enum Kind { case chromium, safari }

    let id: String          // bundle identifier
    let name: String
    let kind: Kind
    let appURL: URL

    /// How to name this browser to `yt-dlp --cookies-from-browser`.
    ///
    /// yt-dlp knows brave, chrome, chromium, edge, firefox, opera, safari, vivaldi
    /// and whale. Arc isn't on that list, but it's Chromium underneath, so point
    /// yt-dlp at its profile directory with the `chrome:PATH` form instead.
    var cookieSpec: String? {
        switch id {
        case "com.apple.Safari":            return "safari"
        case "com.google.Chrome":           return "chrome"
        case "com.brave.Browser":           return "brave"
        case "com.microsoft.edgemac":       return "edge"
        case "org.chromium.Chromium":       return "chromium"
        case "com.vivaldi.Vivaldi":         return "vivaldi"
        case "com.operasoftware.Opera":     return "opera"
        case "company.thebrowser.Browser":
            let path = NSHomeDirectory() + "/Library/Application Support/Arc/User Data"
            return FileManager.default.fileExists(atPath: path) ? "chrome:\(path)" : nil
        default: return nil
        }
    }

    /// What granting this costs the user, so the UI can warn before they pick it.
    /// Safari's cookie jar is protected by TCC; Chromium keeps its key in the
    /// login keychain. Neither failure is self-explanatory when it happens.
    var cookieCaveat: String? {
        switch id {
        case "com.apple.Safari":
            return "Requires Full Disk Access for VideoPro."
        case "company.thebrowser.Browser", "com.google.Chrome", "com.brave.Browser",
             "com.microsoft.edgemac", "org.chromium.Chromium", "com.vivaldi.Vivaldi",
             "com.operasoftware.Opera":
            return "macOS will ask for keychain access the first time."
        default: return nil
        }
    }
}

enum BrowserScan {
    /// Chromium forks we know how to read, plus Safari. Order = display order.
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

    /// Is this bundle id one of the browsers we can read a tab URL out of?
    static func isKnownBrowser(_ bundleID: String) -> Bool {
        known.contains { $0.id == bundleID }
    }

    /// Supported browsers with a live process, in display order.
    ///
    /// Deliberately not `installed()` — reading a tab out of a browser that isn't
    /// running would launch it, which is a startling thing to happen when someone
    /// presses a hotkey expecting a download.
    static func runningBrowsers() -> [BrowserTarget] {
        let live = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return installed().filter { live.contains($0.id) }
    }
}
