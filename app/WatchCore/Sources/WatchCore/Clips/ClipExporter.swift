import AVFoundation
import CoreMedia
import Foundation

/// Saves a stretch of a `LiveSnapshot` as an MP4 file.
///
/// Nothing is re-encoded. The segments overlapping the range are downloaded, taken apart
/// into their compressed video and audio frames, and those frames are written into an MP4
/// container as they are. The result is bit-for-bit the stream's own picture and sound.
public enum ClipExporter {

    /// Downloads the segments overlapping `range` (seconds on the snapshot's
    /// `0...duration` timeline), remuxes them to MP4 trimmed to that range, and writes the
    /// file to `output`, replacing anything already there.
    ///
    /// `range` is clamped to the snapshot. `progress` is called with values from 0 to 1,
    /// from arbitrary threads; most of the time goes into the downloads. Cancelling the
    /// calling task stops the export and leaves nothing at `output`.
    public static func export(
        _ snapshot: LiveSnapshot,
        range: Range<TimeInterval>,
        to output: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await export(snapshot, range: range, to: output, fetcher: ClipFetcher(), progress: progress)
    }

    static func export(
        _ snapshot: LiveSnapshot,
        range: Range<TimeInterval>,
        to output: URL,
        fetcher: ClipFetcher,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let lower = max(0, range.lowerBound)
        let upper = min(snapshot.duration, range.upperBound)
        guard upper - lower > 0.001 else { throw ClipError.emptyRange }
        let range = lower..<upper
        progress?(0)

        // Fragmented MP4 would need its own demuxer, and no stream the app plays uses it.
        guard !(snapshot.video + (snapshot.audio ?? [])).contains(where: { $0.map != nil }) else {
            throw ClipError.unsupportedMedia("fragmented MP4 segments")
        }
        let media = try await TransportStreamSource.load(snapshot, range: range, fetcher: fetcher) { progress?($0 * 0.9) }
        try Task.checkCancellation()

        let plan = try media.trimmed(to: range)

        // Everything is written to scratch files first, so a failed or cancelled export
        // never leaves a half-written file at the destination.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        let patched = scratch.deletingPathExtension().appendingPathExtension("explicit.mp4")
        defer {
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: patched)
        }
        try await ClipWriter.write(video: plan.video, audio: plan.audio, start: plan.start, end: plan.end, to: scratch)
        try Task.checkCancellation()
        let finished = try MP4AudioPriming.makeExplicit(from: scratch, to: patched) ? patched : scratch

        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: finished, to: output)
        progress?(1)
    }

    /// Fetches segments a few at a time and returns their bytes in playlist order.
    static func download(
        _ segments: [LiveSnapshot.Segment],
        fetcher: ClipFetcher,
        onSegment: @escaping @Sendable () -> Void
    ) async throws -> [Data] {
        let limit = 4
        var results = [Data?](repeating: nil, count: segments.count)
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func enqueue() {
                guard next < segments.count else { return }
                let index = next
                let segment = segments[index]
                next += 1
                group.addTask {
                    (index, try await fetcher.data(from: segment.url, range: segment.byteRange))
                }
            }
            for _ in 0..<limit { enqueue() }
            while let (index, data) = try await group.next() {
                results[index] = data
                onSegment()
                enqueue()
            }
        }
        return results.map { $0 ?? Data() }
    }
}

/// Counts finished downloads across concurrent tasks and reports the fraction done.
final class DownloadCounter: @unchecked Sendable {

    private let total: Int
    private let report: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var finished = 0

    init(total: Int, report: @escaping @Sendable (Double) -> Void) {
        self.total = max(total, 1)
        self.report = report
    }

    func advance() {
        let count = lock.withLock {
            finished += 1
            return finished
        }
        report(min(1, Double(count) / Double(total)))
    }
}

/// Everything downloaded for an export, as samples on the snapshot timeline, before it is
/// cut down to the requested range.
struct ClipMedia: Sendable {

