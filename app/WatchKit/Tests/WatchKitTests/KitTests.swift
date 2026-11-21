import Foundation
import Testing

@testable import WatchKit

@Suite struct RouteTests {

    @Test func linksRoundTrip() {
        let routes: [Route] = [
            .playlist("5E0C"),
            .channel("rumble:RTNews"),
            .clip("TBPN, 2-14 PM.mp4"),
            .clipCreate("SkyNews"),
            .pip("kick:tbpn"),
            .channelAdd,
            .settings,
        ]
        for route in routes {
            #expect(Route(url: route.url) == route)
        }
    }

    @Test func rejectsLinksThatNameNothing() {
        #expect(Route(url: URL(string: "watch://playlist")!) == nil)
        #expect(Route(url: URL(string: "watch://nonsense/1")!) == nil)
        #expect(Route(url: URL(string: "https://channel/SkyNews")!) == nil)
    }
}

@Suite struct TimeTests {

    @Test func lengthsAndClocks() {
        #expect(TimeInterval(30).clipLength == "30 sec")
        #expect(TimeInterval(59.6).clipLength == "1 min")
        #expect(TimeInterval(170).clipLength == "3 min")
        #expect(TimeInterval(120).clock == "2:00")
        #expect(TimeInterval(30).clock == "0:30")
    }
}

@MainActor
@Suite struct AppStateTests {

    /// The preview library: "Tech News" (2×2, four channels) and "News"
    /// (3×3, nine), with no streams actually started.
    private func state() -> AppState {
        let state = AppState.preview
        state.select(.playlist("tech"))
        return state
    }

    @Test func showsThePlaylistsVisibleTiles() {
        let state = state()
        #expect(state.showing.count == 4)
        state.select(.playlist("news"))
        #expect(state.showing.count == 9)
        state.select(.channel("CNN"))
        #expect(state.showing == ["CNN"])
    }

    @Test func oneChannelHasTheSoundAtATime() {
        let state = state()
        let tiles = state.showing
        state.listen(tiles[1])
        #expect(state.listening == tiles[1])
        state.listenToggle(tiles[1])
        #expect(state.listening == nil)
        state.listen(tile: 3)
        #expect(state.listening == tiles[3])
        state.listen(tile: 7)
        #expect(state.listening == tiles[3])
    }

    @Test func zoomingGivesTheTileTheSoundAndTogglesBack() {
        let state = state()
        let tiles = state.showing
        state.listen(tiles[2])
        state.zoomToggle()
        #expect(state.zoomed == tiles[2])
        // Listening to a hidden tile brings it forward instead.
        state.listen(tiles[0])
        #expect(state.zoomed == tiles[0])
        state.zoomToggle()
        #expect(state.zoomed == nil)
        state.zoomToggle(tiles[1])
        #expect(state.zoomed == tiles[1])
        #expect(state.listening == tiles[1])
        state.zoomToggle(tiles[1])
        #expect(state.zoomed == nil)
    }

    @Test func leavingAPlaylistDropsItsZoomAndSound() {
        let state = state()
        state.zoom(state.showing[1])
        state.select(.playlist("news"))
        #expect(state.zoomed == nil)
        #expect(state.listening == nil || state.showing.contains(state.listening!))
    }

    @Test func pictureInPictureKeepsPlayingAfterItsTileLeaves() {
        let state = state()
        let tiles = state.showing
        state.listen(tiles[1])
        state.pipBegan(tiles[1])

        state.select(.channel(tiles[0]))
        #expect(state.pip == tiles[1])
        #expect(state.listening == tiles[1])

        // It trades the sound like any tile, on screen or not.
        state.listen(tiles[0])
        #expect(state.listening == tiles[0])
        state.listen(tiles[1])
        #expect(state.listening == tiles[1])

        state.pipEnded(tiles[1])
        #expect(state.pip == nil)
        #expect(state.listening == nil)
    }

    @Test func pictureInPictureReturnsToWhereItLeftFrom() {
        let state = state()
        let tiles = state.showing
        state.pipBegan(tiles[1])
        state.select(.channel(tiles[0]))
        state.pipRestore(tiles[1])
        #expect(state.router.selection == .playlist("tech"))

        // With that playlist gone, the channel is shown on its own.
        state.select(.channel(tiles[0]))
        state.playlistDelete("tech")
        state.pipRestore(tiles[1])
        #expect(state.router.selection == .channel(tiles[1]))
    }

    @Test func pictureInPictureReturnsToATileThatIsNotHidden() {
        let state = state()
        let tiles = state.showing
        state.pipBegan(tiles[1])
        state.zoom(tiles[0])
        state.pipRestore(tiles[1])
        #expect(state.zoomed == nil)
        #expect(state.router.selection == .playlist("tech"))
    }

    @Test func listeningToPictureInPictureLeavesTheZoomAlone() {
        let state = state()
        state.select(.playlist("news"))
        let away = state.showing[6]
        state.pipBegan(away)
        state.select(.playlist("tech"))
        #expect(!state.showing.contains(away))

        state.zoom(state.showing[0])
        state.listen(away)
        #expect(state.zoomed == state.showing[0])
        #expect(state.listening == away)
    }

    @Test func deletingAChannelEndsItsPictureInPicture() {
        let state = state()
        let channel = state.showing[1]
        state.pipBegan(channel)
        state.channelDelete(channel)
        #expect(state.pip == nil)
    }

    @Test func swappingAndPlacingTiles() {
        let state = state()
        let tiles = state.showing
        state.playlistSwap(0, 3)
        #expect(state.showing == [tiles[3], tiles[1], tiles[2], tiles[0]])
        // A channel from outside the playlist joins it and takes the tile.
        let outside = state.session.channels.first { !tiles.contains($0.id) }!.id
        state.playlistPlace(outside, at: 1)
        #expect(state.showing[1] == outside)
        #expect(state.playlist?.channels.contains(outside) == true)
        #expect(state.playlist?.channels.contains(tiles[1]) == true)
    }

    @Test func removingTheSelectedThingMovesTheSelection() {
        let state = state()
        state.playlistDelete("tech")
        #expect(state.router.selection == .playlist("news"))
        state.select(.channel("CNN"))
        state.channelDelete("CNN")
        #expect(state.router.selection == .playlist("news"))
        #expect(!state.showing.contains("CNN"))
    }

    @Test func addingAChannelPutsItInThePlaylistOnScreen() throws {
        let state = state()
        try state.channelAdd(input: "https://www.youtube.com/@NASA", name: "NASA")
        #expect(state.session.channel("NASA")?.displayName == "NASA")
        #expect(state.playlist?.channels.contains("NASA") == true)
        #expect(throws: (any Error).self) { try state.channelAdd(input: "@NASA", name: "") }
        #expect(throws: (any Error).self) { try state.channelAdd(input: "not a channel", name: "") }
    }

    @Test func renamingAPlaylist() {
        let state = state()
        state.renameBegin(.playlist("tech"))
        #expect(state.renameText == "Tech News")
        state.renameText = "  Tech  "
        state.renameCommit()
        #expect(state.session.playlist("tech")?.name == "Tech")
        #expect(state.renaming == nil)
    }
}
