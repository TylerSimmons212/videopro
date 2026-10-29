import Foundation
import Combine

// MARK: - Job

enum JobKind: Equatable, Sendable {
    case download(DownloadQuality)
    case export(ExportTarget)
    /// Joining a collection into one file. Shares the export lane: it is the same
    /// CPU-bound ffmpeg work, just N+1 processes instead of one or two.
    case buildCollection(String)

    /// What the user is told this job is. Kept here so a row, a notification and
    /// a log line can never describe the same job differently.
    var label: String {
        switch self {
        case .download(let q): return "Download · \(q.rawValue)"
        case .export(let t):   return "Export · \(t.displayName)"
        case .buildCollection(let name): return "Build · \(name)"
        }
    }

    var symbolName: String {
        switch self {
        case .download: return "arrow.down.circle"
        case .export:   return "square.and.arrow.up.on.square"
        case .buildCollection: return "film.stack"
        }
    }
}

enum JobState: Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed(String)
    case cancelled
    /// Stopped by the user with its partial data kept. Terminal for the *job* —
    /// it gives its slot back — and resuming starts a fresh job that picks the
    /// data up, the same way a retry does.
    case paused
}

/// One unit of user-visible work.
///
/// The title is denormalised rather than looked up from the item: history has to
/// keep reading correctly after the item it refers to has expired out of the
/// Inbox or been removed, and a row that says "Export · (missing)" is worse than
/// no history at all.
@MainActor
final class Job: ObservableObject, Identifiable {
    let id: UUID
    let itemID: UUID
    let title: String
    let kind: JobKind

    @Published var state: JobState
    /// 0...1, or -1 when the work can't say — yt-dlp before the first progress
    /// line, ffmpeg with no known duration.
    @Published var progress: Double
    @Published var detail: String

    let createdAt: Date
    private(set) var finishedAt: Date?

    /// Set by the running work so the center can stop it (e.g. terminate a
    /// process). Cancelling a job that never set this still settles the job —
    /// the work simply finds itself orphaned and its result ignored.
    var onCancel: (() -> Void)?
    /// Like `onCancel`, but the work stops keeping what it has. Unset for work
    /// that can't be resumed, which is then simply stopped.
    var onPause: (() -> Void)?

    init(itemID: UUID, title: String, kind: JobKind) {
        self.id = UUID()
        self.itemID = itemID
        self.title = title
        self.kind = kind
        self.state = .queued
        self.progress = -1
        self.detail = ""
        self.createdAt = Date()
    }

    var isActive: Bool {
        switch state {
        case .queued, .running: return true
        default: return false
        }
    }
    var isFinished: Bool { !isActive }

    /// Only JobCenter drives terminal state — that is the invariant that keeps a
    /// slot accounted for by exactly one owner.
    fileprivate func markFinished(_ newState: JobState) {
        state = newState
        finishedAt = Date()
        if case .succeeded = newState { progress = 1 }
    }
}

// MARK: - Job center

/// The scheduler behind every long operation in the app.
///
/// It replaces an `activeDownloads` integer that was decremented in exactly one
/// place — a completion callback — and therefore had exactly one way to reach
/// zero. Anything that stopped the callback arriving (a starved dispatch queue
/// swallowing `Process.terminationHandler`, see DownloadManager's probe pool)
/// left the count permanently high and wedged the queue for the session.
///
/// Here occupancy is *derived* from job state rather than counted, and terminal
/// state is reachable two ways: the work reporting back, or the center settling
/// the job itself on cancel. A work closure that never returns can no longer
/// hold a slot, because nothing is waiting on it to release one.
@MainActor
final class JobCenter: ObservableObject {
    static let shared = JobCenter()

    /// Oldest first — the queue order. Views read `active`/`history`, which
    /// present it newest first.
    @Published private(set) var jobs: [Job] = []

    /// Independent per-lane limits. Downloads are network-bound and three at a
    /// time is what the old queue ran; ffmpeg exports are CPU-bound, and running
    /// several finishes them all later than running them in sequence. Sharing one
    /// pool would also let a slow download block an export that costs no
    /// bandwidth at all, so the lanes never see each other.
    private enum Lane: Hashable {
        case download, export

