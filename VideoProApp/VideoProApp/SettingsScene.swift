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
/// standard aligned layout, and gets it identical on every tab for free.
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
                Toggle("Offer links you copy", isOn: $state.offerCopiedLinks)
            } footer: {
                Text("When you come back to VideoPro, a link you copied in another app is waiting in the field, ready to download.")
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

            Section {
                Toggle(isOn: $state.convertForQuickTime) {
                    Label("Convert videos QuickTime can’t play", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("Above 1080p, YouTube sends AV1 or VP9, which QuickTime can’t play on Macs before M3. VideoPro re-encodes those downloads to HEVC on the Mac’s hardware encoder — about as long as the video itself for 4K — and replaces the original. Off keeps the original, for IINA or VLC.")
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
        }
        .settingsForm()
    }
}

// MARK: - Fast path settings

/// The grab-a-video-without-the-window controls: global hotkey and cookie source.
struct FastPathSettings: View {
    @EnvironmentObject var state: AppState
    @State private var browsers: [BrowserTarget] = []
    @State private var copiedBookmarklet = false

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
                LabeledContent {
                    Button(copiedBookmarklet ? "Copied" : "Copy Bookmarklet") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(state.bookmarklet, forType: .string)
                        copiedBookmarklet = true
                    }
                } label: {
                    Text("Bookmarklet")
                    Text("Sends the page you’re on to VideoPro, from any browser")
                }
            } footer: {
                Text("Make a bookmark in your bookmarks bar and paste this as its address. Click it on a page with a video: a single video starts downloading, a playlist opens for picking. Works in Firefox, which the shortcut can’t read.")
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
