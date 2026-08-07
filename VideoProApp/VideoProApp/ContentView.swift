import SwiftUI
import AVKit
import Combine
import ImageIO

// MARK: - Library scopes

/// What the sidebar selects.
///
/// These are *scopes* — genuinely different sets of videos. The old sidebar held
/// All / Downloading / Completed / Failed, which were one list with a `where`
/// clause on status; you saw all of it under All Videos anyway. Status is a
/// transient property of an item, so it belongs in a filter, not in navigation.
enum LibraryScope: Hashable, Identifiable {
    case inbox
    case all
    case collection(UUID)
    case smart(SmartFilter)

    var id: String {
        switch self {
        case .inbox: return "inbox"
        case .all: return "all"
        case .collection(let id): return "c-\(id.uuidString)"
        case .smart(let f): return "s-\(f.rawValue)"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .all: return "square.stack"
        case .collection: return "folder"
        case .smart(let f): return f.systemImage
        }
    }

    func matches(_ item: VideoItem) -> Bool {
        switch self {
        case .inbox: return item.meta.tier == .inbox
        case .all: return true
        case .collection(let id): return item.meta.collectionIDs.contains(id)
        case .smart(let f): return f.matches(item)
        }
    }
}

/// Saved filters for things the status chips can't express.
enum SmartFilter: String, CaseIterable, Identifiable, Hashable {
    case highRes = "High Resolution"
    case long    = "Over 10 Minutes"
    case kept    = "Kept"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .highRes: return "4k.tv"
        case .long:    return "clock.arrow.circlepath"
        case .kept:    return "pin"
        }
    }

    func matches(_ item: VideoItem) -> Bool {
        switch self {
        case .highRes:
            return max(item.meta.height, item.availableHeights.max() ?? 0) >= 1440
        case .long:
            return (item.meta.duration ?? 0) > 600
        case .kept:
            return item.meta.tier == .kept
        }
    }
}

