import Foundation
import PipedKit

extension RecommendationEngine {
    /// Gather related videos from the user's recent watches, with a frequency
    /// count (how many source videos pointed at each candidate).
    func candidates(from recent: [HistorySignal], excluding watched: Set<String>)
        async -> (items: [StreamItem], frequency: [String: Int])
    {
        var frequency: [String: Int] = [:]
        var byID: [String: StreamItem] = [:]
        var ordered: [StreamItem] = []
        for related in await relatedStreams(forVideoIDs: recent.prefix(12).map(\.videoID)) {
            for item in related {
                guard let id = item.videoID, !watched.contains(id) else { continue }
                frequency[id, default: 0] += 1
                if byID[id] == nil {
                    byID[id] = item
                    ordered.append(item)
                }
            }
        }
        let ranked = ordered.sorted { lhs, rhs in
            let lf = frequency[lhs.videoID ?? ""] ?? 0
            let rf = frequency[rhs.videoID ?? ""] ?? 0
            if lf != rf { return lf > rf }
            return (lhs.uploaded ?? 0) > (rhs.uploaded ?? 0)
        }
        return (ranked, frequency)
    }

    /// Resolve `/streams` for several seed videos with bounded concurrency
    /// (mirrors `subscriptionCandidates`), returning each seed's related videos
    /// in seed order so the downstream merges stay deterministic.
    private func relatedStreams(forVideoIDs videoIDs: [String]) async -> [[StreamItem]] {
        let videoIDs = Array(videoIDs.prefix(16))
        guard !videoIDs.isEmpty else { return [] }
        let app = self.app
        var lists = Array(repeating: [StreamItem](), count: videoIDs.count)
        let maximumConcurrentRelatedRequests = 6
        for start in stride(
            from: 0,
            to: videoIDs.count,
            by: maximumConcurrentRelatedRequests
        ) {
            let end = min(start + maximumConcurrentRelatedRequests, videoIDs.count)
            let fetched = await withTaskGroup(of: (Int, [StreamItem]).self) { group in
                for index in start..<end {
                    let id = videoIDs[index]
                    group.addTask {
                        let related = (try? await app.resolveStream(id))?.relatedStreams ?? []
                        return (index, related.filter(\.isVideo))
                    }
                }
                var out: [(Int, [StreamItem])] = []
                for await result in group { out.append(result) }
                return out
            }
            for (index, related) in fetched { lists[index] = related }
        }
        return lists
    }

