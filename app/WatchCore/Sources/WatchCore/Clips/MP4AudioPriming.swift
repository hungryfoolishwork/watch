import Foundation

/// Rewrites the audio timing of an MP4 written by AVAssetWriter so that every player places
/// the sound where Apple's players do.
///
/// An AAC decoder's first output is unusable, so a player has to decode a little audio it
/// doesn't play ("priming") before the point where sound should begin. MP4 has two ways of
/// saying how much:
///
/// - The old QuickTime convention, which AVAssetWriter still follows when given compressed
///   audio: nothing is written down, the reader assumes the first 2112 decoded samples of
///   the track are priming, and the track's edit list is offset to match. Apple's frameworks
///   read this correctly.
/// - The ISO way: a `roll` sample group in the track says that decoding must begin one
///   packet early, and the edit list points at the exact first sample to be heard. ffmpeg,
///   and everything built on it, assumes this reading whether or not the group is present.
///
/// A file in the first form therefore plays with its sound 2112 samples (48 ms at 44.1 kHz)
/// late in ffmpeg-based players, browsers and most upload pipelines. Converting it to the
/// second form, which Apple's frameworks also honor, takes two small changes to the file's
/// index: move the audio edit 2112 samples later, and add the sample group. The media data
/// is not touched.
enum MP4AudioPriming {

    /// The implicit priming Apple's readers assume for AAC, in samples.
    static let implicitPriming: Int64 = 2112

    /// Writes a copy of the MP4 at `source` to `destination` with explicit audio priming.
    ///
    /// Returns false, writing nothing, when the file has no audio track that needs the
    /// change (no AAC audio, a `roll` group already present, or an index laid out in a way
    /// this code doesn't recognize), in which case the source is already as good as it gets.
    static func makeExplicit(from source: URL, to destination: URL) throws -> Bool {
        let file = try Data(contentsOf: source, options: .mappedIfSafe)

        var position = 0
        var moovRange: Range<Int>?
        var mediaDataOffset: Int?
        while let box = BoxHeader(file, at: position, limit: file.count) {
            if box.type == "moov" { moovRange = position..<(position + box.size) }
            if box.type == "mdat", mediaDataOffset == nil { mediaDataOffset = position }
            position += box.size
        }
        guard let moovRange, var moov = Box(file, at: moovRange.lowerBound, limit: moovRange.upperBound) else {
            return false
        }

        var changed = false
        for index in moov.children.indices where moov.children[index].type == "trak" {
            if makeExplicit(track: &moov.children[index]) { changed = true }
        }
        guard changed else { return false }

        // The index grew, so if the media data comes after it, every recorded chunk position
        // has moved by the same amount.
        let growth = moov.serializedSize - moovRange.count
        if let mediaDataOffset, mediaDataOffset > moovRange.lowerBound {
            moov.shiftChunkOffsets(by: growth)
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: file[..<moovRange.lowerBound])
        try handle.write(contentsOf: moov.serialized())
        try handle.write(contentsOf: file[moovRange.upperBound...])
        return true
    }

    /// Applies the change to one `trak` box. Returns false if the track isn't AAC audio in
    /// the old form.
    private static func makeExplicit(track: inout Box) -> Bool {
        guard let media = track.child("mdia"),
              media.child("hdlr")?.payload.dropFirst(8).prefix(4).elementsEqual("soun".utf8) == true,
              let table = media.child("minf")?.child("stbl"),
              let description = table.child("stsd")?.payload, description.count >= 16,
              description.dropFirst(12).prefix(4).elementsEqual("mp4a".utf8),
              let sizes = table.child("stsz")?.payload, sizes.count >= 12,
              !table.children.contains(where: { $0.type == "sgpd" && $0.payload.dropFirst(4).prefix(4).elementsEqual("roll".utf8) }),
              var edits = track.child("edts")?.child("elst")?.payload, edits.count >= 8
        else { return false }

        // Edit list entries are (duration, media time, rate), with 64-bit times in version 1.
        // A media time of -1 marks an empty edit and stays as it is.
        let wide = edits[edits.startIndex] == 1
        let count = Int(edits.readUInt32(at: 4))
        let entrySize = wide ? 20 : 12
        guard count > 0, edits.count >= 8 + count * entrySize else { return false }
        for entry in 0..<count {
            let offset = 8 + entry * entrySize + (wide ? 8 : 4)
            if wide {
                let time = Int64(bitPattern: edits.readUInt64(at: offset))
                if time >= 0 { edits.writeUInt64(UInt64(time + implicitPriming), at: offset) }
            } else {
                let time = Int32(bitPattern: edits.readUInt32(at: offset))
                if time >= 0 { edits.writeUInt32(UInt32(Int64(time) + implicitPriming), at: offset) }
            }
        }

        let sampleCount = sizes.readUInt32(at: 8)
        // `sgpd` version 1: one description of two bytes, a roll distance of -1 ("start
        // decoding one sample early"). `sbgp`: all samples belong to description 1.
        var group = Data([1, 0, 0, 0])
        group.append(contentsOf: "roll".utf8)
        group.appendUInt32(2)
        group.appendUInt32(1)
        group.append(contentsOf: [0xFF, 0xFF])
        var assignment = Data([0, 0, 0, 0])
        assignment.append(contentsOf: "roll".utf8)
        assignment.appendUInt32(1)
        assignment.appendUInt32(sampleCount)
        assignment.appendUInt32(1)

        track.modify(["edts", "elst"]) { $0.payload = edits }
        track.modify(["mdia", "minf", "stbl"]) { table in
            table.children.append(Box(type: "sgpd", payload: group))
            table.children.append(Box(type: "sbgp", payload: assignment))
        }
        return true
    }

