import Foundation
import PipedKit
import Testing

@testable import Atlas

@MainActor
@Test func candidateMergeRespectsSourceQuotasAndTracksSources() throws {
    let subscription = try [streamItem("s1"), streamItem("s2"), streamItem("shared")]
    let related = try [streamItem("r1"), streamItem("shared"), streamItem("r2")]

    let pool = RecommendationEngine.mergeCandidateSources(
        [
            CandidateSourceBucket(source: .subscription, items: subscription, limit: 2),
            CandidateSourceBucket(
                source: .related, items: related,
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

    let pool = RecommendationEngine.mergeCandidateSources(
        [
            CandidateSourceBucket(
                source: .related, items: related,
                frequency: ["shared": 4], limit: 1),
            CandidateSourceBucket(
                source: .exploration, items: exploration,
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

    let pool = RecommendationEngine.mergeCandidateSources(
        [
            CandidateSourceBucket(
                source: .related, items: sharedA,
                frequency: ["shared": 2], limit: 2),
            CandidateSourceBucket(
                source: .exploration, items: sharedB,
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

private func streamItem(
    _ id: String, uploader: String = "Uploader",
    channelID: String = "UC\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
) throws -> StreamItem {
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
