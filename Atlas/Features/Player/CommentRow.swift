import PipedKit
import SwiftUI

/// A single comment: avatar, author + metadata, body, like count, and an
/// expandable replies thread (top-level comments only).
struct CommentRow: View {
    let comment: CommentDisplay
    let client: PipedClient
    let videoID: String
    var isReply = false
    var onTimestampTap: (Int) -> Void = { _ in }

    @State private var replies: [CommentDisplay] = []
    @State private var showReplies = false
    @State private var loadingReplies = false
    @State private var replyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(
                    url: comment.thumbnail,
                    size: isReply ? 28 : 36,
                    networkScope: .selectedInstance)

                VStack(alignment: .leading, spacing: 4) {
                    metaLine

                    TimestampedText(
                        text: comment.plainText,
                        timestamps: comment.timestamps,
                        onTimestampTap: onTimestampTap
                    )
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                    footer
                    if replyError != nil {
                        Button("Retry replies") { Task { await toggleReplies() } }
                            .font(.caption2.weight(.semibold))
                            .frame(minHeight: 44)
                    }
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
                        onTimestampTap: onTimestampTap
                    )
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
                    .accessibilityLabel("Pinned comment")
            }
            Text(comment.author ?? "Unknown")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if comment.verified == true {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Verified creator")
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
                    .accessibilityLabel("\(likes) likes")
            }
            if comment.hearted == true {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(.pink)
                    .accessibilityLabel("Hearted by creator")
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
                .disabled(loadingReplies)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .padding(.top, 1)
    }

    private var repliesLabel: String {
        if showReplies { return "Hide replies" }
        let replyCount = comment.replyCount ?? 0
        return "\(replyCount) repl\(replyCount == 1 ? "y" : "ies")"
    }

    private func toggleReplies() async {
        guard !loadingReplies else { return }
        if showReplies {
            showReplies = false
            return
        }
        if replies.isEmpty, let token = comment.repliesPage {
            loadingReplies = true
            defer { loadingReplies = false }
            do {
                let page = try await client.commentsNextPage(videoID: videoID, nextPage: token)
                replies =
                    CommentWorkBudget.displays(
                        from: page.comments ?? [],
                        identityScope: "replies:\(comment.id)",
                        remainingCount: CommentWorkBudget.maximumCommentsPerPage,
                        remainingBytes: CommentWorkBudget.maximumAggregateBytes
                    ).items
                replyError = nil
            } catch {
                replyError = error.localizedDescription
                return
            }
        }
        showReplies = true
    }
}
