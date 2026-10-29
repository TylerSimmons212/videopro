import Foundation
import Combine

/// The one field at the top of the library.
///
/// Paste a link and it shows what's there before anything downloads: a single
/// video with every quality and its size, or every video on the page, playlist
/// or channel in a grid to pick from. Type anything that isn't a link and it
/// searches the library instead. Held by AppState rather than the view so the
/// menu bar, a menu command or the clipboard can put a link in it.
@MainActor
final class LinkSearch: ObservableObject {
    enum Phase {
        case idle
        case loading
        case loaded(LinkResult)
        case failed(String)
    }

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if !settingFromClipboard { fromClipboard = false }
            queryChanged()
        }
    }

    /// The link in the field was put there from the clipboard, not typed — the
    /// field says so, so a link appearing on its own isn't a mystery.
    @Published private(set) var fromClipboard = false
    @Published private(set) var phase: Phase = .idle

    /// Entry ids picked in the grid. Everything starts picked, as a playlist's
    /// link in a downloader usually means "these".
    @Published var selection = Set<String>()
    @Published var sectionIndex = 0 {
        didSet { if sectionIndex != oldValue { selectAll() } }
    }
    /// The quality a grid of videos downloads at.
    @Published var listQuality: DownloadQuality = .bestMP4
    /// The choice picked for a single video; nil means "the default".
    @Published var chosen: DownloadQuality?
    @Published private(set) var loadingMore = false

    /// Bumped to move keyboard focus into the field.
    @Published var focusToken = 0
    /// Whether the field has focus — the library's ⌘A must not steal select-all
    /// from the text being typed.
    @Published var fieldFocused = false

    weak var state: AppState?

    private var probeTask: Task<Void, Never>?
    private var moreTask: Task<Void, Never>?
    private var settingFromClipboard = false
    /// Return was pressed before the lookup finished.
    private var downloadWhenReady = false

    // MARK: Reading the field

    /// The field's text as a link, or nil when it should search the library.
    var link: String? { Self.link(from: query) }
    var isLinkMode: Bool { link != nil }

    /// What the library should filter by — nothing while the field holds a link.
    var librarySearch: String { isLinkMode ? "" : query }

    var isLoading: Bool { if case .loading = phase { return true }; return false }

    var result: LinkResult? { if case .loaded(let r) = phase { return r }; return nil }

    var currentSection: LinkSection? {
        guard let r = result, !r.sections.isEmpty else { return nil }
        return r.sections[min(sectionIndex, r.sections.count - 1)]
    }

    /// Selected entries of the visible section, in grid order.
    var selectedEntries: [LinkEntry] {
        currentSection?.entries.filter { selection.contains($0.id) } ?? []
    }

    /// Anything that parses as a web address. Bare words never do, so a search
    /// for "cats" stays a search; "youtu.be/abc" and "www.vimeo.com" are links.
    static func link(from text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace) else { return nil }
        let lower = t.lowercased()
        let candidate: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            candidate = t
        } else if lower.hasPrefix("www.") || (t.contains(".") && t.contains("/")) {
            candidate = "https://" + t
        } else {
            return nil
        }
        guard let url = URL(string: candidate), let host = url.host, host.contains(".") else { return nil }
        return candidate
    }

    /// The choice a single video starts on: the one matching the default
    /// quality, or the one that preset folded into.
    func defaultChoice(for video: LinkVideo, preferring q: DownloadQuality) -> QualityChoice? {
        if let c = video.choices.first(where: { $0.quality == q }) { return c }
        if q.isAudioOnly { return video.choices.first(where: \.isAudio) }
        // The preset was folded into another that picks the same file; find the
        // first video choice at or under its cap.
        let cap = q.heightCap ?? Int.max
        // Never fall back to Audio when a video quality was asked for.
        return video.choices.first { !$0.isAudio && ($0.height ?? 0) <= cap }
            ?? video.choices.first { !$0.isAudio }
            ?? video.choices.first
    }

    // MARK: Actions

    func focus() { focusToken += 1 }

    func clear() {
        probeTask?.cancel()
        moreTask?.cancel()
        query = ""
        phase = .idle
        selection = []
        chosen = nil
        downloadWhenReady = false
        loadingMore = false
    }

    /// Put a copied link in the field.
    func offer(_ link: String) {
        settingFromClipboard = true
        query = link
        fromClipboard = true
        settingFromClipboard = false
    }

    /// Show a link and download it as soon as it's known to be one video. A list
    /// is shown for picking instead — nobody means "all 400" by accident.
    func openAndDownload(_ link: String) {
        query = link
        downloadWhenReady = true
        focus()
    }

    /// Return in the field.
    func submit() {
        guard isLinkMode else { return }
        switch phase {
        case .loaded(let r):
            if r.isSingle { downloadSingle() } else if !selectedEntries.isEmpty { downloadSelected() }
        case .loading, .idle:
            downloadWhenReady = true
        case .failed:
            break
        }
    }

    func downloadSingle(addOnly: Bool = false) {
        guard let state, let r = result, let video = r.video else { return }
        let choice = chosen.flatMap { q in video.choices.first { $0.quality == q } }
            ?? defaultChoice(for: video, preferring: state.defaultQuality)
        state.takeLinkVideo(video, site: r.site, quality: choice?.quality ?? state.defaultQuality,
                            download: !addOnly)
        clear()
    }

    func downloadSelected() {
        guard let state, let r = result else { return }
        let entries = selectedEntries
        guard !entries.isEmpty else { return }
        state.takeLinkEntries(entries, site: r.site, quality: listQuality)
        clear()
    }

    func toggle(_ entry: LinkEntry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
    }

    func selectAll() {
        selection = Set(currentSection?.entries.map(\.id) ?? [])
    }

    func selectNone() { selection = [] }

    /// Fetch the next page of the visible section.
    func loadMore() {
        guard let section = currentSection, section.hasMore, !loadingMore, !section.url.isEmpty else { return }
        let index = min(sectionIndex, (result?.sections.count ?? 1) - 1)
        let start = section.entries.count + 1
        let allWereSelected = selection == Set(section.entries.map(\.id))
        loadingMore = true
        moreTask = Task { [weak self] in
            let outcome = await DownloadManager.shared.probeLink(section.url, start: start)
            guard let self, !Task.isCancelled else { return }
            self.loadingMore = false
            guard case .success(let page) = outcome,
                  case .loaded(var r) = self.phase, index < r.sections.count else {
                // A failed page leaves what's already there; stop offering more.
                if case .loaded(var r) = self.phase, index < r.sections.count {
                    r.sections[index].hasMore = false
                    self.phase = .loaded(r)
                }
                return
            }
            let incoming = page.sections.first?.entries ?? []
            var seen = Set(r.sections[index].entries.map(\.id))
            let fresh = incoming.filter { seen.insert($0.id).inserted }
            r.sections[index].entries += fresh
            r.sections[index].hasMore = !fresh.isEmpty && incoming.count >= DownloadManager.linkPageSize
            self.phase = .loaded(r)
            if allWereSelected { self.selection.formUnion(fresh.map(\.id)) }
        }
    }

    // MARK: Lookup

    private func queryChanged() {
        probeTask?.cancel()
        moreTask?.cancel()
        loadingMore = false
        guard let link else {
            phase = .idle
            downloadWhenReady = false
            return
        }
        if case .loaded(let r) = phase, r.sourceURL == link { return }
        phase = .loading
        chosen = nil
        probeTask = Task { [weak self] in
            // Typing a link character by character shouldn't fire a lookup per
            // keystroke; a paste lands all at once and barely notices this.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let outcome = await DownloadManager.shared.probeLink(link)
            guard let self, !Task.isCancelled, self.link == link else { return }
            self.finish(outcome)
        }
    }

    private func finish(_ outcome: Result<LinkResult, LinkProbeError>) {
        switch outcome {
        case .success(let r):
            phase = .loaded(r)
            sectionIndex = 0
            selectAll()
            if let state { listQuality = state.defaultQuality }
            if downloadWhenReady, r.isSingle {
                downloadWhenReady = false
                downloadSingle()
            }
            downloadWhenReady = false
        case .failure(.cancelled):
            break
        case .failure(let e):
            phase = .failed(e.message)
            downloadWhenReady = false
        }
    }
}
