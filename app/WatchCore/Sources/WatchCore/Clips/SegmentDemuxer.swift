import Foundation

/// One H.264 access unit (a coded picture), ready to become an MP4 sample.
struct VideoFrame: Sendable {
    /// Presentation and decode time in 90 kHz ticks, unwrapped. They differ when the stream
    /// uses B-frames.
    var pts: Int64
    var dts: Int64
    /// True for IDR pictures, the only ones decoding can start from.
    var isKeyframe: Bool
    /// The picture's NAL units in AVCC form: each prefixed by its length as four big-endian
    /// bytes. Parameter sets, access unit delimiters and filler are left out.
    var data: Data
    /// The SPS and PPS found alongside this picture, if it carried any.
    var parameterSets: H264ParameterSets?
}

/// The H.264 sequence and picture parameter sets that describe how to decode a run of
/// pictures. In MP4 these live in the sample description rather than in the samples.
struct H264ParameterSets: Sendable, Equatable {
    var sps: [Data]
    var pps: [Data]
}

/// One raw AAC frame (an ADTS frame with its header removed).
struct AudioFrame: Sendable {
    /// Presentation time in 90 kHz ticks, unwrapped. Only the first frame after a timestamp
    /// in the stream is exact; the others are counted forward from it, 1024 samples each.
    var pts: Int64
    var data: Data
    var config: AACConfig
}

/// What an ADTS header says about the audio: enough to write an MP4 sample description.
struct AACConfig: Sendable, Equatable {
    /// MPEG-4 audio object type. ADTS can only express 1...4; 2 is AAC-LC. HE-AAC streams
    /// also say 2 here, with the SBR extension signalled implicitly inside the frames.
    var objectType: Int
    var sampleRate: Int
    var channelConfiguration: Int

    static let samplesPerFrame = 1024

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// The two-byte MPEG-4 AudioSpecificConfig equivalent to the ADTS header fields.
    var audioSpecificConfig: Data {
        let index = Self.sampleRates.firstIndex(of: sampleRate) ?? 4
        let bits = UInt16(objectType) << 11 | UInt16(index) << 7 | UInt16(channelConfiguration) << 3
        return Data([UInt8(bits >> 8), UInt8(bits & 0xFF)])
    }
}

/// The video and audio found in one HLS media segment.
struct DemuxedSegment: Sendable {
    var video: [VideoFrame] = []
    var audio: [AudioFrame] = []
}

/// Extracts frames from the segment formats HLS uses outside fragmented MP4: MPEG-TS
/// (video, audio, or both muxed) and packed audio (bare ADTS behind an ID3 tag).
enum SegmentDemuxer {

    /// Demuxes one segment. Timestamps are passed through `unwrapper`, which the caller
    /// keeps across the segments of one continuous stretch of the stream.
    static func demux(_ data: Data, unwrapper: inout TimestampUnwrapper) throws -> DemuxedSegment {
        if MPEGTS.matches(data) {
            return try demuxTransportStream(data, unwrapper: &unwrapper)
        }
        if PackedAudio.matches(data) {
            return DemuxedSegment(audio: try PackedAudio.frames(in: data, unwrapper: &unwrapper))
        }
        throw ClipError.unsupportedMedia("unrecognized segment container")
    }

    private static func demuxTransportStream(_ data: Data, unwrapper: inout TimestampUnwrapper) throws -> DemuxedSegment {
        let (packets, streamTypes) = MPEGTS.demux(data)

        // Refuse streams we would otherwise silently export without their picture or sound.
        for type in streamTypes.values {
            switch type {
            case MPEGTS.StreamType.hevc:
                throw ClipError.unsupportedMedia("HEVC video in MPEG-TS")
            case MPEGTS.StreamType.mpeg1Audio, MPEGTS.StreamType.mpeg2Audio:
                throw ClipError.unsupportedMedia("MPEG audio in MPEG-TS")
            case MPEGTS.StreamType.latmAAC:
                throw ClipError.unsupportedMedia("LATM AAC in MPEG-TS")
            case MPEGTS.StreamType.ac3, MPEGTS.StreamType.eac3:
                throw ClipError.unsupportedMedia("Dolby audio in MPEG-TS")
            default:
                break
            }
        }

        // Use the first video and the first audio PID; alternate tracks are ignored.
        let videoPID = streamTypes.filter { $0.value == MPEGTS.StreamType.h264 }.keys.min()
        let audioPID = streamTypes.filter { $0.value == MPEGTS.StreamType.adtsAAC }.keys.min()

        var video = H264Assembler()
        var audio = ADTSParser()
        for packet in packets {
            if packet.pid == videoPID {
                // Decode time comes first in the stream, so unwrap it first.
                let dts = packet.pts.map { unwrapper.unwrap(packet.dts ?? $0) }
                let pts = packet.pts.map { unwrapper.unwrap($0) }
                video.append(packet.payload, pts: pts, dts: dts)
            } else if packet.pid == audioPID {
                audio.append(packet.payload, pts: packet.pts.map { unwrapper.unwrap($0) })
            }
        }
        return DemuxedSegment(video: video.frames(), audio: audio.frames)
    }
}

