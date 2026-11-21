import AVKit
import SwiftUI
import WatchProtocol

/// A saved clip, playing.
struct ClipDetail: View {
    @Environment(AppState.self) private var state

    let clip: Clip

    @State private var player = AVPlayer()

    private var subtitle: String {
        let saved = clip.created.formatted(date: .abbreviated, time: .shortened)
        guard let duration = clip.duration else { return saved }
        return "\(duration.clipLength) · \(saved)"
    }

    private var metrics: TileMetrics {
        TileMetrics(padded: state.showsPadding)
    }

    var body: some View {
        VideoPlayer(player: player)
            .clipShape(RoundedRectangle(cornerRadius: metrics.cornerRadius))
            .padding(metrics.padding)
            .task(id: clip.url) {
                player.replaceCurrentItem(with: AVPlayerItem(url: clip.url))
                player.play()
            }
            .onDisappear {
                player.pause()
            }
            .navigationTitle(clip.name)
            #if os(macOS)
            .navigationSubtitle(subtitle)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: clip.url)
                    #if os(macOS)
                    Button("Show in Finder", systemImage: "folder") { handleReveal() }
                        .help("Show in Finder")
                    #endif
                }
            }
    }

    #if os(macOS)
    private func handleReveal() {
        NSWorkspace.shared.activateFileViewerSelecting([clip.url])
    }
    #endif
}
