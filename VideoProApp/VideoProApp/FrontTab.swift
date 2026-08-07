import AppKit

/// Reads the URL of the active tab out of the user's browser.
///
/// This is what lets the browser extension become optional. For platform pages —
/// which is most of what anyone downloads — yt-dlp only ever needed the page URL,
/// and every mainstream macOS browser hands that out over AppleScript. So the
/// fast path is: hotkey → read the front tab → download. No paste, no extension,
/// no loopback server.
///
/// Permission is Automation (`NSAppleEventsUsageDescription`), which is prompted
/// once per browser and revocable in System Settings — much lighter than the
/// Screen Recording or Network Extension entitlements the alternatives need.
@MainActor
final class FrontTab {
    static let shared = FrontTab()

    struct Tab {
        let url: String
        let title: String?
        let browser: String
    }

    enum Failure: LocalizedError {
        case noBrowser
        case notPermitted(String)
        case notRunning(String)
        case noWindow(String)
        case timedOut(String)
        case script(String, String)

        var errorDescription: String? {
            switch self {
            case .noBrowser:
                return "No supported browser is running."
            case .notPermitted(let b):
                return "VideoPro isn’t allowed to control \(b)."
            case .notRunning(let b):
                return "\(b) isn’t running."
            case .noWindow(let b):
                return "\(b) has no open tab."
            case .timedOut(let b):
                return "\(b) didn’t respond."
            case .script(let b, let msg):
                return "Couldn’t read the front tab in \(b): \(msg)"
            }
        }

        /// Only the permission failure is worth sending someone to Settings for.
        var isPermission: Bool {
            if case .notPermitted = self { return true }
            return false
        }
    }

    // MARK: - Which browser to ask

    /// Bundle id of the most recent browser to come forward.
    ///
    /// Load-bearing: clicking our menu bar item — or firing the global hotkey and
    /// then having us activate — makes *VideoPro* the frontmost app. "Who is
    /// frontmost right now" is therefore the wrong question; we need whoever was
    /// in front just before us.
    private var lastBrowserID: String?

    private init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            guard BrowserScan.isKnownBrowser(id) else { return }
            MainActor.assumeIsolated { self?.lastBrowserID = id }
        }
        // Seed from whatever is in front at launch, so the very first grab works
        // even if the user hasn't switched apps since we started.
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           BrowserScan.isKnownBrowser(id) {
            lastBrowserID = id
        }
    }

    /// The browser we'd read from right now, if any. Drives the menu bar label
    /// so the action can name its target instead of saying "front tab".
    var target: BrowserTarget? {
        let running = BrowserScan.runningBrowsers()
        if let id = lastBrowserID, let match = running.first(where: { $0.id == id }) { return match }
        return running.first
    }

    // MARK: - Reading

    func read() throws -> Tab {
        guard let browser = target else { throw Failure.noBrowser }
        let source = Self.script(for: browser)

        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw Failure.script(browser.name, "could not compile")
        }
        let output = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "unknown error"
            switch code {
            case -1743: throw Failure.notPermitted(browser.name)   // errAEEventNotPermitted
            case -600, -609: throw Failure.notRunning(browser.name) // procNotFound
            case -1728: throw Failure.noWindow(browser.name)        // errAENoSuchObject
            case -1712: throw Failure.timedOut(browser.name)        // errAETimeout
            default: throw Failure.script(browser.name, message)
            }
        }

        // The script returns "url\ntitle" — a record would need coercion dances
        // that differ between Safari and the Chromium forks.
        let parts = (output.stringValue ?? "").components(separatedBy: "\n")
        let url = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : nil

        guard url.hasPrefix("http") else { throw Failure.noWindow(browser.name) }
        return Tab(url: url, title: (title?.isEmpty ?? true) ? nil : title, browser: browser.name)
    }

    /// Safari and the Chromium family disagree on both accessors: Safari has
    /// `current tab` / `name`, everyone else (Arc included) has `active tab` /
    /// `title`. Verified against each app's own `sdef`.
    ///
    /// `application id` rather than `application "Name"` so a localised or
    /// renamed app bundle still resolves. The explicit timeout matters: Apple
    /// events default to 60 seconds, and NSAppleScript runs on this thread — a
    /// beachballing browser would otherwise take the UI down with it.
    private static func script(for browser: BrowserTarget) -> String {
        let (tab, titleKey) = browser.kind == .safari
            ? ("current tab", "name")
            : ("active tab", "title")
        return """
        with timeout of 2 seconds
            tell application id "\(browser.id)"
                if (count of windows) is 0 then error number -1728
                set _t to \(tab) of front window
                return ((URL of _t) as text) & "\\n" & ((\(titleKey) of _t) as text)
            end tell
        end timeout
        """
    }

    /// Open the pane where Automation permission is granted. There's no API to
    /// re-prompt once a user has said no — the switch in Settings is the only way
    /// back, so link them straight to it.
    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
}
