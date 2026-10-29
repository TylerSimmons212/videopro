import Foundation

// MARK: - What a link turned out to be

/// One video a link turned up: the video itself, or one entry of a playlist,
/// a channel tab, or a page with several videos on it.
struct LinkEntry: Identifiable, Hashable, Sendable {
    var id: String
    /// What we hand to yt-dlp to download this one video.
    var url: String
    var title: String
    var thumbnail: String?
    var duration: Double?
    var uploader: String?
    var isLive: Bool = false

    var prettyDuration: String? {
        guard let d = duration, d > 0 else { return nil }
        let s = Int(d.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

/// What one quality preset will actually produce for a single video, worked out
/// from the formats the site offers — so the picker can say "1080p · 312 MB"
/// instead of naming a preset and hoping.
///
/// The resolution here is the one the preset's format selector really picks,
/// which is not always the one in its name: the capped presets prefer H.264,
/// and YouTube serves H.264 only up to 1080p, so "2160p (4K)" yields 1080p
/// there. Presets that land on the same file are folded together.
struct QualityChoice: Identifiable, Hashable, Sendable {
    var quality: DownloadQuality
    var height: Int?            // nil for audio
    var codec: String?          // "H.264", "VP9", "AV1"… nil for audio / unknown
    var bytes: Int64?
    var approximate: Bool

    var id: String { quality.rawValue }
    var isAudio: Bool { quality.isAudioOnly }

    var label: String {
        if isAudio { return "Audio" }
        if let height { return "\(height)p" }
        return quality == .best ? "Best" : "Video"
    }

    var sizeText: String? {
        guard let bytes, bytes > 0 else { return nil }
        let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return approximate ? "~" + text : text
    }
}

/// A run of entries under one heading: a playlist, or one tab of a channel
/// (Videos, Live, Shorts).
struct LinkSection: Identifiable, Hashable, Sendable {
    var title: String
    /// Where to ask for the next page of entries.
    var url: String
    var entries: [LinkEntry]
    /// The site's own count, when it gives one.
    var total: Int?
    var hasMore: Bool

    var id: String { url.isEmpty ? title : url }
}

struct LinkVideo: Sendable {
    var entry: LinkEntry
    var choices: [QualityChoice]
    var heights: [Int]
    var chapters: [VideoChapter]
    var playURL: String?
}

struct LinkResult: Sendable {
    /// The link as the user gave it.
    var sourceURL: String
    var title: String
    var site: String?
    var uploader: String?
    /// Set when the link is one video.
    var video: LinkVideo?
    /// Set when the link holds several: one section for a playlist or page,
    /// several for a channel's tabs.
    var sections: [LinkSection] = []

    var isSingle: Bool { video != nil }
    var entryCount: Int { sections.reduce(0) { $0 + $1.entries.count } }
}

enum LinkProbeError: Error, Sendable {
    case noTool
    case failed(String)
    case cancelled

    var message: String {
        switch self {
        case .noTool: return "yt-dlp isn’t installed. Bundle it, or run `brew install yt-dlp`."
        case .failed(let why): return why
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Probing

extension DownloadManager {
    /// How many entries one look at a playlist or channel fetches. Enough to
    /// fill the grid; "Load more" asks for the next page.
    static let linkPageSize = 60

    /// Ask yt-dlp what a link is, without downloading anything.
    ///
    /// `--flat-playlist` keeps a playlist or channel quick: entries come back
    /// with their title, thumbnail and length but without resolving each one's
    /// formats, which for a channel would mean one request per video.
    /// `--no-playlist` only matters for a link that is both a video and a
    /// playlist (`watch?v=…&list=…`) — the video wins, matching what Download
    /// has always done with such a link.
    ///
    /// Cancelling the calling task terminates yt-dlp, so a link replaced by
    /// another mid-lookup stops costing anything.
    func probeLink(_ url: String, start: Int = 1) async -> Result<LinkResult, LinkProbeError> {
        guard let ytdlp = ytDlpPath else { return .failure(.noTool) }
        let pageSize = Self.linkPageSize
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = [
            "-J", "--flat-playlist", "--no-playlist", "--no-warnings",
            "--playlist-items", "\(start):\(start + pageSize - 1)",
        ] + cookieArgs + Self.target(url)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stop = ProbeStop()

        // The process runs and is drained off the main thread; only the raw bytes
        // come back, and parsing happens here on the main actor where the model
        // types live.
        let output: (out: Data, err: Data, launchError: String?) = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                    } catch {
                        cont.resume(returning: (Data(), Data(), error.localizedDescription))
                        return
                    }
                    stop.attach(process)
                    // Some extractors hang on a dead page rather than failing.
                    DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                        if process.isRunning { process.terminate() }
                    }
                    // Both pipes drained concurrently: a channel's JSON runs to
                    // megabytes, and an undrained stderr can fill and wedge it.
                    let errBox = DataBox()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global().async {
                        errBox.data = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    process.waitUntilExit()
                    cont.resume(returning: (outData, errBox.data, nil))
                }
            }
        } onCancel: {
            stop.stop()
        }

        if stop.stopped || Task.isCancelled { return .failure(.cancelled) }
        if let launchError = output.launchError {
            return .failure(.failed("Couldn’t run yt-dlp: \(launchError)"))
        }
        if let result = Self.parseLink(output.out, source: url, pageSize: pageSize) {
            return .success(result)
        }
        return .failure(.failed(Self.explain(stderr: output.err)))
    }

    /// Turn yt-dlp's last error line into something a person can act on.
    static func explain(stderr: Data) -> String {
        let text = String(data: stderr, encoding: .utf8) ?? ""
        let line = text.split(separator: "\n").last { $0.contains("ERROR:") }.map(String.init) ?? ""
        let lower = line.lowercased()
        if lower.contains("unsupported url") {
            return "No videos found at this link."
        }
        if lower.contains("drm") {
            return "This video is DRM-protected and can’t be downloaded."
        }
        if lower.contains("sign in") || lower.contains("login") || lower.contains("cookies") {
            return "This site wants you to sign in. Turn on sign-in cookies in Settings → Quick Grab, then try again."
        }
        if lower.contains("private") {
            return "This video is private."
        }
        if line.isEmpty { return "Couldn’t read this link." }
        // "ERROR: [vimeo] 76979871: Unable to …" → "Unable to …"
        var message = line.replacingOccurrences(of: "ERROR: ", with: "")
        if message.hasPrefix("["), let close = message.firstIndex(of: "]") {
            message = String(message[message.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if let colon = message.range(of: ": "), message[..<colon.lowerBound].count < 24 {
            message = String(message[colon.upperBound...])
        }
        return message
    }

    // MARK: Parsing

    static func parseLink(_ data: Data, source: String, pageSize: Int) -> LinkResult? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let site = (json["extractor_key"] as? String).map { siteName($0) }
        let uploader = (json["uploader"] as? String) ?? (json["channel"] as? String)
        let type = (json["_type"] as? String) ?? "video"

        guard type == "playlist" || json["entries"] != nil else {
            let video = parseVideo(json, source: source)
            return LinkResult(sourceURL: source, title: video.entry.title, site: site,
                              uploader: uploader, video: video)
        }

        let title = (json["title"] as? String) ?? URL(string: source)?.host ?? "Videos"
        let raw = (json["entries"] as? [[String: Any]]) ?? []

        // A channel's root comes back as a playlist of its tabs, each a playlist
        // of its own with the first page of entries already inside.
        let nested = raw.filter { ($0["_type"] as? String) == "playlist" }
        var sections: [LinkSection] = []
        if !nested.isEmpty, nested.count == raw.count {
            for tab in nested {
                let entries = parseEntries(tab["entries"])
                guard !entries.isEmpty else { continue }
                sections.append(LinkSection(
                    title: tabTitle(tab["title"] as? String, parent: title),
                    url: (tab["webpage_url"] as? String) ?? "",
                    entries: entries,
                    total: tab["playlist_count"] as? Int,
                    hasMore: entries.count >= pageSize
                ))
            }
        } else {
            let entries = parseEntries(raw)
            if !entries.isEmpty {
                sections.append(LinkSection(
                    title: title,
                    url: (json["webpage_url"] as? String) ?? source,
                    entries: entries,
                    total: json["playlist_count"] as? Int,
                    hasMore: entries.count >= pageSize
                ))
            }
        }
        guard !sections.isEmpty else { return nil }

        // A "playlist" holding exactly one video — a page with a single embed —
        // reads better as that video than as a grid of one.
        if sections.count == 1, sections[0].entries.count == 1, !sections[0].hasMore {
            let only = sections[0].entries[0]
            let video = LinkVideo(entry: only, choices: [], heights: [], chapters: [], playURL: nil)
            return LinkResult(sourceURL: source, title: only.title, site: site, uploader: uploader,
                              video: video)
        }
        return LinkResult(sourceURL: source, title: title, site: site, uploader: uploader,
                          sections: sections)
    }

    private static func parseEntries(_ value: Any?) -> [LinkEntry] {
        var seen = Set<String>()
        var list: [LinkEntry] = []
        for e in (value as? [[String: Any]]) ?? [] {
            guard let entry = parseEntry(e), seen.insert(entry.id).inserted else { continue }
            list.append(entry)
        }
        return list
    }

    private static func parseEntry(_ e: [String: Any]) -> LinkEntry? {
        let url = (e["webpage_url"] as? String) ?? (e["url"] as? String) ?? ""
        guard url.hasPrefix("http") else { return nil }
        // A playlist inside a playlist (a channel's Playlists tab) would download
        // as one job that quietly fetches dozens of videos. Leave those out.
        let ie = (e["ie_key"] as? String) ?? ""
        if ie.hasSuffix("Tab") || ie.contains("Playlist") { return nil }
        if (e["_type"] as? String) == "playlist" { return nil }

        let title = (e["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(string: url)?.lastPathComponent ?? "Untitled video"
        return LinkEntry(
            id: (e["id"] as? String) ?? url,
            url: url,
            title: title,
            thumbnail: (e["thumbnail"] as? String) ?? pickThumbnail(e["thumbnails"]),
            duration: e["duration"] as? Double,
            uploader: (e["uploader"] as? String) ?? (e["channel"] as? String),
            isLive: (e["live_status"] as? String) == "is_live" || (e["is_live"] as? Bool) == true
        )
    }

    /// The largest thumbnail up to grid size — not the full-resolution one, which
    /// on a 60-card grid means 60 needlessly large downloads.
    private static func pickThumbnail(_ value: Any?) -> String? {
        let thumbs = ((value as? [[String: Any]]) ?? []).filter { ($0["url"] as? String)?.hasPrefix("http") == true }
        let sized = thumbs.filter { (($0["width"] as? Int) ?? 0) > 0 }
        if let best = sized.filter({ ($0["width"] as? Int ?? 0) <= 720 })
            .max(by: { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }) {
            return best["url"] as? String
        }
        return thumbs.last?["url"] as? String
    }

    /// "Blender Studio - Videos" → "Videos".
    private static func tabTitle(_ raw: String?, parent: String) -> String {
        guard var t = raw, !t.isEmpty else { return "Videos" }
        if t.hasPrefix(parent + " - ") { t.removeFirst(parent.count + 3) }
        return t
    }

    /// "YoutubeTab" → "YouTube", "Generic" → nil (a site name nobody would recognise).
    static func siteName(_ extractor: String) -> String {
        let base = extractor.replacingOccurrences(of: "Tab", with: "")
            .replacingOccurrences(of: "Playlist", with: "")
        let known: [String: String] = [
            "Youtube": "YouTube", "Vimeo": "Vimeo", "Twitter": "X", "TikTok": "TikTok",
            "Instagram": "Instagram", "Facebook": "Facebook", "Reddit": "Reddit",
            "Twitch": "Twitch", "Dailymotion": "Dailymotion", "SoundCloud": "SoundCloud",
            "BiliBili": "Bilibili", "Generic": "Web",
        ]
        if let name = known[base] { return name }
        if let hit = known.first(where: { base.hasPrefix($0.key) }) { return hit.value }
        return base
    }

    // MARK: Single video

    private static func parseVideo(_ json: [String: Any], source: String) -> LinkVideo {
        let formats = (json["formats"] as? [[String: Any]]) ?? []
        let duration = json["duration"] as? Double
        let entry = LinkEntry(
            id: (json["id"] as? String) ?? source,
            url: (json["webpage_url"] as? String) ?? source,
            title: (json["title"] as? String) ?? URL(string: source)?.host ?? "Untitled video",
            thumbnail: (json["thumbnail"] as? String) ?? pickThumbnail(json["thumbnails"]),
            duration: duration,
            uploader: (json["uploader"] as? String) ?? (json["channel"] as? String),
            isLive: (json["live_status"] as? String) == "is_live" || (json["is_live"] as? Bool) == true
        )

        var heights = Set<Int>()
        for f in formats { if let h = f["height"] as? Int, h > 0 { heights.insert(h) } }
        if let h = json["height"] as? Int, h > 0 { heights.insert(h) }

        let chapters: [VideoChapter] = ((json["chapters"] as? [[String: Any]]) ?? []).compactMap { c in
            guard let start = c["start_time"] as? Double else { return nil }
            let title = (c["title"] as? String) ?? ""
            return VideoChapter(title: title.isEmpty ? "Chapter" : title, start: start,
                                end: c["end_time"] as? Double)
        }

        return LinkVideo(
            entry: entry,
            choices: qualityChoices(formats: formats, json: json, duration: duration),
            heights: heights.sorted(by: >),
            chapters: chapters,
            playURL: pickProgressiveURL(formats: formats, json: json)
        )
    }

    /// Work out, per preset, which formats yt-dlp's selector will pick and how
    /// big they are. An approximation of yt-dlp's own sort — resolution, then
    /// frame rate, then codec, then bitrate — which is what decides the picks
    /// that matter here.
    static func qualityChoices(formats: [[String: Any]], json: [String: Any],
                                           duration: Double?) -> [QualityChoice] {
        // A direct file or a single-format page: one thing to download.
        guard !formats.isEmpty else {
            let height = json["height"] as? Int
            let size = sizeOf(json, duration: duration)
            return [QualityChoice(quality: .best, height: height, codec: codecName(json["vcodec"] as? String),
                                  bytes: size.bytes, approximate: size.approx)]
        }

        // Only an explicit "none" means a stream is absent. A missing codec means
        // *unknown* — a direct file link reports no codecs at all — and yt-dlp
        // treats unknown as "may carry both". Reading it as "none" made a plain
        // MP4 link look audio-only, so its one choice was Audio and Download
        // saved an MP3.
        func isNone(_ v: Any?) -> Bool { (v as? String) == "none" }
        let video = formats.filter { !isNone($0["vcodec"]) }
        let audio = formats.filter { isNone($0["vcodec"]) && !isNone($0["acodec"]) }

        func codecRank(_ f: [String: Any]) -> Int {
            let v = ((f["vcodec"] as? String) ?? "").lowercased()
            if v.hasPrefix("av01") { return 4 }
            if v.hasPrefix("vp9") || v.hasPrefix("vp09") { return 3 }
            if v.hasPrefix("hev") || v.hasPrefix("hvc") { return 2 }
            if v.hasPrefix("avc") { return 1 }
            return 0
        }
        func rank(_ f: [String: Any]) -> (Int, Double, Int, Double) {
            ((f["height"] as? Int) ?? 0, (f["fps"] as? Double) ?? 0, codecRank(f), (f["tbr"] as? Double) ?? 0)
        }
        func bestVideo(cap: Int?, avc: Bool) -> [String: Any]? {
            // Unknown height passes any cap: every preset's selector ends in a
            // plain `b`, which takes such a format whatever the cap says.
            var pool = video.filter { cap == nil || (($0["height"] as? Int) ?? 0) <= cap! }
            if avc {
                let h264 = pool.filter { (($0["vcodec"] as? String) ?? "").hasPrefix("avc1") }
                if !h264.isEmpty { pool = h264 }
            }
            return pool.max { rank($0) < rank($1) }
        }
        func bestAudio(aac: Bool) -> [String: Any]? {
            var pool = audio
            if aac {
                let m4a = pool.filter { (($0["acodec"] as? String) ?? "").hasPrefix("mp4a") }
                if !m4a.isEmpty { pool = m4a }
            }
            return pool.max { (($0["abr"] as? Double) ?? ($0["tbr"] as? Double) ?? 0)
                            < (($1["abr"] as? Double) ?? ($1["tbr"] as? Double) ?? 0) }
        }
        func combine(_ v: [String: Any]?, _ a: [String: Any]?) -> (Int64?, Bool) {
            guard let v else { return (nil, true) }
            let vs = sizeOf(v, duration: duration)
            // A format carrying its own audio needs nothing added.
            if !isNone(v["acodec"]) { return (vs.bytes, vs.approx) }
            guard let a else { return (vs.bytes, vs.approx) }
            let s = sizeOf(a, duration: duration)
            guard let vb = vs.bytes, let ab = s.bytes else { return (vs.bytes ?? s.bytes, true) }
            return (vb + ab, vs.approx || s.approx)
        }

        var choices: [QualityChoice] = []
        var seen = Set<String>()
        for q in DownloadQuality.allCases {
            let choice: QualityChoice
            if q.isAudioOnly {
                // Converted to MP3 afterwards at yt-dlp's default VBR, which lands
                // near 128 kbit/s — so the length predicts the file better than
                // the source stream does (a 160 kbit/s Opus source is ~3× bigger).
                let bytes: Int64?
                if let d = duration, d > 0 {
                    bytes = Int64(d * 16_000)
                } else {
                    bytes = bestAudio(aac: false).flatMap { sizeOf($0, duration: duration).bytes }
                }
                choice = QualityChoice(quality: q, height: nil, codec: nil,
                                       bytes: bytes, approximate: true)
            } else {
                let avc = q != .best
                guard let v = bestVideo(cap: q.heightCap, avc: avc) else { continue }
                let size = combine(v, bestAudio(aac: avc))
                let h = (v["height"] as? Int).flatMap { $0 > 0 ? $0 : nil }
                choice = QualityChoice(quality: q, height: h,
                                       codec: codecName(v["vcodec"] as? String),
                                       bytes: size.0, approximate: size.1)
            }
            // Presets that resolve to the same file are the same choice.
            let key = "\(choice.isAudio)-\(choice.height ?? 0)-\(choice.codec ?? "")"
            if seen.insert(key).inserted { choices.append(choice) }
        }
        return choices
    }

    private static func sizeOf(_ f: [String: Any], duration: Double?) -> (bytes: Int64?, approx: Bool) {
        if let n = f["filesize"] as? Int64, n > 0 { return (n, false) }
        if let n = f["filesize"] as? Int, n > 0 { return (Int64(n), false) }
        if let n = f["filesize_approx"] as? Double, n > 0 { return (Int64(n), true) }
        if let tbr = f["tbr"] as? Double, let d = duration, tbr > 0, d > 0 {
            return (Int64(tbr * 125 * d), true)    // kbit/s → bytes
        }
        return (nil, true)
    }

    static func codecName(_ vcodec: String?) -> String? {
        let v = (vcodec ?? "").lowercased()
        if v.hasPrefix("avc") || v.hasPrefix("h264") { return "H.264" }
        if v.hasPrefix("hev") || v.hasPrefix("hvc") || v.hasPrefix("h265") { return "HEVC" }
        if v.hasPrefix("vp9") || v.hasPrefix("vp09") { return "VP9" }
        if v.hasPrefix("av01") { return "AV1" }
        return nil
    }
}

/// Carries stderr out of the reader thread.
nonisolated private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Lets a cancelled lookup stop its process whether the cancel lands before
/// yt-dlp has launched or while it runs.
nonisolated private final class ProbeStop: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var _stopped = false

    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let kill = _stopped
        lock.unlock()
        if kill, p.isRunning { p.terminate() }
    }

    func stop() {
        lock.lock()
        _stopped = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