    /// Fresh candidates from the user's recent searches: run each query and take
    /// its top video results. Unlike related-streams (bounded by what you've
    /// already watched), this injects genuinely new content matching explicit
    /// intent — "I searched X, now my feed has more X."
    func searchCandidates(
        _ queries: [String], excluding watched: Set<String>,
        perQuery: Int = 12, maxPages: Int = 2
    ) async -> [StreamItem] {
        let queries = queries.prefix(8).map { RecommendationWorkBudget.field($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let perQuery = min(max(1, perQuery), 24)
        let maxPages = min(max(1, maxPages), 4)
        guard let client = try? app.client, !queries.isEmpty else { return [] }
        // Queries run concurrently (each still pages sequentially — page 2 needs
        // page 1's token); results merge back in query order so the candidate
        // pool stays deterministic.
        var lists = Array(repeating: [StreamItem](), count: queries.count)
        let maximumConcurrentSearchRequests = 4
        for start in stride(
            from: 0,
            to: queries.count,
            by: maximumConcurrentSearchRequests
        ) {
            let end = min(start + maximumConcurrentSearchRequests, queries.count)
            let fetched = await withTaskGroup(of: (Int, [StreamItem]).self) { group in
                for index in start..<end {
                    let query = queries[index]
                    group.addTask {
                        (
                            index,
                            await Self.searchResults(
                                for: query, client: client,
                                excluding: watched,
                                perQuery: perQuery,
                                maxPages: maxPages)
                        )
                    }
                }
                var out: [(Int, [StreamItem])] = []
                for await result in group { out.append(result) }
                return out
            }
            for (index, items) in fetched { lists[index] = items }
        }
        var byID: [String: StreamItem] = [:]
        var ordered: [StreamItem] = []
        for list in lists {
            for item in list {
                guard let id = item.videoID, byID[id] == nil else { continue }
                byID[id] = item
                ordered.append(item)
            }
        }
        return ordered
    }

    /// One query's paged video results, deduped within the query and capped at
    /// `perQuery`. Cross-query dedupe happens in `searchCandidates`.
    nonisolated private static func searchResults(
        for query: String, client: PipedClient,
        excluding watched: Set<String>,
        perQuery: Int, maxPages: Int
    ) async -> [StreamItem] {
        var seen = Set<String>()
        var seenTokens = Set<String>()
        var taken: [StreamItem] = []
        var token: String?
        for page in 0..<maxPages {
            let response: SearchResponse?
            if page == 0 {
                response = try? await client.searchPage(query, filter: "videos")
            } else if let token {
                response = try? await client.searchNextPage(
                    query, filter: "videos", nextPage: token)
            } else {
                break
            }
            guard let response else { break }
            for item in (response.items ?? []) where item.isVideo {
                guard let id = item.videoID, !watched.contains(id) else { continue }
                if seen.insert(id).inserted {
                    taken.append(item)
                }
                if taken.count >= perQuery { break }
            }
            token = normalizedToken(response.nextPage)
            if let token, !seenTokens.insert(token).inserted { break }
            if taken.count >= perQuery || token == nil { break }
        }
        return taken
    }

    nonisolated private static func normalizedToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false
            && (trimmed?.utf8.count ?? 0) <= RecommendationWorkBudget.maximumCursorBytes
            ? trimmed : nil
    }

    /// Candidates from the related-streams of saved (playlist) videos —
    /// "more like what you saved." Same shape as `candidates(from:)`, seeded by
    /// deliberate keeps instead of passive watches.
    func playlistCandidates(_ videoIDs: [String], excluding watched: Set<String>)
        async -> [StreamItem]
    {
        var byID: [String: StreamItem] = [:]
        var ordered: [StreamItem] = []
        for related in await relatedStreams(forVideoIDs: Array(videoIDs.prefix(16))) {
            for item in related {
                guard let id = item.videoID, !watched.contains(id) else { continue }
                if byID[id] == nil {
                    byID[id] = item
                    ordered.append(item)
                }
            }
        }
        return ordered
    }

    /// Recent uploads from the channels the user subscribes to — the most explicit
    /// "I like this channel" signal there is. One `/channel` request per sub (see
    /// below); capped so a prolific sub can't swamp the pool (ranking still orders
    /// them by taste). These let For You surface your channels' new videos, not
    /// just whatever related-streams happen to bubble up.
    func subscriptionCandidates(
        _ channelIDs: [String], excluding watched: Set<String>,
        limit: Int = 40
    ) async -> [StreamItem] {
        let channelIDs = Self.prioritizedChannelIDs(channelIDs)
        guard !channelIDs.isEmpty, let client = try? app.client else { return [] }
        // One `/channel` request per sub — `feed/unauthenticated` is empty on many
        // instances. Page one (the channel's most recent uploads) is enough for a
        // candidate pool; ranking reorders them anyway.
        var lists: [[StreamItem]] = []
        let maximumConcurrentSubscriptionRequests = 6
        for start in stride(
            from: 0,
            to: channelIDs.count,
            by: maximumConcurrentSubscriptionRequests
        ) {
            let end = min(start + maximumConcurrentSubscriptionRequests, channelIDs.count)
            let slice = Array(channelIDs[start..<end])
            let fetched = await withTaskGroup(of: [StreamItem].self) { group in
                for id in slice {
                    group.addTask {
                        let channel = try? await client.channel(id: id)
                        return (channel?.relatedStreams ?? []).filter(\.isVideo)
                    }
                }
                var out: [[StreamItem]] = []
                for await result in group { out.append(result) }
                return out
            }
            lists.append(contentsOf: fetched)
        }
        // Round-robin across channels so a prolific sub can't fill the pool before
        // the others get a look in.
        var byID: [String: StreamItem] = [:]
        var ordered: [StreamItem] = []
        let deepest = lists.map(\.count).max() ?? 0
        for index in 0..<deepest {
            for list in lists where index < list.count {
                let item = list[index]
                guard let id = item.videoID, !watched.contains(id), byID[id] == nil else { continue }
                byID[id] = item
                ordered.append(item)
                if ordered.count >= limit { break }
            }
            if ordered.count >= limit { break }
        }
        return ordered
    }

    nonisolated static func prioritizedChannelIDs(_ channelIDs: [String]) -> [String] {
        var seen = Set<String>()
        return channelIDs.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty,
                id.utf8.count <= RecommendationWorkBudget.maximumChannelIDBytes,
                seen.insert(id).inserted
            else { return nil }
            return id
        }.prefix(RecommendationWorkBudget.maximumSubscriptionRequests).map { $0 }
    }
}
