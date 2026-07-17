import Foundation
import Combine
import SwiftUI
import AppKit
import UserNotifications
import SafariServices

@MainActor
final class AppState: ObservableObject {
    @Published var items: [VideoItem] = []
    @Published var serverRunning = false
    @Published var serverStatus = "Starting…"
    @Published var downloadFolder: URL
    @Published var toolsReady = false
    @Published var toolSummary = ""

    /// Last time any browser extension talked to us — the popup pings /health on
    /// every open, so this is how the setup UI can say "it's working" instead of
    /// leaving the user to guess.
    @Published var lastExtensionContact: Date?
    /// Persisted so we can distinguish "never set up" from "set up, not open right now".
    @Published var everConnected = false

    // User download preferences.
    @Published var defaultQuality: DownloadQuality = .bestMP4
    @Published var embedThumbnail = true
    @Published var embedSubtitles = true

    // Download queue
    @Published var activeDownloads = 0
    @Published var queuedCount = 0
    private var pending: [(VideoItem, DownloadQuality)] = []
    let maxConcurrent = 3

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

    let port: UInt16 = 8787
    private var server: LocalServer?

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
        self.everConnected = UserDefaults.standard.bool(forKey: "everConnected")
    }

    // MARK: - Lifecycle

    func start() {
        checkInstallLocation()
        loadLibrary()
        refreshTools()
        requestNotifications()
        startServer()

        // Only now is it safe to apply incoming URLs: loadLibrary() replaces
        // `items` wholesale, so anything added before this point would be lost.
        started = true
        let queued = pendingURLs
        pendingURLs.removeAll()
        for url in queued { handleURL(url) }
    }

    // MARK: - Extension connection status

    func noteExtensionContact() {
        lastExtensionContact = Date()
        if !everConnected {
            everConnected = true
            UserDefaults.standard.set(true, forKey: "everConnected")
        }
    }

    /// Human-readable connection state for the setup UI.
    var extensionStatus: (text: String, connected: Bool) {
        if let seen = lastExtensionContact {
            let secs = Int(Date().timeIntervalSince(seen))
            if secs < 90 { return ("Extension connected", true) }
            return ("Extension connected · last seen \(relative(secs)) ago", true)
        }
        if everConnected { return ("Set up — open the extension to reconnect", true) }
        return ("No extension connected yet", false)
    }

    private func relative(_ secs: Int) -> String {
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86_400 { return "\(secs / 3600)h" }
        return "\(secs / 86_400)d"
    }

    // MARK: - videopro:// URL scheme

    private var started = false
    private var pendingURLs: [URL] = []

    /// Handle `videopro://add?v=<base64url JSON>`.
    ///
    /// This is the Safari path. Safari won't let an extension reach 127.0.0.1, so
    /// the POST that works in Chrome always fails there. LaunchServices *will*
    /// route our registered URL scheme to us — and launch us if we're not running —
    /// so the extension encodes the payload into the URL instead. Same JSON shape
    /// as the HTTP bridge, so it reuses VideoMapper and the enrich pipeline.
    func handleURL(_ url: URL) {
        NSLog("VideoPro: handleURL fired: %@", url.absoluteString)
        guard url.scheme?.lowercased() == "videopro" else { return }
        // A cold launch delivers the URL before start() — hold it until we're ready.
        guard started else { pendingURLs.append(url); return }

        // Accept videopro://add?… and videopro:///add?… alike.
        let action = (url.host?.isEmpty == false ? url.host! : url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard action == "add" else { return }   // bare videopro:// = just focus us

        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = comps.queryItems?.first(where: { $0.name == "v" })?.value,
              let data = Self.decodeBase64URL(encoded),
              let batch = try? JSONDecoder().decode(IncomingBatch.self, from: data) else {
            return
        }
        let metas = VideoMapper.metas(from: batch)
        guard !metas.isEmpty else { return }
        // Safari can't reach the local server, so this scheme delivery is the only
        // "the extension is working" signal we'll ever get from it.
        noteExtensionContact()
        add(metas)
    }

    /// base64url → Data (the extension strips `=` padding and swaps `+/` for `-_`
    /// so the payload survives being a URL query value).
    private static func decodeBase64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    // MARK: - Install location & installer cleanup

    /// If we're running from a DMG or Downloads, offer to move to /Applications
    /// (also required for Safari to load the extension). If already installed,
    /// offer to eject leftover installer disk images.
    func checkInstallLocation() {
        let path = Bundle.main.bundlePath
        if path.hasPrefix("/Applications/") {
            offerEjectInstallers()
            return
        }
        // Only nudge real distributions — never dev builds (DerivedData/Xcode).
        guard path.hasPrefix("/Volumes/") || path.contains("/Downloads/") else { return }

        let a = NSAlert()
        a.messageText = "Move VideoPro to Applications?"
        a.informativeText = "VideoPro should live in your Applications folder. Safari also needs it there to load the extension."
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
            toolSummary = "yt-dlp: \((yt as NSString).lastPathComponent) · \(ff)"
        } else {
            toolSummary = "yt-dlp not found — install with `brew install yt-dlp`"
        }
    }

    private func startServer() {
        let server = LocalServer(port: port)
        server.onStatus = { [weak self] running, message in
            Task { @MainActor in
                self?.serverRunning = running
                self?.serverStatus = message
            }
        }
        server.onBatch = { [weak self] metas in
            Task { @MainActor in self?.add(metas) }
        }
        server.onContact = { [weak self] in
            Task { @MainActor in self?.noteExtensionContact() }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            serverRunning = false
            serverStatus = "Could not open port \(port): \(error.localizedDescription)"
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

    /// Add a video by pasting a URL directly into the app (no extension needed).
    func addURL(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else {
            alert("Invalid URL", "That doesn’t look like a web address.")
            return
        }
        if items.contains(where: { $0.meta.downloadURL == s }) { return }
        let meta = VideoMeta(title: host, pageURL: s, mediaURL: "", sourceKind: "page",
                             thumbnail: "", duration: nil, width: 0, height: 0, platform: nil)
        let item = VideoItem(meta)
        items.insert(item, at: 0)
        enrich(item)
        saveLibrary()
    }

    func remove(_ item: VideoItem) {
        items.removeAll { $0.id == item.id }
        saveLibrary()
    }

    func clear() {
        items.removeAll()
        saveLibrary()
    }

    // MARK: - Downloads

    /// Queue a download at the given quality (inherits the global embed toggles).
    /// Runs at most `maxConcurrent` at once; the rest wait their turn.
    func download(_ item: VideoItem, quality: DownloadQuality? = nil) {
        guard item.status != .downloading, item.status != .queued else { return }
        item.status = .queued
        item.statusLine = "Queued…"
        pending.append((item, quality ?? defaultQuality))
        pump()
    }

    /// Queue every item that isn't already downloaded or in flight.
    func downloadAll() {
        for item in items where item.status == .idle || item.status == .error {
            download(item)
        }
    }

    func cancel(_ item: VideoItem) {
        // Remove from the pending queue if it hasn't started yet.
        if let idx = pending.firstIndex(where: { $0.0.id == item.id }) {
            pending.remove(at: idx)
            item.status = .idle
            item.statusLine = ""
            refreshCounts()
            return
        }
        DownloadManager.shared.cancel(item)
    }

    private func pump() {
        while activeDownloads < maxConcurrent, !pending.isEmpty {
            let (item, quality) = pending.removeFirst()
            activeDownloads += 1
            try? FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
            var opts = options
            opts.quality = quality
            DownloadManager.shared.download(item, into: downloadFolder, options: opts) { [weak self] ok in
                guard let self else { return }
                self.activeDownloads = max(0, self.activeDownloads - 1)
                if ok { self.onDownloadFinished(item) }
                self.pump()
            }
        }
        refreshCounts()
    }

    private func onDownloadFinished(_ item: VideoItem) {
        // Persist the result so it survives relaunch, and notify.
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].meta.downloadedPath = item.outputPath
            saveLibrary()
        }
        notifyComplete(item)
    }

    private func refreshCounts() {
        queuedCount = pending.count
        NSApp.dockTile.badgeLabel = activeDownloads > 0 ? "\(activeDownloads)" : ""
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
                // Prefer a real captured frame (data:) from the extension; otherwise
                // use yt-dlp's thumbnail URL and persist it so we don't refetch.
                if let thumb = info.thumbnail, !thumb.isEmpty, !item.thumbnail.hasPrefix("data:") {
                    item.thumbnail = thumb
                    item.meta.thumbnail = thumb
                    saveLibrary()
                }
                item.availableHeights = info.heights

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
        if thumb.hasPrefix("data:") || thumb.hasPrefix("http") { return true }
        // Local file path — only if it still exists.
        return FileManager.default.fileExists(atPath: thumb)
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
        !item.outputPath.isEmpty && FileManager.default.fileExists(atPath: item.outputPath)
    }

    /// True when we can export at all: either we have the file, or we know where
    /// to get it. Downloading first is *not* a prerequisite.
    func canExport(_ item: VideoItem) -> Bool {
        hasLocalFile(item) || !item.meta.downloadURL.isEmpty
    }

    /// Export a clip, GIF, or MP3. Works whether or not the video has been
    /// downloaded — if we don't have it locally, we fetch only what the export
    /// needs (just the requested section for a clip/GIF, audio-only for MP3)
    /// into a temp dir, convert, then throw the temp away.
    /// `start`/`end` are in seconds; a non-positive `end` means "whole file".
    func export(_ item: VideoItem, kind: ExportKind, start: Double, end: Double) {
        // Already downloaded → cut straight from disk, no network at all.
        if hasLocalFile(item) {
            let input = URL(fileURLWithPath: item.outputPath)
            runExport(item, kind: kind, input: input,
                      outputDir: input.deletingLastPathComponent(),
                      start: start, end: end, preSliced: false, cleanup: nil)
            return
        }

        guard !item.meta.downloadURL.isEmpty else {
            alert("Nothing to export", "VideoPro doesn’t have a source URL for this video.")
            return
        }

        let hasRange = kind.usesTimeRange && end > start && start >= 0
        // MP3 needs no video track — grabbing audio-only saves a lot of bandwidth.
        let format = (kind == .audio ? DownloadQuality.audioMP3 : DownloadQuality.bestMP4).format

        item.busy = true
        item.busyLabel = "Fetching source…"
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoPro-export-\(item.id.uuidString)", isDirectory: true)

        DownloadManager.shared.fetchSource(item, format: format,
                                           range: hasRange ? (start, end) : nil,
                                           into: temp) { [weak self] path in
            guard let self else { return }
            guard let path else {
                item.busy = false
                item.busyLabel = ""
                try? FileManager.default.removeItem(at: temp)
                self.alert("Couldn’t fetch this video",
                           "VideoPro couldn’t retrieve a source to export from. DRM-protected videos can’t be exported.")
                return
            }
            // yt-dlp already cut the section for us — don't cut it twice.
            self.runExport(item, kind: kind, input: URL(fileURLWithPath: path),
                           outputDir: self.downloadFolder,
                           start: start, end: end, preSliced: hasRange, cleanup: temp)
        }
    }

    /// The ffmpeg half of an export, shared by the local and fetched paths.
    private func runExport(_ item: VideoItem, kind: ExportKind, input: URL, outputDir: URL,
                           start: Double, end: Double, preSliced: Bool, cleanup: URL?) {
        let stem = preSliced || input.lastPathComponent.hasPrefix("source.")
            ? sanitizedStem(item.meta.title)
            : input.deletingPathExtension().lastPathComponent
        let out = uniqueURL(in: outputDir, name: stem + kind.suffix, ext: kind.fileExtension)

        // If the source was fetched pre-sliced, it *is* the clip already — applying
        // the range again would cut a range out of a range.
        let hasRange = !preSliced && kind.usesTimeRange && end > start && start >= 0
        let dur = end - start

        var args = ["-y"]
        if hasRange { args += ["-ss", String(start)] }
        args += ["-i", input.path]
        if hasRange { args += ["-t", String(dur)] }

        switch kind {
        case .trim:
            args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
        case .gif:
            args += ["-vf", "fps=12,scale=480:-1:flags=lanczos", "-loop", "0"]
        case .audio:
            args += ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        }
        args.append(out.path)

        DownloadManager.shared.runFFmpeg(args, item: item, label: "Exporting \(kind.rawValue)…") { [weak self] ok in
            guard let self else { return }
            if let cleanup { try? FileManager.default.removeItem(at: cleanup) }
            if ok {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                self.notifyExportDone(item, kind: kind)
            } else {
                self.alert("Export failed", "ffmpeg couldn’t process this file.")
            }
        }
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

    private func notifyExportDone(_ item: VideoItem, kind: ExportKind) {
        let content = UNMutableNotificationContent()
        content.title = "Export complete"
        content.body = "\(kind.rawValue) · \(item.meta.title)"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Browser extension

    /// Where the unpacked extension lives.
    ///
    /// Deliberately NOT ~/Downloads: Chromium loads an unpacked extension *by
    /// path* and keeps reading from it forever, so a folder in Downloads silently
    /// breaks the extension the day the user tidies up. Application Support is
    /// stable and out of the way.
    var extensionFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoPro", isDirectory: true)
        return base.appendingPathComponent("extension", isDirectory: true)
    }

    /// Unpack the bundled extension to a stable folder. Returns the folder, or
    /// nil (after alerting) if something went wrong.
    @discardableResult
    func unpackExtension() -> URL? {
        guard let zip = Bundle.main.url(forResource: "extension", withExtension: "zip") else {
            alert("Extension not bundled",
                  "This build doesn’t include the browser extension yet. Run scripts/bundle-extension.sh and rebuild.")
            return nil
        }
        let dest = extensionFolder
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        do {
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                alert("Couldn’t unpack the extension", "ditto exited with code \(p.terminationStatus).")
                return nil
            }
        } catch {
            alert("Couldn’t unpack the extension", error.localizedDescription)
            return nil
        }
        return dest
    }

    /// Set up the extension in a specific Chromium browser: unpack, copy the
    /// folder path, reveal it in Finder, and deep-link the browser straight to
    /// its extensions page.
    func setUpExtension(in browser: BrowserTarget) {
        guard browser.kind == .chromium else {
            openSafariExtensionSettings()
            return
        }
        guard let folder = unpackExtension() else { return }

        // "Load unpacked" opens a folder picker, so put the path on the clipboard
        // (⌘⇧G pastes it) and reveal it in Finder for dragging.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder.path, forType: .string)
        NSWorkspace.shared.activateFileViewerSelecting([folder])

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([URL(string: browser.extensionsPage)!],
                                withApplicationAt: browser.appURL,
                                configuration: config) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in
                self?.alert("Couldn’t open \(browser.name)",
                            "Open \(browser.name) → Extensions and use “Load unpacked”.\n\n\(error.localizedDescription)")
            }
        }
    }

    /// Legacy entry point (onboarding/back-compat): set up the first Chromium
    /// browser we find, or fall back to just revealing the folder.
    func installExtension() {
        if let first = BrowserScan.chromiumInstalled().first {
            setUpExtension(in: first)
        } else if let folder = unpackExtension() {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            alert("No Chromium browser found",
                  "VideoPro couldn’t find Chrome, Arc, Brave, Edge, or Chromium.\n\nThe extension is unpacked at:\n\(folder.path)\n\nLoad it unpacked from your browser’s extensions page, or use Safari instead.")
        }
    }

    /// Jump straight to Safari's Extensions settings so the user can enable the
    /// bundled Safari Web Extension.
    func openSafariExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: "com.videopro.app.safari") { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.alert("Couldn’t open Safari settings",
                            "Open Safari → Settings → Extensions and enable VideoPro.\n\n\(error.localizedDescription)")
            }
        }
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

    private func saveLibrary() {
        let metas = items.map(\.meta)
        if let data = try? JSONEncoder().encode(metas) {
            try? data.write(to: libraryURL, options: .atomic)
        }
    }

    private func loadLibrary() {
        guard let data = try? Data(contentsOf: libraryURL),
              let metas = try? JSONDecoder().decode([VideoMeta].self, from: data) else { return }
        items = metas.map { VideoItem($0) }
        for item in items {
            // Restore "downloaded" state if the file is still on disk. markDone
            // also flags it ready — a local file needs no resolving.
            if let path = item.meta.downloadedPath, !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                item.markDone(path: path)
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
