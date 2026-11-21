import Foundation

/// A parsed HLS playlist. A URL handed to the clip code may point at either kind, so parsing
/// decides which one it got: anything carrying `#EXTINF` is a media playlist, everything else
/// is treated as a master.
enum HLSPlaylist: Sendable, Equatable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)

    /// Parses playlist text. Relative URIs are resolved against `baseURL`, which should be the
    /// URL the playlist was fetched from.
    static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first?.hasPrefix("#EXTM3U") == true else {
            throw ClipError.invalidPlaylist("missing #EXTM3U header")
        }
        if lines.contains(where: { $0.hasPrefix("#EXTINF:") }) {
            return .media(try HLSMediaPlaylist(lines: lines, baseURL: baseURL))
        }
        return .master(HLSMasterPlaylist(lines: lines, baseURL: baseURL))
    }
}

/// The variant streams and alternate renditions listed by a master playlist.
struct HLSMasterPlaylist: Sendable, Equatable {

    struct Variant: Sendable, Equatable {
        var url: URL
        var bandwidth: Int
        var codecs: [String]
        var width: Int?
        var height: Int?
        var frameRate: Double?
        /// The `GROUP-ID` of the audio renditions this variant plays with, if it names one.
        var audioGroup: String?

        /// True when the codec list names a video codec other than H.264. An absent codec list
        /// counts as H.264, since that is what an unlabelled stream almost always is.
        var hasForeignVideoCodec: Bool {
            let video = codecs.filter { !$0.hasPrefix("mp4a") && !$0.hasPrefix("ac-3") && !$0.hasPrefix("ec-3") }
            return !video.isEmpty && !video.contains { $0.hasPrefix("avc1") || $0.hasPrefix("avc3") }
        }

        /// True when the variant's sound is AC-3 or E-AC-3, which plays but can't be exported.
        var hasDolbyAudio: Bool {
            codecs.contains { $0.hasPrefix("ac-3") || $0.hasPrefix("ec-3") }
        }

        /// True when the codec list is present and names only audio codecs.
        var isAudioOnly: Bool {
            !codecs.isEmpty && height == nil && codecs.allSatisfy { $0.hasPrefix("mp4a") || $0.hasPrefix("ac-3") || $0.hasPrefix("ec-3") }
        }
    }

    struct Rendition: Sendable, Equatable {
        var type: String
        var groupID: String
        var name: String
        var isDefault: Bool
        /// Absent when the rendition's media is carried inside the variant stream itself.
        var url: URL?
    }

    var variants: [Variant] = []
    var renditions: [Rendition] = []

