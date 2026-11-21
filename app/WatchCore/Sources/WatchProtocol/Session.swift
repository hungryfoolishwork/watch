import Foundation
import Observation

/// Everything Watch remembers: the channel library, the playlists made from
/// it, and the clips saved from live streams.
@MainActor
public protocol Session: AnyObject, Observable {

    /// Every channel, in the order the sidebar shows them.
    var channels: [Channel] { get }

    var playlists: [Playlist] { get }

    /// Saved clips, newest first.
    var clips: [Clip] { get }

    /// The folder holding the library's files, or nil when it only lives in
    /// memory.
    var directory: URL? { get }

    /// Rereads whatever changed on disk since the last look: the JSON files
    /// can be edited by hand and clips can be moved around in Finder.
    func reload()

    // MARK: Channels

    /// Adds a channel at the end of the library. Throws if it's already there.
    func channelAdd(_ channel: Channel) throws
    func channelRename(_ id: String, name: String)
    func channelMove(fromOffsets source: IndexSet, toOffset destination: Int)

    /// Removes the channel from the library and from every playlist.
    func channelDelete(_ id: String)

    // MARK: Playlists

    @discardableResult
    func playlistCreate(name: String, grid: GridSize, channels: [String]) -> Playlist
    func playlistUpdate(_ playlist: Playlist)
    func playlistMove(fromOffsets source: IndexSet, toOffset destination: Int)
    func playlistDelete(_ id: String)

    // MARK: Clips

    /// Where clips are saved.
    var clipsDirectory: URL { get }

    /// A file URL in the clips folder for a new clip with this name. The name
    /// is cleaned up for the file system and numbered if it's taken.
    func clipReserve(name: String) throws -> URL

    /// Call after writing a new clip so it shows up.
    func clipsReload()

    /// Renames the clip's file. A clip's id is its file name, so this returns
    /// the id it has afterwards.
    @discardableResult
    func clipRename(_ id: String, name: String) throws -> String

    /// Moves the clip's file to the Trash.
    func clipDelete(_ id: String) throws
}

public enum SessionError: LocalizedError {
    case channelExists(String)
    case clipMissing
    case clipNameTaken(String)

    public var errorDescription: String? {
        switch self {
        case .channelExists(let label): "\(label) is already in the list."
        case .clipMissing: "That clip's file is gone."
        case .clipNameTaken(let name): "There's already a clip named “\(name)”."
        }
    }
}

extension Session {

    public func channel(_ id: String) -> Channel? {
        channels.first { $0.id == id }
    }

    public func playlist(_ id: String) -> Playlist? {
        playlists.first { $0.id == id }
    }

    public func clip(_ id: String) -> Clip? {
        clips.first { $0.id == id }
    }
}
