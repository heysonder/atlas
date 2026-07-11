import Foundation
import SwiftData
import Testing

@testable import Atlas

@MainActor
@Test func recommendationProfilePersistsDigestAndReusesOnlyMatchingSnapshot() throws {
    let container = try makeTestContainer()
    let context = container.mainContext
    var history = (0..<12).map { index in
        HistoryEntry(
            videoID: "video-\(index)",
            title: "Video \(index)",
            uploader: "Typical Creator Name",
            watchedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            positionSeconds: 120,
            durationSeconds: 600)
    }
    history.forEach(context.insert)

    let canonical = RecommendationEngine.canonicalProfileSignature(
        history: history.map(HistorySignal.init),
        feedback: [],
        saved: [],
        searches: [],
        subscribedIDs: [])
    #expect(canonical.utf8.count > PersistedMetadataPolicy.maximumIdentifierBytes)

    let first = RecommendationProfileStore.loadOrBuild(
        in: context,
        history: history,
        feedback: [],
        saved: [],
        searches: [],
        subscribedIDs: [])
    let snapshot = try #require(
        context.fetch(FetchDescriptor<RecommendationProfileSnapshot>()).first)
    let firstDigest = snapshot.signature
    #expect(firstDigest.utf8.count == 64)
    #expect(first.candidateSearchQueries.isEmpty)

    snapshot.candidateSearchQueries = ["cached-query"]
    let reused = RecommendationProfileStore.loadOrBuild(
        in: context,
        history: history,
        feedback: [],
        saved: [],
        searches: [],
        subscribedIDs: [])
    #expect(reused.candidateSearchQueries == ["cached-query"])
    #expect(snapshot.signature == firstDigest)

    let changed = HistoryEntry(
        videoID: "changed-video",
        title: "Changed",
        uploader: "Another Creator",
        watchedAt: Date(timeIntervalSince1970: 1_800_000_000),
        positionSeconds: 30,
        durationSeconds: 90)
    context.insert(changed)
    history.append(changed)
    let rebuilt = RecommendationProfileStore.loadOrBuild(
        in: context,
        history: history,
        feedback: [],
        saved: [],
        searches: [],
        subscribedIDs: [])
    #expect(snapshot.signature != firstDigest)
    #expect(rebuilt.candidateSearchQueries.isEmpty)
    #expect(snapshot.candidateSearchQueries.isEmpty)
}
