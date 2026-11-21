import AVFoundation
import CoreMedia
import Foundation

/// One compressed sample bound for the output file, with times on the snapshot timeline.
struct ClipSample: Sendable {
    var pts: CMTime
    var dts: CMTime
    var duration: CMTime
    /// False for pictures that depend on earlier ones. Always true for audio.
    var isSync: Bool
    var data: Data
    /// Index into the owning track's `formats`.
    var format: Int
}

/// The samples of one output track, in decode order, plus the sample descriptions they use.
struct ClipTrack: Sendable {
    var mediaType: AVMediaType
    var formats: [CMFormatDescription]
    var samples: [ClipSample]
}

/// Writes already-compressed samples into an MP4 file without touching their contents.
enum ClipWriter {

    /// Writes the tracks to `url` so that the file presents exactly `start..<end` of the
    /// samples' timeline, beginning at time zero.
    ///
    /// The tracks usually hold a little more than that range: video has to begin at a
    /// keyframe, which is rarely where the user put the in point, and trailing B-frame
    /// references may extend past the out point. AVAssetWriter stores all of it and writes
    /// an edit list that hides everything outside the session's start and end times, which
    /// is what makes the cut frame-accurate without re-encoding.
    static func write(video: ClipTrack?, audio: ClipTrack?, start: CMTime, end: CMTime, to url: URL) async throws {
        let tracks = [video, audio].compactMap { $0 }.filter { !$0.samples.isEmpty && !$0.formats.isEmpty }
        guard !tracks.isEmpty else { throw ClipError.noSamples }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Puts the index at the front of the file so it starts playing before it has fully
        // downloaded wherever it ends up being shared.
        writer.shouldOptimizeForNetworkUse = true
        // The edit list is expressed in the movie time scale. The default of 600 would round
        // each track's in point to a different 1/600 s; 90 kHz keeps them exact.
        writer.movieTimeScale = 90000

        var feeds: [(track: ClipTrack, input: AVAssetWriterInput, next: Int)] = []
        for track in tracks {
            // Passing no output settings means passthrough; MP4 then needs the format up front.
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: track.formats[0])
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video {
                input.mediaTimeScale = 90000
            }
            guard writer.canAdd(input) else {
                throw ClipError.writeFailed("the file can't hold a \(track.mediaType.rawValue) track in this format")
            }
            writer.add(input)
            feeds.append((track, input, 0))
        }

        guard writer.startWriting() else {
            throw failure(writer, otherwise: "could not start writing")
        }
        writer.startSession(atSourceTime: start)

        do {
            // The writer interleaves the tracks and stops accepting samples for one that has
            // run ahead of the other, so always offer the track that is furthest behind and
            // fall back to the other when that one is momentarily full.
            while true {
                try Task.checkCancellation()
                let pending = feeds.indices
                    .filter { feeds[$0].next < feeds[$0].track.samples.count }
                    .sorted { feeds[$0].track.samples[feeds[$0].next].dts < feeds[$1].track.samples[feeds[$1].next].dts }
                guard !pending.isEmpty else { break }

                if let index = pending.first(where: { feeds[$0].input.isReadyForMoreMediaData }) {
                    let track = feeds[index].track
                    let sample = track.samples[feeds[index].next]
                    let buffer = try sampleBuffer(for: sample, format: track.formats[sample.format])
                    guard feeds[index].input.append(buffer) else {
                        throw failure(writer, otherwise: "a sample was rejected")
                    }
                    feeds[index].next += 1
                    // Finish a track the moment it runs out. Until then the writer keeps the
                    // other track waiting for samples that will never come.
                    if feeds[index].next == track.samples.count {
                        feeds[index].input.markAsFinished()
                    }
                } else {
                    guard writer.status == .writing else {
                        throw failure(writer, otherwise: "the writer stopped")
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }

        writer.endSession(atSourceTime: end)
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw failure(writer, otherwise: "the file was not completed")
        }
    }

    /// Describes why the writer failed. AVFoundation's localized description is usually just
    /// "The operation could not be completed", so the underlying error's domain and code,
    /// which are what identify the cause, are included.
    private static func failure(_ writer: AVAssetWriter, otherwise fallback: String) -> ClipError {
        guard let error = writer.error as NSError? else { return .writeFailed(fallback) }
        let cause = (error.userInfo[NSUnderlyingErrorKey] as? NSError) ?? error
        let reason = error.localizedFailureReason.map { ", \($0)" } ?? ""
        return .writeFailed("\(error.localizedDescription)\(reason) [\(cause.domain) \(cause.code)]")
    }

    /// Wraps one sample's bytes and timing in a CMSampleBuffer.
    static func sampleBuffer(for sample: ClipSample, format: CMFormatDescription) throws -> CMSampleBuffer {
        let block = try CMBlockBuffer(length: sample.data.count)
        try sample.data.withUnsafeBytes { try block.replaceDataBytes(with: $0) }

        let timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: sample.pts, decodeTimeStamp: sample.dts)
        let buffer = try CMSampleBuffer(
            dataBuffer: block,
            formatDescription: format,
            numSamples: 1,
            sampleTimings: [timing],
            sampleSizes: [sample.data.count]
        )
        if !sample.isSync, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return buffer
    }
}

extension H264ParameterSets {

    /// The `avc1` sample description for pictures coded with these parameter sets.
    func formatDescription() throws -> CMFormatDescription {
        try CMFormatDescription(h264ParameterSets: sps + pps, nalUnitHeaderLength: 4)
    }
}

extension AACConfig {

    /// The `mp4a` sample description for this audio.
    ///
    /// The magic cookie has to be a complete MPEG-4 ES_Descriptor: the writer copies it into
    /// the file's `esds` box as it is. Leave it out and the file has no `esds` at all, which
    /// AVFoundation tolerates but most other players don't.
    func formatDescription() throws -> CMFormatDescription {
        // Channel configuration 7 means 7.1; every other value is its own channel count.
        let channels = channelConfiguration == 7 ? 8 : channelConfiguration
        let description = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: UInt32(objectType),
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(AACConfig.samplesPerFrame),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        return try CMFormatDescription(audioStreamBasicDescription: description, magicCookie: elementaryStreamDescriptor)
    }

    /// The ES_Descriptor wrapping `audioSpecificConfig`: stream 0, object type 0x40 (MPEG-4
    /// audio), stream type 5 (audio), with the buffer size and bitrates left unspecified.
    var elementaryStreamDescriptor: Data {
        let config = audioSpecificConfig
        var decoderConfig = Data([0x40, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        decoderConfig.append(contentsOf: [0x05, UInt8(config.count)])
        decoderConfig.append(config)

        var descriptor = Data([0x00, 0x00, 0x00])
        descriptor.append(contentsOf: [0x04, UInt8(decoderConfig.count)])
        descriptor.append(decoderConfig)
        descriptor.append(contentsOf: [0x06, 0x01, 0x02])
        return Data([0x03, UInt8(descriptor.count)]) + descriptor
    }
}
