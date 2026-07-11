import PipedKit
import SwiftData
import SwiftUI

/// The contents of the player's "Info" panel: the title, a channel row with
/// avatar + subscribe toggle, video actions, a collapsible
/// description, the video's comments, chapters, and the upcoming queue. Used both inside
/// `PlayerInfoSheet` (over the full-screen player) and inline beneath the
/// embedded player.
struct PlayerInfoContent: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
    let onToggleSubscribe: (Bool) -> Bool
    /// Only shown when the personalized For You feed is on.
    let showFeedback: Bool
    let onFeedback: (Int) -> Bool
    let onQueuedVideoPlay: (QueuedVideo) -> Void
    /// Used to fetch comments lazily once the view appears.
    let client: PipedClient
    let videoID: String
    let currentPlaybackSeconds: Double?
    let onTimestampTap: (Int) -> Void
    /// Inline layout for the embedded player: comments expand in place behind
    /// a collapsed preview (no navigation push). Defaults off, so the Info
    /// sheet keeps its compact comments preview + "View all" push.
    let inline: Bool

    @State private var isSubscribed: Bool
    @State private var feedback: Int
    @State private var loader: CommentsLoader?
    @State private var descriptionExpanded = false
    @State private var creatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var playlistError: String?
    @State private var fallbackCollaborators: [CreatorChannel] = []

    private var visibleChapters: [VideoChapter] {
        chapters
            .filter { $0.start >= 0 }
            .sorted { $0.start < $1.start }
    }

    private var streamCollaborators: [CreatorChannel] {
        creators.creatorChannels(
            verifiedChannelID: channelID,
            uploaderVerified: uploaderVerified)
    }

    private var creator: CreatorSummary {
        CreatorSummary(
            primaryName: uploader,
            displayName: uploaderDisplayName,
            avatarURL: uploaderAvatar,
            channelID: channelID,
            isVerified: uploaderVerified,
            subscriberCount: subscriberCount,
            collaborators: streamCollaborators.enriched(with: fallbackCollaborators))
    }

    init(
        title: String, uploader: String?, uploaderDisplayName: String? = nil,
        uploaderAvatar: String?, channelID: String?, creators: [VideoCreator] = [],
        subscriberCount: Int?,
        uploaderVerified: Bool, thumbnail: String? = nil, duration: Int? = nil,
        description: String, chapters: [VideoChapter] = [],
        canSubscribe: Bool, isSubscribed: Bool,
        onToggleSubscribe: @escaping (Bool) -> Bool, showFeedback: Bool, feedback: Int,
        onFeedback: @escaping (Int) -> Bool,
        onQueuedVideoPlay: @escaping (QueuedVideo) -> Void = { _ in },
        client: PipedClient, videoID: String,
        currentPlaybackSeconds: Double? = nil,
        onTimestampTap: @escaping (Int) -> Void = { _ in },
        inline: Bool = false
    ) {
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
                .accessibilityAddTraits(.isHeader)

            if creator.visibleName != nil {
                PlayerInfoChannelRow(
                    creator: creator,
                    canSubscribe: canSubscribe,
                    isSubscribed: $isSubscribed,
                    reduceMotion: reduceMotion,
                    onToggleSubscribe: onToggleSubscribe
                ) {
                    videoActionsMenu
                }
            }

            Divider()

            PlayerInfoDescriptionSection(
                description: description,
                isExpanded: $descriptionExpanded,
                reduceMotion: reduceMotion,
                onTimestampTap: onTimestampTap)

            if !visibleChapters.isEmpty {
                Divider()
                PlayerInfoChaptersSection(
                    chapters: visibleChapters,
                    thumbnail: thumbnail,
                    onTimestampTap: onTimestampTap)
            }

            Divider()

            PlayerInfoCommentsSection(
                loader: loader,
                videoID: videoID,
                currentPlaybackSeconds: currentPlaybackSeconds,
                inline: inline,
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
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(
            "Playlist Not Updated",
            isPresented: Binding(
                get: { playlistError != nil },
                set: { if !$0 { playlistError = nil } })
        ) {
            Button("OK", role: .cancel) { playlistError = nil }
        } message: {
            Text(playlistError ?? "")
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
            let requestedFeedback = (feedback == target) ? 0 : target
            feedback = PlayerInfoPersistence.retainedValue(
                current: feedback,
                requested: requestedFeedback,
                persist: onFeedback)
        } label: {
            Label(
                more ? "Suggest More" : "Suggest Less",
                systemImage: more
                    ? (active ? "hand.thumbsup.fill" : "hand.thumbsup")
                    : (active ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
        }
        .accessibilityValue(active ? "Selected" : "Not selected")
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
        if PlaylistStore.add(snapshot, to: playlist, in: context) == .missing {
            playlistError = "Atlas couldn’t add this video. Check available storage and try again."
        }
    }

    private func createAndAddToPlaylist() {
        let name = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        newPlaylistName = ""
        guard !name.isEmpty else { return }
        let snapshot = PlaylistVideoSnapshot(
            videoID: videoID,
            title: title,
            uploader: uploaderDisplayName ?? uploader,
            thumbnailURL: thumbnail,
            duration: duration ?? 0)
        if PlaylistStore.createPlaylist(named: name, adding: snapshot, in: context) != .added {
            playlistError =
                "Atlas couldn’t create that playlist. The name may already exist or a storage limit was reached."
        }
    }

}
