import PipedKit
import SwiftData
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Query(sort: \SearchEntry.lastSearchedAt, order: .reverse) private var searchHistory: [SearchEntry]

    @State private var query = ""
    @State private var phase: LoadPhase<SearchResults> = .idle
    @State private var suggestions: [String] = []
    @State private var suggestTask: Task<Void, Never>?
    /// The query the current results belong to + the `nextpage` cursor for the
    /// next batch. `isLoadingMore` gates the infinite-scroll footer.
    @State private var activeQuery = ""
    @State private var nextPage: String?
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    /// Bumped when a new search starts; stale responses check it and drop out,
    /// so overlapping searches can't race on `phase`/`activeQuery`/pagination.
    @State private var searchGeneration = 0
    /// Set when `query` is changed programmatically (suggestion tap, Siri), so
    /// `.onChange(of: query)` doesn't re-schedule a suggestions fetch for it.
    @State private var suppressSuggestionsOnce = false
    @FocusState private var searchFocused: Bool

    private var historySuggestions: [SearchEntry] {
        let key = SearchEntry.normalize(query)
        let matches =
            key.isEmpty
            ? searchHistory
            : searchHistory.filter {
                $0.query.contains(key) || $0.displayTitle.localizedCaseInsensitiveContains(query)
            }
        return Array(matches.prefix(5))
    }

    private var remoteSuggestions: [String] {
        let historyKeys = Set(historySuggestions.map(\.query))
        return Array(
            suggestions
                .filter { !historyKeys.contains(SearchEntry.normalize($0)) }
                .prefix(5))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.large)
                .navigationDestination(for: String.self) { id in
                    ChannelDetailView(channelID: id)
                }
        }
        .searchable(text: $query, placement: .automatic, prompt: "Search YouTube")
        .searchFocused($searchFocused)
        .searchSuggestions {
            // Only while the field is focused. The system keeps the suggestion
            // list over the content whenever this builder is non-empty and
            // search is active — and recording a successful search into history
            // makes `historySuggestions` match the just-submitted query, which
            // re-presented the list on top of the results (feeling like the
            // search never ran). Gating on focus guarantees results are visible
            // the moment the keyboard drops.
            if searchFocused {
                ForEach(historySuggestions) { entry in
                    Button {
                        selectSearchHistory(entry)
                    } label: {
                        Label(entry.displayTitle, systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(remoteSuggestions, id: \.self) { suggestion in
                    Button {
                        selectSuggestion(suggestion)
                    } label: {
                        Label(suggestion, systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChange(of: query) { _, newValue in
            if suppressSuggestionsOnce {
                suppressSuggestionsOnce = false
                return
            }
            scheduleSuggestions(newValue)
        }
        .onSubmit(of: .search) { submit() }
        .onChange(of: app.searchRetapToken) { _, _ in focusForFreshSearch() }
        .onChange(of: app.instanceGeneration) { _, _ in resetForInstanceChange() }
        .onAppear { applyPendingSearch() }
        .onChange(of: app.pendingSearchQuery) { _, _ in applyPendingSearch() }
    }

    /// Runs a query handed to us by Siri / the "Search Atlas" intent: fill the
    /// field, run it, and clear the request so it doesn't re-fire.
    private func applyPendingSearch() {
        guard let pending = app.pendingSearchQuery,
            !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        app.pendingSearchQuery = nil
        suppressSuggestionsOnce = query != pending
        query = pending
        Task { await runSearch() }
    }

    /// Re-tapping the search tab while already here: pop the keyboard so the
    /// user can start typing immediately. Deliberately NON-destructive — on the
    /// iOS 26 search tab this token bumps for ordinary taps on the tab-bar
    /// search field (TabView re-writes `.search` to the selection binding), so
    /// clearing the query/results here nuked in-progress searches and forced
    /// the user to retype them. The field's clear button covers "start over".
    private func focusForFreshSearch() {
        searchFocused = true
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            idleContent
        case .loading:
            ProgressView()
                .accessibilityLabel("Loading search results")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await runSearch() }
        case .loaded(let results):
            resultsList(results)
        }
    }

    @ViewBuilder private var idleContent: some View {
        if searchHistory.isEmpty {
            ContentUnavailableView(
                "Search", systemImage: "magnifyingglass",
                description: Text("Find videos and channels."))
        } else {
            searchHistoryList
        }
    }

    @ViewBuilder private var searchHistoryList: some View {
        SearchHistoryContent(
            entries: searchHistory,
            horizontalSizeClass: horizontalSizeClass,
            onSelect: selectSearchHistory,
            onDeleteOffsets: deleteSearchHistory,
            onDeleteEntry: deleteSearchHistory,
            onClear: clearSearchHistory)
    }

    @ViewBuilder private func resultsList(_ results: SearchResults) -> some View {
        let videos = app.filteringShorts(results.videos)
        SearchResultsContent(
            results: results,
            videos: videos,
            query: activeQuery,
            horizontalSizeClass: horizontalSizeClass,
            isLoadingMore: isLoadingMore,
            canLoadMore: nextPage != nil,
            loadMoreError: loadMoreError,
            onAppearVideo: { app.prefetchStream($0.videoID) },
            onPlay: { app.play($0) },
            onLoadMore: loadMore,
            onRetryLoadMore: retryLoadMore)
    }

    // MARK: Search + suggestions

    /// Submitting from the keyboard's Search key: drop the keyboard, run it.
    private func submit() {
        hideKeyboard()
        Task { await runSearch() }
    }

    /// Tapping a suggestion fills the field *and* runs the search (and dismisses
    /// the keyboard) — it shouldn't just populate the text box.
    private func selectSuggestion(_ suggestion: String) {
        runSelectedSearch(suggestion)
    }

    private func selectSearchHistory(_ entry: SearchEntry) {
        runSelectedSearch(entry.displayTitle)
    }

    private func runSelectedSearch(_ text: String) {
        suppressSuggestionsOnce = query != text
        query = text
        suggestTask?.cancel()
        suggestions = []
        hideKeyboard()
        Task { await runSearch() }
    }

    private func hideKeyboard() {
        searchFocused = false
    }

    private func runSearch() async {
        suggestTask?.cancel()
        suggestions = []
        searchGeneration += 1
        let generation = searchGeneration
        let instanceGeneration = app.instanceGeneration
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else {
            phase = .idle
            return
        }
        phase = .loading
        nextPage = nil
        loadMoreError = nil
        do {
            let response = try await app.client.searchPage(searchText, filter: "all")
            guard generation == searchGeneration,
                instanceGeneration == app.instanceGeneration
            else { return }
            // Record only successful searches, so failures don't pollute the
            // history list or the For You signal.
            SearchHistoryStore.record(searchText, in: modelContext)
            let items = StreamItemIdentity.firstOccurrences(in: response.items ?? [])
            activeQuery = searchText
            nextPage = normalizedNextPage(response.nextPage)
            loadMoreError = nil
            let channels = items.filter { $0.isChannel }
            let videos = items.filter { $0.isVideo }
            phase = .loaded(SearchResults(channels: channels, videos: videos))
            if let client = try? app.httpClient {
                await ThumbnailPrefetcher.shared.prefetch(
                    videos.prefix(12).map { ThumbnailURL.upgraded($0.thumbnail) },
                    client: client,
                    generation: app.instanceGeneration)
            }
        } catch {
            guard generation == searchGeneration,
                instanceGeneration == app.instanceGeneration
            else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Appends the next page of results, de-duped against what's already shown.
    /// On failure it stops paginating rather than dropping the current results —
    /// except cancellation, which keeps the token so scrolling can retry.
    private func loadMore() async {
        guard let token = nextPage, !isLoadingMore, loadMoreError == nil,
            case .loaded(var results) = phase
        else { return }
        let generation = searchGeneration
        let instanceGeneration = app.instanceGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let response = try await app.client.searchNextPage(
                activeQuery,
                filter: "all",
                nextPage: token)
            guard generation == searchGeneration,
                instanceGeneration == app.instanceGeneration
            else { return }
            var seen = Set((results.channels + results.videos).map(\.id))
            let newItems = StreamItemIdentity.firstOccurrences(
                in: response.items ?? [],
                seenIDs: &seen)
            results.channels.append(contentsOf: newItems.filter { $0.isChannel })
            results.videos.append(contentsOf: newItems.filter { $0.isVideo })
            let newToken = normalizedNextPage(response.nextPage)
            // No-progress guard: a repeated token with no new items would loop.
            nextPage = newItems.isEmpty && newToken == token ? nil : newToken
            loadMoreError = nil
            phase = .loaded(results)
        } catch is CancellationError {
            // Keep the token so a later scroll can retry.
        } catch let error as URLError where error.code == .cancelled {
            // Keep the token so a later scroll can retry.
        } catch {
            guard generation == searchGeneration,
                instanceGeneration == app.instanceGeneration
            else { return }
            loadMoreError = error.localizedDescription
        }
    }

    private func retryLoadMore() async {
        loadMoreError = nil
        await loadMore()
    }

    private func normalizedNextPage(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func scheduleSuggestions(_ value: String) {
        suggestTask?.cancel()
        suggestions = []
        let searchText = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else { return }
        let instanceGeneration = app.instanceGeneration
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let result = (try? await app.client.suggestions(searchText)) ?? []
            guard !Task.isCancelled,
                instanceGeneration == app.instanceGeneration,
                query.trimmingCharacters(in: .whitespacesAndNewlines) == searchText
            else { return }
            suggestions = result
        }
    }

    private func resetForInstanceChange() {
        searchGeneration += 1
        suggestTask?.cancel()
        suggestTask = nil
        suggestions = []
        phase = .idle
        activeQuery = ""
        nextPage = nil
        isLoadingMore = false
        loadMoreError = nil
    }

    private func deleteSearchHistory(_ offsets: IndexSet) {
        for index in offsets {
            SearchHistoryStore.delete(searchHistory[index], in: modelContext)
        }
    }

    private func deleteSearchHistory(_ entry: SearchEntry) {
        SearchHistoryStore.delete(entry, in: modelContext)
    }

    private func clearSearchHistory() {
        SearchHistoryStore.clear(searchHistory, in: modelContext)
    }
}