/// Splits an H.264 elementary stream into pictures and gives each its timestamps.
///
/// Most muxers put exactly one picture in each PES packet, but nothing requires it. The
/// video is one continuous byte stream that may be cut into packets anywhere, even in the
/// middle of a NAL unit (Apple's older segmenter does this), and a packet's timestamp then
/// belongs to the first picture that begins inside it. So the payloads are joined back
/// together and split where the codec says pictures start, at access unit delimiters, with
/// each timestamp remembered by the position at which it entered the stream.
struct H264Assembler: Sendable {

    private struct Stamp: Equatable {
        var pts: Int64
        var dts: Int64
    }

    private struct Picture {
        var stamp: Stamp?
        var data = Data()
        var isKeyframe = false
    }

    private var stream = Data()
    private var stamps: [(offset: Int, stamp: Stamp)] = []

    /// Feeds the next PES payload, with its unwrapped timestamps if the packet had any.
    mutating func append(_ payload: Data, pts: Int64?, dts: Int64?) {
        if let pts { stamps.append((stream.count, Stamp(pts: pts, dts: dts ?? pts))) }
        stream.append(payload)
    }

    /// The pictures in everything fed so far, in decode order.
    func frames() -> [VideoFrame] {
        var frames: [VideoFrame] = []
        stream.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var units: [(type: UInt8, offset: Int, bytes: UnsafeRawBufferPointer)] = []
            H264.forEachNAL(in: raw) { nal, offset in
                units.append((nal[0] & 0x1F, offset, nal))
            }
            let hasDelimiters = units.contains { $0.type == H264.NALType.accessUnitDelimiter }

            var picture: Picture?
            // Parameter sets seen since the last finished picture. They describe the next.
            var sps: [Data] = []
            var pps: [Data] = []
            var nextStamp = 0

            /// The timestamp of the last packet that began at or before `offset` and has
            /// not been handed out yet.
            func takeStamp(upTo offset: Int) -> Stamp? {
                var found: Stamp?
                while nextStamp < stamps.count, stamps[nextStamp].offset <= offset {
                    found = stamps[nextStamp].stamp
                    nextStamp += 1
                }
                return found
            }

            func finishPicture() {
                guard let done = picture, !done.data.isEmpty else { return }
                var stamp = done.stamp
                if stamp == nil, let last = frames.last {
                    // A picture that began in a packet some other picture had already
                    // begun in has no timestamp of its own. Its decode time has to be one
                    // step on from the previous picture's; when it is shown is a guess.
                    let step = frames.count > 1 ? max(1, last.dts - frames[frames.count - 2].dts) : 3000
                    stamp = Stamp(pts: last.dts + step, dts: last.dts + step)
                }
                guard let stamp else { return }
                frames.append(VideoFrame(
                    pts: stamp.pts,
                    dts: stamp.dts,
                    isKeyframe: done.isKeyframe,
                    data: done.data,
                    parameterSets: sps.isEmpty || pps.isEmpty ? nil : H264ParameterSets(sps: sps, pps: pps)
                ))
                sps = []
                pps = []
            }

            for unit in units {
                var fresh: Stamp?
                let startsPicture: Bool
                if hasDelimiters {
                    startsPicture = unit.type == H264.NALType.accessUnitDelimiter
                    if startsPicture { fresh = takeStamp(upTo: unit.offset) }
                } else {
                    // With no delimiters to go by, trust the packets: a new timestamp is a
                    // new picture. (A repeated one is more of the same picture, as when
                    // parameter sets travel in a packet of their own.)
                    fresh = takeStamp(upTo: unit.offset)
                    startsPicture = fresh != nil && (picture == nil || fresh != picture?.stamp)
                }
                if startsPicture {
                    finishPicture()
                    picture = Picture(stamp: fresh)
                }
                // Anything ahead of the first picture start is the end of a picture whose
                // beginning was never seen.
                guard picture != nil else { continue }

                switch unit.type {
                case H264.NALType.sps:
                    sps.append(Data(unit.bytes))
                case H264.NALType.pps:
                    pps.append(Data(unit.bytes))
                case H264.NALType.accessUnitDelimiter, H264.NALType.filler, H264.NALType.endOfSequence, H264.NALType.endOfStream:
                    break
                default:
                    if unit.type == H264.NALType.idrSlice { picture?.isKeyframe = true }
                    var length = UInt32(unit.bytes.count).bigEndian
                    withUnsafeBytes(of: &length) { picture?.data.append(contentsOf: $0) }
                    picture?.data.append(contentsOf: unit.bytes)
                }
            }
            finishPicture()
        }
        return frames
    }
}

