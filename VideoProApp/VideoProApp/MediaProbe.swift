import Foundation

// MARK: - Model

/// What ffprobe can tell us about a file on disk. Persisted on `VideoMeta`, so
/// every field is optional — a probe that only half-succeeds is still worth
/// keeping, and an older record must survive a newer ffprobe reporting more.
struct MediaInfo: Codable, Equatable, Sendable {
    var duration: Double?
    var fileSize: Int64?
    var container: String?
    var overallBitrate: Int?
    var video: VideoStreamInfo?
    var audioTracks: [AudioStreamInfo]
    var subtitleTracks: [SubtitleStreamInfo]

    init(duration: Double? = nil, fileSize: Int64? = nil, container: String? = nil,
         overallBitrate: Int? = nil, video: VideoStreamInfo? = nil,
         audioTracks: [AudioStreamInfo] = [], subtitleTracks: [SubtitleStreamInfo] = []) {
        self.duration = duration
        self.fileSize = fileSize
        self.container = container
        self.overallBitrate = overallBitrate
        self.video = video
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
    }
}

struct VideoStreamInfo: Codable, Equatable, Sendable {
    var codec: String?
    var width: Int
    var height: Int
    var fps: Double?
    var bitrate: Int?
    var pixelFormat: String?
}

struct AudioStreamInfo: Codable, Equatable, Sendable {
    var codec: String?
    var channels: Int?
    var sampleRate: Int?
    var language: String?
    var bitrate: Int?
}

struct SubtitleStreamInfo: Codable, Equatable, Sendable {
    var codec: String?
    var language: String?
    var title: String?
}

// MARK: - Probe

/// Reads technical metadata out of a local file with ffprobe.
///
/// Deliberately mirrors `DownloadManager`'s subprocess discipline rather than
/// inventing its own: the two failure modes that bit hardest there apply here
/// verbatim, and this runs against *every* item in the library on launch.
final class MediaProbe {
    static let shared = MediaProbe()

