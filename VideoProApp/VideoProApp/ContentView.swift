import SwiftUI
import AVKit
import Combine

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var playerItem: PlayerContext?
    @State private var showSettings = false
    @State private var showAddURL = false
    @State private var urlText = ""
    @AppStorage("vp.hasOnboarded") private var hasOnboarded = false
    @State private var showOnboarding = false
    @State private var convertItem: VideoItem?

    var body: some View {
        ZStack {
            BackdropView()

            Group {
                if state.items.isEmpty {
                    EmptyStateView()
                } else {
                    listView
                }
            }
        }
        .navigationTitle("VideoPro")
        .onAppear { if !hasOnboarded { showOnboarding = true } }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView { hasOnboarded = true; showOnboarding = false }
                .environmentObject(state)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) { statusPill }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showAddURL.toggle() } label: {
                    Image(systemName: "plus")
                }
                .help("Add a video by URL")
                .popover(isPresented: $showAddURL, arrowEdge: .bottom) {
                    addURLPopover
                }
                if state.activeDownloads + state.queuedCount > 0 {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(state.queuedCount > 0
                             ? "\(state.activeDownloads)↓ · \(state.queuedCount) queued"
                             : "\(state.activeDownloads) downloading")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !state.items.isEmpty {
                    Button { state.downloadAll() } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .help("Download all")
                }
                Button { showSettings.toggle() } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .help("Download settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsPopover().environmentObject(state)
                }

                if !state.items.isEmpty {
                    Button(role: .destructive) { state.clear() } label: {
                        Image(systemName: "trash")
                    }
                    .help("Clear all")
                }
            }
        }
        .sheet(item: $playerItem) { PlayerSheet(context: $0) }
        .sheet(item: $convertItem) { ConvertSheet(item: $0).environmentObject(state) }
    }

    private var listView: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                LazyVStack(spacing: 14) {
                    ForEach(state.items) { item in
                        VideoCard(item: item, onPlay: { play(item) }, onExport: { convertItem = item })
                            .environmentObject(state)
                    }
                }
                .padding(18)
            }
        }
    }

    private var statusPill: some View {
        // No .glassEffect here — the toolbar already provides the glass background;
        // adding our own capsule produced a "pill inside a pill".
        HStack(spacing: 6) {
            Circle()
                .fill(state.serverRunning ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .shadow(color: state.serverRunning ? .green : .orange, radius: 4)
            Text(state.serverRunning ? "Active" : "Inactive")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
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
        // Warmed on arrival (or already downloaded) — open with zero latency.
        if let url = item.warmPlayURL {
            playerItem = PlayerContext(url: url, title: item.meta.title)
            return
        }
        // Cold: never warmed, or the signed URL aged out. Resolve and re-cache.
        item.statusLine = "Resolving stream…"
        Task {
            if let url = await DownloadManager.shared.resolvePlayableURL(for: item.meta) {
                item.setPlayURL(url, expires: DownloadManager.expiry(for: url.absoluteString))
                playerItem = PlayerContext(url: url, title: item.meta.title)
                item.statusLine = ""
            } else {
                item.statusLine = "Couldn't resolve a playable stream"
            }
        }
    }
}

// MARK: - Backdrop

struct BackdropView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.09, blue: 0.20),
                         Color(red: 0.05, green: 0.05, blue: 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color(red: 0.42, green: 0.36, blue: 0.90).opacity(0.45))
                .frame(width: 420).blur(radius: 140)
                .offset(x: -160, y: -220)
            Circle()
                .fill(Color(red: 0.20, green: 0.55, blue: 0.95).opacity(0.35))
                .frame(width: 380).blur(radius: 150)
                .offset(x: 180, y: 260)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Video card

