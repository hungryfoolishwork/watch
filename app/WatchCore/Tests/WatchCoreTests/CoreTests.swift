import Foundation
import Testing

@testable import WatchProtocol
@testable import WatchCore

@Suite struct ChannelTests {

    @Test func parsesWhatYouWouldPaste() {
        #expect(Channel(input: "NASA")?.id == "NASA")
        #expect(Channel(input: " @NASA ")?.id == "NASA")
        #expect(Channel(input: "https://www.youtube.com/@NASA/live")?.id == "NASA")
        #expect(Channel(input: "https://www.youtube.com/channel/UCLA_DiR1FfKNvjuUpBHmylQ")?.id == "UCLA_DiR1FfKNvjuUpBHmylQ")
        #expect(Channel(input: "https://rumble.com/c/RTNews")?.id == "rumble:RTNews")
        #expect(Channel(input: "Kick:XQC")?.id == "kick:xqc")
        #expect(Channel(input: "https://kick.com/xqc")?.id == "kick:xqc")
    }

    @Test func rejectsWhatIsNotAChannel() {
        #expect(Channel(input: "") == nil)
        #expect(Channel(input: "two words") == nil)
        #expect(Channel(input: "https://www.youtube.com/watch?v=abc") == nil)
        #expect(Channel(input: "https://kick.com/xqc/videos/1") == nil)
        #expect(Channel(input: "https://example.com/@NASA") == nil)
    }

    @Test func decodesStringsAndObjects() throws {
        let json = #"["@NASA", {"id": "rumble:RTNews", "name": "RT"}]"#
        let channels = try JSONDecoder().decode([Channel].self, from: Data(json.utf8))
        #expect(channels == [Channel(id: "NASA"), Channel(id: "rumble:RTNews", name: "RT")])
        #expect(channels[1].displayName == "RT")
        #expect(channels[0].displayName == "@NASA")
    }
}

@Suite struct PlaylistTests {

    @Test func newChannelsFillTheGridThenWait() {
        let playlist = Playlist(name: "News", channels: ["a", "b", "c", "d", "e", "f"])
        #expect(playlist.visible == ["a", "b", "c", "d"])
        #expect(playlist.channels.count == 6)
        #expect(playlist.position(of: "e") == nil)
    }

    @Test func growingTheGridFillsItAndShrinkingKeepsPlaces() {
        var playlist = Playlist(name: "News", channels: ["a", "b", "c", "d", "e", "f"])
        playlist.resize(.three)
        #expect(playlist.visible == ["a", "b", "c", "d", "e", "f", nil, nil, nil])
        playlist.resize(.two)
        #expect(playlist.visible == ["a", "b", "c", "d"])
        #expect(playlist.tiles[4] == "e")
    }

    @Test func placingAChannelThatIsShowingSwaps() {
        var playlist = Playlist(name: "News", channels: ["a", "b", "c", "d", "e"])
        playlist.place("d", at: 0)
        #expect(playlist.visible == ["d", "b", "c", "a"])
        playlist.place("e", at: 1)
        #expect(playlist.visible == ["d", "e", "c", "a"])
        #expect(playlist.position(of: "b") == nil)
        #expect(playlist.channels.contains("b"))
    }

    @Test func placingANewChannelAddsIt() {
        var playlist = Playlist(name: "News", channels: ["a"])
        playlist.place("z", at: 3)
        #expect(playlist.channels == ["a", "z"])
        #expect(playlist.visible == ["a", nil, nil, "z"])
    }

    @Test func removingAChannelBringsInOneThatWasWaiting() {
        var playlist = Playlist(name: "News", channels: ["a", "b", "c", "d", "e"])
        playlist.remove("b")
        #expect(playlist.visible == ["a", "e", "c", "d"])
        #expect(playlist.channels == ["a", "c", "d", "e"])
    }

    @Test func decodingRepairsTiles() throws {
        let json = #"{"name": "News", "grid": 2, "channels": ["a", "b", "c"], "tiles": ["b", "b", "nope"]}"#
        let playlist = try JSONDecoder().decode(Playlist.self, from: Data(json.utf8))
        #expect(playlist.tiles.count == Playlist.positions)
        #expect(playlist.visible == ["b", "a", "c", nil])
    }

