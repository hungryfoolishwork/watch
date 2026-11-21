import AVFoundation
import CoreMedia
import Foundation

/// Makes compressed frames of silence, used to pad holes in a stream's audio.
enum AACSilence {

    /// One raw AAC-LC frame (1024 samples) of silence for the given layout, or nil if the
    /// system encoder won't produce one.
    ///
    /// The frame comes from encoding a short run of digital silence and keeping the last
    /// packet, by which point the encoder has settled into its steady state. AAC-LC frames
    /// don't depend on their neighbors' bits, so the result can be spliced between frames
    /// from any other encoder with the same sample rate and channel count.
    static func frame(sampleRate: Double, channels: Int) -> Data? {
        guard let pcm = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else {
            return nil
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let packets: AVAudioPacketCount = 8
        guard let aac = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: pcm, to: aac),
              let input = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024 * packets)
        else { return nil }
        // A fresh PCM buffer is zero-filled, which is the silence to encode.
        input.frameLength = input.frameCapacity

        let output = AVAudioCompressedBuffer(format: aac, packetCapacity: packets, maximumPacketSize: converter.maximumOutputPacketSize)
        let supplied = SuppliedFlag()
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied.value {
                status.pointee = .endOfStream
                return nil
            }
            supplied.value = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.packetCount > 2, let descriptions = output.packetDescriptions else { return nil }

        let last = descriptions[Int(output.packetCount) - 1]
        guard last.mDataByteSize > 0 else { return nil }
        return Data(bytes: output.data + Int(last.mStartOffset), count: Int(last.mDataByteSize))
    }

    /// Whether the converter's input block has handed over its one buffer yet. The block is
    /// only ever called synchronously from within `convert`.
    private final class SuppliedFlag: @unchecked Sendable {
        var value = false
    }
}

extension ClipTrack {

    /// Pads holes in an AAC track with frames of silence.
    ///
    /// AVAssetWriter in passthrough mode places each audio packet directly after the one
    /// before it, whatever their timestamps say. A hole in the stream's audio (typically
    /// where an ad was spliced in and the segment before it ended a little short) would
    /// therefore pull everything after it earlier and out of sync with the picture. Filling
    /// the hole with the right number of silent frames keeps later audio where it belongs.
    ///
    /// Position is tracked by adding up what has actually been written rather than by each
    /// sample's own timestamp, so rounding a hole to whole frames never accumulates.
    func fillingAudioGaps() -> ClipTrack {
        guard mediaType == .audio, let first = samples.first else { return self }

        var result = self
        result.samples.removeAll(keepingCapacity: true)
        var cursor = first.pts
        var silence: [Int: Data?] = [:]

        for sample in samples {
            let hole = (sample.pts - cursor).seconds
            let length = sample.duration.seconds
            // Cap the padding at a minute so a nonsense timestamp can't balloon the file.
            let missing = length > 0 ? Int((hole / length).rounded()) : 0
            if missing >= 1, missing < Int(60 / length) {
                if silence[sample.format] == nil {
                    silence[sample.format] = formats[sample.format].audioStreamBasicDescription.flatMap { description in
                        description.mFormatID == kAudioFormatMPEG4AAC
                            ? AACSilence.frame(sampleRate: description.mSampleRate, channels: Int(description.mChannelsPerFrame))
                            : nil
                    }
                }
                // Without an encoder, repeating the neighboring frame still keeps sync, at
                // the cost of a brief stutter instead of silence.
                let filler = (silence[sample.format] ?? nil) ?? sample.data
                for _ in 0..<missing {
                    result.samples.append(ClipSample(pts: cursor, dts: cursor, duration: sample.duration, isSync: true, data: filler, format: sample.format))
                    cursor = cursor + sample.duration
                }
            }
            var placed = sample
            placed.pts = cursor
            placed.dts = cursor
            result.samples.append(placed)
            cursor = cursor + sample.duration
        }
        return result
    }
}