struct VideoCard: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var item: VideoItem
    let onPlay: () -> Void
    var onExport: () -> Void = {}
    @State private var showQuality = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ThumbView(thumb: item.thumbnail)
                .frame(width: 148, height: 83)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.meta.title)
                    .font(.headline).fontWeight(.semibold)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    if let p = item.meta.platform, !p.isEmpty { Pill(text: p, tint: .purple) }
                    Pill(text: item.meta.sourceKind.uppercased())
                    if let d = item.meta.prettyDuration { Pill(text: d) }
                    if item.meta.height > 0 { Pill(text: "\(item.meta.height)p") }
                }

                if let host = URL(string: item.meta.downloadURL)?.host {
                    Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                statusView.padding(.top, 2)
            }

            Spacer(minLength: 4)
            controls
        }
        .padding(14)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
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
            Label("Queued…", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        case .downloading:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: item.progress).progressViewStyle(.linear).tint(.purple)
                Text("\(Int(item.progress * 100))%  ·  \(item.statusLine)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 280)
        case .done:
            Label("Saved to \(state.downloadFolder.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .error:
            Label(item.statusLine, systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange).lineLimit(2)
        default:
            if !item.statusLine.isEmpty {
                Text(item.statusLine).font(.caption2).foregroundStyle(.secondary)
            } else if item.readyToPlay {
                Label("Ready to play", systemImage: "bolt.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if item.probing {
                Label("Getting ready…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        VStack(spacing: 8) {
            Button(action: onPlay) {
                Image(systemName: "play.fill").frame(width: 34, height: 30)
            }
            .buttonStyle(.glass)
            .help("Play")

            switch item.status {
            case .downloading, .queued:
                Button { state.cancel(item) } label: {
                    Image(systemName: "stop.fill").frame(width: 34, height: 30)
                }
                .buttonStyle(.glass)
                .help(item.status == .queued ? "Remove from queue" : "Cancel")
            case .done:
                Button { state.revealInFinder(item) } label: {
                    Image(systemName: "folder.fill").frame(width: 34, height: 30)
                }
                .buttonStyle(.glass)
                .help("Show in Finder")
            default:
                Button {
                    showQuality.toggle()
                    if showQuality { state.probeQualities(item) }
                } label: {
                    Image(systemName: "arrow.down.to.line").frame(width: 34, height: 30)
                }
                .buttonStyle(.glassProminent)
                .tint(.purple)
                .help("Download…")
                .popover(isPresented: $showQuality, arrowEdge: .trailing) {
                    QualityPopover(item: item) { quality in
                        showQuality = false
                        state.download(item, quality: quality)
                    }
                    .environmentObject(state)
                }
            }

            // Clip / GIF / MP3 are available from the start — no need to download
            // the full video first; the export fetches its own source if needed.
            if item.status != .downloading, item.status != .queued {
                Button(action: onExport) {
                    Image(systemName: "wand.and.stars").frame(width: 34, height: 30)
                }
                .buttonStyle(.glass)
                .help("Clip · GIF · MP3…")
                .disabled(item.busy || !state.canExport(item))
            }

            Button { state.remove(item) } label: {
                Image(systemName: "xmark").frame(width: 34, height: 24)
            }
            .buttonStyle(.glass)
            .help("Remove")
        }
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
                            .foregroundStyle(q.isAudioOnly ? .pink : .purple)
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

// MARK: - Settings

struct SettingsPopover: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Download Settings").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Default quality").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $state.defaultQuality) {
                    ForEach(DownloadQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu)
            }

            Toggle(isOn: $state.embedSubtitles) {
                Label("Embed subtitles (when available)", systemImage: "captions.bubble")
            }
            Toggle(isOn: $state.embedThumbnail) {
                Label("Embed thumbnail", systemImage: "photo")
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Save to").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(state.downloadFolder.path)
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Change…") { state.chooseDownloadFolder() }
                        .controlSize(.small)
                }
            }

            Divider()

            ExtensionSetupView()

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Connection").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Circle()
                        .fill(state.serverRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(state.serverRunning
                         ? "Active · listening on 127.0.0.1:\(state.port)"
                         : state.serverStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()
            Label(state.toolSummary, systemImage: state.toolsReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(state.toolsReady ? .green : .orange)
                .lineLimit(2)
        }
        .padding(16)
        .frame(width: 320)
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

// MARK: - Extension setup

/// Lists the browsers actually installed on this Mac and sets the extension up in
/// the one you pick.
///
/// The old flow hard-coded "Chrome" and told you to open `chrome://extensions` —
/// useless if you don't have Chrome (Arc, Brave and Edge users got no working path
/// at all). It also never told you whether setup had actually worked.
struct ExtensionSetupView: View {
    @EnvironmentObject var state: AppState
    @State private var chromium: [BrowserTarget] = []
    @State private var safari: BrowserTarget?
    @State private var sheetBrowser: BrowserTarget?
    /// Ticks so "last seen" stays honest while the popover is open.
    @State private var now = Date()
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Browser extension").font(.caption).foregroundStyle(.secondary)

            // Say plainly whether it's working — no guessing.
            HStack(spacing: 7) {
                Circle()
                    .fill(state.extensionStatus.connected ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 8, height: 8)
                Text(state.extensionStatus.text).font(.caption)
                    .foregroundStyle(state.extensionStatus.connected ? .primary : .secondary)
            }

            if chromium.isEmpty && safari == nil {
                Text("No supported browser found.")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            ForEach(chromium) { b in
                browserRow(
                    name: b.name,
                    detail: "Guided setup — takes about 20 seconds",
                    action: { sheetBrowser = b },
                    label: "Set up…"
                )
            }

            if let s = safari {
                browserRow(
                    name: s.name,
                    detail: "Enable in Safari’s Extensions settings",
                    action: { state.openSafariExtensionSettings() },
                    label: "Enable…"
                )
            }

            Text(state.extensionFolder.path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .onAppear {
            chromium = BrowserScan.chromiumInstalled()
            safari = BrowserScan.safariInstalled()
        }
        .onReceive(tick) { now = $0 }
        .sheet(item: $sheetBrowser) { b in
            ExtensionInstallSheet(browser: b).environmentObject(state)
        }
    }

    @ViewBuilder
    private func browserRow(name: String, detail: String,
                            action: @escaping () -> Void, label: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.caption).fontWeight(.medium)
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(label, action: action).controlSize(.small)
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
                    .font(.title2).foregroundStyle(.purple)
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
                .background(.purple, in: .circle)
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
                    .font(.system(size: 46)).foregroundStyle(.purple.gradient)
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
                        .buttonStyle(.glassProminent).tint(.purple).controlSize(.large)
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
                .foregroundStyle(.purple.gradient)
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
            guard let data = Data(base64Encoded: b64) else { return nil }
            return NSImage(data: data)
        }
        if s.hasPrefix("/") {
            return NSImage(contentsOfFile: s)
        }
        if s.hasPrefix("file://"), let url = URL(string: s) {
            return NSImage(contentsOf: url)
        }
        return nil
    }
}

// MARK: - Player

struct PlayerContext: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
}

struct PlayerSheet: View {
    let context: PlayerContext
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer

    init(context: PlayerContext) {
        self.context = context
        _player = State(initialValue: AVPlayer(url: context.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(context.title).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { player.pause(); dismiss() }.buttonStyle(.glass)
            }
            .padding(12)
            PlayerView(player: player)
                .frame(minWidth: 720, minHeight: 405)
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(.black)
        .onAppear { player.play() }
        .onDisappear { player.pause() }
    }
}

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
