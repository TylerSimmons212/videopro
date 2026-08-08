import SwiftUI
import AVKit
import Combine

// MARK: - Model

/// A chapter mark drawn on the timeline. `start` only — chapter *ends* are
/// implicit (the next chapter, or the end of the clip), and storing them would
/// let the two disagree after an edit.
struct TimelineChapter: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let start: Double

    init(id: UUID = UUID(), title: String, start: Double) {
        self.id = id
        self.title = title
        self.start = start
    }
}

// MARK: - Timeline

/// A scrubbable timeline with draggable in/out handles over a live player.
///
/// This replaces blind text-field time entry: you cannot pick a trim point you
/// can't see, and "0:00 → 1:23" gives no feedback about whether 1:23 lands
/// mid-word or mid-cut.
struct TimelineView: View {
    let player: AVPlayer
    let duration: Double
    @Binding var inPoint: Double
    @Binding var outPoint: Double
    /// Optional chapter marks to draw on the track: (title, startSeconds).
    var chapters: [TimelineChapter] = []
    /// Frames per second, used for frame-accurate stepping. Nil → assume 30.
    var fps: Double? = nil

    // Private stored properties with defaults are excluded from the synthesised
    // memberwise init, so integration code still gets the documented signature.
    @StateObject private var clock = PlayerClock()
    @State private var drag: DragTarget?
    /// Where the finger is during a drag. The player's own clock lags a seek by
    /// a frame or two, and a readout that stutters backwards while you drag
    /// feels broken — so the drag value wins until the drag ends.
    @State private var scrubTime: Double?

    private enum DragTarget { case inPoint, outPoint, playhead }

    private enum Metrics {
        static let trackHeight: CGFloat = 34
        static let handleWidth: CGFloat = 11
        /// Pointer slop for grabbing a handle. Generous, because the handles sit
        /// on top of the scrub area and losing a handle grab silently jumps the
        /// playhead instead — a much worse outcome than a slightly sticky handle.
        static let grabRadius: CGFloat = 12
    }

