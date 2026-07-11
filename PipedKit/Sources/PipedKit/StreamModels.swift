import Foundation

/// Shared item shape returned by search, feed, and channel-related endpoints.
/// Fields are intentionally optional because instances can return partial data.
public struct StreamItem: Codable, Identifiable, Hashable, Sendable {
    public let url: String
    public let type: String?
    public let title: String?
    public let name: String?
    public let thumbnail: String?
    public let uploaderName: String?
    public let uploaderURL: String?
    public let uploaderAvatar: String?
    public let uploadedDate: String?
    public let shortDescription: String?
    public let description: String?
    public let duration: Int?
    public let views: Int?
    public let uploaded: Int64?
    public let subscribers: Int?
    public let videos: Int?
    public let verified: Bool?
    public let uploaderVerified: Bool?
    public let isShort: Bool?
    public let livestream: Bool?

    enum CodingKeys: String, CodingKey {
        case url, type, title, name, thumbnail, uploaderName
        case uploaderURL = "uploaderUrl"
        case uploaderAvatar, uploadedDate, shortDescription, description
        case duration, views, uploaded, subscribers, videos, verified
        case uploaderVerified, isShort, livestream
    }

    @available(*, deprecated, renamed: "uploaderURL")
    public var uploaderUrl: String? { uploaderURL }

    /// Stable identity: the video ID when present, otherwise the raw URL string.
    public var id: String { videoID ?? url }

    public var videoID: String? { PipedID.video(fromWatchURL: url) }
    public var ownChannelID: String? { PipedID.channel(fromURL: url) }
    public var uploaderChannelID: String? { PipedID.channel(fromURL: uploaderURL) }

    public var isVideo: Bool { (type ?? "stream") == "stream" && videoID != nil }
    public var isChannel: Bool { type == "channel" || ownChannelID != nil }
    public var displayTitle: String { title ?? name ?? "Untitled" }
    public var isLive: Bool { livestream == true }
    public var needsLiveStatusResolution: Bool { livestream == nil && duration == -1 }
}

public struct MediaStream: Codable, Hashable, Sendable {
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
    public let audioTrackID: String?
    public let audioTrackName: String?
    public let audioTrackType: String?
    public let audioTrackLocale: String?
    public let language: String?
    public let languageCode: String?
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case url, format, quality, mimeType, codec, videoOnly, bitrate, width, height, fps
        case audioTrackID = "audioTrackId"
        case audioTrackName, audioTrackType, audioTrackLocale, language, languageCode, name
    }

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
        audioTrackID: String? = nil,
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
        self.audioTrackID = audioTrackID
        self.audioTrackName = audioTrackName
        self.audioTrackType = audioTrackType
        self.audioTrackLocale = audioTrackLocale
        self.language = language
        self.languageCode = languageCode
        self.name = name
    }

    @available(
        *, deprecated,
        renamed:
            "init(url:format:quality:mimeType:codec:videoOnly:bitrate:width:height:fps:audioTrackID:audioTrackName:audioTrackType:audioTrackLocale:language:languageCode:name:)"
    )
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
        audioTrackId: String?,
        audioTrackName: String? = nil,
        audioTrackType: String? = nil,
        audioTrackLocale: String? = nil,
        language: String? = nil,
        languageCode: String? = nil,
        name: String? = nil
    ) {
        self.init(
            url: url,
            format: format,
            quality: quality,
            mimeType: mimeType,
            codec: codec,
            videoOnly: videoOnly,
            bitrate: bitrate,
            width: width,
            height: height,
            fps: fps,
            audioTrackID: audioTrackId,
            audioTrackName: audioTrackName,
            audioTrackType: audioTrackType,
            audioTrackLocale: audioTrackLocale,
            language: language,
            languageCode: languageCode,
            name: name)
    }

    @available(*, deprecated, renamed: "audioTrackID")
    public var audioTrackId: String? { audioTrackID }

    public var isProgressive: Bool { (videoOnly ?? false) == false }

    private var codecLower: String { (codec ?? "").lowercased() }
    private var mimeLower: String { (mimeType ?? "").lowercased() }

    public var isH264: Bool {
        codecLower.hasPrefix("avc1")
            || (codecLower.isEmpty && mimeLower.hasPrefix("video/") && mimeLower.contains("mp4"))
    }

    public var isAV1: Bool { codecLower.hasPrefix("av01") }

    public var isVP9OrWebM: Bool {
        codecLower.hasPrefix("vp9") || codecLower.hasPrefix("vp09") || mimeLower.contains("webm")
    }

    public var isPlayableAudio: Bool { mimeLower.contains("mp4") && !mimeLower.contains("webm") }

    public var audioLanguageHints: [String] {
        [audioTrackID, audioTrackName, audioTrackType, audioTrackLocale, language, languageCode, name, quality]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

@available(*, deprecated, renamed: "MediaStream")
public typealias Stream = MediaStream
