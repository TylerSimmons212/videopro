import Foundation
import Combine

// MARK: - Persisted / wire data

/// Pure, Codable, Sendable description of a video. This is what travels over the
/// HTTP bridge from the extension and what we persist to disk.
struct VideoMeta: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var title: String
    var pageURL: String          // the page the video was found on (best for yt-dlp)
    var mediaURL: String         // direct src, if the extension found one
    var sourceKind: String       // file | hls | dash | audio-file | stream | platform
    var thumbnail: String        // data: URL (base64 jpeg) or http(s) URL
    var duration: Double?        // seconds
    var width: Int
    var height: Int
    var platform: String?        // "YouTube", "Vimeo", ...
    var receivedAt: Date = Date()
    var downloadedPath: String? = nil   // set once successfully downloaded

    /// The URL we hand to yt-dlp. Prefer the page URL for platform pages,
    /// otherwise fall back to the direct media URL.
    var downloadURL: String {
        if !pageURL.isEmpty && VideoMeta.isPlatformPage(pageURL) { return pageURL }
        if !mediaURL.isEmpty { return mediaURL }
        return pageURL.isEmpty ? mediaURL : pageURL
    }

    /// Can AVPlayer likely play this directly without resolving through yt-dlp?
    var isDirectlyPlayable: Bool {
        let k = sourceKind.lowercased()
        if ["file", "hls", "audio-file"].contains(k) { return mediaURL.hasPrefix("http") }
        guard mediaURL.hasPrefix("http") else { return false }
        let lower = mediaURL.lowercased()
        return lower.contains(".mp4") || lower.contains(".m3u8")
            || lower.contains(".webm") || lower.contains(".mov") || lower.contains(".m4v")
    }

    var prettyDuration: String? {
        guard let d = duration, d > 0 else { return nil }
        let s = Int(d.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    static let platformHosts: Set<String> = [
        "youtube.com", "youtu.be", "m.youtube.com", "music.youtube.com",
        "vimeo.com", "tiktok.com", "vm.tiktok.com", "instagram.com",
        "twitter.com", "x.com", "reddit.com", "old.reddit.com",
        "soundcloud.com", "twitch.tv", "facebook.com", "fb.watch",
        "bilibili.com", "dailymotion.com", "streamable.com", "vk.com",
        "ok.ru", "bsky.app", "pinterest.com", "tumblr.com",
    ]

    static func isPlatformPage(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?
            .replacingOccurrences(of: "www.", with: "")
            .lowercased() else { return false }
        return platformHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }
}

// MARK: - Live UI item

enum DownloadStatus: String, Sendable {
    case idle, queued, downloading, done, error
}

// MARK: - Download quality & options

enum DownloadQuality: String, CaseIterable, Identifiable, Sendable {
    case best        = "Best (max quality)"
    case bestMP4     = "Best MP4 (H.264)"
    case p2160       = "2160p (4K)"
    case p1440       = "1440p"
    case p1080       = "1080p"
    case p720        = "720p"
    case p480        = "480p"
    case audioMP3    = "Audio only (MP3)"

    var id: String { rawValue }
    var isAudioOnly: Bool { self == .audioMP3 }

    /// The height ceiling, if this is a capped preset (used to filter menus).
    var heightCap: Int? {
        switch self {
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720:  return 720
        case .p480:  return 480
        default:     return nil
        }
    }

    /// yt-dlp format selector.
    ///
    /// Compatible presets explicitly require **H.264 video + AAC audio** so the
    /// file plays in QuickTime, Finder Quick Look, and AVKit. (AV1/VP9 + Opus in
    /// an .mp4 — what "best" often yields on YouTube — will not.) Each ends in a
    /// plain `b` fallback so direct-file URLs (generic extractor, "unknown"
    /// codecs) still resolve.
    var format: String {
        switch self {
        case .best:
            // Max quality — may be AV1/VP9 + Opus (less compatible).
            return "bv*+ba/b"
        case .bestMP4:
            return "bv*[vcodec^=avc1]+ba[acodec^=mp4a]/b[vcodec^=avc1]/bv*+ba/b"
        case .audioMP3:
            return "ba/b"
        default:
            let h = heightCap ?? 1080
            return "bv*[vcodec^=avc1][height<=\(h)]+ba[acodec^=mp4a]"
                + "/b[vcodec^=avc1][height<=\(h)]"
                + "/bv*[height<=\(h)]+ba/b[height<=\(h)]/b"
        }
    }
}

struct DownloadOptions: Sendable {
    var quality: DownloadQuality = .bestMP4
    var embedThumbnail: Bool = true
    var embedSubtitles: Bool = true
    var subtitleLanguages: String = "en.*,en"

    static let `default` = DownloadOptions()
}

// MARK: - Export / convert

enum ExportKind: String, CaseIterable, Identifiable, Sendable {
    case trim  = "Trim (MP4)"
    case gif   = "GIF"
    case audio = "Audio (MP3)"
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .trim: return "mp4"
        case .gif: return "gif"
        case .audio: return "mp3"
        }
    }
    var suffix: String {
        switch self {
        case .trim: return "_clip"
        case .gif: return "_clip"
        case .audio: return ""
        }
    }
    var usesTimeRange: Bool { self != .audio }
}

