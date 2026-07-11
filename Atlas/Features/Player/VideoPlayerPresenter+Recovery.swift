import AVFoundation
import CoreMedia
import PipedKit

extension VideoPlayerPresenter.Coordinator {
    static let supportsAV1: Bool = StreamPlaybackBuilder.deviceSupportsAV1

    /// If an upgraded source fails to actually play, swap to its configured fallback.
    func observeForFailure(
        _ item: AVPlayerItem,
        detail: VideoDetail,
        player: AVPlayer,
        fallback: StreamPlaybackBuilder.FailureFallback,
        stallFallbackDelay: TimeInterval
    ) {
        fallbackInProgress = false
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                await self?.fallbackAfterFailure(
                    reason: "status failed",
                    failedItem: item,
                    detail: detail,
                    player: player,
                    fallback: fallback)
            }
        }
        let center = NotificationCenter.default
        itemDiagnosticObservers.append(
            center.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak self, weak item, weak player] _ in
                Task { @MainActor [weak self, weak item, weak player] in
                    guard let item, let player else { return }
                    self?.scheduleFallbackIfStillStalled(
                        item,
                        detail: detail,
                        player: player,
                        fallback: fallback,
                        delay: stallFallbackDelay)
                }
            })
        itemDiagnosticObservers.append(
            center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self, weak item, weak player] _ in
                Task { @MainActor [weak self, weak item, weak player] in
                    guard let item, let player else { return }
                    await self?.fallbackAfterFailure(
                        reason: "failed to play to end",
                        failedItem: item,
                        detail: detail,
                        player: player,
                        fallback: fallback)
                }
            })
    }

    private func fallbackAfterFailure(
        reason: String,
        failedItem item: AVPlayerItem,
        detail: VideoDetail,
        player: AVPlayer,
        fallback: StreamPlaybackBuilder.FailureFallback
    ) async {
        guard !fallbackInProgress, fallback != .none else { return }
        // Claim the fallback before the awaits below so a second failure
        // signal (status + failed-to-play often arrive together) can't
        // start a competing swap.
        fallbackInProgress = true
        // The item being replaced is the one a pending upgrade targets;
        // its swap guards would reject it anyway.
        upgradeTask?.cancel()
        upgradeTask = nil
        let detail = await refreshedDetailForFallback(detail, failedItem: item)
        guard let client = currentHTTPClient else {
            fallbackInProgress = false
            return
        }
        let fallbackPlayback: StreamPlaybackBuilder.PreparedPlayback?
        switch fallback {
        case .none:
            fallbackPlayback = nil
        case .direct:
            fallbackPlayback = StreamPlaybackBuilder.makeDirectFailureFallbackItem(
                for: detail,
                client: client)
        case .composedOrDirect:
            fallbackPlayback = await StreamPlaybackBuilder.makeComposedOrDirectFailureFallbackItem(
                detail,
                allowAV1: Self.supportsAV1,
                client: client)
        }
        guard let fallbackPlayback else {
            fallbackInProgress = false
            return
        }
        // The awaits above can outlive this playback: bail if the
        // coordinator moved to another player/item meanwhile (whoever
        // replaced it also reset the fallback state — leave it alone).
        guard self.player === player, player.currentItem === item else { return }
        fallbackCheckTask?.cancel()
        fallbackCheckTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        let resume = player.currentTime()
        let wasPlaying = player.timeControlStatus != .paused
        PlaybackDiagnostics.fallback(
            videoID: currentRequest?.videoID ?? "unknown",
            source: activePlaybackSource,
            reason: reason,
            item: item)
        let fallbackItem = fallbackPlayback.item
        let currentMetadata = player.currentItem?.externalMetadata ?? []
        fallbackItem.externalMetadata =
            currentMetadata.isEmpty
            ? PlayerNowPlayingMetadata.streaming(
                detail,
                request: currentRequest
                    ?? PlayRequest(
                        videoID: presentedID ?? "",
                        title: detail.title ?? ""))
            : currentMetadata
        if fallbackPlayback.selectsPreferredAudio {
            await PlayerAudioSelection.selectPreferredAudio(for: fallbackItem)
            guard self.player === player, player.currentItem === item else { return }
        }
        player.replaceCurrentItem(with: fallbackItem)
        PlayerCaptionSelection.keepOffByDefault(for: fallbackItem)
        installEndObserver(for: fallbackItem)
        installItemDiagnostics(
            for: fallbackItem,
            videoID: currentRequest?.videoID ?? "unknown",
            source: fallbackPlayback.sourceName)
        debugModel.configure(detail: detail, composed: fallbackPlayback.composed, allowAV1: Self.supportsAV1)
        await player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero)
        // `defaultRate` carries the user's selected playback speed.
        if wasPlaying { player.playImmediately(atRate: player.defaultRate) }
    }

    /// Startup picked a composition that outranks the playing manifest but
    /// wasn't assembled yet. Assemble it off the hot path and swap once
    /// ready — unless playback moved on (new item, or a runtime fallback
    /// claimed the player first).
    func scheduleComposedUpgrade(
        _ upgrade: StreamPlaybackBuilder.ComposedUpgrade,
        from item: AVPlayerItem,
        detail: VideoDetail,
        player: AVPlayer,
        client: PolicyHTTPClient
    ) {
        upgradeTask?.cancel()
        upgradeTask = Task { [weak self, weak item, weak player] in
            let playback = await StreamPlaybackBuilder.makeComposedUpgradePlayback(
                upgrade,
                client: client)
            guard !Task.isCancelled, let self, let playback, let item, let player else { return }
            await self.upgradeToComposed(playback, from: item, detail: detail, player: player)
        }
    }

    private func upgradeToComposed(
        _ playback: StreamPlaybackBuilder.PreparedPlayback,
        from item: AVPlayerItem,
        detail: VideoDetail,
        player: AVPlayer
    ) async {
        guard !fallbackInProgress,
            self.player === player,
            player.currentItem === item
        else { return }
        // Claim the swap like a fallback would, so a failure signal on the
        // old item can't start a competing one mid-upgrade.
        fallbackInProgress = true
        fallbackCheckTask?.cancel()
        fallbackCheckTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        let resume = player.currentTime()
        let wasPlaying = player.timeControlStatus != .paused
        PlaybackDiagnostics.message(
            "composed-upgrade",
            videoID: currentRequest?.videoID,
            source: activePlaybackSource)
        let upgradeItem = playback.item
        upgradeItem.externalMetadata = item.externalMetadata
        if playback.selectsPreferredAudio {
            await PlayerAudioSelection.selectPreferredAudio(for: upgradeItem)
            // Whoever replaced the item meanwhile also reset the fallback
            // state — leave it alone.
            guard self.player === player, player.currentItem === item else { return }
        }
        player.replaceCurrentItem(with: upgradeItem)
        PlayerCaptionSelection.keepOffByDefault(for: upgradeItem)
        installEndObserver(for: upgradeItem)
        installItemDiagnostics(
            for: upgradeItem,
            videoID: currentRequest?.videoID ?? "unknown",
            source: playback.sourceName)
        debugModel.configure(detail: detail, composed: true, allowAV1: Self.supportsAV1)
        // The composition can still fail at runtime; keep the direct
        // fallback armed (this also re-opens `fallbackInProgress`).
        if playback.failureFallback != .none {
            observeForFailure(
                upgradeItem,
                detail: detail,
                player: player,
                fallback: playback.failureFallback,
                stallFallbackDelay: playback.stallFallbackDelay)
        }
        await player.seek(to: resume, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.playImmediately(atRate: player.defaultRate) }
    }

    func scheduleFallbackIfStillStalled(
        _ item: AVPlayerItem,
        detail: VideoDetail,
        player: AVPlayer,
        fallback: StreamPlaybackBuilder.FailureFallback,
        delay: TimeInterval
    ) {
        fallbackCheckTask?.cancel()
        let stalledAt = player.currentTime().seconds
        fallbackCheckTask = Task { [weak self, weak item, weak player] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fallbackIfStillStalled(
                stalledAt: stalledAt,
                failedItem: item,
                detail: detail,
                player: player,
                fallback: fallback)
        }
    }

    private func fallbackIfStillStalled(
        stalledAt: Double,
        failedItem item: AVPlayerItem?,
        detail: VideoDetail,
        player: AVPlayer?,
        fallback: StreamPlaybackBuilder.FailureFallback
    ) async {
        guard let item,
            let player,
            player.currentItem === item
        else {
            return
        }
        let currentSeconds = player.currentTime().seconds
        let advanced = PlayerRuntimeFallbackPolicy.hasAdvanced(
            from: stalledAt,
            to: currentSeconds)
        guard !advanced else { return }
        // Only starvation while actively trying to play counts as blocked —
        // a user-paused item with a thin buffer must not trigger a swap.
        let stillBlocked =
            item.status == .failed
            || (player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                && (item.isPlaybackBufferEmpty || !item.isPlaybackLikelyToKeepUp))
        guard stillBlocked else { return }
        await fallbackAfterFailure(
            reason: "unrecovered media stall",
            failedItem: item,
            detail: detail,
            player: player,
            fallback: fallback)
    }

    /// A video's signed URLs all expire together, so when the failure looks
    /// like expiry — an HTTP 403 in the error log or details past the
    /// freshness window — rebuild from freshly resolved URLs instead of
    /// equally stale ones.
    private func refreshedDetailForFallback(
        _ detail: VideoDetail,
        failedItem item: AVPlayerItem
    ) async -> VideoDetail {
        guard let videoID = currentRequest?.videoID else { return detail }
        let age = currentDetailLoadedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard
            PlayerRuntimeFallbackPolicy.hasExpiredURLError(item)
                || age > StreamPlaybackBuilder.staleDetailFallbackAge
        else { return detail }
        guard let client = currentPipedClient,
            let fresh = try? await client.streams(videoID: videoID)
        else { return detail }
        PlaybackDiagnostics.message("stream-refreshed", videoID: videoID)
        currentDetail = fresh
        currentDetailLoadedAt = Date()
        return fresh
    }

}
