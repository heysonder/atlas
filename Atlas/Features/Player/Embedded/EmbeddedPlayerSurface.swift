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

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func preparePictureInPictureIfNeeded() {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else { return }
        pipController = controller
        onPiPController?(controller)
    }
}
