import Foundation

public struct SearchResponse: Codable, Sendable {
    public let items: [StreamItem]?
    public let nextPage: String?
    public let suggestion: String?
    public let corrected: Bool?

    enum CodingKeys: String, CodingKey {
        case items
        case nextPage = "nextpage"
        case suggestion, corrected
    }

    public init(items: [StreamItem]?, nextPage: String?, suggestion: String?, corrected: Bool?) {
        self.items = items
        self.nextPage = nextPage
        self.suggestion = suggestion
        self.corrected = corrected
    }

    @available(*, deprecated, renamed: "init(items:nextPage:suggestion:corrected:)")
    public init(items: [StreamItem]?, nextpage: String?, suggestion: String?, corrected: Bool?) {
        self.init(items: items, nextPage: nextpage, suggestion: suggestion, corrected: corrected)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try values.decodeLossyArray([StreamItem].self, forKey: .items)
        self.nextPage = try values.decodeIfPresent(String.self, forKey: .nextPage)
        self.suggestion = try values.decodeIfPresent(String.self, forKey: .suggestion)
        self.corrected = try values.decodeIfPresent(Bool.self, forKey: .corrected)
    }

    @available(*, deprecated, renamed: "nextPage")
    public var nextpage: String? { nextPage }
}
