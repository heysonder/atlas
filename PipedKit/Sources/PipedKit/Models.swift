import Foundation

// MARK: - Stream list item
// Shared shape returned by /search, /feed and a channel's relatedStreams.
// Fields are widely optional on purpose: instances frequently return partial
// data when YouTube extraction is degraded.
public struct StreamItem: Codable, Identifiable, Hashable, Sendable {
    public let url: String          // "/watch?v=ID" (video) or "/channel/ID"
    public let type: String?        // "stream" | "channel" | "playlist"
    public let title: String?
    public let name: String?        // channel results use `name` instead of `title`
    public let thumbnail: String?
    public let uploaderName: String?
    public let uploaderUrl: String?
    public let uploaderAvatar: String?
    public let uploadedDate: String?
    public let shortDescription: String?
    public let description: String?
    public let duration: Int?
    public let views: Int?
    public let uploaded: Int64?
    public let subscribers: Int?    // channel results
    public let videos: Int?         // channel results: number of uploads
    public let verified: Bool?
    public let uploaderVerified: Bool?
    public let isShort: Bool?

    /// Stable identity: the video id when present, else the raw url.
    public var id: String { videoID ?? url }

    /// "ID" extracted from "/watch?v=ID".
    public var videoID: String? { PipedID.video(fromWatchURL: url) }
    /// For a channel result: "ID" from this item's own "/channel/ID" url.
    public var ownChannelID: String? { PipedID.channel(fromURL: url) }
    /// For a video result: the uploader's "/channel/ID".
    public var uploaderChannelID: String? { PipedID.channel(fromURL: uploaderUrl) }

    public var isVideo: Bool { (type ?? "stream") == "stream" && videoID != nil }
    public var isChannel: Bool { type == "channel" || ownChannelID != nil }
    public var displayTitle: String { title ?? name ?? "Untitled" }
}

// MARK: - Video / audio stream
public struct Stream: Codable, Hashable, Sendable {
    public let url: String?
    public let format: String?
    public let quality: String?
    public let mimeType: String?
    public let codec: String?
    public let videoOnly: Bool?
    public let bitrate: Int?
    public let width: Int?
    public let height: Int?
    public let fps: Int?

    /// True when this progressive stream carries both audio and video.
    public var isProgressive: Bool { (videoOnly ?? false) == false }

    private var codecLower: String { (codec ?? "").lowercased() }
    private var mimeLower: String { (mimeType ?? "").lowercased() }

    /// H.264 in an mp4 container — decodable by AVPlayer on every device.
    public var isH264: Bool {
        codecLower.hasPrefix("avc1") || (codecLower.isEmpty && mimeLower.contains("mp4") && !isAV1)
    }
    /// AV1 in an mp4 container — decodable only on AV1-capable devices (A17 Pro+).
    public var isAV1: Bool { codecLower.hasPrefix("av01") }
    /// VP9/WebM — AVFoundation cannot decode this; never selectable.
    public var isVP9OrWebM: Bool {
        codecLower.hasPrefix("vp9") || codecLower.hasPrefix("vp09") || mimeLower.contains("webm")
    }
    /// Audio that AVPlayer can play (AAC/m4a in mp4), not Opus/WebM.
    public var isPlayableAudio: Bool { mimeLower.contains("mp4") && !mimeLower.contains("webm") }
}

// MARK: - Full video details (/streams/{id})
public struct VideoCreator: Codable, Hashable, Sendable {
    public let name: String?
    public let url: String?
    public let avatar: String?
    public let role: String?

    public var channelID: String? { PipedID.channel(fromURL: url) }
}

public struct VideoDetail: Codable, Sendable {
    public let title: String?
    public let description: String?
    public let uploader: String?
    public let uploaderUrl: String?
    public let uploaderAvatar: String?
    public let thumbnailUrl: String?
    public let hls: String?
    public let duration: Int?
    public let views: Int?
    public let likes: Int?
    public let uploaded: Int64?
    public let uploaderVerified: Bool?
    public let uploaderSubscriberCount: Int?
    public let creators: [VideoCreator]?
    public let livestream: Bool?
    public let videoStreams: [Stream]?
    public let audioStreams: [Stream]?
    public let relatedStreams: [StreamItem]?
    public let category: String?    // YouTube's own label, e.g. "News & politics"
    public let tags: [String]?      // creator-supplied keywords — clean, no ad copy

