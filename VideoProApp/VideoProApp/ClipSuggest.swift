import Foundation
// Name collision worth knowing about: FoundationModels exports its own
// `SubtitleTranscript` (the model's conversation history). Our subtitle `SubtitleTranscript`
// wins here because a same-module declaration outranks an imported one — but
// that's the only thing keeping them apart, so if `SubtitleTranscript.swift` is ever
// moved into a separate module this file starts silently type-checking against
// Apple's. Verified against the real framework, not assumed.
import FoundationModels

// MARK: - Public model

/// A clip the model proposed, already resolved to real seconds.
///
/// `start`/`end` are derived from `startCue`/`endCue` via the transcript — the
/// model never supplies a timestamp, only cue indices. See `ClipSuggester` for
/// why. A suggestion is deliberately *not* an `EditRecipe`: the caller decides
/// whether to promote it into one.
struct SuggestedClip: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var startCue: Int
    var endCue: Int
    var start: Double
    var end: Double
    var rationale: String?

    init(id: UUID = UUID(), title: String, startCue: Int, endCue: Int,
         start: Double, end: Double, rationale: String? = nil) {
        self.id = id
        self.title = title
        self.startCue = startCue
        self.endCue = endCue
        self.start = start
        self.end = end
        self.rationale = rationale
    }

    var duration: Double { max(0, end - start) }
}

enum ClipSuggestError: Error, LocalizedError, Equatable {
    /// The on-device model can't run here. The string is user-facing.
    case unavailable(String)
    case noTranscript
    /// The safety sanitiser rejected the transcript or the prompt. Retrying is
    /// pointless — the same input produces the same refusal.
    case refused
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .noTranscript:         return "This video has no transcript to read."
        case .refused:              return "Apple Intelligence declined to process this transcript."
        case .failed(let why):      return why
        }
    }
}

// MARK: - Structured output schema

/// The model's raw answer. Indices here are *untrusted* — every field is
/// validated against the transcript before it becomes a `SuggestedClip`.
///
/// `reason` is a plain String rather than `String?` because optional properties
/// in a generated schema are unreliable in practice: the model tends to omit the
/// key entirely rather than emit null, which decodes as a hard failure for the
/// whole response. An empty string is cheap and maps to nil on our side.
@Generable
private struct ModelClip {
    @Guide(description: "A short title, at most six words. No quotes, no timestamps.")
    var title: String

    @Guide(description: "The index of the first line of the segment, copied exactly from a [n] marker in the transcript.")
    var startCue: Int

    @Guide(description: "The index of the last line of the segment, copied exactly from a [n] marker in the transcript. Must be greater than or equal to startCue.")
    var endCue: Int

    @Guide(description: "One short sentence on why this segment stands alone. Empty string if there is nothing to say.")
    var reason: String
}

/// Answer to the reduce pass: which candidates survive.
@Generable
private struct ModelKeep {
    @Guide(description: "The numbers of the candidates that genuinely match the request. Empty list if none of them do.")
    var keep: [Int]
}

@Generable
private struct ModelClips {
    @Guide(description: "The matching segments. An empty list is a valid and expected answer when nothing matches.")
    var clips: [ModelClip]
}

// MARK: - Suggester

/// Finds clip-worthy segments in a transcript using the on-device model.
///
/// Three rules drive the whole design:
///
/// 1. **The model never emits a timestamp.** Ask it for seconds and it invents
///    plausible-looking ones, producing clips that start mid-syllable. It gets
///    cue-indexed text and returns cue *indices*; we map those to time. Cutting
///    on cue boundaries also lands the edit on a sentence boundary for free.
/// 2. **Every returned index is untrusted.** Out-of-range, inverted, and
///    chunk-relative indices all occur. They are clamped or discarded, never
///    passed through.
/// 3. **Query-driven beats taste-driven.** `find(_:in:limit:)` is retrieval,
///    which a ~3B on-device model does well. `suggest(in:limit:)` is judgement,
///    which it does markedly less well — it exists, but the UI should lead with
///    the query.
@MainActor
final class ClipSuggester {
    static let shared = ClipSuggester()

