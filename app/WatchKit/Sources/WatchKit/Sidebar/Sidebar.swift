import SwiftUI
import WatchProtocol

/// The window's left pane: playlists, saved clips, and the channel library.
public struct Sidebar: View {
    @Environment(AppState.self) private var state

    /// A playlist or channel waiting on "are you sure?".
    @State private var deleting: Route?

    public init() {}

    private var selection: Binding<Route?> {
        Binding {
            state.router.selection
        } set: { route in
            // Clicking the empty part of the list shouldn't stop everything
            // that's playing.
            guard let route else { return }
            state.select(route)
        }
    }

    public var body: some View {
        List(selection: selection) {
            Section("Playlists") {
                ForEach(state.session.playlists) { playlist in
                    PlaylistRow(playlist: playlist, deleting: $deleting)
                        .tag(Route.playlist(playlist.id))
                }
                .onMove { source, destination in
                    state.session.playlistMove(fromOffsets: source, toOffset: destination)
                }
            }
            if !state.session.clips.isEmpty {
                Section("Clips") {
                    ForEach(state.session.clips) { clip in
                        ClipRow(clip: clip)
                            .tag(Route.clip(clip.id))
                    }
                }
            }
            Section("Channels") {
                ForEach(state.session.channels) { channel in
                    ChannelRow(channel: channel, deleting: $deleting)
                        .tag(Route.channel(channel.id))
                }
            }
        }
        .listStyle(.sidebar)
        #if os(macOS)
        .onDeleteCommand { handleDeleteSelected() }
        #endif
        .confirmationDialog(deletingTitle, isPresented: isDeleting, presenting: deleting) { route in
            Button("Delete", role: .destructive) { handleDelete(route) }
        } message: { route in
            Text(deletingMessage(route))
        }
    }

    private var isDeleting: Binding<Bool> {
        Binding {
            deleting != nil
        } set: { showing in
            if !showing { deleting = nil }
        }
    }

    private var deletingTitle: String {
        switch deleting {
        case .playlist(let id): "Delete “\(state.session.playlist(id)?.name ?? "")”?"
        case .channel(let id): "Delete “\(state.session.channel(id)?.displayName ?? "")”?"
        default: ""
        }
    }

    private func deletingMessage(_ route: Route) -> String {
        switch route {
        case .playlist: "Its channels stay in your library."
        case .channel: "It's removed from your library and from every playlist."
        default: ""
        }
    }

    private func handleDeleteSelected() {
        switch state.router.selection {
        case .playlist, .channel: deleting = state.router.selection
        case .clip(let id): state.clipDelete(id)
        default: break
        }
    }

    private func handleDelete(_ route: Route) {
        switch route {
        case .playlist(let id): state.playlistDelete(id)
        case .channel(let id): state.channelDelete(id)
        default: break
        }
    }
}
