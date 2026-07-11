import Foundation
import PipedKit

nonisolated enum RecommendationWorkBudget {
    static let maximumFieldBytes = 4 * 1_024
    static let maximumTagBytes = 256
    static let maximumTags = 64
    static let maximumTokensPerDocument = 96
    static let maximumRankingItems = 120
    static let maximumSubscriptionRequests = 24
    static let maximumChannelIDBytes = 256
    static let maximumCursorBytes = 8 * 1_024

    static func field(_ value: String, maximumBytes: Int = maximumFieldBytes) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var end = value.startIndex
        var bytes = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let width = value[end..<next].utf8.count
            guard bytes + width <= maximumBytes else { break }
            bytes += width
            end = next
        }
        return String(value[..<end])
    }

    static func optionalField(_ value: String?) -> String? {
        value.map { field($0) }
    }

    static func tags(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.prefix(maximumTags * 2).compactMap { raw in
            let value = field(raw, maximumBytes: maximumTagBytes)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return value
        }.prefix(maximumTags).map { $0 }
    }

    static func tokens(_ text: String, excluding stop: Set<String>) -> [String] {
        field(text).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .lazy
            .filter { $0.count > 2 && !stop.contains($0) }
            .prefix(maximumTokensPerDocument)
            .map { $0 }
    }
}

/// Per-video signals fetched from `/streams` to sharpen ranking: YouTube's own
/// category label ("News & politics", "Science & technology") and the creator's
/// tags — clean topical keywords with none of a description's ad/affiliate copy.
nonisolated struct VideoSignals: Sendable {
    let category: String?
    let tags: [String]
    let topicKey: String?

    nonisolated init(category: String?, tags: [String], topicKey: String? = nil) {
        self.category = RecommendationWorkBudget.optionalField(category)
        self.tags = RecommendationWorkBudget.tags(tags)
        self.topicKey = RecommendationWorkBudget.optionalField(topicKey)
    }
}

/// A value-type snapshot of a `Feedback` row for the ranking functions: a
/// thumbs-up (+1) or thumbs-down (−1) plus the video's signature.
nonisolated struct FeedbackSignal: Sendable {
    let signal: Int
    let title: String
    let uploader: String?
    let category: String?
    let tags: [String]

    init(signal: Int, title: String, uploader: String?, category: String?, tags: [String]) {
        self.signal = min(max(signal, -1), 1)
        self.title = RecommendationWorkBudget.field(title)
        self.uploader = RecommendationWorkBudget.optionalField(uploader)
        self.category = RecommendationWorkBudget.optionalField(category)
        self.tags = RecommendationWorkBudget.tags(tags)
    }
}

/// Value snapshot of a watched video. Ranking can move this off the main actor
/// without carrying SwiftData model instances across actors.
nonisolated struct HistorySignal: Sendable, Hashable {
    let videoID: String
    let title: String
    let uploader: String?
    let thumbnailURL: String?
    let watchedAt: Date
    let positionSeconds: Double
    let durationSeconds: Double

    @MainActor
    init(_ entry: HistoryEntry) {
        self.videoID = RecommendationWorkBudget.field(entry.videoID)
        self.title = RecommendationWorkBudget.field(entry.title)
        self.uploader = RecommendationWorkBudget.optionalField(entry.uploader)
        self.thumbnailURL = RecommendationWorkBudget.optionalField(entry.thumbnailURL)
        self.watchedAt = entry.watchedAt
        self.positionSeconds = entry.positionSeconds
        self.durationSeconds = entry.durationSeconds
    }

    init(
        videoID: String, title: String, uploader: String? = nil,
        thumbnailURL: String? = nil, watchedAt: Date,
        positionSeconds: Double, durationSeconds: Double
    ) {
        self.videoID = RecommendationWorkBudget.field(videoID)
        self.title = RecommendationWorkBudget.field(title)
        self.uploader = RecommendationWorkBudget.optionalField(uploader)
        self.thumbnailURL = RecommendationWorkBudget.optionalField(thumbnailURL)
        self.watchedAt = watchedAt
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
    }
}

/// Value snapshot of a saved playlist video used by ranking/profile math.
nonisolated struct SavedVideoSignal: Sendable, Hashable {
    let videoID: String
    let title: String
    let uploader: String?
    let addedAt: Date

    @MainActor
    init(_ video: PlaylistVideo) {
        self.videoID = RecommendationWorkBudget.field(video.videoID)
        self.title = RecommendationWorkBudget.field(video.title)
        self.uploader = RecommendationWorkBudget.optionalField(video.uploader)
        self.addedAt = video.addedAt
    }

    init(videoID: String, title: String, uploader: String? = nil, addedAt: Date) {
        self.videoID = RecommendationWorkBudget.field(videoID)
        self.title = RecommendationWorkBudget.field(title)
        self.uploader = RecommendationWorkBudget.optionalField(uploader)
        self.addedAt = addedAt
    }
}

