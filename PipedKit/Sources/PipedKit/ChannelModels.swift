import Foundation

public struct Channel: Codable, Sendable {
    public let id: String?
    public let name: String?
    public let avatarURL: String?
    public let bannerURL: String?
    public let description: String?
    public let nextPage: String?
    public let subscriberCount: Int?
    public let verified: Bool?
    public let relatedStreams: [StreamItem]?
    public let tabs: [ChannelTab]?

    enum CodingKeys: String, CodingKey {
        case id, name
        case avatarURL = "avatarUrl"
        case bannerURL = "bannerUrl"
        case description
        case nextPage = "nextpage"
        case subscriberCount, verified, relatedStreams, tabs
    }

    public init(
        id: String?,
        name: String?,
        avatarURL: String?,
        bannerURL: String?,
        description: String?,
        nextPage: String?,
        subscriberCount: Int?,
        verified: Bool?,
        relatedStreams: [StreamItem]?,
        tabs: [ChannelTab]?
    ) {
        self.id = id
        self.name = name
        self.avatarURL = avatarURL
        self.bannerURL = bannerURL
        self.description = description
        self.nextPage = nextPage
        self.subscriberCount = subscriberCount
        self.verified = verified
        self.relatedStreams = relatedStreams
        self.tabs = tabs
    }

    @available(
        *, deprecated,
        renamed: "init(id:name:avatarURL:bannerURL:description:nextPage:subscriberCount:verified:relatedStreams:tabs:)"
    )
    public init(
        id: String?,
        name: String?,
        avatarUrl: String?,
        bannerUrl: String?,
        description: String?,
        nextpage: String?,
        subscriberCount: Int?,
        verified: Bool?,
        relatedStreams: [StreamItem]?,
        tabs: [ChannelTab]?
    ) {
        self.init(
            id: id,
            name: name,
            avatarURL: avatarUrl,
            bannerURL: bannerUrl,
            description: description,
            nextPage: nextpage,
            subscriberCount: subscriberCount,
            verified: verified,
            relatedStreams: relatedStreams,
            tabs: tabs)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decodeIfPresent(String.self, forKey: .id)
        self.name = try values.decodeIfPresent(String.self, forKey: .name)
        self.avatarURL = try values.decodeIfPresent(String.self, forKey: .avatarURL)
        self.bannerURL = try values.decodeIfPresent(String.self, forKey: .bannerURL)
        self.description = try values.decodeIfPresent(String.self, forKey: .description)
        self.nextPage = try values.decodeIfPresent(String.self, forKey: .nextPage)
        self.subscriberCount = try values.decodeIfPresent(Int.self, forKey: .subscriberCount)
        self.verified = try values.decodeIfPresent(Bool.self, forKey: .verified)
        self.relatedStreams = try values.decodeLossyArray([StreamItem].self, forKey: .relatedStreams)
        self.tabs = try values.decodeIfPresent([ChannelTab].self, forKey: .tabs)
    }

    @available(*, deprecated, renamed: "avatarURL")
    public var avatarUrl: String? { avatarURL }

    @available(*, deprecated, renamed: "bannerURL")
    public var bannerUrl: String? { bannerURL }

    @available(*, deprecated, renamed: "nextPage")
    public var nextpage: String? { nextPage }
}

public struct ChannelTab: Codable, Hashable, Sendable {
    public let name: String?
    public let data: String?
}

public struct ChannelTabPage: Codable, Sendable {
    public let content: [StreamItem]?
    public let nextPage: String?

    enum CodingKeys: String, CodingKey {
        case content
        case nextPage = "nextpage"
    }

    public init(content: [StreamItem]?, nextPage: String?) {
        self.content = content
        self.nextPage = nextPage
    }

    @available(*, deprecated, renamed: "init(content:nextPage:)")
    public init(content: [StreamItem]?, nextpage: String?) {
        self.init(content: content, nextPage: nextpage)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try values.decodeLossyArray([StreamItem].self, forKey: .content)
        self.nextPage = try values.decodeIfPresent(String.self, forKey: .nextPage)
    }

    @available(*, deprecated, renamed: "nextPage")
    public var nextpage: String? { nextPage }
}
