import Foundation
import SwiftData

/// Training log for the ranker (local cache, never backed up): one row per
/// For You first-screen impression, holding the features the semantic ranker
/// scored the video with and what happened (tapped or ignored; the watched
/// fraction can be joined from history by videoID at fit time). Once a few
/// weeks accumulate, these rows are what a learned re-weighting of the ranking
/// knobs will be fit on.
@Model
final class RecommendationOutcomeEntry {
    var videoID: String
    var shownAt: Date
    /// 0-based rank position on the first screen — needed to correct for
    /// position bias when fitting (top slots get taps just for being on top).
    var position: Int
    var tapped: Bool
    var tappedAt: Date?

    var topicSimilarity: Double
    var longTermSimilarity: Double
    var categoryFit: Double
    var corroboration: Int
    var freshness: Double
    var channelAffinity: Double
    var isSubscribed: Bool
    var dislikeSimilarity: Double
    var priorImpressions: Int
    var fromRelated: Bool
    var fromSearch: Bool
    var fromSaved: Bool
    var fromSubscription: Bool
    var fromExploration: Bool
    var usedContextualEmbedding: Bool

    init(
        videoID: String, shownAt: Date, position: Int,
        features: RecommendationOutcomeFeatures
    ) {
        self.videoID = videoID
        self.shownAt = shownAt
        self.position = position
        self.tapped = false
        self.tappedAt = nil
        self.topicSimilarity = features.topicSimilarity
        self.longTermSimilarity = features.longTermSimilarity
        self.categoryFit = features.categoryFit
        self.corroboration = features.corroboration
        self.freshness = features.freshness
        self.channelAffinity = features.channelAffinity
        self.isSubscribed = features.isSubscribed
        self.dislikeSimilarity = features.dislikeSimilarity
        self.priorImpressions = features.priorImpressions
        self.fromRelated = features.fromRelated
        self.fromSearch = features.fromSearch
        self.fromSaved = features.fromSaved
        self.fromSubscription = features.fromSubscription
        self.fromExploration = features.fromExploration
        self.usedContextualEmbedding = features.usedContextualEmbedding
    }
}

@MainActor
enum RecommendationOutcomeStore {
    struct Impression {
        let videoID: String
        let position: Int
        let features: RecommendationOutcomeFeatures
    }

    /// Keep well over a year of heavy usage; prune the oldest beyond it.
    private static let maximumRows = 20_000
    private static let maximumAge: TimeInterval = 180 * 86_400

    static func record(_ impressions: [Impression], in context: ModelContext?, now: Date = .now) {
        guard let context, !impressions.isEmpty else { return }
        for impression in impressions {
            guard !impression.videoID.isEmpty,
                impression.videoID.utf8.count <= PersistedMetadataPolicy.maximumIdentifierBytes
            else { continue }
            context.insert(
                RecommendationOutcomeEntry(
                    videoID: impression.videoID, shownAt: now,
                    position: impression.position, features: impression.features))
        }
        prune(in: context, now: now)
    }

    /// Mark the most recent impression of this video as tapped.
    static func recordTap(_ videoID: String, in context: ModelContext?, now: Date = .now) {
        guard let context else { return }
        var descriptor = FetchDescriptor<RecommendationOutcomeEntry>(
            predicate: #Predicate { $0.videoID == videoID },
            sortBy: [SortDescriptor(\.shownAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let entry = try? context.fetch(descriptor).first else { return }
        entry.tapped = true
        entry.tappedAt = now
    }

    private static func prune(in context: ModelContext, now: Date) {
        let staleCutoff = now.addingTimeInterval(-maximumAge)
        let staleDescriptor = FetchDescriptor<RecommendationOutcomeEntry>(
            predicate: #Predicate { $0.shownAt < staleCutoff })
        for entry in (try? context.fetch(staleDescriptor)) ?? [] {
            context.delete(entry)
        }
        guard let total = try? context.fetchCount(FetchDescriptor<RecommendationOutcomeEntry>()),
            total > maximumRows
        else { return }
        var oldest = FetchDescriptor<RecommendationOutcomeEntry>(
            sortBy: [SortDescriptor(\.shownAt, order: .forward)])
        oldest.fetchLimit = total - maximumRows
        for entry in (try? context.fetch(oldest)) ?? [] {
            context.delete(entry)
        }
    }
}