enum H264 {

    enum NALType {
        static let slice: UInt8 = 1
        static let idrSlice: UInt8 = 5
        static let sps: UInt8 = 7
        static let pps: UInt8 = 8
        static let accessUnitDelimiter: UInt8 = 9
        static let endOfSequence: UInt8 = 10
        static let endOfStream: UInt8 = 11
        static let filler: UInt8 = 12
    }

    /// Calls `body` with each NAL unit of an Annex B byte stream (NAL units separated by
    /// `00 00 01` start codes) and the offset of its start code. Zero bytes before a start
    /// code belong to the start code (or are padding), never to the NAL unit, whose last
    /// byte is always non-zero.
    static func forEachNAL(in bytes: UnsafeRawBufferPointer, _ body: (_ nal: UnsafeRawBufferPointer, _ offset: Int) -> Void) {
        let count = bytes.count
        var start = -1
        var index = 0

        func emit(upTo end: Int) {
            guard start >= 0 else { return }
            var end = end
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            if end > start { body(UnsafeRawBufferPointer(rebasing: bytes[start..<end]), start - 3) }
        }

        while index + 2 < count {
            // A start code ends in 01 after two zeros, so a third byte above 1 rules out a
            // start code beginning at any of these three positions.
            if bytes[index + 2] > 1 {
                index += 3
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                emit(upTo: index)
                start = index + 3
                index += 3
            } else {
                index += 1
            }
        }
        emit(upTo: count)
    }
}

/// Splits an ADTS byte stream into AAC frames and assigns each a timestamp.
///
/// In a transport stream the ADTS frames flow through PES packets without regard to packet
/// boundaries: a PES usually holds several frames, and a frame can straddle two packets. A
/// PES timestamp applies to the first frame that begins inside that packet, so the parser
/// remembers where each timestamp entered the byte stream and counts frames from there.
struct ADTSParser: Sendable {

    private(set) var frames: [AudioFrame] = []

    private var buffer: [UInt8] = []
    /// Timestamps not yet applied, with the buffer offset their PES payload started at.
    private var anchors: [(offset: Int, pts: Int64)] = []
    private var anchorPTS: Int64?
    private var framesSinceAnchor = 0

    /// Feeds the next stretch of the ADTS stream. `pts` is the unwrapped timestamp that
    /// applies to the first frame starting within `bytes`, if the container supplied one.
    mutating func append(_ bytes: Data, pts: Int64?) {
        if let pts {
            anchors.append((buffer.count, pts))
        }
        buffer.append(contentsOf: bytes)

        var position = 0
        while position + 7 <= buffer.count {
            guard let header = ADTSHeader(buffer, at: position) else {
                position += 1
                continue
            }
            guard position + header.frameLength <= buffer.count else { break }

            while let anchor = anchors.first, anchor.offset <= position {
                anchorPTS = anchor.pts
                framesSinceAnchor = 0
                anchors.removeFirst()
            }
            if let anchorPTS {
                let rate = Int64(header.config.sampleRate)
                let elapsed = (Int64(framesSinceAnchor) * Int64(AACConfig.samplesPerFrame) * 90000 + rate / 2) / rate
                let payload = buffer[(position + header.headerLength)..<(position + header.frameLength)]
                frames.append(AudioFrame(pts: anchorPTS + elapsed, data: Data(payload), config: header.config))
                framesSinceAnchor += 1
            }
            position += header.frameLength
        }

        buffer.removeFirst(position)
        anchors = anchors.map { (max(0, $0.offset - position), $0.pts) }
    }
}

/// The fixed part of an ADTS frame header.
struct ADTSHeader {
    var config: AACConfig
    /// 7 bytes, or 9 when a CRC follows the header.
    var headerLength: Int
    /// Header plus payload.
    var frameLength: Int

