import Foundation
import PipedKit

extension RecommendationEngine {
    // MARK: Candidate pool

    nonisolated static func mergeCandidateSources(
        _ buckets: [CandidateSourceBucket],
        target: Int = 80
    ) -> CandidatePool {
        let buckets = Array(buckets.prefix(16))
        let target = min(max(0, target), 200)
        var items: [StreamItem] = []
        var included = Set<String>()
        var sourcesByID: [String: Set<CandidateSource>] = [:]
        var frequency: [String: Int] = [:]

        func noteSelected(_ item: StreamItem, bucket: CandidateSourceBucket) {
            guard let id = item.videoID else { return }
            sourcesByID[id, default: []].insert(bucket.source)
            if let count = bucket.frequency[id] {
                frequency[id] = max(frequency[id] ?? 0, count)
            }
        }

        @discardableResult
        func append(_ item: StreamItem) -> Bool {
            guard let id = item.videoID, !included.contains(id), items.count < target else { return false }
            included.insert(id)
            items.append(item)
            return true
        }

        for bucket in buckets {
            var addedForBucket = 0
            for item in bucket.items.prefix(500) where addedForBucket < bucket.limit {
                if append(item) { addedForBucket += 1 }
            }
        }

        if items.count < target {
            for bucket in buckets {
                for item in bucket.items.prefix(500) {
                    append(item)
                    if items.count >= target { break }
                }
                if items.count >= target { break }
            }
        }

        // Attribution runs over the final pool, decoupled from the quota gating
        // above: an item that made the pool credits every source that listed it
        // (and keeps that source's frequency), even where a bucket's quota or the
        // pool target cut the selection passes short. Multi-source items are
        // exactly the ones ranking should boost hardest.
        for bucket in buckets {
            for item in bucket.items.prefix(500) {
                guard let id = item.videoID, included.contains(id) else { continue }
                noteSelected(item, bucket: bucket)
            }
        }

        return CandidatePool(items: items, frequency: frequency, sourcesByID: sourcesByID)
    }

    // MARK: Watch weighting

    /// How strongly a watch counts, from how much of it you actually saw.
    /// Reaching the end is a strong "I really like this — suggest more"; bailing
    /// early is weak. Anchored so ~50% watched returns 1.0 — the original flat
    /// weight, so half-watches behave exactly as before. It then ramps up hard,
    /// hitting the 4× ceiling by 80%: you don't have to reach 100%, because end
    /// cards, outros and ads mean people routinely stop within the last 10–20%, so
    /// "near the end" already counts as finished. Unknown duration stays neutral.
    nonisolated static func watchWeight(position: Double, duration: Double) -> Double {
        guard position.isFinite,
            duration.isFinite,
            position >= 0,
            duration > 0
        else { return 1 }
        let unboundedRatio = position / duration
        guard unboundedRatio.isFinite else { return 1 }
        let ratio = min(unboundedRatio, 1)
        if ratio <= 0.5 { return 0.5 + ratio }  // 0 → 0.5, 0.5 → 1.0
        return min(4, 1 + (ratio - 0.5) * 10)  // 0.5 → 1.0, ≥0.8 → 4.0
    }

    // MARK: Strategy A — heuristic

    nonisolated static func rankRelated(_ pool: CandidatePool, profile: InterestProfile) -> [StreamItem] {
        let maxAff = max(profile.channelAffinity.values.max() ?? 1, 1)
        let now = Date().timeIntervalSince1970

        func freshness(_ uploaded: Int64?) -> Double {
            guard let uploaded, uploaded > 0 else { return 0 }
            let ageDays = (now - Double(uploaded) / 1000) / 86_400
            return max(0, 1 - ageDays / 60)  // decays over ~2 months
        }
        func score(_ item: StreamItem) -> Double {
            let id = item.videoID ?? ""
            let sources = pool.sourcesByID[id] ?? []
            let freq = Double(pool.frequency[id] ?? 0)
            let aff = (profile.channelAffinity[item.uploaderName ?? ""] ?? 0) / maxAff
            // A channel you follow is an explicit "I want this" — bump it like a
            // strong affinity hit on top of whatever the watch counts already gave.
            let sub = profile.subscribedIDs.contains(item.uploaderChannelID ?? "") ? 1.5 : 0
            let sourceBoost =
                (sources.contains(.saved) ? 1.0 : 0) + (sources.contains(.search) ? 0.8 : 0)
                + (sources.contains(.subscription) ? 0.6 : 0) + (sources.contains(.exploration) ? 0.25 : 0)
            return freq * 2.0 + aff * 1.5 + sub + sourceBoost + freshness(item.uploaded) * 0.5
        }
        // Score once per item, then sort — not once per comparison.
        return diversify(
            pool.items
                .map { ($0, score($0)) }
                .sorted { $0.1 > $1.1 }
                .map { $0.0 })
    }