    /// Bounded, for the same reason `DownloadManager.probeQueue` is: each probe
    /// parks its thread in `waitUntilExit()`, and enrichment fires one per
    /// un-probed item with no ceiling. An unbounded concurrent queue would push
    /// libdispatch past its ~64-thread limit and starve *unrelated* queues,
    /// including the one `Process.terminationHandler` is delivered on — which is
    /// how downloads got permanently wedged. Kept at 2 so probes stay a junior
    /// partner to the download manager's 3 slots.
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .utility
        return q
    }()

    /// Timers only — `asyncAfter` here costs no thread, so the watchdog still
    /// fires when every probe slot is busy.
    private let timerQueue = DispatchQueue(label: "com.videopro.probe.timers")

    /// ffprobe on a healthy local file returns in milliseconds. Anything past
    /// this is a damaged container or a network mount that has gone away, and
    /// waiting longer never turns into an answer.
    private static let timeout: TimeInterval = 15

    /// Returns nil for anything that isn't a clean success — a missing binary,
    /// an unreadable file, a non-media file, a timeout. Callers treat "no info"
    /// as a display state, not an error to surface.
    func probe(path: String) async -> MediaInfo? {
        guard let ffprobe = DownloadManager.shared.locate("ffprobe") else { return nil }
        guard FileManager.default.isReadableFile(atPath: path) else { return nil }

        return await withCheckedContinuation { continuation in
            queue.addOperation {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: ffprobe)
                process.environment = DownloadManager.toolEnvironment
                process.arguments = [
                    "-v", "quiet",
                    "-print_format", "json",
                    "-show_format",
                    "-show_streams",
                    path,
                ]

                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                // Both pipes get drained. `-v quiet` should keep stderr empty, but
                // a corrupt file still makes ffprobe complain, and an undrained
                // pipe deadlocks the child once its 64KB buffer fills — the same
                // hang that used to strand ffmpeg exports mid-run.
                err.fileHandleForReading.readabilityHandler = { _ = $0.availableData }

                // Once-only resume: the watchdog and the normal path can both
                // reach the finish line, and resuming a continuation twice traps.
                let gate = NSLock()
                var resumed = false
                func finish(_ info: MediaInfo?) {
                    gate.lock(); defer { gate.unlock() }
                    if resumed { return }
                    resumed = true
                    err.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: info)
                }

                self.timerQueue.asyncAfter(deadline: .now() + Self.timeout) { [weak process] in
                    guard let process, process.isRunning else { return }
                    process.terminate()
                    // SIGTERM is a request; a process wedged in a syscall on a
                    // stalled mount won't honour it, and the slot has to come back.
                    self.timerQueue.asyncAfter(deadline: .now() + 5) { [weak process] in
                        guard let process, process.isRunning else { return }
                        kill(process.processIdentifier, SIGKILL)
                    }
                }

                do {
                    try process.run()
                    // Read to EOF *before* waiting: the JSON for a file with many
                    // streams can exceed the pipe buffer, and waiting first would
                    // deadlock against ffprobe blocked on write().
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { return finish(nil) }
                    finish(Self.parse(data, path: path))
                } catch {
                    finish(nil)
                }
            }
        }
    }

    // MARK: - Parsing

    static func parse(_ data: Data, path: String) -> MediaInfo? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let raw = try? decoder.decode(FFProbeOutput.self, from: data) else { return nil }

        var info = MediaInfo(
            duration: raw.format?.duration?.double,
            fileSize: raw.format?.size?.int64,
            container: raw.format?.formatName,
            overallBitrate: raw.format?.bitRate?.int
        )
        // ffprobe omits `size` for some containers; the filesystem always knows.
        if info.fileSize == nil {
            info.fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size]) as? Int64
        }

        for stream in raw.streams ?? [] {
            switch stream.codecType {
            case "video":
                // Cover art in an audio file is a "video" stream with no motion.
                // Taking it as *the* video stream would report an MP3 as 600x600
                // MJPEG, so only the first real one counts.
                guard info.video == nil, stream.disposition?.attachedPic != 1 else { continue }
                info.video = VideoStreamInfo(
                    codec: stream.codecName,
                    width: stream.width?.int ?? 0,
                    height: stream.height?.int ?? 0,
                    fps: frameRate(stream.rFrameRate) ?? frameRate(stream.avgFrameRate),
                    bitrate: stream.bitRate?.int,
                    pixelFormat: stream.pixFmt
                )
            case "audio":
                info.audioTracks.append(AudioStreamInfo(
                    codec: stream.codecName,
                    channels: stream.channels?.int,
                    sampleRate: stream.sampleRate?.int,
                    language: stream.tag("language"),
                    bitrate: stream.bitRate?.int
                ))
            case "subtitle":
                info.subtitleTracks.append(SubtitleStreamInfo(
                    codec: stream.codecName,
                    language: stream.tag("language"),
                    title: stream.tag("title")
                ))
            default:
                continue
            }
        }
        return info
    }

    /// `r_frame_rate` is a rational string — "30/1", "30000/1001", and "0/0" for
    /// streams with no meaningful rate at all.
    static func frameRate(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let parts = raw.split(separator: "/", maxSplits: 1)
        guard let first = parts.first, let num = Double(first) else { return nil }
        guard parts.count == 2 else { return num > 0 ? num : nil }
        guard let den = Double(parts[1]), den != 0 else { return nil }
        let fps = num / den
        return fps > 0 ? fps : nil
    }
}

// MARK: - ffprobe JSON

/// ffprobe quotes most numbers ("1920", "5000000") but not all of them —
/// `channels` and `width` come back bare in some builds — so every numeric field
/// goes through `Loose` rather than being typed Int and throwing the whole
/// decode away on one surprise.
private struct Loose: Decodable {
    let double: Double?

    var int: Int? { double.flatMap { $0.isFinite ? Int($0) : nil } }
    var int64: Int64? { double.flatMap { $0.isFinite ? Int64($0) : nil } }
    var string: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            double = d
            string = nil
        } else if let s = try? c.decode(String.self) {
            double = Double(s)
            string = s
        } else {
            double = nil
            string = nil
        }
    }
}

private struct FFProbeOutput: Decodable {
    let format: Format?
    let streams: [Stream]?

    struct Format: Decodable {
        let formatName: String?
        let duration: Loose?
        let size: Loose?
        let bitRate: Loose?
    }

    struct Stream: Decodable {
        let codecType: String?
        let codecName: String?
        let width: Loose?
        let height: Loose?
        let rFrameRate: String?
        let avgFrameRate: String?
        let bitRate: Loose?
        let pixFmt: String?
        let channels: Loose?
        let sampleRate: Loose?
        let tags: [String: Loose]?
        let disposition: Disposition?

        struct Disposition: Decodable {
            let attachedPic: Int?
        }

        /// Tag keys are case-inconsistent across containers — Matroska writes
        /// LANGUAGE, MP4 writes language.
        func tag(_ name: String) -> String? {
            guard let tags else { return nil }
            let hit = tags.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }
            let value = hit?.value.string ?? hit?.value.double.map { String(Int($0)) }
            guard let value, !value.isEmpty, value != "und" else { return nil }
            return value
        }
    }
}
