import AVKit
import CoreMedia
import MediaPlayer
import Observation
import PipedKit
import SwiftData

/// Owns the `AVPlayer` for the embedded player and mirrors the full-screen
/// player's data work — stream resolution, resume, progress tracking, history,
/// subscribe, and feedback — independently, so the original player is untouched.
@MainActor
@Observable
final class EmbeddedPlayerModel {
    /// Lazy so the models SwiftUI constructs and immediately discards while
    /// re-evaluating the cover content (only the first `@State` value is
    /// kept) never pay for a live `AVPlayer`. Body only touches `player` on
    /// the installed model.
    @ObservationIgnored private(set) lazy var player: AVPlayer = {
        let player = AVPlayer()
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        return player
    }()
    /// Transport state for the custom controls overlay (see
    /// `EmbeddedPlayerModel+Controls`).
    let playbackState = EmbeddedPlaybackState()
    /// The `AVPlayerLayer` host. Owned by the model rather than the SwiftUI
    /// representable so it survives the cover being dismissed during PiP and
    /// can be re-parented between the inline and full-screen layouts.
    @ObservationIgnored private(set) lazy var layerView: EmbeddedPlayerLayerView = {
        let view = EmbeddedPlayerLayerView()
        view.playerLayer.player = player
        return view
    }()
    /// Lock-screen / Control Center metadata and remote commands.
    @ObservationIgnored let nowPlaying = EmbeddedNowPlaying()
    @ObservationIgnored var pipController: AVPictureInPictureController?
    @ObservationIgnored lazy var pipDelegate: EmbeddedPiPDelegate = {
        let delegate = EmbeddedPiPDelegate()
        delegate.model = self
        return delegate
    }()
    @ObservationIgnored var pipPossibleObservation: NSKeyValueObservation?
    @ObservationIgnored var scrubSeekInFlight = false
    @ObservationIgnored var wasPlayingBeforeScrub = false
    /// Keeps the model (and with it the player, layer, and PiP controller)
    /// alive while PiP outlives the dismissed cover.
    @ObservationIgnored static var pipRetainer: EmbeddedPlayerModel?
    var request: PlayRequest
    var historySession: PlaybackHistorySession?
    var detail: VideoDetail?
    /// `detail.description` stripped of HTML once when the detail arrives —
    /// body re-evaluates every playback tick, so it must not re-parse there.
    var plainDescription = ""
    /// When `detail`'s URLs were resolved — runtime fallback uses this to
    /// decide whether they may have expired.
    var detailLoadedAt: Date?
    var errorMessage: String?
    var currentPlaybackSeconds: Double?
    var client: PipedClient?
    /// Policy client captured alongside `client`; fallbacks, upgrades, artwork,
    /// and PiP remain pinned to the instance generation that resolved the item.
    var httpClient: PolicyHTTPClient?
    /// Flips true the moment a player item is set, so the inline controller is
    /// only attached to a player that has something to play.
    var isReady = false

    let app: AppModel
    let modelContext: ModelContext
    var loadTask: Task<Void, Never>?
    var timeObserver: Any?
    var endObserver: NSObjectProtocol?
    var itemDiagnosticObservers: [NSObjectProtocol] = []
    var statusObservation: NSKeyValueObservation?
    var timeControlObservation: NSKeyValueObservation?
    var fallbackCheckTask: Task<Void, Never>?
    var upgradeTask: Task<Void, Never>?
    var activePlaybackSource = "unknown"
    var fallbackInProgress = false
    private var started = false
    /// PiP keeps playing after the cover is dismissed; while it's active,
    /// `viewDisappeared()` defers teardown until PiP ends.
    private var pipActive = false
    private var teardownDeferredForPiP = false
    var lastProgressSaveSeconds: Double?
    let debugModel = PlayerDebugModel()
    /// A pinch in full screen fixes fill vs. letterbox for the rest of the
    /// video; `nil` leaves it to `applyFullscreenFill`.
    @ObservationIgnored var fullscreenFillChoice: Bool?
    /// SponsorBlock (see `EmbeddedPlayerModel+SponsorBlock`).
    let sponsorModel = SponsorSkipModel()
    @ObservationIgnored var sponsorSegments: [SponsorSegment] = []
    @ObservationIgnored var sponsorTask: Task<Void, Never>?

    static let supportsAV1 = StreamPlaybackBuilder.deviceSupportsAV1

    init(request: PlayRequest, app: AppModel, modelContext: ModelContext) {
        self.request = request
        self.app = app
        self.modelContext = modelContext
    }

    func start() {
        guard !started else { return }
        started = true
        installControls()
        historySession = PlaybackHistoryStore.beginSession(
            videoID: request.videoID, in: modelContext)
        updateFavoritesCommand(for: request)
        if let local = request.localURL {
            loadLocal(local)
        } else {
            loadTask = Task { await load() }
        }
    }

