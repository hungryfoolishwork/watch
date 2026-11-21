import SwiftUI
import WatchProtocol

/// A playlist's tiles, laid out 2×2 or 3×3.
///
/// Click a tile to hear it, double-click to zoom in on it, drag it onto
/// another to swap them, right-click to choose its channel.
struct TileGrid: View {
    @Environment(AppState.self) private var state

    let playlist: Playlist

    private static let space = "grid"
    private static let animation = Animation.snappy(duration: 0.25)

    /// The tile being dragged to another spot. Resets on its own if the drag
    /// is cancelled (say, the grid zooms mid-drag).
    @GestureState(resetTransaction: Transaction(animation: TileGrid.animation))
    private var drag: Drag?

    private struct Drag: Equatable {
        var position: Int
        var translation: CGSize
        /// The other spot under the cursor, if any.
        var target: Int?
    }

    /// One spot in the grid. Its identity is the channel, so a tile that's
    /// swapped to another spot keeps its view (and its picture) and slides
    /// there instead of being rebuilt.
    private struct Spot: Identifiable {
        enum ID: Hashable {
            case channel(String)
            case empty(Int)
        }
        let position: Int
        let channel: Channel?
        var id: ID { channel.map { .channel($0.id) } ?? .empty(position) }
    }

    private var spots: [Spot] {
        playlist.visible.enumerated().map { position, id in
            Spot(position: position, channel: id.flatMap(state.session.channel))
        }
    }

    private var metrics: TileMetrics {
        TileMetrics(padded: state.showsPadding)
    }

