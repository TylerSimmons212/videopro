import SwiftUI

/// Everything the app is doing, or has recently done.
///
/// Replaces ActivityPopover, which could only show downloads because downloads
/// were the only thing that had a queue. Exports now share the same model, so
/// they get progress, cancel, retry and a record for free rather than a spinner
/// on a row that vanishes without saying whether it worked.
struct ActivityCenterView: View {
    @ObservedObject private var center = JobCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if center.jobs.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        section("In progress", jobs: center.active) { job in
                            ActiveJobRow(job: job)
                        }
                        section("Recent", jobs: center.history) { job in
                            FinishedJobRow(job: job)
                        }
                    }
                    .padding(.vertical, 4)
                }
                // Tall enough to show a working queue, short enough that a full
                // history doesn't turn a popover into a window.
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Activity").font(.subheadline).fontWeight(.semibold)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !center.active.isEmpty {
                Button("Stop All") { center.cancelAll() }
                    .controlSize(.small)
            }
            if !center.history.isEmpty {
                Button("Clear") { center.clearHistory() }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var summary: String {
        let running = center.activeCount, queued = center.queuedCount
        if running == 0 && queued == 0 { return "Idle" }
        var parts = ["\(running) running"]
        if queued > 0 { parts.append("\(queued) waiting") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.title2).foregroundStyle(.secondary)
            Text("Nothing running").font(.callout)
            Text("Downloads and exports show up here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    @ViewBuilder
    private func section<Row: View>(_ title: String, jobs: [Job],
                                    @ViewBuilder row: @escaping (Job) -> Row) -> some View {
        if !jobs.isEmpty {
            Text(title.uppercased())
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)
            ForEach(jobs) { job in
                row(job)
                    .padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
    }
}

// MARK: - Rows

/// Observes the Job itself, not the center — progress ticks several times a
/// second and must not redraw the whole list to do it.
private struct ActiveJobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: job.kind.symbolName)
                    .font(.caption).foregroundStyle(.tint)
                Text(job.title).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Button { JobCenter.shared.cancel(job) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Cancel")
            }

            if job.state == .queued {
                Text("Waiting · \(job.kind.label)")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if job.progress < 0 {
                ProgressView().progressViewStyle(.linear)
            } else {
                ProgressView(value: min(max(job.progress, 0), 1))
                    .progressViewStyle(.linear)
            }

            if job.state == .running {
                Text(job.detail.isEmpty ? job.kind.label : job.detail)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct FinishedJobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(isFailure ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(job.title).font(.caption).lineLimit(1)
                Text(outcome)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            // Cancelled work is offered a retry too — a user who stopped a
            // download and changed their mind shouldn't have to find the item
            // again to start it over.
            if isFailure {
                Button("Retry") { JobCenter.shared.retry(job) }
                    .controlSize(.small)
            }
        }
    }

    private var isFailure: Bool {
        switch job.state {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    private var symbol: String {
        switch job.state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .cancelled: return "slash.circle"
        default:         return "circle"
        }
    }

    private var outcome: String {
        switch job.state {
        case .succeeded:         return job.kind.label
        case .failed(let why):   return why
        case .cancelled:         return "Cancelled · \(job.kind.label)"
        default:                 return job.kind.label
        }
    }
}
