import AVKit
import CoreMedia
import PipedKit
import SwiftData
import SwiftUI

/// Presents the native fullscreen `AVPlayerViewController` directly (no SwiftUI
/// cover), so there's a single slide-up/down. AVKit owns system Now Playing
/// state and keeps the player attached for background audio and PiP.
struct VideoPlayerPresenter: UIViewControllerRepresentable {
    @Binding var request: PlayRequest?
    let app: AppModel
    let downloads: DownloadManager
    let modelContext: ModelContext

    func makeCoordinator() -> Coordinator {
        Coordinator(
            app: app,
            downloads: downloads,
            modelContext: modelContext,
            clearRequest: { request = nil })
    }

    func makeUIViewController(context: Context) -> FullscreenPlayerPresenterController {
        let viewController = FullscreenPlayerPresenterController()
        viewController.onDismissed = {
            [weak coordinator = context.coordinator] in coordinator?.playerWasDismissed()
        }
        context.coordinator.presenter = viewController
        return viewController
    }

    func updateUIViewController(
        _ uiViewController: FullscreenPlayerPresenterController,
        context: Context
    ) {
        context.coordinator.sync(request: request)
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        let app: AppModel
        let downloads: DownloadManager
        let modelContext: ModelContext
        let clearRequest: () -> Void
        weak var presenter: FullscreenPlayerPresenterController?

        var presentedID: String?
        var player: AVPlayer?
        var playerVC: AVPlayerViewController?
        var loadTask: Task<Void, Never>?
        var pipActive = false
        /// True while the old player is being dismissed so a new video can be
        /// presented from the dismissal's completion; blocks re-entrant `sync`.
        private var pendingReplacement = false
        var timeObserver: Any?
        var endObserver: NSObjectProtocol?
        var itemDiagnosticObservers: [NSObjectProtocol] = []
        var statusObservation: NSKeyValueObservation?
        var fallbackCheckTask: Task<Void, Never>?
        var upgradeTask: Task<Void, Never>?
        var activePlaybackSource = "unknown"
        var fallbackInProgress = false
        var currentRequest: PlayRequest?
        var currentDetail: VideoDetail?
        /// The clients that resolved `currentDetail`. Keep playback pinned to
        /// that immutable instance generation even if the selected instance
        /// changes while AVPlayer, PiP, a fallback, or an upgrade is active.
        var currentPipedClient: PipedClient?
        var currentHTTPClient: PolicyHTTPClient?
        /// When `currentDetail`'s URLs were resolved — runtime fallback uses
        /// this to decide whether they may have expired.
        var currentDetailLoadedAt: Date?
        var infoButtonHost: UIHostingController<InfoOverlayButton>?
        var debugOverlayHost: UIHostingController<PlayerDebugOverlay>?
        let infoButtonModel = InfoButtonModel()
        let debugModel = PlayerDebugModel()
        let infoPlaybackTime = PlayerPlaybackTime()
        var timeControlObservation: NSKeyValueObservation?
        var infoCommentTimeObserver: Any?
        // SponsorBlock: skippable segments + the overlay button that offers them.
        var sponsorSegments: [SponsorSegment] = []
        var sponsorObserver: Any?
        let sponsorModel = SponsorSkipModel()
        var skipButtonHost: UIHostingController<SkipSponsorButton>?

        init(
            app: AppModel,
            downloads: DownloadManager,
            modelContext: ModelContext,
            clearRequest: @escaping () -> Void
        ) {
            self.app = app
            self.downloads = downloads
            self.modelContext = modelContext
            self.clearRequest = clearRequest
            super.init()
        }

        func sync(request: PlayRequest?) {
            // A replacement dismissal is in flight; its completion presents
            // the new video.
            guard !pendingReplacement else { return }
            if let request {
                guard presentedID != request.videoID else { return }
                present(request)
            } else if presentedID != nil, !pipActive {
                dismissPlayer()
            }
        }

        private func present(_ request: PlayRequest) {
            guard let presenter, presenter.view.window != nil else { return }
            // Replacing while the old player is still on screen (PiP excluded —
            // its fullscreen UI is already dismissed): UIKit ignores `present`
            // while another controller is presented, so tear down and dismiss
            // the old one first, then present the new video from the
            // dismissal's completion. `hardStop()` clears `presentedID`, so
            // the `playerWasDismissed` fired by this dismissal is a no-op.
            if playerVC != nil, !pipActive, presenter.presentedViewController != nil {
                hardStop()
                pendingReplacement = true
                presenter.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    self.pendingReplacement = false
                    self.present(request)
                }
                return
            }
            if playerVC != nil { hardStop() }  // replace any existing (incl. PiP) player
            presentedID = request.videoID
            currentRequest = request
            updateFavoritesCommand(for: request)

            let player = AVPlayer()
            player.appliesMediaSelectionCriteriaAutomatically = false
            // Keep buffering/stall behavior at AVPlayer defaults
            // (automaticallyWaitsToMinimizeStalling defaults to true).
            let controller = AVPlayerViewController()
            controller.player = player
            controller.delegate = self
            controller.allowsPictureInPicturePlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = true
            controller.updatesNowPlayingInfoCenter = true
            controller.modalPresentationStyle = .fullScreen
            self.player = player
            self.playerVC = controller

            presenter.presentModal(controller)

            loadTask?.cancel()
            loadTask = Task { await load(request, player: player, controller: controller) }
        }

