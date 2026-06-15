import SwiftUI
import SwiftData
import PipedKit

struct FeedView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @AppStorage("feedMode") private var feedMode: FeedMode = .subscriptions
    @Query(sort: \SubscribedChannel.subscribedAt, order: .reverse)
    private var subscriptions: [SubscribedChannel]
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]
    @Query private var feedback: [Feedback]
    @Query(sort: \PlaylistVideo.addedAt, order: .reverse) private var savedVideos: [PlaylistVideo]
    @Query(sort: \SearchEntry.lastSearchedAt, order: .reverse) private var searchEntries: [SearchEntry]

    @State private var phase: LoadPhase<[StreamItem]> = .idle
    /// The `loadKey` the current results were built for. Lets us tell a genuine
    /// reload (mode / subscription change) apart from a bare view reappearance.
    @State private var loadedKey: String?
    /// Top For You items from the last successful render. Pull-to-refresh softly
    /// rotates these down so refresh can reveal the next good candidates.
    @State private var lastForYouTopIDs: [String] = []

    /// Videos that count as watched (≥80% seen) — hidden from the feed. Opening
    /// one and bailing early doesn't count, so it stays/reappears until you
    /// actually get through it.
    private var watchedIDs: Set<String> { Set(history.filter(\.isWatched).map(\.videoID)) }
    private func unwatched(_ videos: [StreamItem]) -> [StreamItem] {
        videos.filter { item in
            guard let id = item.videoID else { return true }
            return !watchedIDs.contains(id)
        }
    }

    /// What the feed actually shows: unwatched, with Shorts dropped if hidden.
    private func visible(_ videos: [StreamItem]) -> [StreamItem] {
        app.filteringShorts(unwatched(videos))
    }

    /// Reload when the mode changes or the subscription set changes.
    private var loadKey: String { "\(feedMode.rawValue)|\(subscriptionKey)|\(forYouSignalKey)" }

    /// A coarse For You key: cold-start discovery should upgrade to personalized
    /// content once the user creates their first meaningful local signal, without
    /// forcing a slow recommender reload after every later watch.
    private var forYouSignalKey: String {
        guard feedMode.isForYou else { return "subscriptions" }
        return hasForYouSignals ? "seeded" : "cold"
    }

    private var hasForYouSignals: Bool {
        !history.isEmpty || !subscriptions.isEmpty || !savedVideos.isEmpty || !recentSearches.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loaded(let videos):
                    feedList(visible(videos))
                case .failed(let message):
                    ErrorState(message: message) { await load() }
                default:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(feedMode.isForYou ? "For You" : "Home")
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
        }
        .task(id: loadKey) { await loadIfNeeded() }
    }

    private func feedList(_ videos: [StreamItem]) -> some View {
        ScrollView {
            if videos.isEmpty {
                ContentUnavailableView("You're all caught up", systemImage: "checkmark.circle",
                    description: Text("Nothing new to show right now — pull to refresh."))
                    .padding(.top, 60)
            } else {
                GroupedVideoList(items: videos,
                                 shortsLayout: app.shortsLayout,
                                 onAppearItem: { app.prefetchStream($0.videoID) }) { app.play($0) }
                    .onScreenVideos(videos)
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
        .refreshable { await load(refreshing: true) }
    }

    private var subscriptionKey: String {
        subscriptions.map(\.channelID).joined(separator: ",")
    }

    private var discoveryRegion: String {
        Locale.autoupdatingCurrent.region?.identifier ?? "US"
    }

    /// Recent searches used as a For You signal — windowed so stale intent ages
    /// out, capped so the ranking math stays cheap. Repeated searches carry more
    /// weight through `SearchSignal`.
    private var recentSearches: [SearchSignal] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        return searchEntries
            .filter { $0.lastSearchedAt >= cutoff }
            .prefix(15)
            .map {
                SearchSignal(query: $0.query, count: $0.count,
                             lastSearchedAt: $0.lastSearchedAt, now: now)
            }
    }

    /// `.task(id:)` re-runs every time this view reappears — and because the
    /// player is a fullscreen modal, returning from a video counts as a reappear.
    /// Rebuilding (especially For You) is a slow, multi-request network pass, so
    /// skip it when we already have results for the current mode + subscriptions.
    /// The video you just watched still drops off on its own via `unwatched()`.
    /// A real rebuild happens on a mode/subscription change or pull-to-refresh.
    private func loadIfNeeded() async {
        if loadedKey == loadKey, case .loaded = phase { return }
        await load()
    }

    private func load(refreshing: Bool = false) async {
        // Blank to a spinner only for a genuinely new feed. A same-key refresh
        // (pull-to-refresh) keeps the current results on screen while it reloads.
        let keepingResults: Bool
        if case .loaded = phase, loadedKey == loadKey { keepingResults = true } else { keepingResults = false }
        if !keepingResults { phase = .loading }

        if feedMode.isForYou {
            let recentTopIDs = refreshing ? Set(lastForYouTopIDs) : []
            await loadForYou(recentTopIDs: recentTopIDs)
        } else {
            await loadSubscriptions()
        }
        if case .loaded = phase { loadedKey = loadKey }
    }

    private func loadSubscriptions() async {
        let ids = subscriptions.map(\.channelID)
        guard !ids.isEmpty else {
            await loadDiscovery()
            return
        }
        do {
            let videos = try await app.client.feed(channelIDs: ids)
            phase = .loaded(videos)
            await prefetch(visible(videos))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func loadDiscovery() async {
        do {
            let videos = try await app.client.trending(region: discoveryRegion)
            phase = .loaded(videos)
            await prefetch(visible(videos))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// For You: rank a candidate pool drawn from your watch history, searches,
    /// saves and subscriptions (plus feedback) — either Piped-related or our
    /// personalized topic match.
    private func loadForYou(recentTopIDs: Set<String> = []) async {
        let disliked = Set(feedback.filter { $0.signal < 0 }.map(\.videoID))
        let exclude = watchedIDs.union(disliked)
        let signals = feedback.map {
            FeedbackSignal(signal: $0.signal, title: $0.title, uploader: $0.uploader,
                           category: $0.category, tags: $0.tags ?? [])
        }
        // Personalization signals beyond watch history. Pull the Sendable bits the
        // concurrent seeds need (plain strings) out here, so the child tasks below
        // never capture the non-Sendable @Model arrays themselves.
        let saved = Array(savedVideos.prefix(40))
        let searches = recentSearches
        // Channels you follow — the most explicit interest signal. Both a candidate
        // source (their recent uploads) and a ranking boost below.
        let subIDs = subscriptions.map(\.channelID)
        let subscribedIDs = Set(subIDs)
        let profile = RecommendationProfileStore.loadOrBuild(
            in: modelContext, history: history, feedback: signals, saved: saved,
            searches: searches, subscribedIDs: subscribedIDs)
        let seedQueries = profile.candidateSearchQueries
        let savedSeedIDs = profile.savedSeedIDs
        let relatedSeeds = profile.relatedSeeds
        let explorationSeeds = profile.explorationSeeds
        guard !seedQueries.isEmpty || !savedSeedIDs.isEmpty || !subIDs.isEmpty
                || !relatedSeeds.isEmpty || !explorationSeeds.isEmpty else {
            await loadDiscovery()
            return
        }

        let engine = RecommendationEngine(app: app, modelContext: modelContext)
        // Kick off all independent sources together. Source quotas below keep any
        // one source from flooding the personalized pool.
        async let searched = engine.searchCandidates(seedQueries, excluding: exclude)
        async let savedSeeds = engine.playlistCandidates(savedSeedIDs, excluding: exclude)
        async let subbed = engine.subscriptionCandidates(subIDs, excluding: exclude)
        let (historyCandidates, frequency) = await engine.candidates(
            from: relatedSeeds, excluding: exclude)
        let (explorationCandidates, explorationFrequency) = await engine.candidates(
            from: explorationSeeds, excluding: exclude)
        let searchCandidates = await searched
        let savedCandidates = await savedSeeds
        let subscriptionCandidates = await subbed

        let pool = RecommendationEngine.mergeCandidateSources([
            CandidateSourceBucket(source: .subscription, items: subscriptionCandidates, limit: 18),
            CandidateSourceBucket(source: .related, items: historyCandidates,
                                  frequency: frequency, limit: 24),
            CandidateSourceBucket(source: .saved, items: savedCandidates, limit: 12),
            CandidateSourceBucket(source: .search, items: searchCandidates, limit: 12),
            CandidateSourceBucket(source: .exploration, items: explorationCandidates,
                                  frequency: explorationFrequency, limit: 6),
        ])
        guard !pool.items.isEmpty else {
            await loadDiscovery()
            return
        }

        switch feedMode {
        case .forYouRelated:
            let ranked = RecommendationEngine.rankRelated(pool, profile: profile)
            let rotated = RecommendationEngine.rotateRecentlyShown(
                ranked, recentTopIDs: recentTopIDs)
            phase = .loaded(Array(rotated.prefix(40)))
            rememberForYouTop(rotated)
            await prefetch(visible(rotated))
        case .forYouCustom:
            // Instant on-device pass, then upgrade with YouTube category/tags.
            let coarse = RecommendationEngine.rankByTopic(
                pool.items, profile: profile, sourcesByID: pool.sourcesByID)
            let diverseCoarse = RecommendationEngine.diversify(coarse)
            let rotatedCoarse = RecommendationEngine.rotateRecentlyShown(
                diverseCoarse, recentTopIDs: recentTopIDs)
            phase = .loaded(Array(rotatedCoarse.prefix(40)))
            rememberForYouTop(rotatedCoarse)
            await prefetch(visible(rotatedCoarse))
            let refined = await engine.refineWithSignals(
                Array(coarse.prefix(50)), profile: profile, sourcesByID: pool.sourcesByID)
            let rotatedRefined = RecommendationEngine.rotateRecentlyShown(
                refined, recentTopIDs: recentTopIDs)
            phase = .loaded(Array(rotatedRefined.prefix(40)))
            rememberForYouTop(rotatedRefined)
            await prefetch(visible(rotatedRefined))
        case .subscriptions:
            break
        }
    }

    private func rememberForYouTop(_ videos: [StreamItem]) {
        lastForYouTopIDs = visible(videos).prefix(8).compactMap(\.videoID)
    }

    private func prefetch(_ videos: [StreamItem]) async {
        await ThumbnailPrefetcher.shared.prefetch(
            videos.prefix(12).map { Thumbnail.upgraded($0.thumbnail) })
    }
}
