import Foundation
import PipedKit
import SwiftData

extension RecommendationEngine {
    private static var signalCacheTTL: TimeInterval { 30 * 86_400 }

    // MARK: Per-video enrichment (YouTube category + tags)

    /// Re-rank a shortlist using YouTube's own category + tags, fetched per video.
    /// This is what hard-buries News & politics for an all-tech watcher and folds
    /// clean creator tags into the topic match. Runs after the instant on-device
    /// pass so the user sees results immediately, then an upgrade once it returns.
    func refineWithSignals(
        _ shortlist: [StreamItem], profile: InterestProfile,
        sourcesByID: [String: Set<CandidateSource>] = [:]
    ) async -> [StreamItem] {
        let signals = await fetchSignals(shortlist)
        // A mode switch / new load cancels the surrounding task — skip the
        // (pointless) re-rank; the caller discards stale results anyway.
        guard !Task.isCancelled else { return shortlist }
        let ranked = await Self.rankByTopicInBackground(
            shortlist, profile: profile, sourcesByID: sourcesByID, enrichment: signals)
        return Self.diversify(ranked, enrichment: signals)
    }

    /// Fetch `/streams` for the shortlist with bounded concurrency. Cached and
    /// de-duplicated results are supplied by `resolveStream`, so repeat refreshes
    /// are cheap.
    private func fetchSignals(_ items: [StreamItem]) async -> [String: VideoSignals] {
        let items = Array(items.prefix(RecommendationWorkBudget.maximumRankingItems))
        var seenIDs = Set<String>()
        let ids = items.compactMap(\.videoID).filter { seenIDs.insert($0).inserted }
        guard !ids.isEmpty else { return [:] }
        var itemByID: [String: StreamItem] = [:]
        for item in items {
            guard let id = item.videoID, itemByID[id] == nil else { continue }
            itemByID[id] = item
        }
        var out = cachedSignals(for: ids)
        let missing = ids.filter { out[$0] == nil }
        guard !missing.isEmpty else { return out }
        pruneExpiredSignalCache()

        let app = self.app
        let maximumConcurrentSignalRequests = 8
        for start in stride(
            from: 0,
            to: missing.count,
            by: maximumConcurrentSignalRequests
        ) {
            // A mode switch / new load cancels the surrounding task; stop fanning
            // out fresh extractions the moment that happens.
            if Task.isCancelled { break }
            // Kick off the batch together so the resolveStream network waits
            // overlap. Structured, so cancelling the load also cancels the
            // in-flight extractions.
            let end = min(start + maximumConcurrentSignalRequests, missing.count)
            let batch = Array(missing[start..<end])
            let resolved = await withTaskGroup(
                of: (String, VideoSignals, VideoDetail)?.self
            ) { group in
                for id in batch {
                    let fallback = itemByID[id]
                    group.addTask {
                        guard !Task.isCancelled,
                            let d = try? await app.resolveStream(id)
                        else { return nil }
                        let title = d.title ?? fallback?.displayTitle ?? ""
                        let uploader = d.uploader ?? fallback?.uploaderName ?? ""
                        let topic = Self.topicKey(
                            category: d.category,
                            text: "\(title) \(uploader)"
                        )
                        return (
                            id,
                            VideoSignals(
                                category: d.category, tags: d.tags ?? [],
                                topicKey: topic), d
                        )
                    }
                }
                var collected: [(String, VideoSignals, VideoDetail)] = []
                for await result in group {
                    if let result { collected.append(result) }
                }
                return collected
            }
            for (id, sig, _) in resolved { out[id] = sig }
            cacheSignals(resolved, itemsByID: itemByID)
        }
        return out
    }

    private func cachedSignals(for ids: [String]) -> [String: VideoSignals] {
        guard let modelContext else { return [:] }
        return Self.freshCachedSignals(for: ids, in: modelContext)
    }

    static func freshCachedSignals(
        for ids: [String],
        in modelContext: ModelContext,
        now: Date = .now
    ) -> [String: VideoSignals] {
        guard !ids.isEmpty else { return [:] }
        let uniqueIDs = Array(Set(ids))
        let descriptor = FetchDescriptor<VideoSignalCacheEntry>(
            predicate: #Predicate { uniqueIDs.contains($0.videoID) })
        let entries = (try? modelContext.fetch(descriptor)) ?? []
        return freshCachedSignals(from: entries, now: now)
    }

    static func freshCachedSignals(
        from entries: [VideoSignalCacheEntry],
        now: Date = .now
    ) -> [String: VideoSignals] {
        entries.reduce(into: [:]) { out, entry in
            guard now.timeIntervalSince(entry.updatedAt) < signalCacheTTL else { return }
            out[entry.videoID] = entry.videoSignals
        }
    }

    /// Upsert a resolved batch with a single fetch for the existing rows, instead
    /// of one descriptor per video.
    private func cacheSignals(
        _ resolved: [(String, VideoSignals, VideoDetail)],
        itemsByID: [String: StreamItem]
    ) {
        guard let modelContext, !resolved.isEmpty else { return }
        let ids = resolved.map { $0.0 }
        let descriptor = FetchDescriptor<VideoSignalCacheEntry>(
            predicate: #Predicate { ids.contains($0.videoID) })
        let fetched = (try? modelContext.fetch(descriptor)) ?? []
        let existing = Dictionary(
            fetched.map { ($0.videoID, $0) },
            uniquingKeysWith: { first, _ in first })
        for (id, signals, detail) in resolved {
            let existingEntry = existing[id]
            let entry =
                existingEntry
                ?? {
                    let entry = VideoSignalCacheEntry(videoID: id)
                    modelContext.insert(entry)
                    return entry
                }()
            if !entry.update(from: detail, fallback: itemsByID[id], topicKey: signals.topicKey),
                existingEntry == nil
            {
                modelContext.delete(entry)
            }
        }
    }

    /// Rows past the read-side TTL are never served again — drop them so the
    /// cache table doesn't grow forever. One cheap batch delete per refine pass.
    private func pruneExpiredSignalCache(now: Date = .now) {
        guard let modelContext else { return }
        let cutoff = now.addingTimeInterval(-Self.signalCacheTTL)
        try? modelContext.delete(
            model: VideoSignalCacheEntry.self,
            where: #Predicate { $0.updatedAt < cutoff })
    }
}