        func load(_ request: PlayRequest, player: AVPlayer, controller: AVPlayerViewController) async {
            if let local = request.localURL {
                loadLocal(request, fileURL: local, player: player, controller: controller)
                return
            }
            do {
                let client = try app.client
                let httpClient = try app.httpClient
                let detail = try await app.resolveStreamForPlayback(request.videoID)
                guard !Task.isCancelled else { return }
                // Only try AV1 HLS when it can actually work: the device decodes
                // AV1 and the instance extracted AV1 streams (otherwise the
                // /hls/av1 endpoint 404s and AVPlayer fails before falling back).
                let av1HLSURL =
                    (Self.supportsAV1 && detail.hasAV1VideoStream)
                    ? client.av1HLSMasterURL(videoID: request.videoID)
                    : nil
                let baseMetadata = PlayerNowPlayingMetadata.streaming(detail, request: request)
                guard
                    let playback = await StreamPlaybackBuilder.makePlayerItem(
                        detail,
                        allowAV1: Self.supportsAV1,
                        av1HLSURL: av1HLSURL,
                        client: httpClient
                    )
                else {
                    showError(on: controller, PipedError.noPlayableStream.localizedDescription)
                    return
                }
                guard !Task.isCancelled else { return }
                let initialItem = playback.item
                if playback.selectsPreferredAudio {
                    await PlayerAudioSelection.selectPreferredAudio(for: initialItem)
                    guard !Task.isCancelled else { return }
                }
                // Keep the forward buffer window system-managed.
                initialItem.externalMetadata = baseMetadata
                player.replaceCurrentItem(with: initialItem)
                PlayerCaptionSelection.keepOffByDefault(for: initialItem)
                installEndObserver(for: initialItem)
                installItemDiagnostics(
                    for: initialItem,
                    videoID: request.videoID,
                    source: playback.sourceName)
                debugModel.configure(detail: detail, composed: playback.composed, allowAV1: Self.supportsAV1)
                PlaybackDiagnostics.start(videoID: request.videoID, source: playback.sourceName)
                if playback.failureFallback != .none {
                    observeForFailure(
                        initialItem,
                        detail: detail,
                        player: player,
                        fallback: playback.failureFallback,
                        stallFallbackDelay: playback.stallFallbackDelay)
                }
                PlayerNowPlayingMetadata.attachArtwork(
                    to: initialItem,
                    urlString: detail.thumbnailURL ?? request.thumbnail,
                    base: baseMetadata,
                    client: httpClient)

                currentPipedClient = client
                currentHTTPClient = httpClient
                currentDetail = detail
                currentDetailLoadedAt = app.streamResolvedAt(request.videoID) ?? Date()
                installDebugOverlay(on: controller)
                installInfoButton(on: controller)
                // Resume from a saved position (ignore if we're at/near the end).
                if let resume = savedPosition(for: request.videoID),
                    resume >= PlaybackHistoryStore.minWatchSeconds
                {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                // The seek can outlive this playback (dismissal cancels the
                // load): don't resume audio or install observers on an
                // orphaned player.
                guard !Task.isCancelled, self.player === player else { return }
                // Start normally so AVPlayer can wait to minimize stalls.
                player.play()
                // A start that never becomes playback (buffering that never
                // completes) fires no stall notification and no failure, so
                // watch for it explicitly.
                if playback.failureFallback != .none {
                    scheduleFallbackIfStillStalled(
                        initialItem,
                        detail: detail,
                        player: player,
                        fallback: playback.failureFallback,
                        delay: playback.stallFallbackDelay)
                }
                if let upgrade = playback.composedUpgrade {
                    scheduleComposedUpgrade(
                        upgrade,
                        from: initialItem,
                        detail: detail,
                        player: player,
                        client: httpClient)
                }
                installProgressTracking(on: player)
                loadSponsorSegments(for: request, player: player, controller: controller)
                recordHistory(detail, request)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                showError(on: controller, error.localizedDescription)
            }
        }

        /// Offline playback of a downloaded file: no stream resolution, info panel,
        /// or related streams — just the local asset, basic Now Playing metadata,
        /// resume, and progress tracking (shared with streamed playback by videoID).
        private func loadLocal(
            _ request: PlayRequest,
            fileURL: URL,
            player: AVPlayer,
            controller: AVPlayerViewController
        ) {
            let metadata = PlayerNowPlayingMetadata.local(request)
            let item = AVPlayerItem(url: fileURL)
            item.externalMetadata = metadata
            player.replaceCurrentItem(with: item)
            PlayerCaptionSelection.keepOffByDefault(for: item)
            installEndObserver(for: item)
            installItemDiagnostics(for: item, videoID: request.videoID, source: "local")
            debugModel.configureLocal()
            PlaybackDiagnostics.start(videoID: request.videoID, source: "local")
            installDebugOverlay(on: controller)
            PlayerNowPlayingMetadata.attachArtwork(
                to: item,
                urlString: request.thumbnail,
                base: metadata,
                client: AppModel.publicHTTPClient)
            recordHistory(request)
            // Tied to `loadTask` so teardown cancels it; otherwise the seek
            // could resume an orphaned player and install a time observer that
            // is never removed.
            loadTask = Task {
                if let resume = savedPosition(for: request.videoID),
                    resume >= PlaybackHistoryStore.minWatchSeconds
                {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                guard !Task.isCancelled, self.player === player else { return }
                player.play()
                installProgressTracking(on: player)
            }
        }
    }
}
