import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func videoSignalCacheEntryExposesCachedSignals() {
    let entry = VideoSignalCacheEntry(
        videoID: "v1", category: "Science & technology",
        tags: ["physics", "space"], topicKey: "yt:science & technology")

    #expect(entry.videoSignals.category == "Science & technology")
    #expect(entry.videoSignals.tags == ["physics", "space"])
    #expect(entry.videoSignals.topicKey == "yt:science & technology")
}

@MainActor
@Test func batchedSignalCacheFiltersExpiredEntries() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let fresh = VideoSignalCacheEntry(
        videoID: "fresh",
        category: "Science & technology",
        tags: ["swift"],
        updatedAt: now.addingTimeInterval(-60))
    let expired = VideoSignalCacheEntry(
        videoID: "expired",
        category: "News & politics",
        tags: ["policy"],
        updatedAt: now.addingTimeInterval(-31 * 86_400))

    let signals = RecommendationEngine.freshCachedSignals(from: [fresh, expired], now: now)

    #expect(signals["fresh"]?.category == "Science & technology")
    #expect(signals["expired"] == nil)
}

@MainActor
@Test func batchedSignalCacheFetchesRequestedIDsFromSwiftData() throws {
    let schema = Schema([VideoSignalCacheEntry.self])
    let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [config])
    let context = container.mainContext
    context.insert(
        VideoSignalCacheEntry(
            videoID: "wanted",
            category: "Science & technology",
            tags: ["swift"]))
    context.insert(
        VideoSignalCacheEntry(
            videoID: "other",
            category: "News & politics",
            tags: ["policy"]))

    let signals = RecommendationEngine.freshCachedSignals(for: ["wanted"], in: context)

    #expect(signals["wanted"]?.tags == ["swift"])
    #expect(signals["other"] == nil)
}
