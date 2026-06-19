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
    @State private var regularVideos: [StreamItem] = []
    @State private var shorts: [StreamItem] = []
    @State private var videoNextpage: String?
    @State private var shortsTabData: String?
    @State private var shortsNextpage: String?
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

                let shown = app.filteringShorts(displayItems)
                if shown.isEmpty {
                    emptyState
                } else {
                    GroupedVideoList(items: shown,
                                     avatarFallback: channel.avatarUrl,
                                     channelIDFallback: channelID,
                                     shortsLayout: .carousel,
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
                .task(id: loadMoreToken) { await loadNextPage() }
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
                .id(loadMoreToken)
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
        videoNextpage?.isEmpty == false || (!app.hideShorts && shortsNextpage?.isEmpty == false)
    }

    private var loadMoreToken: String {
        [
            videoNextpage ?? "videos-end",
            shortsNextpage ?? "shorts-end",
            "\(regularVideos.count)",
            "\(shorts.count)"
        ].joined(separator: "|")
    }

    private var displayItems: [StreamItem] {
        let leadCount = min(3, regularVideos.count)
        return Array(regularVideos.prefix(leadCount))
            + shorts
            + Array(regularVideos.dropFirst(leadCount))
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
            var loaded = channel.relatedStreams ?? []
            if loaded.isEmpty {
                loaded = (try? await app.client.feed(channelIDs: [channelID])) ?? []
            }
            let split = splitUploads(loaded)
            let tabData = channel.shortsTabData
            var loadedShorts = split.shorts
            var loadedShortsNextpage: String?
            if !app.hideShorts, let tabData {
                let shortsPage = try? await app.client.channelTab(data: tabData)
                let tabShorts = splitUploads(shortsPage?.content ?? []).shorts
                let loadedIDs = Set((split.regular + loadedShorts).map(\.id))
                loadedShorts.append(contentsOf: unique(tabShorts, excluding: loadedIDs))
                loadedShortsNextpage = normalizedNextpage(shortsPage?.nextpage)
            }
            phase = .loaded(channel)
            regularVideos = split.regular
            shorts = loadedShorts
            videoNextpage = normalizedNextpage(channel.nextpage)
            shortsTabData = tabData
            shortsNextpage = loadedShortsNextpage
            await prefetchThumbnails(app.filteringShorts(displayItems))
        } catch is CancellationError {
            return
        } catch {
            // On a refresh failure keep the content we're already showing.
            if !alreadyLoaded { phase = .failed(error.localizedDescription) }
        }
    }

    private func loadNextPage() async {
        guard hasNextPage, !isLoadingNextPage else { return }
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }

        var appended: [StreamItem] = []
        do {
            if let token = videoNextpage {
                let page = try await app.client.channelNextPage(id: channelID, nextpage: token)
                let split = splitUploads(page.relatedStreams ?? [])
                let newRegular = appendUniqueRegular(split.regular)
                let newShorts = appendUniqueShorts(split.shorts)
                appended.append(contentsOf: newRegular + newShorts)
                let newToken = normalizedNextpage(page.nextpage)
                videoNextpage = (newRegular + newShorts).isEmpty && newToken == token ? nil : newToken
            }

            if !app.hideShorts, let data = shortsTabData, let token = shortsNextpage {
                let page = try await app.client.channelTab(data: data, nextpage: token)
                let newShorts = appendUniqueShorts(splitUploads(page.content ?? []).shorts)
                appended.append(contentsOf: newShorts)
                let newToken = normalizedNextpage(page.nextpage)
                shortsNextpage = newShorts.isEmpty && newToken == token ? nil : newToken
            }
            await prefetchThumbnails(appended)
        } catch is CancellationError {
            return
        } catch {
            // Keep the token so a later scroll or pull-to-refresh can retry.
        }
    }

    @discardableResult
    private func appendUniqueRegular(_ newVideos: [StreamItem]) -> [StreamItem] {
        let unique = unique(newVideos, excluding: loadedIDs)
        regularVideos.append(contentsOf: unique)
        return unique
    }

    @discardableResult
    private func appendUniqueShorts(_ newShorts: [StreamItem]) -> [StreamItem] {
        let unique = unique(newShorts, excluding: loadedIDs)
        shorts.append(contentsOf: unique)
        return unique
    }

    private var loadedIDs: Set<String> {
        Set((regularVideos + shorts).map(\.id))
    }

    private func unique(_ items: [StreamItem], excluding existingIDs: Set<String>) -> [StreamItem] {
        var seen = existingIDs
        return items.filter { item in
            guard !seen.contains(item.id) else { return false }
            seen.insert(item.id)
            return true
        }
    }

    private func splitUploads(_ items: [StreamItem]) -> (regular: [StreamItem], shorts: [StreamItem]) {
        let videos = items.filter(\.isVideo)
        return (
            videos.filter { $0.isShort != true },
            videos.filter { $0.isShort == true }
        )
    }

    /// Warm the first batch of thumbnails so they're decoded before scroll, the
    /// same head start the Home feed gives its list.
    private func prefetchThumbnails(_ videos: [StreamItem]) async {
        await ThumbnailPrefetcher.shared.prefetch(
            videos.prefix(12).map { Thumbnail.upgraded($0.thumbnail) })
    }
}

private extension Channel {
    var shortsTabData: String? {
        tabs?.first { ($0.name ?? "").caseInsensitiveCompare("shorts") == .orderedSame }?.data
    }
}
