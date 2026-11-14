import AVFoundation
import UIKit

/// Pinch-to-fill that tracks the fingers. While a pinch is down the video is
/// always letterboxed (`.resizeAspect`) and scaled by a transform between 1
/// (letterboxed) and the scale at which it covers the screen; on release it
/// springs to whichever end the pinch was heading for, starting at the
/// fingers' speed, and the resting state goes back to plain video gravity.
extension EmbeddedPlayerModel {
    /// How far past either end the video may be pulled before it resists.
    private static let pinchOvershoot: CGFloat = 0.06
    private static let pinchSettleKey = "pinchSettle"

    /// The transform scale at which a letterboxed video covers the layer, or
    /// `nil` when there is nothing to zoom (no size yet, or the video already
    /// matches the screen's shape).
    private var fillScale: CGFloat? {
        let video = playbackState.videoSize
        let bounds = layerView.bounds.size
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let horizontal = bounds.width / video.width
        let vertical = bounds.height / video.height
        let scale = max(horizontal, vertical) / min(horizontal, vertical)
        return scale > 1.02 ? scale : nil
    }

    func pinchZoomChanged(magnification: CGFloat) {
        guard let fillScale else { return }
        if pinchBaseScale == nil {
            beginPinchZoom(fillScale: fillScale)
            // Measured from the first reading, which already sits past the
            // gesture's recognition threshold, so the video doesn't hop.
            pinchFirstMagnification = magnification
        }
        guard let pinchBaseScale, let first = pinchFirstMagnification, first > 0 else { return }
        // The smoother eases the video toward this every display frame:
        // raw pinch readings arrive unevenly and wobble with the fingers.
        pinchSmoother?.target = Self.resisted(pinchBaseScale * magnification / first, upTo: fillScale)
    }

    func pinchZoomEnded(magnification: CGFloat, velocity: CGFloat) {
        guard let fillScale else {
            // Nothing to track: the plain threshold still toggles.
            if magnification > 1.1 { chooseVideoFill(true) } else if magnification < 0.9 { chooseVideoFill(false) }
            return
        }
        guard let base = pinchBaseScale else { return }
        pinchBaseScale = nil
        pinchFirstMagnification = nil
        // Settle from where the video is on screen, not the last raw reading.
        let current = pinchSmoother?.displayed ?? Self.resisted(base * magnification, upTo: fillScale)
        endPinchSmoothing()
        // `velocity` is magnification per second; in video-scale terms:
        let speed = velocity * base
        // Where the pinch would coast to decides the end it lands on, so a
        // quick flick commits even when the fingers barely travelled.
        let projected = current + speed * 0.18
        let fills = projected > (1 + fillScale) / 2
        let target = fills ? fillScale : 1
        let distance = target - current

        fullscreenFillChoice = fills
        playbackState.videoFillsScreen = fills
        pinchGeneration += 1
        let generation = pinchGeneration
        let videoLayer = layerView.videoView.layer

        // An explicit spring rather than `UIView.animate`: it takes the
        // fingers' speed directly and asks for the display's full refresh
        // rate, which UIKit's block animations don't on ProMotion.
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = current
        spring.toValue = target
        spring.mass = 1
        spring.stiffness = 320
        spring.damping = 32
        spring.initialVelocity = abs(distance) > 0.001 ? min(max(speed / distance, -20), 20) : 0
        spring.duration = spring.settlingDuration
        spring.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.pinchGeneration == generation, self.pinchBaseScale == nil else { return }
                self.restVideo(fills: fills)
            }
        }
        withoutLayerActions {
            layerView.videoView.transform = CGAffineTransform(scaleX: target, y: target)
        }
        videoLayer.add(spring, forKey: Self.pinchSettleKey)
        CATransaction.commit()
    }

    /// Drops any pinch transform; the caller sets the video gravity.
    func cancelPinchZoom() {
        pinchBaseScale = nil
        pinchFirstMagnification = nil
        endPinchSmoothing()
        pinchGeneration += 1
        layerView.videoView.layer.removeAllAnimations()
        layerView.videoView.transform = .identity
    }

    /// Fingers down: swap a filled video for the letterboxed one scaled up to
    /// the same size, so the transform alone drives it from here.
    private func beginPinchZoom(fillScale: CGFloat) {
        pinchGeneration += 1
        let videoView = layerView.videoView
        // A settle still in flight: carry on from where it is on screen.
        let presented = videoView.layer.presentation()?.affineTransform().a
        videoView.layer.removeAllAnimations()
        let layer = layerView.playerLayer
        let start: CGFloat
        if layer.videoGravity == .resizeAspectFill {
            start = fillScale
        } else {
            start = presented ?? videoView.transform.a
        }
        withoutLayerActions {
            layer.videoGravity = .resizeAspect
            videoView.transform = CGAffineTransform(scaleX: start, y: start)
        }
        pinchBaseScale = start
        let smoother = EmbeddedPinchSmoother(view: videoView, scale: start)
        pinchSmoother = smoother
        smoother.start()
    }

    private func endPinchSmoothing() {
        pinchSmoother?.stop()
        pinchSmoother = nil
    }

    /// The settled state: plain gravity and no transform, so rotation, PiP,
    /// and leaving full screen see an ordinary layer.
    private func restVideo(fills: Bool) {
        withoutLayerActions {
            layerView.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
            layerView.videoView.transform = .identity
        }
    }

    private func withoutLayerActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Tracks 1:1 between the two ends and gives progressively less beyond
    /// them, like a scroll view's edge.
    private static func resisted(_ scale: CGFloat, upTo fillScale: CGFloat) -> CGFloat {
        func band(_ excess: CGFloat) -> CGFloat {
            pinchOvershoot * (1 - 1 / (excess / pinchOvershoot + 1))
        }
        if scale < 1 { return 1 - band(1 - scale) }
        if scale > fillScale { return fillScale + band(scale - fillScale) }
        return scale
    }
}

/// Eases the video's scale toward the pinch's latest reading once per display
/// frame, at the display's full refresh rate. Applying each reading directly
/// made the zoom step with every uneven, slightly noisy sample.
final class EmbeddedPinchSmoother: NSObject {
    var target: CGFloat
    private(set) var displayed: CGFloat
    private weak var view: UIView?
    private var link: CADisplayLink?
    /// Time constant of the follow: short enough to feel attached to the
    /// fingers, long enough to iron out the samples.
    private static let smoothing: CFTimeInterval = 0.04

    init(view: UIView, scale: CGFloat) {
        self.view = view
        target = scale
        displayed = scale
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// The display link retains its target; this breaks that.
    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = link.targetTimestamp - link.timestamp
        displayed += (target - displayed) * (1 - exp(-elapsed / Self.smoothing))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view?.transform = CGAffineTransform(scaleX: displayed, y: displayed)
        CATransaction.commit()
    }
}