    func retry() {
        teardown()
        detail = nil
        plainDescription = ""
        detailLoadedAt = nil
        errorMessage = nil
        isReady = false
        started = false
        start()
    }

    func load() async {
        do {
            let client = try app.client
            let httpClient = try app.httpClient
            let detail = try await app.resolveStreamForPlayback(request.videoID)
            guard !Task.isCancelled else { return }
            // Only try AV1 HLS when it can actually work: the device decodes AV1
            // and the instance extracted AV1 streams (otherwise the /hls/av1
            // endpoint 404s and AVPlayer fails before falling back).
            let av1HLSURL =
                (Self.supportsAV1 && detail.hasAV1VideoStream)
                ? client.av1HLSMasterURL(videoID: request.videoID)
                : nil
            guard
                let playback = await StreamPlaybackBuilder.makePlayerItem(
                    detail,
                    allowAV1: Self.supportsAV1,
                    av1HLSURL: av1HLSURL,
                    client: httpClient
                )
            else {
                errorMessage = PipedError.noPlayableStream.localizedDescription
                return
            }
            guard !Task.isCancelled else { return }
            let initialItem = playback.item
            if playback.selectsPreferredAudio {
                await PlayerAudioSelection.selectPreferredAudio(for: initialItem)
                guard !Task.isCancelled else { return }
            }
            let baseMetadata = PlayerNowPlayingMetadata.streaming(detail, request: request)
            initialItem.externalMetadata = baseMetadata
            playbackState.isLive = detail.isCurrentlyLive
            Self.configureLiveEdge(initialItem, live: detail.livestream == true)
            player.replaceCurrentItem(with: initialItem)
            PlayerCaptionSelection.keepOffByDefault(for: initialItem)
            installEndObserver(for: initialItem)
            installItemDiagnostics(
                for: initialItem,
                videoID: request.videoID,
                source: playback.sourceName)
            debugModel.configure(detail: detail, composed: playback.composed, allowAV1: Self.supportsAV1)
            installPlaybackDiagnostics()
            PlaybackDiagnostics.start(videoID: request.videoID, source: playback.sourceName)
            isReady = true
            if playback.failureFallback != .none {
                observeForFailure(
                    initialItem,
                    detail: detail,
                    fallback: playback.failureFallback,
                    stallFallbackDelay: playback.stallFallbackDelay)
            }
            PlayerNowPlayingMetadata.attachArtwork(
                to: initialItem,
                urlString: detail.thumbnailURL ?? request.thumbnail,
                base: baseMetadata,
                client: httpClient)
            self.client = client
            self.httpClient = httpClient
            self.detail = detail
            plainDescription = HTMLText.plain(detail.description ?? "")
            detailLoadedAt = app.streamResolvedAt(request.videoID) ?? Date()
            // A live stream starts at the live edge; a saved position would
            // land somewhere arbitrary inside the DVR window. Piped's flag
            // isn't always set for a running stream, so the asset's own
            // (indefinite) duration is the deciding check.
            if let resume = savedPosition(for: request.videoID),
                resume >= PlaybackHistoryStore.minWatchSeconds,
                await isResumable(initialItem, detail: detail)
            {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            // The seek can outlive this playback (teardown cancels the load):
            // don't resume audio or install observers afterwards.
            guard !Task.isCancelled else { return }
            player.play()
            nowPlaying.publish(
                title: detail.title ?? request.title,
                artist: detail.uploader ?? request.uploader,
                artworkURL: detail.thumbnailURL ?? request.thumbnail,
                client: httpClient,
                isLive: detail.livestream == true)
            // A start that never becomes playback (buffering that never
            // completes) fires no stall notification and no failure, so
            // watch for it explicitly.
            if playback.failureFallback != .none {
                scheduleFallbackIfStillStalled(
                    initialItem,
                    detail: detail,
                    fallback: playback.failureFallback,
                    delay: playback.stallFallbackDelay)
            }
            if let upgrade = playback.composedUpgrade {
                scheduleComposedUpgrade(
                    upgrade,
                    from: initialItem,
                    detail: detail,
                    client: httpClient)
            }
            installProgressTracking()
            loadSponsorSegments(client: client)
            recordHistory(detail)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Live items catch back up after a stall: AVFoundation restores the
    /// offset from the live edge the playhead had before buffering, so a
    /// hiccup doesn't leave the stream permanently behind.
    static func configureLiveEdge(_ item: AVPlayerItem, live: Bool) {
        item.automaticallyPreservesTimeOffsetFromLive = live
    }

    /// False for anything live: the detail says so, or the asset reports an
    /// indefinite duration once loaded (an HLS live playlist). Loading the
    /// duration waits on the same manifest fetch playback needs anyway.
    private func isResumable(_ item: AVPlayerItem, detail: VideoDetail) async -> Bool {
        if detail.livestream == true {
            playbackState.isLive = true
            PlaybackDiagnostics.message("resume-skipped-live-flag", videoID: request.videoID)
            return false
        }
        guard let duration = try? await item.asset.load(.duration) else {
            PlaybackDiagnostics.message("resume-skipped-no-duration", videoID: request.videoID)
            return false
        }
        guard !Task.isCancelled else { return false }
        if duration.isIndefinite || !duration.isNumeric {
            playbackState.isLive = true
            PlaybackDiagnostics.message("resume-skipped-indefinite", videoID: request.videoID)
            return false
        }
        PlaybackDiagnostics.message(
            "resume-allowed-duration-\(Int(duration.seconds))", videoID: request.videoID)
        return duration.seconds > 0
    }

    func loadLocal(_ fileURL: URL) {
        let metadata = PlayerNowPlayingMetadata.local(request)
        let item = AVPlayerItem(url: fileURL)
        item.externalMetadata = metadata
        player.replaceCurrentItem(with: item)
        PlayerCaptionSelection.keepOffByDefault(for: item)
        installEndObserver(for: item)
        installItemDiagnostics(for: item, videoID: request.videoID, source: "local")
        debugModel.configureLocal()
        installPlaybackDiagnostics()
        PlaybackDiagnostics.start(videoID: request.videoID, source: "local")
        isReady = true
        PlayerNowPlayingMetadata.attachArtwork(
            to: item,
            urlString: request.thumbnail,
            base: metadata,
            client: AppModel.publicHTTPClient)
        recordHistoryLocal()
        // Tied to `loadTask` so teardown cancels it; otherwise the seek could
        // resume an orphaned player and install a time observer that is never
        // removed.
        loadTask = Task {
            if let resume = savedPosition(for: request.videoID),
                resume >= PlaybackHistoryStore.minWatchSeconds
            {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            guard !Task.isCancelled else { return }
            player.play()
            nowPlaying.publish(
                title: request.title,
                artist: request.uploader,
                artworkURL: request.thumbnail,
                client: AppModel.publicHTTPClient,
                isLive: false)
            installProgressTracking()
        }
    }

    /// Called when the cover disappears. Tears down immediately unless PiP is
    /// running (mirrors the fullscreen presenter's `pipActive` guard) — then
    /// teardown waits for PiP to end so the picture doesn't go black.
    func viewDisappeared() {
        if pipActive {
            teardownDeferredForPiP = true
        } else {
            teardown()
        }
    }

    /// The cover is coming back (PiP's "return to app"): the teardown that
    /// was queued when it was dismissed must not fire when PiP now stops.
    func cancelDeferredTeardown() {
        teardownDeferredForPiP = false
    }

    func setPiPActive(_ active: Bool) {
        pipActive = active
        if !active, teardownDeferredForPiP {
            teardownDeferredForPiP = false
            teardown()
        }
    }

    /// Closing the cover while the video is playing hands it to Picture in
    /// Picture over whatever screen was beneath, rather than stopping it.
    /// Returns false when PiP can't take it (no controller yet, not possible,
    /// or paused), in which case the caller just dismisses and playback ends.
    ///
    /// `pipActive` and the retainer are set up front: the delegate's did-start
    /// arrives after the cover has already disappeared, and `viewDisappeared`
    /// must not tear the player down in between. A start that fails reports
    /// through `pipDidStop`, which runs the deferred teardown then.
    @discardableResult
    func handOffToPictureInPicture() -> Bool {
        guard let pipController, pipController.isPictureInPicturePossible else { return false }
        if pipController.isPictureInPictureActive { return true }
        guard playbackState.isPlaying else { return false }
        pipActive = true
        Self.pipRetainer = self
        pipController.startPictureInPicture()
        return true
    }

    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        fallbackCheckTask?.cancel()
        fallbackCheckTask = nil
        upgradeTask?.cancel()
        upgradeTask = nil
        let t = player.currentTime().seconds
        if t.isFinite { savePosition(t, flush: true) }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        removeEndObserver()
        removeItemDiagnostics()
        clearSponsorSegments()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        activePlaybackSource = "unknown"
        fallbackInProgress = false
        debugModel.reset()
        currentPlaybackSeconds = nil
        client = nil
        httpClient = nil
        lastProgressSaveSeconds = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeControls()
        if app.nowPlaying == nil || app.nowPlaying?.videoID == request.videoID {
            updateFavoritesCommand(for: nil)
        }
    }
}
