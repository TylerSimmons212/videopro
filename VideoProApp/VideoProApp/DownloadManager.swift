import Foundation

/// Runs yt-dlp (with ffmpeg for muxing) as a subprocess. Not @MainActor — it
/// streams output on a background queue and hops to the main actor only to push
/// progress into the observable VideoItem.
final class DownloadManager {
    static let shared = DownloadManager()

    private let ioQueue = DispatchQueue(label: "com.videopro.downloads", attributes: .concurrent)
    private var running: [UUID: Process] = [:]
    private let lock = NSLock()

    // MARK: - Binary discovery

    /// Search order: bundled Resources/bin, then common install locations.
    private static let searchDirs: [String] = [
        // Bundled binaries first (self-contained app), then common installs.
        Bundle.main.resourceURL?.appendingPathComponent("bin").path,
        Bundle.main.resourceURL?.path,
        Bundle.main.bundlePath + "/Contents/MacOS",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ].compactMap { $0 }

    func locate(_ name: String) -> String? {
        for dir in Self.searchDirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    var ytDlpPath: String? { locate("yt-dlp") ?? locate("yt-dlp_macos") }
    var ffmpegDirectory: String? { locate("ffmpeg").map { ($0 as NSString).deletingLastPathComponent } }

    struct ToolStatus {
        let ytDlp: String?
        let ffmpeg: String?
        var ready: Bool { ytDlp != nil }
    }

    func toolStatus() -> ToolStatus {
        ToolStatus(ytDlp: ytDlpPath, ffmpeg: locate("ffmpeg"))
    }

    // MARK: - Download

    @MainActor
    func download(_ item: VideoItem, into folder: URL, options: DownloadOptions = .default,
                  completion: (@MainActor (Bool) -> Void)? = nil) {
        guard let ytdlp = ytDlpPath else {
            item.markError("yt-dlp not found. Install it or bundle it into the app.")
            completion?(false)
            return
        }
        item.status = .downloading
        item.progress = 0
        item.statusLine = "Starting…"

        let url = item.meta.downloadURL
        let id = item.id

        var args = [
            url,
            "--newline",
            "--no-playlist",
            "--no-part",
            "--restrict-filenames",
            "--embed-metadata",
            "-o", folder.appendingPathComponent("%(title)s.%(ext)s").path,
        ]
        if let ff = ffmpegDirectory {
            args += ["--ffmpeg-location", ff]
        }

        if options.quality.isAudioOnly {
            args += ["-f", options.quality.format, "-x", "--audio-format", "mp3"]
            if options.embedThumbnail { args += ["--embed-thumbnail"] }
        } else {
            args += ["-f", options.quality.format, "--merge-output-format", "mp4"]
            if options.embedThumbnail { args += ["--embed-thumbnail", "--convert-thumbnails", "jpg"] }
            if options.embedSubtitles {
                args += [
                    "--write-subs", "--write-auto-subs",
                    "--sub-langs", options.subtitleLanguages,
                    "--embed-subs", "--convert-subs", "srt",
                ]
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = args
        process.currentDirectoryURL = folder

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        var lastPath = ""
        var drmBlocked = false
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(raw)
                if let p = Self.parseProgress(line) {
                    Task { @MainActor in item.apply(progress: p, line: line) }
                }
                if let dest = Self.parseDestination(line) {
                    lastPath = dest
                }
                if line.contains("[DRM]") || line.contains("DRM protection") {
                    drmBlocked = true
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.forget(id)
            let ok = proc.terminationStatus == 0
            let path = lastPath
            if ok { Self.cleanupSidecars(mainFile: path) }
            Task { @MainActor in
                if ok {
                    item.markDone(path: path)
                } else if drmBlocked {
                    item.markError("DRM-protected — can’t be downloaded")
                } else {
                    item.markError("yt-dlp failed (exit \(proc.terminationStatus))")
                }
                completion?(ok)
            }
        }

        do {
            try process.run()
            remember(id, process)
        } catch {
            item.markError("Could not launch yt-dlp: \(error.localizedDescription)")
            completion?(false)
        }
    }

    @MainActor
    func cancel(_ item: VideoItem) {
        lock.lock(); let proc = running[item.id]; lock.unlock()
        proc?.terminate()
        item.markError("Cancelled")
    }

    // MARK: - Fetch a source to export from

    /// Grab media to convert/trim **without** adding it to the user's library.
    ///
    /// When `range` is set we ask yt-dlp for just that section, so trimming ten
    /// seconds out of an hour-long video doesn't pull down the whole hour. The
    /// returned file is then already the clip — callers must not re-cut it.
    @MainActor
    func fetchSource(_ item: VideoItem, format: String, range: (start: Double, end: Double)?,
                     into folder: URL, completion: @escaping @MainActor (String?) -> Void) {
        // Note: no markError here — an export that can't start must not leave the
        // item looking like a *download* failed. The caller surfaces the problem.
        guard let ytdlp = ytDlpPath else {
            completion(nil)
            return
        }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var args = [
            item.meta.downloadURL,
            "--newline", "--no-playlist", "--no-part", "--restrict-filenames",
            "-f", format,
            "-o", folder.appendingPathComponent("source.%(ext)s").path,
        ]
        if let ff = ffmpegDirectory { args += ["--ffmpeg-location", ff] }
        if let range {
            // Section downloads are cut by ffmpeg, so they need it on PATH.
            args += ["--download-sections", "*\(range.start)-\(range.end)"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = args
        process.currentDirectoryURL = folder

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let id = item.id

        var drmBlocked = false
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(raw)
                // Report into busyLabel — this is an export, not a library download,
                // so it must not touch the item's download status.
                if let p = Self.parseProgress(line) {
                    Task { @MainActor in item.busyLabel = "Fetching source… \(Int(p * 100))%" }
                }
                if line.contains("[DRM]") || line.contains("DRM protection") { drmBlocked = true }
            }
        }

        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.forget(id)
            let ok = proc.terminationStatus == 0 && !drmBlocked
            // Pick the file straight out of our private temp dir rather than
            // parsing stdout — the "Destination:" line varies by extractor and
            // isn't printed at all in some section-download paths.
            let file = ok ? Self.largestFile(in: folder) : nil
            Task { @MainActor in completion(file?.path) }
        }

        do {
            try process.run()
            remember(id, process)
        } catch {
            completion(nil)
        }
    }

    private static func largestFile(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        func size(_ u: URL) -> Int {
            (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return files
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .max(by: { size($0) < size($1) })
    }

    // MARK: - Resolve a playable URL (for platform pages)

    /// Returns a direct, AVPlayer-friendly URL by asking yt-dlp for it.
    func resolvePlayableURL(for meta: VideoMeta) async -> URL? {
        guard let ytdlp = ytDlpPath else { return nil }
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ytdlp)
                // Prefer a single progressive mp4 so AVPlayer gets one stream.
                process.arguments = [
                    "-g", "-f", "b[ext=mp4]/b", "--no-playlist", meta.downloadURL,
                ]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let first = String(data: data, encoding: .utf8)?
                        .split(separator: "\n").first.map(String.init) ?? ""
                    continuation.resume(returning: URL(string: first.trimmingCharacters(in: .whitespaces)))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Remove sidecar subtitle files yt-dlp leaves next to the output once subs
    /// are embedded (e.g. "Title.en.srt", "Title.en-orig.srt"), so the folder
    /// stays clean.
    static func cleanupSidecars(mainFile: String) {
        guard !mainFile.isEmpty else { return }
        let url = URL(fileURLWithPath: mainFile)
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let subExts: Set<String> = ["srt", "vtt", "ass", "lrc"]
        let fm = FileManager.default
        guard !stem.isEmpty,
              let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where subExts.contains(entry.pathExtension.lowercased()) {
            if entry.lastPathComponent.hasPrefix(stem) {
                try? fm.removeItem(at: entry)
            }
        }
    }

    // MARK: - Run an ffmpeg export/convert job

    @MainActor
    func runFFmpeg(_ args: [String], item: VideoItem, label: String,
                   completion: @escaping @MainActor (Bool) -> Void) {
        guard let ffmpeg = locate("ffmpeg") else {
            item.markError("ffmpeg not found — bundle it or `brew install ffmpeg`.")
            completion(false)
            return
        }
        item.busy = true
        item.busyLabel = label

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { proc in
            let ok = proc.terminationStatus == 0
            Task { @MainActor in
                item.busy = false
                item.busyLabel = ""
                completion(ok)
            }
        }
        do {
            try process.run()
        } catch {
            item.busy = false
            item.busyLabel = ""
            completion(false)
        }
    }

    // MARK: - Generate a thumbnail with ffmpeg

    /// Directory where generated preview frames live.
    static func thumbsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoPro/thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Grab a single representative frame from the stream with ffmpeg and save it
    /// as a JPEG. Works for http(s) MP4/HLS/DASH; returns the file path, or nil for
    /// blob/DRM/unreachable sources. Best-effort with a hard timeout.
    func generateThumbnail(for meta: VideoMeta, id: UUID, seek: Double = 3) async -> String? {
        guard let ffmpeg = locate("ffmpeg") else { return nil }
        let src = meta.downloadURL
        guard src.hasPrefix("http") else { return nil }
        let out = Self.thumbsDirectory().appendingPathComponent("\(id.uuidString).jpg")

        return await withCheckedContinuation { continuation in
            ioQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.arguments = [
                    "-y", "-nostdin",
                    "-ss", String(seek),
                    "-i", src,
                    "-frames:v", "1",
                    "-vf", "scale=400:-2",
                    "-q:v", "5",
                    out.path,
                ]
                process.standardOutput = Pipe()
                process.standardError = Pipe()

                var finished = false
                let lock = NSLock()
                func resumeOnce(_ value: String?) {
                    lock.lock(); defer { lock.unlock() }
                    if finished { return }
                    finished = true
                    continuation.resume(returning: value)
                }
                // Hard timeout so a slow/huge source can't hang enrichment.
                self.ioQueue.asyncAfter(deadline: .now() + 20) {
                    if process.isRunning { process.terminate() }
                }
                do {
                    try process.run()
                    process.waitUntilExit()
                    let ok = process.terminationStatus == 0
                        && FileManager.default.fileExists(atPath: out.path)
                    resumeOnce(ok ? out.path : nil)
                } catch {
                    resumeOnce(nil)
                }
            }
        }
    }

    // MARK: - Probe video info (thumbnail + qualities)

    struct VideoInfo: Sendable {
        var thumbnail: String?
        var title: String?
        var duration: Double?
        var heights: [Int]
        var playURL: String?     // a muxed stream AVPlayer can open directly
    }

    /// Signed CDN URLs (googlevideo & friends) are time-limited. Trust the URL's
    /// own `expire` hint when it has one; otherwise assume a conservative hour.
    static func expiry(for urlString: String) -> Date {
        if let comps = URLComponents(string: urlString),
           let item = comps.queryItems?.first(where: { $0.name == "expire" || $0.name == "expires" }),
           let secs = item.value.flatMap(Double.init), secs > 1_000_000_000 {
            return Date(timeIntervalSince1970: secs).addingTimeInterval(-60)  // safety margin
        }
        return Date().addingTimeInterval(3600)
    }

    /// Ask yt-dlp (`-J`) for a video's real thumbnail, title, duration, and the
    /// distinct heights it offers. Best-effort; nil on failure.
    func fetchInfo(for meta: VideoMeta) async -> VideoInfo? {
        guard let ytdlp = ytDlpPath else { return nil }
        return await withCheckedContinuation { continuation in
            ioQueue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ytdlp)
                process.arguments = ["-J", "--no-playlist", "--no-warnings", meta.downloadURL]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: Self.parseInfo(from: data))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func parseInfo(from data: Data) -> VideoInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let formats = (json["formats"] as? [[String: Any]]) ?? []
        var set = Set<Int>()
        for f in formats {
            if let h = f["height"] as? Int, h > 0 { set.insert(h) }
        }
        if let h = json["height"] as? Int, h > 0 { set.insert(h) }
        return VideoInfo(
            thumbnail: json["thumbnail"] as? String,
            title: json["title"] as? String,
            duration: json["duration"] as? Double,
            heights: set.sorted(by: >),
            playURL: pickProgressiveURL(formats: formats, json: json)
        )
    }

    /// Pick a single **muxed** (video+audio) stream out of the info JSON so Play
    /// can start instantly — without shelling out to `yt-dlp -g` a second time.
    /// Adaptive-only formats are skipped: AVPlayer can't mux two streams itself.
    private static func pickProgressiveURL(formats: [[String: Any]], json: [String: Any]) -> String? {
        func rank(_ f: [String: Any]) -> (Int, Int) {
            let ext = (f["ext"] as? String)?.lowercased() ?? ""
            // Prefer mp4/mov (H.264) — universally playable in AVKit — then resolution.
            let compat = (ext == "mp4" || ext == "m4v" || ext == "mov") ? 1 : 0
            return (compat, (f["height"] as? Int) ?? 0)
        }
        let playable = formats.filter { f in
            guard let u = f["url"] as? String, u.hasPrefix("http") else { return false }
            let v = (f["vcodec"] as? String) ?? "none"
            let a = (f["acodec"] as? String) ?? "none"
            guard v != "none", a != "none" else { return false }   // must carry both
            let ext = (f["ext"] as? String)?.lowercased() ?? ""
            let isHLS = ((f["protocol"] as? String) ?? "").hasPrefix("m3u8")
            return isHLS || ["mp4", "m4v", "mov", "webm"].contains(ext)
        }
        if let best = playable.max(by: { rank($0) < rank($1) }), let u = best["url"] as? String {
            return u
        }
        // Direct files and HLS manifests report one top-level url and no formats.
        if let u = json["url"] as? String, u.hasPrefix("http") { return u }
        return nil
    }

    // MARK: - Parsing helpers

    /// Parse "[download]  42.3% of ..." into 0...1.
    static func parseProgress(_ line: String) -> Double? {
        guard line.contains("[download]"), let pctRange = line.range(of: "%") else { return nil }
        let before = line[line.startIndex..<pctRange.lowerBound]
        guard let token = before.split(whereSeparator: { $0 == " " }).last,
              let value = Double(token) else { return nil }
        return min(max(value / 100.0, 0), 1)
    }

    /// Capture the destination filename from yt-dlp/ffmpeg output.
    static func parseDestination(_ line: String) -> String? {
        if let r = line.range(of: "Destination: ") {
            return String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        if let r = line.range(of: "Merging formats into \"") {
            let rest = line[r.upperBound...]
            if let end = rest.firstIndex(of: "\"") { return String(rest[rest.startIndex..<end]) }
        }
        if let r = line.range(of: "has already been downloaded") {
            _ = r
            // e.g. [download] /path/file.mp4 has already been downloaded
            if let dr = line.range(of: "] ") {
                let rest = line[dr.upperBound...]
                if let hr = rest.range(of: " has already") {
                    return String(rest[rest.startIndex..<hr.lowerBound])
                }
            }
        }
        return nil
    }

    // MARK: - Process registry

    private func remember(_ id: UUID, _ process: Process) {
        lock.lock(); running[id] = process; lock.unlock()
    }
    private func forget(_ id: UUID) {
        lock.lock(); running[id] = nil; lock.unlock()
    }
}
