import AVKit
import CoreMedia
import MediaPlayer

/// Transport, Picture in Picture, and Now Playing for the custom embedded
/// player. The native full-screen player gets all of this from
/// `AVPlayerViewController`; the embedded surface is a bare `AVPlayerLayer`,
/// so it wires the pieces up itself.
extension EmbeddedPlayerModel {
    static let skipInterval: Double = 10

    // MARK: Transport

    func togglePlayPause() {
        if player.timeControlStatus == .paused {
            // Replay from the start once the item has finished.
            if let item = player.currentItem,
                item.duration.isNumeric,
                item.currentTime().seconds >= item.duration.seconds - 0.5
            {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
    }

    /// Press-and-hold 2×: `defaultRate` keeps the user's normal speed so
    /// release restores it rather than hard-coding 1×.
    func beginFastForward() {
        guard player.timeControlStatus != .paused else { return }
        player.rate = 2
    }

    func endFastForward() {
        guard player.timeControlStatus != .paused else { return }
        player.rate = player.defaultRate
    }

    func skip(by seconds: Double) {
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        var target = current + seconds
        if let duration = player.currentItem?.duration.seconds, duration.isFinite {
            target = min(target, duration - 0.5)
        } else if playbackState.hasSeekableWindow {
            target = min(max(target, playbackState.seekableStart), playbackState.seekableEnd)
        }
        seek(toSeconds: max(target, 0))
    }

    /// Jumps a live stream back to the live edge and resumes. Resetting the
    /// configured offset means later stall recoveries return here too,
    /// rather than to wherever the user had scrubbed before.
    func seekToLiveEdge() {
        if let item = player.currentItem {
            item.configuredTimeOffsetFromLive = item.recommendedTimeOffsetFromLive
        }
        guard playbackState.hasSeekableWindow else {
            player.play()
            return
        }
        seek(toSeconds: playbackState.seekableEnd, resume: true)
    }

    /// Precise seek used by the scrubber; the Int-based `seek(to:)` resumes
    /// playback, which a scrub must not do when the user had paused.
    func seek(toSeconds seconds: Double, resume: Bool = false) {
        let target = max(seconds, 0)
        playbackState.position = target
        currentPlaybackSeconds = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600)
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.nowPlaying.refresh() }
        }
        if resume { player.play() }
    }

    /// Throttled seek while the finger is still down, so the frame follows the
    /// scrubber instead of waiting for release.
    func scrubPreview(toSeconds seconds: Double) {
        playbackState.position = max(seconds, 0)
        guard !scrubSeekInFlight else { return }
        scrubSeekInFlight = true
        player.seek(
            to: CMTime(seconds: max(seconds, 0), preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scrubSeekInFlight = false }
        }
    }

    func beginScrubbing() {
        playbackState.isScrubbing = true
        wasPlayingBeforeScrub = player.timeControlStatus != .paused
        player.pause()
    }

    func endScrubbing(atSeconds seconds: Double) {
        playbackState.isScrubbing = false
        seek(toSeconds: seconds, resume: wasPlayingBeforeScrub)
    }

    // MARK: Attach / detach

    /// Called once from `start()`: observes the player for the controls and
    /// publishes Now Playing + remote commands for the lock screen.
    func installControls() {
        playbackState.attach(to: player)
        nowPlaying.attach(to: player, model: self)
        installCaptionTracking()
    }

    func removeControls() {
        playbackState.detach()
        nowPlaying.detach()
        removeCaptionTracking()
    }

    // MARK: Full-screen fill

    /// Entering full screen: letterboxed unless a pinch chose fill for this
    /// video. Never fills on its own, so nothing is cropped unasked.
    func applyFullscreenFill() {
        setVideoFillsScreen(fullscreenFillChoice ?? false)
    }

    /// Pinch out crops the video to the screen (what a double-tap does in
    /// AVKit); pinch in letterboxes it again. Remembered for this video.
    func chooseVideoFill(_ fills: Bool) {
        fullscreenFillChoice = fills
        setVideoFillsScreen(fills)
    }

    /// The inline layout always letterboxes.
    func setVideoFillsScreen(_ fills: Bool) {
        guard playbackState.videoFillsScreen != fills else { return }
        playbackState.videoFillsScreen = fills
        layerView.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
    }

    // MARK: Picture in Picture

    /// The surface view hands over its controller once the layer exists.
    /// Owned here (not by the view) so PiP keeps running after the cover is
    /// dismissed — `pipRetainer` keeps this model alive for that window.
    func adoptPiPController(_ controller: AVPictureInPictureController) {
        guard pipController !== controller else { return }
        pipController = controller
        controller.delegate = pipDelegate
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipPossibleObservation = controller.observe(
            \.isPictureInPicturePossible, options: [.initial, .new]
        ) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                self?.playbackState.isPiPPossible = possible
            }
        }
    }

    func togglePictureInPicture() {
        guard let pipController else { return }
        if pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        } else {
            pipController.startPictureInPicture()
        }
    }

    func pipDidStart() {
        playbackState.isPiPActive = true
        Self.pipRetainer = self
        setPiPActive(true)
    }

    func pipDidStop() {
        playbackState.isPiPActive = false
        setPiPActive(false)
        // Only drop the retainer if it's still us: another video may have
        // started its own PiP in the meantime.
        if Self.pipRetainer === self { Self.pipRetainer = nil }
    }

    /// AVKit asks for the interface back whenever PiP stops other than by
    /// its ✕: the user's "return to app", or `stopPictureInPicture()` called
    /// because a different video is taking the player. Only the first
    /// re-presents this cover (`EmbeddedPlayerView` adopts this model and its
    /// running player instead of starting over). In the second case the new
    /// video's cover is already up and must be left alone; re-presenting this
    /// one re-keyed the cover back to the old video and the new one never
    /// started.
    func restoreInterfaceFromPiP(completion: @escaping @Sendable (Bool) -> Void) {
        if let current = app.nowPlaying, current.videoID != request.videoID {
            completion(true)
            return
        }
        cancelDeferredTeardown()
        if app.nowPlaying == nil || app.playerStyle != .embedded {
            app.playerStyle = .embedded
            app.nowPlaying = request
        }
        Task {
            // Let the cover's presentation land before PiP collapses into it.
            try? await Task.sleep(for: .milliseconds(400))
            completion(true)
        }
    }
}

/// `AVPictureInPictureControllerDelegate` is an NSObject protocol; the model
/// isn't one, so a small adapter forwards to it.
@MainActor
final class EmbeddedPiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
    weak var model: EmbeddedPlayerModel?

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in model?.pipDidStart() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in model?.pipDidStop() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in model?.pipDidStop() }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // AVKit's handler isn't typed Sendable; it's only ever called once
        // from the main actor below.
        nonisolated(unsafe) let handler = completionHandler
        Task { @MainActor in
            guard let model else {
                handler(false)
                return
            }
            model.restoreInterfaceFromPiP { handler($0) }
        }
    }
}
