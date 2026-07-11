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

    @discardableResult
    static func setSubscribed(
        _ subscribed: Bool, channelID: String?, name: String?,
        avatarURL: String?, in context: ModelContext
    ) -> Bool {
        guard let channelID else { return false }
        let descriptor = FetchDescriptor<SubscribedChannel>(
            predicate: #Predicate { $0.channelID == channelID })
        if !subscribed {
            guard let matches = try? context.fetch(descriptor) else { return false }
            if let existing = matches.first { context.delete(existing) }
            return true
        }
        do {
            try PersistedMetadataPolicy.requireIdentifier(
                channelID, field: "subscription.channelID")
            try PersistedMetadataPolicy.requireText(
                name ?? "Channel", field: "subscription.name")
            try PersistedMetadataPolicy.requireOptionalURL(
                avatarURL, field: "subscription.avatarURL")
        } catch {
            return false
        }
        guard let matches = try? context.fetch(descriptor) else { return false }
        let existing = matches.first
        if existing == nil {
            guard let count = try? context.fetchCount(FetchDescriptor<SubscribedChannel>()),
                count < PersistedMetadataPolicy.maximumChannels,
                PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context)
            else {
                return false
            }
            context.insert(
                SubscribedChannel(
                    channelID: channelID,
                    name: name ?? "Channel",
                    avatarURL: avatarURL))
        }
        return true
    }
}
