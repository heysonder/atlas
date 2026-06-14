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
        InlineVideoPlayer(player: model.player, isReady: model.isReady)
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
    }

    // MARK: Info

    @ViewBuilder private var infoArea: some View {
        if let detail = model.detail {
            ScrollView {
                PlayerInfoContent(
                    title: detail.title ?? model.request.title,
                    uploader: detail.uploader ?? model.request.uploader,
                    uploaderAvatar: detail.uploaderAvatar,
                    subscriberCount: detail.uploaderSubscriberCount,
                    uploaderVerified: detail.uploaderVerified ?? false,
                    description: HTMLText.plain(detail.description ?? ""),
                    canSubscribe: detail.channelID != nil,
                    isSubscribed: model.isSubscribed(detail.channelID),
                    onToggleSubscribe: { model.setSubscription($0, detail: detail) },
                    showFeedback: FeedMode.current.isPersonalized,
                    feedback: model.currentFeedbackSignal(),
                    onFeedback: { model.setFeedback($0, detail: detail) },
                    client: model.client,
                    videoID: model.request.videoID,
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

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.updatesNowPlayingInfoCenter = true
        controller.videoGravity = .resizeAspect
        if isReady { controller.player = player }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if isReady, controller.player !== player {
            controller.player = player
        }
    }
}

/// Owns the `AVPlayer` for the embedded player and mirrors the full-screen
/// player's data work — stream resolution, resume, progress tracking, history,
/// subscribe, and feedback — independently, so the original player is untouched.
@MainActor
@Observable
final class EmbeddedPlayerModel {
    let player = AVPlayer()
    let request: PlayRequest
    private(set) var detail: VideoDetail?
    private(set) var errorMessage: String?
    /// Flips true the moment a player item is set, so the inline controller is
    /// only attached to a player that has something to play.
    private(set) var isReady = false

    private let app: AppModel
    private let modelContext: ModelContext
    private var loadTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var usedComposition = false
    private var started = false

    private static let minWatchSeconds: Double = 5
    private static let supportsAV1 = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

    var client: PipedClient { app.client }

    init(request: PlayRequest, app: AppModel, modelContext: ModelContext) {
        self.request = request
        self.app = app
        self.modelContext = modelContext
        player.allowsExternalPlayback = true
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
        player.replaceCurrentItem(with: AVPlayerItem(url: fileURL))
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
        let t = player.currentTime().seconds
        if t.isFinite { savePosition(t) }
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
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
            forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.savePosition(time.seconds) }
        }
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
                self.player.replaceCurrentItem(with: AVPlayerItem(url: url))
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