    private var safeDuration: Double { max(duration, 0.001) }
    private var frameDuration: Double { 1.0 / max(fps ?? 30, 1) }
    private var displayTime: Double { scrubTime ?? clock.currentTime }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                track(width: geo.size.width)
            }
            .frame(height: Metrics.trackHeight)
            readout
        }
        .onAppear { clock.attach(to: player) }
        // The single most important line in this file: an AVPlayer outlives its
        // SwiftUI view, so a periodic observer left behind keeps firing (and
        // keeps this view's state alive) for the life of the player.
        .onDisappear { clock.detach() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { stepFrames(player: player, count: -1, fps: fps); return .handled }
        .onKeyPress(.rightArrow) { stepFrames(player: player, count: 1, fps: fps); return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    // MARK: Track

    @ViewBuilder
    private func track(width: CGFloat) -> some View {
        let inX = x(for: inPoint, width: width)
        let outX = x(for: outPoint, width: width)
        let headX = x(for: displayTime, width: width)

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)

            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.30))
                .frame(width: max(outX - inX, 1))
                .offset(x: inX)

            // Dim the excluded head and tail by laying the window background over
            // them: it resolves light in light mode and dark in dark mode, so one
            // opacity reads as "muted" in both without naming a colour.
            Rectangle()
                .fill(.background.opacity(0.55))
                .frame(width: max(inX, 0))
            Rectangle()
                .fill(.background.opacity(0.55))
                .frame(width: max(width - outX, 0))
                .offset(x: outX)

            chapterMarks(width: width)

            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: max(outX - inX, 1))
                .offset(x: inX)

            handle(at: inX, leading: true, label: "In point")
            handle(at: outX, leading: false, label: "Out point")
            // Last, so it stays visible when it's parked exactly on a handle —
            // which is the common case right after "jump to in".
            playhead(at: headX)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .gesture(dragGesture(width: width))
    }

    @ViewBuilder
    private func chapterMarks(width: CGFloat) -> some View {
        ForEach(chapters) { chapter in
            if chapter.start > 0, chapter.start < duration {
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 1.5)
                    .offset(x: x(for: chapter.start, width: width) - 0.75)
                    .help(chapter.title)
            }
        }
    }

    @ViewBuilder
    private func playhead(at x: CGFloat) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.primary)
                .frame(width: 2)
            Circle()
                .fill(.primary)
                .frame(width: 7, height: 7)
                .offset(y: -1)
        }
        .frame(width: 7)
        // Half the ZStack width, so the 2pt line straddles the time rather than
        // sitting to the right of it.
        .offset(x: x - 3.5)
        .shadow(radius: 1)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func handle(at x: CGFloat, leading: Bool, label: String) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor)
            .frame(width: Metrics.handleWidth)
            .overlay(
                Rectangle()
                    .fill(.background.opacity(0.7))
                    .frame(width: 1.5, height: 12)
            )
            // Handles bracket the selection rather than centring on it, so the
            // highlighted region is exactly what gets exported — a centred handle
            // would put half a handle's width of "selected" pixels outside it.
            .offset(x: leading ? x : x - Metrics.handleWidth)
            .help(label)
    }

    // MARK: Readout

    private var readout: some View {
        HStack(spacing: 10) {
            Text(TimelineView.timecode(displayTime))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
            Text("/ \(TimelineView.timecode(duration))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Label {
                Text("\(TimelineView.timecode(inPoint)) → \(TimelineView.timecode(outPoint))")
            } icon: {
                Image(systemName: "scissors")
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)

            Text(TimelineView.timecode(max(outPoint - inPoint, 0)))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tint)
                .help("Selection duration")
        }
        .lineLimit(1)
    }

    // MARK: Interaction

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let target = drag ?? nearestTarget(toX: value.startLocation.x, width: width)
                if drag == nil { drag = target }
                let t = clamp(time(atX: value.location.x, width: width), 0, duration)
                switch target {
                case .inPoint:
                    // A one-frame floor rather than zero: a zero-length selection
                    // exports nothing and the two handles become unpickable.
                    inPoint = clamp(t, 0, max(outPoint - frameDuration, 0))
                    scrubTime = inPoint
                    clock.seekExact(to: inPoint)
                case .outPoint:
                    outPoint = clamp(t, min(inPoint + frameDuration, duration), duration)
                    scrubTime = outPoint
                    clock.seekExact(to: outPoint)
                case .playhead:
                    scrubTime = t
                    clock.seekExact(to: t)
                }
            }
            .onEnded { _ in
                drag = nil
                scrubTime = nil
            }
    }

    /// Handles win over the scrub track inside `grabRadius`, and the closer one
    /// wins when they're stacked on top of each other at a tiny selection.
    private func nearestTarget(toX px: CGFloat, width: CGFloat) -> DragTarget {
        let dIn = abs(px - x(for: inPoint, width: width))
        let dOut = abs(px - x(for: outPoint, width: width))
        guard min(dIn, dOut) <= Metrics.grabRadius else { return .playhead }
        return dIn <= dOut ? .inPoint : .outPoint
    }

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(clamp(seconds, 0, safeDuration) / safeDuration) * width
    }

    private func time(atX px: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(px / width) * safeDuration
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), max(lo, hi))
    }

    /// `H:MM:SS.ss`. Hundredths are always shown: at this zoom one timeline pixel
    /// can be a handful of frames, so a whole-second readout can't confirm the
    /// handle is where you meant to put it.
    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00:00.00" }
        let hundredths = (seconds * 100).rounded()
        let total = Int(hundredths)
        let (h, m, s, cs) = (total / 360_000, (total / 6_000) % 60, (total / 100) % 60, total % 100)
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }
}

// MARK: - Transport

