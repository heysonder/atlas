import SwiftUI
import Observation
import PipedKit

/// Loads and paginates a video's comments. Shared between the preview shown in
/// `PlayerInfoSheet` and the full `CommentsView` that's pushed from it, so the
/// list is fetched once and survives navigation.
@MainActor
@Observable
final class CommentsLoader {
    let client: PipedClient
    let videoID: String

    private(set) var comments: [Comment] = []
    private(set) var nextpage: String?
    private(set) var disabled = false
    private(set) var commentCount = -1
    private(set) var didLoad = false
    private(set) var isLoading = false

    init(client: PipedClient, videoID: String) {
        self.client = client
        self.videoID = videoID
    }

    /// Fetches the first page; a no-op once it has succeeded.
    func loadInitial() async {
        guard !didLoad, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let page = try? await client.comments(videoID: videoID) {
            comments = page.comments ?? []
            nextpage = page.nextpage
            disabled = page.disabled ?? false
            commentCount = page.commentCount ?? -1
        }
        didLoad = true
    }

    /// Appends the next page when one exists. On failure it stops paginating
    /// rather than dropping the comments already shown.
    func loadMore() async {
        guard let token = nextpage, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.commentsNextPage(videoID: videoID, nextpage: token)
            comments.append(contentsOf: page.comments ?? [])
            nextpage = page.nextpage
        } catch {
            nextpage = nil
        }
    }
}

/// The full, scrollable comment list, pushed from the info sheet's "View all
/// comments" row. Reuses the loader the sheet already populated.
struct CommentsView: View {
    let loader: CommentsLoader
    var onTimestampTap: (Int) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if loader.disabled {
                    unavailable("Comments are turned off", "bubble.left.and.bubble.right")
                } else if loader.comments.isEmpty && loader.didLoad {
                    unavailable("No comments yet", "bubble.left")
                } else {
                    ForEach(loader.comments) { comment in
                        CommentRow(
                            comment: comment,
                            client: loader.client,
                            videoID: loader.videoID,
                            onTimestampTap: onTimestampTap)
                        Divider()
                    }
                    if loader.nextpage != nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .task(id: loader.comments.count) { await loader.loadMore() }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Comments")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loader.loadInitial() }
    }

    private func unavailable(_ title: String, _ symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol)
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
    }
}

/// A single comment: avatar, author + metadata, body, like count, and an
/// expandable replies thread (top-level comments only).
struct CommentRow: View {
    let comment: Comment
    let client: PipedClient
    let videoID: String
    var isReply = false
    var onTimestampTap: (Int) -> Void = { _ in }

    @State private var replies: [Comment] = []
    @State private var showReplies = false
    @State private var loadingReplies = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(url: comment.thumbnail, size: isReply ? 28 : 36)

                VStack(alignment: .leading, spacing: 4) {
                    metaLine

                    TimestampedText(
                        text: comment.plainText,
                        timestamps: comment.timestamps,
                        onTimestampTap: onTimestampTap)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                    footer
                }
                Spacer(minLength: 0)
            }

            if showReplies {
                ForEach(replies) { reply in
                    CommentRow(
                        comment: reply,
                        client: client,
                        videoID: videoID,
                        isReply: true,
                        onTimestampTap: onTimestampTap)
                    .padding(.leading, 30)
                }
            }
        }
    }

    private var metaLine: some View {
        HStack(spacing: 4) {
            if comment.pinned == true {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(comment.author ?? "Unknown")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if comment.verified == true {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let time = comment.commentedTime, !time.isEmpty {
                Text("· \(time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 16) {
            if let likes = Format.compact(comment.likeCount), (comment.likeCount ?? 0) > 0 {
                Label(likes, systemImage: "hand.thumbsup")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if comment.hearted == true {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
            }

            if !isReply, comment.hasReplies {
                Button {
                    Task { await toggleReplies() }
                } label: {
                    HStack(spacing: 4) {
                        if loadingReplies {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: showReplies ? "chevron.up" : "chevron.down")
                        }
                        Text(repliesLabel)
                    }
                    .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .padding(.top, 1)
    }

    private var repliesLabel: String {
        if showReplies { return "Hide replies" }
        let n = comment.replyCount ?? 0
        return "\(n) repl\(n == 1 ? "y" : "ies")"
    }

    private func toggleReplies() async {
        if showReplies { showReplies = false; return }
        if replies.isEmpty, let token = comment.repliesPage {
            loadingReplies = true
            let page = try? await client.commentsNextPage(videoID: videoID, nextpage: token)
            replies = page?.comments ?? []
            loadingReplies = false
        }
        showReplies = true
    }
}
