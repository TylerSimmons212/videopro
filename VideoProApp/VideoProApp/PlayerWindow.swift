import SwiftUI
import AVKit

/// What a player window is opened with. `Codable`/`Hashable` because
/// `WindowGroup(for:)` persists the value across launches and uses equality to
/// decide whether to reuse a window — so no `id` field here: two plays of the
/// same file should raise the one window that already has it, not stack up
/// duplicates. A re-resolved stream URL differs, so it correctly gets its own.
struct PlayerContext: Codable, Hashable {
    let url: URL
    let title: String
}

/// Playback lives in its own window rather than a sheet so the library stays
/// usable — browsing and queueing downloads while a video is open is the whole
/// point of a video app.
struct PlayerWindowView: View {
    let context: PlayerContext?

    var body: some View {
        if let context {
            // Keyed on the context so a window restored with a different value
            // rebuilds its player instead of holding the old one's asset.
            PlayerWindowContent(context: context).id(context)
        } else {
            // Only reachable if the persisted value fails to decode.
            ContentUnavailableView("Nothing to play", systemImage: "film")
        }
    }
}

private struct PlayerWindowContent: View {
    let context: PlayerContext
    @State private var player: AVPlayer

    init(context: PlayerContext) {
        self.context = context
        _player = State(initialValue: AVPlayer(url: context.url))
    }

    var body: some View {
        PlayerView(player: player)
            .frame(minWidth: 720, minHeight: 460)
            .background(.black)
            .navigationTitle(context.title)
            .onAppear { player.play() }
            .onDisappear {
                // Closing the window only tears down the view; without this the
                // audio of a detached AVPlayer keeps going.
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
    }
}
