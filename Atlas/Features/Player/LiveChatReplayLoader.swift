import Foundation
import Observation
import PipedKit

typealias LiveChatReplayPageLoader =
    @Sendable (PipedClient, String, String?) async throws -> LiveChatPage

/// Replays an ended live stream's chat in step with playback. Replay pages
/// chain through `pageToken` as consecutive windows from the start of the
/// stream, each message stamped with its video offset. The server cannot
/// seek, so pages are fetched just ahead of the playhead — one per tick — and
/// a far-forward seek catches up gradually rather than bulk-walking hundreds
/// of pages against a small self-hosted instance.
@MainActor
@Observable
final class LiveChatReplayLoader {
    /// Keep this much chat buffered beyond the playhead so messages are
    /// already here when playback reaches them.
    static let lookaheadSeconds = 30.0
    /// Oldest messages are dropped past this; a backward seek beyond the
    /// buffer shows an empty pane rather than re-walking pages.
    static let maximumRetainedMessages = 2_000
    /// Shown at once — the pane only ever needs the tail.
    static let maximumVisibleMessages = 300

    let client: PipedClient
    let videoID: String

    private(set) var messages: [LiveChatMessageDisplay] = []
    /// The instance rejected the replay (404): no transcript for this video.
    private(set) var unavailable = false
    private(set) var didLoad = false
    private(set) var isLoading = false
    private(set) var reachedEnd = false
    /// Transient first-page failure; `loadInitial` can be retried.
    private(set) var loadFailed = false
    /// A page fetch failed; the token is kept so the next tick retries.
    private(set) var paginationFailed = false

    /// Video offset (seconds) the loaded pages cover up to.
    private(set) var coveredSeconds = 0
    private var nextPageToken: String?
    private var requestedTokens = Set<String>()
    private var seenIDs = Set<String>()
    @ObservationIgnored private let pageLoader: LiveChatReplayPageLoader
    @ObservationIgnored private let sleeper: LiveChatSleeper

    init(
        client: PipedClient,
        videoID: String,
        pageLoader: @escaping LiveChatReplayPageLoader = { client, videoID, token in
            try await client.liveChatReplay(videoID: videoID, pageToken: token)
        },
        sleeper: @escaping LiveChatSleeper = { milliseconds in
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
    ) {
        self.client = client
        self.videoID = videoID
        self.pageLoader = pageLoader
        self.sleeper = sleeper
    }

    /// Fetches the first page; a no-op once it has succeeded.
    func loadInitial() async {
        guard !Task.isCancelled, !didLoad, !isLoading, !unavailable else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await pageLoader(client, videoID, nil)
            try Task.checkCancellation()
            append(page.messages ?? [])
            advance(to: page.nextPageToken)
            didLoad = true
            loadFailed = false
            paginationFailed = false
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            if LiveChatLoader.isPermanentFailure(error) {
                unavailable = true
            } else {
                loadFailed = true
            }
        }
    }

    /// Follows the latest playhead while the chat pane is visible. Playback
    /// updates do not cancel a page that is already being fetched.
    func run(playbackSeconds: () -> Double?) async {
        while !Task.isCancelled, !reachedEnd {
            await follow(playbackSeconds: playbackSeconds())
            guard !Task.isCancelled, !reachedEnd else { return }
            guard (try? await sleeper(1_000)) != nil else { return }
        }
    }

    /// Called as playback advances: fetches one more page when the buffered
    /// chat doesn't yet reach `lookaheadSeconds` past the playhead.
    func follow(playbackSeconds: Double?) async {
        guard didLoad, !reachedEnd, !isLoading else { return }
        guard let playbackSeconds, playbackSeconds.isFinite else { return }
        guard Double(coveredSeconds) < playbackSeconds + Self.lookaheadSeconds else { return }
        await loadMore()
    }

    /// Appends the next page when one exists. On failure it keeps the token
    /// and flags for a retry rather than dropping the transcript.
    func loadMore() async {
        guard !Task.isCancelled, didLoad, !isLoading, !reachedEnd else { return }
        guard let token = nextPageToken, requestedTokens.insert(token).inserted else {
            reachedEnd = true
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await pageLoader(client, videoID, token)
            try Task.checkCancellation()
            let addedCount = append(page.messages ?? [])
            if addedCount == 0, page.nextPageToken == nil || page.nextPageToken == token {
                reachedEnd = true
            } else {
                advance(to: page.nextPageToken)
            }
            paginationFailed = false
        } catch {
            requestedTokens.remove(token)
            if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                paginationFailed = true
            }
        }
    }

    func retryLoadMore() async {
        paginationFailed = false
        await loadMore()
    }

    /// The tail of the transcript up to the playhead — what the pane shows.
    /// With no playback position (nothing playing yet) it shows everything
    /// buffered.
    func visibleMessages(at playbackSeconds: Double?) -> [LiveChatMessageDisplay] {
        guard let playbackSeconds, playbackSeconds.isFinite else {
            return Array(messages.suffix(Self.maximumVisibleMessages))
        }
        let limit = Int(playbackSeconds.rounded(.down))
        let end = messages.partitioningIndex { ($0.videoOffsetSeconds ?? 0) > limit }
        return Array(messages[..<end].suffix(Self.maximumVisibleMessages))
    }

    @discardableResult
    private func append(_ incoming: [LiveChatMessage]) -> Int {
        let fresh = incoming.compactMap(LiveChatLoader.display(from:))
            .filter { seenIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return 0 }
        messages.append(contentsOf: fresh)
        messages.sort { ($0.videoOffsetSeconds ?? 0) < ($1.videoOffsetSeconds ?? 0) }
        if let last = messages.last?.videoOffsetSeconds {
            coveredSeconds = max(coveredSeconds, last)
        }
        if messages.count > Self.maximumRetainedMessages {
            messages.removeFirst(messages.count - Self.maximumRetainedMessages)
        }
        return fresh.count
    }

    private func advance(to token: String?) {
        if let token, !token.isEmpty, !requestedTokens.contains(token) {
            nextPageToken = token
        } else {
            nextPageToken = nil
            reachedEnd = true
        }
    }
}

extension Array where Element == LiveChatMessageDisplay {
    /// First index whose element satisfies `belongsInSecondPartition`, for an
    /// array already ordered so that all such elements are at the end.
    fileprivate func partitioningIndex(
        where belongsInSecondPartition: (Element) -> Bool
    ) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if belongsInSecondPartition(self[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
}
