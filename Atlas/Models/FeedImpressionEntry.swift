import Foundation
import SwiftData

/// Derived repetition penalties rebuilt from retained local/synced activity.
/// This aggregate is not itself synchronized; legacy values migrate once to
/// separately identified baselines before any events are counted.
@Model
final class FeedImpressionEntry {
    @Attribute(.unique) var videoID: String
    var count: Int
    var lastShownAt: Date

    init(videoID: String, count: Int = 1, lastShownAt: Date = .now) {
        self.videoID = videoID
        self.count = count
        self.lastShownAt = lastShownAt
    }
}

@MainActor
enum FeedImpressionStore {
    static let maximumCount = 12
    static let maximumAge: TimeInterval = 45 * 86_400
    static let maximumRows = 4_000

    static func recordTap(_ videoID: String, in context: ModelContext?) {
        RecommendationOutcomeStore.recordTap(videoID, in: context)
    }

    static func counts(in context: ModelContext?) -> [String: Int] {
        guard let context else { return [:] }
        let entries = (try? context.fetch(FetchDescriptor<FeedImpressionEntry>())) ?? []
        let cutoff = Date().addingTimeInterval(-maximumAge)
        return entries.reduce(into: [:]) { result, entry in
            guard entry.lastShownAt >= cutoff else { return }
            result[entry.videoID] = min(max(0, entry.count), maximumCount)
        }
    }

    /// Featureless impressions still have stable event identity; schema version
    /// zero marks them as unavailable to a future training pass.
    static func record(_ videoIDs: [String], in context: ModelContext?, now: Date = .now) {
        RecommendationOutcomeStore.record(
            videoIDs.enumerated().map {
                .init(
                    videoID: $0.element, position: $0.offset,
                    features: RecommendationSyncFeatures.empty.features, featureSchemaVersion: 0)
            }, in: context, now: now)
    }

    /// Deterministic local projection. Taps reset the video penalty everywhere,
    /// including earlier independent impressions received from another device.
    ///
    /// Passing `videoIDs` recomputes only those videos' rows from their own events and
    /// baselines (a render or a tap); the global row bound is enforced by the full pass
    /// that runs after every incoming sync batch and after pruning.
    static func rebuild(in context: ModelContext, now: Date = .now, videoIDs: Set<String>? = nil) throws {
        if let videoIDs {
            try rebuildSubset(videoIDs, in: context, now: now)
            return
        }
        let events = try context.fetch(FetchDescriptor<RecommendationOutcomeEntry>())
        let baselines = try context.fetch(FetchDescriptor<FeedImpressionBaseline>())
        let values = projectedCounts(events: events, baselines: baselines, now: now)
        let retainedIDs = Set(
            values.keys.sorted {
                let lhs = values[$0]!.shownAt
                let rhs = values[$1]!.shownAt
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }.prefix(maximumRows))
        let existing = try context.fetch(FetchDescriptor<FeedImpressionEntry>())
        var remaining = retainedIDs
        for row in existing {
            guard retainedIDs.contains(row.videoID), let value = values[row.videoID] else {
                context.delete(row)
                continue
            }
            remaining.remove(row.videoID)
            if row.count != value.count { row.count = value.count }
            if row.lastShownAt != value.shownAt { row.lastShownAt = value.shownAt }
        }
        for id in remaining {
            guard let value = values[id] else { continue }
            context.insert(FeedImpressionEntry(videoID: id, count: value.count, lastShownAt: value.shownAt))
        }
    }

    private static func rebuildSubset(_ videoIDs: Set<String>, in context: ModelContext, now: Date) throws {
        // Expired rows are dropped outright on every pass, exactly as the full rebuild does.
        let cutoff = now.addingTimeInterval(-maximumAge)
        for stale in try context.fetch(
            FetchDescriptor<FeedImpressionEntry>(
                predicate: #Predicate { $0.lastShownAt < cutoff }))
        {
            context.delete(stale)
        }
        guard !videoIDs.isEmpty else { return }
        let ids = Array(videoIDs)
        let events = try context.fetch(
            FetchDescriptor<RecommendationOutcomeEntry>(
                predicate: #Predicate { ids.contains($0.videoID) }))
        let baselines = try context.fetch(
            FetchDescriptor<FeedImpressionBaseline>(
                predicate: #Predicate { ids.contains($0.videoID) }))
        let values = projectedCounts(events: events, baselines: baselines, now: now)
        let existing = try context.fetch(
            FetchDescriptor<FeedImpressionEntry>(
                predicate: #Predicate { ids.contains($0.videoID) }))
        var remaining = Set(values.keys)
        for row in existing {
            guard let value = values[row.videoID] else {
                context.delete(row)
                continue
            }
            remaining.remove(row.videoID)
            if row.count != value.count { row.count = value.count }
            if row.lastShownAt != value.shownAt { row.lastShownAt = value.shownAt }
        }
        for id in remaining {
            guard let value = values[id] else { continue }
            context.insert(FeedImpressionEntry(videoID: id, count: value.count, lastShownAt: value.shownAt))
        }
    }

    /// Shared projection rule for the full and subset rebuilds.
    private static func projectedCounts(
        events: [RecommendationOutcomeEntry], baselines: [FeedImpressionBaseline], now: Date
    ) -> [String: (count: Int, shownAt: Date)] {
        let cutoff = now.addingTimeInterval(-maximumAge)
        var latestTap: [String: Date] = [:]
        for event in events {
            guard let tappedAt = event.tappedAt, event.tapped else { continue }
            latestTap[event.videoID] = max(latestTap[event.videoID] ?? tappedAt, tappedAt)
        }
        for reset in baselines where reset.count == 0 {
            latestTap[reset.videoID] = max(latestTap[reset.videoID] ?? reset.lastShownAt, reset.lastShownAt)
        }
        var values: [String: (count: Int, shownAt: Date)] = [:]
        func add(videoID: String, count: Int, shownAt: Date) {
            guard shownAt >= cutoff, shownAt <= now.addingTimeInterval(86_400),
                latestTap[videoID].map({ shownAt > $0 }) ?? true
            else { return }
            let previous = values[videoID]
            values[videoID] = (
                min((previous?.count ?? 0) + count, maximumCount),
                max(previous?.shownAt ?? shownAt, shownAt)
            )
        }
        for baseline in baselines where baseline.count > 0 {
            add(videoID: baseline.videoID, count: baseline.count, shownAt: baseline.lastShownAt)
        }
        for event in events where event.contributesToImpressions {
            add(videoID: event.videoID, count: 1, shownAt: event.shownAt)
        }
        return values
    }
}
