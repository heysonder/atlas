import Foundation
import PipedKit
import Testing

@testable import Atlas

@MainActor
private func makeLoader(
    pages: [Result<LiveChatPage, Error>]
) throws -> LiveChatLoader {
    let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
    let queue = PageQueue(pages: pages)
    return LiveChatLoader(
        client: client,
        videoID: "video01",
        pageLoader: { _, _ in try await queue.next() },
        sleeper: { _ in })
}

private actor PageQueue {
    private var pages: [Result<LiveChatPage, Error>]

    init(pages: [Result<LiveChatPage, Error>]) {
        self.pages = pages
    }

    func next() throws -> LiveChatPage {
        guard !pages.isEmpty else { throw URLError(.timedOut) }
        return try pages.removeFirst().get()
    }
}

private func textMessage(
    id: String, text: String = "hi", usec: Int64
) -> LiveChatMessage {
    LiveChatMessage(
        id: id, type: "liveChatTextMessageRenderer", text: text,
        author: "@a", timestampUsec: "\(usec)")
}

private func page(
    _ messages: [LiveChatMessage], pollAfterMs: Int? = 10_000
) -> LiveChatPage {
    LiveChatPage(
        videoId: "video01", messages: messages,
        nextPageToken: "t", pollAfterMs: pollAfterMs)
}

@MainActor
@Test func pollsDeduplicateOverlappingWindowsAndKeepTimestampOrder() async throws {
    let loader = try makeLoader(pages: [
        .success(page([textMessage(id: "a", usec: 2), textMessage(id: "b", usec: 3)])),
        .success(
            page([
                textMessage(id: "b", usec: 3),
                textMessage(id: "c", usec: 1),
                textMessage(id: "d", usec: 4),
            ])),
    ])

    await loader.refresh()
    await loader.refresh()

    #expect(loader.availability == .active)
    #expect(loader.messages.map(\.id) == ["c", "a", "b", "d"])
}

@MainActor
@Test func nonTextAndEmptyMessagesAreDropped() async throws {
    let engagement = LiveChatMessage(
        id: "e", type: "liveChatViewerEngagementMessageRenderer", text: "Welcome!",
        author: nil)
    let blank = textMessage(id: "blank", text: "   ", usec: 1)
    let missingID = LiveChatMessage(
        id: nil, type: "liveChatTextMessageRenderer", text: "no id", author: "@a")
    let kept = textMessage(id: "kept", usec: 2)

    let loader = try makeLoader(pages: [
        .success(page([engagement, blank, missingID, kept]))
    ])
    await loader.refresh()

    #expect(loader.messages.map(\.id) == ["kept"])
}

@MainActor
@Test func transcriptIsCappedToNewestMessages() async throws {
    let overflow = (0..<(LiveChatLoader.maximumRetainedMessages + 25)).map {
        textMessage(id: "m\($0)", usec: Int64($0))
    }
    let loader = try makeLoader(pages: [.success(page(overflow))])
    await loader.refresh()

    #expect(loader.messages.count == LiveChatLoader.maximumRetainedMessages)
    #expect(loader.messages.first?.id == "m25")
    #expect(loader.messages.last?.id == "m\(overflow.count - 1)")
}

@MainActor
@Test func serverRejectionBeforeAnyMessagesHidesChat() async throws {
    let loader = try makeLoader(pages: [
        .failure(PipedError.upstream("This video does not have live chat"))
    ])
    await loader.refresh()
    #expect(loader.availability == .unavailable)
}

@MainActor
@Test func serverRejectionAfterMessagesEndsChatButKeepsTranscript() async throws {
    let loader = try makeLoader(pages: [
        .success(page([textMessage(id: "a", usec: 1)])),
        .failure(PipedError.http(404)),
    ])
    await loader.refresh()
    await loader.refresh()

    #expect(loader.availability == .ended)
    #expect(loader.messages.map(\.id) == ["a"])
}

@MainActor
@Test func transientFailuresKeepPollingState() async throws {
    let loader = try makeLoader(pages: [
        .success(page([textMessage(id: "a", usec: 1)])),
        .failure(URLError(.timedOut)),
        .failure(PipedError.http(503)),
    ])
    await loader.refresh()
    await loader.refresh()
    await loader.refresh()

    #expect(loader.availability == .active)
    #expect(loader.messages.map(\.id) == ["a"])
}

@MainActor
@Test func runStopsOncePermanentlyRejected() async throws {
    let loader = try makeLoader(pages: [
        .success(page([textMessage(id: "a", usec: 1)])),
        .success(page([textMessage(id: "b", usec: 2)])),
        .failure(PipedError.http(404)),
    ])

    // The queue throws URLError (transient) once drained, so run() only
    // terminating proves the permanent rejection stopped the loop.
    await loader.run()

    #expect(loader.availability == .ended)
    #expect(loader.messages.map(\.id) == ["a", "b"])
}

@Test func pollIntervalIsClampedToProtectSmallInstances() {
    #expect(LiveChatLoader.clampedPollInterval(nil) == LiveChatLoader.defaultPollMilliseconds)
    #expect(LiveChatLoader.clampedPollInterval(10_000) == LiveChatLoader.targetPollMilliseconds)
    #expect(LiveChatLoader.clampedPollInterval(3_000) == 3_000)
    #expect(LiveChatLoader.clampedPollInterval(50) == LiveChatLoader.minimumPollMilliseconds)
    // A server asking for a long delay is capped at the target, not the max.
    #expect(
        LiveChatLoader.clampedPollInterval(600_000) == LiveChatLoader.targetPollMilliseconds)
}

@Test func permanentFailureClassification() {
    #expect(LiveChatLoader.isPermanentFailure(PipedError.upstream("no chat")))
    #expect(LiveChatLoader.isPermanentFailure(PipedError.http(404)))
    #expect(!LiveChatLoader.isPermanentFailure(PipedError.http(503)))
    #expect(!LiveChatLoader.isPermanentFailure(URLError(.timedOut)))
    #expect(!LiveChatLoader.isPermanentFailure(PipedError.decoding("x")))
}