    fileprivate init(lines: [String], baseURL: URL) {
        var pending: [String: String]?
        for line in lines {
            if let value = line.tagValue("#EXT-X-STREAM-INF") {
                pending = HLSAttributes.parse(value)
            } else if let value = line.tagValue("#EXT-X-MEDIA") {
                let attributes = HLSAttributes.parse(value)
                guard let type = attributes["TYPE"], let group = attributes["GROUP-ID"] else { continue }
                renditions.append(Rendition(
                    type: type,
                    groupID: group,
                    name: attributes["NAME"] ?? "",
                    isDefault: attributes["DEFAULT"] == "YES",
                    url: attributes["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                ))
            } else if !line.isEmpty, !line.hasPrefix("#"), let attributes = pending {
                pending = nil
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                let resolution = attributes["RESOLUTION"]?.split(separator: "x").compactMap { Int($0) } ?? []
                variants.append(Variant(
                    url: url,
                    bandwidth: attributes["BANDWIDTH"].flatMap { Int($0) } ?? 0,
                    codecs: attributes["CODECS"]?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
                    width: resolution.count == 2 ? resolution[0] : nil,
                    height: resolution.count == 2 ? resolution[1] : nil,
                    frameRate: attributes["FRAME-RATE"].flatMap { Double($0) },
                    audioGroup: attributes["AUDIO"]
                ))
            }
        }
    }

    /// Picks the variant to clip from: the tallest one that fits `maxHeight`, breaking ties
    /// by bandwidth (which also prefers 60 fps over 30 fps and AAC-LC over HE-AAC at the same
    /// size). H.264 variants win over other video codecs because the MPEG-TS demuxer only
    /// understands H.264, and audio-only variants are a last resort. When nothing fits the
    /// limit the shortest variant is used rather than failing.
    func selectVariant(maxHeight: Int) -> Variant? {
        let pools = [
            variants.filter { !$0.isAudioOnly && !$0.hasForeignVideoCodec },
            variants.filter { !$0.isAudioOnly },
            variants,
        ]
        guard let pool = pools.first(where: { !$0.isEmpty }) else { return nil }
        let fitting = pool.filter { ($0.height ?? 0) <= maxHeight }
        if fitting.isEmpty {
            return pool.min { ($0.height ?? 0, $0.hasDolbyAudio ? 1 : 0, $0.bandwidth) < ($1.height ?? 0, $1.hasDolbyAudio ? 1 : 0, $1.bandwidth) }
        }
        // At the same height, AAC sound beats Dolby whatever the bit rates.
        return fitting.max { ($0.height ?? 0, $0.hasDolbyAudio ? 0 : 1, $0.bandwidth) < ($1.height ?? 0, $1.hasDolbyAudio ? 0 : 1, $1.bandwidth) }
    }

    /// The separate audio playlist that accompanies `variant`, or nil when its audio is
    /// muxed into the variant's own segments (no audio group, or a group without a URI).
    func audioRendition(for variant: Variant) -> Rendition? {
        guard let group = variant.audioGroup else { return nil }
        let candidates = renditions.filter { $0.type == "AUDIO" && $0.groupID == group }
        guard let chosen = candidates.first(where: \.isDefault) ?? candidates.first else { return nil }
        return chosen.url == nil || chosen.url == variant.url ? nil : chosen
    }
}

/// The segment list of a media playlist, with the per-segment state that HLS spreads across
/// preceding tags (byte ranges, discontinuities, wall-clock dates, init sections, keys)
/// already resolved onto each segment.
struct HLSMediaPlaylist: Sendable, Equatable {

    struct ByteRange: Sendable, Equatable, Hashable {
        var offset: Int
        var length: Int
    }

    /// An `#EXT-X-MAP` initialization section, which marks the segments after it as
    /// fragmented MP4.
    struct Map: Sendable, Equatable, Hashable {
        var url: URL
        var byteRange: ByteRange?
    }

    struct Segment: Sendable, Equatable {
        var url: URL
        var duration: TimeInterval
        var byteRange: ByteRange?
        var mediaSequence: Int
        /// Counts the `#EXT-X-DISCONTINUITY` tags up to and including this segment, starting
        /// from `#EXT-X-DISCONTINUITY-SEQUENCE`. Segments sharing a value share a timestamp
        /// timeline; renditions of one stream use the same numbering.
        var discontinuitySequence: Int
        /// Wall-clock time of the segment's first sample. The tag usually appears only once
        /// per playlist or discontinuity, so later segments carry the date extrapolated from
        /// the segment durations in between.
        var programDateTime: Date?
        var map: Map?
        /// True when an `#EXT-X-KEY` with a method other than `NONE` applies.
        var isEncrypted: Bool
    }

    var targetDuration: TimeInterval = 0
    var segments: [Segment] = []
    var hasEndList = false

    fileprivate init(lines: [String], baseURL: URL) throws {
        var mediaSequence = 0
        var discontinuitySequence = 0
        var duration: TimeInterval?
        var byteRange: ByteRange?
        var nextRangeOffset: [URL: Int] = [:]
        var pendingRange: (length: Int, offset: Int?)?
        var date: Date?
        var map: Map?
        var isEncrypted = false

        for line in lines {
            if let value = line.tagValue("#EXTINF") {
                duration = Double(value.prefix { $0 != "," }.trimmingCharacters(in: .whitespaces))
            } else if let value = line.tagValue("#EXT-X-TARGETDURATION") {
                targetDuration = Double(value) ?? 0
            } else if let value = line.tagValue("#EXT-X-MEDIA-SEQUENCE") {
                mediaSequence = Int(value) ?? 0
            } else if let value = line.tagValue("#EXT-X-DISCONTINUITY-SEQUENCE") {
                discontinuitySequence = Int(value) ?? 0
            } else if line == "#EXT-X-DISCONTINUITY" {
                discontinuitySequence += 1
            } else if let value = line.tagValue("#EXT-X-PROGRAM-DATE-TIME") {
                date = HLSAttributes.date(value)
            } else if let value = line.tagValue("#EXT-X-BYTERANGE") {
                pendingRange = HLSAttributes.byteRange(value)
            } else if let value = line.tagValue("#EXT-X-MAP") {
                let attributes = HLSAttributes.parse(value)
                guard let uri = attributes["URI"], let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
                    throw ClipError.invalidPlaylist("#EXT-X-MAP without a usable URI")
                }
                let range = attributes["BYTERANGE"].flatMap(HLSAttributes.byteRange)
                map = Map(url: url, byteRange: range.map { ByteRange(offset: $0.offset ?? 0, length: $0.length) })
            } else if let value = line.tagValue("#EXT-X-KEY") {
                isEncrypted = (HLSAttributes.parse(value)["METHOD"] ?? "NONE") != "NONE"
            } else if line == "#EXT-X-ENDLIST" {
                hasEndList = true
            } else if !line.isEmpty, !line.hasPrefix("#"), let segmentDuration = duration {
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else {
                    throw ClipError.invalidPlaylist("unusable segment URI")
                }
                if let range = pendingRange {
                    // A range without an offset continues where the previous range of the
                    // same resource ended.
                    let offset = range.offset ?? nextRangeOffset[url] ?? 0
                    byteRange = ByteRange(offset: offset, length: range.length)
                    nextRangeOffset[url] = offset + range.length
                }
                segments.append(Segment(
                    url: url,
                    duration: segmentDuration,
                    byteRange: byteRange,
                    mediaSequence: mediaSequence,
                    discontinuitySequence: discontinuitySequence,
                    programDateTime: date,
                    map: map,
                    isEncrypted: isEncrypted
                ))
                mediaSequence += 1
                date = date?.addingTimeInterval(segmentDuration)
                duration = nil
                byteRange = nil
                pendingRange = nil
            }
        }
    }
}

enum HLSAttributes {

    /// Splits an attribute list such as `BANDWIDTH=1,CODECS="a,b"` into a dictionary. Quoted
    /// values may contain commas and are returned without their quotes.
    static func parse(_ list: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false
        func commit() {
            let name = key.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { result[name] = value }
            key = ""
            value = ""
            inKey = true
        }
        for character in list {
            if inKey {
                if character == "=" { inKey = false } else if character == "," { commit() } else { key.append(character) }
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == ",", !inQuotes {
                commit()
            } else {
                value.append(character)
            }
        }
        commit()
        return result
    }

    /// Parses `<length>[@<offset>]`.
    static func byteRange(_ value: String) -> (length: Int, offset: Int?)? {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard let first = parts.first, let length = Int(first.trimmingCharacters(in: .whitespaces)) else { return nil }
        return (length, parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil)
    }

    /// Parses an ISO 8601 date with or without fractional seconds.
    static func date(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: false))
    }
}

extension String {

    /// The text after `tag:` when the line is that tag, otherwise nil.
    fileprivate func tagValue(_ tag: String) -> String? {
        guard hasPrefix(tag), dropFirst(tag.count).first == ":" else { return nil }
        return String(dropFirst(tag.count + 1))
    }
}