/// Reference-type wrapper used by SwiftUI rows. Carries the immutable metadata
/// plus live download state that changes as yt-dlp runs.
@MainActor
final class VideoItem: ObservableObject, Identifiable {
    var meta: VideoMeta          // thumbnail may be upgraded after enrichment
    var id: UUID { meta.id }

    @Published var status: DownloadStatus = .idle
    @Published var progress: Double = 0        // 0...1
    @Published var statusLine: String = ""     // last human-readable line
    @Published var outputPath: String = ""     // final file once known

    /// Displayed thumbnail — starts with whatever the extension sent, then gets
    /// upgraded to yt-dlp's real thumbnail once the video is enriched.
    @Published var thumbnail: String

    // Live info probe (thumbnail + available qualities).
    @Published var availableHeights: [Int] = []
    @Published var probing = false
    @Published var enriched = false

    // ffmpeg export/convert in progress.
    @Published var busy = false
    @Published var busyLabel = ""

    init(_ meta: VideoMeta) {
        self.meta = meta
        self.thumbnail = meta.thumbnail
    }

    /// Quality presets applicable to this video, filtered by what's actually
    /// available when we've probed it.
    var qualityMenu: [DownloadQuality] {
        guard !availableHeights.isEmpty, let maxH = availableHeights.max() else {
            return DownloadQuality.allCases
        }
        return DownloadQuality.allCases.filter { q in
            guard let cap = q.heightCap else { return true }  // Best / MP4 / Audio always shown
            return cap <= maxH
        }
    }

    func apply(progress: Double, line: String) {
        self.status = .downloading
        self.progress = progress
        if !line.isEmpty { self.statusLine = line }
    }

    func markDone(path: String) {
        status = .done
        progress = 1
        if !path.isEmpty { outputPath = path }
        statusLine = "Completed"
    }

    func markError(_ message: String) {
        status = .error
        statusLine = message
    }
}

// MARK: - Incoming JSON (lenient; mirrors the extension's serialize() shape)

struct IncomingBatch: Decodable {
    var videos: [IncomingVideo]?
    var pageUrl: String?
    var pageTitle: String?
}

struct IncomingVideo: Decodable {
    var title: String?
    var label: String?
    var pageUrl: String?
    var pageTitle: String?
    var mediaUrl: String?
    var primarySrc: String?
    var srcKind: String?
    var thumbnail: String?
    var poster: String?
    var duration: Double?
    var width: Int?
    var height: Int?
    var platform: String?
}

enum VideoMapper {
    static func metas(from batch: IncomingBatch) -> [VideoMeta] {
        let batchPage = batch.pageUrl ?? ""
        let batchTitle = batch.pageTitle ?? ""
        return (batch.videos ?? []).compactMap { v in
            let page = firstNonEmpty(v.pageUrl, batchPage)
            let media = firstNonEmpty(v.mediaUrl, v.primarySrc)
            // Skip entries with nothing usable.
            guard !page.isEmpty || !media.isEmpty else { return nil }
            let title = firstNonEmpty(v.title, v.label, v.pageTitle, batchTitle, deriveTitle(page: page, media: media))
            return VideoMeta(
                title: title,
                pageURL: page,
                mediaURL: media,
                sourceKind: v.srcKind ?? "stream",
                thumbnail: firstNonEmpty(v.thumbnail, v.poster),
                duration: v.duration,
                width: v.width ?? 0,
                height: v.height ?? 0,
                platform: v.platform
            )
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String {
        for case let v? in values where !v.isEmpty { return v }
        return ""
    }

    private static func deriveTitle(page: String, media: String) -> String {
        if let host = URL(string: page.isEmpty ? media : page)?.host { return host }
        return "Untitled video"
    }
}
