import SwiftUI
import PipedKit

/// The small Liquid Glass "Info" button layered over the video.
struct InfoOverlayButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("Info", systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// The contents of the player's "Info" sheet: a channel row with avatar +
/// subscribe toggle, a collapsible description, and the video's comments.
/// Presented over the still-playing video, so it never interrupts playback.
/// Opens at the medium detent — drag up to reveal the comments below.
struct PlayerInfoSheet: View {
    let title: String
    let uploader: String?
    let uploaderAvatar: String?
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
    /// Used to fetch comments lazily once the sheet appears.
    let client: PipedClient
    let videoID: String

    @State private var loader: CommentsLoader?
    @State private var descriptionExpanded = false
    @Environment(\.dismiss) private var dismiss

    init(title: String, uploader: String?, uploaderAvatar: String?, subscriberCount: Int?,
         uploaderVerified: Bool, description: String, canSubscribe: Bool, isSubscribed: Bool,
         onToggleSubscribe: @escaping (Bool) -> Void, showFeedback: Bool, feedback: Int,
         onFeedback: @escaping (Int) -> Void, client: PipedClient, videoID: String) {
        self.title = title
        self.uploader = uploader
        self.uploaderAvatar = uploaderAvatar
        self.subscriberCount = subscriberCount
        self.uploaderVerified = uploaderVerified
        self.description = description
        self.canSubscribe = canSubscribe
        self._isSubscribed = State(initialValue: isSubscribed)
        self.onToggleSubscribe = onToggleSubscribe
        self.showFeedback = showFeedback
        self._feedback = State(initialValue: feedback)
        self.onFeedback = onFeedback
        self.client = client
        self.videoID = videoID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if let uploader, !uploader.isEmpty {
                        channelRow(uploader)
                    }

                    if showFeedback {
                        HStack(spacing: 12) {
                            suggestButton(more: true)
                            suggestButton(more: false)
                            Spacer(minLength: 0)
                        }
                    }

                    Divider()

                    descriptionBlock

                    Divider()

                    commentsSection
                }
                .padding()
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            if loader == nil { loader = CommentsLoader(client: client, videoID: videoID) }
            await loader?.loadInitial()
        }
    }

    // MARK: Channel row

    private func channelRow(_ uploader: String) -> some View {
        HStack(spacing: 12) {
            Avatar(url: uploaderAvatar, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(uploader)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if uploaderVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let subs = Format.subscribers(subscriberCount) {
                    Text(subs)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if canSubscribe { subscribeButton }
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

    // MARK: Comments

    @ViewBuilder private var commentsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Comments")
                    .font(.headline)
                if let loader, loader.commentCount > 0, let count = Format.compact(loader.commentCount) {
                    Text(count)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let loader {
                if loader.disabled {
                    Text("Comments are turned off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if !loader.didLoad {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading comments…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if loader.comments.isEmpty {
                    Text("No comments yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(loader.comments.prefix(2)) { comment in
                        CommentRow(comment: comment, client: loader.client, videoID: videoID)
                    }
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
            }
        }
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
