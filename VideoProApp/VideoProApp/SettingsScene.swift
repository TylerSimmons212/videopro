import SwiftUI
import Combine

// MARK: - Settings window

/// The ⌘, window.
///
/// This used to be a 320pt popover hanging off the toolbar, which meant every new
/// preference had to justify itself against the space it stole from the ones
/// already there. Tabs give each concern room, and put settings where Mac users
/// already look for them.
///
/// Every tab is a grouped `Form`. Hand-rolled stacks were mixing label-less
/// pickers, labelled pickers and bare toggles, so nothing shared a label column
/// and the controls looked randomly indented; `Form` is what gives macOS its
/// standard aligned layout, and gets it identical on all five tabs for free.
struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DownloadSettingsTab()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            FastPathSettings()
                .tabItem { Label("Quick Grab", systemImage: "bolt") }
            ExtensionSetupView()
                .tabItem { Label("Extension", systemImage: "puzzlepiece.extension") }
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        // Fixed size rather than fit-to-content: otherwise the window resizes
        // every time you switch tabs.
        .frame(width: 500, height: 420)
    }
}

private extension View {
    /// One place to say "this is a settings pane", so a tab can't drift from the
    /// others by forgetting a modifier.
    func settingsForm() -> some View {
        formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Keep Inbox videos for", selection: $state.inboxExpiryDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(36_500)
                }
            } footer: {
                // The single most important thing to say about this setting: it is
                // not a delete button.
                Text("Expiry removes the library entry only. Files you’ve downloaded stay on disk, untouched.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Save downloads to") {
                    HStack(spacing: 8) {
                        Text(state.downloadFolder.path)
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") { state.chooseDownloadFolder() }
                    }
                }
            }
        }
        .settingsForm()
    }
}

// MARK: - Downloads

private struct DownloadSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section {
                Picker("Default quality", selection: $state.defaultQuality) {
                    ForEach(DownloadQuality.allCases) { Text($0.rawValue).tag($0) }
                }
            }

            Section {
                Toggle(isOn: $state.embedSubtitles) {
                    Label("Embed subtitles (when available)", systemImage: "captions.bubble")
                }
                Toggle(isOn: $state.embedThumbnail) {
                    Label("Embed thumbnail", systemImage: "photo")
                }
            } footer: {
                Text("Embedded tracks travel with the file, so they survive being moved or shared.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsForm()
    }
}

// MARK: - Advanced

/// Diagnostics rather than preferences — nothing here is a choice, it's the app
/// telling you whether its moving parts are alive.
private struct AdvancedSettingsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            Section("Downloader") {
                Label(state.toolSummary,
                      systemImage: state.toolsReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(state.toolsReady ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(isOn: $state.serverEnabled) {
                    Text("Accept videos from the browser extension")
                }
                if state.serverEnabled {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(state.serverRunning ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(state.serverRunning
                             ? "Listening on 127.0.0.1:\(state.port)"
                             : state.serverStatus)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Local connection")
            } footer: {
                // Say plainly what leaving it on costs, without melodrama.
                Text(state.serverEnabled
                     ? "While this is on, VideoPro listens on a local port. It can't tell an extension request apart from one made by a page you're visiting, so leave it off unless you use the extension."
                     : "Off. The global shortcut, the menu bar and dragging files in all work without it — only the browser extension needs it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsForm()
    }
}

// MARK: - Fast path settings

/// The grab-a-video-without-the-window controls: global hotkey and cookie source.
struct FastPathSettings: View {
    @EnvironmentObject var state: AppState
    @State private var browsers: [BrowserTarget] = []

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $state.hotKeyEnabled) {
                    Label("Global shortcut", systemImage: "keyboard")
                }
                LabeledContent("Shortcut") {
                    ShortcutRecorder(combo: $state.hotKeyCombo)
                }
                .disabled(!state.hotKeyEnabled)

                if state.hotKeyEnabled && state.hotKeyUnavailable {
                    // A hotkey another app already owns never fires, and looks
                    // identical to a bug unless we say so.
                    Label("Another app is already using this shortcut. Pick a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("Grabs the video from whichever browser you were last in. Click the shortcut to change it — it needs at least one of ⌃ ⌥ ⌘.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Sign-in cookies", selection: $state.cookieBrowserID) {
                    Text("Don’t use cookies").tag(String?.none)
                    ForEach(browsers) { b in
                        Text(b.name).tag(String?.some(b.id))
                    }
                }
            } footer: {
                // Say what it buys and what it costs, before they pick — both failure
                // modes here are opaque if you meet them cold.
                Text(state.cookieBrowser.flatMap(\.cookieCaveat)
                     ?? "Needed for private, members-only, or age-restricted videos.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .settingsForm()
        .onAppear { browsers = BrowserScan.installed().filter { $0.cookieSpec != nil } }
    }
}

// MARK: - Extension setup

/// Lists the browsers actually installed on this Mac and sets the extension up in
/// the one you pick.
///
/// The extension is a fallback now, not the way in — the hotkey, the menu bar and
/// paste all work without it. It earns its keep on sites that hide their media
/// behind a player the downloader can't see, so this tab leads with *when* you'd
/// want it rather than pushing anyone through setup.
///
/// The old flow hard-coded "Chrome" and told you to open `chrome://extensions` —
/// useless if you don't have Chrome (Arc, Brave and Edge users got no working path
/// at all). It also never told you whether setup had actually worked.
struct ExtensionSetupView: View {
    @EnvironmentObject var state: AppState
    @State private var chromium: [BrowserTarget] = []
    @State private var safari: BrowserTarget?
    @State private var sheetBrowser: BrowserTarget?
    /// Ticks so "last seen" stays honest while the window is open.
    @State private var now = Date()
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                // Say plainly whether it's working — no guessing.
                HStack(spacing: 7) {
                    Circle()
                        .fill(state.extensionStatus.connected ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                    Text(state.extensionStatus.text).font(.caption)
                        .foregroundStyle(state.extensionStatus.connected ? .primary : .secondary)
                }
            } header: {
                Text("Optional — for awkward sites")
            } footer: {
                Text("VideoPro doesn’t need the extension. Use the global shortcut, the menu bar, or paste a link. Install this only if a site hides its video from the downloader.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if chromium.isEmpty && safari == nil {
                    Text("No supported browser found.")
                        .font(.caption).foregroundStyle(.secondary)
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
            } header: {
                Text("Browsers")
            } footer: {
                Text(state.extensionFolder.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .settingsForm()
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
        LabeledContent {
            Button(label, action: action)
        } label: {
            Text(name)
            Text(detail)
        }
    }
}