/// Transient state, so: a filter, not a destination.
enum StatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case downloading = "Active"
    case done = "Saved"
    case failed = "Failed"

    var id: String { rawValue }

    func matches(_ item: VideoItem) -> Bool {
        switch self {
        case .all: return true
        case .downloading: return item.status == .downloading || item.status == .queued
        case .done: return item.status == .done
        case .failed: return item.status == .error
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest = "Newest"
    case oldest = "Oldest"
    case title = "Title"
    case longest = "Longest"

    var id: String { rawValue }

    func apply(_ list: [VideoItem]) -> [VideoItem] {
        switch self {
        case .newest: return list.sorted { $0.meta.receivedAt > $1.meta.receivedAt }
        case .oldest: return list.sorted { $0.meta.receivedAt < $1.meta.receivedAt }
        case .title: return list.sorted {
            $0.meta.title.localizedCaseInsensitiveCompare($1.meta.title) == .orderedAscending }
        case .longest: return list.sorted { ($0.meta.duration ?? 0) > ($1.meta.duration ?? 0) }
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var scope: LibraryScope = .inbox
    @AppStorage("vp.hasOnboarded") private var hasOnboarded = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $scope)
                .navigationSplitViewColumnWidth(min: 188, ideal: 208, max: 260)
        } detail: {
            LibraryView(scope: scope)
        }
        .onAppear { if !hasOnboarded { showOnboarding = true } }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { hasOnboarded = true; showOnboarding = false }
                .environmentObject(state)
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @Binding var selection: LibraryScope
    @State private var newCollectionName = ""
    @State private var showNewCollection = false
    @State private var renaming: VideoCollection?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                row(.inbox, "Inbox")
                row(.all, "All Videos")
            }

            // Stays hidden until one exists — a new user should never meet an
            // empty "Collections" header asking to be filled in.
            if !state.collections.isEmpty {
                Section("Collections") {
                    ForEach(state.collections) { c in
                        Label(c.name, systemImage: "folder")
                            .badge(count(.collection(c.id)))
                            .tag(LibraryScope.collection(c.id))
                            .contextMenu {
                                Button("Rename…") { renaming = c }
                                Button("Delete Collection", role: .destructive) {
                                    if selection == .collection(c.id) { selection = .inbox }
                                    state.deleteCollection(c.id)
                                }
                            }
                    }
                }
            }

            Section("Smart") {
                ForEach(SmartFilter.allCases) { f in
                    row(.smart(f), f.rawValue)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
        .popover(isPresented: $showNewCollection) { newCollectionForm }
        .sheet(item: $renaming) { c in RenameSheet(collection: c).environmentObject(state) }
    }

    private func row(_ scope: LibraryScope, _ title: String) -> some View {
        Label(title, systemImage: scope.systemImage)
            .badge(count(scope))
            .tag(scope)
    }

    private func count(_ scope: LibraryScope) -> Int {
        state.items.filter(scope.matches).count
    }

    private var newCollectionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Collection").font(.subheadline).fontWeight(.semibold)
            TextField("Name", text: $newCollectionName)
                .textFieldStyle(.roundedBorder).frame(width: 200)
                .onSubmit(commitNewCollection)
            HStack {
                Spacer()
                Button("Create", action: commitNewCollection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func commitNewCollection() {
        let name = newCollectionName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let c = state.createCollection(named: name)
        newCollectionName = ""
        showNewCollection = false
        selection = .collection(c.id)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button {
                showNewCollection = true
            } label: {
                Label("New Collection", systemImage: "plus").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            statusLine(ok: state.toolsReady,
                       text: state.toolsReady ? "Ready" : "yt-dlp missing")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func statusLine(ok: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct RenameSheet: View {
    @EnvironmentObject var state: AppState
    let collection: VideoCollection
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Collection").font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") {
                    state.renameCollection(collection.id, to: name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .onAppear { name = collection.name }
    }
}

// MARK: - Library (detail)

struct LibraryView: View {
    @EnvironmentObject var state: AppState
    let scope: LibraryScope

    @Environment(\.openWindow) private var openWindow
    @State private var convertItem: VideoItem?
    @State private var showAddURL = false
    @State private var showActivity = false
    @State private var urlText = ""
    @State private var search = ""
    @State private var status: StatusFilter = .all
    @State private var sort: LibrarySort = .newest
    @State private var selection = Set<UUID>()
    @State private var pendingRemoval: [VideoItem] = []

    /// Everything in this scope, before the status chips and search narrow it —
    /// used so the chips can show counts and hide themselves when irrelevant.
    private var scoped: [VideoItem] { state.items.filter(scope.matches) }

    private var visible: [VideoItem] {
        var list = scoped.filter(status.matches)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter {
                $0.meta.title.lowercased().contains(q)
                    || (URL(string: $0.meta.downloadURL)?.host?.lowercased().contains(q) ?? false)
                    || $0.meta.tags.contains { $0.lowercased().contains(q) }
            }
        }
        return sort.apply(list)
    }

    /// Selection resolved back to items, in the order they appear on screen.
    /// Everything batch acts on goes through here, so an action can never touch
    /// a row the filters have hidden.
    private var selectedItems: [VideoItem] {
        visible.filter { selection.contains($0.id) }
    }

    var body: some View {
        Group {
            if state.items.isEmpty {
                EmptyStateView()
            } else if scoped.isEmpty {
                ContentUnavailableView("Nothing here yet", systemImage: scope.systemImage,
                                       description: Text(emptyScopeHint))
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(selection: $selection) {
                    ForEach(visible) { item in
                        VideoRow(item: item,
                                 onPlay: { play(item) },
                                 onExport: { convertItem = item },
                                 selection: selection,
                                 selectedItems: { selectedItems },
                                 onRemove: requestRemoval)
                            .environmentObject(state)
                            .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                    }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds()
            }
        }
        .safeAreaInset(edge: .top) { if !state.items.isEmpty { filterBar } }
        // A filter or sort change must not silently widen or narrow what a
        // batch action is about to hit, so anything that scrolls out of the
        // filtered set leaves the selection with it.
        .onChange(of: Set(visible.map(\.id))) { _, ids in
            if !selection.isEmpty { selection.formIntersection(ids) }
        }
        .background { selectionShortcuts }
        .confirmationDialog("Remove \(pendingRemoval.count) videos from your library?",
                            isPresented: Binding(get: { !pendingRemoval.isEmpty },
                                                 set: { if !$0 { pendingRemoval = [] } })) {
            Button("Remove \(pendingRemoval.count) Videos", role: .destructive) {
                state.remove(pendingRemoval)
                selection.subtract(pendingRemoval.map(\.id))
                pendingRemoval = []
            }
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
        } message: {
            Text("The downloaded files stay on disk.")
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .searchable(text: $search, placement: .toolbar, prompt: "Search videos")
        .toolbar { toolbarContent }
        .sheet(item: $convertItem) { ConvertSheet(item: $0).environmentObject(state) }
    }

    private var title: String {
        switch scope {
        case .inbox: return "Inbox"
        case .all: return "All Videos"
        case .collection(let id):
            return state.collections.first { $0.id == id }?.name ?? "Collection"
        case .smart(let f): return f.rawValue
        }
    }

    private var emptyScopeHint: String {
        switch scope {
        case .inbox: return "New videos land here. They clear themselves after \(state.inboxExpiryDays) days — your files are never touched."
        case .collection: return "Drop videos in from the library, or use Add to Collection."
        default: return "Videos will show up here as they qualify."
        }
    }

    private var subtitle: String {
        let n = visible.count
        var base = "\(n) video\(n == 1 ? "" : "s")"
        if n != scoped.count { base += " of \(scoped.count)" }
        return base
    }

    /// Removing one or two is an obvious, easily-redone gesture; removing a
    /// sweep of rows the user may have selected by accident is not.
    private func requestRemoval(_ batch: [VideoItem]) {
        guard !batch.isEmpty else { return }
        if batch.count > 2 {
            pendingRemoval = batch
        } else {
            state.remove(batch)
            selection.subtract(batch.map(\.id))
        }
    }

    /// Zero-sized buttons purely to carry the key equivalents. Escape only
    /// exists while something is selected so it doesn't shadow sheet dismissal.
    @ViewBuilder private var selectionShortcuts: some View {
        Button("") { selection = Set(visible.map(\.id)) }
            .keyboardShortcut("a", modifiers: .command)
            .frame(width: 0, height: 0).opacity(0)
        if !selection.isEmpty {
            Button("") { selection.removeAll() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0).opacity(0)
        }
    }

    /// The filter bar's slot, taken over while a multi-selection is live.
    /// Chips and sort are irrelevant mid-batch, and this keeps the actions in
    /// the one place the eye is already using to steer the list.
    @ViewBuilder private var batchBar: some View {
        let targets = selectedItems
        let downloadable = targets.filter { $0.status == .idle || $0.status == .error }
        let promotable = targets.filter { $0.meta.tier == .inbox }

        HStack(spacing: 8) {
            Text("\(targets.count) selected")
                .font(.caption).fontWeight(.medium)

            Divider().frame(height: 14)

            Button {
                for item in downloadable { state.download(item) }
            } label: {
                Label("Download \(downloadable.count)", systemImage: "arrow.down.to.line")
            }
            .disabled(downloadable.isEmpty)

            Menu {
                collectionMenuItems(for: targets)
            } label: {
                Label("Add to Collection", systemImage: "folder.badge.plus")
            }
            .fixedSize()

            if !promotable.isEmpty {
                Button {
                    for item in promotable { state.promote(item) }
                } label: {
                    Label("Keep", systemImage: "pin")
                }
                .help("Keep these in the library instead of letting the Inbox expire them")
            }

            Button(role: .destructive) {
                requestRemoval(targets)
            } label: {
                Label("Remove", systemImage: "trash")
            }

            Spacer()

            Button("Done") { selection.removeAll() }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(.bar)
    }

    /// Disabled only when *every* target is already filed there — otherwise the
    /// menu item still has work to do for the rest of the selection.
    @ViewBuilder private func collectionMenuItems(for targets: [VideoItem]) -> some View {
        ForEach(state.collections) { c in
            Button(c.name) {
                for item in targets { state.add(item, to: c.id) }
            }
            .disabled(targets.allSatisfy { $0.meta.collectionIDs.contains(c.id) })
        }
        if !state.collections.isEmpty { Divider() }
        Button("New Collection…") {
            let c = state.createCollection(named: "Untitled Collection")
            for item in targets { state.add(item, to: c.id) }
        }
    }

    /// Status as chips. One click, no navigation, and they disappear entirely
    /// when the current scope has nothing in flight.
    @ViewBuilder private var filterBar: some View {
        if selection.count > 1 {
            batchBar
        } else {
            statusFilterBar
        }
    }

    @ViewBuilder private var statusFilterBar: some View {
        let counts = Dictionary(grouping: scoped, by: { item -> StatusFilter in
            if item.status == .downloading || item.status == .queued { return .downloading }
            if item.status == .done { return .done }
            if item.status == .error { return .failed }
            return .all
        }).mapValues(\.count)

        HStack(spacing: 6) {
            ForEach(StatusFilter.allCases) { f in
                let n = f == .all ? scoped.count : (counts[f] ?? 0)
                if f == .all || n > 0 {
                    Button {
                        status = (status == f && f != .all) ? .all : f
                    } label: {
                        Text(n > 0 && f != .all ? "\(f.rawValue) \(n)" : f.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .background(status == f ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                                in: .capsule)
                    .foregroundStyle(status == f ? Color.accentColor : .secondary)
                }
            }
            Spacer()
            Picker("", selection: $sort) {
                ForEach(LibrarySort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 110)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { showAddURL.toggle() } label: { Image(systemName: "plus") }
                .help("Add a video by URL")
                .popover(isPresented: $showAddURL, arrowEdge: .bottom) { addURLPopover }

            // In-flight work lives here now instead of taking two sidebar rows.
            if state.activeDownloads + state.queuedCount > 0 {
                Button { showActivity.toggle() } label: {
                    Image(systemName: "arrow.down.circle")
                        .symbolVariant(.fill)
                        .foregroundStyle(.tint)
                }
                .help("Activity")
                .popover(isPresented: $showActivity, arrowEdge: .bottom) {
                    ActivityPopover().environmentObject(state)
                }
            }

            if scoped.contains(where: { $0.status == .idle || $0.status == .error }) {
                Button { for i in visible where i.status == .idle || i.status == .error {
                    state.download(i)
                } } label: { Image(systemName: "arrow.down.to.line") }
                    .help("Download everything shown")
            }
        }
    }

    private var addURLPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a video by URL").font(.subheadline).fontWeight(.semibold)
            Text("Paste any video page or direct link.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("https://…", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                    .onSubmit(submitURL)
                Button("Add", action: submitURL)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func submitURL() {
        let t = urlText
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.addURL(t)
        urlText = ""
        showAddURL = false
    }

    private func play(_ item: VideoItem) {
        if let url = item.warmPlayURL {
            openWindow(value: PlayerContext(url: url, title: item.meta.title))
            return
        }
        item.statusLine = "Resolving stream…"
        Task {
            if let url = await DownloadManager.shared.resolvePlayableURL(for: item.meta) {
                item.setPlayURL(url, expires: DownloadManager.expiry(for: url.absoluteString))
                openWindow(value: PlayerContext(url: url, title: item.meta.title))
                item.statusLine = ""
            } else {
                item.statusLine = "Couldn't resolve a playable stream"
            }
        }
    }
}

/// What's running right now. Replaces the Downloading/Failed sidebar rows.
struct ActivityPopover: View {
    @EnvironmentObject var state: AppState

    private var active: [VideoItem] {
        state.items.filter { $0.status == .downloading || $0.status == .queued }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity").font(.subheadline).fontWeight(.semibold)
                Spacer()
                Text("\(state.activeDownloads) of \(state.maxConcurrent)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if active.isEmpty {
                Text("Nothing in progress.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(active) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.meta.title).font(.caption).lineLimit(1)
                        Spacer()
                        Button {
                            state.cancel(item)
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    if item.status == .queued {
                        Text("Queued").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        ProgressView(value: item.progress).progressViewStyle(.linear)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Backdrop

/// Backdrop for full-bleed surfaces (onboarding).
///
/// Achromatic on purpose. This was a hardcoded dark purple gradient with no
/// light-mode variant, so in Light Mode it rendered as a dark slab in an
/// otherwise light window — and worse, `.regularMaterial` cards over it degraded
/// into opaque grey bricks, which made the content look broken rather than just
/// the background. Depth now comes from value instead of hue, so it reads
/// correctly in both appearances and can never fight the user's accent colour.
struct BackdropView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [Color.primary.opacity(scheme == .dark ? 0.07 : 0.045), .clear],
                startPoint: .top, endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Video row

/// One video in the library list.
///
/// Replaces the old full-width glass card: at ~72pt a row shows roughly 5x more
/// videos per screen, which is what actually matters once you've sent a dozen.
/// Actions stay hidden until hover so the list reads as content, not chrome —
/// except while downloading, where Cancel must always be reachable.
struct VideoRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var item: VideoItem
    let onPlay: () -> Void
    var onExport: () -> Void = {}
    /// The live list selection, so the row can tell whether a right-click on it
    /// is a right-click on the whole selection.
    var selection: Set<UUID> = []
    var selectedItems: () -> [VideoItem] = { [] }
    /// Removal goes back up: only the list knows whether a batch is big enough
    /// to deserve a confirmation.
    var onRemove: ([VideoItem]) -> Void = { _ in }
    @State private var showQuality = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ThumbView(thumb: item.thumbnail)
                    .frame(width: 96, height: 54)
                    .clipShape(.rect(cornerRadius: 6))
                // Play affordance right where the eye already is.
                if hovering {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .frame(width: 96, height: 54)
                            .background(.black.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .clipShape(.rect(cornerRadius: 6))
                    .help("Play")
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.meta.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 5) {
                    if let p = item.meta.platform, !p.isEmpty { Pill(text: p, tint: .accentColor) }
                    if let d = item.meta.prettyDuration { Pill(text: d) }
                    if item.meta.height > 0 { Pill(text: "\(item.meta.height)p") }
                    if let host = URL(string: item.meta.downloadURL)?.host {
                        Text(host).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }

                statusView
            }

            Spacer(minLength: 4)
            controls.opacity(hovering || alwaysShowControls ? 1 : 0)
        }
        .padding(.vertical, 5)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onPlay)
        .contextMenu { contextMenu }
    }

    /// While a download is live the Cancel button can't be hover-gated.
    private var alwaysShowControls: Bool {
        item.status == .downloading || item.status == .queued
    }

    /// macOS convention: right-clicking inside a multi-selection acts on the
    /// whole selection; right-clicking outside it acts on that row alone.
    @ViewBuilder private var contextMenu: some View {
        if selection.count > 1, selection.contains(item.id) {
            batchMenu(selectedItems())
        } else {
            singleMenu
        }
    }

    @ViewBuilder private func batchMenu(_ targets: [VideoItem]) -> some View {
        let downloadable = targets.filter { $0.status == .idle || $0.status == .error }
        let promotable = targets.filter { $0.meta.tier == .inbox }

        if !downloadable.isEmpty {
            Button("Download \(downloadable.count) Videos") {
                for i in downloadable { state.download(i) }
            }
        }
        if !promotable.isEmpty {
            Button("Keep \(promotable.count) in Library") {
                for i in promotable { state.promote(i) }
            }
        }
        Menu("Add \(targets.count) to Collection") {
            ForEach(state.collections) { c in
                Button(c.name) { for i in targets { state.add(i, to: c.id) } }
                    .disabled(targets.allSatisfy { $0.meta.collectionIDs.contains(c.id) })
            }
            if !state.collections.isEmpty { Divider() }
            Button("New Collection…") {
                let c = state.createCollection(named: "Untitled Collection")
                for i in targets { state.add(i, to: c.id) }
            }
        }
        Divider()
        Button("Remove \(targets.count) Videos", role: .destructive) { onRemove(targets) }
    }

    @ViewBuilder private var singleMenu: some View {
        Button("Play", action: onPlay)
        if item.status == .idle || item.status == .error {
            Button("Download") { state.download(item) }
        }
        Button("Clip · GIF · MP3…", action: onExport)
            .disabled(item.busy || !state.canExport(item))
        if state.canExport(item), !item.outputPath.isEmpty {
            Button("Show in Finder") { state.revealInFinder(item) }
        }
        Divider()
        Button("Copy Source URL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.meta.downloadURL, forType: .string)
        }
        Divider()
        if item.meta.tier == .inbox {
            Button("Keep in Library") { state.promote(item) }
        }
        Menu("Add to Collection") {
            ForEach(state.collections) { c in
                Button(c.name) { state.add(item, to: c.id) }
                    .disabled(item.meta.collectionIDs.contains(c.id))
            }
            if !state.collections.isEmpty { Divider() }
            Button("New Collection…") {
                let c = state.createCollection(named: "Untitled Collection")
                state.add(item, to: c.id)
            }
        }
        if !item.meta.collectionIDs.isEmpty {
            Menu("Remove from Collection") {
                ForEach(state.collections.filter { item.meta.collectionIDs.contains($0.id) }) { c in
                    Button(c.name) { state.remove(item, from: c.id) }
                }
            }
        }
        Divider()
        Button("Remove", role: .destructive) { onRemove([item]) }
    }

    @ViewBuilder private var statusView: some View {
        if item.busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(item.busyLabel).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            downloadStatus
        }
    }

    @ViewBuilder private var downloadStatus: some View {
        switch item.status {
        case .queued:
            Label("Queued", systemImage: "clock")
                .font(.caption2).foregroundStyle(.secondary)
        case .downloading:
            HStack(spacing: 7) {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 130)
                Text("\(Int(item.progress * 100))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                Text(item.statusLine)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        case .done:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption2).foregroundStyle(.green)
        case .error:
            Label(item.statusLine, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.orange).lineLimit(1)
        default:
            if !item.statusLine.isEmpty {
                Text(item.statusLine).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if item.readyToPlay {
                Label("Ready", systemImage: "bolt.fill")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if item.probing {
                Label("Getting ready…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 4) {
            switch item.status {
            case .downloading, .queued:
                iconButton("stop.fill", help: item.status == .queued ? "Remove from queue" : "Cancel") {
                    state.cancel(item)
                }
            case .done:
                iconButton("folder", help: "Show in Finder") { state.revealInFinder(item) }
                iconButton("wand.and.stars", help: "Clip · GIF · MP3…", action: onExport)
                    .disabled(item.busy)
            default:
                // Clip/GIF/MP3 works without downloading first — the export
                // fetches only the part it needs.
                iconButton("wand.and.stars", help: "Clip · GIF · MP3…", action: onExport)
                    .disabled(item.busy || !state.canExport(item))
                Button {
                    showQuality.toggle()
                    if showQuality { state.probeQualities(item) }
                } label: {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 11))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.borderedProminent)
                .help("Download…")
                .popover(isPresented: $showQuality, arrowEdge: .trailing) {
                    QualityPopover(item: item) { quality in
                        showQuality = false
                        state.download(item, quality: quality)
                    }
                    .environmentObject(state)
                }
            }
            iconButton("xmark", help: "Remove") { state.remove(item) }
        }
    }

    private func iconButton(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 26, height: 22)
        }
        .buttonStyle(.bordered)
        .help(help)
    }
}

// MARK: - Quality popover

struct QualityPopover: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var item: VideoItem
    let choose: (DownloadQuality) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Download quality").font(.subheadline).fontWeight(.semibold)
                Spacer()
                if item.probing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            Divider()

            ForEach(item.qualityMenu) { q in
                Button {
                    choose(q)
                } label: {
                    HStack {
                        Image(systemName: q.isAudioOnly ? "music.note" : "film")
                            .foregroundStyle(q.isAudioOnly ? Color.pink : Color.accentColor)
                            .frame(width: 18)
                        Text(q.rawValue)
                        Spacer()
                        if q == state.defaultQuality {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }

            Divider()
            HStack(spacing: 8) {
                Image(systemName: state.embedSubtitles ? "captions.bubble.fill" : "captions.bubble")
                    .foregroundStyle(state.embedSubtitles ? .blue : .secondary)
                Image(systemName: state.embedThumbnail ? "photo.fill" : "photo")
                    .foregroundStyle(state.embedThumbnail ? .green : .secondary)
                Text("subtitles & thumbnail embed").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 240)
    }
}

// MARK: - Convert / trim

struct ConvertSheet: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var item: VideoItem
    @Environment(\.dismiss) private var dismiss

    @State private var kind: ExportKind = .trim
    @State private var startText = "0:00"
    @State private var endText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title3).fontWeight(.bold)
            Text(item.meta.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)

            Picker("Format", selection: $kind) {
                ForEach(ExportKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if kind.usesTimeRange {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Start").font(.caption).foregroundStyle(.secondary)
                        TextField("0:00", text: $startText).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).padding(.top, 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("End").font(.caption).foregroundStyle(.secondary)
                        TextField(endPlaceholder, text: $endText).textFieldStyle(.roundedBorder).frame(width: 90)
                    }
                }
                Text(kind == .gif ? "Tip: keep GIFs short (a few seconds)." : "Leave End blank to go to the end.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Extracts the full audio track as an MP3.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !state.hasLocalFile(item) {
                Label(sourceNote, systemImage: "arrow.down.circle")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export") {
                    state.export(item, kind: kind,
                                 start: parseTime(startText),
                                 end: endText.isEmpty ? (item.meta.duration ?? 0) : parseTime(endText))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var endPlaceholder: String {
        if let d = item.meta.prettyDuration { return d }
        return "end"
    }

    /// This video isn't downloaded, so say what we'll pull down for the export.
    private var sourceNote: String {
        switch kind {
        case .audio: return "Not downloaded — VideoPro will fetch the audio track only."
        case .trim, .gif:
            return endText.isEmpty
                ? "Not downloaded — VideoPro will fetch the video first."
                : "Not downloaded — VideoPro will fetch just this section."
        }
    }

    private func parseTime(_ s: String) -> Double {
        let parts = s.split(separator: ":").map { Double($0) ?? 0 }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return 0
        }
    }
}

/// Guided "Load unpacked" flow.
///
/// Chromium's Load-unpacked button opens a bare folder picker with no idea where
/// to go — and our folder lives in ~/Library, which Finder hides by default. So
/// we spell out the two ways that actually work (⌘⇧G + paste, or drag from the
/// Finder window we open) and confirm when the extension connects.
struct ExtensionInstallSheet: View {
    @EnvironmentObject var state: AppState
    let browser: BrowserTarget
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var now = Date()
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var connected: Bool { state.extensionStatus.connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Set up in \(browser.name)").font(.title3).fontWeight(.bold)
                    Text("VideoPro opened \(browser.name)’s Extensions page and copied the folder path.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                step(1, "Turn on **Developer mode** — the toggle at the top-right.")
                step(2, "Click **Load unpacked**. A folder picker opens.")
                step(3, "Press **⌘⇧G**, paste with **⌘V**, then hit **Return**.")
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.tertiary)
                    Text("Or drag the folder from the Finder window onto the Extensions page.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 22)
            }

            HStack(spacing: 6) {
                Text(state.extensionFolder.path)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                    .textSelection(.enabled)
                Spacer()
                Button(copied ? "Copied ✓" : "Copy path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(state.extensionFolder.path, forType: .string)
                    copied = true
                }
                .controlSize(.small)
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 7))

            // Closes the loop: the popup pings /health on open, so this flips
            // green on its own the moment it's really working.
            HStack(spacing: 7) {
                if connected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Connected — you’re all set.").font(.callout).fontWeight(.medium)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Waiting for the extension to connect…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Reveal folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([state.extensionFolder])
                }
                Button("Reopen \(browser.name)") { state.setUpExtension(in: browser) }
                Spacer()
                Button(connected ? "Done" : "Close") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            // Unpack + open the browser + copy the path as the sheet appears, so
            // the steps below are true by the time the user reads them.
            state.setUpExtension(in: browser)
            copied = true
        }
        .onReceive(tick) { now = $0 }
    }

    @ViewBuilder
    private func step(_ n: Int, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption2).fontWeight(.bold).foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(.tint, in: .circle)
            Text(.init(markdown)).font(.callout)
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    let onDone: () -> Void
    @State private var installed = false
    @State private var chromium: [BrowserTarget] = []
    @State private var safari: BrowserTarget?
    @State private var sheetBrowser: BrowserTarget?

    var body: some View {
        ZStack {
            BackdropView()
            VStack(spacing: 16) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 46)).foregroundStyle(Color.accentColor.gradient)
                Text("Welcome to VideoPro").font(.title2).fontWeight(.bold)
                Text("Find videos in your browser, then send them here to play or download.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 350)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Install the browser extension", systemImage: "puzzlepiece.extension.fill")
                        .font(.headline)
                    Text("Adds video detection and a “Send to VideoPro” button to any page. Pick your browser — VideoPro opens it and copies the folder path for you.")
                        .font(.caption).foregroundStyle(.secondary)

                    // Offer the browsers actually on this Mac. Hard-coding "Chrome"
                    // left Arc/Brave/Edge users with no working path at all.
                    ForEach(chromium) { b in
                        Button {
                            sheetBrowser = b
                            installed = true
                        } label: {
                            Label("Install in \(b.name)", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent).controlSize(.large)
                    }

                    if safari != nil {
                        Button("Using Safari? Enable it there instead") {
                            state.openSafariExtensionSettings()
                            installed = true
                        }
                        .buttonStyle(.glass).controlSize(.small)
                        .frame(maxWidth: .infinity)
                    }

                    if chromium.isEmpty && safari == nil {
                        Text("No supported browser found. Install Chrome, Arc, Brave, Edge, or use Safari.")
                            .font(.caption2).foregroundStyle(.orange)
                    }

                    if installed {
                        Label("Follow the steps in your browser — this turns green once it connects",
                              systemImage: state.extensionStatus.connected ? "checkmark.circle.fill" : "info.circle")
                            .font(.caption2)
                            .foregroundStyle(state.extensionStatus.connected ? .green : .secondary)
                    }
                }
                .padding(16)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .onAppear {
                    chromium = BrowserScan.chromiumInstalled()
                    safari = BrowserScan.safariInstalled()
                }

                Label(state.toolSummary, systemImage: state.toolsReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(state.toolsReady ? .green : .orange)
                    .lineLimit(2).multilineTextAlignment(.center)

                Button("Get Started", action: onDone)
                    .buttonStyle(.glass).controlSize(.large)
            }
            .padding(28)
        }
        .frame(width: 440, height: 500)
        .sheet(item: $sheetBrowser) { b in
            ExtensionInstallSheet(browser: b).environmentObject(state)
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 46))
                .foregroundStyle(Color.accentColor.gradient)
            Text("No videos yet").font(.title3).fontWeight(.semibold)
            Text("Find a video in your browser and click **Send to VideoPro**.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider().frame(width: 200).padding(.vertical, 4)

            Text("Set up the browser extension")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                // Only offer browsers that exist on this Mac.
                ForEach(BrowserScan.chromiumInstalled()) { b in
                    Button { state.setUpExtension(in: b) } label: {
                        Label(b.name, systemImage: "puzzlepiece.extension.fill")
                    }
                }
                if BrowserScan.safariInstalled() != nil {
                    Button { state.openSafariExtensionSettings() } label: {
                        Label("Safari", systemImage: "safari.fill")
                    }
                }
            }
            .buttonStyle(.glass)
        }
        .padding(40)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .padding(40)
    }
}

// MARK: - Reusable pieces

struct Pill: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption2).fontWeight(.medium)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(tint == .secondary ? .secondary : tint)
            .glassEffect(.regular, in: .capsule)
    }
}

struct ThumbView: View {
    let thumb: String

    var body: some View {
        Group {
            if let nsImage = Self.localImage(thumb) {
                Image(nsImage: nsImage).resizable().aspectRatio(contentMode: .fill)
            } else if thumb.hasPrefix("http"), let url = URL(string: thumb) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.35))
            Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
        }
    }

    /// Handles a `data:` URL (extension frame) or a local file path (ffmpeg frame).
    static func localImage(_ s: String) -> NSImage? {
        if s.hasPrefix("data:"), let comma = s.firstIndex(of: ",") {
            let b64 = String(s[s.index(after: comma)...])
            // Tolerate whitespace/newlines that survive a JSON round-trip; strict
            // decoding would return nil and silently drop an otherwise fine frame.
            guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            else { return nil }
            return decode(data)
        }
        if s.hasPrefix("/") {
            guard let data = FileManager.default.contents(atPath: s) else { return nil }
            return decode(data)
        }
        if s.hasPrefix("file://"), let url = URL(string: s), let data = try? Data(contentsOf: url) {
            return decode(data)
        }
        return nil
    }

    /// Decode **only** if the payload is a whole image.
    ///
    /// `NSImage(data:)` is happy to return an object for a half-written JPEG: it
    /// decodes the scanlines it got and leaves the rest grey, which renders as a
    /// thin coloured bar across the top of the thumbnail. Because that object is
    /// non-nil, the caller takes the "we have an image" branch and the placeholder
    /// never gets a chance to show.
    ///
    /// ImageIO is no help here — `CGImageSourceCreateWithData` treats its buffer as
    /// final, so it reports `.statusComplete` for a truncated JPEG just as readily
    /// as for an intact one (measured, not assumed). What *does* separate them is
    /// the container's terminator, so check that structurally.
    static func decode(_ data: Data) -> NSImage? {
        guard isComplete(data),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              cg.width > 0, cg.height > 0
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Does this buffer actually end where its format says it should?
    ///
    /// Covers the two formats we ever hold: JPEG from the extension's canvas grab
    /// and from ffmpeg's frame export, and PNG defensively. Anything else is
    /// passed through to the decoder rather than rejected on a guess.
    private static func isComplete(_ data: Data) -> Bool {
        guard data.count > 4 else { return false }
        let head = [UInt8](data.prefix(4))
        if head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF {
            // JPEG: a bare FFD9 is the end-of-image marker. It can't occur inside
            // entropy-coded data, where a literal FF is byte-stuffed as FF00.
            return data.range(of: Data([0xFF, 0xD9]), options: .backwards) != nil
        }
        if head == [0x89, 0x50, 0x4E, 0x47] {
            return data.range(of: Data("IEND".utf8), options: .backwards) != nil
        }
        return true
    }
}

// MARK: - Player

/// AppKit AVPlayerView wrapped for SwiftUI. Using this instead of SwiftUI's
/// `VideoPlayer` avoids a metadata crash in _AVKit_SwiftUI on some macOS builds.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
