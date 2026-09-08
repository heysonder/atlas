import Foundation
import PipedKit
import Testing

@testable import Atlas

private actor ReplayPageServer {
    private var pages: [String?: Result<LiveChatPage, Error>]
    private(set) var requestedTokens: [String?] = []

    init(pages: [String?: Result<LiveChatPage, Error>]) {
        self.pages = pages
    }

    func page(for token: String?) throws -> LiveChatPage {
        requestedTokens.append(token)
        guard let result = pages[token] else { throw URLError(.timedOut) }
        return try result.get()
    }

    func replace(_ token: String?, with result: Result<LiveChatPage, Error>) {
        pages[token] = result
    }
}

@MainActor
private func makeLoader(server: ReplayPageServer) throws -> LiveChatReplayLoader {
    let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
    return LiveChatReplayLoader(
        client: client,
        videoID: "video01",
        pageLoader: { _, _, token in try await server.page(for: token) })
}

nonisolated private func replayMessage(id: String, offsetMs: Int) -> LiveChatMessage {
    LiveChatMessage(
        id: id, type: "liveChatTextMessageRenderer", text: "msg \(id)", author: "@a",
        videoOffsetMs: offsetMs, timestampText: "0:\(offsetMs / 1_000)")
}

nonisolated private func page(_ messages: [LiveChatMessage], next: String?) -> LiveChatPage {
    LiveChatPage(videoId: "video01", messages: messages, nextPageToken: next, pollAfterMs: 0)
}

@MainActor
@Test func replayPagesChainThroughTokensInOrder() async throws {
    let server = ReplayPageServer(pages: [
        nil: .success(page([replayMessage(id: "a", offsetMs: 3_000)], next: "p2")),
        "p2": .success(page([replayMessage(id: "b", offsetMs: 30_000)], next: "p3")),
        // A quiet stretch of the stream: no messages, but the walk continues.
        "p3": .success(page([], next: "p4")),
        "p4": .success(page([], next: nil)),
    ])
    let loader = try makeLoader(server: server)

    await loader.loadInitial()
    #expect(loader.didLoad)
    #expect(loader.messages.map(\.id) == ["a"])
    #expect(loader.messages.first?.videoOffsetSeconds == 3)
    #expect(loader.messages.first?.timestampText == "0:3")

    await loader.loadMore()
    #expect(loader.messages.map(\.id) == ["a", "b"])
    #expect(!loader.reachedEnd)

    await loader.loadMore()
    #expect(!loader.reachedEnd)
    await loader.loadMore()
    #expect(loader.reachedEnd)
    #expect(await server.requestedTokens == [nil, "p2", "p3", "p4"])

    await loader.loadMore()
    #expect(await server.requestedTokens.count == 4)
}

@MainActor
@Test func replayEndsWhenTokenMissingOrRepeated() async throws {
    let server = ReplayPageServer(pages: [
        nil: .success(page([replayMessage(id: "a", offsetMs: 0)], next: "same")),
        "same": .success(page([replayMessage(id: "b", offsetMs: 1_000)], next: "same")),
    ])
    let loader = try makeLoader(server: server)
    await loader.loadInitial()
    await loader.loadMore()

    #expect(loader.messages.map(\.id) == ["a", "b"])
    #expect(loader.reachedEnd)
}

@MainActor
@Test func replayRejectionHidesSection() async throws {
    let server = ReplayPageServer(pages: [
        nil: .failure(PipedError.http(404))
    ])
    let loader = try makeLoader(server: server)
    await loader.loadInitial()

    #expect(loader.unavailable)
    #expect(!loader.didLoad)
}

@MainActor
@Test func replayTransientFirstPageFailureOffersRetry() async throws {
    let server = ReplayPageServer(pages: [
        nil: .failure(URLError(.timedOut))
    ])
    let loader = try makeLoader(server: server)
    await loader.loadInitial()
    #expect(loader.loadFailed)
    #expect(!loader.unavailable)

    await server.replace(nil, with: .success(page([replayMessage(id: "a", offsetMs: 0)], next: nil)))
    await loader.loadInitial()
    #expect(loader.didLoad)
    #expect(!loader.loadFailed)
    #expect(loader.reachedEnd)
}

@MainActor
@Test func replayLoadMoreFailureKeepsTokenForRetry() async throws {
    let server = ReplayPageServer(pages: [
        nil: .success(page([replayMessage(id: "a", offsetMs: 0)], next: "p2")),
        "p2": .failure(PipedError.http(503)),
    ])
    let loader = try makeLoader(server: server)
    await loader.loadInitial()
    await loader.loadMore()
    #expect(loader.paginationFailed)
    #expect(loader.messages.map(\.id) == ["a"])

    await server.replace("p2", with: .success(page([replayMessage(id: "b", offsetMs: 5_000)], next: nil)))
    await loader.retryLoadMore()
    #expect(!loader.paginationFailed)
    #expect(loader.messages.map(\.id) == ["a", "b"])
}

