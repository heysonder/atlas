import SwiftUI
import PipedKit

/// Drives the in-player "Info" button. While the video plays the button shows
/// just the ⓘ glyph; when the coordinator sets `isPaused` it expands to reveal
/// the "Info" label, matching the more discoverable controls-visible state.
@MainActor
@Observable
final class InfoButtonModel {
    var isPaused = false
    @ObservationIgnored var onTap: () -> Void = {}
}

/// The small Liquid Glass "Info" button layered over the video.
struct InfoOverlayButton: View {
    let model: InfoButtonModel
    var body: some View {
        Button(action: model.onTap) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                if model.isPaused {
                    Text("Info")
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, model.isPaused ? 14 : 10)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .animation(.snappy(duration: 0.25), value: model.isPaused)
    }
}

/// The player's "Info" sheet: wraps the shared `PlayerInfoContent` in a sheet
/// chrome (navigation bar + Done). Presented over the still-playing video, so it
/// never interrupts playback. Opens at the medium detent — drag up for comments.
struct PlayerInfoSheet: View {
    let title: String
    let uploader: String?
    let uploaderDisplayName: String?
    let uploaderAvatar: String?
    let channelID: String?
    let creators: [VideoCreator]
    let subscriberCount: Int?
    let uploaderVerified: Bool
    let description: String
    let canSubscribe: Bool
    let isSubscribed: Bool
    let onToggleSubscribe: (Bool) -> Void
    /// Only shown when the personalized For You feed is on.
    let showFeedback: Bool
    let feedback: Int
    let onFeedback: (Int) -> Void
    /// Related videos shown as the playback queue when present.
    let queue: [StreamItem]
    let onQueuePlay: (StreamItem) -> Void
    /// Used to fetch comments lazily once the sheet appears.
    let client: PipedClient
    let videoID: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                PlayerInfoContent(
                    title: title, uploader: uploader, uploaderDisplayName: uploaderDisplayName,
                    uploaderAvatar: uploaderAvatar, channelID: channelID,
                    creators: creators,
                    subscriberCount: subscriberCount, uploaderVerified: uploaderVerified,
                    description: description, canSubscribe: canSubscribe, isSubscribed: isSubscribed,
                    onToggleSubscribe: onToggleSubscribe, showFeedback: showFeedback,
                    feedback: feedback, onFeedback: onFeedback, queue: queue,
                    onQueuePlay: onQueuePlay, client: client, videoID: videoID)
                    .padding()
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The contents of the player's "Info" panel: the title, a channel row with
/// avatar + subscribe toggle, optional feedback buttons, a collapsible
/// description, and the video's comments. Used both inside `PlayerInfoSheet`
/// (over the full-screen player) and inline beneath the embedded player.
struct PlayerInfoContent: View {
    let title: String
    let uploader: String?
    let uploaderDisplayName: String?
    let uploaderAvatar: String?
    let channelID: String?
    let creators: [VideoCreator]
    let subscriberCount: Int?
    let uploaderVerified: Bool
    let description: String
    let canSubscribe: Bool
    @State private var isSubscribed: Bool
    let onToggleSubscribe: (Bool) -> Void
    /// Only shown when the personalized For You feed is on.
    let showFeedback: Bool
    @State private var feedback: Int
    let onFeedback: (Int) -> Void
    let queue: [StreamItem]
    let onQueuePlay: (StreamItem) -> Void
    /// Used to fetch comments lazily once the view appears.
    let client: PipedClient
    let videoID: String
    /// Inline layout for the embedded player: feedback shown as circular buttons
    /// in the channel row, and comments expanded in place (no navigation push).
    /// Defaults off, so the full-screen player's Info sheet is unchanged.
    var inline: Bool = false

