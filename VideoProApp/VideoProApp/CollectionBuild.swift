import Foundation

// MARK: - Spec

/// The shared codec parameters every clip is normalised to before concatenation.
///
/// This exists because ffmpeg's fast concat demuxer (`-f concat -c copy`) does not
/// re-encode: it staples packet streams together and writes ONE set of stream
/// headers, taken from the first input. Anything the later inputs disagree about —
/// resolution, pixel format, SAR, frame rate, timebase, audio codec, sample rate,
/// channel layout — is not reconciled, it is simply lost. The result is a file that
/// plays the first clip correctly and then goes black, garbled or silent, with no
/// error from ffmpeg at any point. Normalising to a single spec first is what makes
/// the `-c copy` payoff safe rather than a lottery.
struct ConcatSpec: Equatable, Sendable {
    var width: Int
    var height: Int
    var fps: Double
    var sampleRate: Int
    var channels: Int

    /// Derive a defensible common target from the clips' own media info.
    ///
    /// Resolution: the *modal* resolution — the one the largest number of clips
    /// already have — because that is the size the most clips can be normalised to
    /// without resampling at all. Ties (including the all-distinct case, which is
    /// the common one for a hand-assembled collection) go to the largest by pixel
    /// area: upscaling a small clip invents no detail but keeps the big clip's, and
    /// downscaling everything to the smallest member throws away detail the user
    /// can never get back from the output file.
    ///
    /// Frame rate: the maximum. Up-sampling a 25fps clip to 60 duplicates frames,
    /// which is invisible; down-sampling a 60fps clip to 25 drops two frames in
    /// three and turns smooth motion into judder, which is not. Capped at 60 so one
    /// 240fps phone clip cannot make every other segment four times the size.
    ///
    /// Audio: fixed 48000/2 rather than derived. There is no "most common" worth
    /// honouring here — 48k stereo is what every mp4/AAC consumer expects, resampling
    /// audio is perceptually free, and upmixing mono to stereo is what a viewer
    /// wants anyway (a mono track in a stereo timeline otherwise plays out of one
    /// ear for its segment and then jumps back to centre).
    static func derive(from sources: [MediaInfo?]) -> ConcatSpec {
        let videos = sources.compactMap { $0?.video }.filter { $0.width > 0 && $0.height > 0 }

        var width = 1920
        var height = 1080
        if !videos.isEmpty {
            var counts: [Size: Int] = [:]
            for v in videos {
                counts[Size(w: v.width, h: v.height), default: 0] += 1
            }
            // Sort rather than max(by:) so the tie-break is total and the result is
            // stable: dictionary iteration order is not, and a spec that changes
            // between two runs over the same collection is a bug nobody can reproduce.
            let winner = counts.sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                let areaA = a.key.w * a.key.h, areaB = b.key.w * b.key.h
                if areaA != areaB { return areaA > areaB }
                return a.key.w > b.key.w
            }.first!.key
            width = winner.w
            height = winner.h
        }

        let rates = videos.compactMap(\.fps).filter { $0.isFinite && $0 > 0 }
        let fps = min(rates.max() ?? 30, 60)

        // Even dimensions: yuv420p subsamples chroma 2x2 and libx264 refuses an odd
        // dimension outright, so an odd-height source would fail every segment.
        return ConcatSpec(width: even(width), height: even(height),
                          fps: fps, sampleRate: 48000, channels: 2)
    }

    private struct Size: Hashable { let w: Int; let h: Int }

    private static func even(_ value: Int) -> Int {
        Swift.max(2, value - (value % 2))
    }
}

// MARK: - Plan

/// Everything needed to join a collection into one file, as data.
///
/// Same discipline as `ExportPlan`, and for the same reasons — inspectable in a bug
/// report, replayable, and the caller decides how to run and report N processes. The
/// extra thing this owns is a *directory*: unlike an export's two stray scratch
/// files, a join writes one full intermediate video per clip, which can be several
/// gigabytes, so they are all corralled under one `workingDirectory` the caller
/// deletes when the build finishes or fails.
///
/// `make` is pure and does no I/O. The caller must, in order:
///   1. create `workingDirectory`,
///   2. write `listFileContents` to `listFileURL`,
///   3. run every pass of every segment in order, stopping at the first non-zero exit,
///   4. run `finalPass`,
///   5. delete `workingDirectory` (which also removes the segments and the list file).
struct CollectionBuildPlan {

