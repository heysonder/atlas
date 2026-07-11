import Foundation
import Observation
import PipedKit

typealias InitialSubscriptionChannelLoader =
    @Sendable (PipedClient, String) async throws -> Channel
typealias NextSubscriptionChannelPageLoader =
    @Sendable (PipedClient, String, String) async throws -> Channel

/// Builds a paginated, reverse-chronological subscriptions feed by merging each
/// channel's uploads from `/channel/:id` (+ its `nextpage` cursor).
///
/// We can't use `feed/unauthenticated` for this: several instances (e.g.
/// cmf.sh) return it empty, and even when it works it's RSS-backed and capped at
/// ~15 uploads per channel with no continuation token. `/channel/:id` paginates
/// properly, so this does a k-way merge across all subscribed channels: take the
/// globally newest buffered upload each step, and only fetch a channel's next
/// page when its buffer empties (its next page is always older than what we've
/// already buffered, so on-demand refills keep the merge correct and cheap).
@MainActor
@Observable
final class SubscriptionFeedLoader {
    private enum PageFetchResult: Sendable {
        case success(channelID: String, requestedToken: String, channel: Channel)
        case cancelled(channelID: String, requestedToken: String)
        case failure(channelID: String, requestedToken: String, message: String)
    }

    private struct ChannelState {
        var buffer: [StreamItem]  // fetched, newest-first, not yet emitted
        var cursor: String?  // nextpage token; nil once the channel is exhausted
        var requestedCursors: Set<String> = []
        var pagesFetched = 1
    }

    let client: PipedClient
    let channelIDs: [String]
    let instanceGeneration: UInt64

    private(set) var items: [StreamItem] = []
    private(set) var isLoading = false
    private(set) var didLoad = false
    private(set) var paginationError: String?

    private var states: [String: ChannelState] = [:]
    private var emittedIDs = Set<String>()
    private var requestCount = 0
    @ObservationIgnored private let initialChannelLoader: InitialSubscriptionChannelLoader
    @ObservationIgnored private let nextChannelPageLoader: NextSubscriptionChannelPageLoader

    /// How many items each `loadInitial`/`loadMore` emits, and how many channels
    /// we hit the network for at once.
    private let pageSize = 30
    private let concurrency = 6
    static let maximumChannels = 100
    static let maximumItemsPerPage = 200
    static let maximumPagesPerChannel = 20
    static let maximumRequests = 300
    static let maximumChannelIDBytes = 256
    static let maximumCursorBytes = 8 * 1_024

    init(
        client: PipedClient,
        channelIDs: [String],
        instanceGeneration: UInt64 = 0,
        initialChannelLoader: @escaping InitialSubscriptionChannelLoader = { client, id in
            try await client.channel(id: id)
        },
        nextChannelPageLoader: @escaping NextSubscriptionChannelPageLoader = {
            client, id, token in
            try await client.channelNextPage(id: id, nextPage: token)
        }
    ) {
        self.client = client
        self.channelIDs = Self.boundedChannelIDs(channelIDs)
        self.instanceGeneration = instanceGeneration
        self.initialChannelLoader = initialChannelLoader
        self.nextChannelPageLoader = nextChannelPageLoader
    }

    /// More uploads are available if any channel still has buffered items or an
    /// unconsumed cursor.
    var hasMore: Bool {
        states.values.contains { !$0.buffer.isEmpty || $0.cursor != nil }
    }

