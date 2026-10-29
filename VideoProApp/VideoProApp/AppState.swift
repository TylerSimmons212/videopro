import Foundation
import Combine
import SwiftUI
import AppKit
import UserNotifications
import Security

@MainActor
final class AppState: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var downloadFolder: URL
    @Published var toolsReady = false
    @Published var toolSummary = ""

    // User download preferences. All persisted — these used to reset to their
    // defaults on every launch, silently undoing whatever the user chose.
    @Published var defaultQuality: DownloadQuality = .bestMP4 { didSet { persistPrefs() } }
    @Published var embedThumbnail = true { didSet { persistPrefs() } }
    @Published var embedSubtitles = true { didSet { persistPrefs() } }

    /// Bundle id of the browser to borrow cookies from, or nil for none.
    ///
    /// Off by default and deliberately opt-in: it's what makes logged-in and
    /// members-only videos work without the extension, but the first use triggers
    /// a keychain prompt (Chromium) or needs Full Disk Access (Safari), and
    /// neither is something to spring on someone who didn't ask.
    @Published var cookieBrowserID: String? {
        didSet { persistPrefs(); applyCookieSetting() }
    }

    /// System-wide hotkey for the fast path.
    @Published var hotKeyEnabled = true { didSet { persistPrefs(); applyHotKey() } }

    /// The combination the fast path listens for. User-changeable, because the
    /// default can collide with whatever else they've installed.
    @Published var hotKeyCombo: KeyCombo = .fallback { didSet { persistPrefs(); applyHotKey() } }

    /// Set when the OS refused the chosen combination — another app already owns
    /// it. Surfaced in Settings; without it a taken shortcut just looks broken.
    @Published var hotKeyUnavailable = false

    /// Put a link copied in another app into the field when coming back.
    @Published var offerCopiedLinks = true { didSet { persistPrefs() } }

    /// Convert a finished download to HEVC when this Mac's QuickTime can't play
    /// it — YouTube's 4K is AV1 or VP9, which Macs before M3 can't decode.
    @Published var convertForQuickTime = true { didSet { persistPrefs() } }

    /// Mirrors JobCenter so views observing AppState still repaint when work
    /// starts or finishes. The queue itself lives in JobCenter now.
    let jobs = JobCenter.shared

    /// The field at the top of the library: links to look up, or a search.
    let linkSearch = LinkSearch()

    /// How many un-downloaded videos to pre-warm on launch. Each costs one
    /// `yt-dlp -J`, so this is a deliberate ceiling, not the whole library.
    let warmOnLaunchCount = 6

    var options: DownloadOptions {
        DownloadOptions(
            quality: defaultQuality,
            embedThumbnail: embedThumbnail,
            embedSubtitles: embedSubtitles
        )
    }

    init() {
        // Default download folder: ~/Downloads/VideoPro
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = downloads.appendingPathComponent("VideoPro", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.downloadFolder = folder

        // Restore a previously chosen folder if the user picked one.
        if let saved = UserDefaults.standard.url(forKey: "downloadFolder") {
            self.downloadFolder = saved
        }
        loadPrefs()

        // Throttled so a burst of transitions coalesces into one re-render.
        VideoItem.statusChanged
            .throttle(for: .milliseconds(200), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &bag)

        // `objectWillChange` fires *before* the mutation, so read the counts on the
        // next runloop turn or the badge is always one event stale.
        JobCenter.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                let n = JobCenter.shared.activeCount
                NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : ""
                self?.updateKeepAwake()
                self?.objectWillChange.send()
            }
            .store(in: &bag)

        linkSearch.state = self
    }

    private var bag = Set<AnyCancellable>()

    /// Held while anything is downloading or exporting, so the Mac doesn't go to
    /// sleep on an unattended download. The display may still sleep.
    private var keepAwake: NSObjectProtocol?

    private func updateKeepAwake() {
        let busy = JobCenter.shared.activeCount + JobCenter.shared.queuedCount > 0
        if busy, keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .automaticTerminationDisabled],
                reason: "Downloading videos")
        } else if !busy, let activity = keepAwake {
            ProcessInfo.processInfo.endActivity(activity)
            keepAwake = nil
        }
    }

    // MARK: - Preferences

    private enum PrefKey {
        static let quality = "defaultQuality"
        static let thumb = "embedThumbnail"
        static let subs = "embedSubtitles"
        static let cookieBrowser = "cookieBrowserID"
        static let hotKey = "hotKeyEnabled"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let offerLinks = "offerCopiedLinks"
        static let convertQT = "convertForQuickTime"
    }

    private var loadingPrefs = false

    private func loadPrefs() {
        loadingPrefs = true
        defer { loadingPrefs = false }
        let d = UserDefaults.standard
        if let raw = d.string(forKey: PrefKey.quality),
           let q = DownloadQuality(rawValue: raw) { defaultQuality = q }
        if d.object(forKey: PrefKey.thumb) != nil { embedThumbnail = d.bool(forKey: PrefKey.thumb) }
        if d.object(forKey: PrefKey.subs) != nil { embedSubtitles = d.bool(forKey: PrefKey.subs) }
        cookieBrowserID = d.string(forKey: PrefKey.cookieBrowser)
        if d.object(forKey: PrefKey.hotKey) != nil { hotKeyEnabled = d.bool(forKey: PrefKey.hotKey) }
        // Left behind by the browser extension, which is gone.
        for stale in ["serverEnabled", "everConnected"] { d.removeObject(forKey: stale) }
        if d.object(forKey: PrefKey.hotKeyCode) != nil,
           d.object(forKey: PrefKey.hotKeyModifiers) != nil {
            hotKeyCombo = KeyCombo(keyCode: UInt32(d.integer(forKey: PrefKey.hotKeyCode)),
                                   modifiers: UInt32(d.integer(forKey: PrefKey.hotKeyModifiers)))
        }
        if d.object(forKey: "inboxExpiryDays") != nil {
            inboxExpiryDays = d.integer(forKey: "inboxExpiryDays")
        }
        if d.object(forKey: PrefKey.offerLinks) != nil {
            offerCopiedLinks = d.bool(forKey: PrefKey.offerLinks)
        }
        if d.object(forKey: PrefKey.convertQT) != nil {
            convertForQuickTime = d.bool(forKey: PrefKey.convertQT)
        }
    }

    private func persistPrefs() {
        guard !loadingPrefs else { return }   // don't echo the load straight back
        let d = UserDefaults.standard
        d.set(defaultQuality.rawValue, forKey: PrefKey.quality)
        d.set(embedThumbnail, forKey: PrefKey.thumb)
        d.set(embedSubtitles, forKey: PrefKey.subs)
        d.set(cookieBrowserID, forKey: PrefKey.cookieBrowser)
        d.set(hotKeyEnabled, forKey: PrefKey.hotKey)
        d.set(Int(hotKeyCombo.keyCode), forKey: PrefKey.hotKeyCode)
        d.set(Int(hotKeyCombo.modifiers), forKey: PrefKey.hotKeyModifiers)
        d.set(offerCopiedLinks, forKey: PrefKey.offerLinks)
        d.set(convertForQuickTime, forKey: PrefKey.convertQT)
    }

    /// The browser cookies are currently being borrowed from, if any.
    var cookieBrowser: BrowserTarget? {
        guard let id = cookieBrowserID else { return nil }
        return BrowserScan.installed().first { $0.id == id }
    }

    private func applyCookieSetting() {
        DownloadManager.shared.cookieSpec = cookieBrowser?.cookieSpec
    }

    private func applyHotKey() {
        if hotKeyEnabled {
            let ok = GlobalHotKey.shared.register(hotKeyCombo) { [weak self] in
                Task { @MainActor in self?.grabFrontTab() }
            }
            hotKeyUnavailable = !ok
        } else {
            GlobalHotKey.shared.unregister()
            hotKeyUnavailable = false
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Called from the main window's onAppear, which fires again when a closed
        // window is reopened. Once is right: a second run would reload the
        // library over live downloads and subscribe to everything twice.
        guard !started else { return }
        clearOwnQuarantineIfNeeded()
        checkInstallLocation()
        loadCollections()
        loadLibrary()
        expireInbox()
        refreshTools()
        requestNotifications()
        applyCookieSetting()
        applyHotKey()

        // Only now is it safe to apply incoming URLs: loadLibrary() replaces
        // `items` wholesale, so anything added before this point would be lost.
        started = true
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued { handleURL(url) }

        // Downloads that quitting cut off carry on by themselves; ones the user
        // paused wait for them.
        let interrupted = resumeOnLaunch
        resumeOnLaunch = []
        for item in interrupted { download(item) }

        removeAbandonedConversions()

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.offerCopiedLink() }
            .store(in: &bag)
        offerCopiedLink()
    }

    /// Filled by loadLibrary() with downloads that were running at quit.
    private var resumeOnLaunch: [VideoItem] = []

    // MARK: - videopro:// URL scheme

    private var started = false
    private var pendingURLs: [URL] = []

    /// Handle `videopro://open?url=<page>` and `videopro://download?t=<token>&url=<page>`.
    ///
    /// What the bookmarklet sends: the page you're on, from any browser —
    /// Firefox included, which the front-tab grab can't read.
    ///
    /// Any web page can fire a `videopro://` link, so nothing here may act on
    /// its own say-so. `open` only puts the link in the field for the user to
    /// look at. `download` starts it without asking only when it carries the
    /// secret that's baked into the user's own bookmarklet; without it, it's
    /// treated as `open`. And the address must be an ordinary web address —
    /// no other schemes, and no way to smuggle a yt-dlp option in.
    func handleURL(_ url: URL) {
        guard url.scheme?.lowercased() == "videopro" else { return }
        // A cold launch delivers the URL before start() — hold it until we're ready.
        guard started else { pendingURLs.append(url); return }

        // Accept videopro://open?… and videopro:///open?… alike.
        let action = (url.host?.isEmpty == false ? url.host! : url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let page = query.first(where: { $0.name == "url" })?.value,
              let link = LinkSearch.link(from: page),
              let scheme = URL(string: link)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            showMainWindow()   // bare videopro:// — just come forward
            return
        }
        let trusted = query.first(where: { $0.name == "t" })?.value == bookmarkletToken
        showMainWindow()
        if action == "download" && trusted {
            linkSearch.openAndDownload(link)
        } else if action == "download" || action == "open" {
            linkSearch.query = link
            linkSearch.focus()
        }
    }

    /// A per-install secret that only the user's own bookmarklet knows. Made on
    /// first use; it isn't protecting anything on this Mac, only telling the
    /// bookmarklet apart from a web page that fires the same kind of link.
    var bookmarkletToken: String {
        let key = "bookmarkletToken"
        if let t = UserDefaults.standard.string(forKey: key), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(t, forKey: key)
        return t
    }

    /// The bookmarklet for the browser's bookmarks bar. It hands the page's
    /// address to the app and nothing else — no access to other pages, no
    /// extension to install or keep updated.
    var bookmarklet: String {
        "javascript:location.href='videopro://download?t=\(bookmarkletToken)&url='+encodeURIComponent(location.href)"
    }

    // MARK: - Install location & installer cleanup

    /// Strip our own `com.apple.quarantine` on launch.
    ///
    /// Added for the Safari extension, which wouldn't register from a
    /// quarantined app. The extension is gone, but this stays for now: a
    /// quarantined bundle is also what App Translocation keys on, and the
    /// translocation fix in 2.0.1 was verified with this running. Drop it once a
    /// release confirms the Automation prompt works without it. (A running,
    /// non-sandboxed app may modify its own bundle; the user can't easily, since
    /// `com.apple.macl` blocks `xattr` without Full Disk Access.)
    private func clearOwnQuarantineIfNeeded() {
        let bundlePath = Bundle.main.bundlePath
        // Dev builds in DerivedData are never quarantined; skip the work.
        guard bundlePath.hasPrefix("/Applications/") || bundlePath.hasPrefix("/Volumes/")
            || bundlePath.contains("/Downloads/") else { return }

        // Fast check: is the top-level bundle even quarantined?
        let hasQuarantine = (try? URL(fileURLWithPath: bundlePath)
            .resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil
        guard hasQuarantine else { return }

        // `xattr -dr` clears it from every nested file, not just the top level.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-dr", "com.apple.quarantine", bundlePath]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do {
            try p.run(); p.waitUntilExit()
            if p.terminationStatus == 0 {
                NSLog("VideoPro: cleared own quarantine")
            }
        } catch {
            NSLog("VideoPro: quarantine clear failed: %@", error.localizedDescription)
        }
    }

    /// Is macOS running us from a randomised read-only copy?
    ///
    /// Opening a quarantined app straight from a DMG triggers App Translocation:
    /// the app executes from /private/var/…/AppTranslocation/<uuid>/d/, not from
    /// where the user thinks it lives. That path is randomised per launch, so TCC
    /// can't record a stable identity for us — Automation prompts don't stick and
    /// **no entry ever appears in Privacy & Security → Automation**, leaving the
    /// user staring at a list they can't add to. Nothing in-app can fix it; the
    /// bundle has to be moved to a real location and reopened.
    var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// If we're running from a DMG or Downloads, offer to move to /Applications.
    /// If already installed, offer to eject leftover installer disk images.
    func checkInstallLocation() {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") {
            offerEjectInstallers()
            return
        }
        // Translocation is checked first and separately: the path looks nothing
        // like a DMG or Downloads, so the location tests below all miss it.
        guard isTranslocated || path.hasPrefix("/Volumes/") || path.contains("/Downloads/")
        else { return }   // never nudge dev builds (DerivedData/Xcode)

        let a = NSAlert()
        a.messageText = isTranslocated
            ? "Move VideoPro to Applications to finish setup"
            : "Move VideoPro to Applications?"
        a.informativeText = isTranslocated
            ? "macOS is running VideoPro from a temporary copy, which stops it asking for permission to read your browser’s tab — the Automation list stays empty and there’s nothing to switch on. Moving it to Applications fixes that."
            : "VideoPro should live in your Applications folder, so it keeps working after the disk image is ejected or Downloads is tidied up."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not Now")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        moveToApplications(from: path)
    }

    private func moveToApplications(from currentPath: String) {
        let fm = FileManager.default
        let dest = "/Applications/VideoPro.app"
        do {
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: currentPath, toPath: dest)
        } catch {
            alert("Couldn’t move automatically",
                  "Please drag VideoPro into your Applications folder yourself.\n\n\(error.localizedDescription)")
            return
        }
        // Relaunch from /Applications; the fresh copy will offer to eject the installer.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", dest]
        try? p.run()
        NSApp.terminate(nil)
    }

    private func offerEjectInstallers() {
        let mounts = ((try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [])
            .filter { $0 == "VideoPro" || $0.hasPrefix("VideoPro ") }
        guard !mounts.isEmpty else { return }

        let a = NSAlert()
        a.messageText = "Eject the VideoPro installer?"
        a.informativeText = "VideoPro is installed. You can eject the installer disk image\(mounts.count > 1 ? "s" : "") now to keep things tidy."
        a.addButton(withTitle: "Eject")
        a.addButton(withTitle: "Keep")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for name in mounts {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["detach", "/Volumes/\(name)", "-force"]
            try? p.run(); p.waitUntilExit()
        }
    }

    func refreshTools() {
        let status = DownloadManager.shared.toolStatus()
        toolsReady = status.ready
        if let yt = status.ytDlp {
            let ff = status.ffmpeg != nil ? "ffmpeg ✓" : "ffmpeg ✗ (muxing limited)"
            let probe = status.ffprobe != nil ? "ffprobe ✓" : "ffprobe ✗ (no media details)"
            let deno = status.deno != nil ? "deno ✓" : "deno ✗ (fewer YouTube formats)"
            toolSummary = "yt-dlp: \((yt as NSString).lastPathComponent) · \(ff) · \(probe) · \(deno)"
        } else {
            toolSummary = "yt-dlp not found — install with `brew install yt-dlp`"
        }
    }

    // MARK: - Items

    func add(_ metas: [VideoMeta]) {
        for meta in metas {
            // De-dupe on the URL we'd actually download.
            let key = meta.downloadURL
            if !key.isEmpty, items.contains(where: { $0.meta.downloadURL == key }) { continue }
            let item = VideoItem(meta)
            items.insert(item, at: 0)
            enrich(item)   // fetch a real thumbnail + qualities in the background
        }
        saveLibrary()
    }

    // MARK: - Fast path

    /// Grab whatever is in the user's browser and start downloading it.
    ///
    /// This is the whole point of the app-first rework: hotkey or menu bar item →
    /// the video is downloading. No window, no paste, no extension. Everything
    /// this needs is a page URL, which is all yt-dlp ever wanted.
    func grabFrontTab() {
        do {
            let tab = try FrontTab.shared.read()
            guard let item = addURL(tab.url, title: tab.title) else {
                notify("Already in your library", tab.title ?? tab.url)
                return
            }
            download(item)
        } catch let error as FrontTab.Failure {
            if error.isPermission {
                presentAutomationDenied(error)
            } else {
                notify("Couldn’t grab the tab", error.errorDescription ?? "Unknown error")
            }
        } catch {
            notify("Couldn’t grab the tab", error.localizedDescription)
        }
    }

    /// Explain an Automation denial in terms the user can act on.
    ///
    /// "Turn it on in Settings" is useless advice when there is no switch to turn
    /// on, and that is the common case: the Automation pane only lists apps that
    /// have already prompted, so a denial that happened before any prompt leaves
    /// the list empty. There are exactly two real remedies, and which one applies
    /// is knowable, so say the right one rather than the generic one.
    private func presentAutomationDenied(_ error: FrontTab.Failure) {
        let a = NSAlert()
        a.messageText = error.errorDescription ?? "Permission needed"

        if isTranslocated {
            a.informativeText = """
            macOS is running VideoPro from a temporary copy, so it can’t ask for \
            permission and nothing appears in the Automation list.

            Move VideoPro to your Applications folder and open it from there.
            """
            a.addButton(withTitle: "Move to Applications")
            a.addButton(withTitle: "Cancel")
            if a.runModal() == .alertFirstButtonReturn {
                moveToApplications(from: Bundle.main.bundlePath)
            }
            return
        }

        a.informativeText = """
        If VideoPro is listed under Privacy & Security → Automation, switch on the \
        browser you want it to read.

        If it isn’t listed, macOS never recorded the request — ask again to bring \
        the permission prompt back.
        """
        a.addButton(withTitle: "Ask Again")
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            // Clears only our own Automation decisions, which is what makes macOS
            // prompt afresh. Same thing the user would type by hand.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", "AppleEvents", Bundle.main.bundleIdentifier ?? "com.videopro.app"]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            grabFrontTab()   // retry immediately; macOS should prompt this time
        case .alertSecondButtonReturn:
            FrontTab.openAutomationSettings()
        default:
            break
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - From the link field

    /// Take one video from the link field into the library, downloading it or
    /// just keeping it there.
    func takeLinkVideo(_ video: LinkVideo, site: String?, quality: DownloadQuality, download: Bool) {
        let item = libraryItem(for: video.entry, site: site)
        // The lookup already did what enrichment does; don't pay for it twice.
        if !video.choices.isEmpty {
            item.availableHeights = video.heights
            if !video.chapters.isEmpty { item.meta.chapters = video.chapters }
            if let p = video.playURL, let u = URL(string: p) {
                item.setPlayURL(u, expires: DownloadManager.expiry(for: p))
            }
            item.enriched = true
        } else {
            enrich(item)
        }
        saveLibrary()
        if download, item.status != .done { self.download(item, quality: quality) }
    }

    /// Take the videos picked in the link field's grid and download them all.
    func takeLinkEntries(_ entries: [LinkEntry], site: String?, quality: DownloadQuality) {
        // Added last-to-first so the list reads in the page's order with the
        // first on top, then queued first-to-last so it downloads in that order.
        let added = entries.reversed().map { libraryItem(for: $0, site: site) }.reversed()
        for item in added where item.status != .done {
            download(item, quality: quality)
        }
        saveLibrary()
    }

    /// The library's state for a link, if it's there — the grid marks videos
    /// already downloaded so they aren't fetched twice by accident.
    func libraryStatus(for url: String) -> DownloadStatus? {
        items.first { $0.meta.downloadURL == url || $0.meta.pageURL == url }?.status
    }

    /// The existing item for a link, or a new one filled in from what the
    /// lookup already knows. Not enriched: the entry carries its title,
    /// thumbnail and length, and a grid of sixty shouldn't start sixty probes.
    private func libraryItem(for entry: LinkEntry, site: String?) -> VideoItem {
        if let existing = items.first(where: { $0.meta.downloadURL == entry.url || $0.meta.pageURL == entry.url }) {
            return existing
        }
        let meta = VideoMeta(title: entry.title, pageURL: entry.url, mediaURL: "", sourceKind: "page",
                             thumbnail: entry.thumbnail ?? "", duration: entry.duration,
                             width: 0, height: 0, platform: site == "Web" ? nil : site)
        let item = VideoItem(meta)
        items.insert(item, at: 0)
        if entry.thumbnail == nil { enrich(item) }
        return item
    }

    /// Download whatever link is on the clipboard (⇧⌘V). Goes through the
    /// field so a playlist is shown for picking rather than fetched whole.
    func downloadCopiedLink() {
        let pb = NSPasteboard.general
        guard let text = pb.string(forType: .string), let link = LinkSearch.link(from: text) else {
            NSSound.beep()
            return
        }
        lastPasteboardChange = pb.changeCount
        lastOfferedLink = link
        showMainWindow()
        linkSearch.openAndDownload(link)
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Copied links

    /// The pasteboard's change count when we last looked, so coming back with
    /// the same clipboard doesn't offer the same link again. Starts unset, so a
    /// link copied before launch is offered once.
    private var lastPasteboardChange = -1
    private var lastOfferedLink: String?

    /// Offer a link the user copied elsewhere, the moment they come back.
    ///
    /// Asks the pasteboard whether it holds a web address *before* reading it.
    /// That check doesn't count as access, so the system's paste-privacy prompt
    /// can only ever appear when there's a link worth offering — never for
    /// whatever text someone happened to copy.
    func offerCopiedLink() {
        guard offerCopiedLinks, linkSearch.query.isEmpty else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastPasteboardChange else { return }
        lastPasteboardChange = pb.changeCount
        guard pb.accessBehavior != .alwaysDeny else { return }

        let webURL: PartialKeyPath<NSPasteboard.DetectedValues> = \NSPasteboard.DetectedValues.probableWebURL
        Task {
            guard let found = try? await pb.detectedPatterns(for: [webURL]), found.contains(webURL),
                  let values = try? await pb.detectedValues(for: [webURL]),
                  let link = LinkSearch.link(from: values.probableWebURL),
                  link != lastOfferedLink,
                  // Already in the library means already dealt with — including a
                  // link just copied out of it with Copy Source URL.
                  libraryStatus(for: link) == nil,
                  linkSearch.query.isEmpty
            else { return }
            lastOfferedLink = link
            linkSearch.offer(link)
        }
    }

    /// Add a video by pasting a URL directly into the app (no extension needed).
    @discardableResult
    func addURL(_ raw: String, title: String? = nil) -> VideoItem? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else {
            alert("Invalid URL", "That doesn’t look like a web address.")
            return nil
        }
        if items.contains(where: { $0.meta.downloadURL == s }) { return nil }
        // The browser's tab title beats the bare host as a placeholder — enrichment
        // will replace it with the real one shortly either way.
        let meta = VideoMeta(title: title ?? host, pageURL: s, mediaURL: "", sourceKind: "page",
                             thumbnail: "", duration: nil, width: 0, height: 0, platform: nil)
        let item = VideoItem(meta)
        items.insert(item, at: 0)
        enrich(item)
        saveLibrary()
        return item
    }

    // MARK: - Local files

    /// File types worth offering in the open panel / accepting on a drop.
    static let importableExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "ts", "m2ts",
        "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "opus",
    ]

    /// Bring files the user already has into the library.
    ///
    /// The file is referenced where it sits — deliberately not copied. Importing
    /// a 4GB movie should not silently duplicate it, and the user's own folder
    /// layout is not ours to reorganise.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [VideoItem] {
        var added: [VideoItem] = []
        for url in urls {
            guard Self.importableExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // Same file twice is almost always a mistake rather than intent.
            if items.contains(where: { $0.meta.importedPath == url.path }) { continue }
            let item = VideoItem(VideoMeta(importing: url))
            item.markDone(path: url.path)   // it's already "downloaded" — it's right there
            items.insert(item, at: 0)
            added.append(item)
            probeLocal(item)
        }
        if !added.isEmpty { saveLibrary() }
        return added
    }

    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose video or audio files to add to your library."
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    /// Fill in what we can read straight off the file: technical detail from
    /// ffprobe, then a poster frame from ffmpeg.
    func probeLocal(_ item: VideoItem) {
        guard let path = item.meta.filePath, !item.probing else { return }

        // A cached probe describes the bytes it was taken from, and nothing here
        // notices when an export or re-encode replaces them. File size is the
        // cheapest signal that it has gone stale — and it costs one stat() against
        // a subprocess, so it's worth checking every time rather than trusting the
        // cache blindly.
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let sizeOnDisk = (attrs?[.size] as? NSNumber)?.int64Value
        if let cached = item.meta.probe, cached.fileSize != nil, cached.fileSize == sizeOnDisk,
           Self.hasDisplayableThumbnail(item.thumbnail) {
            item.enriched = true
            return
        }

        item.probing = true
        Task {
            if let info = await MediaProbe.shared.probe(path: path) {
                item.meta.probe = info
                if let d = info.duration, d > 0 { item.meta.duration = d }
                if let v = info.video {
                    item.meta.width = v.width
                    item.meta.height = v.height
                    item.availableHeights = v.height > 0 ? [v.height] : []
                }
                saveLibrary()
            }
            if !Self.hasDisplayableThumbnail(item.thumbnail),
               let path = await DownloadManager.shared.generateThumbnail(for: item.meta, id: item.id) {
                item.thumbnail = path
                item.meta.thumbnail = path
                saveLibrary()
            }
            item.enriched = true
            item.probing = false
        }
    }

    /// Removing an unfinished download stops it and deletes its partial files —
    /// they'd otherwise sit in Downloads with nothing left that knows about them.
    private func abandonDownload(_ item: VideoItem) {
        if let job = JobCenter.shared.active.first(where: { $0.itemID == item.id }) {
            JobCenter.shared.cancel(job)
        }
        if let pending = item.meta.pending {
            DownloadManager.removePartials(pending.partials)
            item.meta.pending = nil
        }
    }

    func remove(_ item: VideoItem) {
        abandonDownload(item)
        items.removeAll { $0.id == item.id }
        for idx in collections.indices {
            collections[idx].ordering.removeAll { $0 == item.id }
        }
        // The generated preview frame outlives the entry otherwise; nothing else
        // ever prunes that directory.
        let thumb = DownloadManager.thumbsDirectory()
            .appendingPathComponent("\(item.id.uuidString).jpg")
        try? FileManager.default.removeItem(at: thumb)
        saveLibrary()
        saveCollections()
    }

    /// Batch remove.
    ///
    /// Not a loop over `remove(_:)` on purpose: that writes the library and the
    /// collections file once per item, so removing a selection of thirty would
    /// mean sixty disk writes and thirty `items` mutations for the list to
    /// animate through.
    func remove(_ batch: [VideoItem]) {
        guard !batch.isEmpty else { return }
        for item in batch { abandonDownload(item) }
        let ids = Set(batch.map(\.id))
        items.removeAll { ids.contains($0.id) }
        for idx in collections.indices {
            collections[idx].ordering.removeAll { ids.contains($0) }
        }
        for id in ids {
            let thumb = DownloadManager.thumbsDirectory()
                .appendingPathComponent("\(id.uuidString).jpg")
            try? FileManager.default.removeItem(at: thumb)
        }
        saveLibrary()
        saveCollections()
    }

    func clear() {
        remove(items)
    }

    // MARK: - Tiers & collections

    @Published var collections: [VideoCollection] = []

    /// How long an untouched Inbox entry survives.
    @Published var inboxExpiryDays = 14 { didSet { UserDefaults.standard.set(inboxExpiryDays, forKey: "inboxExpiryDays") } }

    /// Mark an item as deliberately kept.
    ///
    /// Called wherever the user does something that implies intent rather than
    /// asking them to curate explicitly — that's the whole point of the tier
    /// split. Downloading is *not* one of those actions: grabbing one video and
    /// downloading it is exactly the one-off case that should still tidy itself up.
    func promote(_ item: VideoItem) {
        guard item.meta.tier != .kept else { return }
        item.meta.tier = .kept
        saveLibrary()
    }

    /// Drop stale Inbox entries. **Files on disk are never touched** — this only
    /// forgets the library row, so a one-off grab leaves nothing to clean up.
    private func expireInbox() {
        let cutoff = Date().addingTimeInterval(-Double(inboxExpiryDays) * 86_400)
        let stale = items.filter {
            $0.meta.tier == .inbox && !$0.meta.isLocal && $0.meta.receivedAt < cutoff
                && !$0.status.isUnfinished && $0.meta.pending == nil
        }
        guard !stale.isEmpty else { return }
        let ids = Set(stale.map(\.id))
        items.removeAll { ids.contains($0.id) }
        for item in stale {
            let thumb = DownloadManager.thumbsDirectory()
                .appendingPathComponent("\(item.id.uuidString).jpg")
            try? FileManager.default.removeItem(at: thumb)
        }
        saveLibrary()
    }

    @discardableResult
    func createCollection(named name: String) -> VideoCollection {
        let c = VideoCollection(name: name)
        collections.append(c)
        saveCollections()
        return c
    }

    func renameCollection(_ id: UUID, to name: String) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].name = name
        saveCollections()
    }

    /// Removes the grouping, not the videos — they stay in the library.
    func deleteCollection(_ id: UUID) {
        collections.removeAll { $0.id == id }
        for item in items where item.meta.collectionIDs.contains(id) {
            item.meta.collectionIDs.removeAll { $0 == id }
        }
        saveCollections()
        saveLibrary()
    }

    func add(_ item: VideoItem, to collectionID: UUID) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if !collections[idx].ordering.contains(item.id) {
            collections[idx].ordering.append(item.id)
        }
        if !item.meta.collectionIDs.contains(collectionID) {
            item.meta.collectionIDs.append(collectionID)
        }
        promote(item)   // filing something away is intent
        saveCollections()
        saveLibrary()
    }

    func remove(_ item: VideoItem, from collectionID: UUID) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[idx].ordering.removeAll { $0 == item.id }
        item.meta.collectionIDs.removeAll { $0 == collectionID }
        saveCollections()
        saveLibrary()
    }

    private var collectionsURL: URL {
        libraryURL.deletingLastPathComponent().appendingPathComponent("collections.json")
    }

    private func saveCollections() {
        if let data = try? JSONEncoder().encode(collections) {
            try? data.write(to: collectionsURL, options: .atomic)
        }
    }

    private func loadCollections() {
        guard let data = try? Data(contentsOf: collectionsURL),
              let list = try? JSONDecoder().decode([VideoCollection].self, from: data) else { return }
        collections = list
    }

    // MARK: - Downloads

    /// Queue a download at the given quality (inherits the global embed toggles).
    /// Runs at most `maxConcurrent` at once; the rest wait their turn.
    func download(_ item: VideoItem, quality: DownloadQuality? = nil) {
        // Nothing to fetch for a file that's already on disk.
        guard !item.meta.isLocal else { return }
        guard item.status != .downloading, item.status != .queued else { return }
        // A paused or interrupted download resumes at the quality it started
        // with. A different one picks different formats, so the partial data
        // is useless and goes.
        let resumable = item.meta.pending.flatMap { DownloadQuality(rawValue: $0.quality) }
        let q = quality ?? resumable ?? defaultQuality
        if let pending = item.meta.pending, pending.quality != q.rawValue {
            DownloadManager.removePartials(pending.partials)
            item.meta.pending = nil
            item.progress = 0
        }
        item.meta.pending = PendingDownload(quality: q.rawValue, paused: false,
                                            progress: item.meta.pending?.progress ?? 0,
                                            partials: item.meta.pending?.partials ?? [])
        saveLibrary()
        item.status = .queued
        item.statusLine = item.progress > 0 ? "Queued · resumes at \(Int(item.progress * 100))%" : "Queued…"

        JobCenter.shared.enqueue(itemID: item.id, title: item.meta.title,
                                 kind: .download(q)) { [weak self] job in
            guard let self else { return false }
            // Paused or cancelled between being scheduled and starting: the job
            // is already settled, so starting yt-dlp now would orphan it.
            guard !Task.isCancelled, job.state == .running else { return false }
            job.onCancel = { DownloadManager.shared.cancel(item) }
            job.onPause = { DownloadManager.shared.pause(item) }
            try? FileManager.default.createDirectory(at: self.downloadFolder,
                                                     withIntermediateDirectories: true)
            var opts = self.options
            opts.quality = q
            // Mirrored rather than pushed: DownloadManager already reports into the
            // item, and keeping it unaware of jobs means the download path has one
            // owner of progress instead of two that can disagree.
            let progress = item.$progress.sink { job.progress = $0 }
            let detail = item.$statusLine.sink { job.detail = $0 }
            let ok = await withCheckedContinuation { cont in
                DownloadManager.shared.download(item, into: self.downloadFolder,
                                                options: opts) { cont.resume(returning: $0) }
            }
            progress.cancel()
            detail.cancel()
            if ok {
                self.onDownloadFinished(item)
            } else if item.status == .error {
                // A failure that got partway keeps its record, so Retry — or the
                // next launch, shown paused — continues it. One that never wrote
                // anything (DRM, a dead link) has nothing to continue.
                if item.meta.pending?.partials.isEmpty ?? true {
                    item.meta.pending = nil
                } else {
                    item.meta.pending?.paused = true
                    item.meta.pending?.progress = item.progress
                }
                self.saveLibrary()
            }
            return ok
        }
    }

    /// Queue every item that isn't already downloaded or in flight.
    func downloadAll() {
        for item in items where item.status == .idle || item.status == .error || item.status == .paused {
            download(item)
        }
    }

    /// Stop and throw away: the partial download goes too.
    func cancel(_ item: VideoItem) {
        guard let job = JobCenter.shared.active.first(where: { $0.itemID == item.id }) else {
            // Paused, or failed partway: no process, just files to clear up.
            guard item.status == .paused || item.meta.pending != nil else { return }
            discardPending(item)
            if item.status == .paused { item.status = .idle }
            item.statusLine = ""
            return
        }
        let wasQueued = job.state == .queued
        JobCenter.shared.cancel(job)
        discardPending(item)
        // A queued job's work never ran, so nothing has touched the item — put it
        // back to idle rather than leaving it looking like a failure.
        if wasQueued {
            item.status = .idle
            item.statusLine = ""
        }
    }

    /// Stop a download where it is. Its partial files stay, and Resume — or the
    /// download menu at the same quality — carries on from there.
    func pause(_ item: VideoItem) {
        guard let job = JobCenter.shared.active.first(where: { $0.itemID == item.id }) else { return }
        if item.meta.pending == nil, case .download(let q) = job.kind {
            item.meta.pending = PendingDownload(quality: q.rawValue, paused: true)
        }
        JobCenter.shared.pause(job)
        item.status = .paused
        item.statusLine = "Paused"
        item.meta.pending?.paused = true
        item.meta.pending?.progress = item.progress
        saveLibrary()
    }

    func resume(_ item: VideoItem) {
        guard item.status == .paused || item.meta.pending != nil else { return }
        download(item)
    }

    func pauseAll() {
        // Queued ones first, so pausing a running one doesn't hand its slot to a
        // queued download that's about to be paused anyway.
        for item in items where item.status == .queued { pause(item) }
        for item in items where item.status == .downloading { pause(item) }
    }

    func resumeAll() {
        for item in items where item.status == .paused { resume(item) }
    }

    var hasPausable: Bool { items.contains { $0.status == .downloading || $0.status == .queued } }
    var hasPaused: Bool { items.contains { $0.status == .paused } }

    /// Forget a download's partial data, deleting its files.
    private func discardPending(_ item: VideoItem) {
        if let pending = item.meta.pending {
            DownloadManager.removePartials(pending.partials)
        }
        item.meta.pending = nil
        item.progress = 0
        saveLibrary()
    }

    /// At quit: stop downloads where they are and note them, so the next launch
    /// carries on. Without this yt-dlp kept running after VideoPro quit, and its
    /// finished file never made it into the library.
    func suspendDownloadsForQuit() {
        for item in items where item.status == .downloading || item.status == .queued {
            if item.meta.pending == nil,
               let job = JobCenter.shared.active.first(where: { $0.itemID == item.id }),
               case .download(let q) = job.kind {
                item.meta.pending = PendingDownload(quality: q.rawValue, paused: false)
            }
            item.meta.pending?.paused = false
            item.meta.pending?.progress = item.progress
        }
        DownloadManager.shared.stopAllForQuit()
        // A conversion's ffmpeg would outlive us too. Cancelling stops it; the
        // original file was never touched, and the half-written copy is swept
        // up at the next launch.
        for job in JobCenter.shared.active where job.kind == .convert {
            JobCenter.shared.cancel(job)
        }
        saveLibrary()
    }

    private func onDownloadFinished(_ item: VideoItem) {
        // Persist the result so it survives relaunch, and notify.
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].meta.downloadedPath = item.outputPath
            items[idx].meta.pending = nil
            saveLibrary()
        }
        notifyComplete(item)
        convertIfUnplayable(item)
    }

    // MARK: - Notifications

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyComplete(_ item: VideoItem) {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = item.meta.title
        content.sound = .default
        let req = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    /// Fetch a video's real thumbnail + available qualities via yt-dlp. Runs once
    /// per item (on arrival, and on-demand when the download menu opens).
    func enrich(_ item: VideoItem) {
        // An imported file has no remote source; ffprobe is the right tool, not
        // yt-dlp, and asking yt-dlp to resolve "" wastes a subprocess per item.
        if item.meta.isLocal { probeLocal(item); return }
        guard !item.enriched, !item.probing else { return }
        item.probing = true

        // A direct media URL from the extension is already playable — mark it
        // ready immediately rather than making the user wait on the probe.
        if item.meta.isDirectlyPlayable, !item.meta.mediaURL.isEmpty,
           let u = URL(string: item.meta.mediaURL) {
            item.setPlayURL(u, expires: DownloadManager.expiry(for: item.meta.mediaURL))
        }

        Task {
            if let info = await DownloadManager.shared.fetchInfo(for: item.meta) {
                // Take yt-dlp's thumbnail whenever it has one, and persist it so we
                // don't refetch.
                //
                // This used to keep the extension's captured `data:` frame instead.
                // That frame is grabbed off a <canvas> the moment a <video> reports
                // readyState >= 2, so it is routinely a partly-painted image — which
                // renders as a thin bar — and once stored it was never revisited:
                // this branch skipped it, and hasDisplayableThumbnail() counted any
                // `data:` string as good, so the ffmpeg fallback below never ran
                // either. A bad capture was permanent. yt-dlp's thumbnail is also
                // full-resolution rather than the 160px canvas grab, so preferring it
                // is the better picture regardless.
                if let thumb = info.thumbnail, !thumb.isEmpty {
                    item.thumbnail = thumb
                    item.meta.thumbnail = thumb
                    saveLibrary()
                }
                item.availableHeights = info.heights
                if !info.chapters.isEmpty, item.meta.chapters != info.chapters {
                    item.meta.chapters = info.chapters
                    saveLibrary()
                }

                // Backfill a duration the extension couldn't read (MSE/blob players).
                if item.meta.duration == nil, let d = info.duration, d > 0 {
                    item.meta.duration = d
                    saveLibrary()
                }

                // Warm the player using the stream we just probed — this is what
                // makes Play instant instead of shelling out to `yt-dlp -g`.
                if let p = info.playURL, let u = URL(string: p) {
                    item.setPlayURL(u, expires: DownloadManager.expiry(for: p))
                }
            }

            // Still no image? Grab a frame from the stream with ffmpeg.
            if !Self.hasDisplayableThumbnail(item.thumbnail) {
                if let path = await DownloadManager.shared.generateThumbnail(for: item.meta, id: item.id) {
                    item.thumbnail = path
                    item.meta.thumbnail = path
                    saveLibrary()
                }
            }

            item.enriched = true
            item.probing = false
        }
    }

    private static func hasDisplayableThumbnail(_ thumb: String) -> Bool {
        if thumb.isEmpty { return false }
        // An http URL is taken on trust — AsyncImage resolves it later.
        if thumb.hasPrefix("http") { return true }
        // Everything else we can actually decode right now, so do: a `data:` frame
        // the extension truncated, or an ffmpeg JPEG that got cut off, both decode
        // to a partial image. Treat those as missing so the ffmpeg fallback below
        // gets a chance to replace them.
        return ThumbView.localImage(thumb) != nil
    }

    /// Back-compat alias used by the download menu.
    func probeQualities(_ item: VideoItem) { enrich(item) }

    func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            downloadFolder = url
            UserDefaults.standard.set(url, forKey: "downloadFolder")
        }
    }

    func revealInFinder(_ item: VideoItem) {
        let path = item.outputPath.isEmpty ? downloadFolder.path : item.outputPath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Convert / trim (ffmpeg)

    /// True when we already hold the bytes locally — the export is then instant.
    func hasLocalFile(_ item: VideoItem) -> Bool {
        guard let path = item.meta.filePath ?? (item.outputPath.isEmpty ? nil : item.outputPath)
        else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// True when we can export at all: either we have the file, or we know where
    /// to get it. Downloading first is *not* a prerequisite.
    func canExport(_ item: VideoItem) -> Bool {
        hasLocalFile(item) || !item.meta.downloadURL.isEmpty || item.meta.isLocal
    }

    /// Export a clip, GIF, or MP3. Works whether or not the video has been
    /// downloaded — if we don't have it locally, we fetch only what the export
    /// needs (just the requested section for a clip/GIF, audio-only for MP3)
    /// into a temp dir, convert, then throw the temp away.
    /// `start`/`end` are in seconds; a non-positive `end` means "whole file".
    /// Export `item` through `recipe` to `target`.
    ///
    /// The recipe is persisted rather than applied — the source is never modified,
    /// so the same edit can be re-exported to several targets later.
    func export(_ item: VideoItem, recipe: EditRecipe, target: ExportTarget) {
        guard hasLocalFile(item) || !item.meta.downloadURL.isEmpty else {
            alert("Nothing to export", "VideoPro doesn’t have a source URL for this video.")
            return
        }
        if item.meta.recipe != recipe {
            item.meta.recipe = recipe
            promote(item)        // editing is intent
            saveLibrary()
        }
        JobCenter.shared.enqueue(itemID: item.id, title: item.meta.title,
                                 kind: .export(target)) { [weak self] job in
            guard let self else { return false }
            return await self.runExportJob(item, recipe: recipe, target: target, job: job)
        }
    }

    /// Fetch-if-needed, then run the plan's passes in order, as ONE job.
    ///
    /// Both halves share a job so the export lane genuinely serialises the
    /// CPU-bound work — splitting them would let several ffmpeg encodes start the
    /// moment their fetches happened to finish together, which is slower than
    /// running them in sequence.
    private func runExportJob(_ item: VideoItem, recipe: EditRecipe,
                              target: ExportTarget, job: Job) async -> Bool {
        // ffmpeg's progress output isn't parsed today, so the bar stays honest
        // about not knowing rather than inventing a number.
        job.progress = -1

        var effective = recipe
        var input: URL
        var outputDir: URL
        var cleanup: URL?

        if hasLocalFile(item), let path = item.meta.filePath ?? (item.outputPath.isEmpty ? nil : item.outputPath) {
            input = URL(fileURLWithPath: path)
            outputDir = input.deletingLastPathComponent()
        } else {
            job.detail = "Fetching source…"
            let hasRange = recipe.inPoint != nil || recipe.outPoint != nil
            let range = hasRange ? (recipe.inPoint ?? 0, recipe.outPoint ?? .greatestFiniteMagnitude) : nil
            let format = (target == .audioMP3 ? DownloadQuality.audioMP3 : DownloadQuality.bestMP4).format
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("VideoPro-export-\(item.id.uuidString)", isDirectory: true)
            job.onCancel = { DownloadManager.shared.cancel(item) }

            let fetched: String? = await withCheckedContinuation { cont in
                DownloadManager.shared.fetchSource(item, format: format, range: range,
                                                   into: temp) { cont.resume(returning: $0) }
            }
            guard let fetched else {
                try? FileManager.default.removeItem(at: temp)
                job.detail = "Couldn’t fetch a source. DRM-protected videos can’t be exported."
                return false
            }
            input = URL(fileURLWithPath: fetched)
            outputDir = downloadFolder
            cleanup = temp
            // yt-dlp already cut the section, so drop ONLY the trim from the recipe.
            // Zeroing the whole thing here would silently discard crop, rotation,
            // speed and scale — everything else the user asked for.
            if hasRange {
                effective.inPoint = nil
                effective.outPoint = nil
            }
        }

        // The planner needs real dimensions to turn a normalised crop into pixels,
        // and the source bitrate to size a two-pass encode.
        var source = item.meta.probe
        if source == nil, effective.crop != nil || target.isSizeTargeted {
            source = await MediaProbe.shared.probe(path: input.path)
        }

        let stem = input.lastPathComponent.hasPrefix("source.")
            ? sanitizedStem(item.meta.title)
            : input.deletingPathExtension().lastPathComponent
        let out = uniqueURL(in: outputDir, name: stem + "_edit", ext: target.fileExtension)

        let plan = ExportPlan.make(input: input, output: out, recipe: effective,
                                   target: target, source: source)

        var ok = true
        for (index, args) in plan.passes.enumerated() {
            job.detail = plan.passes.count > 1
                ? "Exporting \(target.displayName)… (pass \(index + 1) of \(plan.passes.count))"
                : "Exporting \(target.displayName)…"
            ok = await withCheckedContinuation { cont in
                let handle = DownloadManager.shared.runFFmpeg(args, item: item,
                                                              label: job.detail) {
                    cont.resume(returning: $0)
                }
                job.onCancel = { handle?.stop() }
            }
            // Fail fast: a failed pass invalidates everything after it, and pass 2
            // of a two-pass encode reads statistics pass 1 never wrote.
            if !ok { break }
        }

        // Always clear the scratch: a surviving x264 pass log would be picked up by
        // the *next* export and target a bitrate computed for a different clip.
        for scratch in plan.scratchFiles { try? FileManager.default.removeItem(at: scratch) }
        if let cleanup { try? FileManager.default.removeItem(at: cleanup) }

        if ok {
            NSWorkspace.shared.activateFileViewerSelecting([plan.outputURL])
            notifyExportDone(item, target: target)
        } else {
            // No modal: the failure is in the Activity popover with a Retry button,
            // and a modal for background work interrupts whatever the user moved on to.
            job.detail = "ffmpeg couldn’t process this file."
        }
        return ok
    }

    // MARK: - Collection builder

    /// Can this collection be joined right now?
    ///
    /// Every member needs bytes on disk: joining re-encodes each clip to a shared
    /// spec, and fetching several sources mid-build would turn one job into an
    /// unbounded queue of network work with no way to report progress honestly.
    func buildReadiness(_ collection: VideoCollection) -> (ready: Bool, reason: String) {
        let members = collection.ordering.compactMap { id in items.first { $0.id == id } }
        if members.isEmpty { return (false, "This collection is empty.") }
        if members.count < 2 { return (false, "Add at least two videos to join them.") }
        let missing = members.filter { !hasLocalFile($0) }
        if !missing.isEmpty {
            return (false, "\(missing.count) video\(missing.count == 1 ? " isn’t" : "s aren’t") downloaded yet.")
        }
        return (true, "\(members.count) videos")
    }

    /// Join a collection into a single file, in the order the user arranged it.
    func buildCollection(_ collection: VideoCollection) {
        let readiness = buildReadiness(collection)
        guard readiness.ready else {
            alert("Can’t build “\(collection.name)”", readiness.reason)
            return
        }
        let members = collection.ordering.compactMap { id in items.first { $0.id == id } }
        JobCenter.shared.enqueue(itemID: collection.id, title: collection.name,
                                 kind: .buildCollection(collection.name)) { [weak self] job in
            guard let self else { return false }
            return await self.runCollectionBuild(collection, members: members, job: job)
        }
    }

    private func runCollectionBuild(_ collection: VideoCollection,
                                    members: [VideoItem], job: Job) async -> Bool {
        job.progress = 0
        job.detail = "Reading media…"

        // The spec is derived from what the clips actually are, so every one needs
        // a probe. Without it derive() falls back to a guess and an unprobed clip
        // is assumed to have audio — both silently produce a worse join.
        var clips: [(input: URL, recipe: EditRecipe, source: MediaInfo?)] = []
        for item in members {
            guard let path = item.meta.filePath ?? (item.outputPath.isEmpty ? nil : item.outputPath)
            else { job.detail = "“\(item.meta.title)” has no file."; return false }
            var info = item.meta.probe
            if info == nil {
                info = await MediaProbe.shared.probe(path: path)
                if let info { item.meta.probe = info }
            }
            clips.append((URL(fileURLWithPath: path), item.meta.recipe ?? .identity, info))
        }
        saveLibrary()

        let spec = ConcatSpec.derive(from: clips.map(\.source))
        let out = uniqueURL(in: downloadFolder, name: sanitizedStem(collection.name), ext: "mp4")
        let plan = CollectionBuildPlan.make(clips: clips, spec: spec, output: out)

        let fm = FileManager.default
        // A mid-build failure otherwise strands gigabytes of intermediates in
        // /var/folders, and nothing else ever sweeps them.
        defer { try? fm.removeItem(at: plan.workingDirectory) }

        do {
            try fm.createDirectory(at: plan.workingDirectory, withIntermediateDirectories: true)
            try plan.listFileContents.write(to: plan.listFileURL, atomically: true, encoding: .utf8)
        } catch {
            job.detail = "Couldn’t prepare a working folder."
            return false
        }

        let totalSteps = Double(plan.segments.count + 1)
        for segment in plan.segments {
            job.detail = "Normalising clip \(segment.index + 1) of \(plan.segments.count)…"
            for args in segment.passes {
                let ok = await withCheckedContinuation { cont in
                    let handle = DownloadManager.shared.runFFmpeg(args, item: members[0],
                                                                  label: job.detail) {
                        cont.resume(returning: $0)
                    }
                    job.onCancel = { handle?.stop() }
                }
                guard ok else {
                    // Name the clip: "clip 3 of 7" is the difference between a
                    // fixable problem and an opaque one.
                    job.detail = "Clip \(segment.index + 1) (\(members[segment.index].meta.title)) couldn’t be converted."
                    return false
                }
            }
            job.progress = Double(segment.index + 1) / totalSteps
        }

        job.detail = "Joining…"
        let joined = await withCheckedContinuation { cont in
            let handle = DownloadManager.shared.runFFmpeg(plan.finalPass, item: members[0],
                                                          label: "Joining…") {
                cont.resume(returning: $0)
            }
            job.onCancel = { handle?.stop() }
        }
        guard joined else { job.detail = "Couldn’t join the clips."; return false }

        job.progress = 1
        NSWorkspace.shared.activateFileViewerSelecting([plan.outputURL])
        let content = UNMutableNotificationContent()
        content.title = "Collection built"
        content.body = "\(collection.name) · \(plan.segments.count) clips"
        content.sound = .default
        // In an async context this resolves to the throwing async overload rather
        // than the completion-handler one the sync call sites use.
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        return true
    }

    /// Filename-safe stem from a video title (temp sources are all "source.mp4").
    private func sanitizedStem(_ title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = title.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = cleaned.isEmpty ? "video" : cleaned
        return String(stem.prefix(80))
    }

    private func uniqueURL(in dir: URL, name: String, ext: String) -> URL {
        var candidate = dir.appendingPathComponent("\(name).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private func notifyExportDone(_ item: VideoItem, target: ExportTarget) {
        let content = UNMutableNotificationContent()
        content.title = "Export complete"
        content.body = "\(target.displayName) · \(item.meta.title)"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.runModal()
    }

    // MARK: - Persistence (metadata only)

    private var libraryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoPro", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }

    /// Set when the library file exists but wouldn't parse. Blocks every write
    /// from that point on — see loadLibrary() for why that matters.
    private var libraryLoadFailed = false

    private func saveLibrary() {
        guard !libraryLoadFailed else { return }
        let metas = items.map(\.meta)
        if let data = try? JSONEncoder().encode(metas) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL) else { return }
        let metas: [VideoMeta]
        do {
            metas = try JSONDecoder().decode([VideoMeta].self, from: data)
        } catch {
            // A decode failure used to be indistinguishable from an empty library:
            // `items` stayed empty and the very next saveLibrary() overwrote the
            // file with `[]`, destroying it. Any schema change makes that a live
            // risk, so keep a copy and refuse to write until it's sorted out.
            let backup = libraryURL.deletingLastPathComponent()
                .appendingPathComponent("library.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: libraryURL, to: backup)
            libraryLoadFailed = true
            NSLog("VideoPro: could not read library (%@). Backed up to %@; writes disabled.",
                  error.localizedDescription, backup.path)
            alert("Couldn’t open your library",
                  "VideoPro couldn’t read its library file, so it won’t overwrite it. A copy is at:\n\n\(backup.path)")
            return
        }
        items = metas.map { VideoItem($0) }
        for item in items {
            // Restore "downloaded" state if the file is still on disk. markDone
            // also flags it ready — a local file needs no resolving.
            if let path = item.meta.downloadedPath, !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                item.markDone(path: path)
                item.meta.pending = nil
            } else if let pending = item.meta.pending {
                // Unfinished last time: paused ones wait, interrupted ones carry
                // on once start() has the tools ready.
                item.progress = pending.progress
                if pending.paused {
                    item.status = .paused
                    item.statusLine = "Paused"
                } else {
                    resumeOnLaunch.append(item)
                }
            }
        }

        // Play URLs are memory-only, so nothing is warm after a relaunch. Warm the
        // newest handful in the background — enough that the videos you're likely
        // to touch are instant, without spawning a probe for the whole library.
        // Everything else still gets enriched if it's missing a thumbnail.
        let warm = Set(items.filter { $0.status != .done }
                            .prefix(warmOnLaunchCount)
                            .map(\.id))
        for item in items where warm.contains(item.id) || item.thumbnail.isEmpty {
            enrich(item)
        }
    }
}
