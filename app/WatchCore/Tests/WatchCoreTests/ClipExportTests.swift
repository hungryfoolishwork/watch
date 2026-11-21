import AVFoundation
import CoreMedia
import Foundation
import Testing

@testable import WatchCore

/// Demuxing and export against the small HLS fixtures in `Fixtures/` (see `make-fixtures.sh`
/// there for how they were made). Each fixture is six seconds of 160x90 test video at 15 fps
/// with a keyframe every second, and a 440 Hz tone that jumps to 1760 Hz for 40 ms at every
/// whole second of the video's timeline. The beeps are what the export tests use to check
/// that sound still lines up with picture.
@Suite struct ClipExportTests {

    // MARK: - Demuxing

    @Test func demuxesMuxedTransportStream() throws {
        var unwrapper = TimestampUnwrapper()
        let segment = try SegmentDemuxer.demux(try Fixture.data("muxed/seg0.ts"), unwrapper: &unwrapper)

        #expect(segment.video.count == 30)
        #expect(segment.video.indices.filter { segment.video[$0].isKeyframe } == [0, 15])
        // Decode times step evenly; presentation times are the same set reordered (B-frames).
        let decodeSteps = zip(segment.video, segment.video.dropFirst()).map { $1.dts - $0.dts }
        #expect(decodeSteps.allSatisfy { $0 == 6000 })
        #expect(segment.video.contains { $0.pts != $0.dts })
        #expect(segment.video.allSatisfy { $0.pts >= $0.dts })
        let presentation = segment.video.map(\.pts).sorted()
        #expect(zip(presentation, presentation.dropFirst()).allSatisfy { $1 - $0 == 6000 })

        let sets = try #require(segment.video[0].parameterSets)
        let format = try sets.formatDescription()
        #expect(format.mediaSubType == .h264)
        #expect(format.dimensions.width == 160)
        #expect(format.dimensions.height == 90)
        // AVCC framing: the first four bytes are the length of the first NAL unit.
        let first = segment.video[0].data
        let length = first.prefix(4).reduce(0) { $0 << 8 | Int($1) }
        #expect(length > 0 && length + 4 <= first.count)

        #expect(segment.audio.count >= 80 && segment.audio.count <= 90)
        #expect(segment.audio.allSatisfy { $0.config == AACConfig(objectType: 2, sampleRate: 44100, channelConfiguration: 2) })
        // 1024 samples at 44.1 kHz is 2089.8 ticks of the 90 kHz clock.
        let audioSteps = zip(segment.audio, segment.audio.dropFirst()).map { $1.pts - $0.pts }
        #expect(audioSteps.allSatisfy { $0 == 2089 || $0 == 2090 })
        // Audio and video start within a frame of each other.
        #expect(abs(segment.audio[0].pts - presentation[0]) < 3000)
    }

    @Test func unwrapsTimestampsAcrossThe33BitWrap() throws {
        // The fixture's clock starts about 2.3 s short of 2^33 ticks, so raw timestamps drop
        // from the top of the range to near zero partway through the second segment.
        var unwrapper = TimestampUnwrapper()
        var video: [VideoFrame] = []
        var audio: [AudioFrame] = []
        for name in ["muxed/seg0.ts", "muxed/seg1.ts", "muxed/seg2.ts"] {
            let segment = try SegmentDemuxer.demux(try Fixture.data(name), unwrapper: &unwrapper)
            video += segment.video
            audio += segment.audio
        }
        #expect(video.count == 90)
        #expect(zip(video, video.dropFirst()).allSatisfy { $1.dts - $0.dts == 6000 })
        #expect(zip(audio, audio.dropFirst()).allSatisfy { (2089...2090).contains($1.pts - $0.pts) })
        let wrap: Int64 = 1 << 33
        #expect(video.first.map { $0.dts < wrap } == true)
        #expect(video.last.map { $0.dts > wrap } == true)
    }

