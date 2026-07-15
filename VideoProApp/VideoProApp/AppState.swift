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

    // User download preferences.
    @Published var defaultQuality: DownloadQuality = .bestMP4
    @Published var embedThumbnail = true
    @Published var embedSubtitles = true

    // Download queue
    @Published var activeDownloads = 0
    @Published var queuedCount = 0
    private var pending: [(VideoItem, DownloadQuality)] = []
    let maxConcurrent = 3

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
    }

    // MARK: - Lifecycle

    func start() {
        loadLibrary()
        refreshTools()
        requestNotifications()
        startServer()
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

    /// True when an item has a finished download we can convert.
    func canExport(_ item: VideoItem) -> Bool {
        !item.outputPath.isEmpty && FileManager.default.fileExists(atPath: item.outputPath)
    }

    /// Export a downloaded file: trim to MP4, make a GIF, or extract MP3.
    /// `start`/`end` are in seconds; a non-positive `end` means "whole file".
    func export(_ item: VideoItem, kind: ExportKind, start: Double, end: Double) {
        guard canExport(item) else {
            alert("Nothing to export", "Download this video first, then convert or trim it.")
            return
        }
        let input = URL(fileURLWithPath: item.outputPath)
        let dir = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let out = uniqueURL(in: dir, name: stem + kind.suffix, ext: kind.fileExtension)

        let hasRange = kind.usesTimeRange && end > start && start >= 0
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
            if ok {
                NSWorkspace.shared.activateFileViewerSelecting([out])
                self.notifyExportDone(item, kind: kind)
            } else {
                self.alert("Export failed", "ffmpeg couldn’t process this file.")
            }
        }
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

    /// Unpack the bundled extension to ~/Downloads and guide the user through
    /// loading it unpacked in Chrome.
    func installExtension() {
        guard let zip = Bundle.main.url(forResource: "extension", withExtension: "zip") else {
            alert("Extension not bundled",
                  "This build doesn’t include the browser extension yet. Run scripts/bundle-extension.sh and rebuild.")
            return
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dest = downloads.appendingPathComponent("VideoPro Extension", isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        do {
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                alert("Couldn’t unpack the extension", "ditto exited with code \(p.terminationStatus).")
                return
            }
        } catch {
            alert("Couldn’t unpack the extension", error.localizedDescription)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([dest])
        showInstallSteps(folder: dest)
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

    private func showInstallSteps(folder: URL) {
        let a = NSAlert()
        a.messageText = "Install the VideoPro extension"
        a.informativeText = """
        Saved to: \(folder.path)

        In Chrome (or any Chromium browser):
        1.  Open  chrome://extensions
        2.  Turn on “Developer mode” (top-right)
        3.  Click “Load unpacked”
        4.  Select the “VideoPro Extension” folder
        """
        a.addButton(withTitle: "Copy “chrome://extensions”")
        a.addButton(withTitle: "Done")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("chrome://extensions", forType: .string)
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
            // Restore "downloaded" state if the file is still on disk.
            if let path = item.meta.downloadedPath, !path.isEmpty,
               FileManager.default.fileExists(atPath: path) {
                item.status = .done
                item.progress = 1
                item.outputPath = path
                item.statusLine = "Completed"
            }
            // Backfill thumbnails/qualities for restored items that don't have one.
            if item.thumbnail.isEmpty { enrich(item) }
        }
    }
}
