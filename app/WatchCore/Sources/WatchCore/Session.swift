import AVFoundation
import Foundation
import WatchProtocol

/// A session kept in plain files.
///
/// The library is two JSON files in `directory`: `channels.json` and
/// `playlists.json`. Both can be edited by hand (see the types' Codable
/// conformances for what's accepted); ``reload()`` picks up the changes.
/// Clips are the video files in `clipsDirectory` and nothing else: there is
/// no index to fall out of step with the folder.
///
/// With no `directory` the library lives in memory only, for previews and
/// tests.
@MainActor
@Observable
public final class Session: WatchProtocol::Session {
    public private(set) var channels: [Channel] = []
    public private(set) var playlists: [Playlist] = []
    public private(set) var clips: [Clip] = []

    public let directory: URL?
    public let clipsDirectory: URL

    private var channelsModified: Date?
    private var playlistsModified: Date?
    /// Durations already read, by file name and modification date, so a
    /// rescan only opens files that are new or changed.
    private var durations: [String: (modified: Date, duration: TimeInterval)] = [:]

    private var channelsURL: URL? { directory?.appending(path: "channels.json") }
    private var playlistsURL: URL? { directory?.appending(path: "playlists.json") }

    private static let clipExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public init(directory: URL?, clipsDirectory: URL) {
        self.directory = directory
        self.clipsDirectory = clipsDirectory

        if !loadChannels() {
            channels = Channel.defaults
            saveChannels()
        }
        if !loadPlaylists() {
            // First launch: one playlist holding everything.
            playlists = [Playlist(name: "News", channels: channels.map(\.id))]
            savePlaylists()
        }
        clipsReload()
    }

    /// A session with a fixed library that's never written anywhere.
    public init(channels: [Channel], playlists: [Playlist], clips: [Clip] = []) {
        self.directory = nil
        self.clipsDirectory = URL.temporaryDirectory.appending(path: "Watch-\(UUID().uuidString)")
        self.channels = channels
        self.playlists = playlists
        self.clips = clips
    }

    public func reload() {
        if let url = channelsURL, let date = modified(url), date != channelsModified {
            loadChannels()
            prunePlaylists()
        }
        if let url = playlistsURL, let date = modified(url), date != playlistsModified {
            loadPlaylists()
        }
        clipsReload()
    }

    // MARK: - Channels

    public func channelAdd(_ channel: Channel) throws {
        guard self.channel(channel.id) == nil else {
            throw SessionError.channelExists(channel.idLabel)
        }
        channels.append(channel)
        saveChannels()
    }

    public func channelRename(_ id: String, name: String) {
        guard let index = channels.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = trimmed.isEmpty ? nil : trimmed
        guard channels[index].name != newName else { return }
        channels[index].name = newName
        saveChannels()
    }

    public func channelMove(fromOffsets source: IndexSet, toOffset destination: Int) {
        channels.shift(fromOffsets: source, toOffset: destination)
        saveChannels()
    }

    public func channelDelete(_ id: String) {
        channels.removeAll { $0.id == id }
        saveChannels()
        prunePlaylists()
    }

    // MARK: - Playlists