    public var channelID: String? { PipedID.channel(fromURL: uploaderUrl) }

    /// The video's real width/height ratio, from the first stream that reports a size.
    /// Falls back to 16:9 when the instance doesn't provide dimensions.
    public var aspectRatio: Double {
        if let s = (videoStreams ?? []).first(where: { ($0.width ?? 0) > 0 && ($0.height ?? 0) > 0 }),
           let w = s.width, let h = s.height {
            return Double(w) / Double(h)
        }
        return 16.0 / 9.0
    }

    /// Best URL AVPlayer can play on its own:
    /// 1. HLS (adaptive, includes audio) when the instance provides it.
    /// 2. Highest-resolution progressive (audio+video) stream as a fallback.
    /// Returns nil when the instance failed to extract anything playable.
    public var playableURL: URL? {
        if let hls, !hls.isEmpty, let u = URL(string: hls) { return u }
        let best = (videoStreams ?? [])
            .filter { $0.isProgressive && ($0.url?.isEmpty == false) }
            .max { ($0.height ?? 0) < ($1.height ?? 0) }
        if let s = best, let raw = s.url { return URL(string: raw) }
        return nil
    }

    /// Best single-file progressive (muxed audio+video) stream for an offline
    /// download — the simplest reliable asset, since it needs no merge step.
    /// Skips VP9/WebM (AVFoundation can't decode it). Returns nil when the
    /// instance only exposes adaptive (video-only) streams.
    public var bestProgressiveDownload: (url: URL, height: Int)? {
        let best = (videoStreams ?? [])
            .filter { $0.isProgressive && !$0.isVP9OrWebM && ($0.url?.isEmpty == false) }
            .max { ($0.height ?? 0) < ($1.height ?? 0) }
        guard let s = best, let raw = s.url, let u = URL(string: raw) else { return nil }
        return (u, s.height ?? 0)
    }

    /// The highest-resolution video-only stream AVPlayer can decode, paired with
    /// the best audio stream, for an `AVMutableComposition`. `allowAV1` should
    /// reflect device hardware support. Returns nil if no compose-able pair exists.
    public func bestComposedSource(allowAV1: Bool) -> (video: URL, audio: URL, height: Int)? {
        let candidates = (videoStreams ?? []).filter { stream in
            guard !stream.isProgressive, stream.url?.isEmpty == false, !stream.isVP9OrWebM else { return false }
            return stream.isH264 || (allowAV1 && stream.isAV1)
        }
        guard let video = candidates.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }),
              let videoURLString = video.url, let videoURL = URL(string: videoURLString) else { return nil }

        let audio = (audioStreams ?? [])
            .filter { $0.isPlayableAudio && $0.url?.isEmpty == false }
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        guard let audioURLString = audio?.url, let audioURL = URL(string: audioURLString) else { return nil }

        return (videoURL, audioURL, video.height ?? 0)
    }
}

// MARK: - SponsorBlock (/sponsors/{id})

/// One crowdsourced SponsorBlock segment for a video. `segment` is `[start, end]`
/// in seconds. Returned by the instance's `/sponsors/{id}` proxy of the
/// SponsorBlock API.
public struct SponsorSegment: Codable, Hashable, Sendable {
    public let segment: [Double]
    public let category: String
    /// "skip" (jump past), "mute", "poi" (highlight), "full" (whole-video label).
    /// Atlas only acts on "skip".
    public let actionType: String?
    public let uuid: String?

    public var start: Double { segment.first ?? 0 }
    public var end: Double { segment.count > 1 ? segment[1] : start }

    /// The typed category, when it's one Atlas knows about.
    public var sponsorCategory: SponsorCategory? { SponsorCategory(rawValue: category) }

    enum CodingKeys: String, CodingKey {
        case segment, category, actionType
        case uuid = "UUID"
    }

    public init(segment: [Double], category: String, actionType: String? = "skip", uuid: String? = nil) {
        self.segment = segment
        self.category = category
        self.actionType = actionType
        self.uuid = uuid
    }
}

/// The `/sponsors/{id}` envelope. `segments` is absent/empty when the video has
/// no crowdsourced data.
public struct SponsorSegmentsResponse: Codable, Sendable {
    public let segments: [SponsorSegment]?
    public let hash: String?
}