    @State private var loader: CommentsLoader?
    @State private var descriptionExpanded = false
    @State private var fallbackCollaborators: [CreatorChannel] = []
    private var queuedVideos: [StreamItem] {
        queue.filter { $0.isVideo && $0.videoID != videoID }
    }
    private var streamCollaborators: [CreatorChannel] {
        creators.creatorChannels(verifiedChannelID: channelID,
                                  uploaderVerified: uploaderVerified)
    }
    private var creator: CreatorSummary {
        CreatorSummary(primaryName: uploader,
                       displayName: uploaderDisplayName,
                       avatarURL: uploaderAvatar,
                       channelID: channelID,
                       isVerified: uploaderVerified,
                       subscriberCount: subscriberCount,
                       collaborators: streamCollaborators.enriched(with: fallbackCollaborators))
    }

    init(title: String, uploader: String?, uploaderDisplayName: String? = nil,
         uploaderAvatar: String?, channelID: String?, creators: [VideoCreator] = [],
         subscriberCount: Int?,
         uploaderVerified: Bool, description: String, canSubscribe: Bool, isSubscribed: Bool,
         onToggleSubscribe: @escaping (Bool) -> Void, showFeedback: Bool, feedback: Int,
         onFeedback: @escaping (Int) -> Void, queue: [StreamItem] = [],
         onQueuePlay: @escaping (StreamItem) -> Void = { _ in },
         client: PipedClient, videoID: String,
         inline: Bool = false) {
        self.inline = inline
        self.title = title
        self.uploader = uploader
        self.uploaderDisplayName = uploaderDisplayName
        self.uploaderAvatar = uploaderAvatar
        self.channelID = channelID
        self.creators = creators
        self.subscriberCount = subscriberCount
        self.uploaderVerified = uploaderVerified
        self.description = description
        self.canSubscribe = canSubscribe
        self._isSubscribed = State(initialValue: isSubscribed)
        self.onToggleSubscribe = onToggleSubscribe
        self.showFeedback = showFeedback
        self._feedback = State(initialValue: feedback)
        self.onFeedback = onFeedback
        self.queue = queue
        self.onQueuePlay = onQueuePlay
        self.client = client
        self.videoID = videoID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if creator.visibleName != nil {
                channelRow(creator)
            }

            if showFeedback && !inline {
                HStack(spacing: 12) {
                    suggestButton(more: true)
                    suggestButton(more: false)
                    Spacer(minLength: 0)
                }
            }

            Divider()

            descriptionBlock

            if !queuedVideos.isEmpty {
                Divider()

                queueSection
            }

            Divider()

            commentsSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: videoID) {
            await loadCreatorFallbackIfNeeded()
        }
        .task {
            if loader == nil { loader = CommentsLoader(client: client, videoID: videoID) }
            await loader?.loadInitial()
        }
    }

    // MARK: Channel row

