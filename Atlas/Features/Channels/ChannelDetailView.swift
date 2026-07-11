import PipedKit
import SwiftData
import SwiftUI

struct ChannelDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let channelID: String

    /// Just this channel's subscription row (filtered in `init`), not the whole
    /// table — the page only ever needs the one match.
    @Query private var matchingSubs: [SubscribedChannel]
    @Query(sort: \HistoryEntry.watchedAt, order: .reverse) private var history: [HistoryEntry]

    @State private var phase: LoadPhase<Channel> = .idle
    @State private var regularVideos: [StreamItem] = []
    @State private var shorts: [StreamItem] = []
    @State private var videoNextPage: String?
    @State private var shortsTabData: String?
    @State private var shortsNextPage: String?
    @State private var isLoadingNextPage = false
    @State private var paginationError: String?

    @State private var watchedMemo = WatchedIDsMemo()

    private var subscription: SubscribedChannel? {
        matchingSubs.first
    }

    /// The channel catalog keeps watched videos visible and badges completed items.
    private var watchedIDs: Set<String> {
        watchedMemo.ids(for: history)
    }

    private var headerName: String {
        if case .loaded(let channel) = phase {
            return channel.name ?? "Channel"
        }
        return subscription?.name ?? "Channel"
    }

    private var hasNextPage: Bool {
        videoNextPage?.isEmpty == false
            || (!app.hideShorts && shortsNextPage?.isEmpty == false)
    }

    private var loadMoreToken: String {
        [
            videoNextPage ?? "videos-end",
            shortsNextPage ?? "shorts-end",
            "\(regularVideos.count)",
            "\(shorts.count)",
        ].joined(separator: "|")
    }

    private var displayItems: [StreamItem] {
        let leadCount = min(3, regularVideos.count)
        return Array(regularVideos.prefix(leadCount))
            + shorts
            + Array(regularVideos.dropFirst(leadCount))
    }

    private var loadedIDs: Set<String> {
        Set((regularVideos + shorts).map(\.id))
    }

    init(channelID: String) {
        self.channelID = channelID
        _matchingSubs = Query(
            filter: #Predicate<SubscribedChannel> {
                $0.channelID == channelID
            })
    }

    var body: some View {
        Group {
            switch phase {
            case .loaded(let channel):
                content(channel)
            case .failed(let message):
                ErrorState(message: message) { await load() }
            default:
                ProgressView("Loading channel…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(headerName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: app.instanceGeneration) { await reloadForSelectedInstance() }
    }

    private func content(_ channel: Channel) -> some View {
        let shownItems = app.filteringShorts(displayItems)
        let paginationTriggerIDs = Set(shownItems.suffix(4).map(\.id))
        return ChannelDetailContent(
            channel: channel,
            channelID: channelID,
            shownItems: shownItems,
            hasFilteredItems: !displayItems.isEmpty && shownItems.isEmpty,
            watchedIDs: watchedIDs,
            isSubscribed: subscription != nil,
            reduceMotion: reduceMotion,
            hasNextPage: hasNextPage,
            isLoadingNextPage: isLoadingNextPage,
            paginationError: paginationError,
            loadMoreToken: loadMoreToken,
            onToggleSubscription: { toggleSubscription(channel) },
            onAppearItem: { handleAppear($0, paginationTriggerIDs: paginationTriggerIDs) },
            onPlay: { app.play($0) },
            onLoadNextPage: loadNextPage,
            onRetryNextPage: retryNextPage,
            onRefresh: { await load(force: true) })
    }

    private func toggleSubscription(_ channel: Channel) {
        SubscriptionStore.setSubscribed(
            subscription == nil,
            channelID: channelID,
            name: channel.name,
            avatarURL: channel.avatarURL,
            in: modelContext)
    }

    private func normalizedNextPage(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func handleAppear(_ item: StreamItem, paginationTriggerIDs: Set<String>) {
        app.prefetchStream(item.videoID)
        guard paginationError == nil, paginationTriggerIDs.contains(item.id) else { return }
        Task { await loadNextPage() }
    }

    /// Loads the channel header + uploads. `.task` calls it once on appear (and
    /// skips when already loaded); pull-to-refresh passes `force` to re-fetch
    /// while keeping the current content on screen instead of blanking to a spinner.
    private func load(force: Bool = false) async {
        let instanceGeneration = app.instanceGeneration
        let alreadyLoaded: Bool
        if case .loaded = phase { alreadyLoaded = true } else { alreadyLoaded = false }
        if alreadyLoaded && !force { return }
        if !alreadyLoaded { phase = .loading }
        do {
            let client = try app.client
            let channel = try await client.channel(id: channelID)
            guard instanceGeneration == app.instanceGeneration else { return }
            var loaded = channel.relatedStreams ?? []
            if loaded.isEmpty {
                loaded = (try? await client.feed(channelIDs: [channelID])) ?? []
                guard instanceGeneration == app.instanceGeneration else { return }
            }
            let split = splitUploads(StreamItemIdentity.firstOccurrences(in: loaded))
            let tabData = channel.shortsTabData
            var loadedShorts = split.shorts
            var loadedShortsNextPage: String?
            if !app.hideShorts, let tabData {
                let shortsPage = try? await client.channelTab(data: tabData)
                guard instanceGeneration == app.instanceGeneration else { return }
                let tabShorts = splitUploads(shortsPage?.content ?? []).shorts
                let loadedIDs = Set((split.regular + loadedShorts).map(\.id))
                loadedShorts.append(
                    contentsOf: StreamItemIdentity.firstOccurrences(
                        in: tabShorts,
                        excludingIDs: loadedIDs))
                loadedShortsNextPage = normalizedNextPage(shortsPage?.nextPage)
            }
            phase = .loaded(channel)
            regularVideos = split.regular
            shorts = loadedShorts
            videoNextPage = normalizedNextPage(channel.nextPage)
            shortsTabData = tabData
            shortsNextPage = loadedShortsNextPage
            paginationError = nil
            await prefetchThumbnails(app.filteringShorts(displayItems))
        } catch is CancellationError {
            return
        } catch {
            // On a refresh failure keep the content we're already showing.
            if !alreadyLoaded { phase = .failed(error.localizedDescription) }
        }
    }

    private func loadNextPage() async {
        guard hasNextPage, !isLoadingNextPage, paginationError == nil else { return }
        let instanceGeneration = app.instanceGeneration
        isLoadingNextPage = true
        defer { isLoadingNextPage = false }

        var appended: [StreamItem] = []
        do {
            let client = try app.client
            if let token = videoNextPage {
                let page = try await client.channelNextPage(id: channelID, nextPage: token)
                guard instanceGeneration == app.instanceGeneration else { return }
                let split = splitUploads(page.relatedStreams ?? [])
                let newRegular = appendUniqueRegular(split.regular)
                let newShorts = appendUniqueShorts(split.shorts)
                appended.append(contentsOf: newRegular + newShorts)
                let newToken = normalizedNextPage(page.nextPage)
                videoNextPage = (newRegular + newShorts).isEmpty && newToken == token ? nil : newToken
            }

            if !app.hideShorts, let data = shortsTabData, let token = shortsNextPage {
                let page = try await client.channelTab(data: data, nextPage: token)
                guard instanceGeneration == app.instanceGeneration else { return }
                let newShorts = appendUniqueShorts(splitUploads(page.content ?? []).shorts)
                appended.append(contentsOf: newShorts)
                let newToken = normalizedNextPage(page.nextPage)
                shortsNextPage = newShorts.isEmpty && newToken == token ? nil : newToken
            }
            paginationError = nil
            await prefetchThumbnails(appended)
        } catch is CancellationError {
            return
        } catch {
            // Retain the cursor for an explicit retry, but stop the visible
            // sentinel from immediately starting the same failing request again.
            paginationError = error.localizedDescription
        }
    }

    private func retryNextPage() async {
        paginationError = nil
        await loadNextPage()
    }

    private func reloadForSelectedInstance() async {
        phase = .idle
        regularVideos = []
        shorts = []
        videoNextPage = nil
        shortsTabData = nil
        shortsNextPage = nil
        isLoadingNextPage = false
        paginationError = nil
        await load(force: true)
    }

    @discardableResult
    private func appendUniqueRegular(_ newVideos: [StreamItem]) -> [StreamItem] {
        let unique = StreamItemIdentity.firstOccurrences(
            in: newVideos,
            excludingIDs: loadedIDs)
        regularVideos.append(contentsOf: unique)
        return unique
    }

    @discardableResult
    private func appendUniqueShorts(_ newShorts: [StreamItem]) -> [StreamItem] {
        let unique = StreamItemIdentity.firstOccurrences(
            in: newShorts,
            excludingIDs: loadedIDs)
        shorts.append(contentsOf: unique)
        return unique
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
        guard let client = try? app.httpClient else { return }
        await ThumbnailPrefetcher.shared.prefetch(
            videos.prefix(12).map { ThumbnailURL.upgraded($0.thumbnail) },
            client: client,
            generation: app.instanceGeneration)
    }
}

extension Channel {
    fileprivate var shortsTabData: String? {
        tabs?.first { ($0.name ?? "").caseInsensitiveCompare("shorts") == .orderedSame }?.data
    }
}
