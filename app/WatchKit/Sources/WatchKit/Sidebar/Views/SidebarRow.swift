import SwiftUI
import WatchProtocol

/// A sidebar row: an icon, a name that can be edited in place, and a short
/// detail at the trailing edge.
struct SidebarRow: View {
    @Environment(AppState.self) private var state

    let route: Route
    let title: String
    let systemImage: String
    var detail: String? = nil

    @FocusState private var focused: Bool

    private var isRenaming: Bool {
        state.renaming == route
    }

    var body: some View {
        @Bindable var state = state
        Label {
            if isRenaming {
                TextField("Name", text: $state.renameText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { handleCommit() }
                    #if os(macOS)
                    .onExitCommand { handleCancel() }
                    #endif
                    .onAppear { focused = true }
                    .onChange(of: focused) { _, focused in
                        if !focused { handleCommit() }
                    }
            } else {
                Text(title)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .badge(isRenaming ? nil : detail.map(Text.init))
    }

    private func handleCommit() {
        state.renameCommit()
    }

    private func handleCancel() {
        state.renameCancel()
    }
}

struct PlaylistRow: View {
    @Environment(AppState.self) private var state

    let playlist: Playlist
    @Binding var deleting: Route?

    private var route: Route { .playlist(playlist.id) }

    var body: some View {
        SidebarRow(
            route: route,
            title: playlist.name,
            systemImage: playlist.grid == .two ? "square.grid.2x2" : "square.grid.3x3",
            detail: "\(playlist.channels.count)")
            .dropDestination(for: String.self) { items, _ in
                handleDrop(items)
            }
            .contextMenu {
                Button("Rename") { state.renameBegin(route) }
                Divider()
                ForEach(GridSize.allCases) { grid in
                    Toggle("\(grid.label) Grid", isOn: Binding(
                        get: { playlist.grid == grid },
                        set: { _ in state.playlistResize(playlist.id, grid: grid) }))
                }
                Divider()
                Button.delete { deleting = route }
            }
    }

    /// Channels dragged from the list below join the playlist.
    private func handleDrop(_ channels: [String]) {
        for channel in channels where state.session.channel(channel) != nil {
            state.playlistAdd(channel, to: playlist.id)
        }
    }
}

struct ClipRow: View {
    @Environment(AppState.self) private var state

    let clip: Clip

    private var route: Route { .clip(clip.id) }

    var body: some View {
        SidebarRow(
            route: route,
            title: clip.name,
            systemImage: "play",
            detail: clip.duration?.clipLength)
            .draggable(clip.url)
            .contextMenu {
                Button("Rename") { state.renameBegin(route) }
                #if os(macOS)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
                #endif
                ShareLink(item: clip.url)
                Divider()
                Button("Move to Trash", systemImage: "trash") { state.clipDelete(clip.id) }
            }
    }
}

struct ChannelRow: View {
    @Environment(AppState.self) private var state

    let channel: Channel
    @Binding var deleting: Route?

    private var route: Route { .channel(channel.id) }

    var body: some View {
        SidebarRow(
            route: route,
            title: channel.displayName,
            systemImage: "play.rectangle")
            .draggable(channel.id)
            .help(channel.idLabel)
            .contextMenu {
                Button("Rename") { state.renameBegin(route) }
                Menu("Add to Playlist") {
                    ForEach(state.session.playlists) { playlist in
                        Button(playlist.name) { state.playlistAdd(channel.id, to: playlist.id) }
                            .disabled(playlist.channels.contains(channel.id))
                    }
                }
                Button("Copy Link") { Pasteboard.copy(channel.link.absoluteString) }
                Divider()
                Button.delete { deleting = route }
            }
    }
}

extension Channel {

    /// The channel's page on its site, for sharing.
    var link: URL {
        switch site {
        case .kick: URL(string: "https://kick.com/\(id.dropFirst(site.prefix.count))")!
        case .rumble: URL(string: "https://rumble.com/c/\(id.dropFirst(site.prefix.count))")!
        case .youtube: liveURL.deletingLastPathComponent()
        }
    }
}
