import Foundation
import Testing

@testable import WatchCore

@Suite struct ClipPlaylistTests {

    /// The shape of a YouTube live master: video-only variants that share separate audio
    /// groups, with two 240p variants differing only in which audio they pair with.
    static let youTubeMaster = """
        #EXTM3U
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:URI="https://manifest.example.com/api/itag/233/playlist/index.m3u8",TYPE=AUDIO,GROUP-ID="233",NAME="Default",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-MEDIA:URI="https://manifest.example.com/api/itag/234/playlist/index.m3u8",TYPE=AUDIO,GROUP-ID="234",NAME="Default",DEFAULT=YES,AUTOSELECT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=507418,CODECS="avc1.4D4015,mp4a.40.5",RESOLUTION=426x240,FRAME-RATE=30,VIDEO-RANGE=SDR,AUDIO="233",CLOSED-CAPTIONS=NONE
        https://manifest.example.com/api/itag/229-a233/playlist/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=591418,CODECS="avc1.4D4015,mp4a.40.2",RESOLUTION=426x240,FRAME-RATE=30,VIDEO-RANGE=SDR,AUDIO="234",CLOSED-CAPTIONS=NONE
        https://manifest.example.com/api/itag/229/playlist/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=962461,CODECS="avc1.4D401E,mp4a.40.2",RESOLUTION=640x360,FRAME-RATE=30,VIDEO-RANGE=SDR,AUDIO="234",CLOSED-CAPTIONS=NONE
        https://manifest.example.com/api/itag/230/playlist/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=269034,CODECS="avc1.42C00B,mp4a.40.5",RESOLUTION=256x144,FRAME-RATE=15,VIDEO-RANGE=SDR,AUDIO="233",CLOSED-CAPTIONS=NONE
        https://manifest.example.com/api/itag/269/playlist/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2922155,CODECS="avc1.4D4020,mp4a.40.2",RESOLUTION=1280x720,FRAME-RATE=60,VIDEO-RANGE=SDR,AUDIO="234",CLOSED-CAPTIONS=NONE
        https://manifest.example.com/api/itag/311/playlist/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=5552610,CODECS="avc1.64002A,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=60,VIDEO-RANGE=SDR,AUDIO="234",CLOSED-CAPTIONS=NONE
        https://manifest.example.com/api/itag/312/playlist/index.m3u8
        """

