import SwiftUI
import SwiftData
import AVKit
import CoreMedia
import VideoToolbox
import PipedKit

/// Presents the native fullscreen `AVPlayerViewController` directly (no SwiftUI
/// cover), so there's a single slide-up/down. Handles Picture-in-Picture:
/// keeps the player alive when PiP takes over and re-attaches on restore.
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
        private var timeObserver: Any?
        private var endObserver: NSObjectProtocol?
        private var statusObservation: NSKeyValueObservation?
        private var currentRequest: PlayRequest?
        private var currentDetail: VideoDetail?
        private var usedComposition = false
        private var infoButtonHost: UIHostingController<InfoOverlayButton>?
        private let infoButtonModel = InfoButtonModel()
        private let infoPlaybackTime = PlayerPlaybackTime()
        private var timeControlObservation: NSKeyValueObservation?
        private var infoCommentTimeObserver: Any?
        private var detachedForBackground = false
        private static let minWatchSeconds: Double = 5

        // SponsorBlock: skippable segments + the overlay button that offers them.
        private var sponsorSegments: [SponsorSegment] = []
        private var sponsorObserver: Any?
        private let sponsorModel = SponsorSkipModel()
        private var skipButtonHost: UIHostingController<SkipSponsorButton>?
        private let captionModel = CaptionOverlayModel()
        private var captionHost: UIHostingController<CaptionOverlayView>?
        private var captionObserver: Any?
        private var captionTask: Task<Void, Never>?

        init(app: AppModel, modelContext: ModelContext, clearRequest: @escaping () -> Void) {
            self.app = app
            self.modelContext = modelContext
            self.clearRequest = clearRequest
            super.init()
            observeAppLifecycle()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Background audio
        //
        // A fullscreen-presented `AVPlayerViewController` is paused by the system
        // when the app backgrounds (it isn't "inline", so PiP doesn't auto-start).
        // To keep *audio* going, we detach the player from the controller on the
        // way to the background — an unattached `AVPlayer` keeps playing under the
        // `.playback` audio session — and reattach the video when we return.

        private func observeAppLifecycle() {
            let nc = NotificationCenter.default
            nc.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
            nc.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
        }

        @objc private func appDidEnterBackground(_ note: Notification) { handleEnterBackground() }
        @objc private func appWillEnterForeground(_ note: Notification) { handleEnterForeground() }

        private func handleEnterBackground() {
            guard !pipActive, let player, playerVC != nil,
                  player.timeControlStatus != .paused else { return }
            playerVC?.player = nil
            detachedForBackground = true
            player.play()
        }

        private func handleEnterForeground() {
            guard detachedForBackground, let player else { return }
            detachedForBackground = false
            playerVC?.player = player
        }

        func sync(request: PlayRequest?) {
            if let request {
                guard presentedID != request.videoID else { return }
                present(request)
            } else if presentedID != nil, !pipActive {
                dismissPlayer()
            }
        }

        private func present(_ request: PlayRequest) {
            guard let presenter, presenter.view.window != nil else { return }
            if playerVC != nil { hardStop() }   // replace any existing (incl. PiP) player
            presentedID = request.videoID
            currentRequest = request

            let player = AVPlayer()
            player.appliesMediaSelectionCriteriaAutomatically = true
            // TEST: all buffering/stall behavior left at AVPlayer defaults
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

            Orientation.allowVideo()
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
                let detail = try await app.resolveStream(request.videoID)
                guard !Task.isCancelled else { return }
                guard let built = await Self.makePlayerItem(detail) else {
                    showError(on: controller, PipedError.noPlayableStream.localizedDescription)
                    return
                }
                guard !Task.isCancelled else { return }
                let item = built.item
                usedComposition = built.composed
                // TEST: leave preferredForwardBufferDuration at its default (0 = system-managed).
                let baseMetadata = Self.metadata(detail, request)
                item.externalMetadata = baseMetadata
                player.replaceCurrentItem(with: item)
                installEndObserver(for: item)
                configureAccessibleMedia(detail: detail, player: player, controller: controller)
                if built.composed { observeForFailure(item, detail: detail, player: player) }
                attachArtwork(to: item,
                              urlString: detail.thumbnailUrl ?? request.thumbnail,
                              base: baseMetadata)

                currentDetail = detail
                installInfoButton(on: controller)
                // Resume from a saved position (ignore if we're at/near the end).
                if let resume = savedPosition(for: request.videoID),
                   resume >= Self.minWatchSeconds {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                // TEST: default playback start (waits to minimize stalling) instead of playImmediately.
                player.play()
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
            let metadata = Self.localMetadata(request)
            let item = AVPlayerItem(url: fileURL)
            item.externalMetadata = metadata
            player.replaceCurrentItem(with: item)
            installEndObserver(for: item)
            configureAccessibleLocalMedia(request: request, player: player, controller: controller)
            attachArtwork(to: item, urlString: request.thumbnail, base: metadata)
            recordHistory(request)
            Task {
                if let resume = savedPosition(for: request.videoID), resume >= Self.minWatchSeconds {
                    await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                player.play()
                installProgressTracking(on: player)
            }
        }

        // MARK: Resume / progress tracking

        private func savedPosition(for videoID: String) -> Double? {
            let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == videoID })
            guard let entry = try? modelContext.fetch(descriptor).first else { return nil }
            // Don't resume if they finished it (within 10s of the end).
            if entry.durationSeconds > 0, entry.positionSeconds >= entry.durationSeconds - 10 { return nil }
            return entry.positionSeconds
        }

        private func installProgressTracking(on player: AVPlayer) {
            if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
            timeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.savePosition(time.seconds) }
            }
        }

        private func savePosition(_ seconds: Double) {
            guard let id = currentRequest?.videoID, seconds.isFinite,
                  seconds >= Self.minWatchSeconds else { return }
            let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == id })
            guard let entry = try? modelContext.fetch(descriptor).first else { return }
            entry.positionSeconds = seconds
            if entry.durationSeconds == 0,
               let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 {
                entry.durationSeconds = d
            }
            entry.watchedAt = .now
        }

        // MARK: Queue advancement

        private func installEndObserver(for item: AVPlayerItem) {
            removeEndObserver()
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
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
            player.replaceCurrentItem(with: nil)
            loadTask = Task { await load(next, player: player, controller: controller) }
        }

        private func resetForItemReplacement(on player: AVPlayer) {
            loadTask?.cancel()
            loadTask = nil
            captionTask?.cancel()
            captionTask = nil
            if let timeObserver { player.removeTimeObserver(timeObserver) }
            if let sponsorObserver { player.removeTimeObserver(sponsorObserver) }
            if let captionObserver { player.removeTimeObserver(captionObserver) }
            if let infoCommentTimeObserver { player.removeTimeObserver(infoCommentTimeObserver) }
            timeObserver = nil
            sponsorObserver = nil
            captionObserver = nil
            infoCommentTimeObserver = nil
            sponsorSegments = []
            sponsorModel.prompt = nil
            captionModel.reset()
            removeEndObserver()
            statusObservation?.invalidate()
            statusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            infoButtonModel.isPaused = false
            infoPlaybackTime.seconds = nil
            usedComposition = false
            currentDetail = nil
            infoButtonHost?.willMove(toParent: nil)
            infoButtonHost?.view.removeFromSuperview()
            infoButtonHost?.removeFromParent()
            infoButtonHost = nil
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
                guard let self, self.presentedID == videoID else { return }
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
                MainActor.assumeIsolated { self?.updateSponsorPrompt(at: time.seconds) }
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

        // MARK: Captions + audio descriptions

        private func configureAccessibleMedia(
            detail: VideoDetail,
            player: AVPlayer,
            controller: AVPlayerViewController
        ) {
            guard SystemMediaAccessibility.shouldShowCaptions,
                  let subtitle = detail.preferredSubtitle(
                    preferredLanguages: SystemMediaAccessibility.preferredCaptionLanguages)
            else {
                captionModel.reset()
                return
            }
            installCaptionOverlay(on: controller)
            loadCaptions(from: subtitle, player: player)
        }

        private func configureAccessibleLocalMedia(
            request: PlayRequest,
            player: AVPlayer,
            controller: AVPlayerViewController
        ) {
            guard SystemMediaAccessibility.shouldShowCaptions, let url = request.localCaptionURL else {
                captionModel.reset()
                return
            }
            installCaptionOverlay(on: controller)
            loadCaptions(from: url, mimeType: request.localCaptionMimeType, player: player)
        }

        private func installCaptionOverlay(on controller: AVPlayerViewController) {
            guard captionHost == nil, let overlay = controller.contentOverlayView else { return }
            let host = UIHostingController(rootView: CaptionOverlayView(model: captionModel))
            host.view.backgroundColor = .clear
            host.view.translatesAutoresizingMaskIntoConstraints = false
            controller.addChild(host)
            overlay.insertSubview(host.view, at: 0)
            host.didMove(toParent: controller)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor)
            ])
            captionHost = host
        }

        private func loadCaptions(from subtitle: Subtitle, player: AVPlayer) {
            captionTask?.cancel()
            captionModel.reset()
            captionTask = Task { [weak self] in
                let cues = await CaptionLoader.load(subtitle)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.captionModel.setCues(cues)
                    self.installCaptionTracking(on: player)
                }
            }
        }

        private func loadCaptions(from url: URL, mimeType: String?, player: AVPlayer) {
            captionTask?.cancel()
            captionModel.reset()
            captionTask = Task { [weak self] in
                let cues = await CaptionLoader.load(url: url, mimeType: mimeType)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.captionModel.setCues(cues)
                    self.installCaptionTracking(on: player)
                }
            }
        }

        private func installCaptionTracking(on player: AVPlayer) {
            if let captionObserver { player.removeTimeObserver(captionObserver); self.captionObserver = nil }
            captionObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.captionModel.update(at: time.seconds) }
            }
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
                cleanup()
                clearRequest()
            }
        }

        // MARK: Dismissal

        /// Fired when the presented player disappears. Ignore the dismissal that
        /// happens automatically when PiP takes over.
        func playerWasDismissed() {
            guard presentedID != nil, !pipActive else { return }
            cleanup()
            clearRequest()
        }

        private func dismissPlayer() {
            presenter?.dismiss(animated: true)
            cleanup()
        }

        private func cleanup() {
            hardStop()
            Orientation.lockPortrait()
        }

        private func hardStop() {
            loadTask?.cancel()
            loadTask = nil
            captionTask?.cancel()
            captionTask = nil
            if let player {
                if let t = player.currentTime().seconds as Double?, t.isFinite { savePosition(t) }
                if let timeObserver { player.removeTimeObserver(timeObserver) }
                if let sponsorObserver { player.removeTimeObserver(sponsorObserver) }
                if let captionObserver { player.removeTimeObserver(captionObserver) }
                if let infoCommentTimeObserver { player.removeTimeObserver(infoCommentTimeObserver) }
            }
            timeObserver = nil
            sponsorObserver = nil
            captionObserver = nil
            infoCommentTimeObserver = nil
            removeEndObserver()
            sponsorSegments = []
            sponsorModel.prompt = nil
            captionModel.reset()
            statusObservation?.invalidate()
            statusObservation = nil
            timeControlObservation?.invalidate()
            timeControlObservation = nil
            infoButtonModel.isPaused = false
            infoPlaybackTime.seconds = nil
            usedComposition = false
            infoButtonHost?.willMove(toParent: nil)
            infoButtonHost?.view.removeFromSuperview()
            infoButtonHost?.removeFromParent()
            infoButtonHost = nil
            skipButtonHost?.willMove(toParent: nil)
            skipButtonHost?.view.removeFromSuperview()
            skipButtonHost?.removeFromParent()
            skipButtonHost = nil
            captionHost?.willMove(toParent: nil)
            captionHost?.view.removeFromSuperview()
            captionHost?.removeFromParent()
            captionHost = nil
            player?.pause()
            player = nil
            playerVC = nil
            presentedID = nil
            currentRequest = nil
            currentDetail = nil
            pipActive = false
            detachedForBackground = false
        }

        private func showError(on controller: AVPlayerViewController, _ message: String) {
            let alert = UIAlertController(title: "Couldn’t play video", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.presenter?.dismiss(animated: true)
            })
            controller.present(alert, animated: true)
        }

        private func recordHistory(_ detail: VideoDetail, _ request: PlayRequest) {
            let id = request.videoID
            let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == id })
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.watchedAt = .now
            } else {
                modelContext.insert(HistoryEntry(
                    videoID: id,
                    title: detail.title ?? request.title,
                    uploader: detail.uploader ?? request.uploader,
                    thumbnailURL: detail.thumbnailUrl ?? request.thumbnail))
            }
        }

        /// History for offline playback, where only the request fields are known.
        private func recordHistory(_ request: PlayRequest) {
            let id = request.videoID
            let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == id })
            if let existing = try? modelContext.fetch(descriptor).first {
                existing.watchedAt = .now
            } else {
                modelContext.insert(HistoryEntry(
                    videoID: id, title: request.title,
                    uploader: request.uploader, thumbnailURL: request.thumbnail))
            }
        }

        // MARK: Info panel (title · description · subscribe)

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
            timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
                [weak self] player, _ in
                MainActor.assumeIsolated {
                    self?.infoButtonModel.isPaused = player.timeControlStatus == .paused
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
                MainActor.assumeIsolated { self?.updateInfoPlaybackTime(time.seconds) }
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
                description: HTMLText.plain(detail.description ?? ""),
                canSubscribe: channelID != nil,
                isSubscribed: channelID.map(isCurrentlySubscribed) ?? false,
                onToggleSubscribe: { [weak self] subscribed in
                    self?.setSubscription(channelID: channelID, name: name,
                                          avatar: avatar, subscribed: subscribed)
                },
                showFeedback: FeedMode.current.isPersonalized,
                feedback: currentFeedbackSignal(),
                onFeedback: { [weak self] signal in self?.setFeedback(signal) },
                queue: detail.relatedStreams ?? [],
                onQueuePlay: { [weak self, weak host] item in
                    guard let self else { return }
                    if let sheet = host?.presentedViewController {
                        sheet.dismiss(animated: true) { self.playQueued(item) }
                    } else {
                        self.playQueued(item)
                    }
                },
                client: client,
                videoID: videoID,
                playbackTime: infoPlaybackTime,
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

        private func playQueued(_ item: StreamItem) {
            guard let request = PlayRequest(item: item) else { return }
            if let player, let controller = playerVC {
                restartPlayback(with: request, player: player, controller: controller)
            }
            app.nowPlaying = request
        }

        private func restartPlayback(with request: PlayRequest, player: AVPlayer, controller: AVPlayerViewController) {
            loadTask?.cancel()
            loadTask = nil
            if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
            if let sponsorObserver { player.removeTimeObserver(sponsorObserver); self.sponsorObserver = nil }
            statusObservation?.invalidate()
            statusObservation = nil
            sponsorSegments = []
            sponsorModel.prompt = nil
            usedComposition = false
            currentDetail = nil
            currentRequest = request
            presentedID = request.videoID
            player.pause()
            player.replaceCurrentItem(with: nil)
            loadTask = Task { await load(request, player: player, controller: controller) }
        }

        private func isCurrentlySubscribed(_ channelID: String) -> Bool {
            let descriptor = FetchDescriptor<SubscribedChannel>(
                predicate: #Predicate { $0.channelID == channelID })
            return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
        }

        private func setSubscription(channelID: String?, name: String?, avatar: String?, subscribed: Bool) {
            guard let channelID else { return }
            let descriptor = FetchDescriptor<SubscribedChannel>(
                predicate: #Predicate { $0.channelID == channelID })
            let existing = (try? modelContext.fetch(descriptor))?.first
            if subscribed {
                if existing == nil {
                    modelContext.insert(SubscribedChannel(
                        channelID: channelID, name: name ?? "Channel", avatarURL: avatar))
                }
            } else if let existing {
                modelContext.delete(existing)
            }
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
        private static let supportsAV1: Bool = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

        /// Builds the highest-quality playable item: first try composing the best
        /// video-only + audio streams (1080p H.264, or AV1 4K where supported);
        /// fall back to HLS / progressive (<=720p) if composition isn't possible.
        /// `composed` indicates the high-quality path was taken (so callers can
        /// watch for runtime failure and retry with the simple URL).
        private static func makePlayerItem(_ detail: VideoDetail) async -> (item: AVPlayerItem, composed: Bool)? {
            // Diagnostic: what did the instance actually offer? Reveals whether
            // AV1 / >1080p streams even exist for this video on this instance.
            let inventory = (detail.videoStreams ?? [])
                .sorted { ($0.height ?? 0) > ($1.height ?? 0) }
                .map { "\($0.height ?? 0)p:\($0.codec ?? $0.mimeType ?? "?")\($0.isProgressive ? "(prog)" : "")" }
                .joined(separator: ", ")
            NSLog("Atlas.player: 📺 videoStreams = [\(inventory)] | hls: \(detail.hls?.isEmpty == false) | AV1 hw: \(supportsAV1)")

            if let source = detail.bestComposedSource(allowAV1: supportsAV1) {
                NSLog("Atlas.player: best compose-able source = \(source.height)p (AV1 allowed: \(supportsAV1))")
                if let composed = await composedItem(video: source.video, audio: source.audio) {
                    NSLog("Atlas.player: ✅ composed \(source.height)p item")
                    return (composed, true)
                }
                NSLog("Atlas.player: ⚠️ composition failed, falling back")
            } else {
                NSLog("Atlas.player: no compose-able video-only+audio pair (HLS present: \(detail.hls?.isEmpty == false))")
            }
            guard let url = detail.playableURL else { return nil }
            NSLog("Atlas.player: ▶️ fallback URL = \(url.absoluteString.prefix(60))…")
            return (AVPlayerItem(url: url), false)
        }

        /// If a composed item fails to actually play, swap to the simple HLS/progressive URL.
        private func observeForFailure(_ item: AVPlayerItem, detail: VideoDetail, player: AVPlayer) {
            statusObservation?.invalidate()
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.usedComposition,
                          let url = detail.playableURL else { return }
                    self.usedComposition = false
                    self.statusObservation?.invalidate()
                    self.statusObservation = nil
                    let resume = player.currentTime()
                    let fallback = AVPlayerItem(url: url)
                    fallback.externalMetadata = Self.metadata(detail, self.currentRequest ?? PlayRequest(
                        videoID: detail.channelID ?? "", title: detail.title ?? ""))
                    player.replaceCurrentItem(with: fallback)
                    self.installEndObserver(for: fallback)
                    await player.seek(to: resume)
                    player.playImmediately(atRate: 1.0)
                }
            }
        }

        /// Merges separate remote video-only and audio tracks into one playable item.
        private static func composedItem(video videoURL: URL, audio audioURL: URL) async -> AVPlayerItem? {
            let videoAsset = AVURLAsset(url: videoURL)
            let audioAsset = AVURLAsset(url: audioURL)
            let composition = AVMutableComposition()
            do {
                guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                      let aTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                    NSLog("Atlas.player: composition aborted — missing video or audio track")
                    return nil
                }
                let vDuration = try await videoAsset.load(.duration)
                let range = CMTimeRange(start: .zero, duration: vDuration)

                guard let vComp = composition.addMutableTrack(
                        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                      let aComp = composition.addMutableTrack(
                        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    return nil
                }
                try vComp.insertTimeRange(range, of: vTrack, at: .zero)
                // Audio track may be a hair shorter/longer; clamp to its own duration.
                let aDuration = try await audioAsset.load(.duration)
                let aRange = CMTimeRange(start: .zero, duration: min(vDuration, aDuration))
                try aComp.insertTimeRange(aRange, of: aTrack, at: .zero)

                return AVPlayerItem(asset: composition)
            } catch {
                NSLog("Atlas.player: composition threw — \(error.localizedDescription)")
                return nil   // fall back to HLS/progressive
            }
        }

        /// Fetches the thumbnail and attaches it as artwork so the lock screen /
        /// Now Playing shows the video image. Done after playback starts so it
        /// never delays the video.
        private func attachArtwork(to item: AVPlayerItem, urlString: String?, base: [AVMetadataItem]) {
            guard let urlString, let url = URL(string: urlString) else { return }
            Task { [weak item] in
                let data: Data? = url.isFileURL
                    ? try? Data(contentsOf: url)
                    : (try? await URLSession.shared.data(from: url))?.0
                guard let data, let image = UIImage(data: data),
                      let jpeg = image.jpegData(compressionQuality: 0.9) else { return }
                let art = AVMutableMetadataItem()
                art.identifier = .commonIdentifierArtwork
                art.value = jpeg as NSData
                art.dataType = kCMMetadataBaseDataType_JPEG as String
                art.extendedLanguageTag = "und"
                await MainActor.run {
                    guard let item else { return }
                    item.externalMetadata = base + [art]
                }
            }
        }

        /// Now Playing metadata for an offline file, built from the request alone.
        private static func localMetadata(_ request: PlayRequest) -> [AVMetadataItem] {
            func item(_ identifier: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
                guard let value, !value.isEmpty else { return nil }
                let m = AVMutableMetadataItem()
                m.identifier = identifier
                m.value = value as NSString
                m.extendedLanguageTag = "und"
                m.dataType = kCMMetadataBaseDataType_UTF8 as String
                return m
            }
            return [
                item(.commonIdentifierTitle, request.title),
                item(.iTunesMetadataTrackSubTitle, request.uploader)
            ].compactMap { $0 }
        }

        private static func metadata(_ detail: VideoDetail, _ request: PlayRequest) -> [AVMetadataItem] {
            let descLen = HTMLText.plain(detail.description ?? "").count
            NSLog("Atlas.player: description length from instance = \(descLen) chars")
            func item(_ identifier: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
                guard let value, !value.isEmpty else { return nil }
                let m = AVMutableMetadataItem()
                m.identifier = identifier
                m.value = value as NSString
                m.extendedLanguageTag = "und"
                m.dataType = kCMMetadataBaseDataType_UTF8 as String
                return m
            }
            return [
                item(.commonIdentifierTitle, detail.title ?? request.title),
                item(.iTunesMetadataTrackSubTitle, detail.uploader ?? request.uploader),
                item(.commonIdentifierDescription, HTMLText.plain(detail.description ?? ""))
            ].compactMap { $0 }
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
