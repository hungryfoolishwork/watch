import Foundation

/// One reassembled PES packet: the unit an MPEG transport stream uses to carry a video
/// access unit or a run of audio frames, with its timestamps.
struct PESPacket: Sendable {
    var pid: Int
    /// The stream type the PMT declared for this PID (`0x1B` H.264, `0x0F` ADTS AAC, ...).
    var streamType: UInt8
    /// Raw 33-bit, 90 kHz presentation and decode timestamps as written in the stream, so
    /// they may have wrapped. A PES that only continues the previous one carries none.
    var pts: Int64?
    var dts: Int64?
    var payload: Data
}

/// Splits an MPEG transport stream into PES packets.
///
/// This reads just enough of the format for HLS segments: the PAT to find the PMT, the PMT
/// to learn which PIDs carry which stream types, and PES reassembly for those PIDs. Only
/// the first program is used. Continuity counters, PCR and scrambling are ignored.
enum MPEGTS {

    static let packetSize = 188

    enum StreamType {
        static let h264: UInt8 = 0x1B
        static let adtsAAC: UInt8 = 0x0F
        static let hevc: UInt8 = 0x24
        static let mpeg1Audio: UInt8 = 0x03
        static let mpeg2Audio: UInt8 = 0x04
        static let latmAAC: UInt8 = 0x11
        static let ac3: UInt8 = 0x81
        static let eac3: UInt8 = 0x87
    }

    /// Returns true when `data` looks like a transport stream: sync bytes one packet apart.
    static func matches(_ data: Data) -> Bool {
        syncOffset(in: data) != nil
    }

    /// The PES packets of every elementary stream the PMT lists, in the order they complete,
    /// along with the stream type the PMT declares for each PID (including PIDs that turned
    /// out to carry no packets).
    static func demux(_ data: Data) -> (packets: [PESPacket], streamTypes: [Int: UInt8]) {
        guard let start = syncOffset(in: data) else { return ([], [:]) }

        var result: [PESPacket] = []
        var pmtPID: Int?
        var streamTypes: [Int: UInt8] = [:]
        var sections: [Int: [UInt8]] = [:]
        var pending: [Int: [UInt8]] = [:]

        func flush(_ pid: Int) {
            guard let bytes = pending.removeValue(forKey: pid), let type = streamTypes[pid] else { return }
            if let packet = parsePES(bytes, pid: pid, streamType: type) {
                result.append(packet)
            }
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = start
            while offset + packetSize <= raw.count {
                guard raw[offset] == 0x47 else {
                    // Lost sync (a truncated or damaged packet): slide forward to the next one.
                    offset += 1
                    continue
                }
                let unitStart = raw[offset + 1] & 0x40 != 0
                let pid = Int(raw[offset + 1] & 0x1F) << 8 | Int(raw[offset + 2])
                let adaptation = (raw[offset + 3] >> 4) & 0x3
                var position = offset + 4
                let end = offset + packetSize
                offset = end

                if adaptation & 0x2 != 0 {
                    position += 1 + Int(raw[position])
                }
                guard adaptation & 0x1 != 0, position < end else { continue }
                let payload = UnsafeRawBufferPointer(rebasing: raw[position..<end])

                if pid == 0 || pid == pmtPID {
                    guard let section = assembleSection(payload, unitStart: unitStart, into: &sections[pid, default: []]) else { continue }
                    if pid == 0 {
                        pmtPID = pmtPID ?? parsePAT(section)
                    } else {
                        for (streamPID, type) in parsePMT(section) where streamTypes[streamPID] == nil {
                            streamTypes[streamPID] = type
                        }
                    }
                } else if streamTypes[pid] != nil {
                    if unitStart {
                        flush(pid)
                        pending[pid] = Array(payload)
                    } else {
                        pending[pid]?.append(contentsOf: payload)
                    }
                }
            }
        }

        for pid in pending.keys.sorted() {
            flush(pid)
        }
        return (result, streamTypes)
    }