@MainActor
@Test func replayFollowsPlayheadOnePageAtATime() async throws {
    let server = ReplayPageServer(pages: [
        nil: .success(page([replayMessage(id: "a", offsetMs: 3_000)], next: "p2")),
        "p2": .success(page([replayMessage(id: "b", offsetMs: 30_000)], next: "p3")),
        "p3": .success(page([replayMessage(id: "c", offsetMs: 60_000)], next: "p4")),
        "p4": .success(page([replayMessage(id: "d", offsetMs: 90_000)], next: nil)),
    ])
    let loader = try makeLoader(server: server)
    await loader.loadInitial()
    #expect(loader.coveredSeconds == 3)

    // Playhead at 0s: coverage (3s) is short of the 30s lookahead → one page.
    await loader.follow(playbackSeconds: 0)
    #expect(loader.coveredSeconds == 30)
    #expect(await server.requestedTokens == [nil, "p2"])

    // Still short (30 < 0 + 30 is false) → nothing more at this tick.
    await loader.follow(playbackSeconds: 0)
    #expect(await server.requestedTokens.count == 2)

    // Playback moves on; each tick buys at most one page, even after a far seek.
    await loader.follow(playbackSeconds: 3_600)
    #expect(await server.requestedTokens == [nil, "p2", "p3"])
    await loader.follow(playbackSeconds: 3_600)
    #expect(loader.reachedEnd)
    await loader.follow(playbackSeconds: 3_600)
    #expect(await server.requestedTokens.count == 4)

    await loader.follow(playbackSeconds: nil)
    #expect(await server.requestedTokens.count == 4)
}

@MainActor
@Test func replayShowsOnlyMessagesUpToThePlayhead() async throws {
    let server = ReplayPageServer(pages: [
        nil: .success(
            page(
                [
                    replayMessage(id: "a", offsetMs: 1_000),
                    replayMessage(id: "b", offsetMs: 7_500),
                    replayMessage(id: "c", offsetMs: 9_000),
                ], next: nil))
    ])
    let loader = try makeLoader(server: server)
    await loader.loadInitial()

    #expect(loader.visibleMessages(at: 0).isEmpty)
    #expect(loader.visibleMessages(at: 1).map(\.id) == ["a"])
    #expect(loader.visibleMessages(at: 7.9).map(\.id) == ["a", "b"])
    #expect(loader.visibleMessages(at: 120).map(\.id) == ["a", "b", "c"])
    #expect(loader.visibleMessages(at: nil).map(\.id) == ["a", "b", "c"])
}

@MainActor
@Test func replayBufferDropsOldestPastTheCap() async throws {
    let overflow = (0..<(LiveChatReplayLoader.maximumRetainedMessages + 10)).map {
        replayMessage(id: "m\($0)", offsetMs: $0 * 1_000)
    }
    let server = ReplayPageServer(pages: [nil: .success(page(overflow, next: nil))])
    let loader = try makeLoader(server: server)
    await loader.loadInitial()

    #expect(loader.messages.count == LiveChatReplayLoader.maximumRetainedMessages)
    #expect(loader.messages.first?.id == "m10")
    #expect(loader.visibleMessages(at: 1_000_000).count == LiveChatReplayLoader.maximumVisibleMessages)
}

@MainActor
@Test func replayDeduplicatesAcrossPages() async throws {
    let server = ReplayPageServer(pages: [
        nil: .success(page([replayMessage(id: "a", offsetMs: 0)], next: "p2")),
        "p2": .success(
            page([replayMessage(id: "a", offsetMs: 0), replayMessage(id: "b", offsetMs: 1)], next: nil)),
    ])
    let loader = try makeLoader(server: server)
    await loader.loadInitial()
    await loader.loadMore()
    #expect(loader.messages.map(\.id) == ["a", "b"])
}

@MainActor
@Test func replayPollingLetsSlowPagesFinishWhilePlaybackAdvances() async throws {
    let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
    let clock = PlayerPlaybackTime()
    clock.seconds = 0
    let loader = LiveChatReplayLoader(
        client: client, videoID: "slow-replay",
        pageLoader: { _, _, token in
            if token == nil { return page([replayMessage(id: "first", offsetMs: 0)], next: "p2") }
            // Slower than the old one-second cancellation cycle.
            try await Task.sleep(for: .milliseconds(1_100))
            return page([replayMessage(id: "next", offsetMs: 2_000)], next: nil)
        })
    await loader.loadInitial()
    let polling = Task { await loader.run { clock.seconds } }
    defer { polling.cancel() }
    for tick in 1...3 {
        try await Task.sleep(for: .milliseconds(100))
        clock.seconds = Double(tick)
    }
    await polling.value
    #expect(loader.reachedEnd)
    #expect(!loader.paginationFailed)
    #expect(loader.messages.map(\.id) == ["first", "next"])
}

@MainActor
@Test func closingReplayCancelsItsPendingPageAndKeepsTheCursor() async throws {
    let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
    let (started, continuation) = AsyncStream<Void>.makeStream()
    let loader = LiveChatReplayLoader(
        client: client, videoID: "cancelled-replay",
        pageLoader: { _, _, token in
            if token == nil { return page([replayMessage(id: "first", offsetMs: 0)], next: "p2") }
            continuation.yield(())
            try await Task.sleep(for: .seconds(30))
            return page([], next: nil)
        })
    await loader.loadInitial()
    let polling = Task { await loader.run { 0 } }
    var iterator = started.makeAsyncIterator()
    _ = await iterator.next()
    polling.cancel()
    await polling.value
    continuation.finish()
    #expect(!loader.isLoading)
    #expect(!loader.reachedEnd)
    #expect(loader.messages.map(\.id) == ["first"])
}