    // MARK: Diversity

    /// Keep the opening screen from becoming one channel or one topic, while
    /// preserving the full ranked order after the first window.
    nonisolated static func diversify(
        _ ranked: [StreamItem],
        enrichment: [String: VideoSignals] = [:],
        window: Int = 15,
        maxPerChannel: Int = 2,
        maxPerTopic: Int = 4
    ) -> [StreamItem] {
        let target = min(window, ranked.count)
        guard target > 1 else { return ranked }

        var front: [StreamItem] = []
        var deferred: [StreamItem] = []
        var channelCounts: [String: Int] = [:]
        var topicCounts: [String: Int] = [:]

        func channelKey(_ item: StreamItem) -> String? {
            item.uploaderChannelID ?? item.uploaderName?.lowercased()
        }

        func canPlace(_ item: StreamItem) -> Bool {
            if let channel = channelKey(item),
                channelCounts[channel, default: 0] >= maxPerChannel
            {
                return false
            }
            if let topic = topicKey(for: item, enrichment: enrichment),
                topicCounts[topic, default: 0] >= maxPerTopic
            {
                return false
            }
            return true
        }

        func place(_ item: StreamItem, counted: Bool = true) {
            front.append(item)
            guard counted else { return }
            if let channel = channelKey(item) { channelCounts[channel, default: 0] += 1 }
            if let topic = topicKey(for: item, enrichment: enrichment) {
                topicCounts[topic, default: 0] += 1
            }
        }

        for item in ranked {
            if front.count < target, canPlace(item) {
                place(item)
            } else {
                deferred.append(item)
            }
        }

        var remainder: [StreamItem] = []
        for item in deferred {
            if front.count < target {
                place(item, counted: false)
            } else {
                remainder.append(item)
            }
        }
        return front + remainder
    }

    /// Pull-to-refresh should not feel like a no-op. When the top of the previous
    /// For You render appears again, move those items below the next screenful
    /// without excluding them from the feed.
    nonisolated static func rotateRecentlyShown(
        _ ranked: [StreamItem],
        recentTopIDs: Set<String>,
        protectedWindow: Int = 8,
        insertionIndex: Int = 12
    ) -> [StreamItem] {
        guard !recentTopIDs.isEmpty else { return ranked }

        var kept: [StreamItem] = []
        var held: [StreamItem] = []
        for (index, item) in ranked.enumerated() {
            let id = item.videoID ?? item.id
            if index < protectedWindow, recentTopIDs.contains(id) {
                held.append(item)
            } else {
                kept.append(item)
            }
        }

        let split = min(insertionIndex, kept.count)
        return Array(kept.prefix(split)) + held + Array(kept.dropFirst(split))
    }

    nonisolated private static func topicKey(
        for item: StreamItem,
        enrichment: [String: VideoSignals]
    ) -> String? {
        if let id = item.videoID, let signal = enrichment[id] {
            if let topicKey = signal.topicKey { return topicKey }
            if let category = signal.category?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).lowercased(),
                !category.isEmpty
            {
                return "yt:\(category)"
            }
        }

        return topicKey(category: nil, text: "\(item.displayTitle) \(item.uploaderName ?? "")")
    }

    nonisolated static func topicKey(category: String?, text rawText: String) -> String? {
        if let category = category.map({ RecommendationWorkBudget.field($0) })?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            !category.isEmpty
        {
            return "yt:\(category)"
        }

        let text = RecommendationWorkBudget.field(rawText).lowercased()
        let groups: [(String, [String])] = [
            ("tech", ["software", "hardware", "developer", "coding", "programming", "phone", "laptop", "ai"]),
            ("science", ["science", "physics", "space", "biology", "engineering", "math"]),
            ("politics", ["politics", "election", "government", "congress", "president"]),
            ("war", ["war", "military", "missile", "invasion", "combat", "defense"]),
            ("finance", ["finance", "stocks", "market", "crypto", "investing", "economy"]),
            ("gaming", ["gaming", "gameplay", "game", "speedrun", "esports"]),
            ("entertainment", ["movie", "film", "music", "celebrity", "trailer"]),
            ("sports", ["football", "basketball", "soccer", "baseball", "sports"]),
            ("lifestyle", ["vlog", "travel", "food", "fitness", "fashion", "cooking"]),
            ("education", ["documentary", "explained", "tutorial", "lecture", "history"]),
        ]
        for (topic, terms) in groups where terms.contains(where: { text.contains($0) }) {
            return topic
        }
        return nil
    }
}
