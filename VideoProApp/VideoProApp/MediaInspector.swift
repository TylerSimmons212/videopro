import SwiftUI

/// Read-only technical panel for one item: what the file actually *is*, as
/// opposed to what the library row says about it.
///
/// Same `Form` + `LabeledContent` construction as the settings tabs, for the same
/// reason — it's what gives macOS its aligned label column, and hand-rolled HStacks
/// drift out of alignment the moment one value wraps.
struct MediaInspectorView: View {
    let title: String
    /// nil when the item has no local file yet — a queued or failed download has
    /// nothing to probe, which is a different state from "probed and empty".
    let path: String?
    let info: MediaInfo?
    let isProbing: Bool

    var body: some View {
        Form {
            Section {
                Text(title)
                    .font(.headline)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let path {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if let info {
                details(info)
            } else {
                Section { placeholder }
            }
        }
        .formStyle(.grouped)
        .frame(width: 280)
    }

    // MARK: - Populated

    @ViewBuilder
    private func details(_ info: MediaInfo) -> some View {
        Section("File") {
            if let container = info.container {
                // format_name is a comma-joined list of every container the
                // demuxer matched ("mov,mp4,m4a,…"); the first is the real one.
                row("Container", container.split(separator: ",").first.map(String.init))
            }
            row("Duration", info.duration.map(Self.timecode))
            row("Size", info.fileSize.map {
                ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
            })
            row("Bitrate", info.overallBitrate.map(Self.bitrate))
        }

        if let video = info.video {
            Section("Video") {
                row("Codec", video.codec?.uppercased())
                row("Resolution", video.width > 0 && video.height > 0
                    ? "\(video.width) × \(video.height)" : nil)
                row("Frame rate", video.fps.map { String(format: "%.4g fps", $0) })
                row("Bitrate", video.bitrate.map(Self.bitrate))
                row("Pixel format", video.pixelFormat)
            }
        }

        if !info.audioTracks.isEmpty {
            Section(info.audioTracks.count == 1 ? "Audio" : "Audio (\(info.audioTracks.count))") {
                ForEach(Array(info.audioTracks.enumerated()), id: \.offset) { index, track in
                    LabeledContent(trackLabel(index, count: info.audioTracks.count,
                                              language: track.language)) {
                        Text(Self.audioSummary(track))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }

        if !info.subtitleTracks.isEmpty {
            Section(info.subtitleTracks.count == 1
                    ? "Subtitles" : "Subtitles (\(info.subtitleTracks.count))") {
                ForEach(Array(info.subtitleTracks.enumerated()), id: \.offset) { index, track in
                    LabeledContent(track.title
                                   ?? trackLabel(index, count: info.subtitleTracks.count,
                                                 language: track.language)) {
                        Text(track.codec?.uppercased() ?? "—")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Language when the file names one, otherwise a position — never a bare
    /// "Track 1" on a single-track file, where the number says nothing.
    private func trackLabel(_ index: Int, count: Int, language: String?) -> String {
        if let language { return language.uppercased() }
        return count == 1 ? "Track" : "Track \(index + 1)"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value {
            LabeledContent(label) {
                Text(value)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 8) {
            if isProbing {
                ProgressView()
                    .controlSize(.small)
                Text("Reading media info…")
            } else {
                Image(systemName: path == nil ? "arrow.down.circle" : "questionmark.circle")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text(path == nil
                     ? "No file yet. Download this to see its media details."
                     : "Couldn’t read media details from this file.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Formatting

    /// h:mm:ss, dropping the hours field when there isn't one.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    static func bitrate(_ bitsPerSecond: Int) -> String {
        let mbps = Double(bitsPerSecond) / 1_000_000
        return mbps >= 1
            ? String(format: "%.1f Mbps", mbps)
            : String(format: "%.0f kbps", Double(bitsPerSecond) / 1_000)
    }

    static func audioSummary(_ track: AudioStreamInfo) -> String {
        var parts: [String] = []
        if let codec = track.codec { parts.append(codec.uppercased()) }
        if let channels = track.channels { parts.append(channelName(channels)) }
        if let rate = track.sampleRate {
            parts.append(String(format: "%.4g kHz", Double(rate) / 1000))
        }
        if let bitrate = track.bitrate { parts.append(Self.bitrate(bitrate)) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private static func channelName(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(count) ch"
        }
    }
}

#Preview("Populated") {
    MediaInspectorView(
        title: "A reasonably long video title that has to wrap",
        path: "/Users/me/Movies/clip.mp4",
        info: MediaInfo(
            duration: 3725,
            fileSize: 812_345_678,
            container: "mov,mp4,m4a,3gp,3g2,mj2",
            overallBitrate: 5_400_000,
            video: VideoStreamInfo(codec: "h264", width: 1920, height: 1080,
                                   fps: 29.97, bitrate: 5_000_000, pixelFormat: "yuv420p"),
            audioTracks: [
                AudioStreamInfo(codec: "aac", channels: 2, sampleRate: 48000,
                                language: "eng", bitrate: 192_000),
                AudioStreamInfo(codec: "ac3", channels: 6, sampleRate: 48000,
                                language: "fra", bitrate: 448_000),
            ],
            subtitleTracks: [
                SubtitleStreamInfo(codec: "mov_text", language: "eng", title: nil),
            ]
        ),
        isProbing: false
    )
}

#Preview("Probing") {
    MediaInspectorView(title: "Clip", path: "/tmp/clip.mp4", info: nil, isProbing: true)
}

#Preview("No file") {
    MediaInspectorView(title: "Queued download", path: nil, info: nil, isProbing: false)
}