    @Test func timestampUnwrapperFollowsTheNearestInterpretation() {
        var unwrapper = TimestampUnwrapper()
        let top: Int64 = (1 << 33) - 1
        #expect(unwrapper.unwrap(top - 100) == top - 100)
        #expect(unwrapper.unwrap(50) == top + 51)
        // A step back across the wrap point stays a small step back.
        #expect(unwrapper.unwrap(top - 10) == top - 10)
        #expect(unwrapper.unwrap(3000) == top + 3001)
        #expect(unwrapper.unwrap(2000) == top + 2001)
    }

    @Test func demuxesPackedAudioWithItsTimestampTag() throws {
        let data = try Fixture.data("split/audio1.aac")
        let tag = try #require(ID3Tag([UInt8](data), at: 0))
        #expect(tag.length == 73)
        let stamp = try #require(tag.transportStreamTimestamp)

        var unwrapper = TimestampUnwrapper()
        let segment = try SegmentDemuxer.demux(data, unwrapper: &unwrapper)
        #expect(segment.video.isEmpty)
        #expect(segment.audio.count == 86)
        #expect(segment.audio[0].pts == stamp)
        #expect(segment.audio[1].pts == stamp + 2090)
        #expect(segment.audio[85].pts == stamp + Int64((85.0 * 1024 * 90000 / 44100).rounded()))
        #expect(segment.audio.allSatisfy { $0.config.sampleRate == 44100 && $0.config.channelConfiguration == 2 && !$0.data.isEmpty })

        // The audio rendition runs on the video's clock: this segment starts within one
        // audio frame of the matching video segment.
        var videoUnwrapper = TimestampUnwrapper()
        let video = try SegmentDemuxer.demux(try Fixture.data("split/video1.ts"), unwrapper: &videoUnwrapper)
        #expect(video.audio.isEmpty)
        let videoStart = try #require(video.video.map(\.pts).min())
        #expect(abs(stamp - videoStart) < 2100)
    }

