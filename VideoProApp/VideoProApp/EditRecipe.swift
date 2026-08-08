import Foundation

// MARK: - Rotation

/// Only the four lossless right-angle steps. Arbitrary-angle rotation needs
/// padding, a background colour, and interpolation choices — none of which the
/// single-clip editor exposes, so admitting it into the model would create a
/// state the UI can't produce and the planner would have to guess at.
enum Rotation: String, Codable, Equatable, Sendable, CaseIterable {
    case none
    case cw90
    case ccw90
    case half   // 180°

    /// True when the transform swaps the frame's axes, so callers sizing a
    /// preview don't have to re-derive it from the case list.
    var swapsAxes: Bool { self == .cw90 || self == .ccw90 }
}

// MARK: - Crop

/// Normalised 0...1 against source dimensions, so a recipe survives the source
/// being re-encoded at a different resolution.
///
/// Storing pixels would silently mis-crop the moment the same recipe is applied
/// to a re-downloaded 1080p copy of a clip that was trimmed at 720p — which is
/// a routine event here, since the export path will happily fetch a fresh source
/// when the local file is gone. Normalised coordinates make that a no-op.
struct CropRect: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    static let full = CropRect(x: 0, y: 0, width: 1, height: 1)

    /// Slack rather than `== .full`: crop handles are dragged with a mouse, and
    /// a rect that is 0.9997 of the frame is a user who meant "no crop". Emitting
    /// a real crop filter for that costs a re-encode and shaves a pixel row.
    var isFull: Bool {
        x <= 0.001 && y <= 0.001 && width >= 0.999 && height >= 0.999
    }

    /// Clamped to the frame and to a non-degenerate size. The planner works from
    /// this rather than the raw values, because a rect dragged past the edge of
    /// the preview would otherwise become a `crop` filter with a negative offset
    /// and ffmpeg fails the whole invocation rather than clamping.
    var normalised: CropRect {
        let cx = min(max(x, 0), 1)
        let cy = min(max(y, 0), 1)
        return CropRect(x: cx, y: cy,
                        width: min(max(width, 0.01), 1 - cx),
                        height: min(max(height, 0.01), 1 - cy))
    }
}

// MARK: - Recipe

/// A non-destructive description of an edit. Persisted on the library item and
/// replayed at export time, so the same clip can be sent to a Reel, a GIF, and a
/// ProRes master without three destructive round-trips through ffmpeg.
///
/// Every field is a *declaration of intent*, never a rendered artefact — nothing
/// in here refers to a file, a resolution the source happens to have today, or a
/// previously chosen export target.
struct EditRecipe: Codable, Equatable, Sendable {
    /// Seconds into the source; nil = start of file.
    var inPoint: Double?
    /// Seconds into the source; nil = end of file.
    var outPoint: Double?
    /// nil = no crop.
    var crop: CropRect?
    var rotation: Rotation
    /// 1.0 = unchanged. See `speedRange` for why it is bounded.
    var speed: Double
    /// Target height in pixels; nil = keep source.
    var scaleHeight: Int?
    var flipHorizontal: Bool
    var mute: Bool

    /// Bounded because the audio path is the binding constraint: `atempo` is
    /// chained to reach anything outside 0.5–2.0, and past two links the
    /// artefacts are audible enough that the result isn't worth shipping.
    static let speedRange: ClosedRange<Double> = 0.25...4.0

    init(inPoint: Double? = nil,
         outPoint: Double? = nil,
         crop: CropRect? = nil,
         rotation: Rotation = .none,
         speed: Double = 1.0,
         scaleHeight: Int? = nil,
         flipHorizontal: Bool = false,
         mute: Bool = false) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.crop = crop
        self.rotation = rotation
        self.speed = speed
        self.scaleHeight = scaleHeight
        self.flipHorizontal = flipHorizontal
        self.mute = mute
    }

    static let identity = EditRecipe()

    /// True when the recipe asks for nothing. Drives the stream-copy fast path in
    /// `ExportPlan`, so it deliberately treats a full-frame crop and an
    /// out-of-range speed of exactly 1.0 as "nothing", rather than only accepting
    /// the literal `.identity` value the UI may never construct.
    var isIdentity: Bool {
        inPoint == nil
            && outPoint == nil
            && (crop == nil || crop!.isFull)
            && rotation == .none
            && abs(speed - 1.0) < 0.0001
            && scaleHeight == nil
            && !flipHorizontal
            && !mute
    }

    /// Speed with the model's bounds actually enforced. The planner uses this
    /// rather than `speed` directly: a decoded recipe from a future build, or a
    /// text field that got a `0`, would otherwise produce `setpts=PTS/0`.
    var effectiveSpeed: Double {
        guard speed.isFinite, speed > 0 else { return 1.0 }
        return min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)
    }

    /// Seconds of source consumed, before speed is applied. nil when the answer
    /// depends on a source duration we weren't given.
    func sourceSpan(sourceDuration: Double?) -> Double? {
        let start = max(0, inPoint ?? 0)
        let end: Double?
        if let outPoint {
            // A stale out-point past the end of a re-fetched source is clamped
            // rather than rejected — the recipe is still meaningful, it just runs
            // to the end of the file.
            end = sourceDuration.map { min(outPoint, $0) } ?? outPoint
        } else {
            end = sourceDuration
        }
        guard let end else { return nil }
        return max(0, end - start)
    }

    /// Output duration given the source duration, accounting for trim and speed.
    ///
    /// This — not the source duration — is what a size-targeted export must
    /// divide by, since trimming and speed both change how many seconds of video
    /// the bitrate budget has to cover.
    func outputDuration(sourceDuration: Double?) -> Double? {
        guard let span = sourceSpan(sourceDuration: sourceDuration) else { return nil }
        return span / effectiveSpeed
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case inPoint, outPoint, crop, rotation, speed, scaleHeight, flipHorizontal, mute
    }

    /// Hand-written because this is persisted on `VideoMeta`. Swift's synthesised
    /// `Decodable` throws on a missing key even when the property has a default,
    /// so the first build that adds a field to this struct would fail to decode
    /// every library written by the previous one — and a failed library load is a
    /// user-visible data loss event here, not a warning.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inPoint = try c.decodeIfPresent(Double.self, forKey: .inPoint)
        outPoint = try c.decodeIfPresent(Double.self, forKey: .outPoint)
        crop = try c.decodeIfPresent(CropRect.self, forKey: .crop)
        rotation = try c.decodeIfPresent(Rotation.self, forKey: .rotation) ?? .none
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        scaleHeight = try c.decodeIfPresent(Int.self, forKey: .scaleHeight)
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        mute = try c.decodeIfPresent(Bool.self, forKey: .mute) ?? false
    }
}