    init?(_ bytes: [UInt8], at index: Int) {
        guard index + 7 <= bytes.count else { return nil }
        // Twelve sync bits, then MPEG version (1 bit), layer (2 bits, always 0 for AAC) and
        // the "no CRC" flag.
        guard bytes[index] == 0xFF, bytes[index + 1] & 0xF6 == 0xF0 else { return nil }
        let hasCRC = bytes[index + 1] & 0x01 == 0
        let objectType = Int(bytes[index + 2] >> 6) + 1
        let rateIndex = Int(bytes[index + 2] >> 2 & 0x0F)
        let channels = Int(bytes[index + 2] & 0x01) << 2 | Int(bytes[index + 3] >> 6)
        let length = Int(bytes[index + 3] & 0x03) << 11 | Int(bytes[index + 4]) << 3 | Int(bytes[index + 5] >> 5)
        guard rateIndex < AACConfig.sampleRates.count else { return nil }
        headerLength = hasCRC ? 9 : 7
        guard length > headerLength else { return nil }
        frameLength = length
        config = AACConfig(objectType: objectType, sampleRate: AACConfig.sampleRates[rateIndex], channelConfiguration: channels)
    }
}

/// HLS "packed audio": a segment that is nothing but ADTS frames, with an ID3 tag in front
/// whose `PRIV` frame gives the first frame's timestamp on the same 90 kHz clock the video
/// rendition's transport stream uses.
enum PackedAudio {

    static let timestampOwner = "com.apple.streaming.transportStreamTimestamp"

    static func matches(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(10))
        if head.starts(with: [0x49, 0x44, 0x33]) { return true }
        return ADTSHeader(head, at: 0) != nil
    }

    static func frames(in data: Data, unwrapper: inout TimestampUnwrapper) throws -> [AudioFrame] {
        let bytes = [UInt8](data)
        var position = 0
        var timestamp: Int64?
        while let tag = ID3Tag(bytes, at: position) {
            timestamp = timestamp ?? tag.transportStreamTimestamp
            position += tag.length
        }
        guard let timestamp else {
            throw ClipError.unsupportedMedia("packed audio without a timestamp tag")
        }
        guard ADTSHeader(bytes, at: position) != nil else {
            throw ClipError.unsupportedMedia("packed audio that is not ADTS AAC")
        }
        var parser = ADTSParser()
        parser.append(Data(bytes[position...]), pts: unwrapper.unwrap(timestamp))
        return parser.frames
    }
}

/// Just enough ID3v2 to step over a tag and read the HLS timestamp out of it.
struct ID3Tag {
    /// Total size of the tag including its header (and footer, if flagged).
    var length: Int
    /// The 33-bit, 90 kHz value of the `PRIV` frame owned by
    /// `com.apple.streaming.transportStreamTimestamp`, if the tag has one.
    var transportStreamTimestamp: Int64?

    init?(_ bytes: [UInt8], at index: Int) {
        guard index + 10 <= bytes.count, bytes[index] == 0x49, bytes[index + 1] == 0x44, bytes[index + 2] == 0x33 else {
            return nil
        }
        let version = bytes[index + 3]
        let hasFooter = bytes[index + 5] & 0x10 != 0
        let size = Self.synchsafe(bytes, at: index + 6)
        length = 10 + size + (hasFooter ? 10 : 0)
        let end = min(index + 10 + size, bytes.count)

        var position = index + 10
        while position + 10 <= end {
            let identifier = bytes[position..<(position + 4)]
            // Frame sizes are synchsafe in ID3v2.4 and plain big-endian in v2.3.
            let frameSize = version >= 4
                ? Self.synchsafe(bytes, at: position + 4)
                : Int(bytes[position + 4]) << 24 | Int(bytes[position + 5]) << 16 | Int(bytes[position + 6]) << 8 | Int(bytes[position + 7])
            let body = position + 10
            guard frameSize > 0, body + frameSize <= end else { break }
            if identifier.elementsEqual([0x50, 0x52, 0x49, 0x56]) {
                let owner = Array(PackedAudio.timestampOwner.utf8)
                let payload = bytes[body..<(body + frameSize)]
                if payload.starts(with: owner), payload.count >= owner.count + 9 {
                    let value = payload.suffix(8).reduce(Int64(0)) { $0 << 8 | Int64($1) }
                    transportStreamTimestamp = value & 0x1_FFFF_FFFF
                }
            }
            position = body + frameSize
        }
    }

    private static func synchsafe(_ bytes: [UInt8], at index: Int) -> Int {
        Int(bytes[index] & 0x7F) << 21 | Int(bytes[index + 1] & 0x7F) << 14 | Int(bytes[index + 2] & 0x7F) << 7 | Int(bytes[index + 3] & 0x7F)
    }
}
