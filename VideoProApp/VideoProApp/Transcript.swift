import Foundation

/// One timed line of a transcript.
struct TranscriptCue: Identifiable, Equatable, Sendable {
    let id: Int
    let index: Int
    let start: Double
    let end: Double
    let text: String
}

/// A parsed subtitle track, reduced to something a language model can reason over.
///
/// The clip-suggestion work (PLAN.md M7) never lets the model emit timestamps — it
/// gets cue-indexed text and returns cue *indices*, and we map those back to real
/// times here. That means index stability is a contract, not a convenience: the
/// indices this type hands out in `numberedChunks` are the same ones `timeRange`
/// resolves, so cues are renumbered exactly once, after all cleanup.
struct Transcript: Equatable, Sendable {

    let cues: [TranscriptCue]

    /// End of the last cue. Not the video's duration — a transcript usually stops
    /// before the video does.
    var duration: Double { cues.last?.end ?? 0 }

    var isEmpty: Bool { cues.isEmpty }

    init(cues: [TranscriptCue]) { self.cues = cues }

    // MARK: - Parsing

    static func parse(fileURL: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // `DownloadManager.retainSubtitles` names its kept file ".srt" whatever it
        // actually moved, so the extension proves nothing and we sniff instead.
        // Encoding is likewise unpromised: broadcast-sourced .srt files are often
        // Latin-1, and a strict UTF-8 read returns nil rather than mojibake.
        guard let text = decode(data) else { return nil }
        return parse(text: text)
    }

    static func parse(text: String) -> Transcript? {
        let raw = rawCues(in: text)
        guard !raw.isEmpty else { return nil }

        let deduped = deduplicate(raw)
        let cleaned: [Draft] = deduped.compactMap { draft in
            let body = collapse(draft.text)
            guard !body.isEmpty else { return nil }
            return Draft(start: draft.start, end: draft.end, text: body)
        }
        let merged = mergeFragments(cleaned)
        guard !merged.isEmpty else { return nil }

        let cues = merged.enumerated().map { i, d in
            TranscriptCue(id: i, index: i, start: d.start, end: d.end, text: d.text)
        }
        return Transcript(cues: cues)
    }

    // MARK: - Slicing

