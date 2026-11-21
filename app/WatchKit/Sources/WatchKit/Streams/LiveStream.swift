import AVFoundation
import Foundation
import WatchCore
import WatchProtocol

/// One channel playing live: its player, and the loop that keeps it playing.
@MainActor
@Observable
public final class LiveStream: Identifiable {
    public enum Status: Equatable {
        case loading
        case playing
        case failed(String)
    }

    public let channel: Channel
    public let player = AVPlayer()

    public private(set) var status: Status = .loading

    /// The stream's HLS master playlist, once it has been found. The clip
    /// editor reads the last couple of minutes from it.
    public private(set) var url: URL?

    public var isMuted = true {
        didSet { player.isMuted = isMuted }
    }

    /// False while the stream is hidden behind a zoomed-in tile. Hidden
    /// streams stay loaded but paused.
    public private(set) var isActive = true

    public nonisolated var id: String { channel.id }

    private var statusObservation: NSKeyValueObservation?
    private var notifications: [any NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var isStopped = false

    /// YouTube's manifests expire after ~6 h; re-resolve well before that.
    private let refreshInterval: TimeInterval = 4 * 60 * 60
    private let maxRetryDelay: TimeInterval = 10 * 60

    /// Starts at the site's base delay and doubles with each failure in a row,
    /// so a rate-limited or offline channel stops hammering the site.
    private var retryDelay: TimeInterval {
        let base = channel.site.retryDelay
        return min(base * pow(2, Double(max(consecutiveFailures - 1, 0))), maxRetryDelay)
    }

    public init(channel: Channel) {
        self.channel = channel
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
        player.preventsDisplaySleepDuringVideoPlayback = true
        load()
    }

    /// Pauses a hidden stream, or resumes one coming back into view. Resuming
    /// jumps to the live edge rather than picking up where it paused.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            resumeAtLiveEdge()
        } else {
            player.pause()
        }
    }

    private func resumeAtLiveEdge() {
        if let live = player.currentItem?.seekableTimeRanges.last?.timeRangeValue,
           live.duration.seconds > 0 {
            player.seek(to: live.end)
        }
        player.play()
    }

    /// Stops playback and the resolve/refresh loop for good. Call before
    /// dropping the stream.
    public func stop() {
        isStopped = true
        refreshTask?.cancel()
        refreshTask = nil
        stopObserving()
        player.replaceCurrentItem(with: nil)
    }

    /// Finds the stream again from scratch, as when a channel has just gone
    /// live.
    public func load() {
        guard !isStopped else { return }
        refreshTask?.cancel()
        status = .loading
        refreshTask = Task { [weak self, channel, refreshInterval] in
            do {
                let url = try await StreamResolver.resolve(channel)
                guard !Task.isCancelled, let self else { return }
                play(url)
                try await Task.sleep(for: .seconds(refreshInterval))
                load()
            } catch is CancellationError {
                // reload requested; nothing to do
            } catch {
                guard let self else { return }
                consecutiveFailures += 1
                status = .failed(error.localizedDescription)
                try? await Task.sleep(for: .seconds(retryDelay))
                guard !Task.isCancelled else { return }
                load()
            }
        }
    }

    private func play(_ url: URL) {
        stopObserving()
        self.url = url

        let item = AVPlayerItem(url: url)
        // Keep latency down for live content.
        item.preferredForwardBufferDuration = 2

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let message = item.error?.localizedDescription
            Task { @MainActor in
                self?.itemStatusChanged(status, message: message)
            }
        }

        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.failAndRetry("Stream ended")
            }
        })
        notifications.append(center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isActive else { return }
                self.player.play()
            }
        })

        player.replaceCurrentItem(with: item)
        if isActive { player.play() }
    }

    private func itemStatusChanged(_ itemStatus: AVPlayerItem.Status, message: String?) {
        switch itemStatus {
        case .readyToPlay:
            status = .playing
            consecutiveFailures = 0
        case .failed:
            failAndRetry(message ?? "Playback failed")
        default:
            break
        }
    }

    private func failAndRetry(_ message: String) {
        guard !isStopped else { return }
        consecutiveFailures += 1
        status = .failed(message)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let delay = self?.retryDelay else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }

    private func stopObserving() {
        statusObservation = nil
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
    }
}
