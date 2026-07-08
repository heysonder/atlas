import SwiftUI
import SwiftData
import AVKit
import CoreMedia
import PipedKit

/// Presents the native fullscreen `AVPlayerViewController` directly (no SwiftUI
/// cover), so there's a single slide-up/down. AVKit owns system Now Playing
/// state and keeps the player attached for background audio and PiP.
struct VideoPlayerPresenter: UIViewControllerRepresentable {
    @Binding var request: PlayRequest?
    let app: AppModel
    let modelContext: ModelContext

    func makeCoordinator() -> Coordinator {
        Coordinator(app: app, modelContext: modelContext, clearRequest: { request = nil })
    }

    func makeUIViewController(context: Context) -> PresenterController {
        let vc = PresenterController()
        vc.onDismissed = { [weak coordinator = context.coordinator] in coordinator?.playerWasDismissed() }
        context.coordinator.presenter = vc
        return vc
    }

    func updateUIViewController(_ uiViewController: PresenterController, context: Context) {
        context.coordinator.sync(request: request)
    }

    @MainActor
    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let app: AppModel
        private let modelContext: ModelContext
        private let clearRequest: () -> Void
        weak var presenter: PresenterController?

        private var presentedID: String?
        private var player: AVPlayer?
        private var playerVC: AVPlayerViewController?
        private var loadTask: Task<Void, Never>?
        private var pipActive = false
        /// True while the old player is being dismissed so a new video can be
        /// presented from the dismissal's completion; blocks re-entrant `sync`.
        private var pendingReplacement = false
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?
        private var itemDiagnosticObservers: [NSObjectProtocol] = []
        private var statusObservation: NSKeyValueObservation?
        private var fallbackCheckTask: Task<Void, Never>?
        private var activePlaybackSource = "unknown"
        private var fallbackInProgress = false
        private var currentRequest: PlayRequest?
        private var currentDetail: VideoDetail?
        /// When `currentDetail`'s URLs were resolved — runtime fallback uses
        /// this to decide whether they may have expired.
        private var currentDetailLoadedAt: Date?
        private var infoButtonHost: UIHostingController<InfoOverlayButton>?
        private var debugOverlayHost: UIHostingController<PlayerDebugOverlay>?
        private let infoButtonModel = InfoButtonModel()
        private let debugModel = PlayerDebugModel()
        private let infoPlaybackTime = PlayerPlaybackTime()
        private var timeControlObservation: NSKeyValueObservation?
        private var infoCommentTimeObserver: Any?
        // SponsorBlock: skippable segments + the overlay button that offers them.
        private var sponsorSegments: [SponsorSegment] = []
        private var sponsorObserver: Any?
        private let sponsorModel = SponsorSkipModel()
        private var skipButtonHost: UIHostingController<SkipSponsorButton>?

