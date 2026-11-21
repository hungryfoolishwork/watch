import AVFoundation
import SwiftUI

/// A bare AVPlayerLayer: no controls, no gestures, just video.
/// (AVKit's VideoPlayer adds a control bar that fights the tile's own clicks.)
struct PlayerLayer {
    let player: AVPlayer
    /// Fill crops whatever overhangs so the picture reaches every edge; fit
    /// letterboxes.
    var gravity: AVLayerVideoGravity = .resizeAspectFill
}

#if os(macOS)
extension PlayerLayer: NSViewRepresentable {

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Without this the layer animates to its new frame, and the picture
        // lags behind the tile while the window resizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    /// Clicks go to the tile underneath, not to this view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
extension PlayerLayer: UIViewRepresentable {

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
    }
}

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#endif