    /// Cue-indexed text for a prompt: "[12] some spoken words".
    ///
    /// Chunks split on cue boundaries only, because a half-cue is a half-sentence
    /// with an index the model would then cite for a clip that starts mid-word. A
    /// single cue longer than the cap gets its own oversized chunk rather than
    /// being cut.
    func numberedChunks(maxCharacters: Int) -> [String] {
        guard !cues.isEmpty else { return [] }
        let cap = max(1, maxCharacters)
        var chunks: [String] = []
        var current: [String] = []
        var length = 0

        for cue in cues {
            let line = "[\(cue.index)] \(cue.text)"
            let cost = line.count + (current.isEmpty ? 0 : 1)  // +1 for the newline
            if !current.isEmpty, length + cost > cap {
                chunks.append(current.joined(separator: "\n"))
                current = []
                length = 0
            }
            current.append(line)
            length += line.count + (current.count > 1 ? 1 : 0)
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    /// Cues in the inclusive index range `from...to`, clamped to what exists.
    /// Empty rather than trapping when the range misses entirely — the indices
    /// come from a language model, so out-of-range is an expected input.
    func cues(from: Int, to: Int) -> [TranscriptCue] {
        guard !cues.isEmpty else { return [] }
        let lo = max(0, min(from, to))
        let hi = min(cues.count - 1, max(from, to))
        guard lo <= hi else { return [] }
        return Array(cues[lo...hi])
    }

    /// Real time span for a cue-index range — the mapping that keeps the model
    /// from ever needing to produce a timestamp.
    func timeRange(from: Int, to: Int) -> (start: Double, end: Double)? {
        let slice = cues(from: from, to: to)
        guard let first = slice.first, let last = slice.last else { return nil }
        return (first.start, last.end)
    }

    // MARK: - Intermediate form

    private struct Draft {
        var start: Double
        var end: Double
        var text: String
    }

    /// A cue as it came off disk: words in order, each optionally carrying the
    /// inline timestamp that preceded it in a yt-dlp auto-caption.
    private struct RawCue {
        var start: Double
        var end: Double
        var words: [(text: String, time: Double?)]
        var hasInlineTiming: Bool
    }

    // MARK: - Lexing the file

    private static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        return String(data: data, encoding: .macOSRoman)
    }

    private static func rawCues(in text: String) -> [RawCue] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let lines = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var out: [RawCue] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // WEBVTT header and its metadata blocks carry no speech. NOTE bodies
            // in particular can contain "-->"-free prose that would otherwise be
            // swept up as the previous cue's text.
            if trimmed.isEmpty || isMetadataHeader(trimmed) {
                i += 1
                if isMetadataHeader(trimmed) {
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
                }
                continue
            }

            guard let span = timeSpan(trimmed) else {
                i += 1  // cue identifier, SRT index, or junk — skipped either way
                continue
            }

            i += 1
            var collected: [String] = []
            while i < lines.count {
                let next = lines[i]
                let nextTrimmed = next.trimmingCharacters(in: .whitespaces)
                if nextTrimmed.isEmpty { break }
                if timeSpan(nextTrimmed) != nil { break }
                // A bare number followed by a timestamp is the *next* SRT block's
                // index, not this cue's last line — files with no blank separator
                // are common enough to be worth the lookahead.
                if isInteger(nextTrimmed), i + 1 < lines.count,
                   timeSpan(lines[i + 1].trimmingCharacters(in: .whitespaces)) != nil {
                    break
                }
                collected.append(next)
                i += 1
            }

            guard span.end > span.start || !collected.isEmpty else { continue }
            let words = timedWords(in: collected.joined(separator: " "), cueStart: span.start)
            guard !words.list.isEmpty else { continue }
            out.append(RawCue(start: span.start,
                              end: max(span.end, span.start),
                              words: words.list,
                              hasInlineTiming: words.hadTiming))
        }
        return out
    }

    private static func isMetadataHeader(_ line: String) -> Bool {
        if line == "WEBVTT" || line.hasPrefix("WEBVTT ") || line.hasPrefix("WEBVTT\t") { return true }
        for keyword in ["NOTE", "STYLE", "REGION"] where line == keyword || line.hasPrefix(keyword + " ") {
            return true
        }
        return line.hasPrefix("X-TIMESTAMP-MAP")
    }

    private static func isInteger(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isNumber }
    }

    private static func timeSpan(_ line: String) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let lhs = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        // Everything after the end stamp is cue settings ("align:start position:0%").
        let rhsField = line[arrow.upperBound...]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        guard let start = seconds(lhs), let end = seconds(rhsField) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, or WebVTT's hour-less `MM:SS.mmm`.
    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        var total = 0.0
        for part in parts.dropLast() {
            guard !part.isEmpty, part.allSatisfy({ $0.isNumber }), let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        let tail = parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")
        let secondsParts = tail.split(separator: ".", omittingEmptySubsequences: false)
        guard secondsParts.count <= 2, let whole = secondsParts.first, !whole.isEmpty,
              whole.allSatisfy({ $0.isNumber }), let wholeValue = Double(whole) else { return nil }
        var value = wholeValue
        if secondsParts.count > 1 {
            let frac = secondsParts[1]
            guard !frac.isEmpty, frac.allSatisfy({ $0.isNumber }), let f = Double(frac) else { return nil }
            value += f / pow(10, Double(frac.count))
        }
        return total * 60 + value
    }

    // MARK: - Markup

    /// Split a cue body into words, honouring yt-dlp's per-word timing tags.
    ///
    /// Auto-captions interleave `<00:00:12.345><c>word</c>` through the text. Those
    /// stamps are the one thing that makes rolling-caption de-duplication *precise*:
    /// after dropping the words already spoken, the surviving first word carries the
    /// moment it was actually said, which is well after the cue's own start time.
    private static func timedWords(in raw: String, cueStart: Double) -> (list: [(text: String, time: Double?)], hadTiming: Bool) {
        var list: [(text: String, time: Double?)] = []
        var pending: Double? = cueStart
        var hadTiming = false
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            for word in decodeEntities(buffer).split(whereSeparator: { $0.isWhitespace }) {
                list.append((String(word), pending))
                pending = nil
            }
            buffer = ""
        }

        var scanner = raw[...]
        while let open = scanner.firstIndex(of: "<") {
            buffer.append(contentsOf: scanner[..<open])
            guard let close = scanner[open...].firstIndex(of: ">") else {
                // Unterminated tag: treat the rest as text rather than dropping it.
                buffer.append(contentsOf: scanner[open...])
                scanner = scanner[scanner.endIndex...]
                break
            }
            let tag = String(scanner[scanner.index(after: open)..<close])
            if let t = seconds(tag) {
                flush()
                pending = t
                hadTiming = true
            }
            scanner = scanner[scanner.index(after: close)...]
        }
        buffer.append(contentsOf: scanner)
        flush()

        // ASS-style override blocks ({\an8}) survive the tag stripper above.
        list = list.compactMap { word in
            let stripped = stripBraces(word.text)
            return stripped.isEmpty ? nil : (stripped, word.time)
        }
        return (list, hadTiming)
    }

    private static func stripBraces(_ s: String) -> String {
        guard s.contains("{") else { return s }
        var out = ""
        var depth = 0
        for ch in s {
            if ch == "{" { depth += 1 } else if ch == "}" { depth = max(0, depth - 1) } else if depth == 0 { out.append(ch) }
        }
        return out
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, replacement) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"),
                                      ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                      ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        return out
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - De-duplication

    /// Strip the rolling repetition out of auto-generated captions.
    ///
    /// yt-dlp's auto-subs are a *scrolling* display, not a transcript: each cue
    /// repeats the tail of what was already said and appends a few new words, so
    /// the same sentence appears three or four times and the file is several times
    /// longer than the speech. Feeding that to a model wastes most of the context
    /// budget on text it has already read.
    ///
    /// The fix is a suffix/prefix match against a sliding window of words already
    /// emitted: find the longest tail of the transcript-so-far that the new cue
    /// starts with, and drop exactly that many words. A cue that adds nothing
    /// disappears entirely and its time is folded into the cue before it, so
    /// coverage stays continuous.
    ///
    /// Two deliberate guards, because the same trick applied to a clean
    /// human-authored track would eat real speech:
    ///
    /// - The aggressive form only runs on files that *look* rolling — inline
    ///   timing tags present, or a good share of adjacent cues overlapping. Clean
    ///   files get only exact whole-cue duplicates removed.
    /// - Matching is on normalised words (case- and punctuation-insensitive), but
    ///   the original text is what survives, so punctuation from a human track is
    ///   never rewritten.
    private static func deduplicate(_ raw: [RawCue]) -> [Draft] {
        guard !raw.isEmpty else { return [] }
        let normalised = raw.map { $0.words.map { normalise($0.text) } }
        let rolling = looksRolling(raw, normalised)

        var out: [Draft] = []
        var tail: [String] = []          // normalised words already emitted
        let window = 64                  // a rolling caption never repeats more than a line or two

        for (i, cue) in raw.enumerated() {
            let words = normalised[i]
            guard !words.isEmpty else { continue }

            var overlap = 0
            let limit = min(words.count, tail.count, window)
            if limit > 0 {
                var k = limit
                while k > 0 {
                    if Array(tail.suffix(k)) == Array(words.prefix(k)) { overlap = k; break }
                    k -= 1
                }
            }

            // On a clean track only an exact whole-cue repeat is safe to drop; a
            // partial match there is far more likely to be an ordinary repeated
            // phrase than a scrolling artefact.
            if !rolling && overlap < words.count { overlap = 0 }

            if overlap >= words.count {
                // Nothing new. Let the previous cue own this cue's time so the
                // transcript has no hole where the repeat used to be.
                if !out.isEmpty { out[out.count - 1].end = max(out[out.count - 1].end, cue.end) }
                tail = Array((tail + words).suffix(window))
                continue
            }

            let kept = Array(cue.words[overlap...])
            let start = overlap > 0 ? (kept.first?.time ?? cue.start) : cue.start
            let text = kept.map(\.text).joined(separator: " ")
            out.append(Draft(start: min(start, cue.end), end: max(cue.end, start), text: text))
            tail = Array((tail + words).suffix(window))
        }
        return out
    }

    private static func looksRolling(_ raw: [RawCue], _ normalised: [[String]]) -> Bool {
        if raw.contains(where: \.hasInlineTiming) { return true }
        guard raw.count > 2 else { return false }
        var overlapping = 0
        for i in 1..<normalised.count {
            let previous = normalised[i - 1], current = normalised[i]
            guard !previous.isEmpty, !current.isEmpty else { continue }
            let limit = min(previous.count, current.count)
            var k = limit
            while k > 0 {
                if Array(previous.suffix(k)) == Array(current.prefix(k)) { break }
                k -= 1
            }
            if k >= 2 || (k > 0 && k == current.count) { overlapping += 1 }
        }
        return Double(overlapping) / Double(normalised.count - 1) >= 0.3
    }

    private static func normalise(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "'"
        })
    }

    // MARK: - Fragment merging

    private static let fragmentDuration = 1.0
    private static let fragmentGap = 0.75
    private static let mergedCeiling = 12.0

    /// Glue sub-second cues onto their neighbour.
    ///
    /// A model reasons about sentences; auto-captions arrive as two-word fragments.
    /// Merging only happens across a near-zero gap and never past `mergedCeiling`,
    /// so a fragment sitting alone before a long silence keeps its own timing
    /// rather than dragging a clip's in-point backwards into dead air.
    private static func mergeFragments(_ drafts: [Draft]) -> [Draft] {
        var out: [Draft] = []
        for draft in drafts {
            if var previous = out.last,
               previous.end - previous.start < fragmentDuration,
               draft.start - previous.end <= fragmentGap,
               draft.end - previous.start <= mergedCeiling {
                previous.end = max(previous.end, draft.end)
                previous.text += " " + draft.text
                out[out.count - 1] = previous
            } else {
                out.append(draft)
            }
        }
        // The rule above only absorbs *forwards*, so a short final cue is the one
        // case left over.
        if out.count > 1, let last = out.last, last.end - last.start < fragmentDuration,
           last.start - out[out.count - 2].end <= fragmentGap,
           last.end - out[out.count - 2].start <= mergedCeiling {
            out[out.count - 2].end = max(out[out.count - 2].end, last.end)
            out[out.count - 2].text += " " + last.text
            out.removeLast()
        }
        return out
    }
}
