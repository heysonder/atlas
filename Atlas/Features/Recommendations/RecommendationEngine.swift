import Foundation
import NaturalLanguage
import SwiftData
import PipedKit

/// Per-video signals fetched from `/streams` to sharpen ranking: YouTube's own
/// category label ("News & politics", "Science & technology") and the creator's
/// tags — clean topical keywords with none of a description's ad/affiliate copy.
nonisolated struct VideoSignals: Sendable {
    let category: String?
    let tags: [String]
    let topicKey: String?

    nonisolated init(category: String?, tags: [String], topicKey: String? = nil) {
        self.category = category
        self.tags = tags
        self.topicKey = topicKey
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
        self.videoID = entry.videoID
        self.title = entry.title
        self.uploader = entry.uploader
        self.thumbnailURL = entry.thumbnailURL
        self.watchedAt = entry.watchedAt
        self.positionSeconds = entry.positionSeconds
        self.durationSeconds = entry.durationSeconds
    }

    init(videoID: String, title: String, uploader: String? = nil,
         thumbnailURL: String? = nil, watchedAt: Date,
         positionSeconds: Double, durationSeconds: Double) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
        self.thumbnailURL = thumbnailURL
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
        self.videoID = video.videoID
        self.title = video.title
        self.uploader = video.uploader
        self.addedAt = video.addedAt
    }

    init(videoID: String, title: String, uploader: String? = nil, addedAt: Date) {
        self.videoID = videoID
        self.title = title
        self.uploader = uploader
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
        self.query = query
        self.count = max(1, count)
        self.lastSearchedAt = lastSearchedAt

        let ageDays = max(0, now.timeIntervalSince(lastSearchedAt) / 86_400)
        let recency = max(0.25, 1 - ageDays / 30)
        let frequency = min(4, 1 + log2(Double(max(1, count))))
        self.weight = frequency * recency
    }

    var copyCount: Int {
        max(1, min(4, Int(weight.rounded())))
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
        return searches
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

    init(history: [HistorySignal], feedback: [FeedbackSignal], saved: [SavedVideoSignal],
         searches: [SearchSignal], subscribedIDs: Set<String>,
         relatedSeeds: [HistorySignal], explorationSeeds: [HistorySignal],
         channelAffinity: [String: Double],
         candidateSearchQueriesOverride: [String]? = nil,
         savedSeedIDsOverride: [String]? = nil) {
        self.history = history
        self.feedback = feedback
        self.saved = saved
        self.searches = searches
        self.subscribedIDs = subscribedIDs
        self.relatedSeeds = relatedSeeds
        self.explorationSeeds = explorationSeeds
        self.channelAffinity = channelAffinity
        self.candidateSearchQueriesOverride = candidateSearchQueriesOverride
        self.savedSeedIDsOverride = savedSeedIDsOverride
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

    init(source: CandidateSource, items: [StreamItem],
         frequency: [String: Int] = [:], limit: Int) {
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

/// Shared candidate generation + the two ranking strategies.
@MainActor
struct RecommendationEngine {
    let app: AppModel
    let modelContext: ModelContext?
    private static let signalCacheTTL: TimeInterval = 30 * 86_400

    init(app: AppModel, modelContext: ModelContext? = nil) {
        self.app = app
        self.modelContext = modelContext
    }

    /// Gather related videos from the user's recent watches, with a frequency
    /// count (how many source videos pointed at each candidate).
    func candidates(from recent: [HistorySignal], excluding watched: Set<String>)
    async -> (items: [StreamItem], frequency: [String: Int]) {
        var frequency: [String: Int] = [:]
        var byID: [String: StreamItem] = [:]
        var ordered: [StreamItem] = []
        for entry in recent {
            let related = (try? await app.resolveStream(entry.videoID))?.relatedStreams ?? []
            for item in related where item.isVideo {
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

    /// Fresh candidates from the user's recent searches: run each query and take
    /// its top video results. Unlike related-streams (bounded by what you've
    /// already watched), this injects genuinely new content matching explicit
    /// intent — "I searched X, now my feed has more X."
    func searchCandidates(_ queries: [String], excluding watched: Set<String>,
                          perQuery: Int = 12, maxPages: Int = 2) async -> [StreamItem] {
        guard let client = try? app.client else { return [] }
        var byID: [String: StreamItem] = [:]
        var ordered: [StreamItem] = []
        for query in queries {
            var token: String?
            var taken = 0
            for page in 0..<maxPages {
                let response: SearchResponse?
                if page == 0 {
                    response = try? await client.searchPage(query, filter: "videos")
                } else if let token {
                    response = try? await client.searchNextPage(
                        query, filter: "videos", nextpage: token)
                } else {
                    break
                }
                guard let response else { break }
                for item in (response.items ?? []) where item.isVideo {
                    guard let id = item.videoID, !watched.contains(id) else { continue }
                    if byID[id] == nil {
                        byID[id] = item
                        ordered.append(item)
                        taken += 1
                    }
                    if taken >= perQuery { break }
                }
                token = normalizedToken(response.nextpage)
                if taken >= perQuery || token == nil { break }
            }
        }
        return ordered
    }

    private func normalizedToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    /// Candidates from the related-streams of saved (playlist) videos —
    /// "more like what you saved." Same shape as `candidates(from:)`, seeded by
    /// deliberate keeps instead of passive watches.
    func playlistCandidates(_ videoIDs: [String], excluding watched: Set<String>)
    async -> [StreamItem] {
        var byID: [String: StreamItem] = [:]
        var ordered: [StreamItem] = []
        for videoID in videoIDs {
            let related = (try? await app.resolveStream(videoID))?.relatedStreams ?? []
            for item in related where item.isVideo {
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
    /// "I like this channel" signal there is. One `/feed` request for all of them;
    /// capped so a prolific sub can't swamp the pool (ranking still orders them by
    /// taste). These let For You surface your channels' new videos, not just
    /// whatever related-streams happen to bubble up.
    func subscriptionCandidates(_ channelIDs: [String], excluding watched: Set<String>,
                                limit: Int = 40) async -> [StreamItem] {
        guard !channelIDs.isEmpty, let client = try? app.client else { return [] }
        // One `/channel` request per sub — `feed/unauthenticated` is empty on many
        // instances. Page one (the channel's most recent uploads) is enough for a
        // candidate pool; ranking reorders them anyway.
        var lists: [[StreamItem]] = []
        let cap = 6
        for start in stride(from: 0, to: channelIDs.count, by: cap) {
            let slice = Array(channelIDs[start..<min(start + cap, channelIDs.count)])
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

    // MARK: Local profile + candidate pool

    @MainActor
    static func makeProfile(history: [HistoryEntry], feedback: [FeedbackSignal],
                            saved: [PlaylistVideo], searches: [SearchSignal],
                            subscribedIDs: Set<String>,
                            snapshot: RecommendationProfileSnapshot? = nil,
                            signature: String? = nil) -> InterestProfile {
        makeProfile(
            history: history.map(HistorySignal.init),
            feedback: feedback,
            saved: saved.map(SavedVideoSignal.init),
            searches: searches,
            subscribedIDs: subscribedIDs,
            snapshot: snapshot,
            signature: signature)
    }

    static func makeProfile(history: [HistorySignal], feedback: [FeedbackSignal],
                            saved: [SavedVideoSignal], searches: [SearchSignal],
                            subscribedIDs: Set<String>,
                            snapshot: RecommendationProfileSnapshot? = nil,
                            signature: String? = nil) -> InterestProfile {
        let affinity = snapshot.flatMap { cached in
            signature == cached.signature ? cached.channelAffinity : nil
        } ?? channelAffinity(history: history, saved: saved)

        if let snapshot, signature == snapshot.signature {
            let historyByID = Dictionary(uniqueKeysWithValues: history.map { ($0.videoID, $0) })
            let relatedSeeds = snapshot.relatedSeedIDs.compactMap { historyByID[$0] }
            let explorationSeeds = snapshot.explorationSeedIDs.compactMap { historyByID[$0] }
            return InterestProfile(
                history: history, feedback: feedback, saved: saved, searches: searches,
                subscribedIDs: subscribedIDs, relatedSeeds: relatedSeeds,
                explorationSeeds: explorationSeeds, channelAffinity: affinity,
                candidateSearchQueriesOverride: snapshot.candidateSearchQueries,
                savedSeedIDsOverride: snapshot.savedSeedIDs)
        }

        let relatedSeeds = selectHistorySeeds(history, limit: 8, channelCap: 2)
        let relatedIDs = Set(relatedSeeds.map(\.videoID))
        let explorationSeeds = selectHistorySeeds(
            history, limit: 3, excludedIDs: relatedIDs, channelCap: 1)

        return InterestProfile(history: history, feedback: feedback, saved: saved,
                               searches: searches, subscribedIDs: subscribedIDs,
                               relatedSeeds: relatedSeeds,
                               explorationSeeds: explorationSeeds,
                               channelAffinity: affinity)
    }

    @MainActor
    static func profileSignature(history: [HistoryEntry], feedback: [FeedbackSignal],
                                 saved: [PlaylistVideo], searches: [SearchSignal],
                                 subscribedIDs: Set<String>) -> String {
        profileSignature(
            history: history.map(HistorySignal.init),
            feedback: feedback,
            saved: saved.map(SavedVideoSignal.init),
            searches: searches,
            subscribedIDs: subscribedIDs)
    }

    static func profileSignature(history: [HistorySignal], feedback: [FeedbackSignal],
                                 saved: [SavedVideoSignal], searches: [SearchSignal],
                                 subscribedIDs: Set<String>) -> String {
        let historyPart = history.prefix(80).map {
            "\($0.videoID):\(Int($0.watchedAt.timeIntervalSince1970)):" +
            "\(Int($0.positionSeconds)):\(Int($0.durationSeconds)):\($0.uploader ?? "")"
        }.joined(separator: "|")
        let feedbackPart = feedback.sorted { $0.title < $1.title }.map {
            "\($0.signal):\($0.title):\($0.uploader ?? ""):\($0.category ?? ""):\($0.tags.joined(separator: ","))"
        }.joined(separator: "|")
        let savedPart = saved.prefix(60).map {
            "\($0.videoID):\(Int($0.addedAt.timeIntervalSince1970)):\($0.uploader ?? "")"
        }.joined(separator: "|")
        let searchPart = searches.map {
            "\($0.query):\($0.count):\(Int($0.lastSearchedAt.timeIntervalSince1970))"
        }.joined(separator: "|")
        let subPart = subscribedIDs.sorted().joined(separator: "|")
        return [historyPart, feedbackPart, savedPart, searchPart, subPart].joined(separator: "\n")
    }

    nonisolated private static func channelAffinity(history: [HistorySignal],
                                                    saved: [SavedVideoSignal]) -> [String: Double] {
        var affinity: [String: Double] = [:]
        for entry in history {
            if let u = entry.uploader {
                affinity[u, default: 0] += watchWeight(position: entry.positionSeconds,
                                                       duration: entry.durationSeconds)
            }
        }
        for video in saved {
            if let u = video.uploader { affinity[u, default: 0] += 1.5 }
        }
        return affinity
    }

    /// Strong-watch seed selection: prefer videos the user actually spent time
    /// with, keep some recency, and avoid letting one channel own all seed slots.
    nonisolated private static func selectHistorySeeds(_ history: [HistorySignal], limit: Int,
                                                       excludedIDs: Set<String> = [],
                                                       channelCap: Int) -> [HistorySignal] {
        let ranked = history
            .filter { !excludedIDs.contains($0.videoID) }
            .map { ($0, historySeedScore($0)) }
            .sorted {
                if $0.1 == $1.1 { return $0.0.watchedAt > $1.0.watchedAt }
                return $0.1 > $1.1
            }

        var chosen: [HistorySignal] = []
        var channels: [String: Int] = [:]
        for (entry, _) in ranked where chosen.count < limit {
            let key = entry.uploader ?? entry.videoID
            guard channels[key, default: 0] < channelCap else { continue }
            chosen.append(entry)
            channels[key, default: 0] += 1
        }
        if chosen.count < limit {
            let chosenIDs = Set(chosen.map(\.videoID))
            for (entry, _) in ranked where chosen.count < limit && !chosenIDs.contains(entry.videoID) {
                chosen.append(entry)
            }
        }
        return chosen
    }

    nonisolated private static func historySeedScore(_ entry: HistorySignal) -> Double {
        let ageDays = max(0, Date().timeIntervalSince(entry.watchedAt) / 86_400)
        let recency = max(0.2, 1 - ageDays / 45)
        return watchWeight(position: entry.positionSeconds, duration: entry.durationSeconds) * recency
    }

    nonisolated static func mergeCandidateSources(_ buckets: [CandidateSourceBucket],
                                                  target: Int = 80) -> CandidatePool {
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
            for item in bucket.items {
                guard addedForBucket < bucket.limit else { continue }
                guard let id = item.videoID else { continue }
                if included.contains(id) {
                    noteSelected(item, bucket: bucket)
                } else if append(item) {
                    noteSelected(item, bucket: bucket)
                    addedForBucket += 1
                }
            }
        }

        if items.count < target {
            for bucket in buckets {
                for item in bucket.items {
                    if append(item) {
                        noteSelected(item, bucket: bucket)
                    }
                    if items.count >= target { break }
                }
                if items.count >= target { break }
            }
        }

        return CandidatePool(items: items, frequency: frequency, sourcesByID: sourcesByID)
    }

    // MARK: Per-video enrichment (YouTube category + tags)

    /// Re-rank a shortlist using YouTube's own category + tags, fetched per video.
    /// This is what hard-buries News & politics for an all-tech watcher and folds
    /// clean creator tags into the topic match. Runs after the instant on-device
    /// pass so the user sees results immediately, then an upgrade once it returns.
    func refineWithSignals(_ shortlist: [StreamItem], profile: InterestProfile,
                           sourcesByID: [String: Set<CandidateSource>] = [:]) async -> [StreamItem] {
        let signals = await fetchSignals(shortlist)
        let ranked = await Self.rankByTopicInBackground(
            shortlist, profile: profile, sourcesByID: sourcesByID, enrichment: signals)
        return Self.diversify(ranked, enrichment: signals)
    }

    /// Fetch `/streams` for the shortlist with bounded concurrency, so we never
    /// fire more than `cap` extractions at the instance at once. Cached + de-duped
    /// by `resolveStream`, so repeat refreshes are cheap.
    private func fetchSignals(_ items: [StreamItem]) async -> [String: VideoSignals] {
        let ids = items.compactMap(\.videoID)
        guard !ids.isEmpty else { return [:] }
        var itemByID: [String: StreamItem] = [:]
        for item in items {
            guard let id = item.videoID, itemByID[id] == nil else { continue }
            itemByID[id] = item
        }
        var out = cachedSignals(for: ids)
        let missing = ids.filter { out[$0] == nil }
        guard !missing.isEmpty else { return out }

        let cap = 8   // concurrent extractions per batch — tunable knob
        for start in stride(from: 0, to: missing.count, by: cap) {
            // Kick off the batch together; since resolveStream awaits the network,
            // these main-actor tasks overlap their I/O waits, then we collect them.
            let tasks = missing[start..<min(start + cap, missing.count)].map { id in
                Task { @MainActor () -> (String, VideoSignals, VideoDetail)? in
                    guard let d = try? await app.resolveStream(id) else { return nil }
                    let topic = Self.topicKey(category: d.category,
                                              text: "\(d.title ?? itemByID[id]?.displayTitle ?? "") \(d.uploader ?? itemByID[id]?.uploaderName ?? "")")
                    return (id, VideoSignals(category: d.category, tags: d.tags ?? [],
                                             topicKey: topic), d)
                }
            }
            for task in tasks {
                if let (id, sig, detail) = await task.value {
                    out[id] = sig
                    cacheSignals(videoID: id, detail: detail,
                                 fallback: itemByID[id], topicKey: sig.topicKey)
                }
            }
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

    private func cacheSignals(videoID: String, detail: VideoDetail,
                              fallback item: StreamItem?, topicKey: String?) {
        guard let modelContext else { return }
        let descriptor = FetchDescriptor<VideoSignalCacheEntry>(
            predicate: #Predicate { $0.videoID == videoID })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.update(from: detail, fallback: item, topicKey: topicKey)
        } else {
            let entry = VideoSignalCacheEntry(videoID: videoID)
            entry.update(from: detail, fallback: item, topicKey: topicKey)
            modelContext.insert(entry)
        }
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
        guard duration > 0 else { return 1 }
        let ratio = min(position / duration, 1)
        if ratio <= 0.5 { return 0.5 + ratio }            // 0 → 0.5, 0.5 → 1.0
        return min(4, 1 + (ratio - 0.5) * 10)             // 0.5 → 1.0, ≥0.8 → 4.0
    }

    // MARK: Strategy A — heuristic

    nonisolated static func rankRelated(_ pool: CandidatePool, profile: InterestProfile) -> [StreamItem] {
        let maxAff = max(profile.channelAffinity.values.max() ?? 1, 1)
        let now = Date().timeIntervalSince1970

        func freshness(_ uploaded: Int64?) -> Double {
            guard let uploaded, uploaded > 0 else { return 0 }
            let ageDays = (now - Double(uploaded) / 1000) / 86_400
            return max(0, 1 - ageDays / 60)   // decays over ~2 months
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
                (sources.contains(.saved) ? 1.0 : 0) +
                (sources.contains(.search) ? 0.8 : 0) +
                (sources.contains(.subscription) ? 0.6 : 0) +
                (sources.contains(.exploration) ? 0.25 : 0)
            return freq * 2.0 + aff * 1.5 + sub + sourceBoost + freshness(item.uploaded) * 0.5
        }
        return diversify(pool.items.sorted { score($0) > score($1) })
    }

    // MARK: Strategy B — on-device semantic

    nonisolated static func rankByTopic(_ items: [StreamItem], profile: InterestProfile,
                                        sourcesByID: [String: Set<CandidateSource>] = [:],
                                        enrichment: [String: VideoSignals] = [:]) -> [StreamItem] {
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else { return items }

        // Only pure grammar words are dropped outright. Topical-but-common words
        // ("new", "best", "review") are KEPT — IDF below down-weights whatever turns
        // out to be ubiquitous in your actual pool, instead of guessing a blocklist.
        let stop: Set<String> = [
            "the","and","for","you","your","with","this","that","from","but","not",
            "are","was","has","have","had","its","our","they","them","then","than",
            "when","who","all","what","why","how","can","will","just","out","now","get"
        ]

        func tokens(_ text: String) -> [String] {
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 && !stop.contains($0) }
        }

        // The channel name is the strongest topic signal we have ("Veritasium",
        // "Fireship", "ThePrimeagen" *are* the topic) and survives when a title is
        // all jargon/proper-nouns the embedding can't see — so fold it into the text.
        func docTokens(title: String, channel: String?) -> [String] {
            tokens(channel.map { "\(title) \($0)" } ?? title)
        }

        func cosine(_ a: [Double], _ b: [Double]) -> Double {
            guard a.count == b.count else { return 0 }
            var dot = 0.0, na = 0.0, nb = 0.0
            for i in a.indices { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
            let denom = (na.squareRoot() * nb.squareRoot())
            return denom == 0 ? 0 : dot / denom
        }

        // Plain (un-weighted) mean vector — used for category classification, where
        // IDF would be counterproductive: it'd suppress the very category words (like
        // "war") that are common in a news-heavy candidate pool.
        func meanVector(_ doc: [String]) -> [Double]? {
            var sum: [Double] = []
            var n = 0
            for w in doc {
                guard let v = embedding.vector(for: w) else { continue }
                if sum.isEmpty { sum = v } else { for i in v.indices { sum[i] += v[i] } }
                n += 1
            }
            guard n > 0 else { return nil }
            return sum.map { $0 / Double(n) }
        }

        // Zero-shot topic categories: each is a prototype vector built from seed
        // words; a video is assigned to its nearest prototype. Splitting politics
        // from war matters — a "Trump phone" review may brush politics, but it's
        // nowhere near "war", so Iran/Ukraine content still gets gated below.
        let categorySeeds: [(String, [String])] = [
            ("tech", ["technology","software","hardware","gadget","computer","programming","developer","app","phone","laptop","processor","coding","startup","silicon"]),
            ("science", ["science","physics","chemistry","biology","space","astronomy","research","engineering","mathematics"]),
            ("politics", ["politics","election","president","government","senate","congress","policy","campaign","vote","democrat","republican"]),
            ("war", ["war","military","army","troops","missile","invasion","conflict","weapon","soldier","strike","defense","combat"]),
            ("news", ["news","breaking","report","headline","coverage","reporter","correspondent"]),
            ("finance", ["finance","stocks","market","economy","investing","crypto","trading","inflation"]),
            ("gaming", ["gaming","gameplay","game","esports","speedrun","multiplayer"]),
            ("entertainment", ["movie","film","celebrity","music","drama","trailer","song","album"]),
            ("sports", ["sports","football","basketball","soccer","baseball","league","championship"]),
            ("lifestyle", ["vlog","travel","food","cooking","fitness","fashion","lifestyle"]),
            ("education", ["history","documentary","explained","education","tutorial","lecture"]),
        ]
        let prototypes: [(name: String, vec: [Double])] = categorySeeds.compactMap { name, seeds in
            meanVector(seeds).map { (name, $0) }
        }
        func classify(_ doc: [String]) -> String? {
            guard let v = meanVector(doc), !prototypes.isEmpty else { return nil }
            return prototypes.max { cosine($0.vec, v) < cosine($1.vec, v) }?.name
        }

        // Taste = your watches from the last 7 days. With nearest-match scoring
        // (below) a bigger sample only helps, so widen it — but floor it when you've
        // had a quiet week, and cap it so the math stays cheap.
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        var recent = profile.history.filter { $0.watchedAt >= cutoff }
        if recent.count < 15 { recent = Array(profile.history.prefix(30)) }
        recent = Array(recent.prefix(60))

        // Weight each watch by how much of it you finished: a video you watched to
        // the end joins your taste up to 4×, a half-watch once (as before). Repeating
        // the doc lets the "top-3 nearest" scoring below lean hard toward the topics
        // you actually finish — "suggest more like the things I watch all the way."
        let tasteDocs = recent.flatMap { entry -> [[String]] in
            let doc = docTokens(title: entry.title, channel: entry.uploader)
            let copies = max(1, Int(watchWeight(position: entry.positionSeconds,
                                                duration: entry.durationSeconds).rounded()))
            return Array(repeating: doc, count: copies)
        }
        // Fold creator tags (when enriched) into the candidate's text — clean topical
        // keywords that sharpen both the similarity and the category classification.
        let candDocs = items.map { item -> [String] in
            var t = docTokens(title: item.displayTitle, channel: item.uploaderName)
            if let tags = enrichment[item.videoID ?? ""]?.tags, !tags.isEmpty {
                t += tokens(tags.joined(separator: " "))
            }
            return t
        }

        // Explicit feedback. Likes act like strong watches (added to taste + your
        // category profile); dislikes drive an active penalty below.
        func feedbackDoc(_ f: FeedbackSignal) -> [String] {
            var t = docTokens(title: f.title, channel: f.uploader)
            if !f.tags.isEmpty { t += tokens(f.tags.joined(separator: " ")) }
            return t
        }
        let likedDocs = profile.feedback.filter { $0.signal > 0 }.map(feedbackDoc)
        let dislikedDocs = profile.feedback.filter { $0.signal < 0 }.map(feedbackDoc)

        // Deliberate signals beyond a passive watch: a playlist save is a strong
        // "keep this" — its title+channel joins your taste like a like. A recent
        // search is pure topical intent — the query string itself is the doc.
        let savedDocs = profile.saved.map { docTokens(title: $0.title, channel: $0.uploader) }
        let searchDocs = profile.searches.flatMap { signal -> [[String]] in
            let doc = tokens(signal.query)
            guard !doc.isEmpty else { return [] }
            return Array(repeating: doc, count: signal.copyCount)
        }

        // Your category distribution, learned from history + likes — no hardcoded
        // "news is bad". A candidate whose category you never watch gets gated; a
        // like on that category raises its share and lifts the gate.
        var catCount: [String: Int] = [:]
        var classified = 0
        for doc in tasteDocs + likedDocs + savedDocs + searchDocs { if let c = classify(doc) { catCount[c, default: 0] += 1; classified += 1 } }
        func categoryFit(_ category: String?) -> Double {
            guard classified > 0, let c = category else { return 1 }  // no signal → don't gate
            return Double(catCount[c] ?? 0) / Double(classified)
        }
        // How much of your taste is itself news/politics/war — decides whether to
        // trust YouTube's "News & politics" label as grounds to bury a candidate.
        let newsShare = classified > 0
            ? Double((catCount["news"] ?? 0) + (catCount["politics"] ?? 0) + (catCount["war"] ?? 0)) / Double(classified)
            : 0
        // Categories you've explicitly thumbed-down — suppressed wholesale below.
        let dislikedCategories = Set(dislikedDocs.compactMap(classify))

        // IDF over the live pool: a word in every title (incl. "new"/"best"/"video")
        // earns weight ~1; a distinctive word earns more. Down-weight, never drop.
        var df: [String: Int] = [:]
        for doc in tasteDocs + candDocs + likedDocs + dislikedDocs + savedDocs + searchDocs { for w in Set(doc) { df[w, default: 0] += 1 } }
        let total = Double(tasteDocs.count + candDocs.count + likedDocs.count + dislikedDocs.count
                           + savedDocs.count + searchDocs.count)
        func idf(_ w: String) -> Double { log((total + 1) / Double((df[w] ?? 0) + 1)) + 1 }

        func vector(_ doc: [String]) -> [Double]? {
            var sum: [Double] = []
            var wsum = 0.0
            for w in doc {
                guard let v = embedding.vector(for: w) else { continue }
                let weight = idf(w)
                if sum.isEmpty { sum = v.map { $0 * weight } }
                else { for i in v.indices { sum[i] += v[i] * weight } }
                wsum += weight
            }
            guard wsum > 0 else { return nil }
            return sum.map { $0 / wsum }
        }

        // Likes, playlist saves, and recent searches are all interest signals — they
        // join your taste so similar videos rank up. A dislike forms a separate
        // "anti-taste" used to push down lookalikes.
        let tasteVectors = (tasteDocs + likedDocs + savedDocs + searchDocs).compactMap(vector)
        let dislikedVectors = dislikedDocs.compactMap(vector)
        guard !tasteVectors.isEmpty else { return items }

        let maxAff = max(profile.channelAffinity.values.max() ?? 1, 1)

        func topThreeMeanSimilarity(to v: [Double], in candidates: [[Double]]) -> Double {
            var first = -Double.infinity
            var second = -Double.infinity
            var third = -Double.infinity
            var count = 0
            for candidate in candidates {
                let similarity = cosine(candidate, v)
                count += 1
                if similarity > first {
                    third = second
                    second = first
                    first = similarity
                } else if similarity > second {
                    third = second
                    second = similarity
                } else if similarity > third {
                    third = similarity
                }
            }
            guard count > 0 else { return 0 }
            let top = [first, second, third].prefix(min(3, count))
            return top.reduce(0, +) / Double(top.count)
        }

        let candidateFeatures = zip(items, candDocs).map { item, doc in
            let category = classify(doc)
            return (item: item, vector: vector(doc), category: category, fit: categoryFit(category))
        }

        func score(_ item: StreamItem, vector v: [Double], category: String?, fit: Double) -> Double {
            let id = item.videoID ?? ""
            let sources = sourcesByID[id] ?? []
            // Mean of your 3 NEAREST interests: as sharp as a single max, but one
            // stray off-topic watch can't single-handedly magnet a candidate up.
            let topicSim = topThreeMeanSimilarity(to: v, in: tasteVectors)
            // Categorical gate: collapse the score of a video whose category you
            // essentially never watch (e.g. war/news for an all-tech history). The
            // 0.15 floor keeps it soft, so a misclassification can't fully erase it.
            let gated = topicSim * (0.15 + 0.85 * fit)
            let aff = (profile.channelAffinity[item.uploaderName ?? ""] ?? 0) / maxAff
            // Following a channel is an explicit interest — lift its uploads on top
            // of the topic match, so your subs surface even on a quieter topic day.
            let sub = profile.subscribedIDs.contains(item.uploaderChannelID ?? "") ? 0.2 : 0
            let sourceBoost =
                (sources.contains(.saved) ? 0.12 : 0) +
                (sources.contains(.search) ? 0.10 : 0) +
                (sources.contains(.subscription) ? 0.08 : 0) +
                (sources.contains(.exploration) ? 0.03 : 0)
            var s = gated + aff * 0.25 + sub + sourceBoost
            // YouTube's own category is authoritative: if it says News & politics and
            // you don't watch news, bury it regardless of what the title words imply.
            if newsShare < 0.15,
               let cat = enrichment[id]?.category?.lowercased(),
               cat.contains("news") || cat.contains("politic") {
                s *= 0.05
            }
            // "Suggest less": push down anything resembling a thumbs-down, and bury a
            // whole category you've down-voted.
            if !dislikedVectors.isEmpty {
                let dislikeSim = dislikedVectors.map { cosine($0, v) }.max() ?? 0
                s -= 0.6 * max(0, dislikeSim)   // dislike weight: tunable knob
            }
            if !dislikedCategories.isEmpty, let c = category, dislikedCategories.contains(c) {
                s *= 0.2
            }
            return s
        }

        return candidateFeatures
            .map { feature in
                (feature.item, feature.vector.map {
                    score(feature.item, vector: $0, category: feature.category, fit: feature.fit)
                } ?? -1)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    nonisolated static func rankByTopicInBackground(
        _ items: [StreamItem],
        profile: InterestProfile,
        sourcesByID: [String: Set<CandidateSource>] = [:],
        enrichment: [String: VideoSignals] = [:]
    ) async -> [StreamItem] {
        await Task.detached(priority: .userInitiated) {
            rankByTopic(items, profile: profile, sourcesByID: sourcesByID, enrichment: enrichment)
        }.value
    }

    // MARK: Diversity

    /// Keep the opening screen from becoming one channel or one topic, while
    /// preserving the full ranked order after the first window.
    nonisolated static func diversify(_ ranked: [StreamItem],
                                      enrichment: [String: VideoSignals] = [:],
                                      window: Int = 15,
                                      maxPerChannel: Int = 2,
                                      maxPerTopic: Int = 4) -> [StreamItem] {
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
               channelCounts[channel, default: 0] >= maxPerChannel {
                return false
            }
            if let topic = topicKey(for: item, enrichment: enrichment),
               topicCounts[topic, default: 0] >= maxPerTopic {
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
    nonisolated static func rotateRecentlyShown(_ ranked: [StreamItem],
                                                recentTopIDs: Set<String>,
                                                protectedWindow: Int = 8,
                                                insertionIndex: Int = 12) -> [StreamItem] {
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

    nonisolated private static func topicKey(for item: StreamItem,
                                             enrichment: [String: VideoSignals]) -> String? {
        if let id = item.videoID, let signal = enrichment[id] {
            if let topicKey = signal.topicKey { return topicKey }
            if let category = signal.category?.trimmingCharacters(
                in: .whitespacesAndNewlines).lowercased(),
               !category.isEmpty {
                return "yt:\(category)"
            }
        }

        return topicKey(category: nil, text: "\(item.displayTitle) \(item.uploaderName ?? "")")
    }

    nonisolated static func topicKey(category: String?, text rawText: String) -> String? {
        if let category = category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !category.isEmpty {
            return "yt:\(category)"
        }

        let text = rawText.lowercased()
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