    @Test func roundTrips() throws {
        var playlist = Playlist(name: "News", grid: .three, channels: ["a", "b", "c"])
        playlist.swap(0, 8)
        let data = try JSONEncoder().encode(playlist)
        #expect(try JSONDecoder().decode(Playlist.self, from: data) == playlist)
    }
}

@MainActor
@Suite struct SessionTests {

    private func scratch() -> URL {
        URL.temporaryDirectory.appending(path: "WatchTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func firstLaunchSeedsAndSaves() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }

        let session = Session(directory: home, clipsDirectory: home.appending(path: "Clips"))
        #expect(session.channels == Channel.defaults)
        #expect(session.playlists.count == 1)
        #expect(session.playlists[0].channels.count == Channel.defaults.count)

        let again = Session(directory: home, clipsDirectory: home.appending(path: "Clips"))
        #expect(again.channels == session.channels)
        #expect(again.playlists == session.playlists)
    }

    @Test func deletingAChannelTakesItOutOfPlaylists() throws {
        let session = Session.preview()
        let gone = session.playlists[0].visible[0]!
        session.channelDelete(gone)
        #expect(session.channel(gone) == nil)
        #expect(session.playlists.allSatisfy { !$0.channels.contains(gone) })
    }

    @Test func addingTheSameChannelTwiceThrows() throws {
        let session = Session.preview()
        try session.channelAdd(Channel(id: "NASA"))
        #expect(throws: SessionError.self) { try session.channelAdd(Channel(id: "NASA")) }
    }

    @Test func readsHandEditedFiles() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(#"["@NASA", 7, {"id": "kick:xqc"}]"#.utf8).write(to: home.appending(path: "channels.json"))
        try Data(#"[{"name": "Space", "channels": ["NASA", "missing"]}]"#.utf8).write(to: home.appending(path: "playlists.json"))

        let session = Session(directory: home, clipsDirectory: home.appending(path: "Clips"))
        #expect(session.channels.map(\.id) == ["NASA", "kick:xqc"])
        #expect(session.playlists[0].channels == ["NASA"])
        #expect(session.playlists[0].visible == ["NASA", nil, nil, nil])
    }

    @Test func clipsAreTheFilesInTheFolder() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let session = Session(directory: home, clipsDirectory: home.appending(path: "Clips"))
        #expect(session.clips.isEmpty)

        let first = try session.clipReserve(name: "TBPN, 2:14 PM")
        #expect(first.lastPathComponent == "TBPN, 2.14 PM.mp4")
        try Data().write(to: first)
        let second = try session.clipReserve(name: "TBPN, 2:14 PM")
        #expect(second.lastPathComponent == "TBPN, 2.14 PM 2.mp4")
        try Data().write(to: second)
        try Data().write(to: session.clipsDirectory.appending(path: "notes.txt"))

        session.clipsReload()
        #expect(Set(session.clips.map(\.name)) == ["TBPN, 2.14 PM", "TBPN, 2.14 PM 2"])

        #expect(try session.clipRename("TBPN, 2.14 PM 2.mp4", name: "Interview") == "Interview.mp4")
        #expect(session.clip("Interview.mp4") != nil)
        #expect(Session.fileName("a/b\u{202F}PM: c.") == "a-b PM. c")
        #expect(throws: SessionError.self) { try session.clipRename("Interview.mp4", name: "TBPN, 2.14 PM") }
    }

    @Test func shiftMatchesSwiftUIMove() {
        var items = ["a", "b", "c", "d"]
        items.shift(fromOffsets: [0], toOffset: 3)
        #expect(items == ["b", "c", "a", "d"])
        items.shift(fromOffsets: [3], toOffset: 0)
        #expect(items == ["d", "b", "c", "a"])
    }
}

@Suite struct StreamResolverTests {

    @Test func errorLinesLoseTheirPrefix() {
        #expect(StreamResolver.message(fromErrorLine: "ERROR: [youtube:tab] @PBSNewsHour: The channel is not currently live")
                == "The channel is not currently live")
        #expect(StreamResolver.message(fromErrorLine: "ERROR: [youtube] abc123: Sign in to confirm your age")
                == "Sign in to confirm your age")
        #expect(StreamResolver.message(fromErrorLine: "ERROR: Unable to download webpage: timed out")
                == "Unable to download webpage: timed out")
        #expect(StreamResolver.message(fromErrorLine: "") == "")
    }
}
