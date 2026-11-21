import AVFoundation
import SwiftUI

/// A bare AVPlayerLayer: no controls, no gestures, just video.
/// (AVKit's VideoPlayer adds a control bar that fights the tile's own clicks.)
///
/// The layer is handed in rather than made here. A live stream owns its
/// layer, because Picture in Picture is tied to a layer and has to outlive
/// the tile that was showing it.
struct PlayerLayer {
    let layer: AVPlayerLayer
    /// Fill crops whatever overhangs so the picture reaches every edge; fit
    /// letterboxes.
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    /// A view that has just been made takes the layer from whichever view
    /// had it. After that it only picks the layer up again if nobody has it,
    /// so a view on its way out can't take it back from its successor.
    @MainActor
    private func update(_ view: PlayerLayerView, isNew: Bool) {
        layer.videoGravity = gravity
        view.show(layer, taking: isNew)
    }
}

#if os(macOS)
extension PlayerLayer: NSViewRepresentable {

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        update(view, isNew: true)
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        update(view, isNew: false)
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) {
        view.show(nil, taking: false)
    }
}

final class PlayerLayerView: NSView {
    private var playerLayer: AVPlayerLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Puts a player layer in this view, or with nil takes it out. A layer
    /// lives in one view at a time. `taking` takes it from a view that has
    /// it; otherwise it's only picked up if it's new here or has no home.
    func show(_ shown: AVPlayerLayer?, taking: Bool) {
        guard let layer else { return }
        if let playerLayer, playerLayer !== shown, playerLayer.superlayer === layer {
            playerLayer.removeFromSuperlayer()
        }
        let changed = playerLayer !== shown
        playerLayer = shown
        if let shown, shown.superlayer !== layer, taking || changed || shown.superlayer == nil {
            layer.addSublayer(shown)
            fit()
        }
    }

    override func layout() {
        super.layout()
        fit()
    }

    /// Without this the layer animates to its new frame, and the picture
    /// lags behind the tile while the window resizes.
    private func fit() {
        guard let playerLayer, playerLayer.superlayer === layer else { return }
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
        update(view, isNew: true)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        update(view, isNew: false)
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.show(nil, taking: false)
    }
}

final class PlayerLayerView: UIView {
    private var playerLayer: AVPlayerLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Puts a player layer in this view, or with nil takes it out. A layer
    /// lives in one view at a time. `taking` takes it from a view that has
    /// it; otherwise it's only picked up if it's new here or has no home.
    func show(_ shown: AVPlayerLayer?, taking: Bool) {
        if let playerLayer, playerLayer !== shown, playerLayer.superlayer === layer {
            playerLayer.removeFromSuperlayer()
        }
        let changed = playerLayer !== shown
        playerLayer = shown
        if let shown, shown.superlayer !== layer, taking || changed || shown.superlayer == nil {
            layer.addSublayer(shown)
            fit()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fit()
    }

    private func fit() {
        guard let playerLayer, playerLayer.superlayer === layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
#endif
