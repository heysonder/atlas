import Testing

@testable import Atlas

@MainActor
@Test func subscriptionAndRecommendationInputsAreBoundedBeforeRequests() {
    let channelIDs = (0..<150).map { " channel-\($0) " } + ["channel-1", String(repeating: "x", count: 300)]
    let subscription = SubscriptionFeedLoader.boundedChannelIDs(channelIDs)
    let recommendation = RecommendationEngine.prioritizedChannelIDs(channelIDs)

    #expect(subscription.count == SubscriptionFeedLoader.maximumChannels)
    #expect(Set(subscription).count == subscription.count)
    #expect(recommendation.count == RecommendationWorkBudget.maximumSubscriptionRequests)
    #expect(recommendation.first == "channel-0")
    #expect(recommendation.last == "channel-23")
    #expect(
        SubscriptionFeedLoader.nextCursor(
            candidate: "next", requested: "current", requestedCursors: ["current"],
            hasNewItems: true, pagesFetched: 2) == "next")
    #expect(
        SubscriptionFeedLoader.nextCursor(
            candidate: "current", requested: "current", requestedCursors: ["current"],
            hasNewItems: true, pagesFetched: 2) == nil)
    #expect(
        SubscriptionFeedLoader.nextCursor(
            candidate: "next", requested: "current", requestedCursors: ["current"],
            hasNewItems: false, pagesFetched: 2) == nil)
    #expect(
        SubscriptionFeedLoader.nextCursor(
            candidate: "next", requested: "current", requestedCursors: ["current"],
            hasNewItems: true, pagesFetched: SubscriptionFeedLoader.maximumPagesPerChannel) == nil)
}

@MainActor
@Test func recommendationMetadataAndTokenWorkIsBounded() {
    let tags = (0..<200).map { "tag-\($0)-" + String(repeating: "x", count: 400) }
    let signals = VideoSignals(
        category: String(repeating: "c", count: 10_000),
        tags: tags,
        topicKey: String(repeating: "k", count: 10_000))
    let tokens = RecommendationWorkBudget.tokens(
        Array(repeating: "meaningful", count: 500).joined(separator: " "),
        excluding: [])

    #expect(signals.category?.utf8.count == RecommendationWorkBudget.maximumFieldBytes)
    #expect(signals.tags.count == RecommendationWorkBudget.maximumTags)
    #expect(signals.tags.allSatisfy { $0.utf8.count <= RecommendationWorkBudget.maximumTagBytes })
    #expect(tokens.count == RecommendationWorkBudget.maximumTokensPerDocument)
}
