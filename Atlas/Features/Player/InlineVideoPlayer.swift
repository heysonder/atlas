import AVKit
import SwiftUI

/// Hosts an `AVPlayerViewController` inline (not full-screen-presented), giving
/// the standard transport controls, full-screen-expand button, AirPlay and PiP.
///
/// The player is attached only once `isReady` is true (i.e. its item is set).
/// Binding an inline controller to a player whose `currentItem` is still nil
/// leaves the transport stuck — center "play.slash" glyph and `--:--` time —
/// even after the item loads, so we wait until there's something to play.
struct InlineVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let isReady: Bool
    let onPiPActiveChanged: (Bool) -> Void

    func makeUIViewController(context: Context) -> InlinePlayerController {
        let controller = InlinePlayerController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = .resizeAspect
        controller.onPiPActiveChanged = onPiPActiveChanged
        if isReady { controller.player = player }
        return controller
    }

    func updateUIViewController(_ controller: InlinePlayerController, context: Context) {
        controller.onPiPActiveChanged = onPiPActiveChanged
        if isReady, controller.player !== player {
            controller.player = player
        }
    }
}

/// An inline `AVPlayerViewController` that reports PiP start/stop so the
/// embedded model can defer teardown while PiP is active. AVKit keeps this
/// controller alive for the duration of PiP, so the callback (and the model it
/// captures) survives the SwiftUI cover being dismissed.
final class InlinePlayerController: AVPlayerViewController, AVPlayerViewControllerDelegate {
    var onPiPActiveChanged: ((Bool) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        onPiPActiveChanged?(true)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        onPiPActiveChanged?(false)
    }
}