/// A persisted search query collapsed into a ranking signal. Repeated searches
/// matter, but the weight decays as the query gets stale.
nonisolated struct SearchSignal: Sendable {
    let query: String
    let count: Int
    let lastSearchedAt: Date
    let weight: Double

    init(query: String, count: Int, lastSearchedAt: Date, now: Date = .now) {
        self.query = RecommendationWorkBudget.field(query)
        self.count = max(1, count)
        self.lastSearchedAt = lastSearchedAt

        let elapsed = now.timeIntervalSince(lastSearchedAt)
        let ageDays = elapsed.isFinite ? max(0, elapsed / 86_400) : .infinity
        let recency = ageDays.isFinite ? max(0.25, 1 - ageDays / 30) : 0.25
        let frequency = min(4, 1 + log2(Double(max(1, count))))
        let weight = frequency * recency
        self.weight = weight.isFinite ? weight : 1
    }

    var copyCount: Int {
        guard weight.isFinite else { return 1 }
        return max(1, min(4, Int(weight.rounded())))
    }
}

/// Local, on-device taste profile assembled from the persisted user signals.
nonisolated struct InterestProfile: Sendable {
    let history: [HistorySignal]
    let feedback: [FeedbackSignal]
    let saved: [SavedVideoSignal]
    let searches: [SearchSignal]
    let subscribedIDs: Set<String>
    let relatedSeeds: [HistorySignal]
    let explorationSeeds: [HistorySignal]
    let channelAffinity: [String: Double]
    private let candidateSearchQueriesOverride: [String]?
    private let savedSeedIDsOverride: [String]?

    var candidateSearchQueries: [String] {
        if let candidateSearchQueriesOverride { return candidateSearchQueriesOverride }
        return
            searches
            .sorted {
                if $0.weight == $1.weight { return $0.lastSearchedAt > $1.lastSearchedAt }
                return $0.weight > $1.weight
            }
            .prefix(4)
            .map(\.query)
    }

    var savedSeedIDs: [String] {
        if let savedSeedIDsOverride { return savedSeedIDsOverride }
        return saved.prefix(8).map(\.videoID)
    }

    init(
        history: [HistorySignal], feedback: [FeedbackSignal], saved: [SavedVideoSignal],
        searches: [SearchSignal], subscribedIDs: Set<String>,
        relatedSeeds: [HistorySignal], explorationSeeds: [HistorySignal],
        channelAffinity: [String: Double],
        candidateSearchQueriesOverride: [String]? = nil,
        savedSeedIDsOverride: [String]? = nil
    ) {
        self.history = Array(history.prefix(200))
        self.feedback = Array(feedback.prefix(200))
        self.saved = Array(saved.prefix(120))
        self.searches = Array(searches.prefix(60))
        self.subscribedIDs = Set(
            subscribedIDs.lazy
                .filter { !$0.isEmpty && $0.utf8.count <= RecommendationWorkBudget.maximumChannelIDBytes }
                .prefix(200))
        self.relatedSeeds = Array(relatedSeeds.prefix(12))
        self.explorationSeeds = Array(explorationSeeds.prefix(6))
        self.channelAffinity = channelAffinity
        self.candidateSearchQueriesOverride = candidateSearchQueriesOverride.map {
            $0.prefix(8).map { RecommendationWorkBudget.field($0) }
        }
        self.savedSeedIDsOverride = savedSeedIDsOverride.map {
            $0.prefix(16).map { RecommendationWorkBudget.field($0) }
        }
    }
}

nonisolated enum CandidateSource: Hashable, Sendable {
    case related
    case search
    case saved
    case subscription
    case exploration
}

nonisolated struct CandidateSourceBucket: Sendable {
    let source: CandidateSource
    let items: [StreamItem]
    let frequency: [String: Int]
    let limit: Int

    init(
        source: CandidateSource, items: [StreamItem],
        frequency: [String: Int] = [:], limit: Int
    ) {
        self.source = source
        self.items = items
        self.frequency = frequency
        self.limit = limit
    }
}

nonisolated struct CandidatePool: Sendable {
    let items: [StreamItem]
    let frequency: [String: Int]
    let sourcesByID: [String: Set<CandidateSource>]
}