    @Test func readsVersion3TimestampTags() throws {
        // YouTube writes ID3v2.3, where frame sizes are plain integers rather than synchsafe.
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
        let value: [UInt8] = [0, 0, 0, 0, 0xDD, 0x09, 0x19, 0x24]
        let frame: [UInt8] = Array("PRIV".utf8) + [0, 0, 0, UInt8(owner.count + value.count), 0, 0] + owner + value
        let bytes: [UInt8] = Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, UInt8(frame.count)] + frame
        let tag = try #require(ID3Tag(bytes, at: 0))
        #expect(tag.length == bytes.count)
        #expect(tag.transportStreamTimestamp == 0xDD09_1924)
    }

    @Test func adtsParserHandlesFramesSplitAcrossPackets() throws {
        let data = try Fixture.data("split/audio0.aac")
        let adts = data.dropFirst(73)

        var whole = ADTSParser()
        whole.append(Data(adts), pts: 1_000_000)

        // The same bytes in 300-byte pieces, as PES packets would deliver them, each piece
        // stamped with the time of the first frame that starts inside it.
        var pieces = ADTSParser()
        var offset = 0
        var frameStarts: [Int] = []
        var cursor = 0
        for frame in whole.frames {
            frameStarts.append(cursor)
            cursor += frame.data.count + 7
        }
        while offset < adts.count {
            let end = min(offset + 300, adts.count)
            let firstFrame = frameStarts.firstIndex { $0 >= offset && $0 < end }
            let stamp = firstFrame.map { whole.frames[$0].pts }
            pieces.append(Data(adts.dropFirst(offset).prefix(end - offset)), pts: stamp)
            offset = end
        }

        #expect(whole.frames.count == 87)
        #expect(pieces.frames.count == whole.frames.count)
        #expect(pieces.frames.map(\.data) == whole.frames.map(\.data))
        #expect(zip(pieces.frames, whole.frames).allSatisfy { abs($0.pts - $1.pts) <= 1 })
    }

    @Test func convertsAnnexBToLengthPrefixedSamples() {
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x0C]
        let pps: [UInt8] = [0x68, 0xE8, 0x43]
        let idr: [UInt8] = [0x65, 0x88, 0x00, 0x00, 0x03, 0x00, 0x01]
        // Four-byte and three-byte start codes, an access unit delimiter, and trailing zeros.
        let stream: [UInt8] = [0, 0, 0, 1, 0x09, 0xF0] + [0, 0, 0, 1] + sps + [0, 0, 1] + pps + [0, 0, 1] + idr + [0, 0, 0]
        var assembler = H264Assembler()
        assembler.append(Data(stream), pts: 9000, dts: 3000)
        let frames = assembler.frames()
        #expect(frames.count == 1)
        #expect(frames.first?.pts == 9000)
        #expect(frames.first?.dts == 3000)
        #expect(frames.first?.isKeyframe == true)
        #expect(frames.first?.parameterSets == H264ParameterSets(sps: [Data(sps)], pps: [Data(pps)]))
        #expect(frames.first?.data == Data([0, 0, 0, UInt8(idr.count)] + idr))

        var bare = H264Assembler()
        bare.append(Data([0, 0, 1, 0x41, 0x9A, 0x01]), pts: 6000, dts: nil)
        let slice = bare.frames()
        #expect(slice.count == 1)
        #expect(slice.first?.dts == 6000)
        #expect(slice.first?.isKeyframe == false)
        #expect(slice.first?.parameterSets == nil)
        #expect(slice.first?.data == Data([0, 0, 0, 3, 0x41, 0x9A, 0x01]))
    }

    @Test func assemblesPicturesFromPacketsThatDoNotLineUpWithThem() {
        func annexB(_ nals: [[UInt8]]) -> [UInt8] { nals.flatMap { [0, 0, 1] + $0 } }
        func avcc(_ nals: [[UInt8]]) -> Data { Data(nals.flatMap { [0, 0, 0, UInt8($0.count)] + $0 }) }
        let delimiter: [UInt8] = [0x09, 0xF0]
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x0C]
        let pps: [UInt8] = [0x68, 0xE8, 0x43]
        let idr: [UInt8] = [0x65, 0x11, 0x12, 0x13], idrTail: [UInt8] = [0x65, 0x14]
        let b: [UInt8] = [0x01, 0x21, 0x22, 0x23, 0x24, 0x25], bTail: [UInt8] = [0x01, 0x26]
        let p: [UInt8] = [0x41, 0x31], pTail: [UInt8] = [0x41, 0x32]
        let extra: [UInt8] = [0x41, 0x41]

        // Packets cut the way Apple's older segmenter cuts them. Each starts with the end
        // of the previous picture, one cut falls in the middle of a NAL unit, one packet
        // holds nothing but a picture's end while carrying the next picture's timestamps,
        // and one holds the start of two pictures but has only one timestamp to give.
        var ragged = H264Assembler()
        ragged.append(Data(annexB([delimiter, sps, pps, idr])), pts: 9000, dts: 3000)
        ragged.append(Data(annexB([idrTail, delimiter]) + annexB([b]).prefix(5)), pts: 6000, dts: 6000)
        ragged.append(Data(annexB([b]).dropFirst(5) + annexB([bTail])), pts: 15000, dts: 9000)
        ragged.append(Data(annexB([delimiter, p])), pts: 15000, dts: 9000)
        ragged.append(Data(annexB([pTail, delimiter, extra])), pts: nil, dts: nil)
        let frames = ragged.frames()
        #expect(frames.map(\.dts) == [3000, 6000, 9000, 12000])
        #expect(frames.map(\.pts) == [9000, 6000, 15000, 12000])
        #expect(frames.map(\.data) == [avcc([idr, idrTail]), avcc([b, bTail]), avcc([p, pTail]), avcc([extra])])
        #expect(frames.map(\.isKeyframe) == [true, false, false, false])
        #expect(frames[0].parameterSets == H264ParameterSets(sps: [Data(sps)], pps: [Data(pps)]))
        #expect(frames[1].parameterSets == nil)

        // No delimiters at all, with the parameter sets in a packet of their own.
        var bare = H264Assembler()
        bare.append(Data(annexB([sps, pps])), pts: 3000, dts: 3000)
        bare.append(Data(annexB([idr])), pts: 3000, dts: 3000)
        bare.append(Data(annexB([p])), pts: 6000, dts: 6000)
        bare.append(Data(annexB([pTail])), pts: nil, dts: nil)
        let plain = bare.frames()
        #expect(plain.map(\.data) == [avcc([idr]), avcc([p, pTail])])
        #expect(plain.map(\.dts) == [3000, 6000])
        #expect(plain.first?.isKeyframe == true)
        #expect(plain.first?.parameterSets != nil)
    }

    @Test func repairsDecodeTimesTheWriterWouldReject() throws {
        var unwrapper = TimestampUnwrapper()
        var frames = try SegmentDemuxer.demux(try Fixture.data("muxed/seg0.ts"), unwrapper: &unwrapper).video
        let presentation = frames.map(\.pts)
        // Decode times numbered with no room for reordering, so B-frames claim to be shown
        // before they are decoded, and one decode time used twice.
        for index in frames.indices { frames[index].dts += 12000 }
        frames[7].dts = frames[6].dts
        #expect(frames.contains { $0.pts < $0.dts })

        let track = try #require(try TransportStreamSource.videoTrack(frames))
        #expect(track.samples.count == frames.count)
        #expect(track.samples.allSatisfy { $0.pts >= $0.dts })
        #expect(zip(track.samples, track.samples.dropFirst()).allSatisfy { $0.dts < $1.dts })
        // Presentation times, which are what the viewer sees, are left alone.
        #expect(track.samples.map { $0.pts.value - ClipMedia.biasTicks } == presentation)
    }

    @Test func describesAACForMP4() throws {
        let config = AACConfig(objectType: 2, sampleRate: 44100, channelConfiguration: 2)
        #expect(config.audioSpecificConfig == Data([0x12, 0x10]))
        #expect(AACConfig(objectType: 2, sampleRate: 48000, channelConfiguration: 1).audioSpecificConfig == Data([0x11, 0x88]))
        let format = try config.formatDescription()
        #expect(format.mediaSubType == .mpeg4AAC)
        #expect(format.audioStreamBasicDescription?.mSampleRate == 44100)
        #expect(format.audioStreamBasicDescription?.mChannelsPerFrame == 2)
    }

    // MARK: - Export

    @Test func exportsARangeOfAMuxedStream() async throws {
        let snapshot = try await LiveSnapshot.capture(master: Fixture.url("muxed/media.m3u8"), last: 120)
        #expect(snapshot.duration == 6)
        #expect(snapshot.audio == nil)

        let output = Fixture.scratchFile()
        defer { try? FileManager.default.removeItem(at: output) }
        let progress = ProgressLog()
        try await ClipExporter.export(snapshot, range: 1.3..<4.7, to: output) { progress.record($0) }

        let clip = try await ExportedClip(output)
        #expect(clip.videoTrackCount == 1)
        #expect(clip.audioTrackCount == 1)
        #expect(abs(clip.duration - 3.4) < 0.01)
        #expect(abs(clip.videoDuration - 3.4) < 0.01)
        #expect(abs(clip.audioDuration - 3.4) < 0.01)
        #expect(clip.videoSize == CGSize(width: 160, height: 90))

        // 1.3 s falls two thirds of the way through the picture shown from 1.267 s, so the
        // clip opens on the rest of that picture and then shows 20/15 s ... 70/15 s.
        #expect(clip.videoFrameTimes.count == 52)
        #expect(clip.videoFrameTimes.first.map { abs($0) < 0.001 } == true)
        #expect(clip.videoFrameTimes.dropFirst().first.map { abs($0 - (20.0 / 15 - 1.3)) < 0.001 } == true)
        #expect(clip.videoFrameTimes.last.map { abs($0 - (70.0 / 15 - 1.3)) < 0.001 } == true)

        // Beeps at 2, 3 and 4 s of the stream land 1.3 s earlier in the clip.
        #expect(clip.beepOnsets.count == 3)
        for (onset, expected) in zip(clip.beepOnsets, [0.7, 1.7, 2.7]) {
            #expect(abs(onset - expected) < 0.012)
        }

        #expect(progress.values.first == 0)
        #expect(progress.values.last == 1)
        #expect(progress.values == progress.values.sorted())
    }

    @Test func muxedAudioCoversARangeCutAtSegmentBoundaries() async throws {
        // The sound that goes with the last tenth of a second of each fixture segment's
        // picture is at the start of the next segment, so a range that is exactly one
        // segment still needs its neighbors.
        let snapshot = try await LiveSnapshot.capture(master: Fixture.url("muxed/media.m3u8"), last: 120)
        let output = Fixture.scratchFile()
        defer { try? FileManager.default.removeItem(at: output) }
        try await ClipExporter.export(snapshot, range: 2..<4, to: output)

        let clip = try await ExportedClip(output)
        #expect(abs(clip.duration - 2) < 0.01)
        #expect(abs(clip.videoDuration - 2) < 0.01)
        #expect(abs(clip.audioStart) < 0.001)
        #expect(abs(clip.audioDuration - 2) < 0.01)
        #expect(clip.videoFrameTimes.count == 30)
        #expect(clip.beepOnsets.count == 2)
        for (onset, expected) in zip(clip.beepOnsets, [0, 1.0]) {
            #expect(abs(onset - expected) < 0.012)
        }
    }

    @Test func exportsVideoWithSeparatePackedAudio() async throws {
        let snapshot = try await LiveSnapshot.capture(master: Fixture.url("split/master.m3u8"), last: 120)
        #expect(snapshot.duration == 6)
        #expect(snapshot.videoSize == CGSize(width: 160, height: 90))
        #expect(snapshot.video.map(\.url.lastPathComponent) == ["video0.ts", "video1.ts", "video2.ts"])
        #expect(snapshot.audio?.map(\.url.lastPathComponent) == ["audio0.aac", "audio1.aac", "audio2.aac"])

        let output = Fixture.scratchFile()
        defer { try? FileManager.default.removeItem(at: output) }
        try await ClipExporter.export(snapshot, range: 0.5..<5.5, to: output)

        let clip = try await ExportedClip(output)
        #expect(clip.videoTrackCount == 1)
        #expect(clip.audioTrackCount == 1)
        #expect(abs(clip.duration - 5) < 0.01)
        #expect(abs(clip.audioDuration - 5) < 0.01)
        #expect(clip.videoFrameTimes.count == 76)
        #expect(clip.beepOnsets.count == 5)
        for (onset, expected) in zip(clip.beepOnsets, [0.5, 1.5, 2.5, 3.5, 4.5]) {
            #expect(abs(onset - expected) < 0.012)
        }
    }

    @Test func exportClampsTheRangeAndReplacesTheDestination() async throws {
        let snapshot = try await LiveSnapshot.capture(master: Fixture.url("muxed/media.m3u8"), last: 4)
        #expect(snapshot.duration == 4)
        #expect(snapshot.video.map(\.url.lastPathComponent) == ["seg1.ts", "seg2.ts"])

        let output = Fixture.scratchFile()
        defer { try? FileManager.default.removeItem(at: output) }
        try Data("stale".utf8).write(to: output)
        try await ClipExporter.export(snapshot, range: -5..<100, to: output)

        let clip = try await ExportedClip(output)
        #expect(abs(clip.duration - 4) < 0.03)
        #expect(clip.videoFrameTimes.count == 60)
        // The snapshot starts at 2 s of the stream, so its beeps are at 1 s and 2 s (the one
        // at 0 s is cut in half by the start and may or may not register).
        let later = clip.beepOnsets.filter { $0 > 0.5 }
        #expect(later.count == 3)
        for (onset, expected) in zip(later, [1.0, 2.0, 3.0]) {
            #expect(abs(onset - expected) < 0.012)
        }

        await #expect(throws: ClipError.emptyRange) {
            try await ClipExporter.export(snapshot, range: 9..<12, to: output)
        }
    }

    @Test func exportsThroughByteRanges() async throws {
        // One file holding all three segments back to back, addressed by byte range.
        let directory = Fixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var combined = Data()
        var lines = ["#EXTM3U", "#EXT-X-VERSION:4", "#EXT-X-TARGETDURATION:2"]
        for (index, name) in ["muxed/seg0.ts", "muxed/seg1.ts", "muxed/seg2.ts"].enumerated() {
            let data = try Fixture.data(name)
            lines.append("#EXTINF:2.0,")
            lines.append(index == 0 ? "#EXT-X-BYTERANGE:\(data.count)@0" : "#EXT-X-BYTERANGE:\(data.count)")
            lines.append("all.ts")
            combined.append(data)
        }
        try combined.write(to: directory.appendingPathComponent("all.ts"))
        let playlist = directory.appendingPathComponent("media.m3u8")
        try lines.joined(separator: "\n").write(to: playlist, atomically: true, encoding: .utf8)

        let snapshot = try await LiveSnapshot.capture(master: playlist, last: 120)
        #expect(snapshot.video.compactMap(\.byteRange).count == 3)
        let output = directory.appendingPathComponent("clip.mp4")
        try await ClipExporter.export(snapshot, range: 2.5..<5.5, to: output)

        let clip = try await ExportedClip(output)
        #expect(abs(clip.duration - 3) < 0.01)
        #expect(clip.beepOnsets.count == 3)
        for (onset, expected) in zip(clip.beepOnsets, [0.5, 1.5, 2.5]) {
            #expect(abs(onset - expected) < 0.012)
        }
    }

    @Test func exportsAcrossADiscontinuity() async throws {
        // Two seconds of the main fixture, then a different stream with its own clock and
        // picture size, then the main fixture again: what an inserted ad looks like.
        let directory = Fixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let playlist = directory.appendingPathComponent("media.m3u8")
        try """
            #EXTM3U
            #EXT-X-TARGETDURATION:2
            #EXT-X-MEDIA-SEQUENCE:10
            #EXTINF:2.0,
            \(Fixture.url("muxed/seg0.ts").absoluteString)
            #EXT-X-DISCONTINUITY
            #EXTINF:2.0,
            \(Fixture.url("alt/seg0.ts").absoluteString)
            #EXT-X-DISCONTINUITY
            #EXTINF:2.0,
            \(Fixture.url("muxed/seg2.ts").absoluteString)
            """.write(to: playlist, atomically: true, encoding: .utf8)

        let snapshot = try await LiveSnapshot.capture(master: playlist, last: 120)
        #expect(snapshot.video.map(\.discontinuitySequence) == [0, 1, 2])
        let output = directory.appendingPathComponent("clip.mp4")
        try await ClipExporter.export(snapshot, range: 0.5..<5.5, to: output)

        let clip = try await ExportedClip(output)
        #expect(clip.videoTrackCount == 1)
        #expect(clip.audioTrackCount == 1)
        #expect(abs(clip.duration - 5) < 0.02)
        // Every picture decodes, including those after each change of format.
        #expect(clip.videoFrameTimes.count == 76)
        // The first run has its beep at 1 s. The middle run is a steady tone. The last run is
        // the stream's 4...6 s, with beeps at its start and at 5 s. The first segment's audio
        // stops 0.1 s short of its video (the rest is in the segment the playlist skips), so
        // the later beeps only land on time if that hole was padded rather than closed up.
        #expect(abs(clip.audioDuration - 5) < 0.03)
        #expect(clip.beepOnsets.count == 3)
        for (onset, expected) in zip(clip.beepOnsets, [0.5, 3.5, 4.5]) {
            #expect(abs(onset - expected) < 0.012)
        }
    }

    @Test func refusesContainersItCannotRemux() async throws {
        let directory = Fixture.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 0x00, count: 4096).write(to: directory.appendingPathComponent("junk.ts"))
        let playlist = directory.appendingPathComponent("media.m3u8")
        try "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,\njunk.ts\n".write(to: playlist, atomically: true, encoding: .utf8)

        let snapshot = try await LiveSnapshot.capture(master: playlist, last: 120)
        let output = directory.appendingPathComponent("clip.mp4")
        await #expect(throws: ClipError.self) {
            try await ClipExporter.export(snapshot, range: 0..<2, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))

        // Fragmented MP4 can be captured (and played back), but export says no up front,
        // before downloading anything.
        let fragmented = directory.appendingPathComponent("fmp4.m3u8")
        try """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:2
            #EXT-X-MAP:URI="init.mp4"
            #EXTINF:2.0,
            seg0.m4s
            #EXTINF:2.0,
            seg1.m4s
            """.write(to: fragmented, atomically: true, encoding: .utf8)
        let fragmentedSnapshot = try await LiveSnapshot.capture(master: fragmented, last: 120)
        #expect(fragmentedSnapshot.duration == 4)
        await #expect(throws: ClipError.unsupportedMedia("fragmented MP4 segments")) {
            try await ClipExporter.export(fragmentedSnapshot, range: 0..<2, to: output)
        }
    }
}

