import SwiftUI
import SwiftData
import UIKit
import PipedKit

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext

    struct Results { var channels: [StreamItem]; var videos: [StreamItem] }

    @State private var query = ""
    @State private var phase: LoadPhase<Results> = .idle
    @State private var suggestions: [String] = []
    @State private var suggestTask: Task<Void, Never>?
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
            ForEach(suggestions, id: \.self) { suggestion in
                Button { selectSuggestion(suggestion) } label: {
                    Label(suggestion, systemImage: "magnifyingglass")
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: query) { _, newValue in scheduleSuggestions(newValue) }
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
        query = pending
        Task { await runSearch() }
    }

    /// Re-tapping the search tab while already here: clear any existing query
    /// and pop the keyboard so the user can start typing immediately.
    private func focusForFreshSearch() {
        suggestTask?.cancel()
        suggestions = []
        query = ""
        phase = .idle
        searchFocused = true
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .idle:
            ContentUnavailableView("Search", systemImage: "magnifyingglass",
                description: Text("Find videos and channels."))
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorState(message: message) { await runSearch() }
        case .loaded(let results):
            resultsList(results)
        }
    }

    @ViewBuilder private func resultsList(_ results: Results) -> some View {
        let videos = app.filteringShorts(results.videos)
        if results.channels.isEmpty && videos.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Matching channels first.
                    ForEach(results.channels.prefix(3)) { item in
                        if let id = item.ownChannelID {
                            NavigationLink(value: id) { ChannelResultRow(item: item) }
                                .buttonStyle(.plain)
                            Divider().padding(.leading, 76)
                        }
                    }
                    if !results.channels.isEmpty {
                        Color.clear.frame(height: 12)
                    }
                    // Then videos.
                    GroupedVideoList(items: videos) { app.play($0) }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
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
        query = suggestion
        suggestTask?.cancel()
        suggestions = []
        hideKeyboard()
        Task { await runSearch() }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func runSearch() async {
        suggestTask?.cancel()
        suggestions = []
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { phase = .idle; return }
        recordSearch(q)
        phase = .loading
        do {
            let all = try await app.client.search(q, filter: "all")
            let channels = all.filter { $0.isChannel }
            let videos = all.filter { $0.isVideo }
            phase = .loaded(Results(channels: channels, videos: videos))
            await ThumbnailPrefetcher.shared.prefetch(videos.prefix(12).map { Thumbnail.upgraded($0.thumbnail) })
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Persist the query as a personalization signal: upsert so repeats bump a
    /// counter + the timestamp rather than duplicating. Mirrors how the player
    /// records watch history.
    private func recordSearch(_ raw: String) {
        let key = SearchEntry.normalize(raw)
        guard !key.isEmpty else { return }
        let descriptor = FetchDescriptor<SearchEntry>(predicate: #Predicate { $0.query == key })
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.count += 1
            existing.lastSearchedAt = .now
        } else {
            modelContext.insert(SearchEntry(query: key))
        }
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
        let subs = Format.views(item.subscribers)?.replacingOccurrences(of: "views", with: "subscribers")
        let videos = (item.videos ?? -1) > 0 ? "\(item.videos!) videos" : nil
        let line = Format.metaLine(subs, videos)
        return line.isEmpty ? nil : line
    }
}
