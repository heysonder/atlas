import Foundation
import Observation
import PipedKit

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
    private struct ChannelState {
        var buffer: [StreamItem]   // fetched, newest-first, not yet emitted
        var cursor: String?        // nextpage token; nil once the channel is exhausted
    }

    let client: PipedClient
    let channelIDs: [String]

    private(set) var items: [StreamItem] = []
    private(set) var isLoading = false
    private(set) var didLoad = false

    private var states: [String: ChannelState] = [:]
    private var emittedIDs = Set<String>()

    /// How many items each `loadInitial`/`loadMore` emits, and how many channels
    /// we hit the network for at once.
    private let pageSize = 30
    private let concurrency = 6

    init(client: PipedClient, channelIDs: [String]) {
        self.client = client
        self.channelIDs = channelIDs
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

        let client = self.client
        for start in stride(from: 0, to: channelIDs.count, by: concurrency) {
            let slice = Array(channelIDs[start..<min(start + concurrency, channelIDs.count)])
            let fetched = await withTaskGroup(of: (String, Channel?).self) { group in
                for id in slice {
                    group.addTask { (id, try? await client.channel(id: id)) }
                }
                var out: [(String, Channel?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (id, channel) in fetched {
                let videos = (channel?.relatedStreams ?? []).filter(\.isVideo)
                // Keep the cursor even when page one has no plain videos (e.g.
                // all Shorts/livestreams) — real uploads may sit a page deeper.
                // `refillEmptyBuffers` has its own empty-page spin-guard, so a
                // truly exhausted channel still stops after one refill attempt.
                states[id] = ChannelState(buffer: sortedNewestFirst(videos),
                                          cursor: normalized(channel?.nextpage))
            }
        }
        didLoad = true
        await emit(pageSize)
    }

    /// Emits the next merged batch, refilling channel buffers from the network on
    /// demand.
    func loadMore() async {
        guard didLoad, !isLoading, hasMore else { return }
        isLoading = true
        defer { isLoading = false }
        await emit(pageSize)
    }

    /// Produces up to `count` more items in global newest-first order.
    private func emit(_ count: Int) async {
        var produced = 0
        while produced < count {
            await refillEmptyBuffers()
            // The channel whose buffered head upload is newest wins the next slot.
            guard let pick = states
                .filter({ !$0.value.buffer.isEmpty })
                .max(by: { headDate($0.value) < headDate($1.value) })?.key
            else { break }   // every buffer empty and nothing left to fetch

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
        let pending = states.filter { $0.value.buffer.isEmpty && $0.value.cursor != nil }.map(\.key)
        guard !pending.isEmpty else { return }

        let client = self.client
        for start in stride(from: 0, to: pending.count, by: concurrency) {
            let slice = Array(pending[start..<min(start + concurrency, pending.count)])
            let fetched = await withTaskGroup(of: (String, Channel?).self) { group in
                for id in slice {
                    let token = states[id]?.cursor ?? ""
                    group.addTask { (id, try? await client.channelNextPage(id: id, nextpage: token)) }
                }
                var out: [(String, Channel?)] = []
                for await result in group { out.append(result) }
                return out
            }
            for (id, channel) in fetched {
                let videos = (channel?.relatedStreams ?? []).filter(\.isVideo)
                states[id]?.buffer = sortedNewestFirst(videos)
                // Stop paging a channel that returns an empty page, even if it
                // still hands back a token, so we don't spin re-fetching nothing.
                states[id]?.cursor = videos.isEmpty ? nil : normalized(channel?.nextpage)
            }
        }
    }

    private func headDate(_ state: ChannelState) -> Int64 {
        state.buffer.first?.uploaded ?? 0
    }

    private func sortedNewestFirst(_ items: [StreamItem]) -> [StreamItem] {
        items.sorted { ($0.uploaded ?? 0) > ($1.uploaded ?? 0) }
    }

    private func normalized(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
