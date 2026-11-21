import Foundation

/// The last stretch of a live HLS stream, frozen at the moment of capture.
///
/// A snapshot is only a list of segment URLs with their positions on a timeline that starts
/// at zero; no media is downloaded until it is played or exported. The URLs are the
/// stream's own, so a snapshot stays usable only for as long as the server keeps those
/// segments available.
public struct LiveSnapshot: Sendable {

    /// Seconds captured, measured as the sum of the video segments' playlist durations.
    /// Whole segments are kept, so this can exceed the request by up to one segment, and it
    /// is shorter than the request when the playlist doesn't reach back that far.
    public let duration: TimeInterval

    /// When the playlists were fetched.
    public let capturedAt: Date

    /// Pixel size of the chosen variant, when the master playlist states it.
    public let videoSize: CGSize?

    /// One media segment placed on the snapshot timeline.
    struct Segment: Sendable, Equatable {
        var url: URL
        var byteRange: HLSMediaPlaylist.ByteRange?
        var duration: TimeInterval
        /// Seconds from the snapshot's time zero to the start of this segment, according to
        /// the playlist durations. Audio segments are placed on the video timeline, so the
        /// first one can start slightly before zero.
        var start: TimeInterval
        var discontinuitySequence: Int
        var map: HLSMediaPlaylist.Map?
        var isEncrypted = false

        var end: TimeInterval { start + duration }
    }

    /// What the master playlist said about the chosen variant. Only used to describe the
    /// stream to AVPlayer again when the snapshot is played back.
    struct VariantInfo: Sendable, Equatable {
        var bandwidth: Int
        var codecs: [String]
        var width: Int?
        var height: Int?
        var frameRate: Double?
    }

    /// The segments that carry video (and, for muxed streams, audio as well).
    let video: [Segment]
    /// The segments of the separate audio rendition, or nil when audio is muxed into `video`.
    let audio: [Segment]?
    let variant: VariantInfo?

    /// Fetches the master (or a bare media playlist), picks a variant, and freezes the
    /// segments covering the last `seconds`.
    ///
    /// The variant is the tallest H.264 one not exceeding `maxHeight`. Time zero of the
    /// snapshot is the start of the first captured video segment.
    public static func capture(master: URL, last seconds: TimeInterval, maxHeight: Int = 1080) async throws -> LiveSnapshot {
        try await capture(master: master, last: seconds, maxHeight: maxHeight, fetcher: ClipFetcher())
    }

    static func capture(master: URL, last seconds: TimeInterval, maxHeight: Int, fetcher: ClipFetcher) async throws -> LiveSnapshot {
        let capturedAt = Date()
        let top = try await fetcher.playlist(from: master)

        switch try HLSPlaylist.parse(top.text, baseURL: top.url) {
        case .media(let playlist):
            return try LiveSnapshot(video: playlist, audio: nil, variant: nil, last: seconds, capturedAt: capturedAt)

        case .master(let masterPlaylist):
            guard let variant = masterPlaylist.selectVariant(maxHeight: maxHeight) else {
                throw ClipError.emptyPlaylist
            }
            let audioURL = masterPlaylist.audioRendition(for: variant)?.url

            // Fetched together so the two playlists describe (nearly) the same live edge.
            async let videoFetch = fetcher.playlist(from: variant.url)
            async let audioFetch = Self.optionalPlaylist(from: audioURL, fetcher: fetcher)
            let (videoResult, audioResult) = try await (videoFetch, audioFetch)

            return try LiveSnapshot(
                video: try Self.mediaPlaylist(videoResult),
                audio: try audioResult.map(Self.mediaPlaylist),
                variant: VariantInfo(
                    bandwidth: variant.bandwidth,
                    codecs: variant.codecs,
                    width: variant.width,
                    height: variant.height,
                    frameRate: variant.frameRate
                ),
                last: seconds,
                capturedAt: capturedAt
            )
        }
    }

    private static func optionalPlaylist(from url: URL?, fetcher: ClipFetcher) async throws -> (text: String, url: URL)? {
        guard let url else { return nil }
        return try await fetcher.playlist(from: url)
    }

    private static func mediaPlaylist(_ fetched: (text: String, url: URL)) throws -> HLSMediaPlaylist {
        guard case .media(let playlist) = try HLSPlaylist.parse(fetched.text, baseURL: fetched.url) else {
            throw ClipError.invalidPlaylist("expected a media playlist")
        }
        return playlist
    }