    /// One clip's normalisation: the ffmpeg args, and where it lands.
    struct Segment {
        /// Position in the collection's ordering. Carried so a failure can be
        /// reported as "clip 3 of 7" without the caller re-deriving it.
        let index: Int
        let passes: [[String]]
        let intermediate: URL
        /// Artefacts this segment's passes leave behind beyond `intermediate`.
        /// Currently always empty — normalisation is deliberately single-pass — but
        /// present so a future two-pass segment cannot leak without a signature change.
        let scratchFiles: [URL]
    }

    let segments: [Segment]
    let listFileURL: URL
    let listFileContents: String
    let finalPass: [String]
    let outputURL: URL
    /// Caller deletes this when done. Everything the build writes except the final
    /// output lives inside it.
    let workingDirectory: URL

    // MARK: - Planning

    static func make(clips: [(input: URL, recipe: EditRecipe, source: MediaInfo?)],
                     spec: ConcatSpec,
                     output: URL) -> CollectionBuildPlan {
        // UUID-keyed: two builds of two collections can be in flight at once, and a
        // shared directory would have them overwriting each other's `seg-000.mp4`.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("videopro-collection-\(UUID().uuidString)", isDirectory: true)

        let segments = clips.enumerated().map { index, clip in
            let intermediate = work.appendingPathComponent(String(format: "seg-%03d.mp4", index))
            return Segment(index: index,
                           passes: [normalisePass(clip: clip, spec: spec, output: intermediate)],
                           intermediate: intermediate,
                           scratchFiles: [])
        }

        let listURL = work.appendingPathComponent("concat.txt")
        let listContents = segments
            .map { "file '\(escapeForConcatList($0.intermediate.path))'\n" }
            .joined()

        // `-c copy` for both streams: this is the entire point of having normalised.
        // A second encode here would halve the quality of every frame for no change
        // in parameters, and take as long again as the whole normalisation stage.
        //
        // `-safe 0` because the demuxer refuses absolute paths otherwise, and absolute
        // paths are what we want — relative ones resolve against the list file's
        // directory, which silently breaks if anything ever moves the list.
        //
        // `-avoid_negative_ts make_zero` because each segment's first packet carries
        // its own encoder delay; without it the mp4 muxer can shift a later segment's
        // timestamps and open a gap at the join.
        let final = ["-y",
                     "-f", "concat", "-safe", "0",
                     "-i", listURL.path,
                     "-c", "copy",
                     "-avoid_negative_ts", "make_zero",
                     "-movflags", "+faststart",
                     output.path]

        return CollectionBuildPlan(segments: segments,
                                   listFileURL: listURL,
                                   listFileContents: listContents,
                                   finalPass: final,
                                   outputURL: output,
                                   workingDirectory: work)
    }

    // MARK: - Normalisation

