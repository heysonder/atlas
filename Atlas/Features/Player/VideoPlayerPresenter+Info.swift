import AVKit
import CoreMedia
import PipedKit
import SwiftData
import SwiftUI

extension VideoPlayerPresenter.Coordinator {
    // MARK: Info panel (title · description · subscribe)

    func installDebugOverlay(on controller: AVPlayerViewController) {
        guard app.statsForNerdsEnabled,
            debugOverlayHost == nil,
            let overlay = controller.contentOverlayView
        else { return }
        let host = UIHostingController(rootView: PlayerDebugOverlay(model: debugModel))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        controller.addChild(host)
        overlay.addSubview(host.view)
        host.didMove(toParent: controller)
        let guide = overlay.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: guide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
        if let player = controller.player {
            debugModel.update(player: player, source: activePlaybackSource)
        }
        overlay.bringSubviewToFront(host.view)
    }

    /// iOS's `AVPlayerViewController` has no public API to add transport-bar
    /// buttons (those are tvOS-only), so we layer a small Liquid Glass "Info"
    /// button into the sanctioned `contentOverlayView`. The host view is
    /// pinned to the top-trailing corner and sized to the button itself, so
    /// it only ever receives touches inside that small area — it can't
    /// intercept taps elsewhere (notably the tab-bar region at the bottom).
    func installInfoButton(on controller: AVPlayerViewController) {
        guard infoButtonHost == nil, let overlay = controller.contentOverlayView else { return }

        infoButtonModel.onTap = { [weak self] in self?.presentInfo() }
        let host = UIHostingController(rootView: InfoOverlayButton(model: infoButtonModel))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        controller.addChild(host)
        overlay.addSubview(host.view)
        host.didMove(toParent: controller)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(
                equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
            host.view.trailingAnchor.constraint(
                equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        infoButtonHost = host
        observePlaybackForInfoButton(on: controller.player)
    }

    /// Collapses the Info button to its glyph while playing and expands it to
    /// the labeled pill whenever the video is paused (i.e. the transport
    /// controls are likely on screen), driven off the player's transport state.
    private func observePlaybackForInfoButton(on player: AVPlayer?) {
        timeControlObservation?.invalidate()
        guard let player else { return }
        infoButtonModel.isPaused = player.timeControlStatus == .paused
        logTimeControl(player)
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
            [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.infoButtonModel.isPaused = player.timeControlStatus == .paused
                self.logTimeControl(player)
            }
        }
    }

    private func installInfoCommentTimeTracking(on player: AVPlayer?) {
        guard let player else { return }
        updateInfoPlaybackTime(player.currentTime().seconds)
        guard infoCommentTimeObserver == nil else { return }
        infoCommentTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.updateInfoPlaybackTime(seconds)
            }
        }
    }

    private func stopInfoCommentTimeTracking() {
        if let infoCommentTimeObserver, let player {
            player.removeTimeObserver(infoCommentTimeObserver)
        }
        infoCommentTimeObserver = nil
        infoPlaybackTime.seconds = nil
    }

    private func updateInfoPlaybackTime(_ seconds: Double) {
        infoPlaybackTime.seconds = seconds.isFinite ? seconds : nil
    }

    /// Slides up a sheet over the still-playing video with the title, full
    /// description, and a subscribe toggle for the uploader.
    private func presentInfo() {
        guard let detail = currentDetail, let host = playerVC,
            let client = currentPipedClient,
            let videoID = currentRequest?.videoID ?? presentedID
        else { return }
        installInfoCommentTimeTracking(on: player)
        let channelID = detail.channelID
        let name = detail.uploader ?? currentRequest?.uploader
        let avatar = detail.uploaderAvatar
        let sheet = PlayerInfoSheet(
            title: detail.title ?? currentRequest?.title ?? "Video",
            uploader: name,
            uploaderDisplayName: currentRequest?.uploader ?? name,
            uploaderAvatar: avatar,
            channelID: channelID,
            creators: detail.creators ?? [],
            subscriberCount: detail.uploaderSubscriberCount,
            uploaderVerified: detail.uploaderVerified ?? false,
            thumbnail: detail.thumbnailURL ?? currentRequest?.thumbnail,
            duration: detail.duration,
            description: HTMLText.plain(detail.description ?? ""),
            chapters: detail.chapters ?? [],
            canSubscribe: channelID != nil,
            isSubscribed: channelID.map(isCurrentlySubscribed) ?? false,
            onToggleSubscribe: { [weak self] subscribed in
                self?.setSubscription(
                    channelID: channelID, name: name,
                    avatar: avatar, subscribed: subscribed) ?? false
            },
            showFeedback: FeedMode.current.isPersonalized,
            feedback: currentFeedbackSignal(),
            onFeedback: { [weak self] signal in self?.setFeedback(signal) ?? false },
            onQueuedVideoPlay: { [weak self, weak host] queued in
                guard let self else { return }
                if let sheet = host?.presentedViewController {
                    sheet.dismiss(animated: true) { self.playQueued(queued) }
                } else {
                    self.playQueued(queued)
                }
            },
            client: client,
            videoID: videoID,
            playbackTime: infoPlaybackTime,
            onTimestampTap: { [weak self] seconds in
                self?.seekToCommentTimestamp(seconds)
            },
            onDisappear: { [weak self] in self?.stopInfoCommentTimeTracking() })
        let infoVC = UIHostingController(
            rootView:
                sheet
                .environment(app)
                .environment(downloads)
                .modelContext(modelContext))
        infoVC.modalPresentationStyle = .pageSheet
        if let presentation = infoVC.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        host.present(infoVC, animated: true)
    }

    private func seekToCommentTimestamp(_ seconds: Int) {
        guard let player else { return }
        let target = max(seconds, 0)
        updateInfoPlaybackTime(Double(target))
        player.seek(
            to: CMTime(seconds: Double(target), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
        player.play()
    }

    private func playQueued(_ queued: QueuedVideo) {
        guard let request = app.removeFromQueue(queued) else { return }
        if let player, let controller = playerVC {
            restartPlayback(with: request, player: player, controller: controller)
        }
        app.nowPlaying = request
    }

    private func restartPlayback(with request: PlayRequest, player: AVPlayer, controller: AVPlayerViewController) {
        let seconds = player.currentTime().seconds
        if seconds.isFinite { savePosition(seconds) }
        resetForItemReplacement(on: player)
        currentRequest = request
        presentedID = request.videoID
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadTask = Task { await load(request, player: player, controller: controller) }
    }

    private func isCurrentlySubscribed(_ channelID: String) -> Bool {
        SubscriptionStore.isSubscribed(channelID, in: modelContext)
    }

    private func setSubscription(
        channelID: String?, name: String?, avatar: String?, subscribed: Bool
    ) -> Bool {
        SubscriptionStore.setSubscribed(
            subscribed,
            channelID: channelID,
            name: name,
            avatarURL: avatar,
            in: modelContext)
    }

    private func currentFeedbackSignal() -> Int {
        guard let id = currentRequest?.videoID else { return 0 }
        return FeedbackStore.signal(for: id, in: modelContext)
    }

    private func setFeedback(_ signal: Int) -> Bool {
        guard let request = currentRequest else { return false }
        return FeedbackStore.set(
            signal, videoID: request.videoID,
            title: currentDetail?.title ?? request.title,
            uploader: currentDetail?.uploader ?? request.uploader,
            category: currentDetail?.category,
            tags: currentDetail?.tags,
            in: modelContext)
    }

    /// Whether this device has hardware AV1 decode (iPhone 15 Pro / A17 Pro+).

}