    private func channelRow(_ creator: CreatorSummary) -> some View {
        HStack(spacing: 12) {
            CreatorChannelControl(summary: creator) {
                HStack(spacing: 12) {
                    CreatorAvatarCluster(avatarURL: creator.avatarURL,
                                         collaboratorAvatarURLs: creator.collaborators.map(\.avatarURL),
                                         additionalCount: creator.additionalCount,
                                         size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(creator.visibleName ?? "Channel")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            if creator.isVerified {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let subs = Format.subscribers(creator.subscriberCount) {
                            Text(subs)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if inline && showFeedback {
                    feedbackButton(more: true)
                    feedbackButton(more: false)
                }
                if canSubscribe { subscribeButton }
            }
        }
    }

    private func loadCreatorFallbackIfNeeded() async {
        guard fallbackCollaborators.isEmpty, creator.hasMultipleCreators else { return }
        let expectedAdditionalCount = creator.additionalCount
        guard streamCollaborators.needsCreatorFallback(expectedAdditionalCount: expectedAdditionalCount) else { return }

        let channels = await YouTubeCollaborators.channels(for: videoID)
        if !channels.isEmpty {
            fallbackCollaborators = channels
        }
    }

    /// Circular thumbs-up / thumbs-down matching the subscribe button, used in
    /// the embedded player's channel row. Tapping the active one clears it.
    private func feedbackButton(more: Bool) -> some View {
        let active = more ? feedback > 0 : feedback < 0
        return Button {
            let target = more ? 1 : -1
            feedback = (feedback == target) ? 0 : target
            onFeedback(feedback)
        } label: {
            Image(systemName: more ? (active ? "hand.thumbsup.fill" : "hand.thumbsup")
                                   : (active ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : .primary)
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(more ? "Suggest more" : "Suggest less")
    }

    private var subscribeButton: some View {
        Button {
            isSubscribed.toggle()
            onToggleSubscribe(isSubscribed)
        } label: {
            Image(systemName: isSubscribed ? "checkmark" : "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSubscribed ? .secondary : .primary)
                .frame(width: 44, height: 44)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(isSubscribed ? "Unsubscribe" : "Subscribe")
    }

    // MARK: Description

    @ViewBuilder private var descriptionBlock: some View {
        if description.isEmpty {
            Text("No description.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(description)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isDescriptionLong {
                    Button(descriptionExpanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.2)) { descriptionExpanded.toggle() }
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
    }

    /// Heuristic for whether the description is worth a Show more/less toggle —
    /// keeps comments reachable instead of buried under a wall of text.
    private var isDescriptionLong: Bool {
        description.count > 160 || description.filter { $0 == "\n" }.count >= 3
    }

    // MARK: Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Queue")
                .font(.headline)

            ForEach(queuedVideos) { item in
                Button {
                    onQueuePlay(item)
                } label: {
                    QueueVideoRow(item: item)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Comments

    @ViewBuilder private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            commentsHeader

            if let loader {
                if loader.disabled {
                    commentsNotice("Comments are turned off.")
                } else if !loader.didLoad {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading comments…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if loader.comments.isEmpty {
                    commentsNotice("No comments yet.")
                } else if inline {
                    inlineComments(loader)
                } else {
                    ForEach(loader.comments.prefix(2)) { comment in
                        CommentRow(comment: comment, client: loader.client, videoID: videoID)
                    }
                    viewAllCommentsLink(loader)
                }
            }
        }
    }

    private var commentsHeader: some View {
        HStack(spacing: 6) {
            Text("Comments")
                .font(.headline)
            if let loader, loader.commentCount > 0, let count = Format.compact(loader.commentCount) {
                Text(count)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func commentsNotice(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    /// All comments, expanded in place and paginated as the user scrolls — used
    /// in the embedded player so comments never push to a separate page.
    @ViewBuilder private func inlineComments(_ loader: CommentsLoader) -> some View {
        ForEach(loader.comments) { comment in
            CommentRow(comment: comment, client: loader.client, videoID: videoID)
            Divider()
        }
        if loader.nextpage != nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .task(id: loader.comments.count) { await loader.loadMore() }
        }
    }

    private func viewAllCommentsLink(_ loader: CommentsLoader) -> some View {
        NavigationLink {
            CommentsView(loader: loader)
        } label: {
            HStack {
                Text("View all comments")
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.top, 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: Feedback

    /// "Suggest More / Less"; tapping the active one again clears it.
    private func suggestButton(more: Bool) -> some View {
        let active = more ? feedback > 0 : feedback < 0
        return Button {
            let target = more ? 1 : -1
            feedback = (feedback == target) ? 0 : target
            onFeedback(feedback)
        } label: {
            Label(more ? "Suggest More" : "Suggest Less",
                  systemImage: more ? (active ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    : (active ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
    }
}

private struct QueueVideoRow: View {
    let item: StreamItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Thumbnail(url: item.thumbnail)
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                durationPill
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                let meta = metaText
                if !meta.isEmpty {
                    Text(meta)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var durationPill: some View {
        let duration = Format.duration(item.duration)
        if !duration.isEmpty {
            Text(duration)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .foregroundStyle(.white)
                .background(.black.opacity(0.75), in: Capsule())
                .padding(5)
        }
    }

    private var metaText: String {
        let timeAgo = Format.relativeTime(item.uploaded) ?? item.uploadedDate
        let views = (item.views ?? -1) >= 500 ? Format.views(item.views) : nil
        return Format.metaLine(item.uploaderName, views, timeAgo)
    }
}
