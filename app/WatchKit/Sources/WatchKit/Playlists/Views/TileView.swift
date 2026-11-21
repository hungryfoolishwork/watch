import SwiftUI
import WatchProtocol

/// One channel in the grid: its picture, its name, and the buttons that sit
/// over it.
struct TileView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openWindow) private var openWindow

    let channel: Channel
    /// In a grid the picture fills its tile and loses its edges. On its own
    /// it's shown whole.
    var fills = true

    @State private var isHovering = false

    private var stream: LiveStream? {
        state.streams[channel.id]
    }

    private var isListening: Bool {
        state.listening == channel.id
    }

    private var isInPip: Bool {
        state.pip == channel.id
    }

    var body: some View {
        ZStack {
            Color.black
            if let stream {
                PlayerLayer(layer: stream.layer, gravity: fills ? .resizeAspectFill : .resizeAspect)
                TileStatus(status: stream.status)
            }
        }
        .overlay(alignment: .bottom) {
            // Tickers and captions live along the bottom of the picture; the
            // shade keeps the name readable over them.
            Text(channel.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .lineLimit(1)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                        .padding(.top, -24)
                }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: .small) {
                if isHovering, stream?.url != nil {
                    Button("Clip", systemImage: "scissors") { handleClip() }
                        .help("Clip the last two minutes")
                        .transition(.opacity)
                }
                if isHovering, isInPip || state.canPip(channel.id) {
                    Button("Picture in Picture", systemImage: isInPip ? "pip.exit" : "pip.enter") { handlePip() }
                        .labelStyle(.iconOnly)
                        .help(isInPip ? "Bring back from Picture in Picture" : "Play in Picture in Picture")
                        .transition(.opacity)
                }
                // A muted tile always says so. The one with the sound has its
                // ring, so its button waits for the pointer.
                if !isListening || isHovering {
                    Button(isListening ? "Mute" : "Listen", systemImage: isListening ? "speaker.wave.2" : "speaker.slash") {
                        handleListen()
                    }
                    .labelStyle(.iconOnly)
                    .help(isListening ? "Mute" : "Listen to \(channel.displayName)")
                    .transition(.opacity)
                }
            }
            .buttonStyle(TileButtonStyle())
            .padding(12)
        }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isListening)
        .onHover { isHovering = $0 }
    }

    private func handleListen() {
        state.listenToggle(channel.id)
    }

    private func handleClip() {
        openWindow(id: ClipEditor.windowID, value: channel.id)
    }

    private func handlePip() {
        state.pipToggle(channel.id)
    }
}

/// What a tile says while there's no picture.
private struct TileStatus: View {
    let status: LiveStream.Status

    var body: some View {
        switch status {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .colorScheme(.dark)
        case .failed(let message):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Text("Retrying…")
                    .font(.caption)
                    .opacity(0.6)
            }
            .padding(.large)
            .foregroundStyle(.white)
        case .playing:
            EmptyView()
        }
    }
}

/// A position with no channel: the playlist ran out, or its channel was removed.
struct TileEmpty: View {
    var body: some View {
        ZStack {
            Color.black
            Text("Right-click to choose a channel")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.large)
        }
    }
}

/// The dark capsules over a tile's picture. They have to read over anything
/// from a black screen to a white one, so there's a dark layer under the
/// light one.
struct TileButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(minWidth: 35, minHeight: 35)
            .background {
                Capsule()
                    .fill(.black.opacity(0.35))
                    .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.35 : 0.2)))
            }
            .contentShape(Capsule())
    }
}
