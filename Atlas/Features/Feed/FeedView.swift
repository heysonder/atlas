import PipedKit
import SwiftData
import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @AppStorage(FeedMode.storageKey) private var feedMode: FeedMode = .subscriptions
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
    /// Subscriptions feed: paginates each channel's uploads (the RSS-backed
    /// `feed/unauthenticated` is empty/15-capped on many instances).
    @State private var subsLoader: SubscriptionFeedLoader?
    /// For You: the full ranked list, revealed a window at a time on scroll so the
    /// feed doesn't hard-stop at the first screenful.
    @State private var forYouRanked: [StreamItem] = []
    @State private var forYouShown = forYouInitialWindow
    @State private var loadGeneration = 0
    @State private var forYouSourceTasks: [Task<Void, Never>] = []
    @State private var isLoadingMore = false
    /// Pull-to-refresh support: For You spawns its source tasks and returns, so
    /// `.refreshable` parks here until the refresh's results actually land.
    /// Resumed exactly once (resume-and-nil): at the first apply/fail for its
    /// generation, or immediately when a newer load supersedes it — a stale
    /// continuation is never left hanging.
    @State private var refreshContinuation: CheckedContinuation<Void, Never>?
    /// The `loadGeneration` the pending refresh continuation is waiting on.
    @State private var refreshWaitGeneration: Int?
    /// Highest generation whose load has settled (applied results or failed).
    @State private var settledGeneration = 0
    /// Memoized because playback updates the history query every second.
    @State private var watchedMemo = WatchedIDsMemo()

    private static let forYouInitialWindow = 40
    private static let pageWindow = 20
    private static let forYouInitialResponseTimeout: UInt64 = 8_000_000_000

    /// Videos that count as watched (≥80% seen) — hidden from the feed. Opening
    /// one and bailing early doesn't count, so it stays/reappears until you
    /// actually get through it. Memoized: the history query invalidates every
    /// second during playback, so the set is only rebuilt when the table
    /// meaningfully changes rather than on every body evaluation.
    private var watchedIDs: Set<String> { watchedMemo.ids(for: history) }
    private func unwatched(_ videos: [StreamItem], watchedIDs: Set<String>) -> [StreamItem] {
        videos.filter { item in
            guard let id = item.videoID else { return true }
            return !watchedIDs.contains(id)
        }
    }

    /// What the feed actually shows: unwatched, with Shorts dropped if hidden.
    private func visible(_ videos: [StreamItem], watchedIDs: Set<String>? = nil) -> [StreamItem] {
        let ids = watchedIDs ?? self.watchedIDs
        return app.filteringShorts(unwatched(videos, watchedIDs: ids))
    }

    /// Reload when the mode changes or the subscription set changes.
    private var loadKey: String {
        "\(app.instanceGeneration)|\(feedMode.rawValue)|\(subscriptionKey)|\(forYouSignalKey)"
    }

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
                    let watched = watchedIDs
                    FeedContentView(
                        videos: visible(videos, watchedIDs: watched),
                        shortsLayout: app.shortsLayout,
                        isLoadingMore: isLoadingMore,
                        canLoadMore: canLoadMore,
                        paginationError: feedMode.isForYou ? nil : subsLoader?.paginationError,
                        loadMoreToken: loadMoreToken,
                        onAppearItem: { app.prefetchStream($0.videoID) },
                        onPlay: { app.play($0) },
                        onRefresh: { await load(refreshing: true) },
                        onLoadMore: loadMore,
                        onRetryLoadMore: retryLoadMore)
                case .failed(let message):
                    ErrorState(message: message) { await load() }
                default:
                    VStack(spacing: 12) {
                        ProgressView()
                            .accessibilityLabel(
                                feedMode.isForYou
                                    ? "Loading personalized videos" : "Loading home videos")
                        Text(
                            feedMode.isForYou
                                ? "Personalizing your content…" : "Loading subscriptions…"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(feedMode.isForYou ? "For You" : "Home")
            .navigationDestination(for: String.self) { id in
                ChannelDetailView(channelID: id)
            }
        }
        .task(id: loadKey) { await loadIfNeeded() }
    }

    private var canLoadMore: Bool {
        if feedMode.isForYou { return forYouShown < forYouRanked.count }
        return subsLoader?.hasMore ?? false
    }

    /// Changes whenever a page lands, so the sentinel re-fires while still at the
    /// bottom instead of latching after the first page.
    private var loadMoreToken: String {
        feedMode.isForYou ? "fy-\(forYouShown)" : "sub-\(subsLoader?.items.count ?? 0)"
    }

    private func loadMore() async {
        guard !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        if feedMode.isForYou {
            forYouShown = min(forYouShown + Self.pageWindow, forYouRanked.count)
            phase = .loaded(Array(forYouRanked.prefix(forYouShown)))
        } else if let loader = subsLoader, loader.hasMore {
            let generation = loadGeneration
            let requestKey = loadKey
            await loader.loadMore()
            guard subsLoader === loader,
                loader.instanceGeneration == app.instanceGeneration,
                isCurrentLoad(requestKey: requestKey, generation: generation)
            else { return }
            phase = .loaded(StreamItemIdentity.firstOccurrences(in: loader.items))
        }
    }

    private func retryLoadMore() async {
        guard !feedMode.isForYou, !isLoadingMore, let loader = subsLoader else { return }
        let generation = loadGeneration
        let requestKey = loadKey
        isLoadingMore = true
        defer { isLoadingMore = false }
        await loader.retryLoadMore()
        guard subsLoader === loader,
            loader.instanceGeneration == app.instanceGeneration,
            isCurrentLoad(requestKey: requestKey, generation: generation)
        else { return }
        phase = .loaded(StreamItemIdentity.firstOccurrences(in: loader.items))
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
        return
            searchEntries
            .filter { $0.lastSearchedAt >= cutoff }
            .prefix(15)
            .map {
                SearchSignal(
                    query: $0.query, count: $0.count,
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
        cancelForYouSourceTasks()
        // A new load supersedes whatever a previous refresh was waiting on —
        // resolve that gesture now instead of leaving it hung on results that
        // will never apply.
        resumeRefreshContinuation()
        let requestKey = loadKey
        loadGeneration += 1
        let generation = loadGeneration
        // Blank to a spinner only for a genuinely new feed. A same-key refresh
        // (pull-to-refresh) keeps the current results on screen while it reloads.
        let keepingResults: Bool
        if case .loaded = phase, loadedKey == requestKey { keepingResults = true } else { keepingResults = false }
        if !keepingResults { phase = .loading }

        if feedMode.isForYou {
            let recentTopIDs = refreshing ? Set(lastForYouTopIDs) : []
            await loadForYou(
                recentTopIDs: recentTopIDs,
                requestKey: requestKey,
                generation: generation)
            // `loadForYou` returns once its source tasks are spawned. Keep the
            // pull-to-refresh spinner up until this generation's results apply
            // (or the load fails); Subscriptions below already awaits inline.
            if refreshing { await waitUntilSettled(generation) }
        } else {
            await loadSubscriptions(requestKey: requestKey, generation: generation)
        }
        if isCurrentLoad(requestKey: requestKey, generation: generation),
            case .loaded = phase
        {
            loadedKey = requestKey
        }
    }

    private func loadSubscriptions(requestKey: String, generation: Int) async {
        let ids = subscriptions.map(\.channelID)
        guard !ids.isEmpty else {
            await loadDiscovery(requestKey: requestKey, generation: generation)
            return
        }
        do {
            let loader = SubscriptionFeedLoader(
                client: try app.client,
                channelIDs: ids,
                instanceGeneration: app.instanceGeneration)
            await loader.loadInitial()
            guard isCurrentLoad(requestKey: requestKey, generation: generation) else { return }
            subsLoader = loader
            // If channel aggregation came back empty (e.g. a degraded instance),
            // fall back to trending so the tab isn't blank.
            if loader.items.isEmpty {
                await loadDiscovery(requestKey: requestKey, generation: generation)
            } else {
                phase = .loaded(StreamItemIdentity.firstOccurrences(in: loader.items))
                await prefetch(visible(loader.items))
            }
        } catch {
            guard isCurrentLoad(requestKey: requestKey, generation: generation) else { return }
            applyLoadFailure(error.localizedDescription, requestKey: requestKey)
        }
    }

    private func loadDiscovery(
        requestKey: String? = nil, generation: Int? = nil,
        collector: ForYouCandidateCollector? = nil
    ) async {
        do {
            let videos = try await app.client.trending(region: discoveryRegion)
            // Re-check after the await: a slow personalized source may have
            // rendered while trending was in flight — never clobber it with
            // generic content. (The reverse order stays allowed: personalized
            // results landing after trending still upgrade via `applyForYou`.)
            guard canApplyLoad(requestKey: requestKey, generation: generation),
                collector?.didPresentPersonalized != true
            else { return }
            let uniqueVideos = StreamItemIdentity.firstOccurrences(in: videos)
            phase = .loaded(uniqueVideos)
            if let requestKey { loadedKey = requestKey }
            if let generation { settleLoad(generation: generation) }
            await prefetch(visible(uniqueVideos))
        } catch {
            guard canApplyLoad(requestKey: requestKey, generation: generation),
                collector?.didPresentPersonalized != true
            else { return }
            applyLoadFailure(error.localizedDescription, requestKey: requestKey)
            if let generation { settleLoad(generation: generation) }
        }
    }

    /// A same-key reload keeps usable results on screen when the replacement
    /// request fails. Initial loads and context-changing loads still surface the
    /// full-page error because they have no matching content to preserve.
    private func applyLoadFailure(_ message: String, requestKey: String?) {
        if let requestKey, loadedKey == requestKey, case .loaded = phase { return }
        phase = .failed(message)
    }

    /// For You: rank a candidate pool drawn from your watch history, searches,
    /// saves and subscriptions (plus feedback) — either Piped-related or our
    /// personalized topic match.
    private func loadForYou(
        recentTopIDs: Set<String> = [],
        requestKey: String,
        generation: Int
    ) async {
        forYouShown = Self.forYouInitialWindow
        subsLoader = nil
        // Exclusion must consider every dislike; profile construction below is
        // bounded before transformation to the builder's existing 200-item cap.
        let disliked = Set(feedback.filter { $0.signal < 0 }.map(\.videoID))
        let exclude = watchedIDs.union(disliked)
        let signals = feedback.prefix(200).map {
            FeedbackSignal(
                signal: $0.signal, title: $0.title, uploader: $0.uploader,
                category: $0.category, tags: $0.tags ?? [])
        }
        // Personalization signals beyond watch history. Pull the Sendable bits the
        // concurrent seeds need (plain strings) out here, so the child tasks below
        // never capture the non-Sendable @Model arrays themselves. `saved` is
        // still [PlaylistVideo]: it is consumed synchronously by the profile
        // build below and never crosses into a child task.
        let saved = Array(savedVideos.prefix(40))
        let searches = recentSearches
        // Channels you follow — the most explicit interest signal. Both a candidate
        // source (their recent uploads) and a ranking boost below.
        let subIDs = subscriptions.map(\.channelID)
        let subscribedIDs = Set(subIDs)
        let profile = RecommendationProfileStore.loadOrBuild(
            in: modelContext, history: Array(history.prefix(200)), feedback: signals, saved: saved,
            searches: searches, subscribedIDs: subscribedIDs)
        let seedQueries = profile.candidateSearchQueries
        let savedSeedIDs = profile.savedSeedIDs
        let relatedSeeds = profile.relatedSeeds
        let explorationSeeds = profile.explorationSeeds
        guard
            !seedQueries.isEmpty || !savedSeedIDs.isEmpty || !subIDs.isEmpty
                || !relatedSeeds.isEmpty || !explorationSeeds.isEmpty
        else {
            await loadDiscovery(requestKey: requestKey, generation: generation)
            return
        }

        let engine = RecommendationEngine(app: app, modelContext: modelContext)
        let requestedMode = feedMode
        let collector = ForYouCandidateCollector(
            totalSources: sourceCount(
                seedQueries: seedQueries,
                savedSeedIDs: savedSeedIDs,
                subIDs: subIDs,
                relatedSeeds: relatedSeeds,
                explorationSeeds: explorationSeeds))
        var tasks: [Task<Void, Never>] = []

        if !seedQueries.isEmpty {
            tasks.append(
                Task { @MainActor in
                    let items = await engine.searchCandidates(seedQueries, excluding: exclude)
                    await receiveForYouCandidate(
                        .search(items),
                        collector: collector,
                        engine: engine,
                        profile: profile,
                        requestedMode: requestedMode,
                        recentTopIDs: recentTopIDs,
                        requestKey: requestKey,
                        generation: generation)
                })
        }
        if !savedSeedIDs.isEmpty {
            tasks.append(
                Task { @MainActor in
                    let items = await engine.playlistCandidates(savedSeedIDs, excluding: exclude)
                    await receiveForYouCandidate(
                        .saved(items),
                        collector: collector,
                        engine: engine,
                        profile: profile,
                        requestedMode: requestedMode,
                        recentTopIDs: recentTopIDs,
                        requestKey: requestKey,
                        generation: generation)
                })
        }
        if !subIDs.isEmpty {
            tasks.append(
                Task { @MainActor in
                    let items = await engine.subscriptionCandidates(subIDs, excluding: exclude)
                    await receiveForYouCandidate(
                        .subscription(items),
                        collector: collector,
                        engine: engine,
                        profile: profile,
                        requestedMode: requestedMode,
                        recentTopIDs: recentTopIDs,
                        requestKey: requestKey,
                        generation: generation)
                })
        }
        if !relatedSeeds.isEmpty {
            tasks.append(
                Task { @MainActor in
                    let result = await engine.candidates(from: relatedSeeds, excluding: exclude)
                    await receiveForYouCandidate(
                        .related(result.items, result.frequency),
                        collector: collector,
                        engine: engine,
                        profile: profile,
                        requestedMode: requestedMode,
                        recentTopIDs: recentTopIDs,
                        requestKey: requestKey,
                        generation: generation)
                })
        }
        if !explorationSeeds.isEmpty {
            tasks.append(
                Task { @MainActor in
                    let result = await engine.candidates(from: explorationSeeds, excluding: exclude)
                    await receiveForYouCandidate(
                        .exploration(result.items, result.frequency),
                        collector: collector,
                        engine: engine,
                        profile: profile,
                        requestedMode: requestedMode,
                        recentTopIDs: recentTopIDs,
                        requestKey: requestKey,
                        generation: generation)
                })
        }

        tasks.append(
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: Self.forYouInitialResponseTimeout)
                guard !Task.isCancelled,
                    isCurrentLoad(requestKey: requestKey, generation: generation),
                    !collector.didPresentPersonalized,
                    !collector.didStartDiscovery
                else { return }
                collector.didStartDiscovery = true
                await loadDiscovery(
                    requestKey: requestKey, generation: generation,
                    collector: collector)
            })
        forYouSourceTasks = tasks
    }

    private func sourceCount(
        seedQueries: [String],
        savedSeedIDs: [String],
        subIDs: [String],
        relatedSeeds: [HistorySignal],
        explorationSeeds: [HistorySignal]
    ) -> Int {
        [
            !seedQueries.isEmpty,
            !savedSeedIDs.isEmpty,
            !subIDs.isEmpty,
            !relatedSeeds.isEmpty,
            !explorationSeeds.isEmpty,
        ].filter { $0 }.count
    }

    private func receiveForYouCandidate(
        _ result: ForYouCandidateResult,
        collector: ForYouCandidateCollector,
        engine: RecommendationEngine,
        profile: InterestProfile,
        requestedMode: FeedMode,
        recentTopIDs: Set<String>,
        requestKey: String,
        generation: Int
    ) async {
        guard !Task.isCancelled,
            isCurrentLoad(requestKey: requestKey, generation: generation)
        else { return }
        collector.apply(result)
        let pool = collector.pool
        guard !pool.items.isEmpty else {
            if collector.isComplete, !collector.didStartDiscovery {
                collector.didStartDiscovery = true
                await loadDiscovery(
                    requestKey: requestKey, generation: generation,
                    collector: collector)
            }
            return
        }

        let shouldRender = !collector.didPresentPersonalized || collector.isComplete
        guard shouldRender else { return }
        let refine = collector.isComplete && requestedMode.isPersonalized
        collector.didPresentPersonalized = true
        collector.renderRevision += 1
        let renderRevision = collector.renderRevision
        await renderForYou(
            pool: pool,
            engine: engine,
            profile: profile,
            collector: collector,
            renderRevision: renderRevision,
            requestedMode: requestedMode,
            recentTopIDs: recentTopIDs,
            requestKey: requestKey,
            generation: generation,
            refine: refine)
    }

    private func renderForYou(
        pool: CandidatePool,
        engine: RecommendationEngine,
        profile: InterestProfile,
        collector: ForYouCandidateCollector,
        renderRevision: Int,
        requestedMode: FeedMode,
        recentTopIDs: Set<String>,
        requestKey: String,
        generation: Int,
        refine: Bool
    ) async {
        switch requestedMode {
        case .forYouRelated:
            let ranked = RecommendationEngine.rankRelated(pool, profile: profile)
            let rotated = RecommendationEngine.rotateRecentlyShown(
                ranked, recentTopIDs: recentTopIDs)
            await applyForYou(
                rotated,
                collector: collector,
                renderRevision: renderRevision,
                requestKey: requestKey,
                generation: generation)
        case .forYouCustom:
            let coarse = await RecommendationEngine.rankByTopicInBackground(
                pool.items, profile: profile, sourcesByID: pool.sourcesByID)
            let diverseCoarse = RecommendationEngine.diversify(coarse)
            let rotatedCoarse = RecommendationEngine.rotateRecentlyShown(
                diverseCoarse, recentTopIDs: recentTopIDs)
            await applyForYou(
                rotatedCoarse,
                collector: collector,
                renderRevision: renderRevision,
                requestKey: requestKey,
                generation: generation)
            guard refine,
                isCurrentLoad(requestKey: requestKey, generation: generation)
            else { return }
            let refineHead = Array(coarse.prefix(50))  // per-video /streams budget — tunable knob
            let refined = await engine.refineWithSignals(
                refineHead, profile: profile, sourcesByID: pool.sourcesByID)
            // Refinement only re-ranks the head; keep the un-refined coarse tail
            // (deduped) so the ranked list never shrinks under a scrolled user.
            let refinedIDs = Set(refined.map { $0.videoID ?? $0.id })
            let upgraded =
                refined
                + coarse.dropFirst(refineHead.count).filter {
                    !refinedIDs.contains($0.videoID ?? $0.id)
                }
            let rotatedRefined = RecommendationEngine.rotateRecentlyShown(
                upgraded, recentTopIDs: recentTopIDs)
            await applyForYou(
                rotatedRefined,
                collector: collector,
                renderRevision: renderRevision,
                requestKey: requestKey,
                generation: generation)
        case .subscriptions:
            break
        }
    }

    private func applyForYou(
        _ ranked: [StreamItem],
        collector: ForYouCandidateCollector,
        renderRevision: Int,
        requestKey: String,
        generation: Int
    ) async {
        guard isCurrentLoad(requestKey: requestKey, generation: generation),
            collector.renderRevision == renderRevision
        else { return }
        presentForYou(ranked)
        rememberForYouTop(ranked)
        loadedKey = requestKey
        settleLoad(generation: generation)
        await prefetch(visible(ranked))
    }

    private func cancelForYouSourceTasks() {
        forYouSourceTasks.forEach { $0.cancel() }
        forYouSourceTasks = []
    }

    // MARK: Refresh settling

    /// Parks a pull-to-refresh until `settleLoad` fires for `generation` (or a
    /// newer one). No-op when the load was already superseded, or when it
    /// settled synchronously before we got here (e.g. the no-seeds path applies
    /// discovery inside `loadForYou`).
    private func waitUntilSettled(_ generation: Int) async {
        guard loadGeneration == generation, settledGeneration < generation else { return }
        await withCheckedContinuation { continuation in
            refreshContinuation = continuation
            refreshWaitGeneration = generation
        }
    }

    /// Marks `generation`'s load as landed — first successful apply or terminal
    /// failure — and releases a refresh waiting on it. Later apply passes for
    /// the same generation (e.g. the refine re-rank) are harmless no-ops.
    private func settleLoad(generation: Int) {
        settledGeneration = max(settledGeneration, generation)
        if let waiting = refreshWaitGeneration, waiting <= generation {
            resumeRefreshContinuation()
        }
    }

    /// Resume-and-nil so the continuation can only ever fire once.
    private func resumeRefreshContinuation() {
        refreshWaitGeneration = nil
        refreshContinuation?.resume()
        refreshContinuation = nil
    }

    private func isCurrentLoad(requestKey: String, generation: Int) -> Bool {
        loadKey == requestKey && loadGeneration == generation
    }

    private func canApplyLoad(requestKey: String?, generation: Int?) -> Bool {
        guard let requestKey, let generation else { return true }
        return isCurrentLoad(requestKey: requestKey, generation: generation)
    }

    /// Stores the full ranked list and shows the current reveal window. The
    /// `paginationFooter` widens `forYouShown` as the user scrolls.
    private func presentForYou(_ ranked: [StreamItem]) {
        let uniqueRanked = StreamItemIdentity.firstOccurrences(in: ranked)
        forYouRanked = uniqueRanked
        phase = .loaded(Array(uniqueRanked.prefix(forYouShown)))
    }

    private func rememberForYouTop(_ videos: [StreamItem]) {
        lastForYouTopIDs = visible(videos).prefix(8).compactMap(\.videoID)
    }

    private func prefetch(_ videos: [StreamItem]) async {
        guard let client = try? app.httpClient else { return }
        await ThumbnailPrefetcher.shared.prefetch(
            videos.prefix(12).map { ThumbnailURL.upgraded($0.thumbnail) },
            client: client,
            generation: app.instanceGeneration)
    }
}
