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
    #expect(pool.sourcesByID["shared"]?.contains(.subscription) == true)
    #expect(pool.sourcesByID["shared"]?.contains(.related) == true)
    #expect(pool.frequency["shared"] == 3)
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

@MainActor
@Test func timestampPreviewIndexPrefersLatestActiveTimestamp() throws {
    let comments = try [
        comment("first", text: "Early note at 0:04"),
        comment("second", text: "Better match at 0:08"),
        comment("third", text: "Later note at 0:30"),
    ]
    var index = TimestampCommentPreviewIndex()
    index.updateIfNeeded(comments)

    #expect(index.activeComment(at: 9)?.id == "second")
    #expect(index.activeComment(at: 18) == nil)
    #expect(index.activeComment(at: 35)?.id == "third")
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

private func comment(_ id: String, text: String) throws -> PipedKit.Comment {
    let json = """
    {
      "commentId": "\(id)",
      "commentText": "\(text)",
      "author": "Tester"
    }
    """.data(using: .utf8)!
    return try JSONDecoder().decode(PipedKit.Comment.self, from: json)
}