    @discardableResult
    public func playlistCreate(name: String, grid: GridSize, channels: [String]) -> Playlist {
        let known = Set(self.channels.map(\.id))
        let playlist = Playlist(name: name, grid: grid, channels: channels.filter(known.contains))
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    public func playlistUpdate(_ playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }),
              playlists[index] != playlist
        else { return }
        var playlist = playlist
        playlist.retain(Set(channels.map(\.id)))
        playlists[index] = playlist
        savePlaylists()
    }

    public func playlistMove(fromOffsets source: IndexSet, toOffset destination: Int) {
        playlists.shift(fromOffsets: source, toOffset: destination)
        savePlaylists()
    }

    public func playlistDelete(_ id: String) {
        playlists.removeAll { $0.id == id }
        savePlaylists()
    }

    /// Takes channels that have left the library out of every playlist.
    private func prunePlaylists() {
        let known = Set(channels.map(\.id))
        var pruned = playlists
        for index in pruned.indices {
            pruned[index].retain(known)
        }
        guard pruned != playlists else { return }
        playlists = pruned
        savePlaylists()
    }

    // MARK: - Clips

    public func clipReserve(name: String) throws -> URL {
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        let base = Self.fileName(name)
        var candidate = clipsDirectory.appending(path: "\(base).mp4")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            candidate = clipsDirectory.appending(path: "\(base) \(number).mp4")
            number += 1
        }
        return candidate
    }

    public func clipsReload() {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: clipsDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []

        var found: [Clip] = []
        var unread: [(url: URL, modified: Date)] = []
        for url in files where Self.clipExtensions.contains(url.pathExtension.lowercased()) {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            var clip = Clip(url: url, created: values.creationDate ?? modified)
            if let known = durations[clip.id], known.modified == modified {
                clip.duration = known.duration
            } else {
                unread.append((url, modified))
            }
            found.append(clip)
        }
        found.sort { $0.created > $1.created }
        if found != clips { clips = found }

        let names = Set(found.map(\.id))
        durations = durations.filter { names.contains($0.key) }

        for (url, modified) in unread {
            Task { [weak self] in
                guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return }
                self?.clipLoaded(id: url.lastPathComponent, modified: modified, duration: time.seconds)
            }
        }
    }

    private func clipLoaded(id: String, modified: Date, duration: TimeInterval) {
        durations[id] = (modified, duration)
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[index].duration = duration
    }

    @discardableResult
    public func clipRename(_ id: String, name: String) throws -> String {
        guard let clip = clip(id) else { throw SessionError.clipMissing }
        let base = Self.fileName(name)
        guard base != clip.name else { return id }
        let destination = clipsDirectory.appending(path: "\(base).\(clip.url.pathExtension)")
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw SessionError.clipNameTaken(base)
        }
        try FileManager.default.moveItem(at: clip.url, to: destination)
        if let known = durations.removeValue(forKey: id) {
            durations[destination.lastPathComponent] = known
        }
        clipsReload()
        return destination.lastPathComponent
    }

    public func clipDelete(_ id: String) throws {
        guard let clip = clip(id) else { throw SessionError.clipMissing }
        try FileManager.default.trashItem(at: clip.url, resultingItemURL: nil)
        clipsReload()
    }

    /// A clip name made safe to use as a file name. Times keep their shape
    /// the way the system's own screenshots do it: "2:14 PM" becomes "2.14 PM".
    static func fileName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: ":", with: ".")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: "/\\").union(.newlines).union(.controlCharacters))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return cleaned.isEmpty ? "Clip" : cleaned
    }

    // MARK: - Files

    /// Reads channels.json. Returns false if it's missing or unreadable;
    /// entries it can't make sense of are skipped.
    @discardableResult
    private func loadChannels() -> Bool {
        guard let url = channelsURL, let entries: [Lenient<Channel>] = read(url) else { return false }
        var seen = Set<String>()
        channels = entries.compactMap(\.value).filter { seen.insert($0.id).inserted }
        channelsModified = modified(url)
        return true
    }

    @discardableResult
    private func loadPlaylists() -> Bool {
        guard let url = playlistsURL, let entries: [Lenient<Playlist>] = read(url) else { return false }
        let known = Set(channels.map(\.id))
        var seen = Set<String>()
        playlists = entries.compactMap(\.value).filter { seen.insert($0.id).inserted }.map {
            var playlist = $0
            playlist.retain(known)
            return playlist
        }
        playlistsModified = modified(url)
        return true
    }

    private func saveChannels() {
        guard let url = channelsURL else { return }
        write(channels, to: url)
        channelsModified = modified(url)
    }

    private func savePlaylists() {
        guard let url = playlistsURL else { return }
        write(playlists, to: url)
        playlistsModified = modified(url)
    }

    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log("couldn't read \(url.path(percentEncoded: false)): \(error)")
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(value).write(to: url, options: .atomic, withIntermediateDirectories: true)
        } catch {
            log("couldn't save \(url.path(percentEncoded: false)): \(error)")
        }
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("Watch: \(message)\n".utf8))
    }

    /// Decodes to nil rather than failing the whole file over one bad entry.
    private struct Lenient<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

extension Session {

    /// The session the app runs on: the library in Application Support and
    /// clips in the Movies folder.
    public static func disk() -> Session {
        Session(
            directory: URL.applicationSupportDirectory.appending(path: "Watch", directoryHint: .isDirectory),
            clipsDirectory: URL.moviesDirectory.appending(path: "Watch", directoryHint: .isDirectory))
    }

    /// A small in-memory library for previews.
    public static func preview() -> Session {
        let channels = Channel.defaults
        return Session(
            channels: channels,
            playlists: [
                Playlist(id: "tech", name: "Tech News", channels: channels.prefix(4).map(\.id)),
                Playlist(id: "news", name: "News", grid: .three, channels: channels.map(\.id)),
            ])
    }
}
