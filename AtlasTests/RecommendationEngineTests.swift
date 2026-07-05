import Foundation
import SwiftData
import Testing
@testable import Atlas
import PipedKit

@MainActor
@Test func searchSignalsWeightRepeatedRecentQueries() {
    let now = Date(timeIntervalSince1970: 10_000)
    let single = SearchSignal(query: "swiftui", count: 1, lastSearchedAt: now, now: now)
    let repeated = SearchSignal(query: "swiftui", count: 4, lastSearchedAt: now, now: now)

    #expect(repeated.weight > single.weight)
    #expect(repeated.copyCount > single.copyCount)
}

@MainActor
@Test func profileSnapshotOverridesSeedSelectionAndAffinity() {
    let history = [
        historyEntry("a", uploader: "A", watchedAt: 100),
        historyEntry("b", uploader: "B", watchedAt: 90),
        historyEntry("c", uploader: "C", watchedAt: 80),
    ]
    let snapshot = RecommendationProfileSnapshot(
        signature: "sig",
        relatedSeedIDs: ["c"],
        explorationSeedIDs: ["b"],
        candidateSearchQueries: ["cached-query"],
        savedSeedIDs: ["saved-cached"],
        channelAffinityKeys: ["Cached"],
        channelAffinityValues: [9])

    let profile = RecommendationEngine.makeProfile(
        history: history, feedback: [], saved: [], searches: [],
        subscribedIDs: [], snapshot: snapshot, signature: "sig")

    #expect(profile.relatedSeeds.map(\.videoID) == ["c"])
    #expect(profile.explorationSeeds.map(\.videoID) == ["b"])
    #expect(profile.candidateSearchQueries == ["cached-query"])
    #expect(profile.savedSeedIDs == ["saved-cached"])
    #expect(profile.channelAffinity["Cached"] == 9)
}

@MainActor
@Test func profileSeedSelectionCapsDominantChannelsWhenThereIsEnoughVariety() {
    let channelA = (0..<5).map {
        historyEntry("a\($0)", uploader: "A", watchedAt: 100 - Double($0))
    }
    let channelB = (0..<2).map {
        historyEntry("b\($0)", uploader: "B", watchedAt: 80 - Double($0))
    }
    let channelC = (0..<2).map {
        historyEntry("c\($0)", uploader: "C", watchedAt: 70 - Double($0))
    }
    let channelD = (0..<2).map {
        historyEntry("d\($0)", uploader: "D", watchedAt: 60 - Double($0))
    }
    let history = channelA + channelB + channelC + channelD

    let profile = RecommendationEngine.makeProfile(
        history: history, feedback: [], saved: [], searches: [], subscribedIDs: [])

    #expect(profile.relatedSeeds.count == 8)
    #expect(profile.relatedSeeds.filter { $0.uploader == "A" }.count <= 2)
}

@MainActor
@Test func candidateMergeRespectsSourceQuotasAndTracksSources() throws {
    let subscription = try [streamItem("s1"), streamItem("s2"), streamItem("shared")]
    let related = try [streamItem("r1"), streamItem("shared"), streamItem("r2")]

    let pool = RecommendationEngine.mergeCandidateSources([
        CandidateSourceBucket(source: .subscription, items: subscription, limit: 2),
        CandidateSourceBucket(source: .related, items: related,
                              frequency: ["shared": 3, "r1": 1], limit: 2),
    ], target: 5)

    #expect(pool.items.compactMap(\.videoID) == ["s1", "s2", "r1", "shared", "r2"])
    // "shared" was listed by the subscription source too — quota only limits
    // placement, never attribution.
    #expect(pool.sourcesByID["shared"]?.contains(.subscription) == true)
    #expect(pool.sourcesByID["shared"]?.contains(.related) == true)
    #expect(pool.sourcesByID["r2"] == Set([.related]))
    #expect(pool.frequency["shared"] == 3)
    #expect(pool.frequency["r2"] == nil)
}

@MainActor
@Test func candidateMergeKeepsAttributionForDuplicatesAfterQuotaFills() throws {
    let related = try [streamItem("r1"), streamItem("shared")]
    let exploration = try [streamItem("shared"), streamItem("e1")]

    let pool = RecommendationEngine.mergeCandidateSources([
        CandidateSourceBucket(source: .related, items: related,
                              frequency: ["shared": 4], limit: 1),
        CandidateSourceBucket(source: .exploration, items: exploration,
                              frequency: ["shared": 2], limit: 2),
    ], target: 10)

    // r1 fills related's quota, so "shared" can't be *placed* by related — but
    // once exploration places it, related must still be credited (and its
    // frequency count kept) or multi-source items lose their ranking boost.
    #expect(pool.items.compactMap(\.videoID) == ["r1", "shared", "e1"])
    #expect(pool.sourcesByID["shared"] == Set([.related, .exploration]))
    #expect(pool.frequency["shared"] == 4)
}

