import Foundation
import SwiftData

/// Local ranking cache (like `VideoSignalCacheEntry`, not user metadata — never
/// backed up): how many times a video has appeared on the For You first screen
/// without being opened. Ranking turns the count into a compounding score
/// haircut so the feed doesn't greet every open with the same untapped
/// recommendations. Watching a video removes it from the feed entirely (and
/// its row here ages out), so there is no explicit reset path.
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
    /// Counts stop mattering past the penalty cap; not growing them keeps the
    /// signature of the row stable for videos that linger.
    private static let maximumCount = 12
    /// Rows this stale are forgotten — an old impression shouldn't keep
    /// punishing a video that fell out of the pool months ago.
    private static let maximumAge: TimeInterval = 45 * 86_400
    /// Hard cap on the table so it can't grow without bound.
    private static let maximumRows = 4_000

    /// A tap wipes the video's penalty: it was a good recommendation the user
    /// acted on, not a stale one. (A finished watch removes it from the feed
    /// anyway; this covers taps that end in a partial watch.)
    static func recordTap(_ videoID: String, in context: ModelContext?) {
        guard let context else { return }
        let descriptor = FetchDescriptor<FeedImpressionEntry>(
            predicate: #Predicate { $0.videoID == videoID })
        for entry in (try? context.fetch(descriptor)) ?? [] {
            context.delete(entry)
        }
    }

    /// Every persisted count, for the ranking pass.
    static func counts(in context: ModelContext?) -> [String: Int] {
        guard let context else { return [:] }
        let entries = (try? context.fetch(FetchDescriptor<FeedImpressionEntry>())) ?? []
        let cutoff = Date().addingTimeInterval(-maximumAge)
        return entries.reduce(into: [:]) { out, entry in
            guard entry.lastShownAt >= cutoff else { return }
            out[entry.videoID] = entry.count
        }
    }

    /// Record one first-screen appearance for each id (callers dedupe within a
    /// load, so a coarse render followed by the refine re-render doesn't count
    /// twice). Prunes expired rows and enforces the table cap in the same pass.
    static func record(_ videoIDs: [String], in context: ModelContext?, now: Date = .now) {
        guard let context, !videoIDs.isEmpty else { return }
        var seen = Set<String>()
        let ids = videoIDs.filter {
            !$0.isEmpty && $0.utf8.count <= PersistedMetadataPolicy.maximumIdentifierBytes
                && seen.insert($0).inserted
        }
        guard !ids.isEmpty else { return }

        // In-context fetch-and-delete, not a store-level batch delete: the
        // table is small (capped below), and a batch delete misses rows still
        // pending in the context.
        let staleCutoff = now.addingTimeInterval(-maximumAge)
        let staleDescriptor = FetchDescriptor<FeedImpressionEntry>(
            predicate: #Predicate { $0.lastShownAt < staleCutoff })
        for entry in (try? context.fetch(staleDescriptor)) ?? [] {
            context.delete(entry)
        }

        let descriptor = FetchDescriptor<FeedImpressionEntry>(
            predicate: #Predicate { ids.contains($0.videoID) })
        let existing = Dictionary(
            ((try? context.fetch(descriptor)) ?? []).map { ($0.videoID, $0) },
            uniquingKeysWith: { first, _ in first })
        for id in ids {
            if let entry = existing[id] {
                entry.count = min(entry.count + 1, maximumCount)
                entry.lastShownAt = now
            } else {
                context.insert(FeedImpressionEntry(videoID: id, lastShownAt: now))
            }
        }

        if let total = try? context.fetchCount(FetchDescriptor<FeedImpressionEntry>()),
            total > maximumRows
        {
            var oldest = FetchDescriptor<FeedImpressionEntry>(
                sortBy: [SortDescriptor(\.lastShownAt, order: .forward)])
            oldest.fetchLimit = total - maximumRows
            for entry in (try? context.fetch(oldest)) ?? [] {
                context.delete(entry)
            }
        }
    }
}
