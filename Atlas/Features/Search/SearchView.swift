import SwiftUI
import SwiftData
import PipedKit

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSize
    @Query(sort: \SearchEntry.lastSearchedAt, order: .reverse) private var searchHistory: [SearchEntry]

    struct Results { var channels: [StreamItem]; var videos: [StreamItem] }

    @State private var query = ""
    @State private var phase: LoadPhase<Results> = .idle
    @State private var suggestions: [String] = []
    @State private var suggestTask: Task<Void, Never>?
    /// The query the current results belong to + the `nextpage` cursor for the
    /// next batch. `isLoadingMore` gates the infinite-scroll footer.
    @State private var activeQuery = ""
    @State private var nextpage: String?
    @State private var isLoadingMore = false
    /// Bumped when a new search starts; stale responses check it and drop out,
    /// so overlapping searches can't race on `phase`/`activeQuery`/pagination.
    @State private var searchGeneration = 0
    /// Set when `query` is changed programmatically (suggestion tap, Siri), so
    /// `.onChange(of: query)` doesn't re-schedule a suggestions fetch for it.
    @State private var suppressSuggestionsOnce = false
    @FocusState private var searchFocused: Bool

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
                    Button { selectSearchHistory(entry) } label: {
                        Label(entry.displayTitle, systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(remoteSuggestions, id: \.self) { suggestion in
                    Button { selectSuggestion(suggestion) } label: {
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
        .onAppear { applyPendingSearch() }
        .onChange(of: app.pendingSearchQuery) { _, _ in applyPendingSearch() }
    }

    /// Runs a query handed to us by Siri / the "Search Atlas" intent: fill the
    /// field, run it, and clear the request so it doesn't re-fire.
    private func applyPendingSearch() {
        guard let pending = app.pendingSearchQuery,
              !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await runSearch() }
        case .loaded(let results):
            resultsList(results)
        }
    }

    @ViewBuilder private var idleContent: some View {
        if searchHistory.isEmpty {
            ContentUnavailableView("Search", systemImage: "magnifyingglass",
                description: Text("Find videos and channels."))
        } else {
            searchHistoryList
        }
    }

    @ViewBuilder private var searchHistoryList: some View {
        if hSize == .regular {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    searchHistoryHeader
                    LazyVGrid(columns: LibraryGrid.columns(minCardWidth: 280),
                              spacing: LibraryGrid.spacing) {
                        ForEach(searchHistory) { entry in
                            Button { selectSearchHistory(entry) } label: {
                                SearchHistoryRow(entry: entry).libraryCard()
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) { deleteSearchHistory(entry) } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        } else {
            List {
                Section {
                    ForEach(searchHistory) { entry in
                        Button { selectSearchHistory(entry) } label: {
                            SearchHistoryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteSearchHistory)
                } header: {
                    searchHistoryHeader
                        .textCase(nil)
                        .padding(.horizontal, -14)
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var searchHistoryHeader: some View {
        HStack {
            Text("Recent Searches")
                .font(.headline)
            Spacer()
            Button {
                clearSearchHistory()
            } label: {
                Text("Clear")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func resultsList(_ results: Results) -> some View {
        let videos = app.filteringShorts(results.videos)
        if results.channels.isEmpty && videos.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    channelResults(results.channels)
                    if !results.channels.isEmpty {
                        Color.clear.frame(height: 12)
                    }
                    // Then videos.
                    GroupedVideoList(items: videos,
                                     onAppearItem: { app.prefetchStream($0.videoID) }) { app.play($0) }
                        .onScreenVideos(videos)
                    paginationFooter
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
        }
    }

    /// The top matching channels. iPhone shows divider-separated rows; iPad tiles
    /// them into the same adaptive card grid the rest of the library uses.
    @ViewBuilder private func channelResults(_ channels: [StreamItem]) -> some View {
        let top = Array(channels.prefix(3))
        if hSize == .regular {
            LazyVGrid(columns: LibraryGrid.columns(minCardWidth: 320), spacing: LibraryGrid.spacing) {
                ForEach(top) { item in
                    if let id = item.ownChannelID {
                        NavigationLink(value: id) {
                            ChannelResultRow(item: item).libraryCard()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            ForEach(top) { item in
                if let id = item.ownChannelID {
                    NavigationLink(value: id) { ChannelResultRow(item: item) }
                        .buttonStyle(.plain)
                    Divider().padding(.leading, 76)
                }
            }
        }
    }

    /// Infinite scroll: a 1pt sentinel at the end of the list pulls the next
    /// page as it scrolls into view. Re-`id`'d on the result count so it fires
    /// again for each subsequent page while you're still at the bottom.
    @ViewBuilder private var paginationFooter: some View {
        if isLoadingMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else if nextpage != nil, case .loaded(let results) = phase {
            Color.clear
                .frame(height: 1)
                .id(results.videos.count + results.channels.count)
                .onAppear { Task { await loadMore() } }
        }
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
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { phase = .idle; return }
        phase = .loading
        nextpage = nil
        do {
            let res = try await app.client.searchPage(q, filter: "all")
            guard generation == searchGeneration else { return }
            // Record only successful searches, so failures don't pollute the
            // history list or the For You signal.
            SearchHistoryStore.record(q, in: modelContext)
            let all = res.items ?? []
            activeQuery = q
            nextpage = normalizedNextpage(res.nextpage)
            let channels = all.filter { $0.isChannel }
            let videos = all.filter { $0.isVideo }
            phase = .loaded(Results(channels: channels, videos: videos))
            await ThumbnailPrefetcher.shared.prefetch(videos.prefix(12).map { Thumbnail.upgraded($0.thumbnail) })
        } catch {
            guard generation == searchGeneration else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    /// Appends the next page of results, de-duped against what's already shown.
    /// On failure it stops paginating rather than dropping the current results —
    /// except cancellation, which keeps the token so scrolling can retry.
    private func loadMore() async {
        guard let token = nextpage, !isLoadingMore,
              case .loaded(var results) = phase else { return }
        let generation = searchGeneration
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let res = try await app.client.searchNextPage(activeQuery, filter: "all", nextpage: token)
            guard generation == searchGeneration else { return }
            let seen = Set((results.channels + results.videos).map(\.id))
            let fresh = (res.items ?? []).filter { !seen.contains($0.id) }
            results.channels.append(contentsOf: fresh.filter { $0.isChannel })
            results.videos.append(contentsOf: fresh.filter { $0.isVideo })
            let newToken = normalizedNextpage(res.nextpage)
            // No-progress guard: a repeated token with no new items would loop.
            nextpage = fresh.isEmpty && newToken == token ? nil : newToken
            phase = .loaded(results)
        } catch is CancellationError {
            // Keep the token so a later scroll can retry.
        } catch let error as URLError where error.code == .cancelled {
            // Keep the token so a later scroll can retry.
        } catch {
            guard generation == searchGeneration else { return }
            nextpage = nil
        }
    }

    private func normalizedNextpage(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func scheduleSuggestions(_ value: String) {
        suggestTask?.cancel()
        let q = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let result = (try? await app.client.suggestions(q)) ?? []
            guard !Task.isCancelled else { return }
            suggestions = result
        }
    }

    private var historySuggestions: [SearchEntry] {
        let key = SearchEntry.normalize(query)
        let matches = key.isEmpty
            ? searchHistory
            : searchHistory.filter {
                $0.query.contains(key) || $0.displayTitle.localizedCaseInsensitiveContains(query)
            }
        return Array(matches.prefix(5))
    }

    private var remoteSuggestions: [String] {
        let historyKeys = Set(historySuggestions.map(\.query))
        return Array(suggestions
            .filter { !historyKeys.contains(SearchEntry.normalize($0)) }
            .prefix(5))
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

private struct SearchHistoryRow: View {
    let entry: SearchEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.left")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityLabel("Search \(entry.displayTitle)")
    }

    private var subtitle: String {
        entry.count == 1 ? "Searched once" : "\(entry.count) searches"
    }
}

private struct ChannelResultRow: View {
    let item: StreamItem
    var body: some View {
        HStack(spacing: 12) {
            Avatar(url: item.thumbnail ?? item.uploaderAvatar, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).font(.body.weight(.semibold)).lineLimit(1)
                if let meta = metaLine {
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    /// Subscriber count, plus a video count only when the API actually reports one.
    private var metaLine: String? {
        let subs = Format.subscribers(item.subscribers)
        let videos = (item.videos ?? -1) > 0 ? "\(item.videos!) videos" : nil
        let line = Format.metaLine(subs, videos)
        return line.isEmpty ? nil : line
    }
}
