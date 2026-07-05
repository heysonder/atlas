import SwiftUI
import PipedKit

struct PlayerInfoCommentsSection: View {
    let loader: CommentsLoader?
    let videoID: String
    let currentPlaybackSeconds: Double?
    let inline: Bool
    @Binding var timestampPreviewIndex: TimestampCommentPreviewIndex
    let onTimestampTap: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            commentsHeader

            if let loader {
                if loader.disabled {
                    commentsNotice("Comments are turned off.")
                } else if loader.loadFailed {
                    HStack(spacing: 8) {
                        commentsNotice("Couldn’t load comments.")
                        Button("Retry") {
                            Task { await loader.loadInitial() }
                        }
                        .font(.callout.weight(.semibold))
                    }
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
                    ForEach(previewComments(loader)) { comment in
                        CommentRow(
                            comment: comment,
                            client: loader.client,
                            videoID: videoID,
                            onTimestampTap: onTimestampTap)
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

    private func previewComments(_ loader: CommentsLoader) -> [CommentDisplay] {
        let comments = loader.comments
        guard !comments.isEmpty else { return [] }

        var selected: [CommentDisplay] = []
        if let pinned = comments.first(where: { $0.pinned == true }) {
            selected.append(pinned)
        } else if let first = comments.first {
            selected.append(first)
        }

        if let active = activeTimestampComment(in: comments), !selected.containsComment(active) {
            selected.append(active)
        }

        for comment in comments where selected.count < 2 && !selected.containsComment(comment) {
            selected.append(comment)
        }

        return Array(selected.prefix(2))
    }

    private func activeTimestampComment(in comments: [CommentDisplay]) -> CommentDisplay? {
        guard let currentPlaybackSeconds, currentPlaybackSeconds.isFinite else { return nil }
        timestampPreviewIndex.updateIfNeeded(comments)
        return timestampPreviewIndex.activeComment(at: Int(currentPlaybackSeconds.rounded(.down)))
    }

    /// All comments, expanded in place and paginated as the user scrolls — used
    /// in the embedded player so comments never push to a separate page.
    @ViewBuilder private func inlineComments(_ loader: CommentsLoader) -> some View {
        ForEach(loader.comments) { comment in
            CommentRow(
                comment: comment,
                client: loader.client,
                videoID: videoID,
                onTimestampTap: onTimestampTap)
            Divider()
        }
        if loader.nextpage != nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                // Keyed on the fetch counter (not the comment count): a page
                // can return zero new comments with a fresh token, which must
                // still re-trigger.
                .task(id: loader.pageFetchCount) { await loader.loadMore() }
        }
    }

    private func viewAllCommentsLink(_ loader: CommentsLoader) -> some View {
        NavigationLink {
            CommentsView(loader: loader, onTimestampTap: onTimestampTap)
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

private extension [CommentDisplay] {
    func containsComment(_ comment: CommentDisplay) -> Bool {
        contains { $0.id == comment.id }
    }
}

struct TimestampCommentPreviewIndex {
    private struct Entry {
        let comment: CommentDisplay
        let timestamp: CommentTimestamp
        let commentIndex: Int
    }

    private var signature = ""
    private var entries: [Entry] = []
    private let activeWindow = 10

    mutating func updateIfNeeded(_ comments: [CommentDisplay]) {
        let newSignature = signature(for: comments)
        guard newSignature != signature else { return }
        signature = newSignature
        entries = comments.enumerated().flatMap { index, comment in
            comment.timestamps.map { Entry(comment: comment, timestamp: $0, commentIndex: index) }
        }
        .sorted {
            if $0.timestamp.seconds == $1.timestamp.seconds {
                return $0.commentIndex < $1.commentIndex
            }
            return $0.timestamp.seconds < $1.timestamp.seconds
        }
    }

    func activeComment(at playhead: Int) -> CommentDisplay? {
        var best: Entry?
        for entry in entries {
            if entry.timestamp.seconds > playhead { break }
            guard playhead < entry.timestamp.seconds + activeWindow else { continue }
            if best == nil
                || entry.timestamp.seconds > best!.timestamp.seconds
                || (entry.timestamp.seconds == best!.timestamp.seconds
                    && entry.commentIndex < best!.commentIndex) {
                best = entry
            }
        }
        return best?.comment
    }

    private func signature(for comments: [CommentDisplay]) -> String {
        guard let first = comments.first else { return "empty" }
        return "\(comments.count)|\(first.id)|\(comments.last?.id ?? "")"
    }
}
