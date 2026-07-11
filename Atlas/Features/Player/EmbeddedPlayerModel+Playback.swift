import AVKit
import CoreMedia
import PipedKit

extension EmbeddedPlayerModel {
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

    func removeEndObserver() {
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

    func removeItemDiagnostics() {
        for observer in itemDiagnosticObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        itemDiagnosticObservers.removeAll()
    }

    func installPlaybackDiagnostics() {
        timeControlObservation?.invalidate()
        logTimeControl()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.logTimeControl()
            }
        }
    }

    private func logTimeControl() {
        debugModel.update(player: player, source: activePlaybackSource)
        PlaybackDiagnostics.timeControl(
            videoID: request.videoID, source: activePlaybackSource, player: player)
    }

    private func playbackEndedNaturally() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite { savePosition(seconds) }
        guard let next = app.dequeueNext() else { return }
        advance(to: next)
    }

    func playQueued(_ queued: QueuedVideo) {
        guard let next = app.removeFromQueue(queued) else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { savePosition(seconds) }
        advance(to: next)
    }

    /// Plays a tapped related video: saves the current position, then hands the
    /// request to `advance`, which re-presents the cover with a fresh model.
    func playRelated(_ item: StreamItem) {
        guard let next = PlayRequest(item: item) else { return }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { savePosition(seconds) }
        advance(to: next)
    }

    /// Hands playback to `next` by updating `app.nowPlaying` only: the cover
    /// is keyed on the request's identity (videoID), so the change re-presents
    /// it with a fresh model that performs the single stream load. Reloading
    /// in place here as well would resolve the stream twice — once on this
    /// model and once on the re-presented one.
    private func advance(to next: PlayRequest) {
        guard next.videoID != request.videoID else {
            // Same video again: the cover identity won't change, so an
            // in-place reload is the only way to restart it.
            resetForItemReplacement()
            request = next
            app.nowPlaying = next
            updateFavoritesCommand(for: next)
            if let local = next.localURL {
                loadLocal(local)
            } else {
                loadTask = Task { await load() }
            }
            return
        }
        app.nowPlaying = next
    }

    private func resetForItemReplacement() {
        loadTask?.cancel()
        loadTask = nil
        fallbackCheckTask?.cancel()
        fallbackCheckTask = nil
        upgradeTask?.cancel()
        upgradeTask = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        removeEndObserver()
        removeItemDiagnostics()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        activePlaybackSource = "unknown"
        fallbackInProgress = false
        debugModel.reset()
        detail = nil
        plainDescription = ""
        detailLoadedAt = nil
        errorMessage = nil
        currentPlaybackSeconds = nil
        client = nil
        httpClient = nil
        lastProgressSaveSeconds = nil
        isReady = false
        player.replaceCurrentItem(with: nil)
    }

    func updateFavoritesCommand(for request: PlayRequest?) {
        PlayerFavoritesRemoteCommand.shared.update(
            request: request,
            modelContext: request == nil ? nil : modelContext)
    }

    // MARK: Resume / progress (shared with the full-screen player via HistoryEntry)

    func savedPosition(for videoID: String) -> Double? {
        PlaybackHistoryStore.savedPosition(for: videoID, in: modelContext)
    }

    func installProgressTracking() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.handleProgressTick(seconds)
            }
        }
    }

    private func handleProgressTick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        debugModel.update(player: player, source: activePlaybackSource)
        currentPlaybackSeconds = seconds
        guard seconds >= PlaybackHistoryStore.minWatchSeconds else { return }
        if lastProgressSaveSeconds == nil
            || abs(seconds - (lastProgressSaveSeconds ?? 0)) >= PlaybackHistoryStore.minWatchSeconds
        {
            lastProgressSaveSeconds = seconds
            savePosition(seconds)
        }
    }

    func seek(to seconds: Int) {
        let target = max(seconds, 0)
        currentPlaybackSeconds = Double(target)
        player.seek(
            to: CMTime(seconds: Double(target), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
        player.play()
    }

    func savePosition(_ seconds: Double) {
        PlaybackHistoryStore.savePosition(
            seconds,
            videoID: request.videoID,
            duration: player.currentItem?.duration.seconds,
            in: modelContext)
    }

    func recordHistory(_ detail: VideoDetail) {
        PlaybackHistoryStore.record(request, detail: detail, in: modelContext)
    }

    func recordHistoryLocal() {
        PlaybackHistoryStore.record(request, in: modelContext)
    }

    // MARK: Subscribe / feedback (shared stores with the full-screen player)

    func isSubscribed(_ channelID: String?) -> Bool {
        SubscriptionStore.isSubscribed(channelID, in: modelContext)
    }

    func setSubscription(_ subscribed: Bool, detail: VideoDetail) -> Bool {
        SubscriptionStore.setSubscribed(
            subscribed,
            channelID: detail.channelID,
            name: detail.uploader ?? request.uploader,
            avatarURL: detail.uploaderAvatar,
            in: modelContext)
    }

    func currentFeedbackSignal() -> Int {
        FeedbackStore.signal(for: request.videoID, in: modelContext)
    }

    func setFeedback(_ signal: Int, detail: VideoDetail) -> Bool {
        FeedbackStore.set(
            signal, videoID: request.videoID,
            title: detail.title ?? request.title,
            uploader: detail.uploader ?? request.uploader,
            category: detail.category,
            tags: detail.tags,
            in: modelContext)
    }

}
