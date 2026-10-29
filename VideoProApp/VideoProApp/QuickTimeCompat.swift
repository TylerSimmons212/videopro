import Foundation
import AVFoundation
import VideoToolbox

/// What this Mac's own media stack — QuickTime Player, Quick Look, Finder
/// previews and VideoPro's player — can decode.
///
/// YouTube serves H.264 only up to 1080p. Above that it's AV1 or VP9, and
/// macOS decodes VP9 on no Mac and AV1 only on chips with a hardware AV1
/// decoder (M3 and later). So a 4K download plays in IINA or a browser but
/// QuickTime refuses it outright — on an M1 Pro, both AV1 and VP9 report "not
/// decodable" — and the user reasonably concludes the download is broken.
enum QuickTimeCompat {
    /// Best guess from a codec name, for labelling a quality before download.
    /// Takes the picker's names ("H.264", "AV1") or ffprobe's ("h264", "av1").
    static func canPlay(codec: String?) -> Bool {
        let c = (codec ?? "").lowercased()
        if c.hasPrefix("av1") || c.hasPrefix("av01") {
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }
        if c.hasPrefix("vp9") || c.hasPrefix("vp09") || c.hasPrefix("vp8") { return false }
        return true   // H.264, HEVC, ProRes and anything unknown: don't cry wolf
    }

    /// The definitive answer for a file: ask AVFoundation whether it can decode
    /// every video track. Audio-only files and unreadable ones count as fine —
    /// there's nothing a video conversion would fix.
    static func canPlay(fileAt url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            return true
        }
        for track in tracks {
            if (try? await track.load(.isDecodable)) == false { return false }
        }
        return true
    }

    /// Audio QuickTime plays inside an MP4 everywhere; anything else becomes AAC.
    static let playableAudio: Set<String> = ["aac", "mp3", "alac", "ac3", "eac3"]

    /// HEVC bitrate for a re-encode. Hardware HEVC needs roughly twice what AV1
    /// or VP9 spend for the same picture, so it starts there, with a floor per
    /// resolution for sources that report a low or no bitrate.
    static func hevcBitrate(for video: VideoStreamInfo?) -> Int {
        let height = video?.height ?? 1080
        let fps = video?.fps ?? 30
        var floor: Int
        switch height {
        case 2000...: floor = 20_000_000
        case 1400...: floor = 10_000_000
        case 1000...: floor = 6_000_000
        default:      floor = 3_000_000
        }
        if fps > 40 { floor = floor * 3 / 2 }
        let fromSource = (video?.bitrate ?? 0) * 2
        return min(max(fromSource, floor), 80_000_000)
    }

    /// ffmpeg arguments for the conversion. Only the main video is re-encoded,
    /// on the Mac's hardware HEVC encoder; subtitles, chapters, metadata and the
    /// embedded cover art are carried over as they are (`0:V` excludes the cover,
    /// which ffmpeg also reports as a video stream, and `disp:attached_pic` adds
    /// it back untouched).
    static func conversionArgs(input: String, output: String, info: MediaInfo?) -> [String] {
        let audioCodec = info?.audioTracks.first?.codec?.lowercased() ?? ""
        let audio = playableAudio.contains(audioCodec) ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
        let tenBit = (info?.video?.pixelFormat ?? "").contains("10")
        return [
            "-nostdin", "-y", "-i", input,
            "-map", "0:V:0", "-map", "0:a?", "-map", "0:s?", "-map", "0:disp:attached_pic?",
            "-map_metadata", "0", "-map_chapters", "0",
            "-c", "copy",
            "-c:v:0", "hevc_videotoolbox", "-b:v:0", String(hevcBitrate(for: info?.video)),
            "-tag:v:0", "hvc1", "-profile:v:0", tenBit ? "main10" : "main",
        ] + audio + [
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            output,
        ]
    }
}

extension DownloadManager {
    /// Re-encode `input` to HEVC beside it, then swap it into place so the
    /// library's path stays valid. Reports 0…1 as it goes; cancelling the task
    /// stops ffmpeg and leaves the original untouched.
    func convertForQuickTime(_ input: URL, info: MediaInfo?,
                             onProgress: @escaping @MainActor (Double) -> Void) async -> String? {
        guard let ffmpeg = locate("ffmpeg") else { return "ffmpeg not found" }
        let temp = input.deletingPathExtension().appendingPathExtension("converting.mp4")
        try? FileManager.default.removeItem(at: temp)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.environment = Self.toolEnvironment
        process.arguments = QuickTimeCompat.conversionArgs(input: input.path, output: temp.path, info: info)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        // stderr must be drained or a long encode fills the pipe and ffmpeg blocks.
        err.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
        let duration = info?.duration ?? 0
        out.fileHandleForReading.readabilityHandler = { handle in
            guard let text = String(data: handle.availableData, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") where line.hasPrefix("out_time_us=") {
                guard duration > 0, let us = Double(line.dropFirst("out_time_us=".count)) else { continue }
                let p = min(max(us / 1_000_000 / duration, 0), 1)
                Task { @MainActor in onProgress(p) }
            }
        }

        if Task.isCancelled { return "Cancelled" }
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do { try process.run() } catch { cont.resume(returning: -1) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil

        guard status == 0, !Task.isCancelled else {
            try? FileManager.default.removeItem(at: temp)
            return Task.isCancelled ? "Cancelled" : "ffmpeg exited with code \(status)"
        }
        do {
            _ = try FileManager.default.replaceItemAt(input, withItemAt: temp)
            return nil
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return error.localizedDescription
        }
    }
}

extension AppState {
    /// Half-written HEVC copies left by a conversion that quitting cut short.
    func removeAbandonedConversions() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: downloadFolder.path) else { return }
        for name in names where name.hasSuffix(".converting.mp4") {
            try? fm.removeItem(at: downloadFolder.appendingPathComponent(name))
        }
    }

    /// After a download: if this Mac's QuickTime can't play it, convert it.
    ///
    /// Decided from the file, not the codec name — an M3 plays AV1 and needs
    /// nothing, an M1 doesn't. Imported files are never touched; this only runs
    /// for what VideoPro downloaded.
    func convertIfUnplayable(_ item: VideoItem) {
        guard convertForQuickTime, !item.meta.isLocal, !item.outputPath.isEmpty else { return }
        let url = URL(fileURLWithPath: item.outputPath)
        Task {
            guard await !QuickTimeCompat.canPlay(fileAt: url) else { return }
            let info = await MediaProbe.shared.probe(path: url.path)
            let codec = info?.video?.codec?.uppercased() ?? "This video"
            JobCenter.shared.enqueue(itemID: item.id, title: item.meta.title, kind: .convert) { job in
                job.progress = 0
                item.busy = true
                item.busyLabel = "Converting \(codec) for QuickTime…"
                let task = Task {
                    await DownloadManager.shared.convertForQuickTime(url, info: info) { p in
                        job.progress = p
                        item.busyLabel = "Converting \(codec) for QuickTime… \(Int(p * 100))%"
                    }
                }
                job.onCancel = { task.cancel() }
                let failure = await task.value
                item.busy = false
                item.busyLabel = ""
                if let failure {
                    job.detail = failure
                    if failure != "Cancelled" {
                        item.statusLine = "Couldn’t convert for QuickTime — the original is kept"
                    }
                    return false
                }
                // The bytes changed under the same path: the cached probe is stale.
                item.meta.probe = nil
                item.statusLine = "Completed · converted to HEVC for QuickTime"
                return true
            }
        }
    }
}
