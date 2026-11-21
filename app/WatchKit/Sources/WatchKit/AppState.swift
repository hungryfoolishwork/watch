import Foundation
import SwiftUI
import WatchCore
import WatchProtocol

@MainActor
@Observable
public final class AppState {

    public var router = Router()
    public let session: any WatchProtocol::Session

    /// The streams that are running, by channel id. Only channels on screen
    /// have one, and a channel keeps its stream when it moves to another tile
    /// or the selection changes to something else that shows it.
    public private(set) var streams: [String: LiveStream] = [:]

    /// The channel with sound. Everything else is muted.
    public private(set) var listening: String?

    /// The channel zoomed to fill the grid. The tiles behind it are paused.
    public private(set) var zoomed: String?

    /// Whether tiles sit apart with rounded corners or edge to edge.
    public var showsPadding: Bool {
        didSet { UserDefaults.standard.set(showsPadding, forKey: Keys.showsPadding) }
    }

    /// The sidebar row whose name is being edited, and the text so far.
    public private(set) var renaming: Route?
    public var renameText = ""

    /// Something went wrong that the person should hear about.
    public var error: String?

    /// False for previews, which shouldn't go looking for streams.
    private let playsStreams: Bool

    /// Whether arriving at a playlist gives its first tile the sound.
    /// `-muted YES` on the command line turns that off, so nothing plays
    /// aloud until a tile is clicked.
    private let listensOnArrival = !UserDefaults.standard.bool(forKey: "muted")

    private enum Keys {
        static let showsPadding = "showsPadding"
    }

    public init(session: any WatchProtocol::Session, playsStreams: Bool = true) {
        self.session = session
        self.playsStreams = playsStreams
        let defaults = UserDefaults.standard
        self.showsPadding = defaults.object(forKey: Keys.showsPadding) == nil || defaults.bool(forKey: Keys.showsPadding)

        router.restore(resolve: exists)
        select(router.selection ?? session.playlists.first.map { .playlist($0.id) })
    }

    // MARK: - Selection

    /// The playlist on screen, if that's what is selected.
    public var playlist: Playlist? {
        guard case .playlist(let id) = router.selection else { return nil }
        return session.playlist(id)
    }

    /// The channels on screen, in tile order.
    public var showing: [String] {
        switch router.selection {
        case .playlist(let id): session.playlist(id)?.visible.compactMap { $0 } ?? []
        case .channel(let id): session.channel(id) == nil ? [] : [id]
        default: []
        }
    }

    public func select(_ route: Route?) {
        if router.selection != route {
            router.selection = route
            zoomed = nil
        }
        sync()
        // Arriving somewhere with nothing audible gives the first tile the
        // sound. Later changes leave a deliberate silence alone.
        if listening == nil, listensOnArrival {
            listen(showing.first)
        }
    }

    private func exists(_ route: Route) -> Bool {
        switch route {
        case .playlist(let id): session.playlist(id) != nil
        case .clip(let id): session.clip(id) != nil
        case .channel(let id): session.channel(id) != nil
        case .clipCreate, .channelAdd, .settings: false
        }
    }

    /// Call when the app comes back to the front: files may have changed.
    public func reload() {
        session.reload()
        selectionRepair()
        sync()
    }

    /// Moves the selection off something that no longer exists.
    private func selectionRepair() {
        guard let route = router.selection, !exists(route) else { return }
        select(session.playlists.first.map { .playlist($0.id) })
    }

    // MARK: - Streams

    /// Starts streams for channels that came on screen, stops the ones that
    /// left, and puts mute and pause in step with `listening` and `zoomed`.
    private func sync() {
        let showing = showing
        for (id, stream) in streams where !showing.contains(id) {
            stream.stop()
            streams[id] = nil
        }
        if playsStreams {
            for id in showing where streams[id] == nil {
                guard let channel = session.channel(id) else { continue }
                streams[id] = LiveStream(channel: channel)
            }
        }
        if let listening, !showing.contains(listening) { self.listening = nil }
        if let zoomed, !showing.contains(zoomed) { self.zoomed = nil }

        for (id, stream) in streams {
            stream.isMuted = id != listening
            stream.setActive(zoomed == nil || zoomed == id)
        }
    }

    /// Gives a channel the sound, or with nil mutes everything. Listening to
    /// a tile hidden behind the zoomed one brings it forward instead, so the
    /// number keys flip channels while zoomed.
    public func listen(_ channel: String?) {
        if let channel, zoomed != nil, zoomed != channel {
            zoomed = channel
        }
        listening = channel
        sync()
    }

    public func listenToggle(_ channel: String) {
        listen(listening == channel ? nil : channel)
    }

    /// Listens to the tile at a grid position, counting from zero.
    public func listen(tile position: Int) {
        guard let playlist, playlist.visible.indices.contains(position),
              let channel = playlist.visible[position]
        else { return }
        listen(channel)
    }

    /// Fills the grid with one channel, which also gets the sound. Nil goes
    /// back to showing every tile.
    public func zoom(_ channel: String?) {
        zoomed = channel
        if let channel { listening = channel }
        sync()
    }

