import SwiftUI

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
                } else if loader.loadFailed {
                    VStack(spacing: 12) {
                        unavailable("Couldn’t load comments", "wifi.exclamationmark")
                        Button("Retry") {
                            Task { await loader.loadInitial() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                } else if loader.comments.isEmpty && loader.didLoad {
                    unavailable("No comments yet", "bubble.left")
                } else if !loader.didLoad {
                    ProgressView("Loading comments…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    ForEach(loader.comments) { comment in
                        CommentRow(
                            comment: comment,
                            client: loader.client,
                            videoID: loader.videoID,
                            onTimestampTap: onTimestampTap)
                        Divider()
                    }
                    if let paginationError = loader.paginationError {
                        VStack(spacing: 8) {
                            Label("Couldn’t load more comments", systemImage: "wifi.exclamationmark")
                                .font(.callout.weight(.semibold))
                            Text(paginationError)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Retry") { Task { await loader.retryLoadMore() } }
                                .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    } else if loader.nextPageToken != nil {
                        ProgressView("Loading more comments…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            // Keyed on the fetch counter (not the comment
                            // count): a page can return zero new comments with
                            // a fresh token, which must still re-trigger.
                            .task(id: loader.pageFetchCount) { await loader.loadMore() }
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
