import Foundation
import PipedKit
import Testing

@testable import Atlas

private actor PageAttemptCounter {
    private(set) var value = 0

    func next() -> Int {
        value += 1
        return value
    }
}

@MainActor
@Test func subscriptionFeedRetainsFailedCursorUntilExplicitRetry() async throws {
    let attempts = PageAttemptCounter()
    let initialItems = try (0...30).map { try streamItem(id: "initial-\($0)", uploaded: 100 - $0) }
    let retryItem = try streamItem(id: "retry-success", uploaded: 1)
    let client = PipedClient(baseURL: try #require(URL(string: "https://example.com")))
    let loader = SubscriptionFeedLoader(
        client: client,
        channelIDs: ["channel"],
        initialChannelLoader: { _, _ in channel(items: initialItems, nextPage: "retry-token") },
        nextChannelPageLoader: { _, _, token in
            #expect(token == "retry-token")
            if await attempts.next() == 1 { throw URLError(.timedOut) }
            return channel(items: [retryItem], nextPage: nil)
        })

    await loader.loadInitial()
    #expect(loader.items.count == 30)

    await loader.loadMore()
    #expect(loader.items.count == 31)
    #expect(loader.paginationError != nil)
    #expect(loader.hasMore)
    #expect(await attempts.value == 1)

    await loader.loadMore()
    #expect(await attempts.value == 1)

    await loader.retryLoadMore()
    #expect(loader.items.count == 32)
    #expect(loader.items.last?.videoID == "retry-success")
    #expect(loader.paginationError == nil)
    #expect(!loader.hasMore)
    #expect(await attempts.value == 2)
}

nonisolated private func channel(items: [StreamItem], nextPage: String?) -> Channel {
    Channel(
        id: "channel",
        name: "Creator",
        avatarURL: nil,
        bannerURL: nil,
        description: nil,
        nextPage: nextPage,
        subscriberCount: nil,
        verified: nil,
        relatedStreams: items,
        tabs: nil)
}

private func streamItem(id: String, uploaded: Int) throws -> StreamItem {
    let data = try JSONSerialization.data(withJSONObject: [
        "url": "/watch?v=\(id)",
        "type": "stream",
        "title": id,
        "uploaded": uploaded,
    ])
    return try JSONDecoder().decode(StreamItem.self, from: data)
}
