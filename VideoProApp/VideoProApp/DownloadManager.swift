import Foundation

/// Runs yt-dlp (with ffmpeg for muxing) as a subprocess. Not @MainActor — it
/// streams output on a background queue and hops to the main actor only to push
/// progress into the observable VideoItem.
final class DownloadManager {
    static let shared = DownloadManager()

    /// Timers only. `asyncAfter` on here costs no thread, so it stays responsive
    /// even when every probe slot is busy.
    private let timerQueue = DispatchQueue(label: "com.videopro.timers")

    /// Bounded pool for the blocking probes (`yt-dlp -J`, `yt-dlp -g`, the ffmpeg
    /// thumbnail grab). Each one parks its thread in `waitUntilExit()`.
    ///
    /// This used to be a plain `.concurrent` DispatchQueue, which meant N queued
    /// probes parked N threads — and AppState fires one probe per un-thumbnailed
    /// item on launch and one per video added, with no ceiling. Past libdispatch's
    /// ~64-thread limit the pool is exhausted and *unrelated* queues stop being
    /// serviced, including the one Foundation delivers `Process.terminationHandler`
    /// on. A finished download then never reports completion, AppState never
    /// decrements `activeDownloads`, and once three are stuck the queue is wedged
    /// for the rest of the session. An OperationQueue runs `max` at a time and
    /// parks nothing while the rest wait their turn.
    private let probeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()

    private var running: [UUID: Process] = [:]
    /// The live download's shared state, so pause and cancel can tell its
    /// termination handler *why* it stopped.
    private var runs: [UUID: RunState] = [:]
    private let lock = NSLock()

    /// Kill a download that has printed nothing for this long.
    ///
    /// yt-dlp retries internally and can spin for a very long time against a CDN
    /// that has started throttling — which is exactly what happens after a burst
    /// of downloads. It holds one of AppState's three slots the whole time, so
    /// without this a stalled transfer is indistinguishable from a permanent hang.
    static let stallTimeout: TimeInterval = 120

    /// `--cookies-from-browser` argument, or nil when the user hasn't opted in.
    ///
    /// Held here rather than threaded through every call site because *all* the
    /// yt-dlp entry points need it: a members-only video fails to probe for the
    /// same reason it fails to download. Set by AppState when the setting changes.
    var cookieSpec: String?

    /// Cookie flags for a yt-dlp invocation, empty when opted out.
    var cookieArgs: [String] {
        guard let cookieSpec else { return [] }
        return ["--cookies-from-browser", cookieSpec]
    }

    /// The JavaScript runtime yt-dlp needs for YouTube's challenges: the bundled
    /// Deno, or Homebrew's in a development build. yt-dlp only looks on PATH,
    /// and an app opened from Finder gets a PATH without Homebrew — so without
    /// this it ran runtime-less, saw fewer formats (49 of 57 on a test video),
    /// and relied on a fallback yt-dlp has deprecated.
    var denoPath: String? { locate("deno") }

