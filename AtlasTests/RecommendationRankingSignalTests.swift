import Foundation
import PipedKit
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func frequencyBoostIsLogDampedAndCapped() {
    #expect(RecommendationEngine.frequencyBoost(0) == 0)
    #expect(RecommendationEngine.frequencyBoost(-3) == 0)
    #expect(RecommendationEngine.frequencyBoost(1) == 0.15)
    // Monotone, but each extra corroborating seed is worth less than the last.
    let one = RecommendationEngine.frequencyBoost(1)
    let three = RecommendationEngine.frequencyBoost(3)
    let seven = RecommendationEngine.frequencyBoost(7)
    #expect(three > one)
    #expect(three - one > seven - three)
    // Capped so a viral candidate can't win on popularity alone.
    #expect(RecommendationEngine.frequencyBoost(1_000) == 0.45)
}

@MainActor
@Test func impressionPenaltyCompoundsAndFloors() {
    #expect(RecommendationEngine.impressionPenalty(0) == 1)
    #expect(RecommendationEngine.impressionPenalty(-1) == 1)
    #expect(RecommendationEngine.impressionPenalty(1) == 0.85)
    #expect(
        RecommendationEngine.impressionPenalty(2)
            < RecommendationEngine.impressionPenalty(1))
    // Capped: a good match sinks, it doesn't vanish forever.
    #expect(
        RecommendationEngine.impressionPenalty(100)
            == RecommendationEngine.impressionPenalty(8))
    #expect(RecommendationEngine.impressionPenalty(8) > 0.2)
}

@MainActor
@Test func uploadFreshnessDecaysToZeroAtHorizon() {
    let now = Date().timeIntervalSince1970
    let today = Int64(now * 1000)
    let fortyDaysAgo = Int64((now - 40 * 86_400) * 1000)
    let ninetyDaysAgo = Int64((now - 90 * 86_400) * 1000)

    #expect(RecommendationEngine.uploadFreshness(nil, now: now, horizonDays: 60) == 0)
    #expect(RecommendationEngine.uploadFreshness(0, now: now, horizonDays: 60) == 0)
    #expect(RecommendationEngine.uploadFreshness(today, now: now, horizonDays: 60) > 0.99)
    let midway = RecommendationEngine.uploadFreshness(fortyDaysAgo, now: now, horizonDays: 60)
    #expect(midway > 0.3 && midway < 0.4)
    #expect(RecommendationEngine.uploadFreshness(ninetyDaysAgo, now: now, horizonDays: 60) == 0)
    // A tighter horizon (subscription uploads) decays the same age harder.
    #expect(
        RecommendationEngine.uploadFreshness(fortyDaysAgo, now: now, horizonDays: 14) == 0)
}

@MainActor
@Test func noveltySlotsPromoteUnfamiliarChannelsIntoTheFirstWindow() throws {
    // 20 familiar-channel items, then two novel channels buried at the tail.
    var items = try (0..<20).map { try rankedItem("f\($0)", uploader: "Familiar\($0)") }
    items.append(try rankedItem("n1", uploader: "NovelOne"))
    items.append(try rankedItem("f20", uploader: "Familiar20"))
    items.append(try rankedItem("n2", uploader: "NovelTwo"))
    let profile = profileWithAffinity(
        for: (0...20).map { "Familiar\($0)" }, subscribedIDs: [])

    let injected = RecommendationEngine.injectNoveltySlots(items, profile: profile)

    #expect(injected.count == items.count)
    #expect(injected[4].videoID == "n1")
    #expect(injected[9].videoID == "n2")
    // Everything else keeps its relative order.
    let rest = injected.compactMap(\.videoID).filter { $0 != "n1" && $0 != "n2" }
    #expect(rest == (0...20).map { "f\($0)" })
}

@MainActor
@Test func noveltySlotsRespectNovelItemsAlreadyOnTheFirstScreen() throws {
    // Two novel channels already inside the window — the quota is met, so
    // nothing should move.
    var items = [
        try rankedItem("n1", uploader: "NovelOne"),
        try rankedItem("n2", uploader: "NovelTwo"),
    ]
    items += try (0..<20).map { try rankedItem("f\($0)", uploader: "Familiar\($0)") }
    let profile = profileWithAffinity(
        for: (0..<20).map { "Familiar\($0)" }, subscribedIDs: [])

    let injected = RecommendationEngine.injectNoveltySlots(items, profile: profile)

    #expect(injected.compactMap(\.videoID) == items.compactMap(\.videoID))
}

@MainActor
@Test func noveltySlotsTreatSubscribedChannelsAsFamiliar() throws {
    var items = try (0..<16).map { try rankedItem("f\($0)", uploader: "Familiar\($0)") }
    items.append(try rankedItem("sub1", uploader: "SubOnly", channelID: "UCSUB"))
    items.append(try rankedItem("n1", uploader: "NovelOne"))
    let profile = profileWithAffinity(
        for: (0..<16).map { "Familiar\($0)" }, subscribedIDs: ["UCSUB"])

    let injected = RecommendationEngine.injectNoveltySlots(items, profile: profile)

    // The subscribed channel isn't novelty; the genuinely unfamiliar one is.
    #expect(injected[4].videoID == "n1")
    #expect(injected.compactMap(\.videoID).filter { $0 == "sub1" }.count == 1)
}

