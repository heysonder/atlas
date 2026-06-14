import SwiftUI
import SwiftData
import PipedKit

struct FeedView: View {
    @Environment(AppModel.self) private var app
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

    /// The empty-state gate depends on which data source the mode draws from.
    private var isEmptyForMode: Bool {
        feedMode.isForYou ? history.isEmpty : subscriptions.isEmpty
    }
    /// Reload when the mode changes or the subscription set changes.
    private var loadKey: String { "\(feedMode.rawValue)|\(subscriptionKey)" }

    var body: some View {
        NavigationStack {
            Group {
                if isEmptyForMode {
                    emptyState
                } else {
                    switch phase {
                    case .loaded(let videos):
                        feedList(visible(videos))
                    case .failed(let message):
                        ErrorState(message: message) { await load() }
                    default:
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
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
        .refreshable { await load() }
    }

    @ViewBuilder private var emptyState: some View {
        if feedMode.isForYou {
            ContentUnavailableView("Watch something first", systemImage: "sparkles",
                description: Text("Your For You feed learns from what you watch, search, and save — all on-device."))
        } else {
            ContentUnavailableView {
                Label("No subscriptions yet", systemImage: "play.rectangle.on.rectangle")
            } description: {
                Text("Search for a channel and subscribe to fill your feed.")
            } actions: {
                Button("Search") { app.selectedTab = .search }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var subscriptionKey: String {
        subscriptions.map(\.channelID).joined(separator: ",")
    }

    /// Recent searches used as a For You signal — windowed so stale intent ages
    /// out, capped so the ranking math stays cheap. Newest first.
    private var recentSearches: [String] {
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        return searchEntries.filter { $0.lastSearchedAt >= cutoff }.prefix(15).map(\.query)
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

    private func load() async {
        // Blank to a spinner only for a genuinely new feed. A same-key refresh
        // (pull-to-refresh) keeps the current results on screen while it reloads.
        let keepingResults: Bool
        if case .loaded = phase, loadedKey == loadKey { keepingResults = true } else { keepingResults = false }
        if !keepingResults { phase = .loading }

        if feedMode.isForYou {
            await loadForYou()
        } else {
            await loadSubscriptions()
        }
        if case .loaded = phase { loadedKey = loadKey }
    }

    private func loadSubscriptions() async {
        let ids = subscriptions.map(\.channelID)
        guard !ids.isEmpty else { phase = .loaded([]); return }
        do {
            let videos = try await app.client.feed(channelIDs: ids)
            phase = .loaded(videos)
            await prefetch(visible(videos))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// For You: rank a candidate pool drawn from your watch history, searches,
    /// saves and subscriptions (plus feedback) — either Piped-related or our
    /// personalized topic match.
    private func loadForYou() async {
        guard !history.isEmpty else { phase = .loaded([]); return }
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
        let queries = recentSearches
        let seedQueries = Array(queries.prefix(3))
        let savedSeedIDs = saved.prefix(6).map(\.videoID)
        // Channels you follow — the most explicit interest signal. Both a candidate
        // source (their recent uploads) and a ranking boost below.
        let subIDs = subscriptions.map(\.channelID)
        let subscribedIDs = Set(subIDs)

        let engine = RecommendationEngine(app: app)
        // Kick off the search/playlist/subscription seeds first, then await the
        // history pass directly — they all overlap their network I/O on the main
        // actor, so total latency is the slowest source, not the sum.
        async let searched = engine.searchCandidates(seedQueries, excluding: exclude)
        async let savedSeeds = engine.playlistCandidates(savedSeedIDs, excluding: exclude)
        async let subbed = engine.subscriptionCandidates(subIDs, excluding: exclude)
        let (historyCandidates, frequency) = await engine.candidates(
            from: Array(history.prefix(6)), excluding: exclude)
        let extras = await searched + savedSeeds + subbed

        // Merge into one pool, de-duped by video ID. History candidates keep their
        // place (and frequency count); search/playlist/subscription seeds fill in
        // behind them.
        var candidates = historyCandidates
        var seen = Set(historyCandidates.compactMap(\.videoID))
        for item in extras {
            guard let id = item.videoID, !seen.contains(id) else { continue }
            seen.insert(id)
            candidates.append(item)
        }

        switch feedMode {
        case .forYouRelated:
            let ranked = RecommendationEngine.rankRelated(
                candidates, frequency: frequency, history: history, saved: saved,
                subscribedIDs: subscribedIDs)
            phase = .loaded(Array(ranked.prefix(40)))
            await prefetch(visible(ranked))
        case .forYouCustom:
            // Instant on-device pass, then upgrade with YouTube category/tags.
            let coarse = RecommendationEngine.rankByTopic(
                candidates, history: history, feedback: signals, saved: saved,
                searches: queries, subscribedIDs: subscribedIDs)
            phase = .loaded(Array(coarse.prefix(40)))
            await prefetch(visible(coarse))
            let refined = await engine.refineWithSignals(
                Array(coarse.prefix(50)), history: history, feedback: signals,
                saved: saved, searches: queries, subscribedIDs: subscribedIDs)
            phase = .loaded(Array(refined.prefix(40)))
            await prefetch(visible(refined))
        case .subscriptions:
            break
        }
    }

    private func prefetch(_ videos: [StreamItem]) async {
        await ThumbnailPrefetcher.shared.prefetch(
            videos.prefix(12).map { Thumbnail.upgraded($0.thumbnail) })
    }
}
