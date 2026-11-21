import SwiftUI
import WatchProtocol

/// One channel on its own, filling the window.
struct ChannelDetail: View {
    @Environment(AppState.self) private var state

    let channel: Channel

    private var metrics: TileMetrics {
        TileMetrics(padded: state.showsPadding)
    }

    var body: some View {
        TileView(channel: channel, fills: false)
            .tileShape(metrics, isListening: false)
            .contentShape(Rectangle())
            .onTapGesture { handleClick() }
            .padding(metrics.padding)
            .animation(.snappy(duration: 0.25), value: state.showsPadding)
            .navigationTitle(channel.displayName)
            #if os(macOS)
            .navigationSubtitle(channel.idLabel)
            #endif
    }

    private func handleClick() {
        state.listenToggle(channel.id)
    }
}
