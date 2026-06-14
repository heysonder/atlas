import Foundation
import SwiftData

/// A channel the user subscribed to (stored locally — no Piped account needed).
@Model
final class SubscribedChannel {
    @Attribute(.unique) var channelID: String
    var name: String
    var avatarURL: String?
    var subscribedAt: Date

    init(channelID: String, name: String, avatarURL: String? = nil, subscribedAt: Date = .now) {
        self.channelID = channelID
        self.name = name
        self.avatarURL = avatarURL
        self.subscribedAt = subscribedAt
    }
}
