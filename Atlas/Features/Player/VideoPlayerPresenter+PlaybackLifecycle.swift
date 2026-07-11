import AVKit
import CoreMedia
import PipedKit

extension VideoPlayerPresenter.Coordinator {
    // MARK: Resume / progress tracking

    func savedPosition(for videoID: String) -> Double? {
        PlaybackHistoryStore.savedPosition(for: videoID, in: modelContext)
    }

    func installProgressTracking(on player: AVPlayer) {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.savePosition(seconds)
                if let player = self.player {
                    self.debugModel.update(player: player, source: self.activePlaybackSource)
                }
            }
        }
    }

    func savePosition(_ seconds: Double) {
        guard let id = currentRequest?.videoID else { return }
        PlaybackHistoryStore.savePosition(
            seconds,
            videoID: id,
            duration: player?.currentItem?.duration.seconds,
            in: modelContext)
    }

    // MARK: Queue advancement

    func installEndObserver(for item: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackEndedNaturally()
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    func installItemDiagnostics(for item: AVPlayerItem, videoID: String, source: String) {
        removeItemDiagnostics()
        activePlaybackSource = source
        let center = NotificationCenter.default
        itemDiagnosticObservers.append(
            center.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak item] _ in
                Task { @MainActor [weak item] in
                    PlaybackDiagnostics.itemEvent(
                        "stalled", videoID: videoID, source: source, item: item)
                }
            })
        itemDiagnosticObservers.append(
            center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak item] note in
                let notificationError = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                Task { @MainActor [weak item] in
                    PlaybackDiagnostics.itemEvent(
                        "failed-to-end", videoID: videoID, source: source,
                        item: item, notificationError: notificationError)
                }
            })
        itemDiagnosticObservers.append(
            center.addObserver(
                forName: .AVPlayerItemNewErrorLogEntry,
                object: item,
                queue: .main
            ) { [weak item] _ in
                Task { @MainActor [weak item] in
                    PlaybackDiagnostics.itemEvent(
                        "error-log", videoID: videoID, source: source, item: item)
                }
            })
        itemDiagnosticObservers.append(
            center.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                Task { @MainActor [weak self, weak item] in
                    self?.debugModel.updateAccessLog(item)
                    PlaybackDiagnostics.accessEvent(
                        videoID: videoID, source: source, item: item)
                }
            })
    }

    private func removeItemDiagnostics() {
        for observer in itemDiagnosticObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemDiagnosticObservers.removeAll()
    }

    func logTimeControl(_ player: AVPlayer) {
        let videoID = currentRequest?.videoID ?? presentedID ?? "unknown"
        debugModel.update(player: player, source: activePlaybackSource)
        PlaybackDiagnostics.timeControl(
            videoID: videoID, source: activePlaybackSource, player: player)
    }

    private func playbackEndedNaturally() {
        if let seconds = player?.currentTime().seconds, seconds.isFinite {
            savePosition(seconds)
        }
        guard let next = app.dequeueNext(),
            let player,
            let controller = playerVC
        else { return }

        resetForItemReplacement(on: player)
        presentedID = next.videoID
        currentRequest = next
        app.nowPlaying = next
        updateFavoritesCommand(for: next)
        player.replaceCurrentItem(with: nil)
        loadTask = Task { await load(next, player: player, controller: controller) }
    }

    func resetForItemReplacement(on player: AVPlayer) {
        loadTask?.cancel()
        loadTask = nil
        fallbackCheckTask?.cancel()
        fallbackCheckTask = nil
        upgradeTask?.cancel()
        upgradeTask = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let sponsorObserver { player.removeTimeObserver(sponsorObserver) }
        if let infoCommentTimeObserver { player.removeTimeObserver(infoCommentTimeObserver) }
        timeObserver = nil
        sponsorObserver = nil
        infoCommentTimeObserver = nil
        sponsorSegments = []
        sponsorModel.prompt = nil
        removeEndObserver()
        removeItemDiagnostics()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        infoButtonModel.isPaused = false
        infoPlaybackTime.seconds = nil
        activePlaybackSource = "unknown"
        fallbackInProgress = false
        debugModel.reset()
        currentDetail = nil
        currentDetailLoadedAt = nil
        currentPipedClient = nil
        currentHTTPClient = nil
        infoButtonHost?.willMove(toParent: nil)
        infoButtonHost?.view.removeFromSuperview()
        infoButtonHost?.removeFromParent()
        infoButtonHost = nil
        debugOverlayHost?.willMove(toParent: nil)
        debugOverlayHost?.view.removeFromSuperview()
        debugOverlayHost?.removeFromParent()
        debugOverlayHost = nil
        skipButtonHost?.willMove(toParent: nil)
        skipButtonHost?.view.removeFromSuperview()
        skipButtonHost?.removeFromParent()
        skipButtonHost = nil
    }

    // MARK: Picture-in-Picture

    func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
        pipActive = true
    }

    func playerViewController(
        _ controller: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        // Expanding from PiP: re-present the (still-alive) player.
        guard let presenter, presenter.presentedViewController == nil else {
            completionHandler(true)
            return
        }
        presenter.presentModal(controller) { completionHandler(true) }
    }

    func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
        pipActive = false
        // PiP closed without restoring the full-screen UI → tear down.
        if presenter?.presentedViewController == nil {
            hardStop()
            clearRequest()
        }
    }

    // MARK: Dismissal

    /// Fired when the presented player disappears. Ignore the dismissal that
    /// happens automatically when PiP takes over.
    func playerWasDismissed() {
        guard presentedID != nil, !pipActive else { return }
        hardStop()
        clearRequest()
    }

    func dismissPlayer() {
        presenter?.dismiss(animated: true)
        hardStop()
    }

    func hardStop() {
        loadTask?.cancel()
        loadTask = nil
        fallbackCheckTask?.cancel()
        fallbackCheckTask = nil
        upgradeTask?.cancel()
        upgradeTask = nil
        if let player {
            let t = player.currentTime().seconds
            if t.isFinite { savePosition(t) }
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            if let sponsorObserver { player.removeTimeObserver(sponsorObserver) }
            if let infoCommentTimeObserver { player.removeTimeObserver(infoCommentTimeObserver) }
        }
        timeObserver = nil
        sponsorObserver = nil
        infoCommentTimeObserver = nil
        removeEndObserver()
        removeItemDiagnostics()
        sponsorSegments = []
        sponsorModel.prompt = nil
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        infoButtonModel.isPaused = false
        infoPlaybackTime.seconds = nil
        activePlaybackSource = "unknown"
        fallbackInProgress = false
        debugModel.reset()
        infoButtonHost?.willMove(toParent: nil)
        infoButtonHost?.view.removeFromSuperview()
        infoButtonHost?.removeFromParent()
        infoButtonHost = nil
        debugOverlayHost?.willMove(toParent: nil)
        debugOverlayHost?.view.removeFromSuperview()
        debugOverlayHost?.removeFromParent()
        debugOverlayHost = nil
        skipButtonHost?.willMove(toParent: nil)
        skipButtonHost?.view.removeFromSuperview()
        skipButtonHost?.removeFromParent()
        skipButtonHost = nil
        player?.pause()
        player = nil
        playerVC = nil
        presentedID = nil
        currentRequest = nil
        currentDetail = nil
        currentDetailLoadedAt = nil
        currentPipedClient = nil
        currentHTTPClient = nil
        pipActive = false
        updateFavoritesCommand(for: nil)
    }

    func updateFavoritesCommand(for request: PlayRequest?) {
        PlayerFavoritesRemoteCommand.shared.update(
            request: request,
            modelContext: request == nil ? nil : modelContext)
    }

    func showError(on controller: AVPlayerViewController, _ message: String) {
        let alert = UIAlertController(title: "Couldn’t play video", message: message, preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.presenter?.dismiss(animated: true)
            })
        controller.present(alert, animated: true)
    }

    func recordHistory(_ detail: VideoDetail, _ request: PlayRequest) {
        PlaybackHistoryStore.record(request, detail: detail, in: modelContext)
    }

    /// History for offline playback, where only the request fields are known.
    func recordHistory(_ request: PlayRequest) {
        PlaybackHistoryStore.record(request, in: modelContext)
    }

}
