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

    @State private var phase: LoadPhase<[StreamItem]> = .idle
    /// The `loadKey` the current results were built for. Lets us tell a genuine
    /// reload (mode / subscription change) apart from a bare view reappearance.
    @State private var loadedKey: String?

    /// Hide videos already in watch history.
    private var watchedIDs: Set<String> { Set(history.map(\.videoID)) }
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
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
        }
        .refreshable { await load() }
    }

    @ViewBuilder private var emptyState: some View {
        if feedMode.isForYou {
            ContentUnavailableView("Watch something first", systemImage: "sparkles",
                description: Text("Your For You feed is built from your watch history — all on-device."))
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

    /// For You: rank a candidate pool built from your watch history (and feedback),
    /// either Piped-related or our personalized topic match.
    private func loadForYou() async {
        guard !history.isEmpty else { phase = .loaded([]); return }
        let watched = Set(history.map(\.videoID))
        let disliked = Set(feedback.filter { $0.signal < 0 }.map(\.videoID))
        let signals = feedback.map {
            FeedbackSignal(signal: $0.signal, title: $0.title, uploader: $0.uploader,
                           category: $0.category, tags: $0.tags ?? [])
        }
        let engine = RecommendationEngine(app: app)
        let (candidates, frequency) = await engine.candidates(
            from: Array(history.prefix(6)), excluding: watched.union(disliked))

        switch feedMode {
        case .forYouRelated:
            let ranked = RecommendationEngine.rankRelated(
                candidates, frequency: frequency, history: history)
            phase = .loaded(Array(ranked.prefix(40)))
            await prefetch(visible(ranked))
        case .forYouCustom:
            // Instant on-device pass, then upgrade with YouTube category/tags.
            let coarse = RecommendationEngine.rankByTopic(
                candidates, history: history, feedback: signals)
            phase = .loaded(Array(coarse.prefix(40)))
            await prefetch(visible(coarse))
            let refined = await engine.refineWithSignals(
                Array(coarse.prefix(50)), history: history, feedback: signals)
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
