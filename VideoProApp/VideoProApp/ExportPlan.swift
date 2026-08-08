import Foundation

// MARK: - Target

/// What the user is exporting *for*. Deliberately phrased as destinations rather
/// than codec settings — "Reel" and "under 10MB" are the things people actually
/// ask for, and both decompose into codec settings the planner derives.
enum ExportTarget: Equatable, Sendable, Identifiable, CaseIterable {
    /// H.264 + AAC at the source's resolution.
    case mp4
    /// H.264 + AAC with the height capped (720/1080/…). Never upscales.
    case mp4Height(Int)
    case gif
    case audioMP3
    case proRes
    /// 9:16 vertical, 1080x1920, for Reels/Shorts/TikTok.
    case reel
    /// Two-pass, aimed at a file size.
    case underSize(megabytes: Double)

    /// Associated values mean this can't be synthesised. These are the presets the
    /// UI offers; the parameterised cases stay constructible with other values for
    /// callers that need them (a Discord 8MB limit, a 1440p master).
    static var allCases: [ExportTarget] {
        [.mp4, .mp4Height(1080), .mp4Height(720), .reel, .gif, .audioMP3, .proRes,
         .underSize(megabytes: 10)]
    }

    var id: String {
        switch self {
        case .mp4: return "mp4"
        case .mp4Height(let h): return "mp4-\(h)"
        case .gif: return "gif"
        case .audioMP3: return "mp3"
        case .proRes: return "prores"
        case .reel: return "reel"
        case .underSize(let mb): return "size-\(mb)"
        }
    }

    var displayName: String {
        switch self {
        case .mp4: return "MP4 (source quality)"
        case .mp4Height(let h): return "MP4 \(h)p"
        case .gif: return "GIF"
        case .audioMP3: return "Audio (MP3)"
        case .proRes: return "ProRes (editing master)"
        case .reel: return "Reel / Short (9:16)"
        case .underSize(let mb):
            // Trailing ".0" on the common whole-number case reads as a bug.
            let n = mb.rounded() == mb ? String(Int(mb)) : String(format: "%.1f", mb)
            return "Fit under \(n) MB"
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4, .mp4Height, .reel, .underSize: return "mp4"
        case .gif: return "gif"
        case .audioMP3: return "mp3"
        case .proRes: return "mov"
        }
    }

    /// Targets whose output has no picture. Lets the planner skip the entire
    /// video-filter chain rather than building one and then discarding it.
    var isAudioOnly: Bool { self == .audioMP3 }
}

// MARK: - Plan

/// A rendered `EditRecipe` — the ffmpeg invocations that produce one output file.
///
/// Building this as data rather than running it inline is the point of M5: the
/// same recipe has to be replayable against several targets, a plan has to be
/// inspectable in a bug report, and two-pass targets need the caller to run N
/// processes in sequence and only claim success after the last one.
struct ExportPlan {
    /// One ffmpeg invocation per element, run in order. Two-pass targets emit two.
    /// A non-zero exit from *any* pass invalidates the output; the caller must not
    /// continue to the next pass.
    let passes: [[String]]

    let outputURL: URL

    /// Temporary artefacts the passes write (GIF palette, x264 first-pass log).
    /// Surfaced so the caller can delete them — ffmpeg leaves them behind, and the
    /// pass log in particular will be silently reused by the *next* export if it
    /// survives, producing a bitrate aimed at the previous clip's duration.
    let scratchFiles: [URL]

    var isTwoPass: Bool { passes.count > 1 }

    // MARK: - Planning