@MainActor
@Test func impressionStoreCountsRecordsAndCaps() throws {
    let container = try makeTestContainer()
    let context = container.mainContext

    FeedImpressionStore.record(["a", "b", "a"], in: context)
    var counts = FeedImpressionStore.counts(in: context)
    // Deduped within one call: a render pass counts each slot once.
    #expect(counts["a"] == 1)
    #expect(counts["b"] == 1)

    for _ in 0..<20 { FeedImpressionStore.record(["a"], in: context) }
    counts = FeedImpressionStore.counts(in: context)
    // Capped: the penalty saturates, the row shouldn't grow forever.
    #expect(counts["a"] == 12)
    #expect(counts["b"] == 1)
}

@MainActor
@Test func impressionStoreForgetsStaleRows() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let longAgo = Date().addingTimeInterval(-60 * 86_400)

    FeedImpressionStore.record(["old"], in: context, now: longAgo)
    #expect(FeedImpressionStore.counts(in: context)["old"] == nil)

    // The next record pass also deletes the expired row outright.
    FeedImpressionStore.record(["fresh"], in: context)
    let remaining = try context.fetch(FetchDescriptor<FeedImpressionEntry>())
    #expect(remaining.map(\.videoID) == ["fresh"])
}

@MainActor
@Test func longTermTasteKeepsStrongWatchesWithinWindowAndChannelCap() {
    let now = Date()
    func entry(
        _ id: String, uploader: String, daysAgo: Double, watchedFraction: Double
    ) -> HistorySignal {
        HistorySignal(
            videoID: id, title: "Video \(id)", uploader: uploader,
            watchedAt: now.addingTimeInterval(-daysAgo * 86_400),
            positionSeconds: watchedFraction * 100, durationSeconds: 100)
    }
    let history = [
        entry("recent", uploader: "A", daysAgo: 2, watchedFraction: 0.9),
        entry("strong1", uploader: "A", daysAgo: 10, watchedFraction: 0.9),
        entry("strong2", uploader: "A", daysAgo: 11, watchedFraction: 0.9),
        entry("strong3", uploader: "A", daysAgo: 12, watchedFraction: 0.9),  // over channel cap
        entry("weak", uploader: "B", daysAgo: 10, watchedFraction: 0.3),  // not a strong watch
        entry("strongB", uploader: "B", daysAgo: 20, watchedFraction: 0.85),
        entry("tooOld", uploader: "C", daysAgo: 40, watchedFraction: 1.0),  // outside 30d
    ]

    let longTerm = RecommendationEngine.longTermTasteSignals(
        history, excluding: ["recent"], now: now)

    #expect(longTerm.map(\.videoID) == ["strong1", "strong2", "strongB"])
}

@MainActor
@Test func impressionTapClearsThePenaltyRow() throws {
    let container = try makeTestContainer()
    let context = container.mainContext

    FeedImpressionStore.record(["a", "b"], in: context)
    FeedImpressionStore.recordTap("a", in: context)

    let counts = FeedImpressionStore.counts(in: context)
    #expect(counts["a"] == nil)
    #expect(counts["b"] == 1)
}

@MainActor
@Test func outcomeStoreLogsImpressionsAndMarksTaps() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    let features = RecommendationOutcomeFeatures(
        topicSimilarity: 0.6, longTermSimilarity: 0.4, categoryFit: 0.8,
        corroboration: 2, freshness: 0.5, channelAffinity: 0.3,
        isSubscribed: true, dislikeSimilarity: 0, priorImpressions: 1,
        fromRelated: true, fromSearch: false, fromSaved: false,
        fromSubscription: true, fromExploration: false,
        usedContextualEmbedding: false)

    RecommendationOutcomeStore.record(
        [
            .init(videoID: "a", position: 0, features: features),
            .init(videoID: "b", position: 3, features: features),
        ], in: context)
    RecommendationOutcomeStore.recordTap("b", in: context)

    let rows = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
    #expect(rows.count == 2)
    let tapped = rows.first { $0.videoID == "b" }
    #expect(tapped?.tapped == true)
    #expect(tapped?.position == 3)
    #expect(tapped?.topicSimilarity == 0.6)
    #expect(rows.first { $0.videoID == "a" }?.tapped == false)
    // A tap on a video that was never logged is a quiet no-op.
    RecommendationOutcomeStore.recordTap("missing", in: context)
}

private func rankedItem(
    _ id: String, uploader: String, channelID: String? = nil
) throws -> StreamItem {
    let channel = channelID ?? "UC\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let json = """
        {
          "url": "/watch?v=\(id)",
          "type": "stream",
          "title": "Video \(id)",
          "uploaderName": "\(uploader)",
          "uploaderUrl": "/channel/\(channel)"
        }
        """.data(using: .utf8)!
    return try JSONDecoder().decode(StreamItem.self, from: json)
}

private func profileWithAffinity(
    for uploaders: [String], subscribedIDs: Set<String>
) -> InterestProfile {
    InterestProfile(
        history: [], feedback: [], saved: [], searches: [],
        subscribedIDs: subscribedIDs, relatedSeeds: [], explorationSeeds: [],
        channelAffinity: Dictionary(uniqueKeysWithValues: uploaders.map { ($0, 2.0) }))
}
