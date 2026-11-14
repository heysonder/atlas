import AVKit
import SwiftUI

/// A plain `AVPlayerLayer` host for the embedded player — no AVKit chrome, so
/// the SwiftUI controls overlay is the only UI. The view is created once by
/// the model and merely parented here, which lets the same layer move between
/// the inline and full-screen layouts without re-attaching the player.
struct EmbeddedPlayerSurface: UIViewRepresentable {
    let layerView: EmbeddedPlayerLayerView
    let onPiPController: (AVPictureInPictureController) -> Void

    func makeUIView(context: Context) -> EmbeddedPlayerLayerView {
        layerView.onPiPController = onPiPController
        layerView.preparePictureInPictureIfNeeded()
        return layerView
    }

    func updateUIView(_ uiView: EmbeddedPlayerLayerView, context: Context) {
        uiView.onPiPController = onPiPController
        uiView.preparePictureInPictureIfNeeded()
    }
}

final class EmbeddedPlayerLayerView: UIView {
    var onPiPController: ((AVPictureInPictureController) -> Void)?
    private var pipController: AVPictureInPictureController?
    /// Hosts the `AVPlayerLayer`. A subview rather than this view's own
    /// layer so pinch-to-fill can scale it with a transform while SwiftUI
    /// keeps setting this view's frame.
    let videoView = EmbeddedVideoLayerView()

    var playerLayer: AVPlayerLayer { videoView.playerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        isAccessibilityElement = false
        addSubview(videoView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre, not frame: frame is undefined under a transform.
        videoView.bounds = CGRect(origin: .zero, size: bounds.size)
        videoView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func preparePictureInPictureIfNeeded() {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return }
        pipController = controller
        onPiPController?(controller)
    }
}

final class EmbeddedVideoLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }
}
