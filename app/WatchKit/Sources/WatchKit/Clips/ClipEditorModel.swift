import AVFoundation
import SwiftUI
import VideoToolbox
import WatchCore
import WatchProtocol

/// What the clip editor is working on: a frozen copy of a stream's last
/// couple of minutes, the stretch of it that's been picked out, and a player
/// to look it over with.
///
/// Times are seconds from the start of the frozen stretch, so `duration` is
/// "now" as of when the editor opened.
@MainActor
@Observable
final class ClipEditorModel {
    enum Phase: Equatable {
        case capturing
        case ready
        case saving(Double)
        case failed(String)
    }

    /// How far back the editor reaches.
    static let reach: TimeInterval = 120
    static let thumbnailCount = 12
    private static let defaultLength: TimeInterval = 30
    private static let minimumLength: TimeInterval = 1

    let channel: Channel
    let player = AVPlayer()
    /// The layer the preview shows.
    let layer = AVPlayerLayer()
    var name: String

    private(set) var phase: Phase = .capturing
    private(set) var duration: TimeInterval = 0
    /// Where the clip starts and ends.
    private(set) var start: TimeInterval = 0
    private(set) var end: TimeInterval = 0
    private(set) var playhead: TimeInterval = 0
    private(set) var isPlaying = false
    private(set) var thumbnails: [CGImage?] = Array(repeating: nil, count: thumbnailCount)
    /// Why the last save didn't work, if it didn't.
    private(set) var saveError: String?

    private var snapshot: LiveSnapshot?
    private var playback: SnapshotPlayback?
    private var timeObserver: Any?
    private var thumbnailTask: Task<Void, Never>?

    /// The newest place a drag has asked the player to show. Seeks are slow
    /// next to a moving cursor, so only one runs at a time and it chases this.
    private var seekTarget: TimeInterval?
    private var isSeeking = false

    var length: TimeInterval { end - start }

    init(channel: Channel, now: Date = .now) {
        self.channel = channel
        // The system puts a narrow no-break space before AM and PM, which is
        // no fun in a file name.
        let time = now.formatted(date: .omitted, time: .shortened).replacingOccurrences(of: "\u{202F}", with: " ")
        self.name = "\(channel.displayName), \(time)"
        layer.player = player
    }

    // MARK: - Capturing

    /// Freezes the last two minutes of the stream at `url`, or finds the
    /// stream first if it isn't known.
    func capture(from url: URL?) async {
        do {
            let master: URL
            if let url {
                master = url
            } else {
                master = try await StreamResolver.resolve(channel)
            }
            let snapshot = try await LiveSnapshot.capture(master: master, last: Self.reach)
            let playback = SnapshotPlayback(snapshot)
            self.snapshot = snapshot
            self.playback = playback

            duration = snapshot.duration
            end = duration
            start = max(0, duration - Self.defaultLength)
            playhead = start

            player.replaceCurrentItem(with: AVPlayerItem(asset: playback.asset))
            observe()
            show(start)
            phase = .ready

            thumbnailTask = Task { [weak self] in
                await self?.loadThumbnails(from: playback.asset)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Lets go of the player and anything still loading.
    func close() {
        thumbnailTask?.cancel()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func observe() {
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                self?.tick(seconds)
            }
        }
    }

    private func tick(_ seconds: TimeInterval) {
        guard isPlaying, seconds.isFinite else { return }
        if seconds >= end {
            pause()
            playhead = end
        } else {
            playhead = seconds
        }
    }

    // MARK: - Playing

    func playToggle() {
        guard phase == .ready else { return }
        if isPlaying {
            pause()
        } else {
            // Past the end of the clip, or before it: start it over.
            if playhead < start || playhead >= end - 0.1 {
                playhead = start
            }
            let time = CMTime(seconds: playhead, preferredTimescale: 600)
            isPlaying = true
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isPlaying else { return }
                    self.player.play()
                }
            }
        }
    }

    private func pause() {
        isPlaying = false
        player.pause()
    }

    // MARK: - Trimming

