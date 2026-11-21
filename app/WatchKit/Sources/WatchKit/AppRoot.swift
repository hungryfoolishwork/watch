import SwiftUI
import WatchProtocol

/// The main window: the sidebar, and whatever it has selected.
public struct AppRoot: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    public init() {}

    /// The Stream menu's single-key shortcuts would swallow typing, so
    /// they're only on while there are tiles to act on and no text field in
    /// the way.
    private var streamKeys: Bool {
        !state.showing.isEmpty && state.renaming == nil && state.router.modal == nil
    }

    private var showsTiles: Bool {
        switch state.router.selection {
        case .playlist, .channel: true
        default: false
        }
    }

    public var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbar { toolbar }
        }
        .sheet(item: $state.router.modal) { route in
            switch route {
            case .channelAdd: ChannelAdd()
            default: EmptyView()
            }
        }
        .alert("Something went wrong", isPresented: hasError) {
            Button("OK") { state.error = nil }
        } message: {
            Text(state.error ?? "")
        }
        .background(alignment: .bottomTrailing) { pipAnchor }
        .focusedSceneValue(\.streamKeys, streamKeys)
        .onOpenURL { url in
            handleOpen(url)
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.reload()
        }
        #endif
    }

    /// Picture in Picture can only be brought back while its layer is in a
    /// window. When the channel's tile isn't on screen, its layer is kept
    /// here instead, out of sight behind everything else.
    @ViewBuilder
    private var pipAnchor: some View {
        if let pip = state.pip, !state.showing.contains(pip), let stream = state.streams[pip] {
            PlayerLayer(layer: stream.layer)
                .frame(width: 2, height: 2)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.router.selection {
        case .playlist(let id):
            if let playlist = state.session.playlist(id) {
                PlaylistDetail(playlist: playlist)
            }
        case .channel(let id):
            if let channel = state.session.channel(id) {
                ChannelDetail(channel: channel)
            }
        case .clip(let id):
            if let clip = state.session.clip(id) {
                ClipDetail(clip: clip)
            }
        default:
            ContentUnavailableView {
                Label("Nothing Selected", systemImage: "square.grid.2x2")
            } description: {
                Text("Choose a playlist or a channel in the sidebar.")
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if showsTiles {
                Button("Padding", systemImage: state.showsPadding ? "square.grid.2x2" : "squareshape.split.2x2") {
                    handlePadding()
                }
                .help(state.showsPadding ? "Fit tiles edge to edge" : "Space tiles apart")

                Button("Zoom", systemImage: state.zoomed == nil
                       ? "arrow.up.backward.and.arrow.down.forward.rectangle"
                       : "arrow.down.forward.and.arrow.up.backward.rectangle") {
                    handleZoom()
                }
                .help(state.zoomed == nil ? "Zoom in on the tile that's playing" : "Show all tiles")
                .disabled(!state.canZoom)
            }
            Menu("Add", systemImage: "plus") {
                Button.newChannel { handleChannelAdd() }
                Button.newPlaylist { handlePlaylistCreate() }
            }
            .menuIndicator(.hidden)
            .help("Add a playlist or a channel")
        }
    }

    private var hasError: Binding<Bool> {
        Binding {
            state.error != nil
        } set: { showing in
            if !showing { state.error = nil }
        }
    }

    /// A `watch://` link: show what it names.
    private func handleOpen(_ url: URL) {
        switch Route(url: url) {
        case .playlist(let id) where state.session.playlist(id) != nil:
            state.select(.playlist(id))
        case .clip(let id) where state.session.clip(id) != nil:
            state.select(.clip(id))
        case .channel(let id) where state.session.channel(id) != nil:
            state.select(.channel(id))
        case .clipCreate(let channel) where state.session.channel(channel) != nil:
            openWindow(id: ClipEditor.windowID, value: channel)
        case .pip(let channel):
            state.pipToggle(channel)
        case .channelAdd:
            state.router.present(.channelAdd)
        case .settings:
            openWindow(id: "settings")
        default:
            break
        }
    }

    private func handlePadding() {
        state.showsPadding.toggle()
    }

    private func handleZoom() {
        state.zoomToggle()
    }

    private func handlePlaylistCreate() {
        state.playlistCreate()
    }

    private func handleChannelAdd() {
        state.router.present(.channelAdd)
    }
}

extension FocusedValues {

    /// True while the main window is in front with tiles showing and nothing
    /// being typed into.
    @Entry public var streamKeys: Bool?
}