    /// The environment for every yt-dlp, ffmpeg and ffprobe the app starts.
    ///
    /// The bundled static ffmpeg carries its own OpenSSL, which looks for CA
    /// certificates where its build machine kept them — a path that doesn't
    /// exist on anyone else's Mac — and recent ffmpeg verifies certificates by
    /// default. So every https input failed with "certificate verify failed":
    /// clipping a video that isn't downloaded yet, the fallback thumbnail grab,
    /// and any download yt-dlp hands to ffmpeg. macOS ships a CA bundle at
    /// /etc/ssl/cert.pem; pointing OpenSSL at it fixes all of them. yt-dlp passes
    /// its environment on to the ffmpeg it runs, so setting it there covers that
    /// path too. Homebrew's ffmpeg finds its own certificates, which is why
    /// development builds never showed this.
    nonisolated static let toolEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let bundle = "/etc/ssl/cert.pem"
        if env["SSL_CERT_FILE"] == nil, FileManager.default.fileExists(atPath: bundle) {
            env["SSL_CERT_FILE"] = bundle
        }
        return env
    }()

    /// What every yt-dlp call carries: sign-in cookies when opted in, and the
    /// JavaScript runtime when there is one.
    var commonArgs: [String] {
        var args = cookieArgs
        if let deno = denoPath { args += ["--js-runtimes", "deno:\(deno)"] }
        return args
    }

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
        let ffprobe: String?
        let deno: String?
        var ready: Bool { ytDlp != nil }
    }

    func toolStatus() -> ToolStatus {
        ToolStatus(ytDlp: ytDlpPath, ffmpeg: locate("ffmpeg"), ffprobe: locate("ffprobe"), deno: denoPath)
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

        // No `--no-part`. With it yt-dlp wrote straight to the final name, so a
        // stopped download left a truncated file that looked finished — and the
        // next attempt said "has already been downloaded" and merged the stub.
        // Writing to `.part` is also what lets a paused or interrupted download
        // carry on: run the same command again and yt-dlp continues the file.
        var args = [
            "--newline",
            "--no-playlist",
            "--restrict-filenames",
            "--embed-metadata",
            // Fail in bounded time rather than retrying forever. Defaults are 10
            // retries with backoff and no socket timeout, which against a
            // throttling CDN can stall well past any reasonable wait.
            "--socket-timeout", "30",
            "--retries", "5",
            "--fragment-retries", "5",
            // A subtitle or thumbnail that can't be fetched must not cost the
            // video. Without this, yt-dlp treats a failed subtitle as fatal, and
            // YouTube rate-limits subtitle requests (HTTP 429) far more readily
            // than video — so downloads failed outright with nothing saved. Real
            // failures (unavailable, no such format, unsupported page) still
            // exit non-zero with this on; only these extras become warnings.
            "--ignore-errors",
            "-o", folder.appendingPathComponent("%(title)s.%(ext)s").path,
        ] + commonArgs
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
                    // Pace the subtitle requests: several in quick succession is
                    // what earns a 429, and a failed subtitle aborts the video too.
                    "--sleep-subtitles", "1",
                    "--embed-subs", "--convert-subs", "srt",
                ]
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.environment = Self.toolEnvironment
        process.arguments = args + Self.target(url)
        process.currentDirectoryURL = folder

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // The pipe reader and the termination handler run on different queues, so
        // everything shared between them lives behind a lock rather than in
        // captured `var`s.
        let run = RunState()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            run.touch()
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                let line = String(raw)
                if let p = Self.parseProgress(line) {
                    Task { @MainActor in item.apply(progress: p, line: line) }
                }
                if let dest = Self.parseDestination(line) {
                    run.note(path: dest)
                }
                // Only files this run is *writing* — not "has already been
                // downloaded" — are ours to clean up if it's cancelled.
                if let r = line.range(of: "Destination: ") {
                    let writing = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                    run.noteWriting(writing)
                    Task { @MainActor in item.notePartial(writing) }
                }
                if line.contains("[DRM]") || line.contains("DRM protection") {
                    run.noteDRM()
                }
            }
        }

        // Watchdog: a download that stops producing output is killed so its slot
        // in AppState's queue is released. Without this a single stalled transfer
        // is permanent, and three of them stop the app downloading entirely.
        let watchdog = DispatchSource.makeTimerSource(queue: timerQueue)
        watchdog.schedule(deadline: .now() + 30, repeating: 30)
        watchdog.setEventHandler { [weak process] in
            guard let process, process.isRunning else { return }
            guard Date().timeIntervalSince(run.lastActivity) > Self.stallTimeout else { return }
            run.noteStalled()
            process.terminate()
            // SIGTERM is a request. If yt-dlp is wedged in a syscall it may not
            // honour it, and the slot has to come back either way.
            self.timerQueue.asyncAfter(deadline: .now() + 10) { [weak process] in
                guard let process, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
        }
        watchdog.resume()

        process.terminationHandler = { [weak self] proc in
            watchdog.cancel()
            // Drain whatever the reader hasn't picked up yet. yt-dlp prints
            // "Merging formats into ..." as its very last line, so without this the
            // final destination is frequently lost to the race between the process
            // exiting and the readability handler being scheduled — leaving the item
            // with an empty outputPath despite a successful download.
            let tail = pipe.fileHandleForReading.availableData
            if !tail.isEmpty, let text = String(data: tail, encoding: .utf8) {
                for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    if let dest = Self.parseDestination(String(raw)) { run.note(path: dest) }
                }
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            self?.forget(id)
            let ok = proc.terminationStatus == 0
            let path = run.lastPath
            if ok { Self.cleanupSidecars(mainFile: path) }
            // Only once the process has exited are its files closed and safe to
            // delete.
            if !ok && run.cancelled { Self.removePartials(run.writing) }
            let stalled = run.stalled
            let drmBlocked = run.drmBlocked
            let paused = run.paused
            Task { @MainActor in
                if ok {
                    item.markDone(path: path)
                } else if paused {
                    // AppState already shows it paused; the stop was the point.
                } else if drmBlocked {
                    item.markError("DRM-protected — can’t be downloaded")
                } else if stalled {
                    item.markError("Stalled — no data for \(Int(Self.stallTimeout))s. Try again.")
                } else if item.statusLine == "Cancelled" {
                    // cancel() already said so; don't overwrite it with the exit code.
                } else {
                    item.markError("yt-dlp failed (exit \(proc.terminationStatus))")
                }
                completion?(ok)
            }
        }

        remember(id, process, run)
        do {
            try process.run()
        } catch {
            watchdog.cancel()
            pipe.fileHandleForReading.readabilityHandler = nil
            forget(id)
            item.markError("Could not launch yt-dlp: \(error.localizedDescription)")
            completion?(false)
        }
    }

    @MainActor
    func cancel(_ item: VideoItem) {
        lock.lock(); let proc = running[item.id]; let run = runs[item.id]; lock.unlock()
        run?.noteCancelled()
        proc?.terminate()
        item.markError("Cancelled")
    }

    /// Stop a download and keep its partial files, so running it again later
    /// continues where it stopped.
    ///
    /// SIGTERM ends yt-dlp without cleanup, which is exactly right here: the
    /// `.part` file and, for streamed formats, the `.ytdl` fragment index stay
    /// on disk for the next run to pick up.
    @MainActor
    func pause(_ item: VideoItem) {
        lock.lock(); let proc = running[item.id]; let run = runs[item.id]; lock.unlock()
        run?.notePaused()
        proc?.terminate()
    }

    /// At quit: stop every download where it is, keeping partial files. Child
    /// processes outlive their parent on macOS, so without this a quit left
    /// yt-dlp running with nobody to record what it finished.
    func stopAllForQuit() {
        lock.lock()
        let all = running
        let states = runs
        lock.unlock()
        for (id, proc) in all {
            states[id]?.notePaused()
            if proc.isRunning { proc.terminate() }
        }
    }

    /// Delete what a stopped download left behind: `<file>.part`, the `.ytdl`
    /// fragment index, any `.part-FragN` pieces, and per-format intermediates
    /// (`Title.f137.mp4`) that were waiting to be merged.
    static func removePartials(_ paths: [String]) {
        let fm = FileManager.default
        for path in Set(paths) where !path.isEmpty {
            try? fm.removeItem(atPath: path + ".part")
            try? fm.removeItem(atPath: path + ".ytdl")
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let dir = url.deletingLastPathComponent()
            if let entries = try? fm.contentsOfDirectory(atPath: dir.path) {
                for e in entries where e.hasPrefix(name + ".part-Frag") {
                    try? fm.removeItem(at: dir.appendingPathComponent(e))
                }
            }
            // Only the numbered per-format pieces: a name like "Title.mp4" may
            // be a finished file from an earlier download and isn't ours.
            if name.range(of: #"\.f[0-9]+\.[A-Za-z0-9]+$"#, options: .regularExpression) != nil {
                try? fm.removeItem(at: url)
            }
        }
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
            "--newline", "--no-playlist", "--no-part", "--restrict-filenames",
            "-f", format,
            "-o", folder.appendingPathComponent("source.%(ext)s").path,
        ] + commonArgs
        if let ff = ffmpegDirectory { args += ["--ffmpeg-location", ff] }
        if let range {
            // Section downloads are cut by ffmpeg, so they need it on PATH.
            args += ["--download-sections", "*\(range.start)-\(range.end)"]
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.environment = Self.toolEnvironment
        process.arguments = args + Self.target(item.meta.downloadURL)
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

        remember(id, process)
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            forget(id)
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
        let cookies = commonArgs
        return await withCheckedContinuation { continuation in
            probeQueue.addOperation {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ytdlp)
                process.environment = Self.toolEnvironment
                // Prefer a single progressive mp4 so AVPlayer gets one stream.
                process.arguments = [
                    "-g", "-f", "b[ext=mp4]/b", "--no-playlist",
                ] + cookies + Self.target(meta.downloadURL)
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

    /// Remove the subtitle sidecars yt-dlp leaves next to the output once they're
    /// embedded ("Title.en.srt", "Title.en-orig.srt"), so the download folder
    /// stays clean. The subtitles themselves live in the video from here on.
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
                   completion: @escaping @MainActor (Bool) -> Void) -> Cancel? {
        guard let ffmpeg = locate("ffmpeg") else {
            item.markError("ffmpeg not found — bundle it or `brew install ffmpeg`.")
            completion(false)
            return nil
        }
        item.busy = true
        item.busyLabel = label

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.environment = Self.toolEnvironment
        process.arguments = args

        // Both pipes must be drained. ffmpeg writes a progress line to stderr
        // every half second or so; nobody was reading it, so on a long job the
        // 64KB pipe buffer filled and ffmpeg blocked on write() forever. The
        // termination handler then never ran, leaving `item.busy` stuck true —
        // a permanently spinning row that could never be exported again.
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let sink: @Sendable (FileHandle) -> Void = { _ = $0.availableData }
        out.fileHandleForReading.readabilityHandler = sink
        err.fileHandleForReading.readabilityHandler = sink

        process.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
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
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            item.busy = false
            item.busyLabel = ""
            completion(false)
            return nil
        }
        // Handing the caller a way to stop this is what makes cancelling an export
        // mean anything. Exports were previously unregistered entirely, so a
        // cancelled job settled while ffmpeg carried on burning CPU to completion.
        return Cancel { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
    }

    /// A one-shot stop handle for work that isn't tracked in `running` (which is
    /// keyed by item id and so can't hold two jobs for the same video).
    struct Cancel {
        let stop: () -> Void
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
        // An imported file is read straight off disk; only remote sources have to
        // be an http(s) URL. Anything else (blob:, data:) ffmpeg can't open.
        let src: String
        if let local = meta.filePath, FileManager.default.fileExists(atPath: local) {
            src = local
        } else if meta.downloadURL.hasPrefix("http") {
            src = meta.downloadURL
        } else {
            return nil
        }
        // Seeking past the end yields no frame at all, which is easy to hit on the
        // short clips people import.
        var seek = seek
        if let d = meta.duration, d > 0, seek >= d { seek = max(0, d / 2) }
        let out = Self.thumbsDirectory().appendingPathComponent("\(id.uuidString).jpg")

        return await withCheckedContinuation { continuation in
            probeQueue.addOperation {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffmpeg)
                process.environment = Self.toolEnvironment
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
                self.timerQueue.asyncAfter(deadline: .now() + 20) {
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
        var chapters: [VideoChapter] = []
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
        let cookies = commonArgs
        return await withCheckedContinuation { continuation in
            probeQueue.addOperation {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ytdlp)
                process.environment = Self.toolEnvironment
                process.arguments = ["-J", "--no-playlist", "--no-warnings"] + cookies + Self.target(meta.downloadURL)
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
        // yt-dlp gives chapters as {start_time, end_time, title}; a video with none
        // simply omits the key.
        let chapters: [VideoChapter] = ((json["chapters"] as? [[String: Any]]) ?? [])
            .compactMap { c in
                guard let start = c["start_time"] as? Double else { return nil }
                let title = (c["title"] as? String) ?? ""
                return VideoChapter(title: title.isEmpty ? "Chapter" : title,
                                    start: start, end: c["end_time"] as? Double)
            }

        return VideoInfo(
            thumbnail: json["thumbnail"] as? String,
            title: json["title"] as? String,
            duration: json["duration"] as? Double,
            heights: set.sorted(by: >),
            playURL: pickProgressiveURL(formats: formats, json: json),
            chapters: chapters
        )
    }

    /// Pick a single **muxed** (video+audio) stream out of the info JSON so Play
    /// can start instantly — without shelling out to `yt-dlp -g` a second time.
    /// Adaptive-only formats are skipped: AVPlayer can't mux two streams itself.
    static func pickProgressiveURL(formats: [[String: Any]], json: [String: Any]) -> String? {
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

    /// The address yt-dlp should fetch, as the last arguments after `--`.
    ///
    /// Without the `--`, an address that starts with a dash is read as an
    /// option — `--exec=…` would run a command. Addresses reach here from the
    /// link field, the clipboard, the library file and `videopro://` links,
    /// and not all of those are checked as tightly as the field is, so this is
    /// the one place that makes every call safe regardless of where it came from.
    static func target(_ url: String) -> [String] {
        ["--", url]
    }

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

    private func remember(_ id: UUID, _ process: Process, _ run: RunState? = nil) {
        lock.lock(); running[id] = process; runs[id] = run; lock.unlock()
    }
    private func forget(_ id: UUID) {
        lock.lock(); running[id] = nil; runs[id] = nil; lock.unlock()
    }
}

/// State shared between a subprocess's pipe reader and its termination handler.
///
/// These run on two different queues, so the plain captured `var`s this replaced
/// were a genuine data race — and one whose practical effect was losing the last
/// line of output, which is where yt-dlp reports the merged file's path.
nonisolated private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _lastPath = ""
    private var _drm = false
    private var _stalled = false
    private var _paused = false
    private var _cancelled = false
    private var _writing: [String] = []
    private var _lastActivity = Date()

    var lastPath: String { lock.lock(); defer { lock.unlock() }; return _lastPath }
    var drmBlocked: Bool { lock.lock(); defer { lock.unlock() }; return _drm }
    var stalled: Bool { lock.lock(); defer { lock.unlock() }; return _stalled }
    var paused: Bool { lock.lock(); defer { lock.unlock() }; return _paused }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var writing: [String] { lock.lock(); defer { lock.unlock() }; return _writing }
    var lastActivity: Date { lock.lock(); defer { lock.unlock() }; return _lastActivity }

    func note(path: String) { lock.lock(); _lastPath = path; lock.unlock() }
    func noteWriting(_ path: String) { lock.lock(); _writing.append(path); lock.unlock() }
    func noteDRM() { lock.lock(); _drm = true; lock.unlock() }
    func noteStalled() { lock.lock(); _stalled = true; lock.unlock() }
    func notePaused() { lock.lock(); _paused = true; lock.unlock() }
    func noteCancelled() { lock.lock(); _cancelled = true; lock.unlock() }
    func touch() { lock.lock(); _lastActivity = Date(); lock.unlock() }
}