    /// Selects the trailing segments of `video` covering `seconds` and the audio segments
    /// that go with them.
    ///
    /// The two playlists of a live stream are fetched separately, so one can be a segment
    /// ahead of the other, and nothing guarantees their segments have the same boundaries.
    /// They are therefore lined up on one timeline first (see `audioShift`), trimmed to the
    /// stretch both cover, and only then cut to the requested length.
    init(video: HLSMediaPlaylist, audio: HLSMediaPlaylist?, variant: VariantInfo?, last seconds: TimeInterval, capturedAt: Date) throws {
        guard !video.segments.isEmpty else { throw ClipError.emptyPlaylist }

        var videoSegments = Self.place(video.segments, shift: 0)
        var audioSegments: [Segment]?

        if let audio, !audio.segments.isEmpty {
            var placed = Self.place(audio.segments, shift: Self.audioShift(video: video, audio: audio))
            let audioEnd = placed[placed.count - 1].end
            // Drop video the audio playlist hasn't caught up with (less than half a segment
            // covered), and audio that lies wholly past the end of the video.
            while videoSegments.count > 1, let last = videoSegments.last, last.start + last.duration / 2 > audioEnd {
                videoSegments.removeLast()
            }
            let videoEnd = videoSegments[videoSegments.count - 1].end
            placed.removeAll { $0.start >= videoEnd - 0.01 }
            audioSegments = placed
        }

        var first = videoSegments.count
        var covered: TimeInterval = 0
        while first > 0, covered < seconds - 0.001 {
            first -= 1
            covered += videoSegments[first].duration
        }
        first = min(first, videoSegments.count - 1)
        videoSegments.removeFirst(first)

        let origin = videoSegments[0].start
        let rebase: (Segment) -> Segment = { segment in
            var segment = segment
            segment.start -= origin
            return segment
        }
        let window = videoSegments.map(rebase)
        let windowEnd = window[window.count - 1].end

        let audioWindow = audioSegments.map { segments in
            segments.map(rebase).filter { $0.end > 0.01 && $0.start < windowEnd - 0.01 }
        }

        guard !window.contains(where: \.isEncrypted), audioWindow?.contains(where: \.isEncrypted) != true else {
            throw ClipError.encrypted
        }

        self.video = window
        self.audio = audioWindow.flatMap { $0.isEmpty ? nil : $0 }
        self.variant = variant
        self.duration = windowEnd
        self.capturedAt = capturedAt
        if let width = variant?.width, let height = variant?.height {
            self.videoSize = CGSize(width: width, height: height)
        } else {
            self.videoSize = nil
        }
    }

    /// Lays a playlist's segments end to end, starting at `shift`.
    private static func place(_ segments: [HLSMediaPlaylist.Segment], shift: TimeInterval) -> [Segment] {
        var start = shift
        return segments.map { segment in
            defer { start += segment.duration }
            return Segment(
                url: segment.url,
                byteRange: segment.byteRange,
                duration: segment.duration,
                start: start,
                discontinuitySequence: segment.discontinuitySequence,
                map: segment.map,
                isEncrypted: segment.isEncrypted
            )
        }
    }

    /// Where the audio playlist's first segment starts, in seconds from the start of the
    /// video playlist's first segment.
    ///
    /// Wall-clock dates are the alignment HLS defines, so they are used when both playlists
    /// carry them, comparing the newest segment of each. Without dates, segments with the
    /// same media sequence number are assumed to start together, which holds for packagers
    /// that cut every rendition at the same points (YouTube does). Failing both, the
    /// playlists are assumed to end at the same instant.
    static func audioShift(video: HLSMediaPlaylist, audio: HLSMediaPlaylist) -> TimeInterval {
        let videoStarts = starts(of: video.segments)
        let audioStarts = starts(of: audio.segments)
        guard let videoLast = video.segments.last, let audioLast = audio.segments.last else { return 0 }

        if let videoDate = videoLast.programDateTime, let audioDate = audioLast.programDateTime {
            return videoStarts[videoStarts.count - 1] + audioDate.timeIntervalSince(videoDate) - audioStarts[audioStarts.count - 1]
        }

        let videoIndex = Dictionary(video.segments.enumerated().map { ($1.mediaSequence, $0) }, uniquingKeysWith: { $1 })
        if let match = audio.segments.indices.reversed().first(where: { videoIndex[audio.segments[$0].mediaSequence] != nil }),
           let index = videoIndex[audio.segments[match].mediaSequence] {
            return videoStarts[index] - audioStarts[match]
        }

        return (videoStarts[videoStarts.count - 1] + videoLast.duration) - (audioStarts[audioStarts.count - 1] + audioLast.duration)
    }

    private static func starts(of segments: [HLSMediaPlaylist.Segment]) -> [TimeInterval] {
        var start: TimeInterval = 0
        return segments.map { segment in
            defer { start += segment.duration }
            return start
        }
    }
}
