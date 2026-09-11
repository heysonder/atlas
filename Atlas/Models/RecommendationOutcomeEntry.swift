import Foundation
import SwiftData

/// Durable, optionally synced training log for the ranker: one row per
/// For You first-screen impression, holding the features the semantic ranker
/// scored the video with and what happened (tapped or ignored; the watched
/// fraction can be joined from history by videoID at fit time). Once a few
/// weeks accumulate, these rows are what a learned re-weighting of the ranking
/// knobs will be fit on.
@Model
final class RecommendationOutcomeEntry {
    /// Optional storage permits a safe additive migration. Every legacy row is
    /// assigned a distinct ID by RecommendationSyncBridge before it is sent.
    var eventID: UUID? = nil
    var originID: String = "legacy"
    var featureSchemaVersion: Int = 1
    var contributesToImpressions: Bool = false
    /// Future feature layouts remain byte-preserved until this version can use
    /// them. The transport still validates all common event metadata and bounds.
    var unrecognizedSyncPayload: Data? = nil
    /// Unsupported feature versions are retained and synced, but never fitted.
    var isEligibleForTraining: Bool { featureSchemaVersion == 1 }

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
        features: RecommendationOutcomeFeatures,
        eventID: UUID = UUID(), originID: String = "local",
        featureSchemaVersion: Int = 1, contributesToImpressions: Bool = true
    ) {
        self.eventID = eventID
        self.originID = originID
        self.featureSchemaVersion = featureSchemaVersion
        self.contributesToImpressions = contributesToImpressions
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
        var featureSchemaVersion: Int = 1
    }

    // Compatibility entry points remember only events recorded in THIS context.
    // Remote rows can never change which displayed impression receives a tap.
    private static var displayedEvents: [ObjectIdentifier: [String: UUID]] = [:]

    /// Records one durable event for both training and repetition counting.
    /// Returned IDs belong to this render, so later taps target the exact event.
    @discardableResult
    static func record(
        _ impressions: [Impression], in context: ModelContext?, now: Date = .now
    ) -> [String: UUID] {
        guard let context, !impressions.isEmpty else { return [:] }
        var recorded: [String: UUID] = [:]
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                let state = try RecommendationSyncBridge.prepare(in: context)
                for impression in impressions {
                    guard recorded[impression.videoID] == nil,
                        !impression.videoID.isEmpty,
                        impression.videoID.utf8.count <= PersistedMetadataPolicy.maximumIdentifierBytes,
                        (0..<20_000).contains(impression.position),
                        RecommendationSyncFeatures(impression.features).isValid
                    else { continue }
                    let id = UUID()
                    context.insert(
                        RecommendationOutcomeEntry(
                            videoID: impression.videoID, shownAt: now,
                            position: impression.position, features: impression.features,
                            eventID: id, originID: state.originID,
                            featureSchemaVersion: impression.featureSchemaVersion))
                    recorded[impression.videoID] = id
                }
                try RecommendationSyncBridge.prune(in: context, now: now)
                try FeedImpressionStore.rebuild(in: context, now: now, videoIDs: Set(recorded.keys))
                for id in recorded.values {
                    try LibrarySyncJournal.capture(kind: .activity, entityID: id.uuidString.lowercased(), in: context)
                }
                try LibrarySyncJournal.capture(
                    kind: .activity, entityID: RecommendationSyncBridge.retentionEntityID, in: context)
            }
            displayedEvents[ObjectIdentifier(context), default: [:]].merge(recorded) { _, new in new }
            return recorded
        } catch {
            return [:]
        }
    }

    static func recordTap(eventID: UUID, in context: ModelContext?, now: Date = .now) {
        guard let context else { return }
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                let optionalID: UUID? = eventID
                let descriptor = FetchDescriptor<RecommendationOutcomeEntry>(
                    predicate: #Predicate { $0.eventID == optionalID })
                guard let entry = try context.fetch(descriptor).first else { return }
                guard now >= entry.shownAt else { return }
                entry.tapped = true
                entry.tappedAt = max(entry.tappedAt ?? now, now)
                try RecommendationSyncBridge.recordTapReset(for: entry, in: context)
                try LibrarySyncJournal.capture(
                    kind: .impressionBaseline,
                    entityID: eventID.uuidString.lowercased(), in: context)
                try FeedImpressionStore.rebuild(in: context, now: now, videoIDs: [entry.videoID])
                try LibrarySyncJournal.capture(kind: .activity, entityID: eventID.uuidString.lowercased(), in: context)
            }
        } catch {
            // The journal rolls back both activity and pending synchronization.
        }
    }

    /// Existing callers without a render handle can only tap a locally recorded
    /// event in their own context; never search for the newest synced video row.
    static func recordTap(_ videoID: String, in context: ModelContext?, now: Date = .now) {
        guard let context,
            let id = displayedEvents[ObjectIdentifier(context)]?[videoID]
        else { return }
        recordTap(eventID: id, in: context, now: now)
    }

    /// A feed tap. Rows below the first-screen impression window have no event
    /// from this render; the tap still has to clear the video's staleness penalty.
    /// It goes to the newest event this device logged for the video, or, without
    /// one, to a fresh baseline reset. Events from other devices are never tapped.
    static func recordTap(videoID: String, eventID: UUID?, in context: ModelContext?, now: Date = .now) {
        if let eventID {
            recordTap(eventID: eventID, in: context, now: now)
            return
        }
        guard let context, !videoID.isEmpty,
            videoID.utf8.count <= PersistedMetadataPolicy.maximumIdentifierBytes
        else { return }
        do {
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                let origin = try RecommendationSyncBridge.prepare(in: context).originID
                var descriptor = FetchDescriptor<RecommendationOutcomeEntry>(
                    predicate: #Predicate { $0.videoID == videoID && $0.originID == origin && $0.eventID != nil },
                    sortBy: [SortDescriptor(\.shownAt, order: .reverse)])
                descriptor.fetchLimit = 1
                if let entry = try context.fetch(descriptor).first, let id = entry.eventID, now >= entry.shownAt {
                    entry.tapped = true
                    entry.tappedAt = max(entry.tappedAt ?? now, now)
                    try RecommendationSyncBridge.recordTapReset(for: entry, in: context)
                    try LibrarySyncJournal.capture(
                        kind: .impressionBaseline, entityID: id.uuidString.lowercased(), in: context)
                    try LibrarySyncJournal.capture(kind: .activity, entityID: id.uuidString.lowercased(), in: context)
                } else {
                    let reset = FeedImpressionBaseline(videoID: videoID, count: 0, lastShownAt: now)
                    context.insert(reset)
                    try LibrarySyncJournal.capture(
                        kind: .impressionBaseline, entityID: reset.id.uuidString.lowercased(), in: context)
                }
                try FeedImpressionStore.rebuild(in: context, now: now, videoIDs: [videoID])
            }
        } catch {
            // The journal rolls back both activity and pending synchronization.
        }
    }
}
