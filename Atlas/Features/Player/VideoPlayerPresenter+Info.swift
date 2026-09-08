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
        chatButtonModel.onTap = { [weak self] in self?.presentChat() }
        let host = UIHostingController(
            rootView: PlayerOverlayButtons(info: infoButtonModel, chat: chatButtonModel))
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
                self.chatButtonModel.isPaused = self.infoButtonModel.isPaused
                self.logTimeControl(player)
            }
        }
    }

    // MARK: Chat page

    /// Decides whether the Chat button shows: immediately for a live stream,
    /// or after a one-page replay probe for anything else (most videos are
    /// plain uploads and the probe comes back empty).
    func installChatAvailability(detail: VideoDetail, client: PipedClient, videoID: String) {
        chatProbeTask?.cancel()
        chatButtonModel.isLive = detail.isCurrentlyLive
        if detail.isCurrentlyLive {
            liveChatLoader = LiveChatLoader(client: client, videoID: videoID)
            chatButtonModel.isVisible = true
            return
        }
        let loader = LiveChatReplayLoader(client: client, videoID: videoID)
        chatReplayLoader = loader
        chatButtonModel.isVisible = false
        chatProbeTask = Task { [weak self] in
            await loader.loadInitial()
            guard !Task.isCancelled, let self, self.chatReplayLoader === loader else { return }
            self.chatButtonModel.isVisible = !loader.messages.isEmpty
        }
    }

    /// Chat on its own page: a glass sheet in portrait, a trailing side panel
    /// over the still-playing video in landscape.
    private func presentChat() {
        guard let host = playerVC, host.presentedViewController == nil else { return }
        installInfoCommentTimeTracking(on: player)
        let content = PlayerChatContent(
            liveLoader: liveChatLoader,
            replayLoader: chatReplayLoader,
            playbackTime: infoPlaybackTime)
        let isLandscape = host.view.bounds.width > host.view.bounds.height
        let onDisappear: () -> Void = { [weak self] in self?.stopInfoCommentTimeTracking() }
        let chatVC: UIViewController
        if isLandscape {
            let vc = UIHostingController(
                rootView:
                    PlayerChatSidePanel(content: content, onDisappear: onDisappear)
                    .environment(app))
            vc.view.backgroundColor = .clear
            vc.modalPresentationStyle = .overFullScreen
            vc.modalTransitionStyle = .crossDissolve
            chatVC = vc
        } else {
            let vc = UIHostingController(
                rootView:
                    PlayerChatSheet(content: content, onDisappear: onDisappear)
                    .environment(app))
            vc.view.backgroundColor = .clear
            vc.modalPresentationStyle = .pageSheet
            if let presentation = vc.sheetPresentationController {
                // Open just under the letterboxed video (which sits in the
                // middle ~30% of a portrait screen) so it stays watchable;
                // drag up for more chat.
                let compact = UISheetPresentationController.Detent.custom(identifier: .init("chat.compact")) {
                    $0.maximumDetentValue * 0.38
                }
                presentation.detents = [compact, .medium(), .large()]
                presentation.selectedDetentIdentifier = .init("chat.compact")
                presentation.prefersGrabberVisible = true
                presentation.largestUndimmedDetentIdentifier = .init("chat.compact")
            }
            chatVC = vc
        }
        host.present(chatVC, animated: true)
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
    /// description, and a subscribe toggle for the uploader. On wide viewports
    /// (iPad, landscape) it becomes a floating glass card docked under the
    /// Info button instead, so the video stays watchable beside it.
    private func presentInfo() {
        guard let detail = currentDetail, let host = playerVC,
            let client = currentPipedClient,
            let videoID = currentRequest?.videoID ?? presentedID
        else { return }
        installInfoCommentTimeTracking(on: player)
        let channelID = detail.channelID
        let name = detail.uploader ?? currentRequest?.uploader
        let avatar = detail.uploaderAvatar
        let asSideCard =
            host.view.bounds.width >= 700
            && host.view.bounds.width > host.view.bounds.height
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
            onDisappear: { [weak self] in self?.stopInfoCommentTimeTracking() },
            asSideCard: asSideCard)
        let infoVC = UIHostingController(
            rootView:
                sheet
                .environment(app)
                .environment(downloads)
                .modelContext(modelContext))
        // A clear content view is what lets UISheetPresentationController use
        // its Liquid Glass background at the medium detent (and lets the side
        // card float over the video).
        infoVC.view.backgroundColor = .clear
        if asSideCard {
            infoVC.modalPresentationStyle = .overFullScreen
            infoVC.modalTransitionStyle = .crossDissolve
            host.present(infoVC, animated: true)
            return
        }
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
