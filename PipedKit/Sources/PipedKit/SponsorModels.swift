import Foundation

/// One crowdsourced SponsorBlock segment for a video.
public struct SponsorSegment: Codable, Hashable, Sendable {
    public let segment: [Double]
    public let category: String
    public let actionType: String?
    public let uuid: String?

    public var start: Double { segment.first ?? 0 }
    public var end: Double { segment.count > 1 ? segment[1] : start }
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
