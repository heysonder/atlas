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
        .onAppear { Orientation.allowVideo() }
        .onDisappear {
            model.teardown()
            Orientation.lockPortrait()
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
                if !model.isReady && model.errorMessage == nil {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
            .overlay {
                CaptionOverlayView(model: model.captionModel, bottomPadding: 14)
            }
    }

    // MARK: Info

    @ViewBuilder private var infoArea: some View {
        if let detail = model.detail {
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
                    canSubscribe: detail.channelID != nil,
                    isSubscribed: model.isSubscribed(detail.channelID),
                    onToggleSubscribe: { model.setSubscription($0, detail: detail) },
                    showFeedback: FeedMode.current.isPersonalized,
                    feedback: model.currentFeedbackSignal(),
                    onFeedback: { model.setFeedback($0, detail: detail) },
                    queue: detail.relatedStreams ?? [],
                    onQueuePlay: { app.play($0) },
                    client: model.client,
                    videoID: model.request.videoID,
                    currentPlaybackSeconds: model.currentPlaybackSeconds,
                    onTimestampTap: { model.seek(to: $0) },
                    inline: true)
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
    private var didScheduleDump = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        ensureCloseButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Dump the tree once, ~2s in, after the controls have had a chance to
        // build — regardless of whether we found any buttons — so we can see
        // whether the transport controls live in our process at all.
        guard !didScheduleDump else { return }
        didScheduleDump = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            Self.dumpHierarchy(self.view)
        }
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
            NSLog("Atlas.embedX: ✅ injected into UIStackView (now \(row.arrangedSubviews.count) items)")
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
        NSLog("Atlas.embedX: ✅ injected beside \(type(of: anchor)) in \(type(of: bar))")
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

    /// One-shot diagnostic: logs the controller's view tree so we can see exactly
    /// where (or whether) the transport controls live in our process.
    private static func dumpHierarchy(_ root: UIView) {
        func walk(_ v: UIView, _ depth: Int) {
            let indent = String(repeating: "·  ", count: depth)
            var tag = ""
            if let s = v as? UIStackView { tag = " [STACK \(s.axis == .horizontal ? "H" : "V") arranged=\(s.arrangedSubviews.count)]" }
            else if v is UIButton { tag = " [BUTTON]" }
            else if v is UIControl { tag = " [CONTROL]" }
            NSLog("Atlas.embedX: \(indent)\(type(of: v))\(tag) \(v.frame.debugDescription) hidden=\(v.isHidden) alpha=\(v.alpha)")
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        NSLog("Atlas.embedX: ── view hierarchy dump ──")
        walk(root, 0)
        NSLog("Atlas.embedX: ── end dump ──")
    }
}

/// Owns the `AVPlayer` for the embedded player and mirrors the full-screen
/// player's data work — stream resolution, resume, progress tracking, history,
/// subscribe, and feedback — independently, so the original player is untouched.
@MainActor
@Observable
final class EmbeddedPlayerModel {
    let player = AVPlayer()
    let captionModel = CaptionOverlayModel()
    private(set) var request: PlayRequest
    private(set) var detail: VideoDetail?
    private(set) var errorMessage: String?
    private(set) var currentPlaybackSeconds: Double?
    /// Flips true the moment a player item is set, so the inline controller is
    /// only attached to a player that has something to play.
    private(set) var isReady = false

    private let app: AppModel
    private let modelContext: ModelContext
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var captionObserver: Any?
    private var captionTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var usedComposition = false
    private var started = false
    private var lastProgressSaveSeconds: Double?

    private static let minWatchSeconds: Double = 5
    private static let supportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    var client: PipedClient { try! app.client }

    init(request: PlayRequest, app: AppModel, modelContext: ModelContext) {
        self.request = request
        self.app = app
        self.modelContext = modelContext
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
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
            let detail = try await app.resolveStream(request.videoID)
            guard !Task.isCancelled else { return }
            guard let built = await StreamComposer.makePlayerItem(detail, allowAV1: Self.supportsAV1) else {
                errorMessage = PipedError.noPlayableStream.localizedDescription
                return
            }
            guard !Task.isCancelled else { return }
            usedComposition = built.composed
            player.replaceCurrentItem(with: built.item)
            installEndObserver(for: built.item)
            configureAccessibleMedia(detail)
            isReady = true
            if built.composed { observeForFailure(built.item, detail: detail) }
            self.detail = detail
            if let resume = savedPosition(for: request.videoID), resume >= Self.minWatchSeconds {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            player.play()
            installProgressTracking()
            recordHistory(detail)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func loadLocal(_ fileURL: URL) {
        let item = AVPlayerItem(url: fileURL)
        player.replaceCurrentItem(with: item)
        installEndObserver(for: item)
        configureAccessibleLocalMedia()
        isReady = true
        recordHistoryLocal()
        Task {
            if let resume = savedPosition(for: request.videoID), resume >= Self.minWatchSeconds {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            player.play()
            installProgressTracking()
        }
    }

    func teardown() {
        loadTask?.cancel()
        loadTask = nil
        captionTask?.cancel()
        captionTask = nil
        let t = player.currentTime().seconds
        if t.isFinite { savePosition(t) }
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let captionObserver { player.removeTimeObserver(captionObserver); self.captionObserver = nil }
        removeEndObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        captionModel.reset()
        currentPlaybackSeconds = nil
        lastProgressSaveSeconds = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Captions + audio descriptions

    private func configureAccessibleMedia(_ detail: VideoDetail) {
        guard SystemMediaAccessibility.shouldShowCaptions,
              let subtitle = detail.preferredSubtitle(
                preferredLanguages: SystemMediaAccessibility.preferredCaptionLanguages)
        else {
            captionModel.reset()
            return
        }
        loadCaptions(from: subtitle)
    }

    private func configureAccessibleLocalMedia() {
        guard SystemMediaAccessibility.shouldShowCaptions, let url = request.localCaptionURL else {
            captionModel.reset()
            return
        }
        loadCaptions(from: url, mimeType: request.localCaptionMimeType)
    }

    private func loadCaptions(from subtitle: Subtitle) {
        captionTask?.cancel()
        captionModel.reset()
        captionTask = Task { [weak self] in
            let cues = await CaptionLoader.load(subtitle)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.captionModel.setCues(cues)
                self.installCaptionTracking()
            }
        }
    }

    private func loadCaptions(from url: URL, mimeType: String?) {
        captionTask?.cancel()
        captionModel.reset()
        captionTask = Task { [weak self] in
            let cues = await CaptionLoader.load(url: url, mimeType: mimeType)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.captionModel.setCues(cues)
                self.installCaptionTracking()
            }
        }
    }

    private func installCaptionTracking() {
        if let captionObserver { player.removeTimeObserver(captionObserver); self.captionObserver = nil }
        captionObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.captionModel.update(at: time.seconds) }
        }
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
        let seconds = player.currentTime().seconds
        if seconds.isFinite { savePosition(seconds) }
        guard let next = app.dequeueNext() else { return }
        playQueued(next)
    }

    private func playQueued(_ next: PlayRequest) {
        resetForItemReplacement()
        request = next
        app.nowPlaying = next
        if let local = next.localURL {
            loadLocal(local)
        } else {
            loadTask = Task { await load() }
        }
    }

    private func resetForItemReplacement() {
        loadTask?.cancel()
        loadTask = nil
        captionTask?.cancel()
        captionTask = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let captionObserver { player.removeTimeObserver(captionObserver) }
        timeObserver = nil
        captionObserver = nil
        removeEndObserver()
        statusObservation?.invalidate()
        statusObservation = nil
        captionModel.reset()
        usedComposition = false
        detail = nil
        errorMessage = nil
        currentPlaybackSeconds = nil
        lastProgressSaveSeconds = nil
        isReady = false
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Resume / progress (shared with the full-screen player via HistoryEntry)

    private func savedPosition(for videoID: String) -> Double? {
        let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == videoID })
        guard let entry = try? modelContext.fetch(descriptor).first else { return nil }
        if entry.durationSeconds > 0, entry.positionSeconds >= entry.durationSeconds - 10 { return nil }
        return entry.positionSeconds
    }

    private func installProgressTracking() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.handleProgressTick(time.seconds) }
        }
    }

    private func handleProgressTick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        currentPlaybackSeconds = seconds
        guard seconds >= Self.minWatchSeconds else { return }
        if lastProgressSaveSeconds == nil
            || abs(seconds - (lastProgressSaveSeconds ?? 0)) >= Self.minWatchSeconds {
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
        let id = request.videoID
        guard seconds.isFinite, seconds >= Self.minWatchSeconds else { return }
        let descriptor = FetchDescriptor<HistoryEntry>(predicate: #Predicate { $0.videoID == id })
        guard let entry = try? modelContext.fetch(descriptor).first else { return }
        entry.positionSeconds = seconds
        if entry.durationSeconds == 0,
           let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 {
            entry.durationSeconds = d
        }
        entry.watchedAt = .now
    }

    private func recordHistory(_ detail: VideoDetail) {
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

    private func recordHistoryLocal() {
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

    // MARK: Subscribe / feedback (shared stores with the full-screen player)

    func isSubscribed(_ channelID: String?) -> Bool {
        guard let channelID else { return false }
        let descriptor = FetchDescriptor<SubscribedChannel>(
            predicate: #Predicate { $0.channelID == channelID })
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    func setSubscription(_ subscribed: Bool, detail: VideoDetail) {
        guard let channelID = detail.channelID else { return }
        let descriptor = FetchDescriptor<SubscribedChannel>(
            predicate: #Predicate { $0.channelID == channelID })
        let existing = (try? modelContext.fetch(descriptor))?.first
        if subscribed {
            if existing == nil {
                modelContext.insert(SubscribedChannel(
                    channelID: channelID,
                    name: detail.uploader ?? request.uploader ?? "Channel",
                    avatarURL: detail.uploaderAvatar))
            }
        } else if let existing {
            modelContext.delete(existing)
        }
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
                guard let self, self.usedComposition, let url = detail.playableURL else { return }
                self.usedComposition = false
                self.statusObservation?.invalidate()
                self.statusObservation = nil
                let resume = self.player.currentTime()
                let fallback = AVPlayerItem(url: url)
                self.player.replaceCurrentItem(with: fallback)
                self.installEndObserver(for: fallback)
                await self.player.seek(to: resume)
                self.player.playImmediately(atRate: 1.0)
            }
        }
    }
}

/// Builds the highest-quality playable item the same way the full-screen player
/// does (compose best video-only + audio; fall back to HLS/progressive). Kept
/// self-contained here so the original `VideoPlayerPresenter` is left untouched.
private enum StreamComposer {
    static func makePlayerItem(_ detail: VideoDetail, allowAV1: Bool) async -> (item: AVPlayerItem, composed: Bool)? {
        if let source = detail.bestComposedSource(allowAV1: allowAV1),
           let composed = await composedItem(video: source.video, audio: source.audio) {
            return (composed, true)
        }
        guard let url = detail.playableURL else { return nil }
        return (AVPlayerItem(url: url), false)
    }

    private static func composedItem(video videoURL: URL, audio audioURL: URL) async -> AVPlayerItem? {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        do {
            guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let aTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
                return nil
            }
            let vDuration = try await videoAsset.load(.duration)
            guard let vComp = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let aComp = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return nil
            }
            try vComp.insertTimeRange(CMTimeRange(start: .zero, duration: vDuration), of: vTrack, at: .zero)
            let aDuration = try await audioAsset.load(.duration)
            try aComp.insertTimeRange(
                CMTimeRange(start: .zero, duration: min(vDuration, aDuration)), of: aTrack, at: .zero)
            return AVPlayerItem(asset: composition)
        } catch {
            return nil   // fall back to HLS/progressive
        }
    }
}
