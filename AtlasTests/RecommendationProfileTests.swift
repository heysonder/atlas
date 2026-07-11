import Foundation
import Testing

@testable import Atlas

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
@Test func watchWeightIsTotalAndBoundedForLegacyInvalidNumbers() {
    let invalidPairs: [(Double, Double)] = [
        (.nan, 100), (.infinity, 100), (10, .infinity),
        (-1, 100), (10, -1), (-1, 1e-300), (1e300, 1e-300),
    ]
    for (position, duration) in invalidPairs {
        let weight = RecommendationEngine.watchWeight(position: position, duration: duration)
        #expect(weight == 1)
        #expect(weight.isFinite)
    }
}

@MainActor
@Test func profileSignatureDoesNotTrapOnUnrepresentableNumbers() {
    let history = [
        HistorySignal(
            videoID: "legacy", title: "Legacy", watchedAt: .distantFuture,
            positionSeconds: 1e300, durationSeconds: -1)
    ]

    let first = RecommendationEngine.profileSignature(
        history: history, feedback: [], saved: [], searches: [], subscribedIDs: [])
    let second = RecommendationEngine.profileSignature(
        history: history, feedback: [], saved: [], searches: [], subscribedIDs: [])
    let canonical = RecommendationEngine.canonicalProfileSignature(
        history: history, feedback: [], saved: [], searches: [], subscribedIDs: [])

    #expect(first == second)
    #expect(first.utf8.count == 64)
    #expect(canonical.contains("invalid:-1"))
}

@MainActor
@Test func searchSignalKeepsInvalidDatesAndExtremeCountsFinite() {
    let invalidDate = Date(timeIntervalSinceReferenceDate: .infinity)
    let signal = SearchSignal(
        query: "legacy", count: Int.max, lastSearchedAt: invalidDate, now: .now)

    #expect(signal.weight.isFinite)
    #expect((1...4).contains(signal.copyCount))
}

@MainActor
@Test func profileSnapshotIgnoresInvalidAffinityDeterministically() {
    let snapshot = RecommendationProfileSnapshot(
        signature: "sig", relatedSeedIDs: [], explorationSeedIDs: [],
        candidateSearchQueries: [], savedSeedIDs: [],
        channelAffinityKeys: ["Valid", "", "Negative", "Infinite", "Valid"],
        channelAffinityValues: [2, 9, -1, .infinity, 5])

    #expect(snapshot.channelAffinity == ["Valid": 5])
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

private func historyEntry(_ id: String, uploader: String, watchedAt: TimeInterval) -> HistoryEntry {
    HistoryEntry(
        videoID: id, title: "Video \(id)", uploader: uploader,
        watchedAt: Date(timeIntervalSince1970: watchedAt),
        positionSeconds: 90, durationSeconds: 100)
}