    /// Added to every sample time before writing, in 90 kHz ticks (ten seconds). Trimming
    /// keeps a couple of audio frames ahead of the in point, which at the very start of a
    /// snapshot would otherwise have negative times.
    static let biasTicks: Int64 = 900_000
    static let bias = CMTime(value: biasTicks, timescale: 90000)

    /// Video samples in decode order.
    var video: ClipTrack?
    /// Audio samples in presentation order.
    var audio: ClipTrack?

    struct Plan: Sendable {
        var video: ClipTrack?
        var audio: ClipTrack?
        var start: CMTime
        var end: CMTime
    }

    /// Chooses the samples that have to be written for the file to show `range`.
    ///
    /// Video starts at the last keyframe at or before the in point, because nothing after
    /// it can be decoded without it, and runs through the last picture shown before the
    /// out point. Audio frames decode independently, but a decoder needs the preceding
    /// frame or two to produce clean output for the first one that is heard, so two extra
    /// frames are kept ahead of the in point. The returned start and end are the times the
    /// writer should present, which hide the extra samples again.
    func trimmed(to range: Range<TimeInterval>) throws -> Plan {
        var start = CMTime(seconds: range.lowerBound, preferredTimescale: 90000) + Self.bias
        let end = CMTime(seconds: range.upperBound, preferredTimescale: 90000) + Self.bias

        var videoTrack: ClipTrack?
        if let video, !video.samples.isEmpty {
            let samples = video.samples
            let first = samples.lastIndex { $0.isSync && $0.pts <= start } ?? samples.firstIndex { $0.isSync }
            let last = samples.lastIndex { $0.pts < end }
            if let first, let last, first <= last {
                // Without a keyframe at or before the in point the clip can only begin at
                // the first one after it.
                start = max(start, samples[first].pts)
                videoTrack = ClipTrack(mediaType: .video, formats: video.formats, samples: Array(samples[first...last])).compacted()
            }
        }

        var audioTrack: ClipTrack?
        if let audio = audio?.fillingAudioGaps(), !audio.samples.isEmpty {
            let samples = audio.samples.filter { sample in
                let lead = CMTimeMultiply(sample.duration, multiplier: 2)
                return sample.pts + sample.duration > start - lead && sample.pts < end
            }
            if !samples.isEmpty {
                audioTrack = ClipTrack(mediaType: .audio, formats: audio.formats, samples: samples).compacted()
            }
        }

        guard videoTrack != nil || audioTrack != nil, start < end else { throw ClipError.noSamples }
        return Plan(video: videoTrack, audio: audioTrack, start: start, end: end)
    }
}

extension ClipTrack {

    /// Drops formats no remaining sample refers to and renumbers the rest in order of first
    /// use, so that the first format is the first sample's.
    func compacted() -> ClipTrack {
        var mapping: [Int: Int] = [:]
        var used: [CMFormatDescription] = []
        var renumbered = samples
        for index in renumbered.indices {
            let old = renumbered[index].format
            if mapping[old] == nil {
                mapping[old] = used.count
                used.append(formats[old])
            }
            renumbered[index].format = mapping[old] ?? 0
        }
        return ClipTrack(mediaType: mediaType, formats: used, samples: renumbered)
    }
}

/// Builds `ClipMedia` from MPEG-TS and packed-audio segments.
enum TransportStreamSource {