    var body: some View {
        GeometryReader { geo in
            let layout = Layout(side: playlist.grid.rawValue, size: geo.size, metrics: metrics)

            ZStack(alignment: .topLeading) {
                ForEach(spots) { spot in
                    let position = spot.position
                    let isZoomed = spot.channel != nil && spot.channel?.id == state.zoomed
                    let isVisible = state.zoomed == nil || isZoomed
                    let isDragged = drag?.position == position
                    let frame = isZoomed ? layout.bounds : layout.rect(position)
                    let moved = isDragged ? drag?.translation ?? .zero : .zero

                    tile(spot)
                        .frame(width: frame.width, height: frame.height)
                        .tileShape(metrics, isListening: spot.channel != nil && spot.channel?.id == state.listening)
                        .overlay {
                            if drag?.target == position {
                                RoundedRectangle(cornerRadius: metrics.cornerRadius)
                                    .strokeBorder(.white.opacity(0.6), lineWidth: 4)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { handleDoubleClick(spot) }
                        .onTapGesture { handleClick(spot) }
                        // Drag a tile onto another to swap them; only in the
                        // plain grid, where every spot is showing.
                        .gesture(dragGesture(for: position, in: layout),
                                 including: state.zoomed == nil ? .all : .subviews)
                        .contextMenu { TileMenu(playlist: playlist, position: position) }
                        .dropDestination(for: String.self) { items, _ in
                            handleDrop(channels: items, at: position)
                        }
                        .scaleEffect(isDragged ? 0.9 : 1)
                        .opacity(isDragged ? 0.85 : 1)
                        .shadow(color: .black.opacity(isDragged ? 0.5 : 0), radius: 16)
                        .animation(.snappy(duration: 0.15), value: isDragged)
                        .offset(x: frame.minX + moved.width, y: frame.minY + moved.height)
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
                        .zIndex(isDragged ? 2 : isZoomed ? 1 : 0)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(.named(Self.space))
            .animation(Self.animation, value: state.zoomed)
            .animation(Self.animation, value: state.showsPadding)
            .animation(Self.animation, value: playlist.grid)
        }
    }

    @ViewBuilder
    private func tile(_ spot: Spot) -> some View {
        if let channel = spot.channel {
            TileView(channel: channel)
        } else {
            TileEmpty()
        }
    }

    private func dragGesture(for position: Int, in layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .updating($drag) { value, drag, _ in
                let target = layout.position(at: value.location)
                drag = Drag(position: position,
                            translation: value.translation,
                            target: target == position ? nil : target)
            }
            .onEnded { value in
                guard let target = layout.position(at: value.location) else { return }
                handleSwap(position, target)
            }
    }

    private func handleClick(_ spot: Spot) {
        guard let channel = spot.channel else { return }
        state.listenToggle(channel.id)
    }

    /// Zooms in on the tile, or back out if it already fills the grid.
    private func handleDoubleClick(_ spot: Spot) {
        guard let channel = spot.channel else { return }
        state.zoomToggle(channel.id)
    }

    private func handleSwap(_ position: Int, _ target: Int) {
        withAnimation(Self.animation) {
            state.playlistSwap(position, target)
        }
    }

    /// A channel dragged in from the sidebar lands on this tile.
    private func handleDrop(channels: [String], at position: Int) {
        guard let channel = channels.first, state.session.channel(channel) != nil else { return }
        withAnimation(Self.animation) {
            state.playlistPlace(channel, at: position)
        }
    }

    /// Where the tiles go: `side` rows and columns inside the padding.
    private struct Layout {
        let side: Int
        let size: CGSize
        let metrics: TileMetrics

        /// Everything inside the padding; what a zoomed tile fills.
        var bounds: CGRect {
            CGRect(origin: .zero, size: size).insetBy(dx: metrics.padding, dy: metrics.padding)
        }

        private var cell: CGSize {
            let gaps = metrics.spacing * CGFloat(side - 1)
            return CGSize(width: max(0, bounds.width - gaps) / CGFloat(side),
                          height: max(0, bounds.height - gaps) / CGFloat(side))
        }

        func rect(_ position: Int) -> CGRect {
            let cell = cell
            return CGRect(
                x: bounds.minX + CGFloat(position % side) * (cell.width + metrics.spacing),
                y: bounds.minY + CGFloat(position / side) * (cell.height + metrics.spacing),
                width: cell.width,
                height: cell.height)
        }

        /// The grid position under a point, or nil if it's outside the grid.
        func position(at point: CGPoint) -> Int? {
            guard bounds.contains(point) else { return nil }
            let cell = cell
            let column = min(Int((point.x - bounds.minX) / (cell.width + metrics.spacing)), side - 1)
            let row = min(Int((point.y - bounds.minY) / (cell.height + metrics.spacing)), side - 1)
            return row * side + column
        }
    }
}

/// How tiles sit in the window: apart with rounded corners, or edge to edge
/// with a hairline between them.
struct TileMetrics: Equatable {
    let padded: Bool

    var padding: CGFloat { padded ? 16 : 0 }
    var spacing: CGFloat { padded ? 16 : 1 }
    var cornerRadius: CGFloat { padded ? 8 : 0 }
}

extension View {

    /// Clips a tile to its shape and, when it's the one with sound and there's
    /// room to show it, draws a soft ring around it.
    func tileShape(_ metrics: TileMetrics, isListening: Bool) -> some View {
        self
            .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
            .background {
                if metrics.padded {
                    RoundedRectangle(cornerRadius: metrics.cornerRadius + 4)
                        .fill(.primary.opacity(isListening ? 0.1 : 0))
                        .padding(-4)
                }
            }
    }
}

/// Right-click a tile to choose its channel from the playlist. Picking one
/// that's on another tile swaps the two.
private struct TileMenu: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    let playlist: Playlist
    let position: Int

    private var current: String? {
        playlist.tiles[position]
    }

    private var members: [Channel] {
        playlist.channels.compactMap(state.session.channel)
    }

    /// Library channels that aren't in this playlist yet.
    private var others: [Channel] {
        state.session.channels.filter { !playlist.channels.contains($0.id) }
    }

    var body: some View {
        ForEach(members) { channel in
            Toggle(channel.displayName, isOn: Binding(
                get: { current == channel.id },
                set: { _ in handlePick(channel) }))
        }
        if members.isEmpty {
            Text("No channels in this playlist")
        }
        Divider()
        Menu("Add to Playlist") {
            ForEach(others) { channel in
                Button(channel.displayName) { handlePick(channel) }
            }
            if !others.isEmpty {
                Divider()
            }
            Button("New Channel…") { handleChannelAdd() }
        }
        if let current, let channel = state.session.channel(current) {
            Button("Remove “\(channel.displayName)” from Playlist") { handleRemove(current) }
            Divider()
            Button("Clip…", systemImage: "scissors") { handleClip(current) }
                .disabled(state.streams[current]?.url == nil)
        }
    }

    private func handlePick(_ channel: Channel) {
        withAnimation(.snappy(duration: 0.25)) {
            state.playlistPlace(channel.id, at: position)
        }
    }

    private func handleRemove(_ channel: String) {
        state.playlistRemove(channel, from: playlist.id)
    }

    private func handleChannelAdd() {
        state.router.present(.channelAdd)
    }

    private func handleClip(_ channel: String) {
        openWindow(id: ClipEditor.windowID, value: channel)
    }
}