    /// Zooms in on the tile that's playing (or the first one), or back out.
    public func zoomToggle(_ channel: String? = nil) {
        if zoomed != nil, channel == nil || channel == zoomed {
            zoom(nil)
        } else if let target = channel ?? listening ?? showing.first {
            zoom(target)
        }
    }

    public var canZoom: Bool {
        playlist != nil && !showing.isEmpty
    }

    /// Finds every stream on screen again, as when a channel has just gone live.
    public func streamsReload() {
        streams.values.forEach { $0.load() }
    }

    // MARK: - Channels

    /// Adds a channel to the library and, when a playlist is on screen, to
    /// that playlist. `input` is whatever was pasted; see `Channel.init(input:)`.
    public func channelAdd(input: String, name: String) throws {
        guard let channel = Channel(input: input, name: name) else {
            throw AppStateError.notAChannel
        }
        try session.channelAdd(channel)
        if var playlist {
            playlist.add(channel.id)
            session.playlistUpdate(playlist)
        }
        sync()
    }

    public func channelDelete(_ id: String) {
        session.channelDelete(id)
        selectionRepair()
        sync()
    }

    // MARK: - Playlists

    /// Makes an empty playlist, shows it, and starts editing its name.
    public func playlistCreate() {
        let taken = Set(session.playlists.map(\.name))
        var name = "Untitled Playlist"
        var number = 2
        while taken.contains(name) {
            name = "Untitled Playlist \(number)"
            number += 1
        }
        let playlist = session.playlistCreate(name: name, grid: .two, channels: [])
        select(.playlist(playlist.id))
        renameBegin(.playlist(playlist.id))
    }

    public func playlistDelete(_ id: String) {
        session.playlistDelete(id)
        selectionRepair()
        sync()
    }

    public func playlistResize(_ id: String, grid: GridSize) {
        playlistEdit(id) { $0.resize(grid) }
    }

    public func playlistAdd(_ channel: String, to id: String) {
        playlistEdit(id) { $0.add(channel) }
    }

    public func playlistRemove(_ channel: String, from id: String) {
        playlistEdit(id) { $0.remove(channel) }
    }

    /// Puts a channel on a tile of the playlist on screen. A channel that's
    /// already on another tile swaps with this one, and both keep playing.
    public func playlistPlace(_ channel: String, at position: Int) {
        guard let playlist else { return }
        playlistEdit(playlist.id) { $0.place(channel, at: position) }
    }

    /// Swaps two tiles of the playlist on screen.
    public func playlistSwap(_ a: Int, _ b: Int) {
        guard let playlist else { return }
        playlistEdit(playlist.id) { $0.swap(a, b) }
    }

    private func playlistEdit(_ id: String, _ edit: (inout Playlist) -> Void) {
        guard var playlist = session.playlist(id) else { return }
        edit(&playlist)
        session.playlistUpdate(playlist)
        sync()
    }

    // MARK: - Clips

    /// Shows a clip that was just written to the clips folder.
    public func clipSaved(_ url: URL) {
        session.clipsReload()
        select(.clip(url.lastPathComponent))
    }

    public func clipDelete(_ id: String) {
        attempt { try session.clipDelete(id) }
        selectionRepair()
    }

    // MARK: - Renaming

    public func renameBegin(_ route: Route) {
        switch route {
        case .playlist(let id): renameText = session.playlist(id)?.name ?? ""
        case .clip(let id): renameText = session.clip(id)?.name ?? ""
        case .channel(let id): renameText = session.channel(id)?.name ?? ""
        case .clipCreate, .channelAdd, .settings: return
        }
        renaming = route
    }

    public func renameCommit() {
        guard let route = renaming else { return }
        renaming = nil
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch route {
        case .playlist(let id):
            guard !name.isEmpty, var playlist = session.playlist(id) else { return }
            playlist.name = name
            session.playlistUpdate(playlist)
        case .clip(let id):
            guard !name.isEmpty else { return }
            // A clip's id is its file name, so the selection has to follow.
            let wasSelected = router.selection == route
            attempt {
                let renamed = try session.clipRename(id, name: name)
                if wasSelected { router.selection = .clip(renamed) }
            }
        case .channel(let id):
            session.channelRename(id, name: name)
        case .clipCreate, .channelAdd, .settings:
            break
        }
    }

    public func renameCancel() {
        renaming = nil
    }

    // MARK: - Errors

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

public enum AppStateError: LocalizedError {
    case notAChannel

    public var errorDescription: String? {
        switch self {
        case .notAChannel: "That doesn't look like a YouTube, Rumble, or Kick channel."
        }
    }
}

extension AppState {

    /// The app as it runs: the library on disk, streams playing.
    public static var live: AppState {
        .init(session: WatchCore::Session.disk())
    }

    /// A sample library that never touches the network or the disk.
    public static var preview: AppState {
        .init(session: WatchCore::Session.preview(), playsStreams: false)
    }
}
