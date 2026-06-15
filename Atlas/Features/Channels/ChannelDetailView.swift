import SwiftUI
import SwiftData
import PipedKit

struct ChannelDetailView: View {
    let channelID: String

    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query private var allSubs: [SubscribedChannel]
    @Query private var history: [HistoryEntry]

    @State private var phase: LoadPhase<Channel> = .idle
    @State private var videos: [StreamItem] = []
    @State private var nextpage: String?
    @State private var isLoadingNextPage = false

    private var subscription: SubscribedChannel? {
        allSubs.first { $0.channelID == channelID }
    }

    /// A channel page shows the full catalog (watched videos stay visible), so we
    /// badge what's been seen rather than hiding it the way the Home feed does.
    /// Only videos watched ≥80% earn the badge — opening one and bailing early
    /// doesn't count as watched.
    private var watchedIDs: Set<String> { Set(history.filter(\.isWatched).map(\.videoID)) }

    var body: some View {
        Group {
            switch phase {
            case .loaded(let channel):
                content(channel)
            case .failed(let message):
                ErrorState(message: message) { await load() }
            default:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(headerName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var headerName: String {
        if case .loaded(let c) = phase { return c.name ?? "Channel" }
        return subscription?.name ?? "Channel"
    }

    private func content(_ channel: Channel) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                header(channel)

                Divider()
                    .padding(.horizontal)

                let shown = app.filteringShorts(videos)
                if shown.isEmpty {
                    emptyState
                } else {
                    GroupedVideoList(items: shown,
                                     avatarFallback: channel.avatarUrl,
                                     channelIDFallback: channelID,
                                     watchedIDs: watchedIDs,
                                     onAppearItem: { handleAppear($0, visibleItems: shown) }) { app.play($0) }
                        .padding(.horizontal)
                    paginationFooter
                }
            }
            .padding(.bottom, 24)
        }
        .refreshable { await load(force: true) }
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasNextPage || isLoadingNextPage {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                .task(id: nextpage) { await loadNextPage() }
        } else {
            ContentUnavailableView("No videos to show", systemImage: "play.slash",
                description: Text("This instance returned no uploads for this channel. Try another instance in Settings."))
                .padding(.top, 40)
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if isLoadingNextPage {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else if hasNextPage {
            Color.clear
                .frame(height: 1)
                .id(nextpage)
                .onAppear { Task { await loadNextPage() } }
        }
    }

    @ViewBuilder
    private func header(_ channel: Channel) -> some View {
        VStack(spacing: 12) {
            if let banner = channel.bannerUrl, let url = URL(string: banner) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
                    .overlay {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image): image.resizable().scaledToFill()
                            default: Rectangle().fill(.quaternary)
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal)
            }

            HStack(alignment: .center, spacing: 12) {
                Avatar(url: channel.avatarUrl, size: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name ?? "Channel")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if let subs = channel.subscriberCount, subs > 0 {
                        Text(Format.views(subs)?.replacingOccurrences(of: "views", with: "subscribers") ?? "")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                subscribeButton(channel)
            }
            .padding(.horizontal)
        }
    }

    private func subscribeButton(_ channel: Channel) -> some View {
        let subscribed = subscription != nil
        return Button {
            toggle(channel)
        } label: {
            Image(systemName: subscribed ? "checkmark" : "plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(subscribed ? .secondary : Color.accentColor)
                .frame(width: 44, height: 44)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .accessibilityLabel(subscribed ? "Unsubscribe" : "Subscribe")
    }

    private func toggle(_ channel: Channel) {
        if let existing = subscription {
            context.delete(existing)
        } else {
            context.insert(SubscribedChannel(
                channelID: channelID,
                name: channel.name ?? "Channel",
                avatarURL: channel.avatarUrl))
        }
    }

    private var hasNextPage: Bool {
        nextpage?.isEmpty == false
    }

    private func normalizedNextpage(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func handleAppear(_ item: StreamItem, visibleItems: [StreamItem]) {
        app.prefetchStream(item.videoID)
        guard shouldLoadNextPage(after: item, visibleItems: visibleItems) else { return }
        Task { await loadNextPage() }
    }

    private func shouldLoadNextPage(after item: StreamItem, visibleItems: [StreamItem]) -> Bool {
        guard hasNextPage, !isLoadingNextPage,
              let index = visibleItems.firstIndex(where: { $0.id == item.id }) else { return false }
        return index >= max(visibleItems.count - 4, 0)
    }

    /// Loads the channel header + uploads. `.task` calls it once on appear (and
    /// skips when already loaded); pull-to-refresh passes `force` to re-fetch
    /// while keeping the current content on screen instead of blanking to a spinner.
    private func load(force: Bool = false) async {
        let alreadyLoaded: Bool
        if case .loaded = phase { alreadyLoaded = true } else { alreadyLoaded = false }
        if alreadyLoaded && !force { return }
        if !alreadyLoaded { phase = .loading }
        do {
            let channel = try await app.client.channel(id: channelID)
            // The channel "Videos" tab is currently broken upstream in Piped —
            // `relatedStreams` comes back empty network-wide — so fall back to the
            // RSS-based feed endpoint, which still returns the channel's recent
            // uploads on a healthy instance.
            var loaded = channel.relatedStreams ?? []
            if loaded.isEmpty {
                loaded = (try? await app.client.feed(channelIDs: [channelID])) ?? []
            }
            phase = .loaded(channel)
            videos = loaded
            nextpage = normalizedNextpage(channel.nextpage)
            await prefetchThumbnails(app.filteringShorts(loaded))
        } catch is CancellationError {
            return
        } catch {
            // On a refresh failure keep the content we're already showing.
            if !alreadyLoaded { phase = .failed(error.localizedDescription) }
        }
    }

    private func loadNextPage() async {
        guard let token = nextpage, !isLoadingNextPage else { return }
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }

        do {
            let page = try await app.client.channelNextPage(id: channelID, nextpage: token)
            let newToken = normalizedNextpage(page.nextpage)
            let appended = appendUnique(page.relatedStreams ?? [])
            nextpage = appended.isEmpty && newToken == token ? nil : newToken
            await prefetchThumbnails(appended)
        } catch is CancellationError {
            return
        } catch {
            // Keep the token so a later scroll or pull-to-refresh can retry.
        }
    }

    @discardableResult
    private func appendUnique(_ newVideos: [StreamItem]) -> [StreamItem] {
        var existingIDs = Set(videos.map(\.id))
        let unique = newVideos.filter { item in
            guard !existingIDs.contains(item.id) else { return false }
            existingIDs.insert(item.id)
            return true
        }
        videos.append(contentsOf: unique)
        return unique
    }

    /// Warm the first batch of thumbnails so they're decoded before scroll, the
    /// same head start the Home feed gives its list.
    private func prefetchThumbnails(_ videos: [StreamItem]) async {
        await ThumbnailPrefetcher.shared.prefetch(
            videos.prefix(12).map { Thumbnail.upgraded($0.thumbnail) })
    }
}