    /// One clip's `EditRecipe` and the spec, applied in a single encode.
    ///
    /// Deliberately not `ExportPlan.make`. Its targets are *user-facing* — they
    /// choose CRF for looks, cap rather than force a height, leave the frame rate to
    /// the source unless a slowdown demands otherwise, and emit `-an` for a muted
    /// clip. Every one of those is wrong here: a normalisation pass has to hit exact
    /// dimensions, an exact frame rate, an exact timebase and an audio track that
    /// exists unconditionally, because the concat demuxer compares them byte for
    /// byte. The recipe *geometry* logic is the same idea and the ordering rationale
    /// in `ExportPlan.videoFilterChain` applies verbatim; the target-shaped decisions
    /// around it are not reusable.
    private static func normalisePass(clip: (input: URL, recipe: EditRecipe, source: MediaInfo?),
                                      spec: ConcatSpec,
                                      output: URL) -> [String] {
        let recipe = clip.recipe
        let speed = recipe.effectiveSpeed

        // A clip with no audio track of its own — or one the user muted — still needs
        // an audio track in the output. This is the single most common way a
        // collection join fails: the concat demuxer writes stream headers from the
        // first input only, so a segment that is missing stream 1 does not "have no
        // audio for its span", it desynchronises the audio stream for the rest of the
        // file — typically every clip after it plays silent. `-an` is never correct
        // in a segment. Mute is honoured by substituting silence, not by dropping the
        // track.
        //
        // With `source == nil` we have no probe and assume the clip has audio. That is
        // right for the overwhelming majority of video, and the failure mode when it is
        // wrong is loud and immediate — ffmpeg exits with "Stream map '0:a:0' matches
        // no streams" — which is far better than silently synthesising silence over a
        // clip that had a soundtrack. Callers should probe before building.
        let hasRealAudio = (clip.source?.audioTracks.isEmpty == false) || clip.source == nil
        let useSilence = recipe.mute || !hasRealAudio

        var args = ["-y"]
        args += trimArgs(recipe)
        args += ["-i", clip.input.path]

        if useSilence {
            // Generated at the spec's layout directly, so it needs no resampling and
            // cannot disagree with a real segment's track. `anullsrc` is infinite;
            // `-shortest` below is what ends it.
            args += ["-f", "lavfi",
                     "-i", "anullsrc=channel_layout=\(spec.channels == 1 ? "mono" : "stereo"):sample_rate=\(spec.sampleRate)"]
        }

        args += ["-map", "0:v:0"]
        args += ["-map", useSilence ? "1:a:0" : "0:a:0"]
        // Exactly one video and one audio stream per segment. A source with a second
        // audio language or a subtitle track would otherwise contribute streams that
        // the first segment's headers have no slot for.
        args += ["-vf", videoFilterChain(recipe, spec: spec, source: clip.source)]

        if useSilence {
            args.append("-shortest")
        } else if let tempo = ExportPlan.atempoChain(speed) {
            args += ["-af", "\(tempo),aresample=async=1:first_pts=0"]
        } else {
            // `first_pts=0` on every real track: a clip whose audio starts at a small
            // positive PTS (AAC encoder delay in the source, or a trim landing between
            // packets) would otherwise carry that offset into the join, and the offsets
            // accumulate across segments into audible drift by the end of a long
            // collection.
            args += ["-af", "aresample=async=1:first_pts=0"]
        }

        args += [
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
            // Forced, not capped. The concat demuxer compares the encoded frame rate;
            // "leave it alone unless asked" is exactly what produces mismatched segments.
            "-r", fmt(spec.fps),
            "-pix_fmt", "yuv420p",
            // The other half of the header comparison. The mp4 muxer picks a timescale
            // per file otherwise, and two segments encoded from differently-timed
            // sources land on different ones. 90000 is the MPEG standard tick and
            // divides evenly by 24/25/30/50/60.
            "-video_track_timescale", "90000",
            // Pinned so x264 cannot pick a different profile for a segment whose
            // content happens to need fewer features — a profile change mid-file is
            // invisible to the muxer and fatal to the decoder.
            "-profile:v", "high",
            "-c:a", "aac", "-b:a", "192k",
            "-ar", String(spec.sampleRate),
            "-ac", String(spec.channels),
            output.path,
        ]
        return args
    }

