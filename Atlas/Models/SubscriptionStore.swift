import Foundation
import SwiftData

@MainActor
enum SubscriptionStore {
    static func isSubscribed(_ channelID: String?, in context: ModelContext) -> Bool {
        guard let channelID else { return false }
        let descriptor = FetchDescriptor<SubscribedChannel>(
            predicate: #Predicate { $0.channelID == channelID })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    static func setSubscribed(_ subscribed: Bool, channelID: String?, name: String?,
                              avatarURL: String?, in context: ModelContext) {
        guard let channelID else { return }
        let descriptor = FetchDescriptor<SubscribedChannel>(
            predicate: #Predicate { $0.channelID == channelID })
        let existing = (try? context.fetch(descriptor))?.first
        if subscribed {
            if existing == nil {
                context.insert(SubscribedChannel(
                    channelID: channelID,
                    name: name ?? "Channel",
                    avatarURL: avatarURL))
            }
        } else if let existing {
            context.delete(existing)
        }
    }
}