@MainActor
@Test func candidateMergeDoesNotDoubleCountFrequencyAcrossPools() throws {
    let sharedA = try [streamItem("shared"), streamItem("a2")]
    let sharedB = try [streamItem("shared"), streamItem("b2")]

    let pool = RecommendationEngine.mergeCandidateSources([
        CandidateSourceBucket(source: .related, items: sharedA,
                              frequency: ["shared": 2], limit: 2),
        CandidateSourceBucket(source: .exploration, items: sharedB,
                              frequency: ["shared": 5], limit: 2),
    ], target: 4)

    #expect(pool.items.compactMap(\.videoID) == ["shared", "a2", "b2"])
    #expect(pool.sourcesByID["shared"] == Set([.related, .exploration]))
    #expect(pool.frequency["shared"] == 5)
}

@MainActor
@Test func diversityLimitsRepeatedChannelsInOpeningWindow() throws {
    let ranked = try [
        streamItem("a1", uploader: "A", channelID: "UCA"),
        streamItem("a2", uploader: "A", channelID: "UCA"),
        streamItem("a3", uploader: "A", channelID: "UCA"),
        streamItem("b1", uploader: "B", channelID: "UCB"),
        streamItem("c1", uploader: "C", channelID: "UCC"),
    ]

    let diversified = RecommendationEngine.diversify(
        ranked, window: 4, maxPerChannel: 2, maxPerTopic: 99)
    let firstFourChannels = diversified.prefix(4).map(\.uploaderName)

    #expect(firstFourChannels.filter { $0 == "A" }.count == 2)
    #expect(firstFourChannels.contains("B"))
}

@MainActor
@Test func refreshRotationMovesPreviousTopBelowNextScreenful() throws {
    let ranked = try (1...5).map { try streamItem("v\($0)") }

    let rotated = RecommendationEngine.rotateRecentlyShown(
        ranked, recentTopIDs: ["v1", "v2"], protectedWindow: 3, insertionIndex: 3)

    #expect(rotated.compactMap(\.videoID) == ["v3", "v4", "v5", "v1", "v2"])
}

@MainActor
@Test func watchWeightMatchesDocumentedAnchors() {
    // 0% → 0.5, 50% → 1.0 (the original flat weight), ≥80% → the 4× ceiling.
    #expect(RecommendationEngine.watchWeight(position: 0, duration: 100) == 0.5)
    #expect(RecommendationEngine.watchWeight(position: 50, duration: 100) == 1.0)
    #expect(RecommendationEngine.watchWeight(position: 80, duration: 100) == 4.0)
    #expect(RecommendationEngine.watchWeight(position: 100, duration: 100) == 4.0)
    // Unknown duration stays neutral.
    #expect(RecommendationEngine.watchWeight(position: 30, duration: 0) == 1)
}

@MainActor
@Test func tasteDocDedupCollapsesReplicatedCopies() {
    let replicated: [[String]] = [
        ["swift", "concurrency"],
        ["swift", "concurrency"],
        ["swift", "concurrency"],
        ["rust", "systems"],
        ["swift", "concurrency"],
    ]

    let deduped = RecommendationEngine.deduplicatedDocs(replicated)

    #expect(deduped == [["swift", "concurrency"], ["rust", "systems"]])
}

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
    context.insert(VideoSignalCacheEntry(
        videoID: "wanted",
        category: "Science & technology",
        tags: ["swift"]))
    context.insert(VideoSignalCacheEntry(
        videoID: "other",
        category: "News & politics",
        tags: ["policy"]))

    let signals = RecommendationEngine.freshCachedSignals(for: ["wanted"], in: context)

    #expect(signals["wanted"]?.tags == ["swift"])
    #expect(signals["other"] == nil)
}

private func historyEntry(_ id: String, uploader: String, watchedAt: TimeInterval) -> HistoryEntry {
    HistoryEntry(videoID: id, title: "Video \(id)", uploader: uploader,
                 watchedAt: Date(timeIntervalSince1970: watchedAt),
                 positionSeconds: 90, durationSeconds: 100)
}

private func streamItem(_ id: String, uploader: String = "Uploader",
                        channelID: String = "UC\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))") throws -> StreamItem {
    let json = """
    {
      "url": "/watch?v=\(id)",
      "type": "stream",
      "title": "Video \(id)",
      "uploaderName": "\(uploader)",
      "uploaderUrl": "/channel/\(channelID)"
    }
    """.data(using: .utf8)!
    return try JSONDecoder().decode(StreamItem.self, from: json)
}