/// Transport controls: play/pause, frame step, jump to in/out, loop toggle.
struct TransportControls: View {
    let player: AVPlayer
    @Binding var inPoint: Double
    @Binding var outPoint: Double
    @Binding var loopSelection: Bool
    var fps: Double? = nil

    @StateObject private var transport = TransportObserver()

    var body: some View {
        HStack(spacing: 6) {
            button("arrow.left.to.line", "Jump to in point") { seek(to: inPoint) }
            button("backward.frame", "Step back one frame") {
                stepFrames(player: player, count: -1, fps: fps)
            }

            Button {
                if transport.isPlaying {
                    player.pause()
                } else {
                    // Pressing play with loop armed but the playhead outside the
                    // selection would otherwise play unrelated footage until it
                    // happened to cross the out boundary.
                    if loopSelection {
                        let now = player.currentTime().seconds
                        if !now.isFinite || now < inPoint || now >= outPoint { seek(to: inPoint) }
                    }
                    player.play()
                }
            } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 22)
            }
            .help(transport.isPlaying ? "Pause" : "Play")
            .keyboardShortcut(.space, modifiers: [])

            button("forward.frame", "Step forward one frame") {
                stepFrames(player: player, count: 1, fps: fps)
            }
            button("arrow.right.to.line", "Jump to out point") { seek(to: outPoint) }

            Divider().frame(height: 16)

            Toggle(isOn: $loopSelection) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Loop the selection")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        // Arm the loop here rather than in a `.task`, so it can't race the attach
        // that gives the observer a player to install itself on.
        .onAppear {
            transport.attach(to: player)
            syncLoop()
        }
        // Same contract as the timeline's clock: rate KVO, the boundary observer
        // and the end-of-item notification all get dropped here, not at dealloc.
        .onDisappear { transport.detach() }
        .onChange(of: loopSelection) { syncLoop() }
        .onChange(of: inPoint) { syncLoop() }
        .onChange(of: outPoint) { syncLoop() }
    }

    private func syncLoop() {
        transport.syncLoop(enabled: loopSelection, start: inPoint, end: outPoint)
    }

    private func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @ViewBuilder
    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22)
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Frame stepping

/// One frame, exactly.
///
/// `step(byCount:)` moves the item by decoded frames, so it lands on real frame
/// boundaries whatever the source rate is. Seeking by `1/fps` is a fallback only:
/// it assumes a constant frame rate the file may not have, and repeated steps
/// accumulate rounding drift until the preview and the export disagree.
@discardableResult
func stepFrames(player: AVPlayer, count: Int, fps: Double?) -> Bool {
    guard let item = player.currentItem else { return false }
    // Stepping during playback fights the playback clock; the frame you land on
    // is gone before it's drawn.
    player.pause()

    if count > 0 ? item.canStepForward : item.canStepBackward {
        item.step(byCount: count)
        return true
    }

    let frame = 1.0 / max(fps ?? 30, 1)
    let now = player.currentTime().seconds
    guard now.isFinite else { return false }
    let target = max(now + Double(count) * frame, 0)
    player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero, toleranceAfter: .zero)
    return false
}

// MARK: - Observers

/// Owns the periodic time observer and the seek pipeline for one player.
///
/// A reference type rather than view state because a token has to be *removed*
/// from the exact player it was added to, and SwiftUI structs get recreated
/// freely — there'd be nothing stable to remove from.
private final class PlayerClock: ObservableObject {
    @Published var currentTime: Double = 0

    /// Weak: the player belongs to the window, not to us. Holding it strongly
    /// would keep audio-capable objects alive after the view is gone.
    private weak var player: AVPlayer?
    private var token: Any?

    private var isSeeking = false
    private var pendingSeek: CMTime?

