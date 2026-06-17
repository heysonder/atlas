import SwiftUI
import SwiftData
import Observation
import AVKit
import CoreMedia
import VideoToolbox
import PipedKit

/// The "Embedded" player (opt-in via Settings): plays the video inline at the
/// top of a scrolling page, with the shared `PlayerInfoContent` — channel row,
/// description, and comments — beneath it. The native full-screen player
/// (`VideoPlayerPresenter`) is untouched and remains the default.
struct EmbeddedPlayerView: View {
    @State private var model: EmbeddedPlayerModel
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    init(request: PlayRequest, app: AppModel, modelContext: ModelContext) {
        _model = State(initialValue: EmbeddedPlayerModel(
            request: request, app: app, modelContext: modelContext))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                videoArea
                infoArea
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
        }
        .task { model.start() }
        .onDisappear {
            model.teardown()
        }
    }

    // MARK: Video

    /// The inline player, sized to the video's aspect ratio and pinned to the
    /// top. The native controls include an "expand" button for true full screen
    /// (landscape) and PiP — so nothing is lost versus the full-screen player.
    private var videoArea: some View {
        InlineVideoPlayer(player: model.player, isReady: model.isReady, onClose: { dismiss() })
            .aspectRatio(model.detail?.aspectRatio ?? 16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .overlay {
                if app.statsForNerdsEnabled {
                    PlayerDebugOverlay(model: model.debugModel)
                }
            }
            .overlay {
                if !model.isReady && model.errorMessage == nil {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
    }

    // MARK: Info

    @ViewBuilder private var infoArea: some View {
        if let detail = model.detail {
            if let client = model.client {
                ScrollView {
                    PlayerInfoContent(
                        title: detail.title ?? model.request.title,
                        uploader: detail.uploader ?? model.request.uploader,
                        uploaderDisplayName: model.request.uploader ?? detail.uploader,
                        uploaderAvatar: detail.uploaderAvatar,
                        channelID: detail.channelID,
                        creators: detail.creators ?? [],
                        subscriberCount: detail.uploaderSubscriberCount,
                        uploaderVerified: detail.uploaderVerified ?? false,
                        thumbnail: detail.thumbnailUrl ?? model.request.thumbnail,
                        duration: detail.duration,
                        description: HTMLText.plain(detail.description ?? ""),
                        chapters: detail.chapters ?? [],
                        canSubscribe: detail.channelID != nil,
                        isSubscribed: model.isSubscribed(detail.channelID),
                        onToggleSubscribe: { model.setSubscription($0, detail: detail) },
                        showFeedback: FeedMode.current.isPersonalized,
                        feedback: model.currentFeedbackSignal(),
                        onFeedback: { model.setFeedback($0, detail: detail) },
                        onQueuedVideoPlay: { model.playQueued($0) },
                        client: client,
                        videoID: model.request.videoID,
                        currentPlaybackSeconds: model.currentPlaybackSeconds,
                        onTimestampTap: { model.seek(to: $0) },
                        inline: true)
                        .padding()
                }
            } else {
                ContentUnavailableView {
                    Label("Comments unavailable", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(AppModel.missingInstanceMessage)
                }
                .padding()
            }
        } else if let message = model.errorMessage {
            Spacer()
            ContentUnavailableView {
                Label("Couldn’t play video", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
            Spacer()
        } else if model.request.localURL != nil {
            ScrollView { offlineInfo.padding() }
        } else {
            // Stream still resolving — the spinner sits over the video above.
            Spacer()
        }
    }

    /// Minimal info for offline playback, where no stream details (and thus no
    /// description or comments) are fetched.
    private var offlineInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.request.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let uploader = model.request.uploader, !uploader.isEmpty {
                Text(uploader)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("Saved for offline — description and comments aren’t available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hosts an `AVPlayerViewController` inline (not full-screen-presented), giving
/// the standard transport controls, full-screen-expand button, AirPlay and PiP.
///
/// The player is attached only once `isReady` is true (i.e. its item is set).
/// Binding an inline controller to a player whose `currentItem` is still nil
/// leaves the transport stuck — center "play.slash" glyph and `--:--` time —
/// even after the item loads, so we wait until there's something to play.
private struct InlineVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let isReady: Bool
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> InlinePlayerController {
        let controller = InlinePlayerController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = .resizeAspect
        controller.onClose = onClose
        if isReady { controller.player = player }
        return controller
    }

    func updateUIViewController(_ controller: InlinePlayerController, context: Context) {
        controller.onClose = onClose
        if isReady, controller.player !== player {
            controller.player = player
        }
    }
}

/// An inline `AVPlayerViewController` that adds a custom **close (✕)** control to
/// the native transport row — sitting beside PiP / AirPlay / full-screen and
/// auto-hiding with the controls.
///
/// iOS exposes no public API for this (custom transport-bar items are tvOS-only,
/// which is why the full-screen player's "Info" button is a floating overlay
/// instead). So we reach into the controls' *private* view hierarchy: on each
/// layout pass we locate the busiest horizontal control row and append our
/// button if it isn't already attached. Everything is guarded — if a future iOS
/// reorganises the hierarchy and the row can't be found, we simply add nothing
/// (no crash; the player just lacks the extra button). Scoped to the embedded
/// player only; the full-screen `VideoPlayerPresenter` is deliberately untouched.
final class InlinePlayerController: AVPlayerViewController {
    var onClose: (() -> Void)?
    private weak var closeButton: UIButton?

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ensureCloseButton()
    }

    private func ensureCloseButton() {
        guard onClose != nil else { return }
        // Still attached from an earlier pass — leave it be.
        if let closeButton, closeButton.superview != nil { return }

        let buttons = Self.allButtons(in: view)
        guard !buttons.isEmpty else { return }   // controls not built yet (or out-of-process)

        // Strategy 1: append to the horizontal stack holding the most buttons.
        if let row = Self.bestControlRow(in: view) {
            let button = makeCloseButton()
            row.addArrangedSubview(button)
            closeButton = button
            return
        }

        // Strategy 2 (no stack): sit beside the bottom-most control button, in its superview.
        guard let anchor = buttons.max(by: {
            let a = $0.convert($0.bounds, to: view), b = $1.convert($1.bounds, to: view)
            return (a.maxY, a.maxX) < (b.maxY, b.maxX)
        }), let bar = anchor.superview else { return }
        let button = makeCloseButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: anchor.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: anchor.trailingAnchor, constant: 16)
        ])
        closeButton = button
    }

    private func makeCloseButton() -> UIButton {
        let button = UIButton(type: .system)
        let config = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
        button.setImage(UIImage(systemName: "xmark", withConfiguration: config), for: .normal)
        button.tintColor = .white
        button.accessibilityLabel = "Close"
        button.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        return button
    }

    private static func allButtons(in root: UIView) -> [UIButton] {
        var found: [UIButton] = []
        func walk(_ v: UIView) {
            if let b = v as? UIButton { found.append(b) }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    /// The most likely transport-control row: the horizontal `UIStackView` with
    /// the most buttons, breaking ties toward the lowest one on screen (the
    /// bottom bar, where PiP / AirPlay / full-screen live).
    private static func bestControlRow(in root: UIView) -> UIStackView? {
        var best: UIStackView?
        var bestButtons = 0
        var bestY: CGFloat = 0
        func walk(_ v: UIView) {
            if let stack = v as? UIStackView, stack.axis == .horizontal {
                let buttons = stack.arrangedSubviews.reduce(into: 0) { count, sub in
                    if sub is UIButton { count += 1 }
                }
                if buttons > 0 {
                    let y = stack.convert(stack.bounds, to: root).maxY
                    if buttons > bestButtons || (buttons == bestButtons && y > bestY) {
                        best = stack; bestButtons = buttons; bestY = y
                    }
                }
            }
            for sub in v.subviews { walk(sub) }
        }
        walk(root)
        return best
    }

}

/// Owns the `AVPlayer` for the embedded player and mirrors the full-screen
/// player's data work — stream resolution, resume, progress tracking, history,
/// subscribe, and feedback — independently, so the original player is untouched.
@MainActor
@Observable
final class EmbeddedPlayerModel {
    let player = AVPlayer()
    private(set) var request: PlayRequest
    private(set) var detail: VideoDetail?
    private(set) var errorMessage: String?
    private(set) var currentPlaybackSeconds: Double?
    private(set) var client: PipedClient?
    /// Flips true the moment a player item is set, so the inline controller is
    /// only attached to a player that has something to play.
    private(set) var isReady = false

    private let app: AppModel
    private let modelContext: ModelContext
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemDiagnosticObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var compositionUpgradeTask: Task<Void, Never>?
    private var activePlaybackSource = "unknown"
    private var usedComposition = false
    private var started = false
    private var lastProgressSaveSeconds: Double?
    let debugModel = PlayerDebugModel()

    private static let supportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    init(request: PlayRequest, app: AppModel, modelContext: ModelContext) {
        self.request = request
        self.app = app
        self.modelContext = modelContext
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = false
    }

    func start() {
        guard !started else { return }
        started = true
        if let local = request.localURL {
            loadLocal(local)
        } else {
            loadTask = Task { await load() }
        }
    }

    private func load() async {
        do {
            let client = try app.client
            let detail = try await app.resolveStream(request.videoID)
            guard !Task.isCancelled else { return }
            guard let playback = await StreamPlaybackBuilder.makePlayerItem(
                detail,
                allowAV1: Self.supportsAV1
            ) else {
                errorMessage = PipedError.noPlayableStream.localizedDescription
                return
            }
            guard !Task.isCancelled else { return }
            let initialItem = playback.item
            await PlayerAudioSelection.selectPreferredAudio(for: initialItem)
            guard !Task.isCancelled else { return }
            usedComposition = playback.composed
            let baseMetadata = PlayerNowPlayingMetadata.streaming(detail, request: request)
            initialItem.externalMetadata = baseMetadata
            player.replaceCurrentItem(with: initialItem)
            PlayerCaptionSelection.keepOffByDefault(for: initialItem)
            installEndObserver(for: initialItem)
            installItemDiagnostics(
                for: initialItem,
                videoID: request.videoID,
                source: playback.composed ? "composed-initial" : "direct-initial")
            debugModel.configure(detail: detail, composed: playback.composed, allowAV1: Self.supportsAV1)
            installPlaybackDiagnostics()
            NSLog("Atlas.player: embedded start videoID=\(request.videoID) source=\(playback.composed ? "composed" : "direct")")
            isReady = true
            if playback.composed { observeForFailure(initialItem, detail: detail) }
            PlayerNowPlayingMetadata.attachArtwork(
                to: initialItem,
                urlString: detail.thumbnailUrl ?? request.thumbnail,
                base: baseMetadata)
            self.client = client
            self.detail = detail
            if let resume = savedPosition(for: request.videoID),
               resume >= PlaybackHistoryStore.minWatchSeconds {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            player.play()
            installProgressTracking()
            if !playback.composed {
                startComposedUpgradeIfAvailable(detail)
            }
            recordHistory(detail)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadLocal(_ fileURL: URL) {
        let metadata = PlayerNowPlayingMetadata.local(request)
        let item = AVPlayerItem(url: fileURL)
        item.externalMetadata = metadata
        player.replaceCurrentItem(with: item)
        PlayerCaptionSelection.keepOffByDefault(for: item)
        installEndObserver(for: item)
        installItemDiagnostics(for: item, videoID: request.videoID, source: "local")
        debugModel.configureLocal()
        installPlaybackDiagnostics()
        NSLog("Atlas.player: embedded start videoID=\(request.videoID) source=local")
        isReady = true
        PlayerNowPlayingMetadata.attachArtwork(to: item, urlString: request.thumbnail, base: metadata)
        recordHistoryLocal()
        Task {
            if let resume = savedPosition(for: request.videoID),
               resume >= PlaybackHistoryStore.minWatchSeconds {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            player.play()
            installProgressTracking()
        }
    }

    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        compositionUpgradeTask?.cancel()
        compositionUpgradeTask = nil
        let t = player.currentTime().seconds
        if t.isFinite { savePosition(t) }
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        removeEndObserver()
        removeItemDiagnostics()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        activePlaybackSource = "unknown"
        debugModel.reset()
        usedComposition = false
        currentPlaybackSeconds = nil
        client = nil
        lastProgressSaveSeconds = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
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
                NSLog("Atlas.player: embedded stalled videoID=\(videoID) source=\(source) error=\(Self.itemErrorSummary(item))")
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
                NSLog("Atlas.player: embedded failedToPlayToEnd videoID=\(videoID) source=\(source) notificationError=\(notificationError) itemError=\(Self.itemErrorSummary(item))")
            }
        })
        itemDiagnosticObservers.append(center.addObserver(
            forName: .AVPlayerItemNewErrorLogEntry,
            object: item,
            queue: .main
        ) { [weak item] _ in
            Task { @MainActor [weak item] in
                NSLog("Atlas.player: embedded errorLog videoID=\(videoID) source=\(source) error=\(Self.itemErrorSummary(item))")
            }
        })
        itemDiagnosticObservers.append(center.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                self?.debugModel.updateAccessLog(item)
                NSLog("Atlas.player: embedded accessLog videoID=\(videoID) source=\(source) \(Self.accessLogSummary(item))")
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

    private func installPlaybackDiagnostics() {
        timeControlObservation?.invalidate()
        logTimeControl()
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.logTimeControl()
            }
        }
    }

    private func logTimeControl() {
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
        let seconds = player.currentTime().seconds
        let secondsText = seconds.isFinite ? String(seconds) : "none"
        debugModel.update(player: player, source: activePlaybackSource)
        NSLog("Atlas.player: embedded timeControl videoID=\(request.videoID) source=\(activePlaybackSource) status=\(Self.timeControlStatusName(player.timeControlStatus)) reason=\(reason) rate=\(player.rate) seconds=\(secondsText) \(Self.itemStateSummary(player.currentItem))")
    }

    private func startComposedUpgradeIfAvailable(_ detail: VideoDetail) {
        guard detail.bestComposedSource(allowAV1: Self.supportsAV1) != nil else { return }
        NSLog("Atlas.player: embedded composed upgrade scheduled videoID=\(request.videoID)")
        compositionUpgradeTask?.cancel()
        let videoID = request.videoID
        compositionUpgradeTask = Task { [weak self] in
            let startedAt = Date()
            guard let composed = await StreamPlaybackBuilder.makeComposedPlayerItem(
                detail,
                allowAV1: Self.supportsAV1,
                timeout: 20
            ) else {
                NSLog("Atlas.player: embedded composed upgrade unavailable videoID=\(videoID) elapsed=\(Date().timeIntervalSince(startedAt))")
                return
            }
            guard !Task.isCancelled else { return }
            await PlayerAudioSelection.selectPreferredAudio(for: composed)
            guard !Task.isCancelled,
                  let self,
                  self.request.videoID == videoID,
                  !self.usedComposition else {
                return
            }

            let resume = self.player.currentTime()
            let wasPlaying = self.player.timeControlStatus != .paused
            let currentMetadata = self.player.currentItem?.externalMetadata ?? []
            composed.externalMetadata = currentMetadata.isEmpty
                ? PlayerNowPlayingMetadata.streaming(detail, request: self.request)
                : currentMetadata
            self.usedComposition = true
            self.player.replaceCurrentItem(with: composed)
            PlayerCaptionSelection.keepOffByDefault(for: composed)
            self.installEndObserver(for: composed)
            self.installItemDiagnostics(for: composed, videoID: videoID, source: "composed-upgrade")
            self.debugModel.configure(detail: detail, composed: true, allowAV1: Self.supportsAV1)
            self.observeForFailure(composed, detail: detail)
            if resume.isValid && resume.seconds.isFinite {
                await self.player.seek(
                    to: resume,
                    toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
            }
            if wasPlaying { self.player.playImmediately(atRate: 1.0) }
            NSLog("Atlas.player: embedded composed upgrade swapped videoID=\(videoID) seconds=\(resume.seconds) elapsed=\(Date().timeIntervalSince(startedAt))")
        }
    }

    private func playbackEndedNaturally() {
        let seconds = player.currentTime().seconds
        if seconds.isFinite { savePosition(seconds) }
        guard let next = app.dequeueNext() else { return }
        playQueued(next)
    }

    private func playQueued(_ next: PlayRequest) {
        let seconds = player.currentTime().seconds
        if seconds.isFinite { savePosition(seconds) }
        resetForItemReplacement()
        request = next
        app.nowPlaying = next
        if let local = next.localURL {
            loadLocal(local)
        } else {
            loadTask = Task { await load() }
        }
    }

    func playQueued(_ queued: QueuedVideo) {
        guard let request = app.removeFromQueue(queued) else { return }
        playQueued(request)
    }

    private func resetForItemReplacement() {
        loadTask?.cancel()
        loadTask = nil
        compositionUpgradeTask?.cancel()
        compositionUpgradeTask = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        removeEndObserver()
        removeItemDiagnostics()
        statusObservation?.invalidate()
        statusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        activePlaybackSource = "unknown"
        debugModel.reset()
        usedComposition = false
        detail = nil
        errorMessage = nil
        currentPlaybackSeconds = nil
        client = nil
        lastProgressSaveSeconds = nil
        isReady = false
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Resume / progress (shared with the full-screen player via HistoryEntry)

    private func savedPosition(for videoID: String) -> Double? {
        PlaybackHistoryStore.savedPosition(for: videoID, in: modelContext)
    }

    private func installProgressTracking() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
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
            || abs(seconds - (lastProgressSaveSeconds ?? 0)) >= PlaybackHistoryStore.minWatchSeconds {
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

    private func savePosition(_ seconds: Double) {
        PlaybackHistoryStore.savePosition(
            seconds,
            videoID: request.videoID,
            duration: player.currentItem?.duration.seconds,
            in: modelContext)
    }

    private func recordHistory(_ detail: VideoDetail) {
        PlaybackHistoryStore.record(request, detail: detail, in: modelContext)
    }

    private func recordHistoryLocal() {
        PlaybackHistoryStore.record(request, in: modelContext)
    }

    // MARK: Subscribe / feedback (shared stores with the full-screen player)

    func isSubscribed(_ channelID: String?) -> Bool {
        SubscriptionStore.isSubscribed(channelID, in: modelContext)
    }

    func setSubscription(_ subscribed: Bool, detail: VideoDetail) {
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

    func setFeedback(_ signal: Int, detail: VideoDetail) {
        FeedbackStore.set(signal, videoID: request.videoID,
                          title: detail.title ?? request.title,
                          uploader: detail.uploader ?? request.uploader,
                          category: detail.category,
                          tags: detail.tags,
                          in: modelContext)
    }

    // MARK: Composed-item fallback

    /// If a composed (video-only + audio) item fails at runtime, swap to the
    /// simple HLS/progressive URL — mirroring the full-screen player.
    private func observeForFailure(_ item: AVPlayerItem, detail: VideoDetail) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, self.usedComposition else { return }
                self.usedComposition = false
                self.statusObservation?.invalidate()
                self.statusObservation = nil
                let resume = self.player.currentTime()
                NSLog("Atlas.player: embedded composed status failed videoID=\(self.request.videoID) error=\(Self.itemErrorSummary(item))")
                guard let fallback = StreamPlaybackBuilder.fallbackPlayerItem(for: detail) else { return }
                let currentMetadata = self.player.currentItem?.externalMetadata ?? []
                fallback.externalMetadata = currentMetadata.isEmpty
                    ? PlayerNowPlayingMetadata.streaming(detail, request: self.request)
                    : currentMetadata
                await PlayerAudioSelection.selectPreferredAudio(for: fallback)
                self.player.replaceCurrentItem(with: fallback)
                PlayerCaptionSelection.keepOffByDefault(for: fallback)
                self.installEndObserver(for: fallback)
                self.installItemDiagnostics(for: fallback, videoID: self.request.videoID, source: "fallback-direct")
                self.debugModel.configure(detail: detail, composed: false, allowAV1: Self.supportsAV1)
                await self.player.seek(to: resume)
                self.player.playImmediately(atRate: 1.0)
            }
        }
    }
}