    /// The user's edit, then the spec fit. Both halves have to be in one chain, and
    /// the order between them is not negotiable: the spec's guarantee is about the
    /// *final* frame, so a rotation applied after the fit would hand the concat
    /// demuxer a segment that is HxW instead of WxH.
    ///
    /// Within the user's half the ordering rationale is `ExportPlan.videoFilterChain`'s,
    /// unchanged: speed first (pure timestamp arithmetic, so the later timestamp-
    /// sensitive `fps` sees the final timeline), crop before scale (the rect is
    /// normalised against *source* dimensions), rotate after crop (a crop rect in
    /// source coordinates is meaningless once the axes swap), flip after rotate (the
    /// user mirrors the frame they can see).
    private static func videoFilterChain(_ recipe: EditRecipe, spec: ConcatSpec,
                                         source: MediaInfo?) -> String {
        var chain: [String] = []

        let speed = recipe.effectiveSpeed
        if abs(speed - 1.0) > 0.0001 {
            chain.append("setpts=PTS/\(fmt(speed))")
        }

        if let crop = recipe.crop, !crop.isFull, let v = source?.video,
           v.width > 0, v.height > 0 {
            // Dropped without a probe for the same reason `ExportPlan` drops it: the
            // rect is a fraction and turning it into pixels needs the real dimensions.
            let r = crop.normalised
            let w = even(Int((Double(v.width) * r.width).rounded()), min: 2)
            let h = even(Int((Double(v.height) * r.height).rounded()), min: 2)
            let x = even(Int((Double(v.width) * r.x).rounded()), min: 0)
            let y = even(Int((Double(v.height) * r.y).rounded()), min: 0)
            chain.append("crop=\(w):\(h):\(x):\(y)")
        }

        // `recipe.scaleHeight` is deliberately not honoured. It asks for an output
        // height, and in a collection the output height is the spec's — one clip
        // cannot be 720 tall in a 1080 timeline. Emitting it anyway would just cost a
        // scaler pass whose result the fit below immediately overwrites.

        switch recipe.rotation {
        case .none: break
        case .cw90: chain.append("transpose=1")
        case .ccw90: chain.append("transpose=2")
        case .half: chain += ["hflip", "vflip"]
        }
        if recipe.flipHorizontal { chain.append("hflip") }

        // Fit to the spec by letterboxing, not cropping. A collection is exactly where
        // aspect ratios differ, and cover-and-crop would silently cut the top and
        // bottom off every portrait clip joined into a landscape sequence. Bars are
        // visible and undoable; lost framing is neither.
        chain.append("scale=\(spec.width):\(spec.height):force_original_aspect_ratio=decrease:flags=lanczos")
        chain.append("pad=\(spec.width):\(spec.height):(ow-iw)/2:(oh-ih)/2:color=black")
        // Anamorphic sources carry a non-square SAR that survives scaling and would
        // differ segment to segment, stretching whichever clips did not supply the
        // header the demuxer kept.
        chain.append("setsar=1")
        // Last, and necessarily after `setpts`: `fps` resamples against the timeline it
        // is handed, so ahead of the retiming it would sample the original one and undo
        // the speed change. Belt to `-r`'s braces — the filter fixes the frame
        // *timestamps*, the flag fixes what the encoder declares.
        chain.append("fps=\(fmt(spec.fps))")

        return chain.joined(separator: ",")
    }

    /// Input-side seek, identical in intent to `ExportPlan.trimArgs`: `-ss` before
    /// `-i` demuxes rather than decodes the skipped span, `-accurate_seek` then makes
    /// the first output frame the one asked for, and `-t` as an *input* option bounds
    /// how much source is read so a 2x segment is not also cut to half its footage.
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

    // MARK: - Concat list

    /// The demuxer's list syntax is `file '<path>'` per line, single-quoted.
    ///
    /// Its quoting is shell-like but not a shell: inside single quotes nothing is
    /// escapable, so a literal apostrophe is written by closing the quote, emitting a
    /// backslash-apostrophe, and reopening — `'\''`. Getting this wrong on a file
    /// named "Tyler's cut.mp4" does not produce a quoting error, it produces
    /// "no such file" halfway through a build that has already spent minutes encoding.
    static func escapeForConcatList(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }

    // MARK: - Helpers

    /// Keeps float noise out of filter arguments — `fps=29.97`, not
    /// `fps=29.969999999999999`.
    private static func fmt(_ value: Double) -> String {
        let rounded = (value * 10000).rounded() / 10000
        if rounded == rounded.rounded() { return String(format: "%.1f", rounded) }
        return String(format: "%g", rounded)
    }

    private static func even(_ value: Int, min lower: Int) -> Int {
        Swift.max(lower, value - (value % 2))
    }
}
