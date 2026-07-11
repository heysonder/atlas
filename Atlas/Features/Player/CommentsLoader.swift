import Observation
import PipedKit

typealias InitialCommentsPageLoader = @Sendable (PipedClient, String) async throws -> CommentsPage
typealias NextCommentsPageLoader =
    @Sendable (PipedClient, String, String) async throws -> CommentsPage

/// Loads and paginates a video's comments. Shared between the preview shown in
/// `PlayerInfoSheet` and the full `CommentsView` that's pushed from it, so the
/// list is fetched once and survives navigation.
@MainActor
@Observable
final class CommentsLoader {
    let client: PipedClient
    let videoID: String

    private(set) var comments: [CommentDisplay] = []
    private(set) var nextPageToken: String?
    private(set) var disabled = false
    private(set) var commentCount = -1
    private(set) var didLoad = false
    private(set) var isLoading = false
    private(set) var paginationError: String?
    /// The initial fetch failed — distinct from "loaded and empty", so the UI
    /// can offer a retry instead of a permanent "No comments yet".
    private(set) var loadFailed = false
    /// Bumped on every completed page fetch, so pagination `.task(id:)` re-keys
    /// even when a page adds no new comments but carries a fresh token.
    private(set) var pageFetchCount = 0

    private var requestedPageTokens = Set<String>()
    private var pageRequestCount = 0
    private var retainedByteCost = 0
    @ObservationIgnored private var timestampPreviewIndex =
        TimestampCommentPreviewIndex(comments: [])
    @ObservationIgnored private let initialPageLoader: InitialCommentsPageLoader
    @ObservationIgnored private let nextPageLoader: NextCommentsPageLoader

    init(
        client: PipedClient,
        videoID: String,
        initialPageLoader: @escaping InitialCommentsPageLoader = { client, videoID in
            try await client.comments(videoID: videoID)
        },
        nextPageLoader: @escaping NextCommentsPageLoader = { client, videoID, token in
            try await client.commentsNextPage(videoID: videoID, nextPage: token)
        }
    ) {
        self.client = client
        self.videoID = videoID
        self.initialPageLoader = initialPageLoader
        self.nextPageLoader = nextPageLoader
    }

    /// Fetches the first page; a no-op once it has succeeded.
    func loadInitial() async {
        guard !didLoad, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let page = try? await initialPageLoader(client, videoID) {
            let bounded = CommentWorkBudget.displays(
                from: page.comments ?? [],
                identityScope: "comments:0",
                remainingCount: CommentWorkBudget.maximumComments,
                remainingBytes: CommentWorkBudget.maximumAggregateBytes)
            replaceComments(with: bounded.items)
            retainedByteCost = bounded.byteCost
            nextPageToken = CommentWorkBudget.cursor(page.nextPage)
            disabled = page.disabled ?? false
            commentCount = CommentWorkBudget.commentCount(page.commentCount)
            didLoad = true
            loadFailed = false
            paginationError = nil
            pageRequestCount = 1
        } else {
            loadFailed = true
        }
        pageFetchCount += 1
    }

    /// Appends the next page when one exists. On failure it stops paginating
    /// rather than dropping the comments already shown.
    func loadMore() async {
        guard !isLoading else { return }
        guard let token = nextPageToken,
            pageRequestCount < CommentWorkBudget.maximumPages,
            requestedPageTokens.insert(token).inserted
        else {
            nextPageToken = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        pageRequestCount += 1
        let identityScope = "comments:\(pageRequestCount - 1)"
        do {
            let page = try await nextPageLoader(client, videoID, token)
            let bounded = CommentWorkBudget.displays(
                from: page.comments ?? [],
                identityScope: identityScope,
                remainingCount: CommentWorkBudget.maximumComments - comments.count,
                remainingBytes: CommentWorkBudget.maximumAggregateBytes - retainedByteCost)
            appendComments(bounded.items)
            retainedByteCost += bounded.byteCost
            let candidate = CommentWorkBudget.cursor(page.nextPage)
            nextPageToken =
                bounded.items.isEmpty || candidate == token
                    || candidate.map(requestedPageTokens.contains) == true ? nil : candidate
            paginationError = nil
        } catch {
            requestedPageTokens.remove(token)
            pageRequestCount -= 1
            paginationError = error.localizedDescription
        }
        pageFetchCount += 1
    }

    func retryLoadMore() async {
        paginationError = nil
        await loadMore()
    }

    func activeTimestampComment(at playbackSeconds: Double?) -> CommentDisplay? {
        guard let playbackSeconds, playbackSeconds.isFinite else { return nil }
        return timestampPreviewIndex.activeComment(
            at: Int(playbackSeconds.rounded(.down)))
    }

    private func replaceComments(with newComments: [CommentDisplay]) {
        comments = newComments
        timestampPreviewIndex = TimestampCommentPreviewIndex(comments: comments)
    }

    private func appendComments(_ newComments: [CommentDisplay]) {
        guard !newComments.isEmpty else { return }
        comments.append(contentsOf: newComments)
        timestampPreviewIndex = TimestampCommentPreviewIndex(comments: comments)
    }
}
