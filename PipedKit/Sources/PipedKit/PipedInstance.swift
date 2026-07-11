import Foundation

public struct PipedInstance: Codable, Identifiable, Hashable, Sendable {
    public let name: String
    public let apiURL: String
    public let locations: String?
    public let cdn: Bool?
    public let registered: Int?
    public let uptime24h: Double?

    public var id: String { apiURL }

    enum CodingKeys: String, CodingKey {
        case name
        case apiURL = "api_url"
        case locations
        case cdn
        case registered
        case uptime24h = "uptime_24h"
    }

    @available(*, deprecated, renamed: "apiURL")
    public var apiUrl: String { apiURL }

    public var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
}
