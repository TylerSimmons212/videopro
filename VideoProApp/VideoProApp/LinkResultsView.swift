import SwiftUI

// MARK: - The field

/// Links and searches share one field. What's typed decides which it is, and
/// the leading icon says so: a link icon (spinning while it's looked up) or a
/// magnifying glass.
struct LinkField: View {
    @ObservedObject var search: LinkSearch
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: search.isLinkMode ? "link" : "magnifyingglass")
                .foregroundStyle(search.isLinkMode ? Color.accentColor : .secondary)
                .symbolEffect(.pulse, isActive: search.isLoading)
                .frame(width: 16)
            TextField("Paste a link to download, or search", text: $search.query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { search.submit() }
                .onExitCommand { search.clear() }
            if search.fromClipboard {
                Text("From your clipboard")
                    .font(.caption2).fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: .capsule)
                    .fixedSize()
            }
            if !search.query.isEmpty {
                Button { search.clear() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(minWidth: 240, idealWidth: 460, maxWidth: 560)
        .onChange(of: search.focusToken) { _, _ in focused = true }
        .onChange(of: focused) { _, now in search.fieldFocused = now }
    }
}

// MARK: - Results

/// What a link holds, shown in place of the library while the field has a link.
struct LinkResultsView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var search: LinkSearch

    var body: some View {
        switch search.phase {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Looking up the link…").foregroundStyle(.secondary)
                Text("Press Return to download as soon as it’s found.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            ContentUnavailableView {
                Label("Nothing to download here", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text(message)
            } actions: {
                Button("Add to Library Anyway") {
                    if let link = search.link { state.addURL(link) }
                    search.clear()
                }
                .help("Keep the link in your library to try again later, or to use with the browser extension")
            }

        case .loaded(let result):
            if let video = result.video {
                ScrollView {
                    SingleVideoCard(search: search, result: result, video: video)
                        .padding(24)
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                }
            } else {
                LinkGridView(search: search, result: result)
            }
        }
    }
}

// MARK: - One video

private struct SingleVideoCard: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var search: LinkSearch
    let result: LinkResult
    let video: LinkVideo

    private var selected: QualityChoice? {
        if let q = search.chosen, let c = video.choices.first(where: { $0.quality == q }) { return c }
        return search.defaultChoice(for: video, preferring: state.defaultQuality)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { ThumbView(thumb: video.entry.thumbnail ?? "") }
                .clipShape(.rect(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    if let d = video.entry.prettyDuration { DurationBadge(text: d).padding(8) }
                }
                .overlay(alignment: .topLeading) {
                    if video.entry.isLive { LiveBadge().padding(8) }
                }
                .frame(width: 340)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(video.entry.title)
                        .font(.title3).fontWeight(.semibold)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }

                if !video.choices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quality").font(.caption).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)],
                                  alignment: .leading, spacing: 8) {
                            ForEach(video.choices) { c in
                                QualityChip(choice: c, selected: c.id == selected?.id) {
                                    search.chosen = c.quality
                                }
                            }
                        }
                    }
                    if let c = selected, let codec = c.codec, !c.isAudio,
                       !QuickTimeCompat.canPlay(codec: codec) {
                        // Say what will actually happen on *this* Mac, not "may not
                        // play": an M1 can't decode AV1 or VP9 at all.
                        Label(state.convertForQuickTime
                              ? "QuickTime can’t play \(codec) on this Mac, so VideoPro converts it to HEVC after downloading. That takes about as long as the video itself."
                              : "QuickTime can’t play \(codec) on this Mac. Turn on conversion in Settings → Downloads, or play it in IINA or VLC.",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        search.downloadSingle()
                    } label: {
                        Label(downloadTitle, systemImage: "arrow.down.to.line")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)

                    Button("Add to Library") { search.downloadSingle(addOnly: true) }
                        .controlSize(.large)
                        .help("Keep it without downloading — you can still play it, or clip just the part you need")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        [result.site, video.entry.uploader].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var downloadTitle: String {
        guard let c = selected else { return "Download" }
        if let size = c.sizeText { return "Download \(c.label) · \(size)" }
        return "Download \(c.label)"
    }
}