    static func make(input: URL, output: URL, recipe: EditRecipe,
                     target: ExportTarget, source: MediaInfo?) -> ExportPlan {
        // Remux-only fast path. Safe *because* the recipe is identity: a stream
        // copy can only cut on keyframes, so a copy of a trimmed recipe would
        // silently start at the nearest preceding keyframe — up to several seconds
        // early — and no amount of flag-tuning fixes that. Identity has no cut to
        // make, so there is nothing to be inaccurate about. Every other path
        // re-encodes and is frame-accurate.
        if target == .mp4, recipe.isIdentity {
            return ExportPlan(
                passes: [["-y", "-i", input.path,
                          "-c", "copy",
                          "-movflags", "+faststart",
                          output.path]],
                outputURL: output,
                scratchFiles: [])
        }

        let trim = trimArgs(recipe)
        let audio = audioArgs(recipe, target: target)
        let vf = videoFilterChain(recipe, target: target, source: source)

        switch target {
        case .gif:
            return gifPlan(input: input, output: output, trim: trim, chain: vf ?? "fps=15")

        case .underSize(let megabytes):
            return sizeTargetedPlan(input: input, output: output, recipe: recipe,
                                    trim: trim, vf: vf, audio: audio,
                                    megabytes: megabytes, source: source)

        case .audioMP3:
            // `-vn` before the codec flags so a source with cover art doesn't get
            // the still image muxed into the MP3 as a video stream.
            var args = ["-y"] + trim + ["-i", input.path, "-vn"] + audio
            args.append(output.path)
            return ExportPlan(passes: [args], outputURL: output, scratchFiles: [])

        case .proRes:
            var args = ["-y"] + trim + ["-i", input.path]
            if let vf { args += ["-vf", vf] }
            args += ["-c:v", "prores_ks", "-profile:v", "3", "-pix_fmt", "yuv422p10le"]
            args += audio
            args.append(output.path)
            return ExportPlan(passes: [args], outputURL: output, scratchFiles: [])

        case .mp4, .mp4Height, .reel:
            var args = ["-y"] + trim + ["-i", input.path]
            if let vf { args += ["-vf", vf] }
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", "20",
                     // 4:2:0 8-bit is the only chroma format QuickTime, Safari and
                     // every social uploader agree on. Without it a 4:4:4 source
                     // produces an MP4 that plays nowhere the user is going to put it.
                     "-pix_fmt", "yuv420p",
                     "-movflags", "+faststart"]
            args += audio
            args.append(output.path)
            return ExportPlan(passes: [args], outputURL: output, scratchFiles: [])
        }
    }

    // MARK: - Trim / seek

    /// Input-side seek arguments.
    ///
    /// `-ss` *before* `-i` seeks by demuxing rather than decoding the skipped
    /// span, which is orders of magnitude faster on a long file; `-accurate_seek`
    /// (the default for input seeking, stated explicitly here so it survives
    /// someone reordering these) then decodes and discards from the preceding
    /// keyframe so the first output frame is the one asked for. Fast *and* exact,
    /// which the after-`-i` form only manages by decoding everything before it.
    ///
    /// `-t` is also an input option, so it bounds how much *source* is read. That
    /// matters once speed is in play: as an output option it would bound the
    /// output instead, and a 2x export would be cut to half the footage.
    private static func trimArgs(_ recipe: EditRecipe) -> [String] {
        var args: [String] = []
        let start = max(0, recipe.inPoint ?? 0)
        if start > 0 {
            args += ["-accurate_seek", "-ss", String(format: "%.3f", start)]
        }
        if let out = recipe.outPoint, out > start {
            args += ["-t", String(format: "%.3f", out - start)]
        }
        return args
    }

    // MARK: - Video filters

    /// The `-vf` chain, or nil when the recipe and target both ask for nothing.
    ///
    /// Order is the whole game here; three of these steps are non-commutative and
    /// getting them wrong produces a plausible-looking wrong frame rather than an
    /// error.
    ///
    ///   1. `setpts` — pure timestamp arithmetic, no pixels touched. First so that
    ///      every downstream *timestamp-sensitive* filter (`fps`, and the GIF
    ///      palette pass built on it) sees the final timeline. Run after `fps` it
    ///      would re-time frames that had already been resampled at the old rate.
    ///   2. `crop` — before `scale`, because the rect is normalised against the
    ///      *source* dimensions. After a scale it would still be normalised
    ///      against dimensions that no longer exist, and it also means the scaler
    ///      never touches pixels that are about to be thrown away.
    ///   3. `scale` — before `transpose`, because `scaleHeight` is the user's
    ///      request against the frame as they see it in the editor, i.e. upright.
    ///      Scaling after a 90° rotation would make "720p" produce a 720-pixel-wide
    ///      portrait clip.
    ///   4. `transpose` — after crop, because a crop rect expressed in source
    ///      coordinates is meaningless once the axes have been swapped.
    ///   5. `hflip` — after the rotation, since the user is mirroring the frame
    ///      they can see, which is the rotated one.
    ///   6. target framing (Reel box, height cap) — after all user geometry, so the
    ///      1080x1920 guarantee is made about the *final* frame. Before the
    ///      rotation it would be undone by it.
    ///   7. `fps` — last. Dropping frames is cheapest once the frames are small,
    ///      and for GIF the rate has to be the one `palettegen` samples.
    private static func videoFilterChain(_ recipe: EditRecipe, target: ExportTarget,
                                         source: MediaInfo?) -> String? {
        guard !target.isAudioOnly else { return nil }
        var chain: [String] = []

        // 1. speed
        let speed = recipe.effectiveSpeed
        if abs(speed - 1.0) > 0.0001 {
            chain.append("setpts=PTS/\(fmt(speed))")
        }

        // 2. crop
        if let crop = recipe.crop, !crop.isFull, let v = source?.video,
           v.width > 0, v.height > 0 {
            // Omitted entirely when we have no probe: the rect is a *fraction*, and
            // turning it into pixels requires the source dimensions. Guessing a
            // resolution would crop the wrong region, which is worse than not
            // cropping — an uncropped export is obviously wrong and re-runnable.
            let r = crop.normalised
            // Even values throughout: yuv420p subsamples chroma 2x2 and libx264
            // refuses an odd dimension outright, so an off-by-one from rounding a
            // drag would fail the export at the last moment.
            let w = even(Int((Double(v.width) * r.width).rounded()), min: 2)
            let h = even(Int((Double(v.height) * r.height).rounded()), min: 2)
            let x = even(Int((Double(v.width) * r.x).rounded()), min: 0)
            let y = even(Int((Double(v.height) * r.y).rounded()), min: 0)
            chain.append("crop=\(w):\(h):\(x):\(y)")
        }

        // 3. scale
        if let requested = recipe.scaleHeight, requested > 0 {
            // `-2` keeps the aspect ratio and rounds the derived width to an even
            // number, rather than `-1` which can land on an odd one and fail x264.
            chain.append("scale=-2:\(even(requested, min: 2)):flags=lanczos")
        }

        // 4. rotate
        switch recipe.rotation {
        case .none: break
        case .cw90: chain.append("transpose=1")
        case .ccw90: chain.append("transpose=2")
        // Two transposes would work but decode-and-rewrite the frame twice; a
        // horizontal plus a vertical mirror is the same 180° for less work.
        case .half: chain += ["hflip", "vflip"]
        }

        // 5. flip
        if recipe.flipHorizontal { chain.append("hflip") }

        // 6. target framing
        switch target {
        case .reel:
            // `increase` scales until the frame *covers* 1080x1920, then the crop
            // takes the centre. The alternative (`decrease` + pad) is what produces
            // the letterboxed clips with black bars down both sides that every
            // vertical platform down-ranks.
            chain += ["scale=1080:1920:force_original_aspect_ratio=increase:flags=lanczos",
                      "crop=1080:1920",
                      // Non-square pixels from an anamorphic source would otherwise
                      // survive into the output and stretch it on playback.
                      "setsar=1"]
        case .mp4Height(let cap) where cap > 0:
            // Expressed as an ffmpeg expression rather than computed here so it
            // works with no probe, and clamped so a "1080p" preset never upscales
            // a 480p source into four times the bitrate for no added detail.
            chain.append("scale=-2:'min(ih,\(even(cap, min: 2)))':flags=lanczos")
        case .gif:
            // A full-resolution GIF is tens of megabytes and nobody wants one.
            // Only applied when the user hasn't already said what they want.
            if recipe.scaleHeight == nil {
                chain.append("scale=-2:'min(ih,480)':flags=lanczos")
            }
        default:
            break
        }

        // 7. fps
        if target == .gif {
            chain.append("fps=15")
        } else if speed < 1.0 - 0.0001, let fps = source?.video?.fps, fps > 0 {
            // Slowing down stretches the existing frames over more time and nothing
            // fills the gap, so a 30fps clip at 0.25x is a *7.5fps* clip — measured,
            // not theorised. It reads as a stutter, and sub-10fps streams get
            // re-encoded or rejected outright by the upload pipelines this app's
            // output is headed for. Duplicating frames back up to the source rate
            // invents no motion, but it does keep the result a normal video.
            //
            // Last in the chain, and necessarily after `setpts`: `fps` resamples
            // against the timeline it is handed, so ahead of the retiming it would
            // sample the *original* one and the speed change would be undone.
            chain.append("fps=\(fmt(min(fps, 60)))")
        }

        return chain.isEmpty ? nil : chain.joined(separator: ",")
    }

    // MARK: - Audio

    private static func audioArgs(_ recipe: EditRecipe, target: ExportTarget) -> [String] {
        if target == .gif { return ["-an"] }
        if recipe.mute { return ["-an"] }

        var args: [String] = []
        if let filter = atempoChain(recipe.effectiveSpeed) {
            args += ["-af", filter]
        }
        switch target {
        case .audioMP3: args += ["-c:a", "libmp3lame", "-q:a", "2"]
        case .proRes: args += ["-c:a", "pcm_s16le"]
        default: args += ["-c:a", "aac", "-b:a", "\(audioBitrateKbps)k"]
        }
        return args
    }

    /// Assumed AAC rate for the size-budget arithmetic, and what the H.264 targets
    /// actually ask for. One constant so the two can't drift.
    private static let audioBitrateKbps = 128

    /// `atempo` accepts 0.5–2.0 per instance and silently *rejects* the filter
    /// graph outside that, so the requested factor is decomposed into a chain
    /// whose product is the factor.
    ///
    /// Halve (or double) into range, then apply what's left:
    ///   4.00 → 2.0 × 2.0        0.25 → 0.5 × 0.5
    ///   3.00 → 2.0 × 1.5        0.40 → 0.5 × 0.8
    /// The recipe's 0.25...4.0 bound keeps this at two links, which is also the
    /// point past which `atempo`'s phase-vocoder artefacts stop being subtle.
    ///
    /// Returns nil at 1.0 rather than emitting `atempo=1.0`, which is a no-op that
    /// still costs a decode/re-encode of the audio.
    static func atempoChain(_ speed: Double) -> String? {
        guard speed.isFinite, speed > 0, abs(speed - 1.0) > 0.0001 else { return nil }
        var remaining = speed
        var factors: [Double] = []
        // The epsilon keeps an exact 4.0 or 0.25 from leaving a 1.0000000002
        // remainder behind and emitting a pointless third link.
        while remaining > 2.0 + 0.0001 {
            factors.append(2.0)
            remaining /= 2.0
        }
        while remaining < 0.5 - 0.0001 {
            factors.append(0.5)
            remaining *= 2.0
        }
        if abs(remaining - 1.0) > 0.0001 { factors.append(remaining) }
        guard !factors.isEmpty else { return nil }
        return factors.map { "atempo=\(fmt($0))" }.joined(separator: ",")
    }

    // MARK: - GIF

    /// Two passes, because the single-pass default is the 256-colour web palette —
    /// a fixed, evenly-spaced cube that has no idea what colours are in *this*
    /// clip, so skin tones band and gradients posterise. `palettegen` derives a
    /// palette from the actual frames and `paletteuse` maps against it.
    ///
    /// Both passes run the identical filter chain: the palette has to be generated
    /// from the frames it will be applied to, so a chain that differs by even a
    /// scale step samples colours that never reach the output.
    private static func gifPlan(input: URL, output: URL, trim: [String],
                                chain: String) -> ExportPlan {
        let palette = FileManager.default.temporaryDirectory
            .appendingPathComponent("videopro-palette-\(UUID().uuidString).png")

        let pass1 = ["-y"] + trim + ["-i", input.path,
                                     // `diff` weights the pixels that actually move,
                                     // so a clip over a static background spends its
                                     // 256 colours on the subject.
                                     "-vf", chain + ",palettegen=stats_mode=diff",
                                     "-an",
                                     palette.path]

        let pass2 = ["-y"] + trim + ["-i", input.path,
                                     "-i", palette.path,
                                     // -lavfi, not -vf: this graph has two inputs.
                                     "-lavfi",
                                     "[0:v]\(chain)[v];[v][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                                     "-loop", "0",
                                     "-an",
                                     output.path]

        return ExportPlan(passes: [pass1, pass2], outputURL: output, scratchFiles: [palette])
    }

    // MARK: - Size target

    /// Genuine two-pass ABR aimed at a byte budget.
    ///
    /// Single-pass CRF cannot hit a size — it targets quality and the size falls
    /// out. Single-pass ABR hits the average but spends the budget badly, because
    /// it has never seen the second half of the clip. Two-pass analyses first, so
    /// the bits land on the hard scenes.
    private static func sizeTargetedPlan(input: URL, output: URL, recipe: EditRecipe,
                                         trim: [String], vf: String?, audio: [String],
                                         megabytes: Double, source: MediaInfo?) -> ExportPlan {
        // The OUTPUT duration, not the source's: trimming and speed both change how
        // many seconds the budget has to cover, and dividing by the source duration
        // would hand a 2x-speed clip half the bitrate it was entitled to.
        let duration = recipe.outputDuration(sourceDuration: source?.duration)

        guard let duration, duration > 0.1, megabytes > 0 else {
            // No duration means no budget arithmetic is possible — the source was
            // never probed, or probed badly. A CRF encode at least produces a small
            // file honestly, instead of a size guarantee we cannot make.
            var args = ["-y"] + trim + ["-i", input.path]
            if let vf { args += ["-vf", vf] }
            args += ["-c:v", "libx264", "-preset", "medium", "-crf", "30",
                     "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
            args += audio
            args.append(output.path)
            return ExportPlan(passes: [args], outputURL: output, scratchFiles: [])
        }

        // Decimal MB. Users comparing against an upload limit read the number in the
        // Finder, which is also decimal, and the binary reading is the larger of the
        // two — so this errs toward under-shooting either interpretation.
        let budgetBits = megabytes * 1_000_000 * 8
        // MP4 headers, the moov atom, and per-packet overhead are all outside the
        // bitrate ffmpeg is asked to hit. 3% covers it on clips of a few seconds,
        // where the fixed header is proportionally largest.
        let usableBits = budgetBits * 0.97

        let audioKbps = recipe.mute ? 0 : audioBitrateKbps
        let audioBits = Double(audioKbps) * 1000 * duration
        var videoKbps = Int(((usableBits - audioBits) / duration) / 1000)

        // Guard: below this the request is arithmetically unsatisfiable — a 1MB cap
        // on a ten-minute clip. Clamping rather than failing keeps the export
        // usable (the user gets the smallest thing x264 will make) and the overshoot
        // is visible in the resulting file, which is a better outcome than an error
        // sheet for a slider they can just move.
        let floorKbps = 48
        if videoKbps < floorKbps { videoKbps = floorKbps }

        // Written outside the output directory: it is ffmpeg's scratch, not the
        // user's, and a stale `*-0.log` sitting next to a video is confusing.
        // Unique per plan because a shared name lets a concurrent export read
        // another clip's statistics.
        let passLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("videopro-2pass-\(UUID().uuidString)")

        func common() -> [String] {
            var args = ["-y"] + trim + ["-i", input.path]
            if let vf { args += ["-vf", vf] }
            args += ["-c:v", "libx264", "-preset", "medium",
                     "-b:v", "\(videoKbps)k",
                     "-pix_fmt", "yuv420p",
                     "-passlogfile", passLog.path]
            return args
        }

        // Pass 1 discards its output — only the statistics file matters. `-an`
        // because encoding audio here is pure wasted time, and `-f mp4` so the
        // muxer x264 is tuned against is the one that will actually be used.
        var pass1 = common()
        pass1 += ["-pass", "1", "-an", "-f", "mp4", "/dev/null"]

        var pass2 = common()
        pass2 += ["-pass", "2", "-movflags", "+faststart"]
        pass2 += audio
        pass2.append(output.path)

        // x264 appends `-0.log` and `-0.log.mbtree` to `-passlogfile`; those exact
        // two names are what it leaves on disk (verified, not assumed).
        return ExportPlan(passes: [pass1, pass2], outputURL: output,
                          scratchFiles: [URL(fileURLWithPath: passLog.path + "-0.log"),
                                         URL(fileURLWithPath: passLog.path + "-0.log.mbtree")])
    }

    // MARK: - Helpers

    /// Trims the float noise out of a filter argument. `setpts=PTS/2.0` is fine;
    /// `setpts=PTS/1.9999999999999998` is what naive interpolation produces.
    private static func fmt(_ value: Double) -> String {
        let rounded = (value * 10000).rounded() / 10000
        if rounded == rounded.rounded() { return String(format: "%.1f", rounded) }
        return String(format: "%g", rounded)
    }

    private static func even(_ value: Int, min lower: Int) -> Int {
        Swift.max(lower, value - (value % 2))
    }
}
