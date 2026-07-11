import Foundation
import PipedKit
import Testing

@testable import Atlas

@MainActor
@Test func commentDisplayPrecomputesPlainTextAndTimestamps() throws {
    let json = """
        {"commentText":"Intro <a href=\\"/watch?v=x&t=83\\">1:23</a><br>Deep &amp; clean 1:02:03"}
        """.data(using: .utf8)!
    let comment = try JSONDecoder().decode(PipedKit.Comment.self, from: json)
    let display = CommentWorkBudget.displays(
        from: [comment],
        identityScope: "test",
        remainingCount: 1,
        remainingBytes: CommentWorkBudget.maximumAggregateBytes
    ).items[0]

    #expect(!display.plainText.contains("<a"))
    #expect(display.plainText.contains("Deep & clean"))
    #expect(display.timestamps.map(\.seconds) == [83, 3723])
    #expect(display.timestamps.map(\.label) == ["1:23", "1:02:03"])
}

@MainActor
@Test func commentDisplayIDsAreUniqueAcrossCollidingCommentsAndPagesAndStableAcrossRebuilds() throws {
    let comments = try [
        decodeDisplayComment(id: "duplicate", text: "First"),
        decodeDisplayComment(id: "duplicate", text: "Second"),
    ]

    let firstBuild = displays(comments, scope: "comments:0")
    let repeatedBuild = displays(comments, scope: "comments:0")
    let nextPage = displays(comments, scope: "comments:1")

    #expect(firstBuild.map(\.plainText) == ["First", "Second"])
    #expect(Set(firstBuild.map(\.id)).count == firstBuild.count)
    #expect(firstBuild.map(\.id) == repeatedBuild.map(\.id))
    #expect(Set(firstBuild.map(\.id)).isDisjoint(with: Set(nextPage.map(\.id))))
}

@MainActor
@Test func commentsLoaderRefreshesTimestampIndexAfterAppendingACommentPage() async throws {
    let initialComment = try decodeDisplayComment(id: "duplicate", text: "Opening 0:05")
    let appendedComment = try decodeDisplayComment(id: "duplicate", text: "Later 0:30")
    let initialPage = CommentsPage(
        comments: [initialComment],
        nextPage: "next-page",
        disabled: false,
        commentCount: 2)
    let appendedPage = CommentsPage(
        comments: [appendedComment],
        nextPage: nil,
        disabled: false,
        commentCount: 2)
    let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
    let loader = CommentsLoader(
        client: client,
        videoID: "video",
        initialPageLoader: { _, _ in initialPage },
        nextPageLoader: { _, _, _ in appendedPage })

    await loader.loadInitial()
    #expect(loader.activeTimestampComment(at: 5)?.plainText == "Opening 0:05")
    #expect(loader.activeTimestampComment(at: 30) == nil)

    await loader.loadMore()

    #expect(loader.comments.map(\.plainText) == ["Opening 0:05", "Later 0:30"])
    #expect(Set(loader.comments.map(\.id)).count == 2)
    #expect(loader.activeTimestampComment(at: 5)?.plainText == "Opening 0:05")
    #expect(loader.activeTimestampComment(at: 30)?.plainText == "Later 0:30")
}

@MainActor
@Test func commentsLoaderRetainsFailedCursorForExplicitRetry() async throws {
    let initialPage = CommentsPage(
        comments: [try decodeDisplayComment(id: "first", text: "First")],
        nextPage: "retry-token",
        disabled: false,
        commentCount: 2)
    let appendedPage = CommentsPage(
        comments: [try decodeDisplayComment(id: "second", text: "Second")],
        nextPage: nil,
        disabled: false,
        commentCount: 2)
    let attempts = CommentPageAttemptCounter()
    let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
    let loader = CommentsLoader(
        client: client,
        videoID: "video",
        initialPageLoader: { _, _ in initialPage },
        nextPageLoader: { _, _, _ in
            guard await attempts.next() > 1 else { throw CommentPageTestError.failed }
            return appendedPage
        })

    await loader.loadInitial()
    await loader.loadMore()

    #expect(loader.paginationError != nil)
    #expect(loader.nextPageToken == "retry-token")
    #expect(loader.comments.count == 1)

    await loader.retryLoadMore()

    #expect(loader.paginationError == nil)
    #expect(loader.nextPageToken == nil)
    #expect(loader.comments.map(\.plainText) == ["First", "Second"])
    #expect(await attempts.value == 2)
}

@MainActor
@Test func commentsLoaderKeepsCursorWhenLoadMoreIsReentered() async throws {
    let initialPage = CommentsPage(
        comments: [try decodeDisplayComment(id: "first", text: "First")],
        nextPage: "next-token",
        disabled: false,
        commentCount: 2)
    let appendedPage = CommentsPage(
        comments: [try decodeDisplayComment(id: "second", text: "Second")],
        nextPage: nil,
        disabled: false,
        commentCount: 2)
    let controlledPage = ControlledCommentPageLoader()
    let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
    let loader = CommentsLoader(
        client: client,
        videoID: "video",
        initialPageLoader: { _, _ in initialPage },
        nextPageLoader: { _, _, _ in await controlledPage.load() })

    await loader.loadInitial()
    async let firstLoad: Void = loader.loadMore()
    await controlledPage.waitUntilStarted()

    await loader.loadMore()
    #expect(loader.nextPageToken == "next-token")

    await controlledPage.finish(with: appendedPage)
    await firstLoad
    #expect(loader.comments.map(\.plainText) == ["First", "Second"])
    #expect(loader.nextPageToken == nil)
}

private actor CommentPageAttemptCounter {
    private(set) var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

private actor ControlledCommentPageLoader {
    private var started = false
    private var continuation: CheckedContinuation<CommentsPage, Never>?

    func load() async -> CommentsPage {
        started = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func finish(with page: CommentsPage) {
        continuation?.resume(returning: page)
        continuation = nil
    }
}

private enum CommentPageTestError: Error {
    case failed
}

private func displays(_ comments: [PipedKit.Comment], scope: String) -> [CommentDisplay] {
    CommentWorkBudget.displays(
        from: comments,
        identityScope: scope,
        remainingCount: CommentWorkBudget.maximumComments,
        remainingBytes: CommentWorkBudget.maximumAggregateBytes
    ).items
}

private func decodeDisplayComment(id: String, text: String) throws -> PipedKit.Comment {
    let data = try JSONSerialization.data(withJSONObject: [
        "commentId": id,
        "commentText": text,
        "replyCount": 0,
    ])
    return try JSONDecoder().decode(PipedKit.Comment.self, from: data)
}
