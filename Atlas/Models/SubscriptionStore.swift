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
        do {
            if subscribed {
                try PersistedMetadataPolicy.requireIdentifier(channelID, field: "subscription.channelID")
                try PersistedMetadataPolicy.requireText(name ?? "Channel", field: "subscription.name")
                try PersistedMetadataPolicy.requireOptionalURL(avatarURL, field: "subscription.avatarURL")
            }
            let descriptor = FetchDescriptor<SubscribedChannel>(
                predicate: #Predicate { $0.channelID == channelID })
            let existing = try context.fetch(descriptor).first
            if subscribed, existing == nil {
                guard
                    try context.fetchCount(FetchDescriptor<SubscribedChannel>())
                        < PersistedMetadataPolicy.maximumChannels,
                    PersistedMetadataCapacity.allowsAddingTopLevelRecord(in: context)
                else { return false }
            }
            try LibrarySyncJournal.transaction(in: context, captureChanges: false) {
                if subscribed {
                    if let existing {
                        if let name { existing.name = name }
                        if let avatarURL { existing.avatarURL = avatarURL }
                    } else {
                        context.insert(
                            SubscribedChannel(
                                channelID: channelID, name: name ?? "Channel", avatarURL: avatarURL))
                    }
                    try LibrarySyncJournal.capture(
                        kind: .subscription, entityID: channelID, in: context)
                } else {
                    try LibraryDeletionJournal.record(
                        kind: .subscription, entityID: channelID, in: context)
                    if let existing { context.delete(existing) }
                }
            }
            if subscribed {
                SpotlightIndexer.index(
                    channelID: channelID, name: name ?? existing?.name ?? "Channel", avatarURL: avatarURL)
            } else {
                SpotlightIndexer.remove(channelID: channelID)
            }
            return true
        } catch {
            return false
        }
    }
}

/// Malformed legacy rows must remain removable. Values that could never enter
/// sync need no new cloud identity; previously journaled identities still retain
/// their deletion when their compact envelope satisfies the protocol bound.
@MainActor
enum LibraryDeletionJournal {
    static func record(
        kind: SyncKind, entityID: String, sourceIdentifier: String? = nil,
        in context: ModelContext
    ) throws {
        let source = sourceIdentifier ?? entityID
        let isValid = (try? PersistedMetadataPolicy.requireIdentifier(source, field: "deletion.id")) != nil
        if !isValid {
            guard entityID.utf8.count <= 2_048 else { return }
            guard try LibrarySyncJournal.hasRecord(kind: kind, entityID: entityID, in: context) else { return }
        }
        try LibrarySyncJournal.record(kind: kind, entityID: entityID, payload: nil, in: context)
    }
}
