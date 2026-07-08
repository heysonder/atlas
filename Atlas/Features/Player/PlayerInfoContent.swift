import SwiftUI
import SwiftData
import PipedKit

/// The contents of the player's "Info" panel: the title, a channel row with
/// avatar + subscribe toggle, video actions, a collapsible
/// description, the video's comments, chapters, and the upcoming queue. Used both inside
/// `PlayerInfoSheet` (over the full-screen player) and inline beneath the
/// embedded player.
struct PlayerInfoContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Query(sort: \Playlist.createdAt, order: .reverse) private var playlists: [Playlist]

    let title: String
    let uploader: String?
    let uploaderDisplayName: String?
    let uploaderAvatar: String?
    let channelID: String?
    let creators: [VideoCreator]
    let subscriberCount: Int?
    let uploaderVerified: Bool
    let thumbnail: String?
    let duration: Int?
    let description: String
    let chapters: [VideoChapter]
    let canSubscribe: Bool
    @State private var isSubscribed: Bool
    let onToggleSubscribe: (Bool) -> Void
    /// Only shown when the personalized For You feed is on.
    let showFeedback: Bool
    @State private var feedback: Int
    let onFeedback: (Int) -> Void
    let onQueuedVideoPlay: (QueuedVideo) -> Void
    /// Used to fetch comments lazily once the view appears.
    let client: PipedClient
    let videoID: String
    let currentPlaybackSeconds: Double?
    let onTimestampTap: (Int) -> Void
    /// Inline layout for the embedded player: comments expand in place behind
    /// a collapsed preview (no navigation push). Defaults off, so the Info
    /// sheet keeps its compact comments preview + "View all" push.
    var inline: Bool = false

    @State private var loader: CommentsLoader?
    @State private var descriptionExpanded = false
    @State private var creatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var fallbackCollaborators: [CreatorChannel] = []
    @State private var timestampPreviewIndex = TimestampCommentPreviewIndex()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleChapters: [VideoChapter] {
        chapters
            .filter { $0.start >= 0 }
            .sorted { $0.start < $1.start }
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
         uploaderVerified: Bool, thumbnail: String? = nil, duration: Int? = nil,
         description: String, chapters: [VideoChapter] = [],
         canSubscribe: Bool, isSubscribed: Bool,
         onToggleSubscribe: @escaping (Bool) -> Void, showFeedback: Bool, feedback: Int,
         onFeedback: @escaping (Int) -> Void,
         onQueuedVideoPlay: @escaping (QueuedVideo) -> Void = { _ in },
         client: PipedClient, videoID: String,
         currentPlaybackSeconds: Double? = nil,
         onTimestampTap: @escaping (Int) -> Void = { _ in },
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
        self.thumbnail = thumbnail
        self.duration = duration
        self.description = description
        self.chapters = chapters
        self.canSubscribe = canSubscribe
        self._isSubscribed = State(initialValue: isSubscribed)
        self.onToggleSubscribe = onToggleSubscribe
        self.showFeedback = showFeedback
        self._feedback = State(initialValue: feedback)
        self.onFeedback = onFeedback
        self.onQueuedVideoPlay = onQueuedVideoPlay
        self.client = client
        self.videoID = videoID
        self.currentPlaybackSeconds = currentPlaybackSeconds
        self.onTimestampTap = onTimestampTap
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if creator.visibleName != nil {
                channelRow(creator)
            }

            Divider()

            descriptionBlock

            if !visibleChapters.isEmpty {
                Divider()
                chaptersSection
            }

            Divider()

            PlayerInfoCommentsSection(
                loader: loader,
                videoID: videoID,
                currentPlaybackSeconds: currentPlaybackSeconds,
                inline: inline,
                timestampPreviewIndex: $timestampPreviewIndex,
                onTimestampTap: onTimestampTap)

            if !app.queuedVideos.isEmpty {
                Divider()
                PlayerInfoQueueSection(onQueuedVideoPlay: onQueuedVideoPlay)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: videoID) {
            await loadCreatorFallbackIfNeeded()
        }
        .task {
            if loader == nil { loader = CommentsLoader(client: client, videoID: videoID) }
            await loader?.loadInitial()
        }
        .alert("New Playlist", isPresented: $creatingPlaylist) {
            TextField("Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) { newPlaylistName = "" }
            Button("Create") { createAndAddToPlaylist() }
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
                videoActionsMenu
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

    private var subscribeButton: some View {
        Button {
            isSubscribed.toggle()
            onToggleSubscribe(isSubscribed)
        } label: {
            Image(systemName: isSubscribed ? "checkmark" : "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSubscribed ? .secondary : .primary)
                .frame(width: 44, height: 44)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(isSubscribed ? "Unsubscribe" : "Subscribe")
    }

    // MARK: Playlist

    private var videoActionsMenu: some View {
        Menu {
            if showFeedback {
                feedbackMenuButton(more: true)
                feedbackMenuButton(more: false)
                Divider()
            }
            playlistMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel("More video actions")
    }

    @ViewBuilder private func feedbackMenuButton(more: Bool) -> some View {
        let active = more ? feedback > 0 : feedback < 0
        let target = more ? 1 : -1
        Button {
            feedback = (feedback == target) ? 0 : target
            onFeedback(feedback)
        } label: {
            Label(more ? "Suggest More" : "Suggest Less",
                  systemImage: more ? (active ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    : (active ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
        }
    }

    @ViewBuilder private var playlistMenuItems: some View {
        Button("New Playlist…", systemImage: "plus") { creatingPlaylist = true }
        if !playlists.isEmpty { Divider() }
        ForEach(playlists) { playlist in
            let containsVideo = playlistContainsCurrentVideo(playlist)
            Button {
                addCurrentVideo(to: playlist)
            } label: {
                Label(playlist.name, systemImage: containsVideo ? "checkmark" : "music.note.list")
            }
            .disabled(containsVideo)
        }
    }

    private func playlistContainsCurrentVideo(_ playlist: Playlist) -> Bool {
        PlaylistStore.containsVideoID(videoID, in: playlist)
    }

    private func addCurrentVideo(to playlist: Playlist) {
        let snapshot = PlaylistVideoSnapshot(
            videoID: videoID,
            title: title,
            uploader: uploaderDisplayName ?? uploader,
            thumbnailURL: thumbnail,
            duration: duration ?? 0)
        PlaylistStore.add(snapshot, to: playlist, in: context)
    }

    private func createAndAddToPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPlaylistName = ""
        guard !name.isEmpty else { return }
        guard let playlist = PlaylistStore.createPlaylist(named: name, in: context) else { return }
        addCurrentVideo(to: playlist)
    }

    // MARK: Description

    @ViewBuilder private var descriptionBlock: some View {
        if description.isEmpty {
            Text("No description.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                TimestampedText(
                    text: description,
                    onTimestampTap: onTimestampTap)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(descriptionExpanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isDescriptionLong {
                    Button(descriptionExpanded ? "Show less" : "Show more") {
                        if reduceMotion {
                            descriptionExpanded.toggle()
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) { descriptionExpanded.toggle() }
                        }
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

    // MARK: Chapters

    @ViewBuilder private var chaptersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("Chapters")
                    .font(.headline)
                Text("\(visibleChapters.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(visibleChapters) { chapter in
                    chapterRow(chapter)
                }
            }
        }
    }

    private func chapterRow(_ chapter: VideoChapter) -> some View {
        let title = chapter.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Chapter"
        return Button {
            onTimestampTap(chapter.start)
        } label: {
            HStack(spacing: 10) {
                ZStack(alignment: .bottomLeading) {
                    Thumbnail(url: chapter.image ?? thumbnail)
                        .aspectRatio(16 / 9, contentMode: .fill)
                        .frame(width: 84, height: 47)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    Text(Format.clock(chapter.start))
                        .font(.caption2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(5)
                }

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Skip to \(chapter.title ?? "chapter") at \(Format.clock(chapter.start))")
    }
}
