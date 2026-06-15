import Foundation
import Testing
@testable import Atlas

@MainActor
@Test func topicCloudWeightsLocalActivity() {
    let now = Date(timeIntervalSince1970: 10_000)
    let history = [
        HistoryEntry(videoID: "h1", title: "SwiftUI architecture deep dive",
                     uploader: "Builder", watchedAt: now,
                     positionSeconds: 95, durationSeconds: 100),
    ]
    let saved = [
        PlaylistVideo(videoID: "s1", title: "iOS app architecture",
                      uploader: "Builder", addedAt: now),
    ]
    let searches = [
        SearchEntry(query: "swiftui architecture", lastSearchedAt: now, count: 4),
    ]
    let cached = [
        VideoSignalCacheEntry(videoID: "h1", category: "Science & technology",
                              tags: ["swiftui", "ios", "architecture"],
                              updatedAt: now),
    ]

    let cloud = TopicCloudBuilder.make(history: history, feedback: [], saved: saved,
                                       searches: searches, cachedSignals: cached, now: now)
    let terms = Set(cloud.positive.map(\.term))

    #expect(terms.contains("swiftui"))
    #expect(terms.contains("architecture"))
    #expect(terms.contains("ios"))
    #expect(cloud.negative.isEmpty)
}

@MainActor
@Test func topicCloudSeparatesSuggestLessTerms() {
    let feedback = [
        Feedback(videoID: "n1", signal: -1, title: "Election politics news breakdown",
                 category: "News & politics", tags: ["campaign"]),
    ]

    let cloud = TopicCloudBuilder.make(history: [], feedback: feedback, saved: [],
                                       searches: [], cachedSignals: [])
    let negativeTerms = Set(cloud.negative.map(\.term))
    let positiveTerms = Set(cloud.positive.map(\.term))

    #expect(negativeTerms.contains("politics"))
    #expect(negativeTerms.contains("election"))
    #expect(!positiveTerms.contains("politics"))
}