private struct QualityChip: View {
    let choice: QualityChoice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: choice.isAudio ? "music.note" : "film")
                        .font(.caption2)
                    Text(choice.label).fontWeight(.semibold)
                    if let codec = choice.codec, codec != "H.264" {
                        Text(codec).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(choice.sizeText ?? "Size unknown")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                        in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Many videos

private struct LinkGridView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var search: LinkSearch
    let result: LinkResult

    private var section: LinkSection? { search.currentSection }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if let section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)],
                              spacing: 18) {
                        ForEach(section.entries) { entry in
                            EntryCard(entry: entry,
                                      selected: search.selection.contains(entry.id),
                                      inLibrary: state.libraryStatus(for: entry.url))
                                .onTapGesture { search.toggle(entry) }
                        }
                    }
                    .padding(16)

                    if section.hasMore {
                        Button {
                            search.loadMore()
                        } label: {
                            if search.loadingMore {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load More")
                            }
                        }
                        .disabled(search.loadingMore)
                        .padding(.bottom, 20)
                    }
                }
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.headline).lineLimit(1)
                Text(countLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if result.sections.count > 1 {
                Picker("", selection: $search.sectionIndex) {
                    ForEach(Array(result.sections.enumerated()), id: \.offset) { i, s in
                        Text(s.title).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var countLine: String {
        let shown = section?.entries.count ?? 0
        var parts: [String] = []
        if let site = result.site { parts.append(site) }
        if let up = result.uploader, up != result.title { parts.append(up) }
        if let total = section?.total, total > shown {
            parts.append("\(shown) of \(total) videos")
        } else {
            parts.append("\(shown)\(section?.hasMore == true ? "+" : "") video\(shown == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        let picked = search.selectedEntries.count
        let all = section?.entries.count ?? 0
        return HStack(spacing: 10) {
            Button(picked == all ? "Select None" : "Select All") {
                if picked == all { search.selectNone() } else { search.selectAll() }
            }
            Text("\(picked) of \(all) selected")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            Picker("Quality", selection: $search.listQuality) {
                ForEach(DownloadQuality.allCases) { Text($0.rawValue).tag($0) }
            }
            .fixedSize()
            Button {
                search.downloadSelected()
            } label: {
                Label(picked == 1 ? "Download 1 Video" : "Download \(picked) Videos",
                      systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(picked == 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}

private struct EntryCard: View {
    let entry: LinkEntry
    let selected: Bool
    let inLibrary: DownloadStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A fixed 16:9 frame the picture fills and is cropped to, so a vertical
            // Short and a widescreen film take the same cell.
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { ThumbView(thumb: entry.thumbnail ?? "") }
                .clipShape(.rect(cornerRadius: 10))
                .opacity(selected ? 1 : 0.55)
                .overlay { badges.padding(7) }
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))

            Text(entry.title)
                .font(.callout).fontWeight(.medium)
                .lineLimit(2, reservesSpace: true)
            if let up = entry.uploader, !up.isEmpty {
                Text(up).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var badges: some View {
        VStack {
            HStack(alignment: .top) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(Color.white, selected ? Color.accentColor : Color.black.opacity(0.35))
                    .shadow(radius: 2)
                Spacer()
                if let badge = libraryBadge {
                    Text(badge)
                        .font(.caption2).fontWeight(.semibold)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .capsule)
                        .foregroundStyle(.white)
                }
            }
            Spacer()
            HStack {
                if entry.isLive { LiveBadge() }
                Spacer()
                if let d = entry.prettyDuration { DurationBadge(text: d) }
            }
        }
    }

    private var libraryBadge: String? {
        switch inLibrary {
        case .done: return "Downloaded"
        case .downloading, .queued: return "Downloading"
        case .paused: return "Paused"
        case .some: return "In Library"
        case nil: return nil
        }
    }
}

// MARK: - Badges

private struct DurationBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2).fontWeight(.semibold).monospacedDigit()
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.7), in: .rect(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}

private struct LiveBadge: View {
    var body: some View {
        Text("LIVE")
            .font(.caption2).fontWeight(.bold)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.red, in: .rect(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}