        init(app: AppModel, modelContext: ModelContext, clearRequest: @escaping () -> Void) {
            self.app = app
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
            if playerVC != nil { hardStop() }   // replace any existing (incl. PiP) player
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

        private func load(_ request: PlayRequest, player: AVPlayer, controller: AVPlayerViewController) async {
            if let local = request.localURL {
                loadLocal(request, fileURL: local, player: player, controller: controller)
                return
            }
            do {
                let client = try app.client
                let detail = try await app.resolveStream(request.videoID)
                guard !Task.isCancelled else { return }
                // Only try AV1 HLS when it can actually work: the device decodes
                // AV1 and the instance extracted AV1 streams (otherwise the
                // /hls/av1 endpoint 404s and AVPlayer fails before falling back).
                let av1HLSURL = (Self.supportsAV1 && detail.hasAV1VideoStream)
                    ? client.av1HLSMasterURL(videoID: request.videoID)
                    : nil
                let baseMetadata = PlayerNowPlayingMetadata.streaming(detail, request: request)
                guard let playback = await StreamPlaybackBuilder.makePlayerItem(
                    detail,
                    allowAV1: Self.supportsAV1,
                    av1HLSURL: av1HLSURL
                ) else {
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
                NSLog("Atlas.player: start videoID=\(request.videoID) source=\(playback.sourceName)")
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
                    urlString: detail.thumbnailUrl ?? request.thumbnail,
                    base: baseMetadata)

                currentDetail = detail
                currentDetailLoadedAt = app.streamResolvedAt(request.videoID) ?? Date()
                installDebugOverlay(on: controller)
                installInfoButton(on: controller)
                // Resume from a saved position (ignore if we're at/near the end).
                if let resume = savedPosition(for: request.videoID),
                   resume >= PlaybackHistoryStore.minWatchSeconds {
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
                installProgressTracking(on: player)
                loadSponsorSegments(for: request, player: player, controller: controller)
                recordHistory(detail, request)
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
            NSLog("Atlas.player: start videoID=\(request.videoID) source=local")
            installDebugOverlay(on: controller)
            PlayerNowPlayingMetadata.attachArtwork(to: item, urlString: request.thumbnail, base: metadata)
            recordHistory(request)
            // Tied to `loadTask` so teardown cancels it; otherwise the seek
            // could resume an orphaned player and install a time observer that
            // is never removed.
            loadTask = Task {
                if let resume = savedPosition(for: request.videoID),
                   resume >= PlaybackHistoryStore.minWatchSeconds {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                guard !Task.isCancelled, self.player === player else { return }
                player.play()
                installProgressTracking(on: player)
            }
        }

        // MARK: Resume / progress tracking

        private func savedPosition(for videoID: String) -> Double? {
            PlaybackHistoryStore.savedPosition(for: videoID, in: modelContext)
        }

        private func installProgressTracking(on player: AVPlayer) {
            if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
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

        private func savePosition(_ seconds: Double) {
            guard let id = currentRequest?.videoID else { return }
            PlaybackHistoryStore.savePosition(
                seconds,
                videoID: id,
                duration: player?.currentItem?.duration.seconds,
                in: modelContext)
        }

        // MARK: Queue advancement

        private func installEndObserver(for item: AVPlayerItem) {
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

        private func installItemDiagnostics(for item: AVPlayerItem, videoID: String, source: String) {
            removeItemDiagnostics()
            activePlaybackSource = source
            let center = NotificationCenter.default
            itemDiagnosticObservers.append(center.addObserver(
                forName: .AVPlayerItemPlaybackStalled,
                object: item,
                queue: .main
            ) { [weak item] _ in
                Task { @MainActor [weak item] in
                    NSLog("Atlas.player: stalled videoID=\(videoID) source=\(source) error=\(Self.itemErrorSummary(item))")
                }
            })
            itemDiagnosticObservers.append(center.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak item] note in
                let notificationError = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                    .localizedDescription ?? "none"
                Task { @MainActor [weak item] in
                    NSLog("Atlas.player: failedToPlayToEnd videoID=\(videoID) source=\(source) notificationError=\(notificationError) itemError=\(Self.itemErrorSummary(item))")
                }
            })
            itemDiagnosticObservers.append(center.addObserver(
                forName: .AVPlayerItemNewErrorLogEntry,
                object: item,
                queue: .main
            ) { [weak item] _ in
                Task { @MainActor [weak item] in
                    NSLog("Atlas.player: errorLog videoID=\(videoID) source=\(source) error=\(Self.itemErrorSummary(item))")
                }
            })
            itemDiagnosticObservers.append(center.addObserver(
                forName: .AVPlayerItemNewAccessLogEntry,
                object: item,
                queue: .main
            ) { [weak self, weak item] _ in
                Task { @MainActor [weak self, weak item] in
                    self?.debugModel.updateAccessLog(item)
                    NSLog("Atlas.player: accessLog videoID=\(videoID) source=\(source) \(Self.accessLogSummary(item))")
                }
            })
        }

        private func removeItemDiagnostics() {
            for observer in itemDiagnosticObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            itemDiagnosticObservers.removeAll()
        }

        private static func itemErrorSummary(_ item: AVPlayerItem?) -> String {
            guard let item else { return "missing item" }
            if let event = item.errorLog()?.events.last {
                return "status=\(event.errorStatusCode) domain=\(event.errorDomain) comment=\(event.errorComment ?? "none") uri=\(event.uri ?? "none")"
            }
            return item.error?.localizedDescription ?? "no item error"
        }

        private static func accessLogSummary(_ item: AVPlayerItem?) -> String {
            guard let event = item?.accessLog()?.events.last else { return "no access log" }
            return "indicatedBitrate=\(Int(event.indicatedBitrate)) observedBitrate=\(Int(event.observedBitrate)) stalls=\(event.numberOfStalls) bytes=\(event.numberOfBytesTransferred) uri=\(event.uri ?? "none")"
        }

        private static func itemStateSummary(_ item: AVPlayerItem?) -> String {
            guard let item else { return "missing item" }
            let bufferEnd = item.loadedTimeRanges
                .map(\.timeRangeValue)
                .map { $0.start.seconds + $0.duration.seconds }
                .filter(\.isFinite)
                .max()
            let bufferEndText = bufferEnd.map { String($0) } ?? "none"
            return "itemStatus=\(itemStatusName(item.status)) likely=\(item.isPlaybackLikelyToKeepUp) bufferEmpty=\(item.isPlaybackBufferEmpty) bufferFull=\(item.isPlaybackBufferFull) bufferEnd=\(bufferEndText) error=\(itemErrorSummary(item))"
        }

        private static func itemStatusName(_ status: AVPlayerItem.Status) -> String {
            switch status {
            case .unknown: "unknown"
            case .readyToPlay: "ready"
            case .failed: "failed"
            @unknown default: "unrecognized"
            }
        }

        private static func timeControlStatusName(_ status: AVPlayer.TimeControlStatus) -> String {
            switch status {
            case .paused: "paused"
            case .waitingToPlayAtSpecifiedRate: "waiting"
            case .playing: "playing"
            @unknown default: "unrecognized"
            }
        }

        private func logTimeControl(_ player: AVPlayer) {
            let videoID = currentRequest?.videoID ?? presentedID ?? "unknown"
            let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
            let seconds = player.currentTime().seconds
            let secondsText = seconds.isFinite ? String(seconds) : "none"
            debugModel.update(player: player, source: activePlaybackSource)
            NSLog("Atlas.player: timeControl videoID=\(videoID) source=\(activePlaybackSource) status=\(Self.timeControlStatusName(player.timeControlStatus)) reason=\(reason) rate=\(player.rate) seconds=\(secondsText) \(Self.itemStateSummary(player.currentItem))")
        }

        private func playbackEndedNaturally() {
            if let seconds = player?.currentTime().seconds, seconds.isFinite {
                savePosition(seconds)
            }
            guard let next = app.dequeueNext(),
                  let player,
                  let controller = playerVC else { return }

            resetForItemReplacement(on: player)
            presentedID = next.videoID
            currentRequest = next
            app.nowPlaying = next
            updateFavoritesCommand(for: next)
            player.replaceCurrentItem(with: nil)
            loadTask = Task { await load(next, player: player, controller: controller) }
        }

        private func resetForItemReplacement(on player: AVPlayer) {
            loadTask?.cancel()
            loadTask = nil
            fallbackCheckTask?.cancel()
            fallbackCheckTask = nil
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

        // MARK: SponsorBlock
        //
        // We fetch crowdsourced skip segments after playback starts (so they never
        // delay the video), then watch the playhead with a fine-grained observer.
        // When it's inside an enabled segment, a "Skip …" button appears; tapping
        // it seeks to the segment's end. Nothing is skipped automatically.

        private func loadSponsorSegments(
            for request: PlayRequest, player: AVPlayer, controller: AVPlayerViewController
        ) {
            let categories = app.activeSponsorCategoryIDs
            guard !categories.isEmpty else { return }
            guard let client = try? app.client else { return }
            let videoID = request.videoID
            Task { [weak self] in
                let fetched = (try? await client.sponsorSegments(
                    videoID: videoID, categories: categories)) ?? []
                // Same-video re-present within the fetch window swaps players;
                // the identity check keeps observers off the old one.
                guard let self, self.presentedID == videoID, self.player === player else { return }
                let usable = Self.usableSegments(fetched)
                guard !usable.isEmpty else { return }
                self.sponsorSegments = usable
                self.installSkipButton(on: controller)
                self.installSponsorTracking(on: player)
                NSLog("Atlas.sponsor: \(usable.count) skippable segment(s) for \(videoID)")
            }
        }

        /// Keep only "skip" segments with a positive duration, earliest first.
        private static func usableSegments(_ segments: [SponsorSegment]) -> [SponsorSegment] {
            segments
                .filter { ($0.actionType ?? "skip") == "skip" && $0.end > $0.start }
                .sorted { $0.start < $1.start }
        }

        private func installSponsorTracking(on player: AVPlayer) {
            if let sponsorObserver { player.removeTimeObserver(sponsorObserver); self.sponsorObserver = nil }
            sponsorObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                let seconds = time.seconds
                Task { @MainActor [weak self] in
                    self?.updateSponsorPrompt(at: seconds)
                }
            }
        }

        private func updateSponsorPrompt(at seconds: Double) {
            guard seconds.isFinite else { return }
            let active = sponsorSegments.first { seconds >= $0.start && seconds < $0.end }
            if let active {
                let id = active.uuid ?? "\(active.start)-\(active.end)"
                guard sponsorModel.prompt?.id != id else { return }
                let end = active.end
                sponsorModel.onSkip = { [weak self] in self?.skipSponsor(to: end) }
                sponsorModel.prompt = .init(
                    id: id, noun: active.sponsorCategory?.skipLabel ?? "segment")
            } else if sponsorModel.prompt != nil {
                sponsorModel.prompt = nil
            }
        }

        private func skipSponsor(to end: Double) {
            guard let player else { return }
            sponsorModel.prompt = nil
            player.seek(to: CMTime(seconds: end, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
        }

        /// Hosts the skip button. Unlike the Info button, this host fills the
        /// overlay's safe area and lets the SwiftUI view place the pill in the
        /// lower-trailing corner itself. A fixed full-size host means the pill
        /// never overflows its bounds as it animates in (a content-sized host
        /// collapses to zero between segments and momentarily draws the pill off
        /// the bottom of the screen). The empty area isn't hit-testable, and the
        /// host sits *below* the Info button, so neither the transport controls
        /// nor the Info button lose their taps.
        private func installSkipButton(on controller: AVPlayerViewController) {
            guard skipButtonHost == nil, let overlay = controller.contentOverlayView else { return }
            let host = UIHostingController(rootView: SkipSponsorButton(model: sponsorModel))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            controller.addChild(host)
            overlay.insertSubview(host.view, at: 0)
            host.didMove(toParent: controller)
            let guide = overlay.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: guide.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
            ])
            skipButtonHost = host
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

        private func dismissPlayer() {
            presenter?.dismiss(animated: true)
            hardStop()
        }

        private func hardStop() {
            loadTask?.cancel()
            loadTask = nil
            fallbackCheckTask?.cancel()
            fallbackCheckTask = nil
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
            pipActive = false
            updateFavoritesCommand(for: nil)
        }

        private func updateFavoritesCommand(for request: PlayRequest?) {
            PlayerFavoritesRemoteCommand.shared.update(
                request: request,
                modelContext: request == nil ? nil : modelContext)
        }

        private func showError(on controller: AVPlayerViewController, _ message: String) {
            let alert = UIAlertController(title: "Couldn’t play video", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.presenter?.dismiss(animated: true)
            })
            controller.present(alert, animated: true)
        }

        private func recordHistory(_ detail: VideoDetail, _ request: PlayRequest) {
            PlaybackHistoryStore.record(request, detail: detail, in: modelContext)
        }

        /// History for offline playback, where only the request fields are known.
        private func recordHistory(_ request: PlayRequest) {
            PlaybackHistoryStore.record(request, in: modelContext)
        }

        // MARK: Info panel (title · description · subscribe)

        private func installDebugOverlay(on controller: AVPlayerViewController) {
            guard app.statsForNerdsEnabled,
                  debugOverlayHost == nil,
                  let overlay = controller.contentOverlayView else { return }
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
                host.view.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
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
        private func installInfoButton(on controller: AVPlayerViewController) {
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
                    equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -12)
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
                  let client = try? app.client,
                  let videoID = currentRequest?.videoID ?? presentedID else { return }
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
                thumbnail: detail.thumbnailUrl ?? currentRequest?.thumbnail,
                duration: detail.duration,
                description: HTMLText.plain(detail.description ?? ""),
                chapters: detail.chapters ?? [],
                canSubscribe: channelID != nil,
                isSubscribed: channelID.map(isCurrentlySubscribed) ?? false,
                onToggleSubscribe: { [weak self] subscribed in
                    self?.setSubscription(channelID: channelID, name: name,
                                          avatar: avatar, subscribed: subscribed)
                },
                showFeedback: FeedMode.current.isPersonalized,
                feedback: currentFeedbackSignal(),
                onFeedback: { [weak self] signal in self?.setFeedback(signal) },
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
            let infoVC = UIHostingController(rootView: sheet
                .environment(app)
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

        private func setSubscription(channelID: String?, name: String?, avatar: String?, subscribed: Bool) {
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

        private func setFeedback(_ signal: Int) {
            guard let request = currentRequest else { return }
            FeedbackStore.set(signal, videoID: request.videoID,
                              title: currentDetail?.title ?? request.title,
                              uploader: currentDetail?.uploader ?? request.uploader,
                              category: currentDetail?.category,
                              tags: currentDetail?.tags,
                              in: modelContext)
        }

        /// Whether this device has hardware AV1 decode (iPhone 15 Pro / A17 Pro+).
        private static let supportsAV1: Bool = StreamPlaybackBuilder.deviceSupportsAV1

        /// If an upgraded source fails to actually play, swap to its configured fallback.
        private func observeForFailure(
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
            itemDiagnosticObservers.append(center.addObserver(
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
            itemDiagnosticObservers.append(center.addObserver(
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
            let detail = await refreshedDetailForFallback(detail, failedItem: item)
            let fallbackPlayback: StreamPlaybackBuilder.PreparedPlayback?
            switch fallback {
            case .none:
                fallbackPlayback = nil
            case .direct:
                fallbackPlayback = StreamPlaybackBuilder.makeDirectFailureFallbackItem(for: detail)
            case .composedOrDirect:
                fallbackPlayback = await StreamPlaybackBuilder.makeComposedOrDirectFailureFallbackItem(
                    detail,
                    allowAV1: Self.supportsAV1)
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
            NSLog("Atlas.player: runtime fallback videoID=\(currentRequest?.videoID ?? "unknown") source=\(activePlaybackSource) reason=\(reason) error=\(Self.itemErrorSummary(item))")
            let fallbackItem = fallbackPlayback.item
            let currentMetadata = player.currentItem?.externalMetadata ?? []
            fallbackItem.externalMetadata = currentMetadata.isEmpty
                ? PlayerNowPlayingMetadata.streaming(
                    detail,
                    request: currentRequest ?? PlayRequest(
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

        private func scheduleFallbackIfStillStalled(
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
                  player.currentItem === item else {
                return
            }
            let currentSeconds = player.currentTime().seconds
            let advanced = currentSeconds.isFinite
                && stalledAt.isFinite
                && currentSeconds > stalledAt + 0.75
            guard !advanced else { return }
            // Only starvation while actively trying to play counts as blocked —
            // a user-paused item with a thin buffer must not trigger a swap.
            let stillBlocked = item.status == .failed
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
            guard Self.hasExpiredURLError(item)
                    || age > StreamPlaybackBuilder.staleDetailFallbackAge else { return detail }
            guard let fresh = try? await app.refreshStream(videoID) else { return detail }
            NSLog("Atlas.player: refreshed stream URLs for fallback videoID=\(videoID)")
            currentDetail = fresh
            currentDetailLoadedAt = Date()
            return fresh
        }

        /// -12660 is CoreMedia's status for an HTTP 403 on a media request —
        /// the signature of an expired signed URL.
        private static func hasExpiredURLError(_ item: AVPlayerItem?) -> Bool {
            guard let event = item?.errorLog()?.events.last else { return false }
            return event.errorDomain == "CoreMediaErrorDomain"
                && event.errorStatusCode == -12660
        }

    }
}

/// Invisible host that presents the player and reports when it's dismissed.
final class PresenterController: UIViewController {
    var onDismissed: (() -> Void)?
    private var presenting = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presenting && presentedViewController == nil {
            presenting = false
            onDismissed?()
        }
    }

    func presentModal(_ controller: UIViewController, completion: (() -> Void)? = nil) {
        presenting = true
        present(controller, animated: true, completion: completion)
    }
}