    /// Fetches page one of every channel, then emits the first merged batch.
    func loadInitial() async {
        guard !didLoad, !isLoading, !channelIDs.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        states.removeAll(keepingCapacity: true)
        emittedIDs.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
        requestCount = 0
        paginationError = nil

        let client = self.client
        let initialChannelLoader = self.initialChannelLoader
        for start in stride(from: 0, to: channelIDs.count, by: concurrency) {
            guard !Task.isCancelled, requestCount < Self.maximumRequests else { return }
            let slice = Array(channelIDs[start..<min(start + concurrency, channelIDs.count)])
            requestCount += slice.count
            let fetched = await withTaskGroup(of: (String, Channel?).self) { group in
                for id in slice {
                    group.addTask { (id, try? await initialChannelLoader(client, id)) }
                }
                var out: [(String, Channel?)] = []
                for await result in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    out.append(result)
                }
                return out
            }
            guard !Task.isCancelled else { return }
            for (id, channel) in fetched {
                let videos = (channel?.relatedStreams ?? [])
                    .lazy.filter(\.isVideo).prefix(Self.maximumItemsPerPage)
                // Keep the cursor even when page one has no plain videos (e.g.
                // all Shorts/livestreams) — real uploads may sit a page deeper.
                // `refillEmptyBuffers` has its own empty-page spin-guard, so a
                // truly exhausted channel still stops after one refill attempt.
                states[id] = ChannelState(
                    buffer: sortedNewestFirst(Array(videos)),
                    cursor: normalized(channel?.nextPage))
            }
        }
        didLoad = true
        await emit(pageSize)
    }

    /// Emits the next merged batch, refilling channel buffers from the network on
    /// demand.
    func loadMore() async {
        guard didLoad, !isLoading, paginationError == nil, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        await emit(pageSize)
    }

    func retryLoadMore() async {
        paginationError = nil
        await loadMore()
    }

    /// Produces up to `count` more items in global newest-first order.
    private func emit(_ count: Int) async {
        var produced = 0
        while produced < count {
            guard !Task.isCancelled else { return }
            await refillEmptyBuffers()
            // The channel whose buffered head upload is newest wins the next slot.
            guard
                let pick =
                    states
                    .filter({ !$0.value.buffer.isEmpty })
                    .max(by: { headDate($0.value) < headDate($1.value) })?.key
            else { break }  // every buffer empty and nothing left to fetch

            guard var state = states[pick], !state.buffer.isEmpty else { break }
            let item = state.buffer.removeFirst()
            states[pick] = state
            guard let id = item.videoID, !emittedIDs.contains(id) else { continue }
            emittedIDs.insert(id)
            items.append(item)
            produced += 1
        }
    }

    /// Fetches the next page for every channel whose buffer has drained but still
    /// has a cursor, so the merge above never overlooks a newer upload sitting one
    /// page deep in some channel.
    private func refillEmptyBuffers() async {
        guard paginationError == nil else { return }
        let pending = states.filter {
            $0.value.buffer.isEmpty && $0.value.cursor != nil
                && $0.value.pagesFetched < Self.maximumPagesPerChannel
        }.map(\.key)
        guard !pending.isEmpty else { return }

        let client = self.client
        let nextChannelPageLoader = self.nextChannelPageLoader
        for start in stride(from: 0, to: pending.count, by: concurrency) {
            guard !Task.isCancelled, paginationError == nil,
                requestCount < Self.maximumRequests
            else { return }
            let remaining = Self.maximumRequests - requestCount
            let end = min(start + concurrency, pending.count, start + remaining)
            guard start < end else { return }
            let slice = Array(pending[start..<end])
            let requests = slice.compactMap { id -> (String, String)? in
                guard let token = states[id]?.cursor,
                    states[id]?.requestedCursors.contains(token) == false
                else {
                    states[id]?.cursor = nil
                    return nil
                }
                states[id]?.requestedCursors.insert(token)
                return (id, token)
            }
            guard !requests.isEmpty else { continue }
            requestCount += requests.count
            let fetched = await withTaskGroup(of: PageFetchResult.self) { group in
                for (id, token) in requests {
                    group.addTask {
                        do {
                            return .success(
                                channelID: id,
                                requestedToken: token,
                                channel: try await nextChannelPageLoader(client, id, token))
                        } catch is CancellationError {
                            return .cancelled(channelID: id, requestedToken: token)
                        } catch let error as URLError where error.code == .cancelled {
                            return .cancelled(channelID: id, requestedToken: token)
                        } catch {
                            return .failure(
                                channelID: id,
                                requestedToken: token,
                                message: error.localizedDescription)
                        }
                    }
                }
                var out: [PageFetchResult] = []
                for await result in group {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    out.append(result)
                }
                return out
            }
            guard !Task.isCancelled else {
                rollback(requests)
                return
            }
            for result in fetched {
                switch result {
                case .success(let id, let requestedToken, let channel):
                    guard var state = states[id] else { continue }
                    state.pagesFetched += 1
                    let videos = (channel.relatedStreams ?? [])
                        .lazy.filter(\.isVideo)
                        .filter { item in item.videoID.map { !self.emittedIDs.contains($0) } ?? false }
                        .prefix(Self.maximumItemsPerPage)
                    state.buffer = sortedNewestFirst(Array(videos))
                    // Empty/duplicate-only pages, repeated cursors, and page-budget
                    // exhaustion are terminal for that channel.
                    state.cursor = Self.nextCursor(
                        candidate: channel.nextPage,
                        requested: requestedToken,
                        requestedCursors: state.requestedCursors,
                        hasNewItems: !state.buffer.isEmpty,
                        pagesFetched: state.pagesFetched)
                    states[id] = state
                case .cancelled(let id, let requestedToken):
                    restoreCursor(requestedToken, for: id)
                    requestCount -= 1
                case .failure(let id, let requestedToken, let message):
                    restoreCursor(requestedToken, for: id)
                    requestCount -= 1
                    if paginationError == nil { paginationError = message }
                }
            }
        }
    }

    private func rollback(_ requests: [(String, String)]) {
        for (id, requestedToken) in requests {
            restoreCursor(requestedToken, for: id)
        }
        requestCount -= requests.count
    }

    private func restoreCursor(_ requestedToken: String, for channelID: String) {
        guard var state = states[channelID] else { return }
        state.requestedCursors.remove(requestedToken)
        state.cursor = requestedToken
        states[channelID] = state
    }

    private func headDate(_ state: ChannelState) -> Int64 {
        state.buffer.first?.uploaded ?? 0
    }

    private func sortedNewestFirst(_ items: [StreamItem]) -> [StreamItem] {
        items.sorted { ($0.uploaded ?? 0) > ($1.uploaded ?? 0) }
    }

    private func normalized(_ token: String?) -> String? {
        Self.normalizedCursor(token)
    }

    static func nextCursor(
        candidate: String?,
        requested: String,
        requestedCursors: Set<String>,
        hasNewItems: Bool,
        pagesFetched: Int
    ) -> String? {
        guard hasNewItems, pagesFetched < maximumPagesPerChannel,
            let candidate = normalizedCursor(candidate),
            candidate != requested,
            !requestedCursors.contains(candidate)
        else { return nil }
        return candidate
    }

    private static func normalizedCursor(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false && (trimmed?.utf8.count ?? 0) <= maximumCursorBytes
            ? trimmed : nil
    }

    static func boundedChannelIDs(_ channelIDs: [String]) -> [String] {
        var seen = Set<String>()
        return channelIDs.compactMap { raw in
            let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.utf8.count <= maximumChannelIDBytes,
                seen.insert(id).inserted
            else { return nil }
            return id
        }.prefix(maximumChannels).map { $0 }
    }
}
