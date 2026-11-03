import DeclaredAgeRange
import PipedKit
import SwiftData
import SwiftUI

/// Everything beneath the embedded video: title + description, the channel
/// row, the comments card, the queue, and related videos. Tapping the
/// comments card slides the full comment list up over this page; dragging it
/// down brings the page back.
struct EmbeddedWatchPage: View {
    let model: EmbeddedPlayerModel
    let detail: VideoDetail
    let client: PipedClient

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.requestAgeRange) private var requestAgeRange
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]
    @State private var watchedMemo = WatchedIDsMemo()
    @State private var loader: CommentsLoader?
    @State private var showingComments = false
    /// Live streams swap the comments card for live chat; when the instance
    /// doesn't serve chat, the card falls back to comments.
    @State private var liveChatLoader: LiveChatLoader?
    @State private var showingLiveChat = false
    /// Related titles only start scrolling once the reader has scrolled.
    @State private var hasScrolled = false
    @State private var isSubscribed = false
    @State private var feedback = 0
    @State private var fallbackCollaborators: [CreatorChannel] = []

    /// Comments are user-generated content and stay off until the Declared
    /// Age Range check allows social features.
    private var socialGate: SocialFeaturesGate { SocialFeaturesGate.shared }
    private var allowsSocial: Bool { socialGate.allowsSocialFeatures }

    private var videoID: String { model.request.videoID }
    private var title: String { detail.title ?? model.request.title }

    private var streamCollaborators: [CreatorChannel] {
        (detail.creators ?? []).creatorChannels(
            verifiedChannelID: detail.channelID,
            uploaderVerified: detail.uploaderVerified ?? false)
    }

    private var creator: CreatorSummary {
        CreatorSummary(
            primaryName: detail.uploader ?? model.request.uploader,
            displayName: model.request.uploader ?? detail.uploader,
            avatarURL: detail.uploaderAvatar,
            channelID: detail.channelID,
            isVerified: detail.uploaderVerified ?? false,
            subscriberCount: detail.uploaderSubscriberCount,
            collaborators: streamCollaborators.enriched(with: fallbackCollaborators))
    }

    private var relatedVideos: [StreamItem] {
        StreamItemIdentity.firstOccurrences(
            in: app.filteringShorts(
                (detail.relatedStreams ?? []).filter { $0.isVideo && $0.videoID != videoID }))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            page
            if showingComments, let loader {
                EmbeddedSlidePane(
                    title: "Comments",
                    countText: loader.commentCount > 0 ? Format.compact(loader.commentCount) : nil,
                    closeLabel: "Close comments",
                    onClose: { setComments(false) }
                ) {
                    CommentsView(loader: loader, onTimestampTap: { model.seek(to: $0) })
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                .zIndex(1)
            }
            if showingLiveChat, let liveChatLoader {
                EmbeddedSlidePane(
                    title: "Live Chat",
                    countText: nil,
                    closeLabel: "Close live chat",
                    onClose: { setLiveChat(false) }
                ) {
                    EmbeddedLiveChatPaneContent(loader: liveChatLoader)
                }
                .transition(reduceMotion ? .opacity : .move(edge: .bottom))
                .zIndex(1)
            }
        }
        .onAppear {
            isSubscribed = model.isSubscribed(detail.channelID)
            feedback = model.currentFeedbackSignal()
        }
        .task(id: videoID) { await loadCreatorFallbackIfNeeded() }
        .task { await socialGate.resolve(using: requestAgeRange) }
        .task(id: allowsSocial) {
            guard allowsSocial else { return }
            if loader == nil { loader = CommentsLoader(client: client, videoID: videoID) }
            await loader?.loadInitial()
        }
        .task(id: "\(videoID)|\(allowsSocial)|\(detail.isCurrentlyLive)") {
            // One poller for both the card and the pane, alive while the
            // page is; it stops by itself once the stream ends.
            guard allowsSocial, detail.isCurrentlyLive else {
                liveChatLoader = nil
                return
            }
            let chat = LiveChatLoader(client: client, videoID: videoID)
            liveChatLoader = chat
            AppDiagnostics.reportLiveChat(active: true)
            defer { AppDiagnostics.reportLiveChat(active: false) }
            await chat.run()
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EmbeddedTitleBlock(
                    title: title,
                    views: detail.views,
                    uploadedMillis: detail.uploaded,
                    isLive: detail.isCurrentlyLive,
                    description: model.plainDescription,
                    chapters: detail.chapters ?? [],
                    thumbnail: detail.thumbnailURL ?? model.request.thumbnail,
                    onTimestampTap: { model.seek(to: $0) })

                if creator.visibleName != nil {
                    EmbeddedChannelRow(
                        creator: creator,
                        canSubscribe: detail.channelID != nil,
                        isSubscribed: $isSubscribed,
                        onToggleSubscribe: { model.setSubscription($0, detail: detail) }
                    ) {
                        EmbeddedVideoActionsMenu(
                            videoID: videoID,
                            title: title,
                            uploader: model.request.uploader ?? detail.uploader,
                            thumbnail: detail.thumbnailURL ?? model.request.thumbnail,
                            duration: detail.duration,
                            showFeedback: FeedMode.current.isPersonalized,
                            feedback: $feedback,
                            onFeedback: { model.setFeedback($0, detail: detail) })
                    }
                }

                if allowsSocial {
                    if let liveChatLoader, liveChatLoader.availability != .unavailable {
                        EmbeddedLiveChatCard(loader: liveChatLoader, onOpen: { setLiveChat(true) })
                    } else {
                        EmbeddedCommentCard(
                            loader: loader,
                            currentPlaybackSeconds: model.currentPlaybackSeconds,
                            onOpen: openComments)
                    }
                } else {
                    SocialFeaturesNotice(gate: socialGate) {
                        Task { await socialGate.resolve(using: requestAgeRange, force: true) }
                    }
                }

                if !app.queuedVideos.isEmpty {
                    Divider()
                    PlayerInfoQueueSection(onQueuedVideoPlay: { model.playQueued($0) })
                }

                if !app.embeddedHidesRelated {
                    relatedSection
                }
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)
        .onScrollGeometryChange(for: Bool.self) {
            $0.contentOffset.y > 24
        } action: { _, scrolled in
            if scrolled { hasScrolled = true }
        }
        .environment(\.marqueeTitlesEnabled, hasScrolled)
    }

    @ViewBuilder private var relatedSection: some View {
        let videos = relatedVideos
        if !videos.isEmpty {
            let watchedIDs = watchedMemo.ids(for: history)
            Divider()
            // The same big-thumbnail card as the Home feed.
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(videos) { item in
                    VideoRow(
                        item: item,
                        watched: item.videoID.map(watchedIDs.contains) ?? false,
                        onPlay: { model.playRelated(item) })
                }
            }
        }
    }

    private func openComments() {
        guard let loader else { return }
        if loader.loadFailed {
            Task { await loader.loadInitial() }
            return
        }
        setComments(true)
    }

    private func setLiveChat(_ showing: Bool) {
        if reduceMotion {
            showingLiveChat = showing
        } else {
            withAnimation(.spring(duration: 0.38, bounce: 0.12)) { showingLiveChat = showing }
        }
    }

    private func setComments(_ showing: Bool) {
        if reduceMotion {
            showingComments = showing
        } else {
            withAnimation(.spring(duration: 0.38, bounce: 0.12)) { showingComments = showing }
        }
    }

    private func loadCreatorFallbackIfNeeded() async {
        guard fallbackCollaborators.isEmpty, creator.hasMultipleCreators else { return }
        guard streamCollaborators.needsCreatorFallback(expectedAdditionalCount: creator.additionalCount)
        else { return }
        let channels = await YouTubeCollaborators.channels(for: videoID)
        if !channels.isEmpty { fallbackCollaborators = channels }
    }
}