    /// The size and type at the start of a box.
    private struct BoxHeader {
        var type: String
        var size: Int
        var headerSize: Int

        init?(_ data: Data, at offset: Int, limit: Int) {
            guard offset + 8 <= limit else { return nil }
            let declared = Int(data.readUInt32(at: offset))
            type = String(decoding: data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 8)], as: UTF8.self)
            headerSize = 8
            switch declared {
            case 0:
                size = limit - offset
            case 1:
                guard offset + 16 <= limit else { return nil }
                size = Int(data.readUInt64(at: offset + 8))
                headerSize = 16
            default:
                size = declared
            }
            guard size >= headerSize, offset + size <= limit else { return nil }
        }
    }

    /// A box held in memory: either a container with child boxes or a leaf with a payload.
    /// Only the containers on the way to the tables this code edits are opened up.
    private struct Box {
        static let containers: Set<String> = ["moov", "trak", "edts", "mdia", "minf", "stbl"]

        var type: String
        var payload = Data()
        var children: [Box] = []

        init(type: String, payload: Data) {
            self.type = type
            self.payload = payload
        }

        init?(_ data: Data, at offset: Int, limit: Int) {
            // Boxes inside the index never need the 16-byte header form, and writing them
            // back assumes the 8-byte one.
            guard let header = BoxHeader(data, at: offset, limit: limit), header.headerSize == 8 else { return nil }
            type = header.type
            let end = offset + header.size
            if Self.containers.contains(type) {
                var position = offset + header.headerSize
                while position < end {
                    guard let child = Box(data, at: position, limit: end) else { return nil }
                    children.append(child)
                    position += child.originalSize
                }
            } else {
                payload = Data(data[(data.startIndex + offset + header.headerSize)..<(data.startIndex + end)])
            }
            originalSize = header.size
        }

        private var originalSize = 0

        var serializedSize: Int {
            8 + (Self.containers.contains(type) ? children.reduce(0) { $0 + $1.serializedSize } : payload.count)
        }

        func serialized() -> Data {
            var data = Data(capacity: serializedSize)
            data.appendUInt32(UInt32(serializedSize))
            data.append(contentsOf: type.utf8)
            if Self.containers.contains(type) {
                for child in children { data.append(child.serialized()) }
            } else {
                data.append(payload)
            }
            return data
        }

        func child(_ type: String) -> Box? {
            children.first { $0.type == type }
        }

        /// Applies `change` to the first descendant found by following `path`.
        mutating func modify(_ path: [String], _ change: (inout Box) -> Void) {
            guard let next = path.first else { return change(&self) }
            guard let index = children.firstIndex(where: { $0.type == next }) else { return }
            children[index].modify(Array(path.dropFirst()), change)
        }

        /// Adds `delta` to every entry of every chunk offset table (`stco` is 32-bit, `co64`
        /// 64-bit) beneath this box.
        mutating func shiftChunkOffsets(by delta: Int) {
            for index in children.indices {
                children[index].shiftChunkOffsets(by: delta)
            }
            guard type == "stco" || type == "co64", payload.count >= 8 else { return }
            let count = Int(payload.readUInt32(at: 4))
            for entry in 0..<count {
                if type == "stco", payload.count >= 8 + (entry + 1) * 4 {
                    let offset = 8 + entry * 4
                    payload.writeUInt32(UInt32(Int(payload.readUInt32(at: offset)) + delta), at: offset)
                } else if type == "co64", payload.count >= 8 + (entry + 1) * 8 {
                    let offset = 8 + entry * 8
                    payload.writeUInt64(UInt64(Int(payload.readUInt64(at: offset)) + delta), at: offset)
                }
            }
        }
    }
}

extension Data {

    fileprivate func readUInt32(at offset: Int) -> UInt32 {
        self[(startIndex + offset)..<(startIndex + offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    fileprivate func readUInt64(at offset: Int) -> UInt64 {
        self[(startIndex + offset)..<(startIndex + offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }

    fileprivate mutating func writeUInt32(_ value: UInt32, at offset: Int) {
        for byte in 0..<4 {
            self[startIndex + offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * (3 - UInt32(byte))))
        }
    }

    fileprivate mutating func writeUInt64(_ value: UInt64, at offset: Int) {
        for byte in 0..<8 {
            self[startIndex + offset + byte] = UInt8(truncatingIfNeeded: value >> (8 * (7 - UInt64(byte))))
        }
    }

    fileprivate mutating func appendUInt32(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
