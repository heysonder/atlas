import SwiftUI

struct PlayerInfoCommentsSection: View {
    let loader: CommentsLoader?
    let videoID: String
    let currentPlaybackSeconds: Double?
    let inline: Bool
    let onTimestampTap: (Int) -> Void

    /// Inline mode presents the full list as a sheet over the still-playing
    /// video (the Info sheet pushes instead — it already lives in a sheet).
    @State private var showingAllComments = false

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
                } else {
                    ForEach(previewComments(loader)) { comment in
                        CommentRow(
                            comment: comment,
                            client: loader.client,
                            videoID: videoID,
                            onTimestampTap: onTimestampTap)
                    }
                    if inline {
                        allCommentsSheetButton
                    } else {
                        viewAllCommentsLink(loader)
                    }
                }
            }
        }
        .sheet(isPresented: $showingAllComments) {
            if let loader {
                NavigationStack {
                    CommentsView(loader: loader, onTimestampTap: onTimestampTap)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // Medium keeps the video visible and interactive above the
                // sheet, so comments read alongside playback.
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
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
        .accessibilityAddTraits(.isHeader)
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

        if let active = loader.activeTimestampComment(at: currentPlaybackSeconds),
            !selected.containsComment(active)
        {
            selected.append(active)
        }

        for comment in comments where selected.count < 2 && !selected.containsComment(comment) {
            selected.append(comment)
        }

        return Array(selected.prefix(2))
    }

    private var allCommentsSheetButton: some View {
        Button {
            showingAllComments = true
        } label: {
            HStack {
                Text("View all comments")
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.tint)
            .padding(.top, 2)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension [CommentDisplay] {
    fileprivate func containsComment(_ comment: CommentDisplay) -> Bool {
        contains { $0.id == comment.id }
    }
}