    static func load(
        _ snapshot: LiveSnapshot,
        range: Range<TimeInterval>,
        fetcher: ClipFetcher,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ClipMedia {
        // Sound doesn't keep to the picture's segment boundaries. A separate audio
        // rendition can be cut at different times altogether, and its placement comes from
        // playlist arithmetic; in a muxed stream the sound for the first or last fraction
        // of a second of a segment's picture is often in the neighboring segment. So
        // whichever segments carry the audio are taken with a little extra either side.
        let margin: TimeInterval = 0.5
        let videoMargin = snapshot.audio == nil ? margin : 0
        let videoSegments = snapshot.video.filter { $0.end > range.lowerBound - videoMargin && $0.start < range.upperBound + videoMargin }
        let audioSegments = (snapshot.audio ?? []).filter { $0.end > range.lowerBound - margin && $0.start < range.upperBound + margin }
        guard !videoSegments.isEmpty else { throw ClipError.noSamples }

        let counter = DownloadCounter(total: videoSegments.count + audioSegments.count, report: progress)
        async let videoFetch = ClipExporter.download(videoSegments, fetcher: fetcher) { counter.advance() }
        async let audioFetch = ClipExporter.download(audioSegments, fetcher: fetcher) { counter.advance() }
        let (videoData, audioData) = try await (videoFetch, audioFetch)

        return try assemble(
            video: Array(zip(videoSegments, videoData)),
            audio: Array(zip(audioSegments, audioData))
        )
    }

    /// Demuxes the downloaded segments and places their frames on the snapshot timeline.
    ///
    /// Stream timestamps are arbitrary large numbers that restart at every discontinuity,
    /// so each continuous run of segments gets its own offset: the earliest video timestamp
    /// in the run's first downloaded segment is pinned to that segment's position in the
    /// snapshot. Everything else in the run, including the separate audio rendition (which
    /// shares the video's clock), moves by the same offset, which is what keeps picture and
    /// sound in sync exactly as the stream had them.
    static func assemble(
        video: [(segment: LiveSnapshot.Segment, data: Data)],
        audio: [(segment: LiveSnapshot.Segment, data: Data)]
    ) throws -> ClipMedia {
        var videoFrames: [VideoFrame] = []
        var audioFrames: [AudioFrame] = []
        var audioBySequence = Dictionary(grouping: audio, by: \.segment.discontinuitySequence)

        var index = 0
        while index < video.count {
            let sequence = video[index].segment.discontinuitySequence
            var unwrapper = TimestampUnwrapper()
            var runVideo: [VideoFrame] = []
            var runAudio: [AudioFrame] = []
            var anchor: (ticks: Int64, start: TimeInterval)?

            while index < video.count, video[index].segment.discontinuitySequence == sequence {
                let demuxed = try SegmentDemuxer.demux(video[index].data, unwrapper: &unwrapper)
                if anchor == nil, let earliest = demuxed.video.map(\.pts).min() ?? demuxed.audio.map(\.pts).min() {
                    anchor = (earliest, video[index].segment.start)
                }
                runVideo += demuxed.video
                runAudio += demuxed.audio
                index += 1
            }

            // The audio rendition's segments for this run, read with the same unwrapper so a
            // timestamp wrap between the two renditions resolves consistently.
            for item in audioBySequence.removeValue(forKey: sequence) ?? [] {
                runAudio += try SegmentDemuxer.demux(item.data, unwrapper: &unwrapper).audio
            }

            guard let anchor else { continue }
            var offset = Int64((anchor.start * 90000).rounded()) - anchor.ticks

            // Playlist durations are rounded, so a run can come out a hair longer than its
            // segments claim. Never let the next run start before this one's last picture
            // has had its turn.
            if let previous = videoFrames.last, let first = runVideo.first {
                let step = videoFrames.count > 1 ? max(1, previous.dts - videoFrames[videoFrames.count - 2].dts) : 1
                let earliest = previous.dts + step
                if first.dts + offset < earliest { offset = earliest - first.dts }
            }
            videoFrames += runVideo.map { frame in
                var frame = frame
                frame.pts += offset
                frame.dts += offset
                return frame
            }
            audioFrames += runAudio.map { frame in
                var frame = frame
                frame.pts += offset
                return frame
            }
        }

        // Audio segments whose discontinuity numbering matched no video run. That shouldn't
        // happen in a conforming stream; place them by their own playlist position rather
        // than exporting silence.
        for sequence in audioBySequence.keys.sorted() {
            var unwrapper = TimestampUnwrapper()
            var offset: Int64?
            for item in audioBySequence[sequence] ?? [] {
                for var frame in try SegmentDemuxer.demux(item.data, unwrapper: &unwrapper).audio {
                    let applied = offset ?? Int64((item.segment.start * 90000).rounded()) - frame.pts
                    offset = applied
                    frame.pts += applied
                    audioFrames.append(frame)
                }
            }
        }

        return ClipMedia(video: try videoTrack(videoFrames), audio: try audioTrack(audioFrames))
    }

    /// Turns frames into samples. A frame's duration is the gap to the next decode time; the
    /// last frame, which has no successor, borrows its predecessor's.
    static func videoTrack(_ frames: [VideoFrame]) throws -> ClipTrack? {
        var formats: [CMFormatDescription] = []
        var currentSets: H264ParameterSets?
        var samples: [ClipSample] = []
        samples.reserveCapacity(frames.count)
        var lastDuration: Int64 = 3000
        var previousDTS = Int64.min

        // A decode time may not be later than its presentation time, but some packagers
        // (Apple's own older segmenter among them) number decode times from the first
        // picture without leaving room for reordering, so B-frames come out "presented
        // before decoded" and AVAssetWriter rejects them. Only the order and spacing of
        // decode times matter, so slide them all earlier by the worst offender's amount.
        let lead = max(0, frames.map { $0.dts - $0.pts }.max() ?? 0)

        for (index, frame) in frames.enumerated() {
            if let sets = frame.parameterSets, sets != currentSets {
                formats.append(try sets.formatDescription())
                currentSets = sets
            }
            // Pictures ahead of the first parameter sets can't be described, so skip them.
            guard !formats.isEmpty else { continue }

            if index + 1 < frames.count {
                let gap = frames[index + 1].dts - frame.dts
                if gap > 0, gap < 90000 { lastDuration = gap }
            }
            // The writer also insists that decode times strictly increase. A repeated one
            // is nudged forward a tick rather than losing the picture.
            let dts = max(frame.dts - lead, previousDTS + 1)
            previousDTS = dts
            samples.append(ClipSample(
                pts: CMTime(value: frame.pts + ClipMedia.biasTicks, timescale: 90000),
                dts: CMTime(value: dts + ClipMedia.biasTicks, timescale: 90000),
                duration: CMTime(value: lastDuration, timescale: 90000),
                isSync: frame.isKeyframe,
                data: frame.data,
                format: formats.count - 1
            ))
        }
        return samples.isEmpty ? nil : ClipTrack(mediaType: .video, formats: formats, samples: samples)
    }

    /// Turns frames into samples on the audio's own sample clock.
    ///
    /// Stream timestamps are in 90 kHz ticks, which can't express a 1024-sample frame
    /// exactly, so writing them as they are would give every frame a slightly different
    /// length. Instead each frame is placed directly after the previous one for as long as
    /// its timestamp agrees to within half a frame. A larger step forward is a real gap and
    /// is kept; a step backward means the frame overlaps audio already taken (as happens
    /// where two runs meet) and it is dropped.
    private static func audioTrack(_ frames: [AudioFrame]) throws -> ClipTrack? {
        var formats: [CMFormatDescription] = []
        var currentConfig: AACConfig?
        var samples: [ClipSample] = []
        samples.reserveCapacity(frames.count)
        var expected: CMTime?

        for frame in frames.sorted(by: { $0.pts < $1.pts }) {
            if frame.config != currentConfig {
                formats.append(try frame.config.formatDescription())
                currentConfig = frame.config
                expected = nil
            }
            let rate = Int64(frame.config.sampleRate)
            let duration = CMTime(value: CMTimeValue(AACConfig.samplesPerFrame), timescale: CMTimeScale(rate))
            let stamped = CMTime(value: ((frame.pts + ClipMedia.biasTicks) * rate + 45000) / 90000, timescale: CMTimeScale(rate))
            var pts = stamped
            if let expected {
                let drift = (stamped - expected).seconds
                let tolerance = duration.seconds / 2
                if drift < -tolerance { continue }
                if drift <= tolerance { pts = expected }
            }
            expected = pts + duration
            samples.append(ClipSample(pts: pts, dts: pts, duration: duration, isSync: true, data: frame.data, format: formats.count - 1))
        }
        return samples.isEmpty ? nil : ClipTrack(mediaType: .audio, formats: formats, samples: samples)
    }
}