    /// Finds the first offset where sync bytes repeat at the packet size, tolerating a little
    /// junk before the first packet.
    private static func syncOffset(in data: Data) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            let limit = min(raw.count, packetSize * 4)
            for offset in 0..<limit where raw[offset] == 0x47 {
                let next = offset + packetSize
                if next >= raw.count || raw[next] == 0x47 { return offset }
            }
            return nil
        }
    }

    /// Collects a PSI section, which starts after a pointer field in a packet with the unit
    /// start flag and may spill into following packets. Returns the section once complete.
    private static func assembleSection(_ payload: UnsafeRawBufferPointer, unitStart: Bool, into buffer: inout [UInt8]) -> [UInt8]? {
        if unitStart {
            guard let pointer = payload.first, 1 + Int(pointer) <= payload.count else { return nil }
            buffer = Array(payload[(1 + Int(pointer))...])
        } else if !buffer.isEmpty {
            buffer.append(contentsOf: payload)
        }
        guard buffer.count >= 3 else { return nil }
        let length = 3 + (Int(buffer[1] & 0x0F) << 8 | Int(buffer[2]))
        guard buffer.count >= length else { return nil }
        defer { buffer = [] }
        return Array(buffer[..<length])
    }

    /// Returns the PMT PID of the first real program (program 0 is the network table).
    private static func parsePAT(_ section: [UInt8]) -> Int? {
        guard section.count >= 12, section[0] == 0x00 else { return nil }
        var position = 8
        while position + 4 <= section.count - 4 {
            let program = Int(section[position]) << 8 | Int(section[position + 1])
            let pid = Int(section[position + 2] & 0x1F) << 8 | Int(section[position + 3])
            if program != 0 { return pid }
            position += 4
        }
        return nil
    }

    private static func parsePMT(_ section: [UInt8]) -> [(pid: Int, type: UInt8)] {
        guard section.count >= 16, section[0] == 0x02 else { return [] }
        let programInfoLength = Int(section[10] & 0x0F) << 8 | Int(section[11])
        var position = 12 + programInfoLength
        var streams: [(Int, UInt8)] = []
        while position + 5 <= section.count - 4 {
            let type = section[position]
            let pid = Int(section[position + 1] & 0x1F) << 8 | Int(section[position + 2])
            let infoLength = Int(section[position + 3] & 0x0F) << 8 | Int(section[position + 4])
            streams.append((pid, type))
            position += 5 + infoLength
        }
        return streams
    }

    private static func parsePES(_ bytes: [UInt8], pid: Int, streamType: UInt8) -> PESPacket? {
        guard bytes.count >= 9, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 else { return nil }
        let declaredLength = Int(bytes[4]) << 8 | Int(bytes[5])
        let flags = bytes[7]
        let headerLength = Int(bytes[8])
        let payloadStart = 9 + headerLength
        guard payloadStart <= bytes.count else { return nil }

        var pts: Int64?
        var dts: Int64?
        if flags & 0x80 != 0, headerLength >= 5 {
            pts = timestamp(bytes, at: 9)
        }
        if flags & 0x40 != 0, headerLength >= 10 {
            dts = timestamp(bytes, at: 14)
        }

        // A declared length of zero means "until the next unit start", which is the usual
        // case for video. A non-zero length can be shorter than what was collected only if
        // the stream is padded, so honor it.
        var payloadEnd = bytes.count
        if declaredLength != 0 {
            payloadEnd = min(payloadEnd, 6 + declaredLength)
        }
        guard payloadEnd >= payloadStart else { return nil }
        return PESPacket(pid: pid, streamType: streamType, pts: pts, dts: dts, payload: Data(bytes[payloadStart..<payloadEnd]))
    }

    /// Reads the 33-bit timestamp spread over five bytes with marker bits in between.
    private static func timestamp(_ bytes: [UInt8], at index: Int) -> Int64 {
        let b0 = Int64(bytes[index]), b1 = Int64(bytes[index + 1]), b2 = Int64(bytes[index + 2])
        let b3 = Int64(bytes[index + 3]), b4 = Int64(bytes[index + 4])
        return (b0 >> 1 & 0x07) << 30 | b1 << 22 | (b2 >> 1) << 15 | b3 << 7 | b4 >> 1
    }
}

/// Turns 33-bit MPEG timestamps, which wrap every 26.5 hours, into a monotonic 64-bit
/// timeline.
///
/// Each value is interpreted as the one closest to the previous value, so a wrap from
/// 2^33 - 1 to 0 continues upward, and a small step backward (B-frames, or audio read after
/// video) stays a small step backward. One unwrapper is shared by every stream of a
/// continuous stretch of the timeline, since their timestamps all sit within seconds of
/// each other.
struct TimestampUnwrapper: Sendable {

    private var last: Int64?

    mutating func unwrap(_ raw: Int64) -> Int64 {
        let modulus: Int64 = 1 << 33
        guard let last else {
            self.last = raw
            return raw
        }
        var delta = (raw - last) % modulus
        if delta >= modulus / 2 { delta -= modulus }
        if delta < -modulus / 2 { delta += modulus }
        let value = last + delta
        self.last = value
        return value
    }
}