    func setStart(_ seconds: TimeInterval) {
        start = min(max(0, seconds), end - Self.minimumLength)
        scrub(to: start)
    }

    func setEnd(_ seconds: TimeInterval) {
        end = max(min(duration, seconds), start + Self.minimumLength)
        scrub(to: end)
    }

    /// Moves the playhead by hand and shows the frame there.
    func scrub(to seconds: TimeInterval) {
        pause()
        playhead = min(max(0, seconds), duration)
        show(playhead)
    }

    private func show(_ seconds: TimeInterval) {
        seekTarget = seconds
        chase()
    }

    private func chase() {
        guard !isSeeking, let target = seekTarget else { return }
        seekTarget = nil
        isSeeking = true
        // A little slack lets the player land on a nearby frame it already
        // has, which keeps dragging smooth.
        let slack = CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: slack, toleranceAfter: slack) { [weak self] _ in
            Task { @MainActor in
                self?.isSeeking = false
                self?.chase()
            }
        }
    }

    // MARK: - Saving

    /// Writes the picked-out stretch to a new file in the clips folder and
    /// returns where it went, or nil if that failed (see `saveError`).
    func save(to session: any WatchProtocol::Session) async -> URL? {
        guard let snapshot, phase == .ready else { return nil }
        pause()
        saveError = nil
        phase = .saving(0)
        do {
            let url = try session.clipReserve(name: name.trimmingCharacters(in: .whitespaces))
            try await ClipExporter.export(snapshot, range: start..<end, to: url) { [weak self] fraction in
                Task { @MainActor in
                    self?.saving(fraction)
                }
            }
            phase = .ready
            return url
        } catch {
            saveError = error.localizedDescription
            phase = .ready
            return nil
        }
    }

    private func saving(_ fraction: Double) {
        guard case .saving = phase else { return }
        phase = .saving(fraction)
    }

    // MARK: - Thumbnails

    /// Fills in the filmstrip one frame at a time, each from the middle of
    /// its slot.
    private func loadThumbnails(from asset: AVAsset) async {
        let thumbnailer = Thumbnailer(asset: asset)
        let slot = duration / Double(Self.thumbnailCount)
        for index in 0..<Self.thumbnailCount {
            guard !Task.isCancelled else { break }
            thumbnails[index] = await thumbnailer.image(at: (Double(index) + 0.5) * slot)
        }
        thumbnailer.close()
    }
}

/// Pulls still frames out of a stream. AVAssetImageGenerator can't read HLS,
/// so this plays the asset on a second, silent player and copies frames off
/// its video output.
@MainActor
private final class Thumbnailer {
    private let player = AVPlayer()
    private let item: AVPlayerItem
    private let output: AVPlayerItemVideoOutput

    /// Thumbnails are small; there's no reason to keep full frames around.
    private static let maxWidth = 320

    init(asset: AVAsset) {
        item = AVPlayerItem(asset: asset)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        player.isMuted = true
        player.replaceCurrentItem(with: item)
    }

    func close() {
        item.remove(output)
        player.replaceCurrentItem(with: nil)
    }

    func image(at seconds: TimeInterval) async -> CGImage? {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        // Any frame near the mark will do, and the nearest keyframe is the
        // quickest to get.
        guard await player.seek(to: time, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity) else {
            return nil
        }
        // The frame arrives a moment after the seek reports done.
        for _ in 0..<60 {
            let now = item.currentTime()
            if output.hasNewPixelBuffer(forItemTime: now),
               let buffer = output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) {
                return Self.thumbnail(buffer)
            }
            guard (try? await Task.sleep(for: .milliseconds(50))) != nil else { return nil }
        }
        return nil
    }

    private static func thumbnail(_ buffer: CVPixelBuffer) -> CGImage? {
        var full: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &full)
        guard let full, full.width > maxWidth else { return full }

        let height = full.height * maxWidth / full.width
        guard let context = CGContext(
            data: nil, width: maxWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return full }
        context.interpolationQuality = .medium
        context.draw(full, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return context.makeImage()
    }
}