    /// Bytes of transcript per model call.
    ///
    /// The context window is a hard limit (`exceededContextWindowSize` is a real
    /// error) and an hour of speech is far past it. This is deliberately well
    /// under what fits: the instructions, the schema, and the response all share
    /// the window, and a chunk that *just* fits on a terse transcript overflows
    /// on a dense one.
    private let chunkCharacters = 3_500

    /// A wedged model must not hang the UI. Generation is normally ~2s warm and
    /// ~7s cold, so this is loose enough to never fire on a healthy call.
    private let perCallTimeout: Duration = .seconds(45)

    /// The first structured call after boot can fail with a bare
    /// `LanguageModelError -1` wrapping `ModelManagerError 1013` — a model asset
    /// still paging in. The identical call succeeds a moment later. One retry
    /// with a short pause covers it; a refusal is never retried.
    private let retryBackoff: Duration = .milliseconds(750)

    private init() {}

    // MARK: Availability

    /// Whether the model is usable right now, and a user-facing reason if not.
    ///
    /// Every unavailable case is reachable on shipping hardware, so callers are
    /// expected to degrade (hide the feature, show the reason) rather than treat
    /// this as an error path.
    static var availability: (usable: Bool, reason: String) {
        switch SystemLanguageModel.default.availability {
        case .available:
            return (true, "")
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return (false, "This Mac doesn't support Apple Intelligence, so clip suggestions aren't available.")
            case .appleIntelligenceNotEnabled:
                return (false, "Turn on Apple Intelligence in System Settings to get clip suggestions.")
            case .modelNotReady:
                return (false, "Apple Intelligence is still downloading its model. Try again shortly.")
            @unknown default:
                return (false, "Apple Intelligence isn't available right now.")
            }
        @unknown default:
            return (false, "Apple Intelligence isn't available right now.")
        }
    }

    // MARK: Entry points

    /// Retrieval: find segments matching what the user asked for.
    func find(_ query: String, in transcript: SubtitleTranscript, limit: Int = 5) async throws -> [SuggestedClip] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await suggest(in: transcript, limit: limit) }
        return try await run(transcript: transcript, limit: limit, query: trimmed)
    }

    /// Taste: no query, the model picks what stands alone.
    func suggest(in transcript: SubtitleTranscript, limit: Int = 5) async throws -> [SuggestedClip] {
        try await run(transcript: transcript, limit: limit, query: nil)
    }

    // MARK: Map-reduce

    private func run(transcript: SubtitleTranscript, limit: Int, query: String?) async throws -> [SuggestedClip] {
        let gate = Self.availability
        guard gate.usable else { throw ClipSuggestError.unavailable(gate.reason) }
        guard !transcript.isEmpty else { throw ClipSuggestError.noTranscript }

        let chunks = transcript.numberedChunks(maxCharacters: chunkCharacters)
        guard !chunks.isEmpty else { throw ClipSuggestError.noTranscript }

        // Ask each chunk for a few more than we need so the reduce step has room
        // to drop duplicates and still fill `limit`.
        let perChunk = max(2, min(limit, 4))

        let allBounds = chunks.map { Self.markerBounds(in: $0) }
        // Every chunk's last index except the final one — the only places a
        // suggestion can be artificially cut in half.
        let boundaries = Set(allBounds.dropLast().compactMap { $0?.upperBound })

        var harvested: [SuggestedClip] = []
        var lastError: ClipSuggestError?

        for (chunk, bounds) in zip(chunks, allBounds) {
            do {
                let raw = try await generate(chunk: chunk, query: query, limit: perChunk)
                harvested += validate(raw, transcript: transcript, chunkBounds: bounds)
            } catch let e as ClipSuggestError {
                // A refusal is about *this* chunk's content — a single blocked
                // passage shouldn't lose the whole transcript's results. Keep
                // going and only surface it if nothing at all came back.
                lastError = e
                continue
            }
        }

        if harvested.isEmpty, let lastError { throw lastError }

        var candidates = merge(harvested, acrossBoundariesAt: boundaries)
        // Worth running even on a single candidate: one chunk of an unrelated
        // transcript will still offer up its least-irrelevant passage.
        if let query, !candidates.isEmpty, chunks.count > 1 {
            candidates = await reduce(candidates, query: query, transcript: transcript)
        }
        return Array(candidates.prefix(limit))
    }

    /// Second pass over the winners.
    ///
    /// Each chunk is scored in isolation, so a chunk containing nothing relevant
    /// still gets asked for matches and will offer up its least-irrelevant
    /// passage — a short tail chunk is the worst offender. Judging all the
    /// candidates side by side is the only point at which "this one is weaker
    /// than that one" is even answerable.
    ///
    /// Failure here is not fatal: an unreadable answer keeps the unfiltered list,
    /// since a slightly noisy result beats no result.
    private func reduce(_ candidates: [SuggestedClip], query: String,
                        transcript: SubtitleTranscript) async -> [SuggestedClip] {
        let listing = candidates.enumerated().map { i, clip -> String in
            let body = transcript.cues(from: clip.startCue, to: clip.endCue)
                .map(\.text).joined(separator: " ")
            return "\(i + 1). \(clip.title) — \(body.prefix(220))"
        }.joined(separator: "\n")

        let session = LanguageModelSession(instructions: """
            You are checking a shortlist of transcript segments against a request.
            Judge each candidate only by the words of the segment itself, not by its title — the titles were written by someone guessing and are often wrong.
            Keep a candidate only if the segment's own words are about what was asked for.
            Dropping every candidate is a valid answer. Do not keep a candidate because it is the closest one available.
            Answer with the candidates' numbers only.
            """)
        let prompt = """
            Request: \(query)

            Candidates:
            \(listing)

            For each candidate, is the text about "\(query)"? Answer with the numbers of the ones that are.
            """

        do {
            let kept = try await withTimeout(perCallTimeout) {
                try await session.respond(to: prompt, generating: ModelKeep.self).content.keep
            }
            // Out-of-range ordinals are as untrusted as cue indices are.
            let picked = Set(kept.map { $0 - 1 }.filter { $0 >= 0 && $0 < candidates.count })
            guard !kept.isEmpty else { return [] }
            guard !picked.isEmpty else { return candidates }
            return candidates.enumerated().filter { picked.contains($0.offset) }.map(\.element)
        } catch {
            return candidates
        }
    }

    // MARK: Generation

    private func generate(chunk: String, query: String?, limit: Int) async throws -> [ModelClip] {
        do {
            return try await attempt(chunk: chunk, query: query, limit: limit)
        } catch let e as ClipSuggestError {
            // Refusals and context overflow are deterministic; only the transient
            // asset-loading failure is worth a second go.
            guard case .failed = e else { throw e }
            try? await Task.sleep(for: retryBackoff)
            return try await attempt(chunk: chunk, query: query, limit: limit)
        }
    }

    private func attempt(chunk: String, query: String?, limit: Int) async throws -> [ModelClip] {
        // A fresh session per chunk. Reusing one accumulates every previous chunk
        // in the transcript history, which is the fastest possible route to
        // exceeding the context window we just went to the trouble of chunking for.
        let session = LanguageModelSession(instructions: Self.instructions(query: query))
        let prompt = Self.prompt(chunk: chunk, query: query, limit: limit)

        do {
            // Only `clips` crosses the isolation boundary: `Response` itself is
            // not Sendable, and returning it from the timeout group is an error
            // under strict concurrency.
            return try await withTimeout(perCallTimeout) {
                try await session.respond(to: prompt, generating: ModelClips.self).content.clips
            }
        } catch let e as ClipSuggestError {
            throw e
        } catch {
            throw Self.classify(error)
        }
    }

    /// Races generation against a deadline. `LanguageModelSession` respects
    /// cancellation, so the losing branch stops rather than leaking a live call.
    private func withTimeout<T: Sendable>(_ limit: Duration,
                                          _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw ClipSuggestError.failed("The model didn't respond in time.")
            }
            guard let first = try await group.next() else {
                throw ClipSuggestError.failed("The model returned nothing.")
            }
            group.cancelAll()
            return first
        }
    }

    /// Maps a FoundationModels error onto our vocabulary. The distinction that
    /// matters is refusal (never retry) versus everything else (retry once).
    private static func classify(_ error: Error) -> ClipSuggestError {
        // macOS 27 replaced GenerationError's cases with LanguageModelError but
        // kept both live, and which one you get depends on the call path — so
        // both are matched. The deployment target is still 26, hence the guard.
        if #available(macOS 27.0, *), let e = error as? LanguageModelError {
            switch e {
            case .guardrailViolation, .refusal, .unsupportedTranscriptContent:
                return .refused
            case .contextSizeExceeded:
                return .failed("That section of the transcript was too long to read at once.")
            case .unsupportedLanguageOrLocale:
                return .unavailable("Apple Intelligence can't read this transcript's language.")
            default:
                return .failed(e.localizedDescription)
            }
        }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation, .refusal:
                return .refused
            case .exceededContextWindowSize:
                return .failed("That section of the transcript was too long to read at once.")
            case .assetsUnavailable:
                return .unavailable("Apple Intelligence is still downloading its model. Try again shortly.")
            default:
                return .failed(generation.localizedDescription)
            }
        }
        // The transient boot failure arrives as a bare LanguageModelError -1 with
        // no case to match on, so it falls through to .failed and gets the retry.
        let text = String(describing: error).lowercased()
        if text.contains("guardrail") || text.contains("safety") { return .refused }
        return .failed((error as NSError).localizedDescription)
    }

    // MARK: Prompts

    private static func instructions(query: String?) -> String {
        var lines = [
            "You select segments from a transcript. Each line is prefixed with its index in square brackets, like [12].",
            "Refer to segments ONLY by those bracketed indices. Never write a timestamp, a time in seconds, or a clock time.",
            "startCue and endCue must be indices that actually appear in the transcript you are given.",
            "Prefer segments that make sense on their own to someone who has not seen the rest of the video: a complete thought, starting at the beginning of a sentence.",
            "A segment is usually 3 to 20 lines. Do not return the entire transcript as one segment.",
            "Titles are at most six words.",
        ]
        if query != nil {
            // The single most common failure in retrieval mode is answering with
            // *something* rather than nothing, so this is stated twice and last.
            lines.append("Return ONLY segments that genuinely match the user's request. If nothing in this transcript matches, return an empty list. An empty list is a correct answer — do not pad it with the closest thing you found.")
        } else {
            lines.append("Choose the segments most likely to interest someone scrolling: a clear claim, a story, a strong exchange. Skip introductions, sign-offs, and filler.")
        }
        return lines.joined(separator: "\n")
    }

    private static func prompt(chunk: String, query: String?, limit: Int) -> String {
        if let query {
            return """
            Find up to \(limit) segments about: \(query)

            If none of the transcript below is about that, return an empty list.

            SubtitleTranscript:
            \(chunk)
            """
        }
        return """
        Choose up to \(limit) segments from the transcript below that would work as standalone clips.

        SubtitleTranscript:
        \(chunk)
        """
    }

    // MARK: Validation

    /// The range of cue indices a chunk actually contains, read back out of the
    /// text rather than assumed.
    ///
    /// `numberedChunks` documents absolute indices, but a returned index that
    /// looks chunk-relative (0-based on the fourth chunk) is indistinguishable
    /// from a hallucination without this, and would silently map to the wrong
    /// moment in the video. Checking against the markers we actually sent turns
    /// that into a discard.
    static func markerBounds(in chunk: String) -> ClosedRange<Int>? {
        var lo = Int.max, hi = Int.min
        var scanning = false
        var digits = ""
        for ch in chunk {
            if ch == "[" { scanning = true; digits = ""; continue }
            if scanning {
                if ch.isNumber { digits.append(ch) }
                else {
                    if ch == "]", let n = Int(digits) { lo = min(lo, n); hi = max(hi, n) }
                    scanning = false
                }
            }
        }
        return lo <= hi ? lo...hi : nil
    }

    /// Index-only half of validation: order, range, and the chunk-relative check.
    /// Split out from `validate` so the clamping path can be exercised without
    /// having to coax the model into emitting a bad index.
    ///
    /// Returns nil when the answer should be discarded outright.
    static func resolveRange(startCue: Int, endCue: Int,
                             global: ClosedRange<Int>, chunk: ClosedRange<Int>?) -> ClosedRange<Int>? {
        var lo = min(startCue, endCue)
        var hi = max(startCue, endCue)

        // Wholly outside the transcript is a hallucination, not an off-by-one.
        guard hi >= global.lowerBound, lo <= global.upperBound else { return nil }

        // Wholly outside the chunk we sent, but inside the transcript, is the
        // chunk-relative signature. Discarding is right: clamping would produce
        // a confidently wrong moment somewhere else in the video.
        if let chunk, hi < chunk.lowerBound || lo > chunk.upperBound { return nil }

        lo = max(lo, global.lowerBound)
        hi = min(hi, global.upperBound)
        guard lo <= hi else { return nil }
        return lo...hi
    }

    private func validate(_ raw: [ModelClip], transcript: SubtitleTranscript,
                          chunkBounds: ClosedRange<Int>?) -> [SuggestedClip] {
        guard let first = transcript.cues.first, let last = transcript.cues.last else { return [] }
        let global = first.index...last.index

        var out: [SuggestedClip] = []
        for clip in raw {
            guard let resolved = Self.resolveRange(startCue: clip.startCue, endCue: clip.endCue,
                                                   global: global, chunk: chunkBounds) else { continue }
            let lo = resolved.lowerBound, hi = resolved.upperBound

            guard let range = transcript.timeRange(from: lo, to: hi), range.end > range.start else { continue }

            let title = Self.tidy(clip.title, fallback: transcript.cues(from: lo, to: hi).first?.text ?? "Clip")
            let reason = clip.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(SuggestedClip(title: title, startCue: lo, endCue: hi,
                                     start: range.start, end: range.end,
                                     rationale: reason.isEmpty ? nil : reason))
        }
        return out
    }

    private static func tidy(_ title: String, fallback: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        if t.isEmpty { t = String(fallback.prefix(48)) }
        if t.count > 64 { t = String(t.prefix(63)) + "…" }
        return t
    }

    // MARK: Reduce

    /// Collapses suggestions that describe the same moment.
    ///
    /// Chunks are scored independently, so a passage spanning a chunk boundary is
    /// seen twice — once truncated at the end of one chunk, once truncated at the
    /// start of the next. Those two halves *abut* rather than overlap, so they
    /// need joining too.
    ///
    /// But joining every abutting pair chains: two genuinely different clips that
    /// happen to sit back to back become one, and a run of them swallows half the
    /// video (observed: three good suggestions collapsing into a single two-minute
    /// span). So abutting pairs join only at a real chunk boundary, which is the
    /// only place the artefact can occur. `boundaries` holds the last cue index of
    /// every chunk except the final one.
    func merge(_ clips: [SuggestedClip], acrossBoundariesAt boundaries: Set<Int> = []) -> [SuggestedClip] {
        guard !clips.isEmpty else { return [] }
        let sorted = clips.sorted { ($0.startCue, $0.endCue) < ($1.startCue, $1.endCue) }

        var merged: [SuggestedClip] = []
        for clip in sorted {
            guard var open = merged.last else { merged.append(clip); continue }

            let overlaps = clip.startCue <= open.endCue
            let bridgesBoundary = clip.startCue == open.endCue + 1 && boundaries.contains(open.endCue)
            guard overlaps || bridgesBoundary else { merged.append(clip); continue }

            let wasLonger = (open.endCue - open.startCue) >= (clip.endCue - clip.startCue)
            open.endCue = max(open.endCue, clip.endCue)
            open.end = max(open.end, clip.end)
            // Keep the title from whichever half saw more of the passage; the
            // truncated half usually titles it worse.
            if !wasLonger { open.title = clip.title }
            if open.rationale == nil { open.rationale = clip.rationale }
            merged[merged.count - 1] = open
        }
        return merged
    }
}