// MARK: - Helpers

enum Fixture {

    static func url(_ path: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent(path)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: url(path))
    }

    static func scratchFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("clip-test-\(UUID().uuidString).mp4")
    }

    static func scratchDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Collects progress callbacks, which arrive on arbitrary threads.
final class ProgressLog: @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [Double] = []

    func record(_ value: Double) {
        lock.withLock { recorded.append(value) }
    }

    var values: [Double] {
        lock.withLock { recorded }
    }
}

/// What AVFoundation makes of an exported file, decoded all the way to pictures and PCM.
struct ExportedClip {

    var duration: TimeInterval
    var videoTrackCount: Int
    var audioTrackCount: Int
    var videoDuration: TimeInterval = 0
    var audioDuration: TimeInterval = 0
    /// Where in the clip the sound begins.
    var audioStart: TimeInterval = 0
    var videoSize: CGSize = .zero
    /// Presentation times of the decoded pictures, in order.
    var videoFrameTimes: [TimeInterval] = []
    /// Times at which the audio turns from the 440 Hz tone into a 1760 Hz beep.
    var beepOnsets: [TimeInterval] = []

    init(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        videoTrackCount = videoTracks.count
        audioTrackCount = audioTracks.count

        if let track = videoTracks.first {
            videoDuration = try await track.load(.timeRange).duration.seconds
            videoSize = try await track.load(.naturalSize)
            videoFrameTimes = try Self.decodeVideo(asset: asset, track: track)
        }
        if let track = audioTracks.first {
            let range = try await track.load(.timeRange)
            audioDuration = range.duration.seconds
            audioStart = range.start.seconds
            beepOnsets = try Self.findBeeps(asset: asset, track: track)
        }
    }

