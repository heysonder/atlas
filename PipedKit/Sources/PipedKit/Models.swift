import Foundation

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private struct AnyDecodableValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                _ = try? array.decode(AnyDecodableValue.self)
            }
            return
        }

        if let object = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in object.allKeys {
                _ = try? object.decode(AnyDecodableValue.self, forKey: key)
            }
            return
        }

        let value = try decoder.singleValueContainer()
        if value.decodeNil() { return }
        if (try? value.decode(Bool.self)) != nil { return }
        if (try? value.decode(Double.self)) != nil { return }
        if (try? value.decode(String.self)) != nil { return }
    }
}

private extension KeyedDecodingContainer {
    func decodeLossyArray<Element: Decodable>(
        _ type: [Element].Type,
        forKey key: Key
    ) throws -> [Element]? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        var container = try nestedUnkeyedContainer(forKey: key)
        var output: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                output.append(element)
            } else if (try? container.decode(AnyDecodableValue.self)) == nil {
                break
            }
        }
        return output
    }
}

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
    public let livestream: Bool?

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
    public var isLive: Bool { livestream == true }
    public var needsLiveStatusResolution: Bool { livestream == nil && duration == -1 }
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
    public let audioTrackId: String?
    public let audioTrackName: String?
    public let audioTrackType: String?
    public let audioTrackLocale: String?
    public let language: String?
    public let languageCode: String?
    public let name: String?

    public init(
        url: String?,
        format: String?,
        quality: String?,
        mimeType: String?,
        codec: String?,
        videoOnly: Bool?,
        bitrate: Int?,
        width: Int?,
        height: Int?,
        fps: Int?,
        audioTrackId: String? = nil,
        audioTrackName: String? = nil,
        audioTrackType: String? = nil,
        audioTrackLocale: String? = nil,
        language: String? = nil,
        languageCode: String? = nil,
        name: String? = nil
    ) {
        self.url = url
        self.format = format
        self.quality = quality
        self.mimeType = mimeType
        self.codec = codec
        self.videoOnly = videoOnly
        self.bitrate = bitrate
        self.width = width
        self.height = height
        self.fps = fps
        self.audioTrackId = audioTrackId
        self.audioTrackName = audioTrackName
        self.audioTrackType = audioTrackType
        self.audioTrackLocale = audioTrackLocale
        self.language = language
        self.languageCode = languageCode
        self.name = name
    }

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

    public var audioLanguageHints: [String] {
        [audioTrackId, audioTrackName, audioTrackType, audioTrackLocale, language, languageCode, name, quality]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Full video details (/streams/{id})
public struct VideoCreator: Codable, Hashable, Sendable {
    public let name: String?
    public let url: String?
    public let avatar: String?
    public let role: String?

    public var channelID: String? { PipedID.channel(fromURL: url) }
}

public struct Subtitle: Codable, Hashable, Sendable {
    public let autoGenerated: Bool?
    public let code: String?
    public let mimeType: String?
    public let name: String?
    public let url: String?

    public var usableURL: URL? {
        guard let url, !url.isEmpty else { return nil }
        return URL(string: url)
    }
}

public struct VideoChapter: Codable, Hashable, Identifiable, Sendable {
    public let title: String?
    public let image: String?
    public let start: Int

    public var id: String { "\(start)|\(title ?? "")" }
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
    public let chapters: [VideoChapter]?
    public let videoStreams: [Stream]?
    public let audioStreams: [Stream]?
    public let subtitles: [Subtitle]?
    public let relatedStreams: [StreamItem]?
    public let category: String?    // YouTube's own label, e.g. "News & politics"
    public let tags: [String]?      // creator-supplied keywords — clean, no ad copy

    enum CodingKeys: String, CodingKey {
        case title, description, uploader, uploaderUrl, uploaderAvatar, thumbnailUrl
        case hls, duration, views, likes, uploaded, uploaderVerified, uploaderSubscriberCount
        case creators, livestream, chapters, videoStreams, audioStreams, subtitles, relatedStreams
        case category, tags
    }

    public init(
        title: String?,
        description: String?,
        uploader: String?,
        uploaderUrl: String?,
        uploaderAvatar: String?,
        thumbnailUrl: String?,
        hls: String?,
        duration: Int?,
        views: Int?,
        likes: Int?,
        uploaded: Int64?,
        uploaderVerified: Bool?,
        uploaderSubscriberCount: Int?,
        creators: [VideoCreator]?,
        livestream: Bool?,
        chapters: [VideoChapter]?,
        videoStreams: [Stream]?,
        audioStreams: [Stream]?,
        subtitles: [Subtitle]?,
        relatedStreams: [StreamItem]?,
        category: String?,
        tags: [String]?
    ) {
        self.title = title
        self.description = description
        self.uploader = uploader
        self.uploaderUrl = uploaderUrl
        self.uploaderAvatar = uploaderAvatar
        self.thumbnailUrl = thumbnailUrl
        self.hls = hls
        self.duration = duration
        self.views = views
        self.likes = likes
        self.uploaded = uploaded
        self.uploaderVerified = uploaderVerified
        self.uploaderSubscriberCount = uploaderSubscriberCount
        self.creators = creators
        self.livestream = livestream
        self.chapters = chapters
        self.videoStreams = videoStreams
        self.audioStreams = audioStreams
        self.subtitles = subtitles
        self.relatedStreams = relatedStreams
        self.category = category
        self.tags = tags
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try values.decodeIfPresent(String.self, forKey: .title)
        self.description = try values.decodeIfPresent(String.self, forKey: .description)
        self.uploader = try values.decodeIfPresent(String.self, forKey: .uploader)
        self.uploaderUrl = try values.decodeIfPresent(String.self, forKey: .uploaderUrl)
        self.uploaderAvatar = try values.decodeIfPresent(String.self, forKey: .uploaderAvatar)
        self.thumbnailUrl = try values.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        self.hls = try values.decodeIfPresent(String.self, forKey: .hls)
        self.duration = try values.decodeIfPresent(Int.self, forKey: .duration)
        self.views = try values.decodeIfPresent(Int.self, forKey: .views)
        self.likes = try values.decodeIfPresent(Int.self, forKey: .likes)
        self.uploaded = try values.decodeIfPresent(Int64.self, forKey: .uploaded)
        self.uploaderVerified = try values.decodeIfPresent(Bool.self, forKey: .uploaderVerified)
        self.uploaderSubscriberCount = try values.decodeIfPresent(Int.self, forKey: .uploaderSubscriberCount)
        self.creators = try values.decodeIfPresent([VideoCreator].self, forKey: .creators)
        self.livestream = try values.decodeIfPresent(Bool.self, forKey: .livestream)
        self.chapters = try values.decodeLossyArray([VideoChapter].self, forKey: .chapters)
        self.videoStreams = try values.decodeIfPresent([Stream].self, forKey: .videoStreams)
        self.audioStreams = try values.decodeIfPresent([Stream].self, forKey: .audioStreams)
        self.subtitles = try values.decodeIfPresent([Subtitle].self, forKey: .subtitles)
        self.relatedStreams = try values.decodeIfPresent([StreamItem].self, forKey: .relatedStreams)
        self.category = try values.decodeIfPresent(String.self, forKey: .category)
        self.tags = try values.decodeIfPresent([String].self, forKey: .tags)
    }

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

    /// Whether the instance extracted at least one AV1 video stream. This is the
    /// signal that its `/hls/av1/{id}/master.m3u8` endpoint can actually build a
    /// master playlist: most videos extract HLS-only (empty `videoStreams`), and
    /// for those the AV1 HLS endpoint returns 404. Gating the optimistic AV1 HLS
    /// attempt on this avoids a guaranteed failed playback cycle per video.
    public var hasAV1VideoStream: Bool {
        (videoStreams ?? []).contains { $0.isAV1 }
    }

    /// The highest-resolution video-only stream AVPlayer can decode, paired with
    /// the best audio stream, for an `AVMutableComposition`. `allowAV1` should
    /// reflect device hardware support. Returns nil if no compose-able pair exists.
    public func bestComposedSource(
        allowAV1: Bool,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> (video: URL, audio: URL, height: Int)? {
        let candidates = (videoStreams ?? []).filter { stream in
            guard !stream.isProgressive, stream.url?.isEmpty == false, !stream.isVP9OrWebM else { return false }
            return stream.isH264 || (allowAV1 && stream.isAV1)
        }
        guard let video = candidates.max(by: { ($0.height ?? 0) < ($1.height ?? 0) }),
              let videoURLString = video.url, let videoURL = URL(string: videoURLString) else { return nil }

        let audio = (audioStreams ?? [])
            .filter { $0.isPlayableAudio && $0.url?.isEmpty == false }
            .max {
                Self.audioScore($0, preferredLanguages: preferredLanguages)
                    < Self.audioScore($1, preferredLanguages: preferredLanguages)
            }
        guard let audioURLString = audio?.url, let audioURL = URL(string: audioURLString) else { return nil }

        return (videoURL, audioURL, video.height ?? 0)
    }

    public static func audioScore(_ stream: Stream, preferredLanguages: [String] = Locale.preferredLanguages) -> Int {
        let hints = stream.audioLanguageHints.map {
            $0.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        let preferred = preferredLanguagesWithEnglishFallback(preferredLanguages)
        var languageScore = 0
        for (index, language) in preferred.enumerated() {
            let weight = max(0, 1_000 - index * 25)
            if hints.contains(language) {
                languageScore = max(languageScore, weight)
            } else if hints.contains(where: { hint in
                hint.hasPrefix(language + "-")
                    || language.hasPrefix(hint + "-")
                    || hint.localizedStandardContains(languageName(for: language))
            }) {
                languageScore = max(languageScore, weight - 10)
            }
        }
        var result = languageScore * 1_000
        if hints.contains(where: { $0.contains("original") }) {
            result += 500
        }
        if hints.contains(where: { $0.contains("dub") }) {
            result -= 500
        }
        result += min(max(stream.bitrate ?? 0, 0) / 1_000, 499)
        return result
    }

    public func preferredSubtitle(preferredLanguages: [String] = Locale.preferredLanguages) -> Subtitle? {
        let candidates = (subtitles ?? []).filter { $0.usableURL != nil }
        guard !candidates.isEmpty else { return nil }
        let languageCodes = preferredLanguages.flatMap(Self.languageCandidates)

        func score(_ subtitle: Subtitle) -> Int {
            let code = (subtitle.code ?? "").lowercased()
            let name = (subtitle.name ?? "").lowercased()
            var result = subtitle.autoGenerated == true ? 0 : 100
            if languageCodes.contains(code) {
                result += 50
            } else if languageCodes.contains(where: { code.hasPrefix($0 + "-") || name.contains($0) }) {
                result += 25
            }
            return result
        }

        return candidates.max { score($0) < score($1) }
    }

    private static func languageCandidates(_ identifier: String) -> [String] {
        let lower = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        var output = [lower]
        if let base = lower.split(separator: "-").first {
            output.append(String(base))
        }
        return output
    }

    private static func preferredLanguagesWithEnglishFallback(_ preferredLanguages: [String]) -> [String] {
        var output: [String] = []
        for language in preferredLanguages.flatMap(languageCandidates) where !output.contains(language) {
            output.append(language)
        }
        for language in ["en-us", "en"] where !output.contains(language) {
            output.append(language)
        }
        return output
    }

    private static func languageName(for language: String) -> String {
        let base = language.split(separator: "-").first.map(String.init) ?? language
        return Locale(identifier: "en_US").localizedString(forLanguageCode: base)?.lowercased() ?? base
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

    enum CodingKeys: String, CodingKey {
        case segments, hash
    }

    public init(segments: [SponsorSegment]?, hash: String?) {
        self.segments = segments
        self.hash = hash
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.segments = try values.decodeLossyArray([SponsorSegment].self, forKey: .segments)
        self.hash = try values.decodeIfPresent(String.self, forKey: .hash)
    }
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
    public let tabs: [ChannelTab]?
}

public struct ChannelTab: Codable, Hashable, Sendable {
    public let name: String?
    public let data: String?
}

public struct ChannelTabPage: Codable, Sendable {
    public let content: [StreamItem]?
    public let nextpage: String?
}

// MARK: - Comments (/comments/{id} and /nextpage/comments/{id})

/// A timestamp mentioned in a comment body, normalized to seconds.
public struct CommentTimestamp: Hashable, Identifiable, Sendable {
    public let seconds: Int
    public let label: String

    public var id: String { "\(seconds)|\(label)" }

    public init(seconds: Int, label: String) {
        self.seconds = seconds
        self.label = label
    }

    public static func extract(from text: String) -> [CommentTimestamp] {
        let pattern = #"(?<![\d:])(?:(\d{1,2}):)?(\d{1,3}):(\d{2})(?![\d:])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound,
                      let swiftRange = Range(range, in: text) else { return nil }
                return String(text[swiftRange])
            }

            guard let label = group(0),
                  let middleText = group(2),
                  let secondsText = group(3),
                  let middle = Int(middleText),
                  let seconds = Int(secondsText),
                  seconds < 60 else { return nil }

            if let hoursText = group(1), let hours = Int(hoursText) {
                guard middle < 60 else { return nil }
                return CommentTimestamp(seconds: hours * 3600 + middle * 60 + seconds,
                                        label: label)
            }
            return CommentTimestamp(seconds: middle * 60 + seconds, label: label)
        }
    }
}

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
    /// Timestamps such as `1:23` or `1:02:03` mentioned in the comment body.
    public var timestamps: [CommentTimestamp] {
        CommentTimestamp.extract(from: plainText)
    }
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
