import Foundation

/// One page of `/livechat/:videoId` — a rolling window of the most recent
/// messages for a currently-live stream. The endpoint is not part of upstream
/// Piped, so most public instances 404 it; callers must treat it as optional.
public struct LiveChatPage: Decodable, Sendable {
    public let videoId: String?
    public let messages: [LiveChatMessage]?
    /// Continuation token. Observed instances return the same latest-window
    /// regardless of the token, so clients poll and de-duplicate by message id
    /// instead of chaining pages.
    public let nextPageToken: String?
    /// Server-suggested delay before the next poll, in milliseconds.
    public let pollAfterMs: Int?

    private enum CodingKeys: String, CodingKey {
        case videoId, messages, nextPageToken, pollAfterMs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try values.decodeIfPresent(String.self, forKey: .videoId)
        messages = try values.decodeLossyArray([LiveChatMessage].self, forKey: .messages)
        nextPageToken = try values.decodeIfPresent(String.self, forKey: .nextPageToken)
        pollAfterMs = try values.decodeIfPresent(Int.self, forKey: .pollAfterMs)
    }

    public init(
        videoId: String?,
        messages: [LiveChatMessage]?,
        nextPageToken: String?,
        pollAfterMs: Int?
    ) {
        self.videoId = videoId
        self.messages = messages
        self.nextPageToken = nextPageToken
        self.pollAfterMs = pollAfterMs
    }
}

public struct LiveChatMessage: Decodable, Sendable, Equatable {
    public let id: String?
    /// YouTube renderer name, e.g. `liveChatTextMessageRenderer`. Non-text
    /// renderers (viewer-engagement banners, paid stickers) carry no `text`
    /// worth showing in a plain chat list.
    public let type: String?
    /// Plain message text; custom channel emoji appear as `:shortcode:` runs.
    public let text: String?
    public let author: String?
    public let authorChannelId: String?
    public let avatar: String?
    /// Microseconds since the epoch, as a decimal string.
    public let timestampUsec: String?
    public let publishedAt: String?
    /// Replay pages only: when the message appeared, as an offset into the
    /// video, with `timestampText` as its human-readable form (e.g. "1:23:45").
    public let videoOffsetMs: Int?
    public let timestampText: String?
    public let verified: Bool?
    public let chatOwner: Bool?
    public let chatModerator: Bool?
    public let chatSponsor: Bool?

    public var isTextMessage: Bool { type == "liveChatTextMessageRenderer" }

    public var timestampMicroseconds: Int64? {
        timestampUsec.flatMap(Int64.init)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, text, author, authorChannelId, avatar
        case timestampUsec, publishedAt, verified, chatOwner, chatModerator, chatSponsor
        case videoOffsetMs, timestampText
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
        type = try values.decodeIfPresent(String.self, forKey: .type)
        text = try values.decodeIfPresent(String.self, forKey: .text)
        author = try values.decodeIfPresent(String.self, forKey: .author)
        authorChannelId = try values.decodeIfPresent(String.self, forKey: .authorChannelId)
        avatar = try values.decodeIfPresent(String.self, forKey: .avatar)
        timestampUsec = try values.decodeIfPresent(String.self, forKey: .timestampUsec)
        publishedAt = try values.decodeIfPresent(String.self, forKey: .publishedAt)
        videoOffsetMs = try values.decodeIfPresent(Int.self, forKey: .videoOffsetMs)
        timestampText = try values.decodeIfPresent(String.self, forKey: .timestampText)
        verified = try values.decodeIfPresent(Bool.self, forKey: .verified)
        chatOwner = try values.decodeIfPresent(Bool.self, forKey: .chatOwner)
        chatModerator = try values.decodeIfPresent(Bool.self, forKey: .chatModerator)
        chatSponsor = try values.decodeIfPresent(Bool.self, forKey: .chatSponsor)
    }

    public init(
        id: String?,
        type: String?,
        text: String?,
        author: String?,
        authorChannelId: String? = nil,
        avatar: String? = nil,
        timestampUsec: String? = nil,
        publishedAt: String? = nil,
        videoOffsetMs: Int? = nil,
        timestampText: String? = nil,
        verified: Bool? = nil,
        chatOwner: Bool? = nil,
        chatModerator: Bool? = nil,
        chatSponsor: Bool? = nil
    ) {
        self.id = id
        self.type = type
        self.text = text
        self.author = author
        self.authorChannelId = authorChannelId
        self.avatar = avatar
        self.timestampUsec = timestampUsec
        self.publishedAt = publishedAt
        self.videoOffsetMs = videoOffsetMs
        self.timestampText = timestampText
        self.verified = verified
        self.chatOwner = chatOwner
        self.chatModerator = chatModerator
        self.chatSponsor = chatSponsor
    }
}