/// SponsorBlock's segment categories, by their API id. `label`/`skipLabel`
/// carry display strings so the UI doesn't re-derive them.
public enum SponsorCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case sponsor
    case selfpromo
    case interaction
    case intro
    case outro
    case preview
    case musicOfftopic = "music_offtopic"
    case filler

    public var id: String { rawValue }

    /// Settings-row label.
    public var label: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Self-promotion"
        case .interaction: "Interaction reminder"
        case .intro: "Intro / intermission"
        case .outro: "Outro / endcards"
        case .preview: "Preview / recap"
        case .musicOfftopic: "Non-music section"
        case .filler: "Filler tangent"
        }
    }

    /// Short noun for the in-player "Skip …" button.
    public var skipLabel: String {
        switch self {
        case .sponsor: "Sponsor"
        case .selfpromo: "Self-promo"
        case .interaction: "Interaction"
        case .intro: "Intro"
        case .outro: "Outro"
        case .preview: "Preview"
        case .musicOfftopic: "Non-music"
        case .filler: "Filler"
        }
    }
}

// MARK: - Channel (/channel/{id})
public struct Channel: Codable, Sendable {
    public let id: String?
    public let name: String?
    public let avatarUrl: String?
    public let bannerUrl: String?
    public let description: String?
    public let nextpage: String?
    public let subscriberCount: Int?
    public let verified: Bool?
    public let relatedStreams: [StreamItem]?
}

// MARK: - Comments (/comments/{id} and /nextpage/comments/{id})

/// One comment (or, when fetched via a parent's `repliesPage`, one reply).
/// `commentText` is HTML, like descriptions — render through `plainText`.
public struct Comment: Codable, Identifiable, Sendable {
    public let author: String?
    public let thumbnail: String?       // commenter avatar URL
    public let commentId: String?
    public let commentText: String?     // HTML
    public let commentedTime: String?   // already human-readable, e.g. "2 days ago"
    public let commentorUrl: String?    // "/channel/ID"
    public let repliesPage: String?     // nextpage token for this comment's replies
    public let hearted: Bool?           // hearted by the creator
    public let likeCount: Int?
    public let pinned: Bool?
    public let verified: Bool?          // commenter is verified
    public let replyCount: Int?
    public let creatorReplied: Bool?

    /// Stable identity for `ForEach`; `commentId` is reliably present in practice.
    public var id: String {
        commentId ?? "\(author ?? "")|\(commentedTime ?? "")|\(likeCount ?? 0)"
    }
    /// The commenter's "/channel/ID", when known.
    public var channelID: String? { PipedID.channel(fromURL: commentorUrl) }
    /// HTML-stripped comment body.
    public var plainText: String { HTMLText.plain(commentText ?? "") }
    /// True when there are replies that can be fetched via `repliesPage`.
    public var hasReplies: Bool { (replyCount ?? 0) > 0 && repliesPage != nil }
}

/// The `/comments/{id}` envelope. `disabled` is true when the uploader turned
/// comments off; `nextpage` paginates further comments (or, for a reply fetch,
/// further replies).
public struct CommentsPage: Codable, Sendable {
    public let comments: [Comment]?
    public let nextpage: String?
    public let disabled: Bool?
    /// Total comment count, or -1 when the instance couldn't determine it.
    public let commentCount: Int?
}

// MARK: - Search response (/search)
public struct SearchResponse: Codable, Sendable {
    public let items: [StreamItem]?
    public let nextpage: String?
    public let suggestion: String?
    public let corrected: Bool?
}

// MARK: - Public instance directory entry
public struct PipedInstance: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let apiUrl: String
    public let locations: String?
    public let cdn: Bool?
    public let registered: Int?
    public let uptime24h: Double?

    public var id: String { apiUrl }

    enum CodingKeys: String, CodingKey {
        case name
        case apiUrl = "api_url"
        case locations
        case cdn
        case registered
        case uptime24h = "uptime_24h"
    }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
}

// MARK: - ID parsing helpers
public enum PipedID {
    public static func video(fromWatchURL url: String?) -> String? {
        guard let url else { return nil }
        guard let comps = URLComponents(string: "https://x.invalid" + url) else { return nil }
        return comps.queryItems?.first(where: { $0.name == "v" })?.value
    }

    public static func channel(fromURL url: String?) -> String? {
        guard let url, let range = url.range(of: "/channel/") else { return nil }
        let tail = url[range.upperBound...]
        return tail.split(separator: "/").first.map(String.init)
    }
}
