import SwiftUI
import WatchProtocol

struct PlaylistDetail: View {
    let playlist: Playlist

    private var subtitle: String {
        playlist.channels.count == 1 ? "1 channel" : "\(playlist.channels.count) channels"
    }

    var body: some View {
        TileGrid(playlist: playlist)
            .navigationTitle(playlist.name)
            #if os(macOS)
            .navigationSubtitle(subtitle)
            #endif
    }
}
