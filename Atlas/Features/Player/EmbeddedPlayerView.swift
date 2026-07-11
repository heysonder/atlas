import SwiftData
import SwiftUI

/// The "Embedded" player (opt-in via Settings): plays the video inline at the
/// top of a scrolling page, with the shared `PlayerInfoContent` — channel row,
/// description, and comments — beneath it. The native full-screen player
/// (`VideoPlayerPresenter`) is untouched and remains the default.
struct EmbeddedPlayerView: View {
    @State private var model: EmbeddedPlayerModel
    /// Live offset of the swipe-down-to-dismiss drag on the video area.
    @State private var dragOffset: CGFloat = 0
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(request: PlayRequest, app: AppModel, modelContext: ModelContext) {
        _model = State(
            initialValue: EmbeddedPlayerModel(
                request: request, app: app, modelContext: modelContext))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                videoArea
                infoArea
            }
            // No navigation bar on the root: the video pins to the top of the
            // safe area instead of sitting under a mostly-empty bar. Pushed
            // destinations (channel pages) still get their own bar.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
        }
        .offset(y: dragOffset)
        .task { model.start() }
        .onDisappear {
            // Keeps the player alive while PiP is running (mirrors the
            // fullscreen presenter's `pipActive` guard); teardown happens
            // when PiP ends instead.
            model.viewDisappeared()
        }
    }

    // MARK: Video

    /// The inline player, sized to the video's aspect ratio and pinned to the
    /// top. The native controls include an "expand" button for true full screen
    /// (landscape) and PiP — so nothing is lost versus the full-screen player.
    private var videoArea: some View {
        InlineVideoPlayer(
            player: model.player,
            isReady: model.isReady,
            onPiPActiveChanged: { [model] in model.setPiPActive($0) }
        )
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
                    .accessibilityLabel("Loading video")
            }
        }
        .overlay(alignment: .topLeading) {
            dismissButton.padding(10)
        }
        .simultaneousGesture(dismissDrag)
    }

    /// Floating dismiss control over the video's top-left corner. Injecting an
    /// ✕ into AVKit's private transport-control hierarchy stopped working on
    /// iOS 27, so closing the player is this button plus the swipe-down drag.
    private var dismissButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("Close")
    }

    /// Drag the video down to dismiss the player, YouTube-style. Attached with
    /// `simultaneousGesture` and a 20pt threshold so the native tap-to-show
    /// controls and the transport bar keep working; only predominantly
    /// vertical drags move the view.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                let dy = value.translation.height
                guard dy > 0, dy > abs(value.translation.width) else { return }
                dragOffset = dy
            }
            .onEnded { value in
                if value.translation.height > 140
                    || value.predictedEndTranslation.height > 320
                {
                    dismiss()
                } else if reduceMotion {
                    dragOffset = 0
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                }
            }
    }

    // MARK: Info

    @ViewBuilder private var infoArea: some View {
        if let detail = model.detail {
            if let client = model.client {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PlayerInfoContent(
                            title: detail.title ?? model.request.title,
                            uploader: detail.uploader ?? model.request.uploader,
                            uploaderDisplayName: model.request.uploader ?? detail.uploader,
                            uploaderAvatar: detail.uploaderAvatar,
                            channelID: detail.channelID,
                            creators: detail.creators ?? [],
                            subscriberCount: detail.uploaderSubscriberCount,
                            uploaderVerified: detail.uploaderVerified ?? false,
                            thumbnail: detail.thumbnailURL ?? model.request.thumbnail,
                            duration: detail.duration,
                            description: model.plainDescription,
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

                        if let related = detail.relatedStreams, !related.isEmpty {
                            Divider()
                            PlayerRelatedSection(
                                related: related,
                                currentVideoID: model.request.videoID,
                                onPlay: { model.playRelated($0) })
                        }
                    }
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
            ErrorState(message: message) { model.retry() }
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
