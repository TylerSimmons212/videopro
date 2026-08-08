import SwiftUI

/// Ask for a clip, or let the model propose some.
///
/// Two modes, one mechanism. Asking ("the part about pricing") is retrieval and a
/// small on-device model is good at it; proposing without a query is judgement,
/// which it is markedly weaker at. The search field leads for that reason —
/// suggestions are the fallback, not the headline.
struct ClipFinderView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var item: VideoItem
    @Environment(\.dismiss) private var dismiss
    /// Handing a clip back to the editor rather than exporting straight from here:
    /// a suggestion is a starting point, and the boundaries usually want nudging.
    var onOpen: (SuggestedClip) -> Void

    @State private var query = ""
    @State private var clips: [SuggestedClip] = []
    @State private var working = false
    @State private var message: String?
    @State private var searched = false

    private var blocker: String? { state.clipSuggestBlocker(for: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let blocker {
                ContentUnavailableView("Clip finding isn’t available",
                                       systemImage: "sparkles.slash",
                                       description: Text(blocker))
                    .frame(height: 240)
            } else {
                searchBar
                Divider()
                results
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 470)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Find Clips").font(.headline)
            Text(item.meta.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("What are you looking for? e.g. “the part about pricing”", text: $query)
                .textFieldStyle(.plain)
                .onSubmit { run(query: query) }
            if working { ProgressView().controlSize(.small) }
            Button("Find") { run(query: query) }
                .disabled(working || query.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Suggest") { run(query: nil) }
                .disabled(working)
                .help("Let VideoPro propose clips without a search")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private var results: some View {
        if let message {
            ContentUnavailableView("No clips", systemImage: "text.magnifyingglass",
                                   description: Text(message))
        } else if clips.isEmpty {
            ContentUnavailableView(
                searched ? "Nothing matched" : "Ask for a clip",
                systemImage: searched ? "text.magnifyingglass" : "sparkles",
                description: Text(searched
                    ? "Nothing in this video matched. Try different words."
                    : "Search the spoken words, or press Suggest to see proposals."))
        } else {
            List(clips) { clip in
                Button { onOpen(clip); dismiss() } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(clip.title).font(.system(size: 13, weight: .medium))
                            HStack(spacing: 6) {
                                Text(Self.timecode(clip.start) + " – " + Self.timecode(clip.end))
                                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                                Text(Self.duration(clip.end - clip.start))
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            if let why = clip.rationale, !why.isEmpty {
                                Text(why).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                            }
                        }
                        Spacer()
                        Image(systemName: "arrow.forward.circle").foregroundStyle(.tint)
                    }
                    .contentShape(.rect)
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack {
            // Worth stating plainly: this is the differentiator over cloud tools.
            Label("Runs entirely on this Mac", systemImage: "lock.shield")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func run(query: String?) {
        working = true
        message = nil
        searched = true
        Task {
            defer { working = false }
            // Extraction can take a moment on a long file, so it happens here
            // rather than behind the menu item that opened this sheet.
            guard let transcript = await state.transcript(for: item) else {
                clips = []
                message = "No subtitles found in this video. Re-download it with “Embed subtitles” turned on."
                return
            }
            do {
                let found: [SuggestedClip]
                if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    found = try await ClipSuggester.shared.find(query, in: transcript, limit: 5)
                } else {
                    found = try await ClipSuggester.shared.suggest(in: transcript, limit: 5)
                }
                clips = found
                // An empty result is a real answer — the video genuinely doesn't
                // cover it — so say so rather than showing a blank list.
                if found.isEmpty && query != nil {
                    message = "Nothing in this video matched “\(query!)”."
                }
            } catch let error as ClipSuggestError {
                clips = []
                message = error.errorDescription ?? "Couldn’t analyse this video."
            } catch {
                clips = []
                message = error.localizedDescription
            }
        }
    }

    private static func timecode(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0fs", seconds)
                     : String(format: "%.1f min", seconds / 60)
    }
}