        var limit: Int {
            switch self {
            case .download: return 3
            case .export:   return 1
            }
        }
    }

    /// Bounded so a long session can't accumulate history without limit.
    private let historyLimit = 50

    /// Kept so a failed job can be retried without the caller having to rebuild
    /// the operation, and dropped the moment a job leaves the list.
    private var work: [UUID: @MainActor (Job) async -> Bool] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    // MARK: Queries

    var active: [Job] { jobs.filter(\.isActive).reversed() }
    var history: [Job] { jobs.filter(\.isFinished).reversed() }
    var activeCount: Int { jobs.count { $0.state == .running } }
    var queuedCount: Int { jobs.count { $0.state == .queued } }

    // MARK: Enqueue

    @discardableResult
    func enqueue(itemID: UUID, title: String, kind: JobKind,
                 work body: @escaping @MainActor (Job) async -> Bool) -> Job {
        let job = Job(itemID: itemID, title: title, kind: kind)
        work[job.id] = body
        jobs.append(job)
        pump(lane(of: kind))
        return job
    }

    // MARK: Control

    func cancel(_ job: Job) {
        guard job.isActive else { return }
        // Runs for a running job; a no-op for a queued one, whose work never
        // started and so has nothing to interrupt.
        job.onCancel?()
        stopTask(for: job.id)
        finish(job, .cancelled)
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job) }
    }

    /// Stop a job and free its slot, keeping whatever it has done so far.
    func pause(_ job: Job) {
        guard job.isActive else { return }
        if let onPause = job.onPause { onPause() } else { job.onCancel?() }
        stopTask(for: job.id)
        finish(job, .paused)
    }

    /// Re-runs the original work on a *fresh* job, leaving the failed one in
    /// history.
    ///
    /// Resetting the existing job would move it backwards out of a terminal
    /// state — the one thing this design promises never happens — and would erase
    /// the record of the failure just as the user is deciding whether the retry
    /// is worth attempting. Two rows also read honestly: it failed, then it was
    /// tried again.
    func retry(_ job: Job) {
        guard let body = work[job.id] else { return }
        enqueue(itemID: job.itemID, title: job.title, kind: job.kind, work: body)
    }

    func clearHistory() {
        for job in jobs where job.isFinished { work[job.id] = nil }
        jobs.removeAll(where: \.isFinished)
    }

    // MARK: Scheduling

    private func lane(of kind: JobKind) -> Lane {
        switch kind {
        case .download: return .download
        case .export:   return .export
        case .buildCollection: return .export
        }
    }

    private func running(in lane: Lane) -> Int {
        jobs.count { $0.state == .running && self.lane(of: $0.kind) == lane }
    }

    private func pump(_ lane: Lane) {
        while running(in: lane) < lane.limit,
              let next = jobs.first(where: { $0.state == .queued && self.lane(of: $0.kind) == lane }) {
            start(next)
        }
    }

    private func start(_ job: Job) {
        guard let body = work[job.id] else {
            // No work to run: settle it rather than leave it queued forever.
            finish(job, .failed("Nothing to run"))
            return
        }
        job.state = .running
        objectWillChange.send()

        tasks[job.id] = Task { @MainActor [weak self] in
            let ok = await body(job)
            guard let self else { return }
            // The job may already have been settled by a cancel while this was in
            // flight. A late result must never resurrect it or double-release a
            // slot that has already been handed to the next job.
            guard job.state == .running else { return }
            self.tasks[job.id] = nil
            self.finish(job, ok ? .succeeded : .failed(job.detail.isEmpty ? "Failed" : job.detail))
        }
    }

    private func stopTask(for id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func finish(_ job: Job, _ state: JobState) {
        job.markFinished(state)
        job.onCancel = nil
        job.onPause = nil
        objectWillChange.send()
        trimHistory()
        pump(lane(of: job.kind))
    }

    private func trimHistory() {
        let finished = jobs.filter(\.isFinished)
        guard finished.count > historyLimit else { return }
        let doomed = Set(finished.prefix(finished.count - historyLimit).map(\.id))
        for id in doomed { work[id] = nil }
        jobs.removeAll { doomed.contains($0.id) }
    }
}
