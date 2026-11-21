import SwiftUI
import WatchProtocol

/// The menus Watch adds: New Playlist and Add Channel under File, and the
/// Stream menu.
///
/// The Stream menu's single-key shortcuts (0–9, M, R, C, P, Esc) are only
/// enabled while the main window is in front showing tiles, so they don't
/// swallow typing anywhere else.
public struct StreamCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.streamKeys) private var streamKeys

    private let state: AppState

    public init(state: AppState) {
        self.state = state
    }

    private var keys: Bool {
        streamKeys == true
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button.newChannel {
                state.router.present(.channelAdd)
            }
            .keyboardShortcut("n", modifiers: [.command])
            Button.newPlaylist {
                state.playlistCreate()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Stream") {
            ForEach(GridSize.allCases) { grid in
                Toggle("\(grid.label) Grid", isOn: Binding(
                    get: { state.playlist?.grid == grid },
                    set: { _ in handleResize(grid) }))
                    .keyboardShortcut(KeyEquivalent(Character("\(grid.tiles)")), modifiers: .command)
                    .disabled(state.playlist == nil)
            }
            Toggle("Padding", isOn: Binding(
                get: { state.showsPadding },
                set: { state.showsPadding = $0 }))
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Divider()
            Button("Zoom In on Tile") { state.zoomToggle() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!keys || !state.canZoom || state.zoomed != nil)
            Button("Show All Tiles") { state.zoom(nil) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!keys || state.zoomed == nil)
            Divider()
            ForEach(0..<Playlist.positions, id: \.self) { position in
                Button("Listen to Tile \(position + 1)") { state.listen(tile: position) }
                    .keyboardShortcut(KeyEquivalent(Character("\(position + 1)")), modifiers: [])
                    .disabled(!keys || position >= (state.playlist?.grid.tiles ?? 0))
            }
            Button("Listen to Picture in Picture") { state.listen(state.pip) }
                .keyboardShortcut("0", modifiers: [])
                .disabled(!keys || state.pip == nil)
            Divider()
            Button("Mute All") { state.listen(nil) }
                .keyboardShortcut("m", modifiers: [])
                .disabled(!keys)
            Button("Reload Streams") { state.streamsReload() }
                .keyboardShortcut("r", modifiers: [])
                .disabled(!keys)
            Divider()
            Button("Clip Playing Tile…") { handleClip() }
                .keyboardShortcut("c", modifiers: [])
                .disabled(!keys || state.listening.flatMap { state.streams[$0]?.url } == nil)
            if state.pip == nil {
                Button("Play in Picture in Picture") { state.pipToggle() }
                    .keyboardShortcut("p", modifiers: [])
                    .disabled(!keys || !canPip)
            } else {
                Button("Bring Back from Picture in Picture") { state.pipToggle() }
                    .keyboardShortcut("p", modifiers: [])
                    .disabled(!keys)
            }
        }
    }

    /// Whether the tile that's playing, or failing that the first one, can
    /// go out to Picture in Picture.
    private var canPip: Bool {
        (state.listening ?? state.showing.first).map(state.canPip) ?? false
    }

    private func handleResize(_ grid: GridSize) {
        guard let playlist = state.playlist else { return }
        state.playlistResize(playlist.id, grid: grid)
    }

    private func handleClip() {
        guard let channel = state.listening else { return }
        openWindow(id: ClipEditor.windowID, value: channel)
    }
}