    /// A YouTube live media playlist around an ad break: a date at the top only, cue tags
    /// that mean nothing to us, short segments at the cue, and a discontinuity.
    static func youTubeMedia(itag: Int, firstSequence: Int = 409481, count: Int = 8) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:5",
            "#EXT-X-MEDIA-SEQUENCE:\(firstSequence)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:171",
            "#EXT-X-PROGRAM-DATE-TIME:2026-11-20T23:13:25.335+00:00",
        ]
        let durations = ["5.005", "5.005", "0.533866", "4.938266", "5.005", "5.005", "5.005", "5.005", "5.005", "5.005"]
        for index in 0..<count {
            if index == 3 {
                lines.append(#"#EXT-X-CUEPOINT:CONTEXT=Kg0K,DURATION=210.0,EVENT=START,IDENTIFIER="yt-broadcast:x-1",TYPE=AD"#)
            }
            if index == 5 {
                lines.append("#EXT-X-DISCONTINUITY")
                lines.append("#EXT-X-PROGRAM-DATE-TIME:2026-11-20T23:14:00.000+00:00")
            }
            lines.append("#EXTINF:\(durations[index]),")
            lines.append("https://rr2.example.com/videoplayback/itag/\(itag)/sq/\(firstSequence + index)/file/seg.ts")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static let base = URL(string: "https://cdn.example.com/live/abc/master.m3u8?token=1")!

    private func master(_ text: String, base: URL = ClipPlaylistTests.base) throws -> HLSMasterPlaylist {
        guard case .master(let playlist) = try HLSPlaylist.parse(text, baseURL: base) else {
            Issue.record("expected a master playlist")
            throw ClipError.invalidPlaylist("test")
        }
        return playlist
    }

    private func media(_ text: String, base: URL = ClipPlaylistTests.base) throws -> HLSMediaPlaylist {
        guard case .media(let playlist) = try HLSPlaylist.parse(text, baseURL: base) else {
            Issue.record("expected a media playlist")
            throw ClipError.invalidPlaylist("test")
        }
        return playlist
    }

    @Test func parsesYouTubeMaster() throws {
        let playlist = try master(Self.youTubeMaster)
        #expect(playlist.variants.count == 6)
        #expect(playlist.renditions.count == 2)

        let top = try #require(playlist.selectVariant(maxHeight: 1080))
        #expect(top.height == 1080)
        #expect(top.width == 1920)
        #expect(top.bandwidth == 5_552_610)
        #expect(top.frameRate == 60)
        #expect(top.codecs == ["avc1.64002A", "mp4a.40.2"])
        #expect(top.audioGroup == "234")
        #expect(top.url.absoluteString.contains("/itag/312/"))

        let audio = try #require(playlist.audioRendition(for: top))
        #expect(audio.url?.absoluteString == "https://manifest.example.com/api/itag/234/playlist/index.m3u8")
    }

    @Test func selectsVariantByHeight() throws {
        let playlist = try master(Self.youTubeMaster)
        #expect(playlist.selectVariant(maxHeight: 720)?.height == 720)
        #expect(playlist.selectVariant(maxHeight: 719)?.height == 360)
        #expect(playlist.selectVariant(maxHeight: 4000)?.height == 1080)
        // Two 240p variants: the higher bandwidth one carries AAC-LC rather than HE-AAC.
        #expect(playlist.selectVariant(maxHeight: 240)?.audioGroup == "234")
        // Nothing fits, so the smallest is used instead of failing.
        #expect(playlist.selectVariant(maxHeight: 100)?.height == 144)
    }

    @Test func prefersH264AndAvoidsAudioOnlyVariants() throws {
        let playlist = try master("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"
            audio/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=6000000,CODECS="hvc1.2.4.L123.B0,mp4a.40.2",RESOLUTION=1920x1080
            hevc/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=3000000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720
            h264/index.m3u8
            """)
        let chosen = try #require(playlist.selectVariant(maxHeight: 1080))
        #expect(chosen.url.absoluteString == "https://cdn.example.com/live/abc/h264/index.m3u8")
        #expect(playlist.audioRendition(for: chosen) == nil)

        // The same picture offered with AAC and, at a higher total bit rate, with Dolby sound.
        let dolby = try master("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",DEFAULT=YES,URI="a1/index.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="ac3",NAME="English",DEFAULT=YES,URI="a2/index.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=8200000,CODECS="avc1.64002a,ac-3",RESOLUTION=1920x1080,AUDIO="ac3"
            v9/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="avc1.64002a,mp4a.40.2",RESOLUTION=1920x1080,AUDIO="aac"
            v9/index.m3u8
            """)
        #expect(dolby.selectVariant(maxHeight: 1080)?.audioGroup == "aac")
    }

    @Test func parsesYouTubeMediaPlaylist() throws {
        let playlist = try media(Self.youTubeMedia(itag: 312))
        #expect(playlist.targetDuration == 5)
        #expect(playlist.hasEndList == false)
        #expect(playlist.segments.count == 8)
        #expect(playlist.segments.map(\.mediaSequence) == Array(409481...409488))
        #expect(playlist.segments.map(\.discontinuitySequence) == [171, 171, 171, 171, 171, 172, 172, 172])
        #expect(playlist.segments[2].duration == 0.533866)
        #expect(playlist.segments[0].url.absoluteString == "https://rr2.example.com/videoplayback/itag/312/sq/409481/file/seg.ts")
        #expect(playlist.segments.allSatisfy { $0.byteRange == nil && $0.map == nil && !$0.isEncrypted })

        // The date tag appears twice; segments in between carry it forward by duration.
        let start = try #require(HLSAttributes.date("2026-11-20T23:13:25.335+00:00"))
        let first = try #require(playlist.segments[0].programDateTime)
        let third = try #require(playlist.segments[2].programDateTime)
        let sixth = try #require(playlist.segments[5].programDateTime)
        let seventh = try #require(playlist.segments[6].programDateTime)
        #expect(first == start)
        #expect(abs(third.timeIntervalSince(start) - 10.01) < 0.0001)
        #expect(sixth == HLSAttributes.date("2026-11-20T23:14:00.000+00:00"))
        #expect(abs(seventh.timeIntervalSince(sixth) - 5.005) < 0.0001)
    }

    @Test func parsesMuxedPlaylistWithRelativeURIs() throws {
        let top = try master("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",FRAME-RATE=60.000
            chunked/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720,CODECS="avc1.4D401F,mp4a.40.2"
            /abs/720p/index.m3u8?sig=a,b
            """)
        #expect(top.variants.map(\.url.absoluteString) == [
            "https://cdn.example.com/live/abc/chunked/index.m3u8",
            "https://cdn.example.com/abs/720p/index.m3u8?sig=a,b",
        ])
        let variant = try #require(top.selectVariant(maxHeight: 1080))
        #expect(top.audioRendition(for: variant) == nil)

        let playlist = try media("""
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:7701
            #EXTINF:2.000,live
            1001.ts
            #EXTINF:2.000,
            ../other/1002.ts?x=1
            #EXTINF:1.500
            1003.ts
            """, base: variant.url)
        #expect(playlist.segments.map(\.url.absoluteString) == [
            "https://cdn.example.com/live/abc/chunked/1001.ts",
            "https://cdn.example.com/live/abc/other/1002.ts?x=1",
            "https://cdn.example.com/live/abc/chunked/1003.ts",
        ])
        #expect(playlist.segments.map(\.duration) == [2, 2, 1.5])
        #expect(playlist.segments.map(\.mediaSequence) == [7701, 7702, 7703])
        #expect(playlist.segments.allSatisfy { $0.programDateTime == nil && $0.discontinuitySequence == 0 })
    }

    @Test func parsesByteRangesAndInitSection() throws {
        let playlist = try media("""
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:4
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:1000@720
            main.mp4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:1500
            main.mp4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:500
            main.mp4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:300@9000
            other.mp4
            #EXTINF:4.0,
            whole.mp4
            #EXT-X-ENDLIST
            """)
        #expect(playlist.hasEndList)
        #expect(playlist.segments.map(\.byteRange) == [
            .init(offset: 720, length: 1000),
            .init(offset: 1720, length: 1500),
            .init(offset: 3220, length: 500),
            .init(offset: 9000, length: 300),
            nil,
        ])
        let map = try #require(playlist.segments[0].map)
        #expect(map.url.absoluteString == "https://cdn.example.com/live/abc/init.mp4")
        #expect(map.byteRange == .init(offset: 0, length: 720))
        #expect(playlist.segments.allSatisfy { $0.map == map })
    }

    @Test func tracksEncryptionKeys() throws {
        let playlist = try media("""
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXTINF:4.0,
            clear.ts
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/1",IV=0x00000000000000000000000000000001
            #EXTINF:4.0,
            locked.ts
            #EXT-X-KEY:METHOD=NONE
            #EXTINF:4.0,
            clear-again.ts
            """)
        #expect(playlist.segments.map(\.isEncrypted) == [false, true, false])
        #expect(throws: ClipError.encrypted) {
            try LiveSnapshot(video: playlist, audio: nil, variant: nil, last: 120, capturedAt: .now)
        }
    }

    @Test func rejectsTextThatIsNotAPlaylist() {
        #expect(throws: ClipError.self) {
            try HLSPlaylist.parse("<html>Not found</html>", baseURL: Self.base)
        }
    }

    @Test func parsesAttributeLists() {
        let attributes = HLSAttributes.parse(#"BANDWIDTH=5552610,CODECS="avc1.64002A,mp4a.40.2",RESOLUTION=1920x1080, NAME="a=b" ,EMPTY="""#)
        #expect(attributes["BANDWIDTH"] == "5552610")
        #expect(attributes["CODECS"] == "avc1.64002A,mp4a.40.2")
        #expect(attributes["RESOLUTION"] == "1920x1080")
        #expect(attributes["NAME"] == "a=b ")
        #expect(attributes["EMPTY"] == "")
        #expect(HLSAttributes.date("2026-11-20T23:13:25Z") != nil)
        #expect(HLSAttributes.date("2026-11-20T23:13:25.335Z") != nil)
        #expect(HLSAttributes.date("2026-11-20T15:13:25.335-08:00") == HLSAttributes.date("2026-11-20T23:13:25.335+00:00"))
    }

    // MARK: - Snapshot selection

    /// Segment positions come out of floating-point sums, so compare them with a tolerance.
    private func close(_ lhs: [TimeInterval]?, _ rhs: [TimeInterval]) -> Bool {
        guard let lhs, lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { abs($0 - $1) < 1e-6 }
    }

    @Test func snapshotTakesTheTrailingSegments() throws {
        let video = try media(Self.youTubeMedia(itag: 312))
        let audio = try media(Self.youTubeMedia(itag: 234))
        let snapshot = try LiveSnapshot(video: video, audio: audio, variant: nil, last: 12, capturedAt: .now)

        // Three 5.005 s segments are needed to cover 12 s.
        #expect(snapshot.video.count == 3)
        #expect(abs(snapshot.duration - 15.015) < 0.0001)
        #expect(close(snapshot.video.map(\.start), [0, 5.005, 10.01]))
        #expect(snapshot.video.last?.url == video.segments.last?.url)
        #expect(snapshot.audio?.count == 3)
        #expect(close(snapshot.audio?.map(\.start), snapshot.video.map(\.start)))
        #expect(snapshot.audio?.last?.url == audio.segments.last?.url)
    }

    @Test func snapshotTakesWhatAShortPlaylistHas() throws {
        let video = try media(Self.youTubeMedia(itag: 312))
        let snapshot = try LiveSnapshot(video: video, audio: nil, variant: nil, last: 120, capturedAt: .now)
        #expect(snapshot.video.count == 8)
        #expect(snapshot.audio == nil)
        #expect(abs(snapshot.duration - 35.502132) < 0.0001)
        #expect(snapshot.video.map(\.discontinuitySequence) == [171, 171, 171, 171, 171, 172, 172, 172])
    }

    @Test func snapshotAlignsRenditionsFetchedAtDifferentLiveEdges() throws {
        // The audio playlist was fetched a moment later and already lists one more segment;
        // the video playlist still lists one older segment that audio has dropped.
        let video = try media(Self.youTubeMedia(itag: 312, firstSequence: 409481, count: 8))
        let audio = try media(Self.youTubeMedia(itag: 234, firstSequence: 409481, count: 9))
        let ahead = try LiveSnapshot(video: video, audio: audio, variant: nil, last: 10, capturedAt: .now)
        #expect(ahead.video.map { $0.url.pathComponents[5] } == ["409487", "409488"])
        #expect(ahead.audio?.map { $0.url.pathComponents[5] } == ["409487", "409488"])
        #expect(close(ahead.audio?.map(\.start), [0, 5.005]))

        // The other way round: video is ahead, so its newest segment has no audio yet and
        // is left out.
        let behind = try LiveSnapshot(video: audio, audio: video, variant: nil, last: 10, capturedAt: .now)
        #expect(behind.video.map { $0.url.pathComponents[5] } == ["409487", "409488"])
        #expect(behind.audio?.map { $0.url.pathComponents[5] } == ["409487", "409488"])
        #expect(abs(behind.duration - 10.01) < 0.0001)
    }

    @Test func snapshotAlignsBySequenceNumberWithoutDates() throws {
        func playlist(first: Int, count: Int, name: String) throws -> HLSMediaPlaylist {
            var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:4", "#EXT-X-MEDIA-SEQUENCE:\(first)"]
            for index in 0..<count {
                lines += ["#EXTINF:4.0,", "\(name)\(first + index).ts"]
            }
            return try media(lines.joined(separator: "\n"))
        }
        let video = try playlist(first: 100, count: 10, name: "v")
        let audio = try playlist(first: 103, count: 9, name: "a")
        let snapshot = try LiveSnapshot(video: video, audio: audio, variant: nil, last: 8, capturedAt: .now)
        #expect(snapshot.video.map(\.url.lastPathComponent) == ["v108.ts", "v109.ts"])
        #expect(snapshot.audio?.map(\.url.lastPathComponent) == ["a108.ts", "a109.ts"])
    }

    @Test func snapshotAlignsDifferentlyCutRenditionsByDate() throws {
        // Video in 6 s segments, audio in 4 s segments with unrelated sequence numbers; only
        // the dates say how they line up. Audio starts 2 s before the video playlist does.
        func playlist(first: Int, date: String, duration: Double, count: Int, name: String) throws -> HLSMediaPlaylist {
            var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:6", "#EXT-X-MEDIA-SEQUENCE:\(first)", "#EXT-X-PROGRAM-DATE-TIME:\(date)"]
            for index in 0..<count {
                lines += ["#EXTINF:\(duration),", "\(name)\(index).ts"]
            }
            return try media(lines.joined(separator: "\n"))
        }
        let video = try playlist(first: 50, date: "2026-01-01T00:00:10Z", duration: 6, count: 5, name: "v")
        let audio = try playlist(first: 9000, date: "2026-01-01T00:00:08Z", duration: 4, count: 8, name: "a")
        #expect(LiveSnapshot.audioShift(video: video, audio: audio) == -2)

        let snapshot = try LiveSnapshot(video: video, audio: audio, variant: nil, last: 12, capturedAt: .now)
        // Video covers 28...40 s of wall clock; audio segments a5 (28...32), a6, a7 overlap it.
        #expect(snapshot.video.map(\.url.lastPathComponent) == ["v3.ts", "v4.ts"])
        #expect(snapshot.audio?.map(\.url.lastPathComponent) == ["a5.ts", "a6.ts", "a7.ts"])
        #expect(close(snapshot.audio?.map(\.start), [0, 4, 8]))
        #expect(snapshot.duration == 12)
    }

    // MARK: - Playback playlists

    @Test func playbackPlaylistsDescribeAFinishedStream() throws {
        let video = try media(Self.youTubeMedia(itag: 312))
        let audio = try media(Self.youTubeMedia(itag: 234))
        let variant = LiveSnapshot.VariantInfo(bandwidth: 5_552_610, codecs: ["avc1.64002A", "mp4a.40.2"], width: 1920, height: 1080, frameRate: 60)
        let snapshot = try LiveSnapshot(video: video, audio: audio, variant: variant, last: 22, capturedAt: .now)
        #expect(snapshot.videoSize == CGSize(width: 1920, height: 1080))
        let playlists = snapshot.playbackPlaylists()

        #expect(playlists.master.contains(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Default",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8""#))
        #expect(playlists.master.contains(#"#EXT-X-STREAM-INF:BANDWIDTH=5552610,CODECS="avc1.64002A,mp4a.40.2",RESOLUTION=1920x1080,FRAME-RATE=60.000,AUDIO="audio""#))
        #expect(playlists.master.hasSuffix("video.m3u8\n"))

        // Parsing our own output is the simplest way to check it is well formed.
        let replayed = try media(playlists.video)
        #expect(replayed.hasEndList)
        #expect(replayed.targetDuration == 6)
        #expect(replayed.segments.map(\.url) == snapshot.video.map(\.url))
        #expect(replayed.segments.map(\.duration) == snapshot.video.map(\.duration))
        #expect(replayed.segments.map(\.discontinuitySequence) == [0, 0, 1, 1, 1])
        #expect(playlists.video.contains("#EXT-X-PLAYLIST-TYPE:VOD"))

        let replayedAudio = try media(try #require(playlists.audio))
        #expect(replayedAudio.segments.map(\.url) == snapshot.audio?.map(\.url))
        #expect(replayedAudio.segments.map(\.discontinuitySequence) == [0, 0, 1, 1, 1])
    }

    @Test func playbackPlaylistsKeepByteRangesAndInitSections() throws {
        let source = try media("""
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:1000@720
            main.mp4
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:1500
            main.mp4
            """)
        let snapshot = try LiveSnapshot(video: source, audio: nil, variant: nil, last: 60, capturedAt: .now)
        let playlists = snapshot.playbackPlaylists()
        #expect(playlists.audio == nil)
        #expect(!playlists.master.contains("EXT-X-MEDIA"))
        #expect(playlists.master.contains("#EXT-X-STREAM-INF:BANDWIDTH=50000000\nvideo.m3u8"))

        let replayed = try media(playlists.video)
        #expect(replayed.segments.map(\.byteRange) == source.segments.map(\.byteRange))
        #expect(replayed.segments.map(\.map) == source.segments.map(\.map))
        #expect(playlists.video.components(separatedBy: "#EXT-X-MAP").count == 2)
    }
}
