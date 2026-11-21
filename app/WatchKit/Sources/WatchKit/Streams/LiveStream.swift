import AVFoundation
import AVKit
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

    /// What Picture in Picture has to say about this stream.
    public enum PipEvent: Sendable {
        /// The picture is on its way out to the floating window.
        case began
        /// The floating window is gone, or never managed to open.
        case ended
        /// The floating window's return button was pressed: put this
        /// stream's tile back on screen for the picture to land on.
        case restore
        case failed(String)
    }

    public let channel: Channel
    public let player = AVPlayer()

    /// The layer the stream's tile shows. It belongs to the stream, not to
    /// the tile's view, because Picture in Picture is tied to a layer and
    /// carries on after the tile has left the screen.
    public let layer = AVPlayerLayer()

    /// Whether this stream is playing in the Picture in Picture window.
    public private(set) var isInPip = false

    /// Called as Picture in Picture starts, stops, fails, or asks for its
    /// tile back.
    public var onPip: (PipEvent) -> Void = { _ in }

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
    private var pip: AVPictureInPictureController?
    private var pipDelegate: PipDelegate?

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
        layer.player = player
        pipPrepare()
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
        pipStop()
        pip = nil
        pipDelegate = nil
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

    // MARK: - Picture in Picture

    /// Whether the picture can go out to the floating window right now.
    public var canPip: Bool {
        pip != nil && status == .playing
    }

    /// Sends the picture out to the system's floating window. The system
    /// shows one at a time, so this takes the place of any other.
    public func pipStart() {
        guard let pip, !pip.isPictureInPictureActive else { return }
        pip.startPictureInPicture()
    }

    /// Brings the picture back from the floating window. The system only
    /// does this while the layer is in a window, so if the tile is still on
    /// its way to the screen this waits a moment for it.
    public func pipStop() {
        guard let pip, pip.isPictureInPictureActive else { return }
        guard layer.superlayer == nil, !isStopped else {
            pip.stopPictureInPicture()
            return
        }
        Task { [weak self] in
            await self?.layerShown()
            self?.pip?.stopPictureInPicture()
        }
    }

    /// Waits, briefly, for the layer to be put in a view.
    private func layerShown() async {
        for _ in 0..<40 where layer.superlayer == nil {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The controller is made up front: it takes a moment after it's made
    /// before it will agree to start.
    private func pipPrepare() {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layer)
        else { return }
        let delegate = PipDelegate { [weak self] event in
            self?.pipChanged(event)
        } shown: { [weak self] in
            // The picture flies back to wherever the layer is on screen, so
            // give its tile a moment to be put there first.
            try? await Task.sleep(for: .milliseconds(200))
            await self?.layerShown()
        }
        controller.delegate = delegate
        pip = controller
        pipDelegate = delegate
    }

    private func pipChanged(_ event: PipEvent) {
        switch event {
        case .began: isInPip = true
        case .ended, .failed: isInPip = false
        case .restore: break
        }
        onPip(event)
    }
}

/// AVKit reports to an Objective-C delegate; this passes what it says along.
@MainActor
private final class PipDelegate: NSObject, @preconcurrency AVPictureInPictureControllerDelegate {
    private let report: (LiveStream.PipEvent) -> Void
    private let shown: () async -> Void

    /// `report` hears each event. `shown` returns once the stream's tile is
    /// back on screen, or isn't going to be.
    init(report: @escaping (LiveStream.PipEvent) -> Void, shown: @escaping () async -> Void) {
        self.report = report
        self.shown = shown
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        report(.began)
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error) {
        report(.failed(error.localizedDescription))
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        report(.ended)
    }

    func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        report(.restore)
        nonisolated(unsafe) let done = completionHandler
        Task {
            await shown()
            done(true)
        }
    }
}
