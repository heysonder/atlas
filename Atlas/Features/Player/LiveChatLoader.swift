import Foundation
import Observation
import PipedKit

typealias LiveChatPageLoader = @Sendable (PipedClient, String) async throws -> LiveChatPage
typealias LiveChatSleeper = @Sendable (_ milliseconds: Int) async throws -> Void

/// One renderable live chat message, flattened from the wire model so rows
/// never deal with optionals or non-text renderer types.
struct LiveChatMessageDisplay: Identifiable, Equatable {
    let id: String
    let author: String
    let text: String
    let avatar: String?
    let isVerified: Bool
    let isOwner: Bool
    let isModerator: Bool
    let isSponsor: Bool
    let timestampMicroseconds: Int64
    /// Replay messages only: offset into the video where the message appeared,
    /// with its human-readable "1:23:45" form. Nil while a stream is live.
    let videoOffsetSeconds: Int?
    let timestampText: String?
}

/// Polls `/livechat/:videoId` while a live stream plays. The endpoint returns
/// a rolling latest-messages window (its continuation token is ignored by
/// observed servers), so each poll is de-duplicated by message id and merged
/// into a bounded, timestamp-ordered transcript. The endpoint is not part of
/// upstream Piped, so "unavailable" is an expected outcome, not an error.
@MainActor
@Observable
final class LiveChatLoader {
    enum Availability: Equatable {
        /// First fetch hasn't finished yet.
        case unknown
        /// Chat is streaming; keep polling.
        case active
        /// The instance doesn't serve chat for this video — hide the section.
        case unavailable
        /// Chat was streaming and the server now rejects the poll (stream
        /// likely ended). Keep the transcript on screen, stop polling.
        case ended
    }

    static let maximumRetainedMessages = 300
    /// Bounds on the poll delay: never hammer the instance faster than 2s
    /// (self-hosted instances run on small hardware), never go quieter than
    /// 60s. The server's suggestion (10s on observed instances) is honored as
    /// a floor-ish hint but capped at `targetPollMilliseconds` so chat feels
    /// live — each poll is one small request against a rolling window.
    static let minimumPollMilliseconds = 2_000
    static let maximumPollMilliseconds = 60_000
    static let targetPollMilliseconds = 4_000
    static let defaultPollMilliseconds = 4_000
    private static let maximumTrackedIDs = 10_000

    let client: PipedClient
    let videoID: String

    private(set) var messages: [LiveChatMessageDisplay] = []
    private(set) var availability: Availability = .unknown
    private(set) var pollMilliseconds = LiveChatLoader.defaultPollMilliseconds

    private var seenIDs = Set<String>()
    @ObservationIgnored private let pageLoader: LiveChatPageLoader
    @ObservationIgnored private let sleeper: LiveChatSleeper

    init(
        client: PipedClient,
        videoID: String,
        pageLoader: @escaping LiveChatPageLoader = { client, videoID in
            try await client.liveChat(videoID: videoID)
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

    /// Polls until cancelled (the driving view's `.task` going away) or the
    /// server permanently rejects the chat.
    func run() async {
        while !Task.isCancelled {
            await refresh()
            guard availability == .active || availability == .unknown else { return }
            guard (try? await sleeper(pollMilliseconds)) != nil else { return }
        }
    }

    func refresh() async {
        do {
            let page = try await pageLoader(client, videoID)
            merge(page.messages ?? [])
            pollMilliseconds = Self.clampedPollInterval(page.pollAfterMs)
            availability = .active
        } catch {
            guard Self.isPermanentFailure(error) else { return }
            availability = messages.isEmpty ? .unavailable : .ended
        }
        // Transient failures (timeouts, 5xx) keep the transcript and let the
        // next poll try again.
    }

    private func merge(_ incoming: [LiveChatMessage]) {
        let fresh = incoming.compactMap(Self.display(from:))
            .filter { seenIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }

        messages.append(contentsOf: fresh)
        messages.sort { $0.timestampMicroseconds < $1.timestampMicroseconds }
        if messages.count > Self.maximumRetainedMessages {
            messages.removeFirst(messages.count - Self.maximumRetainedMessages)
        }
        if seenIDs.count > Self.maximumTrackedIDs {
            // The server only ever re-sends its latest window, so ids far
            // older than the retained transcript can't reappear.
            seenIDs = Set(messages.map(\.id))
        }
    }

    static func display(from message: LiveChatMessage) -> LiveChatMessageDisplay? {
        guard message.isTextMessage,
            let id = message.id, !id.isEmpty,
            let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
        else { return nil }
        return LiveChatMessageDisplay(
            id: id,
            author: message.author ?? "Unknown",
            text: text,
            avatar: message.avatar,
            isVerified: message.verified == true,
            isOwner: message.chatOwner == true,
            isModerator: message.chatModerator == true,
            isSponsor: message.chatSponsor == true,
            timestampMicroseconds: message.timestampMicroseconds ?? .max,
            videoOffsetSeconds: message.videoOffsetMs.map { max($0, 0) / 1_000 },
            timestampText: message.timestampText)
    }

    static func clampedPollInterval(_ suggested: Int?) -> Int {
        guard let suggested else { return defaultPollMilliseconds }
        // Respect a server asking for *slower* only up to the target; a
        // rolling-window endpoint doesn't need the 10s it advertises.
        return min(max(suggested, minimumPollMilliseconds), targetPollMilliseconds)
    }

    /// A well-formed server rejection (404 with or without a JSON error body)
    /// means this video has no chat here — retrying can't fix it. Anything
    /// else (network hiccups, 5xx, decode noise) is worth another poll.
    static func isPermanentFailure(_ error: Error) -> Bool {
        switch error {
        case PipedError.http(let code), PipedError.upstream(_, .some(let code)):
            (400..<500).contains(code) && ![408, 425, 429].contains(code)
        default: false
        }
    }
}
