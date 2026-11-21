import SwiftUI
import WatchCore
import WatchProtocol

public struct SettingsMain: View {
    @Environment(AppState.self) private var state

    public init() {}

    private var ytdlp: String? {
        StreamResolver.ytdlp
    }

    public var body: some View {
        Form {
            Section {
                LabeledContent("yt-dlp") {
                    Text(ytdlp ?? "Not found")
                        .foregroundStyle(ytdlp == nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .textSelection(.enabled)
                }
            } header: {
                Text("YouTube")
            } footer: {
                Text(ytdlp == nil
                     ? "Watch needs yt-dlp to find YouTube streams. Install it with “brew install yt-dlp”. Rumble and Kick work without it."
                     : "Watch uses yt-dlp to find YouTube streams. Rumble and Kick work without it.")
            }
            Section {
                LabeledContent("Clips") {
                    FolderLink(url: state.session.clipsDirectory)
                }
                if let directory = state.session.directory {
                    LabeledContent("Channels and playlists") {
                        FolderLink(url: directory)
                    }
                }
            } header: {
                Text("Files")
            } footer: {
                Text("Clips are ordinary video files. channels.json and playlists.json can be edited by hand; Watch rereads them when you switch back to it.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A folder's path, and a button that opens it.
private struct FolderLink: View {
    let url: URL

    private var path: String {
        url.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    var body: some View {
        HStack(spacing: .medium) {
            Text(path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            #if os(macOS)
            Button("Show in Finder", systemImage: "magnifyingglass.circle.fill") { handleShow() }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
            #endif
        }
    }

    #if os(macOS)
    private func handleShow() {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }
    #endif
}