    func attach(to player: AVPlayer, interval: Double = 1.0 / 30.0) {
        // Idempotent: a re-attach (player swap, view re-appear) must not orphan
        // the previous token, which nothing else would ever be able to remove.
        detach()
        self.player = player
        token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: interval, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            // Weak self breaks the retain cycle: the player retains this closure.
            guard let self, time.isNumeric else { return }
            self.currentTime = time.seconds
        }
    }

    func detach() {
        if let token, let player { player.removeTimeObserver(token) }
        token = nil
        pendingSeek = nil
        isSeeking = false
        player = nil
    }

    /// Last-resort cleanup for the paths that skip `onDisappear` (a view torn
    /// down inside a window being closed doesn't always get one).
    deinit { detach() }

    /// Zero-tolerance seek, coalesced.
    ///
    /// Zero tolerance because a sloppy seek lands on the nearest keyframe, and
    /// then the frame you set the in point on isn't the frame ffmpeg cuts at.
    /// Coalesced because an exact seek is expensive and a drag issues one per
    /// mouse-move event; without this the queue backs up and the preview lags
    /// seconds behind the handle.
    func seekExact(to seconds: Double) {
        guard let player else { return }
        pendingSeek = CMTime(seconds: max(seconds, 0), preferredTimescale: 600)
        guard !isSeeking else { return }
        drainSeeks(player)
    }

    private func drainSeeks(_ player: AVPlayer) {
        guard let next = pendingSeek else { isSeeking = false; return }
        pendingSeek = nil
        isSeeking = true
        player.seek(to: next, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            guard self.player != nil else { self.isSeeking = false; return }
            self.drainSeeks(player)
        }
    }
}

/// Owns the play/pause state and the loop machinery.
private final class TransportObserver: ObservableObject {
    @Published var isPlaying = false

    private weak var player: AVPlayer?
    private var rateObservation: NSKeyValueObservation?
    private var boundaryToken: Any?
    private var endObserver: NSObjectProtocol?
    private var loopStart: Double = 0

    func attach(to player: AVPlayer) {
        detach()
        self.player = player
        isPlaying = player.rate != 0
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            // KVO on AVPlayer can land off the main thread.
            DispatchQueue.main.async { self?.isPlaying = player.rate != 0 }
        }
    }

    func detach() {
        removeLoop()
        rateObservation?.invalidate()
        rateObservation = nil
        player = nil
    }

    deinit { detach() }

    /// Re-arms the loop from scratch on every call.
    ///
    /// A boundary observer is bound to the times it was created with, so moving
    /// the out handle means a new observer — and the old one has to go, or the
    /// clip starts jumping back at a boundary the user already dragged away from.
    func syncLoop(enabled: Bool, start: Double, end: Double) {
        removeLoop()
        guard enabled, let player, end > start else { return }
        loopStart = start

        let target = CMTime(seconds: start, preferredTimescale: 600)
        boundaryToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: end, preferredTimescale: 600))],
            queue: .main
        ) { [weak player] in
            player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        // A boundary sitting on the last frame never fires — playback ends rather
        // than crossing it — so an out point at the end of the clip would loop
        // exactly once and then stop.
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            player?.play()
        }
    }

    private func removeLoop() {
        if let boundaryToken, let player { player.removeTimeObserver(boundaryToken) }
        boundaryToken = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }
}

// MARK: - Previews

#Preview("Timeline") {
    struct Harness: View {
        @State private var inPoint = 5.0
        @State private var outPoint = 20.0
        @State private var loop = false
        private let player = AVPlayer()

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(
                    player: player,
                    duration: 30,
                    inPoint: $inPoint,
                    outPoint: $outPoint,
                    chapters: [
                        TimelineChapter(title: "Intro", start: 0),
                        TimelineChapter(title: "The demo", start: 9),
                        TimelineChapter(title: "Wrap up", start: 23),
                    ],
                    fps: 30
                )
                TransportControls(player: player, inPoint: $inPoint,
                                  outPoint: $outPoint, loopSelection: $loop, fps: 30)
            }
            .padding()
            .frame(width: 560)
        }
    }
    return Harness()
}