    private static func decodeVideo(asset: AVAsset, track: AVAssetTrack) throws -> [TimeInterval] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ClipError.noSamples }
        var times: [TimeInterval] = []
        while let buffer = output.copyNextSampleBuffer() {
            if buffer.imageBuffer != nil {
                times.append(buffer.presentationTimeStamp.seconds)
            }
        }
        if reader.status == .failed { throw reader.error ?? ClipError.noSamples }
        return times.sorted()
    }

    /// Decodes the track to mono PCM and counts zero crossings in 5 ms windows: about four
    /// for the 440 Hz tone, about eighteen during a beep.
    private static func findBeeps(asset: AVAsset, track: AVAssetTrack) throws -> [TimeInterval] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ClipError.noSamples }

        var samples: [Float] = []
        var origin: TimeInterval?
        while let buffer = output.copyNextSampleBuffer() {
            origin = origin ?? buffer.presentationTimeStamp.seconds
            guard let block = buffer.dataBuffer else { continue }
            let data = try block.dataBytes()
            data.withUnsafeBytes { samples.append(contentsOf: $0.bindMemory(to: Float.self)) }
        }
        if reader.status == .failed { throw reader.error ?? ClipError.noSamples }

        let window = 220
        var onsets: [TimeInterval] = []
        var inside = false
        var start = 0
        while start + window <= samples.count {
            var crossings = 0
            for index in start..<(start + window - 1) where (samples[index] < 0) != (samples[index + 1] < 0) {
                crossings += 1
            }
            let beeping = crossings > 12
            if beeping, !inside {
                onsets.append((origin ?? 0) + Double(start) / 44100)
            }
            inside = beeping
            start += window
        }
        return onsets
    }
}
